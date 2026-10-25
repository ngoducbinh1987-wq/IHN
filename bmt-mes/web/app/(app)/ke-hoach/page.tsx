import Link from 'next/link';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, PageHeader, Pill, StatusPill } from '@/components/ui';
import { DOC_STATUS, df, nf } from '@/lib/format';
import { can, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { createPlan } from './actions';

export const metadata = { title: 'Kế hoạch & MRP' };

export default async function PlansPage({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string }> }) {
  const sp = await searchParams;
  const me = await requirePerm('plan', 'view');
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').from('v_plans').select('*').order('created_at', { ascending: false });
  return (
    <>
      <PageHeader title="Kế hoạch & MRP" sub="Mỗi kỳ là một kế hoạch riêng; không gộp nhiều kỳ vào một cột mét" />
      <Flash ok={sp.ok} err={sp.err ?? error?.message} />
      {can(me, 'plan', 'create') && (
        <form action={createPlan} className="card mb-4 grid gap-3 p-4 sm:grid-cols-[1fr_1fr_1fr_auto] sm:items-end">
          <label className="lbl">Kỳ kế hoạch<input className="inp inp-y" name="period_label" placeholder="Tháng 11/2026" required /></label>
          <label className="lbl">Ngày cần vật tư<input className="inp inp-y" type="date" name="need_date" required /></label>
          <label className="lbl">Chế độ
            <select className="inp inp-y" name="mode" defaultValue="OFFICIAL">
              <option value="OFFICIAL">Chính thức (chỉ mã đã phát hành spec)</option>
              <option value="PRELIMINARY">Sơ bộ (cho phép mã chờ duyệt, không sinh PR)</option>
            </select>
          </label>
          <SubmitButton>Tạo kế hoạch</SubmitButton>
        </form>
      )}
      <div className="card overflow-x-auto">
        {data && data.length > 0 ? (
          <table className="tbl">
            <thead><tr><th>Mã KH</th><th>Kỳ</th><th>Chế độ</th><th className="num">Số SKU</th><th className="num">Tổng mét</th><th>Ngày cần VT</th><th>MRP</th><th>TT</th></tr></thead>
            <tbody>
              {data.map((p) => (
                <tr key={p.id}>
                  <td><Link className="mono font-semibold text-copper" href={`/ke-hoach/${p.id}`}>{p.plan_no}</Link></td>
                  <td>{p.period_label}</td>
                  <td>{p.mode === 'OFFICIAL' ? 'Chính thức' : <Pill tone="info">Sơ bộ</Pill>}</td>
                  <td className="num">{p.line_count}</td><td className="num">{nf(p.total_m)}</td>
                  <td>{df(p.material_need_date)}</td>
                  <td>{p.last_run_id ? <Pill tone="ok">Đã chạy</Pill> : <Pill>Chưa chạy</Pill>}</td>
                  <td><StatusPill map={DOC_STATUS} value={p.status} /></td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : <Empty>Chưa có kế hoạch nào. Tạo kế hoạch kỳ đầu ở form phía trên.</Empty>}
      </div>
    </>
  );
}
