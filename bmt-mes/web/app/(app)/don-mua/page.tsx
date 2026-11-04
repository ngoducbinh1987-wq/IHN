import Link from 'next/link';
import { StageMini } from '@/components/stage-bar';
import { Empty, Flash, Pill, StatusPill, Tabs, Toolbar } from '@/components/ui';
import { type Approval, stageLabel, stagePos } from '@/lib/approvals';
import { df, nf } from '@/lib/format';
import { PO_STATUS, tongState, type Po } from '@/lib/purchase';

import { requirePage, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Đơn mua hàng' };

// Đơn mua tổng (NV mua chốt từng dòng, gom hợp đồng) và hợp đồng / phiếu mua theo NCC (migration 9500)
const TABS = [
  { key: 'don-tong', label: 'Đơn mua tổng đang xử lý', st: ['DRAFT'], kind: 'TONG' },
  { key: 'cho-nv-mua', label: 'Hợp đồng nháp', st: ['DRAFT'], kind: 'HD' },
  { key: 'dang-duyet', label: 'Hợp đồng đang duyệt', st: ['PENDING_APPROVAL'], kind: 'HD' },
  { key: 'cho-hang', label: 'Đã duyệt, chờ hàng', st: ['APPROVED', 'SENT', 'PARTIAL_RECEIVED'], kind: 'HD' },
  { key: 'tong-xong', label: 'Đơn tổng đã xong', st: ['CLOSED', 'CANCELLED'], kind: 'TONG' },
  { key: 'tat-ca', label: 'Tất cả hợp đồng', st: null, kind: 'HD' },
];

export default async function PoList({ searchParams }: { searchParams: Promise<{ tab?: string; q?: string; ok?: string; err?: string }> }) {
  const sp = await searchParams;
  await requirePage('don-mua');
  const me = await requirePerm('purchase', 'view');
  const tab = TABS.find((t) => t.key === sp.tab) ?? TABS[0];
  const supabase = await createClient();
  let query = supabase.schema('app').from('v_pos').select('*').order('created_at', { ascending: false }).limit(300);
  query = query.eq('kind', tab.kind);
  if (tab.st) query = query.in('status', tab.st);
  const q = (sp.q ?? '').replace(/[,()*%\\]/g, ' ').trim();
  if (q) query = query.or(`po_no.ilike.*${q}*,note.ilike.*${q}*,supplier_name.ilike.*${q}*,plan_no.ilike.*${q}*`);
  const [{ data, error }, { data: counts }] = await Promise.all([
    query.returns<Po[]>(),
    supabase.schema('app').from('v_pos').select('status, kind').in('status', ['DRAFT', 'PENDING_APPROVAL', 'APPROVED', 'SENT', 'PARTIAL_RECEIVED']),
  ]);
  const reqIds = (data ?? []).map((p) => p.request_id).filter(Boolean) as string[];
  const { data: reqs } = reqIds.length
    ? await supabase.schema('app').from('v_approvals').select('*').in('id', reqIds).returns<Approval[]>()
    : { data: [] as Approval[] };
  const byId = new Map((reqs ?? []).map((r) => [r.id, r]));
  const n = (t: (typeof TABS)[number]) => (t.st && t.key !== 'tong-xong' ? (counts ?? []).filter((c) => c.kind === t.kind && t.st!.includes(c.status)).length : undefined);
  const href = (t: string) => `/don-mua?tab=${t}${q ? `&q=${encodeURIComponent(q)}` : ''}`;

  return (
    <>
      <Toolbar title="Đơn mua hàng" reload={href(tab.key)} search={{ placeholder: 'Tìm số đơn, NCC, kế hoạch', value: sp.q }} hidden={{ tab: tab.key }} />
      <Tabs active={tab.key} items={TABS.map((t) => ({ key: t.key, label: t.label, href: href(t.key), count: n(t) }))} />
      <p className="mb-3 text-[13.5px] text-muted">
        Kế hoạch tháng được Chủ tịch HĐQT chốt, đề xuất mua được Giám đốc duyệt thì MES lập <b>đơn mua hàng tổng</b> giao Phòng mua hàng.
        <b> NV mua</b> chốt cho từng dòng: nhà cung cấp, đơn giá, điều khoản thanh toán, ngày giao; gom thành <b>hợp đồng</b> (mỗi NCC một hợp đồng) và gửi đủ trong
        <b> 5 ngày làm việc</b> → <b>TP Mua</b> duyệt (1 ngày làm việc) → <b>Giám đốc</b> duyệt (1 ngày làm việc) → MES báo NV mua, Kế toán. Kho nhận hàng theo hợp đồng đã duyệt.
      </p>
      <Flash ok={sp.ok} err={sp.err ?? error?.message} />
      <div className="card overflow-x-auto">
        {tab.kind === 'TONG' ? (data && data.length > 0 ? (
          <table className="tbl" id="ds-don-tong">
            <thead><tr><th>Đơn mua tổng</th><th>Nhận đơn</th><th>Hạn gửi đủ hợp đồng</th><th className="num">Dòng chưa gom</th><th className="num">Hợp đồng</th>
              {me.can_see_price && <th className="num">Giá trị dòng chưa gom (đ)</th>}<th>Trạng thái</th></tr></thead>
            <tbody>{data.map((p) => {
              const [lb, tone] = tongState(p);
              return (
                <tr key={p.id}>
                  <td className="min-w-[240px] py-3">
                    <Link href={`/don-mua/${p.id}`} className="text-[15px] font-medium text-brand hover:underline">{p.po_no}</Link>
                    <div className="mt-0.5 text-[13px] text-ink/80">{p.source_label}{p.plan_no && <> · {p.plan_no}</>}{p.adj_no && <> · {p.adj_no}</>}{p.pr_no && <> · {p.pr_no}</>}</div>
                  </td>
                  <td>{df(p.created_at, true)}</td>
                  <td className={p.overdue ? 'font-medium text-bad' : ''}>{df(p.due_date)}{p.overdue && ' · quá hạn'}</td>
                  <td className="num">{p.line_count}{p.line_count > 0 && <div className="text-[12px] text-muted">{p.lines_ready} đã chốt</div>}</td>
                  <td className="num">{p.contract_count}{p.contract_count > 0 && <div className="text-[12px] text-muted">{p.contract_approved} đã duyệt</div>}</td>
                  {me.can_see_price && <td className="num">{p.amount === null ? '—' : nf(p.amount)}</td>}
                  <td><Pill tone={tone}>{lb}</Pill></td>
                </tr>
              );
            })}</tbody>
          </table>
        ) : <Empty>Không có đơn mua tổng nào ở mục này.</Empty>) : data && data.length > 0 ? (
          <table className="tbl">
            <thead><tr><th>Đơn mua</th><th>Nhà cung cấp</th><th>Giai đoạn</th><th>Người thực hiện</th><th>Ngày giao</th><th className="num">Dòng</th>
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
                        {p.parent_no && <>Đơn tổng <Link className="link" href={`/don-mua/${p.parent_id}`}>{p.parent_no}</Link> · </>}{p.source_label}{p.plan_no && <> · <Link className="link" href={`/ke-hoach/${p.plan_id}`}>{p.plan_no}</Link></>}
                        {p.adj_no && <> · {p.adj_no}</>}{p.pr_no && <> · <Link className="link" href={`/de-xuat/${p.pr_id}`}>{p.pr_no}</Link></>}
                      </div>
                    </td>
                    <td className="min-w-[160px]">{p.supplier_name ?? <span className="text-warn">Chưa chọn NCC</span>}</td>
                    <td>{a && pos ? <StageMini stages={a.steps ?? []} index={pos.index} total={pos.total} label={stageLabel(a)} overdue={a.overdue} />
                      : <span className="text-muted">{p.status === 'DRAFT' ? 'NV mua gửi TP Mua' : '—'}</span>}</td>
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
