-- Dọn bảo mật sau rà soát module Kho (30/10/2026), theo cảnh báo Supabase Advisors:
--  1. Xóa public._mig_import: hàm nạp dữ liệu tạm khi chuyển database sang Singapore (27/10/2026),
--     SECURITY DEFINER, người chưa đăng nhập gọi được qua /rest/v1/rpc. Hết dùng.
--     (Schema _mig chứa bản dữ liệu chuyển: không mở qua API, giữ lại, xóa khi người dùng đồng ý.)
--  2. Thu quyền EXECUTE của PUBLIC/anon trên 10 hàm SECURITY DEFINER còn mở cho người chưa đăng nhập.
--     Hàm web gọi (kh_*) cấp lại cho authenticated. Hàm trigger không cần quyền EXECUTE khi chạy.
--     Hàm chỉ được gọi bên trong hàm SECURITY DEFINER khác (chạy dưới chủ sở hữu) thì không cấp lại.
--  3. Cố định search_path cho 3 hàm tính toán thuần (Advisors: function_search_path_mutable).

drop function if exists public._mig_import(text, text, text, jsonb);

-- Web gọi (Nhân sự xưởng, Tham số xếp lịch)
revoke execute on function app.kh_delete_op_shift(uuid, text) from public, anon;
revoke execute on function app.kh_save_op_shift(uuid, text, date, date, integer, text) from public, anon;
revoke execute on function app.kh_save_shift_rules(numeric, text) from public, anon;
grant execute on function app.kh_delete_op_shift(uuid, text) to authenticated;
grant execute on function app.kh_save_op_shift(uuid, text, date, date, integer, text) to authenticated;
grant execute on function app.kh_save_shift_rules(numeric, text) to authenticated;

-- Hàm trigger
revoke execute on function master.notify_speed_pending() from public, anon;
revoke execute on function mfg.notify_maint_done() from public, anon;
revoke execute on function plan.apply_adjustment() from public, anon;
revoke execute on function plan.trg_ledger() from public, anon;
revoke execute on function purchase.apply_safety_change() from public, anon;

-- Hàm nội bộ: chỉ gọi trong hàm SECURITY DEFINER khác; can_enter_slips giữ quyền authenticated đã cấp
revoke execute on function mfg.scrap_material_for(text, uuid) from public, anon;
revoke execute on function mfg.can_enter_slips() from public, anon;

-- search_path cố định (thân hàm dùng tên có schema hoặc hàm hệ thống)
alter function inv.fg_pack(numeric, boolean, numeric, numeric) set search_path = pg_catalog, public;
alter function inv.fg_label(text, text, numeric) set search_path = pg_catalog, public;
alter function mfg.loss_level(numeric, numeric) set search_path = pg_catalog, public;
