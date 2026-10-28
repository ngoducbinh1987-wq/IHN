import Link from 'next/link';
import { StageMini } from '@/components/stage-bar';
import { Empty, Flash, Kpi, StatusPill, Toolbar } from '@/components/ui';
import { type Approval, stageLabel, stagePos } from '@/lib/approvals';
import { DOC_STATUS, df, nf } from '@/lib/format';
import { M_STATUS, WO_STATUS } from '@/lib/machine';
import { can, canPage, requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Tổng quan' };

type Dash = {
  products: number; specs_released: number; specs_rdc_over: number; materials_no_price: number;
  materials_no_leadtime: number; approvals_pending: number; plans_open: number;
};
// Thông tin chung mọi người cùng biết (app.shared_overview: chỉ số lượng, ngày, trạng thái – không có giá)
type Shared = {
  today: string;
  plan: { plan_id: string; plan_no: string; label: string; status: string; lines: number; total_m: number; done_m: number; late: number } | null;
  machines: { total: number; by_status: Record<string, number>; down: { code: string; name: string; status: string; since: string | null; eta: string | null; note: string | null }[] };
  maint: { kind: 'WO' | 'PLAN'; no: string | null; title: string; machine: string; date: string | null; status: string; confirmed: boolean }[];
};

export default async function Dashboard({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string }> }) {
  const sp = await searchParams;
  const me = await requireMe();
  const supabase = await createClient();
  const [{ data: dash }, { data: mine }, { data: sent }, { data: shared }] = await Promise.all([
    supabase.schema('app').from('v_dashboard').select('*').maybeSingle<Dash>(),
    supabase.schema('app').from('v_approvals').select('*').eq('my_turn', true).order('submitted_at').limit(10).returns<Approval[]>(),
    supabase.schema('app').from('v_approvals').select('*').eq('i_submitted', true).eq('status', 'PENDING').order('submitted_at', { ascending: false }).limit(5).returns<Approval[]>(),
    supabase.schema('app').rpc('shared_overview'),
  ]);
  const sh = shared as Shared | null;
  const pl = sh?.plan;
  const pct = pl && Number(pl.total_m) > 0 ? Math.round((Number(pl.done_m) / Number(pl.total_m)) * 100) : null;
  const ms = sh?.machines.by_status ?? {};
  const stopped = (ms.DOWN ?? 0) + (ms.MAINT ?? 0);
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
      {sh && (
        <section className="mb-4" id="thong-tin-chung" aria-label="Thông tin chung">
          <div className="mb-2 text-[12.5px] font-medium uppercase tracking-wide text-muted">Thông tin chung · {df(sh.today)}</div>
          <div className="grid gap-3 lg:grid-cols-3">
            <div className="card p-4">
              <div className="flex items-baseline justify-between gap-2"><h2 className="text-[15px] font-medium">Sản lượng tháng này</h2>
                <Link className="link text-[13px]" href="/kh-thuc-te">Kế hoạch sản xuất chung</Link></div>
              {pl ? (
                <>
                  <div className="mt-2 text-[26px] font-medium tabular-nums">{pct ?? 0}%</div>
                  <div className="text-[13px] text-muted">{nf(Number(pl.done_m))} / {nf(Number(pl.total_m))} m thành phẩm · {pl.plan_no} {pl.label} · {pl.lines} mã{pl.status === 'PENDING_APPROVAL' ? ' · đang chờ duyệt' : ''}</div>
                  <div className="mt-2 h-2.5 overflow-hidden rounded bg-todo"><i className="block h-full bg-brand" style={{ width: `${Math.min(100, pct ?? 0)}%` }} /></div>
                  {pl.late > 0 && <div className="mt-2 text-[13px] text-bad">{pl.late} mã quá hạn giao chưa xong</div>}
                </>
              ) : <div className="mt-2 text-[13px] text-muted">Chưa có kế hoạch tháng này.</div>}
            </div>
            <div className="card p-4">
              <div className="flex items-baseline justify-between gap-2"><h2 className="text-[15px] font-medium">Máy hôm nay</h2>
                <Link className="link text-[13px]" href="/may">Danh sách máy</Link></div>
              <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-[13.5px]">
                {Object.entries(M_STATUS).filter(([k]) => ms[k]).map(([k, [l]]) => (
                  <span key={k}><b className={`tabular-nums ${k === 'DOWN' ? 'text-bad' : ''}`}>{ms[k]}</b> {l.toLowerCase()}</span>
                ))}
                {!sh.machines.total && <span className="text-muted">Chưa khai báo máy.</span>}
              </div>
              {stopped > 0 ? (
                <ul className="mt-2 space-y-1 text-[13px]">
                  {sh.machines.down.slice(0, 4).map((m) => (
                    <li key={m.code}><b>{m.code}</b> {M_STATUS[m.status]?.[0].toLowerCase()}{m.eta ? ` · dự kiến chạy lại ${df(m.eta, true)}` : ''}{m.note ? ` · ${m.note}` : ''}</li>
                  ))}
                </ul>
              ) : sh.machines.total > 0 && <div className="mt-2 text-[13px] text-brand">Không có máy hỏng hay đang bảo dưỡng.</div>}
            </div>
            <div className="card p-4">
              <div className="flex items-baseline justify-between gap-2"><h2 className="text-[15px] font-medium">Bảo dưỡng 7 ngày tới</h2>
                <Link className="link text-[13px]" href="/may/bao-duong">Bảo dưỡng, sửa chữa</Link></div>
              {sh.maint.length ? (
                <ul className="mt-2 space-y-1 text-[13px]">
                  {sh.maint.slice(0, 5).map((x, i) => (
                    <li key={i}><b>{x.machine}</b> {x.title} · {x.date ? df(x.date) : 'chưa đặt ngày'}
                      {' · '}{x.kind === 'PLAN' ? (x.status === 'OVERDUE' ? <span className="text-bad">quá hạn, chưa lập phiếu</span> : 'đến hạn, chưa lập phiếu')
                        : <>{WO_STATUS[x.status]?.[0] ?? x.status}{x.confirmed ? ', đã chốt lịch' : ''}</>}</li>
                  ))}
                  {sh.maint.length > 5 && <li className="text-muted">… và {sh.maint.length - 5} việc khác</li>}
                </ul>
              ) : <div className="mt-2 text-[13px] text-muted">Không có việc bảo dưỡng nào trong 7 ngày tới.</div>}
            </div>
          </div>
        </section>
      )}
      <div className="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Kpi label="Việc chờ tôi duyệt" value={mine?.length ?? 0} hint={overdue ? `${overdue} việc quá hạn` : 'Không có việc quá hạn'} tone={overdue ? 'bad' : 'info'} href="/duyet" />
        <Kpi label="Tôi đã gửi, đang chờ" value={sent?.length ?? 0} hint={`${d.approvals_pending ?? 0} quy trình đang chạy toàn hệ thống`} href="/duyet?tab=toi-gui" />
        {canPage(me, 'san-pham') && <Kpi label="Spec đã phát hành" value={`${d.specs_released ?? 0}/${d.products ?? 0}`} hint={`${d.specs_rdc_over ?? 0} mã Rdc vượt tham chiếu`} tone={(d.specs_rdc_over ?? 0) > 0 ? 'warn' : undefined} href="/san-pham" />}
        {canPage(me, 'vat-tu') && <Kpi label="Vật tư thiếu giá / lead time" value={`${d.materials_no_price ?? 0} / ${d.materials_no_leadtime ?? 0}`} hint="MRP chưa tính đủ ngân sách" tone={(d.materials_no_price ?? 0) > 0 ? 'warn' : undefined} href="/vat-tu?thieu=1" />}
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
