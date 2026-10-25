// Bộ xếp lịch máy theo máy và theo người đứng máy (thuần tính toán, không gọi database).
// Đơn vị thời gian: "phút xếp lịch". Mỗi ca có S phút xếp lịch = phút chạy × tỷ lệ xếp lịch (%), mỗi ngày SPD ca.
// Quy tắc (BR-KH-04..07): đơn gấp → hạn giao sớm → màu sáng trước tối; gối đầu công đoạn ≥ 1 ca;
// chỉ xếp khi có người đủ tay nghề rảnh; xếp lại giữ nguyên phần trước mốc (đã chạy + vùng khóa).

export type Op = 'CD1' | 'CD2' | 'CD3' | 'CD5';
export const OPS: Op[] = ['CD1', 'CD2', 'CD3', 'CD5'];

export type ShiftCfg = { code: string; start_time: string; end_time: string; break_min: number; active: boolean };
export type RateCfg = { op_code: string; label: string; unit: string; rate_small: number; rate_large: number; confirmed: boolean; sort: number };
export type ChangeoverCfg = { code: string; op_code: string; label: string; minutes: number; sort: number };
export type Config = {
  fill_pct: number; frozen_days: number; cutoff_time: string; downtime_reason_min: number; plc_dev_pct: number;
  auto_shifts: number; plc_loss_min: number; machines_per_operator: number;
  shifts: ShiftCfg[]; rates: RateCfg[]; changeovers: ChangeoverCfg[];
};
export type MachineInfo = { code: string; name: string; machine_type: string; data_mode: string; tag_count: number; operators: string[] };
export type OperatorInfo = { code: string; job: string; extra: string | null; is_deputy: boolean; keeps_fg: boolean; skills: string[]; learning: string[] };

export type Order = {
  id: string;            // plan_line_id
  label: string;         // D01, D02…
  product_code: string;
  product_name: string;
  group: string;
  size: number;          // mm² danh định
  cores: string[];       // màu từng lõi
  sheath: string | null; // màu vỏ (null: không có vỏ)
  sil: boolean;          // cách điện silicone (line silicone); khác: line vỏ
  shield: boolean;       // chống nhiễu: xoắn + quấn AL/PET liền dây
  route: Op[];
  qty: number;
  due: string | null;    // yyyy-mm-dd
  prio: number;          // 0 gấp, 1 thường
  source: string;
};

export type Task = {
  id: number; key: string; order: Order; oi: number; op: Op; k: number; color: string | null;
  m: number; full: number; rate: number; run: number;
};
export type Slot = {
  id?: string; key: string; lineId: string; op: Op; color: string | null; machine: string; operator: string | null; lane: number;
  start: number; runStart: number; end: number; setup: number; meters: number; rate: number; speed: number;
  reason: string; why: string; part: boolean;
};
export type PrevSchedule = { S: number; SPD: number; slots: Slot[] };
export type OpSpan = { start: number; end: number; left: number };
export type Schedule = {
  slots: Slot[]; byMachine: Map<string, Slot[]>; opDone: Map<string, OpSpan>; unplaced: Task[];
  S: number; SPD: number; RUN: number;
};

// ---------------- Lịch làm việc ----------------
export const toMin = (h: string) => { const [a, b] = h.slice(0, 5).split(':').map(Number); return a * 60 + b; };
export const shiftRun = (s: Pick<ShiftCfg, 'start_time' | 'end_time' | 'break_min'>) =>
  (((toMin(s.end_time) - toMin(s.start_time)) + 1440) % 1440 || 1440) - Number(s.break_min);

export type Calendar = { S: number; SPD: number; RUN: number; shifts: ShiftCfg[]; base: string; days: string[] };

const iso = (d: Date) => d.toISOString().slice(0, 10);
const parse = (s: string) => new Date(s + 'T00:00:00Z');
export const addDays = (s: string, n: number) => { const d = parse(s); d.setUTCDate(d.getUTCDate() + n); return iso(d); };
export const isWorkday = (s: string) => parse(s).getUTCDay() !== 0; // nghỉ Chủ nhật
export const nextWorkday = (s: string) => { let d = s; while (!isWorkday(d)) d = addDays(d, 1); return d; };
// Số ngày làm việc trong [a, b)
export function workdaysBetween(a: string, b: string): number {
  if (b <= a) return 0;
  let n = 0;
  for (let d = a; d < b; d = addDays(d, 1)) if (isWorkday(d)) n++;
  return n;
}

export function makeCalendar(cfg: Pick<Config, 'fill_pct' | 'shifts'>, base: string, horizon = 260): Calendar {
  const shifts = cfg.shifts.filter((s) => s.active).sort((a, b) => a.code.localeCompare(b.code));
  const used = shifts.length ? shifts : cfg.shifts.filter((s) => s.code === 'A');
  const SPD = used.length;
  const RUN = Math.round(used.reduce((a, s) => a + shiftRun(s), 0) / SPD);
  const S = Math.round(RUN * Number(cfg.fill_pct) / 100);
  const days: string[] = [];
  for (let d = nextWorkday(base); days.length < horizon; d = addDays(d, 1)) if (isWorkday(d)) days.push(d);
  return { S, SPD, RUN, shifts: used, base: days[0], days };
}
// Chỉ số ngày làm việc của một ngày (ngày nghỉ → ngày làm việc kế tiếp); trước ngày gốc → số âm
export function dayIndex(cal: Calendar, date: string): number {
  if (date < cal.base) return -workdaysBetween(date, cal.base);
  return workdaysBetween(cal.base, date);
}
export const shiftDate = (cal: Calendar, s: number) => cal.days[Math.min(Math.max(0, Math.floor(s / cal.SPD)), cal.days.length - 1)];
export const shiftCode = (cal: Calendar, s: number) => cal.shifts[((s % cal.SPD) + cal.SPD) % cal.SPD].code;

// ---------------- Màu ----------------
const COLOR_KEYS: [RegExp, number, string][] = [
  [/trắng|white|ral\s*90(01|03|10|16)/i, 0, '#f4f4f4'], [/vàng|yellow|ral\s*1/i, 1, '#f2c200'], [/xám|ghi|gray|grey|ral\s*7/i, 2, '#9aa0a6'],
  [/cam|orange|ral\s*2/i, 3, '#f08a24'], [/đỏ|red|ral\s*3/i, 4, '#d93025'], [/xanh lá|green|ral\s*6/i, 5, '#2e8b57'],
  [/xanh|blue|ral\s*5/i, 6, '#1a5fd0'], [/nâu|brown|ral\s*8/i, 7, '#7a4a24'], [/đen|black|ral\s*9005/i, 8, '#1d1d1d'],
];
export function colorRank(c: string | null | undefined): number {
  if (!c) return 9;
  const hit = COLOR_KEYS.find(([re]) => re.test(c));
  return hit ? hit[1] : 5;
}
export function colorHex(c: string | null | undefined): string {
  if (!c) return 'transparent';
  const hit = COLOR_KEYS.find(([re]) => re.test(c));
  return hit ? hit[2] : '#8a8f94';
}

// ---------------- Máy và công đoạn ----------------
export const OP_NAME: Record<Op, string> = { CD1: 'Bện ruột dẫn', CD2: 'Bọc cách điện', CD3: 'Xoắn / ghép lõi', CD5: 'Bọc vỏ' };
export const OP_SHORT: Record<Op, string> = { CD1: 'Bện', CD2: 'Bọc cách điện', CD3: 'Xoắn (+ AL/PET)', CD5: 'Bọc vỏ' };
export const UNIT: Record<Op, string> = { CD1: 'm lõi', CD2: 'm lõi', CD3: 'm cáp', CD5: 'm cáp' };
export const BOBBIN: Record<Op, number> = { CD1: 10000, CD2: 10000, CD3: 5000, CD5: 5000 }; // giả định m/bobin
export const opName = (op: Op, o: Pick<Order, 'shield' | 'sil'>) =>
  op === 'CD3' && o.shield ? 'Xoắn + quấn AL/PET' : op === 'CD2' ? (o.sil ? 'Bọc cách điện silicone' : 'Bọc cách điện (line vỏ)') : OP_NAME[op];
export const MACHINE_OPS: Record<string, Op[]> = { BUNCHER: ['CD1'], EXTRUDER_SI: ['CD2'], TWISTER: ['CD3'], EXTRUDER_TP: ['CD2', 'CD5'] };
export function canRun(machineType: string, t: Pick<Task, 'op' | 'order'>): boolean {
  if (t.op === 'CD2') return t.order.sil ? machineType === 'EXTRUDER_SI' : machineType === 'EXTRUDER_TP';
  return (MACHINE_OPS[machineType] ?? []).includes(t.op);
}

export function speedOf(cfg: Pick<Config, 'rates'>, op: Op, o: Pick<Order, 'size' | 'shield'>): number {
  const big = o.size >= 2.5;
  const r = (code: string) => { const x = cfg.rates.find((y) => y.op_code === code); return x ? Number(big ? x.rate_large : x.rate_small) : 50; };
  if (op === 'CD3' && o.shield) return Math.min(r('CD3'), r('CD4'));
  return r(op);
}

export function buildTasks(orders: Order[], cfg: Pick<Config, 'rates'>): Task[] {
  const tasks: Task[] = [];
  orders.forEach((o, oi) => {
    o.route.forEach((op, k) => {
      const base = { order: o, oi, op, k };
      if (op === 'CD2') {
        // gộp lõi cùng màu thành 1 việc (chạy liền)
        const counts = new Map<string, number>();
        o.cores.forEach((c) => counts.set(c, (counts.get(c) ?? 0) + 1));
        [...counts.entries()].sort((a, b) => colorRank(a[0]) - colorRank(b[0]))
          .forEach(([c, n]) => tasks.push({ ...base, color: c, m: o.qty * n } as Task));
      } else if (op === 'CD1') tasks.push({ ...base, color: null, m: o.qty * Math.max(1, o.cores.length) } as Task);
      else if (op === 'CD5') tasks.push({ ...base, color: o.sheath, m: o.qty } as Task);
      else tasks.push({ ...base, color: null, m: o.qty } as Task);
    });
  });
  tasks.forEach((t, i) => {
    t.id = i; t.key = `${t.order.id}|${t.op}|${t.color ?? ''}`; t.full = t.m;
    t.rate = speedOf(cfg, t.op, t.order); t.run = t.m / t.rate;
  });
  return tasks;
}

type Prev = { order: Order; op: Op; color: string | null } | null;
function changeover(cfg: Pick<Config, 'changeovers'>, prev: Prev, t: { order: Order; op: Op; color: string | null }): [number, string] {
  if (!prev) return [0, ''];
  const P = (code: string) => Number(cfg.changeovers.find((c) => c.code === code)?.minutes ?? 30);
  if (prev.op !== t.op) return [P('SH_CODE'), 'đổi công đoạn, thay khuôn'];
  if (t.op === 'CD2') {
    if (prev.order.size !== t.order.size || prev.order.sil !== t.order.sil) return [P('INS_SIZE'), 'đổi cỡ ruột, thay khuôn'];
    if (prev.color === t.color) return [0, ''];
    return colorRank(t.color) > colorRank(prev.color)
      ? [P('INS_UP'), `đổi màu ${prev.color} → ${t.color}, sáng sang tối`]
      : [P('INS_DOWN'), `đổi màu ${prev.color} → ${t.color}, tối sang sáng phải purge`];
  }
  if (t.op === 'CD5') {
    if (prev.order.product_code === t.order.product_code) return prev.color === t.color ? [0, ''] : [P('SH_COLOR'), 'đổi màu vỏ'];
    return [P('SH_CODE'), 'đổi mã, thay khuôn và chỉnh in'];
  }
  if (t.op === 'CD1') return prev.order.size === t.order.size ? [0, ''] : [P('BUN_SIZE'), 'đổi cỡ ruột'];
  return prev.order.product_code === t.order.product_code ? [0, ''] : [P('TWS_CODE'), 'đổi mã sản phẩm'];
}

export type ScheduleOpts = {
  from?: PrevSchedule | null;
  boundary?: number;                 // phút xếp lịch: trước mốc giữ nguyên lịch cũ
  split?: boolean;                   // tách việc đang chạy qua mốc (đơn gấp chen vùng khóa)
  credit?: Map<string, number>;      // mét chưa làm được ở ca đã qua (theo báo cáo ca) cộng lại vào việc
};

export function schedule(
  orders: Order[],
  ctx: { cfg: Config; cal: Calendar; machines: MachineInfo[]; operators: OperatorInfo[] },
  opt: ScheduleOpts = {},
): Schedule {
  const { cfg, cal } = ctx;
  const S = cal.S, SPD = cal.SPD;
  const tasks = buildTasks(orders, cfg);
  const byKey = new Map(tasks.map((t) => [t.key, t]));
  const orderById = new Map(orders.map((o) => [o.id, o]));
  const machines = ctx.machines.map((m) => ({ ...m, free: 0, last: null as Prev, slots: [] as Slot[] }));
  const cap = Math.max(1, Number(cfg.machines_per_operator) || 1);
  const workers = ctx.operators.filter((w) => w.skills.length).map((w) => ({ ...w, lanes: Array(cap).fill(0) as number[] }));
  const B = opt.boundary ?? 0;

  if (opt.from) {
    const k = (S * SPD) / (opt.from.S * opt.from.SPD); // giữ vị trí theo ngày khi đổi ca hoặc tỷ lệ xếp lịch
    for (const sl of opt.from.slots) {
      const t = byKey.get(sl.key);
      const m = machines.find((x) => x.code === sl.machine);
      if (!t || !m) continue;
      const start = sl.start * k, rs = sl.runStart * k, end = sl.end * k, rate = sl.rate / k;
      if (start >= B) continue;
      let ns: Slot;
      if (opt.split && end > B) {
        if (rs >= B) continue;
        const mm = (B - rs) * rate;
        ns = { ...sl, start, runStart: rs, end: B, rate, meters: mm, part: true, reason: 'Phần đã chạy trước khi tách lệnh, phần còn lại xếp sau đơn gấp' };
        t.m -= mm;
      } else {
        ns = { ...sl, start, runStart: rs, end, rate };
        t.m -= sl.meters;
      }
      m.slots.push(ns);
      const w = workers.find((x) => x.code === sl.operator);
      if (w) { const li = Math.min(sl.lane || 0, cap - 1); w.lanes[li] = Math.max(w.lanes[li], ns.end); ns.lane = li; }
    }
  }
  if (opt.credit) for (const [key, mm] of opt.credit) { const t = byKey.get(key); if (t) t.m += mm; } // thiếu thì cộng, vượt thì trừ

  const pending = new Set<number>();
  for (const t of tasks) { if (t.m > 1) { t.run = t.m / t.rate; pending.add(t.id); } else t.m = 0; }
  for (const m of machines) {
    m.slots.sort((a, b) => a.start - b.start);
    const l = m.slots[m.slots.length - 1];
    m.free = Math.max(B, l ? l.end : 0);
    m.last = l ? { order: orderById.get(l.lineId)!, op: l.op, color: l.color } : null;
    if (m.last && !m.last.order) m.last = null;
  }
  for (const w of workers) w.lanes = w.lanes.map((x) => Math.max(B, x));

  const opDone = new Map<string, OpSpan>();
  const key = (lineId: string, op: Op) => lineId + '|' + op;
  orders.forEach((o) => o.route.forEach((op) => opDone.set(key(o.id, op), { start: Infinity, end: 0, left: 0 })));
  for (const m of machines) for (const sl of m.slots) {
    const d = opDone.get(key(sl.lineId, sl.op)); if (!d) continue;
    d.start = Math.min(d.start, sl.runStart); d.end = Math.max(d.end, sl.end);
  }
  for (const id of pending) opDone.get(key(tasks[id].order.id, tasks[id].op))!.left++;

  const ready = (t: Task): number | null => {
    if (t.k === 0) return 0;
    const prevOp = t.order.route[t.k - 1];
    const p = opDone.get(key(t.order.id, prevOp))!;
    if (p.left > 0) return null;
    if (p.end === 0) return 0;
    return Math.max(p.start + S, p.end + S - t.run);
  };
  const laneFor = (code: string) => {
    let best: { w: (typeof workers)[number]; li: number; f: number } | null = null;
    for (const w of workers) if (w.skills.includes(code)) w.lanes.forEach((f, li) => { if (!best || f < best.f) best = { w, li, f }; });
    return best as { w: (typeof workers)[number]; li: number; f: number } | null;
  };
  const due = (o: Order) => o.due ?? '9999-12-31';
  const byPrio = (a: Order, b: Order) => a.prio - b.prio || due(a).localeCompare(due(b));

  let guard = 0;
  while (pending.size && guard++ < 50000) {
    const opts: { m: (typeof machines)[number]; t: Task; r: number; st: number; rs: number; ln: NonNullable<ReturnType<typeof laneFor>> }[] = [];
    for (const m of machines) {
      const ln = laneFor(m.code); if (!ln) continue;
      const cands: { t: Task; r: number }[] = [];
      for (const id of pending) {
        const t = tasks[id];
        if (!canRun(m.machine_type, t)) continue;
        const r = ready(t); if (r !== null) cands.push({ t, r });
      }
      if (!cands.length) continue;
      const startOf = (x: { r: number }) => Math.max(m.free, x.r, ln.f);
      const minStart = Math.min(...cands.map(startOf));
      const pool = cands.filter((x) => startOf(x) <= minStart + S / 2);
      pool.sort((a, b) => byPrio(a.t.order, b.t.order) || colorRank(a.t.color) - colorRank(b.t.color) || a.t.id - b.t.id);
      const x = pool[0];
      const st0 = startOf(x);
      opts.push({ m, t: x.t, r: x.r, st: st0, rs: st0 + changeover(cfg, m.last, x.t)[0], ln });
    }
    if (!opts.length) break;
    // máy dùng chung người: trong nửa ca đầu, ưu tiên đơn gấp và hạn giao sớm
    const minRs = Math.min(...opts.map((o) => o.rs));
    const best = opts.filter((o) => o.rs <= minRs + S / 2)
      .sort((a, b) => byPrio(a.t.order, b.t.order) || a.rs - b.rs)[0];
    const { m, t, ln } = best;
    const [su, why] = changeover(cfg, m.last, t);
    const prevOp = t.k > 0 ? t.order.route[t.k - 1] : null;
    const st0 = best.st;
    let reason: string;
    if (prevOp && st0 === best.r && best.r > m.free && best.r >= ln.f) reason = `Chờ ${OP_NAME[prevOp].toLowerCase()} của lệnh này chạy trước ít nhất 1 ca (gối đầu)`;
    else if (st0 === ln.f && ln.f > m.free) reason = `Chờ người: ${ln.w.code} đang đứng máy khác, xong việc mới sang máy này`;
    else reason = m.last ? 'Máy làm xong việc trước thì chạy tiếp' : 'Máy và người đều sẵn, chạy ngay';
    const end = st0 + su + t.run;
    m.slots.push({
      key: t.key, lineId: t.order.id, op: t.op, color: t.color, machine: m.code, operator: ln.w.code, lane: ln.li,
      start: st0, runStart: st0 + su, end, setup: su, meters: t.m, rate: t.rate, speed: t.rate, reason, why, part: false,
    });
    m.free = end; m.last = { order: t.order, op: t.op, color: t.color }; ln.w.lanes[ln.li] = end;
    const d = opDone.get(key(t.order.id, t.op))!;
    d.start = Math.min(d.start, st0 + su); d.end = Math.max(d.end, end); d.left--;
    pending.delete(t.id);
  }
  const byMachine = new Map(machines.map((m) => [m.code, m.slots.sort((a, b) => a.start - b.start)]));
  return { slots: machines.flatMap((m) => m.slots), byMachine, opDone, unplaced: [...pending].map((id) => tasks[id]), S, SPD, RUN: cal.RUN };
}

// ---------------- Ngày xong, tình trạng ----------------
export type Finish = { end: number; finS: number; finDate: string | null; slack: number | null; placed: boolean };
const dayDiff = (a: string, b: string) => Math.round((parse(a).getTime() - parse(b).getTime()) / 86400000);

export function finishInfo(sch: Pick<Schedule, 'opDone' | 'S' | 'SPD'>, cal: Calendar, orders: Order[]): Map<string, Finish> {
  const out = new Map<string, Finish>();
  for (const o of orders) {
    const last = o.route[o.route.length - 1];
    const d = sch.opDone.get(o.id + '|' + last);
    if (!d || d.end === 0 || d.left > 0) { out.set(o.id, { end: 0, finS: -1, finDate: null, slack: null, placed: false }); continue; }
    const finS = Math.floor((d.end + sch.S) / sch.S); // + 1 ca kiểm tra, đóng gói
    const di = Math.floor(finS / sch.SPD);
    const finDate = di < cal.days.length ? cal.days[di] : null;
    out.set(o.id, { end: d.end, finS, finDate, slack: o.due && finDate ? dayDiff(o.due, finDate) : null, placed: true });
  }
  return out;
}

// Mét theo từng ca của một khối trên máy
export function shiftPlan(slots: Slot[], s: number, S: number) {
  const s0 = s * S, s1 = s0 + S, rows: { sl: Slot; run: number; su: number; m: number }[] = [];
  for (const sl of slots) {
    const run = Math.max(0, Math.min(sl.end, s1) - Math.max(sl.runStart, s0));
    const su = Math.max(0, Math.min(sl.runStart, s1) - Math.max(sl.start, s0));
    if (run > 0.5 || su > 0.5) rows.push({ sl, run, su, m: run * sl.rate });
  }
  return rows;
}
