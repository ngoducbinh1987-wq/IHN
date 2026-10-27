-- CHẠY TRÊN DỰ ÁN "BMT MES Singapore" sau khi web đã chạy ổn trên dự án mới (vài ngày sau chuyển đổi).
-- Xóa hàm nhận dữ liệu tạm và vùng tạm dùng khi chuyển.
drop function if exists public._mig_import(text, text, text, jsonb);
drop schema if exists _mig cascade;
select 'đã dọn' as ket_qua;
