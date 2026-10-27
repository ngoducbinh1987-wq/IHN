import Link from 'next/link';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Pill, Tabs, Toolbar } from '@/components/ui';
import { df } from '@/lib/format';
import { can, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { createAdj } from '../actions';

export const metadata = { title: 'Điều chỉnh kế hoạch tháng' };

type Adj = { id: string; adj_no: string; plan_id: string; plan_no: string; status: string; reason: string; applied_at: string | null;
  created_at: string; created_by_name: string | null; line_count: number; approval_id: string | null };
type Plan = { id: string; plan_no: string; period_label: string; status: string };

const STATUS: Record<string, [string, 'ok' | 'warn' | 'info' | 'mute']> = {
  DRAFT: ['Nháp', 'warn'], PENDING_APPROVAL: ['Chờ duyệt', 'info'], APPROVED: ['Đã duyệt, đã áp vào kế hoạch', 'ok'], CANCELLED: ['Đã hủy', 'mute'],
};
const TABS = [
  { key: 'dang-xu-ly', label: 'Đang thực hiện', st: ['DRAFT', 'PENDING_APPROVAL'] },
  { key: 'da-duyet', label: 'Đã duyệt', st: ['APPROVED'] },
  { key: 'tat-ca', label: 'Tất cả', st: null },
];

// Màn hình riêng: phiếu đề xuất thay đổi kế hoạch tháng (thêm/bớt mã, đổi sản lượng, đổi hạn giao, lô ngoài kế hoạch).
// TP SX / Kế hoạch SX lập → người duyệt theo Cài đặt quy trình (Giám đốc, Chủ tịch HĐQT; được sửa khi duyệt) → MES áp vào kế hoạch tháng.
export default async function AdjustmentList({ searchParams }: { searchParams: Promise<{ tab?: string; ok?: string; err?: string }> }) {
  const sp = await searchParams;
  const me = await requirePerm('plan', 'view');
  const tab = TABS.find((t) => t.key === sp.tab) ?? TABS[0];
  const supabase = await createClient();
  let q = supabase.schema('app').from('v_plan_adjustments').select('*').order('created_at', { ascending: false }).limit(300);
  if (tab.st) q = q.in('status', tab.st);
  const [{ data: adjs, error }, { data: plans }] = await Promise.all([
    q.returns<Adj[]>(),
    supabase.schema('app').from('v_plans').select('id, plan_no, period_label, status').eq('status', 'APPROVED').order('created_at', { ascending: false }).returns<Plan[]>(),
  ]);
  const canAdj = can(me, 'plan', 'create') || me.roles.includes('SX_TP');

  return (
    <>
      <Toolbar title="Điều chỉnh kế hoạch tháng" reload={`/ke-hoach/dieu-chinh?tab=${tab.key}`} />
      <Tabs active={tab.key} items={TABS.map((t) => ({ key: t.key, label: t.label, href: `/ke-hoach/dieu-chinh?tab=${t.key}` }))} />
      <Flash ok={sp.ok} err={sp.err ?? error?.message} />
      <p className="mb-3 text-[13.5px] text-muted">
        Kế hoạch tháng đã được Chủ tịch HĐQT chốt thì mọi thay đổi (thêm, bớt mã, đổi sản lượng, đổi hạn giao) lập phiếu ở đây, gửi duyệt lại theo quy trình (Chủ tịch HĐQT duyệt bước cuối).
        Người duyệt được sửa phiếu khi duyệt. Duyệt xong MES áp vào kế hoạch, TP SX chạy lại dự trù và xếp lại lịch máy. Lô phát sinh chen lịch trong tháng đi đơn phát sinh (Giám đốc duyệt) ở Lịch máy.
      </p>

      {canAdj && (
        <section className="card mb-4">
          <div className="card-h"><h2>Lập phiếu đề xuất thay đổi kế hoạch tháng</h2></div>
          {(plans ?? []).length > 0 ? (
            <form action={createAdj} className="grid gap-3 p-4 md:grid-cols-[1fr_2fr_auto] md:items-end">
              <input type="hidden" name="from" value="list" />
              <label className="lbl"><span className="req">Kế hoạch tháng đã duyệt</span>
                <select className="inp" name="plan_id" required>
                  {(plans ?? []).map((p) => <option key={p.id} value={p.id}>{p.plan_no} · {p.period_label}</option>)}
                </select>
              </label>
              <label className="lbl"><span className="req">Lý do điều chỉnh</span>
                <input className="inp" name="reason" required placeholder="VD: khách ABC đặt thêm 3.000 m, khách XYZ lùi hạn" />
              </label>
              <SubmitButton className="btn btn-pri">Lập phiếu</SubmitButton>
            </form>
          ) : <Empty>Chưa có kế hoạch tháng nào đã duyệt.</Empty>}
        </section>
      )}

      <div className="card overflow-x-auto">
        {(adjs ?? []).length > 0 ? (
          <table className="tbl">
            <thead><tr><th>Phiếu</th><th>Kế hoạch</th><th>Lý do</th><th className="num">Dòng</th><th>Người lập</th><th>Trạng thái</th><th /></tr></thead>
            <tbody>{(adjs ?? []).map((a) => (
              <tr key={a.id}>
                <td className="mono"><Link className="link font-medium" href={`/ke-hoach/dieu-chinh/${a.id}`}>{a.adj_no}</Link></td>
                <td><Link className="link" href={`/ke-hoach/${a.plan_id}#dieu-chinh`}>{a.plan_no}</Link></td>
                <td className="min-w-[240px]">{a.reason}</td>
                <td className="num">{a.line_count}</td>
                <td>{a.created_by_name}<div className="text-[12px] text-muted">{df(a.created_at, true)}</div></td>
                <td><Pill tone={STATUS[a.status]?.[1] ?? 'mute'}>{STATUS[a.status]?.[0] ?? a.status}</Pill>{a.applied_at && <div className="text-[12px] text-muted">áp {df(a.applied_at, true)}</div>}</td>
                <td>{a.approval_id && <Link className="btn btn-sm btn-soft" href={`/duyet/${a.approval_id}`}>Quy trình duyệt</Link>}</td>
              </tr>
            ))}</tbody>
          </table>
        ) : <Empty>Chưa có phiếu điều chỉnh nào ở mục này.</Empty>}
      </div>
    </>
  );
}
