import Link from 'next/link';
import { ChevronLeft, ChevronRight } from 'lucide-react';
import { Alert, Bar, FinishPill, GROUP_BG, GROUP_BORDER, GROUP_NAME, LockNote, SubTabs, Swatch, dd, pc, wd, wdl } from '@/components/kh';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Kpi, Pill, Toolbar } from '@/components/ui';
import { LEVEL, type ProductRow, type Step, readChange, simulate } from '@/lib/kh/change';
import { type Kh, ROLE, hasRole, loadKh } from '@/lib/kh/load';
import {
  BOBBIN, type Finish, OP_NAME, OP_SHORT, type Op, type Schedule, type Slot, UNIT, addDays, dayIndex, makeCalendar, opName,
  schedule, finishInfo, shiftDate, shiftCode, workdaysBetween,
} from '@/lib/kh/scheduler';
import { DOC_STATUS, df, nf } from '@/lib/format';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { applyChange, changeStep, createChange, rebuildSchedule, returnChange, setLine, setStart } from './actions';

export const metadata = { title: 'Lịch máy' };

type SP = Record<string, string | undefined>;
const TABS = [
  { key: 'thang', label: 'Kế hoạch tháng & công suất' }, { key: 'lich', label: 'Lịch máy' }, { key: 'tiendo', label: 'Tiến độ từng lệnh' },
  { key: 'cancu', label: 'Căn cứ xếp lịch' }, { key: 'phatsinh', label: 'Đơn phát sinh & thay đổi' },
];

export default async function LichMay({ searchParams }: { searchParams: Promise<SP> }) {
  const sp = await searchParams;
  const me = await requireMe();
  const db = await createClient();
  const kh = await loadKh(db, { plan: sp.plan, roles: me.roles });
  const tab = TABS.find((t) => t.key === sp.tab)?.key ?? 'lich';
  const canPlan = hasRole(me.roles, ROLE.plan) && kh.fromPlan;
  const qs = (extra: SP) => {
    const p = new URLSearchParams();
    const all = { plan: kh.planId ?? undefined, tab, ...extra };
    Object.entries(all).forEach(([k, v]) => { if (v !== undefined && v !== '') p.set(k, v); });
    return '/lich-may?' + p.toString();
  };

  // Chưa có lịch: tạo bản xem trước (không lưu) để Quản lý SX và Giám đốc xem trước khi bấm Xếp lịch
  let view: { sch: Schedule; fin: Map<string, Finish>; preview: boolean } | null = kh.sch ? { sch: kh.sch, fin: kh.fin, preview: false } : null;
  if (!view && kh.orders.length) {
    const sch = schedule(kh.orders, { cfg: kh.cfg, cal: kh.cal, machines: kh.machines, operators: kh.operators });
    view = { sch, fin: finishInfo(sch, kh.cal, kh.orders), preview: true };
  }
  const noDue = kh.orders.filter((o) => !o.due);
  const rebuildBtn = canPlan ? (
    <form action={rebuildSchedule} className="flex">
      <input type="hidden" name="plan_id" value={kh.planId ?? ''} /><input type="hidden" name="tab" value={tab} />
      <SubmitButton pendingText="Đang xếp…">{kh.version ? 'Xếp lại lịch' : 'Xếp lịch'}</SubmitButton>
    </form>
  ) : null;

  return (
    <>
      <Toolbar title={<span>Lịch máy{kh.planNo ? ` · ${kh.planNo}` : ''}</span>} reload={qs({})}
        actions={<>
          {kh.plans.length > 1 && (
            <form className="flex items-center gap-2" action="/lich-may">
              <input type="hidden" name="tab" value={tab} />
              <select name="plan" defaultValue={kh.planId ?? ''} className="inp w-auto py-1.5" aria-label="Chọn kế hoạch">
                {kh.plans.map((p) => <option key={p.id} value={p.id}>{p.plan_no} – {p.period_label}</option>)}
              </select>
              <button className="btn btn-sm">Xem</button>
            </form>
          )}
          {rebuildBtn ?? (kh.version || view ? <LockNote>Chỉ xem · Quản lý SX lập lịch</LockNote> : null)}
        </>} />
      <div className="mt-3 text-[13px] text-muted">
        {kh.version
          ? <>Phiên bản {kh.version.version} · {kh.version.reason} · {kh.version.created_by_name ?? ''} · {df(kh.version.created_at, true)} · {kh.cal.SPD} ca/ngày · mỗi ca xếp {kh.cal.S} phút ({kh.cal.RUN} × {kh.version.params.fill_pct}%)</>
          : kh.planNo ? <>Chưa lưu lịch máy cho {kh.planNo}</> : null}
      </div>
      <div className="mt-3"><Flash ok={sp.ok} err={sp.err} /></div>

      {!kh.planId && <div className="card"><Empty>Chưa có kế hoạch tháng nào. Tạo kế hoạch ở mục Kế hoạch &amp; MRP trước.</Empty></div>}
      {kh.planId && kh.planStatus && kh.planStatus !== 'APPROVED' && (
        <Alert tone="warn" title={`Kế hoạch ${kh.planNo} chưa được duyệt (${DOC_STATUS[kh.planStatus]?.[0] ?? kh.planStatus})`}>
          Lịch máy chỉ để xem trước và chuẩn bị. Chưa phát lệnh ngày được cho đến khi kế hoạch tháng được duyệt.
        </Alert>
      )}
      {kh.dirty && (
        <Alert tone="info" title="Tham số xếp lịch đã đổi sau lần xếp gần nhất" action={rebuildBtn}>
          Quản lý SX bấm “Xếp lại lịch” để tính lại. Phần đã chạy và vùng khóa {kh.cfg.frozen_days} ngày giữ nguyên.
        </Alert>
      )}
      {kh.missing.length > 0 && (
        <Alert tone="warn" title={`${kh.missing.length} dòng kế hoạch chưa có trong lịch máy`} action={rebuildBtn}>
          {kh.missing.map((o) => `${o.label} ${o.product_code}`).join(', ')}
        </Alert>
      )}
      {view?.preview && (
        <Alert tone="info" title="Bản xem trước, chưa lưu" action={rebuildBtn}>
          Hệ thống xếp thử từ kế hoạch tháng với tham số hiện tại. {canPlan ? 'Bấm “Xếp lịch” để lưu thành phiên bản 1.' : 'Quản lý SX bấm “Xếp lịch” để lưu.'}
        </Alert>
      )}
      {noDue.length > 0 && tab !== 'thang' && (
        <Alert tone="info" title={`${noDue.length} dòng chưa có hạn giao`}>
          Lịch xếp các dòng này sau cùng. Giám đốc đặt hạn giao ở thẻ <Link className="link" href={qs({ tab: 'thang' })}>Kế hoạch tháng &amp; công suất</Link>.
        </Alert>
      )}

      {kh.planId && (
        <>
          <SubTabs active={tab} items={TABS.map((t) => ({ ...t, href: qs({ tab: t.key }) }))} />
          {!view && tab !== 'cancu' && tab !== 'phatsinh' && <div className="card"><Empty>Kế hoạch chưa có dòng nào xếp được. Cần mã có spec đã phát hành, có đường đi công đoạn và số mét &gt; 0.</Empty></div>}
          {view && tab === 'thang' && <Month kh={kh} view={view} me={me.roles} />}
          {view && tab === 'lich' && <Gantt kh={kh} view={view} sp={sp} qs={qs} canPlan={canPlan} />}
          {view && tab === 'tiendo' && <Progress kh={kh} view={view} />}
          {tab === 'cancu' && <Basis kh={kh} view={view} />}
          {tab === 'phatsinh' && <Changes kh={kh} sp={sp} roles={me.roles} userId={me.id} />}
        </>
      )}
    </>
  );
}

const lc = (s: string) => s.charAt(0).toLowerCase() + s.slice(1);
type View = { sch: Schedule; fin: Map<string, Finish>; preview: boolean };
const fmtT = (kh: Kh, t: number) => {
  const s = Math.floor(t / kh.cal.S);
  if (Math.floor(s / kh.cal.SPD) >= kh.cal.days.length) return 'ngoài tầm lịch';
  const d = shiftDate(kh.cal, s);
  return `${wd(d)} ${dd(d)}${kh.cal.SPD > 1 ? ' · ca ' + shiftCode(kh.cal, s) : ''}`;
};

// ----------------------------------------------------------------- Kế hoạch tháng & công suất
function Month({ kh, view, me }: { kh: Kh; view: View; me: string[] }) {
  const { cal } = kh;
  const isBgd = hasRole(me, ROLE.params);
  // Cửa sổ tính tải: từ ngày gốc đến cuối tháng (còn dưới 10 ngày làm việc thì đến cuối tháng sau)
  const start = cal.days[Math.max(0, Math.min(kh.todayIdx, cal.days.length - 1))] ?? cal.base;
  const eom = (d: string) => { const x = new Date(d.slice(0, 7) + '-01T00:00:00Z'); x.setUTCMonth(x.getUTCMonth() + 1); x.setUTCDate(0); return x.toISOString().slice(0, 10); };
  let end = eom(start);
  if (workdaysBetween(start, addDays(end, 1), cal.wd) < 10) end = eom(addDays(end, 1));
  const d0 = Math.max(0, dayIndex(cal, start)), d1 = dayIndex(cal, addDays(end, 1));
  const nDays = Math.max(1, d1 - d0), t0 = d0 * cal.SPD * view.sch.S, t1 = d1 * cal.SPD * view.sch.S;
  const capMin = nDays * cal.SPD * view.sch.S;
  const clip = (s: Slot, a: number, b: number) => Math.max(0, Math.min(b, s.end) - Math.max(a, s.start));
  const mach = kh.machines.map((m) => {
    const sl = view.sch.byMachine.get(m.code) ?? [];
    const used = sl.reduce((a, s) => a + clip(s, t0, t1), 0);
    const su = sl.reduce((a, s) => a + Math.max(0, Math.min(t1, s.runStart) - Math.max(t0, s.start)), 0);
    return { m, used, su, load: used / capMin };
  });
  const wk = kh.operators.filter((w) => w.skills.length).map((w) => {
    const used = view.sch.slots.filter((s) => s.operator === w.code).reduce((a, s) => a + clip(s, t0, t1), 0);
    return { w, used, cap: capMin * kh.cfg.machines_per_operator, load: used / (capMin * kh.cfg.machines_per_operator) };
  });
  const top = wk.reduce((a, b) => (b.load > (a?.load ?? -1) ? b : a), wk[0]);
  const late = kh.orders.filter((o) => { const f = view.fin.get(o.id); return f && (!f.placed || (f.slack ?? 0) < 0); });
  const near = kh.orders.filter((o) => { const f = view.fin.get(o.id); return f?.placed && f.slack !== null && f.slack >= 0 && f.slack <= 1; });
  const total = kh.orders.reduce((a, o) => a + o.qty, 0);
  return (
    <div className="flex flex-col gap-4">
      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <Kpi label="Tổng sản lượng kế hoạch" value={`${nf(total / 1000, 1)} km`} hint={`${kh.orders.length} dòng · ${kh.planNo}`} />
        <Kpi label="Người tải cao nhất" value={top ? pc(top.load) : '—'} hint={top ? `${top.w.code} · ${top.w.job}` : ''} tone={top && top.load >= 1 ? 'bad' : top && top.load >= 0.85 ? 'warn' : 'ok'} />
        <Kpi label="Lệnh dự kiến trễ" value={late.length} hint={late.map((o) => o.label).join(', ') || 'Không có'} tone={late.length ? 'bad' : 'ok'} />
        <Kpi label="Lệnh sát hạn (≤ 1 ngày)" value={near.length} hint={near.map((o) => o.label).join(', ') || 'Không có'} tone={near.length ? 'warn' : 'ok'} />
      </div>
      <div className="grid gap-4 xl:grid-cols-2 [&>*]:min-w-0">
        <section className="card">
          <div className="card-h"><h2>Tải theo người</h2><span className="text-[13px] font-normal text-muted">giới hạn thật của xưởng</span></div>
          <div className="overflow-x-auto"><table className="tbl">
            <thead><tr><th>Người</th><th>Đứng máy</th><th className="num">Phút cần</th><th className="num">Phút có</th><th className="min-w-[150px]">Tải</th></tr></thead>
            <tbody>{wk.map((x) => (
              <tr key={x.w.code}><td><b>{x.w.code}</b>{x.w.is_deputy && <div className="text-[12px] text-muted">Tổ phó</div>}</td><td className="text-[12.5px]">{x.w.skills.join(', ')}</td>
                <td className="num">{nf(x.used)}</td><td className="num">{nf(x.cap)}</td><td><Bar value={x.load} /></td></tr>
            ))}</tbody>
          </table></div>
          <p className="px-4 py-3 text-[12.5px] text-muted">Từ {dd(start)} đến {dd(end)}: {nDays} ngày × {cal.SPD} ca × {view.sch.S} phút × {kh.cfg.machines_per_operator} máy/người. {kh.operators.filter((w) => !w.skills.length).map((w) => w.code).join(', ')} vận chuyển bobin, đóng gói: tính 1 ca sau công đoạn cuối.</p>
        </section>
        <section className="card">
          <div className="card-h"><h2>Tải theo máy</h2><span className="text-[13px] font-normal text-muted">phút xếp lịch = ca × {view.sch.RUN} × {kh.cfg.fill_pct}%</span></div>
          <div className="overflow-x-auto"><table className="tbl">
            <thead><tr><th>Máy</th><th>Người</th><th className="num">Phút cần</th><th className="num">Phút có</th><th className="min-w-[150px]">Tải</th></tr></thead>
            <tbody>{mach.map((x) => (
              <tr key={x.m.code}><td><b>{x.m.code}</b><div className="text-[12px] text-muted">{x.m.name}</div></td><td className="text-[12.5px]">{x.m.operators.join(', ') || <span className="text-bad">Chưa có người</span>}</td>
                <td className="num">{nf(x.used)}<div className="text-[12px] text-muted">đổi máy {nf(x.su)}</div></td><td className="num">{nf(capMin)}</td><td><Bar value={x.load} /></td></tr>
            ))}</tbody>
          </table></div>
          <p className="px-4 py-3 text-[12.5px] text-muted">Máy còn trống nhiều thường do thiếu người đứng máy, không phải thiếu máy.</p>
        </section>
      </div>
      {late.length > 0 && (
        <Alert tone="bad" title={`${late.length} lệnh dự kiến trễ hạn giao`}>
          Phương án để Giám đốc chọn: bật ca B vài ngày, thêm người cho {top?.w.code ?? 'vị trí tải cao'}, mua bán thành phẩm, hoặc chốt lại ngày giao với kinh doanh.
        </Alert>
      )}
      <section className="card">
        <div className="card-h"><h2>Dòng kế hoạch: hạn giao, ưu tiên, dự kiến xong</h2>
          {isBgd ? <span className="text-[13px] font-normal text-muted">Giám đốc đặt hạn giao và mức ưu tiên</span> : <LockNote>Giám đốc đặt hạn giao</LockNote>}</div>
        <div className="overflow-x-auto"><table className="tbl">
          <thead><tr><th>Dòng</th><th>Sản phẩm</th><th>Công đoạn</th><th className="num">Số mét</th><th>Nguồn</th><th>Hạn giao · ưu tiên</th><th className="num">Dự kiến xong</th><th>Tình trạng</th></tr></thead>
          <tbody>{kh.orders.map((o) => {
            const f = view.fin.get(o.id);
            return (
              <tr key={o.id}>
                <td className="mono">{o.label}{o.prio === 0 && <> <Pill tone="bad">Gấp</Pill></>}</td>
                <td><b>{o.product_code}</b><div className="text-[12px] text-muted">{o.product_name}</div></td>
                <td className="text-[12.5px]">{o.route.map((op) => (op === 'CD3' && o.shield ? 'CD3+4' : op)).join(' › ')}</td>
                <td className="num">{nf(o.qty)}</td><td className="text-[12.5px]">{o.source}</td>
                <td>{isBgd && kh.fromPlan ? (
                  <form action={setLine} className="flex flex-wrap items-center gap-1.5">
                    <input type="hidden" name="plan_id" value={kh.planId ?? ''} /><input type="hidden" name="line_id" value={o.id} /><input type="hidden" name="label" value={o.label} />
                    <input type="date" name="due" defaultValue={o.due ?? ''} className="inp w-[150px] py-1" aria-label={`Hạn giao ${o.label}`} required />
                    <select name="prio" defaultValue={String(o.prio)} className="inp w-auto py-1" aria-label={`Ưu tiên ${o.label}`}><option value="1">Thường</option><option value="0">Gấp</option></select>
                    <SubmitButton className="btn btn-sm" pendingText="…">Lưu</SubmitButton>
                  </form>
                ) : <>{o.due ? dd(o.due) : <span className="text-muted">Chưa có</span>}{o.prio === 0 ? ' · Gấp' : ''}</>}</td>
                <td className="num">{f?.finDate ? dd(f.finDate) : '—'}</td>
                <td>{f ? <FinishPill {...f} due={o.due} /> : '—'}</td>
              </tr>
            );
          })}</tbody>
        </table></div>
        <p className="px-4 py-3 text-[12.5px] text-muted">Dự kiến xong = công đoạn cuối xong + 1 ca kiểm tra, đóng gói. CD3+4: xoắn và quấn AL/PET chạy liền dây trên máy xoắn. Đổi hạn giao xong bấm “Xếp lại lịch”.</p>
      </section>
      {isBgd && !kh.version && kh.fromPlan && (
        <section className="card">
          <div className="card-h"><h2>Ngày bắt đầu chạy kế hoạch</h2></div>
          <form action={setStart} className="flex flex-wrap items-end gap-3 px-4 py-3">
            <input type="hidden" name="plan_id" value={kh.planId ?? ''} />
            <label className="lbl">Ngày bắt đầu (không chọn Chủ nhật)<input type="date" name="start" defaultValue={kh.schedStart ?? kh.cal.base} className="inp w-[170px]" required /></label>
            <SubmitButton className="btn">Lưu ngày bắt đầu</SubmitButton>
            <span className="text-[12.5px] text-muted">Đặt trước khi Quản lý SX xếp lịch lần đầu. Đã có lịch thì không đổi được.</span>
          </form>
        </section>
      )}
    </div>
  );
}

// ----------------------------------------------------------------- Gantt tuần
function Gantt({ kh, view, sp, qs, canPlan }: { kh: Kh; view: View; sp: SP; qs: (x: SP) => string; canPlan: boolean }) {
  const { cal } = kh;
  const S = view.sch.S, SPD = cal.SPD;
  const w = Number(sp.w ?? 0) || 0;
  // tuần: 6 ngày làm việc, bắt đầu từ thứ 2 của tuần hiện tại
  const today = kh.now.date;
  const dow = (new Date(today + 'T00:00:00Z').getUTCDay() + 6) % 7; // 0 = thứ 2
  const monIdx = dayIndex(cal, addDays(today, -dow));
  const startDay = Math.max(0, monIdx + w * 6);
  const days = cal.days.slice(startDay, startDay + 6);
  const N = days.length * SPD, W0 = startDay * SPD * S, W = N * S;
  const X = (t: number) => (Math.max(0, Math.min(W, t - W0)) / W) * 100;
  const sel = sp.sel ? view.sch.slots.find((s) => s.id === sp.sel) : null;
  const orderOf = new Map(kh.orders.map((o) => [o.id, o]));
  const pastPct = Math.max(0, Math.min(100, ((kh.todayIdx - startDay) / days.length) * 100));
  const fz0 = Math.max(0, Math.min(100, ((kh.frozenFrom - startDay) / days.length) * 100));
  const fz1 = Math.max(0, Math.min(100, ((kh.frozenTo - startDay) / days.length) * 100));
  const nowPct = X(kh.nowT);
  const showNow = kh.nowT >= W0 && kh.nowT <= W0 + W;
  const tag = (i: number) => { const di = startDay + i; return di < kh.todayIdx ? 'Đã chạy' : di === kh.todayIdx ? 'Hôm nay · khóa' : di < kh.frozenTo ? 'Vùng khóa' : 'Dự kiến'; };
  let setupWeek = 0;
  const idleNotes: string[] = [];
  const idleWhy = (sl: Slot | undefined) => {
    if (!sl) return 'Chưa có việc';
    if (sl.reason.startsWith('Chờ người')) return `Chờ người (${sl.operator} đứng máy khác)`;
    const o = orderOf.get(sl.lineId); const k = o ? o.route.indexOf(sl.op) : -1;
    return k > 0 && o ? `Chờ ${OP_NAME[o.route[k - 1]].toLowerCase()}` : 'Trống';
  };
  const rows = kh.machines.map((m) => {
    const all = view.sch.byMachine.get(m.code) ?? [];
    const slots = all.filter((s) => s.end > W0 && s.start < W0 + W);
    let used = 0, prevEnd = W0;
    const els: React.ReactNode[] = [];
    slots.forEach((sl) => {
      if (sl.start - prevEnd > S / 2) {
        const why = idleWhy(sl);
        els.push(<div key={'i' + sl.key + sl.start} className="absolute inset-y-1.5 flex items-center overflow-hidden rounded border border-dashed border-muted/60 px-1.5 text-[11.5px] text-muted" style={{ left: `${X(prevEnd)}%`, width: `calc(${X(sl.start) - X(prevEnd)}% - 3px)` }} title={why}>{why}</div>);
        if (sl.start > kh.frozenFrom * SPD * S && prevEnd < kh.frozenTo * SPD * S) idleNotes.push(`${m.code}: ${lc(why)} từ ${fmtT(kh, Math.max(prevEnd, kh.frozenFrom * SPD * S))}`);
      }
      if (sl.setup > 0 && sl.runStart > W0) els.push(<div key={'s' + sl.key + sl.start} className="absolute inset-y-1.5 rounded-l border border-dashed border-muted/70 bg-[repeating-linear-gradient(135deg,rgba(0,0,0,0.12)_0_3px,transparent_3px_6px)]" style={{ left: `${X(sl.start)}%`, width: `${X(sl.runStart) - X(sl.start)}%` }} title={`Đổi máy ${Math.round(sl.setup)} phút: ${sl.why}`} />);
      const o = orderOf.get(sl.lineId);
      const g = o?.group ?? '';
      const on = sel?.id === sl.id;
      const inner = (
        <>
          <b className="block truncate text-[12px] leading-tight">{o?.product_code ?? '?'}{sl.color ? ' · ' + sl.color : ''}</b>
          <span className="block truncate text-[11px] leading-tight text-ink/70">{sl.operator} · {o?.label} · {nf(sl.meters / 1000, 1)} km{sl.end > W0 + W ? ' · còn tiếp' : ''}</span>
        </>
      );
      const style = {
        left: `${X(sl.runStart)}%`, width: `calc(${X(sl.end) - X(sl.runStart)}% - 2px)`,
        background: GROUP_BG[g] ?? '#eef0f2', borderColor: on ? '#212529' : (GROUP_BORDER[g] ?? '#68717a'),
      };
      const cls = `absolute inset-y-1 overflow-hidden rounded border-l-4 border px-1.5 py-0.5 text-left text-ink hover:brightness-95 ${o?.prio === 0 ? 'ring-2 ring-bad ring-inset' : ''} ${on ? 'ring-2 ring-ink' : ''}`;
      els.push(sl.id
        ? <Link key={sl.key + sl.start} href={qs({ w: sp.w, sel: on ? undefined : sl.id }) + '#chi-tiet'} scroll={false} className={cls} style={style} title={`${o?.label} · ${o?.product_code}${sl.color ? ' · ' + sl.color : ''} · ${nf(sl.meters)} ${UNIT[sl.op]} · ${sl.operator}`}>{inner}</Link>
        : <div key={sl.key + sl.start} className={cls} style={style}>{inner}</div>);
      used += Math.max(0, Math.min(sl.end, W0 + W) - Math.max(sl.start, W0));
      if (sl.start < W0 + W && sl.start >= W0) setupWeek += sl.setup;
      prevEnd = Math.max(prevEnd, sl.end);
    });
    if (prevEnd < W0 + W - S / 2) {
      const nx = all.find((s) => s.start >= W0 + W);
      const lab = idleWhy(nx);
      els.push(<div key="tail" className="absolute inset-y-1.5 flex items-center overflow-hidden rounded border border-dashed border-muted/60 px-1.5 text-[11.5px] text-muted" style={{ left: `${X(prevEnd)}%`, width: `calc(${100 - X(prevEnd)}% - 3px)` }}>{lab}</div>);
      if (prevEnd < kh.frozenTo * SPD * S && kh.frozenTo > startDay) idleNotes.push(`${m.code}: ${lc(lab)} từ ${fmtT(kh, Math.max(prevEnd, kh.frozenFrom * SPD * S))}`);
    }
    return { m, els, used };
  });
  const seen = new Set<string>();
  const notes = idleNotes.filter((n) => { const k = n.split(':')[0]; if (seen.has(k)) return false; seen.add(k); return true; });
  const grid = `repeating-linear-gradient(90deg, rgb(var(--line)) 0 1px, transparent 1px calc(100% / ${N}))`;
  return (
    <div className="flex flex-col gap-4">
      {notes.length > 0 && !view.preview && <Alert tone="warn" title="Máy trống trong vùng khóa · bố trí bảo trì, vệ sinh hoặc đào tạo">{notes.map((n) => <div key={n}>{n}</div>)}</Alert>}
      <div className="flex flex-wrap items-center gap-2">
        <Link className="btn btn-sm" href={qs({ w: String(w - 1) })} scroll={false}><ChevronLeft size={15} />Tuần trước</Link>
        <Link className="btn btn-sm" href={qs({ w: undefined })} scroll={false}>Tuần này</Link>
        <Link className="btn btn-sm" href={qs({ w: String(w + 1) })} scroll={false}>Tuần sau<ChevronRight size={15} /></Link>
        <span className="text-[13px] text-muted">{days.length ? `${dd(days[0])} – ${dd(days[days.length - 1])}` : ''} · bấm vào khối để xem căn cứ xếp</span>
      </div>
      <section className="card overflow-x-auto">
        <div className="min-w-[980px]">
          <div className="grid grid-cols-[180px_1fr] border-b border-line">
            <div className="px-3 py-2 text-[13px]"><b>Máy · người</b><div className="text-[12px] text-muted">{SPD} ca/ngày</div></div>
            <div>
              <div className="grid" style={{ gridTemplateColumns: `repeat(${days.length}, 1fr)` }}>
                {days.map((d, i) => (
                  <div key={d} className={`border-l border-line px-2 py-1.5 text-[12.5px] ${startDay + i === kh.todayIdx ? 'bg-brand-soft' : ''}`}>
                    <b>{wdl(d)} {dd(d)}</b><div className="text-[11.5px] text-muted">{tag(i)}</div>
                  </div>
                ))}
              </div>
              {SPD > 1 && (
                <div className="grid border-t border-line" style={{ gridTemplateColumns: `repeat(${N}, 1fr)` }}>
                  {Array.from({ length: N }, (_, s) => <div key={s} className="border-l border-line px-1 text-[11px] text-muted">Ca {cal.shifts[s % SPD].code}</div>)}
                </div>
              )}
            </div>
          </div>
          {rows.map(({ m, els, used }) => (
            <div key={m.code} className="grid grid-cols-[180px_1fr] border-b border-line last:border-b-0">
              <div className="px-3 py-2 text-[12.5px] leading-snug"><b className="text-[13px]">{m.code}</b><div className="truncate text-muted">{m.name}</div>
                <div className="text-muted">{m.operators.join(', ') || <span className="text-bad">chưa có người</span>} · tải {pc(used / W)}</div></div>
              <div className="relative h-[64px]" style={{ backgroundImage: grid }}>
                {pastPct > 0 && <div className="absolute inset-y-0 left-0 bg-ink/[0.05]" style={{ width: `${pastPct}%` }} />}
                {fz1 > fz0 && <div className="absolute inset-y-0 bg-info/[0.07]" style={{ left: `${fz0}%`, width: `${fz1 - fz0}%` }} />}
                {showNow && <div className="absolute inset-y-0 z-10 w-0.5 bg-bad" style={{ left: `${nowPct}%` }} />}
                {els}
              </div>
            </div>
          ))}
        </div>
        <div className="flex flex-wrap gap-x-4 gap-y-1 border-t border-line px-4 py-2.5 text-[12.5px] text-muted">
          {Object.entries(GROUP_NAME).filter(([g]) => kh.orders.some((o) => o.group === g)).map(([g, n]) => (
            <span key={g} className="inline-flex items-center gap-1.5"><i className="inline-block h-3 w-4 rounded-sm border-l-4" style={{ background: GROUP_BG[g], borderColor: GROUP_BORDER[g] }} />{n}</span>
          ))}
          <span className="inline-flex items-center gap-1.5"><i className="inline-block h-3 w-4 rounded-sm border border-dashed border-muted bg-[repeating-linear-gradient(135deg,rgba(0,0,0,0.15)_0_3px,transparent_3px_6px)]" />Đổi máy</span>
          <span className="inline-flex items-center gap-1.5"><i className="inline-block h-3 w-4 rounded-sm bg-info/20" />Vùng khóa {kh.cfg.frozen_days} ngày</span>
          <span className="inline-flex items-center gap-1.5"><i className="inline-block h-3 w-0.5 bg-bad" />Bây giờ</span>
          <span>Đổi máy cả tuần: {nf(setupWeek)} phút</span>
        </div>
      </section>
      <div id="chi-tiet">{sel ? <SlotDetail kh={kh} view={view} sel={sel} canPlan={canPlan} /> : <div className="card px-4 py-3 text-[13px] text-muted">Bấm vào một khối trên lịch để xem người đứng máy, căn cứ xếp, cách tính thời gian và ngày dự kiến xong.</div>}</div>
    </div>
  );
}

function SlotDetail({ kh, view, sel, canPlan }: { kh: Kh; view: View; sel: Slot; canPlan: boolean }) {
  const o = kh.orders.find((x) => x.id === sel.lineId);
  if (!o) return null;
  const S = view.sch.S, SPD = kh.cal.SPD;
  const frozen = sel.start < kh.frozenTo * SPD * S && sel.end > kh.frozenFrom * SPD * S;
  const past = sel.end <= kh.nowT;
  const f = view.fin.get(o.id);
  const last = o.route[o.route.length - 1];
  const dl = view.sch.opDone.get(o.id + '|' + last);
  const op = kh.operators.find((w) => w.code === sel.operator);
  const real = sel.meters / sel.speed;
  return (
    <section className="card">
      <div className="card-h"><h2><Swatch color={sel.color} />{o.label} · {opName(sel.op, o)} · {sel.machine} · {sel.operator}</h2>
        {frozen ? <Pill tone="info">Trong vùng khóa</Pill> : past ? <Pill>Đã chạy</Pill> : <Pill tone="ok">Ngoài vùng khóa</Pill>}</div>
      <div className="grid gap-3 p-4 sm:grid-cols-2 xl:grid-cols-4">
        <Kpi label="Sản phẩm" value={<span className="text-[18px]">{o.product_code}</span>} hint={o.product_name} />
        <Kpi label="Khối lượng khối này" value={<span className="text-[18px]">{nf(sel.meters)} {UNIT[sel.op]}</span>} hint={`${sel.color ? sel.color + ' · ' : ''}${Math.max(1, Math.round(sel.meters / BOBBIN[sel.op]))} bobin ra${sel.part ? ' · phần đã chạy' : ''}`} />
        <Kpi label="Chạy" value={<span className="text-[16px]">{fmtT(kh, sel.runStart)}</span>} hint={`đến ${fmtT(kh, sel.end - 0.01)}`} />
        <Kpi label="Lệnh dự kiến xong" value={<span className="text-[18px]">{dd(f?.finDate)}</span>} hint={<>hạn {dd(o.due)} · {f ? <FinishPill {...f} due={o.due} /> : null}</>} />
      </div>
      <div className="overflow-x-auto px-4 pb-2"><table className="tbl"><tbody>
        <tr><td className="w-[170px] text-muted">Phút chạy</td><td><b>{nf(sel.meters)} {UNIT[sel.op]} ÷ {nf(sel.speed)} m/phút = {nf(real)} phút ≈ {nf((sel.end - sel.runStart) / S, 1)} ca</b>
          <div className="text-[12.5px] text-muted">Mỗi ca chỉ xếp {S} phút ({view.sch.RUN} × {kh.version?.params.fill_pct ?? kh.cfg.fill_pct}%){sel.op === 'CD3' && o.shield ? ' · xoắn và quấn AL/PET liền dây: lấy tốc độ chậm hơn của hai bước' : ''}</div></td></tr>
        <tr><td className="text-muted">Người đứng máy</td><td><b>{sel.operator}</b><div className="text-[12.5px] text-muted">{op?.job}</div></td></tr>
        <tr><td className="text-muted">Đổi máy</td><td><b>{sel.setup ? `${Math.round(sel.setup)} phút` : 'Không'}</b><div className="text-[12.5px] text-muted">{sel.setup ? `${sel.why} · cần mẫu đầu mã đạt trước khi chạy hàng loạt` : 'Cùng mã, cùng màu với việc trước hoặc là việc đầu tiên của máy'}</div></td></tr>
        <tr><td className="text-muted">Bắt đầu lúc này vì</td><td><b>{sel.reason}</b><div className="text-[12.5px] text-muted">Thứ tự trên máy: {o.prio === 0 ? 'đơn gấp' : o.due ? `theo hạn giao ${dd(o.due)}` : 'chưa có hạn giao, xếp sau'}{sel.color ? ', màu sáng trước tối sau' : ''}</div></td></tr>
        <tr><td className="text-muted">Ngày xong lệnh</td><td><b>{dl && dl.end ? `${opName(last, o)} xong ${fmtT(kh, dl.end - 0.01)} + 1 ca kiểm tra, đóng gói = ${dd(f?.finDate)}` : 'Chưa xếp đủ công đoạn'}</b>
          <div className="text-[12.5px] text-muted">{f?.slack == null ? '' : f.slack >= 0 ? `Còn dư ${f.slack} ngày so với hạn giao` : `Trễ ${-f.slack} ngày so với hạn giao`}</div></td></tr>
      </tbody></table></div>
      <div className="flex flex-wrap items-center gap-2 border-t border-line px-4 py-3 text-[13px] text-muted">
        {past ? 'Phần đã chạy chỉ xem. Phần còn lại cập nhật theo báo cáo ca khi xếp lại lịch.'
          : !canPlan ? <LockNote>Chỉ Quản lý SX đổi lịch</LockNote>
          : frozen ? 'Việc trong vùng khóa: muốn đổi phải lập đơn phát sinh mức C (Giám đốc duyệt) ở thẻ Đơn phát sinh & thay đổi.'
          : 'Ngoài vùng khóa: đổi hạn giao, ưu tiên hoặc tham số rồi bấm Xếp lại lịch; hệ thống tự xếp theo quy tắc.'}
      </div>
    </section>
  );
}

// ----------------------------------------------------------------- Tiến độ
function Progress({ kh, view }: { kh: Kh; view: View }) {
  const ops: Op[] = ['CD1', 'CD2', 'CD3', 'CD5'];
  const sh = (t: number) => { const s = Math.floor(t / view.sch.S); const d = shiftDate(kh.cal, s); return `${dd(d)}${kh.cal.SPD > 1 ? ' ' + shiftCode(kh.cal, s) : ''}`; };
  return (
    <section className="card">
      <div className="card-h"><h2>Tiến độ dự kiến từng lệnh</h2><span className="text-[13px] font-normal text-muted">ngày bắt đầu → ngày xong mỗi công đoạn</span></div>
      <div className="overflow-x-auto"><table className="tbl">
        <thead><tr><th>Dòng</th><th>Sản phẩm</th><th className="num">Dự kiến xong</th><th className="num">Hạn giao</th><th>Tình trạng</th>{ops.map((op) => <th key={op}>{OP_SHORT[op]}</th>)}</tr></thead>
        <tbody>{kh.orders.map((o) => {
          const f = view.fin.get(o.id);
          return (
            <tr key={o.id}>
              <td className="mono">{o.label}{o.prio === 0 && <> <Pill tone="bad">Gấp</Pill></>}</td>
              <td className="whitespace-nowrap"><b>{o.product_code}</b><div className="text-[12px] text-muted">{nf(o.qty)} m · {o.source}</div></td>
              <td className="num"><b>{dd(f?.finDate)}</b></td><td className="num">{dd(o.due)}</td><td>{f ? <FinishPill {...f} due={o.due} /> : '—'}</td>
              {ops.map((op) => {
                if (!o.route.includes(op)) return <td key={op} className="text-[12px] text-muted">—</td>;
                const d = view.sch.opDone.get(o.id + '|' + op);
                if (!d || !d.end) return <td key={op} className="text-[12px] text-bad">Chưa xếp</td>;
                const state = d.end <= kh.nowT ? 'bg-todo text-ink/60 line-through' : d.start <= kh.nowT ? 'bg-brand-soft text-brand-dark' : '';
                return <td key={op} className="whitespace-nowrap text-[12.5px]"><span className={`rounded px-1.5 py-0.5 ${state}`}>{sh(d.start)} → {sh(d.end - 0.01)}</span></td>;
              })}
            </tr>
          );
        })}</tbody>
      </table></div>
      <p className="px-4 py-3 text-[12.5px] text-muted">Gạch ngang: đã xong · nền xanh: đang chạy. Dự kiến xong = công đoạn cuối xong + 1 ca kiểm tra, đóng gói. Tính lại sau mỗi lần xếp lại lịch.</p>
    </section>
  );
}

// ----------------------------------------------------------------- Căn cứ xếp lịch
function Basis({ kh, view }: { kh: Kh; view: View | null }) {
  const c = kh.cfg;
  const r = (op: string) => c.rates.find((x) => x.op_code === op);
  const co = (code: string) => c.changeovers.find((x) => x.code === code)?.minutes ?? '—';
  const o = kh.orders[0];
  const sls = (op: Op) => (view && o ? view.sch.slots.filter((s) => s.lineId === o.id && s.op === op) : []);
  const who = (op: Op) => [...new Set(sls(op).map((s) => `${s.machine} · ${s.operator}`))].join(', ') || '—';
  const span = (op: Op) => { const d = view?.sch.opDone.get(o.id + '|' + op); return d && d.end ? `${fmtT(kh, d.start)} → ${fmtT(kh, d.end - 0.01)}` : '—'; };
  const sp = (op: Op) => sls(op)[0]?.speed ?? 0;
  const f = o && view ? view.fin.get(o.id) : null;
  const cal = makeCalendar(c, kh.cal.base);
  return (
    <div className="flex flex-col gap-4">
      <div className="grid gap-4 xl:grid-cols-2 [&>*]:min-w-0">
        <section className="card">
          <div className="card-h"><h2>Đầu vào hệ thống dùng để xếp</h2></div>
          <div className="overflow-x-auto"><table className="tbl"><tbody>
            <tr><td className="w-[160px]"><b>Kế hoạch tháng</b></td><td>{kh.planNo}: {kh.orders.length} dòng, số mét, hạn giao và mức ưu tiên do Giám đốc đặt</td></tr>
            <tr><td><b>Đường đi công đoạn</b></td><td>Theo nhóm sản phẩm. Cách điện silicone chạy line silicone; HDPE/PVC chạy line vỏ. Cáp chống nhiễu: xoắn và quấn AL/PET liền dây trên máy xoắn</td></tr>
            <tr><td><b>Tốc độ chuẩn</b></td><td>TP Kỹ thuật/QA ban hành (cỡ &lt; 2,5 mm²): bện {r('CD1')?.rate_small}, bọc cách điện {r('CD2')?.rate_small}, xoắn {r('CD3')?.rate_small}, AL/PET {r('CD4')?.rate_small}, vỏ {r('CD5')?.rate_small} m/phút{c.rates.some((x) => !x.confirmed) ? ' · còn số giả định chưa ban hành' : ''}</td></tr>
            <tr><td><b>Phút đổi máy</b></td><td>Màu sáng → tối {co('INS_UP')}′, tối → sáng {co('INS_DOWN')}′, đổi cỡ {co('INS_SIZE')}′, đổi màu vỏ {co('SH_COLOR')}′, đổi mã vỏ {co('SH_CODE')}′, bện đổi cỡ {co('BUN_SIZE')}′, xoắn đổi mã {co('TWS_CODE')}′</td></tr>
            <tr><td><b>Ca làm việc</b></td><td>{cal.shifts.map((s) => `Ca ${s.code} ${s.start_time}–${s.end_time}, nghỉ ${s.break_min}′`).join('; ')} · nghỉ Chủ nhật</td></tr>
            <tr><td><b>Người và tay nghề</b></td><td>{kh.operators.filter((w) => w.skills.length).map((w) => `${w.code}: ${w.skills.join(', ')}`).join(' · ')} · mỗi người đứng {c.machines_per_operator} máy cùng lúc</td></tr>
            <tr><td><b>Tỷ lệ xếp lịch</b></td><td>{c.fill_pct}% → mỗi ca xếp {cal.S} trên {cal.RUN} phút, giữ {100 - c.fill_pct}% cho sự cố, mẫu đầu ca, chạy lại</td></tr>
            <tr><td><b>Thực tế</b></td><td>Báo cáo ca đã xác nhận: phần chưa xong cộng vào ca sau khi xếp lại lịch</td></tr>
          </tbody></table></div>
        </section>
        <section className="card">
          <div className="card-h"><h2>Quy tắc xếp</h2></div>
          <ol className="list-decimal space-y-2 py-3 pl-9 pr-4 text-[14px]">
            <li><b>Đơn gấp đã duyệt</b> xếp trước, rồi đến <b>hạn giao sớm</b>. Dòng chưa có hạn giao xếp sau cùng.</li>
            <li>Mỗi việc vào <b>máy cùng loại có người đủ tay nghề rảnh sớm nhất</b>, đã tính phút đổi máy.</li>
            <li>Trong cùng lệnh, <b>màu sáng chạy trước, màu tối sau</b>. Cùng cỡ ruột chạy liền nhau.</li>
            <li><b>Gối đầu công đoạn:</b> công đoạn sau bắt đầu khi công đoạn trước đã chạy ít nhất 1 ca và không xong trước công đoạn trước.</li>
            <li>Mỗi ca chỉ xếp <b>{c.fill_pct}%</b> thời gian chạy.</li>
            <li>Khi xếp lại: <b>phần đã chạy và vùng khóa {c.frozen_days} ngày giữ nguyên</b>. Chen vào vùng khóa phải qua đơn phát sinh mức C.</li>
            <li>Ngày xong lệnh = công đoạn cuối xong <b>+ 1 ca kiểm tra, đóng gói</b> (NV3, NV4; NV3 giữ kho thành phẩm).</li>
          </ol>
        </section>
      </div>
      {o && view && (
        <section className="card">
          <div className="card-h"><h2>Ví dụ: {o.label} · {o.product_code} · {nf(o.qty)} m · hạn {dd(o.due)}</h2></div>
          <div className="overflow-x-auto"><table className="tbl">
            <thead><tr><th>Công đoạn</th><th>Máy · người</th><th>Khối lượng</th><th>Phút chạy</th><th>Chạy</th></tr></thead>
            <tbody>
              {o.route.map((op) => {
                const m = op === 'CD1' ? o.qty * o.cores.length : o.qty;
                return (
                  <tr key={op}><td><b>{opName(op, o)}</b></td><td className="text-[12.5px]">{who(op)}</td>
                    <td className="text-[12.5px]">{op === 'CD1' ? `${o.cores.length} lõi × ${nf(o.qty)} = ${nf(m)} m lõi` : op === 'CD2' ? `${nf(o.qty)} m lõi mỗi màu (${o.cores.join(', ')})` : `${nf(o.qty)} m cáp`}</td>
                    <td className="text-[12.5px]">{sp(op) ? `${nf(m)} ÷ ${nf(sp(op))} = ${nf(m / sp(op))}′${op === 'CD2' ? ' (cả các màu)' : ''}` : '—'}</td>
                    <td className="text-[12.5px]">{span(op)}</td></tr>
                );
              })}
              <tr><td><b>Kiểm tra, đóng gói</b></td><td className="text-[12.5px]">NV3, NV4</td><td className="text-[12.5px]">theo quy cách đóng gói</td><td className="text-[12.5px]">1 ca</td>
                <td><b>Xong {dd(f?.finDate)}</b> · hạn {dd(o.due)} {f ? <FinishPill {...f} due={o.due} /> : null}</td></tr>
            </tbody>
          </table></div>
        </section>
      )}
    </div>
  );
}

// ----------------------------------------------------------------- Đơn phát sinh
type ChangeRow = {
  id: string; req_no: string; payload: Record<string, unknown>; result: Record<string, unknown>; level: 'A' | 'B' | 'C'; steps: Step[];
  status: string; note: string | null; created_at: string; created_by: string; created_by_name: string | null; finished_at: string | null; plan_id: string;
};
const STEP_ROLE: Record<string, string> = { BGD: 'Giám đốc', KT_TP: 'TP Kỹ thuật/QA', SX_TP: 'Quản lý SX' };
const CH_STATUS: Record<string, [string, 'info' | 'ok' | 'bad' | 'warn' | 'mute']> = {
  PENDING: ['Chờ duyệt', 'info'], READY: ['Đã duyệt · chờ áp dụng', 'warn'], LINE_ADDED: ['Đã thêm dòng · chờ xếp lịch', 'warn'], APPLIED: ['Đã áp dụng', 'ok'], RETURNED: ['Bị trả lại', 'bad'],
};

async function Changes({ kh, sp, roles, userId }: { kh: Kh; sp: SP; roles: string[]; userId: string }) {
  const db = await createClient();
  const canReq = hasRole(roles, ROLE.release) && kh.fromPlan;
  const canSim = canReq || hasRole(roles, ROLE.params);
  const [{ data: prods }, { data: reqs }, { data: vers }] = await Promise.all([
    canSim ? db.schema('app').from('v_kh_products').select('*').order('product_code') : Promise.resolve({ data: [] as ProductRow[] }),
    db.schema('app').from('v_kh_changes').select('*').eq('plan_id', kh.planId ?? '').order('created_at', { ascending: false }).limit(30),
    db.schema('app').from('v_kh_versions').select('*').eq('plan_id', kh.planId ?? '').order('version', { ascending: false }).limit(30),
  ]);
  const products = (prods ?? []) as ProductRow[];
  const input = sp.sp ? readChange(sp) : null;
  const prod = input && typeof input !== 'string' ? products.find((p) => p.product_code === input.product_code) : null;
  const sim = input && typeof input !== 'string' && prod && kh.version ? simulate(kh, prod, input) : null;
  const minDue = addDays(kh.now.date, 1);
  return (
    <div className="flex flex-col gap-4">
      <section className="card">
        <div className="card-h"><h2>Quy trình khi có đơn phát sinh</h2></div>
        <ol className="grid gap-2 p-4 text-[13.5px] md:grid-cols-5">
          {[
            ['1 · Giám đốc nhận đơn', 'Đơn từ kinh doanh KAVIX, Heizka. Giám đốc có thể tự mô phỏng để báo ngày giao sớm nhất.'],
            ['2 · Quản lý SX mô phỏng', 'Nhập đơn, chọn mức ưu tiên. Hệ thống xếp thử theo máy và người, chỉ ra lệnh nào bị lùi, lệnh nào trễ.'],
            ['3 · Hệ thống chọn mức', 'A, B hoặc C theo ảnh hưởng. Không ai tự chọn mức.'],
            ['4 · Duyệt', 'Mức B, C: Giám đốc duyệt. Mức C hỏi ý kiến TP Kỹ thuật/QA trước. Người lập không tự duyệt.'],
            ['5 · Áp dụng', 'Thêm dòng vào kế hoạch tháng, lịch phiên bản mới, báo người liên quan, phát lại lệnh ngày bị ảnh hưởng.'],
          ].map(([t, d]) => <li key={t} className="rounded border border-line bg-sunk/60 p-3"><b className="block">{t}</b><span className="text-muted">{d}</span></li>)}
        </ol>
        <div className="overflow-x-auto border-t border-line"><table className="tbl">
          <thead><tr><th>Mức</th><th>Khi nào</th><th>Ai duyệt</th><th>Hỏi ý kiến / báo</th></tr></thead>
          <tbody>
            <tr><td><Pill tone="ok">A</Pill></td><td>Không chạm vùng khóa, không lệnh nào thành trễ, đơn mới kịp hạn</td><td>Quản lý SX tự áp dụng</td><td>Báo Giám đốc</td></tr>
            <tr><td><Pill tone="warn">B</Pill></td><td>Không chạm vùng khóa nhưng có lệnh khác thành trễ, hoặc đơn mới không kịp hạn</td><td>Giám đốc duyệt, chốt ngày giao với kinh doanh</td><td>Báo Chủ tịch HĐQT các SO bị lùi</td></tr>
            <tr><td><Pill tone="bad">C</Pill></td><td>Đơn gấp chen vào vùng khóa (tách lệnh đang chạy, đổi lệnh đã phát)</td><td>Giám đốc duyệt</td><td>Hỏi TP Kỹ thuật/QA; báo kế toán (phiếu lĩnh bổ sung), TP mua hàng, Chủ tịch nếu trễ SO</td></tr>
          </tbody>
        </table></div>
      </section>

      <section className="card">
        <div className="card-h"><h2>Nhập đơn phát sinh</h2>{!canSim && <LockNote>Chỉ Quản lý SX, Giám đốc dùng</LockNote>}</div>
        {!kh.version ? <p className="px-4 py-3 text-[13.5px] text-muted">Chưa có lịch máy đã lưu. Xếp lịch trước khi nhận đơn phát sinh.</p> : (
          <form action="/lich-may" className="grid gap-3 p-4 sm:grid-cols-2 xl:grid-cols-6">
            <input type="hidden" name="plan" value={kh.planId ?? ''} /><input type="hidden" name="tab" value="phatsinh" />
            <label className="lbl xl:col-span-2">Mã sản phẩm
              <select name="sp" className="inp" defaultValue={sp.sp ?? ''} required disabled={!canSim}>
                <option value="">Chọn mã…</option>
                {products.map((p) => <option key={p.id} value={p.product_code}>{p.product_code} · {p.product_name}</option>)}
              </select></label>
            <label className="lbl">Số mét<input name="qty" className="inp text-right" inputMode="numeric" defaultValue={sp.qty ?? ''} placeholder="10.000" required disabled={!canSim} /></label>
            <label className="lbl">Hạn giao khách cần<input type="date" name="due" min={minDue} className="inp" defaultValue={sp.due ?? ''} required disabled={!canSim} /></label>
            <label className="lbl">Số SO<input name="so" className="inp" defaultValue={sp.so ?? ''} placeholder="SO-2611-0003" disabled={!canSim} /></label>
            <label className="lbl">Mức ưu tiên<select name="prio" className="inp" defaultValue={sp.prio ?? '1'} disabled={!canSim}><option value="1">Thường</option><option value="0">Gấp</option></select></label>
            <label className="flex items-start gap-2 text-[13.5px] sm:col-span-2 xl:col-span-6">
              <input type="checkbox" name="br" value="1" defaultChecked={sp.br === '1'} className="mt-1" disabled={!canSim} />
              <span>Cho chen vào vùng khóa từ ngày mai (tách lệnh đang chạy)<span className="block text-[12.5px] text-muted">Chỉ có tác dụng với đơn Gấp; sẽ thành mức C</span></span>
            </label>
            <div className="flex flex-wrap items-center gap-3 sm:col-span-2 xl:col-span-6">
              <button className="btn btn-pri" disabled={!canSim}>Mô phỏng ảnh hưởng</button>
              <span className="text-[12.5px] text-muted">Mô phỏng không đổi lịch thật.</span>
            </div>
          </form>
        )}
        {typeof input === 'string' && <div className="px-4 pb-3"><Flash err={input} /></div>}
      </section>

      {sim && input && typeof input !== 'string' && (
        <section className="card">
          <div className="card-h"><h2>Kết quả mô phỏng · {input.product_code} · {nf(input.qty)} m</h2><Pill tone={LEVEL[sim.level].tone}>{LEVEL[sim.level].label}</Pill></div>
          <div className="grid gap-3 p-4 sm:grid-cols-2 xl:grid-cols-4">
            <Kpi label="Đơn mới dự kiến xong" value={dd(sim.n.finDate)} hint={<>khách cần {dd(input.due)} · <FinishPill {...sim.n} due={input.due} /></>} tone={!sim.n.placed || (sim.n.slack ?? 0) < 0 ? 'bad' : 'ok'} />
            <Kpi label="Lệnh khác bị đổi ngày xong" value={sim.rows.length} hint={sim.rows.length ? 'xem bảng bên dưới' : 'không ảnh hưởng'} tone={sim.rows.length ? 'warn' : 'ok'} />
            <Kpi label="Lệnh bị lùi thành trễ" value={sim.newly.length} hint={sim.newly.join(', ') || 'không có'} tone={sim.newly.length ? 'bad' : 'ok'} />
            <Kpi label="Chạm vùng khóa" value={sim.br ? 'Có' : 'Không'} hint={sim.br ? (sim.touched.length ? 'máy ' + sim.touched.join(', ') : 'tách lệnh đang chạy') : `bắt đầu sau vùng khóa`} tone={sim.br ? 'bad' : undefined} />
          </div>
          {sim.rows.length > 0 && (
            <div className="overflow-x-auto border-t border-line"><table className="tbl">
              <thead><tr><th>Lệnh bị ảnh hưởng</th><th>Nguồn</th><th className="num">Hạn giao</th><th className="num">Xong trước</th><th className="num">Xong sau</th><th>Tình trạng sau</th></tr></thead>
              <tbody>{sim.rows.map((r) => (
                <tr key={r.id}><td className="mono">{r.label} · {r.product_code}</td><td className="text-[12.5px]">{r.source}</td><td className="num">{dd(r.due)}</td><td className="num">{dd(r.before)}</td><td className="num"><b>{dd(r.after)}</b></td>
                  <td><FinishPill finDate={r.after} slack={r.slackAfter} due={r.due} placed={r.placedAfter} /></td></tr>
              ))}</tbody>
            </table></div>
          )}
          <div className="border-t border-line px-4 py-3 text-[13.5px]">
            <div className="mb-1 font-medium">Các bước duyệt (hệ thống tự chọn theo mức)</div>
            <ol className="list-decimal pl-5 text-muted">{(sim.level === 'A' ? ['Quản lý SX lập đề nghị, chạy mô phỏng', 'Quản lý SX áp dụng'] : sim.level === 'B' ? ['Quản lý SX lập đề nghị', 'Giám đốc duyệt, chốt ngày giao với kinh doanh', 'Áp dụng lịch mới'] : ['Quản lý SX lập đề nghị', 'TP Kỹ thuật/QA cho ý kiến', 'Giám đốc duyệt chen vào vùng khóa', 'Áp dụng lịch mới']).map((s) => <li key={s}>{s}</li>)}</ol>
            <div className="mt-1 text-muted">Hệ thống báo: {sim.notify.join(', ')}.</div>
          </div>
          <div className="flex flex-wrap items-center gap-3 border-t border-line px-4 py-3">
            {canReq ? (
              <form action={createChange}>
                <input type="hidden" name="plan_id" value={kh.planId ?? ''} />
                {(['sp', 'qty', 'due', 'so', 'prio', 'br'] as const).map((k) => <input key={k} type="hidden" name={k} value={sp[k] ?? ''} />)}
                <SubmitButton>Gửi đề nghị mức {sim.level}</SubmitButton>
              </form>
            ) : <LockNote>Giám đốc chỉ mô phỏng để báo ngày giao; Quản lý SX gửi đề nghị</LockNote>}
          </div>
        </section>
      )}
      {sp.sp && !prod && typeof input !== 'string' && <Alert tone="bad">Mã {sp.sp} chưa có spec đã phát hành.</Alert>}

      <section className="card">
        <div className="card-h"><h2>Đề nghị đơn phát sinh</h2></div>
        {(reqs ?? []).length ? (reqs as ChangeRow[]).map((c) => {
          const cur = c.status === 'PENDING' ? c.steps.findIndex((s) => !s.done_at) : -1;
          const curStep = cur >= 0 ? c.steps[cur] : null;
          const mine = curStep && roles.includes(curStep.role);
          const self = c.created_by === userId || c.steps.some((s) => s.done_by === userId);
          const lastRole = c.steps[c.steps.length - 1].role;
          const canApply = ['READY', 'LINE_ADDED'].includes(c.status) && (hasRole(roles, ROLE.plan) || roles.includes(lastRole));
          return (
            <div key={c.id} className="border-b border-line px-4 py-3 last:border-b-0">
              <div className="flex flex-wrap items-center gap-2">
                <b className="mono">{c.req_no}</b><Pill tone={LEVEL[c.level].tone}>Mức {c.level}</Pill><Pill tone={CH_STATUS[c.status]?.[1] ?? 'mute'}>{CH_STATUS[c.status]?.[0] ?? c.status}</Pill>
                <span className="text-[13.5px]"><b>{String(c.payload.product_code)}</b> · {nf(Number(c.payload.qty_m))} m · hạn {dd(String(c.payload.due_date))}{c.payload.priority === '0' ? ' · Gấp' : ''}{c.payload.so ? ` · ${String(c.payload.so)}` : ''}</span>
                <span className="ml-auto text-[12.5px] text-muted">dự kiến xong {dd((c.result.finish as string) ?? null)} · {(c.result.rows as unknown[] | undefined)?.length ?? 0} lệnh đổi ngày</span>
              </div>
              <ol className="mt-2 flex flex-wrap gap-2 text-[12.5px]">
                {c.steps.map((s, i) => (
                  <li key={i} className={`rounded border px-2 py-1 ${s.done_at ? (s.result === 'Trả lại' ? 'border-bad/40 bg-bad-soft' : 'border-brand/40 bg-brand-soft') : i === cur ? 'border-info/50 bg-info-soft' : 'border-line'}`}>
                    <b>{i + 1}. {s.label}</b>
                    <div className="text-muted">{s.done_at ? `${s.done_name ?? ''} · ${df(s.done_at, true)}${s.result ? ' · ' + s.result : ''}${s.comment ? ' · “' + s.comment + '”' : ''}` : i === cur ? 'Đang chờ' : ''}</div>
                  </li>
                ))}
              </ol>
              {c.note && <div className="mt-1 text-[13px] text-bad">Lý do trả lại: {c.note}</div>}
              {curStep && (
                <div className="mt-2 flex flex-wrap items-center gap-2">
                  {mine && !self ? (
                    <form action={changeStep} className="flex flex-wrap items-center gap-2">
                      <input type="hidden" name="plan_id" value={kh.planId ?? ''} /><input type="hidden" name="id" value={c.id} />
                      <input name="comment" className="inp w-[260px] py-1.5" placeholder="Ý kiến (bắt buộc khi trả lại)" aria-label="Ý kiến" />
                      <SubmitButton className="btn btn-sm btn-pri">{curStep.role === 'KT_TP' ? 'Đồng ý' : 'Duyệt'}</SubmitButton>
                      <SubmitButton className="btn btn-sm btn-bad-o" formAction={returnChange}>Trả lại</SubmitButton>
                    </form>
                  ) : <LockNote>{mine && self ? 'Bạn đã lập hoặc đã làm bước trước: người khác duyệt' : `Chờ ${STEP_ROLE[curStep.role] ?? curStep.role}`}</LockNote>}
                </div>
              )}
              {canApply && (
                <form action={applyChange} className="mt-2"><input type="hidden" name="plan_id" value={kh.planId ?? ''} /><input type="hidden" name="id" value={c.id} />
                  <SubmitButton className="btn btn-sm btn-pri" pendingText="Đang xếp lại…">Áp dụng: thêm vào kế hoạch và xếp lại lịch</SubmitButton></form>
              )}
            </div>
          );
        }) : <Empty>Chưa có đơn phát sinh nào cho kế hoạch này.</Empty>}
      </section>

      <section className="card">
        <div className="card-h"><h2>Lịch sử phiên bản lịch máy</h2></div>
        <div className="overflow-x-auto"><table className="tbl">
          <thead><tr><th>Phiên bản</th><th>Lúc</th><th>Nội dung</th><th>Người xếp</th><th>Ca/ngày · phút xếp/ca</th></tr></thead>
          <tbody>{(vers ?? []).length ? (vers as { id: string; version: number; created_at: string; reason: string; created_by_name: string | null; change_no: string | null; is_current: boolean; params: { SPD: number; S: number } }[]).map((v) => (
            <tr key={v.id}><td className="mono">{v.version}{v.is_current && <> <Pill tone="ok">Đang dùng</Pill></>}</td><td className="whitespace-nowrap">{df(v.created_at, true)}</td>
              <td>{v.reason}{v.change_no ? ` · ${v.change_no}` : ''}</td><td className="text-[12.5px]">{v.created_by_name ?? ''}</td><td className="num">{v.params.SPD} · {v.params.S}</td></tr>
          )) : <tr><td colSpan={5} className="text-[13px] text-muted">Chưa có phiên bản nào.</td></tr>}</tbody>
        </table></div>
      </section>
    </div>
  );
}
