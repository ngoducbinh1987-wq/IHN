-- Gọn menu (anh Bình đồng ý 7 điểm rà soát 28/10/2026):
-- 1. Thông báo bỏ khỏi menu (dùng chuông trên đầu trang) – không có trong core.pages, chỉ sửa web.
-- 2. Bỏ Kiểm tra năng lực (/may/kiem-tra): trùng Lịch máy → Kế hoạch tháng & công suất, Tối ưu & tăng ca.
-- 3. Checklist đầu ca bỏ khỏi menu (công nhân dùng giấy) – vẫn mở từ Bảo dưỡng, Danh sách máy nên giữ quyền vào mục.
-- 4. Tốc độ sản xuất sang nhóm Kỹ thuật / QA.
-- 5. Tham số xếp lịch, Cài đặt máy về nhóm "Hệ thống & cài đặt".
-- 6. Lịch sử vận hành, Báo cáo bảo trì sang nhóm Báo cáo.
-- 7. "Người dùng & quyền" đổi tên "Người dùng".
-- Nhóm/tên ở đây dùng cho bảng tick Phân quyền; menu web dựng theo layout.tsx cùng cách chia.

delete from core.role_pages where page_key = 'may-kiem-tra';
delete from core.pages where key = 'may-kiem-tra';

update core.pages set grp = 'Kỹ thuật / QA', sort = 52 where key = 'may-toc-do';
update core.pages set grp = 'Báo cáo', sort = 43 where key = 'may-lich-su';
update core.pages set grp = 'Báo cáo', sort = 44 where key = 'may-bao-cao';
update core.pages set label = 'Checklist đầu ca (mở từ Bảo dưỡng)' where key = 'may-checklist';
update core.pages set grp = 'Hệ thống & cài đặt', sort = 92 where key = 'tham-so';
update core.pages set grp = 'Hệ thống & cài đặt', sort = 93 where key = 'may-cai-dat';
update core.pages set grp = 'Hệ thống & cài đặt', label = 'Người dùng', sort = 90 where key = 'quan-tri';
update core.pages set grp = 'Hệ thống & cài đặt', sort = 91 where key = 'quan-tri-quy-trinh';
