// Bộ tối ưu lịch máy: chạy bộ xếp lịch (schedule) nhiều lần với các phương án khác nhau và chọn phương án tốt nhất.
// Mọi con số lấy từ thông số (tốc độ máy, năng lực máy trộn, hạn dùng silicone, mét/bobin, QC, ca, tăng ca tối đa…):
// đổi thông số thì máy cổ chai, thứ tự lô và đề xuất tăng ca tự đổi theo.
//  1. Thứ tự lô: thử dời từng lô sang vị trí khác (cùng mức gấp), giữ thứ tự cho ít trễ hạn nhất, xong sớm nhất, ít đổi máy nhất.
//  2. Máy cổ chai: nhóm máy bận nhất trên thời gian kế hoạch; line silicone chờ silicone thì máy trộn là cổ chai.
//  3. Tăng ca / trộn sớm: thử thêm từng bước giờ cho một, hai hoặc ba nhóm máy cùng lúc (máy trộn và line silicone phải tăng
//     cùng nhau vì silicone chỉ dùng được trong hạn), chọn bước rút ngắn nhiều nhất trên mỗi giờ công; dừng khi kịp hạn
//     (chế độ "due") hoặc khi lợi ích nhỏ hơn ngưỡng (chế độ "fastest"), không vượt giới hạn tăng ca.
import {
  type Calendar, type Config, type FlowCfg, type MachineInfo, type OperatorInfo, type Order, type Schedule, type ScheduleOpts,
  dayIndex, finishInfo, flowOf, schedule,
} from './scheduler.ts';

export type Ctx = { cfg: Config; cal: Calendar; machines: MachineInfo[]; operators: OperatorInfo[] };
export type Levers = {
  ot_max_min?: number;          // tăng ca tối đa mỗi ngày (phút/người), mặc định 240
  ot_step_min?: number;         // bước thử tăng ca (phút), mặc định 60
  ot_month_h?: number;          // giới hạn tăng ca mỗi tháng (giờ/người), mặc định 40
  early_max_h?: number;         // trộn sớm trước ca tối đa (giờ), mặc định 0 = không đề xuất
  early_step_h?: number;        // bước thử trộn sớm (giờ), mặc định 1
  groups?: string[];            // nhóm máy được phép đề xuất tăng ca (mặc định: mọi nhóm có việc)
  mode?: 'due' | 'fastest';     // due: chỉ thêm giờ đến khi kịp ngày chốt / hạn giao; fastest: thêm đến khi lợi ích < ngưỡng
  min_gain_day_per_10h?: number; // fastest: tối thiểu số ngày rút ngắn cho mỗi 10 giờ công thêm, mặc định 0,1
  min_step_gain_day?: number;   // fastest: mỗi bước thêm giờ phải rút ngắn ít nhất số ngày này, mặc định 0,1
  max_evals?: number;           // giới hạn số lần chạy bộ xếp lịch, mặc định 600
  reorder?: boolean;            // thử đổi thứ tự lô, mặc định true
  time_ms?: number;             // chặn an toàn thời gian tìm (ms), mặc định 15000; kết quả phụ thuộc số lần thử, không phụ thuộc tốc độ máy chủ
  reorder_evals?: number;       // số lần thử đổi thứ tự lô, mặc định 200 (Xếp lịch và thẻ Tối ưu dùng cùng số → cùng kết quả)
  levers?: boolean;             // thử thêm giờ (tăng ca / trộn sớm), mặc định true
};
export type Score = { unplaced: number; late: number; lateLots: number; makespan: number; setup: number; flow: number };
export type GroupLoad = { group: string; machines: string[]; busyDays: number; util: number; waitSilicone_h: number };
export type Proposal = { group: string; machines: string[]; extra_min: number; persons: number; days: number; hours: number; overMonth: boolean };
export type WhatIf = { label: string; days: number; gain: number };
export type OptResult = {
  orders: Order[]; flow: FlowCfg; sch: Schedule; score: Score;
  base: { sch: Schedule; score: Score };       // lịch theo cách xếp thường (không đổi thứ tự, không thêm giờ)
  ordered: { sch: Schedule; score: Score; ords: Order[] };    // sau khi tối ưu thứ tự lô (chưa thêm giờ)
  bottleneck: GroupLoad[]; proposals: Proposal[]; early_h: number; whatIf: WhatIf[]; evals: number; log: string[];
};

const GROUP_NAME: Record<string, string> = {
  MIXER: 'Máy trộn silicone', BUNCHER: 'Máy bện', EXTRUDER_SI: 'Line silicone', TWISTER: 'Máy xoắn', EXTRUDER_TP: 'Line vỏ', PACKER: 'Máy đóng gói',
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
  const otMax = lv.ot_max_min ?? 240, otStep = lv.ot_step_min ?? 60, monthH = lv.ot_month_h ?? 40;
  const earlyMax = lv.early_max_h ?? 0, earlyStep = lv.early_step_h ?? 1;
  const mode = lv.mode ?? 'due', minGain = lv.min_gain_day_per_10h ?? 0.1;
  const mpo = Math.max(1, Number(ctx.cfg.machines_per_operator) || 1);
  const F0 = flowOf(ctx.cfg);
  let evals = 0;
  const t0 = Date.now(), timeMs = lv.time_ms ?? 15000;
  const over = (budget = maxEvals) => evals >= budget || Date.now() - t0 > timeMs;
  const run = (ords: Order[], flow: FlowCfg) => {
    evals++;
    const sch = schedule(ords, { ...ctx, cfg: { ...ctx.cfg, flow } }, opt);
    return { sch, score: scoreOf(sch, ctx.cal, ords), ords };
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
  const reorder = (flow: FlowCfg, budget: number) => {
    if (lv.reorder === false) return;
    for (let pass = 0, improved = true; improved && pass < 3; pass++) {
      improved = false;
      for (let i = 0; i < seqd.length; i++) for (let j = 0; j < seqd.length; j++) {
        if (i === j || over(budget)) continue;
        if (seqd[i].prio !== seqd[j].prio) continue;
        const cand = [...seqd];
        const [x] = cand.splice(i, 1); cand.splice(j, 0, x);
        const r = run(withSeq(cand), flow);
        if (cmpScore(r.score, cur.score) < 0) { cur = r; seqd = cand; improved = true; log.push(`Thứ tự: đưa ${x.label} sang vị trí ${j + 1} → ${r.score.makespan.toFixed(2)} ngày, trễ ${r.score.late}`); }
      }
    }
  };
  reorder(baseFlow, Math.min(maxEvals, 1 + (lv.reorder_evals ?? 200)));
  const ordered = cur;

  // 2. Máy cổ chai và "nếu thêm giờ thì sao"
  const groups = (lv.groups ?? [...new Set(ctx.machines.map((m) => m.machine_type))])
    .filter((g) => cur.sch.slots.some((s) => ctx.machines.find((m) => m.code === s.machine)?.machine_type === g));
  const machinesOf = (g: string) => ctx.machines.filter((m) => m.machine_type === g && m.status !== 'OFF').map((m) => m.code);
  const personsOf = (g: string) => Math.ceil(machinesOf(g).length / mpo);
  const hasMixer = ctx.machines.some((m) => m.machine_type === 'MIXER');
  type Lever = { kind: 'ot'; group: string } | { kind: 'early' };
  const levers: Lever[] = [...groups.map((g) => ({ kind: 'ot' as const, group: g })), ...(hasMixer && earlyMax > 0 ? [{ kind: 'early' as const }] : [])];
  const apply = (flow: FlowCfg, ls: Lever[]): FlowCfg | null => {
    // đề xuất mới thay tăng ca đang áp dụng: tính cho mọi ngày của kế hoạch (khoảng ngày chọn khi đề xuất)
    const f: FlowCfg = { ...flow, extra_min: { ...(flow.extra_min ?? {}) }, ot_from: null, ot_until: null };
    for (const l of ls) {
      if (l.kind === 'early') { const e = Number(f.mix_early_h ?? 0) + earlyStep; if (e > earlyMax + 1e-9) return null; f.mix_early_h = e; }
      else for (const m of machinesOf(l.group)) { const e = Number(f.extra_min![m] ?? 0) + otStep; if (e > otMax + 1e-9) return null; f.extra_min![m] = e; }
    }
    return f;
  };
  const cost = (ls: Lever[], days: number) => ls.reduce((a, l) => a + (l.kind === 'early' ? earlyStep : (otStep / 60) * personsOf(l.group)), 0) * Math.max(1, days);
  const whatIf: WhatIf[] = [];
  for (const l of levers) {
    const f = apply(baseFlow, [l]); if (!f || over()) continue;
    const r = run(cur.ords, f);
    whatIf.push({ label: l.kind === 'early' ? `Trộn sớm ${earlyStep} giờ trước ca` : `${groupName(l.group)} thêm ${otStep / 60} giờ/ngày`, days: r.score.makespan, gain: cur.score.makespan - r.score.makespan });
  }

  // 3. Thêm giờ từng bước: thử mọi tổ hợp 1–3 nhóm, chọn bước lợi nhất trên mỗi giờ công
  let flow = baseFlow;
  const combos: Lever[][] = [];
  for (let a = 0; a < levers.length; a++) {
    combos.push([levers[a]]);
    for (let b = a + 1; b < levers.length; b++) {
      combos.push([levers[a], levers[b]]);
      for (let c = b + 1; c < levers.length; c++) combos.push([levers[a], levers[b], levers[c]]);
    }
  }
  const need = () => lv.levers !== false && (mode === 'fastest' || cur.score.late > 0 || cur.score.unplaced > 0);
  while (need() && !over()) {
    // chọn bước có lợi nhất trên mỗi giờ công: trước hết bớt trễ hạn, sau đó rút ngắn ngày xong
    let bestR: { r: typeof cur; f: FlowCfg; ls: Lever[]; k1: number; k2: number } | null = null;
    for (const ls of combos) {
      if (over()) break;
      const f = apply(flow, ls); if (!f) continue;
      const r = run(cur.ords, f);
      if (cmpScore(r.score, cur.score) >= 0) continue;
      const c = Math.max(1e-9, cost(ls, r.score.makespan));
      const gainLate = cur.score.late - r.score.late + (cur.score.unplaced - r.score.unplaced) * 1000;
      const gainDays = cur.score.makespan - r.score.makespan;
      if (mode === 'fastest' && gainLate <= 0 && ((gainDays * 10) / c < minGain || gainDays < (lv.min_step_gain_day ?? 0.1))) continue;
      if (mode === 'due' && gainLate <= 0 && gainDays <= 0.01) continue;
      const k1 = gainLate / c, k2 = gainDays / c;
      if (!bestR || k1 > bestR.k1 + 1e-12 || (Math.abs(k1 - bestR.k1) <= 1e-12 && k2 > bestR.k2)) bestR = { r, f, ls, k1, k2 };
    }
    if (!bestR) break;
    cur = bestR.r; flow = bestR.f;
    log.push(`Thêm giờ: ${bestR.ls.map((l) => l.kind === 'early' ? `trộn sớm +${earlyStep} giờ` : `${groupName(l.group)} +${otStep} phút/ngày`).join(' + ')} → ${cur.score.makespan.toFixed(2)} ngày, trễ ${cur.score.late}`);
  }
  if (flow !== baseFlow) reorder(flow, maxEvals);

  // Đề xuất: giờ tăng ca từng nhóm, số người, số ngày cần, kiểm giới hạn tháng
  const proposals: Proposal[] = [];
  const DAY = cur.sch.S * cur.sch.SPD;
  for (const g of groups) {
    const ms = machinesOf(g);
    const ex = Math.max(0, ...ms.map((m) => Number(flow.extra_min?.[m] ?? 0)));
    if (ex <= 0) continue;
    const days = new Set(cur.sch.slots.filter((s) => ms.includes(s.machine)).map((s) => Math.floor(s.start / DAY))).size;
    const persons = personsOf(g);
    const hours = (ex / 60) * persons * days;
    proposals.push({ group: g, machines: ms, extra_min: ex, persons, days, hours, overMonth: (ex / 60) * days > monthH + 1e-9 });
  }
  return {
    orders: cur.ords, flow, sch: cur.sch, score: cur.score, base, ordered, bottleneck: groupLoads(ordered.sch, ctx.machines),
    proposals, early_h: Number(flow.mix_early_h ?? 0), whatIf, evals, log,
  };
}
