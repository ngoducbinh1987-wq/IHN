import Link from 'next/link';
import { SubmitButton } from '@/components/submit-button';
import { Flash, Toolbar } from '@/components/ui';
import { requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { createAdj, createPlan } from '../actions';

export const metadata = { title: 'Thêm kế hoạch' };

type Plan = { id: string; plan_no: string; period_label: string; period_month: string | null; status: string };

export default async function NewPlan({ searchParams }: { searchParams: Promise<{ err?: string }> }) {
  const sp = await searchParams;
  await requirePerm('plan', 'create');
  const supabase = await createClient();
  const { data } = await supabase.schema('plan').from('production_plans')
    .select('id, plan_no, period_label, period_month, status').neq('status', 'CANCELLED').order('created_at', { ascending: false }).returns<Plan[]>();
  const plans = data ?? [];
  const taken = new Map(plans.filter((p) => p.period_month).map((p) => [p.period_month!.slice(0, 7), p.plan_no]));
  const approved = plans.filter((p) => p.status === 'APPROVED');

  // Năm nay và năm sau (giờ VN); mặc định tháng sau còn trống
  const now = new Date(Date.now() + 7 * 3600 * 1000);
  const y0 = now.getUTCFullYear();
  const years = [y0, y0 + 1];
  const months = Array.from({ length: 12 }, (_, i) => i + 1);
  const key = (y: number, m: number) => `${y}-${String(m).padStart(2, '0')}`;
  let defY = y0; let defM = now.getUTCMonth() + 2;
  if (defM > 12) { defM = 1; defY = y0 + 1; }
  for (let i = 0; i < 24 && taken.has(key(defY, defM)); i++) { defM++; if (defM > 12) { defM = 1; defY++; } }
  if (defY > y0 + 1) { defY = y0 + 1; defM = 12; }
  const takenList = [...taken.entries()].filter(([k]) => years.includes(Number(k.slice(0, 4)))).sort();

  return (
    <>
      <Toolbar title="Thêm kế hoạch sản xuất" actions={<Link className="btn" href="/ke-hoach">Đóng</Link>} />
      <div className="mt-4"><Flash err={sp.err} /></div>

      <form action={createPlan} className="card mb-4 flex max-w-3xl flex-col gap-4 p-4 md:p-5" aria-label="Kế hoạch tháng mới">
        <h2 className="text-[15px] font-semibold">Kế hoạch tháng mới</h2>
        <div className="grid gap-3 sm:grid-cols-3">
          <label className="lbl"><span className="req">Tháng</span>
            <select className="inp" name="month" defaultValue={defM} required>
              {months.map((m) => <option key={m} value={m}>Tháng {String(m).padStart(2, '0')}</option>)}
            </select></label>
          <label className="lbl"><span className="req">Năm</span>
            <select className="inp" name="year" defaultValue={defY} required>
              {years.map((y) => <option key={y} value={y}>{y}</option>)}
            </select></label>
          <label className="lbl"><span className="req">Ngày cần vật tư</span><input className="inp" type="date" name="need_date" required /></label>
        </div>
        <p className="text-[12.5px] text-muted">
          Mỗi tháng chỉ một kế hoạch, mọi kế hoạch là chính thức (chỉ mã đã phát hành spec). TP SX lập, chạy MRP → Giám đốc duyệt → Chủ tịch HĐQT chốt.
          {takenList.length > 0 && <> Đã có: {takenList.map(([k, no]) => `${k.slice(5)}/${k.slice(0, 4)} (${no})`).join(', ')}.</>}
        </p>
        <div className="flex gap-2 border-t border-line pt-4"><SubmitButton className="btn btn-pri">Tạo kế hoạch</SubmitButton><Link className="btn" href="/ke-hoach">Hủy</Link></div>
      </form>

      <form action={createAdj} className="card flex max-w-3xl flex-col gap-4 p-4 md:p-5" id="de-xuat-hieu-chinh" aria-label="Đề xuất hiệu chỉnh kế hoạch tháng">
        <input type="hidden" name="from" value="moi" />
        <h2 className="text-[15px] font-semibold">Đề xuất hiệu chỉnh kế hoạch tháng</h2>
        <p className="text-[12.5px] text-muted">
          Tăng, giảm sản lượng, thêm, bỏ mã, đổi hạn giao của kế hoạch tháng đã duyệt. Quy trình: TP SX lập → Giám đốc duyệt → Chủ tịch HĐQT duyệt.
          MES chạy bảng MRP hiệu chỉnh: tăng thì ra số mua thêm; giảm thì vật tư Giám đốc đã duyệt mua giữ nguyên, đề xuất mua chưa duyệt được giảm.
        </p>
        {approved.length === 0 ? <p className="text-[14px]">Chưa có kế hoạch tháng nào đã duyệt.</p> : (
          <>
            <div className="grid gap-3 sm:grid-cols-2">
              <label className="lbl"><span className="req">Kế hoạch tháng</span>
                <select className="inp" name="plan_id" required>
                  {approved.map((p) => <option key={p.id} value={p.id}>{p.plan_no} – {p.period_label}</option>)}
                </select></label>
              <label className="lbl"><span className="req">Lý do hiệu chỉnh</span><input className="inp" name="reason" required placeholder="VD: khách ABC đặt thêm 3.000 m" /></label>
            </div>
            <div className="flex gap-2 border-t border-line pt-4"><SubmitButton className="btn btn-pri">Lập đề xuất hiệu chỉnh</SubmitButton></div>
          </>
        )}
      </form>
    </>
  );
}
