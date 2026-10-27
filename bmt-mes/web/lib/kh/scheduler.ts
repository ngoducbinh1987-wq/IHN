// Bộ xếp lịch máy theo máy và theo người đứng máy (thuần tính toán, không gọi database).
// Đơn vị thời gian: "phút xếp lịch". Mỗi ca có S phút xếp lịch = phút chạy × tỷ lệ xếp lịch (%), mỗi ngày SPD ca.
// Quy tắc (BR-KH-04..07): đơn gấp → hạn giao sớm → gom lô cùng cỡ ruột, cùng màu (trong khung gom lô) → màu sáng trước tối;
// gối đầu công đoạn ≥ 1 ca; chỉ xếp khi có người đủ tay nghề rảnh; xếp lại giữ nguyên phần trước mốc (đã chạy + vùng khóa).
// Tốc độ: máy chế độ Tự động (PLC) dùng tốc độ thực tế đo từ PLC (30 ngày, đủ ≥ PLC_MIN_RUN phút chạy);
// chế độ Nhập tay/Song song (hoặc PLC chưa đủ dữ liệu) dùng bảng tốc độ tự nhập của máy (master.machine_speeds);
// máy chưa khai báo dùng tốc độ mặc định theo công đoạn.
// Trộn silicone (CD0, máy trộn trong phòng lạnh) khai báo năng lực theo kg/giờ: đổi ra mét cáp/phút theo kg hỗn hợp/km cáp (BOM CD0);
// trộn chỉ là tiền đề của bọc cách điện, bện không phải chờ trộn. Đóng gói (CD6) trên máy cuốn bobin gỗ là công đoạn cuối.

export type Op = 'CD0' | 'CD1' | 'CD2' | 'CD3' | 'CD5' | 'CD6';
export const OPS: Op[] = ['CD0', 'CD1', 'CD2', 'CD3', 'CD5', 'CD6'];

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
  flow?: FlowCfg;        // thông số dòng chảy (gối đầu theo bobin, máy trộn, hạn dùng silicone, tăng ca)
};
// Thông số dòng chảy: mọi con số của thuật toán đều lấy từ đây (không có số cố định trong code).
export type FlowCfg = {
  qc_min?: number;                              // phút chờ QC một bobin (trung vị thực tế; ban đầu 120)
  unit_m?: Partial<Record<Op, number>>;         // mét một bobin (đơn vị chuyển sang công đoạn sau) theo công đoạn
  safety_min?: Partial<Record<Op, number>>;     // đệm an toàn (phút) công đoạn này phải đi trước công đoạn sau (vd. tồn đệm ruột bện)
  pot_life_h?: number;                          // hạn dùng silicone đã pha lưu hóa (giờ)
  mix_batch_kg?: number;                        // kg một mẻ trộn
  mix_early_h?: number;                         // giờ máy trộn chạy trước giờ vào ca (trộn sẵn đệm)
  extra_min?: Record<string, number>;           // phút tăng ca mỗi ngày theo máy
};
export const FLOW_DEFAULT = { qc_min: 120, safety_min: {} as Partial<Record<Op, number>>, pot_life_h: 8, mix_batch_kg: 25, mix_early_h: 0, extra_min: {} as Record<string, number> };
export function flowOf(cfg: Pick<Config, 'flow'>) {
  const f = cfg.flow ?? {};
  return {
    qc_min: Math.max(0, Number(f.qc_min ?? FLOW_DEFAULT.qc_min)),
    unit_m: { ...BOBBIN, ...(f.unit_m ?? {}) } as Record<Op, number>,
    safety_min: { ...(f.safety_min ?? {}) } as Partial<Record<Op, number>>,
    pot_life_h: Math.max(0.25, Number(f.pot_life_h ?? FLOW_DEFAULT.pot_life_h)),
    mix_batch_kg: Math.max(1, Number(f.mix_batch_kg ?? FLOW_DEFAULT.mix_batch_kg)),
    mix_early_h: Math.max(0, Number(f.mix_early_h ?? 0)),
    extra_min: { ...(f.extra_min ?? {}) } as Record<string, number>,
  };
}
export type MachineInfo = {
  id?: string; code: string; name: string; machine_type: string; data_mode: string; tag_count: number; operators: string[];
  status?: string; status_since?: string | null; status_eta?: string | null; status_note?: string | null;
};
// Khoảng máy không chạy được (phút xếp lịch): hỏng / bảo dưỡng đến giờ dự kiến chạy lại, ngừng dùng, bảo dưỡng đã chốt giữ chỗ
export type Window = { machine: string; from: number; to: number; kind: 'DOWN' | 'MAINT' | 'OFF' | 'PM'; label: string };
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
  mix?: number | null;        // kg hỗn hợp silicone cần trộn / km cáp (BOM công đoạn CD0)
  seq?: number;               // thứ tự do bộ tối ưu chọn (sau mức gấp, trước hạn giao)
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
  mix?: MixLog;   // máy trộn làm nguồn cấp: năng lực, phần đã dùng, từng lần cấp (để kiểm hạn dùng)
};
// Nhật ký máy trộn (giờ thật tính từ 01/01/1970, theo giờ trên lịch): mỗi khoảng trộn và từng lần cấp cho line
export type MixLog = {
  kgh: number; pot_life_h: number;
  buckets: { r0: number; r1: number; t0: number; t1: number; cap: number; used: number; early: boolean }[];
  uses: { key: string; kg: number; mixR0: number; mixR1: number; useR: number }[];
  wait_min: Record<string, number>;   // phút line silicone chạy chậm/chờ vì máy trộn không cấp kịp
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
export const OP_NAME: Record<Op, string> = { CD0: 'Trộn silicone', CD1: 'Bện ruột dẫn', CD2: 'Bọc cách điện', CD3: 'Xoắn / ghép lõi', CD5: 'Bọc vỏ', CD6: 'Đóng gói' };
export const OP_SHORT: Record<Op, string> = { CD0: 'Trộn silicone', CD1: 'Bện', CD2: 'Bọc cách điện', CD3: 'Xoắn (+ AL/PET)', CD5: 'Bọc vỏ', CD6: 'Đóng gói' };
export const UNIT: Record<Op, string> = { CD0: 'm cáp', CD1: 'm lõi', CD2: 'm lõi', CD3: 'm cáp', CD5: 'm cáp', CD6: 'm cáp' };
export const BOBBIN: Record<Op, number> = { CD0: 5000, CD1: 10000, CD2: 10000, CD3: 5000, CD5: 5000, CD6: 500 }; // giả định m/bobin (đóng gói: bobin gỗ 500 m)
export const opName = (op: Op, o: Pick<Order, 'shield' | 'sil'>) =>
  op === 'CD3' && o.shield ? 'Xoắn + quấn AL/PET' : op === 'CD2' ? (o.sil ? 'Bọc cách điện silicone' : 'Bọc cách điện (line vỏ)') : OP_NAME[op];
export const MACHINE_OPS: Record<string, Op[]> = { MIXER: ['CD0'], BUNCHER: ['CD1'], EXTRUDER_SI: ['CD2'], TWISTER: ['CD3'], EXTRUDER_TP: ['CD2', 'CD5'], PACKER: ['CD6'] };
// Kg hỗn hợp trộn (kg/giờ) → mét cáp/phút theo kg/km cáp của mã
export const mixMpm = (kgh: number, o: Pick<Order, 'mix'>) => (Number(o.mix) > 0 ? (kgh / 60) / (Number(o.mix) / 1000) : 0);
// Công đoạn phải chạy trước (gối đầu): bọc cách điện chờ bện và trộn; công đoạn khác chờ công đoạn liền trước (bỏ qua trộn)
// supply = true: máy trộn là nguồn cấp theo nhịp line (không phải công đoạn chạy trước), bọc chỉ chờ bện
export function predOps(route: Op[], k: number, supply = false): Op[] {
  const op = route[k];
  if (op === 'CD0') return [];
  if (op === 'CD2') return route.slice(0, k).filter((x) => x === 'CD1' || (x === 'CD0' && !supply));
  for (let j = k - 1; j >= 0; j--) if (route[j] !== 'CD0') return [route[j]];
  return [];
}
export function canRun(machineType: string, t: Pick<Task, 'op' | 'order'>): boolean {
  if (t.op === 'CD2') return t.order.sil ? machineType === 'EXTRUDER_SI' : machineType === 'EXTRUDER_TP';
  return (MACHINE_OPS[machineType] ?? []).includes(t.op);
}

// Tốc độ mặc định theo công đoạn (Tham số xếp lịch): cỡ < 2,5 mm² và ≥ 2,5 mm²
const defRate = (cfg: Pick<Config, 'rates'>, code: string, o: Pick<Order, 'size'>) => {
  const x = cfg.rates.find((y) => y.op_code === code);
  return x ? Number(o.size >= 2.5 ? x.rate_large : x.rate_small) : 50;
};
export function speedOf(cfg: Pick<Config, 'rates'>, op: Op, o: Pick<Order, 'size' | 'shield' | 'mix'>): number {
  if (op === 'CD3' && o.shield) return Math.min(defRate(cfg, 'CD3', o), defRate(cfg, 'CD4', o));
  if (op === 'CD0') return mixMpm(defRate(cfg, 'CD0', o), o);
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
  o: Pick<Order, 'size' | 'shield' | 'product_id' | 'group' | 'core' | 'mix'>, mode = 'MANUAL'): Speed {
  if (op === 'CD0') {
    // Máy trộn: bảng tốc độ khai báo theo kg/giờ (không lấy PLC)
    const s = machineSpeed(cfg, machine, 'CD0', o) ?? { v: defRate(cfg, 'CD0', o), src: 'MD' as const, pending: false };
    const kgh = Math.round(s.v * 10) / 10, mix = Math.round(Number(o.mix) * 10) / 10;
    return { ...s, v: mixMpm(s.v, o), note: `trộn ${kgh} kg/giờ ÷ ${mix} kg hỗn hợp/km cáp` };
  }
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

// Năng lực một máy trộn (kg/giờ): bảng khai báo của máy (dòng chung, không riêng mã) → mặc định công đoạn CD0
export function mixerKgh(cfg: Pick<Config, 'rates' | 'speeds'>, machine: string): number {
  const s = machineSpeed(cfg, machine, 'CD0', { product_id: null, group: '', core: null });
  return s ? s.v : defRate(cfg, 'CD0', { size: 0 });
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
  if (t.op === 'CD0') return prev.order.product_code === t.order.product_code ? [0, ''] : [P('MIX_CODE'), 'đổi công thức trộn, vệ sinh trục cán'];
  if (t.op === 'CD6') return prev.order.product_code === t.order.product_code ? [0, ''] : [P('PK_CODE'), 'đổi mã, đổi bobin gỗ và nhãn'];
  return prev.order.product_code === t.order.product_code ? [0, ''] : [P('TWS_CODE'), 'đổi mã sản phẩm'];
}

export type ScheduleOpts = {
  from?: PrevSchedule | null;
  boundary?: number;                 // phút xếp lịch: trước mốc giữ nguyên lịch cũ
  split?: boolean;                   // tách việc đang chạy qua mốc (đơn gấp chen vùng khóa)
  credit?: Map<string, number>;      // mét chưa làm được ở ca đã qua (theo báo cáo ca) cộng lại vào việc
  keep?: Set<string>;                // lô TP SX đã duyệt lịch: giữ nguyên chỗ trên lịch máy (cả sau mốc)
  windows?: Window[];                // máy không chạy được: việc chưa chạy trong khoảng này xếp lại, việc mới tránh khoảng này
};
type Block = [number, number, string];
// Dời điểm bắt đầu qua các khối chồng lên [st, st + len); không còn chỗ (khối vô hạn) → Infinity
function fit(st: number, len: number, blocks: Block[]): { s: number; hit: string | null } {
  let s = st, hit: string | null = null;
  for (let moved = true, g = 0; moved && g < 200 && Number.isFinite(s); g++) {
    moved = false;
    for (const b of blocks) if (s < b[1] && s + len > b[0]) { s = b[1]; moved = true; hit = b[2]; }
  }
  return { s, hit };
}

export function schedule(
  orders: Order[],
  ctx: { cfg: Config; cal: Calendar; machines: MachineInfo[]; operators: OperatorInfo[] },
  opt: ScheduleOpts = {},
): Schedule {
  const { cfg, cal } = ctx;
  const S = cal.S, SPD = cal.SPD, DAY = S * SPD;
  const F = flowOf(cfg);
  const tasks = buildTasks(orders, cfg);
  const byKey = new Map(tasks.map((t) => [t.key, t]));
  const orderById = new Map(orders.map((o) => [o.id, o]));
  const machines = ctx.machines.map((m) => ({ ...m, free: 0, last: null as Prev, slots: [] as Slot[], blocks: [] as Block[] }));
  const cap = Math.max(1, Number(cfg.machines_per_operator) || 1);
  const workers = ctx.operators.filter((w) => w.skills.length)
    .map((w) => ({ ...w, lanes: Array(cap).fill(0) as number[], blocks: Array.from({ length: cap }, () => [] as Block[]) }));
  const B = opt.boundary ?? 0;
  const keep = opt.keep ?? new Set<string>();
  const wins = (opt.windows ?? []).filter((w) => w.to > w.from);
  const KEEP_LABEL = 'khối giữ chỗ của lô TP SX đã duyệt lịch';
  // Giờ thật → phút xếp lịch (QC, đệm an toàn là thời gian thật; phút xếp lịch = phút máy chạy)
  const shLenMin = cal.shifts.map((s) => shiftRun(s) + Number(s.break_min));
  const real2s = S / Math.max(1, shLenMin.reduce((a, x) => a + x, 0) / Math.max(1, shLenMin.length));
  const QC = F.qc_min * real2s;
  const SAFE = (op: Op) => Number(F.safety_min[op] ?? 0) * real2s;
  const dayRun = Math.max(1, cal.RUN * SPD);
  const boost = (code: string) => 1 + Math.max(0, Number(F.extra_min[code] ?? 0)) / dayRun;

  // Máy trộn = nguồn cấp silicone theo nhịp line bọc (không xếp như một công đoạn chạy trước)
  const mixers = ctx.machines.filter((m) => m.machine_type === 'MIXER');
  const supply = mixers.length > 0;
  const isSup = (t: Pick<Task, 'op'>) => supply && t.op === 'CD0';
  const usesMix = (t: Task) => supply && t.op === 'CD2' && t.order.route.includes('CD0') && Number(t.order.mix) > 0;
  const kgPerM = (o: Order) => Number(o.mix) / 1000 / Math.max(1, o.cores.length); // kg silicone / m lõi
  const preUse: { t: Task; from: number; to: number; rate: number }[] = [];

  if (opt.from) {
    const k = (S * SPD) / (opt.from.S * opt.from.SPD); // giữ vị trí theo ngày khi đổi ca hoặc tỷ lệ xếp lịch
    for (const sl of opt.from.slots) {
      const t = byKey.get(sl.key);
      const m = machines.find((x) => x.code === sl.machine);
      if (!t || !m) continue;
      const start = sl.start * k, rs = sl.runStart * k, end = sl.end * k, rate = sl.rate / k;
      if (supply && sl.op === 'CD0') {
        // Trộn đã làm trước mốc giữ lại (cắt tại mốc); sau mốc trộn lại theo nhịp line
        if (start < B) {
          const e = Math.min(end, B), mm = end > start ? sl.meters * (e - start) / (end - start) : sl.meters;
          m.slots.push({ ...sl, start, runStart: Math.min(rs, e), end: e, rate, meters: mm, part: e < end - 1e-9 || sl.part });
        }
        continue;
      }
      // Máy hỏng / ngừng dùng / bảo dưỡng giữ chỗ: phần chưa chạy trước khi máy dừng xếp lại (sang máy cùng loại hoặc sau khi chạy lại)
      const hit = wins.find((w) => w.machine === sl.machine && end > w.from && start < w.to);
      if (hit) {
        if (rs >= hit.from) continue;
        const mm = (hit.from - rs) * rate;
        const ns = { ...sl, start, runStart: rs, end: hit.from, rate, meters: mm, part: true, reason: `Phần đã chạy trước khi ${hit.label}, phần còn lại xếp lại` };
        t.m -= mm;
        m.slots.push(ns);
        if (usesMix(t) && ns.end > B) preUse.push({ t, from: Math.max(B, rs), to: ns.end, rate });
        const w = workers.find((x) => x.code === sl.operator);
        if (w) { const li = Math.min(sl.lane || 0, cap - 1); w.lanes[li] = Math.max(w.lanes[li], ns.end); ns.lane = li; }
        continue;
      }
      if (start >= B) {
        // Lô đã duyệt lịch: giữ chỗ (khối cố định trên máy và người), việc khác xếp vào khoảng trống trước/sau khối
        if (!keep.has(sl.lineId)) continue;
        const ns = { ...sl, start, runStart: rs, end, rate, reason: sl.reason.startsWith('Giữ chỗ') ? sl.reason : `Giữ chỗ (TP SX đã duyệt lịch lô) · ${sl.reason}` };
        t.m -= sl.meters;
        m.slots.push(ns); m.blocks.push([start, end, KEEP_LABEL]);
        if (usesMix(t)) preUse.push({ t, from: rs, to: end, rate });
        const w = workers.find((x) => x.code === sl.operator);
        if (w) { const li = Math.min(sl.lane || 0, cap - 1); w.blocks[li].push([start, end, KEEP_LABEL]); ns.lane = li; }
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
        if (usesMix(t) && end > B) preUse.push({ t, from: Math.max(B, rs), to: end, rate });
      }
      m.slots.push(ns);
      const w = workers.find((x) => x.code === sl.operator);
      if (w) { const li = Math.min(sl.lane || 0, cap - 1); w.lanes[li] = Math.max(w.lanes[li], ns.end); ns.lane = li; }
    }
  }
  if (opt.credit) for (const [key, mm] of opt.credit) { const t = byKey.get(key); if (t && !isSup(t)) t.m += mm; } // thiếu thì cộng, vượt thì trừ
  for (const w of wins) machines.find((m) => m.code === w.machine)?.blocks.push([w.from, w.to, w.label]);

  const pending = new Set<number>();
  for (const t of tasks) {
    if (isSup(t)) continue;
    if (t.m > 1) { t.run = t.m / t.rate; pending.add(t.id); } else t.m = 0;
  }
  const dead = new Set<number>(); // việc không thể chạy (vd. không có silicone): việc sau cũng không xếp
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
  // Theo từng việc (từng màu lõi): giờ bắt đầu, xong, tốc độ lượt chạy đầu (để tính gối đầu theo bobin đầu tiên)
  const tspan = new Map<number, { start: number; end: number; rate: number }>();
  const markSpan = (t: Task, rs: number, end: number, rate: number) => {
    const s = tspan.get(t.id);
    if (!s) tspan.set(t.id, { start: rs, end, rate });
    else { if (rs < s.start) { s.start = rs; s.rate = rate; } s.end = Math.max(s.end, end); }
  };
  for (const m of machines) for (const sl of m.slots) {
    const d = opDone.get(key(sl.lineId, sl.op)); if (!d) continue;
    d.start = Math.min(d.start, sl.runStart); d.end = Math.max(d.end, sl.end);
    const t = byKey.get(sl.key); if (t && !isSup(t)) markSpan(t, sl.runStart, sl.end, sl.rate);
  }
  for (const id of pending) opDone.get(key(tasks[id].order.id, tasks[id].op))!.left++;
  const predOf = new Map(tasks.map((t) => {
    const ops = predOps(t.order.route, t.k, supply);
    return [t.id, tasks.filter((x) => x.oi === t.oi && ops.includes(x.op))] as const;
  }));

  // Gối đầu theo bobin: công đoạn sau bắt đầu khi bobin đầu tiên của từng việc trước xong + QC (+ đệm an toàn),
  // và xong sau việc trước ít nhất thời gian QC bobin cuối + chạy bobin cuối trên máy sau (run, v: trên máy đang xét)
  const ready = (t: Task, run: number, v: number): number | null => {
    let r = 0;
    for (const p of predOf.get(t.id)!) {
      if (pending.has(p.id) || dead.has(p.id)) return null;
      const sp = tspan.get(p.id); if (!sp || sp.end <= 0) continue;
      const g = QC + SAFE(p.op);
      const lead = Math.min(F.unit_m[p.op] / Math.max(1e-6, sp.rate), Math.max(0, sp.end - sp.start)) + g;
      const tail = g + Math.min(run, F.unit_m[t.op] / Math.max(1e-6, v));
      r = Math.max(r, sp.start + lead, sp.end + tail - run);
    }
    return r;
  };
  const spMemo = new Map<string, Speed>();
  const modeOf = new Map(ctx.machines.map((m) => [m.code, m.data_mode]));
  const spOf = (m: string, t: Task) => {
    const k = m + '|' + t.id;
    let v = spMemo.get(k);
    if (!v) {
      v = rateOn(cfg, m, t.op, t.order, modeOf.get(m));
      const b = boost(m);
      if (b !== 1) v = { ...v, v: v.v * b, note: `${v.note ? v.note + ', ' : ''}tăng ca ${Math.round(Number(F.extra_min[m]))} phút/ngày` };
      spMemo.set(k, v);
    }
    return v;
  };
  const G = Math.max(0, Math.round(Number(cfg.group_days ?? 0)));
  const laneFor = (code: string) => {
    let best: { w: (typeof workers)[number]; li: number; f: number } | null = null;
    for (const w of workers) if (w.skills.includes(code)) w.lanes.forEach((f, li) => { if (!best || f < best.f) best = { w, li, f }; });
    return best as { w: (typeof workers)[number]; li: number; f: number } | null;
  };
  const due = (o: Order) => o.commit ?? o.due ?? '9999-12-31';
  const byPrio = (a: Order, b: Order) => a.prio - b.prio || (a.seq ?? 0) - (b.seq ?? 0) || due(a).localeCompare(due(b));
  type Cand = { t: Task; r: number; sp: Speed; run: number };
  // Chọn việc cho một máy trong các việc bắt đầu được gần như cùng lúc:
  // 1) lô dẫn đầu = đơn gấp → thứ tự tối ưu → hạn giao sớm nhất → màu sáng; 2) các lô cùng mức gấp, hạn giao không muộn hơn lô dẫn đầu quá G ngày
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

  // ---------- Sổ máy trộn: năng lực theo từng giờ, cấp silicone đúng hạn dùng ----------
  const kghOf = new Map(mixers.map((m) => [m.code, mixerKgh(cfg, m.code)]));
  const fillF = Number(cfg.fill_pct) / 100;
  const shStartH = cal.shifts.map((s) => toMin(s.start_time) / 60);
  const shLenH = shLenMin.map((x) => x / 60);
  const dayH = (di: number) => {
    const n = cal.days.length;
    return Date.parse(cal.days[Math.min(Math.max(di, 0), n - 1)] + 'T00:00:00Z') / 3600000 + (di >= n ? (di - n + 1) * 24 : 0);
  };
  const realAt = (t: number, isEnd = false) => {
    const tt = isEnd ? t - 1e-7 : t;
    const di = Math.max(0, Math.floor(tt / DAY)), w = tt - di * DAY;
    const j = Math.min(SPD - 1, Math.max(0, Math.floor(w / S))), x = Math.max(0, w - j * S);
    return dayH(di) + shStartH[j] + (x / S) * shLenH[j];
  };
  const mixDown = (code: string, t0: number, t1: number) => wins.some((w) => w.machine === code
    && (t1 > t0 ? t1 > w.from + 1e-9 && t0 < w.to - 1e-9 : w.from <= t0 + 1e-9 && t0 < w.to - 1e-9));
  type Alloc = { key: string; oid: string; kg: number; co: boolean; useR: number; op: string | null; lane: number };
  type Bk = { t0: number; t1: number; r0: number; r1: number; cap: number; used: number; early: boolean; ot: boolean; alloc: Alloc[] };
  const dayEndR = (di: number) => dayH(di) + shStartH[SPD - 1] + shLenH[SPD - 1];
  const bdays = new Map<number, Bk[]>();
  const daysB = (di: number): Bk[] => {
    let b = bdays.get(di); if (b) return b;
    b = [];
    const d0 = di * DAY;
    if (F.mix_early_h > 0) {
      // Trộn sẵn trước giờ vào ca (người trộn ca sớm): từng giờ một, giờ càng sớm càng gần hết hạn dùng
      const n = Math.ceil(F.mix_early_h - 1e-9);
      for (let q = n; q >= 1; q--) {
        const len = Math.min(1, F.mix_early_h - (q - 1)), r1 = dayH(di) + shStartH[0] - (q - 1), r0 = r1 - len;
        const kgh = mixers.reduce((a, m) => a + (mixDown(m.code, d0, d0) ? 0 : kghOf.get(m.code)!), 0);
        b.push({ t0: d0, t1: d0, r0, r1, cap: kgh * len * fillF, used: 0, early: true, ot: false, alloc: [] });
      }
    }
    for (let j = 0; j < SPD; j++) {
      const n = Math.max(1, Math.round(shLenH[j]));
      for (let q = 0; q < n; q++) {
        const t0 = d0 + j * S + (q * S) / n, t1 = d0 + j * S + ((q + 1) * S) / n;
        const kgh = mixers.reduce((a, m) => a + (mixDown(m.code, t0, t1) ? 0 : kghOf.get(m.code)!), 0);
        b.push({ t0, t1, r0: realAt(t0), r1: realAt(t1, true), cap: (kgh * (t1 - t0)) / 60, used: 0, early: false, ot: false, alloc: [] });
      }
    }
    // Tăng ca máy trộn: trộn sau giờ tan ca (giờ thật), chỉ dùng được cho line chạy tăng ca trong hạn dùng (hoặc sáng hôm sau nếu hạn dùng đủ dài)
    const maxE = Math.max(0, ...mixers.map((m) => Number(F.extra_min[m.code] ?? 0))) / 60;
    for (let q = 0; q < Math.ceil(maxE - 1e-9); q++) {
      const len = Math.min(1, maxE - q), r0 = dayEndR(di) + q;
      const kg = mixers.reduce((a, m) => a + (mixDown(m.code, d0 + DAY, d0 + DAY) ? 0
        : kghOf.get(m.code)! * Math.min(1, Math.max(0, Number(F.extra_min[m.code] ?? 0) / 60 - q))), 0) * fillF;
      b.push({ t0: d0 + DAY, t1: d0 + DAY, r0, r1: r0 + len, cap: kg, used: 0, early: false, ot: true, alloc: [] });
    }
    bdays.set(di, b);
    return b;
  };
  // Lấy silicone cho lượng dùng lúc useR (giờ thật): chỉ từ khoảng trộn đã xong trước lúc dùng và chưa quá hạn dùng.
  // Lấy khoảng trộn gần lúc dùng nhất trước (trộn vừa kịp): giữ phần trộn sớm cho các lần dùng sớm hơn của line khác
  const allocate = (t: Task, kg: number, co: boolean, useR: number, di: number, who: { op: string | null; lane: number }) => {
    let got = 0;
    const back = Math.ceil(F.pot_life_h / 24) + 1;
    for (let d = di; d >= Math.max(0, di - back) && got < kg - 1e-9; d--) for (const bk of [...daysB(d)].reverse()) {
      if (got >= kg - 1e-9) break;
      if (bk.r1 > useR + 1e-9 || bk.r0 < useR - F.pot_life_h - 1e-9) continue;
      const a = Math.min(bk.cap - bk.used, kg - got);
      if (a <= 1e-9) continue;
      bk.used += a; got += a;
      bk.alloc.push({ key: t.key, oid: t.order.id, kg: a, co, useR, op: who.op, lane: who.lane });
    }
    return got;
  };
  const coKg = () => (Number(cfg.changeovers.find((c) => c.code === 'MIX_CODE')?.minutes ?? 0) / 60)
    * mixers.reduce((a, m) => a + kghOf.get(m.code)!, 0);
  const bucketAt = (tau: number) => daysB(Math.floor(tau / DAY)).find((b) => !b.early && !b.ot && b.t1 > tau + 1e-9);
  // Line bọc chạy từ rs với tốc độ v; mỗi khoảng chỉ chạy được phần có silicone (thiếu thì line chạy chậm / chờ)
  // Line tăng ca (extra_min): phần sản lượng tăng thêm chạy sau giờ tan ca nên dùng silicone lúc đó (giờ thật)
  const runMix = (t: Task, mcode: string, rs: number, v: number, meters: number, limit: number, who: { op: string | null; lane: number }, co: boolean) => {
    const k = kgPerM(t.order);
    const lb = boost(mcode), otH = Math.max(0, Number(F.extra_min[mcode] ?? 0)) / 60;
    let tau = rs, left = meters, wait = 0, starve = 0, coLeft = co ? coKg() : 0;
    const hard = Math.min(limit, cal.days.length * DAY);
    for (let g = 0; left > 1e-6 && tau < hard - 1e-9 && g < 100000; g++) {
      const bk = bucketAt(tau);
      const ce = Math.min(bk ? bk.t1 : (Math.floor(tau / DAY) + 1) * DAY, hard, tau + left / v);
      const len = ce - tau;
      if (len <= 1e-9) { tau = bk ? bk.t1 : ce + 1e-6; continue; }
      const di = Math.floor(tau / DAY), useR = realAt(ce, true);
      let got = 0;
      if (coLeft > 0) { const c = allocate(t, coLeft, true, useR, di, who); coLeft -= c; }
      if (coLeft <= 1e-9) {
        const q = v * len * k, qOt = lb > 1 ? (q * (lb - 1)) / lb : 0;
        got = allocate(t, q - qOt, false, useR, di, who);
        if (qOt > 0) got += allocate(t, qOt, false, dayEndR(di) + otH, di, who);
      }
      const mm = Math.min(left, got / k);
      left -= mm; wait += len - mm / v;
      starve = mm > 1e-6 ? 0 : starve + len;
      tau = ce;
      if (starve > 5 * DAY) break; // 5 ngày không có silicone: dừng
    }
    // bỏ phần chờ ở cuối (khoảng cuối không dùng hết thì line xong sớm trong khoảng)
    return { end: tau, meters: meters - left, wait };
  };
  for (const u of preUse) {
    const k = kgPerM(u.t.order);
    for (let tau = u.from, g = 0; tau < u.to - 1e-9 && g < 100000; g++) {
      const bk = bucketAt(tau);
      const ce = Math.min(bk ? bk.t1 : (Math.floor(tau / DAY) + 1) * DAY, u.to);
      if (ce - tau > 1e-9) allocate(u.t, u.rate * (ce - tau) * k, false, realAt(ce, true), Math.floor(tau / DAY), { op: null, lane: 0 });
      tau = Math.max(ce, tau + 1e-6);
    }
  }
  // Người trộn: cần một làn người có tay nghề máy trộn (khác làn đang đứng line) trong suốt lúc line silicone chạy
  const mixSkilled = workers.filter((w) => mixers.some((mx) => w.skills.includes(mx.code)));
  const mixRes = new Map<string, number>();
  const mixGate = (ln: { w: (typeof workers)[number]; li: number }) => {
    if (!mixSkilled.length) return { w: null as (typeof workers)[number] | null, li: 0, at: 0 };
    let best: { w: (typeof workers)[number] | null; li: number; at: number; res: boolean } | null = null;
    for (const w of mixSkilled) w.lanes.forEach((f, li) => {
      if (w === ln.w && li === ln.li) return;
      const res = mixRes.get(w.code + '|' + li);
      const at = res !== undefined && f <= res + 1e-9 ? 0 : f;
      if (!best || at < best.at || (at === best.at && res !== undefined && !best.res)) best = { w, li, at, res: res !== undefined };
    });
    return best as { w: (typeof workers)[number] | null; li: number; at: number } | null;
  };
  // Line silicone: chọn cùng lúc làn người đứng line và làn người trộn (khác nhau) sao cho cả hai rảnh sớm nhất
  const pairFor = (code: string) => {
    let best: { ln: { w: (typeof workers)[number]; li: number; f: number }; gate: NonNullable<ReturnType<typeof mixGate>>; at: number } | null = null;
    for (const w of workers) if (w.skills.includes(code)) w.lanes.forEach((f, li) => {
      const gate = mixGate({ w, li });
      if (!gate) return;
      const at = Math.max(f, gate.at);
      if (!best || at < best.at) best = { ln: { w, li, f }, gate, at };
    });
    return best as { ln: { w: (typeof workers)[number]; li: number; f: number }; gate: NonNullable<ReturnType<typeof mixGate>>; at: number } | null;
  };
  const mixWait = new Map<string, number>();

  let guard = 0;
  while (pending.size && guard++ < 50000) {
    type Ln = NonNullable<ReturnType<typeof laneFor>>;
    type Gate = ReturnType<typeof mixGate>;
    type Opt = { m: (typeof machines)[number]; t: Task; r: number; st: number; raw: number; hit: string | null; rs: number; sp: Speed; run: number; lead: Task;
      ln: Ln; gate: Gate; bl: Block[] };
    const opts: Opt[] = [];
    for (const m of machines) {
      const ln0 = laneFor(m.code); if (!ln0) continue;
      let pair: ReturnType<typeof pairFor> | undefined;
      const cands: (Cand & { ln: Ln; gate: Gate; bl: Block[] })[] = [];
      for (const id of pending) {
        const t = tasks[id];
        if (!canRun(m.machine_type, t)) continue;
        let ln: Ln = ln0, gate: Gate = null;
        if (usesMix(t)) { if (pair === undefined) pair = pairFor(m.code); if (!pair) continue; ln = pair.ln; gate = pair.gate; }
        const sp = spOf(m.code, t), run = t.m / sp.v;
        const r = ready(t, run, sp.v);
        if (r !== null) cands.push({ t, r, sp, run, ln, gate, bl: [...m.blocks, ...ln.w.blocks[ln.li]] });
      }
      if (!cands.length) continue;
      // Bắt đầu sớm nhất trên máy này, đã tránh khối máy hỏng / bảo dưỡng / giữ chỗ (máy hỏng thì máy cùng loại thắng)
      const rawOf = (x: (typeof cands)[number]) => Math.max(m.free, x.r, x.ln.f, x.gate ? x.gate.at : 0);
      const startOf = (x: (typeof cands)[number]) => fit(rawOf(x), x.run, x.bl).s;
      const ok = cands.filter((x) => Number.isFinite(startOf(x)));
      if (!ok.length) continue;
      const minStart = Math.min(...ok.map(startOf));
      const pool = ok.filter((x) => startOf(x) <= minStart + S / 2);
      const { x: xc, lead, su } = pick(pool, m.last);
      const x = xc as (typeof cands)[number];
      const f = fit(rawOf(x), su + x.run, x.bl);
      if (!Number.isFinite(f.s)) continue;
      opts.push({ m, t: x.t, r: x.r, st: f.s, raw: rawOf(x), hit: f.s > rawOf(x) ? f.hit : null, rs: f.s + su, sp: x.sp, run: x.run, lead: lead.t, ln: x.ln, gate: x.gate, bl: x.bl });
    }
    if (!opts.length) break;
    // Trong nửa ca đầu: đơn gấp, thứ tự tối ưu, hạn giao sớm; rồi máy xong sớm nhất (máy nhanh hơn thắng)
    const minRs = Math.min(...opts.map((o) => o.rs));
    const best = opts.filter((o) => o.rs <= minRs + S / 2)
      .sort((a, b) => byPrio(a.t.order, b.t.order) || (a.rs + a.run) - (b.rs + b.run) || a.rs - b.rs)[0];
    const { m, t, ln, sp, run, lead } = best;
    const [su, why] = changeover(cfg, m.last, t);
    const preds = predOps(t.order.route, t.k, supply);
    const prevOp = preds.length ? preds.reduce((a, b) => (opDone.get(key(t.order.id, b))!.end > opDone.get(key(t.order.id, a))!.end ? b : a)) : null;
    const st0 = best.st;
    let reason: string;
    const qcTxt = `bobin đầu tiên + QC ${Math.round(F.qc_min)} phút${SAFE(prevOp ?? 'CD0') > 0 ? ` + đệm ${Math.round(Number(F.safety_min[prevOp!]))} phút` : ''}`;
    if (prevOp && st0 === best.r && best.r > m.free && best.r >= ln.f) reason = `Chờ ${OP_NAME[prevOp].toLowerCase()} của lệnh này làm xong ${qcTxt} (gối đầu)`;
    else if (st0 === ln.f && ln.f > m.free) reason = `Chờ người: ${ln.w.code} đang đứng máy khác, xong việc mới sang máy này`;
    else if (best.gate && st0 === best.gate.at && best.gate.at > m.free) reason = `Chờ người trộn silicone (${best.gate.w?.code}) rảnh`;
    else reason = m.last ? 'Máy làm xong việc trước thì chạy tiếp' : 'Máy và người đều sẵn, chạy ngay';
    const dmy = (d: string | null) => d ? `${d.slice(8, 10)}/${d.slice(5, 7)}` : 'chưa có';
    if (best.hit) reason += ` · Dời sau ${best.hit}`;
    if (lead !== t) reason += ` · Gom lô: chạy liền ${what(t)} để giảm đổi máy (hạn ${dmy(t.order.due)}, trong khung ${G} ngày so với ${lead.order.label} hạn ${dmy(lead.order.due)})`;
    else if (m.last && su === 0 && m.last.order.id !== t.order.id) reason += ` · Cùng ${what(t)} với việc trước, không đổi máy`;
    const v1 = Math.round(sp.v * 10) / 10;
    if (sp.src === 'PLC') reason += ` · Tốc độ ${v1} m/phút thực tế PLC 30 ngày (${sp.note})`;
    else if (sp.src === 'MAY') reason += ` · Tốc độ ${v1} m/phút theo bảng tự nhập của máy${sp.pending ? ' (chưa duyệt)' : ''}${sp.note ? ', ' + sp.note : ''}`;
    else if (sp.note) reason += ` · Tốc độ ${v1} m/phút mặc định theo công đoạn, ${sp.note}`;
    let end = st0 + su + run, meters = t.m, rate = sp.v, part = false;
    if (usesMix(t)) {
      // Line silicone: chạy theo lượng silicone máy trộn cấp được (đúng hạn dùng); gặp khối máy dừng thì tạm dừng, phần còn lại xếp sau
      const nb = best.bl.filter((b) => b[1] > st0 + su + 1e-9).reduce((a, b) => Math.min(a, Math.max(b[0], st0 + su)), Infinity);
      const who = { op: best.gate?.w?.code ?? null, lane: best.gate?.li ?? 0 };
      const prevSil = m.last && m.last.op === 'CD2' && m.last.order.product_code === t.order.product_code && m.last.color === t.color;
      const res = runMix(t, m.code, st0 + su, sp.v, t.m, nb, who, !prevSil);
      if (res.meters <= 1e-6) { pending.delete(t.id); dead.add(t.id); opDone.get(key(t.order.id, t.op))!.left--; continue; }
      end = res.end; meters = res.meters; rate = meters / Math.max(1e-6, end - st0 - su); part = meters < t.m - 1;
      reason += ` · Máy trộn cấp silicone theo nhịp line (hạn dùng ${F.pot_life_h} giờ)`;
      if (res.wait > S / 16) {
        reason += ` · Chờ silicone ${Math.round(res.wait / real2s)} phút: máy trộn không cấp kịp, bình quân ${Math.round(rate * 10) / 10} m/phút`;
        mixWait.set(m.code, (mixWait.get(m.code) ?? 0) + res.wait / real2s);
      }
      if (part) reason += ' · Tạm dừng, phần còn lại xếp tiếp';
      if (best.gate?.w) {
        const g = best.gate.w, k = g.code + '|' + best.gate.li;
        g.lanes[best.gate.li] = Math.max(g.lanes[best.gate.li], end); mixRes.set(k, g.lanes[best.gate.li]);
      }
    }
    m.slots.push({
      key: t.key, lineId: t.order.id, op: t.op, color: t.color, machine: m.code, operator: ln.w.code, lane: ln.li,
      start: st0, runStart: st0 + su, end, setup: su, meters, rate, speed: sp.v, reason, why, part,
    });
    m.free = end; m.last = { order: t.order, op: t.op, color: t.color }; ln.w.lanes[ln.li] = end;
    markSpan(t, st0 + su, end, rate);
    const d = opDone.get(key(t.order.id, t.op))!;
    d.start = Math.min(d.start, st0 + su); d.end = Math.max(d.end, end);
    if (part) { t.m -= meters; t.run = t.m / t.rate; continue; }
    d.left--;
    pending.delete(t.id);
  }

  // ---------- Lịch máy trộn: từ sổ cấp silicone ra các khối trộn trên máy trộn ----------
  let mixLog: MixLog | undefined;
  if (supply) {
    const mixSlots: Slot[] = [];
    const uses: MixLog['uses'] = [];
    for (const [, bks] of [...bdays.entries()].sort((a, b) => a[0] - b[0])) {
      const early = bks.filter((b) => b.early);
      const ots = bks.filter((b) => b.ot);
      const inShift = bks.filter((b) => !b.early && !b.ot);
      for (const b of bks) for (const a of b.alloc) uses.push({ key: a.key, kg: a.kg, mixR0: b.r0, mixR1: b.r1, useR: a.useR });
      inShift.forEach((b, i) => {
        const last = i === inShift.length - 1;
        const allocs = [...(i === 0 ? early.flatMap((e) => e.alloc) : []), ...b.alloc, ...(last ? ots.flatMap((e) => e.alloc) : [])];
        if (!allocs.length) return;
        const agg = new Map<string, { oid: string; kgM: number; kgC: number; op: string | null; lane: number }>();
        for (const a of allocs) {
          const g = agg.get(a.oid) ?? { oid: a.oid, kgM: 0, kgC: 0, op: a.op, lane: a.lane };
          if (a.co) g.kgC += a.kg; else g.kgM += a.kg;
          agg.set(a.oid, g);
        }
        const capB = b.cap + (i === 0 ? early.reduce((s, e) => s + e.cap, 0) : 0) + (last ? ots.reduce((s, e) => s + e.cap, 0) : 0);
        const tot = [...agg.values()].reduce((s, g) => s + g.kgM + g.kgC, 0);
        const avail = mixers.filter((mx) => !mixDown(mx.code, b.t0, b.t1));
        const useM = avail.length ? avail : mixers.slice(0, 1);
        const totK = useM.reduce((s, mx) => s + kghOf.get(mx.code)!, 0) || 1;
        for (const mx of useM) {
          const share = kghOf.get(mx.code)! / totK;
          let x = b.t0;
          for (const g of agg.values()) {
            const o = orderById.get(g.oid)!;
            const len = ((b.t1 - b.t0) * (g.kgM + g.kgC)) / Math.max(tot, capB);
            const su = len * (g.kgC / Math.max(1e-9, g.kgM + g.kgC));
            const meters = ((g.kgM * share) / Number(o.mix)) * 1000;
            const prev = mixSlots.filter((s) => s.machine === mx.code && s.lineId === g.oid).at(-1);
            if (prev && Math.abs(prev.end - x) < 1e-6 && su < 1e-9) { prev.meters += meters; prev.end = x + len; prev.rate = prev.meters / Math.max(1e-6, prev.end - prev.runStart); }
            else mixSlots.push({
              key: `${g.oid}|CD0|`, lineId: g.oid, op: 'CD0', color: null, machine: mx.code, operator: g.op, lane: g.lane,
              start: x, runStart: x + su, end: x + len, setup: su, meters, rate: meters / Math.max(1e-6, len - su), speed: kghOf.get(mx.code)!,
              reason: `Trộn theo nhịp line silicone, chỉ trộn lượng line dùng hết trong ${F.pot_life_h} giờ (${Math.round(kghOf.get(mx.code)! * 10) / 10} kg/giờ${F.mix_early_h > 0 ? `, trộn sẵn trước ca ${F.mix_early_h} giờ` : ''})`,
              why: su > 0 ? 'đổi công thức trộn, vệ sinh trục cán' : '', part: false,
            });
            x += len;
          }
        }
      });
    }
    for (const s of mixSlots) {
      const m = machines.find((x) => x.code === s.machine)!;
      m.slots.push(s);
      const d = opDone.get(key(s.lineId, 'CD0'));
      if (d) { d.start = Math.min(d.start, s.runStart); d.end = Math.max(d.end, s.end); }
    }
    const buckets = [...bdays.values()].flat().map((b) => ({ r0: b.r0, r1: b.r1, t0: b.t0, t1: b.t1, cap: b.cap, used: b.used, early: b.early }));
    mixLog = { kgh: mixers.reduce((a, m) => a + kghOf.get(m.code)!, 0), pot_life_h: F.pot_life_h, buckets, uses, wait_min: Object.fromEntries(mixWait) };
  }
  const byMachine = new Map(machines.map((m) => [m.code, m.slots.sort((a, b) => a.start - b.start)]));
  return {
    slots: machines.flatMap((m) => m.slots), byMachine, opDone, unplaced: [...pending, ...dead].map((id) => tasks[id]), S, SPD, RUN: cal.RUN, mix: mixLog,
  };
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
    // Đóng gói đã xếp trên máy cuốn bobin: xong ở ca kết thúc đóng gói; chưa có công đoạn đóng gói thì + 1 ca kiểm tra, đóng gói
    const finS = last === 'CD6' ? Math.floor(Math.max(0, d.end - 1e-6) / sch.S) : Math.floor((d.end + sch.S) / sch.S);
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
