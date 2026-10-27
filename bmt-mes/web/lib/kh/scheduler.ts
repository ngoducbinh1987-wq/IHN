// Bộ xếp lịch máy theo máy và theo người đứng máy (thuần tính toán, không gọi database).
// Đơn vị thời gian: "phút xếp lịch". Mỗi ca có S phút xếp lịch = phút chạy × tỷ lệ xếp lịch (%), mỗi ngày SPD ca.
// Quy tắc (BR-KH-04..07): đơn gấp → hạn giao sớm → gom lô cùng cỡ ruột, cùng màu (trong khung gom lô) → màu sáng trước tối;
// gối đầu công đoạn ≥ 1 ca; chỉ xếp khi có người đủ tay nghề rảnh; xếp lại giữ nguyên phần trước mốc (đã chạy + vùng khóa).
// Tốc độ: máy chế độ Tự động (PLC) dùng tốc độ thực tế đo từ PLC (30 ngày, đủ ≥ PLC_MIN_RUN phút chạy);
// chế độ Nhập tay/Song song (hoặc PLC chưa đủ dữ liệu) dùng bảng tốc độ tự nhập của máy (master.machine_speeds);
// máy chưa khai báo dùng tốc độ mặc định theo công đoạn.

export type Op = 'CD1' | 'CD2' | 'CD3' | 'CD5';
export const OPS: Op[] = ['CD1', 'CD2', 'CD3', 'CD5'];

export type ShiftCfg = { code: string; start_time: string; end_time: string; break_min: number; active: boolean };
export type RateCfg = { op_code: string; label: string; unit: string; rate_small: number; rate_large: number; confirmed: boolean; sort: number };
export type ChangeoverCfg = { code: string; op_code: string; label: string; minutes: number; sort: number };
// Tốc độ khai báo ở phần Máy: riêng máy × công đoạn, có thể riêng theo mã sản phẩm / nhóm / mã lõi
export type SpeedCfg = {
  machine_code: string; op_code: string; product_id: string | null; group_code: string | null; core_code: string | null;
  std_mpm: number; rated_mpm: number | null; max_mpm: number | null; status: string; submitted_at?: string | null; label?: string | null;
};
// Tốc độ thực tế từ PLC: tổng mét và phút chạy 30 ngày theo máy × công đoạn × mã SP/nhóm/mã lõi
export type PlcSpeedCfg = { machine_code: string; op_code: string; product_id: string | null; group_code: string | null; core_code: string | null; meters: number; run_min: number; last_at?: string | null };
export const PLC_MIN_RUN = 120; // phút chạy tối thiểu để tin tốc độ PLC
export type Config = {
  fill_pct: number; frozen_days: number; cutoff_time: string; downtime_reason_min: number; plc_dev_pct: number;
  auto_shifts: number; plc_loss_min: number; machines_per_operator: number;
  shifts: ShiftCfg[]; rates: RateCfg[]; changeovers: ChangeoverCfg[]; workdays?: number[] | null;
  speeds?: SpeedCfg[];   // tốc độ theo máy (trống: dùng rates)
  plc_speeds?: PlcSpeedCfg[]; // tốc độ thực tế đo từ PLC (máy chế độ Tự động)
  group_days?: number;   // khung gom lô (ngày); 0 = không gom
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
  commit?: string | null; // ngày TP SX chốt (xếp lịch theo ngày này nếu có)
  prio: number;          // 0 gấp, 1 thường
  source: string;
  product_id?: string | null; // để chọn tốc độ khai báo riêng theo mã sản phẩm
  core?: string | null;       // mã lõi của spec (tốc độ riêng theo lõi)
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

export type Calendar = { S: number; SPD: number; RUN: number; shifts: ShiftCfg[]; base: string; days: string[]; wd: number[] };

const iso = (d: Date) => d.toISOString().slice(0, 10);
const parse = (s: string) => new Date(s + 'T00:00:00Z');
export const addDays = (s: string, n: number) => { const d = parse(s); d.setUTCDate(d.getUTCDate() + n); return iso(d); };
// Ngày làm việc trong tuần theo ISO: 1 = thứ 2 … 7 = Chủ nhật (Giám đốc đặt ở Cài đặt máy; mặc định nghỉ Chủ nhật)
export const DEFAULT_WD = [1, 2, 3, 4, 5, 6];
const isoDow = (s: string) => { const d = parse(s).getUTCDay(); return d === 0 ? 7 : d; };
export const isWorkday = (s: string, wd: number[] = DEFAULT_WD) => wd.includes(isoDow(s));
export const nextWorkday = (s: string, wd: number[] = DEFAULT_WD) => { let d = s; for (let i = 0; i < 14 && !isWorkday(d, wd); i++) d = addDays(d, 1); return d; };
export const prevWorkday = (s: string, wd: number[] = DEFAULT_WD) => { let d = addDays(s, -1); for (let i = 0; i < 14 && !isWorkday(d, wd); i++) d = addDays(d, -1); return d; };
// Số ngày làm việc trong [a, b)
export function workdaysBetween(a: string, b: string, wd: number[] = DEFAULT_WD): number {
  if (b <= a) return 0;
  let n = 0;
  for (let d = a; d < b; d = addDays(d, 1)) if (isWorkday(d, wd)) n++;
  return n;
}

export function makeCalendar(cfg: Pick<Config, 'fill_pct' | 'shifts'> & { workdays?: number[] | null }, base: string, horizon = 260): Calendar {
  const shifts = cfg.shifts.filter((s) => s.active).sort((a, b) => a.code.localeCompare(b.code));
  const used = shifts.length ? shifts : cfg.shifts.filter((s) => s.code === 'A');
  const SPD = used.length;
  const RUN = Math.round(used.reduce((a, s) => a + shiftRun(s), 0) / SPD);
  const S = Math.round(RUN * Number(cfg.fill_pct) / 100);
  const wd = cfg.workdays?.length ? cfg.workdays.map(Number) : DEFAULT_WD;
  const days: string[] = [];
  for (let d = nextWorkday(base, wd); days.length < horizon; d = addDays(d, 1)) if (isWorkday(d, wd)) days.push(d);
  return { S, SPD, RUN, shifts: used, base: days[0], days, wd };
}
// Chỉ số ngày làm việc của một ngày (ngày nghỉ → ngày làm việc kế tiếp); trước ngày gốc → số âm
export function dayIndex(cal: Calendar, date: string): number {
  if (date < cal.base) return -workdaysBetween(date, cal.base, cal.wd);
  return workdaysBetween(cal.base, date, cal.wd);
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

// Tốc độ mặc định theo công đoạn (Tham số xếp lịch): cỡ < 2,5 mm² và ≥ 2,5 mm²
const defRate = (cfg: Pick<Config, 'rates'>, code: string, o: Pick<Order, 'size'>) => {
  const x = cfg.rates.find((y) => y.op_code === code);
  return x ? Number(o.size >= 2.5 ? x.rate_large : x.rate_small) : 50;
};
export function speedOf(cfg: Pick<Config, 'rates'>, op: Op, o: Pick<Order, 'size' | 'shield'>): number {
  if (op === 'CD3' && o.shield) return Math.min(defRate(cfg, 'CD3', o), defRate(cfg, 'CD4', o));
  return defRate(cfg, op, o);
}

// Tốc độ khai báo của một máy cho một công đoạn (giống app.check_capacity):
// ưu tiên dòng riêng mã sản phẩm → nhóm + mã lõi → mã lõi → nhóm → chung của máy; cùng mức thì dòng đã duyệt, rồi dòng mới nhất.
// Tốc độ dùng = min(tốc độ chuẩn, danh định, tốc độ tối đa của dải hoạt động).
export type Speed = { v: number; src: 'PLC' | 'MAY' | 'MD'; pending: boolean; note?: string };
export function machineSpeed(cfg: Pick<Config, 'speeds'>, machine: string, op: string, o: Pick<Order, 'product_id' | 'group' | 'core'>): Speed | null {
  const rows = (cfg.speeds ?? []).filter((s) => s.machine_code === machine && s.op_code === op && s.status !== 'OBSOLETE'
    && (!s.product_id || s.product_id === o.product_id) && (!s.group_code || s.group_code === o.group) && (!s.core_code || s.core_code === o.core));
  if (!rows.length) return null;
  const rank = (s: SpeedCfg) => [s.product_id ? 1 : 0, s.group_code && s.core_code ? 1 : 0, s.core_code ? 1 : 0, s.group_code ? 1 : 0, s.status === 'APPROVED' ? 1 : 0];
  const best = rows.reduce((a, b) => {
    const ra = rank(a), rb = rank(b);
    for (let i = 0; i < ra.length; i++) if (ra[i] !== rb[i]) return rb[i] > ra[i] ? b : a;
    return String(b.submitted_at ?? '') > String(a.submitted_at ?? '') ? b : a;
  });
  const lim = [Number(best.std_mpm), Number(best.rated_mpm ?? best.std_mpm), Number(best.max_mpm ?? best.std_mpm)].filter((x) => x > 0);
  return lim.length ? { v: Math.min(...lim), src: 'MAY', pending: best.status !== 'APPROVED' } : null;
}
// Tốc độ thực tế PLC: cùng mã sản phẩm → cùng nhóm + mã lõi → cùng mã lõi (cỡ ruột); mỗi mức cần ≥ PLC_MIN_RUN phút chạy.
// Xoắn + quấn AL/PET chạy cùng lượt nên PLC đo được tốc độ chung (lấy cả dòng ghi công đoạn CD3 và CD4).
export function plcSpeed(cfg: Pick<Config, 'plc_speeds'>, machine: string, op: Op, o: Pick<Order, 'product_id' | 'group' | 'core'>): Speed | null {
  const ops = op === 'CD3' ? ['CD3', 'CD4'] : [op];
  const rows = (cfg.plc_speeds ?? []).filter((x) => x.machine_code === machine && ops.includes(x.op_code));
  const tiers: ((x: PlcSpeedCfg) => boolean)[] = [
    (x) => !!o.product_id && x.product_id === o.product_id,
    (x) => !!o.core && x.group_code === o.group && x.core_code === o.core,
    (x) => !!o.core && x.core_code === o.core,
  ];
  for (const f of tiers) {
    const sel = rows.filter(f);
    const m = sel.reduce((a, x) => a + Number(x.meters), 0), min = sel.reduce((a, x) => a + Number(x.run_min), 0);
    if (min >= PLC_MIN_RUN && m > 0) return { v: m / min, src: 'PLC', pending: false, note: `${Math.round(min)} phút chạy` };
  }
  return null;
}
// Tốc độ chạy một công đoạn trên một máy theo chế độ nhập dữ liệu của máy.
// Bảng tự nhập: xoắn có quấn AL/PET liền dây lấy tốc độ chậm hơn của hai bước.
export function rateOn(cfg: Pick<Config, 'rates' | 'speeds' | 'plc_speeds'>, machine: string, op: Op,
  o: Pick<Order, 'size' | 'shield' | 'product_id' | 'group' | 'core'>, mode = 'MANUAL'): Speed {
  if (mode === 'PLC') {
    const p = plcSpeed(cfg, machine, op, o);
    if (p) return p;
  }
  const one = (code: string): Speed => machineSpeed(cfg, machine, code, o) ?? { v: defRate(cfg, code, o), src: 'MD', pending: false };
  let r: Speed;
  if (op === 'CD3' && o.shield) {
    const a = one('CD3'), b = one('CD4');
    r = { v: Math.min(a.v, b.v), src: a.src === 'MAY' || b.src === 'MAY' ? 'MAY' : 'MD', pending: a.pending || b.pending };
  } else r = one(op);
  if (mode === 'PLC') r.note = 'máy chế độ tự động nhưng PLC chưa đủ dữ liệu';
  return r;
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
  keep?: Set<string>;                // lô TP SX đã duyệt lịch: giữ nguyên chỗ trên lịch máy (cả sau mốc)
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
  const machines = ctx.machines.map((m) => ({ ...m, free: 0, last: null as Prev, slots: [] as Slot[], blocks: [] as [number, number][] }));
  const cap = Math.max(1, Number(cfg.machines_per_operator) || 1);
  const workers = ctx.operators.filter((w) => w.skills.length)
    .map((w) => ({ ...w, lanes: Array(cap).fill(0) as number[], blocks: Array.from({ length: cap }, () => [] as [number, number][]) }));
  const B = opt.boundary ?? 0;
  const keep = opt.keep ?? new Set<string>();

  if (opt.from) {
    const k = (S * SPD) / (opt.from.S * opt.from.SPD); // giữ vị trí theo ngày khi đổi ca hoặc tỷ lệ xếp lịch
    for (const sl of opt.from.slots) {
      const t = byKey.get(sl.key);
      const m = machines.find((x) => x.code === sl.machine);
      if (!t || !m) continue;
      const start = sl.start * k, rs = sl.runStart * k, end = sl.end * k, rate = sl.rate / k;
      if (start >= B) {
        // Lô đã duyệt lịch: giữ chỗ (khối cố định trên máy và người), việc khác xếp vào khoảng trống trước/sau khối
        if (!keep.has(sl.lineId)) continue;
        const ns = { ...sl, start, runStart: rs, end, rate, reason: sl.reason.startsWith('Giữ chỗ') ? sl.reason : `Giữ chỗ (TP SX đã duyệt lịch lô) · ${sl.reason}` };
        t.m -= sl.meters;
        m.slots.push(ns); m.blocks.push([start, end]);
        const w = workers.find((x) => x.code === sl.operator);
        if (w) { const li = Math.min(sl.lane || 0, cap - 1); w.blocks[li].push([start, end]); ns.lane = li; }
        continue;
      }
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
    const before = m.slots.filter((x) => x.start < B);
    const l = before[before.length - 1];
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

  // Công đoạn trước đã chạy ≥ 1 ca và công đoạn này không xong trước công đoạn trước (run: phút chạy trên máy đang xét)
  const ready = (t: Task, run: number): number | null => {
    if (t.k === 0) return 0;
    const prevOp = t.order.route[t.k - 1];
    const p = opDone.get(key(t.order.id, prevOp))!;
    if (p.left > 0) return null;
    if (p.end === 0) return 0;
    return Math.max(p.start + S, p.end + S - run);
  };
  const spMemo = new Map<string, Speed>();
  const modeOf = new Map(ctx.machines.map((m) => [m.code, m.data_mode]));
  const spOf = (m: string, t: Task) => {
    const k = m + '|' + t.id;
    let v = spMemo.get(k);
    if (!v) { v = rateOn(cfg, m, t.op, t.order, modeOf.get(m)); spMemo.set(k, v); }
    return v;
  };
  const G = Math.max(0, Math.round(Number(cfg.group_days ?? 0)));
  const laneFor = (code: string) => {
    let best: { w: (typeof workers)[number]; li: number; f: number } | null = null;
    for (const w of workers) if (w.skills.includes(code)) w.lanes.forEach((f, li) => { if (!best || f < best.f) best = { w, li, f }; });
    return best as { w: (typeof workers)[number]; li: number; f: number } | null;
  };
  const due = (o: Order) => o.commit ?? o.due ?? '9999-12-31';
  const byPrio = (a: Order, b: Order) => a.prio - b.prio || due(a).localeCompare(due(b));
  type Cand = { t: Task; r: number; sp: Speed; run: number };
  // Chọn việc cho một máy trong các việc bắt đầu được gần như cùng lúc:
  // 1) lô dẫn đầu = đơn gấp → hạn giao sớm nhất → màu sáng; 2) các lô cùng mức gấp, hạn giao không muộn hơn lô dẫn đầu quá G ngày
  // được chạy trước nếu ít phút đổi máy hơn (gom cùng cỡ ruột, cùng màu, cùng mã); 3) bằng nhau: màu sáng trước, hạn sớm trước.
  const pick = (pool: Cand[], last: Prev): { x: Cand; lead: Cand; su: number } => {
    const lead = [...pool].sort((a, b) => byPrio(a.t.order, b.t.order) || colorRank(a.t.color) - colorRank(b.t.color) || a.t.id - b.t.id)[0];
    const leadDue = lead.t.order.commit ?? lead.t.order.due;
    const limit = G > 0 && leadDue ? addDays(leadDue, G) : leadDue ?? '9999-12-31';
    const ok = G > 0 ? pool.filter((c) => c.t.order.prio === lead.t.order.prio && due(c.t.order) <= limit) : [lead];
    const scored = ok.map((c) => ({ c, su: changeover(cfg, last, c.t)[0] }));
    scored.sort((a, b) => a.su - b.su || colorRank(a.c.t.color) - colorRank(b.c.t.color) || byPrio(a.c.t.order, b.c.t.order) || a.c.t.id - b.c.t.id);
    return { x: scored[0].c, lead, su: scored[0].su };
  };
  const what = (t: Task) => t.op === 'CD1' ? `cỡ ${t.order.size} mm²` : t.op === 'CD2' ? `cỡ ${t.order.size} mm², màu ${t.color}`
    : t.op === 'CD5' ? `mã ${t.order.product_code}, vỏ ${t.color}` : `mã ${t.order.product_code}`;

  let guard = 0;
  while (pending.size && guard++ < 50000) {
    const opts: { m: (typeof machines)[number]; t: Task; r: number; st: number; rs: number; sp: Speed; run: number; lead: Task; ln: NonNullable<ReturnType<typeof laneFor>> }[] = [];
    for (const m of machines) {
      const ln = laneFor(m.code); if (!ln) continue;
      const cands: Cand[] = [];
      for (const id of pending) {
        const t = tasks[id];
        if (!canRun(m.machine_type, t)) continue;
        const sp = spOf(m.code, t), run = t.m / sp.v;
        const r = ready(t, run); if (r !== null) cands.push({ t, r, sp, run });
      }
      if (!cands.length) continue;
      const startOf = (x: { r: number }) => Math.max(m.free, x.r, ln.f);
      const minStart = Math.min(...cands.map(startOf));
      const pool = cands.filter((x) => startOf(x) <= minStart + S / 2);
      const { x, lead, su } = pick(pool, m.last);
      const st0 = startOf(x);
      opts.push({ m, t: x.t, r: x.r, st: st0, rs: st0 + su, sp: x.sp, run: x.run, lead: lead.t, ln });
    }
    if (!opts.length) break;
    // máy dùng chung người: trong nửa ca đầu, ưu tiên đơn gấp và hạn giao sớm
    const minRs = Math.min(...opts.map((o) => o.rs));
    const best = opts.filter((o) => o.rs <= minRs + S / 2)
      .sort((a, b) => byPrio(a.t.order, b.t.order) || a.rs - b.rs)[0];
    const { m, t, ln, sp, run, lead } = best;
    const [su, why] = changeover(cfg, m.last, t);
    const prevOp = t.k > 0 ? t.order.route[t.k - 1] : null;
    // Tránh khối giữ chỗ của lô đã duyệt (máy và người): dời đến sau khối nếu chồng lên
    let st0 = best.st;
    for (let moved = true, g = 0; moved && g < 100; g++) {
      moved = false;
      const e0 = st0 + su + run;
      for (const b of [...m.blocks, ...ln.w.blocks[ln.li]]) if (st0 < b[1] && e0 > b[0]) { st0 = b[1]; moved = true; }
    }
    let reason: string;
    if (prevOp && st0 === best.r && best.r > m.free && best.r >= ln.f) reason = `Chờ ${OP_NAME[prevOp].toLowerCase()} của lệnh này chạy trước ít nhất 1 ca (gối đầu)`;
    else if (st0 === ln.f && ln.f > m.free) reason = `Chờ người: ${ln.w.code} đang đứng máy khác, xong việc mới sang máy này`;
    else reason = m.last ? 'Máy làm xong việc trước thì chạy tiếp' : 'Máy và người đều sẵn, chạy ngay';
    const dmy = (d: string | null) => d ? `${d.slice(8, 10)}/${d.slice(5, 7)}` : 'chưa có';
    if (st0 > best.st) reason += ' · Dời sau khối giữ chỗ của lô TP SX đã duyệt lịch';
    if (lead !== t) reason += ` · Gom lô: chạy liền ${what(t)} để giảm đổi máy (hạn ${dmy(t.order.due)}, trong khung ${G} ngày so với ${lead.order.label} hạn ${dmy(lead.order.due)})`;
    else if (m.last && su === 0 && m.last.order.id !== t.order.id) reason += ` · Cùng ${what(t)} với việc trước, không đổi máy`;
    const v1 = Math.round(sp.v * 10) / 10;
    if (sp.src === 'PLC') reason += ` · Tốc độ ${v1} m/phút thực tế PLC 30 ngày (${sp.note})`;
    else if (sp.src === 'MAY') reason += ` · Tốc độ ${v1} m/phút theo bảng tự nhập của máy${sp.pending ? ' (chưa duyệt)' : ''}${sp.note ? ', ' + sp.note : ''}`;
    else if (sp.note) reason += ` · Tốc độ mặc định theo công đoạn, ${sp.note}`;
    const end = st0 + su + run;
    m.slots.push({
      key: t.key, lineId: t.order.id, op: t.op, color: t.color, machine: m.code, operator: ln.w.code, lane: ln.li,
      start: st0, runStart: st0 + su, end, setup: su, meters: t.m, rate: sp.v, speed: sp.v, reason, why, part: false,
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
