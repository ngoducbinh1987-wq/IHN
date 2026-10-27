# Chuyển database BMT MES sang Singapore

Dự án mới: **BMT MES Singapore** (`awjbtcvpzjjxdczepwyr`, vùng Singapore). Dự án cũ: **BMTcable's Project** (`critwnuscvdchdbvwygv`, Mumbai).
Database mới đã có đủ cấu trúc, dữ liệu thử đã nạp, 12 bộ kiểm thử đạt.

## A. Chuẩn bị (không ảnh hưởng người đang dùng)

Trên supabase.com, mở dự án **BMT MES Singapore**:

1. **Project Settings → Data API** (hoặc API) → **Exposed schemas**: giữ `public`, `graphql_public`, thêm
   `app, core, inv, master, mfg, plan, purchase, qa, sales, wf` → **Save**.
2. **Authentication → Sign In / Providers**: tắt **Allow new users to sign up** (dự án cũ đang tắt; chỉ Quản trị tạo tài khoản).
3. **Authentication → URL Configuration**: Site URL = `https://ihn-ten.vercel.app`; Redirect URLs thêm `https://ihn-ten.vercel.app/**`.
4. **Project Settings → API Keys**: chép **Publishable key** (`sb_publishable_…`) và **Secret key** (`sb_secret_…`, bấm Reveal). Không gửi các khóa này vào chat.

Trên vercel.com → dự án web → **Settings → Environment Variables** (môi trường Production), sửa 3 biến:

| Biến | Giá trị mới |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | `https://awjbtcvpzjjxdczepwyr.supabase.co` |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Publishable key vừa chép |
| `SUPABASE_SERVICE_ROLE_KEY` | Secret key vừa chép |

**Lưu nhưng KHÔNG bấm Redeploy.** Web vẫn chạy với database cũ cho tới lần triển khai tiếp theo.

Xong phần A thì nhắn Claude "đã chuẩn bị xong".

## B. Chuyển đổi (khoảng 10 phút, mọi người tạm ngừng nhập liệu)

1. Claude khóa ghi database cũ và gửi dữ liệu lần cuối sang dự án mới.
2. Anh/chị chạy file `02_nap_lan_cuoi.sql` trong SQL Editor của **BMT MES Singapore**, gửi kết quả cho Claude.
3. Claude kiểm số dòng, đẩy bản mới lên `main` → Vercel triển khai với 3 biến mới → web dùng database Singapore.
4. Mọi người đăng nhập lại một lần (mật khẩu không đổi).

## C. Sau chuyển đổi

- Vài ngày sau, khi mọi thứ ổn: chạy `03_don_dep.sql` trên dự án mới; tạm dừng (Pause) dự án cũ trên Supabase.
- Nếu cần quay lại: trả 3 biến trên Vercel về giá trị cũ và Redeploy; Claude mở khóa ghi database cũ.
