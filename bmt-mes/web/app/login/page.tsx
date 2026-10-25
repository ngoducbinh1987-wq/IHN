import { SubmitButton } from '@/components/submit-button';
import { Flash } from '@/components/ui';
import { signIn } from './actions';

export const metadata = { title: 'Đăng nhập' };

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ err?: string; ok?: string }> }) {
  const sp = await searchParams;
  return (
    <main className="grid min-h-full place-items-center px-4 py-10">
      <div className="w-full max-w-sm">
        <div className="mb-6">
          <div className="font-display text-[34px] font-bold leading-none">BMT <span className="text-copper">MES</span></div>
          <div className="mt-1 text-[13px] text-muted">Điều hành sản xuất nhà máy cáp BMT</div>
        </div>
        <Flash err={sp.err} ok={sp.ok} />
        <form action={signIn} className="card flex flex-col gap-3 p-5">
          <label className="lbl">Email công ty
            <input className="inp" id="email" name="email" type="email" autoComplete="username" required />
          </label>
          <label className="lbl">Mật khẩu
            <input className="inp" id="password" name="password" type="password" autoComplete="current-password" required />
          </label>
          <SubmitButton pendingText="Đang đăng nhập…">Đăng nhập</SubmitButton>
        </form>
        <p className="mt-4 text-[12px] text-muted">Chưa có tài khoản? Quản trị hệ thống tạo tài khoản cho bạn trong trang Quản trị.</p>
      </div>
    </main>
  );
}
