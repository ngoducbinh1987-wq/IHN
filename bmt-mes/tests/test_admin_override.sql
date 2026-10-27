-- Kiểm thử migration 20261026002900: Quản trị hệ thống hủy quy trình, mở lại để sửa, xóa chứng từ.
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
grant execute on function pg_temp.ok(boolean, text) to authenticated;
set client_min_messages = notice;

with u(code, role) as (values ('A_ADM','ADMIN'),('A_MUA','MUA_NV'),('A_BGD','BGD'),('A_SXKH','SX_KH'),('A_MUATP','MUA_TP')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('A_ADM','ADMIN'),('A_MUA','MUA_NV'),('A_BGD','BGD'),('A_SXKH','SX_KH'),('A_MUATP','MUA_TP')) u(code, role) on u.code = p.employee_code;

-- Dữ liệu mẫu do NV mua lập
insert into purchase.purchase_requests (pr_no, source, created_by) select x, 'MANUAL', (select id from core.profiles where employee_code = 'A_MUA')
  from unnest(array['PR-A1','PR-A2','PR-A3']) x;
insert into purchase.pr_lines (pr_id, material_id, qty)
select pr.id, (select id from master.materials order by code limit 1), 10 from purchase.purchase_requests pr where pr.pr_no in ('PR-A1','PR-A2','PR-A3');
insert into t select pr_no, id from purchase.purchase_requests where pr_no in ('PR-A1','PR-A2','PR-A3');
-- PR-A3 đã lên PO
insert into purchase.purchase_orders (po_no, supplier_id) select 'PO-A3', id from core.partners order by code limit 1;
insert into purchase.po_lines (po_id, line_no, material_id, qty, pr_line_id)
select (select id from purchase.purchase_orders where po_no = 'PO-A3'), 1, l.material_id, 10, l.id from purchase.pr_lines l where l.pr_id = (select v from t where k = 'PR-A3');

-- ================================================================ 1. Hủy quy trình đang chạy
select pg_temp.as_user('A_MUA');
select pg_temp.as_api($q$insert into t select 'req1', wf.submit('PR', (select v from t where k = 'PR-A1'), '', 'Thử hủy')$q$);
select pg_temp.blocked($q$select app.admin_cancel_request((select v from t where k = 'req1'), 'tự hủy')$q$, 'Chỉ Quản trị',
  'Người không phải Quản trị không hủy được quy trình');
select pg_temp.as_user('A_ADM');
select pg_temp.blocked($q$select app.admin_cancel_request((select v from t where k = 'req1'), '  ')$q$, 'Nhập lý do', 'Hủy quy trình bắt buộc ghi lý do');
select pg_temp.as_api($q$select app.admin_cancel_request((select v from t where k = 'req1'), 'Lập nhầm nhà cung cấp')$q$);
select pg_temp.ok((select q.status = 'CANCELLED' and pr.status = 'DRAFT' from wf.approval_requests q join purchase.purchase_requests pr on pr.id = q.doc_id
  where q.id = (select v from t where k = 'req1')), 'Quản trị hủy quy trình: yêu cầu Đã hủy, PR về Nháp');
select pg_temp.ok(exists (select 1 from wf.approval_actions where request_id = (select v from t where k = 'req1') and comment like '[Quản trị hủy quy trình]%')
  and exists (select 1 from core.audit_log where action = 'ADMIN_CANCEL' and row_id = (select v from t where k = 'req1')::text)
  and exists (select 1 from wf.notifications n join core.profiles p on p.id = n.user_id where p.employee_code = 'A_MUA' and n.title like 'Quản trị đã hủy%'),
  'Lịch sử quy trình, nhật ký và thông báo cho người lập đều ghi lại việc hủy');
select pg_temp.blocked($q$select app.admin_cancel_request((select v from t where k = 'req1'), 'lần 2')$q$, 'đã kết thúc', 'Không hủy lại quy trình đã kết thúc');

-- ================================================================ 2. Mở lại chứng từ đã duyệt
select pg_temp.as_user('A_MUA');
select pg_temp.as_api($q$insert into t select 'req2', wf.submit('PR', (select v from t where k = 'PR-A2'), '', 'Thử mở lại')$q$);
select pg_temp.as_user('A_MUATP');   -- PR: TP Mua duyệt → Giám đốc duyệt (migration 4500)
select pg_temp.as_api($q$select wf.act((select v from t where k = 'req2'), 'APPROVE', 'Đồng ý')$q$);
select pg_temp.as_user('A_BGD');
select pg_temp.as_api($q$select wf.act((select v from t where k = 'req2'), 'APPROVE', 'Đồng ý')$q$);
select pg_temp.ok((select status = 'APPROVED' from purchase.purchase_requests where pr_no = 'PR-A2'), 'PR-A2 đã duyệt');
select pg_temp.blocked($q$select app.admin_doc('PR', (select v from t where k = 'PR-A2'), 'reopen', 'sửa số lượng')$q$, 'Chỉ Quản trị',
  'Giám đốc (không phải Quản trị) không mở lại được chứng từ');
select pg_temp.as_user('A_ADM');
select pg_temp.as_api($q$select app.admin_doc('PR', (select v from t where k = 'PR-A2'), 'reopen', 'Sửa số lượng theo tồn thực tế')$q$);
select pg_temp.ok((select status = 'DRAFT' from purchase.purchase_requests where pr_no = 'PR-A2')
  and (select old_data #>> '{doc,status}' = 'APPROVED' from core.audit_log where action = 'ADMIN_REOPEN' and row_id = (select v from t where k = 'PR-A2')::text),
  'Quản trị mở lại PR đã duyệt về Nháp; nhật ký lưu trạng thái cũ');
select pg_temp.as_user('A_MUA');
select pg_temp.as_api($q$insert into t select 'req2b', wf.submit('PR', (select v from t where k = 'PR-A2'), '', 'Gửi lại sau khi sửa')$q$);
select pg_temp.ok((select status = 'PENDING' from wf.approval_requests where id = (select v from t where k = 'req2b')), 'Sau khi mở lại, người lập gửi duyệt lại được');

-- ================================================================ 3. Xóa chứng từ
select pg_temp.as_user('A_ADM');
select pg_temp.blocked($q$select app.admin_doc('PR', (select v from t where k = 'PR-A3'), 'delete', 'xóa')$q$, 'đã lên PO PO-A3',
  'Không xóa PR đã lên PO');
select pg_temp.as_api($q$select app.admin_doc('PR', (select v from t where k = 'PR-A2'), 'delete', 'Trùng với đề xuất khác')$q$);
select pg_temp.ok(not exists (select 1 from purchase.purchase_requests where pr_no = 'PR-A2')
  and (select status = 'CANCELLED' from wf.approval_requests where id = (select v from t where k = 'req2b'))
  and (select jsonb_array_length(old_data -> 'lines') = 1 and old_data #>> '{doc,pr_no}' = 'PR-A2'
         from core.audit_log where action = 'ADMIN_DELETE' and row_id = (select v from t where k = 'PR-A2')::text),
  'Quản trị xóa PR đang chờ duyệt: quy trình dừng, nhật ký giữ bản sao phiếu và dòng');
select pg_temp.blocked($q$select app.admin_doc('STOCK_ADJ', gen_random_uuid(), 'delete', 'xóa')$q$, 'phiếu đảo', 'Phiếu kho không xóa ở đây');
select pg_temp.blocked($q$select app.admin_doc('PR', gen_random_uuid(), 'delete', 'xóa')$q$, 'Không tìm thấy', 'Chứng từ không tồn tại');

-- Kế hoạch: có lệnh SX thì không xóa; không có thì xóa được (kèm đơn phát sinh, lần chạy MRP)
insert into t select 'spec', s.id from master.products p join lateral (select id from master.product_specs where product_id = p.id order by version desc limit 1) s on true
 order by p.code limit 1;
do $$ begin
  perform set_config('bmt.allow_release', 'on', true);
  update master.product_specs set status = 'RELEASED' where id = (select v from t where k = 'spec') and status <> 'RELEASED';
  perform set_config('bmt.allow_release', 'off', true);
end $$;
insert into plan.production_plans (plan_no, period_label) values ('KH-A1', 'Thử xóa'), ('KH-A2', 'Có lệnh SX');
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, m_per_pack, pack_type, brand)
select pp.id, s.product_id, s.id, 1000, 500, 'Bobin gỗ', 'KAVIX' from plan.production_plans pp, master.product_specs s
 where pp.plan_no in ('KH-A1','KH-A2') and s.id = (select v from t where k = 'spec');
insert into mfg.work_orders (wo_no, product_id, spec_id, bom_id, qty_m, m_per_pack, pack_type, brand, plan_line_id)
select 'LSX-A2', l.product_id, l.spec_id, (select id from master.bom_headers where spec_id = l.spec_id limit 1), 1000, 500, 'Bobin gỗ', 'KAVIX', l.id
  from plan.plan_lines l join plan.production_plans pp on pp.id = l.plan_id where pp.plan_no = 'KH-A2';
insert into plan.change_requests (plan_id, req_no, payload, result, level, steps)
select id, 'DPS-A1', '{}', '{}', 'A', '[]' from plan.production_plans where plan_no = 'KH-A1';
select plan.run_mrp((select id from plan.production_plans where plan_no = 'KH-A1'));
insert into t select plan_no, id from plan.production_plans where plan_no in ('KH-A1','KH-A2');
insert into t select 'DPS-A1', id from plan.change_requests where req_no = 'DPS-A1';
select pg_temp.blocked($q$select app.admin_doc('PLAN', (select v from t where k = 'KH-A2'), 'delete', 'xóa')$q$, 'đã có lệnh SX LSX-A2',
  'Không xóa kế hoạch đã có lệnh SX');
select pg_temp.blocked($q$select app.admin_doc('DPS', (select v from t where k = 'DPS-A1'), 'reopen', 'mở')$q$, 'không mở lại', 'Đơn phát sinh chỉ xóa, không mở lại');
select pg_temp.as_api($q$select app.admin_doc('DPS', (select v from t where k = 'DPS-A1'), 'delete', 'Khách hủy đơn')$q$);
select pg_temp.ok(not exists (select 1 from plan.change_requests where req_no = 'DPS-A1'), 'Quản trị xóa đơn phát sinh');
select pg_temp.as_api($q$select app.admin_doc('PLAN', (select v from t where k = 'KH-A1'), 'delete', 'Lập thử')$q$);
select pg_temp.ok(not exists (select 1 from plan.production_plans where plan_no = 'KH-A1')
  and not exists (select 1 from plan.mrp_runs where plan_id = (select v from t where k = 'KH-A1')),
  'Quản trị xóa kế hoạch chưa có lệnh SX, kèm các lần chạy MRP');

-- Spec đã phát hành: không mở lại/xóa
select pg_temp.blocked($q$select app.admin_doc('SPEC_NEW', (select v from t where k = 'spec'), 'delete', 'xóa')$q$, 'đã phát hành',
  'Spec đã phát hành không xóa được (tạo phiên bản mới)');

-- ================================================================ 4. Nhật ký và quyền gọi
select pg_temp.ok((select count(*) >= 4 from app.admin_overrides(50)), 'Quản trị xem được nhật ký can thiệp');
select pg_temp.as_user('A_MUA');
create temp table c as select 0 as n;
grant all on c to authenticated;
select pg_temp.as_api($q$update c set n = (select count(*) from app.admin_overrides(50))$q$);
select pg_temp.ok((select n = 0 from c), 'Người không có quyền quản trị không xem được nhật ký can thiệp');
select pg_temp.ok(not has_function_privilege('anon', 'app.admin_doc(text,uuid,text,text)', 'execute')
  and not has_function_privilege('anon', 'app.admin_cancel_request(uuid,text)', 'execute'), 'Chưa đăng nhập không gọi được hàm quản trị');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
