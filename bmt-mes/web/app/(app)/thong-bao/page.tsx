import { Bell } from 'lucide-react';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Tabs, Toolbar } from '@/components/ui';
import { df } from '@/lib/format';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { markAllRead, openNotification } from './actions';

export const metadata = { title: 'Thông báo' };

type N = { id: number; title: string; body: string | null; link: string | null; read_at: string | null; created_at: string };

export default async function NotificationsPage({ searchParams }: { searchParams: Promise<{ tab?: string }> }) {
  const sp = await searchParams;
  await requireMe();
  const tab = sp.tab === 'tat-ca' ? 'tat-ca' : 'chua-doc';
  const supabase = await createClient();
  let q = supabase.schema('app').from('v_notifications').select('*').order('created_at', { ascending: false }).limit(200);
  if (tab === 'chua-doc') q = q.is('read_at', null);
  const [{ data }, { count }] = await Promise.all([
    q.returns<N[]>(),
    supabase.schema('app').from('v_notifications').select('id', { count: 'exact', head: true }).is('read_at', null),
  ]);
  return (
    <>
      <Toolbar title="Thông báo" reload={`/thong-bao?tab=${tab}`}
        actions={count ? <form action={markAllRead}><SubmitButton className="btn">Đánh dấu tất cả đã đọc</SubmitButton></form> : null} />
      <Tabs active={tab} items={[
        { key: 'chua-doc', label: 'Chưa đọc', href: '/thong-bao', count: count ?? 0 },
        { key: 'tat-ca', label: 'Tất cả', href: '/thong-bao?tab=tat-ca' },
      ]} />
      <div className="card divide-y divide-line">
        {(data ?? []).map((n) => (
          <form key={n.id} action={openNotification}>
            <input type="hidden" name="id" value={n.id} /><input type="hidden" name="link" value={n.link ?? ''} />
            <button type="submit" className={`flex w-full items-start gap-3 px-4 py-3 text-left hover:bg-sunk ${n.read_at ? '' : 'bg-brand-soft/50'}`}>
              <Bell size={18} className={`mt-0.5 shrink-0 ${n.read_at ? 'text-muted' : 'text-brand'}`} />
              <span className="min-w-0 flex-1">
                <span className={`block text-[15px] ${n.read_at ? '' : 'font-medium'}`}>{n.title}</span>
                {n.body && <span className="block text-[13.5px] text-muted">{n.body}</span>}
              </span>
              <span className="whitespace-nowrap text-[12.5px] text-muted">{df(n.created_at, true)}</span>
            </button>
          </form>
        ))}
        {(data ?? []).length === 0 && <Empty>{tab === 'chua-doc' ? 'Không có thông báo chưa đọc.' : 'Chưa có thông báo nào.'}</Empty>}
      </div>
    </>
  );
}
