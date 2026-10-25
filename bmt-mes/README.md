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
| `supabase/migrations/` | 16 migration, chạy theo thứ tự tên file |
| `docs/BA_BMT_MES_v1.html` | Tài liệu BA kèm mockup giao diện |
| `tools/gen_seed.py` | Sinh migration dữ liệu từ file Excel (chạy lại khi Excel đổi) |
| `tests/test_parity.py` | Đối chiếu định mức và MRP với file Excel |
| `tests/test_flows.sql` | 47 kiểm thử luồng nghiệp vụ, chạy trong transaction rồi rollback |
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
| `1000`–`1600_seed_*` | Từ Excel: 51 vật tư, 59 tham số, 10 mã lõi, 78 SKU, spec v1, kết quả định mức, 1.358 dòng BOM (chia nhỏ < 65 KB/file) |

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

```bash
export SUPABASE_ACCESS_TOKEN=...   # đặt trong cấu hình môi trường, không dán vào chat
scripts/deploy_supabase.sh
```

Script này chỉ chạy những migration chưa có trong `supabase_migrations.schema_migrations`, rồi mở 12 schema cho Data API. Các bảng test cũ trong schema `public` được giữ nguyên.

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
