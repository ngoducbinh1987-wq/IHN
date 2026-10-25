import Link from 'next/link';
import { Star } from 'lucide-react';
import { StageMini } from '@/components/stage-bar';
import { Empty, Flash, StatusPill, Tabs, Toolbar } from '@/components/ui';
import { type Approval, stageLabel, stagePos } from '@/lib/approvals';
import { DOC_STATUS, df } from '@/lib/format';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Quy trình duyệt' };

const TABS = [
  { key: 'cho-toi', label: 'Chờ tôi duyệt' },
  { key: 'dang-xu-ly', label: 'Đang thực hiện' },
  { key: 'toi-gui', label: 'Tôi đã gửi' },
  { key: 'da-xu-ly', label: 'Đã thực hiện' },
  { key: 'tat-ca', label: 'Tất cả' },
];

const TYPES: [string, string][] = [['', 'Tất cả quy trình'], ['SPEC', 'Phát hành spec'], ['PLAN', 'Kế hoạch SX'], ['PR', 'Đề xuất mua hàng'],
  ['PO', 'Đơn mua hàng'], ['SO', 'Đơn bán hàng']];

export default async function ApprovalsPage({ searchParams }:
  { searchParams: Promise<{ tab?: string; q?: string; loai?: string; ok?: string; err?: string }> }) {
  const sp = await searchParams;
  await requireMe();
  const tab = TABS.some((t) => t.key === sp.tab) ? sp.tab! : 'cho-toi';
  const supabase = await createClient();
  let query = supabase.schema('app').from('v_approvals').select('*').order('submitted_at', { ascending: false }).limit(300);
  if (tab === 'cho-toi') query = query.eq('my_turn', true);
  if (tab === 'dang-xu-ly') query = query.eq('status', 'PENDING');
  if (tab === 'toi-gui') query = query.eq('i_submitted', true);
  if (tab === 'da-xu-ly') query = query.or('i_acted.eq.true,status.in.(APPROVED,REJECTED,CANCELLED)');
  if (sp.loai) query = sp.loai === 'SPEC' ? query.like('doc_type', 'SPEC%') : query.eq('doc_type', sp.loai);
  const q = (sp.q ?? '').replace(/[,()*%\\]/g, ' ').trim();
  if (q) query = query.or(`doc_no.ilike.*${q}*,summary.ilike.*${q}*`);
  const [{ data, error }, { count: mine }] = await Promise.all([
    query.returns<Approval[]>(),
    supabase.schema('app').from('v_approvals').select('id', { count: 'exact', head: true }).eq('my_turn', true),
  ]);
  const href = (t: string) => `/duyet?tab=${t}${sp.loai ? `&loai=${sp.loai}` : ''}${q ? `&q=${encodeURIComponent(q)}` : ''}`;

  return (
    <>
      <Toolbar title="Danh sách quy trình duyệt" reload={href(tab)}
        search={{ placeholder: 'Tìm số chứng từ, nội dung', value: sp.q }} hidden={{ tab, loai: sp.loai }}
        actions={
          <form className="flex">
            <input type="hidden" name="tab" value={tab} />
            <select name="loai" defaultValue={sp.loai ?? ''} className="inp w-auto" aria-label="Loại quy trình">
              {TYPES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
            </select>
            <button className="btn ml-1" type="submit">Lọc</button>
          </form>
        } />
      <Tabs active={tab} items={TABS.map((t) => ({ ...t, href: href(t.key), count: t.key === 'cho-toi' ? mine ?? 0 : undefined }))} />
      <Flash ok={sp.ok} err={sp.err ?? error?.message} />

      <div className="card overflow-x-auto">
        {data && data.length > 0 ? (
          <table className="tbl">
            <thead><tr><th className="hidden w-8 md:table-cell" /><th>Thông tin quy trình</th><th className="hidden md:table-cell">Giai đoạn</th><th className="hidden md:table-cell">Người thực hiện</th><th className="hidden lg:table-cell">Ngày gửi</th><th className="hidden md:table-cell">Trạng thái</th></tr></thead>
            <tbody>
              {data.map((a) => {
                const pos = stagePos(a);
                return (
                  <tr key={a.id} className={a.my_turn ? 'bg-brand-soft/40' : ''}>
                    <td className="hidden text-muted md:table-cell"><Star size={18} className={a.my_turn ? 'fill-warn text-warn' : ''} aria-hidden /></td>
                    <td className="py-3 md:min-w-[280px]">
                      <Link href={`/duyet/${a.id}`} className="text-[15px] font-medium text-brand hover:underline">{a.doc_no}{a.summary ? ` – ${a.summary}` : ''}</Link>
                      <div className="mt-0.5 text-[13px] text-ink/80"><b>{a.doc_type_name}</b> tạo bởi <b className="uppercase">{a.submitted_by_name}</b> vào lúc <b>{df(a.submitted_at, true)}</b></div>
                      {/* Điện thoại: gộp giai đoạn + người thực hiện vào một ô */}
                      <div className="mt-2 flex flex-col gap-1 md:hidden">
                        <StageMini stages={a.steps ?? []} index={pos.index} total={pos.total} label={stageLabel(a)} overdue={a.overdue} />
                        {a.status === 'PENDING' && <div className="text-[13px]">Người thực hiện: <b className="uppercase">{a.current_approvers.map((p) => p.name).join(', ')}</b> · Hạn {df(a.step_due_at, true)}</div>}
                        <div><StatusPill map={DOC_STATUS} value={a.status} /></div>
                      </div>
                    </td>
                    <td className="hidden md:table-cell"><StageMini stages={a.steps ?? []} index={pos.index} total={pos.total} label={stageLabel(a)} overdue={a.overdue} /></td>
                    <td className="hidden min-w-[180px] md:table-cell">
                      {a.status === 'PENDING' ? (
                        <>
                          <div className="text-[14px] font-medium uppercase">{a.current_approvers.map((p) => p.name).join(', ') || <span className="normal-case text-bad">Chưa có người giữ vai trò {a.current_role_name}</span>}</div>
                          <div className="text-[12.5px] text-muted">Hạn GĐ: <b className={a.overdue ? 'text-bad' : 'text-ink'}>{df(a.step_due_at, true)}</b></div>
                        </>
                      ) : <span className="text-muted">—</span>}
                    </td>
                    <td className="hidden whitespace-nowrap lg:table-cell">{df(a.submitted_at, true)}</td>
                    <td className="hidden md:table-cell"><StatusPill map={DOC_STATUS} value={a.status} /></td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        ) : <Empty>{tab === 'cho-toi' ? 'Không có quy trình nào chờ bạn duyệt.' : 'Không có quy trình nào.'}</Empty>}
      </div>
      <p className="mt-2 text-right text-[13px] text-muted">Hiển thị {data?.length ?? 0} bản ghi</p>
    </>
  );
}
