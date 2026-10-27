-- Kiểm thử migration 2200: áp dụng Quy chuẩn vai trò & nhiệm vụ nhân sự nhà máy BMT.
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK, không để lại dữ liệu.
-- Trong transaction, mọi tài khoản thật bị tạm ngưng để kết quả không phụ thuộc dữ liệu đang chạy (rollback ở cuối).
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
-- Nhãn các bước trong cấu hình đóng băng của một hồ sơ
create function pg_temp.steps(p_req uuid) returns text language sql as $$
  select string_agg(s ->> 'label', ' | ' order by (s ->> 'seq')::int)
  from wf.approval_requests r, jsonb_array_elements(r.flow_snapshot -> 'steps') s where r.id = p_req
$$;
set client_min_messages = notice;

-- ---------------------------------------------------------------- người dùng thử (tạm ngưng tài khoản thật)
update core.profiles set status = 'INACTIVE' where coalesce(employee_code, '') not like 'R\_%';
with u(code, role) as (values ('R_ADMIN','ADMIN'),('R_BGD','BGD'),('R_CT','BGD'),('R_KTTP','KT_TP'),('R_SXTP','SX_TP'),('R_SXTP','THU_KHO'),
  ('R_SXKH','SX_KH'),('R_MUANV','MUA_NV'),('R_MUATP','MUA_TP'),('R_KTKHO','KT_KHO'),('R_KTT','KTT'),('R_KHO5','KHO_NV'),('R_KHO5','VAN_HANH'),
  ('R_VH','VAN_HANH'),('R_QC','QC')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from (select distinct code from u) x returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Thử ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('R_ADMIN','ADMIN'),('R_BGD','BGD'),('R_CT','BGD'),('R_KTTP','KT_TP'),('R_SXTP','SX_TP'),
  ('R_SXTP','THU_KHO'),('R_SXKH','SX_KH'),('R_MUANV','MUA_NV'),('R_MUATP','MUA_TP'),('R_KTKHO','KT_KHO'),('R_KTT','KTT'),('R_KHO5','KHO_NV'),
  ('R_KHO5','VAN_HANH'),('R_VH','VAN_HANH'),('R_QC','QC')) u(code, role) on u.code = p.employee_code;
update wf.approval_steps set assignee_ids = array[pg_temp.uid('R_CT')] where (doc_type = 'PLAN' and seq = 2) or (doc_type = 'PO' and seq = 3);

-- Spec PFR-2C-1P5 phát hành (nếu chưa) để có lệnh SX
do $$ begin
  if (select s.status from master.products p join master.product_specs s on s.id = p.current_spec_id where p.code = 'PFR-2C-1P5') <> 'RELEASED' then
    perform set_config('request.jwt.claim.sub', (select id::text from core.profiles where employee_code = 'R_ADMIN'), true);
    perform set_config('bmt.wf_release', 'on', true);
    perform master.release_spec((select current_spec_id from master.products where code = 'PFR-2C-1P5'));
    perform set_config('bmt.wf_release', 'off', true);
  end if;
end $$;

-- ================================================================ A. Vai trò
select pg_temp.ok((select name from core.roles where code = 'SX_TP') = 'Quản lý sản xuất', 'Vai trò SX_TP hiển thị "Quản lý sản xuất"');
select pg_temp.as_user('R_ADMIN');
select pg_temp.fails($$select app.admin_upsert_user(pg_temp.uid('R_VH'), 'Thử r_vh', 'R_VH', 'SX', null, array['THU_KHO','KT_KHO'])$$,
  'Không gán chung', 'Chặn gán Thủ kho + Kế toán kho cho một người');
select pg_temp.fails($$select app.admin_upsert_user(pg_temp.uid('R_VH'), 'Thử r_vh', 'R_VH', 'SX', null, array['KTT','KT_KHO'])$$,
  'Không gán chung', 'Chặn gán Kế toán trưởng + Kế toán kho cho một người');
select pg_temp.fails($$select app.admin_upsert_user(pg_temp.uid('R_VH'), 'Thử r_vh', 'R_VH', 'SX', null, array['THU_KHO','MUA_NV'])$$,
  'Không gán chung', 'Chặn gán Thủ kho + NV mua hàng cho một người');
select app.admin_upsert_user(pg_temp.uid('R_VH'), 'Thử r_vh', 'R_VH', 'SX', null, array['THU_KHO','KT_KHO','ADMIN']);
select pg_temp.ok((select count(*) = 3 from core.user_roles where user_id = pg_temp.uid('R_VH')), 'Tài khoản Quản trị (chạy thử) được miễn kiểm tra xung đột');
select app.admin_upsert_user(pg_temp.uid('R_VH'), 'Thử r_vh', 'R_VH', 'SX', null, array['VAN_HANH']);

-- ================================================================ B. Phạm vi kho
select app.admin_set_warehouses(pg_temp.uid('R_KHO5'), array['KTP']);
select pg_temp.ok((select warehouses = array['KTP'] from app.v_users where id = pg_temp.uid('R_KHO5')), 'Gán NV5 chỉ kho thành phẩm');
select pg_temp.fails($$select app.admin_set_warehouses(pg_temp.uid('R_KHO5'), array['KHO-X'])$$, 'Mã kho không hợp lệ', 'Chặn mã kho sai');

-- Nhập 500 kg đồng vào kho nguyên liệu (Quản lý SX kiêm thủ kho)
insert into inv.lots (lot_no, item_kind, material_id, uom, qc_status) select 'R-CU-1', 'MAT', id, 'kg', 'PASSED' from master.materials where code = 'CU-024';
insert into inv.stock_docs (doc_no, doc_type, warehouse_id, ref_type) select 'R-GR-1', 'GR', id, 'PO' from inv.warehouses where code = 'KNL';
insert into inv.stock_doc_lines (doc_id, line_no, lot_id, qty, unit_cost)
select (select id from inv.stock_docs where doc_no = 'R-GR-1'), 1, id, 500, 268000 from inv.lots where lot_no = 'R-CU-1';
insert into inv.stock_docs (doc_no, doc_type, warehouse_id, ref_type) select 'R-GR-2', 'GR', id, 'PO' from inv.warehouses where code = 'KNL';
insert into inv.stock_doc_lines (doc_id, line_no, lot_id, qty, unit_cost)
select (select id from inv.stock_docs where doc_no = 'R-GR-2'), 1, id, 1, 268000 from inv.lots where lot_no = 'R-CU-1';
select pg_temp.as_user('R_KHO5');
select pg_temp.fails($$select inv.post_doc((select id from inv.stock_docs where doc_no = 'R-GR-2'))$$, 'không được giao kho', 'NV5 không ghi sổ kho nguyên liệu');
select pg_temp.as_user('R_SXTP');
select inv.post_doc((select id from inv.stock_docs where doc_no = 'R-GR-1'));
select pg_temp.ok((select status from inv.stock_docs where doc_no = 'R-GR-1') = 'POSTED', 'Quản lý SX (thủ kho) ghi sổ nhập kho nguyên liệu');

-- ================================================================ C. PO theo hạn mức
insert into core.partners (code, name, is_supplier, partner_type) values ('R-NCC-CU', 'NCC đồng cũ (thử)', true, 'SUPPLIER'),
  ('R-NCC-NEW', 'NCC mới (thử)', true, 'SUPPLIER');
insert into purchase.purchase_orders (po_no, supplier_id, status) select 'R-PO-OLD', id, 'CLOSED' from core.partners where code = 'R-NCC-CU';
create function pg_temp.mk_po(p_no text, p_sup text, p_amount numeric, p_import boolean default false) returns uuid language sql as $$
  with po as (insert into purchase.purchase_orders (po_no, supplier_id, is_import)
              select p_no, id, p_import from core.partners where code = p_sup returning id)
  insert into purchase.po_lines (po_id, line_no, material_id, qty, unit_price)
  select po.id, 1, m.id, 1, p_amount from po, master.materials m where m.code = 'CU-024' returning po_id
$$;
select pg_temp.as_user('R_MUANV');
insert into t select 'po10', wf.submit('PO', pg_temp.mk_po('R-PO-10', 'R-NCC-CU', 10000000), 'R-PO-10');
insert into t select 'po50', wf.submit('PO', pg_temp.mk_po('R-PO-50', 'R-NCC-CU', 50000000), 'R-PO-50');
insert into t select 'po200', wf.submit('PO', pg_temp.mk_po('R-PO-200', 'R-NCC-CU', 200000000), 'R-PO-200');
insert into t select 'po250', wf.submit('PO', pg_temp.mk_po('R-PO-250', 'R-NCC-CU', 250000000), 'R-PO-250');
insert into t select 'ponew', wf.submit('PO', pg_temp.mk_po('R-PO-NEW', 'R-NCC-NEW', 10000000), 'R-PO-NEW');
insert into t select 'poimp', wf.submit('PO', pg_temp.mk_po('R-PO-IMP', 'R-NCC-CU', 10000000, true), 'R-PO-IMP');
select pg_temp.ok(pg_temp.steps((select v from t where k = 'po10')) = 'Giám đốc ký', 'PO dưới 20 triệu, NCC cũ: chỉ Giám đốc ký');
select pg_temp.ok(pg_temp.steps((select v from t where k = 'po50')) = 'TP mua hàng duyệt | Giám đốc ký', 'PO 50 triệu: TP mua hàng → Giám đốc');
select pg_temp.ok(pg_temp.steps((select v from t where k = 'po200')) = 'TP mua hàng duyệt | Giám đốc ký', 'PO đúng 200 triệu: chưa cần Chủ tịch');
select pg_temp.ok(pg_temp.steps((select v from t where k = 'po250')) = 'TP mua hàng duyệt | Giám đốc ký | Chủ tịch HĐQT phê duyệt', 'PO 250 triệu: thêm Chủ tịch HĐQT');
select pg_temp.ok(pg_temp.steps((select v from t where k = 'ponew')) = 'TP mua hàng duyệt | Giám đốc ký', 'PO nhà cung cấp mới (dưới 20 triệu): thêm TP mua hàng');
select pg_temp.ok(pg_temp.steps((select v from t where k = 'poimp')) = 'TP mua hàng duyệt | Giám đốc ký | Chủ tịch HĐQT phê duyệt', 'PO nhập khẩu (dưới 20 triệu): đủ 3 cấp');
insert into purchase.purchase_orders (po_no, supplier_id) select 'R-PO-NOPRICE', id from core.partners where code = 'R-NCC-CU';
insert into purchase.po_lines (po_id, line_no, material_id, qty)
select (select id from purchase.purchase_orders where po_no = 'R-PO-NOPRICE'), 1, id, 5 from master.materials where code = 'CU-024';
select pg_temp.fails($$select wf.submit('PO', (select id from purchase.purchase_orders where po_no = 'R-PO-NOPRICE'), 'R-PO-NOPRICE')$$,
  'chưa có đơn giá', 'PO thiếu đơn giá: không gửi duyệt được');

-- ================================================================ D. Người duyệt duy nhất là người lập
select pg_temp.as_user('R_MUATP');
insert into t select 'po_tp', wf.submit('PO', pg_temp.mk_po('R-PO-TP', 'R-NCC-CU', 50000000), 'R-PO-TP');
select pg_temp.ok(pg_temp.steps((select v from t where k = 'po_tp')) = 'Giám đốc ký', 'TP mua hàng tự lập PO: bỏ bước TP mua, Giám đốc vẫn ký');
select pg_temp.as_user('R_BGD');
insert into purchase.purchase_requests (pr_no, source) values ('R-PR-1', 'MANUAL');
insert into t select 'pr_bgd', wf.submit('PR', (select id from purchase.purchase_requests where pr_no = 'R-PR-1'), 'R-PR-1');
select pg_temp.fails($$select wf.act((select v from t where k = 'pr_bgd'), 'APPROVE')$$, 'không tự duyệt', 'Giám đốc lập PR thì Giám đốc khác (Chủ tịch) duyệt, không tự duyệt');

-- ================================================================ E. Lệnh SX, phát lệnh, phiếu lĩnh theo định mức
insert into mfg.work_orders (wo_no, product_id, spec_id, bom_id, qty_m, m_per_pack, pack_type, brand)
select 'R-LSX-1', p.id, p.current_spec_id, h.id, 3500, 500, 'Bobin gỗ', 'KAVIX'
from master.products p join master.bom_headers h on h.spec_id = p.current_spec_id where p.code = 'PFR-2C-1P5';
insert into mfg.work_orders (wo_no, product_id, spec_id, bom_id, qty_m, m_per_pack, pack_type, brand)
select 'R-LSX-2', p.id, p.current_spec_id, h.id, 1000, 500, 'Bobin gỗ', 'KAVIX'
from master.products p join master.bom_headers h on h.spec_id = p.current_spec_id where p.code = 'PFR-2C-1P5';
select pg_temp.as_user('R_VH');
select pg_temp.fails($$select mfg.release_wo((select id from mfg.work_orders where wo_no = 'R-LSX-2'))$$, 'qua quy trình duyệt', 'Công nhân không gọi thẳng hàm phát lệnh SX');
select pg_temp.fails($$select master.release_spec((select current_spec_id from master.products where code = 'SIF-1C-1P5'))$$, 'qua quy trình duyệt', 'Không gọi thẳng hàm phát hành spec');
select pg_temp.fails($$select inv.create_wo_issue((select id from mfg.work_orders where wo_no = 'R-LSX-1'))$$, 'Không có quyền', 'Công nhân không lập phiếu lĩnh');
select pg_temp.as_user('R_SXTP');
select pg_temp.fails($$select inv.create_wo_issue((select id from mfg.work_orders where wo_no = 'R-LSX-1'))$$, 'chưa phát lệnh', 'Lệnh chưa phát thì không lĩnh');
select mfg.release_wo((select id from mfg.work_orders where wo_no = 'R-LSX-1'));
select pg_temp.fails($$select mfg.release_wo((select id from mfg.work_orders where wo_no = 'R-LSX-1'))$$, 'trạng thái RELEASED', 'Không phát lệnh lại lệnh đã phát');
-- Phiếu lĩnh theo định mức (module kho 2400–2600: inv.requisitions, cấp bằng quét QR ở trang Cấp NVL)
insert into t select 'iss1', inv.create_wo_issue((select id from mfg.work_orders where wo_no = 'R-LSX-1'), 1000);
select pg_temp.ok((select rq.kind = 'NORM' and rq.status = 'APPROVED' and rq.qty_m = 1000 from inv.requisitions rq where rq.id = (select v from t where k = 'iss1')),
  'Phiếu lĩnh ca 1.000 m tạo theo định mức, sẵn sàng cấp');
insert into t select 'iss2', inv.create_wo_issue((select id from mfg.work_orders where wo_no = 'R-LSX-1'));
select pg_temp.ok((select abs(sum(rl.qty_norm) - max(s.std_qty)) < 0.002
  from inv.requisition_lines rl join master.materials m on m.id = rl.material_id and m.code = 'CU-024'
  join mfg.wo_std_materials((select id from mfg.work_orders where wo_no = 'R-LSX-1')) s on s.material_id = rl.material_id
  where rl.req_id in ((select v from t where k = 'iss1'), (select v from t where k = 'iss2'))), 'Hai phiếu lĩnh cộng lại đúng định mức đồng của lệnh');
select pg_temp.fails($$select inv.create_wo_issue((select id from mfg.work_orders where wo_no = 'R-LSX-1'))$$, 'đã lĩnh đủ định mức', 'Lĩnh lần 3: lệnh đã lĩnh đủ định mức');
insert into inv.stock_docs (doc_no, doc_type, warehouse_id, ref_type, ref_id)
select 'R-IS-X', 'ISSUE_WO', id, 'WO', (select id from mfg.work_orders where wo_no = 'R-LSX-1') from inv.warehouses where code = 'KNL';
insert into inv.stock_doc_lines (doc_id, line_no, lot_id, qty)
select (select id from inv.stock_docs where doc_no = 'R-IS-X'), 1, l.id, s.std_qty + 1 from inv.lots l
  join mfg.wo_std_materials((select id from mfg.work_orders where wo_no = 'R-LSX-1')) s on s.material_id = l.material_id where l.lot_no = 'R-CU-1';
select pg_temp.fails($$select inv.post_doc((select id from inv.stock_docs where doc_no = 'R-IS-X'))$$, 'Vượt định mức', 'Thủ kho tự xuất quá định mức lệnh: bị chặn');
insert into inv.stock_docs (doc_no, doc_type, warehouse_id) select 'R-IS-NOWO', 'ISSUE_WO', id from inv.warehouses where code = 'KNL';
insert into inv.stock_doc_lines (doc_id, line_no, lot_id, qty) select (select id from inv.stock_docs where doc_no = 'R-IS-NOWO'), 1, id, 1 from inv.lots where lot_no = 'R-CU-1';
select pg_temp.fails($$select inv.post_doc((select id from inv.stock_docs where doc_no = 'R-IS-NOWO'))$$, 'phải gắn lệnh sản xuất', 'Phiếu xuất sản xuất không gắn lệnh SX: bị chặn');
select pg_temp.as_user('R_KHO5');
select pg_temp.fails($$select inv.create_wo_issue((select id from mfg.work_orders where wo_no = 'R-LSX-1'), 100)$$, 'không được giao kho', 'NV5 (chỉ kho thành phẩm) không lĩnh ở kho nguyên liệu');

-- Cấp bổ sung vượt định mức: Quản lý SX lập phiếu lĩnh bổ sung, TP Kỹ thuật/QA duyệt, rồi mới cấp
select pg_temp.as_user('R_SXTP');
select pg_temp.fails($$select wf.submit('EXTRA_ISSUE', (select id from inv.stock_docs where doc_no = 'R-IS-X'), 'R-IS-X')$$, 'Không tìm thấy phiếu lĩnh bổ sung',
  'Không gửi duyệt thẳng phiếu xuất: phải lập phiếu lĩnh bổ sung');
insert into t select 'rx', inv.create_extra_requisition((select id from mfg.work_orders where wo_no = 'R-LSX-1'), '[{"material_code":"CU-024","qty":1}]', 'EX_SCRAP', 'Bù đứt dây');
insert into t select 'req_extra', (select id from wf.approval_requests where doc_id = (select v from t where k = 'rx'));
select pg_temp.ok(pg_temp.steps((select v from t where k = 'req_extra')) = 'TP Kỹ thuật/QA duyệt cấp vượt định mức', 'Cấp vượt định mức do TP Kỹ thuật/QA duyệt');
select pg_temp.as_user('R_KTTP'); select wf.act((select v from t where k = 'req_extra'), 'APPROVE');
select pg_temp.as_user('R_SXTP');
update inv.stock_doc_lines set qty = 1 where doc_id = (select id from inv.stock_docs where doc_no = 'R-IS-X');
update inv.stock_docs set requisition_id = (select v from t where k = 'rx') where doc_no = 'R-IS-X';
select inv.post_doc((select id from inv.stock_docs where doc_no = 'R-IS-X'));
select pg_temp.ok((select status from inv.stock_docs where doc_no = 'R-IS-X') = 'POSTED'
  and (select status from inv.requisitions where id = (select v from t where k = 'rx')) = 'DONE', 'Phiếu lĩnh bổ sung đã duyệt thì cấp được, cấp đủ thì đóng');
select pg_temp.as_user('R_KTKHO');
select pg_temp.fails($$select wf.submit('STOCK_ADJ', (select id from inv.stock_docs where doc_no = 'R-GR-2'), 'R-GR-2')$$, 'không thuộc quy trình',
  'Không dùng quy trình kiểm kê để duyệt phiếu nhập mua');

-- TP Kỹ thuật/QA tự xin cấp bổ sung: không ai khác giữ vai trò → chuyển Giám đốc
insert into core.user_roles (user_id, role_code) values (pg_temp.uid('R_KTTP'), 'SX_KH') on conflict do nothing;
select pg_temp.as_user('R_KTTP');
insert into t select 'rx_kt', inv.create_extra_requisition((select id from mfg.work_orders where wo_no = 'R-LSX-1'), '[{"material_code":"CU-024","qty":1}]', 'EX_SCRAP', null);
insert into t select 'req_kt', (select id from wf.approval_requests where doc_id = (select v from t where k = 'rx_kt'));
select pg_temp.ok((select (s ->> 'role') = 'BGD' and (s ->> 'label') like '%chuyển Giám đốc'
  from wf.approval_requests q, jsonb_array_elements(q.flow_snapshot -> 'steps') s where q.id = (select v from t where k = 'req_kt')),
  'Người duyệt duy nhất là người lập: bước tự chuyển Giám đốc');

-- ================================================================ F. Kế toán SX đánh dấu "Đã kiểm"
insert into inv.stock_docs (doc_no, doc_type, warehouse_id, ref_type, ref_id)
select 'R-IS-OK', 'ISSUE_WO', id, 'WO', (select id from mfg.work_orders where wo_no = 'R-LSX-1') from inv.warehouses where code = 'KNL';
insert into inv.stock_doc_lines (doc_id, line_no, lot_id, qty)   -- phần còn lại của định mức đồng (đã cấp bổ sung 1 kg)
select (select id from inv.stock_docs where doc_no = 'R-IS-OK'), 1, l.id, s.std_qty - 1 from inv.lots l
  join mfg.wo_std_materials((select id from mfg.work_orders where wo_no = 'R-LSX-1')) s on s.material_id = l.material_id where l.lot_no = 'R-CU-1';
select pg_temp.as_user('R_SXTP');
select inv.post_doc((select id from inv.stock_docs where doc_no = 'R-IS-OK'));
update t set v = (select id from inv.stock_docs where doc_no = 'R-IS-OK') where k = 'iss1';
update t set v = (select id from inv.stock_docs where doc_no = 'R-IS-X') where k = 'iss2';
select pg_temp.fails($$select app.review_stock_docs(array[(select v from t where k = 'iss1')])$$, 'Chỉ Kế toán kho', 'Thủ kho không tự đánh dấu đã kiểm');
select pg_temp.as_user('R_KTKHO');
select pg_temp.ok(app.review_stock_docs(array[(select v from t where k = 'iss1'), (select v from t where k = 'iss2'),
  (select id from inv.stock_docs where doc_no = 'R-IS-NOWO')]) = 2, 'Kế toán SX kiểm 2 phiếu đã ghi sổ (bỏ qua phiếu chưa ghi sổ)');
select pg_temp.ok((select reviewed_by_name is not null and wo_no = 'R-LSX-1' and review_status = 'CONFIRMED' from app.v_stock_docs where id = (select v from t where k = 'iss1')),
  'Danh sách phiếu hiện người kiểm và số lệnh SX');

-- ================================================================ G. Cân bằng đồng
select pg_temp.ok((select issued_kg > 0 and not finished and not over_limit from app.copper_balance() where wo_no = 'R-LSX-1'),
  'Cân bằng đồng: lệnh đang chạy chưa đánh giá vượt ngưỡng');
insert into inv.lots (lot_no, item_kind, product_id, spec_id, uom, qc_status)
select 'R-BB-1', 'FG', p.id, p.current_spec_id, 'm', 'PENDING' from master.products p where p.code = 'PFR-2C-1P5';
insert into mfg.wo_outputs (wo_op_id, lot_id, qty_m)
select o.id, (select id from inv.lots where lot_no = 'R-BB-1'), 3500 from mfg.wo_operations o join mfg.work_orders w on w.id = o.wo_id
 where w.wo_no = 'R-LSX-1' and o.op_code = 'CD6';
insert into mfg.scrap_records (wo_op_id, scrap_material_id, reason_code, qty_kg)
select o.id, (select id from master.materials where code = 'PL-CU'), 'SC_BREAK', 1.5 from mfg.wo_operations o join mfg.work_orders w on w.id = o.wo_id
 where w.wo_no = 'R-LSX-1' and o.op_code = 'CD1';
update mfg.work_orders set status = 'PRODUCED' where wo_no = 'R-LSX-1';
select pg_temp.ok((select finished and scrap_kg = 1.5 and abs(diff_kg - (issued_kg - product_kg - scrap_kg)) <= 0.002
  and over_limit = (abs(diff_pct) > tolerance_pct) from app.copper_balance() where wo_no = 'R-LSX-1'),
  'Cân bằng đồng: lệch = đồng xuất − đồng trong thành phẩm − phế đồng, so với ngưỡng cho phép');
select pg_temp.as_user('R_VH');
select pg_temp.fails($$select app.set_control_setting('copper_tolerance_pct', 50)$$, 'được chỉnh', 'Công nhân không đổi ngưỡng lệch đồng');
select pg_temp.as_user('R_KTTP');
select app.set_control_setting('copper_tolerance_pct', 99);
select pg_temp.ok((select not over_limit and tolerance_pct = 99 from app.copper_balance() where wo_no = 'R-LSX-1'), 'TP Kỹ thuật/QA chỉnh ngưỡng lệch đồng');

-- ================================================================ H. Duyệt thay khi quá hạn (Kế toán trưởng → Giám đốc)
insert into inv.stock_docs (doc_no, doc_type, warehouse_id, reason_code) select 'R-ADJ-1', 'ADJ', id, 'ADJ_COUNT' from inv.warehouses where code = 'KNL';
insert into inv.stock_doc_lines (doc_id, line_no, lot_id, qty) select (select id from inv.stock_docs where doc_no = 'R-ADJ-1'), 1, id, -2 from inv.lots where lot_no = 'R-CU-1';
insert into inv.stock_docs (doc_no, doc_type, warehouse_id, reason_code) select 'R-ADJ-2', 'ADJ', id, 'ADJ_COUNT' from inv.warehouses where code = 'KNL';
insert into inv.stock_doc_lines (doc_id, line_no, lot_id, qty) select (select id from inv.stock_docs where doc_no = 'R-ADJ-2'), 1, id, -1 from inv.lots where lot_no = 'R-CU-1';
select pg_temp.as_user('R_SXTP');
select pg_temp.fails($$select wf.submit('STOCK_ADJ', (select id from inv.stock_docs where doc_no = 'R-ADJ-1'), 'R-ADJ-1')$$, 'cần vai trò', 'Thủ kho không tự lập biên bản điều chỉnh kiểm kê');
select pg_temp.as_user('R_KTKHO');
insert into t select 'adj1', wf.submit('STOCK_ADJ', (select id from inv.stock_docs where doc_no = 'R-ADJ-1'), 'R-ADJ-1');
insert into t select 'adj2', wf.submit('STOCK_ADJ', (select id from inv.stock_docs where doc_no = 'R-ADJ-2'), 'R-ADJ-2');
select pg_temp.ok(pg_temp.steps((select v from t where k = 'adj1')) = 'Kế toán trưởng duyệt chênh lệch kiểm kê', 'Kiểm kê: Kế toán SX lập biên bản → Kế toán trưởng duyệt');
select pg_temp.as_user('R_BGD');
select pg_temp.fails($$select wf.act((select v from t where k = 'adj1'), 'APPROVE')$$, 'cần vai trò', 'Chưa quá hạn: Giám đốc chưa duyệt thay Kế toán trưởng');
update wf.approval_requests set step_started_at = now() - interval '25 hours' where id in ((select v from t where k = 'adj1'), (select v from t where k = 'adj2'));
select pg_temp.ok((select my_turn from app.v_approvals where id = (select v from t where k = 'adj1')), 'Quá hạn: phiếu hiện trong việc chờ của Giám đốc');
select wf.act((select v from t where k = 'adj1'), 'APPROVE', 'Đã đối chiếu');
select pg_temp.ok((select status from inv.stock_docs where doc_no = 'R-ADJ-1') = 'POSTED'
  and (select comment from wf.approval_actions where request_id = (select v from t where k = 'adj1') order by id desc limit 1) like '[Duyệt thay do quá hạn]%',
  'Quá hạn: Giám đốc duyệt thay, ghi rõ "duyệt thay do quá hạn"; duyệt xong tự ghi sổ');
reset role;
select wf.check_sla();
select pg_temp.ok(exists (select 1 from wf.notifications where user_id = pg_temp.uid('R_BGD') and title = 'Có thể duyệt thay: R-ADJ-2'),
  'Quá hạn: hệ thống báo Giám đốc có thể duyệt thay');

-- ================================================================ I. Kế hoạch tháng, PR từ MRP, Spec thay đổi nhỏ
select pg_temp.as_user('R_SXKH');
insert into plan.production_plans (plan_no, period_label, material_need_date) values ('R-KH-1', 'Thử 2200', current_date + 30);
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, run_lots, m_per_pack, pack_type, brand)
select pp.id, p.id, p.current_spec_id, 1000, 1, 500, 'Bobin gỗ', 'KAVIX' from plan.production_plans pp, master.products p
 where pp.plan_no = 'R-KH-1' and p.code = 'PFR-2C-1P5';
insert into t select 'run', plan.run_mrp((select id from plan.production_plans where plan_no = 'R-KH-1'));
select pg_temp.as_user('R_MUANV');
select pg_temp.fails($$select wf.submit('PLAN', (select id from plan.production_plans where plan_no = 'R-KH-1'), 'R-KH-1')$$, 'quyền', 'NV mua hàng không gửi duyệt kế hoạch tháng');
select pg_temp.fails($$select plan.create_pr_from_mrp((select v from t where k = 'run'))$$, 'được phê duyệt', 'NV mua hàng có quyền sinh PR (chờ kế hoạch được duyệt)');
-- Quy trình final 27/10/2026: TP SX (Kế hoạch SX) lập kế hoạch tháng, Chủ tịch HĐQT duyệt
select pg_temp.as_user('R_SXKH');
insert into t select 'plan_req', wf.submit('PLAN', (select id from plan.production_plans where plan_no = 'R-KH-1'), 'R-KH-1');
select pg_temp.ok(pg_temp.steps((select v from t where k = 'plan_req')) = 'Chủ tịch HĐQT phê duyệt', 'Kế hoạch tháng: TP SX lập → Chủ tịch HĐQT phê duyệt');
select pg_temp.as_user('R_CT');   select wf.act((select v from t where k = 'plan_req'), 'APPROVE');
select pg_temp.as_user('R_MUANV');
insert into t select 'pr_mrp', plan.create_pr_from_mrp((select v from t where k = 'run'));
select pg_temp.ok((select count(*) > 0 from purchase.pr_lines where pr_id = (select v from t where k = 'pr_mrp')), 'NV mua hàng sinh PR từ MRP sau khi Chủ tịch duyệt kế hoạch');
select pg_temp.ok(not exists (select 1 from app.v_flow_config where doc_type = 'SPEC_MINOR'), 'Quy trình Spec thay đổi nhỏ không còn trong cài đặt');
select pg_temp.ok((select count(*) > 0 from app.v_approvals), 'Hộp duyệt đọc được với cấu hình mới');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
