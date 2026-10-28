import Link from 'next/link';
import type { ReactNode } from 'react';
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
// Số liệu giám sát theo phân quyền (app.dashboard): khối nào không có quyền thì database không trả
type Task = { key: string; label: string; n: number; late?: number; href: string };
type Overview = {
  today: string; month: string; month_elapsed: number;
  tasks: { items: Task[]; all_pending?: number; all_overdue?: number };
  output?: {
    today_m: number; today_passed_m: number; month_m: number; month_passed_m: number; month_target_m: number; forecast_m: number;
    days: { date: string; m: number; passed_m: number }[];
    stages_today: { op_code: string; op_name: string | null; bobbins: number; m: number; kg: number }[];
    plans: { plan_id: string; plan_no: string; period_label: string; total_m: number; done_m: number; lines: number }[];
  };
  lots?: {
    total: number; done: number; late: number; risk: number; ok: number; no_due: number; not_submitted: number; wait_approve: number;
    items: { id: string; plan_no: string; product_code: string; qty_m: number; done_m: number; due_date: string | null; committed_date: string | null; eta: string | null; state: 'LATE' | 'RISK'; approved: boolean }[];
  };
  safety?: { set: number; below: number; items: { code: string; name: string; uom: string; safety_stock: number; available: number; incoming: number; to_buy: number; pending_no: string | null; days_left: number | null }[] };
  qc?: { pending: number; late: number; oldest_min: number | null; quarantine: number; passed_7d: number; failed_7d: number; limit_min: number };
  loss?: {
    date: string; counts: { GREEN: number; YELLOW: number; RED: number; NA: number } | null; red_open_7d: number; scrap_month_kg: number;
    items: { wo_id: string; wo_no: string; product_code: string; stage: string; label: string; level: 'RED' | 'YELLOW'; var_pct: number | null; noted: boolean }[];
  };
  oee?: {
    from: string; to: string; reports: number; shift_min: number; down_min: number; planned_m: number; declared_m: number; missing: number;
    availability: number | null; attainment: number | null;
    machines: { code: string; name: string | null; reports: number; availability: number | null; attainment: number | null; down_min: number }[];
    reasons: { reason: string; name: string; planned: boolean; min: number }[];
  };
  stock?: {
    total: number; no_price: number; issued_month: number; by_kind: { MAT: number; WIP: number; FG: number };
    warehouses: { code: string; name: string; kind: string; value: number; items: number; no_price: number }[];
  };
  cost?: {
    month_material: number; month_fg_m: number; est_material_per_m: number | null;
    periods: { period: string; status: string; wos: number; good_m: number; std_total: number; act_total: number; per_m: number | null; std_per_m: number | null; var_pct: number | null }[];
  };
};

const pct = (v: number | null | undefined, d = 0) => (v === null || v === undefined ? '—' : `${nf(Number(v) * 100, d)}%`);
// Tiền: tỷ / triệu cho dễ đọc
const money = (v: number | null | undefined) => {
  const n = Number(v ?? 0);
  if (Math.abs(n) >= 1e9) return `${nf(n / 1e9, 2)} tỷ`;
  if (Math.abs(n) >= 1e6) return `${nf(n / 1e6, 1)} tr`;
  return `${nf(n)} đ`;
};
const KIND_LABEL: Record<string, string> = { MAT: 'Nguyên vật liệu', WIP: 'Bán thành phẩm', FG: 'Thành phẩm' };
const COST_STATUS: Record<string, string> = { OPEN: 'đang mở', CALCULATED: 'đã tính', PENDING_APPROVAL: 'chờ duyệt', CLOSED: 'đã chốt' };

export default async function Dashboard({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string }> }) {
  const sp = await searchParams;
  const me = await requireMe();
  const supabase = await createClient();
  const [{ data: dash }, { data: mine }, { data: sent }, { data: shared }, { data: ov, error: ovErr }] = await Promise.all([
    supabase.schema('app').from('v_dashboard').select('*').maybeSingle<Dash>(),
    supabase.schema('app').from('v_approvals').select('*').eq('my_turn', true).order('submitted_at').limit(10).returns<Approval[]>(),
    supabase.schema('app').from('v_approvals').select('*').eq('i_submitted', true).eq('status', 'PENDING').order('submitted_at', { ascending: false }).limit(5).returns<Approval[]>(),
    supabase.schema('app').rpc('shared_overview'),
    supabase.schema('app').rpc('dashboard'),
  ]);
  const sh = shared as Shared | null;
  const o = ov as Overview | null;
  const pl = sh?.plan;
  const planPct = pl && Number(pl.total_m) > 0 ? Math.round((Number(pl.done_m) / Number(pl.total_m)) * 100) : null;
  const ms = sh?.machines.by_status ?? {};
  const stopped = (ms.DOWN ?? 0) + (ms.STOP ?? 0) + (ms.MAINT ?? 0);
  const d = dash ?? ({} as Partial<Dash>);
  const tasks = o?.tasks.items ?? [];
  const taskN = tasks.reduce((s, t) => s + Number(t.n), 0);
  const taskLate = tasks.reduce((s, t) => s + Number(t.late ?? 0), 0);
  const out = o?.output, lots = o?.lots, oee = o?.oee, qc = o?.qc, loss = o?.loss, safety = o?.safety, stock = o?.stock, cost = o?.cost;
  const qRate = qc && qc.passed_7d + qc.failed_7d > 0 ? qc.passed_7d / (qc.passed_7d + qc.failed_7d) : null;
  const oeeVal = oee?.attainment != null ? Number(oee.attainment) * (qRate ?? 1) : null;
  const curCost = cost?.periods.find((p) => p.period === o?.month.slice(0, 7));

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
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err ?? ovErr?.message} /></div>

      {/* Dải số chính: chỉ các khối người xem có quyền */}
      <section id="so-chinh" aria-label="Số chính" className="mb-4 grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-5">
        <Kpi label="Việc của tôi" value={taskN} href={tasks[0]?.href ?? '/duyet'} tone={taskLate ? 'bad' : taskN ? 'warn' : 'ok'}
          hint={taskN ? (taskLate ? `${taskLate} việc quá hạn` : `${tasks.length} loại việc`) : 'Không có việc chờ'} />
        {out && <Kpi label="Thành phẩm hôm nay" value={`${nf(out.today_m)} m`} href="/bao-cao/ngay"
          hint={`${nf(out.today_passed_m)} m đạt QC · tháng ${nf(out.month_m)} m`} />}
        {lots && <Kpi label="Lô trễ / nguy cơ trễ" value={`${lots.late} / ${lots.risk}`} href="/lich-may?tab=thang"
          tone={lots.late ? 'bad' : lots.risk ? 'warn' : 'ok'} hint={`${lots.done}/${lots.total} lô xong · ${lots.wait_approve} lô chờ duyệt lịch`} />}
        {oee && <Kpi label="Hiệu suất máy 7 ngày" value={oee.reports ? pct(oeeVal) : '—'} href={canPage(me, 'ghi-nhan-ca') ? '/ghi-nhan-ca' : '#hieu-suat'}
          tone={!oee.reports ? 'info' : oeeVal != null && oeeVal < 0.65 ? 'warn' : 'ok'}
          hint={oee.reports ? `Sẵn sàng ${pct(oee.availability)} · đạt KH ${pct(oee.attainment)}` : 'Chưa có báo cáo ca có giờ dừng'} />}
        {loss && <Kpi label="Hao hụt đỏ hôm nay" value={loss.counts?.RED ?? 0} href="/bao-cao/ngay" tone={(loss.counts?.RED ?? 0) ? 'bad' : (loss.counts?.YELLOW ?? 0) ? 'warn' : 'ok'}
          hint={`${loss.counts?.YELLOW ?? 0} vàng · ${loss.red_open_7d} đỏ chưa giải trình (7 ngày)`} />}
        {qc && <Kpi label="Chờ QC" value={qc.pending} href="/kho/qc" tone={qc.late ? 'bad' : qc.pending ? 'warn' : 'ok'}
          hint={`${qc.late} quá ${qc.limit_min} phút · đạt 7 ngày ${pct(qRate)}`} />}
        {safety && <Kpi label="Dưới mức dự phòng" value={safety.below} href="/de-xuat/du-phong" tone={safety.below ? 'bad' : 'ok'}
          hint={`${safety.set} vật tư đã đặt mức`} />}
        {stock && <Kpi label="Giá trị tồn kho" value={money(stock.total)} href={canPage(me, 'kho-ton') ? '/kho/ton' : '#gia-tri-ton'}
          tone={stock.no_price ? 'warn' : undefined} hint={stock.no_price ? `${stock.no_price} mặt hàng chưa có giá` : `NVL xuất tháng ${money(stock.issued_month)}`} />}
        {cost && <Kpi label="Giá thành / m" value={curCost?.per_m != null ? `${nf(curCost.per_m)} đ` : cost.est_material_per_m != null ? `~${nf(cost.est_material_per_m)} đ` : '—'}
          href="#gia-thanh" tone={curCost?.var_pct != null && Number(curCost.var_pct) > 0 ? 'warn' : undefined}
          hint={curCost?.per_m != null ? `Kỳ ${curCost.period} · lệch định mức ${nf(curCost.var_pct, 1)}%` : 'Tạm tính NVL đã xuất ÷ mét thành phẩm'} />}
      </section>

      {tasks.length > 0 && (
        <section className="card mb-4" id="viec-cua-toi">
          <div className="card-h"><h2>Việc của tôi</h2>
            {o?.tasks.all_pending != null && <span className="text-[13px] text-muted">Toàn hệ thống: {o.tasks.all_pending} quy trình đang chờ{o.tasks.all_overdue ? <>, <b className="text-bad">{o.tasks.all_overdue} quá hạn</b></> : ''}</span>}</div>
          <ul className="divide-y divide-line">
            {tasks.map((t) => (
              <li key={t.key}><Link href={t.href} className="flex items-center justify-between gap-3 px-4 py-2.5 hover:bg-sunk/60">
                <span className="text-[14px]">{t.label}</span>
                <span className="flex items-center gap-2 text-[13px]">{t.late ? <span className="text-bad">{t.late} quá hạn</span> : null}<b className="tabular-nums text-[15px]">{t.n}</b></span>
              </Link></li>
            ))}
          </ul>
        </section>
      )}

      {sh && (
        <section className="mb-4" id="thong-tin-chung" aria-label="Thông tin chung">
          <div className="mb-2 text-[12.5px] font-medium uppercase tracking-wide text-muted">Thông tin chung · {df(sh.today)}</div>
          <div className="grid gap-3 lg:grid-cols-3">
            <div className="card p-4">
              <div className="flex items-baseline justify-between gap-2"><h2 className="text-[15px] font-medium">Sản lượng tháng này</h2>
                <Link className="link text-[13px]" href="/kh-thuc-te">Kế hoạch sản xuất chung</Link></div>
              {pl ? (
                <>
                  <div className="mt-2 text-[26px] font-medium tabular-nums">{planPct ?? 0}%</div>
                  <div className="text-[13px] text-muted">{nf(Number(pl.done_m))} / {nf(Number(pl.total_m))} m thành phẩm · {pl.plan_no} {pl.label} · {pl.lines} mã{pl.status === 'PENDING_APPROVAL' ? ' · đang chờ duyệt' : ''}</div>
                  <div className="mt-2 h-2.5 overflow-hidden rounded bg-todo"><i className="block h-full bg-brand" style={{ width: `${Math.min(100, planPct ?? 0)}%` }} /></div>
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
              ) : sh.machines.total > 0 && <div className="mt-2 text-[13px] text-brand">Không có máy dừng, hỏng hay đang bảo dưỡng.</div>}
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

      <div className="mb-4 grid gap-4 xl:grid-cols-2">
        {out && (
          <Card id="san-luong" title="Sản lượng thành phẩm" link={['/bao-cao/ngay', 'Báo cáo sản xuất ngày']}>
            <div className="flex flex-wrap gap-x-6 gap-y-1 text-[13.5px]">
              <span>Tháng này <b className="tabular-nums">{nf(out.month_m)} m</b> ({nf(out.month_passed_m)} m đạt QC)</span>
              {Number(out.month_target_m) > 0 && <span>Kế hoạch tháng <b className="tabular-nums">{nf(out.month_target_m)} m</b> · đạt {pct(out.month_m / out.month_target_m)}</span>}
              {Number(out.month_target_m) > 0 && <span className={out.forecast_m < out.month_target_m ? 'text-bad' : 'text-brand'}>
                Theo nhịp hiện tại cuối tháng ~{nf(out.forecast_m)} m{out.forecast_m < out.month_target_m ? ` (thiếu ${nf(out.month_target_m - out.forecast_m)} m)` : ''}</span>}
            </div>
            <Bars days={out.days} />
            {out.stages_today.length > 0 && (
              <div className="mt-3 text-[13px]"><span className="text-muted">Hôm nay theo công đoạn: </span>
                {out.stages_today.map((s) => <span key={s.op_code} className="mr-3"><b>{s.op_name ?? s.op_code}</b> {s.bobbins} bobin · {nf(s.m)} m</span>)}</div>
            )}
            {out.plans.length > 0 && (
              <table className="tbl mt-3">
                <thead><tr><th>Kế hoạch đang thực hiện</th><th className="num">Kế hoạch (m)</th><th className="num">Đã làm (m)</th><th>Tiến độ</th></tr></thead>
                <tbody>{out.plans.map((p) => {
                  const v = Number(p.total_m) > 0 ? Number(p.done_m) / Number(p.total_m) : 0;
                  return (
                    <tr key={p.plan_id}>
                      <td><Link className="link" href={`/ke-hoach/${p.plan_id}`}>{p.plan_no}</Link> {p.period_label} · {p.lines} mã</td>
                      <td className="num">{nf(p.total_m)}</td><td className="num">{nf(p.done_m)}</td>
                      <td className="min-w-[120px]"><div className="h-2 overflow-hidden rounded bg-todo"><i className="block h-full bg-brand" style={{ width: `${Math.min(100, v * 100)}%` }} /></div>
                        <div className="text-[12px] text-muted">{pct(v)}</div></td>
                    </tr>
                  );
                })}</tbody>
              </table>
            )}
          </Card>
        )}

        {lots && (
          <Card id="lo-ke-hoach" title="Lô kế hoạch tháng" link={['/lich-may?tab=thang', 'Lịch theo lô']}>
            <div className="flex flex-wrap gap-x-5 gap-y-1 text-[13.5px]">
              <span><b className="tabular-nums">{lots.total}</b> lô</span>
              <span className="text-brand"><b className="tabular-nums">{lots.done}</b> xong</span>
              <span><b className="tabular-nums">{lots.ok}</b> đúng tiến độ</span>
              <span className={lots.risk ? 'text-warn' : ''}><b className="tabular-nums">{lots.risk}</b> nguy cơ trễ</span>
              <span className={lots.late ? 'text-bad' : ''}><b className="tabular-nums">{lots.late}</b> trễ hạn</span>
            </div>
            <div className="mt-1 text-[12.5px] text-muted">{lots.not_submitted} lô TP SX chưa đệ trình ngày chốt · {lots.wait_approve} lô chờ Giám đốc duyệt lịch{lots.no_due ? ` · ${lots.no_due} lô chưa có hạn giao` : ''}</div>
            {lots.items.length > 0 ? (
              <table className="tbl mt-3">
                <thead><tr><th>Lô</th><th className="num">Đã làm / KH (m)</th><th>Hạn giao</th><th>Dự kiến xong</th><th>Tình trạng</th></tr></thead>
                <tbody>{lots.items.map((l) => (
                  <tr key={l.id}>
                    <td><b className="mono">{l.product_code}</b><div className="text-[12px] text-muted">{l.plan_no}</div></td>
                    <td className="num">{nf(l.done_m)} / {nf(l.qty_m)}</td>
                    <td>{df(l.due_date)}{l.committed_date && <div className="text-[12px] text-muted">chốt {df(l.committed_date)}</div>}</td>
                    <td>{l.eta ? df(l.eta) : <span className="text-muted">chưa có lịch</span>}</td>
                    <td>{l.state === 'LATE' ? <span className="text-bad">Trễ hạn</span> : <span className="text-warn">Nguy cơ trễ</span>}</td>
                  </tr>
                ))}</tbody>
              </table>
            ) : <p className="mt-3 text-[13px] text-brand">Không có lô trễ hay nguy cơ trễ.</p>}
          </Card>
        )}

        {oee && (
          <Card id="hieu-suat" title={`Hiệu suất máy 7 ngày (${df(oee.from)} – ${df(oee.to)})`} link={canPage(me, 'ghi-nhan-ca') ? ['/ghi-nhan-ca', 'Ghi nhận ca'] : undefined}>
            {oee.reports ? (
              <>
                <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
                  <Stat label="Sẵn sàng" value={pct(oee.availability)} hint="giờ ca trừ giờ dừng" />
                  <Stat label="Đạt kế hoạch" value={pct(oee.attainment)} hint="mét khai báo / mét kế hoạch" />
                  <Stat label="Chất lượng" value={pct(qRate)} hint="bobin QC đạt" />
                  <Stat label="Hiệu suất tổng" value={pct(oeeVal)} hint="≈ OEE" />
                </div>
                <table className="tbl mt-3">
                  <thead><tr><th>Máy</th><th className="num">Ca</th><th className="num">Dừng (phút)</th><th className="num">Sẵn sàng</th><th className="num">Đạt KH</th></tr></thead>
                  <tbody>{oee.machines.map((m) => (
                    <tr key={m.code}><td><b className="mono">{m.code}</b> {m.name}</td><td className="num">{m.reports}</td><td className="num">{nf(m.down_min)}</td>
                      <td className={`num ${m.availability != null && m.availability < 0.85 ? 'text-warn' : ''}`}>{pct(m.availability)}</td>
                      <td className={`num ${m.attainment != null && m.attainment < 0.85 ? 'text-warn' : ''}`}>{pct(m.attainment)}</td></tr>
                  ))}</tbody>
                </table>
                {oee.reasons.length > 0 && (
                  <div className="mt-3 text-[13px]"><span className="text-muted">Dừng máy theo lý do: </span>
                    {oee.reasons.slice(0, 5).map((x) => <span key={x.reason} className="mr-3">{x.name} <b className="tabular-nums">{nf(x.min)}</b> phút{x.planned ? ' (trong định mức)' : ''}</span>)}</div>
                )}
              </>
            ) : <p className="text-[13px] text-muted">Chưa có báo cáo ca đã gửi trong 7 ngày. Hiệu suất máy tính từ báo cáo ca có ghi giờ dừng máy (Ghi nhận ca).</p>}
            {oee.missing > 0 && <p className="mt-2 text-[13px] text-warn">{oee.missing} ngày-máy có phiếu hoàn thành nhưng chưa có báo cáo ca: hiệu suất chưa đủ.</p>}
          </Card>
        )}

        {loss && (
          <Card id="hao-hut" title={`Hao hụt nguyên liệu (đến hết ${df(loss.date)})`} link={['/bao-cao/ngay', 'Báo cáo ngày, giải trình']}>
            <div className="flex flex-wrap gap-x-5 gap-y-1 text-[13.5px]">
              <span className="text-bad"><b className="tabular-nums">{loss.counts?.RED ?? 0}</b> đỏ</span>
              <span className="text-warn"><b className="tabular-nums">{loss.counts?.YELLOW ?? 0}</b> vàng</span>
              <span className="text-brand"><b className="tabular-nums">{loss.counts?.GREEN ?? 0}</b> xanh</span>
              <span className="text-muted">Phế trong tháng {nf(loss.scrap_month_kg, 1)} kg</span>
            </div>
            {loss.red_open_7d > 0 && <div className="mt-1 text-[13px] text-bad">{loss.red_open_7d} mục đỏ 7 ngày qua chưa giải trình</div>}
            {loss.items.length > 0 ? (
              <table className="tbl mt-3">
                <thead><tr><th>Lô · công đoạn</th><th className="num">Vượt định mức</th><th>Mức</th></tr></thead>
                <tbody>{loss.items.map((x) => (
                  <tr key={`${x.wo_id}-${x.stage}`}><td><b className="mono">{x.wo_no}</b> {x.product_code}<div className="text-[12px] text-muted">{x.label}</div></td>
                    <td className="num">{x.var_pct != null ? `${nf(x.var_pct, 2)}%` : '—'}</td>
                    <td>{x.level === 'RED' ? <span className="text-bad">Đỏ{x.noted ? ', đã giải trình' : ''}</span> : <span className="text-warn">Vàng</span>}</td></tr>
                ))}</tbody>
              </table>
            ) : <p className="mt-3 text-[13px] text-muted">Hôm nay chưa có mục vàng hay đỏ.</p>}
          </Card>
        )}

        {qc && (
          <Card id="qc" title="QC bobin, lô hàng" link={canPage(me, 'kho-qc') ? ['/kho/qc', 'Màn hình QC'] : undefined}>
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              <Stat label="Đang chờ QC" value={nf(qc.pending)} hint={qc.oldest_min != null ? `lâu nhất ${nf(qc.oldest_min)} phút` : 'không có'} />
              <Stat label="Quá hạn" value={nf(qc.late)} hint={`trên ${qc.limit_min} phút`} tone={qc.late ? 'bad' : undefined} />
              <Stat label="Cách ly" value={nf(qc.quarantine)} tone={qc.quarantine ? 'warn' : undefined} />
              <Stat label="Đạt 7 ngày" value={pct(qRate)} hint={`${qc.passed_7d} đạt · ${qc.failed_7d} không đạt`} />
            </div>
          </Card>
        )}

        {safety && (
          <Card id="du-phong" title="Tồn dự phòng" link={['/de-xuat/du-phong', 'Tồn dự phòng']}>
            <p className="text-[13.5px]"><b className={safety.below ? 'text-bad' : 'text-brand'}>{safety.below}</b> vật tư dưới mức · {safety.set} vật tư đã đặt mức dự phòng</p>
            {safety.items.length > 0 ? (
              <table className="tbl mt-3">
                <thead><tr><th>Vật tư</th><th className="num">Tồn / mức</th><th className="num">Còn đủ</th><th className="num">Còn phải mua</th></tr></thead>
                <tbody>{safety.items.map((x) => (
                  <tr key={x.code}><td><b className="mono">{x.code}</b> {x.name}</td>
                    <td className="num">{nf(x.available, 1)} / {nf(x.safety_stock, 1)} {x.uom}</td>
                    <td className="num">{x.days_left != null ? `${nf(x.days_left, 1)} ngày` : '—'}</td>
                    <td className="num">{nf(x.to_buy, 1)}{x.pending_no && <div className="text-[12px] text-muted">{x.pending_no}</div>}</td></tr>
                ))}</tbody>
              </table>
            ) : safety.set === 0 && <p className="mt-2 text-[13px] text-muted">Chưa đặt mức dự phòng: TP Mua lập phiếu ở Tồn dự phòng, Giám đốc duyệt.</p>}
          </Card>
        )}

        {stock && (
          <Card id="gia-tri-ton" title="Giá trị tồn kho" link={canPage(me, 'kho-so-cai') ? ['/kho/so-cai', 'Nhập – xuất – tồn'] : undefined}>
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              <Stat label="Tổng" value={money(stock.total)} />
              {(['MAT', 'WIP', 'FG'] as const).map((k) => <Stat key={k} label={KIND_LABEL[k]} value={money(stock.by_kind[k])} />)}
            </div>
            <p className="mt-2 text-[13px]">NVL đã xuất cho sản xuất tháng này: <b>{money(stock.issued_month)}</b></p>
            {stock.no_price > 0 && <p className="mt-1 text-[13px] text-warn">{stock.no_price} mặt hàng còn tồn nhưng chưa có giá (thành phẩm, bán thành phẩm có giá khi chốt giá thành).</p>}
            {stock.warehouses.length > 0 && (
              <table className="tbl mt-3">
                <thead><tr><th>Kho</th><th className="num">Mặt hàng</th><th className="num">Giá trị</th></tr></thead>
                <tbody>{stock.warehouses.map((w) => (
                  <tr key={w.code}><td><b>{w.code}</b> {w.name}</td><td className="num">{w.items}</td><td className="num">{money(w.value)}</td></tr>
                ))}</tbody>
              </table>
            )}
          </Card>
        )}

        {cost && (
          <Card id="gia-thanh" title="Giá thành sản xuất">
            <p className="text-[13.5px]">Tháng này: NVL đã xuất <b>{money(cost.month_material)}</b> · thành phẩm <b>{nf(cost.month_fg_m)} m</b>
              {cost.est_material_per_m != null && <> · NVL tạm tính <b>{nf(cost.est_material_per_m)} đ/m</b></>}</p>
            {cost.periods.length > 0 ? (
              <table className="tbl mt-3">
                <thead><tr><th>Kỳ</th><th className="num">Lệnh SX</th><th className="num">Thành phẩm (m)</th><th className="num">Thực tế (đ/m)</th><th className="num">Định mức (đ/m)</th><th className="num">Lệch</th></tr></thead>
                <tbody>{cost.periods.map((p) => (
                  <tr key={p.period}><td>{p.period}<div className="text-[12px] text-muted">{COST_STATUS[p.status] ?? p.status}</div></td>
                    <td className="num">{p.wos}</td><td className="num">{nf(p.good_m)}</td><td className="num">{nf(p.per_m)}</td><td className="num">{nf(p.std_per_m)}</td>
                    <td className={`num ${p.var_pct != null && Number(p.var_pct) > 0 ? 'text-bad' : ''}`}>{p.var_pct != null ? `${nf(p.var_pct, 1)}%` : '—'}</td></tr>
                ))}</tbody>
              </table>
            ) : <p className="mt-2 text-[13px] text-muted">Chưa tính giá thành kỳ nào: Kế toán giá thành mở kỳ, nhập chi phí nhân công, điện, khấu hao rồi tính giá thành từng lệnh SX.</p>}
          </Card>
        )}
      </div>

      <section className="card mb-4 overflow-x-auto">
        <div className="card-h"><h2>Chờ tôi duyệt</h2><Link className="link text-[14px]" href="/duyet">Xem tất cả</Link></div>
        {mine && mine.length > 0 ? <Rows rows={mine} /> : <Empty>Không có quy trình nào chờ bạn duyệt.</Empty>}
      </section>
      {sent && sent.length > 0 && (
        <section className="card mb-4 overflow-x-auto">
          <div className="card-h"><h2>Tôi đã gửi, đang chờ duyệt</h2><Link className="link text-[14px]" href="/duyet?tab=toi-gui">Xem tất cả</Link></div>
          <Rows rows={sent} />
        </section>
      )}
      {(canPage(me, 'san-pham') || canPage(me, 'vat-tu')) && (
        <p className="text-[13px] text-muted">
          Dữ liệu nền:{canPage(me, 'san-pham') && <> <Link className="link" href="/san-pham">{d.specs_released ?? 0}/{d.products ?? 0} spec đã phát hành</Link>{(d.specs_rdc_over ?? 0) > 0 ? ` (${d.specs_rdc_over} mã Rdc vượt tham chiếu)` : ''}</>}
          {canPage(me, 'vat-tu') && <> · <Link className="link" href="/vat-tu?thieu=1">{d.materials_no_price ?? 0} vật tư thiếu giá, {d.materials_no_leadtime ?? 0} thiếu lead time</Link></>}
        </p>
      )}
    </>
  );
}

function Card({ id, title, link, children }: { id: string; title: string; link?: [string, string]; children: ReactNode }) {
  return (
    <section id={id} className="card overflow-x-auto">
      <div className="card-h"><h2>{title}</h2>{link && <Link className="link text-[13px]" href={link[0]}>{link[1]}</Link>}</div>
      <div className="p-4">{children}</div>
    </section>
  );
}

function Stat({ label, value, hint, tone }: { label: string; value: ReactNode; hint?: string; tone?: 'bad' | 'warn' }) {
  return (
    <div className="rounded border border-line px-3 py-2">
      <div className="text-[12.5px] text-muted">{label}</div>
      <div className={`text-[20px] font-medium tabular-nums ${tone === 'bad' ? 'text-bad' : tone === 'warn' ? 'text-warn' : ''}`}>{value}</div>
      {hint && <div className="text-[12px] text-muted">{hint}</div>}
    </div>
  );
}

// Thành phẩm 14 ngày: cột chồng đạt QC (đậm) + chờ QC (nhạt), di chuột xem số; bảng ẩn cho trình đọc màn hình
function Bars({ days }: { days: { date: string; m: number; passed_m: number }[] }) {
  const max = Math.max(1, ...days.map((x) => Number(x.m)));
  const total = days.reduce((s, x) => s + Number(x.m), 0);
  const label = (x: string) => new Date(`${x}T00:00:00`).toLocaleDateString('vi-VN', { day: '2-digit', month: '2-digit' });
  return (
    <figure className="mt-3" aria-label="Thành phẩm 14 ngày">
      <div className="mb-1 flex items-center gap-4 text-[12px] text-muted">
        <span>14 ngày gần nhất (m)</span>
        <span className="flex items-center gap-1"><i className="inline-block h-2.5 w-2.5 rounded-sm bg-brand" />đạt QC</span>
        <span className="flex items-center gap-1"><i className="inline-block h-2.5 w-2.5 rounded-sm bg-brand-soft" />chờ QC</span>
      </div>
      {total > 0 ? (
        <div className="flex h-28 items-end gap-1 border-b border-line" aria-hidden="true">
          {days.map((x) => {
            const pass = Number(x.passed_m), wait = Number(x.m) - pass;
            return (
              <div key={x.date} className="group relative flex h-full flex-1 flex-col justify-end" title={`${label(x.date)}: ${nf(x.m)} m (${nf(pass)} m đạt QC)`}>
                {wait > 0 && <i className="block rounded-t bg-brand-soft" style={{ height: `${(wait / max) * 100}%` }} />}
                {pass > 0 && <i className={`block bg-brand ${wait > 0 ? 'mt-[2px]' : 'rounded-t'}`} style={{ height: `${(pass / max) * 100}%` }} />}
              </div>
            );
          })}
        </div>
      ) : <div className="flex h-28 items-center justify-center rounded border border-dashed border-line text-[13px] text-muted">Chưa có thành phẩm trong 14 ngày</div>}
      <div className="mt-1 flex justify-between text-[11.5px] text-muted"><span>{label(days[0]?.date ?? '')}</span><span>{label(days[days.length - 1]?.date ?? '')}</span></div>
      <table className="sr-only"><caption>Thành phẩm theo ngày</caption><thead><tr><th>Ngày</th><th>Mét</th><th>Đạt QC</th></tr></thead>
        <tbody>{days.map((x) => <tr key={x.date}><td>{x.date}</td><td>{x.m}</td><td>{x.passed_m}</td></tr>)}</tbody></table>
    </figure>
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
