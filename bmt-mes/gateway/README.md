# BMT MES – Gateway đọc PLC tại nhà máy (nhánh `plc-gateway`)

Nhánh riêng để làm việc bằng **Claude Desktop trên máy chủ đặt tại nhà máy**: kết nối PLC các máy (chỉ đọc), gom dữ liệu và gửi lên BMT MES (Supabase). Phiên Claude trên cloud không vào được mạng xưởng nên phần này làm tại chỗ.

## 1. Chuẩn bị máy chủ nhà máy
- Máy tính/IPC chạy liên tục, 2 cổng mạng: một vào mạng máy (OT, VLAN riêng của PLC), một ra internet. Windows 10/11 hoặc Ubuntu đều được.
- Cài: Git, Node.js 22 LTS, (tuỳ chọn) Docker Desktop; Claude Desktop, đăng nhập tài khoản của anh.
- Mạng: máy chủ ping được IP các PLC; ra được internet tới `awjbtcvpzjjxdczepwyr.supabase.co` (HTTPS 443). Không mở cổng vào.

## 2. Mở nhánh trong Claude Desktop
```bash
git clone https://github.com/ngoducbinh1987-wq/IHN.git
cd IHN
git checkout plc-gateway
```
Trong Claude Desktop → Claude Code → chọn thư mục `IHN/bmt-mes/gateway`. Claude đọc `CLAUDE.md` của thư mục này (quy tắc chỉ đọc PLC, không đưa khóa vào git…).
Mỗi lần làm xong: `git add`, `git commit`, `git push origin plc-gateway` (Claude làm khi anh yêu cầu).

Cách khác: giữ phiên cloud và cho phép nó dùng thư mục này trên máy chủ (Claude Desktop → Settings → Claude Code → Remote Control, chọn thư mục `IHN`). Khi đó phiên cloud chạy lệnh trên máy chủ nhà máy.

## 3. Thông tin cần chuẩn bị trước khi kết nối
Điền bảng này (gửi Claude ở phiên tại nhà máy). Máy theo mã MES:

| Máy MES | Hãng / model PLC | IP | Giao thức (S7 / OPC UA / Modbus TCP) | Rack/Slot hoặc Unit ID | Đã bật PUT/GET? | Tag có sẵn (mét, tốc độ, nhiệt, OD, trạng thái, lỗi) |
|---|---|---|---|---|---|---|
| BUN-01 bện 630 | | | | | | |
| EXT-SI-01 line silicone 1 | | | | | | |
| EXT-SI-02 line silicone 2 | | | | | | |
| EXT-TP-01 line vỏ 1 | | | | | | |
| EXT-TP-02 line vỏ 2 | | | | | | |
| TWS-01 xoắn 800 | | | | | | |
| SIL-MIX máy trộn | | | | | | |
| PACK-01 đóng gói | | | | | | |
| GAU-01 máy đo OD | | | | | | |

Kèm: địa chỉ từng tag (ví dụ `DB10.DBD4` REAL tốc độ m/ph; Modbus `40001` × 0,1), đơn vị, hệ số. Mẫu: `tags.example.csv`.
Pilot đề xuất: **EXT-SI-01 + máy đo OD** (theo tài liệu BA giai đoạn 4), sau đó mở rộng.

## 4. Dữ liệu gửi lên
Hàm nhận: `iot.ingest_batch(payload jsonb)` – mảng bản ghi, mỗi bản ghi một máy một thời điểm:
```json
[{"machine":"EXT-SI-01","ts":"2026-11-12T08:00:01+07:00","state":1,"speed_mpm":62.5,"length_m":12345.6,
  "od_mm":2.72,"od_dev_mm":0.03,"temps":[180,185,190],"current_a":12.4,"kwh":3456.7,"extra":{"melt_bar":210}}]
```
- `state`: 0 dừng, 1 chạy, 2 chờ, 3 lỗi. `length_m` là bộ đếm mét cộng dồn của PLC (MES tự trừ để ra mét mỗi phút). Trường không có thì bỏ.
- MES tự gắn lệnh đang chạy, cập nhật trạng thái máy (`iot.machine_state`), tổng hợp mỗi phút (`iot.telemetry_1m`, tốc độ thực tế từ PLC dùng cho lịch máy), xóa dữ liệu thô sau 90 ngày.
- Gửi theo lô (ví dụ mỗi 5–10 giây một lần, gồm các mẫu 1–5 giây), có đệm trên đĩa khi mất mạng (≥ 24 giờ) và gửi lại; trùng (máy, thời điểm) MES tự bỏ.
- Dung lượng: 1 mẫu/giây × 9 máy ≈ 130 MB/ngày. Gói Supabase Free (khoảng 500 MB) không đủ → nâng Pro trước khi chạy thật, hoặc đọc 5 giây/lần trong giai đoạn thử.

## 5. Việc phía MES (phiên cloud làm, theo quy trình migration chung)
- [ ] Cách gateway ghi vào MES: schema `iot` chưa mở qua API. Đề xuất: tạo role Postgres riêng `bmt_gateway` chỉ có quyền gọi `iot.ingest_batch`, gateway kết nối Postgres qua cổng pooler (TLS) bằng mật khẩu riêng đặt trong `.env`; hoặc hàm `app.iot_ingest` gọi qua API với khóa riêng. Chốt khi bắt đầu pilot.
- [ ] Nạp `iot.machine_tags` theo bảng tag thực tế.
- [ ] Đổi `master.machines.data_mode` của máy đã nối sang AUTO/BOTH khi số liệu PLC đã đối chiếu đúng (mét PLC khớp mét khai báo ±0,5 %).
- [ ] Rút thời gian giữ dữ liệu thô (90 → 30 ngày), chia bảng phút theo tháng, theo dõi dung lượng (đã đề xuất 11/11/2026).

## 6. Nhật ký
- 12/11/2026: tạo nhánh `plc-gateway` từ `main` (ecca2fa), thêm hướng dẫn, quy tắc (`CLAUDE.md`), mẫu `.env.example`, `tags.example.csv`. Chưa có code gateway, chưa kết nối máy nào (chờ thông tin PLC mục 3).
