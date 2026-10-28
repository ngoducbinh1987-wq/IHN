import Link from 'next/link';
import { StageMini } from '@/components/stage-bar';
import { Empty, Flash, StatusPill, Tabs, Toolbar } from '@/components/ui';
import { type Approval, stageLabel, stagePos } from '@/lib/approvals';
import { DOC_STATUS, df } from '@/lib/format';
import { can, requirePage, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Đề xuất mua hàng' };

type Pr = { id: string; pr_no: string; source: string; status: string; need_date: string | null; note: string | null;
  created_at: string; created_by_name: string | null; line_count: number; request_id: string | null; pr_kind_label: string | null };

const TABS = [
  { key: 'dang-xu-ly', label: 'Đang thực hiện', st: ['DRAFT', 'PENDING_APPROVAL'] },
  { key: 'da-duyet', label: 'Đã duyệt', st: ['APPROVED', 'PARTIAL_PO', 'CLOSED'] },
  { key: 'tat-ca', label: 'Tất cả', st: null },
];

export default async function PrList({ searchParams }: { searchParams: Promise<{ tab?: string; q?: string; ok?: string; err?: string }> }) {
  const sp = await searchParams;
  await requirePage('de-xuat');
  const me = await requirePerm('purchase', 'view');
  const tab = TABS.find((t) => t.key === sp.tab) ?? TABS[0];
  const supabase = await createClient();
  let query = supabase.schema('app').from('v_prs').select('*').order('created_at', { ascending: false }).limit(300);
  if (tab.st) query = query.in('status', tab.st);
  const q = (sp.q ?? '').replace(/[,()*%\\]/g, ' ').trim();
  if (q) query = query.or(`pr_no.ilike.*${q}*,note.ilike.*${q}*`);
  const { data, error } = await query.returns<Pr[]>();
  const reqIds = (data ?? []).map((p) => p.request_id).filter(Boolean) as string[];
  const { data: reqs } = reqIds.length
    ? await supabase.schema('app').from('v_approvals').select('*').in('id', reqIds).returns<Approval[]>()
    : { data: [] as Approval[] };
  const byId = new Map((reqs ?? []).map((r) => [r.id, r]));
  const href = (t: string) => `/de-xuat?tab=${t}${q ? `&q=${encodeURIComponent(q)}` : ''}`;
  const { data: below } = await supabase.schema('app').rpc('safety_below_count');

  return (
    <>
      <Toolbar title="Đề xuất mua hàng" reload={href(tab.key)} search={{ placeholder: 'Tìm số đề xuất, nội dung', value: sp.q }} hidden={{ tab: tab.key }}
        add={can(me, 'purchase', 'create') ? { href: '/de-xuat/moi', label: 'Thêm đề xuất' } : undefined} />
      <Tabs active={tab.key} items={TABS.map((t) => ({ key: t.key, label: t.label, href: href(t.key) }))} />
      <p className="mb-3 text-[13.5px] text-muted">
        Loại đề xuất: <b>theo kế hoạch tháng</b> (sinh từ MRP), <b>mua bổ sung</b>, <b>mua tích trữ</b>, <b>mua tối ưu</b> (NV mua / TP Mua lập, số lượng bất kỳ). Quy trình: TP Mua duyệt → Giám đốc duyệt.{' '}
        <Link href="/de-xuat/du-phong" className="font-medium text-brand hover:underline">Tồn dự phòng{Number(below ?? 0) > 0 ? ` – ${below} vật tư dưới mức` : ''}</Link>
      </p>
      <Flash ok={sp.ok} err={sp.err ?? error?.message} />
      <div className="card overflow-x-auto">
        {data && data.length > 0 ? (
          <table className="tbl">
            <thead><tr><th>Thông tin đề xuất</th><th>Giai đoạn</th><th>Người thực hiện</th><th>Ngày cần hàng</th><th className="num">Số dòng</th><th>Trạng thái</th></tr></thead>
            <tbody>
              {data.map((p) => {
                const a = p.request_id ? byId.get(p.request_id) : undefined;
                const pos = a ? stagePos(a) : null;
                return (
                  <tr key={p.id}>
                    <td className="min-w-[280px] py-3">
                      <Link href={`/de-xuat/${p.id}`} className="text-[15px] font-medium text-brand hover:underline">{p.pr_no} – {p.note}</Link>
                      <div className="mt-0.5 text-[13px] text-ink/80"><b>{p.pr_kind_label ?? (p.source === 'MRP' ? 'Đề xuất từ MRP' : 'Đề xuất mua hàng')}</b> tạo bởi <b className="uppercase">{p.created_by_name ?? '—'}</b> vào lúc <b>{df(p.created_at, true)}</b></div>
                    </td>
                    <td>{a && pos ? <StageMini stages={a.steps ?? []} index={pos.index} total={pos.total} label={stageLabel(a)} overdue={a.overdue} /> : <span className="text-muted">Chưa gửi duyệt</span>}</td>
                    <td className="min-w-[160px]">
                      {a?.status === 'PENDING' ? (
                        <><div className="font-medium uppercase">{a.current_approvers.map((x) => x.name).join(', ')}</div>
                          <div className="text-[12.5px] text-muted">Hạn GĐ: <b className={a.overdue ? 'text-bad' : 'text-ink'}>{df(a.step_due_at, true)}</b></div></>
                      ) : <span className="uppercase">{p.status === 'DRAFT' ? p.created_by_name : '—'}</span>}
                    </td>
                    <td>{df(p.need_date)}</td>
                    <td className="num">{p.line_count}</td>
                    <td><StatusPill map={DOC_STATUS} value={p.status} /></td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        ) : <Empty>Chưa có đề xuất nào. Bấm “+ Thêm đề xuất” để lập đề xuất mua hàng.</Empty>}
      </div>
    </>
  );
}
