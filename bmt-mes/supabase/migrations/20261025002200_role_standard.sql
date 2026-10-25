-- BMT MES · 2200 · Áp dụng "Quy chuẩn vai trò & nhiệm vụ nhân sự nhà máy BMT" (25/10/2026)
--  1. Vai trò: đổi tên "TP sản xuất" → "Quản lý sản xuất"; chặn gán vai trò xung đột; phạm vi kho theo người
--  2. Bộ máy duyệt: điều kiện theo giá trị/loại chứng từ (hạn mức PO); người duyệt duy nhất là người lập → chuyển Giám đốc;
--     quá hạn thì vai trò dự phòng được duyệt thay; kiểm tra đúng loại phiếu kho cho từng quy trình
--  3. Cấu hình quy trình theo quy chuẩn (Kế hoạch tháng: Giám đốc lập, Chủ tịch HĐQT phê duyệt); bỏ quy trình Spec thay đổi nhỏ
--  4. Vá: phát hành spec và phát lệnh SX chỉ qua quy trình duyệt
--  5. Kho: phiếu lĩnh tự tạo từ lệnh SX theo định mức; xuất vượt định mức bị chặn nếu chưa duyệt cấp bổ sung;
--     Kế toán SX đánh dấu "Đã kiểm" phiếu đã ghi sổ; cân bằng đồng theo lệnh SX
--  6. NV mua hàng được sinh PR từ MRP

-- ===========================================================================
-- 1. Vai trò, xung đột vai trò, phạm vi kho
-- ===========================================================================
update core.roles set name = 'Quản lý sản xuất' where code = 'SX_TP';

create table if not exists core.role_conflicts (
  role_a text not null references core.roles(code) on delete cascade,
  role_b text not null references core.roles(code) on delete cascade,
  reason text not null,
  primary key (role_a, role_b)
);
insert into core.role_conflicts (role_a, role_b, reason) values
  ('THU_KHO', 'KT_KHO', 'người giữ kho không tự ghi sổ, tự kiểm phiếu kho'),
  ('THU_KHO', 'MUA_NV', 'người mua hàng không tự nhận hàng vào kho'),
  ('KTT',     'KT_KHO', 'người duyệt kiểm kê không tự lập sổ kho')
on conflict do nothing;
alter table core.role_conflicts enable row level security;
drop policy if exists p_select on core.role_conflicts;
create policy p_select on core.role_conflicts for select to authenticated using (true);
grant select on core.role_conflicts to authenticated;
grant all on core.role_conflicts to service_role;

-- Tài khoản giữ vai trò Quản trị hệ thống được miễn (giai đoạn chạy thử)
create or replace function core.role_conflict_text(p_roles text[]) returns text
language sql stable security definer set search_path = pg_catalog, public as $$
  select case when 'ADMIN' = any(p_roles) then null else
    string_agg(ra.name || ' + ' || rb.name || ' (' || c.reason || ')', '; ') end
  from core.role_conflicts c join core.roles ra on ra.code = c.role_a join core.roles rb on rb.code = c.role_b
  where c.role_a = any(p_roles) and c.role_b = any(p_roles)
$$;

create or replace function app.admin_upsert_user(p_user uuid, p_full_name text, p_employee_code text,
                                                 p_department text, p_title text, p_roles text[], p_status text default 'ACTIVE')
returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_conflict text;
begin
  if not core.has_perm('admin', 'edit') then raise exception 'Không có quyền quản trị người dùng'; end if;
  if p_user = auth.uid() and not ('ADMIN' = any(p_roles)) then
    raise exception 'Không tự gỡ vai trò ADMIN của chính mình';
  end if;
  v_conflict := core.role_conflict_text(p_roles);
  if v_conflict is not null then raise exception 'Không gán chung cho một người: %', v_conflict; end if;
  insert into core.profiles (id, full_name, employee_code, department, title, status)
  values (p_user, p_full_name, nullif(trim(p_employee_code), ''), nullif(p_department, ''), p_title, p_status)
  on conflict (id) do update set full_name = excluded.full_name, employee_code = excluded.employee_code,
    department = excluded.department, title = excluded.title, status = excluded.status;
  delete from core.user_roles where user_id = p_user and role_code <> all(p_roles);
  insert into core.user_roles (user_id, role_code) select p_user, unnest(p_roles) on conflict do nothing;
end $$;

-- Kho được giao (rỗng = toàn bộ kho)
create or replace function app.admin_set_warehouses(p_user uuid, p_codes text[]) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if not core.has_perm('admin', 'edit') then raise exception 'Không có quyền quản trị người dùng'; end if;
  if exists (select 1 from unnest(coalesce(p_codes, '{}')) c where not exists (select 1 from inv.warehouses w where w.code = c)) then
    raise exception 'Mã kho không hợp lệ';
  end if;
  delete from core.user_scopes where user_id = p_user and scope_type = 'WAREHOUSE';
  insert into core.user_scopes (user_id, scope_type, scope_id)
  select p_user, 'WAREHOUSE', w.id from inv.warehouses w where w.code = any(coalesce(p_codes, '{}'));
end $$;

create or replace function core.can_use_warehouse(p_wh uuid) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select not exists (select 1 from core.user_scopes where user_id = auth.uid() and scope_type = 'WAREHOUSE')
      or exists (select 1 from core.user_scopes where user_id = auth.uid() and scope_type = 'WAREHOUSE' and scope_id = p_wh)
$$;

create or replace view app.v_users with (security_invoker = true) as
select p.id, p.full_name, p.employee_code, p.department, p.title, p.status, u.email, u.last_sign_in_at,
       coalesce((select array_agg(ur.role_code order by ur.role_code) from core.user_roles ur where ur.user_id = p.id), '{}') as roles,
       coalesce((select array_agg(w.code order by w.code) from core.user_scopes s join inv.warehouses w on w.id = s.scope_id
                 where s.user_id = p.id and s.scope_type = 'WAREHOUSE'), '{}') as warehouses
from core.profiles p left join app.auth_users() u on u.id = p.id;

create or replace view app.v_warehouses with (security_invoker = true) as
select code, name, kind from inv.warehouses;
create or replace view app.v_role_conflicts with (security_invoker = true) as
select role_a, role_b, reason from core.role_conflicts;

-- ===========================================================================
-- 2. Bộ máy duyệt
-- ===========================================================================
alter table wf.approval_flows add column if not exists active boolean not null default true;
alter table wf.approval_steps
  add column if not exists min_amount numeric(18,2) check (min_amount is null or min_amount >= 0),  -- áp dụng khi giá trị ≥
  add column if not exists when_flags text[] not null default '{}',                                  -- hoặc khi chứng từ có đặc điểm
  add column if not exists fallback_role text references core.roles(code);                         -- quá hạn: vai trò được duyệt thay

-- Đặc điểm của PO dùng cho điều kiện bước duyệt
alter table purchase.purchase_orders
  add column if not exists is_import boolean not null default false,
  add column if not exists is_equipment boolean not null default false;

-- Giá trị + đặc điểm của chứng từ lúc gửi duyệt
create or replace function wf.doc_facts(p_doc_type text, p_doc_id uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_amount numeric; v_flags text[] := '{}'; po purchase.purchase_orders;
begin
  if p_doc_type = 'PO' then
    select * into po from purchase.purchase_orders where id = p_doc_id;
    if not found then raise exception 'Không tìm thấy PO'; end if;
    if not exists (select 1 from purchase.po_lines where po_id = p_doc_id) then raise exception 'PO % chưa có dòng hàng', po.po_no; end if;
    if exists (select 1 from purchase.po_lines where po_id = p_doc_id and unit_price is null) then
      raise exception 'PO % còn dòng chưa có đơn giá: không xác định được hạn mức duyệt', po.po_no;
    end if;
    select round(sum(qty * unit_price), 2) into v_amount from purchase.po_lines where po_id = p_doc_id;
    if po.is_import then v_flags := v_flags || 'IMPORT'::text; end if;
    if po.is_equipment then v_flags := v_flags || 'EQUIPMENT'::text; end if;
    if not exists (select 1 from purchase.purchase_orders x where x.supplier_id = po.supplier_id and x.id <> po.id
                   and x.status in ('APPROVED','SENT','PARTIAL_RECEIVED','RECEIVED','CLOSED')) then
      v_flags := v_flags || 'NEW_SUPPLIER'::text;
    end if;
  end if;
  return jsonb_build_object('amount', v_amount, 'flags', to_jsonb(v_flags));
end $$;

-- Đặc điểm có thể dùng làm điều kiện, theo loại chứng từ
create or replace view app.v_flow_flags with (security_invoker = true) as
select * from (values ('PO', 'NEW_SUPPLIER', 'Nhà cung cấp mới'), ('PO', 'IMPORT', 'Nhập khẩu'), ('PO', 'EQUIPMENT', 'Mua thiết bị')) v(doc_type, flag, name);

create or replace function wf.flow_config(p_doc_type text) returns jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
  select jsonb_build_object(
    'submit', jsonb_build_object('label', f.submit_label, 'role', f.submit_role, 'users', to_jsonb(f.submit_user_ids)),
    'steps', coalesce((select jsonb_agg(jsonb_build_object('seq', s.seq, 'label', s.level_label, 'role', s.role_code,
                                                           'users', to_jsonb(s.assignee_ids), 'sla_hours', s.sla_hours,
                                                           'warn_hours', s.warn_hours, 'min_amount', s.min_amount,
                                                           'flags', to_jsonb(s.when_flags), 'fallback', s.fallback_role) order by s.seq)
                       from wf.approval_steps s where s.doc_type = f.doc_type and s.enabled), '[]'))
  from wf.approval_flows f where f.doc_type = p_doc_type
$$;

-- Bước có điều kiện: áp dụng khi giá trị ≥ ngưỡng HOẶC chứng từ có một trong các đặc điểm. Không đặt điều kiện = luôn áp dụng.
create or replace function wf.step_applies(p_step jsonb, p_facts jsonb) returns boolean
language sql immutable as $$
  select case
    when (p_step ->> 'min_amount') is null and jsonb_array_length(coalesce(p_step -> 'flags', '[]')) = 0 then true
    else coalesce((p_facts ->> 'amount')::numeric >= (p_step ->> 'min_amount')::numeric, false)
      or exists (select 1 from jsonb_array_elements_text(coalesce(p_step -> 'flags', '[]')) f
                 where coalesce(p_facts -> 'flags', '[]') ? f)
  end
$$;

-- Cấu hình đóng băng vào hồ sơ: lọc bước theo điều kiện; bước mà người duyệt duy nhất là người lập
-- → bỏ qua nếu Giám đốc đã duyệt ở bước khác, nếu không thì chuyển lên Giám đốc
create or replace function wf.build_snapshot(p_doc_type text, p_doc_id uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_cfg jsonb; v_facts jsonb; v_steps jsonb; s jsonb; v_out jsonb := '[]'; v_me uuid := auth.uid();
begin
  v_cfg := wf.flow_config(p_doc_type);
  v_facts := wf.doc_facts(p_doc_type, p_doc_id);
  select coalesce(jsonb_agg(x order by (x ->> 'seq')::int), '[]') into v_steps
    from jsonb_array_elements(v_cfg -> 'steps') x where wf.step_applies(x, v_facts);
  for s in select x from jsonb_array_elements(v_steps) x order by (x ->> 'seq')::int loop
    if cardinality(wf.step_actor_ids(s)) = 0 then
      raise exception 'Bước "%" chưa có người thực hiện: gán vai trò % cho người phụ trách (Quản trị → Người dùng & quyền)',
        s ->> 'label', coalesce((select name from core.roles where code = s ->> 'role'), s ->> 'role');
    end if;
    if cardinality(array_remove(wf.step_actor_ids(s), v_me)) = 0 then
      if exists (select 1 from jsonb_array_elements(v_steps) o
                 where (o ->> 'seq') <> (s ->> 'seq') and o ->> 'role' = 'BGD'
                   and cardinality(array_remove(wf.step_actor_ids(o), v_me)) > 0) then
        continue;
      end if;
      s := s || jsonb_build_object('role', 'BGD', 'users', '[]'::jsonb, 'escalated_from', s ->> 'role',
                                   'label', (s ->> 'label') || ' · chuyển Giám đốc');
      if cardinality(array_remove(wf.step_actor_ids(s), v_me)) = 0 then
        raise exception 'Bước "%" không có người duyệt nào khác người lập', s ->> 'label';
      end if;
    end if;
    v_out := v_out || jsonb_build_array(s);
  end loop;
  return jsonb_set(v_cfg, '{steps}', v_out) || jsonb_build_object('facts', v_facts);
end $$;

-- Được xử lý bước không: người được giao / ủy quyền; quá hạn thì thêm vai trò dự phòng (duyệt thay)
create or replace function wf.can_act_step(p_step jsonb, p_started timestamptz, out ok boolean, out on_behalf uuid, out fallback boolean)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  select c.ok, c.on_behalf into ok, on_behalf from wf.can_act_step(p_step) c;
  fallback := false;
  if not ok and (p_step ->> 'fallback') is not null and p_started is not null
     and now() >= p_started + make_interval(hours => coalesce((p_step ->> 'sla_hours')::int, 24)) then
    ok := auth.uid() = any(wf.step_actor_ids(jsonb_build_object('role', p_step ->> 'fallback')));
    fallback := ok;
  end if;
end $$;

-- Mỗi quy trình phiếu kho chỉ nhận đúng loại phiếu
create or replace function wf.check_doc(p_doc_type text, p_doc_id uuid) returns void
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare d inv.stock_docs;
begin
  if p_doc_type in ('EXTRA_ISSUE', 'STOCK_ADJ', 'SCRAP_OUT') then
    select * into d from inv.stock_docs where id = p_doc_id;
    if not found then raise exception 'Không tìm thấy phiếu kho'; end if;
    if d.doc_type <> (case p_doc_type when 'EXTRA_ISSUE' then 'ISSUE_WO' when 'STOCK_ADJ' then 'ADJ' else 'SCRAP_OUT' end) then
      raise exception 'Phiếu % (loại %) không thuộc quy trình này', d.doc_no, d.doc_type;
    end if;
    if p_doc_type = 'EXTRA_ISSUE' and (d.ref_type is distinct from 'WO' or d.ref_id is null) then
      raise exception 'Phiếu cấp bổ sung phải gắn lệnh sản xuất';
    end if;
    if d.status <> 'DRAFT' then raise exception 'Phiếu % đang ở trạng thái %', d.doc_no, d.status; end if;
  end if;
end $$;

create or replace function wf.submit(p_doc_type text, p_doc_id uuid, p_doc_no text, p_summary text default null) returns uuid
language plpgsql security definer set search_path = wf, core, public as $$
declare f wf.approval_flows; v_req uuid; v_snap jsonb; v_first jsonb; v_issues text[]; v_stale boolean;
begin
  select * into f from wf.approval_flows where doc_type = p_doc_type;
  if not found then raise exception 'Chưa cấu hình luồng duyệt cho %', p_doc_type; end if;
  if not f.active then raise exception 'Quy trình "%" đã ngưng sử dụng', f.name; end if;
  if cardinality(f.submit_user_ids) > 0 and not auth.uid() = any(f.submit_user_ids) then
    raise exception 'Bạn không được giao bước "%" của quy trình này', f.submit_label;
  end if;
  if f.submit_role is not null and not core.has_role(f.submit_role) then
    raise exception 'Bước "%" cần vai trò %', f.submit_label, coalesce((select name from core.roles where code = f.submit_role), f.submit_role);
  end if;
  if p_doc_type like 'SPEC%' then
    v_issues := master.check_spec(p_doc_id);
    if array_length(v_issues, 1) > 0 then
      raise exception 'Spec chưa đạt kiểm tra: %', array_to_string(v_issues, '; ');
    end if;
  elsif p_doc_type = 'PLAN' then
    select mrp_stale into v_stale from plan.production_plans where id = p_doc_id;
    if v_stale then raise exception 'Dòng kế hoạch đã thay đổi sau lần chạy MRP: chạy lại MRP rồi gửi duyệt'; end if;
  end if;
  perform wf.check_doc(p_doc_type, p_doc_id);
  v_snap := wf.build_snapshot(p_doc_type, p_doc_id);
  v_first := v_snap -> 'steps' -> 0;
  if v_first is null then raise exception 'Luồng % không có bước nào áp dụng', p_doc_type; end if;
  if cardinality(array_remove(wf.step_actor_ids(v_first), auth.uid())) = 0 then
    raise exception 'Bước "%" chưa có người thực hiện: cấu hình tại Quản trị → Cài đặt quy trình', v_first ->> 'label';
  end if;
  insert into wf.approval_requests (doc_type, doc_id, doc_no, summary, current_seq, data_hash, flow_snapshot)
  values (p_doc_type, p_doc_id, p_doc_no, p_summary, (v_first ->> 'seq')::smallint, wf.doc_hash(f.doc_table, p_doc_id), v_snap)
  returning id into v_req;
  execute format('update %s set %I = $1 where id = $2', f.doc_table, f.status_col) using f.pending_status, p_doc_id;
  perform wf.notify_users(array_remove(wf.step_actor_ids(v_first), auth.uid()), 'Chờ duyệt: ' || p_doc_no, p_summary, '/duyet/' || v_req);
  return v_req;
end $$;

create or replace function wf.act(p_request uuid, p_action text, p_comment text default null) returns text
language plpgsql security definer set search_path = wf, core, public as $$
declare r wf.approval_requests; f wf.approval_flows; v_step jsonb; v_next jsonb; v_hash text;
        v_ok boolean; v_behalf uuid; v_fallback boolean; v_comment text := p_comment;
begin
  select * into r from wf.approval_requests where id = p_request for update;
  if r.status <> 'PENDING' then raise exception 'Yêu cầu đã kết thúc (%)', r.status; end if;
  select * into f from wf.approval_flows where doc_type = r.doc_type;
  v_step := wf.snap_step(r, r.current_seq);

  select c.ok, c.on_behalf, c.fallback into v_ok, v_behalf, v_fallback from wf.can_act_step(v_step, r.step_started_at) c;
  if not v_ok then
    raise exception 'Bước "%" cần vai trò % – người được giao: %', v_step ->> 'label',
      coalesce((select name from core.roles where code = v_step ->> 'role'), v_step ->> 'role'),
      coalesce((select string_agg(full_name, ', ') from core.profiles where id = any(wf.step_actor_ids(v_step))), 'chưa có');
  end if;
  if auth.uid() = r.submitted_by then raise exception 'Người lập không tự duyệt chứng từ của mình'; end if;
  if p_action = 'REJECT' and coalesce(trim(p_comment), '') = '' then
    raise exception 'Nhập lý do trả lại để người lập biết cần sửa gì';
  end if;
  if v_fallback then v_comment := '[Duyệt thay do quá hạn] ' || coalesce(p_comment, ''); end if;
  v_hash := wf.doc_hash(f.doc_table, r.doc_id);
  if v_hash <> r.data_hash then raise exception 'Chứng từ đã bị sửa sau khi gửi duyệt: gửi duyệt lại'; end if;

  insert into wf.approval_actions (request_id, seq, on_behalf_of, action, comment, data_hash)
  values (p_request, r.current_seq, v_behalf, p_action, nullif(trim(v_comment), ''), v_hash);

  if p_action = 'COMMENT' then return 'PENDING'; end if;

  if p_action = 'REJECT' then
    update wf.approval_requests set status = 'REJECTED', finished_at = now() where id = p_request;
    execute format('update %s set %I = $1 where id = $2', f.doc_table, f.status_col) using f.rejected_status, r.doc_id;
    insert into wf.notifications (user_id, title, body, link) values (r.submitted_by, 'Bị trả lại: ' || r.doc_no, p_comment, '/duyet/' || p_request);
    return 'REJECTED';
  end if;

  select s into v_next from jsonb_array_elements(r.flow_snapshot -> 'steps') s
   where (s ->> 'seq')::int > r.current_seq order by (s ->> 'seq')::int limit 1;
  if v_next is not null then
    update wf.approval_requests set current_seq = (v_next ->> 'seq')::smallint where id = p_request;
    perform wf.notify_users(array_remove(wf.step_actor_ids(v_next), r.submitted_by), 'Chờ duyệt: ' || r.doc_no, r.summary, '/duyet/' || p_request);
    return 'PENDING';
  end if;

  update wf.approval_requests set status = 'APPROVED', finished_at = now() where id = p_request;
  perform set_config('bmt.wf_release', 'on', true);
  if r.doc_type like 'SPEC%' then
    perform master.release_spec(r.doc_id);
  elsif r.doc_type = 'WO_RELEASE' then
    perform mfg.release_wo(r.doc_id);
  else
    execute format('update %s set %I = $1 where id = $2', f.doc_table, f.status_col) using f.approved_status, r.doc_id;
  end if;
  perform set_config('bmt.wf_release', 'off', true);
  insert into wf.notifications (user_id, title, link) values (r.submitted_by, 'Đã duyệt: ' || r.doc_no, '/duyet/' || p_request);
  return 'APPROVED';
end $$;

-- Quá hạn: báo người phụ trách và người được duyệt thay
create or replace function wf.check_sla() returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r record; v_kind text; v_n int := 0; v_due timestamptz; v_users uuid[]; v_backup uuid[];
begin
  for r in select q.*, wf.snap_step(q, q.current_seq) as st from wf.approval_requests q where q.status = 'PENDING' loop
    v_due := r.step_started_at + make_interval(hours => coalesce((r.st ->> 'sla_hours')::int, 24));
    v_kind := case when now() >= v_due then 'OVERDUE'
                   when coalesce((r.st ->> 'warn_hours')::int, 0) > 0
                        and now() >= v_due - make_interval(hours => (r.st ->> 'warn_hours')::int) then 'WARN' end;
    continue when v_kind is null;
    insert into wf.sla_alerts (request_id, seq, step_started_at, kind) values (r.id, r.current_seq, r.step_started_at, v_kind)
    on conflict do nothing;
    continue when not found;
    v_users := array_remove(wf.step_actor_ids(r.st), r.submitted_by);
    perform wf.notify_users(v_users,
      case v_kind when 'OVERDUE' then 'Quá hạn duyệt: ' else 'Sắp đến hạn duyệt: ' end || r.doc_no,
      format('Bước "%s" hạn %s. %s', r.st ->> 'label', to_char(v_due at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM/YYYY'), coalesce(r.summary, '')),
      '/duyet/' || r.id, r.id, r.current_seq);
    v_n := v_n + cardinality(v_users);
    if v_kind = 'OVERDUE' and (r.st ->> 'fallback') is not null then
      select coalesce(array_agg(u), '{}') into v_backup
        from unnest(wf.step_actor_ids(jsonb_build_object('role', r.st ->> 'fallback'))) u
       where u <> r.submitted_by and u <> all(v_users);
      perform wf.notify_users(v_backup, 'Có thể duyệt thay: ' || r.doc_no,
        format('Bước "%s" đã quá hạn từ %s. Bạn được duyệt thay theo quy chuẩn.', r.st ->> 'label',
               to_char(v_due at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM/YYYY')),
        '/duyet/' || r.id, r.id, r.current_seq);
      v_n := v_n + cardinality(v_backup);
    end if;
  end loop;
  return v_n;
end $$;
revoke execute on function wf.check_sla() from authenticated, anon, public;
grant execute on function wf.check_sla() to service_role;

-- Điều kiện + duyệt thay của một bước (chỉ quản trị)
create or replace function app.save_flow_step_rule(p_doc_type text, p_seq smallint, p_min_amount numeric, p_flags text[], p_fallback text)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if not core.has_perm('admin', 'edit') then raise exception 'Chỉ quản trị hệ thống được cài đặt quy trình'; end if;
  if p_min_amount is not null and p_min_amount < 0 then raise exception 'Giá trị áp dụng phải ≥ 0'; end if;
  if (p_min_amount is not null or cardinality(coalesce(p_flags, '{}')) > 0) and p_doc_type <> 'PO' then
    raise exception 'Điều kiện theo giá trị chỉ dùng cho quy trình PO';
  end if;
  if exists (select 1 from unnest(coalesce(p_flags, '{}')) x where x not in (select flag from app.v_flow_flags where doc_type = p_doc_type)) then
    raise exception 'Đặc điểm chứng từ không hợp lệ';
  end if;
  if p_fallback is not null and not exists (select 1 from core.roles where code = p_fallback) then
    raise exception 'Vai trò duyệt thay không hợp lệ';
  end if;
  update wf.approval_steps set min_amount = p_min_amount, when_flags = coalesce(p_flags, '{}'), fallback_role = p_fallback
   where doc_type = p_doc_type and seq = p_seq;
  if not found then raise exception 'Không có bước % của %', p_seq, p_doc_type; end if;
end $$;

drop view if exists app.v_approvals;
create view app.v_approvals with (security_invoker = true) as
with base as (
  select r.*, f.name as doc_type_name, cs as cur_step,
         (cs ->> 'label') as current_level, (cs ->> 'role') as current_role, ro.name as current_role_name,
         coalesce((cs ->> 'sla_hours')::int, 24) as sla_hours,
         jsonb_array_length(r.flow_snapshot -> 'steps') as step_total,
         (select count(*) from jsonb_array_elements(r.flow_snapshot -> 'steps') s where (s ->> 'seq')::int <= r.current_seq) as step_index
  from wf.approval_requests r
  join wf.approval_flows f on f.doc_type = r.doc_type
  left join lateral (select wf.snap_step(r, r.current_seq) as cs) c on true
  left join core.roles ro on ro.code = c.cs ->> 'role'
)
select b.id, b.doc_type, b.doc_type_name, b.doc_id, b.doc_no, b.summary, b.status, b.current_seq,
       b.current_level, b.current_role, b.current_role_name,
       case when b.status = 'PENDING' then app.people(array_remove(wf.step_actor_ids(b.cur_step), b.submitted_by)) else '[]'::jsonb end as current_approvers,
       b.submitted_by, app.user_name(b.submitted_by) as submitted_by_name, b.submitted_at, b.finished_at,
       b.step_started_at, b.step_started_at + make_interval(hours => b.sla_hours) as step_due_at,
       (b.status = 'PENDING' and now() > b.step_started_at + make_interval(hours => b.sla_hours)) as overdue,
       b.step_index, b.step_total,
       (b.status = 'PENDING' and b.submitted_by <> auth.uid() and (wf.can_act_step(b.cur_step, b.step_started_at)).ok) as my_turn,
       (b.submitted_by = auth.uid()) as i_submitted,
       exists (select 1 from wf.approval_actions a where a.request_id = b.id and a.actor_id = auth.uid()) as i_acted,
       case b.doc_type
         when 'SPEC_NEW' then '/san-pham/' || (select p.code from master.product_specs s join master.products p on p.id = s.product_id where s.id = b.doc_id) || '?v=' || b.doc_id
         when 'SPEC_MINOR' then '/san-pham/' || (select p.code from master.product_specs s join master.products p on p.id = s.product_id where s.id = b.doc_id) || '?v=' || b.doc_id
         when 'PLAN' then '/ke-hoach/' || b.doc_id
         when 'PR' then '/de-xuat/' || b.doc_id
       end as doc_link,
       (select jsonb_agg(x order by (x->>'seq')::int) from (
          select jsonb_build_object('seq', 0, 'label', coalesce(b.flow_snapshot #>> '{submit,label}', 'Lập phiếu'), 'role_name', null,
                                    'state', 'done', 'actor', app.user_name(b.submitted_by), 'at', b.submitted_at) as x
          union all
          select jsonb_build_object(
                   'seq', (s ->> 'seq')::int, 'label', s ->> 'label', 'role', s ->> 'role', 'role_name', ro.name,
                   'sla_hours', (s ->> 'sla_hours')::int,
                   'state', case
                              when b.status = 'REJECTED' and (s ->> 'seq')::int = b.current_seq then 'rejected'
                              when b.status = 'APPROVED' or (s ->> 'seq')::int < b.current_seq then 'done'
                              when b.status = 'PENDING' and (s ->> 'seq')::int = b.current_seq then 'current'
                              else 'todo' end,
                   'actor', (select app.user_name(a.actor_id) from wf.approval_actions a
                              where a.request_id = b.id and a.seq = (s ->> 'seq')::int and a.action in ('APPROVE','REJECT') order by a.acted_at desc limit 1),
                   'at', (select a.acted_at from wf.approval_actions a
                           where a.request_id = b.id and a.seq = (s ->> 'seq')::int and a.action in ('APPROVE','REJECT') order by a.acted_at desc limit 1),
                   'approvers', case when b.status = 'PENDING' and (s ->> 'seq')::int >= b.current_seq
                                     then app.people(array_remove(wf.step_actor_ids(s), b.submitted_by)) end)
          from jsonb_array_elements(b.flow_snapshot -> 'steps') s left join core.roles ro on ro.code = s ->> 'role') q) as steps,
       (select jsonb_agg(jsonb_build_object('seq', a.seq, 'action', a.action, 'comment', a.comment, 'at', a.acted_at,
                                            'actor', app.user_name(a.actor_id),
                                            'label', (select s ->> 'label' from jsonb_array_elements(b.flow_snapshot -> 'steps') s where (s ->> 'seq')::int = a.seq))
                         order by a.acted_at)
          from wf.approval_actions a where a.request_id = b.id) as history,
       (b.flow_snapshot #>> '{facts,amount}')::numeric as doc_amount
from base b;

drop view if exists app.v_flow_config;
create view app.v_flow_config with (security_invoker = true) as
select f.doc_type, f.name, f.submit_label, f.submit_role, f.submit_user_ids,
       coalesce((select jsonb_agg(jsonb_build_object('seq', s.seq, 'label', s.level_label, 'role', s.role_code, 'users', s.assignee_ids,
                                                      'sla_hours', s.sla_hours, 'warn_hours', s.warn_hours, 'enabled', s.enabled,
                                                      'min_amount', s.min_amount, 'flags', s.when_flags, 'fallback', s.fallback_role) order by s.seq)
                 from wf.approval_steps s where s.doc_type = f.doc_type), '[]') as steps,
       (select count(*) from wf.approval_requests r where r.doc_type = f.doc_type and r.status = 'PENDING') as running
from wf.approval_flows f where f.active;

-- ===========================================================================
-- 3. Cấu hình quy trình theo quy chuẩn
-- ===========================================================================
-- Chủ tịch HĐQT: bước BGĐ giao riêng cho tài khoản Ngô Đức Bình (không có tài khoản này thì để mọi BGĐ)
create temporary table _chairman as
select coalesce(array_agg(id), '{}') as ids from core.profiles where full_name = 'Ngô Đức Bình' and status = 'ACTIVE';

-- Kế hoạch SX tháng: Giám đốc lập → Quản lý SX xác nhận năng lực → Chủ tịch HĐQT phê duyệt
update wf.approval_flows set submit_role = 'BGD', submit_user_ids = '{}', submit_label = 'Giám đốc lập kế hoạch' where doc_type = 'PLAN';
update wf.approval_steps set level_label = 'Quản lý SX xác nhận năng lực', role_code = 'SX_TP', assignee_ids = '{}', enabled = true
 where doc_type = 'PLAN' and seq = 1;
update wf.approval_steps set level_label = 'Chủ tịch HĐQT phê duyệt', role_code = 'BGD', assignee_ids = (select ids from _chairman), enabled = true
 where doc_type = 'PLAN' and seq = 2;

-- Yêu cầu mua (PR): Giám đốc duyệt nhu cầu
update wf.approval_steps set level_label = 'Giám đốc duyệt nhu cầu mua', role_code = 'BGD', assignee_ids = '{}'
 where doc_type = 'PR' and seq = 1;

-- Đề xuất mua tối ưu: TP mua hàng chọn NCC, giá → Giám đốc
update wf.approval_steps set level_label = 'TP mua hàng duyệt NCC, giá', role_code = 'MUA_TP', assignee_ids = '{}', fallback_role = 'BGD'
 where doc_type = 'PROPOSAL' and seq = 1;
update wf.approval_steps set level_label = 'Giám đốc phê duyệt', assignee_ids = '{}' where doc_type = 'PROPOSAL' and seq = 2;

-- PO theo hạn mức: dưới 20 tr GĐ ký; từ 20 tr / NCC mới / nhập khẩu / thiết bị thêm TP mua hàng;
-- trên 200 tr / nhập khẩu / thiết bị thêm Chủ tịch HĐQT
update wf.approval_steps set level_label = 'TP mua hàng duyệt', role_code = 'MUA_TP', min_amount = 20000000,
       when_flags = array['NEW_SUPPLIER','IMPORT','EQUIPMENT'], fallback_role = 'BGD'
 where doc_type = 'PO' and seq = 1;
update wf.approval_steps set level_label = 'Giám đốc ký', role_code = 'BGD', assignee_ids = '{}', min_amount = null, when_flags = '{}'
 where doc_type = 'PO' and seq = 2;
insert into wf.approval_steps (doc_type, seq, level_label, role_code, enabled, sla_hours, warn_hours, assignee_ids, min_amount, when_flags)
select 'PO', 3, 'Chủ tịch HĐQT phê duyệt', 'BGD', true, 24, 0, (select ids from _chairman), 200000001, array['IMPORT','EQUIPMENT']
where not exists (select 1 from wf.approval_steps where doc_type = 'PO' and seq = 3);

-- Cấp NVL vượt định mức: TP Kỹ thuật/QA (Quản lý SX là người xin cấp)
update wf.approval_steps set level_label = 'TP Kỹ thuật/QA duyệt cấp vượt định mức', role_code = 'KT_TP', assignee_ids = '{}'
 where doc_type = 'EXTRA_ISSUE' and seq = 1;

-- Điều chỉnh kiểm kê: Kế toán SX kiểm tra → Kế toán trưởng duyệt
update wf.approval_steps set level_label = 'Kế toán SX kiểm tra' where doc_type = 'STOCK_ADJ' and seq = 1;
update wf.approval_steps set level_label = 'Kế toán trưởng duyệt', role_code = 'KTT', assignee_ids = '{}', fallback_role = 'BGD'
 where doc_type = 'STOCK_ADJ' and seq = 2;

-- Chốt giá thành: Kế toán trưởng (tắt bước BGĐ)
update wf.approval_steps set level_label = 'Kế toán trưởng chốt', fallback_role = 'BGD' where doc_type = 'COST_CLOSE' and seq = 1;
update wf.approval_steps set enabled = false where doc_type = 'COST_CLOSE' and seq = 2;

-- Spec mã mới: TP KT/QA lập → Quản lý SX xác nhận sản xuất được → Giám đốc phát hành
update wf.approval_flows set submit_role = 'KT_TP', submit_label = 'TP Kỹ thuật/QA lập spec', name = 'Spec + BOM (mã mới, phiên bản mới)'
 where doc_type = 'SPEC_NEW';
update wf.approval_steps set level_label = 'Quản lý SX xác nhận sản xuất được', role_code = 'SX_TP', assignee_ids = '{}', enabled = true
 where doc_type = 'SPEC_NEW' and seq = 1;
update wf.approval_steps set enabled = false where doc_type = 'SPEC_NEW' and seq = 2;
update wf.approval_steps set level_label = 'Giám đốc phát hành', role_code = 'BGD', assignee_ids = '{}', enabled = true
 where doc_type = 'SPEC_NEW' and seq = 3;

-- Bỏ quy trình Spec thay đổi nhỏ: mọi thay đổi spec đi qua quy trình đầy đủ
update wf.approval_flows set active = false where doc_type = 'SPEC_MINOR';
update wf.approval_requests set status = 'CANCELLED', finished_at = now() where doc_type = 'SPEC_MINOR' and status = 'PENDING';
update master.product_specs s set status = 'DRAFT'
 where status = 'PENDING_APPROVAL'
   and exists (select 1 from wf.approval_requests r where r.doc_id = s.id and r.doc_type = 'SPEC_MINOR' and r.status = 'CANCELLED')
   and not exists (select 1 from wf.approval_requests r where r.doc_id = s.id and r.status = 'PENDING');
update master.product_specs set change_level = 'MAJOR' where change_level = 'MINOR' and status <> 'RELEASED' and status <> 'OBSOLETE';

drop table _chairman;

-- ===========================================================================
-- 4. Spec chỉ phát hành qua quy trình; phiên bản mới luôn là thay đổi đầy đủ; lệnh SX chỉ phát qua quy trình
-- ===========================================================================
create or replace function master.new_spec_version(p_from uuid, p_change_level text) returns uuid
language plpgsql security definer set search_path = master, public as $$
declare v_new uuid; v_ver int; s master.product_specs;
begin
  if not core.has_perm('spec', 'create') then raise exception 'Không có quyền tạo spec'; end if;
  select * into s from master.product_specs where id = p_from;
  if not found then raise exception 'Không tìm thấy spec'; end if;
  if exists (select 1 from master.product_specs x where x.product_id = s.product_id
             and x.status in ('DRAFT', 'PILOT_PENDING', 'PILOT', 'PENDING_APPROVAL')) then
    raise exception 'Mã này đang có phiên bản nháp hoặc đang duyệt: hoàn tất bản đó trước';
  end if;
  select coalesce(max(version), 0) + 1 into v_ver from master.product_specs where product_id = s.product_id;
  -- Không còn "thay đổi nhỏ": mọi phiên bản mới đi quy trình Spec đầy đủ
  s.id := gen_random_uuid(); s.version := v_ver; s.status := 'DRAFT'; s.change_level := 'MAJOR';
  s.released_at := null; s.released_by := null; s.rdc_deviation_note := null;
  s.created_at := now(); s.created_by := auth.uid(); s.updated_at := now(); s.updated_by := null;
  insert into master.product_specs select s.*;
  v_new := s.id;
  insert into master.spec_results (spec_id, cable_bundle_mm, od_mm, sheath_kgkm, pp_kgkm, pet_kgkm, alpet_kgkm, drain_kgkm, tech_check)
  select v_new, cable_bundle_mm, od_mm, sheath_kgkm, pp_kgkm, pet_kgkm, alpet_kgkm, drain_kgkm, tech_check
  from master.spec_results where spec_id = p_from;
  insert into master.bom_headers (spec_id, status, note) values (v_new, 'DRAFT', 'Sao chép từ v' || (v_ver - 1));
  insert into master.bom_lines (bom_id, material_id, basis, qty_per_basis, loss_rate, startup_per_lot, operation_code, note)
  select (select id from master.bom_headers where spec_id = v_new), l.material_id, l.basis, l.qty_per_basis, l.loss_rate,
         l.startup_per_lot, l.operation_code, l.note
  from master.bom_lines l join master.bom_headers h on h.id = l.bom_id where h.spec_id = p_from;
  perform master.calc_spec(v_new);
  return v_new;
end $$;

create or replace function master.release_spec(p_spec uuid) returns void
language plpgsql security definer set search_path = master, core, public as $$
declare s master.product_specs; v_issues text[];
begin
  if coalesce(current_setting('bmt.wf_release', true), '') <> 'on' then
    raise exception 'Chỉ phát hành spec qua quy trình duyệt';
  end if;
  select * into s from master.product_specs where id = p_spec for update;
  v_issues := master.check_spec(p_spec);
  if array_length(v_issues, 1) > 0 then
    raise exception 'Không phát hành được spec: %', array_to_string(v_issues, '; ');
  end if;
  if not exists (select 1 from master.bom_headers where spec_id = p_spec) then
    raise exception 'Spec chưa có BOM';
  end if;
  update master.product_specs set status = 'OBSOLETE'
   where product_id = s.product_id and status = 'RELEASED' and id <> p_spec;
  update master.bom_headers set status = 'OBSOLETE'
   where spec_id in (select id from master.product_specs where product_id = s.product_id and id <> p_spec) and status = 'RELEASED';
  perform set_config('bmt.allow_release', 'on', true);
  update master.product_specs set status = 'RELEASED', released_at = now(), released_by = auth.uid() where id = p_spec;
  perform set_config('bmt.allow_release', 'off', true);
  update master.bom_headers set status = 'RELEASED' where spec_id = p_spec;
  update master.products set current_spec_id = p_spec where id = s.product_id;
end $$;

create or replace function mfg.release_wo(p_wo uuid) returns void
language plpgsql security definer set search_path = mfg, master, public as $$
declare w mfg.work_orders; v_spec_status text; v_group text;
begin
  if coalesce(current_setting('bmt.wf_release', true), '') <> 'on' and not core.has_perm('production', 'approve') then
    raise exception 'Chỉ phát lệnh sản xuất qua quy trình duyệt';
  end if;
  select * into w from mfg.work_orders where id = p_wo for update;
  if not found then raise exception 'Không tìm thấy lệnh sản xuất'; end if;
  if w.status <> 'DRAFT' then raise exception 'LSX % đang ở trạng thái %', w.wo_no, w.status; end if;
  select s.status, p.group_code into v_spec_status, v_group
    from master.product_specs s join master.products p on p.id = s.product_id where s.id = w.spec_id;
  if w.wo_type = 'PRODUCTION' and v_spec_status <> 'RELEASED' then
    raise exception 'LSX %: spec chưa phát hành, chuyển Kỹ thuật/QA (BR-SP-01)', w.wo_no;
  end if;
  if w.wo_type = 'PILOT' and (w.pilot_max_m is null or w.qty_m > w.pilot_max_m) then
    raise exception 'Lệnh pilot vượt giới hạn mét do KT đặt';
  end if;
  insert into mfg.wo_operations (wo_id, op_code, seq, planned_m)
  select p_wo, o.code, o.seq, w.qty_m from master.routings r join master.operations o on o.code = r.op_code
  where r.group_code = v_group
  on conflict (wo_id, op_code) do nothing;
  update mfg.work_orders set status = 'RELEASED', released_at = now(), released_by = auth.uid() where id = p_wo;
end $$;

-- ===========================================================================
-- 5. Kho: định mức theo lệnh SX, phiếu lĩnh tự tạo, chặn vượt định mức, phạm vi kho, "Đã kiểm"
-- ===========================================================================
-- Định mức NVL của cả lệnh SX (cùng công thức với giá thành định mức)
create or replace function mfg.wo_std_materials(p_wo uuid) returns table (material_id uuid, std_qty numeric)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare w mfg.work_orders; v_packs numeric; v_pallet numeric;
begin
  select * into w from mfg.work_orders where id = p_wo;
  if not found then return; end if;
  v_packs := ceil(w.qty_m / w.m_per_pack);
  select ceil(v_packs / case when w.pack_type = 'Bobin gỗ' then master.param(s.param_set_id, 'palletW') else master.param(s.param_set_id, 'palletC') end)
    into v_pallet from master.product_specs s where s.id = w.spec_id;
  return query
  select bl.material_id,
         round(sum(bl.qty_per_basis * case bl.basis when 'KM' then w.qty_m / 1000 when 'PACK' then v_packs
                                             when 'PALLET' then v_pallet else w.run_lots end / (1 - bl.loss_rate)
             + bl.startup_per_lot * w.run_lots), 4)
  from master.bom_lines bl where bl.bom_id = w.bom_id group by bl.material_id;
end $$;

-- NVL đã xuất thực (xuất − trả lại) cho lệnh SX
create or replace function inv.wo_issued(p_wo uuid) returns table (material_id uuid, qty numeric)
language sql stable security definer set search_path = pg_catalog, public as $$
  select l.material_id, -sum(sm.qty)
  from inv.stock_moves sm join inv.stock_docs d on d.id = sm.doc_id join inv.lots l on l.id = sm.lot_id
  where d.ref_type = 'WO' and d.ref_id = p_wo and d.doc_type in ('ISSUE_WO', 'RETURN_WO') and l.item_kind = 'MAT'
  group by l.material_id
$$;

-- Số kiểu Việt Nam: 1.234,5 (bỏ số 0 thừa)
create or replace function core.vn_num(p numeric) returns text
language sql immutable as $$
  select translate(rtrim(to_char(round(p, 4), 'FM999G999G999G990D9999'), '.'), ',.', '.,')
$$;

-- Phiếu lĩnh tự tạo theo định mức (cả lệnh, hoặc theo số mét chạy trong ca); chọn lô Đạt QC, cũ trước
create or replace function inv.create_wo_issue(p_wo uuid, p_qty_m numeric default null, p_warehouse text default 'KNL') returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare w mfg.work_orders; v_wh uuid; v_doc uuid; v_line int := 0; r record; b record; v_need numeric; v_take numeric;
        v_short text[] := '{}'; v_zero uuid := '00000000-0000-0000-0000-000000000000';
begin
  if not core.has_perm('inventory', 'create') then raise exception 'Không có quyền lập phiếu kho'; end if;
  select * into w from mfg.work_orders where id = p_wo;
  if not found then raise exception 'Không tìm thấy lệnh sản xuất'; end if;
  if w.status not in ('RELEASED', 'IN_PROGRESS', 'PAUSED') then
    raise exception 'LSX % chưa phát lệnh hoặc đã kết thúc (%)', w.wo_no, w.status;
  end if;
  if p_qty_m is not null and (p_qty_m <= 0 or p_qty_m > w.qty_m) then
    raise exception 'Số mét lĩnh phải lớn hơn 0 và không quá % m', w.qty_m;
  end if;
  select id into v_wh from inv.warehouses where code = p_warehouse;
  if v_wh is null then raise exception 'Không có kho %', p_warehouse; end if;
  if not core.can_use_warehouse(v_wh) then raise exception 'Bạn không được giao kho %', p_warehouse; end if;

  insert into inv.stock_docs (doc_no, doc_type, warehouse_id, ref_type, ref_id, note)
  values (core.next_no('XK'), 'ISSUE_WO', v_wh, 'WO', p_wo,
          'Phiếu lĩnh theo định mức ' || w.wo_no || coalesce(' · ' || core.vn_num(p_qty_m) || ' m', ''))
  returning id into v_doc;

  for r in select s.material_id, m.code, m.name,
                  greatest(least(s.std_qty * coalesce(p_qty_m / w.qty_m, 1), s.std_qty - coalesce(i.qty, 0)), 0) as need
           from mfg.wo_std_materials(p_wo) s join master.materials m on m.id = s.material_id
           left join inv.wo_issued(p_wo) i on i.material_id = s.material_id
           order by m.code loop
    v_need := round(r.need, 4);
    continue when v_need <= 0;
    for b in select sb.lot_id, sb.location_key, sb.qty - sb.reserved_qty as avail
             from inv.stock_balances sb join inv.lots l on l.id = sb.lot_id
             where sb.warehouse_id = v_wh and l.material_id = r.material_id and l.item_kind = 'MAT' and l.qc_status = 'PASSED'
               and sb.qty - sb.reserved_qty > 0
             order by l.mfg_date nulls last, l.lot_no loop
      exit when v_need <= 0;
      v_take := least(v_need, b.avail);
      v_line := v_line + 1;
      insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, qty)
      values (v_doc, v_line, b.lot_id, nullif(b.location_key, v_zero), v_take);
      v_need := v_need - v_take;
    end loop;
    if v_need > 0 then v_short := v_short || (r.code || ' thiếu ' || core.vn_num(v_need)); end if;
  end loop;

  if v_line = 0 then
    raise exception '%', case when cardinality(v_short) > 0 then 'Kho không đủ hàng Đạt QC: ' || array_to_string(v_short, '; ')
                              else 'LSX ' || w.wo_no || ' đã lĩnh đủ định mức' end;
  end if;
  if cardinality(v_short) > 0 then
    update inv.stock_docs set note = note || ' · Thiếu: ' || array_to_string(v_short, '; ') where id = v_doc;
  end if;
  return v_doc;
end $$;

alter table inv.stock_docs
  add column if not exists reviewed_at timestamptz,
  add column if not exists reviewed_by uuid references core.profiles(id);

create or replace function inv.post_doc(p_doc uuid) returns void
language plpgsql security definer set search_path = inv, cost, core, public as $$
declare
  d inv.stock_docs; l record; wh inv.warehouses; to_wh inv.warehouses; x record;
  v_sign int; v_cost numeric; v_val cost.item_valuation; v_loc uuid; v_zero uuid := '00000000-0000-0000-0000-000000000000';
begin
  if not core.has_perm('inventory', 'edit') then raise exception 'Không có quyền ghi sổ kho'; end if;
  select * into d from inv.stock_docs where id = p_doc for update;
  if d.status = 'POSTED' then raise exception 'Chứng từ % đã ghi sổ', d.doc_no; end if;
  if d.status not in ('DRAFT', 'APPROVED') then raise exception 'Chứng từ % đang ở trạng thái %', d.doc_no, d.status; end if;
  if d.doc_type in ('ADJ', 'SCRAP_OUT') and d.status <> 'APPROVED' then
    raise exception 'Chứng từ % cần được duyệt theo quy trình trước khi ghi sổ', d.doc_no;
  end if;
  select * into wh from inv.warehouses where id = d.warehouse_id;
  select * into to_wh from inv.warehouses where id = d.to_warehouse_id;
  if not core.can_use_warehouse(d.warehouse_id) or (d.to_warehouse_id is not null and not core.can_use_warehouse(d.to_warehouse_id)) then
    raise exception 'Bạn không được giao kho này (chứng từ %)', d.doc_no;
  end if;

  -- Xuất cho sản xuất: phải gắn lệnh SX và không vượt định mức (vượt thì gửi duyệt "Cấp NVL bổ sung vượt định mức")
  if d.doc_type = 'ISSUE_WO' then
    if d.ref_type is distinct from 'WO' or d.ref_id is null then
      raise exception 'Phiếu xuất sản xuất % phải gắn lệnh sản xuất', d.doc_no;
    end if;
    if d.status <> 'APPROVED' then
      select m.code, coalesce(s.std_qty, 0) as std, coalesce(i.qty, 0) as issued, t.qty as this_qty into x
      from (select lt.material_id, sum(dl.qty) as qty from inv.stock_doc_lines dl join inv.lots lt on lt.id = dl.lot_id
            where dl.doc_id = p_doc and lt.item_kind = 'MAT' group by lt.material_id) t
      join master.materials m on m.id = t.material_id
      left join mfg.wo_std_materials(d.ref_id) s on s.material_id = t.material_id
      left join inv.wo_issued(d.ref_id) i on i.material_id = t.material_id
      where coalesce(i.qty, 0) + t.qty > coalesce(s.std_qty, 0) + 0.0001
      order by m.code limit 1;
      if found then
        raise exception 'Vượt định mức (%): định mức %, đã xuất %, phiếu này %. Gửi duyệt "Cấp NVL bổ sung vượt định mức"',
          x.code, core.vn_num(x.std), core.vn_num(x.issued), core.vn_num(x.this_qty);
      end if;
    end if;
  end if;

  for l in select dl.*, lt.item_kind, lt.material_id, lt.qc_status, lt.lot_no
           from inv.stock_doc_lines dl join inv.lots lt on lt.id = dl.lot_id
           where dl.doc_id = p_doc order by dl.line_no loop

    v_sign := case when d.doc_type in ('GR','RETURN_WO','WIP_IN','FG_IN','SCRAP_IN') then 1
                   when d.doc_type in ('ISSUE_WO','SALE','SCRAP_OUT','RETURN_SUP','TRANSFER') then -1
                   when d.doc_type = 'ADJ' then sign(l.qty)::int end;
    if d.doc_type <> 'ADJ' and l.qty < 0 then raise exception 'Số lượng phải dương (dòng %)', l.line_no; end if;
    if d.doc_type in ('ISSUE_WO', 'SALE') and l.qc_status <> 'PASSED' then
      raise exception 'Lô % chưa đạt QC (%): không được xuất', l.lot_no, l.qc_status;   -- BR-KHO-02
    end if;

    v_cost := 0;
    if wh.kind = 'SCRAP' then
      v_cost := 0;
    elsif l.item_kind = 'MAT' then
      select * into v_val from cost.item_valuation where warehouse_id = d.warehouse_id and material_id = l.material_id for update;
      if d.doc_type = 'GR' then
        if l.unit_cost is null then raise exception 'Dòng % thiếu đơn giá nhập', l.line_no; end if;
        v_cost := l.unit_cost;
        insert into cost.item_valuation (warehouse_id, material_id, qty, avg_cost, value)
        values (d.warehouse_id, l.material_id, l.qty, l.unit_cost, round(l.qty * l.unit_cost, 2))
        on conflict (warehouse_id, material_id) do update set
          avg_cost = case when cost.item_valuation.qty + excluded.qty > 0
                          then (cost.item_valuation.value + excluded.value) / (cost.item_valuation.qty + excluded.qty)
                          else excluded.avg_cost end,
          qty = cost.item_valuation.qty + excluded.qty,
          value = cost.item_valuation.value + excluded.value,
          updated_at = now();
      else
        v_cost := coalesce(v_val.avg_cost, 0);
        insert into cost.item_valuation (warehouse_id, material_id, qty, avg_cost, value)
        values (d.warehouse_id, l.material_id, v_sign * abs(l.qty), v_cost, round(v_sign * abs(l.qty) * v_cost, 2))
        on conflict (warehouse_id, material_id) do update set
          qty = cost.item_valuation.qty + excluded.qty,
          value = case when cost.item_valuation.qty + excluded.qty = 0 then 0 else cost.item_valuation.value + excluded.value end,
          updated_at = now();
      end if;
    else
      v_cost := coalesce(l.unit_cost, 0);
    end if;

    v_loc := coalesce(l.location_id, v_zero);
    insert into inv.stock_moves (doc_id, doc_line_id, move_type, warehouse_id, location_id, lot_id, qty, qty_alt, unit_cost)
    values (p_doc, l.id, d.doc_type, d.warehouse_id, l.location_id, l.lot_id, v_sign * abs(l.qty), l.qty_alt, v_cost);
    perform inv.bal_add(d.warehouse_id, v_loc, l.lot_id, v_sign * abs(l.qty));

    if d.doc_type = 'TRANSFER' then
      if to_wh.id is null then raise exception 'Chuyển kho cần kho nhận'; end if;
      insert into inv.stock_moves (doc_id, doc_line_id, move_type, warehouse_id, location_id, lot_id, qty, qty_alt, unit_cost)
      values (p_doc, l.id, 'TRANSFER', to_wh.id, l.to_location_id, l.lot_id, abs(l.qty), l.qty_alt, v_cost);
      perform inv.bal_add(to_wh.id, coalesce(l.to_location_id, v_zero), l.lot_id, abs(l.qty));
      if l.item_kind = 'MAT' then
        insert into cost.item_valuation (warehouse_id, material_id, qty, avg_cost, value)
        values (to_wh.id, l.material_id, abs(l.qty), v_cost, round(abs(l.qty) * v_cost, 2))
        on conflict (warehouse_id, material_id) do update set
          avg_cost = (cost.item_valuation.value + excluded.value) / nullif(cost.item_valuation.qty + excluded.qty, 0),
          qty = cost.item_valuation.qty + excluded.qty, value = cost.item_valuation.value + excluded.value, updated_at = now();
      end if;
    end if;
  end loop;

  update inv.stock_docs set status = 'POSTED', posted_at = now(), posted_by = auth.uid() where id = p_doc;

  if d.doc_type in ('GR','ISSUE_WO','RETURN_WO','FG_IN','SALE','SCRAP_OUT','ADJ','TRANSFER') then
    insert into integ.sync_queue (entity, entity_id, direction) values ('STOCK_DOC', p_doc, 'TO_MISA');
  end if;
exception
  when check_violation then
    raise exception 'Không đủ tồn để xuất (chứng từ %): %', d.doc_no, sqlerrm;
end $$;

-- Kế toán SX đánh dấu đã kiểm phiếu đã ghi sổ (không kiểm phiếu do chính mình lập/ghi sổ)
create or replace function app.review_stock_docs(p_ids uuid[]) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_n int;
begin
  if not core.has_role('KT_KHO') then raise exception 'Chỉ Kế toán kho (Kế toán SX) đánh dấu đã kiểm'; end if;
  update inv.stock_docs set reviewed_at = now(), reviewed_by = auth.uid()
   where id = any(p_ids) and status = 'POSTED' and reviewed_at is null
     and coalesce(posted_by, '00000000-0000-0000-0000-000000000000') <> auth.uid()
     and coalesce(created_by, '00000000-0000-0000-0000-000000000000') <> auth.uid();
  get diagnostics v_n = row_count;
  return v_n;
end $$;

create or replace function app.wo_no(p_wo uuid) returns text
language sql stable security definer set search_path = pg_catalog, public as $$
  select wo_no from mfg.work_orders where id = p_wo and auth.uid() is not null
$$;

create or replace view app.v_stock_docs with (security_invoker = true) as
select d.id, d.doc_no, d.doc_type,
       case d.doc_type when 'GR' then 'Nhập mua' when 'ISSUE_WO' then 'Xuất sản xuất' when 'RETURN_WO' then 'Trả NVL thừa'
         when 'WIP_IN' then 'Nhập BTP' when 'FG_IN' then 'Nhập thành phẩm' when 'SCRAP_IN' then 'Nhập phế'
         when 'SALE' then 'Xuất bán' when 'SCRAP_OUT' then 'Xuất phế' when 'TRANSFER' then 'Chuyển kho'
         when 'ADJ' then 'Điều chỉnh kiểm kê' when 'RETURN_SUP' then 'Trả NCC' end as doc_type_name,
       w.code as warehouse_code, w.name as warehouse_name, d.doc_date, d.status, d.note,
       case when d.ref_type = 'WO' then app.wo_no(d.ref_id) end as wo_no,
       d.posted_at, app.user_name(d.posted_by) as posted_by_name, app.user_name(d.created_by) as created_by_name,
       d.reviewed_at, app.user_name(d.reviewed_by) as reviewed_by_name,
       (d.posted_by = auth.uid() or d.created_by = auth.uid()) as mine,
       (select count(*) from inv.stock_doc_lines dl where dl.doc_id = d.id) as line_count
from inv.stock_docs d join inv.warehouses w on w.id = d.warehouse_id;

-- ===========================================================================
-- 6. Cân bằng đồng theo lệnh SX
-- ===========================================================================
create table if not exists mfg.control_settings (
  key        text primary key,
  name       text not null,
  value      numeric not null,
  unit       text,
  owner_role text references core.roles(code),
  updated_at timestamptz not null default now(),
  updated_by uuid
);
insert into mfg.control_settings (key, name, value, unit, owner_role) values
  ('copper_tolerance_pct', 'Lệch cân bằng đồng cho phép (tạm, TP Kỹ thuật/QA chỉnh)', 2, '%', 'KT_TP')
on conflict (key) do nothing;
alter table mfg.control_settings enable row level security;
drop policy if exists p_select on mfg.control_settings;
create policy p_select on mfg.control_settings for select to authenticated using (true);
grant select on mfg.control_settings to authenticated;
grant all on mfg.control_settings to service_role;

create or replace function app.set_control_setting(p_key text, p_value numeric) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare s mfg.control_settings;
begin
  select * into s from mfg.control_settings where key = p_key;
  if not found then raise exception 'Không có thông số %', p_key; end if;
  if not (core.has_role(s.owner_role) or core.has_perm('admin', 'edit')) then
    raise exception 'Chỉ % được chỉnh "%"', (select name from core.roles where code = s.owner_role), s.name;
  end if;
  if p_value is null or p_value < 0 or p_value > 100 then raise exception 'Giá trị phải từ 0 đến 100'; end if;
  update mfg.control_settings set value = p_value, updated_at = now(), updated_by = auth.uid() where key = p_key;
end $$;

-- Đồng xuất (kim loại dẫn, xuất − trả) so với đồng trong thành phẩm (mét CĐ6 × kg/km lõi + drain) cộng phế đồng nộp lại
create or replace function app.copper_balance(p_days int default 60)
returns table (wo_id uuid, wo_no text, product_code text, wo_status text, finished boolean, good_m numeric,
               issued_kg numeric, product_kg numeric, scrap_kg numeric, diff_kg numeric, diff_pct numeric,
               tolerance_pct numeric, over_limit boolean)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_tol numeric;
begin
  if not (core.has_perm('inventory', 'view') or core.has_perm('production', 'view') or core.has_perm('cost', 'view')) then
    raise exception 'Không có quyền xem cân bằng đồng';
  end if;
  select value into v_tol from mfg.control_settings where key = 'copper_tolerance_pct';
  return query
  with w as (
    select wo.* from mfg.work_orders wo
    where wo.status not in ('DRAFT', 'CANCELLED') and coalesce(wo.released_at, wo.created_at) > now() - make_interval(days => p_days)
  ), iss as (
    select d.ref_id as wo_id, -sum(sm.qty) as kg
    from inv.stock_moves sm join inv.stock_docs d on d.id = sm.doc_id join inv.lots l on l.id = sm.lot_id
    join master.materials m on m.id = l.material_id
    where d.ref_type = 'WO' and d.doc_type in ('ISSUE_WO', 'RETURN_WO') and l.item_kind = 'MAT' and m.group_code = 'CONDUCTOR'
    group by d.ref_id
  ), outp as (
    select o.wo_id, sum(op.qty_m) as m from mfg.wo_outputs op join mfg.wo_operations o on o.id = op.wo_op_id
    where o.op_code = 'CD6' group by o.wo_id
  ), scr as (
    select o.wo_id, sum(s.qty_kg) as kg from mfg.scrap_records s join mfg.wo_operations o on o.id = s.wo_op_id
    join master.materials m on m.id = s.scrap_material_id where m.code in ('PL-CU', 'PL-TC') group by o.wo_id
  )
  select w.id, w.wo_no, p.code, w.status, w.status in ('PRODUCED', 'QC_PENDING', 'CLOSED'),
         coalesce(outp.m, 0),
         round(coalesce(iss.kg, 0), 3),
         round(coalesce(outp.m, 0) * (coalesce(r.metal_kgkm, 0) + coalesce(r.drain_kgkm, 0)) / 1000, 3),
         round(coalesce(scr.kg, 0), 3),
         round(coalesce(iss.kg, 0) - coalesce(outp.m, 0) * (coalesce(r.metal_kgkm, 0) + coalesce(r.drain_kgkm, 0)) / 1000 - coalesce(scr.kg, 0), 3),
         case when coalesce(iss.kg, 0) > 0 then round(100 * (coalesce(iss.kg, 0) - coalesce(outp.m, 0) * (coalesce(r.metal_kgkm, 0) + coalesce(r.drain_kgkm, 0)) / 1000
                                                              - coalesce(scr.kg, 0)) / iss.kg, 2) end,
         v_tol,
         w.status in ('PRODUCED', 'QC_PENDING', 'CLOSED') and coalesce(iss.kg, 0) > 0
           and abs(100 * (coalesce(iss.kg, 0) - coalesce(outp.m, 0) * (coalesce(r.metal_kgkm, 0) + coalesce(r.drain_kgkm, 0)) / 1000
                          - coalesce(scr.kg, 0)) / iss.kg) > v_tol
  from w join master.products p on p.id = w.product_id
  left join master.spec_results r on r.spec_id = w.spec_id
  left join iss on iss.wo_id = w.id left join outp on outp.wo_id = w.id left join scr on scr.wo_id = w.id
  order by w.wo_no desc;
end $$;

-- ===========================================================================
-- 7. NV mua hàng được sinh PR từ MRP
-- ===========================================================================
create or replace function plan.create_pr_from_mrp(p_run uuid) returns uuid
language plpgsql security definer set search_path = plan, purchase, public as $$
declare v_pr uuid; p plan.production_plans;
begin
  if not (core.has_perm('plan', 'create') or core.has_perm('purchase', 'create')) then raise exception 'Không có quyền tạo PR'; end if;
  select pp.* into p from plan.mrp_runs r join plan.production_plans pp on pp.id = r.plan_id where r.id = p_run;
  if p.status <> 'APPROVED' or p.mode <> 'OFFICIAL' then
    raise exception 'Chỉ sinh PR từ kế hoạch chính thức đã được phê duyệt';
  end if;
  if p.mrp_stale then raise exception 'Dòng kế hoạch đã thay đổi sau lần chạy MRP: chạy lại MRP'; end if;
  if exists (select 1 from purchase.purchase_requests pr where pr.mrp_run_id = p_run and pr.status <> 'CANCELLED') then
    raise exception 'Đã sinh đề xuất mua từ kết quả MRP này';
  end if;
  insert into purchase.purchase_requests (pr_no, source, mrp_run_id, need_date, note)
  values (core.next_no('PR'), 'MRP', p_run, p.material_need_date, 'Từ ' || p.plan_no) returning id into v_pr;
  insert into purchase.pr_lines (pr_id, material_id, qty, need_date, mrp_line_id, note)
  select v_pr, material_id, suggest_qty, coalesce(need_date, latest_order_date), id, note
  from plan.mrp_lines where run_id = p_run and suggest_qty > 0;
  return v_pr;
end $$;

-- ===========================================================================
-- Quyền gọi hàm
-- ===========================================================================
grant select on all tables in schema app to authenticated, service_role;
revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;
revoke execute on function app.notification_outbox(int) from authenticated;
revoke execute on function wf.flow_config(text), wf.build_snapshot(text, uuid), wf.doc_facts(text, uuid), wf.check_doc(text, uuid)
  from public, anon, authenticated;
grant execute on function inv.create_wo_issue(uuid, numeric, text), mfg.wo_std_materials(uuid), inv.wo_issued(uuid),
  core.can_use_warehouse(uuid), core.role_conflict_text(text[]) to authenticated, service_role;
revoke execute on function inv.create_wo_issue(uuid, numeric, text), mfg.wo_std_materials(uuid), inv.wo_issued(uuid),
  core.can_use_warehouse(uuid), core.role_conflict_text(text[]) from public, anon;
