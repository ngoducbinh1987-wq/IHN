-- BMT MES · 2700 · Module Kho: ngày theo giờ Việt Nam
-- Supabase chạy giờ UTC, nên từ 00:00 đến 07:00 sáng (giờ VN) current_date vẫn là ngày hôm trước, trong khi
-- ngày chứng từ (inv.stock_docs.doc_date) mặc định theo giờ VN. Hệ quả: lô phế, ngày SX, ngày giao, hạn dùng,
-- cảnh báo hằng ngày lệch một ngày trong khung giờ đó.
--   1. Hàm kho có dùng current_date: chạy với timezone Asia/Ho_Chi_Minh
--   2. View kho có so sánh hạn dùng: thay current_date bằng ngày giờ VN
--   3. Mã kiểm chứng từ (wf.doc_hash) luôn tính theo UTC, không phụ thuộc giờ của phiên gọi
--      (các hàm kho ở mục 1 gửi duyệt khi đang chạy giờ VN; người duyệt chạy giờ UTC)

-- 1. Hàm
do $$
declare f regprocedure;
begin
  for f in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname || '.' || p.proname = any (array[
      'inv.create_requisition', 'inv.issue_pick', 'inv.receive_goods', 'inv.split_hu', 'inv.reclass_hu',
      'inv.customer_return', 'inv.create_opening', 'inv.record_scrap', 'sales.create_delivery', 'inv.count_open',
      'mfg.record_output', 'inv.daily_alerts', 'app.kho_overview', 'inv.create_wo_issue', 'inv.create_extra_requisition',
      'inv.return_hu', 'inv.move_hu', 'inv.create_scrap_sale', 'inv.ship_delivery', 'inv.count_close', 'inv.reverse_doc'])
  loop
    execute format('alter function %s set timezone = %L', f, 'Asia/Ho_Chi_Minh');
  end loop;
end $$;

-- 2. View: đọc lại định nghĩa đang chạy, chỉ thay current_date (giữ nguyên cột, quyền)
do $$
declare v text; d text;
begin
  foreach v in array array['app.v_hu', 'app.v_stock', 'app.v_requisition_lines', 'app.v_pick_suggest'] loop
    d := pg_get_viewdef(v::regclass, true);
    if position('CURRENT_DATE' in d) > 0 then
      d := replace(d, 'CURRENT_DATE', '(now() AT TIME ZONE ''Asia/Ho_Chi_Minh''::text)::date');
      execute format('create or replace view %s with (security_invoker = true) as %s', v, d);
    end if;
  end loop;
end $$;

-- 3. Mã kiểm chứng từ: cột thời gian đổi ra chữ theo UTC (như mọi phiên web hiện nay) để hồ sơ đang chờ duyệt không bị lệch
alter function wf.doc_hash(text, uuid) set timezone = 'UTC';
