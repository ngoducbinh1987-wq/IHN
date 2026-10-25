# BMT MES – ghi chú cho phiên Claude mới

Phần mềm điều hành sản xuất (MES) cho nhà máy cáp BMT. Trả lời người dùng bằng tiếng Việt, ngắn gọn.

## Hệ thống
- Code: thư mục `bmt-mes/` (repo GitHub `ngoducbinh1987-wq/IHN`). Đẩy lên `main` = Vercel tự deploy production.
- Web: Next.js 15 + React 19 + Tailwind, `bmt-mes/web/`. Chạy tại https://ihn-ten.vercel.app
- Database: Supabase project `critwnuscvdchdbvwygv` (PG17). Schema: core, master, sales, plan, purchase, inv, mfg, qa, cost, wf, iot, integ, app (view/hàm cho web).
- Migration: `bmt-mes/supabase/migrations/` (mới nhất: `20261026002300_production_planning_2.sql`, đã áp lên Supabase). Số phiên bản migration không được trùng: kiểm `supabase_migrations.schema_migrations` trước khi đặt tên.
- Quyền: RLS qua `core.has_perm(module, action)`, `core.has_role(role)`. Luồng duyệt: `wf.submit`, `wf.act`, cấu hình đóng băng vào `wf.approval_requests.flow_snapshot`.
- Thông báo: `wf.notifications`; email qua `lib/notify.ts` (SMTP) và `/api/cron/notify` (CRON_SECRET). pg_cron: `bmt-mes-sla` (wf.check_sla 10 phút/lần), `bmt-mes-email` (pg_net gọi /api/cron/notify, cần Vault `mes_app_url`, `mes_cron_secret`).

## Đã làm (đến 25/10/2026)
- Giao diện kiểu Fastcon màu xanh BMTcable #059B42; thanh giai đoạn + người duyệt tiếp theo; thêm mới spec/vật tư/đề xuất mua/kế hoạch/người dùng.
- Kế hoạch: sửa dòng (nút bút), đóng gói Bobin gỗ 500/305, Cuộn PE 100/200 (`master.pack_options`), kiện chẵn + lẻ, bản in `/in/ke-hoach/[id]`, cờ `mrp_stale`.
- MRP: TP Mua (MUA_TP) / TP Kỹ thuật (KT_TP) điều chỉnh qua `app.adjust_mrp_line` (bắt buộc lý do, lịch sử `plan.mrp_line_edits`); PR dùng số đã chỉnh.
- Quản trị → Cài đặt quy trình (`/quan-tri/quy-trinh`): người được giao, thời hạn, nhắc trước hạn; cảnh báo quá hạn chống trùng (`wf.sla_alerts`).
- Dữ liệu thật: 5 người dùng (binh.nd@ihn.vn có đủ 18 vai trò – để tạm khi chạy thử), 77/78 spec đã phát hành để chạy thử.

- Module Quản lý máy (`/may`, migration 2300): dây chuyền + máy con tự khai báo, thông số, linh kiện, dải hoạt động, tốc độ theo sản phẩm (KT_TP duyệt), bảo dưỡng theo ngày/giờ chạy/km (nhắc trước 7 ngày nhỏ, 30 ngày lớn trên Thông báo), checklist đầu ca, phiếu BD/SC, kiểm tra năng lực, lịch sử vận hành, báo cáo tháng email BGD (pg_cron `bmt-may-daily`, `bmt-may-checklist`, `bmt-may-monthly`).
- Ca làm việc, tỷ lệ xếp lịch, số máy/người dùng chung một nguồn: `master.shifts` (ca A) + `master.planning_config`; module máy đọc qua `mfg.machine_setting('shift')`, Giám đốc sửa ở `/may/cai-dat` (`app.save_work_calendar`) hoặc qua `app.kh_save_shifts`/`kh_save_config`. Ca A hiện 08:00–17:00 nghỉ 60 phút (= 8–12h, 13–17h), 2 máy/người.
- Còn trùng khái niệm cần gộp sau: tốc độ chuẩn `master.machine_rates` (Kế hoạch SX, theo công đoạn) và `master.machine_speeds` (Quản lý máy, theo máy + sản phẩm); người đứng máy `master.operators/operator_skills` (NV1..NV5) và `master.machine_operators` (theo tài khoản).

## Module Kế hoạch sản xuất (26/10/2026)
- Màn hình: `/lich-may` (kế hoạch tháng & công suất, Gantt, tiến độ, căn cứ, đơn phát sinh A/B/C), `/lenh-ngay` (kiểm tra, phát lệnh, phiếu lĩnh), `/ghi-nhan-ca` (mẫu đầu ca/đầu mã, sản lượng, dừng máy, phế, gửi/xác nhận), `/kh-thuc-te`, `/tham-so`.
- Bộ xếp lịch thuần TS: `web/lib/kh/scheduler.ts` (theo máy + người đứng máy, gối đầu ≥ 1 ca, màu sáng→tối, giữ phần trước mốc khi xếp lại, tách việc khi chen vùng khóa). Kiểm thử: `node --experimental-strip-types web/tests/kh-scheduler.test.ts`.
- Database: bảng `master.planning_config/shifts/machine_rates/changeover_rules/operators/operator_skills/planning_param_log`, `plan.schedule_versions/orders/slots/daily_releases/issue_slips/change_requests`, `mfg.shift_reports`; ghi chỉ qua hàm `app.kh_*`; kiểm thử quyền `bmt-mes/tests/test_production_planning.sql`.
- Quyền: BGD sửa ca/tham số/cách nhập/hạn giao; KT_TP sửa tốc độ, phút đổi máy, cho ý kiến mức C, duyệt mẫu (cùng QC); SX_TP/SX_KH xếp lịch, phát lệnh, lập đơn phát sinh; VAN_HANH/TO_TRUONG/SX_TP nhập ca; TO_TRUONG/SX_TP xác nhận ca; KT_KHO duyệt phiếu lĩnh. Không ai tự duyệt đề nghị mình lập.
- Nhân sự xưởng: NV1 (tổ phó) + NV5 đứng 4 line đùn; NV2 bện, xoắn + AL/PET; NV3 (giữ kho thành phẩm) + NV4 vận chuyển bobin, đóng gói.
- Thử cục bộ không có Docker Hub: tải binary PostgREST và supabase/auth từ GitHub releases thay cho container trong `dev/local_stack.sh`.

## Việc còn chờ
- Người dùng tự thêm trên Vercel: `CRON_SECRET`, `SMTP_*` (Zoho smtp.zoho.com:465), `APP_URL`; và chạy `vault.create_secret` cho `mes_app_url`, `mes_cron_secret` trên Supabase.
- Hỏi người dùng: luồng PR hiện chỉ 1 bước SX_TP, có thêm TP Mua → BGĐ không.
- `tests/test_flows_supabase.sql` cần sửa vì spec đã phát hành.
- Giai đoạn 1 tiếp theo (chờ người dùng xác nhận): kho theo lô + QR, PO, nhận hàng/IQC, đề xuất mua tối ưu.

## Kiểm thử
- SQL (rollback, chạy được trên Supabase qua execute_sql): `bmt-mes/tests/test_plan_mrp_flow.sql` (34), `test_machines.sql` (83), `test_production_planning.sql` (40), `test_flows_supabase.sql` (48), `test_flows.sql`. Trên Supabase không chạy được psql: đẩy tệp lên GitHub (repo công khai), lấy bằng `net.http_get` rồi `execute` trong khối DO, kiểm md5 trước khi chạy.
- Cục bộ: Postgres 16 cổng 5433 (`su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /tmp/pgtest -o '-p 5433 -k /tmp' -l /tmp/pgtest.log start"`), `nohup dockerd &`, rồi `bmt-mes/web/tests/run_e2e.sh <thư_mục_ảnh>` (E2E 58 kiểm tra, SMTP giả aiosmtpd).
- `npx tsc --noEmit -p bmt-mes/web` để kiểm tra kiểu.

## Quy tắc
- Không dán token/khóa/mật khẩu vào chat; service role key và SMTP chỉ đặt trên Vercel, không commit.
- Thay đổi database: viết migration mới (không reset DB). Áp lên Supabase cần người dùng bấm Approve trong 60 giây; nếu hết giờ, đề nghị họ dán file vào Supabase SQL Editor rồi kiểm tra lại.
- Áp migration trước, sau đó mới đẩy code web lên `main`.
- PLC chỉ đọc, không ghi xuống. Mã sản phẩm giữ chữ thường (1p5), mã vật tư viết hoa.
- Tái sử dụng code sẵn có, không thêm thư viện nếu chưa cần, chạy kiểm thử liên quan trước khi đẩy.
