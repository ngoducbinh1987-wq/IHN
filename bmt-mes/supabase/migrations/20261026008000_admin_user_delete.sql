-- Quản trị hệ thống xóa người dùng (anh Bình yêu cầu 01/11/2026).
-- Người dùng chưa để lại dấu vết nghiệp vụ (chưa lập, duyệt, ghi nhận gì) → xóa hẳn hồ sơ + tài khoản đăng nhập.
-- Đã có dấu vết (tên đứng trên chứng từ, lịch sử duyệt, nhật ký…) → không xóa dữ liệu để giữ truy vết: khóa đăng nhập vĩnh viễn,
-- bỏ mọi vai trò, phạm vi kho, ủy quyền đang hiệu lực, ẩn khỏi danh sách người dùng; tên vẫn hiện trên chứng từ cũ.
-- Cả hai cách: bỏ người đó khỏi các bước duyệt được giao đích danh, gỡ liên kết người đứng máy, xóa thông báo, đăng xuất.

alter table core.profiles add column if not exists deleted_at timestamptz;
alter table core.profiles add column if not exists deleted_by uuid;

create or replace function pg_temp.patch(p_name text, p_old text, p_new text) returns void language plpgsql as $$
declare v_oid oid; v_n int; v_def text;
begin
  select count(*), min(p.oid) into v_n, v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname || '.' || p.proname = p_name;
  if v_n <> 1 then raise exception 'Vá %: có % hàm cùng tên', p_name, v_n; end if;
  v_def := pg_get_functiondef(v_oid);
  if position(p_old in v_def) = 0 then raise exception 'Vá %: không thấy đoạn "%"', p_name, p_old; end if;
  execute replace(v_def, p_old, p_new);
end $$;

-- Dấu vết của một người trong dữ liệu nghiệp vụ: mọi cột uuid kiểu người làm (…_by, user_id, actor_id…)
create or replace function app._user_traces(p_user uuid) returns jsonb
 language plpgsql stable security definer set search_path to 'pg_catalog', 'public'
as $$
declare c record; n bigint; v jsonb := '{}';
begin
  for c in
    select ns.nspname sch, cl.relname tbl, a.attname col
      from pg_attribute a join pg_class cl on cl.oid = a.attrelid join pg_namespace ns on ns.oid = cl.relnamespace
     where cl.relkind in ('r', 'p') and not cl.relispartition and a.attnum > 0 and not a.attisdropped
       and a.atttypid = 'uuid'::regtype
       and ns.nspname in ('core', 'master', 'sales', 'plan', 'purchase', 'inv', 'mfg', 'qa', 'cost', 'wf', 'iot', 'integ')
       and (a.attname ~ '_by$' or a.attname in ('by_user', 'from_user', 'to_user', 'user_id', 'actor_id', 'inspector_id',
            'on_behalf_of', 'operator_id', 'owner_id', 'profile_id', 'receiver_id', 'witness_id'))
       -- Bảng tài khoản, nhật ký, thông báo, liên kết người đứng máy: không tính là dấu vết nghiệp vụ
       and (ns.nspname, cl.relname) not in (('core', 'profiles'), ('core', 'user_roles'), ('core', 'user_scopes'),
            ('core', 'audit_log'), ('wf', 'notifications'))
       and not (ns.nspname = 'master' and cl.relname = 'operators' and a.attname = 'profile_id')
     order by 1, 2, 3
  loop
    execute format('select count(*) from %I.%I where %I = $1', c.sch, c.tbl, c.col) using p_user into n;
    if n > 0 then v := v || jsonb_build_object(c.sch || '.' || c.tbl || '.' || c.col, n); end if;
  end loop;
  return v;
end $$;
revoke execute on function app._user_traces(uuid) from public, anon, authenticated;

create or replace function app.admin_user_delete(p_user uuid, p_reason text) returns jsonb
 language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare pr core.profiles; v_email text; v_roles text[]; v_wh text[]; v_traces jsonb; v_mode text; v_sess int;
begin
  if not core.is_admin() then raise exception 'Chỉ Quản trị hệ thống được xóa người dùng'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Ghi lý do xóa người dùng'; end if;
  if p_user = auth.uid() then raise exception 'Không tự xóa tài khoản của chính mình'; end if;
  select * into pr from core.profiles where id = p_user for update;
  if not found then raise exception 'Không tìm thấy người dùng'; end if;
  if pr.deleted_at is not null then raise exception 'Người dùng % đã bị xóa', pr.full_name; end if;
  select u.email::text into v_email from auth.users u where u.id = p_user;
  v_roles := array(select role_code from core.user_roles where user_id = p_user order by 1);
  v_wh := array(select w.code from core.user_scopes s join inv.warehouses w on w.id = s.scope_id
                 where s.user_id = p_user and s.scope_type = 'WAREHOUSE' order by 1);
  v_traces := app._user_traces(p_user);

  -- Chung: bỏ khỏi bước duyệt giao đích danh, người được gửi chứng từ; gỡ liên kết người đứng máy; xóa thông báo; đăng xuất
  update wf.approval_steps set assignee_ids = array_remove(assignee_ids, p_user) where p_user = any(assignee_ids);
  update wf.approval_flows set submit_user_ids = array_remove(submit_user_ids, p_user) where p_user = any(submit_user_ids);
  update master.operators set profile_id = null where profile_id = p_user;
  delete from wf.notifications where user_id = p_user;
  delete from auth.sessions where user_id = p_user;
  get diagnostics v_sess = row_count;

  if v_traces = '{}'::jsonb then
    delete from core.profiles where id = p_user;          -- vai trò, phạm vi kho xóa theo (cascade)
    delete from auth.users where id = p_user;             -- identities, phiên… xóa theo (cascade)
    v_mode := 'DELETED';
  else
    delete from core.user_roles where user_id = p_user;
    delete from core.user_scopes where user_id = p_user;
    update core.delegations set valid_to = now() where (from_user = p_user or to_user = p_user) and valid_to > now();
    update core.profiles set status = 'INACTIVE', deleted_at = now(), deleted_by = auth.uid() where id = p_user;
    if exists (select 1 from pg_attribute where attrelid = 'auth.users'::regclass and attname = 'banned_until' and not attisdropped) then
      execute 'update auth.users set banned_until = $2 where id = $1' using p_user, timestamptz '2999-12-31 00:00+00';
    end if;
    v_mode := 'HIDDEN';
  end if;

  perform app.admin_log('core.profiles', p_user::text, 'ADMIN_USER_DELETE',
    jsonb_build_object('profile', to_jsonb(pr), 'email', v_email, 'roles', v_roles, 'warehouses', v_wh),
    jsonb_build_object('doc_type', 'Xóa người dùng', 'doc_no', coalesce(v_email, pr.full_name), 'full_name', pr.full_name,
                       'reason', trim(p_reason), 'mode', v_mode, 'traces', v_traces, 'sessions_ended', v_sess));
  return jsonb_build_object('mode', v_mode, 'email', v_email, 'full_name', pr.full_name,
                            'traces', (select coalesce(sum(value::bigint), 0) from jsonb_each_text(v_traces)));
end $$;
revoke execute on function app.admin_user_delete(uuid, text) from public, anon;
grant execute on function app.admin_user_delete(uuid, text) to authenticated;

-- Người dùng đã xóa không sửa lại được (không hiện lại trong danh sách)
select pg_temp.patch('app.admin_upsert_user',
  $o$v_conflict := core.role_conflict_text(p_roles);$o$,
  $n$if exists (select 1 from core.profiles where id = p_user and deleted_at is not null) then
    raise exception 'Người dùng này đã bị xóa';
  end if;
  v_conflict := core.role_conflict_text(p_roles);$n$);

select pg_temp.patch('app.admin_overrides',
  $o$'ADMIN_PO', 'ADMIN_SPEC'$o$, $n$'ADMIN_PO', 'ADMIN_SPEC', 'ADMIN_USER_DELETE'$n$);

-- Danh sách người dùng thêm cột deleted_at (thêm cuối, giữ thứ tự cột cũ)
create or replace view app.v_users as
 select p.id, p.full_name, p.employee_code, p.department, p.title, p.status, u.email, u.last_sign_in_at,
    coalesce((select array_agg(ur.role_code order by ur.role_code) from core.user_roles ur where ur.user_id = p.id), '{}'::text[]) as roles,
    coalesce((select array_agg(w.code order by w.code) from core.user_scopes s join inv.warehouses w on w.id = s.scope_id
               where s.user_id = p.id and s.scope_type = 'WAREHOUSE'), '{}'::text[]) as warehouses,
    p.deleted_at
   from core.profiles p
   left join app.auth_users() u(id, email, last_sign_in_at) on u.id = p.id;
