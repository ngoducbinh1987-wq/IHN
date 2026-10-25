import Link from 'next/link';
import { SubmitButton } from '@/components/submit-button';
import { Flash, Toolbar } from '@/components/ui';
import { requirePerm } from '@/lib/session';
import { createPlan } from '../actions';

export const metadata = { title: 'Thêm kế hoạch' };

export default async function NewPlan({ searchParams }: { searchParams: Promise<{ err?: string }> }) {
  const sp = await searchParams;
  await requirePerm('plan', 'create');
  return (
    <>
      <Toolbar title="Thêm kế hoạch sản xuất" actions={<Link className="btn" href="/ke-hoach">Đóng</Link>} />
      <div className="mt-4"><Flash err={sp.err} /></div>
      <form action={createPlan} className="card flex max-w-3xl flex-col gap-4 p-4 md:p-5">
        <div className="grid gap-3 sm:grid-cols-2">
          <label className="lbl"><span className="req">Kỳ kế hoạch</span><input className="inp" name="period_label" placeholder="Tháng 11/2026" required /></label>
          <label className="lbl"><span className="req">Ngày cần vật tư</span><input className="inp" type="date" name="need_date" required /></label>
        </div>
        <fieldset className="flex flex-col gap-2">
          <legend className="mb-1 text-[13px] text-muted">Chế độ</legend>
          <label className="flex items-start gap-2 text-[14px]"><input type="radio" name="mode" value="OFFICIAL" defaultChecked className="mt-1 accent-[rgb(var(--brand))]" />
            <span><b>Chính thức</b> — chỉ mã đã phát hành spec; sau khi BGĐ duyệt được sinh đề xuất mua (PR)</span></label>
          <label className="flex items-start gap-2 text-[14px]"><input type="radio" name="mode" value="PRELIMINARY" className="mt-1 accent-[rgb(var(--brand))]" />
            <span><b>Sơ bộ</b> — cho phép mã đang chờ duyệt spec, dùng để ước tính, không sinh PR</span></label>
        </fieldset>
        <div className="flex gap-2 border-t border-line pt-4"><SubmitButton className="btn btn-pri">Tạo kế hoạch</SubmitButton><Link className="btn" href="/ke-hoach">Hủy</Link></div>
      </form>
    </>
  );
}
