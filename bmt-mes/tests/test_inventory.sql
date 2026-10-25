-- Kiểm thử module Kho theo Quy chuẩn vai trò nhân sự BMT. Chạy trong transaction rồi ROLLBACK (không để lại dữ liệu).
-- psql "<kết nối>" -v ON_ERROR_STOP=1 -f tests/test_inventory.sql
\set ON_ERROR_STOP 1
set client_min_messages = warning;
begin;

create function pg_temp.as_user(p_code text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', (select id::text from core.profiles where employee_code = p_code), true)
$$;
create function pg_temp.uid(p_code text) returns uuid language sql as $$ select id from core.profiles where employee_code = p_code $$;
create table pg_temp.n (c int);
insert into pg_temp.n values (0);
grant all on pg_temp.n to authenticated;
create function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_msg; end if;
  update pg_temp.n set c = c + 1;
  raise notice 'PASS: %', p_msg;
end $$;
create function pg_temp.fails(p_sql text, p_pattern text, p_msg text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm ilike '%' || p_pattern || '%' then
      update pg_temp.n set c = c + 1;
      raise notice 'PASS: % → "%"', p_msg, sqlerrm; return;
    end if;
    raise exception 'FAIL: % — lỗi khác mong đợi: %', p_msg, sqlerrm;
  end;
  raise exception 'FAIL: % — lẽ ra phải báo lỗi', p_msg;
end $$;
set client_min_messages = notice;

-- ---------------------------------------------------------------- nhân sự theo Quy chuẩn mục 10
create temp table who (code text, roles text[]);
insert into who values
  ('GD',    array['BGD','SX_KH']),                         -- Giám đốc Minh
  ('QLSX',  array['SX_TP','TO_TRUONG','SX_KH','THU_KHO']), -- Quản lý SX kiêm thủ kho NVL
  ('NV1',   array['VAN_HANH']), ('NV4', array['VAN_HANH']),
  ('NV5',   array['VAN_HANH','KHO_NV']),                   -- đóng gói kiêm kho thành phẩm
  ('KTSX',  array['KT_KHO','KT_GT']),                      -- Kế toán sản xuất
  ('KTSX2', array['KT_KHO']),
  ('TPKT',  array['KT_TP','QC']), ('KTNV', array['KT_NV']),
  ('MUA',   array['MUA_NV']), ('MUATP', array['MUA_TP']), ('KTT', array['KTT']),
  ('KD',    array['KD_NV','KD_TP']), ('ADM', array['ADMIN']);
insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from who;
insert into core.profiles (id, employee_code, full_name, status)
select u.id, upper(split_part(u.email, '@', 1)), 'Test ' || split_part(u.email, '@', 1), 'ACTIVE'
from auth.users u where u.email like '%@bmt.test' and upper(split_part(u.email, '@', 1)) in (select code from who);
insert into core.user_roles (user_id, role_code)
select pg_temp.uid(w.code), unnest(w.roles) from who w;
create temp table t (k text primary key, v uuid);
grant all on t to authenticated;

-- ================================================================ 0. Gán vai trò xung đột
select pg_temp.as_user('ADM');
select pg_temp.fails($$select app.admin_upsert_user(pg_temp.uid('KTSX'), 'X', 'KTSX', null, null, array['KT_KHO','THU_KHO'])$$,
  'Không gán chung', 'Không gán Thủ kho + Kế toán kho cho một người');
select pg_temp.fails($$select app.admin_upsert_user(pg_temp.uid('KTT'), 'X', 'KTT', null, null, array['KTT','KT_KHO'])$$,
  'Kế toán trưởng + Kế toán kho', 'Không gán Kế toán trưởng + Kế toán kho');

-- ================================================================ 1. Chuẩn bị: spec phát hành, PO đã duyệt
select set_config('bmt.wf_release', 'on', true);   -- chạy thử: phát hành spec như khi luồng duyệt hoàn tất
select master.release_spec(current_spec_id) from master.products where code = 'PFR-2C-1p5';
insert into core.partners (code, name, is_supplier, partner_type) values ('NCC-T', 'NCC thử', true, 'SUPPLIER');
insert into purchase.purchase_orders (po_no, supplier_id, status) select 'PO-K1', id, 'APPROVED' from core.partners where code = 'NCC-T';
insert into purchase.po_lines (po_id, line_no, material_id, qty, unit_price)
select po.id, x.n, m.id, x.q, x.p from purchase.purchase_orders po,
  (values (1, 'CU-024', 300, 268000), (2, 'SIL-9710G', 100, 95000)) x(n, c, q, p) join master.materials m on m.code = x.c
where po.po_no = 'PO-K1';
insert into master.package_types (code, name, tare_kg) values ('ONG-CU-T', 'Ống đồng thử', 12.4);

-- ================================================================ 2. Nhận hàng mua (Quản lý SX ký nhận)
select pg_temp.as_user('NV5');
select pg_temp.fails($$select inv.receive_goods((select id from purchase.purchase_orders where po_no='PO-K1'), null, null, null,
  '[{"po_line_id":"00000000-0000-0000-0000-000000000000","units":[{"qty":1}]}]')$$, 'không phải người giữ kho', 'NV5 không nhận hàng vào kho NVL');
select pg_temp.as_user('QLSX');
select pg_temp.fails(format($$select inv.receive_goods(%L, null, null, null, %L)$$,
  (select id from purchase.purchase_orders where po_no = 'PO-K1'),
  jsonb_build_array(jsonb_build_object('po_line_id', (select pl.id from purchase.po_lines pl join master.materials m on m.id = pl.material_id where m.code = 'SIL-9710G'),
    'units', jsonb_build_array(jsonb_build_object('qty', 25))))), 'bắt buộc nhập HSD', 'Silicone có hạn dùng: bắt buộc HSD');
select pg_temp.fails(format($$select inv.receive_goods(%L, null, null, null, %L)$$,
  (select id from purchase.purchase_orders where po_no = 'PO-K1'),
  jsonb_build_array(jsonb_build_object('po_line_id', (select pl.id from purchase.po_lines pl join master.materials m on m.id = pl.material_id where m.code = 'CU-024'),
    'units', jsonb_build_array(jsonb_build_object('qty', 200), jsonb_build_object('qty', 120))))), 'vượt PO quá dung sai', 'Nhận vượt PO + 5% bị chặn');
insert into t select 'gr1', inv.receive_goods((select id from purchase.purchase_orders where po_no = 'PO-K1'), null, null, 'PGH-001',
  jsonb_build_array(
    jsonb_build_object('po_line_id', (select pl.id from purchase.po_lines pl join master.materials m on m.id = pl.material_id where m.code = 'CU-024'),
      'supplier_lot', 'CU-A', 'package_type_id', (select id from master.package_types where code = 'ONG-CU-T'),
      'units', jsonb_build_array(jsonb_build_object('gross_kg', 152.4), jsonb_build_object('gross_kg', 152.4))),
    jsonb_build_object('po_line_id', (select pl.id from purchase.po_lines pl join master.materials m on m.id = pl.material_id where m.code = 'SIL-9710G'),
      'supplier_lot', 'SIL-A', 'exp_date', current_date + 120, 'units', jsonb_build_array(jsonb_build_object('qty', 50), jsonb_build_object('qty', 50)))));
select pg_temp.ok((select status = 'POSTED' and review_status = 'PENDING' from inv.stock_docs where id = (select v from t where k = 'gr1')),
  'Phiếu nhập theo PO ghi sổ ngay, chờ Kế toán SX duyệt');
select pg_temp.ok((select count(*) = 2 and min(qty) = 140 and max(tare_kg) = 12.4 from inv.handling_units h join inv.lots l on l.id = h.lot_id
  join master.materials m on m.id = l.material_id where m.code = 'CU-024'), 'Đồng: 2 ống, kg tịnh = 152,4 − bì 12,4 = 140 kg/ống');
select pg_temp.ok((select received_qty = 280 from purchase.po_lines pl join master.materials m on m.id = pl.material_id where m.code = 'CU-024')
  and (select status = 'PARTIAL_RECEIVED' from purchase.purchase_orders where po_no = 'PO-K1'), 'PO cập nhật số đã nhận, trạng thái nhận một phần');
select pg_temp.ok((select avg_cost = 268000 and qty = 280 from cost.item_valuation v join master.materials m on m.id = v.material_id where m.code = 'CU-024'),
  'Giá bình quân theo giá PO');
select pg_temp.ok((select in_quality = 280 and available = 0 from inv.v_material_availability where code = 'CU-024'), 'Lô mới ở Chờ QC: chưa khả dụng');
select pg_temp.as_user('MUA');
select purchase.check_receipt((select v from t where k = 'gr1'), 'Khớp PO');
select pg_temp.ok((select checked_by = pg_temp.uid('MUA') from purchase.goods_receipts where stock_doc_id = (select v from t where k = 'gr1')),
  'NV mua hàng đối chiếu nhận hàng với PO');

-- Không theo PO: chờ Kế toán SX nhập giá
select pg_temp.as_user('QLSX');
insert into t select 'gr2', inv.receive_goods(null, (select id from core.partners where code = 'NCC-T'), 'Hàng mẫu chạy thử', null,
  '[{"material_code":"PE-PACK","units":[{"qty":10}]}]');
select pg_temp.ok((select status = 'DRAFT' and price_pending from inv.stock_docs where id = (select v from t where k = 'gr2')), 'Không theo PO: phiếu chờ giá');
select pg_temp.fails($$select inv.set_receipt_price((select v from t where k='gr2'), '{}')$$, 'Chỉ Kế toán SX', 'Quản lý SX không nhập giá');
select pg_temp.as_user('KTSX');
select inv.set_receipt_price((select v from t where k = 'gr2'),
  jsonb_build_object((select id::text from inv.stock_doc_lines where doc_id = (select v from t where k = 'gr2')), 45000));
select pg_temp.ok((select status = 'POSTED' and review_status = 'CONFIRMED' and not price_pending from inv.stock_docs where id = (select v from t where k = 'gr2')),
  'Kế toán SX nhập giá → ghi sổ');

-- ================================================================ 3. QC giải phóng lô (TP Kỹ thuật/QA)
select pg_temp.as_user('NV1');
select pg_temp.fails($$select qa.release_lot((select lot_id from inv.stock_doc_lines where doc_id=(select v from t where k='gr1') limit 1), 'PASS', null)$$,
  'Không có quyền', 'Vận hành không giải phóng lô');
select pg_temp.as_user('TPKT');
select qa.release_lot(l.id, 'PASS', null, '[{"test_code":"WIRE_DIA","value_num":0.241,"unit":"mm","limit_min":0.236,"limit_max":0.244,"pass":true}]')
from inv.lots l join master.materials m on m.id = l.material_id where m.code = 'CU-024';
select pg_temp.fails($$select qa.release_lot((select l.id from inv.lots l join master.materials m on m.id = l.material_id where m.code='SIL-9710G'), 'FAIL', '')$$,
  'Ghi lỗi', 'Không đạt phải ghi lỗi');
select qa.release_lot(l.id, 'FAIL', 'Độ cứng ngoài dung sai') from inv.lots l join master.materials m on m.id = l.material_id where m.code = 'SIL-9710G';
select pg_temp.ok((select qc_status = 'QUARANTINE' from inv.lots l join master.materials m on m.id = l.material_id where m.code = 'SIL-9710G')
  and exists (select 1 from qa.ncrs n join inv.lots l on l.id = n.lot_id join master.materials m on m.id = l.material_id where m.code = 'SIL-9710G' and n.status = 'OPEN'),
  'Không đạt → cách ly + NCR');
select qa.release_lot(l.id, 'PASS', 'Nhận có điều kiện, TP KT/QA quyết định') from inv.lots l join master.materials m on m.id = l.material_id where m.code = 'SIL-9710G';
select pg_temp.ok((select available = 280 from inv.v_material_availability where code = 'CU-024'), 'Lô đạt → tồn khả dụng 280 kg');

-- ================================================================ 4. Lệnh SX + phiếu lĩnh theo định mức
select pg_temp.as_user('QLSX');
insert into mfg.work_orders (wo_no, product_id, spec_id, bom_id, qty_m, m_per_pack, pack_type, brand)
select 'LSX-K1', p.id, p.current_spec_id, h.id, 1000, 500, 'Bobin gỗ', 'KAVIX'
from master.products p join master.bom_headers h on h.spec_id = p.current_spec_id where p.code = 'PFR-2C-1p5';
select mfg.release_wo((select id from mfg.work_orders where wo_no = 'LSX-K1'));
select set_config('bmt.wf_release', 'off', true);
select pg_temp.as_user('NV1');
select pg_temp.fails($$select inv.create_requisition((select id from mfg.work_orders where wo_no='LSX-K1'), 1000)$$, 'Chỉ Quản lý SX', 'Vận hành không lập phiếu lĩnh');
select pg_temp.as_user('QLSX');
insert into t select 'req', inv.create_requisition((select id from mfg.work_orders where wo_no = 'LSX-K1'), 1000, current_date, 'Ca 1');
select pg_temp.ok((select round(qty_req, 3) = round(24.72300337 / (1 - 0.015), 3) from inv.requisition_lines rl join master.materials m on m.id = rl.material_id
  where rl.req_id = (select v from t where k = 'req') and m.code = 'CU-024'), 'Phiếu lĩnh đồng = 24,723 kg/km × 1 km / (1 − 1,5%)');
select pg_temp.ok((select round(qty_req, 3) = round(23.9933 / 0.97 + 4.901961, 3) from inv.requisition_lines rl join master.materials m on m.id = rl.material_id
  where rl.req_id = (select v from t where k = 'req') and m.code = 'PVC-FR'), 'Phiếu lĩnh đầu tiên cộng phế khởi động');
select pg_temp.fails($$select inv.create_requisition((select id from mfg.work_orders where wo_no='LSX-K1'), 100)$$, 'chỉ còn', 'Không lĩnh vượt sản lượng lệnh');

-- ================================================================ 5. Cấp NVL: quét QR, FEFO/FIFO, không vượt phiếu lĩnh, công nhân nhận
insert into t select 'hu1', h.id from inv.handling_units h join inv.lots l on l.id = h.lot_id join master.materials m on m.id = l.material_id
  where m.code = 'CU-024' order by h.hu_no limit 1;
insert into t select 'hu2', h.id from inv.handling_units h join inv.lots l on l.id = h.lot_id join master.materials m on m.id = l.material_id
  where m.code = 'CU-024' order by h.hu_no desc limit 1;
select pg_temp.fails($$select inv.issue_pick((select v from t where k='req'), jsonb_build_array(jsonb_build_object('hu_id', (select v from t where k='hu1'))), pg_temp.uid('QLSX'))$$,
  'người nhận khác người xuất', 'Người xuất không tự nhận');
select pg_temp.fails($$select inv.issue_pick((select v from t where k='req'), jsonb_build_array(jsonb_build_object('hu_id', (select v from t where k='hu1')),
  jsonb_build_object('hu_id', (select v from t where k='hu2'))), pg_temp.uid('NV1'))$$, 'xuất vượt phiếu lĩnh', 'Không xuất vượt phiếu lĩnh (2 ống khi cần 25 kg)');
-- Hai ống cùng lô, cùng ngày nhập → không có ống nào "đáng xuất trước"; tạo lô cũ hơn để thử FEFO/FIFO
insert into t select 'gr3', inv.receive_goods((select id from purchase.purchase_orders where po_no = 'PO-K1'), null, null, null,
  jsonb_build_array(jsonb_build_object('po_line_id', (select pl.id from purchase.po_lines pl join master.materials m on m.id = pl.material_id where m.code = 'CU-024'),
    'units', jsonb_build_array(jsonb_build_object('qty', 30)))));
update inv.lots set created_at = now() - interval '10 days' where id = (select lot_id from inv.stock_doc_lines where doc_id = (select v from t where k = 'gr3'));
select set_config('request.jwt.claim.sub', pg_temp.uid('TPKT')::text, true);
select qa.release_lot((select lot_id from inv.stock_doc_lines where doc_id = (select v from t where k = 'gr3')), 'PASS', null);
select pg_temp.as_user('QLSX');
select pg_temp.fails($$select inv.issue_pick((select v from t where k='req'), jsonb_build_array(jsonb_build_object('hu_id', (select v from t where k='hu1'))), pg_temp.uid('NV1'))$$,
  'nên xuất trước', 'FIFO: ống nhập trước phải xuất trước (hoặc ghi lý do)');
insert into t select 'is1', inv.issue_pick((select v from t where k = 'req'),
  jsonb_build_array(jsonb_build_object('hu_id', (select v from t where k = 'hu1'), 'reason', 'Ống cũ ở tầng trên, xuống sau')), pg_temp.uid('NV1'));
select pg_temp.ok((select status = 'EMPTY' and qty = 0 from inv.handling_units where id = (select v from t where k = 'hu1')), 'Ống đồng xuất nguyên ống → Trống');
select pg_temp.ok((select reason is not null from inv.stock_doc_lines where doc_id = (select v from t where k = 'is1')), 'Lý do đổi lô được lưu');
select pg_temp.ok((select status = 'PARTIAL' from inv.requisitions where id = (select v from t where k = 'req')), 'Phiếu lĩnh còn vật tư khác chưa cấp → Đang cấp');
select pg_temp.ok((select status = 'IN_PROGRESS' from mfg.work_orders where wo_no = 'LSX-K1'), 'Lệnh chuyển Đang sản xuất khi cấp NVL');
select pg_temp.ok(exists (select 1 from wf.notifications where user_id = pg_temp.uid('NV1') and title like 'Nhận NVL%'), 'Công nhân nhận thông báo nhận NVL');
select pg_temp.fails($$select inv.confirm_issue((select v from t where k='is1'))$$, 'Chỉ người được giao', 'Thủ kho không xác nhận thay công nhân');
select pg_temp.as_user('NV1');
select inv.confirm_issue((select v from t where k = 'is1'));
select pg_temp.ok((select received_at is not null from inv.stock_docs where id = (select v from t where k = 'is1')), 'Công nhân xác nhận đã nhận tại máy');

-- ================================================================ 6. Trả NVL thừa cuối ca (cân lại)
select pg_temp.as_user('QLSX');
insert into t select 'rt1', inv.return_hu((select v from t where k = 'hu1'), 112.5);
select pg_temp.ok((select status = 'ACTIVE' and qty = 112.5 from inv.handling_units where id = (select v from t where k = 'hu1')), 'Trả 112,5 kg về đúng ống cũ');
select pg_temp.fails($$select inv.return_hu((select v from t where k='hu1'), 30)$$, 'tối đa', 'Không trả nhiều hơn đã cấp');
select pg_temp.ok((select qty_issued = 140 and qty_returned = 112.5 from inv.requisition_lines rl join master.materials m on m.id = rl.material_id
  where rl.req_id = (select v from t where k = 'req') and m.code = 'CU-024'), 'Phiếu lĩnh ghi: cấp 140, trả 112,5 → tiêu hao 27,5 kg');

-- ================================================================ 7. Kế toán SX duyệt trong ngày (hậu kiểm)
select pg_temp.fails($$select inv.review_doc((select v from t where k='is1'), true, null)$$, 'Chỉ Kế toán SX', 'Thủ kho không tự duyệt phiếu');
select pg_temp.as_user('KTSX');
select pg_temp.fails($$select inv.review_doc((select v from t where k='rt1'), false, '')$$, 'lý do', 'Trả lại phải ghi lý do');
select inv.review_doc((select v from t where k = 'is1'), true, null);
select inv.review_doc((select v from t where k = 'gr1'), true, 'Khớp PO, phiếu kiểm tra');
select pg_temp.ok((select review_status = 'CONFIRMED' from inv.stock_docs where id = (select v from t where k = 'is1')), 'Kế toán SX xác nhận phiếu xuất');

-- ================================================================ 8. Sản xuất: ghi đầu ra tự sinh phiếu kho BTP/TP
select pg_temp.as_user('NV1');
create function pg_temp.op(p_code text) returns uuid language sql as $$
  select o.id from mfg.wo_operations o join mfg.work_orders w on w.id = o.wo_id where w.wo_no = 'LSX-K1' and o.op_code = p_code $$;
insert into t select 'cb', mfg.record_output(pg_temp.op('CD1'), 'CB-K1', 2000, 25.0,
  jsonb_build_array(jsonb_build_object('lot_id', (select lot_id from inv.handling_units where id = (select v from t where k = 'hu1')), 'qty', 27.5)));
select pg_temp.ok((select sum(b.qty) = 2000 from inv.stock_balances b where b.lot_id = (select v from t where k = 'cb') and b.warehouse_id = inv.wh('KBTP')),
  'Lõi đồng bện CB nhập kho BTP 2.000 m');
insert into t select 'lb1', mfg.record_output(pg_temp.op('CD2'), 'LB-K1N', 1000, null, jsonb_build_array(jsonb_build_object('lot_id', (select v from t where k = 'cb'), 'qty', 1000)), 'Nâu');
insert into t select 'lb2', mfg.record_output(pg_temp.op('CD2'), 'LB-K1T', 1000, null, jsonb_build_array(jsonb_build_object('lot_id', (select v from t where k = 'cb'), 'qty', 1000)), 'Trắng');
select pg_temp.ok((select qc_status = 'CONSUMED' from inv.lots where id = (select v from t where k = 'cb')), 'Lõi CB dùng hết → lô Hết');
select pg_temp.fails($$select mfg.record_output(pg_temp.op('CD3'), 'BL-X', 1000, null, jsonb_build_array(jsonb_build_object('lot_id', (select v from t where k='lb1'), 'qty', 1200)))$$,
  'không đủ', 'Công đoạn sau không lấy quá số BTP còn');
insert into t select 'bl', mfg.record_output(pg_temp.op('CD3'), 'BL-K1', 1000, null, jsonb_build_array(
  jsonb_build_object('lot_id', (select v from t where k = 'lb1'), 'qty', 1000), jsonb_build_object('lot_id', (select v from t where k = 'lb2'), 'qty', 1000)));
insert into t select 'cv', mfg.record_output(pg_temp.op('CD5'), 'CV-K1', 1000, null, jsonb_build_array(jsonb_build_object('lot_id', (select v from t where k = 'bl'), 'qty', 1000)));
select pg_temp.as_user('NV5');
insert into t select 'bb1', mfg.record_output(pg_temp.op('CD6'), 'BB-K1-01', 505, 32.1, jsonb_build_array(jsonb_build_object('lot_id', (select v from t where k = 'cv'), 'qty', 505)), null, 3.5);
insert into t select 'bb2', mfg.record_output(pg_temp.op('CD6'), 'BB-K1-02', 480, 30.2, jsonb_build_array(jsonb_build_object('lot_id', (select v from t where k = 'cv'), 'qty', 480)));
select pg_temp.ok((select h.location_id = inv.loc('KTP-QC') and h.gross_kg = 35.6 from inv.handling_units h where h.lot_id = (select v from t where k = 'bb1')),
  'Bobin thành phẩm nhập KTP khu Chờ FQC, cân tổng = tịnh + bì');
select pg_temp.ok((select review_status = 'PENDING' from inv.stock_docs d join inv.stock_doc_lines dl on dl.doc_id = d.id where dl.lot_id = (select v from t where k = 'bb1') and d.doc_type = 'FG_IN'),
  'Phiếu nhập thành phẩm chờ Kế toán SX duyệt');
select pg_temp.ok((select review_status = 'NA' from inv.stock_docs d join inv.stock_doc_lines dl on dl.doc_id = d.id where dl.lot_id = (select v from t where k = 'cb') and d.doc_type = 'WIP_IN'),
  'Phiếu BTP nội bộ tự sinh không cần hậu kiểm');

-- ================================================================ 9. Phế theo lệnh (NV4 gom, cân)
select pg_temp.as_user('NV4');
select inv.record_scrap((select id from mfg.work_orders where wo_no = 'LSX-K1'), 'CD1', 'PL-CU', 1.2, 'SC_STARTUP');
select inv.record_scrap((select id from mfg.work_orders where wo_no = 'LSX-K1'), 'CD1', 'PL-CU', 0.3, 'SC_BREAK');
select inv.record_scrap((select id from mfg.work_orders where wo_no = 'LSX-K1'), 'CD5', 'PL-PVC', 2.5, 'SC_STARTUP');
select pg_temp.ok((select qty = 1.5 from inv.handling_units h join inv.lots l on l.id = h.lot_id where l.lot_no = 'PL-CU-' || to_char(current_date, 'YYMMDD')),
  'Phế đồng cùng ngày cộng vào một bao (1,5 kg)');
select pg_temp.ok((select coalesce(sum(sm.qty * sm.unit_cost), 0) = 0 from inv.stock_moves sm where sm.warehouse_id = inv.wh('KPL')), 'Phế giá trị 0');
select pg_temp.fails($$select inv.record_scrap((select id from mfg.work_orders where wo_no='LSX-K1'), 'CD1', 'PL-CU', 1, 'DT_POWER')$$, 'nguyên nhân phế', 'Nguyên nhân phải thuộc nhóm phế');

-- ================================================================ 10. FQC + báo cáo hao hụt, cân bằng đồng
select pg_temp.as_user('TPKT');
select qa.release_lot((select v from t where k = 'bb1'), 'PASS', null);
select qa.release_lot((select v from t where k = 'bb2'), 'PASS', null);
create temp table loss as select * from app.loss_by_wo(current_date - 1, current_date) where wo_no = 'LSX-K1';
select pg_temp.ok((select good_m = 985 and cu_issued = 27.5 from loss), 'Báo cáo: 985 m đạt, đồng cấp ròng 27,5 kg');
select pg_temp.ok((select cu_fg = round(0.985 * 24.723003, 3) and cu_scrap = 1.5 from loss), 'Đồng trong TP = 0,985 km × 24,723 kg/km; phế đồng 1,5 kg');
select pg_temp.ok((select cu_diff = round(cu_issued - cu_fg - cu_scrap - coalesce(cu_cable, 0) - cu_wip, 3) from loss), 'Lệch đồng = cấp − (TP + phế + cáp lỗi + BTP dở)');
select pg_temp.ok((select overlength_m = 5 and startup_kg = 3.7 and quality_kg = 0.3 from loss), 'Mét giao dư 5 m (505/500); phế khởi động 3,7 kg; lỗi 0,3 kg');
select pg_temp.ok((select giveaway_kg = round(62.3 - 0.985 * 62.343041, 2) from loss), 'Vượt dày = kg tịnh bobin − km × kg/km lý thuyết');
select pg_temp.ok((select count(*) > 0 from app.loss_wo_materials((select id from mfg.work_orders where wo_no = 'LSX-K1')) where material_code = 'CU-024' and net = 27.5),
  'Tiêu hao vật tư theo lệnh: CU-024 ròng 27,5 kg');
select pg_temp.ok((select sum(kg) = 4 from app.loss_scrap(current_date, current_date)), 'Pareto phế: tổng 4 kg');

-- ================================================================ 11. Chuyển vị trí (đúng người giữ kho, đúng phạm vi kho được giao)
select pg_temp.as_user('ADM');
select app.admin_set_warehouses(pg_temp.uid('QLSX'), array['KBTP','KPL']);
select pg_temp.as_user('QLSX');
select pg_temp.fails($$select inv.move_hu((select v from t where k = 'hu2'), inv.loc('KNL-CU'))$$, 'không được giao kho', 'Thủ kho chỉ thao tác kho được giao (phạm vi kho)');
select pg_temp.as_user('ADM');
select app.admin_set_warehouses(pg_temp.uid('QLSX'), '{}');   -- không giao riêng = mọi kho
select pg_temp.as_user('QLSX');
select inv.move_hu((select v from t where k = 'hu2'), inv.loc('KNL-CU'));
select pg_temp.ok((select location_id = inv.loc('KNL-CU') from inv.handling_units where id = (select v from t where k = 'hu2')), 'Quét ống + quét vị trí → đổi vị trí');
select pg_temp.fails(format($$select inv.move_hu(%L, inv.loc('KTP-A'))$$, (select h.id from inv.handling_units h where h.lot_id = (select v from t where k = 'bb1'))),
  'không phải người giữ kho KTP', 'Quản lý SX không chuyển hàng trong kho thành phẩm');
select pg_temp.as_user('NV5');
select inv.move_hu(h.id, inv.loc('KTP-A')) from inv.handling_units h where h.lot_id in ((select v from t where k = 'bb1'), (select v from t where k = 'bb2'));

-- ================================================================ 12. Giữ hàng, lệnh giao (TP KT/QA + Giám đốc duyệt), xuất đúng bobin
select pg_temp.as_user('KD');
insert into sales.sales_orders (so_no, customer_id, label_brand, required_date, status)
select 'SO-K1', id, 'KAVIX', current_date + 7, 'APPROVED' from core.partners where code = 'KAVIX';
insert into sales.so_lines (so_id, line_no, product_id, spec_id, qty_m, pack_type, m_per_pack)
select so.id, 1, p.id, p.current_spec_id, 505, 'Bobin gỗ', 500 from sales.sales_orders so, master.products p where so.so_no = 'SO-K1' and p.code = 'PFR-2C-1p5';
select sales.reserve_so((select id from sales.sales_orders where so_no = 'SO-K1'));
select pg_temp.ok((select count(*) = 1 and sum(qty_m) = 505 from sales.so_reservations where hu_id is not null), 'Giữ hàng theo từng bobin');
select pg_temp.ok((select reserved_qty = 505 from inv.stock_balances where lot_id = (select v from t where k = 'bb1')), 'Tồn ghi nhận phần đã giữ');
select pg_temp.as_user('NV5');
select pg_temp.fails(format($$select inv.split_hu(%L, array[200]::numeric[], 0, 'thử')$$, (select h.id from inv.handling_units h where h.lot_id = (select v from t where k = 'bb1'))),
  'đang được giữ', 'Không cắt bobin đang giữ cho đơn');
insert into t select 'dv', sales.create_delivery((select id from sales.sales_orders where so_no = 'SO-K1'),
  array[(select h.id from inv.handling_units h where h.lot_id = (select v from t where k = 'bb1'))], current_date, null);
select pg_temp.as_user('QLSX');
select pg_temp.fails($$select wf.act((select id from wf.approval_requests where doc_id=(select v from t where k='dv')), 'APPROVE')$$, 'cần vai trò', 'Bước 1 lệnh giao: TP Kỹ thuật/QA');
select pg_temp.as_user('TPKT'); select wf.act((select id from wf.approval_requests where doc_id = (select v from t where k = 'dv')), 'APPROVE', 'CQ đủ');
select pg_temp.as_user('GD');   select wf.act((select id from wf.approval_requests where doc_id = (select v from t where k = 'dv')), 'APPROVE');
select pg_temp.ok((select status = 'APPROVED' from sales.deliveries where id = (select v from t where k = 'dv')), 'Giám đốc duyệt lệnh giao');
select pg_temp.as_user('NV5');
select pg_temp.fails(format($$select inv.ship_delivery(%L, array[%L]::uuid[])$$, (select v from t where k = 'dv'),
  (select h.id from inv.handling_units h where h.lot_id = (select v from t where k = 'bb2'))), 'chưa khớp', 'Quét sai bobin → báo thiếu/thừa');
select inv.ship_delivery((select v from t where k = 'dv'), array[(select h.id from inv.handling_units h where h.lot_id = (select v from t where k = 'bb1'))]);
select pg_temp.ok((select delivered_m = 505 and reserved_m = 0 and line_status = 'DELIVERED' from sales.so_lines l join sales.sales_orders s on s.id = l.so_id where s.so_no = 'SO-K1'),
  'Xuất giao: trừ tồn, trả phần đã giữ, ghi đã giao');
select pg_temp.ok((select count(*) = 0 from inv.stock_balances where lot_id = (select v from t where k = 'bb1') and qty > 0), 'Bobin đã giao hết tồn');

-- ================================================================ 13. Cắt bobin, đoạn lẻ
insert into t select 'sp', inv.split_hu(h.id, array[300]::numeric[], 2, 'Khách cần 300 m') from inv.handling_units h where h.lot_id = (select v from t where k = 'bb2') and h.status = 'ACTIVE';
select pg_temp.ok((select qty = 178 from inv.handling_units where lot_id = (select v from t where k = 'bb2') and parent_hu_id is null), 'Bobin mẹ còn 480 − 300 − 2 = 178 m');
select pg_temp.ok((select count(*) = 1 from inv.handling_units where lot_id = (select v from t where k = 'bb2') and parent_hu_id is not null and qty = 300 and not is_remnant), 'Đoạn 300 m có tem mới');
select pg_temp.ok((select sum(qty) > 0 from inv.handling_units h join inv.lots l on l.id = h.lot_id where l.lot_no = 'PL-CABLE-' || to_char(current_date, 'YYMMDD')), 'Phế cắt nhập kho phế dạng cáp lỗi (kg)');

-- ================================================================ 14. Ủy quyền thủ kho: phải có Kế toán SX chứng kiến
insert into core.delegations (from_user, to_user, role_code, valid_from, valid_to, reason)
values (pg_temp.uid('QLSX'), pg_temp.uid('NV1'), 'THU_KHO', now() - interval '1 hour', now() + interval '8 hours', 'Quản lý SX nghỉ phép');
select pg_temp.as_user('NV1');
select pg_temp.fails($$select inv.move_hu((select v from t where k='hu2'), inv.loc('KNL-NH'))$$, 'chứng kiến', 'Tổ phó giữ kho theo ủy quyền: bắt buộc người chứng kiến');
select inv.move_hu((select v from t where k = 'hu2'), inv.loc('KNL-NH'), pg_temp.uid('KTSX'));
select pg_temp.ok((select delegated and witness_id = pg_temp.uid('KTSX') from inv.stock_docs where doc_type = 'TRANSFER' and note like '% → KNL-NH'),
  'Phiếu ghi rõ: theo ủy quyền, Kế toán SX chứng kiến');
delete from core.delegations;

-- ================================================================ 15. Lĩnh bổ sung vượt định mức: TP Kỹ thuật/QA duyệt
select pg_temp.as_user('QLSX');
insert into t select 'rx', inv.create_extra_requisition((select id from mfg.work_orders where wo_no = 'LSX-K1'), '[{"material_code":"CU-024","qty":5}]', 'EX_SCRAP', 'Đứt dây nhiều');
select pg_temp.ok((select status = 'PENDING_APPROVAL' from inv.requisitions where id = (select v from t where k = 'rx')), 'Phiếu lĩnh bổ sung chờ duyệt');
select pg_temp.fails($$select wf.act((select id from wf.approval_requests where doc_id=(select v from t where k='rx')), 'APPROVE')$$, 'cần vai trò Trưởng phòng Kỹ thuật/QA', 'Quản lý SX (TP sản xuất) không duyệt lĩnh bổ sung: phải TP Kỹ thuật/QA');
select pg_temp.as_user('TPKT'); select wf.act((select id from wf.approval_requests where doc_id = (select v from t where k = 'rx')), 'APPROVE');
select pg_temp.ok((select status = 'APPROVED' from inv.requisitions where id = (select v from t where k = 'rx')), 'TP Kỹ thuật/QA duyệt → được cấp');

-- ================================================================ 16. Kiểm kê: Kế toán SX chủ trì, đếm mù, Kế toán trưởng duyệt
select pg_temp.as_user('QLSX');
select pg_temp.fails($$select inv.count_open(inv.wh('KNL'), 'FULL', null, null)$$, 'Kế toán SX chủ trì', 'Thủ kho không tự mở kiểm kê');
select pg_temp.as_user('KTSX');
insert into t select 'cnt', inv.count_open(inv.wh('KNL'), 'FULL', null, 'Cuối tháng');
select pg_temp.as_user('QLSX');
select pg_temp.fails($$select inv.move_hu((select v from t where k='hu1'), inv.loc('KNL-CU'))$$, 'Đang kiểm kê', 'Khóa xuất nhập trong lúc kiểm kê');
set local role authenticated;
select pg_temp.ok((select count(*) > 0 and bool_and(system_qty is null) from app.v_count_lines where count_id = (select v from t where k = 'cnt')), 'Người đếm không thấy số sổ sách (đếm mù)');
reset role;
select inv.count_scan((select v from t where k = 'cnt'), (select v from t where k = 'hu1'), null, 110.0);
select inv.count_scan((select v from t where k = 'cnt'), null, l.id, l.system_qty) from inv.stock_count_lines l
 where l.count_id = (select v from t where k = 'cnt') and l.counted_qty is null;
select pg_temp.as_user('KTSX');
insert into t select 'adj', inv.count_close((select v from t where k = 'cnt'));
select pg_temp.ok((select status = 'PENDING_APPROVAL' from inv.stock_counts where id = (select v from t where k = 'cnt'))
  and (select qty = -2.5 from inv.stock_doc_lines where doc_id = (select v from t where k = 'adj')), 'Chênh −2,5 kg → biên bản chờ Kế toán trưởng duyệt');
select pg_temp.fails($$select wf.act((select id from wf.approval_requests where doc_id=(select v from t where k='adj')), 'APPROVE')$$, 'cần vai trò', 'Kế toán SX không duyệt biên bản của mình');
select pg_temp.as_user('KTT'); select wf.act((select id from wf.approval_requests where doc_id = (select v from t where k = 'adj')), 'APPROVE');
select pg_temp.ok((select status = 'POSTED' from inv.stock_counts where id = (select v from t where k = 'cnt'))
  and (select qty = 110 from inv.handling_units where id = (select v from t where k = 'hu1')), 'Kế toán trưởng duyệt → ghi sổ, ống còn 110 kg, mở khóa');

-- ================================================================ 17. Phiếu đảo, khóa kỳ đã chốt
select pg_temp.as_user('KTSX');
insert into t select 'sc', d.id from inv.stock_docs d where d.doc_type = 'SCRAP_IN' and d.note like 'Lệnh LSX-K1 · CD5%' limit 1;
select inv.reverse_doc((select v from t where k = 'sc'), 'Ghi nhầm công đoạn');
select pg_temp.ok((select reversed_by is not null from inv.stock_docs where id = (select v from t where k = 'sc')), 'Phiếu đảo liên kết phiếu gốc');
select pg_temp.fails($$select inv.reverse_doc((select v from t where k='sc'), 'lần 2')$$, 'đã được đảo', 'Không đảo hai lần');
insert into cost.cost_periods (period, status) values (to_char(current_date, 'YYYY-MM'), 'CLOSED');
select pg_temp.as_user('QLSX');
select pg_temp.fails($$select inv.move_hu((select v from t where k='hu1'), inv.loc('KNL-CU'))$$, 'đã chốt giá thành', 'Kỳ đã chốt: không ghi sổ');
delete from cost.cost_periods where period = to_char(current_date, 'YYYY-MM');

-- ================================================================ 18. Bán phế: Kế toán SX kiểm tra, Giám đốc duyệt → ghi sổ
select pg_temp.as_user('QLSX');
insert into t select 'bp', inv.create_scrap_sale(jsonb_build_array(jsonb_build_object('hu_id', h.id, 'qty', 1.0)), 'Cơ sở thu mua phế A', null)
from inv.handling_units h join inv.lots l on l.id = h.lot_id where l.lot_no = 'PL-CU-' || to_char(current_date, 'YYMMDD');
select pg_temp.as_user('KTSX'); select wf.act((select id from wf.approval_requests where doc_id = (select v from t where k = 'bp')), 'APPROVE');
select pg_temp.as_user('GD');   select wf.act((select id from wf.approval_requests where doc_id = (select v from t where k = 'bp')), 'APPROVE');
select pg_temp.ok((select status = 'POSTED' from inv.stock_docs where id = (select v from t where k = 'bp')), 'Bán phế được duyệt → ghi sổ ngay');

-- ================================================================ 19. Tồn đầu kỳ: Kế toán SX lập, Kế toán trưởng duyệt
select pg_temp.as_user('KTSX');
insert into t select 'op', inv.create_opening(inv.wh('KNL'), current_date, '[{"code":"TALC","qty":50,"unit_cost":20000,"location_code":"KNL-NH","units":2}]');
select pg_temp.as_user('KTT'); select wf.act((select id from wf.approval_requests where doc_id = (select v from t where k = 'op')), 'APPROVE');
select pg_temp.ok((select count(*) = 2 and sum(h.qty) = 50 from inv.handling_units h join inv.stock_doc_lines dl on dl.hu_id = h.id where dl.doc_id = (select v from t where k = 'op')),
  'Tồn đầu kỳ: 2 bao TALC, 50 kg, ghi sổ sau khi duyệt');

-- ================================================================ 20. Hàng khách trả + hủy (TP Kỹ thuật/QA)
select pg_temp.as_user('NV5');
insert into t select 'ret', inv.customer_return((select id from master.products where code = 'PFR-2C-1p5'), 'KAVIX', 50, null, null, 'Vỏ trầy');
select pg_temp.ok((select l.qc_status = 'QUARANTINE' and h.location_id = inv.loc('KTP-RET') from inv.stock_doc_lines dl join inv.lots l on l.id = dl.lot_id
  join inv.handling_units h on h.id = dl.hu_id where dl.doc_id = (select v from t where k = 'ret')), 'Hàng trả về: khu hàng trả, cách ly');
select pg_temp.fails(format($$select inv.reclass_hu(%L, true, null, null, 'Hủy')$$, (select hu_id from inv.stock_doc_lines where doc_id = (select v from t where k = 'ret'))),
  'Chỉ TP Kỹ thuật', 'NV5 không tự hủy hàng');
select pg_temp.as_user('TPKT');
select inv.reclass_hu((select hu_id from inv.stock_doc_lines where doc_id = (select v from t where k = 'ret')), true, null, null, 'NCR: vỏ trầy, hủy');
select pg_temp.ok((select status = 'EMPTY' from inv.handling_units where id = (select hu_id from inv.stock_doc_lines where doc_id = (select v from t where k = 'ret'))),
  'Hủy theo NCR → bobin trống, chuyển phế');

-- ================================================================ 21. Phân quyền đọc (RLS) + tổng quan + cảnh báo
select pg_temp.as_user('NV1');
set local role authenticated;
do $$ begin
  if (select count(*) from app.v_hu) = 0 then raise exception 'FAIL: vận hành phải thấy mã QR để quét'; end if;
  begin
    perform unit_cost from inv.stock_doc_lines limit 1;
    raise exception 'FAIL: vận hành không được đọc giá trên dòng chứng từ';
  exception when insufficient_privilege then null;
  end;
  if (select count(*) from app.doc_line_prices((select v from t where k = 'gr1'))) <> 0 then raise exception 'FAIL: giá phải rỗng với vận hành'; end if;
  begin
    insert into inv.handling_units (hu_no, lot_id, hu_type, qty) values ('X', (select id from inv.lots limit 1), 'BAG', 1);
    raise exception 'FAIL: không được tạo đơn vị chứa ngoài quy trình';
  exception when insufficient_privilege then null;
  end;
  if (app.kho_overview() ->> 'my_receipts') is null then raise exception 'FAIL: tổng quan kho'; end if;
  raise notice 'PASS: Vận hành thấy QR, không thấy giá, không ghi thẳng bảng kho; tổng quan kho chạy';
end $$;
reset role;
update pg_temp.n set c = c + 1;
select pg_temp.as_user('KTSX');
select pg_temp.ok((select count(*) > 0 and bool_and(unit_cost is not null) from app.doc_line_prices((select v from t where k = 'gr1'))), 'Kế toán SX xem được giá dòng phiếu');
select pg_temp.ok((select count(*) > 0 from app.stock_nxt(current_date - 30, current_date)), 'Báo cáo nhập – xuất – tồn chạy');
update inv.stock_docs set posted_at = now() - interval '2 days' where id = (select v from t where k = 'rt1');
reset role;
select pg_temp.ok(inv.daily_alerts() > 0, 'Cảnh báo hằng ngày chạy');
select pg_temp.ok(exists (select 1 from wf.notifications where title like 'Phiếu kho chưa được Kế toán SX duyệt%' and user_id = pg_temp.uid('GD')),
  'Cảnh báo hằng ngày: phiếu quá hạn duyệt báo Giám đốc');

-- Trang web: vị trí, PO mở, in tem, ủy quyền hiện trong app.me()
select pg_temp.as_user('QLSX');
select pg_temp.ok((select count(*) >= 20 from app.v_locations), 'Danh sách vị trí kho đọc được');
select pg_temp.ok((select count(*) >= 0 from app.v_open_po_lines), 'Danh sách dòng PO mở đọc được');
do $$ declare v uuid := (select id from inv.handling_units where status = 'ACTIVE' and print_count = 0 limit 1); begin
  perform inv.mark_printed(array[v], null);
  begin
    perform inv.mark_printed(array[v], null);
    raise exception 'FAIL: in lại tem phải có lý do';
  exception when others then if sqlerrm not like '%lý do in lại%' then raise; end if;
  end;
  perform inv.mark_printed(array[v], 'Tem rách');
  if (select print_count from inv.handling_units where id = v) <> 2 then raise exception 'FAIL: đếm lần in'; end if;
  raise notice 'PASS: in tem đếm lần in, in lại bắt buộc lý do';
end $$;
reset role;
update pg_temp.n set c = c + 1;
select pg_temp.ok((select count(*) = 1 from core.audit_log where action = 'REPRINT' and new_data ->> 'reason' = 'Tem rách'), 'In lại tem lưu nhật ký lý do');
insert into core.delegations (from_user, to_user, role_code, valid_from, valid_to, reason)
values (pg_temp.uid('QLSX'), pg_temp.uid('NV1'), 'THU_KHO', now() - interval '1 hour', now() + interval '1 day', 'Nghỉ phép');
select pg_temp.as_user('NV1');
select pg_temp.ok((select (app.me() -> 'roles') ? 'THU_KHO' and jsonb_array_length(app.me() -> 'delegated_roles') = 1), 'app.me() có vai trò được ủy quyền');
reset role;

do $$ begin raise exception 'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt', (select c from pg_temp.n); end $$;
