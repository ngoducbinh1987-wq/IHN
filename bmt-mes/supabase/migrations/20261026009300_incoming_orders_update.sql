-- Anh Bình 04/11/2026: bổ sung đơn mua đang về (migration 9200):
--   * PVC Nhật Huy dự kiến về 14/11;
--   * băng AL/PET rộng 20 mm (ALP-20, đúng như đã nhập);
--   * talc 50 kg;
--   * phần còn lại của các lô HZK đã giao một phần cũng đã đặt: silicone 9710G 400 kg (500 − 100 đã về) dự kiến 10/11;
--     LSZH cam 150 kg, HDPE 150 kg (250 − 100 đã về) dự kiến 11/11 → một đơn mua HZK mới (đã duyệt, chưa có giá).
-- (DCBP 60/60, màu nâu 40 ≥ 39 kg, hạt màu đen 20/20 đã về đủ.) Chạy lại không làm trùng.
do $$
declare v_admin uuid; v_hzk uuid; v_po uuid;
  v_mark constant text := 'Đơn đã đặt trước khi dùng MES (bảng BMT - GIAO HÀNG';
begin
  select ur.user_id into v_admin from core.user_roles ur join core.profiles p on p.id = ur.user_id
   where ur.role_code = 'ADMIN' and p.status = 'ACTIVE' order by p.created_at limit 1;

  -- PVC: ngày về 14/11
  update purchase.po_lines l set expected_date = date '2026-11-14', note = 'PVC vỏ xám (pha màu sẵn); mẫu 50 kg đã về 26/10; dự kiến về 14/11'
    from purchase.purchase_orders po, master.materials m
   where po.id = l.po_id and m.id = l.material_id and m.code = 'PVC-S' and po.note like v_mark || '%' and l.received_qty = 0;
  update purchase.purchase_orders po set expected_date = date '2026-11-14',
         note = replace(po.note, ' Bảng chưa ghi ngày giao (thời gian sản xuất 4–5 ngày): NV mua cập nhật ngày về dự kiến.', ' Dự kiến về 14/11.')
   where po.note like v_mark || '%' and exists (select 1 from purchase.po_lines l join master.materials m on m.id = l.material_id
                                                 where l.po_id = po.id and m.code = 'PVC-S');
  -- AL/PET: xác nhận rộng 20 mm
  update purchase.po_lines l set note = 'Băng AL/PET rộng 20 mm, 2 × 500 kg; dự kiến 05/11'
    from purchase.purchase_orders po, master.materials m
   where po.id = l.po_id and m.id = l.material_id and m.code = 'ALP-20' and po.note like v_mark || '%';
  -- Talc 50 kg
  update purchase.po_lines l set qty = 50, note = 'Talc 50 kg; dự kiến 29–30/10 (chưa về)'
    from purchase.purchase_orders po, master.materials m
   where po.id = l.po_id and m.id = l.material_id and m.code = 'TALC' and po.note like v_mark || '%' and l.received_qty <= 50;

  -- Phần còn lại các lô HZK
  if exists (select 1 from purchase.purchase_orders where note like 'Phần còn lại lô HZK đã giao một phần%') then
    raise notice 'Đã nhập phần còn lại lô HZK: bỏ qua'; return;
  end if;
  select id into v_hzk from core.partners where lower(name) = 'hzk';
  if v_hzk is null then raise notice 'Chưa có NCC HZK (DB dựng mới): bỏ qua'; return; end if;
  insert into purchase.purchase_orders (po_no, supplier_id, status, order_date, expected_date, note, is_import, source, created_by)
  values (core.next_no('PO'), v_hzk, 'APPROVED', date '2026-10-22', date '2026-11-11',
          'Phần còn lại lô HZK đã giao một phần (bảng BMT - GIAO HÀNG, anh Bình 04/11/2026): đã đặt, hàng đang về; chưa có đơn giá.',
          true, 'MANUAL', v_admin) returning id into v_po;
  insert into purchase.po_lines (po_id, line_no, material_id, qty, expected_date, note)
  select v_po, x.n, m.id, x.q, x.d, x.note
    from (values (1, 'SIL-9710G', 400::numeric, date '2026-11-10', 'Còn lại của 500 kg (đã về 100 kg); dự kiến 10/11'),
                 (2, 'LSZH-S', 150, date '2026-11-11', 'LSZH cam, còn lại của 250 kg (đã về 100 kg); dự kiến 11/11'),
                 (3, 'HDPE-I', 150, date '2026-11-11', 'Còn lại của 250 kg (đã về 100 kg); dự kiến 11/11')) x(n, c, q, d, note)
    join master.materials m on m.code = x.c;
end $$;
