import Link from 'next/link';
import { StageMini } from '@/components/stage-bar';
import { Empty, Flash, StatusPill, Tabs, Toolbar } from '@/components/ui';
import { type Approval, stageLabel, stagePos } from '@/lib/approvals';
import { df, nf } from '@/lib/format';
import { PO_STATUS, type Po } from '@/lib/purchase';
import { requirePage, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Đơn mua hàng' };

const TABS = [
  { key: 'cho-nv-mua', label: 'Chờ NV mua kiểm tra', st: ['DRAFT'] },
  { key: 'dang-duyet', label: 'Đang duyệt', st: ['PENDING_APPROVAL'] },
  { key: 'cho-hang', label: 'Đã duyệt, chờ hàng', st: ['APPROVED', 'SENT', 'PARTIAL_RECEIVED'] },
  { key: 'tat-ca', label: 'Tất cả', st: null },
];

export default async function PoList({ searchParams }: { searchParams: Promise<{ tab?: string; q?: string; ok?: string; err?: string }> }) {
  const sp = await searchParams;
  await requirePage('don-mua');
  const me = await requirePerm('purchase', 'view');
  const tab = TABS.find((t) => t.key === sp.tab) ?? TABS[0];
  const supabase = await createClient();
  let query = supabase.schema('app').from('v_pos').select('*').order('created_at', { ascending: false }).limit(300);
  if (tab.st) query = query.in('status', tab.st);
  const q = (sp.q ?? '').replace(/[,()*%\\]/g, ' ').trim();
  if (q) query = query.or(`po_no.ilike.*${q}*,note.ilike.*${q}*,supplier_name.ilike.*${q}*,plan_no.ilike.*${q}*`);
  const [{ data, error }, { data: counts }] = await Promise.all([
    query.returns<Po[]>(),
    supabase.schema('app').from('v_pos').select('status').in('status', ['DRAFT', 'PENDING_APPROVAL', 'APPROVED', 'SENT', 'PARTIAL_RECEIVED']),
  ]);
  const reqIds = (data ?? []).map((p) => p.request_id).filter(Boolean) as string[];
  const { data: reqs } = reqIds.length
    ? await supabase.schema('app').from('v_approvals').select('*').in('id', reqIds).returns<Approval[]>()
    : { data: [] as Approval[] };
  const byId = new Map((reqs ?? []).map((r) => [r.id, r]));
  const n = (st: string[] | null) => (st ? (counts ?? []).filter((c) => st.includes(c.status)).length : undefined);
  const href = (t: string) => `/don-mua?tab=${t}${q ? `&q=${encodeURIComponent(q)}` : ''}`;

  return (
    <>
      <Toolbar title="Đơn mua hàng" reload={href(tab.key)} search={{ placeholder: 'Tìm số đơn, NCC, kế hoạch', value: sp.q }} hidden={{ tab: tab.key }} />
      <Tabs active={tab.key} items={TABS.map((t) => ({ key: t.key, label: t.label, href: href(t.key), count: n(t.st) }))} />
      <p className="mb-3 text-[13.5px] text-muted">
        Chủ tịch HĐQT chốt kế hoạch tháng thì MES <b>tự sinh đơn mua</b> từ kết quả MRP (mỗi nhà cung cấp ưu tiên một đơn; vật tư chưa có NCC gom một đơn).
        <b> NV mua</b> kiểm tra nhà cung cấp, giá, ngày về rồi bấm <b>Duyệt, gửi TP Mua</b> → <b>TP Mua</b> duyệt (Kế toán nhận thông báo) → <b>Giám đốc</b> duyệt.
        Đề xuất mua bổ sung, tích trữ, tối ưu đã duyệt: NV mua bấm “Lập đơn mua hàng” ở trang đề xuất. Kho nhận hàng theo đơn đã duyệt.
      </p>
      <Flash ok={sp.ok} err={sp.err ?? error?.message} />
      <div className="card overflow-x-auto">
        {data && data.length > 0 ? (
          <table className="tbl">
            <thead><tr><th>Đơn mua</th><th>Nhà cung cấp</th><th>Giai đoạn</th><th>Người thực hiện</th><th>Ngày về</th><th className="num">Dòng</th>
              {me.can_see_price && <th className="num">Giá trị (đ)</th>}<th>Trạng thái</th></tr></thead>
            <tbody>
              {data.map((p) => {
                const a = p.request_id ? byId.get(p.request_id) : undefined;
                const pos = a && a.status === 'PENDING' ? stagePos(a) : null;
                return (
                  <tr key={p.id}>
                    <td className="min-w-[260px] py-3">
                      <Link href={`/don-mua/${p.id}`} className="text-[15px] font-medium text-brand hover:underline">{p.po_no}</Link>
                      <div className="mt-0.5 text-[13px] text-ink/80">
                        {p.source_label}{p.plan_no && <> · <Link className="link" href={`/ke-hoach/${p.plan_id}`}>{p.plan_no}</Link></>}
                        {p.adj_no && <> · {p.adj_no}</>}{p.pr_no && <> · <Link className="link" href={`/de-xuat/${p.pr_id}`}>{p.pr_no}</Link></>}
                      </div>
                    </td>
                    <td className="min-w-[160px]">{p.supplier_name ?? <span className="text-warn">Chưa chọn NCC</span>}</td>
                    <td>{a && pos ? <StageMini stages={a.steps ?? []} index={pos.index} total={pos.total} label={stageLabel(a)} overdue={a.overdue} />
                      : <span className="text-muted">{p.status === 'DRAFT' ? 'NV mua kiểm tra' : '—'}</span>}</td>
                    <td className="min-w-[150px]">
                      {a?.status === 'PENDING' ? <span className="font-medium uppercase">{a.current_approvers.map((x) => x.name).join(', ')}</span>
                        : p.status === 'DRAFT' ? <span className="text-muted">NV mua hàng</span> : '—'}
                    </td>
                    <td>{df(p.expected_date)}</td>
                    <td className="num">{p.line_count}</td>
                    {me.can_see_price && <td className="num">{p.amount === null ? '—' : nf(p.amount)}{p.missing_price > 0 && <div className="text-[12px] text-warn">{p.missing_price} dòng chưa giá</div>}</td>}
                    <td><StatusPill map={PO_STATUS} value={p.status} /></td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        ) : <Empty>Không có đơn mua nào ở mục này.</Empty>}
      </div>
    </>
  );
}
