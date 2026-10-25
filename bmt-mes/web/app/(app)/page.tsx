import Link from 'next/link';
import { StageMini } from '@/components/stage-bar';
import { Empty, Flash, Kpi, StatusPill, Toolbar } from '@/components/ui';
import { type Approval, stageLabel, stagePos } from '@/lib/approvals';
import { DOC_STATUS, df } from '@/lib/format';
import { can, requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Tổng quan' };

type Dash = {
  products: number; specs_released: number; specs_rdc_over: number; materials_no_price: number;
  materials_no_leadtime: number; approvals_pending: number; plans_open: number;
};

export default async function Dashboard({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string }> }) {
  const sp = await searchParams;
  const me = await requireMe();
  const supabase = await createClient();
  const [{ data: dash }, { data: mine }, { data: sent }] = await Promise.all([
    supabase.schema('app').from('v_dashboard').select('*').maybeSingle<Dash>(),
    supabase.schema('app').from('v_approvals').select('*').eq('my_turn', true).order('submitted_at').limit(10).returns<Approval[]>(),
    supabase.schema('app').from('v_approvals').select('*').eq('i_submitted', true).eq('status', 'PENDING').order('submitted_at', { ascending: false }).limit(5).returns<Approval[]>(),
  ]);
  const d = dash ?? ({} as Partial<Dash>);
  const overdue = (mine ?? []).filter((a) => a.overdue).length;

  const quick = [
    can(me, 'purchase', 'create') && { href: '/de-xuat/moi', label: '+ Đề xuất mua hàng' },
    can(me, 'spec', 'create') && { href: '/san-pham/moi', label: '+ Spec mới' },
    can(me, 'master', 'create') && { href: '/vat-tu/moi', label: '+ Vật tư' },
    can(me, 'plan', 'create') && { href: '/ke-hoach/moi', label: '+ Kế hoạch' },
  ].filter(Boolean) as { href: string; label: string }[];

  return (
    <>
      <Toolbar title={`Chào ${me.full_name}`} reload="/"
        actions={quick.map((q) => <Link key={q.href} href={q.href} className="btn btn-soft">{q.label}</Link>)} />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /></div>
      <div className="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Kpi label="Việc chờ tôi duyệt" value={mine?.length ?? 0} hint={overdue ? `${overdue} việc quá hạn` : 'Không có việc quá hạn'} tone={overdue ? 'bad' : 'info'} href="/duyet" />
        <Kpi label="Tôi đã gửi, đang chờ" value={sent?.length ?? 0} hint={`${d.approvals_pending ?? 0} quy trình đang chạy toàn hệ thống`} href="/duyet?tab=toi-gui" />
        <Kpi label="Spec đã phát hành" value={`${d.specs_released ?? 0}/${d.products ?? 0}`} hint={`${d.specs_rdc_over ?? 0} mã Rdc vượt tham chiếu`} tone={(d.specs_rdc_over ?? 0) > 0 ? 'warn' : undefined} href="/san-pham" />
        <Kpi label="Vật tư thiếu giá / lead time" value={`${d.materials_no_price ?? 0} / ${d.materials_no_leadtime ?? 0}`} hint="MRP chưa tính đủ ngân sách" tone={(d.materials_no_price ?? 0) > 0 ? 'warn' : undefined} href="/vat-tu?thieu=1" />
      </div>

      <section className="card mb-4 overflow-x-auto">
        <div className="card-h"><h2>Chờ tôi duyệt</h2><Link className="link text-[14px]" href="/duyet">Xem tất cả</Link></div>
        {mine && mine.length > 0 ? <Rows rows={mine} /> : <Empty>Không có quy trình nào chờ bạn duyệt.</Empty>}
      </section>
      {sent && sent.length > 0 && (
        <section className="card overflow-x-auto">
          <div className="card-h"><h2>Tôi đã gửi, đang chờ duyệt</h2><Link className="link text-[14px]" href="/duyet?tab=toi-gui">Xem tất cả</Link></div>
          <Rows rows={sent} />
        </section>
      )}
    </>
  );
}

function Rows({ rows }: { rows: Approval[] }) {
  return (
    <table className="tbl">
      <thead><tr><th>Thông tin quy trình</th><th>Giai đoạn</th><th>Người thực hiện</th><th>Trạng thái</th></tr></thead>
      <tbody>
        {rows.map((a) => {
          const pos = stagePos(a);
          return (
            <tr key={a.id}>
              <td className="min-w-[260px] py-3"><Link href={`/duyet/${a.id}`} className="font-medium text-brand hover:underline">{a.doc_no}{a.summary ? ` – ${a.summary}` : ''}</Link>
                <div className="text-[13px] text-ink/80"><b>{a.doc_type_name}</b> · {a.submitted_by_name} · {df(a.submitted_at, true)}</div></td>
              <td><StageMini stages={a.steps ?? []} index={pos.index} total={pos.total} label={stageLabel(a)} overdue={a.overdue} /></td>
              <td><div className="font-medium uppercase">{a.current_approvers.map((p) => p.name).join(', ')}</div>
                <div className="text-[12.5px] text-muted">Hạn GĐ: <b className={a.overdue ? 'text-bad' : ''}>{df(a.step_due_at, true)}</b></div></td>
              <td><StatusPill map={DOC_STATUS} value={a.status} /></td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}
