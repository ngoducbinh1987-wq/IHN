-- Kiểm thử migration 20261026005700: quyền tối cao của Quản trị hệ thống.
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
grant execute on function pg_temp.ok(boolean, text) to authenticated;
grant execute on function pg_temp.v(text) to authenticated;
set client_min_messages = notice;

-- Dữ liệu thật trên Supabase: tạm ngưng tài khoản thật để danh sách người duyệt chỉ gồm người thử
update core.profiles set status = 'INACTIVE' where status = 'ACTIVE';
with u(code) as (values ('S_ADM'),('S_MUA'),('S_MUATP'),('S_BGD'),('S_X')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('S_ADM','ADMIN'),('S_MUA','MUA_NV'),('S_MUATP','MUA_TP'),('S_BGD','BGD'),('S_X','MUA_TP'),('S_X','BGD')) u(code, role)
  on u.code = p.employee_code;

-- ================================================================ 1. Quyền nền
select pg_temp.as_user('S_ADM');
select pg_temp.ok(core.has_perm('inventory', 'edit') and core.has_perm('cost', 'edit') and core.has_perm('purchase', 'approve')
  and core.can_see_price() and core.is_admin(), 'Quản trị (chỉ giữ vai trò ADMIN) có mọi quyền thao tác và xem giá');
select pg_temp.ok(core.can_use_warehouse((select id from inv.warehouses where code = 'KTP'))
  and inv.require_keeper((select id from inv.warehouses where code = 'KNL'), null) = false, 'Quản trị dùng mọi kho, không cần là người giữ kho');
select pg_temp.as_user('S_MUA');
select pg_temp.ok(not core.has_perm('cost', 'edit') and not core.is_admin(), 'Người thường không có quyền ngoài vai trò của mình');

-- ================================================================ 2. Quản trị duyệt chứng từ mình lập, duyệt liền các bước
insert into purchase.purchase_requests (pr_no, source, created_by) select x, 'MANUAL', (select id from core.profiles where employee_code = c)
  from (values ('PR-S1','S_ADM'),('PR-S2','S_MUA')) v(x, c);
insert into purchase.pr_lines (pr_id, material_id, qty)
select pr.id, (select id from master.materials order by code limit 1), 10 from purchase.purchase_requests pr where pr.pr_no in ('PR-S1','PR-S2');
insert into t select pr_no, id from purchase.purchase_requests where pr_no in ('PR-S1','PR-S2');

select pg_temp.as_user('S_ADM');
select pg_temp.as_api($q$insert into t select 'req1', wf.submit('PR', pg_temp.v('PR-S1'), '', 'Quản trị tự lập')$q$);
select pg_temp.as_api($q$insert into t select 'turn1', (select case when my_turn then id end from app.v_approvals where id = pg_temp.v('req1'))$q$);
select pg_temp.ok(pg_temp.v('turn1') is not null, '"Chờ tôi duyệt" của Quản trị có cả chứng từ mình lập');
select pg_temp.as_api($q$select app.save_pr_line(pg_temp.v('PR-S1'), (select code from master.materials order by code limit 1), 25, null)$q$);
select pg_temp.ok((select qty = 25 from purchase.pr_lines where pr_id = pg_temp.v('PR-S1')), 'Quản trị sửa đề xuất đang chờ duyệt do chính mình lập');
select pg_temp.as_api($q$select wf.act(pg_temp.v('req1'), 'APPROVE', 'Đồng ý')$q$);
select pg_temp.ok(exists (select 1 from wf.approval_actions where request_id = pg_temp.v('req1') and comment like '[Quản trị duyệt chứng từ mình lập]%'),
  'Quản trị duyệt bước 1 chứng từ mình lập, lịch sử ghi rõ');
select pg_temp.as_api($q$select wf.act(pg_temp.v('req1'), 'APPROVE', 'Đồng ý')$q$);
select pg_temp.ok((select status = 'APPROVED' from purchase.purchase_requests where id = pg_temp.v('PR-S1'))
  and exists (select 1 from wf.approval_actions where request_id = pg_temp.v('req1') and comment like '%[Quản trị duyệt tiếp bước sau]%'),
  'Quản trị duyệt tiếp bước 2 (Giám đốc) của cùng hồ sơ → đề xuất đã duyệt');

-- Người thường vẫn bị chặn như trước
select pg_temp.as_user('S_MUA');
select pg_temp.as_api($q$insert into t select 'req2', wf.submit('PR', pg_temp.v('PR-S2'), '', 'NV mua lập')$q$);
select pg_temp.blocked($q$select app.save_pr_line(pg_temp.v('PR-S2'), (select code from master.materials order by code limit 1), 30, null)$q$,
  'Người lập không sửa', 'Người lập (không phải Quản trị) vẫn không sửa chứng từ đang chờ duyệt');
select pg_temp.as_user('S_X');
select pg_temp.as_api($q$select wf.act(pg_temp.v('req2'), 'APPROVE', 'TP Mua đồng ý')$q$);
select pg_temp.blocked($q$select wf.act(pg_temp.v('req2'), 'APPROVE', 'Giám đốc đồng ý')$q$, 'đã duyệt bước trước',
  'Người thường đã duyệt bước trước vẫn không duyệt bước sau khi còn người khác');

-- ================================================================ 3. Bước duyệt trong module
with x as (insert into master.machine_speeds (machine_id, op_code, std_mpm, created_by)
  select id, 'CD1', 100, (select id from core.profiles where employee_code = 'S_ADM') from master.machines order by code limit 1 returning id)
insert into t select 'sp', id from x;
select pg_temp.as_user('S_ADM');
select pg_temp.as_api($q$select app.approve_machine_speed(pg_temp.v('sp'))$q$);
select pg_temp.ok((select status = 'APPROVED' from master.machine_speeds where id = pg_temp.v('sp')), 'Quản trị duyệt tốc độ máy do chính mình nhập');

-- ================================================================ 4. Sửa số tồn, đơn giá, giá bình quân
with x as (insert into inv.lots (lot_no, item_kind, material_id, uom, qc_status)
  select 'LOT-S1', 'MAT', id, uom, 'PASSED' from master.materials order by code limit 1 returning id)
insert into t select 'lot', id from x;
with x as (insert into inv.stock_docs (doc_no, doc_type, status, warehouse_id, review_status, note)
  select 'TD-S1', 'OPENING', 'APPROVED', id, 'NA', 'Tồn đầu thử' from inv.warehouses where code = 'KNL' returning id)
insert into t select 'doc', id from x;
with x as (insert into inv.stock_doc_lines (doc_id, line_no, lot_id, qty, unit_cost) values (pg_temp.v('doc'), 1, pg_temp.v('lot'), 100, 100) returning id)
insert into t select 'line', id from x;
select pg_temp.as_user('S_ADM');
select inv._post(pg_temp.v('doc'));
create temp view knl as select b.qty, v.qty as vqty, v.avg_cost, v.value
  from inv.stock_balances b join inv.warehouses w on w.id = b.warehouse_id and w.code = 'KNL'
  join inv.lots l on l.id = b.lot_id left join cost.item_valuation v on v.warehouse_id = w.id and v.material_id = l.material_id
  where l.lot_no = 'LOT-S1';
grant select on knl to authenticated;
select pg_temp.ok((select qty = 100 and value = 10000 from knl), 'Tồn đầu 100 × 100 đ');

select pg_temp.as_user('S_MUA');
select pg_temp.blocked($q$select app.admin_stock_set((select id from inv.warehouses where code = 'KNL'), pg_temp.v('lot'), null, null, 80, 'thử')$q$,
  'Chỉ Quản trị', 'Người thường không sửa số tồn trực tiếp');
select pg_temp.as_user('S_ADM');
select pg_temp.blocked($q$select app.admin_stock_set((select id from inv.warehouses where code = 'KNL'), pg_temp.v('lot'), null, null, 80, ' ')$q$,
  'lý do', 'Sửa số tồn bắt buộc ghi lý do');
select pg_temp.as_api($q$select app.admin_stock_set((select id from inv.warehouses where code = 'KNL'), pg_temp.v('lot'), null, null, 80, 'Cân lại thực tế 80 kg')$q$);
insert into t select 'adj', id from inv.stock_docs where ref_type = 'ADMIN' and doc_type = 'ADJ' order by created_at desc limit 1;
select pg_temp.ok((select qty = 80 and vqty = 80 and value = 8000 from knl)
  and (select doc_type = 'ADJ' and status = 'POSTED' from inv.stock_docs where id = pg_temp.v('adj'))
  and exists (select 1 from core.audit_log where action = 'ADMIN_STOCK' and new_data ->> 'reason' = 'Cân lại thực tế 80 kg'),
  'Quản trị đặt tồn 100 → 80: phiếu điều chỉnh ghi sổ ngay, giá trị tồn giảm theo giá bình quân, ghi nhật ký');

select pg_temp.as_api($q$select app.admin_line_cost(pg_temp.v('line'), 120, 'Hóa đơn đúng 120 đ')$q$);
select pg_temp.ok((select unit_cost = 120 from inv.stock_doc_lines where id = pg_temp.v('line'))
  and (select bool_and(unit_cost = 120) from inv.stock_moves where doc_line_id = pg_temp.v('line'))
  and (select value = 9600 and avg_cost = 120 from knl),
  'Quản trị sửa đơn giá phiếu đã ghi sổ 100 → 120: sổ cái đổi giá, giá trị 80 kg còn lại = 9.600 đ');

select pg_temp.as_api($q$select app.admin_avg_cost((select id from inv.warehouses where code = 'KNL'), (select code from master.materials order by code limit 1), 150, 'Đánh giá lại')$q$);
select pg_temp.ok((select avg_cost = 150 and value = 12000 from knl), 'Quản trị sửa giá bình quân 150 đ: giá trị tồn = 80 × 150');

-- ================================================================ 5. Sửa đơn mua đã duyệt
with x as (insert into purchase.purchase_orders (po_no, supplier_id, status, created_by)
  select 'PO-S1', id, 'APPROVED', (select id from core.profiles where employee_code = 'S_MUA') from core.partners order by code limit 1 returning id)
insert into t select 'po', id from x;
with x as (insert into purchase.po_lines (po_id, line_no, material_id, qty, unit_price, received_qty)
  select pg_temp.v('po'), 1, id, 10, 500, 5 from master.materials order by code limit 1 returning id)
insert into t select 'pol', id from x;
select pg_temp.blocked($q$select app.admin_po_line(pg_temp.v('pol'), 4, 500, null, 'giảm')$q$, 'Đã nhận', 'Không sửa số lượng nhỏ hơn số đã nhận');
select pg_temp.as_api($q$select app.admin_po_line(pg_temp.v('pol'), 20, 450, null, 'NCC giảm giá')$q$);
select pg_temp.ok((select qty = 20 and unit_price = 450 from purchase.po_lines where id = pg_temp.v('pol'))
  and exists (select 1 from wf.notifications n join core.profiles p on p.id = n.user_id where p.employee_code = 'S_MUA' and n.title = 'Quản trị sửa đơn mua PO-S1'),
  'Quản trị sửa số lượng, đơn giá đơn mua đã duyệt, báo người lập');
select pg_temp.as_user('S_MUA');
select pg_temp.blocked($q$select app.admin_po_line(pg_temp.v('pol'), 30, 450, null, 'thử')$q$, 'Chỉ Quản trị', 'Người thường không sửa đơn mua đã duyệt');

-- ================================================================ 6. Nhật ký, quyền gọi hàm
select pg_temp.as_user('S_ADM');
select pg_temp.ok((select count(*) filter (where action in ('ADMIN_STOCK', 'ADMIN_COST', 'ADMIN_PO')) = 4 from app.admin_overrides(50)),
  'Nhật ký can thiệp của Quản trị có sửa tồn, sửa giá (2), sửa đơn mua');
select pg_temp.ok(not has_function_privilege('anon', 'app.admin_stock_set(uuid,uuid,uuid,uuid,numeric,text)', 'execute')
  and not has_function_privilege('anon', 'app.admin_line_cost(uuid,numeric,text)', 'execute')
  and not has_function_privilege('anon', 'app.admin_avg_cost(uuid,text,numeric,text)', 'execute')
  and not has_function_privilege('anon', 'app.admin_po_line(uuid,numeric,numeric,date,text)', 'execute')
  and not has_function_privilege('authenticated', 'app.admin_log(text,text,text,jsonb,jsonb)', 'execute'),
  'Khách (anon) không gọi được hàm Quản trị; hàm ghi nhật ký chỉ dùng nội bộ');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
