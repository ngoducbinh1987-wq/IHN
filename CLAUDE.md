# BMT MES – ghi chú cho phiên Claude mới

Phần mềm điều hành sản xuất (MES) cho nhà máy cáp BMT. Trả lời người dùng bằng tiếng Việt, ngắn gọn.

## Hệ thống
- Code: thư mục `bmt-mes/` (repo GitHub `ngoducbinh1987-wq/IHN`). Đẩy lên `main` = Vercel tự deploy production.
- Web: Next.js 15 + React 19 + Tailwind, `bmt-mes/web/`. Chạy tại https://ihn-ten.vercel.app
- Database: Supabase project `critwnuscvdchdbvwygv` (PG17). Schema: core, master, sales, plan, purchase, inv, mfg, qa, cost, wf, iot, integ, app (view/hàm cho web).
- Migration: `bmt-mes/supabase/migrations/` (mới nhất: `20261025002200_role_standard.sql`, đã áp lên Supabase 26/10/2026 qua MCP; 27 hàm khớp từng ký tự với bản kiểm thử). `schema_migrations` trên Supabase đã có số 2100 và 2200 (tên ghi khác repo, bản 2200 mang tên `production_planning`) nên workflow deploy bỏ qua cả hai; bản MCP ghi thêm `20261025171945 bmt_mes_role_standard`. Migration mới tiếp theo đánh số từ `20261025002300`.
- Quyền: RLS qua `core.has_perm(module, action)`, `core.has_role(role)`. Luồng duyệt: `wf.submit`, `wf.act`, cấu hình đóng băng vào `wf.approval_requests.flow_snapshot`.
- Thông báo: `wf.notifications`; email qua `lib/notify.ts` (SMTP) và `/api/cron/notify` (CRON_SECRET). pg_cron: `bmt-mes-sla` (wf.check_sla 10 phút/lần), `bmt-mes-email` (pg_net gọi /api/cron/notify, cần Vault `mes_app_url`, `mes_cron_secret`).

## Đã làm (đến 25/10/2026)
- Giao diện kiểu Fastcon màu xanh BMTcable #059B42; thanh giai đoạn + người duyệt tiếp theo; thêm mới spec/vật tư/đề xuất mua/kế hoạch/người dùng.
- Kế hoạch: sửa dòng (nút bút), đóng gói Bobin gỗ 500/305, Cuộn PE 100/200 (`master.pack_options`), kiện chẵn + lẻ, bản in `/in/ke-hoach/[id]`, cờ `mrp_stale`.
- MRP: TP Mua (MUA_TP) / TP Kỹ thuật (KT_TP) điều chỉnh qua `app.adjust_mrp_line` (bắt buộc lý do, lịch sử `plan.mrp_line_edits`); PR dùng số đã chỉnh.
- Quản trị → Cài đặt quy trình (`/quan-tri/quy-trinh`): người được giao, thời hạn, nhắc trước hạn; cảnh báo quá hạn chống trùng (`wf.sla_alerts`).
- Dữ liệu thật: 5 người dùng (binh.nd@ihn.vn có đủ 18 vai trò – để tạm khi chạy thử), 77/78 spec đã phát hành để chạy thử.

- Quy chuẩn vai trò (migration 2200, nhánh `feat/quy-chuan-vai-tro`): luồng duyệt theo quy chuẩn, PO theo hạn mức, chuyển Giám đốc khi người duyệt là người lập, duyệt thay khi quá hạn, chặn vai trò xung đột, phạm vi kho, phiếu lĩnh theo định mức, "Đã kiểm" phiếu kho, cân bằng đồng (`/kho`), vá phát hành spec/phát lệnh SX. Đã sửa vai trò thật: Minh BGD+SX_KH, Lực KT_TP+QC, Hương MUA_TP, Trang KTT (Bình giữ đủ vai trò để chạy thử).

## Việc còn chờ
- Tạo tài khoản: Quản lý SX (Quản lý sản xuất + Tổ trưởng ca + Kế hoạch SX + Thủ kho, kho KNL/KPL), Kế toán SX (Kế toán kho + Kế toán giá thành), NV mua hàng, 5 công nhân (email nội bộ; NV5 thêm NV kho, kho KTP).
- Người dùng tự thêm trên Vercel: `CRON_SECRET`, `SMTP_*` (Zoho smtp.zoho.com:465), `APP_URL`; và chạy `vault.create_secret` cho `mes_app_url`, `mes_cron_secret` trên Supabase.
- `tests/test_flows_supabase.sql` cần sửa vì spec đã phát hành.
- Giai đoạn 1 tiếp theo (chờ người dùng xác nhận): kho theo lô + QR, PO, nhận hàng/IQC, đề xuất mua tối ưu.

## Kiểm thử
- SQL (rollback, chạy được trên Supabase qua execute_sql): `bmt-mes/tests/test_plan_mrp_flow.sql` (34), `test_role_standard.sql` (52), `test_flows_supabase.sql`, `test_flows.sql` (60).
- Không có Docker Hub: tải `postgrest` và `supabase/auth` bản chạy sẵn từ GitHub Releases, chạy thay cho container (E2E 60 kiểm tra đạt 26/10/2026).
- Cục bộ: Postgres 16 cổng 5433 (`su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /tmp/pgtest -o '-p 5433 -k /tmp' -l /tmp/pgtest.log start"`), `nohup dockerd &`, rồi `bmt-mes/web/tests/run_e2e.sh <thư_mục_ảnh>` (E2E 58 kiểm tra, SMTP giả aiosmtpd).
- `npx tsc --noEmit -p bmt-mes/web` để kiểm tra kiểu.

## Quy tắc
- Không dán token/khóa/mật khẩu vào chat; service role key và SMTP chỉ đặt trên Vercel, không commit.
- Thay đổi database: viết migration mới (không reset DB). Áp lên Supabase cần người dùng bấm Approve trong 60 giây; nếu hết giờ, đề nghị họ dán file vào Supabase SQL Editor rồi kiểm tra lại.
- Áp migration trước, sau đó mới đẩy code web lên `main`.
- PLC chỉ đọc, không ghi xuống. Mã sản phẩm giữ chữ thường (1p5), mã vật tư viết hoa.
- Tái sử dụng code sẵn có, không thêm thư viện nếu chưa cần, chạy kiểm thử liên quan trước khi đẩy.
