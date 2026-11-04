-- Anh Bình 04/11/2026 (bổ sung tồn kho khởi tạo 8900):
--   * PVC mẫu 50 kg đã về nhà máy → PVC-S (PVC vỏ);
--   * 1 cuộn AL/PET bề rộng 20 mm, 2 kg → ALP-20.
-- Phiếu tồn đầu kỳ thứ hai của kho KNL ngày 01/11/2026, Quản trị lập + duyệt → ghi sổ ngay. Đơn giá 0 như 8900.
-- Chạy lại không nhập trùng (đã có phiếu có ghi chú bổ sung thì bỏ qua).
do $$
declare v_admin uuid; v_doc uuid; v_req uuid; v_res text;
begin
  if exists (select 1 from inv.stock_docs where note like 'Bổ sung tồn kho khởi tạo: PVC mẫu%') then
    raise notice 'Đã bổ sung tồn kho khởi tạo: bỏ qua'; return;
  end if;
  select ur.user_id into v_admin from core.user_roles ur join core.profiles p on p.id = ur.user_id
   where ur.role_code = 'ADMIN' and p.status = 'ACTIVE' order by p.created_at limit 1;
  if v_admin is null then
    raise notice 'Chưa có Quản trị (DB dựng mới): bỏ qua bổ sung tồn khởi tạo';
    return;
  end if;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  v_doc := inv.create_opening(inv.wh('KNL'), date '2026-11-01', jsonb_build_array(
    jsonb_build_object('code', 'PVC-S',  'qty', 50, 'unit_cost', 0),  -- PVC mẫu đã về nhà máy
    jsonb_build_object('code', 'ALP-20', 'qty', 2,  'unit_cost', 0)   -- 1 cuộn băng AL/PET 20 mm
  ));
  select id into v_req from wf.approval_requests where doc_id = v_doc and status = 'PENDING' order by submitted_at desc limit 1;
  v_res := wf.act(v_req, 'APPROVE', 'Bổ sung tồn kho khởi tạo (anh Bình 04/11/2026)');
  if v_res <> 'APPROVED' then raise exception 'Duyệt tồn đầu kỳ chưa xong: %', v_res; end if;
  update inv.stock_docs set note = 'Bổ sung tồn kho khởi tạo: PVC mẫu 50 kg (PVC vỏ), 1 cuộn AL/PET 20 mm 2 kg; chưa có đơn giá'
   where id = v_doc;
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
