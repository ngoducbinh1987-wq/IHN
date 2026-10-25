import Link from 'next/link';
import { Empty, Flash, Kpi, Toolbar } from '@/components/ui';
import { HistoryTable } from '@/components/machine-history';
import { M_STATUS, hhmm, vnToday } from '@/lib/machine';
import { df, nf } from '@/lib/format';
import { requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Lịch sử vận hành' };

const COLOR: Record<string, string> = { RUN: 'bg-brand', IDLE: 'bg-todo', STOP: 'bg-warn', MAINT: 'bg-info', DOWN: 'bg-bad', OFF: 'bg-ink/20' };
type Log = { status: string; started_at: string; ended_at: string | null; reason_name: string | null; note: string | null };
const toMin = (t: string) => { const [h, m] = t.split(':').map(Number); return h * 60 + m; };

export default async function HistoryPage({ searchParams }: { searchParams: Promise<{ may?: string; tu?: string; den?: string; err?: string }> }) {
  const sp = await searchParams;
  await requirePerm('machine', 'view');
  const supabase = await createClient();
  const [{ data: lines }, { data: shift }] = await Promise.all([
    supabase.schema('app').from('v_machines').select('id, code, name').is('line_id', null).order('code'),
    supabase.schema('app').from('v_machine_settings').select('value').eq('key', 'shift').maybeSingle(),
  ]);
  const lineId = sp.may ?? lines?.[0]?.id;
  const to = /^\d{4}-\d{2}-\d{2}$/.test(sp.den ?? '') ? sp.den! : vnToday();
  const from = /^\d{4}-\d{2}-\d{2}$/.test(sp.tu ?? '') ? sp.tu! : vnToday(-6);
  const fromTs = `${from}T00:00:00+07:00`, toTs = `${to}T23:59:59+07:00`;
  const sessions: [string, string][] = shift?.value?.sessions ?? [['08:00', '12:00'], ['13:00', '17:00']];
  const axisFrom = Math.max(0, Math.min(...sessions.map((s) => toMin(s[0]))) - 60);
  const axisTo = Math.min(24 * 60, Math.max(...sessions.map((s) => toMin(s[1]))) + 120);
  const span = axisTo - axisFrom;

  const [{ data: logs }, { data: events }, { data: fam }] = lineId ? await Promise.all([
    supabase.schema('app').from('v_machine_status_log').select('status, started_at, ended_at, reason_name, note').eq('machine_id', lineId)
      .lt('started_at', toTs).or(`ended_at.is.null,ended_at.gt.${fromTs}`).order('started_at'),
    supabase.schema('app').from('v_machine_history').select('*').eq('line_id', lineId).gte('at', fromTs).lte('at', toTs).order('at', { ascending: false }).limit(200),
    supabase.schema('app').from('v_machines').select('id, code').or(`id.eq.${lineId},line_id.eq.${lineId}`),
  ]) : [{ data: [] }, { data: [] }, { data: [] }];
  const codes = Object.fromEntries((fam ?? []).map((m) => [m.id, m.code]));

  // Chia nhật ký trạng thái theo từng ngày (giờ Việt Nam)
  const days: string[] = [];
  for (let d = new Date(`${from}T00:00:00Z`); d <= new Date(`${to}T00:00:00Z`); d = new Date(d.getTime() + 86_400_000)) days.push(d.toISOString().slice(0, 10));
  const now = Date.now();
  const totals: Record<string, number> = { RUN: 0, IDLE: 0, STOP: 0, MAINT: 0, DOWN: 0, OFF: 0 };
  let stops = 0;
  const rows = days.map((day) => {
    const d0 = new Date(`${day}T00:00:00+07:00`).getTime();
    const segs = ((logs ?? []) as Log[]).map((l) => {
      const a = Math.max(new Date(l.started_at).getTime(), d0), b = Math.min(l.ended_at ? new Date(l.ended_at).getTime() : now, d0 + 86_400_000);
      return b > a ? { ...l, a: (a - d0) / 60000, b: (b - d0) / 60000 } : null;
    }).filter(Boolean) as (Log & { a: number; b: number })[];
    segs.forEach((s) => { totals[s.status] = (totals[s.status] ?? 0) + (s.b - s.a); });
    const run = segs.filter((s) => s.status === 'RUN').reduce((t, s) => t + s.b - s.a, 0);
    return { day, segs, run };
  });
  ((logs ?? []) as Log[]).forEach((l) => { if ((l.status === 'STOP' || l.status === 'DOWN') && new Date(l.started_at).getTime() >= new Date(fromTs).getTime()) stops++; });
  const bdPct = totals.RUN > 0 ? (totals.DOWN / totals.RUN) * 100 : 0;
  const ticks = [] as number[];
  for (let t = Math.ceil(axisFrom / 60) * 60; t <= axisTo; t += 60) ticks.push(t);
  const wd = (day: string) => ['CN', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7'][new Date(`${day}T12:00:00Z`).getUTCDay()];
  const line = (lines ?? []).find((l) => l.id === lineId);

  return (
    <>
      <Toolbar title="Lịch sử vận hành" actions={line && <Link className="btn btn-soft" href={`/may/${line.id}`}>Hồ sơ {line.code}</Link>} />
      <div className="mt-4" />
      <Flash err={sp.err} />
      <form className="card mb-4 flex flex-wrap items-end gap-3 p-4">
        <label className="lbl">Dây chuyền<select name="may" className="inp w-auto" defaultValue={lineId}>{(lines ?? []).map((l) => <option key={l.id} value={l.id}>{l.code} · {l.name}</option>)}</select></label>
        <label className="lbl">Từ ngày<input type="date" name="tu" className="inp w-auto" defaultValue={from} /></label>
        <label className="lbl">Đến ngày<input type="date" name="den" className="inp w-auto" defaultValue={to} /></label>
        <button className="btn btn-pri" type="submit">Xem</button>
      </form>
      {!lineId ? <div className="card"><Empty>Chưa có dây chuyền.</Empty></div> : (
        <>
          <div className="mb-4 grid grid-cols-2 gap-3 md:grid-cols-5">
            <Kpi label="Giờ chạy" value={nf(totals.RUN / 60, 1)} hint={`${df(from)} – ${df(to)}`} />
            <Kpi label="Dừng" value={nf(totals.STOP / 60, 1)} hint={`${stops} lần dừng, hỏng`} tone={totals.STOP ? 'warn' : 'ok'} />
            <Kpi label="Bảo dưỡng" value={nf(totals.MAINT / 60, 1)} hint="giờ" tone="info" />
            <Kpi label="Hỏng" value={nf(totals.DOWN / 60, 1)} hint="giờ" tone={totals.DOWN ? 'bad' : 'ok'} />
            <Kpi label="Dừng do hỏng / giờ chạy" value={`${nf(bdPct, 1)}%`} hint="Mục tiêu ≤ 3%" tone={bdPct > 3 ? 'bad' : 'ok'} />
          </div>
          <section className="card mb-4">
            <div className="card-h flex-wrap">{line?.code} · {line?.name}
              <span className="flex flex-wrap gap-3 text-[12.5px] font-normal text-muted">
                {['RUN', 'STOP', 'MAINT', 'DOWN', 'IDLE'].map((s) => <span key={s} className="inline-flex items-center gap-1.5"><i className={`inline-block h-2.5 w-3.5 rounded-sm ${COLOR[s]}`} />{M_STATUS[s][0]}</span>)}
              </span>
            </div>
            <div className="overflow-x-auto">
              <div className="min-w-[720px]">
                <div className="grid grid-cols-[96px_minmax(0,1fr)_90px] border-b border-line">
                  <div /><div className="relative h-6">{ticks.map((t) => <span key={t} className="absolute top-1 -translate-x-1/2 text-[11px] tabular-nums text-muted" style={{ left: `${((t - axisFrom) / span) * 100}%` }}>{String(t / 60).padStart(2, '0')}:00</span>)}</div><div />
                </div>
                {rows.map((r) => (
                  <div key={r.day} className="grid grid-cols-[96px_minmax(0,1fr)_90px] items-center border-b border-line last:border-b-0">
                    <div className="px-3 py-2 text-[13px] font-medium">{wd(r.day)} {df(r.day).slice(0, 5)}</div>
                    <div className="relative my-2 h-6 rounded bg-sunk">
                      {sessions.map(([a, b], i) => <span key={i} className="absolute inset-y-0 bg-ink/[0.04]" style={{ left: `${((toMin(a) - axisFrom) / span) * 100}%`, width: `${((toMin(b) - toMin(a)) / span) * 100}%` }} />)}
                      {r.segs.filter((s) => s.b > axisFrom && s.a < axisTo).map((s, i) => {
                        const a = Math.max(s.a, axisFrom), b = Math.min(s.b, axisTo);
                        return <span key={i} className={`absolute inset-y-0 ${COLOR[s.status]}`} style={{ left: `${((a - axisFrom) / span) * 100}%`, width: `${Math.max(0.2, ((b - a) / span) * 100)}%` }}
                          title={`${M_STATUS[s.status][0]} ${hhmm(s.started_at)}–${s.ended_at ? hhmm(s.ended_at) : 'nay'}${s.reason_name ? ' · ' + s.reason_name : ''}${s.note ? ' · ' + s.note : ''}`} />;
                      })}
                    </div>
                    <div className="px-3 text-right text-[12.5px] tabular-nums text-muted"><b className="font-medium text-ink">{nf(r.run / 60, 1)} h</b> chạy</div>
                  </div>
                ))}
              </div>
            </div>
            <p className="px-4 py-2 text-[12.5px] text-muted">Nền đậm là giờ làm việc theo ca ({sessions.map(([a, b]) => `${a}–${b}`).join(', ')}). Rê chuột lên đoạn màu để xem chi tiết.</p>
          </section>
          <section className="card overflow-x-auto">
            <div className="card-h">Nhật ký sự kiện<span className="text-[13px] font-normal text-muted">{(events ?? []).length} sự kiện · gồm cả máy con</span></div>
            <HistoryTable rows={events ?? []} codes={codes} />
          </section>
        </>
      )}
    </>
  );
}
