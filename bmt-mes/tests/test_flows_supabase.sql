-- Bản chạy được trong Supabase SQL Editor / MCP execute_sql (không cần psql).
-- Kết quả trả về dưới dạng "lỗi" KET_QUA_OK để buộc ROLLBACK: không để lại dữ liệu. Có dòng FAIL nghĩa là có kiểm tra hỏng.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
grant all on r to authenticated;
grant usage on sequence r_n_seq to authenticated;

-- ---------------------------------------------------------------- tiện ích kiểm thử
create function pg_temp.as_user(p_code text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', (select id::text from core.profiles where employee_code = p_code), true)
$$;
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
set client_min_messages = notice;

-- ---------------------------------------------------------------- người dùng kiểm thử
with u(code, role) as (values ('U_KTNV','KT_NV'),('U_QC','QC'),('U_KTTP','KT_TP'),('U_BGD','BGD'),('U_SXKH','SX_KH'),
  ('U_SXTP','SX_TP'),('U_MUANV','MUA_NV'),('U_MUATP','MUA_TP'),('U_KHO','THU_KHO'),('U_KTKHO','KT_KHO'),
  ('U_KDNV','KD_NV'),('U_KDTP','KD_TP'),('U_VH','VAN_HANH'),('U_TT','TO_TRUONG'),('U_KTGT','KT_GT'),('U_CT','BGD')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select ins.id, upper(split_part(ins.email, '@', 1)), 'Test ' || split_part(ins.email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('U_KTNV','KT_NV'),('U_QC','QC'),('U_KTTP','KT_TP'),('U_BGD','BGD'),
  ('U_SXKH','SX_KH'),('U_SXTP','SX_TP'),('U_MUANV','MUA_NV'),('U_MUATP','MUA_TP'),('U_KHO','THU_KHO'),('U_KTKHO','KT_KHO'),
  ('U_KDNV','KD_NV'),('U_KDTP','KD_TP'),('U_VH','VAN_HANH'),('U_TT','TO_TRUONG'),('U_KTGT','KT_GT'),('U_CT','BGD')) u(code, role) on u.code = p.employee_code;

create temp table t (k text primary key, v uuid);
grant all on t to authenticated;
-- Bước "Chủ tịch HĐQT" giao cho người dùng thử U_CT
update wf.approval_steps set assignee_ids = array[(select id from core.profiles where employee_code = 'U_CT')]
 where (doc_type = 'PLAN' and seq = 2) or (doc_type = 'PO' and seq = 3);
-- Chạy trên dữ liệu thật: tạm ngưng tài khoản thật để kết quả chỉ phụ thuộc người dùng thử (rollback ở cuối)
update core.profiles set status = 'INACTIVE' where coalesce(employee_code, '') not like 'U\_%';

-- Spec nháp để kiểm thử: DB mới thì dùng bản hiện hành (còn nháp); DB thật (spec đã phát hành) thì mở phiên bản mới
create function pg_temp.draft_spec(p_code text) returns uuid language plpgsql as $$
declare v uuid; v_status text;
begin
  select s.id, s.status into v, v_status from master.products p join master.product_specs s on s.id = p.current_spec_id where p.code = p_code;
  if v_status = 'RELEASED' then
    perform set_config('request.jwt.claim.sub', (select id::text from core.profiles where employee_code = 'U_KTTP'), true);
    v := master.new_spec_version(v, 'MAJOR');
  end if;
  return v;
end $$;
insert into t select 'spec_pfr', pg_temp.draft_spec('PFR-2C-1P5');
insert into t select 'spec_sfr', pg_temp.draft_spec('SFR-2P-1');

-- ================================================================ 1. Phát hành spec mã mới (TP KT/QA lập → Quản lý SX xác nhận → Giám đốc phát hành)
select pg_temp.as_user('U_KTNV');
select pg_temp.fails($$select wf.submit('SPEC_NEW', (select v from t where k = 'spec_pfr'), 'SPEC PFR-2C-1P5')$$,
  'cần vai trò', 'Chỉ TP Kỹ thuật/QA được lập spec gửi duyệt');
select pg_temp.as_user('U_KTTP');
insert into t select 'req_spec', wf.submit('SPEC_NEW', (select v from t where k = 'spec_pfr'), 'SPEC PFR-2C-1P5', 'Phát hành spec');
select pg_temp.ok((select status from master.product_specs where id = (select v from t where k='spec_pfr')) = 'PENDING_APPROVAL', 'Gửi duyệt: spec chuyển Chờ duyệt');
select pg_temp.ok((select jsonb_array_length(flow_snapshot -> 'steps') from wf.approval_requests where id = (select v from t where k='req_spec')) = 2,
  'Spec mã mới: 2 bước (Quản lý SX xác nhận → Giám đốc phát hành)');
select pg_temp.as_user('U_QC');
select pg_temp.fails($$select wf.act((select v from t where k='req_spec'), 'APPROVE')$$, 'cần vai trò', 'QC không duyệt thay bước Quản lý SX');
select pg_temp.as_user('U_SXTP');
select pg_temp.fails($$select wf.act((select v from t where k='req_spec'), 'REJECT', '')$$, 'Nhập lý do', 'Trả lại bắt buộc có lý do');
select wf.act((select v from t where k='req_spec'), 'APPROVE', 'Sản xuất được');
select pg_temp.as_user('U_BGD');   select wf.act((select v from t where k='req_spec'), 'APPROVE');
select pg_temp.ok((select status from master.product_specs where id = (select v from t where k='spec_pfr')) = 'RELEASED', 'BGĐ phê duyệt: spec Đã phát hành');
select pg_temp.ok((select status from master.bom_headers where spec_id = (select v from t where k='spec_pfr')) = 'RELEASED', 'BOM phát hành cùng spec');
select pg_temp.fails($$update master.product_specs set ins_thickness_mm = 0.7 where id = (select v from t where k='spec_pfr')$$, 'đã phát hành', 'Không sửa trực tiếp spec đã phát hành');
select pg_temp.fails($$update master.bom_lines set qty_per_basis = 1 where bom_id = (select id from master.bom_headers where spec_id = (select v from t where k='spec_pfr'))$$, 'BOM đã phát hành', 'Không sửa BOM đã phát hành');
select pg_temp.fails($$update master.product_specs set status = 'RELEASED' where id = (select v from t where k = 'spec_sfr')$$, 'luồng duyệt', 'Không phát hành spec ngoài luồng duyệt');
select pg_temp.fails($$select master.release_spec((select v from t where k = 'spec_sfr'))$$, 'qua quy trình duyệt', 'Không gọi thẳng hàm phát hành spec');
select pg_temp.as_user('U_KTTP');
select pg_temp.fails($$select wf.submit('SPEC_NEW', (select v from t where k = 'spec_sfr'), 'SPEC SFR-2P-1')$$, 'Rdc', 'SFR-2P-1 Rdc vượt: chặn gửi duyệt');
-- Phiên bản mới từ spec đã phát hành
select pg_temp.as_user('U_KTNV');
insert into t select 'spec_v2', master.new_spec_version((select v from t where k='spec_pfr'), 'MINOR');
select pg_temp.ok((select version from master.product_specs where id = (select v from t where k='spec_v2'))
                  = (select version + 1 from master.product_specs where id = (select v from t where k='spec_pfr'))
  and (select count(*) from master.bom_lines l join master.bom_headers h on h.id = l.bom_id where h.spec_id = (select v from t where k='spec_v2'))
    = (select count(*) from master.bom_lines l join master.bom_headers h on h.id = l.bom_id where h.spec_id = (select v from t where k='spec_pfr'))
  and (select change_level from master.product_specs where id = (select v from t where k='spec_v2')) = 'MAJOR',
  'Tạo spec v2 sao chép đủ BOM, luôn là thay đổi đầy đủ (không còn thay đổi nhỏ)');
select pg_temp.fails($$select master.new_spec_version((select v from t where k='spec_pfr'), 'MAJOR')$$, 'đang có phiên bản nháp', 'Không mở thêm phiên bản khi đang có bản nháp');

-- ================================================================ 2. Bỏ quy trình Spec thay đổi nhỏ
select pg_temp.as_user('U_KTTP');
select pg_temp.fails($$select wf.submit('SPEC_MINOR', (select current_spec_id from master.products where code = 'SIF-1C-1P5'), 'SPEC SIF-1C-1P5 v1')$$,
  'ngưng sử dụng', 'Quy trình Spec thay đổi nhỏ đã bỏ');

-- ================================================================ 3. Kế hoạch chính thức + MRP + PR
select pg_temp.as_user('U_MUATP');
update master.material_suppliers set unit_price = 268000, lead_time_days = 14
 where material_id = (select id from master.materials where code = 'CU-024');
select pg_temp.as_user('U_SXKH');
insert into plan.production_plans (plan_no, period_label, material_need_date) values ('KH-2611-01', 'Tháng 11/2026', current_date + 30);
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, run_lots, m_per_pack, pack_type, brand)
select pp.id, p.id, p.current_spec_id, 3500, 1, 500, 'Bobin gỗ', 'KAVIX' from plan.production_plans pp, master.products p
 where pp.plan_no = 'KH-2611-01' and p.code = 'PFR-2C-1P5';
insert into t select 'run1', plan.run_mrp((select id from plan.production_plans where plan_no = 'KH-2611-01'));
select pg_temp.ok((select suggest_qty = 100 and status = 'Đặt hàng' from plan.mrp_lines l join master.materials m on m.id = l.material_id
  where run_id = (select v from t where k='run1') and m.code = 'CU-024'), 'MRP: CU-024 cần 87,85 kg → đề nghị 100 kg (bội số 100), có giá + lead time');
select pg_temp.ok((select status from plan.mrp_lines l join master.materials m on m.id = l.material_id
  where run_id = (select v from t where k='run1') and m.code = 'PVC-FR') = 'Cập nhật giá', 'MRP: giá trống không tính là 0');
select pg_temp.ok((select budget_vnd from plan.mrp_runs where id = (select v from t where k='run1')) = 26800000, 'MRP: ngân sách chỉ cộng dòng có giá');
insert into plan.production_plans (plan_no, period_label) values ('KH-SFR', 'Thử');
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, run_lots, m_per_pack, pack_type, brand)
select pp.id, p.id, (select v from t where k = 'spec_sfr'), 1000, 1, 500, 'Bobin gỗ', 'KAVIX' from plan.production_plans pp, master.products p
 where pp.plan_no = 'KH-SFR' and p.code = 'SFR-2P-1';
select pg_temp.fails($$select plan.run_mrp((select id from plan.production_plans where plan_no = 'KH-SFR'))$$, 'Spec chưa phát hành', 'MRP chính thức chặn spec chưa phát hành');
select pg_temp.fails($$select wf.submit('PLAN', (select id from plan.production_plans where plan_no = 'KH-2611-01'), 'KH-2611-01')$$,
  'cần vai trò', 'Chỉ Giám đốc gửi duyệt kế hoạch tháng');
select pg_temp.fails($$select plan.create_pr_from_mrp((select v from t where k='run1'))$$, 'được phê duyệt', 'Chưa duyệt kế hoạch thì không sinh PR');
select pg_temp.as_user('U_BGD');
insert into t select 'req_plan', wf.submit('PLAN', (select id from plan.production_plans where plan_no = 'KH-2611-01'), 'KH-2611-01');
select pg_temp.as_user('U_SXTP'); select wf.act((select v from t where k='req_plan'), 'APPROVE', 'Đủ năng lực');
select pg_temp.as_user('U_BGD');
select pg_temp.fails($$select wf.act((select v from t where k='req_plan'), 'APPROVE')$$, 'cần vai trò', 'Bước Chủ tịch HĐQT: Giám đốc không duyệt thay');
select pg_temp.as_user('U_CT');   select wf.act((select v from t where k='req_plan'), 'APPROVE');
select pg_temp.ok((select status from plan.production_plans where plan_no = 'KH-2611-01') = 'APPROVED', 'Kế hoạch tháng: Giám đốc lập → Quản lý SX xác nhận → Chủ tịch HĐQT phê duyệt');
select pg_temp.as_user('U_SXKH');
insert into t select 'pr1', plan.create_pr_from_mrp((select v from t where k='run1'));
select pg_temp.ok((select count(*) from purchase.pr_lines where pr_id = (select v from t where k='pr1')) > 5, 'Sinh PR từ MRP sau khi BGĐ duyệt kế hoạch');

-- ================================================================ 4. PO + kiểm tra sửa sau khi gửi duyệt
select pg_temp.as_user('U_MUANV');
insert into core.partners (code, name, is_supplier, partner_type) values ('NCC-CU-01', 'NCC đồng (thử)', true, 'SUPPLIER');
insert into purchase.purchase_orders (po_no, supplier_id, expected_date)
select 'PO-T1', id, current_date + 10 from core.partners where code = 'NCC-CU-01';
insert into purchase.po_lines (po_id, line_no, material_id, qty, unit_price)
select po.id, 1, m.id, 1000, 268000 from purchase.purchase_orders po, master.materials m where po.po_no = 'PO-T1' and m.code = 'CU-024';
insert into t select 'req_po', wf.submit('PO', (select id from purchase.purchase_orders where po_no = 'PO-T1'), 'PO-T1');
update purchase.purchase_orders set note = 'sửa sau khi gửi' where po_no = 'PO-T1';
select pg_temp.as_user('U_MUATP');
select pg_temp.fails($$select wf.act((select v from t where k='req_po'), 'APPROVE')$$, 'bị sửa sau khi gửi duyệt', 'Phát hiện chứng từ bị sửa sau khi gửi duyệt');
update wf.approval_requests set status = 'CANCELLED' where id = (select v from t where k='req_po');
select pg_temp.as_user('U_MUANV');
insert into t select 'req_po2', wf.submit('PO', (select id from purchase.purchase_orders where po_no = 'PO-T1'), 'PO-T1');
select pg_temp.ok((select jsonb_array_length(flow_snapshot -> 'steps') = 3 and (flow_snapshot #>> '{facts,amount}')::numeric = 268000000
  from wf.approval_requests where id = (select v from t where k='req_po2')), 'PO 268 triệu: 3 bước (TP mua → Giám đốc → Chủ tịch HĐQT)');
select pg_temp.as_user('U_MUATP'); select wf.act((select v from t where k='req_po2'), 'APPROVE');
select pg_temp.as_user('U_BGD');   select wf.act((select v from t where k='req_po2'), 'APPROVE');
select pg_temp.ok((select status from purchase.purchase_orders where po_no = 'PO-T1') = 'PENDING_APPROVAL', 'PO trên 200 triệu còn chờ Chủ tịch HĐQT');
select pg_temp.as_user('U_CT');    select wf.act((select v from t where k='req_po2'), 'APPROVE');
select pg_temp.ok((select status from purchase.purchase_orders where po_no = 'PO-T1') = 'APPROVED', 'PO qua TP mua + Giám đốc + Chủ tịch HĐQT');

-- ================================================================ 5a. Lệnh SX (phiếu xuất NVL phải gắn lệnh SX)
select pg_temp.as_user('U_SXKH');
insert into mfg.work_orders (wo_no, product_id, spec_id, bom_id, qty_m, m_per_pack, pack_type, brand)
select 'LSX-T1', p.id, p.current_spec_id, h.id, 3500, 500, 'Bobin gỗ', 'KAVIX'
from master.products p join master.bom_headers h on h.spec_id = p.current_spec_id where p.code = 'PFR-2C-1P5';
insert into t select 'req_wo', wf.submit('WO_RELEASE', (select id from mfg.work_orders where wo_no = 'LSX-T1'), 'LSX-T1');
select pg_temp.as_user('U_SXTP'); select wf.act((select v from t where k='req_wo'), 'APPROVE');
select pg_temp.ok((select status from mfg.work_orders where wo_no = 'LSX-T1') = 'RELEASED'
  and (select count(*) from mfg.wo_operations o join mfg.work_orders w on w.id = o.wo_id where w.wo_no = 'LSX-T1') = 6,
  'Phát lệnh: tạo 6 công đoạn theo routing PFR');

-- ================================================================ 5. Nhập kho + bình quân gia quyền di động
select pg_temp.as_user('U_KHO');
insert into inv.lots (lot_no, item_kind, material_id, uom, supplier_lot)
select x, 'MAT', id, 'kg', 'NCC-' || x from master.materials, (values ('CU24-T1'), ('CU24-T2')) v(x) where code = 'CU-024';
insert into inv.stock_docs (doc_no, doc_type, warehouse_id, ref_type) select d, 'GR', id, 'PO' from inv.warehouses, (values ('GR-T1'),('GR-T2')) v(d) where code = 'KNL';
insert into inv.stock_doc_lines (doc_id, line_no, lot_id, qty, unit_cost)
select (select id from inv.stock_docs where doc_no = 'GR-T1'), 1, id, 600, 268000 from inv.lots where lot_no = 'CU24-T1'
union all select (select id from inv.stock_docs where doc_no = 'GR-T2'), 1, id, 400, 280000 from inv.lots where lot_no = 'CU24-T2';
select inv.post_doc(id) from inv.stock_docs where doc_no in ('GR-T1','GR-T2') order by doc_no;
select pg_temp.ok((select avg_cost from cost.item_valuation v join master.materials m on m.id = v.material_id where m.code = 'CU-024') = 272800,
  'Bình quân di động: (600×268.000 + 400×280.000)/1.000 = 272.800');
insert into inv.stock_docs (doc_no, doc_type, warehouse_id, ref_type, ref_id)
select 'IS-T1', 'ISSUE_WO', id, 'WO', (select id from mfg.work_orders where wo_no = 'LSX-T1') from inv.warehouses where code = 'KNL';
insert into inv.stock_doc_lines (doc_id, line_no, lot_id, qty) select (select id from inv.stock_docs where doc_no = 'IS-T1'), 1, id, 100 from inv.lots where lot_no = 'CU24-T1';
select pg_temp.fails($$select inv.post_doc((select id from inv.stock_docs where doc_no = 'IS-T1'))$$, 'Vượt định mức', 'Xuất 100 kg đồng vượt định mức LSX bị chặn');
select pg_temp.fails($$select wf.submit('EXTRA_ISSUE', (select id from inv.stock_docs where doc_no = 'IS-T1'), 'IS-T1')$$, 'Không tìm thấy phiếu lĩnh bổ sung',
  'Cấp vượt định mức phải lập phiếu lĩnh bổ sung, không gửi duyệt thẳng phiếu xuất');
select pg_temp.as_user('U_SXTP');
insert into t select 'req_extra', inv.create_extra_requisition((select id from mfg.work_orders where wo_no = 'LSX-T1'), '[{"material_code":"CU-024","qty":100}]', 'EX_SCRAP', 'Cấp bù đồng');
select pg_temp.fails($$select wf.act((select id from wf.approval_requests where doc_id = (select v from t where k='req_extra')), 'APPROVE')$$, 'cần vai trò', 'Quản lý SX không duyệt cấp vượt định mức');
select pg_temp.as_user('U_KTTP'); select wf.act((select id from wf.approval_requests where doc_id = (select v from t where k='req_extra')), 'APPROVE');
update inv.stock_docs set requisition_id = (select v from t where k = 'req_extra') where doc_no = 'IS-T1';
select pg_temp.as_user('U_KHO');
select pg_temp.fails($$select inv.post_doc((select id from inv.stock_docs where doc_no = 'IS-T1'))$$, 'chưa đạt QC', 'Lô Chờ QC không được xuất SX');
select pg_temp.as_user('U_QC');
update inv.lots set qc_status = 'PASSED' where lot_no = 'CU24-T1';
select pg_temp.as_user('U_KHO');
select inv.post_doc((select id from inv.stock_docs where doc_no = 'IS-T1'));
select pg_temp.ok((select unit_cost from inv.stock_moves where doc_id = (select id from inv.stock_docs where doc_no = 'IS-T1')) = 272800,
  'Xuất SX lấy giá bình quân tại thời điểm xuất');
select pg_temp.ok((select qty = 900 and value = 245520000 from cost.item_valuation v join master.materials m on m.id = v.material_id where m.code = 'CU-024'),
  'Giá trị tồn sau xuất = 900 × 272.800');
insert into inv.stock_docs (doc_no, doc_type, warehouse_id) select 'IS-T2', 'RETURN_SUP', id from inv.warehouses where code = 'KNL';
insert into inv.stock_doc_lines (doc_id, line_no, lot_id, qty) select (select id from inv.stock_docs where doc_no = 'IS-T2'), 1, id, 1000 from inv.lots where lot_no = 'CU24-T1';
select pg_temp.fails($$select inv.post_doc((select id from inv.stock_docs where doc_no = 'IS-T2'))$$, 'Không đủ tồn', 'Không xuất quá tồn lô');
select pg_temp.ok((select available = 500 and in_quality = 400 from inv.v_material_availability where code = 'CU-024'),
  'Tồn khả dụng chỉ tính lô Đạt (500), lô Chờ QC hiển thị riêng (400)');
-- Phế liệu: giá trị 0
insert into inv.lots (lot_no, item_kind, material_id, uom) select 'PL-CU-T1', 'SCRAP', id, 'kg' from master.materials where code = 'PL-CU';
insert into inv.stock_docs (doc_no, doc_type, warehouse_id) select 'SC-T1', 'SCRAP_IN', id from inv.warehouses where code = 'KPL';
insert into inv.stock_doc_lines (doc_id, line_no, lot_id, qty, unit_cost) select (select id from inv.stock_docs where doc_no = 'SC-T1'), 1, id, 12.4, 99999 from inv.lots where lot_no = 'PL-CU-T1';
select inv.post_doc((select id from inv.stock_docs where doc_no = 'SC-T1'));
select pg_temp.ok((select unit_cost from inv.stock_moves where doc_id = (select id from inv.stock_docs where doc_no = 'SC-T1')) = 0, 'Phế nhập kho phế liệu với giá trị 0');
insert into inv.stock_docs (doc_no, doc_type, warehouse_id) select 'ADJ-T1', 'ADJ', id from inv.warehouses where code = 'KNL';
select pg_temp.fails($$select inv.post_doc((select id from inv.stock_docs where doc_no = 'ADJ-T1'))$$, 'cần được phê duyệt','Điều chỉnh kiểm kê phải được phê duyệt trước khi ghi sổ');
select pg_temp.ok((select count(*) from integ.sync_queue where entity = 'STOCK_DOC') = 3, 'Phiếu nhập mua + xuất SX được đưa vào hàng đợi MISA');

-- ================================================================ 6. Lệnh SX + truy xuất
select pg_temp.as_user('U_SXKH');
insert into mfg.work_orders (wo_no, product_id, spec_id, bom_id, qty_m, m_per_pack, pack_type, brand)
select 'LSX-T2', p.id, h.spec_id, h.id, 1000, 500, 'Bobin gỗ', 'KAVIX'
from master.products p join master.bom_headers h on h.spec_id = (select v from t where k = 'spec_sfr') where p.code = 'SFR-2P-1';
select pg_temp.fails($$select mfg.release_wo((select id from mfg.work_orders where wo_no = 'LSX-T2'))$$, 'qua quy trình duyệt', 'Kế hoạch SX không tự phát lệnh ngoài quy trình');
select pg_temp.as_user('U_SXTP');
select pg_temp.fails($$select mfg.release_wo((select id from mfg.work_orders where wo_no = 'LSX-T2'))$$, 'spec chưa phát hành', 'Chặn phát lệnh SX khi spec chưa phát hành');

select pg_temp.as_user('U_TT');
create function pg_temp.op(p_code text) returns uuid language sql as $$
  select o.id from mfg.wo_operations o join mfg.work_orders w on w.id = o.wo_id where w.wo_no = 'LSX-T1' and o.op_code = p_code $$;
insert into t select 'cb', mfg.record_output(pg_temp.op('CD1'), 'CB-T1', 7200, 89.2, jsonb_build_array(jsonb_build_object('lot_id', (select id from inv.lots where lot_no = 'CU24-T1'), 'qty', 100)));
insert into t select 'lbn', mfg.record_output(pg_temp.op('CD2'), 'LB-T1N', 3600, null, jsonb_build_array(jsonb_build_object('lot_id', (select v from t where k='cb'), 'qty', 3600)), 'Nâu');
insert into t select 'lbt', mfg.record_output(pg_temp.op('CD2'), 'LB-T1T', 3600, null, jsonb_build_array(jsonb_build_object('lot_id', (select v from t where k='cb'), 'qty', 3600)), 'Trắng');
insert into t select 'bl', mfg.record_output(pg_temp.op('CD3'), 'BL-T1', 3500, null, jsonb_build_array(
  jsonb_build_object('lot_id', (select v from t where k='lbn'), 'qty', 3500), jsonb_build_object('lot_id', (select v from t where k='lbt'), 'qty', 3500)));
insert into t select 'cv', mfg.record_output(pg_temp.op('CD5'), 'CV-T1', 3500, null, jsonb_build_array(jsonb_build_object('lot_id', (select v from t where k='bl'), 'qty', 3500)));
insert into t select 'bb', mfg.record_output(pg_temp.op('CD6'), 'BB-T1-001', 500, 31.2, jsonb_build_array(jsonb_build_object('lot_id', (select v from t where k='cv'), 'qty', 500)));
select pg_temp.ok((select item_kind = 'FG' and qc_status = 'PENDING' from inv.lots where lot_no = 'BB-T1-001'), 'Bobin TP tạo ở CĐ6, trạng thái Chờ QC');
select pg_temp.ok(exists (select 1 from mfg.trace_back((select v from t where k='bb')) where lot_no = 'CU24-T1' and depth = 5),
  'Truy xuất ngược: bobin → bó lõi → lõi bọc → lõi đồng → lô CU24-T1 (độ sâu 5)');
select pg_temp.ok(exists (select 1 from mfg.trace_forward((select id from inv.lots where lot_no = 'CU24-T1')) where lot_no = 'BB-T1-001'),
  'Truy xuất xuôi: lô đồng → bobin bị ảnh hưởng');

-- ================================================================ 7. SO: duyệt, ATP, giữ hàng
select pg_temp.as_user('U_QC');
update inv.lots set qc_status = 'PASSED' where lot_no = 'BB-T1-001';
-- Từ 2300: ghi đầu ra CĐ6 tự nhập kho thành phẩm (chờ FQC); không lập phiếu FG_IN tay
select pg_temp.ok((select qty = 500 and status = 'ACTIVE' from inv.handling_units h join inv.lots l on l.id = h.lot_id where l.lot_no = 'BB-T1-001'),
  'Bobin BB-T1-001 đã nằm trong kho thành phẩm (500 m)');
select pg_temp.as_user('U_KDNV');
insert into sales.sales_orders (so_no, customer_id, label_brand, required_date)
select 'SO-T1', id, 'KAVIX', current_date + 14 from core.partners where code = 'KAVIX';
insert into sales.so_lines (so_id, line_no, product_id, spec_id, qty_m, pack_type, m_per_pack)
select so.id, 1, p.id, p.current_spec_id, 1200, 'Bobin gỗ', 500 from sales.sales_orders so, master.products p where so.so_no = 'SO-T1' and p.code = 'PFR-2C-1P5';
select pg_temp.ok(sales.atp((select id from master.products where code = 'PFR-2C-1P5'), 'KAVIX') = 500, 'ATP = 500 m bobin Đạt');
insert into t select 'req_so', wf.submit('SO', (select id from sales.sales_orders where so_no = 'SO-T1'), 'SO-T1');
select pg_temp.as_user('U_KDTP'); select wf.act((select v from t where k='req_so'), 'APPROVE');
select pg_temp.as_user('U_BGD');  select wf.act((select v from t where k='req_so'), 'APPROVE');
select pg_temp.as_user('U_KDNV'); select sales.reserve_so((select id from sales.sales_orders where so_no = 'SO-T1'));
select pg_temp.ok((select reserved_m = 500 and to_produce_m = 700 and line_status = 'PLANNED' from sales.so_lines l join sales.sales_orders s on s.id = l.so_id where s.so_no = 'SO-T1'),
  'Giữ 500 m có sẵn, 700 m chuyển yêu cầu SX');
select pg_temp.ok(sales.atp((select id from master.products where code = 'PFR-2C-1P5'), 'KAVIX') = 0, 'ATP về 0 sau khi giữ hàng');

-- ================================================================ 8. Giá thành LSX
select pg_temp.as_user('U_KTGT');
insert into cost.cost_periods (period) values (to_char(current_date, 'YYYY-MM'));
insert into cost.standard_prices select id, (select id from master.materials where code = 'CU-024'), 265000 from cost.cost_periods;
update mfg.wo_operations set run_minutes = 120, ended_at = now() where id = pg_temp.op('CD1');
insert into cost.cost_pools select id, 'LABOR', 50000000, 'MACHINE_HOURS' from cost.cost_periods;
select cost.calc_wo((select id from mfg.work_orders where wo_no = 'LSX-T1'), (select id from cost.cost_periods));
select pg_temp.ok((select act_material = 27280000 and act_labor = 50000000 and good_m = 500 from cost.wo_costs w join mfg.work_orders o on o.id = w.wo_id where o.wo_no = 'LSX-T1'),
  'Giá thành thực tế: NVL 100 kg × 272.800 = 27.280.000; nhân công phân bổ theo giờ máy');
select pg_temp.ok((select round(qty_variance) = round((100 - std_qty) * 265000) and round(price_variance) = 780000
  from cost.wo_material_variances v join master.materials m on m.id = v.material_id where m.code = 'CU-024'),
  'Chênh lệch lượng và giá tách riêng (giá: 100 × (272.800 − 265.000) = 780.000)');

-- ================================================================ 9. Dữ liệu máy
reset role;
select pg_temp.ok(iot.ingest_batch('[{"machine":"EXT-SI-01","ts":"2026-10-25T08:00:00+07","state":1,"speed_mpm":62,"length_m":100,"od_mm":2.72,"temps":[48,352]},
  {"machine":"EXT-SI-01","ts":"2026-10-25T08:00:01+07","state":1,"speed_mpm":62.4,"length_m":101.04,"od_mm":2.73},
  {"machine":"GAU-01","ts":"2026-10-25T08:00:01+07","state":1,"od_mm":6.95}]'::jsonb) = 3, 'Gateway ghi 3 bản ghi máy');
select pg_temp.ok((select speed_mpm = 62.4::real from iot.machine_state s join master.machines m on m.id = s.machine_id where m.code = 'EXT-SI-01'), 'Trạng thái máy cập nhật bản ghi mới nhất');

-- ================================================================ 10. Phân quyền (RLS) với vai trò authenticated
select pg_temp.as_user('U_VH');
set local role authenticated;
do $$ begin
  if (select count(*) from purchase.purchase_orders) <> 0 then raise exception 'FAIL: vận hành không được thấy PO'; end if;
  insert into r(msg) values ('Vận hành máy không thấy đơn mua hàng (RLS)');
  if (select count(*) from inv.lots) = 0 then raise exception 'FAIL: vận hành phải thấy lô'; end if;
  insert into r(msg) values ('Vận hành máy thấy danh sách lô');
  begin
    perform unit_cost from inv.stock_moves limit 1;
    raise exception 'FAIL: vận hành không được đọc giá';
  exception when insufficient_privilege then insert into r(msg) values ('Vận hành không đọc được cột giá trên sổ cái kho');
  end;
  if (select count(*) from cost.stock_moves_valued()) <> 0 then raise exception 'FAIL: giá trị kho phải rỗng với vận hành'; end if;
  insert into r(msg) values ('Giá trị kho rỗng với người không có quyền xem giá');
  begin
    perform 1 from iot.telemetry_default limit 1;
    raise exception 'FAIL: không được đọc thẳng phân vùng dữ liệu máy';
  exception when insufficient_privilege then insert into r(msg) values ('Không đọc thẳng được phân vùng dữ liệu máy');
  end;
  begin
    insert into purchase.purchase_orders (po_no, supplier_id) values ('PO-X', (select id from core.partners limit 1));
    raise exception 'FAIL: vận hành không được tạo PO';
  exception when insufficient_privilege then insert into r(msg) values ('Vận hành không tạo được PO (RLS)');
  end;
  begin
    perform iot.ingest_batch('[]');
    raise exception 'FAIL: người dùng không được gọi hàm gateway';
  exception when insufficient_privilege then insert into r(msg) values ('Chỉ gateway (service_role) ghi dữ liệu máy');
  end;
end $$;
reset role;
select pg_temp.as_user('U_KTGT');
set local role authenticated;
do $$ begin
  if (select count(*) from cost.stock_moves_valued()) = 0 then raise exception 'FAIL: kế toán phải thấy giá trị kho'; end if;
  insert into r(msg) values ('Kế toán giá thành xem được giá trị kho');
end $$;
reset role;

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
rollback;
