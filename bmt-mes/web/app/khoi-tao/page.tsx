import { redirect } from 'next/navigation';
import { SubmitButton } from '@/components/submit-button';
import { Flash } from '@/components/ui';
import { getMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { signOut } from '../login/actions';

export const metadata = { title: 'Khởi tạo' };

async function claim(form: FormData) {
  'use server';
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('claim_first_admin', { p_full_name: String(form.get('full_name') ?? '') });
  if (error) redirect('/khoi-tao?err=' + encodeURIComponent(error.message));
  redirect('/quan-tri?ok=' + encodeURIComponent('Bạn là quản trị viên đầu tiên. Hãy tạo tài khoản cho các phòng ban.'));
}

// Người đã đăng nhập nhưng chưa có hồ sơ: nếu hệ thống chưa có ADMIN thì cho nhận vai trò quản trị
export default async function SetupPage({ searchParams }: { searchParams: Promise<{ err?: string }> }) {
  const sp = await searchParams;
  if (await getMe()) redirect('/');
  const supabase = await createClient();
  const { data: needsAdmin } = await supabase.schema('app').rpc('needs_first_admin');
  const { data: { user } } = await supabase.auth.getUser();
  return (
    <main className="grid min-h-full place-items-center px-4 py-10">
      <div className="w-full max-w-md">
        <div className="mb-5 text-[30px] font-bold">BMT <span className="text-brand">MES</span></div>
        <Flash err={sp.err} />
        <div className="card p-5">
          {needsAdmin ? (
            <form action={claim} className="flex flex-col gap-3">
              <p className="text-[13px]">Hệ thống chưa có quản trị viên. Tài khoản <b>{user?.email}</b> sẽ trở thành quản trị viên đầu tiên và có quyền tạo tài khoản cho các phòng ban.</p>
              <label className="lbl">Họ và tên
                <input className="inp" id="full_name" name="full_name" required />
              </label>
              <SubmitButton>Nhận vai trò quản trị</SubmitButton>
            </form>
          ) : (
            <p className="text-[13px]">Tài khoản <b>{user?.email}</b> chưa được gán hồ sơ và vai trò. Liên hệ quản trị hệ thống để được cấp quyền.</p>
          )}
        </div>
        <form action={signOut} className="mt-3"><button className="btn" type="submit">Đăng xuất</button></form>
      </div>
    </main>
  );
}
