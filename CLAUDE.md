# BMT MES – ghi chú cho phiên Claude mới

Phần mềm điều hành sản xuất (MES) cho nhà máy cáp BMT. Trả lời người dùng bằng tiếng Việt, ngắn gọn.

## Hệ thống
- Code: thư mục `bmt-mes/` (repo GitHub `ngoducbinh1987-wq/IHN`). Đẩy lên `main` = Vercel tự deploy production.
- Web: Next.js 15 + React 19 + Tailwind, `bmt-mes/web/`. Chạy tại https://ihn-ten.vercel.app
- Database: Supabase project `critwnuscvdchdbvwygv` (PG17). Schema: core, master, sales, plan, purchase, inv, mfg, qa, cost, wf, iot, integ, app (view/hàm cho web).
- Migration: `bmt-mes/supabase/migrations/`. Đã áp lên Supabase hết các file trong repo: kho `2400`–`2700` (26/10/2026) và `20261026002300_production_planning_2` (mới nhất); `2200_role_standard` ghi trong `schema_migrations` là `20261025171945 bmt_mes_role_standard` (repo có hai file số 2200: production_planning và role_standard). Migration mới tiếp theo đặt số sau `20261026002300` (ví dụ `20261026002400`). Số phiên bản không được trùng: kiểm `supabase_migrations.schema_migrations` trước khi đặt tên.
- Supabase chạy giờ UTC: từ 00:00 đến 07:00 giờ VN `current_date` là ngày hôm trước. Không dùng `current_date` trong hàm/view nghiệp vụ: dùng `(now() at time zone 'Asia/Ho_Chi_Minh')::date` hoặc `set timezone = 'Asia/Ho_Chi_Minh'` cho hàm. Kiểm thử cục bộ đặt database `bmt_test` giờ UTC để bắt lỗi này.
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
- Quy chuẩn vai trò (migration 2200, nhánh `feat/quy-chuan-vai-tro`, đã gộp vào `main` cùng module Kho): luồng duyệt theo quy chuẩn, PO theo hạn mức, chuyển Giám đốc khi người duyệt là người lập, duyệt thay khi quá hạn, chặn vai trò xung đột (`core.role_conflicts`), phạm vi kho (`core.can_use_warehouse`), vá phát hành spec/phát lệnh SX. Đã sửa vai trò thật: Minh BGD+SX_KH, Lực KT_TP+QC, Hương MUA_TP, Trang KTT (Bình giữ đủ vai trò để chạy thử).
- Module Kho (2400–2700, chạy trên Supabase và web từ 26/10/2026; tài liệu Claude Doc "BMT MES – Phân tích nghiệp vụ Quản lý kho" mục 11): tồn theo đơn vị chứa có QR (`inv.handling_units`, `stock_balances.hu_key`), người giữ kho `inv.warehouse_keepers` (KNL/KBTP/KPL: THU_KHO; KTP: KHO_NV; ủy quyền cần KT_KHO chứng kiến), phiếu lĩnh `inv.requisitions` (NORM theo định mức, EXTRA qua luồng EXTRA_ISSUE – TP KT/QA), cấp `inv.issue_pick` (FEFO), hậu kiểm Kế toán SX `review_status`, kiểm kê đếm mù (STOCK_ADJ: KT_KHO lập → KTT duyệt), lệnh giao (DELIVERY: KT_TP → BGD), tồn đầu kỳ (STOCK_OPEN: KTT), cài đặt `inv.settings` (ngưỡng lệch đồng `copper_tol_pct` thay `mfg.control_settings`), báo cáo hao hụt `app.loss_by_wo/loss_scrap/loss_wo_materials`. Hàm cũ của 2200 vẫn chạy: `inv.create_wo_issue` → tạo phiếu lĩnh; `app.review_stock_docs` → duyệt hậu kiểm; `app.copper_balance`. Web: `/kho/*`, `/bao-cao/hao-hut`, `/in/tem`; trang `/kho` cũ (Kiểm soát kho) đã thay.

## Module Kế hoạch sản xuất (26/10/2026)
- Trạng thái: chạy trên Supabase và web từ 26/10/2026 06:5x (migration 2200 + `20261026002300`), đã kiểm trên web thật bằng tài khoản Bình cả 5 màn hình; kiểm quyền trên DB thật 26/26 đạt (rollback). Chưa bấm "Xếp lịch" trên dữ liệu thật: để Quản lý SX / người dùng tự bấm.
- Màn hình: `/lich-may` (kế hoạch tháng & công suất, Gantt, tiến độ, căn cứ, đơn phát sinh A/B/C), `/lenh-ngay` (kiểm tra, phát lệnh, phiếu lĩnh), `/ghi-nhan-ca` (mẫu đầu ca/đầu mã, sản lượng, dừng máy, phế, gửi/xác nhận), `/kh-thuc-te`, `/tham-so`.
- Bộ xếp lịch thuần TS: `web/lib/kh/scheduler.ts` (theo máy + người đứng máy, gối đầu ≥ 1 ca, màu sáng→tối, giữ phần trước mốc khi xếp lại, tách việc khi chen vùng khóa). Kiểm thử: `node --experimental-strip-types web/tests/kh-scheduler.test.ts`.
- Database: bảng `master.planning_config/shifts/machine_rates/changeover_rules/operators/operator_skills/planning_param_log`, `plan.schedule_versions/orders/slots/daily_releases/issue_slips/change_requests`, `mfg.shift_reports`; ghi chỉ qua hàm `app.kh_*`; kiểm thử quyền `bmt-mes/tests/test_production_planning.sql`.
- Quyền: BGD sửa ca/tham số/cách nhập/hạn giao; KT_TP sửa tốc độ, phút đổi máy, cho ý kiến mức C, duyệt mẫu (cùng QC); SX_TP/SX_KH xếp lịch, phát lệnh, lập đơn phát sinh; VAN_HANH/TO_TRUONG/SX_TP nhập ca; TO_TRUONG/SX_TP xác nhận ca; KT_KHO duyệt phiếu lĩnh. Không ai tự duyệt đề nghị mình lập.
- Nhân sự xưởng (Chủ tịch chốt 25/10/2026): NV1 (tổ phó, thay Quản lý SX khi vắng) + NV5 đứng 4 line đùn, kiêm lấy hàng ở kho, nhập hàng vào kho; NV2 bện, xoắn + AL/PET (cùng dây chuyền xoắn), kiêm nhập kho; NV3 (giữ kho thành phẩm) + NV4 vận chuyển bobin, đóng gói.
- Ngày làm việc trong tuần lấy từ Cài đặt máy (`mfg.machine_setting('shift')`, lưu kèm `params.workdays` của phiên bản lịch); máy con (`inline_with` khác null) không xếp lịch. Hàm cũ `app.kh_sample(date,text,jsonb,int,text)` còn trong DB nhưng không dùng; web gọi bản có tham số ca.
- Dùng thật cần: duyệt kế hoạch tháng (chưa duyệt thì chưa phát lệnh ngày), Giám đốc đặt hạn giao từng dòng (thẻ Kế hoạch tháng & công suất) rồi Quản lý SX bấm Xếp lịch; Lực (TP KT/QA) nhập tốc độ chuẩn, phút đổi máy thật (đang giả định); tài khoản tổ trưởng + NV1–NV5 để nhập, xác nhận ca.
- Thử cục bộ không có Docker Hub: tải binary PostgREST và supabase/auth từ GitHub releases thay cho container trong `dev/local_stack.sh`.

## Việc còn chờ
- Tạo tài khoản: Quản lý SX (Quản lý sản xuất + Tổ trưởng ca + Kế hoạch SX + Thủ kho, kho KNL/KBTP/KPL), Kế toán SX (Kế toán kho + Kế toán giá thành), NV mua hàng, 5 công nhân (email nội bộ; NV3 thêm NV kho, kho KTP vì NV3 giữ kho thành phẩm theo chỉ đạo 25/10/2026; NV1 là tổ phó).
- Người dùng tự thêm trên Vercel: `CRON_SECRET`, `SMTP_*` (Zoho smtp.zoho.com:465), `APP_URL`; và chạy `vault.create_secret` cho `mes_app_url`, `mes_cron_secret` trên Supabase.
- `tests/test_flows_supabase.sql` cần sửa vì spec đã phát hành.
- Kế hoạch `KH-2610-01` đang chờ duyệt nhưng mã kiểm chứng từ đã lệch (bảng `plan.production_plans` thêm cột ở migration 2200 sau lúc gửi): duyệt sẽ báo "đã bị sửa sau khi gửi duyệt" → gửi duyệt lại.
- Cảnh báo bảo mật còn lại (không thuộc kho): 9 hàm `mfg.*` của module máy + `wf.can_act_step`, `wf.step_actor_ids`, `plan.mrp_lock_reason` gọi được bằng anon; view `app.v_machine_history` SECURITY DEFINER; bật leaked password protection; pg_net trong schema public.
- Trùng khái niệm cần gộp: phiếu lĩnh của Kế hoạch SX (`plan.issue_slips`, JSON, `/lenh-ngay`, KT_KHO duyệt) và phiếu lĩnh của Kho (`inv.requisitions`, cấp bằng quét QR ở `/kho/cap-phat`). Nên cho `app.kh_release_day` tạo `inv.requisitions` để kho cấp theo đúng lệnh ngày.
- Tiếp theo: màn hình tạo PO, lệnh SX, trả hàng NCC; đề xuất mua tối ưu.

## Kiểm thử
- Đã chạy trên Supabase 26/10/2026 sau khi áp 2400–2700: `test_inventory` 97 (chạy lúc 06:5x giờ VN, khung giờ dễ lệch ngày), `test_role_standard` 53, `test_plan_mrp_flow` 34, `test_machines` 83 đạt.
- Cách áp migration/chạy kiểm thử trên Supabase: đẩy tệp lên GitHub, `select net.http_get('https://raw.githubusercontent.com/ngoducbinh1987-wq/IHN/<commit>/bmt-mes/...')`, đọc `net._http_response`, kiểm md5, `execute` trong một khối DO (bỏ dòng `begin;` và `\set`), với migration thì ghi thêm dòng `supabase_migrations.schema_migrations`.
- SQL (rollback): `bmt-mes/tests/test_inventory.sql` (97), `test_role_standard.sql` (53), `test_plan_mrp_flow.sql` (34), `test_machines.sql` (83), `test_flows.sql`, `test_flows_supabase.sql`; `test_production_planning.sql` (cần `psql -1`, dựa trên người dùng thật nên chỉ đạt trên Supabase). Trên Supabase không chạy được psql: đẩy tệp lên GitHub (repo công khai), lấy bằng `net.http_get` rồi `execute` trong khối DO, kiểm md5 trước khi chạy.
- Không có Docker Hub: tải `postgrest` và `supabase/auth` bản chạy sẵn từ GitHub Releases, chạy thay cho container (E2E 60 kiểm tra đạt 26/10/2026).
- Cục bộ: Postgres 16 cổng 5433 (mất `/tmp/pgtest` thì tạo lại: `su postgres -c "/usr/lib/postgresql/16/bin/initdb -D /tmp/pgtest -A trust -E UTF8 --locale=C.UTF-8"`; chạy: `su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /tmp/pgtest -o '-p 5433 -k /tmp' -l /tmp/pgtest.log start"`), `nohup dockerd &`, rồi `bmt-mes/web/tests/run_e2e.sh <thư_mục_ảnh>` (E2E 58 kiểm tra, SMTP giả aiosmtpd).
- `npx tsc --noEmit -p bmt-mes/web` để kiểm tra kiểu.

## Quy tắc
- Không dán token/khóa/mật khẩu vào chat; service role key và SMTP chỉ đặt trên Vercel, không commit.
- Thay đổi database: viết migration mới (không reset DB). Ngày 26/10/2026 người dùng cho phép Claude tự áp migration lên Supabase ("Bạn tự duyệt supabase cho tôi"); vẫn kiểm thử cục bộ đủ bộ trước khi áp và chạy kiểm thử trên Supabase sau khi áp.
- Áp migration trước, sau đó mới đẩy code web lên `main`.
- PLC chỉ đọc, không ghi xuống. Mã sản phẩm giữ chữ thường (1p5), mã vật tư viết hoa.
- Tái sử dụng code sẵn có, không thêm thư viện nếu chưa cần, chạy kiểm thử liên quan trước khi đẩy.
