-- Anh Bình 04/11/2026: hàng chưa về trong bảng "BMT - GIAO HÀNG.xlsx" là hàng đã đặt, đang trên đường về, có ngày giao dự kiến.
-- Nhập thành đơn mua đã duyệt (đặt trước khi dùng MES) để MES tính "hàng đang về" (MRP, tồn dự phòng) và Kho nhận hàng theo đơn:
--   * NCC HZK (hàng nhập khẩu): silicone 915S 200, 9710G 3.000, Z270 200 kg (dự kiến 14–16/11); LSZH cam 1.750, HDPE 1.750,
--     hạt màu đen 10 kg (dự kiến 06/11); băng AL/PET 2 × 500 kg (dự kiến 05/11); drain TCCA 1.009,85 kg (dự kiến 18/11);
--   * NCC Nhật Huy: PVC vỏ xám 3.000 kg (bảng chưa có ngày giao, chỉ ghi thời gian sản xuất 4–5 ngày);
--   * Talc 50–100 kg (bảng chưa ghi NCC, dự kiến 29–30/10): ghi 100 kg, chưa chọn NCC.
-- Ngày về dự kiến ghi theo ngày cuối của khoảng. Bảng không có đơn giá: đơn giá để trống (nhận hàng vẫn được, giá thành chờ cập nhật).
-- Vật tư mới: SIL-915S, SIL-Z270 (chép thuộc tính từ SIL-9710G). Chạy lại không tạo trùng.
insert into master.materials (code, name, group_code, purchase_spec, uom, loss_rate, density, has_expiry, requires_coa)
select x.code, x.name, m.group_code, x.spec, m.uom, m.loss_rate, m.density, m.has_expiry, m.requires_coa
  from master.materials m,
       (values ('SIL-915S', 'Silicone 915S', 'Silicone 915S (HZK)'), ('SIL-Z270', 'Silicone Z270', 'Silicone Z270 (HZK)')) x(code, name, spec)
 where m.code = 'SIL-9710G'
on conflict (code) do nothing;

do $$
declare v_admin uuid; v_hzk uuid; v_nh uuid; v_po uuid; v_n int;
  v_note constant text := 'Đơn đã đặt trước khi dùng MES (bảng BMT - GIAO HÀNG, anh Bình 04/11/2026), hàng đang về; chưa có đơn giá.';
begin
  if exists (select 1 from purchase.purchase_orders where note like 'Đơn đã đặt trước khi dùng MES (bảng BMT - GIAO HÀNG%') then
    raise notice 'Đã nhập đơn mua đang về: bỏ qua'; return;
  end if;
  select ur.user_id into v_admin from core.user_roles ur join core.profiles p on p.id = ur.user_id
   where ur.role_code = 'ADMIN' and p.status = 'ACTIVE' order by p.created_at limit 1;

  -- Nhà cung cấp
  select id into v_hzk from core.partners where lower(name) = 'hzk';
  if v_hzk is null then
    select count(*) + 1 into v_n from core.partners where code like 'NCC-%';
    while exists (select 1 from core.partners where code = 'NCC-' || lpad(v_n::text, 3, '0')) loop v_n := v_n + 1; end loop;
    insert into core.partners (code, name, is_supplier, partner_type, address, created_by)
    values ('NCC-' || lpad(v_n::text, 3, '0'), 'HZK', true, 'SUPPLIER', 'Trung Quốc (hàng nhập khẩu)', v_admin) returning id into v_hzk;
  end if;
  select id into v_nh from core.partners where lower(name) = 'nhật huy';
  if v_nh is null then
    select count(*) + 1 into v_n from core.partners where code like 'NCC-%';
    while exists (select 1 from core.partners where code = 'NCC-' || lpad(v_n::text, 3, '0')) loop v_n := v_n + 1; end loop;
    insert into core.partners (code, name, is_supplier, partner_type, created_by)
    values ('NCC-' || lpad(v_n::text, 3, '0'), 'Nhật Huy', true, 'SUPPLIER', v_admin) returning id into v_nh;
  end if;

  -- Đơn HZK
  insert into purchase.purchase_orders (po_no, supplier_id, status, order_date, expected_date, note, is_import, source, created_by)
  values (core.next_no('PO'), v_hzk, 'APPROVED', date '2026-10-22', date '2026-11-18', v_note, true, 'MANUAL', v_admin) returning id into v_po;
  insert into purchase.po_lines (po_id, line_no, material_id, qty, expected_date, note)
  select v_po, x.n, m.id, x.q, x.d, x.note
    from (values (1, 'SIL-9710G', 3000::numeric, date '2026-11-16', 'Dự kiến 14–16/11 (ETD 04/11, vận chuyển 7 ngày)'),
                 (2, 'SIL-915S', 200, date '2026-11-16', 'Dự kiến 14–16/11'),
                 (3, 'SIL-Z270', 200, date '2026-11-16', 'Dự kiến 14–16/11'),
                 (4, 'LSZH-S', 1750, date '2026-11-06', 'LSZH cam (pha màu sẵn); ETD 04/11, ETA 06/11'),
                 (5, 'HDPE-I', 1750, date '2026-11-06', 'Dự kiến 06/11'),
                 (6, 'HD-B', 10, date '2026-11-06', 'Hạt màu đen; dự kiến 06/11'),
                 (7, 'ALP-20', 1000, date '2026-11-05', 'Băng AL/PET 2 × 500 kg; dự kiến 05/11 – kiểm bề rộng khi nhận (bảng không ghi)'),
                 (8, 'TCCA-020', 1009.85, date '2026-11-18', 'Drain TCCA; ETD 07/11, dự kiến 18/11')) x(n, c, q, d, note)
    join master.materials m on m.code = x.c;

  -- Đơn Nhật Huy
  insert into purchase.purchase_orders (po_no, supplier_id, status, order_date, expected_date, note, source, created_by)
  values (core.next_no('PO'), v_nh, 'APPROVED', date '2026-10-22', null,
          v_note || ' Bảng chưa ghi ngày giao (thời gian sản xuất 4–5 ngày): NV mua cập nhật ngày về dự kiến.', 'MANUAL', v_admin)
  returning id into v_po;
  insert into purchase.po_lines (po_id, line_no, material_id, qty, note)
  select v_po, 1, id, 3000, 'PVC vỏ xám (pha màu sẵn); mẫu 50 kg đã về 26/10' from master.materials where code = 'PVC-S';

  -- Talc (chưa có NCC)
  insert into purchase.purchase_orders (po_no, supplier_id, status, order_date, expected_date, note, source, created_by)
  values (core.next_no('PO'), null, 'APPROVED', date '2026-10-22', date '2026-10-30',
          v_note || ' Bảng chưa ghi NCC: NV mua chọn NCC.', 'MANUAL', v_admin)
  returning id into v_po;
  insert into purchase.po_lines (po_id, line_no, material_id, qty, expected_date, note)
  select v_po, 1, id, 100, date '2026-10-30', 'Bảng ghi 50–100 kg, dự kiến 29–30/10 (chưa về)' from master.materials where code = 'TALC';
end $$;
