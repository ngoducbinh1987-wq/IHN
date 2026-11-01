-- Kiểm thử migration 20261026008000: Quản trị hệ thống xóa người dùng.
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create temp table t (k text primary key, v uuid);
grant all on r, t to authenticated;
grant usage on sequence r_n_seq to authenticated;

create function pg_temp.as_user(p_code text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', (select id::text from core.profiles where employee_code = p_code), true),
         set_config('request.jwt.claim.role', 'authenticated', true)
$$;
create function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_msg; end if;
  insert into r(msg) values (p_msg);
end $$;
create function pg_temp.blocked(p_sql text, p_pattern text, p_msg text) returns void language plpgsql as $$
begin
  begin
    execute 'set local role authenticated';
    execute p_sql;
    execute 'reset role';
  exception when others then
    execute 'reset role';
    if sqlerrm ilike '%' || p_pattern || '%' then insert into r(msg) values (p_msg || ' → chặn: ' || sqlerrm); return; end if;
    raise exception 'FAIL: % — lỗi khác mong đợi: %', p_msg, sqlerrm;
  end;
  raise exception 'FAIL: % — lẽ ra phải bị chặn', p_msg;
end $$;
create function pg_temp.as_api(p_sql text) returns void language plpgsql as $$
begin
  execute 'set local role authenticated';
  execute p_sql;
  execute 'reset role';
end $$;
create function pg_temp.v(p_k text) returns uuid language sql as $$ select v from t where k = p_k $$;
grant execute on function pg_temp.v(text) to authenticated;
create function pg_temp.uid(p_code text) returns uuid language sql as $$ select id from core.profiles where employee_code = p_code $$;
grant execute on function pg_temp.uid(text) to authenticated;
set client_min_messages = notice;

update core.profiles set status = 'INACTIVE' where status = 'ACTIVE';
with u(code) as (values ('X_ADM'),('X_BGD'),('X_NEW'),('X_OLD'),('X_ADM2')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('X_ADM','ADMIN'),('X_BGD','BGD'),('X_NEW','MUA_NV'),('X_NEW','KHO_NV'),
  ('X_OLD','MUA_TP'),('X_ADM2','ADMIN')) u(code, role) on u.code = p.employee_code;
insert into core.user_scopes (user_id, scope_type, scope_id)
select pg_temp.uid('X_NEW'), 'WAREHOUSE', w.id from inv.warehouses w order by w.code limit 1;
insert into auth.sessions (id, user_id) values (gen_random_uuid(), pg_temp.uid('X_NEW')), (gen_random_uuid(), pg_temp.uid('X_OLD'));
-- X_OLD: đã duyệt một quy trình (có dấu vết), được giao đích danh ở một bước duyệt, liên kết người đứng máy, có ủy quyền
update wf.approval_steps set assignee_ids = assignee_ids || pg_temp.uid('X_OLD') where doc_type = 'PR' and seq = 1;
create temp table opc as select code from master.operators order by code limit 1;
grant select on opc to authenticated;
update master.operators set profile_id = pg_temp.uid('X_OLD') where code = (select code from opc);
insert into master.planning_param_log (user_id, section, item, reason) values (pg_temp.uid('X_OLD'), 'Thử', 'dấu vết', 'thử');
insert into core.delegations (from_user, to_user, role_code, valid_from, valid_to)
values (pg_temp.uid('X_OLD'), pg_temp.uid('X_BGD'), 'MUA_TP', now() - interval '1 day', now() + interval '7 days');
insert into wf.notifications (user_id, title) values (pg_temp.uid('X_NEW'), 'Thử'), (pg_temp.uid('X_OLD'), 'Thử');

-- ================================================================ Quyền
select pg_temp.as_user('X_BGD');
select pg_temp.blocked($q$select app.admin_user_delete(pg_temp.uid('X_NEW'), 'thử')$q$, 'Chỉ Quản trị', 'Giám đốc (không phải Quản trị) không xóa được người dùng');
select pg_temp.as_user('X_ADM');
select pg_temp.blocked($q$select app.admin_user_delete(pg_temp.uid('X_NEW'), ' ')$q$, 'lý do', 'Xóa người dùng bắt buộc ghi lý do');
select pg_temp.blocked($q$select app.admin_user_delete(pg_temp.uid('X_ADM'), 'thử')$q$, 'chính mình', 'Quản trị không tự xóa tài khoản của mình');
select pg_temp.blocked($q$select app.admin_user_delete(gen_random_uuid(), 'thử')$q$, 'Không tìm thấy', 'Người dùng không tồn tại');

-- ================================================================ Chưa có dấu vết → xóa hẳn
insert into t values ('new', pg_temp.uid('X_NEW'));
select pg_temp.as_api($q$select app.admin_user_delete(pg_temp.v('new'), 'Tạo nhầm tài khoản')$q$);
select pg_temp.ok(not exists (select 1 from core.profiles where id = pg_temp.v('new'))
  and not exists (select 1 from auth.users where id = pg_temp.v('new'))
  and not exists (select 1 from core.user_roles where user_id = pg_temp.v('new'))
  and not exists (select 1 from core.user_scopes where user_id = pg_temp.v('new'))
  and not exists (select 1 from auth.sessions where user_id = pg_temp.v('new'))
  and not exists (select 1 from wf.notifications where user_id = pg_temp.v('new')),
  'Người chưa có dấu vết nghiệp vụ: xóa hẳn hồ sơ, tài khoản đăng nhập, vai trò, kho, phiên, thông báo');

-- ================================================================ Có dấu vết → khóa vĩnh viễn, ẩn
insert into t values ('old', pg_temp.uid('X_OLD'));
select pg_temp.as_api($q$select app.admin_user_delete(pg_temp.v('old'), 'Nghỉ việc')$q$);
select pg_temp.ok((select status = 'INACTIVE' and deleted_at is not null and deleted_by = pg_temp.uid('X_ADM') from core.profiles where id = pg_temp.v('old'))
  and exists (select 1 from master.planning_param_log where user_id = pg_temp.v('old')),
  'Người đã có dấu vết: giữ hồ sơ (tên trên chứng từ cũ), đánh dấu đã xóa, ngưng hoạt động');
select pg_temp.ok(not exists (select 1 from core.user_roles where user_id = pg_temp.v('old'))
  and not exists (select 1 from auth.sessions where user_id = pg_temp.v('old'))
  and (select banned_until > now() + interval '100 years' from auth.users where id = pg_temp.v('old')),
  'Người đã xóa: bỏ hết vai trò, đăng xuất, khóa đăng nhập vĩnh viễn');
select pg_temp.ok(not exists (select 1 from wf.approval_steps where pg_temp.v('old') = any(assignee_ids))
  and (select profile_id is null from master.operators where code = (select code from opc))
  and not exists (select 1 from core.delegations where from_user = pg_temp.v('old') and valid_to > now()),
  'Bỏ khỏi bước duyệt giao đích danh, gỡ liên kết người đứng máy, kết thúc ủy quyền đang hiệu lực');
select pg_temp.ok((select deleted_at is not null from app.v_users where id = pg_temp.v('old')), 'Danh sách người dùng có cột đã xóa để ẩn');
select pg_temp.blocked($q$select app.admin_user_delete(pg_temp.v('old'), 'thử')$q$, 'đã bị xóa', 'Không xóa lại người đã xóa');
select pg_temp.blocked($q$select app.admin_upsert_user(pg_temp.v('old'), 'Hồi sinh', null, null, null, array['MUA_TP'], 'ACTIVE')$q$, 'đã bị xóa',
  'Không sửa / kích hoạt lại người đã xóa qua form người dùng');

-- Quản trị khác vẫn xóa được Quản trị (không phải chính mình)
select pg_temp.as_api($q$select app.admin_user_delete(pg_temp.uid('X_ADM2'), 'Bỏ tài khoản quản trị thừa')$q$);
select pg_temp.ok(not exists (select 1 from core.profiles where employee_code = 'X_ADM2'), 'Quản trị xóa được tài khoản Quản trị khác');

select pg_temp.ok((select count(*) = 3 from core.audit_log where action = 'ADMIN_USER_DELETE' and at >= now())
  and exists (select 1 from app.admin_overrides(50) where action = 'ADMIN_USER_DELETE' and doc_type = 'Xóa người dùng'),
  'Nhật ký can thiệp ghi 3 lần xóa người dùng (bản sao hồ sơ, vai trò, kho)');
select pg_temp.ok(not has_function_privilege('anon', 'app.admin_user_delete(uuid,text)', 'execute')
  and not has_function_privilege('authenticated', 'app._user_traces(uuid)', 'execute'), 'Khách (anon) không gọi được; hàm quét dấu vết là nội bộ');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
