-- Anh Bình 04/11/2026: tồn kho khởi tạo của nhà máy theo bảng "BMT - GIAO HÀNG.xlsx" (hàng đã giao về nhà máy, đến 01/11/2026).
-- Dữ liệu khởi tạo: kho phải trống (trước khi áp đã kiểm 0 phiếu, 0 tồn, 0 lô, 0 đơn vị chứa); còn dữ liệu thì dừng, không tự xóa.
-- Nhập bằng phiếu tồn đầu kỳ kho nguyên liệu KNL (inv.create_opening), Quản trị duyệt → ghi sổ ngay (inv._post).
-- Bảng không có đơn giá: đơn giá 0 (Quản trị đặt giá bình quân sau ở Kho → Tồn kho, app.admin_avg_cost).
-- Không nhập: thiết bị (máy hàn, máy đo đường kính, tủ sấy, máy in, tháp giải nhiệt, máy trộn…), PVC 50 kg mẫu giao về Gele,
-- 1 cuộn AL/PET (chưa rõ bề rộng, kg), hàng chưa về (silicone 915S/9710G/Z270, LSZH, HDPE, màu đen, AL/PET, TCCA, talc, PVC 3.000 kg).
insert into master.materials (code, name, group_code, purchase_spec, uom, loss_rate, density, has_expiry, requires_coa)
select 'PP-FILL-FR', 'Sợi độn PP chống cháy', m.group_code, m.purchase_spec, m.uom, m.loss_rate, m.density, m.has_expiry, m.requires_coa
  from master.materials m where m.code = 'PP-FILL'
on conflict (code) do nothing;

do $$
declare v_admin uuid; v_doc uuid; v_req uuid; v_res text;
begin
  if exists (select 1 from inv.stock_docs) or exists (select 1 from inv.handling_units) or exists (select 1 from inv.stock_balances where qty <> 0) then
    raise exception 'Kho đã có dữ liệu: dừng nhập tồn khởi tạo (kiểm tra lại trước khi xóa)';
  end if;
  select ur.user_id into v_admin from core.user_roles ur join core.profiles p on p.id = ur.user_id
   where ur.role_code = 'ADMIN' and p.status = 'ACTIVE' order by p.created_at limit 1;
  if v_admin is null then
    raise notice 'Chưa có Quản trị (DB dựng mới): bỏ qua nhập tồn khởi tạo';
    return;
  end if;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  v_doc := inv.create_opening(inv.wh('KNL'), date '2026-11-01', jsonb_build_array(
    jsonb_build_object('code', 'CU-024',     'qty', 2876.65, 'unit_cost', 0),  -- Đồng 0.24 – Sacom
    jsonb_build_object('code', 'TC-020',     'qty', 1003.36, 'unit_cost', 0),  -- Đồng mạ thiếc 0.2 – Aomaga, giao 30/10
    jsonb_build_object('code', 'SIL-9710G',  'qty', 100,     'unit_cost', 0),  -- Silicone 9710 – HZK
    jsonb_build_object('code', 'DCBP-50',    'qty', 60,      'unit_cost', 0),  -- DCBP – HZK
    jsonb_build_object('code', 'SI-C0',      'qty', 40,      'unit_cost', 0),  -- Màu nâu silicone – HZK
    jsonb_build_object('code', 'LSZH-S',     'qty', 100,     'unit_cost', 0),  -- LSZH cam – HZK
    jsonb_build_object('code', 'HDPE-I',     'qty', 100,     'unit_cost', 0),  -- HDPE – HZK
    jsonb_build_object('code', 'HD-B',       'qty', 20,      'unit_cost', 0),  -- Hạt màu đen – HZK
    jsonb_build_object('code', 'PP-FILL',    'qty', 156.7,   'unit_cost', 0),  -- Sợi độn PP – Đại Dương Long, 29/10
    jsonb_build_object('code', 'PP-FILL-FR', 'qty', 80,      'unit_cost', 0)   -- Sợi độn PP chống cháy – Đại Dương Long, 29/10
  ));
  select id into v_req from wf.approval_requests where doc_id = v_doc and status = 'PENDING' order by submitted_at desc limit 1;
  v_res := wf.act(v_req, 'APPROVE', 'Tồn kho khởi tạo nhà máy (dữ liệu anh Bình gửi 04/11/2026)');
  if v_res <> 'APPROVED' then raise exception 'Duyệt tồn đầu kỳ chưa xong: %', v_res; end if;
  -- ghi chú sau khi duyệt (sửa trước khi duyệt làm đổi mã kiểm hồ sơ)
  update inv.stock_docs set note = 'Tồn kho khởi tạo theo bảng BMT - GIAO HÀNG (hàng đã giao nhà máy đến 01/11/2026), chưa có đơn giá'
   where id = v_doc;
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
