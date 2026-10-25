# BMT MES — Cơ sở dữ liệu Supabase

Cơ sở dữ liệu cho phần mềm điều hành sản xuất nhà máy cáp BMT, xây theo tài liệu BA v1.0 (25/10/2026)
và file `BMT_Du_tru_vat_tu_san_xuat` bản 3.0.

Phương án đã duyệt ngày 25/10/2026:
- Tính giá xuất kho: **bình quân gia quyền di động** theo mã vật tư × kho. Lô chỉ dùng cho số lượng và truy xuất.
- Database: **Supabase PostgreSQL**. Project `critwnuscvdchdbvwygv` làm bản thử nghiệm, chuyển gói Pro khi đạt.
- Kết nối máy: **máy trung gian tại xưởng, chỉ đọc PLC**, không ghi xuống PLC.

## Cấu trúc

| Thư mục | Nội dung |
|---|---|
| `supabase/migrations/` | 27 migration, chạy theo thứ tự tên file (2200 có hai file: production_planning, role_standard) |
| `web/` | Web app Next.js giai đoạn 1 |
| `dev/` | Môi trường thử cục bộ giống Supabase |
| `docs/BA_BMT_MES_v1.html` | Tài liệu BA kèm mockup giao diện |
| `tools/gen_seed.py` | Sinh migration dữ liệu từ file Excel (chạy lại khi Excel đổi) |
| `tests/test_parity.py` | Đối chiếu định mức và MRP với file Excel |
| `tests/test_flows.sql` | 47 kiểm thử luồng nghiệp vụ, chạy trong transaction rồi rollback |
| `tests/test_plan_mrp_flow.sql` | 34 kiểm thử: sửa dòng kế hoạch, đóng gói, điều chỉnh MRP, cài đặt quy trình, cảnh báo quá hạn (rollback) |
| `tests/test_machines.sql` | 83 kiểm thử module Quản lý máy: quyền, khai báo máy, tốc độ, bảo dưỡng, nhắc lịch, hỏng máy, checklist, năng lực, báo cáo tháng, lịch làm việc dùng chung (rollback) |
| `tests/test_inventory.sql` | 97 kiểm thử module Kho theo Quy chuẩn vai trò: người giữ kho, phạm vi kho, ủy quyền + chứng kiến, phiếu lĩnh theo định mức, FEFO, cấp/trả theo QR, QC giải phóng lô, kiểm kê đếm mù, hậu kiểm Kế toán SX, khóa kỳ, lệnh giao, phế, báo cáo hao hụt (rollback) |
| `tests/test_role_standard.sql` | 53 kiểm thử quy chuẩn vai trò: xung đột vai trò, phạm vi kho, hạn mức PO, chuyển Giám đốc, duyệt thay quá hạn, phiếu lĩnh theo định mức, cân bằng đồng (rollback, chạy được trên Supabase) |
| `scripts/apply_local.sh` | Dựng database trên PostgreSQL cục bộ |
| `scripts/deploy_supabase.sh` | Đẩy lên Supabase qua Management API |

## Các migration

| File | Nội dung |
|---|---|
| `0100_core` | 12 schema, tài khoản, vai trò, quyền, ủy quyền, đối tác, nhật ký thao tác |
| `0200_master` | Vật tư, điều kiện mua theo NCC, tham số công nghệ có phiên bản, mã lõi, sản phẩm, spec có phiên bản, BOM, máy, công đoạn |
| `0300_inventory` | 4 kho, vị trí, lô, bobin/bao có QR, chứng từ kho, sổ cái kho bất biến, tồn, kiểm kê |
| `0400_sales_plan_purchase` | SO, giữ hàng, kế hoạch kỳ, MRP, đề xuất mua tối ưu, PR, PO, nhận hàng |
| `0500_mfg_qa_cost` | Lệnh SX, công đoạn, phả hệ lô, phế, dừng máy, kiểm tra chất lượng, NCR, giá thành |
| `0600_wf_iot_integ` | Luồng duyệt, dữ liệu máy (phân vùng theo ngày), hàm nhận dữ liệu gateway, hàng đợi MISA |
| `0700_functions` | Bộ tính định mức, phát hành spec, ghi sổ kho + bình quân di động, MRP, ATP/giữ hàng, truy xuất, duyệt, giá thành |
| `0800_security` | GRANT, RLS cho mọi bảng, ẩn cột giá, Realtime, lịch pg_cron |
| `0900_reference_data` | 18 vai trò + ma trận quyền, 13 luồng duyệt, kho, công đoạn, routing, lý do, nhóm SP, máy |
| `1700_hardening` | Vá bảo mật/hiệu năng sau kiểm tra trên Supabase |
| `1800_app_views` | Schema `app` cho web app: view màn hình, `me()`, khởi tạo quản trị, quản trị người dùng, nhập pilot |
| `2300_machines` | Module Quản lý máy: dây chuyền + máy con, thông số, linh kiện, dải hoạt động, tốc độ theo sản phẩm (duyệt), người đứng máy, tài liệu; bảo dưỡng (kế hoạch, phiếu BD/SC, checklist đầu ca, nhắc lịch), nhật ký trạng thái, kiểm tra năng lực, báo cáo tháng; quyền `machine`; lịch pg_cron |
| `2200_role_standard` | Áp dụng Quy chuẩn vai trò & nhiệm vụ nhân sự (25/10/2026): xem mục bên dưới |
| `2400_inventory_core` | Kho (1): cài đặt kho, người giữ kho, 20 vị trí, bobin trung gian, bảng bì, tồn theo đơn vị chứa (QR), phiếu lĩnh, kiểm kê, ghi sổ lõi (khóa kỳ, khóa kiểm kê, FEFO/QC/HSD), `inv.post_doc` |
| `2500_inventory_ops` | Kho (2): phiếu lĩnh theo định mức + bổ sung, cấp/trả quét QR, nhận hàng, QC giải phóng lô, chuyển vị trí, cắt bobin, đổi mã, hàng trả, tồn đầu kỳ, phế, bán phế, lệnh giao, kiểm kê, hậu kiểm, phiếu đảo, in tem, ghi đầu ra công đoạn |
| `2600_inventory_app` | Kho (3): luồng duyệt kho (gộp với 2200), cảnh báo hằng ngày (pg_cron `bmt_inv_daily_alerts`), view cho web, nhập–xuất–tồn, báo cáo hao hụt 5 nhóm + cân bằng đồng |
| `1000`–`1600_seed_*` | Từ Excel: 51 vật tư, 59 tham số, 10 mã lõi, 78 SKU, spec v1, kết quả định mức, 1.358 dòng BOM (chia nhỏ < 65 KB/file) |

## Quy chuẩn vai trò (migration 2200)

| Nội dung | Cách làm trong hệ thống |
|---|---|
| Vai trò xung đột | Không gán chung: Thủ kho + Kế toán kho; Thủ kho + NV mua hàng; KTT + Kế toán kho (tài khoản Quản trị được miễn khi chạy thử) |
| Phạm vi kho | Quản trị → Người dùng: chọn kho được giao; ghi sổ và phiếu lĩnh kiểm tra phạm vi |
| Kế hoạch SX tháng | Giám đốc lập → Quản lý SX xác nhận năng lực → Chủ tịch HĐQT phê duyệt |
| PR | Giám đốc duyệt nhu cầu; NV mua hàng được sinh PR từ MRP |
| PO theo hạn mức | Dưới 20 tr: Giám đốc; từ 20 tr / NCC mới / nhập khẩu / thiết bị: thêm TP mua hàng; trên 200 tr / nhập khẩu / thiết bị: thêm Chủ tịch HĐQT |
| Spec | TP Kỹ thuật/QA lập → Quản lý SX xác nhận → Giám đốc phát hành; đã bỏ quy trình "thay đổi nhỏ" |
| Cấp NVL vượt định mức | TP Kỹ thuật/QA duyệt phiếu lĩnh bổ sung; phiếu lĩnh theo định mức (`inv.create_requisition`, `inv.create_wo_issue` gọi lại hàm này từ 2600), xuất vượt bị chặn |
| Kiểm kê / chốt giá thành | Kiểm kê: Kế toán SX lập biên bản → Kế toán trưởng duyệt (từ 2600); chốt giá thành: Kế toán trưởng; quá 24 giờ Giám đốc được duyệt thay |
| Người duyệt là người lập | Bỏ bước nếu Giám đốc đã duyệt ở bước khác, nếu không thì chuyển Giám đốc |
| Kiểm soát kho | Từ 2600: Kế toán SX duyệt/trả lại phiếu đã ghi sổ ở `/kho/phieu?tab=duyet`; cân bằng đồng ở `/bao-cao/hao-hut?tab=dong`, ngưỡng ở `/kho/cai-dat` (TP Kỹ thuật/QA) |
| Vá bảo mật | Phát hành spec và phát lệnh SX chỉ qua quy trình duyệt |

## Hàm nghiệp vụ chính

| Hàm | Việc làm |
|---|---|
| `master.calc_spec(spec)` | Tính A, D bó, K bện, kg/km đồng và cách điện, Rdc (CAL-01…06) |
| `master.check_spec(spec)` | Kiểm tra Rdc, kiện quá tải, bện nhiều cấp, drain, thương hiệu/vỏ theo nhóm |
| `master.new_spec_version(spec, level)` | Tạo phiên bản mới sao chép BOM |
| `wf.submit / wf.act` | Gửi duyệt, duyệt, trả lại; chặn tự duyệt, bắt buộc lý do trả lại, phát hiện sửa sau khi gửi |
| `plan.run_mrp(plan)` | Dự trù vật tư: hao hụt, khởi động, đóng gói, tồn khả dụng, hàng về, MOQ, bội số, ngày đặt |
| `plan.create_pr_from_mrp(run)` | Sinh PR (chỉ khi kế hoạch chính thức đã BGĐ duyệt) |
| `inv.post_doc(doc)` | Ghi sổ kho, cập nhật bình quân di động, chặn xuất lô chưa đạt QC, phế giá trị 0, đưa vào hàng đợi MISA |
| `sales.atp / sales.reserve_so` | Tồn TP khả dụng, giữ bobin cho SO, phần thiếu chuyển yêu cầu SX |
| `mfg.release_wo / mfg.record_output` | Phát lệnh theo routing; ghi lô đầu ra và phả hệ lô |
| `mfg.trace_back / mfg.trace_forward` | Truy xuất ngược về lô NVL, xuôi ra bobin và SO |
| `cost.calc_wo(wo, period)` | Giá thành định mức và thực tế, chênh lượng và chênh giá, phân bổ theo giờ máy |
| `iot.ingest_batch(json)` | Gateway ghi dữ liệu máy (chỉ service_role) |

## Chạy thử cục bộ

```bash
PGURL="host=/tmp port=5433 user=postgres" scripts/apply_local.sh bmt_test
python3 -I tests/test_parity.py <file.xlsx> "host=/tmp port=5433 user=postgres dbname=bmt_test"
psql "host=/tmp port=5433 user=postgres dbname=bmt_test" -f tests/test_flows.sql
```

Kết quả lần chạy gần nhất:
- Định mức 78 SKU khớp Excel, sai số tối đa 2,2e-13.
- MRP 8 SKU / 34 vật tư khớp tuyệt đối.
- 47/47 kiểm thử luồng đạt.

## Đẩy lên Supabase

**Cách chính: GitHub Actions** (workflow `.github/workflows/bmt-mes-db-deploy.yml`, chạy `scripts/deploy_psql.sh`)
1. Supabase Dashboard → project → nút **Connect** → chọn **Session pooler** → copy chuỗi `postgresql://postgres.<ref>:[YOUR-PASSWORD]@…pooler.supabase.com:5432/postgres`, thay `[YOUR-PASSWORD]` bằng mật khẩu database.
2. GitHub repo → **Settings → Secrets and variables → Actions → New repository secret**: tên `SUPABASE_DB_URL`, giá trị là chuỗi trên.
3. Tab **Actions** → **BMT MES – Deploy database** → **Run workflow**.

Script chỉ chạy migration chưa có trong `supabase_migrations.schema_migrations`, mỗi migration trong một transaction (lỗi thì dừng, không để dở dang), cuối cùng in số liệu kiểm tra. Chạy lại an toàn. Không đụng tới bảng cũ trong `public`.

**Cách khác:** `scripts/deploy_supabase.sh` (Management API, cần `SUPABASE_ACCESS_TOKEN`) hoặc `SUPABASE_DB_URL=... scripts/deploy_psql.sh` trên máy có psql.

## Web app giai đoạn 1 (`web/`)

Next.js 15 + Supabase Auth. Mọi truy vấn chạy bằng phiên của người đăng nhập, nên RLS trong database quyết định ai thấy/sửa gì.

| Trang | Việc làm |
|---|---|
| `/login`, `/khoi-tao` | Đăng nhập; người đầu tiên (khi chưa có ADMIN) nhận vai trò quản trị |
| `/` Tổng quan | Spec đã phát hành, SKU Rdc vượt, vật tư thiếu giá/lead time, việc chờ duyệt |
| `/duyet` Hộp duyệt | Chờ tôi duyệt / tôi đã gửi / tất cả; phê duyệt, trả lại (bắt buộc lý do), ghi ý kiến; các bước + lịch sử |
| `/san-pham` | 78 SKU, lọc theo nhóm/trạng thái/Rdc vượt; chi tiết: cấu trúc, định mức, kiểm tra tự động, BOM, gửi duyệt phát hành, nhập kết quả pilot, chấp nhận sai lệch Rdc |
| `/vat-tu` | 51 vật tư, tồn khả dụng; Mua hàng nhập MOQ, bội số, lead time, giá, mã NCC (ẩn giá với người không có quyền) |
| `/ke-hoach` | Tạo kế hoạch kỳ, thêm dòng SKU, chạy MRP, gửi duyệt, sinh PR |
| `/quan-tri` | Tạo tài khoản, gán vai trò, khóa/mở người dùng |
| `/may` | Danh sách dây chuyền, trạng thái, việc cần xử lý (hỏng, quá hạn bảo dưỡng, tốc độ chờ duyệt, checklist, phụ tùng thiếu) |
| `/may/[id]` | Hồ sơ máy: máy con, thông số, linh kiện, dải hoạt động, tốc độ theo sản phẩm, bảo dưỡng, người đứng máy, tài liệu, lịch sử; cập nhật trạng thái / báo hỏng |
| `/may/bao-duong` | Kế hoạch bảo dưỡng (chu kỳ ngày / giờ chạy / km, tự đặt), phiếu bảo dưỡng và sửa chữa, lịch 30 ngày |
| `/may/checklist` | Checklist bảo dưỡng đầu ca của NV vận hành; TP Kỹ thuật/QA kiểm tra |
| `/may/toc-do`, `/may/kiem-tra` | Tốc độ chuẩn (duyệt, duyệt tạm); kiểm tra năng lực kế hoạch theo tốc độ, tình trạng máy, bảo dưỡng, người đứng máy, số ca, tăng ca |
| `/may/lich-su`, `/may/bao-cao` | Dòng thời gian trạng thái + nhật ký sự kiện; báo cáo bảo trì tháng (tự gửi email Ban giám đốc ngày 1) |
| `/may/cai-dat` | Giờ ca, ngày làm việc, tỷ lệ xếp lịch, ngày nhắc bảo dưỡng nhỏ/lớn, số máy tối đa một người, mục checklist |
| `/kho` | Tổng quan kho: việc chờ (QC, hậu kiểm, giá nhập, phiếu lĩnh, hạn dùng, mức đặt hàng, lệnh giao) và các thao tác theo vai trò |
| `/kho/quet` | Quét QR (camera hoặc máy quét) tra ống/bao/bobin: tồn, lô, QC, hạn dùng, lịch sử |
| `/kho/nhan-hang`, `/kho/qc` | Nhận hàng theo PO/không PO (cân tổng − bì), in tem; QC giải phóng/cách ly/không nhận lô, mở NCR |
| `/kho/cap-phat`, `/kho/nhan-nvl`, `/kho/tra` | Phiếu lĩnh theo định mức + bổ sung (TP KT/QA duyệt), cấp bằng quét QR theo FEFO; công nhân xác nhận nhận tại máy; trả NVL thừa |
| `/kho/chuyen`, `/kho/ton`, `/kho/phieu` | Chuyển vị trí; tồn tổng hợp/chi tiết, dưới mức đặt hàng; phiếu kho, Kế toán SX duyệt trong ngày, nhập giá, phiếu đảo |
| `/kho/kiem-ke`, `/kho/phe`, `/kho/xuat-ban` | Kiểm kê (đếm mù, Kế toán trưởng duyệt chênh lệch); ghi phế, bán phế; lệnh giao, quét bobin lên xe |
| `/kho/thanh-pham`, `/kho/bobin`, `/kho/cai-dat` | Cắt bobin, hàng khách trả, đổi mã/hạ cấp; bobin trung gian; thông số kho, vị trí, bảng bì, mức đặt hàng, tồn đầu kỳ |
| `/kho/so-cai`, `/bao-cao/hao-hut` | Nhập – xuất – tồn, thẻ kho; báo cáo hao hụt 5 nhóm, theo lệnh, cân bằng đồng, Pareto phế |
| `/in/tem` | In tem QR 100 × 75 mm cho đơn vị chứa (`?doc=`, `?hu=`) và vị trí (`?loc=`); in lại phải ghi lý do |

Số nhập theo kiểu Việt Nam: `3.500` = ba nghìn năm trăm, `268.000` = 268 nghìn, `1,5` hoặc `1.5` = một phẩy năm.

### Kiểm thử

- `dev/local_stack.sh up`: dựng "Supabase thu nhỏ" (Postgres + GoTrue + PostgREST + proxy) với đủ migration.
- `web/tests/run_e2e.sh`: dựng lại từ đầu, build, chạy 31 kiểm tra trên trình duyệt thật (Playwright). Gồm: khởi tạo quản trị, tạo 8 tài khoản, Mua hàng nhập giá, chặn spec Rdc vượt, duyệt spec 3 cấp, kế hoạch + MRP khớp Excel, duyệt kế hoạch 2 cấp, sinh PR, phân quyền (vận hành không thấy giá/quản trị).

### Triển khai lên Vercel

1. Chạy workflow **BMT MES – Deploy database** (áp migration mới).
2. Supabase → **Project Settings → Data API → Exposed schemas**: thêm `app, core, master, sales, plan, purchase, inv, mfg, qa, cost, wf, iot, integ`.
3. Supabase → **Authentication → Sign In / Providers**: tắt "Allow new users to sign up" (tài khoản chỉ do Quản trị tạo).
4. https://vercel.com/new → Import repo `IHN` → **Root Directory** = `bmt-mes/web` → thêm Environment Variables:
   - `NEXT_PUBLIC_SUPABASE_URL` = `https://critwnuscvdchdbvwygv.supabase.co`
   - `NEXT_PUBLIC_SUPABASE_ANON_KEY` = publishable key (xem `web/.env.example`)
   - `SUPABASE_SERVICE_ROLE_KEY` = secret key trong Supabase → Project Settings → API Keys (chỉ đặt ở Vercel, không commit)
5. Supabase → **Authentication → Users → Add user**: tạo tài khoản của bạn (tick Auto confirm), đăng nhập web app, bấm "Nhận vai trò quản trị".

## Giới hạn hiện tại

- `calc_spec` tự tính lại phần lõi (đồng, cách điện, Rdc). Các lớp vỏ, độn PP, PET, AL/PET và drain (CAL-07, 08, 10) đang giữ giá trị nhập từ file Excel. Phần này sẽ được chuyển vào bộ tính ở bước làm màn hình Spec.
- Mã máy (EXT-SI-01, EXT-TP-01, BUN-01, TWS-01, PRN-01, GAU-01) là mã tạm, chờ xác nhận số máy thực tế.
- Cả 78 spec v1 đang ở trạng thái Nháp, đúng như file Excel ("Chưa duyệt"). QA cần phát hành spec cho các mã đang sản xuất trước khi go-live.
- Tài khoản người dùng tạo bằng Supabase Auth (mời qua email), sau đó thêm vào `core.profiles` và `core.user_roles`.

## Chuyển sang gói Pro

Gói được đổi ở mức tổ chức: Dashboard → Organization → Billing → Change plan → Pro. Sau khi lên Pro:
- Bật Point-in-Time Recovery (add-on).
- Chọn compute Small trở lên khi bắt đầu nhận dữ liệu máy.
- Theo BA mục 18, nên tạo project PROD riêng ở region Singapore, rồi chạy `deploy_supabase.sh` với `SUPABASE_PROJECT_REF` của project mới.
