-- Danh sách người dùng (app.v_users) chạy theo quyền người xem (anh Bình duyệt 11/11/2026, mục 4 rà soát code).
-- Trước: view chạy dưới chủ sở hữu (SECURITY DEFINER) nên mọi tài khoản đăng nhập đọc được vai trò, kho được giao
-- của mọi người (Supabase báo lỗi security_definer_view). Sau: áp đúng RLS của bảng gốc:
--   core.profiles  : chính mình, admin:view (Quản trị, Ban giám đốc), approval:view (tên người cho quy trình duyệt)
--   core.user_roles: chính mình, admin:view
--   core.user_scopes (kho): admin:view
--   email, lần đăng nhập (app.auth_users): admin:view
-- Web dùng v_users ở Người dùng, Cài đặt quy trình (admin:view) và Nhân sự xưởng (chỉ id, tên, trạng thái): không đổi.
alter view app.v_users set (security_invoker = true);
