import Link from 'next/link';
import { Empty, Flash, PageHeader, StatusPill } from '@/components/ui';
import { DOC_STATUS, df } from '@/lib/format';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Hộp duyệt' };

const TABS = [
  { key: 'cho-toi', label: 'Chờ tôi duyệt' },
  { key: 'toi-gui', label: 'Tôi đã gửi' },
  { key: 'tat-ca', label: 'Tất cả' },
];

export default async function Inbox({ searchParams }: { searchParams: Promise<{ tab?: string; ok?: string; err?: string }> }) {
  const sp = await searchParams;
  const me = await requireMe();
  const tab = TABS.some((t) => t.key === sp.tab) ? sp.tab! : 'cho-toi';
  const supabase = await createClient();
  let q = supabase.schema('app').from('v_approvals')
    .select('id, doc_no, doc_type_name, summary, status, current_level, submitted_by_name, submitted_at, finished_at, my_turn')
    .order('submitted_at', { ascending: false }).limit(200);
  if (tab === 'cho-toi') q = q.eq('my_turn', true);
  if (tab === 'toi-gui') q = q.eq('submitted_by', me.id);
  const { data, error } = await q;
  return (
    <>
      <PageHeader title="Hộp duyệt" sub="Duyệt theo phân cấp chức danh. Người lập không tự duyệt; trả lại phải ghi lý do." />
      <Flash ok={sp.ok} err={sp.err ?? error?.message} />
      <div className="mb-3 flex gap-1.5">
        {TABS.map((t) => <Link key={t.key} href={`/duyet?tab=${t.key}`} className={`btn ${tab === t.key ? 'btn-pri' : ''}`}>{t.label}</Link>)}
      </div>
      <div className="card overflow-x-auto">
        {data && data.length > 0 ? (
          <table className="tbl">
            <thead><tr><th>Chứng từ</th><th>Loại</th><th>Nội dung</th><th>Bước hiện tại</th><th>Người lập</th><th>Gửi lúc</th><th>TT</th></tr></thead>
            <tbody>
              {data.map((a) => (
                <tr key={a.id} className={a.my_turn ? 'bg-copper-soft/40' : ''}>
                  <td><Link className="mono font-semibold text-copper" href={`/duyet/${a.id}`}>{a.doc_no}</Link></td>
                  <td className="whitespace-nowrap">{a.doc_type_name}</td>
                  <td className="min-w-[220px] text-muted">{a.summary}</td>
                  <td className="whitespace-nowrap">{a.status === 'PENDING' ? a.current_level : '—'}</td>
                  <td className="whitespace-nowrap">{a.submitted_by_name}</td>
                  <td className="whitespace-nowrap">{df(a.submitted_at, true)}</td>
                  <td><StatusPill map={DOC_STATUS} value={a.status} /></td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : <Empty>{tab === 'cho-toi' ? 'Không có chứng từ nào chờ bạn duyệt.' : 'Chưa có yêu cầu duyệt nào.'}</Empty>}
      </div>
    </>
  );
}
