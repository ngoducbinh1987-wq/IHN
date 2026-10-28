-- Kiểm thử migration 20261026005200_po_fg_paper:
--  A. Chủ tịch chốt kế hoạch tháng → MES tự sinh đơn mua (theo NCC ưu tiên) → NV mua kiểm tra, sửa, chia NCC, gửi → TP Mua duyệt
--     (báo Kế toán) → Giám đốc duyệt (ghi giá, NCC vào điều kiện mua) → nhận hàng theo PO; đề xuất mua đã duyệt → đơn mua; hủy đơn.
--  B. Tồn đầu kỳ BTP từng bobin, thành phẩm số cuộn; phiếu hoàn thành đóng gói nhiều cuộn; phiếu nhập kho TP; lệnh giao theo số cuộn
--     (Giám đốc sửa khi duyệt), xuất theo phiếu giấy; phế vào kho phế; đối soát cuối ngày xác nhận phiếu giấy; cảnh báo ngày chưa đối soát.
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK, không để lại dữ liệu.
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
create function pg_temp.uid(p_code text) returns uuid language sql as $$ select id from core.profiles where employee_code = p_code $$;
create function pg_temp.v(p_k text) returns uuid language sql as $$ select v from t where k = p_k $$;
create function pg_temp.today() returns date language sql as $$ select (now() at time zone 'Asia/Ho_Chi_Minh')::date $$;
create function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_msg; end if;
  insert into r(msg) values (p_msg);
end $$;
create function pg_temp.fails(p_sql text, p_pattern text, p_msg text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm ilike '%' || p_pattern || '%' then insert into r(msg) values (p_msg || ' → chặn: ' || sqlerrm); return; end if;
    raise exception 'FAIL: % — lỗi khác mong đợi: %', p_msg, sqlerrm;
  end;
  raise exception 'FAIL: % — lẽ ra phải báo lỗi', p_msg;
end $$;
-- số lượng một vật tư trong một đơn mua
create function pg_temp.poq(p_po uuid, p_code text) returns numeric language sql as $$
  select coalesce(sum(l.qty), 0) from purchase.po_lines l join master.materials m on m.id = l.material_id and m.code = p_code where l.po_id = p_po
$$;
create function pg_temp.req(p_doc uuid) returns uuid language sql as $$
  select id from wf.approval_requests where doc_id = p_doc order by submitted_at desc limit 1
$$;
set client_min_messages = notice;

-- Người dùng thử (tạm khóa tài khoản thật trong giao dịch để kết quả chỉ phụ thuộc người thử)
with u(code, role) as (values ('P_GD','BGD'),('P_CT','BGD'),('P_SXTP','SX_TP'),('P_SXTP','THU_KHO'),('P_MUANV','MUA_NV'),('P_MUATP','MUA_TP'),
  ('P_KT','KT_KHO'),('P_KTGT','KT_GT'),('P_KTT','KTT'),('P_KD','KD_NV'),('P_QC','QC'),('P_VH','VAN_HANH')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from (select distinct code from u) x returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('P_GD','BGD'),('P_CT','BGD'),('P_SXTP','SX_TP'),('P_SXTP','THU_KHO'),('P_MUANV','MUA_NV'),
  ('P_MUATP','MUA_TP'),('P_KT','KT_KHO'),('P_KTGT','KT_GT'),('P_KTT','KTT'),('P_KD','KD_NV'),('P_QC','QC'),('P_VH','VAN_HANH')) u(code, role)
  on u.code = p.employee_code;
update core.profiles set status = 'LOCKED' where (employee_code is null or employee_code !~ '^P_') and status = 'ACTIVE';
-- Kế hoạch tháng: Giám đốc duyệt → Chủ tịch chốt; đơn mua: TP Mua → Giám đốc; tồn đầu kỳ: Kế toán trưởng
update wf.approval_flows set submit_role = null, submit_user_ids = '{}' where doc_type in ('PLAN', 'PR', 'PO', 'DELIVERY');
update wf.approval_steps set enabled = (seq in (1, 2)) where doc_type = 'PLAN';
update wf.approval_steps set assignee_ids = array[pg_temp.uid('P_GD')] where (doc_type = 'PLAN' and seq = 1) or (doc_type = 'PR' and seq = 2) or (doc_type = 'PO' and seq = 2)
   or (doc_type = 'DELIVERY' and role_code = 'BGD');
update wf.approval_steps set assignee_ids = array[pg_temp.uid('P_CT')] where doc_type = 'PLAN' and seq = 2;
update wf.approval_steps set assignee_ids = array[pg_temp.uid('P_MUATP')] where doc_type in ('PR', 'PO') and seq = 1;
update wf.approval_steps set assignee_ids = '{}' where doc_type = 'STOCK_OPEN';
update master.operators set keeps_fg = (code = 'NV3') where code in ('NV1', 'NV2', 'NV3', 'NV4', 'NV5');
do $$ begin
  if (select s.status from master.products p join master.product_specs s on s.id = p.current_spec_id where p.code = 'PFR-2C-1P5') <> 'RELEASED' then
    perform set_config('bmt.wf_release', 'on', true);
    perform master.release_spec((select current_spec_id from master.products where code = 'PFR-2C-1P5'));
  end if;
end $$;
-- NCC ưu tiên cho đồng (vật tư khác chưa có NCC): MES chia đơn mua theo NCC
insert into core.partners (code, name, is_supplier, partner_type) values ('P-NCC-CU', 'NCC đồng thử 5200', true, 'SUPPLIER'), ('P-NCC-PVC', 'NCC nhựa thử 5200', true, 'SUPPLIER');
insert into t select 'sup_cu', id from core.partners where code = 'P-NCC-CU';
insert into t select 'sup_pvc', id from core.partners where code = 'P-NCC-PVC';
delete from master.material_suppliers where material_id = (select id from master.materials where code = 'CU-024') and supplier_id is not null;
update master.material_suppliers set supplier_id = pg_temp.v('sup_cu'), unit_price = 268000, is_preferred = true
 where material_id = (select id from master.materials where code = 'CU-024');
insert into master.material_suppliers (material_id, supplier_id, unit_price, is_preferred, lead_time_days)
select id, pg_temp.v('sup_cu'), 268000, true, 7 from master.materials where code = 'CU-024'
  and not exists (select 1 from master.material_suppliers ms where ms.material_id = master.materials.id);

-- ================================================================ 0. Cấu hình quy trình, menu
select pg_temp.ok((select string_agg(level_label, ' → ' order by seq) from wf.approval_steps where doc_type = 'PO' and enabled)
  = 'TP Mua duyệt đơn mua hàng → Giám đốc duyệt đơn mua hàng'
  and (select notify_roles @> array['KT_KHO', 'KT_GT', 'KTT'] from wf.approval_steps where doc_type = 'PO' and seq = 1)
  and (select submit_label like 'NV mua hàng kiểm tra%' from wf.approval_flows where doc_type = 'PO'),
  'Đơn mua: NV mua kiểm tra, duyệt gửi → TP Mua duyệt (báo Kế toán) → Giám đốc duyệt');
select pg_temp.ok((select string_agg(level_label, ' → ' order by seq) from wf.approval_steps where doc_type = 'DELIVERY' and enabled) = 'Giám đốc duyệt lệnh giao',
  'Lệnh giao: chỉ Giám đốc duyệt');
select pg_temp.ok(exists (select 1 from core.pages where key = 'don-mua' and path = '/don-mua')
  and exists (select 1 from core.role_pages where page_key = 'don-mua' and role_code = 'MUA_NV')
  and exists (select 1 from core.role_pages where page_key = 'don-mua' and role_code = 'KTT'),
  'Menu Đơn mua hàng cho Mua hàng, Kế toán, Ban giám đốc');

-- ================================================================ A1. Chủ tịch chốt kế hoạch → MES tự sinh đơn mua theo NCC
select pg_temp.as_user('P_SXTP');
insert into plan.production_plans (plan_no, period_label, material_need_date) values ('KH-T51', 'Thử 5200', pg_temp.today() + 20);
insert into t select 'plan', id from plan.production_plans where plan_no = 'KH-T51';
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, run_lots, m_per_pack, pack_type, brand)
select pg_temp.v('plan'), p.id, p.current_spec_id, 10000, 1, 500, 'Bobin gỗ', 'KAVIX' from master.products p where p.code = 'PFR-2C-1P5';
insert into t select 'run', plan.run_mrp(pg_temp.v('plan'));
insert into t select 'plan_req', wf.submit('PLAN', pg_temp.v('plan'), 'KH-T51', 'Thử');
select pg_temp.ok(not exists (select 1 from purchase.purchase_orders where plan_id = pg_temp.v('plan')), 'Chưa chốt kế hoạch: chưa sinh đơn mua');
select pg_temp.as_user('P_GD'); select wf.act(pg_temp.v('plan_req'), 'APPROVE');
select pg_temp.ok(not exists (select 1 from purchase.purchase_orders where plan_id = pg_temp.v('plan')), 'Giám đốc duyệt (chưa chốt): chưa sinh đơn mua');
select pg_temp.as_user('P_CT'); select wf.act(pg_temp.v('plan_req'), 'APPROVE');
insert into t select 'po_cu', id from purchase.purchase_orders where plan_id = pg_temp.v('plan') and supplier_id = pg_temp.v('sup_cu');
insert into t select 'po_x', id from purchase.purchase_orders where plan_id = pg_temp.v('plan') and supplier_id is null;
select pg_temp.ok((select count(*) = 2 and bool_and(status = 'DRAFT' and source = 'MRP' and mrp_run_id = pg_temp.v('run'))
                   from purchase.purchase_orders where plan_id = pg_temp.v('plan')),
  'Chủ tịch chốt: MES tự sinh 2 đơn mua nháp (một đơn NCC đồng, một đơn vật tư chưa có NCC)');
select pg_temp.ok((select count(*) = 1 from purchase.po_lines where po_id = pg_temp.v('po_cu'))
  and pg_temp.poq(pg_temp.v('po_cu'), 'CU-024') = (select ml.suggest_qty from plan.mrp_lines ml join master.materials m on m.id = ml.material_id
                                                  where ml.run_id = pg_temp.v('run') and m.code = 'CU-024')
  and (select unit_price = 268000 from purchase.po_lines where po_id = pg_temp.v('po_cu')),
  'Đơn NCC đồng: đúng số MRP đề nghị, giá theo điều kiện mua');
select pg_temp.ok((select sum(l.qty) from purchase.po_lines l join purchase.purchase_orders po on po.id = l.po_id where po.plan_id = pg_temp.v('plan'))
  = (select sum(suggest_qty) from plan.mrp_lines where run_id = pg_temp.v('run')),
  'Tổng các đơn mua = tổng đề nghị mua của MRP');
select pg_temp.ok(exists (select 1 from wf.notifications where user_id = pg_temp.uid('P_MUANV') and title like 'Đơn mua hàng chờ NV mua kiểm tra%'),
  'NV mua nhận thông báo kiểm tra đơn mua');
select pg_temp.as_user('P_MUATP');
select pg_temp.fails($$select app.adjust_mrp_line((select id from plan.mrp_lines where run_id = pg_temp.v('run') and suggest_qty > 0 limit 1), 1, null, null, 'x')$$,
  'đơn mua', 'Đã có đơn mua: khóa kết quả MRP, sửa trên đơn mua');

-- ================================================================ A2. NV mua kiểm tra: NCC, giá, chia đơn, gửi
select pg_temp.as_user('P_VH');
select pg_temp.fails($$select app.po_save_header(pg_temp.v('po_x'), pg_temp.v('sup_pvc'), null, null, null, false)$$, 'NV mua', 'Công nhân không sửa đơn mua');
select pg_temp.as_user('P_KD');
select pg_temp.fails($$select wf.submit('PO', pg_temp.v('po_cu'), 'x')$$, 'quyền gửi duyệt', 'Người ngoài phòng mua không gửi duyệt đơn mua');
select pg_temp.as_user('P_MUANV');
select pg_temp.fails($$select wf.submit('PO', pg_temp.v('po_x'), 'x')$$, 'chọn nhà cung cấp', 'Đơn chưa chọn NCC: không gửi được');
-- Chuyển dòng PVC-FR sang NCC nhựa: MES lập đơn mới cho NCC đó
insert into t select 'po_pvc', app.po_move_lines(pg_temp.v('po_x'), array(select l.id from purchase.po_lines l join master.materials m on m.id = l.material_id
                                                                       where l.po_id = pg_temp.v('po_x') and m.code = 'PVC-FR'), pg_temp.v('sup_pvc'));
select pg_temp.ok((select supplier_id = pg_temp.v('sup_pvc') and status = 'DRAFT' and source = 'MRP' and plan_id = pg_temp.v('plan') from purchase.purchase_orders where id = pg_temp.v('po_pvc'))
  and pg_temp.poq(pg_temp.v('po_pvc'), 'PVC-FR') > 0 and pg_temp.poq(pg_temp.v('po_x'), 'PVC-FR') = 0,
  'Chia đơn: dòng nhựa chuyển sang đơn mới của NCC nhựa, cùng nguồn kế hoạch');
-- NCC mới tạo ngay trên đơn
insert into t select 'sup_new', app.save_supplier('NCC tổng hợp thử 5200', '0109999999', 'Chị B', 'Hà Nội');
select pg_temp.ok((select is_supplier and code like 'NCC-%' from core.partners where id = pg_temp.v('sup_new'))
  and app.save_supplier('ncc tổng hợp thử 5200') = pg_temp.v('sup_new'),
  'NV mua thêm NCC mới (trùng tên thì dùng lại)');
select app.po_save_header(pg_temp.v('po_x'), pg_temp.v('sup_new'), pg_temp.today() + 15, '30 ngày', 'Giao tại kho BMT', false);
select pg_temp.fails($$select wf.submit('PO', pg_temp.v('po_x'), 'x')$$, 'chưa có đơn giá', 'Thiếu đơn giá: không gửi được');
select app.po_save_line(pg_temp.v('po_x'), l.id, null, l.qty, 50000, null, null) from purchase.po_lines l where l.po_id = pg_temp.v('po_x');
select app.po_save_line(pg_temp.v('po_pvc'), l.id, null, l.qty, 32000, null, null) from purchase.po_lines l where l.po_id = pg_temp.v('po_pvc');
select pg_temp.fails($$select app.po_save_line(pg_temp.v('po_cu'), null, 'CU-024', 5, 1, null, null)$$, 'đã có trong đơn', 'Không thêm trùng vật tư trong một đơn');
select app.po_save_line(pg_temp.v('po_cu'), null, 'TALC', 25, 20000, pg_temp.today() + 10, 'Mua kèm');
select pg_temp.ok(pg_temp.poq(pg_temp.v('po_cu'), 'TALC') = 25, 'NV mua thêm dòng vào đơn nháp');
select app.po_delete_line(l.id) from purchase.po_lines l join master.materials m on m.id = l.material_id where l.po_id = pg_temp.v('po_cu') and m.code = 'TALC';
select pg_temp.fails($$select app.po_delete_line((select id from purchase.po_lines where po_id = pg_temp.v('po_cu') limit 1))$$, 'ít nhất một dòng', 'Không bỏ dòng cuối (hủy đơn nếu không mua)');
insert into t select 'po_cu_req', wf.submit('PO', pg_temp.v('po_cu'), 'x', 'Đồng theo KH-T51');
select pg_temp.ok((select status = 'PENDING_APPROVAL' from purchase.purchase_orders where id = pg_temp.v('po_cu'))
  and exists (select 1 from wf.notifications where user_id = pg_temp.uid('P_MUATP') and link = '/duyet/' || pg_temp.v('po_cu_req')),
  'NV mua duyệt gửi: TP Mua nhận đơn chờ duyệt');
select pg_temp.fails($$select app.po_save_line(pg_temp.v('po_cu'), (select id from purchase.po_lines where po_id = pg_temp.v('po_cu') limit 1), null, 1, 1, null, null)$$,
  'Người lập không sửa', 'Đã gửi: NV mua không tự sửa (người duyệt sửa hoặc trả lại)');

-- ================================================================ A3. TP Mua sửa khi duyệt, duyệt → báo Kế toán; Giám đốc duyệt
select pg_temp.as_user('P_MUATP');
select app.po_save_line(pg_temp.v('po_cu'), (select id from purchase.po_lines where po_id = pg_temp.v('po_cu') limit 1), null,
  (select qty + 100 from purchase.po_lines where po_id = pg_temp.v('po_cu') limit 1), 265000, pg_temp.today() + 12, 'Đàm phán lại giá');
select pg_temp.ok(exists (select 1 from wf.approval_actions where request_id = pg_temp.v('po_cu_req') and comment like '[Sửa khi duyệt]%CU-024%265%')
  and (select wf.doc_hash('purchase.purchase_orders', pg_temp.v('po_cu')) = data_hash from wf.approval_requests where id = pg_temp.v('po_cu_req'))
  and exists (select 1 from wf.notifications where user_id = pg_temp.uid('P_MUANV') and title like 'Người duyệt đã sửa%'),
  'TP Mua sửa số lượng, giá khi duyệt: ghi lịch sử duyệt, báo NV mua, mã kiểm vẫn khớp');
select pg_temp.ok(wf.act(pg_temp.v('po_cu_req'), 'APPROVE') = 'PENDING', 'TP Mua duyệt, chuyển Giám đốc');
select pg_temp.ok((select count(distinct user_id) = 3 from wf.notifications where title like '%TP Mua duyệt đơn mua hàng xong, chờ Giám đốc%'
                   and user_id in (pg_temp.uid('P_KT'), pg_temp.uid('P_KTGT'), pg_temp.uid('P_KTT'))),
  'TP Mua duyệt chuyển Giám đốc: Kế toán kho, Kế toán giá thành, Kế toán trưởng nhận thông báo');
select pg_temp.as_user('P_CT');
select pg_temp.fails($$select wf.act(pg_temp.v('po_cu_req'), 'APPROVE')$$, 'cần vai trò', 'Chủ tịch không duyệt đơn mua (bước Giám đốc)');
select pg_temp.as_user('P_GD');
select pg_temp.ok(wf.act(pg_temp.v('po_cu_req'), 'APPROVE') = 'APPROVED', 'Giám đốc duyệt đơn mua');
select pg_temp.ok((select status = 'APPROVED' from purchase.purchase_orders where id = pg_temp.v('po_cu'))
  and (select unit_price = 265000 from master.material_suppliers ms join master.materials m on m.id = ms.material_id
       where m.code = 'CU-024' and ms.supplier_id = pg_temp.v('sup_cu'))
  and exists (select 1 from master.price_history ph join master.materials m on m.id = ph.material_id where m.code = 'CU-024' and ph.price = 265000),
  'Đơn mua đã duyệt: giá mới ghi vào điều kiện mua của vật tư (MRP lần sau dùng) và lịch sử giá');
select pg_temp.ok(exists (select 1 from wf.notifications where user_id = pg_temp.uid('P_SXTP') and title like 'Hàng sắp về theo PO-%')
  and exists (select 1 from wf.notifications where user_id = pg_temp.uid('P_MUANV') and title like 'Đơn mua đã duyệt, gửi NCC%'),
  'Báo thủ kho NVL hàng sắp về, báo NV mua gửi NCC');
-- Nhận hàng theo PO đã duyệt (TP SX kiêm thủ kho NVL)
select pg_temp.as_user('P_SXTP');
insert into t select 'gr', inv.receive_goods(pg_temp.v('po_cu'), null, null, 'PGH-01',
  jsonb_build_array(jsonb_build_object('po_line_id', (select id from purchase.po_lines where po_id = pg_temp.v('po_cu') limit 1),
                                       'units', jsonb_build_array(jsonb_build_object('qty', 100)))));
select pg_temp.ok((select status = 'PARTIAL_RECEIVED' from purchase.purchase_orders where id = pg_temp.v('po_cu'))
  and (select received_qty = 100 from purchase.po_lines where po_id = pg_temp.v('po_cu') limit 1),
  'Nhận hàng theo đơn mua đã duyệt: ghi số đã nhận, đơn chuyển "nhận một phần"');
select pg_temp.fails(format($$select inv.receive_goods(%L, null, null, null, jsonb_build_array(jsonb_build_object('po_line_id', %L, 'units', jsonb_build_array(jsonb_build_object('qty', 999999)))))$$,
  pg_temp.v('po_cu'), (select id from purchase.po_lines where po_id = pg_temp.v('po_cu') limit 1)), 'dung sai', 'Không nhận quá số đơn mua cộng dung sai');
-- MRP chạy lại: đơn nháp tính vào "đã đề xuất", không đề nghị trùng
select pg_temp.as_user('P_SXTP');
insert into t select 'run2', app.plan_run_mrp(pg_temp.v('plan'));
select pg_temp.ok((select ml.requested >= pg_temp.poq(pg_temp.v('po_pvc'), 'PVC-FR') and ml.suggest_qty = 0
                   from plan.mrp_lines ml join master.materials m on m.id = ml.material_id and m.code = 'PVC-FR' where ml.run_id = pg_temp.v('run2')),
  'Chạy lại MRP: đơn mua nháp tính vào "đã đề xuất", không đề nghị mua trùng');

-- ================================================================ A4. Hủy đơn nháp; đề xuất mua đã duyệt → đơn mua
select pg_temp.as_user('P_MUANV');
select pg_temp.fails($$select app.po_cancel(pg_temp.v('po_pvc'), ' ')$$, 'lý do', 'Hủy đơn mua phải có lý do');
select app.po_cancel(pg_temp.v('po_pvc'), 'Dùng tồn kho cũ');
select pg_temp.ok((select status = 'CANCELLED' and cancel_reason = 'Dùng tồn kho cũ' from purchase.purchase_orders where id = pg_temp.v('po_pvc')),
  'NV mua hủy đơn mua nháp có lý do');
insert into t select 'pr', app.create_pr(pg_temp.today() + 10, 'Bổ sung đồng', '[{"material_code":"CU-024","qty":500}]', 'BO_SUNG');
insert into t select 'pr_req', wf.submit('PR', pg_temp.v('pr'), 'x', 'Bổ sung');
select pg_temp.fails($$select app.po_from_pr(pg_temp.v('pr'))$$, 'chưa được Giám đốc duyệt', 'Đề xuất chưa duyệt: chưa lập đơn mua');
select pg_temp.as_user('P_MUATP'); select wf.act(pg_temp.v('pr_req'), 'APPROVE');
select pg_temp.as_user('P_GD');    select wf.act(pg_temp.v('pr_req'), 'APPROVE');
select pg_temp.as_user('P_MUANV');
insert into t select 'po_pr', (app.po_from_pr(pg_temp.v('pr')) -> 'po_ids' ->> 0)::uuid;
select pg_temp.ok((select source = 'PR' and pr_id = pg_temp.v('pr') and supplier_id = pg_temp.v('sup_cu') and status = 'DRAFT' from purchase.purchase_orders where id = pg_temp.v('po_pr'))
  and pg_temp.poq(pg_temp.v('po_pr'), 'CU-024') = 500
  and (select status = 'CLOSED' from purchase.purchase_requests where id = pg_temp.v('pr'))
  and (select ordered_qty = 500 from purchase.pr_lines where pr_id = pg_temp.v('pr')),
  'Đề xuất đã duyệt → NV mua lập đơn mua theo NCC ưu tiên; đề xuất ghi đã lên đơn đủ');
select pg_temp.fails($$select app.po_from_pr(pg_temp.v('pr'))$$, 'lên đơn đủ', 'Không lập đơn trùng từ một đề xuất');
select app.po_cancel(pg_temp.v('po_pr'), 'NCC hết hàng, đặt lại sau');
select pg_temp.ok((select status = 'APPROVED' from purchase.purchase_requests where id = pg_temp.v('pr'))
  and (select ordered_qty = 0 from purchase.pr_lines where pr_id = pg_temp.v('pr')),
  'Hủy đơn lập từ đề xuất: đề xuất trở lại "đã duyệt", lập đơn lại được');
select pg_temp.ok((select count(*) = 4 from app.v_pos where plan_id = pg_temp.v('plan') or pr_id = pg_temp.v('pr'))
  and (select source_label = 'Tự sinh từ MRP' and plan_no = 'KH-T51' and line_count = 1 from app.v_pos where id = pg_temp.v('po_cu')),
  'Danh sách đơn mua: nguồn, kế hoạch, số dòng');
select pg_temp.as_user('P_SXTP');
select pg_temp.ok((select unit_price is null and amount is null and need_qty is not null from app.v_po_lines where po_id = pg_temp.v('po_cu') limit 1),
  'Người không được xem giá thấy dòng đơn mua nhưng không thấy giá');

-- ================================================================ B1. Tồn đầu kỳ: BTP từng bobin, thành phẩm số cuộn × mét
reset role;
insert into inv.carriers (code, carrier_type, tare_kg, owner, status) values ('P951', 'B800', 25, 'BMT', 'EMPTY'), ('P952', 'B800', 25, 'BMT', 'EMPTY');
select pg_temp.as_user('P_KT');
select pg_temp.fails($$select inv.create_opening(inv.wh('KBTP'), pg_temp.today(), '[{"code":"PFR-2C-1P5","stage":"CD5","carrier":"P999","qty":1600,"gross_kg":200}]')$$,
  'số bobin', 'BTP tồn đầu kỳ: bobin phải khai báo ở Kho → Bobin');
select pg_temp.fails($$select inv.create_opening(inv.wh('KBTP'), pg_temp.today(), '[{"code":"PFR-2C-1P5","stage":"CD5","carrier":"P951","qty":1600}]')$$,
  'kg cân', 'BTP tồn đầu kỳ: bắt buộc kg cân');
insert into t select 'op_wip', inv.create_opening(inv.wh('KBTP'), pg_temp.today(),
  '[{"code":"PFR-2C-1P5","stage":"CD5","carrier":"P951","qty":1600,"gross_kg":200},{"code":"PFR-2C-1P5","stage":"CB","carrier":"P952","gross_kg":75}]');
select pg_temp.ok((select count(*) = 2 from inv.stock_doc_lines where doc_id = pg_temp.v('op_wip'))
  and (select h.qty = 1600 and h.gross_kg = 200 and h.tare_kg = 25 and l.wip_stage = 'CV' and l.weight_kg = 175
       from inv.handling_units h join inv.lots l on l.id = h.lot_id join inv.carriers c on c.id = h.carrier_id where c.code = 'P951')
  and (select h.qty > 0 and l.wip_stage = 'CB' from inv.handling_units h join inv.lots l on l.id = h.lot_id join inv.carriers c on c.id = h.carrier_id where c.code = 'P952'),
  'Tồn đầu kỳ BTP: mỗi bobin một dòng, công đoạn, kg (trừ bì), ruột bện ước tính mét từ kg');
select pg_temp.fails($$select inv.create_opening(inv.wh('KBTP'), pg_temp.today(), '[{"code":"PFR-2C-1P5","stage":"CD5","carrier":"P951","qty":10,"gross_kg":30}]')$$,
  'đang chờ duyệt', 'Một bobin không nằm ở hai phiếu tồn đầu kỳ');
insert into t select 'op_fg', inv.create_opening(inv.wh('KTP'), pg_temp.today(),
  '[{"code":"PFR-2C-1P5","brand":"KAVIX","pack_m":500,"coils":4,"pack_type":"Bobin gỗ"},{"code":"PFR-2C-1P5","brand":"KAVIX","pack_m":500,"coils":1,"m_each":60}]');
select pg_temp.ok((select count(*) = 5 from inv.stock_doc_lines where doc_id = pg_temp.v('op_fg'))
  and (select count(*) = 4 from inv.stock_doc_lines dl join inv.handling_units h on h.id = dl.hu_id
       where dl.doc_id = pg_temp.v('op_fg') and h.qty = 500 and h.pack_m = 500 and not h.is_remnant and h.location_id = inv.loc('KTP-A'))
  and (select count(*) = 1 from inv.stock_doc_lines dl join inv.handling_units h on h.id = dl.hu_id where dl.doc_id = pg_temp.v('op_fg') and h.is_remnant),
  'Tồn đầu kỳ thành phẩm: 4 cuộn 500 m vào khu lưu KAVIX, đoạn 60 m là đoạn lẻ');
select pg_temp.as_user('P_KTT');
select wf.act(pg_temp.req(pg_temp.v('op_wip')), 'APPROVE');
select wf.act(pg_temp.req(pg_temp.v('op_fg')), 'APPROVE');
select pg_temp.ok((select status = 'IN_USE' and current_hu_id is not null from inv.carriers where code = 'P951')
  and (select status = 'POSTED' from inv.stock_docs where id = pg_temp.v('op_wip')),
  'Kế toán trưởng duyệt: ghi sổ, bobin BTP chuyển "đang chứa hàng" (lắp được ở phiếu hoàn thành)');

-- ================================================================ B2. Phiếu hoàn thành đóng gói: 3 cuộn × 500 m trên một phiếu
reset role;
insert into mfg.work_orders (wo_no, product_id, spec_id, bom_id, qty_m, m_per_pack, pack_type, brand, status)
select 'LSX-T51', p.id, p.current_spec_id, (select h.id from master.bom_headers h where h.spec_id = p.current_spec_id limit 1), 1500, 500, 'Bobin gỗ', 'KAVIX', 'RELEASED'
from master.products p where p.code = 'PFR-2C-1P5';
insert into t select 'wo', id from mfg.work_orders where wo_no = 'LSX-T51';
insert into mfg.wo_operations (wo_id, op_code, seq, planned_m) select pg_temp.v('wo'), o.code, o.seq, 1500 from master.operations o where o.code in ('CD5', 'CD6');
select pg_temp.as_user('P_KT');
select pg_temp.fails($$select app.record_bobbin(jsonb_build_object('wo_id', pg_temp.v('wo'), 'op_code', 'CD6', 'operator_code', 'NV3', 'gross_kg', 100,
  'ended_at', to_char((now() at time zone 'Asia/Ho_Chi_Minh') - interval '1 hour', 'YYYY-MM-DD"T"HH24:MI'), 'coils', 3, 'm_each', 0, 'inputs', '[{"code":"P951"}]'::jsonb))$$,
  'mét mỗi cuộn', 'Đóng gói nhiều cuộn: bắt buộc mét mỗi cuộn');
create temp table slipres as select app.record_bobbin(jsonb_build_object('wo_id', pg_temp.v('wo'), 'op_code', 'CD6',
  'operator_code', 'NV3', 'gross_kg', 96, 'paper_no', 'PHT-G01',
  'ended_at', to_char((now() at time zone 'Asia/Ho_Chi_Minh') - interval '1 hour', 'YYYY-MM-DD"T"HH24:MI'),
  'coils', 3, 'm_each', 500, 'inputs', '[{"code":"P951","left_kg":10}]'::jsonb, 'scrap_kg', 1.5, 'scrap_reason', 'SC_STARTUP')) as v;
insert into t select 'slip_lot', l.id from slipres x join inv.lots l on l.lot_no = x.v ->> 'lot_no';
select pg_temp.ok((select count(*) = 3 and sum(h.qty) = 1500 and bool_and(h.qty = 500 and h.pack_m = 500 and h.location_id = inv.loc('KTP-QC'))
                   from inv.handling_units h where h.lot_id = pg_temp.v('slip_lot'))
  and (select coils = 3 and qty_m = 1500 from mfg.bobbin_slips where lot_id = pg_temp.v('slip_lot'))
  and (select qc_status = 'PENDING' from inv.lots where id = pg_temp.v('slip_lot')),
  'Một phiếu đóng gói 3 cuộn × 500 m: 3 cuộn thành phẩm ở khu chờ QC, chờ QC');
select pg_temp.ok((select count(*) = 1 from mfg.scrap_records sr join mfg.bobbin_slips s on s.scrap_id = sr.id where s.lot_id = pg_temp.v('slip_lot') and sr.lot_id is null),
  'Phế của phiếu ghi sổ hao hụt, chờ vào kho phế');
reset role;
select inv.scrap_to_stock(pg_temp.today());
select pg_temp.ok((select sr.lot_id is not null from mfg.scrap_records sr join mfg.bobbin_slips s on s.scrap_id = sr.id where s.lot_id = pg_temp.v('slip_lot')),
  'Phế của phiếu hoàn thành vào kho phế (mỗi mã phế một bao/ngày)');
select pg_temp.as_user('P_KT');
select pg_temp.fails(format($$select app.void_bobbin(%L, 'nhập sai')$$, (select id from mfg.bobbin_slips where lot_id = pg_temp.v('slip_lot'))), 'đã nhập kho phế',
  'Phế của phiếu đã vào kho phế: không hủy phiếu (lập biên bản điều chỉnh)');
select pg_temp.as_user('P_QC');
select qa.release_lot(pg_temp.v('slip_lot'), 'PASS', null);

-- ================================================================ B3. Phiếu nhập kho thành phẩm (Kế toán SX nhập từ phiếu giấy người giữ kho TP ký)
select pg_temp.as_user('P_KT');
select pg_temp.ok((select putaway_coils = 3 and store_coils = 4 and free_coils = 4 from app.v_fg_stock
                   where product_code = 'PFR-2C-1P5' and brand = 'KAVIX' and pack_m = 500),
  'Tồn TP theo chủng loại: 3 cuộn QC Đạt chờ nhập kho, 4 cuộn đã lưu kho giao được');
select pg_temp.fails($$select app.fg_putaway('{"keeper_code":"NV1","items":[{"product_code":"PFR-2C-1P5","brand":"KAVIX","pack_m":500,"coils":2}]}')$$,
  'giữ kho thành phẩm', 'Người ký nhập kho TP phải là người giữ kho TP khai báo ở Nhân sự xưởng');
select pg_temp.fails($$select app.fg_putaway('{"keeper_code":"NV3","items":[{"product_code":"PFR-2C-1P5","brand":"KAVIX","pack_m":500,"coils":5}]}')$$,
  'chỉ có 3 cuộn', 'Không nhập kho quá số cuộn QC Đạt đang chờ');
select app.fg_putaway('{"keeper_code":"NV3","paper_no":"NK-01","items":[{"product_code":"PFR-2C-1P5","brand":"KAVIX","pack_m":500,"coils":3}]}');
select pg_temp.ok((select putaway_coils = 0 and store_coils = 7 and free_coils = 7 and store_m = 3500 from app.v_fg_stock
                   where product_code = 'PFR-2C-1P5' and brand = 'KAVIX' and pack_m = 500)
  and (select receiver_code = 'NV3' and paper_no = 'NK-01' from inv.stock_docs where doc_no like 'NKTP-%' order by created_at desc limit 1),
  'Nhập kho TP: 3 cuộn sang khu lưu, tồn giao được 7 cuộn (3.500 m); phiếu ghi người giữ kho ký');

-- ================================================================ B4. Lệnh giao: Giám đốc sửa khi duyệt, xuất theo phiếu giấy
select pg_temp.as_user('P_VH');
select pg_temp.fails($$select app.delivery_save(null, '{"customer_name":"X","items":[{"product_code":"PFR-2C-1P5","brand":"KAVIX","pack_m":500,"coils":1}]}')$$,
  'Kinh doanh hoặc Kế toán SX', 'Công nhân không lập lệnh giao');
select pg_temp.as_user('P_KD');
insert into t select 'dv', app.delivery_save(null, jsonb_build_object('customer_name', 'Đại lý Hòa Bình', 'ship_date', pg_temp.today() + 1,
  'items', jsonb_build_array(jsonb_build_object('product_code', 'PFR-2C-1P5', 'brand', 'KAVIX', 'pack_m', 500, 'coils', 5))));
insert into t select 'dv_req', app.delivery_submit(pg_temp.v('dv'));
select pg_temp.ok((select free_coils = 2 and committed_coils = 5 from app.v_fg_stock where product_code = 'PFR-2C-1P5' and brand = 'KAVIX' and pack_m = 500),
  'Lệnh giao chờ duyệt: 5 cuộn đã hứa giao, còn 2 cuộn giao được');
insert into t select 'dv2', app.delivery_save(null, '{"customer_name":"Khách B","items":[{"product_code":"PFR-2C-1P5","brand":"KAVIX","pack_m":500,"coils":3}]}');
select pg_temp.fails($$select app.delivery_submit(pg_temp.v('dv2'))$$, 'chỉ còn 2 cuộn', 'Lệnh giao sau không lấy cuộn đã hứa cho lệnh trước');
select app.delivery_cancel(pg_temp.v('dv2'), 'Khách đổi ngày');
select pg_temp.ok((select status = 'CANCELLED' from sales.deliveries where id = pg_temp.v('dv2')), 'Hủy lệnh giao nháp có lý do');
select pg_temp.as_user('P_GD');
select app.delivery_save(pg_temp.v('dv'), jsonb_build_object('customer_name', 'Đại lý Hòa Bình', 'ship_date', pg_temp.today(),
  'items', jsonb_build_array(jsonb_build_object('product_code', 'PFR-2C-1P5', 'brand', 'KAVIX', 'pack_m', 500, 'coils', 4))));
select pg_temp.ok(exists (select 1 from wf.approval_actions where request_id = pg_temp.v('dv_req') and comment like '[Sửa khi duyệt]%× 4%')
  and (select summary like '%4 cuộn%' from wf.approval_requests where id = pg_temp.v('dv_req')),
  'Giám đốc sửa số cuộn, ngày giao khi duyệt: ghi lịch sử, báo người lập');
select wf.act(pg_temp.v('dv_req'), 'APPROVE');
select pg_temp.ok(exists (select 1 from wf.notifications where user_id = pg_temp.uid('P_KT') and title like 'Lệnh giao đã duyệt%'), 'Duyệt xong báo Kế toán SX in phiếu xuất');
select pg_temp.as_user('P_KD');
select pg_temp.fails($$select app.delivery_ship(pg_temp.v('dv'), '{"giver_code":"NV3"}')$$, 'Kế toán SX', 'Kinh doanh không tự nhập đã giao');
select pg_temp.as_user('P_KT');
select pg_temp.fails(format($$select app.delivery_ship(%L, %L)$$, pg_temp.v('dv'), jsonb_build_object('giver_code', 'NV3', 'items',
  jsonb_build_array(jsonb_build_object('item_id', (select id from sales.delivery_items where delivery_id = pg_temp.v('dv')), 'coils', 5)))),
  'từ 0 đến 4', 'Không xuất quá số cuộn lệnh giao');
select app.delivery_ship(pg_temp.v('dv'), jsonb_build_object('giver_code', 'NV3', 'paper_no', 'PX-T51', 'items',
  jsonb_build_array(jsonb_build_object('item_id', (select id from sales.delivery_items where delivery_id = pg_temp.v('dv')), 'coils', 3))));
select pg_temp.ok((select status = 'SHIPPED' and giver_code = 'NV3' from sales.deliveries where id = pg_temp.v('dv'))
  and (select shipped_coils = 3 and shipped_m = 1500 from sales.delivery_items where delivery_id = pg_temp.v('dv'))
  and (select count(*) = 3 from sales.delivery_lines dl join inv.lots l on l.id = dl.lot_id where dl.delivery_id = pg_temp.v('dv') and l.attrs ? 'opening'),
  'Xuất 3/4 cuộn theo phiếu giấy: MES chọn cuộn lô cũ trước (tồn đầu kỳ), không cần quét QR');
select pg_temp.ok(exists (select 1 from wf.notifications where user_id = pg_temp.uid('P_GD') and title like 'Đã xuất giao%' and body like '%Giao thiếu%3/4%'),
  'Giao thiếu: Giám đốc được báo');
select pg_temp.ok((select free_coils = 4 and committed_coils = 0 from app.v_fg_stock where product_code = 'PFR-2C-1P5' and brand = 'KAVIX' and pack_m = 500),
  'Sau khi xuất: còn 4 cuộn giao được, không còn cuộn hứa giao');

-- ================================================================ B5. Cắt cuộn, hàng khách trả theo phiếu giấy
select app.fg_split(jsonb_build_object('hu_id', (select h.id from inv.handling_units h where h.lot_id = pg_temp.v('slip_lot') and h.status = 'ACTIVE' order by h.hu_no limit 1),
  'parts', jsonb_build_array(200), 'reason', 'Khách cần 200 m', 'keeper_code', 'NV3', 'paper_no', 'CC-01'));
select pg_temp.ok((select count(*) = 1 from app.v_fg_stock where product_code = 'PFR-2C-1P5' and brand = 'KAVIX' and pack_m is null and store_coils = 3 and store_m = 560)
  and (select free_coils = 3 from app.v_fg_stock where product_code = 'PFR-2C-1P5' and brand = 'KAVIX' and pack_m = 500),
  'Cắt cuộn 500 m: còn 3 cuộn đủ quy cách; đoạn 200 m, phần còn 300 m, đoạn lẻ 60 m tính là cuộn lẻ');
select app.fg_customer_return(jsonb_build_object('product_id', (select id from master.products where code = 'PFR-2C-1P5'), 'brand', 'KAVIX', 'qty_m', 120,
  'note', 'Khách trả lỗi vỏ', 'keeper_code', 'NV3', 'paper_no', 'TL-01'));
select pg_temp.ok((select hold_coils >= 1 from app.v_fg_stock where product_code = 'PFR-2C-1P5' and brand = 'KAVIX' and pack_m is null),
  'Hàng khách trả vào khu cách ly, không tính vào tồn giao được');

-- ================================================================ B6. Phế vào kho phế; đối soát cuối ngày; cảnh báo ngày chưa đối soát
reset role;
update inv.stock_docs set doc_date = pg_temp.today() - 1 where ref_id = pg_temp.v('dv') and doc_type = 'SALE';
-- phế cả ca ghi trên báo cáo ca (chưa vào kho)
insert into mfg.scrap_records (wo_op_id, scrap_material_id, reason_code, qty_kg, recorded_at)
select (select id from mfg.wo_operations where wo_id = pg_temp.v('wo') and op_code = 'CD5'), (select id from master.materials where code = 'PL-PVC'), 'SC_STARTUP', 2.4, now();
select inv.daily_alerts();
select pg_temp.ok(exists (select 1 from wf.notifications where user_id = pg_temp.uid('P_GD') and title = 'Ngày ' || to_char(pg_temp.today() - 1, 'DD/MM') || ' chưa đối soát kho')
  and not exists (select 1 from wf.notifications where user_id = pg_temp.uid('P_GD') and title like 'Phiếu kho chưa được Kế toán SX duyệt%'),
  'Phiếu giấy chưa đối soát: một cảnh báo cho cả ngày, không cảnh báo từng phiếu');
select pg_temp.as_user('P_SXTP');
select app.send_daily_report(pg_temp.today());
select pg_temp.ok((select count(*) > 0 from inv.stock_docs where review_status = 'PENDING' and doc_date <= pg_temp.today() and inv.is_recon_doc(created_by)),
  'TP SX gửi báo cáo ngày: chưa xác nhận phiếu giấy (chỉ Kế toán SX đối soát)');
select pg_temp.ok(not exists (select 1 from mfg.scrap_records where lot_id is null and qty_kg = 2.4)
  and (select h.qty >= 2.4 from inv.handling_units h join inv.lots l on l.id = h.lot_id where l.lot_no = 'PL-PVC-' || to_char(pg_temp.today(), 'YYMMDD')),
  'Gửi báo cáo ngày: phế còn lại (báo cáo ca) tự nhập kho phế, giá trị 0');
select pg_temp.as_user('P_KT');
select pg_temp.ok((select (app.send_daily_report(pg_temp.today()) ->> 'confirmed_docs')::int >= 3), 'Kế toán SX đối soát xong, gửi báo cáo ngày: xác nhận các phiếu mình nhập từ giấy');
select pg_temp.ok(not exists (select 1 from inv.stock_docs where review_status = 'PENDING' and doc_date <= pg_temp.today() and inv.is_recon_doc(created_by))
  and (select review_status = 'CONFIRMED' and review_note like 'Đối soát cuối ngày%' from inv.stock_docs where ref_id = pg_temp.v('dv') and doc_type = 'SALE'),
  'Phiếu xuất NVL/thành phẩm/nhập TP do Kế toán SX nhập đã xác nhận, không còn kẹt chờ duyệt');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
