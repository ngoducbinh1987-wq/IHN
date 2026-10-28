// Bảng phân ca tuần (anh Bình duyệt 28/10/2026): máy nào chạy ca 1, ca 2 (ca 3); ai làm ca 2 cả tuần (đổi ca vào Chủ nhật).
// MES đề xuất: người rảnh làm ca 2, xoay vòng theo số tuần đã làm ca 2 rồi giờ đứng máy cộng dồn 4 tuần; ca 2 tối thiểu 2 người, 1 người phụ trách;
// thêm ca khi có lô trễ ngày chốt / hạn giao, hoặc khi có người rảnh cả ngày mà thêm ca giúp xong sớm hơn. TP SX sửa, gửi; Giám đốc duyệt một lần
// (ca máy + ca người); MES gửi lịch ca cho công nhân trước 12:00 thứ 7.
import { type Kh, rebuild } from './load';
import { SHIFT_GROUPS, type Score, groupName, scoreOf } from './optimize';
import { type Calendar, type MachineShift, type OpShift, type Schedule, addDays, isWorkday, peopleOf, toMin } from './scheduler';

export type RMachine = { machine: string; date: string; shifts: number };
export type RPerson = { code: string; shift: number; lead?: boolean };
export type RQc = { mode: 'QC' | 'LEAD'; who?: string | null };
export type RosterIn = { week: string; machines: RMachine[]; people: RPerson[]; qc: RQc };
export type RosterHours = { code: string; shift: number; lead: boolean; week_h: number; night_h: number; prev4_h: number; ca2_weeks: number; idle_days: number };
export type RosterSummary = {
  at: string; reason: string;
  base: { makespan: number; late: number; finish: Record<string, string | null>; idle: number };
  plan: { makespan: number; late: number; finish: Record<string, string | null>; idle: number };
  hours: RosterHours[]; groups: string[]; warnings: string[];
};
export type RosterEval = ReturnType<typeof evalRoster>;

const dow = (d: string) => (new Date(d + 'T00:00:00Z').getUTCDay() + 6) % 7; // 0 = thứ 2
export const mondayOf = (d: string) => addDays(d, -dow(d));
export const weekDays = (week: string, wd: number[]) => Array.from({ length: 7 }, (_, i) => addDays(week, i)).filter((d) => isWorkday(d, wd));
const r1 = (v: number) => Math.round(v * 10) / 10;

// Bỏ phần [a, b] khỏi các khoảng ngày (giữ phần trước, phần sau)
function cut<T extends { from: string; to: string }>(list: T[], a: string, b: string): T[] {
  const out: T[] = [];
  for (const x of list) {
    if (x.to < a || x.from > b) { out.push(x); continue; }
    if (x.from < a) out.push({ ...x, to: addDays(a, -1) });
    if (x.to > b) out.push({ ...x, from: addDays(b, 1) });
  }
  return out;
}

// Số tuần đã làm ca 2 / ca 3 (12 tuần trước tuần đang xét) và giờ đứng máy 4 tuần trước tuần đang xét (sổ giờ)
export function history(kh: Kh, week: string) {
  const P = peopleOf(kh.cfg);
  const wd = kh.cal.wd;
  const ca2 = new Map<string, Set<string>>(), prev4 = new Map<string, number>();
  for (const x of P.op_shifts) {
    if (Number(x.shift) < 2) continue;
    for (let d = x.from < addDays(week, -84) ? addDays(week, -84) : x.from; d <= x.to && d < week; d = addDays(d, 1)) {
      if (!isWorkday(d, wd)) continue;
      const s = ca2.get(x.code) ?? new Set<string>(); s.add(mondayOf(d)); ca2.set(x.code, s);
    }
  }
  for (const x of P.ledger) if (x.date >= addDays(week, -28) && x.date < week) prev4.set(x.code, (prev4.get(x.code) ?? 0) + Number(x.min));
  return { ca2: (c: string) => ca2.get(c)?.size ?? 0, prev4: (c: string) => (prev4.get(c) ?? 0) / 60 };
}

// Chạy bộ xếp lịch với bảng ca tuần này (thay ca máy, ca người trong tuần; từ hôm nay); xếp lại từ đầu tuần (không sớm hơn ngày mai)
export function evalRoster(kh: Kh, r: RosterIn) {
  // bảng ca áp từ ngày mai (hôm nay đã chạy theo ca cũ)
  const tomorrow = addDays(kh.now.date, 1), end = addDays(r.week, 6), from = r.week < tomorrow ? tomorrow : r.week;
  const P = peopleOf(kh.cfg);
  const extra = r.machines.some((m) => m.date >= from && m.shifts >= 2);
  const ms: MachineShift[] = [...cut(kh.cfg.machine_shifts ?? [], from, end),
    ...r.machines.filter((m) => m.date >= from && m.shifts >= 2).map((m) => ({ machine: m.machine, from: m.date, to: m.date, shifts: m.shifts }))];
  const os: OpShift[] = [...cut(P.op_shifts, from, end), ...r.people.filter((p) => p.shift >= 2).map((p) => ({ code: p.code, from, to: end, shift: p.shift }))];
  const qc = [...cut(P.qc_cover, from, end), ...(extra ? [{ from, to: end }] : [])];
  const cfg = { ...kh.cfg, machine_shifts: ms, people: { ...kh.cfg.people, op_shifts: os, qc_cover: qc } };
  const res = rebuild({ ...kh, cfg }, kh.orders, { fromDate: from });
  // ngày xong theo giờ thật (lịch 1 ca và lịch có ca 2, ca 3 chia phút xếp lịch khác nhau nên không so trực tiếp được)
  const score: Score = { ...scoreOf(res.sch, res.cal, res.orders), makespan: realDays(res.sch, res.cal) };
  // giờ đứng máy trong tuần, ngày rảnh cả ngày (người có mặt, không vắng, đứng máy < 15 phút trong khi người khác ≥ 4 giờ)
  const days = weekDays(r.week, kh.cal.wd).filter((d) => d >= from);
  const byDay = new Map<string, Map<string, { m: number; n: number }>>();
  for (const h of res.sch.hours ?? []) {
    if (h.d < r.week || h.d > end) continue;
    const mp = byDay.get(h.d) ?? new Map(); const x = mp.get(h.p) ?? { m: 0, n: 0 }; x.m += h.m; x.n += h.n; mp.set(h.p, x); byDay.set(h.d, mp);
  }
  const absent = (code: string, d: string) => P.absences.some((a) => a.code === code && a.part === 'FULL' && a.from <= d && d <= a.to);
  const idleOf = new Map<string, number>();
  for (const d of days) {
    const mp = byDay.get(d) ?? new Map();
    const mx = Math.max(0, ...[...mp.values()].map((x) => x.m));
    if (mx < 240) continue;
    for (const o of kh.operators) if (!absent(o.code, d) && (mp.get(o.code)?.m ?? 0) < 15) idleOf.set(o.code, (idleOf.get(o.code) ?? 0) + 1);
  }
  const week = new Map<string, { m: number; n: number }>();
  for (const mp of byDay.values()) for (const [p, x] of mp) { const w = week.get(p) ?? { m: 0, n: 0 }; w.m += x.m; w.n += x.n; week.set(p, w); }
  const short = [...new Set((res.sch.roster?.shortages ?? []).filter((x) => x.date >= from && x.date <= end).map((x) => `${x.machine} ca ${x.shift === 'C' ? 3 : 2}: ${x.why}`))];
  const finish = Object.fromEntries(res.orders.map((o) => [o.id, res.fin.get(o.id)?.finDate ?? null]));
  return { res, score, week, idleOf, idle: [...idleOf.values()].reduce((a, x) => a + x, 0), short, finish, days, from, end };
}

// Lúc xong việc cuối cùng: số ngày làm việc + phần ngày theo giờ thật tính từ đầu ca 1 (ca 1 xong 14:00 với ca 1 06:00 = 1/3 ngày)
export function realDays(sch: Pick<Schedule, 'slots' | 'S' | 'SPD'>, cal: Pick<Calendar, 'shifts'>): number {
  const t = Math.max(0, ...sch.slots.map((x) => x.end));
  if (t <= 0) return 0;
  const DAY = sch.S * sch.SPD;
  const di = Math.max(0, Math.floor((t - 1e-6) / DAY)), r = t - di * DAY;
  const seg = Math.min(sch.SPD - 1, Math.max(0, Math.floor((r - 1e-6) / sch.S)));
  const sh = cal.shifts[seg], first = cal.shifts[0];
  if (!sh || !first) return t / DAY;
  const a = toMin(sh.start_time); let b = toMin(sh.end_time); if (b <= a) b += 1440;
  let a0 = a - toMin(first.start_time); if (a0 < 0) a0 += 1440;
  return di + (a0 + ((r - seg * sch.S) / sch.S) * (b - a)) / 1440;
}

// Người cần cho mỗi ca thêm của nhóm máy: máy trộn mỗi máy 1 người đứng riêng, máy đóng gói đủ tổ, máy tự chạy 1 người trông tối đa watch_max máy
function personsOf(kh: Kh, machines: string[]) {
  const P = peopleOf(kh.cfg), type = new Map(kh.machines.map((m) => [m.code, m.machine_type]));
  const mix = machines.filter((c) => type.get(c) === 'MIXER').length, pack = machines.filter((c) => type.get(c) === 'PACKER').length;
  const auto = machines.length - mix - pack;
  return mix + pack * P.pack_crew + (auto ? Math.ceil(auto / P.watch_max) : 0);
}
const groupMachines = (kh: Kh, g: string) => kh.machines.filter((m) => (SHIFT_GROUPS[g] ?? [g]).includes(m.machine_type) && m.status !== 'OFF').map((m) => m.code);

export function summarize(kh: Kh, r: RosterIn, ev: RosterEval, base: RosterEval, reason: string, groups: string[]): RosterSummary {
  const h = history(kh, r.week);
  // cảnh báo người không có việc: chỉ giữ ngày trong tuần của bảng ca
  const wdm = new Set(ev.days.map((d) => `${d.slice(8, 10)}/${d.slice(5, 7)}`));
  const inWeek = (x: string) => { const m = x.match(/ngày (\d{2}\/\d{2})/); return !m || wdm.has(m[1]); };
  const hours: RosterHours[] = kh.operators.map((o) => {
    const p = r.people.find((x) => x.code === o.code);
    const w = ev.week.get(o.code) ?? { m: 0, n: 0 };
    return { code: o.code, shift: p?.shift ?? 1, lead: Boolean(p?.lead), week_h: r1(w.m / 60), night_h: r1(w.n / 60), prev4_h: r1(h.prev4(o.code)),
      ca2_weeks: h.ca2(o.code), idle_days: ev.idleOf.get(o.code) ?? 0 };
  });
  return {
    at: new Date().toISOString(), reason,
    base: { makespan: r1(base.score.makespan), late: base.score.late, finish: base.finish, idle: base.idle },
    plan: { makespan: r1(ev.score.makespan), late: ev.score.late, finish: ev.finish, idle: ev.idle },
    hours, groups, warnings: [...ev.short, ...(ev.res.sch.warnings ?? []).filter((x) => x.startsWith('Giờ đứng máy') || (x.includes('không có việc đứng máy') && inWeek(x)))],
  };
}

// MES đề xuất bảng ca tuần
export function suggestRoster(kh: Kh, week: string): { roster: RosterIn; summary: RosterSummary } {
  const P = peopleOf(kh.cfg);
  const h = history(kh, week);
  const tomorrow = addDays(kh.now.date, 1), from = week < tomorrow ? tomorrow : week;
  const days = weekDays(week, kh.cal.wd).filter((d) => d >= from);
  const allCa1: RPerson[] = kh.operators.map((o) => ({ code: o.code, shift: 1 }));
  const qc: RQc = { mode: 'LEAD', who: null };
  const base0: RosterIn = { week, machines: [], people: allCa1, qc };
  const base = evalRoster(kh, base0);
  if (!days.length) return { roster: base0, summary: summarize(kh, base0, base, base, 'Tuần không còn ngày làm việc nào từ hôm nay', []) };
  // người có mặt trong tuần (không vắng cả tuần); thứ tự làm ca 2: ít tuần ca 2 nhất, ít giờ đứng máy 4 tuần nhất
  const present = kh.operators.filter((o) => days.some((d) => !P.absences.some((a) => a.code === o.code && a.part === 'FULL' && a.from <= d && d <= a.to)));
  const order = [...present].sort((a, b) => h.ca2(a.code) - h.ca2(b.code) || h.prev4(a.code) - h.prev4(b.code) || a.code.localeCompare(b.code));
  // nhóm máy có việc trong tuần
  const DAY = base.res.cal.S * base.res.cal.SPD;
  const t0 = Math.max(0, days.length ? (base.res.cal.days.indexOf(days[0])) : 0) * DAY, t1 = t0 + days.length * DAY;
  const groups = Object.keys(SHIFT_GROUPS).filter((g) => {
    const ms = groupMachines(kh, g);
    return ms.length && base.res.sch.slots.some((s) => ms.includes(s.machine) && s.end > t0 && s.start < t1);
  });
  const late = base.score.late > 0 || base.score.unplaced > 0;
  const idle = base.idle >= 2;
  if (!late && !idle) {
    return { roster: base0, summary: summarize(kh, base0, base, base, base.idle ? `Ít người rảnh (${base.idle} ngày-người), mọi lô kịp hạn: mọi máy chạy ca 1` : 'Mọi người có việc, mọi lô kịp hạn: mọi máy chạy ca 1', []) };
  }
  const cap = Math.max(0, present.length - 2); // ca 1 còn ít nhất 2 người
  const combos: string[][] = [];
  for (let a = 0; a < groups.length; a++) {
    combos.push([groups[a]]);
    for (let b = a + 1; b < groups.length; b++) {
      combos.push([groups[a], groups[b]]);
      for (let c = b + 1; c < groups.length; c++) combos.push([groups[a], groups[b], groups[c]]);
    }
  }
  type Best = { r: RosterIn; ev: RosterEval; gs: string[]; n: number };
  let best: Best | null = null;
  const better = (x: Best, y: Best | null) => {
    if (!y) return true;
    if (x.ev.score.unplaced !== y.ev.score.unplaced) return x.ev.score.unplaced < y.ev.score.unplaced;
    if (Math.abs(x.ev.score.late - y.ev.score.late) > 1e-9) return x.ev.score.late < y.ev.score.late;
    if (Math.abs(x.ev.score.makespan - y.ev.score.makespan) > 0.05) return x.ev.score.makespan < y.ev.score.makespan;
    if (x.n !== y.n) return x.n < y.n;
    return x.ev.idle < y.ev.idle;
  };
  for (const gs of combos) {
    const machines = [...new Set(gs.flatMap((g) => groupMachines(kh, g)))];
    const n = Math.max(2, personsOf(kh, machines));
    if (n > cap) continue;
    const ca2 = order.slice(0, n).map((o) => o.code);
    const lead = kh.operators.find((o) => ca2.includes(o.code) && o.is_deputy)?.code ?? ca2[0];
    const r: RosterIn = {
      week, qc,
      machines: days.flatMap((d) => machines.map((m) => ({ machine: m, date: d, shifts: 2 }))),
      people: kh.operators.map((o) => ca2.includes(o.code) ? { code: o.code, shift: 2, lead: o.code === lead } : { code: o.code, shift: 1 }),
    };
    const ev = evalRoster(kh, r);
    const cand = { r, ev, gs, n };
    if (better(cand, best)) best = cand;
  }
  const gain = best ? base.score.makespan - best.ev.score.makespan : 0;
  const lateGain = best ? base.score.late - best.ev.score.late : 0;
  const useful = best && (late ? lateGain > 0 || (base.score.unplaced - best.ev.score.unplaced) > 0 : gain >= 0.2);
  if (!best || !useful) {
    const why = !groups.length ? 'Tuần này không có máy nào có việc' : cap < 2 ? `Chỉ ${present.length} người có mặt: không đủ 2 người cho ca 2 mà ca 1 vẫn còn người`
      : late ? 'Thêm ca 2 không làm lô nào bớt trễ' : `Thêm ca 2 không làm xong sớm hơn đáng kể (dưới 0,2 ngày)`;
    return { roster: base0, summary: summarize(kh, base0, base, base, `${why}: mọi máy chạy ca 1`, []) };
  }
  const reason = (late ? `Có lô trễ ngày chốt / hạn giao: thêm ca 2 cho ${best.gs.map(groupName).join(', ')} bớt trễ ${base.score.late} → ${best.ev.score.late} ngày`
    : `${base.idle} ngày-người không có việc đứng máy: thêm ca 2 cho ${best.gs.map(groupName).join(', ')}`)
    + `, kế hoạch xong sau ${r1(base.score.makespan)} → ${r1(best.ev.score.makespan)} ngày làm việc`;
  return { roster: best.r, summary: summarize(kh, best.r, best.ev, base, reason, best.gs) };
}
