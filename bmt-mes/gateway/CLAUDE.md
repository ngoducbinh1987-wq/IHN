# Gateway PLC tại nhà máy BMT – ghi chú cho phiên Claude Desktop

Phiên Claude này chạy **trên máy chủ tại nhà máy** (Claude Desktop, nhánh `plc-gateway`), để đọc dữ liệu PLC máy và gửi lên BMT MES.
Trả lời anh Bình bằng tiếng Việt, ngắn gọn. Đọc thêm `../../CLAUDE.md` (ghi chú chung của MES) khi cần biết database, quy trình.

## Quy tắc bắt buộc
1. **PLC chỉ đọc, không ghi xuống.** Không dùng lệnh ghi (S7 `write`, Modbus function 5/6/15/16, OPC UA Write, đổi tham số, tải chương trình). Không đổi cấu hình PLC, không bật/tắt PUT/GET thay người phụ trách điện. Thư viện nào có hàm ghi thì bọc lại, chỉ xuất hàm đọc.
2. Trước khi kết nối máy thật: hỏi anh Bình (hoặc người phụ trách điện) xác nhận IP, cổng, máy nào được thử, lúc nào máy dừng/chạy. Thử trên **một máy** trước (pilot), đọc tần suất thấp (≥ 1 giây/lần).
3. **Không đưa khóa, mật khẩu vào git hay vào chat.** Khóa nằm trong `bmt-mes/gateway/.env` (đã có trong `.gitignore`), mẫu ở `.env.example`.
4. Gateway **chỉ kết nối ra ngoài** (HTTPS/TLS tới Supabase). Không mở cổng từ internet vào mạng xưởng, không cài phần mềm điều khiển từ xa vào PLC.
5. Không quét dải mạng OT rộng (scan) khi chưa được phép; chỉ kết nối IP đã được khai.
6. Thay đổi database (bảng, hàm, quyền) **không làm ở đây**: ghi yêu cầu vào `README.md` mục "Việc phía MES", để phiên Claude trên cloud viết migration theo quy trình chung (kiểm thử cục bộ → áp Supabase → kiểm thử trên Supabase).
7. Code gateway nằm trong `bmt-mes/gateway/`; không sửa thư mục khác của MES trên nhánh này. Xong pilot thì mở pull request `plc-gateway` → `main`.
8. Mỗi khi làm xong một việc: cập nhật mục "Nhật ký" trong `README.md` (ngày, đã làm gì, đã thử máy nào, kết quả).

## Thông tin cần biết
- Máy trong MES (mã ở `master.machines.code`, dùng làm khóa `machine` khi gửi dữ liệu): BUN-01 (bện 630), EXT-SI-01, EXT-SI-02 (line đùn silicone), EXT-TP-01, EXT-TP-02 (line đùn vỏ PVC/HDPE/LSZH), TWS-01 (xoắn 800 + quấn AL/PET), SIL-MIX (máy trộn silicone), PACK-01 (đóng gói), máy con GAU-01 (đo chiều dày/OD), PRN-01 (máy in). Hiện mọi máy `data_mode` = MANUAL.
- Thiết kế ban đầu (tài liệu `bmt-mes/docs/BA_BMT_MES_v1.html` mục IoT): PLC Siemens đọc qua S7 ISO-on-TCP cổng 102 (cần PUT/GET, DB không tối ưu) hoặc OPC UA (S7-1500); thiết bị khác Modbus TCP; gateway Node.js (hoặc Node-RED) chạy Docker; mạng OT tách VLAN; đệm dữ liệu ≥ 24 giờ khi mất mạng.
- Nơi nhận dữ liệu: hàm `iot.ingest_batch(payload jsonb)` – xem `README.md` mục "Dữ liệu gửi lên".
- Tag từng máy khai ở `iot.machine_tags` (máy, tag_code, address, data_type, unit, scale); mẫu `tags.example.csv`.
