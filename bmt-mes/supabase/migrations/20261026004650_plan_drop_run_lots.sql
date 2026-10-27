-- Bỏ cột "Số lô" khỏi kế hoạch tháng (anh Bình đồng ý 28/10/2026 00:15).
-- Số lô chỉ dùng để nhân hao hụt khởi động máy trong MRP; lịch máy không dùng (MES tự xếp, tự gom lô).
-- Từ nay mỗi mã tính 1 lần khởi động khi chạy MRP; hao hụt khởi động thực tế tính ở lệnh ngày / phiếu lĩnh
-- (lần chạy đầu của mã) và báo cáo hao hụt. Web không còn nhập/hiện Số lô; cột run_lots giữ (mặc định 1) để hàm cũ chạy.
-- (Số 4650 vì 4600 đã được phiên khác dùng trên Supabase: procure_schedule_approval.)
update plan.plan_lines l set run_lots = 1
 where l.run_lots <> 1
   and exists (select 1 from plan.production_plans p where p.id = l.plan_id and p.status not in ('CLOSED', 'CANCELLED'));
comment on column plan.plan_lines.run_lots is 'Không dùng nữa trên web (28/10/2026): luôn 1 lần khởi động/mã khi chạy MRP';
