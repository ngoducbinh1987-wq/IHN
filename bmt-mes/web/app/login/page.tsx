import { Activity, ArrowRight, Mail, ScanLine, ShieldCheck, Smartphone } from 'lucide-react';
import { PasswordField } from '@/components/password-field';
import { SubmitButton } from '@/components/submit-button';
import { Flash } from '@/components/ui';
import { signIn } from './actions';

export const metadata = { title: 'Đăng nhập' };

// Ảnh minh họa dựng từ mô hình 3D nhà máy BMT (bản R02). Tọa độ điểm tính theo % khung ảnh
const PULSES: [number, number][] = [
  [33.4, 58.6], [31.0, 40.1], [32.1, 24.0], [52.7, 59.4], [63.5, 67.5], [75.4, 84.5], [7.9, 39.7],
];
const CHIPS: { x: number; y: number; text: string; align?: 'left' }[] = [
  { x: 52.7, y: 59.4, text: 'Máy chạy, dừng, tốc độ theo thời gian thực' },
  { x: 75.4, y: 84.5, text: 'Kết quả QC trên từng cuộn cáp' },
  { x: 7.9, y: 39.7, text: 'Nhiệt độ, độ ẩm phòng lạnh', align: 'left' },
];
const FEATURES = [
  { icon: Activity, title: 'Giám sát dây chuyền', text: 'Trạng thái máy, tiến độ lệnh sản xuất' },
  { icon: ScanLine, title: 'Truy xuất chất lượng', text: 'Spec, BOM, QC đến từng cuộn cáp' },
  { icon: Smartphone, title: 'Duyệt mọi lúc', text: 'Đề xuất, kế hoạch, mua hàng trên điện thoại' },
];

// Ba ô vuông lấy từ chi tiết trên logo BMTcable
function PixelMark({ className = '' }: { className?: string }) {
  return (
    <span className={`inline-grid grid-cols-3 gap-[2px] ${className}`} aria-hidden="true">
      <i className="h-[5px] w-[5px] bg-transparent" /><i className="h-[5px] w-[5px] bg-brand" /><i className="h-[5px] w-[5px] bg-brand" />
      <i className="h-[5px] w-[5px] bg-brand" /><i className="h-[5px] w-[5px] bg-transparent" /><i className="h-[5px] w-[5px] bg-transparent" />
    </span>
  );
}

function FactoryArt({ chips = true }: { chips?: boolean }) {
  return (
    <div className="login-art relative mx-auto aspect-[4800/2477]">
      <img src="/brand/nha-may-bmt-2400.webp" srcSet="/brand/nha-may-bmt-1200.webp 1200w, /brand/nha-may-bmt-2400.webp 2400w"
        sizes="(min-width: 1024px) 62vw, 100vw" alt="Mô hình 3D nhà máy cáp BMT với các dây chuyền bện, bọc silicone, xoắn và đùn vỏ"
        className="absolute inset-0 h-full w-full select-none object-contain" draggable={false} />
      {PULSES.map(([x, y], i) => (
        <span key={i} className="login-pulse" style={{ left: `${x}%`, top: `${y}%`, animationDelay: `${i * 0.35}s` }} />
      ))}
      {chips && CHIPS.map((c) => (
        <span key={c.text} className={`login-chip ${c.align === 'left' ? 'login-chip-l' : ''}`} style={{ left: `${c.x}%`, top: `${c.y}%` }}>
          <i className="h-1.5 w-1.5 shrink-0 rounded-full bg-brand" aria-hidden="true" />{c.text}
        </span>
      ))}
    </div>
  );
}

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ err?: string; ok?: string }> }) {
  const sp = await searchParams;
  const year = new Date().getFullYear();
  return (
    <main className="min-h-full bg-surface lg:grid lg:min-h-screen lg:grid-cols-[minmax(0,1fr)_minmax(440px,34vw)]">
      {/* Bên trái: thương hiệu và ảnh nhà máy số */}
      <section className="login-side relative hidden min-h-screen flex-col overflow-hidden text-white lg:flex" aria-label="Giới thiệu BMT MES">
        <div className="relative z-10 flex items-center justify-between px-10 pt-8 xl:px-14">
          <div className="flex items-center gap-2.5 text-[15px] font-medium tracking-wide">
            <PixelMark />BMT MES
          </div>
          <div className="text-[13px] text-white/45">Nam Đông Hưng · Hưng Yên</div>
        </div>

        <div className="login-intro relative z-10 px-10 pt-12 xl:px-14 xl:pt-16">
          <div className="text-[12px] font-medium uppercase tracking-[0.16em] text-white/55">Công ty CP Cáp chuyên dụng BMT</div>
          <h1 className="login-h1 mt-4 text-[36px] font-medium leading-[1.15] tracking-tight xl:text-[44px]">
            Nhà máy số cho<br /><span className="text-white/60">kỷ nguyên sản xuất mới</span>
          </h1>
          <p className="mt-4 max-w-[520px] text-[15px] leading-relaxed text-white/60">
            Kế hoạch, sản xuất, chất lượng, vật tư và quy trình duyệt của nhà máy cáp BMT trên một hệ thống.
          </p>
        </div>

        <div className="login-stage relative z-0 min-h-0 flex-1 px-4 xl:px-8">
          <div className="login-fit mx-auto">
            <FactoryArt />
          </div>
        </div>

        <div className="login-feat relative z-10 grid grid-cols-3 gap-6 border-t border-white/10 px-10 py-6 xl:px-14">
          {FEATURES.map((f) => (
            <div key={f.title} className="flex gap-3">
              <f.icon size={18} className="mt-0.5 shrink-0 text-white/70" aria-hidden="true" />
              <div>
                <div className="text-[13.5px] font-medium">{f.title}</div>
                <div className="mt-0.5 text-[12.5px] leading-snug text-white/50">{f.text}</div>
              </div>
            </div>
          ))}
        </div>
      </section>

      {/* Điện thoại, máy tính bảng dọc: dải ảnh thu gọn */}
      <section className="login-side relative overflow-hidden px-5 pb-2 pt-5 text-white lg:hidden" aria-label="Giới thiệu BMT MES">
        <div className="flex items-center gap-2 text-[14px] font-medium tracking-wide"><PixelMark />BMT MES</div>
        <div className="mt-1 text-[13px] text-white/55">Nhà máy số cho kỷ nguyên sản xuất mới</div>
        <div className="mt-2"><FactoryArt chips={false} /></div>
      </section>

      {/* Bên phải: biểu mẫu đăng nhập */}
      <section className="flex min-h-full flex-col px-6 py-8 sm:px-10 lg:min-h-screen lg:px-12 xl:px-16">
        <div className="flex flex-1 flex-col justify-center">
          <div className="mx-auto w-full max-w-[400px]">
            <img src="/logo-bmt.png" alt="BMTcable" width={720} height={189} className="h-10 w-auto sm:h-11" />
            <h2 className="login-gap mt-10 text-[28px] font-medium leading-tight tracking-tight text-ink">Đăng nhập</h2>
            <p className="mt-2 text-[15px] leading-relaxed text-muted">Dùng tài khoản công ty được cấp để vào hệ thống điều hành sản xuất.</p>

            <div className="mt-7"><Flash err={sp.err} ok={sp.ok} /></div>
            <form action={signIn} className="flex flex-col gap-5">
              <div className="flex flex-col gap-1.5">
                <label htmlFor="email" className="text-[13.5px] font-medium text-ink/85">Email công ty</label>
                <div className="relative">
                  <Mail size={17} className="pointer-events-none absolute left-3.5 top-1/2 -translate-y-1/2 text-muted" aria-hidden="true" />
                  <input className="login-inp pl-10" id="email" name="email" type="email" autoComplete="username" inputMode="email"
                    required placeholder="ten@bmtcable.vn" />
                </div>
              </div>
              <div className="flex flex-col gap-1.5">
                <label htmlFor="password" className="text-[13.5px] font-medium text-ink/85">Mật khẩu</label>
                <PasswordField />
              </div>
              <SubmitButton className="login-btn mt-1" pendingText="Đang đăng nhập…">
                Đăng nhập<ArrowRight size={18} aria-hidden="true" />
              </SubmitButton>
            </form>

            <div className="mt-8 border-t border-line pt-5 text-[13.5px] leading-relaxed text-muted">
              Chưa có tài khoản hoặc quên mật khẩu? Liên hệ quản trị hệ thống để được cấp hoặc đặt lại.
            </div>
          </div>
        </div>
        <div className="mx-auto mt-10 flex w-full max-w-[400px] flex-wrap items-center justify-between gap-x-4 gap-y-1 text-[12.5px] text-muted">
          <span>© {year} BMT Cable · BMT MES</span>
          <span className="inline-flex items-center gap-1.5"><ShieldCheck size={14} aria-hidden="true" />Kết nối được mã hóa</span>
        </div>
      </section>
    </main>
  );
}
