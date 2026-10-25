import { SubmitButton } from '@/components/submit-button';
import { Flash } from '@/components/ui';
import { signIn } from './actions';

export const metadata = { title: 'Đăng nhập' };

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ err?: string; ok?: string }> }) {
  const sp = await searchParams;
  return (
    <main className="grid min-h-full lg:grid-cols-[1fr_480px]">
      <div className="hidden flex-col justify-between bg-side p-10 text-white lg:flex">
        <div className="text-[15px] text-side-ink">Nhà máy cáp BMT</div>
        <div>
          <div className="text-[34px] font-medium leading-tight">Điều hành sản xuất<br />và quy trình duyệt</div>
          <p className="mt-3 max-w-md text-[15px] text-side-ink">Spec, BOM, kế hoạch, MRP, đề xuất mua hàng và duyệt chứng từ trên một hệ thống.</p>
        </div>
        <div className="h-1.5 w-24 rounded bg-brand" />
      </div>
      <div className="grid place-items-center bg-surface px-6 py-10">
        <div className="w-full max-w-sm">
          <img src="/logo-bmt.png" alt="BMTcable" className="mb-2 h-12 w-auto" />
          <div className="mb-6 text-[15px] text-muted">BMT MES · Đăng nhập bằng tài khoản công ty</div>
          <Flash err={sp.err} ok={sp.ok} />
          <form action={signIn} className="flex flex-col gap-4">
            <label className="lbl">Email công ty
              <input className="inp py-2.5" id="email" name="email" type="email" autoComplete="username" required />
            </label>
            <label className="lbl">Mật khẩu
              <input className="inp py-2.5" id="password" name="password" type="password" autoComplete="current-password" required />
            </label>
            <SubmitButton className="btn btn-pri py-2.5 text-[15px]" pendingText="Đang đăng nhập…">Đăng nhập</SubmitButton>
          </form>
          <p className="mt-5 text-[13px] text-muted">Chưa có tài khoản? Liên hệ quản trị hệ thống để được cấp.</p>
        </div>
      </div>
    </main>
  );
}
