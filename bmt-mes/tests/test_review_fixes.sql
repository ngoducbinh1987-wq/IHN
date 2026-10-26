-- Kiểm thử migration 20261026002500 (rà soát 26/10/2026): chốt trạng thái, đơn phát sinh, mã kiểm, quyền anon.
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
-- Chạy câu lệnh dưới vai trò authenticated (như gọi qua API) và mong đợi bị chặn
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

with u(code, role) as (values ('V_MUANV','MUA_NV'),('V_SXKH','SX_KH'),('V_SXTP','SX_TP'),('V_THUKHO','THU_KHO'),
  ('V_KDNV','KD_NV'),('V_BGD','BGD'),('V_BGD2','BGD'),('V_KTTP','KT_TP'),('V_KTNV','KT_NV')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('V_MUANV','MUA_NV'),('V_SXKH','SX_KH'),('V_SXTP','SX_TP'),('V_THUKHO','THU_KHO'),
  ('V_KDNV','KD_NV'),('V_BGD','BGD'),('V_BGD2','BGD'),('V_KTTP','KT_TP'),('V_KTNV','KT_NV')) u(code, role) on u.code = p.employee_code;

-- Dữ liệu mẫu (tạo bằng quyền hệ thống)
insert into purchase.purchase_orders (po_no, supplier_id) select 'PO-V1', id from core.partners order by code limit 1;
insert into plan.production_plans (plan_no, period_label) values ('KH-V1', 'Thử rà soát');
insert into inv.lots (lot_no, item_kind, material_id, uom) select 'LOT-V1', 'MAT', id, 'kg' from master.materials order by code limit 1;
insert into sales.sales_orders (so_no, customer_id, label_brand, required_date) select 'SO-V1', id, 'KAVIX', current_date + 30 from core.partners order by code limit 1;

-- ================================================================ 1. Chốt trạng thái
select pg_temp.as_user('V_MUANV');
select pg_temp.blocked($$update purchase.purchase_orders set status = 'APPROVED' where po_no = 'PO-V1'$$, 'Không đổi trực tiếp', 'NV mua không tự duyệt PO qua API');
select pg_temp.blocked($$insert into purchase.purchase_orders (po_no, supplier_id, status) select 'PO-V2', id, 'APPROVED' from core.partners limit 1$$,
  'Tạo mới phải ở trạng thái DRAFT', 'Không tạo PO ở trạng thái đã duyệt');
select pg_temp.as_api($$update purchase.purchase_orders set note = 'Ghi chú sửa được' where po_no = 'PO-V1'$$);
select pg_temp.ok((select note = 'Ghi chú sửa được' and status = 'DRAFT' from purchase.purchase_orders where po_no = 'PO-V1'), 'Sửa nội dung khác (ghi chú) vẫn được');
select pg_temp.as_user('V_SXKH');
select pg_temp.blocked($$update plan.production_plans set status = 'APPROVED' where plan_no = 'KH-V1'$$, 'Không đổi trực tiếp', 'Kế hoạch SX không tự duyệt kế hoạch tháng');
select pg_temp.as_api($$insert into plan.production_plans (plan_no, period_label) values ('KH-V2', 'Tạo từ web')$$);
select pg_temp.ok(exists (select 1 from plan.production_plans where plan_no = 'KH-V2' and status = 'DRAFT'), 'Tạo kế hoạch từ web (trạng thái Nháp) vẫn được');
select pg_temp.as_user('V_THUKHO');
select pg_temp.blocked($$update inv.lots set qc_status = 'PASSED' where lot_no = 'LOT-V1'$$, 'Không đổi trực tiếp', 'Thủ kho không tự chuyển lô sang QC đạt');
select pg_temp.as_user('V_KDNV');
select pg_temp.blocked($$update sales.sales_orders set status = 'APPROVED' where so_no = 'SO-V1'$$, 'Không đổi trực tiếp', 'NV kinh doanh không tự duyệt đơn bán');
-- Luồng duyệt (hàm hệ thống) vẫn đổi được trạng thái (bước lập kế hoạch tháng: Giám đốc)
select pg_temp.as_user('V_BGD');
select pg_temp.as_api($q$insert into t select 'req', wf.submit('PLAN', (select id from plan.production_plans where plan_no = 'KH-V1'), 'KH-V1', 'Thử')$q$);
select pg_temp.ok((select status = 'PENDING_APPROVAL' from plan.production_plans where plan_no = 'KH-V1'), 'Gửi duyệt qua quy trình (gọi từ API) vẫn đổi được trạng thái');
-- Mã kiểm bỏ ngày bắt đầu xếp lịch: đặt sched_start khi đang chờ duyệt không làm hồ sơ bị coi là đã sửa
update plan.production_plans set sched_start = current_date + 3 where plan_no = 'KH-V1';
select pg_temp.ok((select data_hash = wf.doc_hash('plan.production_plans', doc_id) from wf.approval_requests where id = (select v from t where k = 'req')),
  'Đổi ngày bắt đầu xếp lịch không làm lệch mã kiểm chứng từ');
update plan.production_plans set note = 'Sửa sau khi gửi' where plan_no = 'KH-V1';
select pg_temp.ok((select data_hash <> wf.doc_hash('plan.production_plans', doc_id) from wf.approval_requests where id = (select v from t where k = 'req')),
  'Sửa nội dung kế hoạch sau khi gửi vẫn bị phát hiện');

-- ================================================================ 2. Đơn phát sinh
select pg_temp.as_user('V_SXKH');
insert into t select 'cr_c', app.kh_create_change((select id from plan.production_plans where plan_no = 'KH-V2'),
  '{"product_code":"X","qty_m":100,"priority":"0","br":true}', '{"placed":true,"slack":2,"newly":[]}', 'C', '[{"role":"SX_KH","label":"tự duyệt"}]');
select pg_temp.ok((select jsonb_array_length(steps) = 3 and steps->1->>'role' = 'KT_TP' and steps->2->>'role' = 'BGD' and status = 'PENDING'
  from plan.change_requests where id = (select v from t where k = 'cr_c')), 'Mức C: database tự lập 3 bước (lập → TP KT/QA → Giám đốc), bỏ qua bước do trình duyệt gửi');
do $$ begin
  begin
    perform app.kh_create_change((select id from plan.production_plans where plan_no = 'KH-V2'),
      '{"product_code":"X","qty_m":100,"priority":"0","br":true}', '{"placed":true,"slack":2,"newly":[]}', 'A', '[]');
    raise exception 'FAIL: mức A cho đơn chen vùng khóa phải bị chặn';
  exception when others then
    if sqlerrm not like '%tối thiểu mức C%' then raise; end if;
    insert into r(msg) values ('Không hạ mức: đơn chen vùng khóa khai mức A bị chặn → ' || sqlerrm);
  end;
  begin
    perform app.kh_create_change((select id from plan.production_plans where plan_no = 'KH-V2'),
      '{"product_code":"X","qty_m":100,"priority":"1"}', '{"placed":true,"slack":-1,"newly":["KH dòng 1"]}', 'A', '[]');
    raise exception 'FAIL: mức A khi làm trễ đơn khác phải bị chặn';
  exception when others then
    if sqlerrm not like '%tối thiểu mức B%' then raise; end if;
    insert into r(msg) values ('Không hạ mức: làm trễ đơn khác mà khai mức A bị chặn → ' || sqlerrm);
  end;
end $$;
insert into t select 'cr_a', app.kh_create_change((select id from plan.production_plans where plan_no = 'KH-V2'),
  '{"product_code":"X","qty_m":100,"priority":"1"}', '{"placed":true,"slack":3,"newly":[]}', 'A', '[]');
select pg_temp.ok((select jsonb_array_length(steps) = 1 and status = 'READY' from plan.change_requests where id = (select v from t where k = 'cr_a')),
  'Mức A hợp lệ: Quản lý SX tự áp dụng');
-- Người lập (có thêm vai trò TP KT/QA) không tự duyệt bước tiếp theo
insert into core.user_roles (user_id, role_code) select id, 'KT_TP' from core.profiles where employee_code = 'V_SXKH';
do $$ begin
  begin
    perform app.kh_change_step((select v from t where k = 'cr_c'), 'approve', null);
    raise exception 'FAIL: người lập tự duyệt đơn phát sinh';
  exception when others then
    if sqlerrm not like '%không tự duyệt%' then raise; end if;
    insert into r(msg) values ('Người lập không tự duyệt bước sau của đơn phát sinh → ' || sqlerrm);
  end;
end $$;
select pg_temp.as_user('V_KTTP');
select pg_temp.ok(app.kh_change_step((select v from t where k = 'cr_c'), 'approve', 'Đồng ý') = 'PENDING', 'TP KT/QA duyệt bước của mình, chuyển Giám đốc');

-- ================================================================ 3. Quyền gọi hàm khi chưa đăng nhập
select pg_temp.ok(not has_function_privilege('anon', 'wf.step_actor_ids(jsonb)', 'execute')
  and not has_function_privilege('anon', 'wf.can_act_step(jsonb)', 'execute')
  and not has_function_privilege('anon', 'plan.mrp_lock_reason(uuid)', 'execute')
  and has_function_privilege('authenticated', 'wf.can_act_step(jsonb)', 'execute'), 'Thu quyền anon trên hàm luồng duyệt, người đăng nhập vẫn dùng được');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
