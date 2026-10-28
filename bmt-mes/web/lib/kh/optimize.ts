// Bộ tối ưu lịch máy: chạy bộ xếp lịch (schedule) nhiều lần với các phương án khác nhau và chọn phương án tốt nhất.
// Mọi con số lấy từ thông số (tốc độ máy, năng lực máy trộn, hạn dùng silicone, mét/bobin, QC, ca, số máy/người…):
// đổi thông số thì máy cổ chai, thứ tự lô và đề xuất thêm ca tự đổi theo.
//  1. Thứ tự lô: thử dời từng lô sang vị trí khác (cùng mức gấp), giữ thứ tự cho ít trễ hạn nhất, xong sớm nhất, ít đổi máy nhất.
//  2. Máy cổ chai: nhóm máy bận nhất trên thời gian kế hoạch; line silicone chờ silicone thì máy trộn là cổ chai.
//  3. Thêm ca (anh Bình duyệt 28/10/2026): máy bị chậm thì chạy 2 ca, 3 ca. Thử thêm một ca cho một hoặc hai nhóm máy cùng lúc
//     (máy trộn luôn chạy cùng ca line silicone vì silicone chỉ dùng được trong hạn), từ ngày xếp lại đến ngày nhóm đó hết việc,
//     tính như đủ người; chọn bước bớt trễ hạn nhiều nhất trên mỗi ngày công thêm, rồi rút ngắn nhiều nhất. Chế độ "due" chỉ thêm ca
//     khi có lô trễ ngày chốt / hạn giao; "fastest" thêm đến khi mỗi bước rút ngắn ít hơn ngưỡng. Sau đó xếp lại với người thật
//     để biết thiếu người ca nào (TP SX phân người ở Nhân sự xưởng).
import {
  type Calendar, type Config, type FlowCfg, type MachineInfo, type MachineShift, type OperatorInfo, type Order, type Schedule, type ScheduleOpts,
  dayIndex, finishInfo, flowOf, makeCalendar, peopleOf, schedule, workdaysBetween, addDays,
} from './scheduler.ts';

// remake: dựng lại lịch ca, mốc xếp lại và khoảng máy dừng khi số ca đổi (thêm ca 2 / ca 3 làm đổi số ca mỗi ngày)
export type Ctx = { cfg: Config; cal: Calendar; machines: MachineInfo[]; operators: OperatorInfo[]; remake?: (cfg: Config) => { cal: Calendar; opt: ScheduleOpts } };
export type Levers = {
  max_shifts?: number;          // số ca tối đa mỗi máy (mặc định 3)
  groups?: string[];            // nhóm máy được phép đề xuất thêm ca (mặc định: mọi nhóm có việc)
  mode?: 'due' | 'fastest';     // due: chỉ thêm ca đến khi kịp ngày chốt / hạn giao; fastest: thêm đến khi lợi ích < ngưỡng
  min_step_gain_day?: number;   // fastest: mỗi bước thêm ca phải rút ngắn ít nhất số ngày này, mặc định 0,2
  max_evals?: number;           // giới hạn số lần chạy bộ xếp lịch, mặc định 600
  reorder?: boolean;            // thử đổi thứ tự lô, mặc định true
  time_ms?: number;             // chặn an toàn thời gian tìm (ms), mặc định 15000; kết quả phụ thuộc số lần thử, không phụ thuộc tốc độ máy chủ
  reorder_evals?: number;       // số lần thử đổi thứ tự lô, mặc định 200 (Xếp lịch và thẻ Tối ưu dùng cùng số → cùng kết quả)
  levers?: boolean;             // thử thêm ca, mặc định true
  max_days?: number;            // một đề xuất thêm ca tối đa số ngày (mặc định 62, như database)
};
export type Score = { unplaced: number; late: number; lateLots: number; makespan: number; setup: number; flow: number };
export type GroupLoad = { group: string; machines: string[]; busyDays: number; util: number; waitSilicone_h: number };
// Một dòng đề xuất thêm ca: nhóm máy chạy `shifts` ca từ ngày … đến ngày …; persons = người cần cho mỗi ca thêm
export type ShiftStep = { group: string; machines: string[]; shifts: number; from: string; to: string; persons: number; days: number; personDays: number };
export type WhatIf = { label: string; days: number; gain: number; kind?: 'shift' | 'person'; group?: string };
export type Run = { sch: Schedule; score: Score; ords: Order[]; cal: Calendar };
export type OptResult = {
  orders: Order[]; flow: FlowCfg; sch: Schedule; score: Score;
  base: { sch: Schedule; score: Score };       // lịch theo cách xếp thường (không đổi thứ tự, không thêm ca)
  ordered: { sch: Schedule; score: Score; ords: Order[] };    // sau khi tối ưu thứ tự lô (ca máy đang duyệt, người thật)
  bottleneck: GroupLoad[]; whatIf: WhatIf[]; evals: number; log: string[];
  shiftPlan: ShiftStep[];                      // đề xuất thêm ca (trống: không cần / không có lợi)
  staffed?: Run;                               // lịch nếu thêm ca như đề xuất và đủ người
  realPlan?: Run;                              // lịch nếu thêm ca như đề xuất với người hiện có (thiếu người thì máy không chạy ca đó)
  machineShifts: MachineShift[];               // ca máy dùng cho staffed / realPlan (đang duyệt + đề xuất)
};

// Nhóm máy thêm ca: máy trộn đi cùng line silicone
export const SHIFT_GROUPS: Record<string, string[]> = { SIL: ['MIXER', 'EXTRUDER_SI'], BUNCHER: ['BUNCHER'], TWISTER: ['TWISTER'], EXTRUDER_TP: ['EXTRUDER_TP'], PACKER: ['PACKER'] };
const GROUP_NAME: Record<string, string> = {
  MIXER: 'Máy trộn silicone', BUNCHER: 'Máy bện', EXTRUDER_SI: 'Line silicone', TWISTER: 'Máy xoắn', EXTRUDER_TP: 'Line vỏ', PACKER: 'Máy đóng gói',
  SIL: 'Máy trộn + line silicone',
};
export const groupName = (g: string) => GROUP_NAME[g] ?? g;

export function scoreOf(sch: Schedule, cal: Calendar, orders: Order[]): Score {
  const fin = finishInfo(sch, cal, orders);
  const DAY = sch.S * sch.SPD;
  let late = 0, lateLots = 0, flow = 0;
  for (const o of orders) {
    const f = fin.get(o.id)!;
    const target = o.commit ?? o.due;
    if (f.placed) flow += f.end / DAY;
    if (target && f.finDate) {
      const d = dayIndex(cal, f.finDate) - dayIndex(cal, target);
      if (d > 0) { late += d * (o.prio === 0 ? 10 : 1); lateLots++; }
    } else if (target && !f.placed) { late += 1000; lateLots++; }
  }
  const makespan = Math.max(0, ...sch.slots.map((s) => s.end)) / DAY;
  return { unplaced: sch.unplaced.length, late, lateLots, makespan, setup: sch.slots.reduce((a, s) => a + s.setup, 0), flow };
}
// So sánh hai kết quả: âm = a tốt hơn
export function cmpScore(a: Score, b: Score): number {
  if (a.unplaced !== b.unplaced) return a.unplaced - b.unplaced;
  if (Math.abs(a.late - b.late) > 1e-9) return a.late - b.late;
  if (Math.abs(a.makespan - b.makespan) > 0.01) return a.makespan - b.makespan;
  if (Math.abs(a.setup - b.setup) > 1) return a.setup - b.setup;
  return a.flow - b.flow;
}

export function groupLoads(sch: Schedule, machines: MachineInfo[]): GroupLoad[] {
  const DAY = sch.S * sch.SPD;
  const span = Math.max(1e-9, ...sch.slots.map((s) => s.end));
  const groups = [...new Set(machines.map((m) => m.machine_type))];
  return groups.map((g) => {
    const ms = machines.filter((m) => m.machine_type === g).map((m) => m.code);
    const busy = sch.slots.filter((s) => ms.includes(s.machine)).reduce((a, s) => a + (s.end - s.start), 0);
    const wait = g === 'MIXER' ? Object.values(sch.mix?.wait_min ?? {}).reduce((a, x) => a + x, 0) / 60 : 0;
    return { group: g, machines: ms, busyDays: busy / DAY, util: busy / (span * Math.max(1, ms.length)), waitSilicone_h: wait };
  }).sort((a, b) => b.util - a.util);
}


export function optimize(orders: Order[], ctx: Ctx, opt: ScheduleOpts = {}, lv: Levers = {}): OptResult {
  const log: string[] = [];
  const maxEvals = lv.max_evals ?? 600;
  const mode = lv.mode ?? 'due';
  const P0 = peopleOf(ctx.cfg);
  const F0 = flowOf(ctx.cfg);
  let evals = 0;
  const t0 = Date.now(), timeMs = lv.time_ms ?? 15000;
  const over = (budget = maxEvals) => evals >= budget || Date.now() - t0 > timeMs;
  const MS0 = ctx.cfg.machine_shifts ?? [];
  const DAY0 = ctx.cal.S * ctx.cal.SPD;
  // Lịch ca, mốc xếp lại, khoảng máy dừng theo bộ ca máy (đổi số ca mỗi ngày thì đổi phút xếp lịch)
  const envOf = (ms: MachineShift[]) => {
    if (ms === MS0) return { cal: ctx.cal, opt };
    const cfg2 = { ...ctx.cfg, machine_shifts: ms };
    if (ctx.remake) return ctx.remake(cfg2);
    const cal = makeCalendar(cfg2, ctx.cal.base);
    const k = (cal.S * cal.SPD) / DAY0;
    return { cal, opt: { ...opt, boundary: opt.boundary != null ? opt.boundary * k : undefined, windows: (opt.windows ?? []).map((w) => ({ ...w, from: w.from * k, to: w.to * k })) } };
  };
  const run = (ords: Order[], flow: FlowCfg, ms: MachineShift[] = MS0, assume = false): Run => {
    evals++;
    const env = envOf(ms);
    const sch = schedule(ords, { ...ctx, cal: env.cal, cfg: { ...ctx.cfg, flow, machine_shifts: ms } }, { ...env.opt, assumeStaff: assume });
    return { sch, score: scoreOf(sch, env.cal, ords), ords, cal: env.cal };
  };
  const baseFlow: FlowCfg = { ...(ctx.cfg.flow ?? {}), extra_min: { ...F0.extra_min }, mix_early_h: F0.mix_early_h };
  const base = run(orders, baseFlow);

  // 1. Thứ tự lô: bắt đầu từ thứ tự gấp → thứ tự đã chọn lần trước → hạn; dời từng lô (cùng mức gấp) sang vị trí khác nếu tốt hơn
  const due = (o: Order) => o.commit ?? o.due ?? '9999-12-31';
  let seqd = [...orders].sort((a, b) => a.prio - b.prio || (a.seq ?? 1e9) - (b.seq ?? 1e9) || due(a).localeCompare(due(b)) || a.label.localeCompare(b.label));
  const withSeq = (list: Order[]) => {
    const pos = new Map(list.map((o, i) => [o.id, i]));
    return orders.map((o) => ({ ...o, seq: pos.get(o.id)! }));
  };
  let cur = run(withSeq(seqd), baseFlow);
  if (cmpScore(base.score, cur.score) < 0) cur = base; // giữ thứ tự (và seq) đã có
  const reorder = (budget: number, ms: MachineShift[] = MS0, assume = false) => {
    if (lv.reorder === false) return;
    for (let pass = 0, improved = true; improved && pass < 3; pass++) {
      improved = false;
      for (let i = 0; i < seqd.length; i++) for (let j = 0; j < seqd.length; j++) {
        if (i === j || over(budget)) continue;
        if (seqd[i].prio !== seqd[j].prio) continue;
        const cand = [...seqd];
        const [x] = cand.splice(i, 1); cand.splice(j, 0, x);
        const r = run(withSeq(cand), baseFlow, ms, assume);
        if (cmpScore(r.score, cur.score) < 0) { cur = r; seqd = cand; improved = true; log.push(`Thứ tự: đưa ${x.label} sang vị trí ${j + 1} → ${r.score.makespan.toFixed(2)} ngày, trễ ${r.score.late}`); }
      }
    }
  };
  reorder(Math.min(maxEvals, 1 + (lv.reorder_evals ?? 200)));
  const ordered = cur;

  // 2. Máy cổ chai
  const typeOf = new Map(ctx.machines.map((m) => [m.code, m.machine_type]));
  const machinesOf = (g: string) => ctx.machines.filter((m) => (SHIFT_GROUPS[g] ?? [g]).includes(m.machine_type) && m.status !== 'OFF').map((m) => m.code);
  const groups = (lv.groups ?? Object.keys(SHIFT_GROUPS))
    .filter((g) => machinesOf(g).length && ordered.sch.slots.some((s) => (SHIFT_GROUPS[g] ?? [g]).includes(typeOf.get(s.machine) ?? '')));
  // Người cần cho mỗi ca thêm của nhóm: máy trộn mỗi máy 1 người đứng riêng, máy đóng gói đủ tổ, máy tự chạy 1 người trông tối đa watch_max máy
  const personsOf = (g: string) => {
    const ms = machinesOf(g);
    const mix = ms.filter((c) => typeOf.get(c) === 'MIXER').length, pack = ms.filter((c) => typeOf.get(c) === 'PACKER').length;
    const auto = ms.length - mix - pack;
    return mix + pack * P0.pack_crew + (auto ? Math.ceil(auto / P0.watch_max) : 0);
  };

  // 3. Thêm ca từng bước (tính như đủ người)
  const cal0 = ctx.cal;
  const fromDi = Math.max(0, Math.floor((opt.boundary ?? 0) / DAY0 + 1e-9));
  const fromDate = cal0.days[Math.min(fromDi, cal0.days.length - 1)];
  const maxDays = lv.max_days ?? 62, maxShifts = Math.min(3, lv.max_shifts ?? 3);
  const lastDay = (r: Run, g: string) => {
    const ms = new Set(machinesOf(g));
    const DAY = r.sch.S * r.sch.SPD;
    const e = Math.max(0, ...r.sch.slots.filter((s) => ms.has(s.machine)).map((s) => s.end));
    const d = r.cal.days[Math.min(r.cal.days.length - 1, Math.max(0, Math.floor((e - 1e-6) / DAY)))];
    const lim = addDays(fromDate, maxDays);
    return d < fromDate ? fromDate : d > lim ? lim : d;
  };
  const level: Record<string, number> = Object.fromEntries(groups.map((g) => [g, 1]));
  const ranges: Record<string, { from: string; to: string }> = {};
  // Khi tìm: mọi phương án dùng chung lịch 3 ca (máy không thêm ca thì đóng giờ ca 2, ca 3) để so sánh công bằng
  const SAME: MachineShift = { machine: '·lịch 3 ca', from: cal0.days[0], to: cal0.days[cal0.days.length - 1], shifts: maxShifts };
  const msOf = (lvl: Record<string, number>, rg: Record<string, { from: string; to: string }>, same = true): MachineShift[] => [
    ...MS0, ...(same && maxShifts > 1 ? [SAME] : []),
    ...groups.filter((g) => lvl[g] > 1).flatMap((g) => machinesOf(g).map((m) => ({ machine: m, from: rg[g].from, to: rg[g].to, shifts: lvl[g] }))),
  ];
  const whatIf: WhatIf[] = [];
  let shiftPlan: ShiftStep[] = [];
  let staffed: Run | undefined, realPlan: Run | undefined;
  let chosenMs = MS0;
  if (lv.levers !== false && groups.length) {
    let s0 = run(ordered.ords, baseFlow, msOf(level, ranges), true);
    // Nếu thêm 1 ca cho từng nhóm (đủ người): xong sớm hơn bao nhiêu ngày
    for (const g of groups) {
      if (over()) break;
      const rg = { ...ranges, [g]: { from: fromDate, to: lastDay(s0, g) } };
      const r = run(s0.ords, baseFlow, msOf({ ...level, [g]: 2 }, rg), true);
      whatIf.push({ label: `${groupName(g)} chạy 2 ca (${machinesOf(g).join(', ')})`, days: r.score.makespan, gain: s0.score.makespan - r.score.makespan, kind: 'shift', group: g });
    }
    // Nếu thêm 1 người kiêm nhiệm cho từng nhóm máy (người cổ chai)
    for (const g of groups) {
      if (over()) break;
      const ms = machinesOf(g);
      const extra: OperatorInfo = { code: 'NV+', job: 'Người kiêm nhiệm thêm (giả định)', extra: null, is_deputy: false, keeps_fg: false, skills: ms, learning: [] };
      evals++;
      const sch = schedule(ordered.ords, { ...ctx, operators: [...ctx.operators, extra], cfg: { ...ctx.cfg, flow: baseFlow } }, opt);
      const sc = scoreOf(sch, ctx.cal, ordered.ords);
      whatIf.push({ label: `Thêm 1 người kiêm nhiệm ${groupName(g).toLowerCase()} (ca 1)`, days: sc.makespan, gain: ordered.score.makespan - sc.makespan, kind: 'person', group: g });
    }
    const combos: string[][] = [];
    for (let a = 0; a < groups.length; a++) { combos.push([groups[a]]); for (let b = a + 1; b < groups.length; b++) combos.push([groups[a], groups[b]]); }
    const need = () => mode === 'fastest' || s0.score.late > 0 || s0.score.unplaced > 0;
    while (need() && !over()) {
      let bestR: { r: Run; lvl: Record<string, number>; rg: typeof ranges; gs: string[]; k1: number; k2: number } | null = null;
      for (const gs of combos) {
        if (over()) break;
        if (gs.some((g) => level[g] >= maxShifts)) continue;
        const lvl = { ...level }, rg = { ...ranges };
        for (const g of gs) { lvl[g] = level[g] + 1; rg[g] = ranges[g] ?? { from: fromDate, to: lastDay(s0, g) }; }
        const r = run(s0.ords, baseFlow, msOf(lvl, rg), true);
        if (cmpScore(r.score, s0.score) >= 0) continue;
        const pd = gs.reduce((a, g) => a + personsOf(g) * Math.max(1, workdaysBetween(rg[g].from, addDays(rg[g].to, 1), cal0.wd)), 0);
        const gainLate = s0.score.late - r.score.late + (s0.score.unplaced - r.score.unplaced) * 1000;
        const gainDays = s0.score.makespan - r.score.makespan;
        if (mode === 'fastest' && gainLate <= 0 && gainDays < (lv.min_step_gain_day ?? 0.2)) continue;
        if (mode === 'due' && gainLate <= 0) continue;
        const k1 = gainLate / Math.max(1, pd), k2 = gainDays / Math.max(1, pd);
        if (!bestR || k1 > bestR.k1 + 1e-12 || (Math.abs(k1 - bestR.k1) <= 1e-12 && k2 > bestR.k2 + 1e-12)) bestR = { r, lvl, rg, gs, k1, k2 };
      }
      if (!bestR) break;
      s0 = bestR.r;
      for (const g of bestR.gs) { level[g] = bestR.lvl[g]; ranges[g] = bestR.rg[g]; }
      log.push(`Thêm ca: ${bestR.gs.map((g) => `${groupName(g)} ${level[g]} ca ${ranges[g].from}–${ranges[g].to}`).join(' + ')} → ${s0.score.makespan.toFixed(2)} ngày, trễ ${s0.score.late}`);
    }
    if (groups.some((g) => level[g] > 1)) {
      // thứ tự lô với ca mới (đủ người)
      cur = s0; reorder(maxEvals, msOf(level, ranges), true); s0 = cur; cur = ordered;
      chosenMs = msOf(level, ranges, false);
      staffed = run(s0.ords, baseFlow, chosenMs, true);
      realPlan = run(s0.ords, baseFlow, chosenMs, false);
      shiftPlan = groups.filter((g) => level[g] > 1).map((g) => {
        const days = Math.max(1, workdaysBetween(ranges[g].from, addDays(ranges[g].to, 1), cal0.wd));
        return { group: g, machines: machinesOf(g), shifts: level[g], from: ranges[g].from, to: ranges[g].to, persons: personsOf(g), days, personDays: personsOf(g) * (level[g] - 1) * days };
      });
    }
  }
  return {
    orders: ordered.ords, flow: baseFlow, sch: ordered.sch, score: ordered.score, base, ordered, bottleneck: groupLoads(ordered.sch, ctx.machines),
    whatIf, evals, log, shiftPlan, staffed, realPlan, machineShifts: chosenMs,
  };
}
