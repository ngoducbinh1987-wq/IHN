# BMT MES – ghi chú cho phiên Claude mới

Phần mềm điều hành sản xuất (MES) cho nhà máy cáp BMT. Trả lời người dùng bằng tiếng Việt, ngắn gọn.

## Hệ thống
- Code: thư mục `bmt-mes/` (repo GitHub `ngoducbinh1987-wq/IHN`). Đẩy lên `main` = Vercel tự deploy production.
- Web: Next.js 15 + React 19 + Tailwind, `bmt-mes/web/`. Chạy tại https://ihn-ten.vercel.app
- Database: Supabase project `critwnuscvdchdbvwygv` (PG17). Schema: core, master, sales, plan, purchase, inv, mfg, qa, cost, wf, iot, integ, app (view/hàm cho web).
- Migration: `bmt-mes/supabase/migrations/`. Đã áp lên Supabase: tới `2300_machines` + `2200_role_standard` (ghi trong `schema_migrations` là `20261025171945 bmt_mes_role_standard`; repo có hai file số 2200: production_planning và role_standard). Module Kho `2400_inventory_core`, `2500_inventory_ops`, `2600_inventory_app` (nhánh `kho-module`, 26/10/2026): CHỜ người dùng duyệt áp lên Supabase, sau đó mới merge vào `main`. Migration mới tiếp theo đánh số từ `20261025002700`. Số phiên bản không được trùng: kiểm `supabase_migrations.schema_migrations` trước khi đặt tên.
- Hàm trên Supabase có xuống dòng CRLF (áp qua MCP) nên md5(prosrc) khác bản cục bộ dù nội dung như nhau.
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
- Quy chuẩn vai trò (migration 2200, nhánh `feat/quy-chuan-vai-tro`, đã gộp vào `kho-module`): luồng duyệt theo quy chuẩn, PO theo hạn mức, chuyển Giám đốc khi người duyệt là người lập, duyệt thay khi quá hạn, chặn vai trò xung đột (`core.role_conflicts`), phạm vi kho (`core.can_use_warehouse`), vá phát hành spec/phát lệnh SX. Đã sửa vai trò thật: Minh BGD+SX_KH, Lực KT_TP+QC, Hương MUA_TP, Trang KTT (Bình giữ đủ vai trò để chạy thử).
- Module Kho (2400–2600, tài liệu Claude Doc "BMT MES – Phân tích nghiệp vụ Quản lý kho" mục 11): tồn theo đơn vị chứa có QR (`inv.handling_units`, `stock_balances.hu_key`), người giữ kho `inv.warehouse_keepers` (KNL/KBTP/KPL: THU_KHO; KTP: KHO_NV; ủy quyền cần KT_KHO chứng kiến), phiếu lĩnh `inv.requisitions` (NORM theo định mức, EXTRA qua luồng EXTRA_ISSUE – TP KT/QA), cấp `inv.issue_pick` (FEFO), hậu kiểm Kế toán SX `review_status`, kiểm kê đếm mù (STOCK_ADJ: KT_KHO lập → KTT duyệt), lệnh giao (DELIVERY: KT_TP → BGD), tồn đầu kỳ (STOCK_OPEN: KTT), cài đặt `inv.settings` (ngưỡng lệch đồng `copper_tol_pct` thay `mfg.control_settings`), báo cáo hao hụt `app.loss_by_wo/loss_scrap/loss_wo_materials`. Hàm cũ của 2200 vẫn chạy: `inv.create_wo_issue` → tạo phiếu lĩnh; `app.review_stock_docs` → duyệt hậu kiểm; `app.copper_balance`. Web: `/kho/*`, `/bao-cao/hao-hut`, `/in/tem`; trang `/kho` cũ (Kiểm soát kho) đã thay.

## Việc còn chờ
- Tạo tài khoản: Quản lý SX (Quản lý sản xuất + Tổ trưởng ca + Kế hoạch SX + Thủ kho, kho KNL/KPL), Kế toán SX (Kế toán kho + Kế toán giá thành), NV mua hàng, 5 công nhân (email nội bộ; NV5 thêm NV kho, kho KTP).
- Người dùng tự thêm trên Vercel: `CRON_SECRET`, `SMTP_*` (Zoho smtp.zoho.com:465), `APP_URL`; và chạy `vault.create_secret` cho `mes_app_url`, `mes_cron_secret` trên Supabase.
- `tests/test_flows_supabase.sql` cần sửa vì spec đã phát hành.
- Áp 2400–2600 lên Supabase (lấy file từ GitHub bằng `net.http_get`, kiểm md5, chạy trong một khối DO, ghi `schema_migrations`), chạy `test_inventory.sql`, `get_advisors`, rồi merge `kho-module` vào `main`.
- Tiếp theo: màn hình tạo PO, lệnh SX, trả hàng NCC; đề xuất mua tối ưu.

## Kiểm thử
- SQL (rollback): `bmt-mes/tests/test_inventory.sql` (97), `test_role_standard.sql` (53), `test_plan_mrp_flow.sql` (34), `test_machines.sql` (83), `test_flows.sql`, `test_flows_supabase.sql`; `test_production_planning.sql` (cần `psql -1`, dựa trên người dùng thật nên chỉ đạt trên Supabase). Trên Supabase không chạy được psql: đẩy tệp lên GitHub (repo công khai), lấy bằng `net.http_get` rồi `execute` trong khối DO, kiểm md5 trước khi chạy.
- Không có Docker Hub: tải `postgrest` và `supabase/auth` bản chạy sẵn từ GitHub Releases, chạy thay cho container (E2E 60 kiểm tra đạt 26/10/2026).
- Cục bộ: Postgres 16 cổng 5433 (`su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /tmp/pgtest -o '-p 5433 -k /tmp' -l /tmp/pgtest.log start"`), `nohup dockerd &`, rồi `bmt-mes/web/tests/run_e2e.sh <thư_mục_ảnh>` (E2E 58 kiểm tra, SMTP giả aiosmtpd).
- `npx tsc --noEmit -p bmt-mes/web` để kiểm tra kiểu.

## Quy tắc
- Không dán token/khóa/mật khẩu vào chat; service role key và SMTP chỉ đặt trên Vercel, không commit.
- Thay đổi database: viết migration mới (không reset DB). Áp lên Supabase cần người dùng bấm Approve trong 60 giây; nếu hết giờ, đề nghị họ dán file vào Supabase SQL Editor rồi kiểm tra lại.
- Áp migration trước, sau đó mới đẩy code web lên `main`.
- PLC chỉ đọc, không ghi xuống. Mã sản phẩm giữ chữ thường (1p5), mã vật tư viết hoa.
- Tái sử dụng code sẵn có, không thêm thư viện nếu chưa cần, chạy kiểm thử liên quan trước khi đẩy.
