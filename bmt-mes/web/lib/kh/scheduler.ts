// Bộ xếp lịch máy theo máy và theo người đứng máy (thuần tính toán, không gọi database).
// Đơn vị thời gian: "phút xếp lịch". Mỗi ca có S phút xếp lịch = phút chạy × tỷ lệ xếp lịch (%), mỗi ngày SPD ca.
// Quy tắc (BR-KH-04..07): đơn gấp → hạn giao sớm → gom lô cùng cỡ ruột, cùng màu (trong khung gom lô) → màu sáng trước tối;
// gối đầu công đoạn ≥ 1 ca; chỉ xếp khi có người đủ tay nghề rảnh; xếp lại giữ nguyên phần trước mốc (đã chạy + vùng khóa).
// Tốc độ: máy chế độ Tự động (PLC) dùng tốc độ thực tế đo từ PLC (30 ngày, đủ ≥ PLC_MIN_RUN phút chạy);
// chế độ Nhập tay/Song song (hoặc PLC chưa đủ dữ liệu) dùng bảng tốc độ tự nhập của máy (master.machine_speeds);
// máy chưa khai báo dùng tốc độ mặc định theo công đoạn.
// Trộn silicone (CD0, máy trộn trong phòng lạnh) khai báo năng lực theo kg/giờ: đổi ra mét cáp/phút theo kg hỗn hợp/km cáp (BOM CD0);
// trộn chỉ là tiền đề của bọc cách điện, bện không phải chờ trộn. Đóng gói (CD6) trên máy cuốn bobin gỗ là công đoạn cuối.
// Người đứng máy (anh Bình duyệt 28/10/2026): máy tự chạy (bện, đùn, xoắn) chỉ cần người lúc đổi máy + khởi động và mỗi lần thay bobin;
// máy trộn cần 1 người liên tục; máy đóng gói cần người liên tục (tổ ngày, mặc định 2, 1 người thì chậm hơn). Một người không có
// hai đoạn có mặt cùng lúc; người vắng không xếp; kiêm nhiệm tạm (QLSX phân công) được đứng máy chưa có tay nghề.
// Máy không chạy được (dừng, hỏng, bảo dưỡng, ngừng dùng, bảo dưỡng giữ chỗ) là khối trên máy; tỷ lệ xếp lịch riêng từng máy
// (trừ tỷ lệ hỏng 90 ngày) làm máy đó chạy ít mét hơn trong mỗi phút xếp lịch.

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
export const PLC_MIN_RUN = 120; // mặc định phút chạy tối thiểu để tin tốc độ PLC (thông số flow.plc_min_run)
export type Config = {
  fill_pct: number; frozen_days: number; cutoff_time: string; downtime_reason_min: number; plc_dev_pct: number;
  auto_shifts: number; plc_loss_min: number; machines_per_operator: number;
  shifts: ShiftCfg[]; rates: RateCfg[]; changeovers: ChangeoverCfg[]; workdays?: number[] | null;
  speeds?: SpeedCfg[];   // tốc độ theo máy (trống: dùng rates)
  plc_speeds?: PlcSpeedCfg[]; // tốc độ thực tế đo từ PLC (máy chế độ Tự động)
  group_days?: number;   // khung gom lô (ngày); 0 = không gom
  flow?: FlowCfg;        // thông số dòng chảy (gối đầu theo bobin, máy trộn, hạn dùng silicone, tăng ca)
  people?: PeopleCfg;    // người đứng máy: phút có mặt, tổ đóng gói, lịch vắng, kiêm nhiệm tạm
  avail?: Record<string, { fill: number; down_pct?: number; days?: number }>; // tỷ lệ xếp lịch riêng từng máy (đủ dữ liệu)
};
// Người đứng máy
export type Absence = { code: string; from: string; to: string; part: 'FULL' | 'AM' | 'PM' };
export type Cover = { code: string; machine: string; from: string; to: string };
export type CrewDay = { date: string; machine: string; crew: number; members?: string[] | null };
export type PeopleCfg = {
  start_min?: number;      // phút người có mặt khi khởi động máy tự chạy (cộng phút đổi máy)
  bobbin_min?: number;     // phút người có mặt mỗi lần thay bobin
  watch_max?: number;      // cảnh báo khi một người trông quá số máy đang chạy cùng lúc
  pack_crew?: number;      // máy đóng gói: số người mặc định
  pack_one_pct?: number;   // đóng gói 1 người: % tốc độ
  absences?: Absence[]; covers?: Cover[]; crews?: CrewDay[];
};
export const PEOPLE_DEFAULT = { start_min: 20, bobbin_min: 5, watch_max: 6, pack_crew: 2, pack_one_pct: 50 };
export function peopleOf(cfg: Pick<Config, 'people'>) {
  const p = cfg.people ?? {};
  const n = (v: unknown, d: number, lo: number, hi: number) => (v == null || Number.isNaN(Number(v)) ? d : Math.min(hi, Math.max(lo, Number(v))));
  return {
    start_min: n(p.start_min, PEOPLE_DEFAULT.start_min, 0, 240), bobbin_min: n(p.bobbin_min, PEOPLE_DEFAULT.bobbin_min, 0, 60),
    watch_max: n(p.watch_max, PEOPLE_DEFAULT.watch_max, 1, 30), pack_crew: Math.round(n(p.pack_crew, PEOPLE_DEFAULT.pack_crew, 1, 2)),
    pack_one_pct: n(p.pack_one_pct, PEOPLE_DEFAULT.pack_one_pct, 10, 100),
    absences: p.absences ?? [], covers: p.covers ?? [], crews: p.crews ?? [],
  };
}
// Máy cần người đứng liên tục (máy trộn, máy đóng gói); máy khác tự chạy
export const CONT_TYPES = ['MIXER', 'PACKER'];
// Đoạn người có mặt trên một khối: START khởi động (gồm đổi máy), BOB thay bobin, RUN đứng liên tục, MIX trộn; c = kiêm nhiệm tạm
export type Attend = { f: number; t: number; p: string; k: 'START' | 'BOB' | 'RUN' | 'MIX'; c?: boolean };
// Tỷ lệ xếp lịch riêng của máy ÷ tỷ lệ chung (≤ 1): máy hỏng nhiều chạy ít mét hơn mỗi phút xếp lịch
export const availFactor = (cfg: Pick<Config, 'avail' | 'fill_pct'>, machine: string) => {
  const a = cfg.avail?.[machine];
  return a && Number(a.fill) > 0 && Number(cfg.fill_pct) > 0 ? Math.min(1, Math.max(0.1, Number(a.fill) / Number(cfg.fill_pct))) : 1;
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
  ot_from?: string | null;                      // tăng ca / trộn sớm áp dụng từ ngày (trống: mọi ngày)
  ot_until?: string | null;                     // … đến ngày (trống: mọi ngày)
  size_large_mm2?: number;                      // tốc độ mặc định theo công đoạn: từ cỡ này trở lên dùng tốc độ "cỡ lớn"
  plc_min_run?: number;                         // phút chạy tối thiểu để tin tốc độ đo từ PLC
  pick_window_min?: number | null;              // việc bắt đầu cách nhau không quá số phút này coi như cùng lúc (để gom lô); trống = nửa ca
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
    ot_from: f.ot_from ?? null, ot_until: f.ot_until ?? null,
    size_large_mm2: Math.max(0.01, Number(f.size_large_mm2 ?? 2.5)),
    plc_min_run: Math.max(1, Number(f.plc_min_run ?? PLC_MIN_RUN)),
    pick_window_min: f.pick_window_min == null || Number.isNaN(Number(f.pick_window_min)) ? null : Math.max(0, Number(f.pick_window_min)),
  };
}
export type MachineInfo = {
  id?: string; code: string; name: string; machine_type: string; data_mode: string; tag_count: number; operators: string[];
  status?: string; status_since?: string | null; status_eta?: string | null; status_note?: string | null;
};
// Khoảng máy không chạy được (phút xếp lịch): dừng / hỏng / bảo dưỡng đến giờ dự kiến chạy lại, ngừng dùng,
// bảo dưỡng giữ chỗ (đã chốt, hoặc giữ chỗ tạm theo kế hoạch bảo dưỡng: tentative)
export type Window = { machine: string; from: number; to: number; kind: 'DOWN' | 'STOP' | 'MAINT' | 'OFF' | 'PM'; label: string; tentative?: boolean };
export type OperatorInfo = {
  code: string; job: string; extra: string | null; is_deputy: boolean; keeps_fg: boolean; skills: string[]; learning: string[]; full_name?: string | null;
};

// Các đoạn bận của một người (phút xếp lịch), sắp theo giờ bắt đầu; tìm chỗ trống sớm nhất có đủ độ dài
export class Busy {
  iv: [number, number, string][] = [];
  maxLen = 0;
  private lo(t: number) { let a = 0, b = this.iv.length; while (a < b) { const m = (a + b) >> 1; if (this.iv[m][0] < t) a = m + 1; else b = m; } return a; }
  add(f: number, t: number, label: string) {
    if (!(t > f)) return null;
    const x: [number, number, string] = [f, t, label];
    this.iv.splice(this.lo(f), 0, x);
    this.maxLen = Math.max(this.maxLen, t - f);
    return x;
  }
  remove(x: [number, number, string] | null) { if (!x) return; const i = this.iv.indexOf(x); if (i >= 0) this.iv.splice(i, 1); }
  // Giờ sớm nhất ≥ t có [s, s + len) không chồng đoạn bận nào
  earliest(t: number, len: number): number {
    let s = t;
    for (let g = 0; g < 10000; g++) {
      let moved = false;
      for (let i = this.lo(s - this.maxLen - 1e-9); i < this.iv.length && this.iv[i][0] < s + Math.max(len, 1e-9) - 1e-9; i++) {
        const b = this.iv[i];
        if (b[1] > s + 1e-9) { s = b[1]; moved = true; break; }
      }
      if (!moved) return s;
    }
    return Infinity;
  }
  free(f: number, len: number) { return this.earliest(f, len) <= f + 1e-7; }
  // Rảnh từ t đến lúc nào (đầu đoạn bận kế tiếp); đang bận lúc t thì trả t
  freeUntil(t: number): number {
    let nxt = Infinity;
    for (let i = this.lo(t - this.maxLen - 1e-9); i < this.iv.length; i++) {
      const b = this.iv[i];
      if (b[0] <= t + 1e-9) { if (b[1] > t + 1e-9) return t; continue; }
      nxt = Math.min(nxt, b[0]); break;
    }
    return nxt;
  }
}

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
  attend?: Attend[];   // các đoạn người có mặt (khởi động, thay bobin, đứng liên tục, trộn)
  crew?: number;       // máy đóng gói: số người của khối
};
export type PrevSchedule = { S: number; SPD: number; slots: Slot[] };
export type OpSpan = { start: number; end: number; left: number };
export type Schedule = {
  slots: Slot[]; byMachine: Map<string, Slot[]>; opDone: Map<string, OpSpan>; unplaced: Task[];
  S: number; SPD: number; RUN: number;
  mix?: MixLog;   // máy trộn làm nguồn cấp: năng lực, phần đã dùng, từng lần cấp (để kiểm hạn dùng)
  warnings?: string[]; // thiếu thông số (tốc độ, phút đổi máy, máy trộn…) cần khai báo
};
// Nhật ký máy trộn (giờ thật tính từ 01/01/1970, theo giờ trên lịch): mỗi khoảng trộn và từng lần cấp cho line
export type MixLog = {
  kgh: number; pot_life_h: number; batch_h: number;
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

// Tốc độ mặc định theo công đoạn (Tham số xếp lịch): cỡ nhỏ và cỡ lớn (ngưỡng flow.size_large_mm2).
// Chưa khai báo tốc độ công đoạn → 0: không xếp, báo thiếu thông số (không đoán số)
const defRate = (cfg: Pick<Config, 'rates' | 'flow'>, code: string, o: Pick<Order, 'size'>) => {
  const x = cfg.rates.find((y) => y.op_code === code);
  if (!x) return 0;
  const v = Number(o.size >= flowOf(cfg).size_large_mm2 ? x.rate_large : x.rate_small);
  return v > 0 ? v : 0;
};
export function speedOf(cfg: Pick<Config, 'rates' | 'flow'>, op: Op, o: Pick<Order, 'size' | 'shield' | 'mix'>): number {
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
export function plcSpeed(cfg: Pick<Config, 'plc_speeds' | 'flow'>, machine: string, op: Op, o: Pick<Order, 'product_id' | 'group' | 'core'>): Speed | null {
  const minRun = flowOf(cfg).plc_min_run;
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
    if (min >= minRun && m > 0) return { v: m / min, src: 'PLC', pending: false, note: `${Math.round(min)} phút chạy` };
  }
  return null;
}
// Tốc độ chạy một công đoạn trên một máy theo chế độ nhập dữ liệu của máy.
// Bảng tự nhập: xoắn có quấn AL/PET liền dây lấy tốc độ chậm hơn của hai bước.
export function rateOn(cfg: Pick<Config, 'rates' | 'speeds' | 'plc_speeds' | 'flow'>, machine: string, op: Op,
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
export function mixerKgh(cfg: Pick<Config, 'rates' | 'speeds' | 'flow'>, machine: string): number {
  const s = machineSpeed(cfg, machine, 'CD0', { product_id: null, group: '', core: null });
  return s ? s.v : defRate(cfg, 'CD0', { size: 0 });
}

export function buildTasks(orders: Order[], cfg: Pick<Config, 'rates' | 'flow'>): Task[] {
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
    t.rate = speedOf(cfg, t.op, t.order); t.run = t.rate > 0 ? t.m / t.rate : Infinity;
  });
  return tasks;
}

type Prev = { order: Order; op: Op; color: string | null } | null;
function changeover(cfg: Pick<Config, 'changeovers'>, prev: Prev, t: { order: Order; op: Op; color: string | null }): [number, string] {
  if (!prev) return [0, ''];
  const P = (code: string) => Number(cfg.changeovers.find((c) => c.code === code)?.minutes ?? 0); // chưa khai báo: 0 phút + cảnh báo (schedule.warnings)
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
  const P = peopleOf(cfg);
  const START = P.start_min, BOB = P.bobbin_min;
  const tasks = buildTasks(orders, cfg);
  const byKey = new Map(tasks.map((t) => [t.key, t]));
  const orderById = new Map(orders.map((o) => [o.id, o]));
  const typeOf = new Map(ctx.machines.map((m) => [m.code, m.machine_type]));
  const isCont = (code: string) => CONT_TYPES.includes(typeOf.get(code) ?? '');
  const machines = ctx.machines.map((m) => ({
    ...m, free: 0, last: null as Prev, slots: [] as Slot[], blocks: [] as Block[],
    lastEnd: null as number | null,   // giờ khối cuối kết thúc (liền khối sau, không đổi máy thì không phải khởi động lại)
    owner: null as string | null,     // người đang phụ trách máy (người khởi động khối gần nhất)
  }));
  type M = (typeof machines)[number];
  const B = opt.boundary ?? 0;
  const keep = opt.keep ?? new Set<string>();
  const wins = (opt.windows ?? []).filter((w) => w.to > w.from);
  const KEEP_LABEL = 'khối giữ chỗ của lô TP SX đã duyệt lịch';
  const warnings = new Set<string>();
  {
    // Phút đổi máy dùng trong thuật toán: thiếu mã nào thì tính 0 phút và báo khai báo
    const ops = new Set(orders.flatMap((o) => o.route));
    const need: [string, Op][] = [['INS_UP', 'CD2'], ['INS_DOWN', 'CD2'], ['INS_SIZE', 'CD2'], ['SH_COLOR', 'CD5'], ['SH_CODE', 'CD5'], ['BUN_SIZE', 'CD1'], ['TWS_CODE', 'CD3'], ['MIX_CODE', 'CD0'], ['PK_CODE', 'CD6']];
    for (const [code, op] of need) if (ops.has(op) && !cfg.changeovers.some((c) => c.code === code))
      warnings.add(`Chưa khai báo phút đổi máy ${code} (${OP_NAME[op].toLowerCase()}): đang tính 0 phút`);
  }
  // Giờ thật → phút xếp lịch (QC, đệm an toàn là thời gian thật; phút xếp lịch = phút máy chạy)
  const shLenMin = cal.shifts.map((s) => shiftRun(s) + Number(s.break_min));
  const real2s = S / Math.max(1, shLenMin.reduce((a, x) => a + x, 0) / Math.max(1, shLenMin.length));
  const QC = F.qc_min * real2s;
  const SAFE = (op: Op) => Number(F.safety_min[op] ?? 0) * real2s;
  const dayRun = Math.max(1, cal.RUN * SPD);
  const PW = F.pick_window_min == null ? S / 2 : F.pick_window_min * real2s; // khung "bắt đầu gần như cùng lúc"
  // Tăng ca / trộn sớm chỉ trong khoảng ngày được duyệt
  const otOn = (di: number) => {
    const d = cal.days[Math.min(Math.max(0, di), cal.days.length - 1)];
    return (!F.ot_from || d >= F.ot_from) && (!F.ot_until || d <= F.ot_until);
  };
  const extraOf = (code: string, di: number) => (otOn(di) ? Math.max(0, Number(F.extra_min[code] ?? 0)) : 0);
  const boost = (code: string, di: number) => 1 + extraOf(code, di) / dayRun;
  const hasOt = (code: string) => Math.max(0, Number(F.extra_min[code] ?? 0)) > 0;
  // Giờ xong khi chạy `meters` từ rs với tốc độ v (m/phút xếp lịch), ngày có tăng ca thì nhanh hơn theo tỷ lệ giờ chạy thêm
  const advance = (code: string, rs: number, meters: number, v: number) => {
    if (!hasOt(code)) return rs + meters / v;
    let tau = rs, left = meters;
    for (let g = 0; left > 1e-9 && g < 100000; g++) {
      const di = Math.floor(tau / DAY), de = (di + 1) * DAY, vd = v * boost(code, di);
      const need = left / vd;
      if (tau + need <= de + 1e-9) return tau + need;
      left -= (de - tau) * vd; tau = de;
    }
    return tau;
  };
  const dmy = (d: string | null) => d ? `${d.slice(8, 10)}/${d.slice(5, 7)}` : 'chưa có';

  // ---------- Người đứng máy: lịch vắng, tay nghề, kiêm nhiệm tạm, tổ đóng gói ----------
  const ND = cal.days.length;
  const dateAt = (di: number) => (di >= 0 && di < ND ? cal.days[di] : null);
  const dayOf = (t: number) => Math.floor(t / DAY + 1e-9);
  type Wk = OperatorInfo & { busy: Busy; mins: number; cont: boolean; off: Set<string> };
  const workers: Wk[] = ctx.operators.map((w) => ({ ...w, busy: new Busy(), mins: 0, cont: w.skills.some(isCont), off: new Set<string>() }));
  const wByCode = new Map(workers.map((w) => [w.code, w]));
  // Lịch vắng → đoạn bận: cả ngày, nửa đầu hoặc nửa sau ngày làm việc
  for (const a of P.absences) {
    const w = wByCode.get(a.code); if (!w) continue;
    for (let di = 0; di < ND; di++) {
      const d = cal.days[di];
      if (d < a.from || d > a.to) continue;
      const half = DAY / 2, f = di * DAY + (a.part === 'PM' ? half : 0), t = a.part === 'AM' ? di * DAY + half : (di + 1) * DAY;
      w.busy.add(f, t, 'vắng'); w.off.add(di + '|' + a.part);
    }
  }
  const absentAt = (w: Wk, di: number, half: 'AM' | 'PM') => w.off.has(di + '|FULL') || w.off.has(di + '|' + half);
  const crewRow = (m: string, di: number) => { const d = dateAt(di); return d ? P.crews.find((c) => c.machine === m && c.date === d) : undefined; };
  const covered = (w: Wk, m: string, di: number) => { const d = dateAt(di); return !!d && P.covers.some((c) => c.code === w.code && c.machine === m && c.from <= d && d <= c.to); };
  // Được đứng máy m ngày di: có tay nghề (đứng chính) hoặc QLSX phân công kiêm nhiệm tạm; máy đóng gói TP SX chọn người thì chỉ người đó
  // Máy đóng gói: người TP SX chọn vào tổ ngày đó được đứng (kể cả chưa có tay nghề); tổ còn thiếu thì lấy thêm người có tay nghề / kiêm nhiệm
  const pickedFor = (w: Wk, m: string, di: number) => typeOf.get(m) === 'PACKER' && Boolean(crewRow(m, di)?.members?.includes(w.code));
  const eligible = (w: Wk, m: string, di: number) => w.skills.includes(m) || covered(w, m, di) || pickedFor(w, m, di);
  const mayStand = (w: Wk, m: string) => w.skills.includes(m) || P.covers.some((c) => c.code === w.code && c.machine === m)
    || P.crews.some((c) => c.machine === m && (c.members ?? []).includes(w.code));
  const staffOf = new Map(ctx.machines.map((m) => [m.code, workers.filter((w) => mayStand(w, m.code))]));
  // Giờ sớm nhất ≥ t người w rảnh [s, s + len) và được đứng máy m ngày đó
  const earliestFor = (w: Wk, m: string, t: number, len: number): number => {
    let s = t;
    for (let g = 0; g < 400; g++) {
      s = w.busy.earliest(s, len);
      if (!Number.isFinite(s)) return Infinity;
      const di = dayOf(s);
      if (di >= ND) return w.skills.includes(m) ? s : Infinity;
      if (eligible(w, m, di)) {
        // đoạn có mặt kéo sang ngày sau (khởi động cuối ca): ngày sau cũng phải được đứng máy (kiêm nhiệm tạm theo ngày)
        const d2 = dayOf(s + Math.max(0, len - 1e-6));
        if (d2 === di || d2 >= ND || eligible(w, m, d2)) return s;
        s = (d2 + 1) * DAY; continue;
      }
      let nd = di + 1;
      while (nd < ND && !eligible(w, m, nd)) nd++;
      if (nd >= ND) return Infinity;
      s = nd * DAY;
    }
    return Infinity;
  };
  type Staff = { w: Wk; at: number; cover: boolean };
  const lexLess = (a: number[], b: number[]) => { for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return a[i] < b[i]; return false; };
  // Người có mặt sớm nhất cho một đoạn; cùng lúc thì ưu tiên người đang phụ trách máy, người không phải giữ máy trộn / đóng gói,
  // người có tay nghề (hơn người kiêm nhiệm tạm), người ít phút có mặt hơn
  const findStaff = (m: string, t: number, len: number, prefer: string | null): Staff | null => {
    let best: Staff | null = null, bk: number[] = [];
    for (const w of staffOf.get(m) ?? []) {
      const at = earliestFor(w, m, t, len);
      if (!Number.isFinite(at)) continue;
      const key = [at, w.code === prefer ? 0 : 1, w.cont ? 1 : 0, w.skills.includes(m) ? 0 : 1, w.mins];
      if (!best || lexLess(key, bk)) { best = { w, at, cover: !w.skills.includes(m) }; bk = key; }
    }
    return best;
  };
  const addAttend = (list: Attend[], w: Wk, m: string, f: number, t: number, k: Attend['k'], cover: boolean) => {
    const iv = w.busy.add(f, t, m);
    w.mins += t - f;
    list.push(cover ? { f, t, p: w.code, k, c: true } : { f, t, p: w.code, k });
    return iv;
  };
  // Lịch cũ chưa có đoạn có mặt: người đứng máy có mặt lúc khởi động (máy tự chạy) hoặc suốt khối (máy trộn, đóng gói)
  const legacyAttend = (sl: Slot): Attend[] => {
    if (!sl.operator) return [];
    if (isCont(sl.machine)) return [{ f: sl.start, t: sl.end, p: sl.operator, k: typeOf.get(sl.machine) === 'MIXER' ? 'MIX' : 'RUN' }];
    return [{ f: sl.start, t: Math.min(Math.max(sl.end, sl.start + 1e-6), sl.runStart + START), p: sl.operator, k: 'START' }];
  };
  // Khối giữ lại khi xếp lại: giữ đoạn có mặt (trước giờ máy dừng), đăng ký người bận phần sau mốc
  const keepAttend = (ns: Slot, src: Slot, k: number) => {
    const base = src.attend?.length ? src.attend.map((a) => ({ ...a, f: a.f * k, t: a.t * k })) : legacyAttend(ns);
    ns.attend = base.filter((a) => a.f < ns.end - 1e-9);
    for (const a of ns.attend) {
      if (a.t <= B + 1e-9) continue;
      const w = wByCode.get(a.p); if (!w) continue;
      const di = dayOf(Math.max(a.f, B));
      if (w.off.has(di + '|FULL') || w.off.has(di + '|AM') || w.off.has(di + '|PM'))
        warnings.add(`${a.p} vắng ${dmy(dateAt(di))} nhưng khối giữ lại trên ${ns.machine} cần người: TP SX phân công kiêm nhiệm tạm`);
      w.busy.add(Math.max(a.f, B), a.t, ns.machine);
      w.mins += a.t - Math.max(a.f, B);
    }
  };

  // Máy trộn = nguồn cấp silicone theo nhịp line bọc (không xếp như một công đoạn chạy trước)
  const mixers = ctx.machines.filter((m) => m.machine_type === 'MIXER');
  const supply = mixers.length > 0;
  const isSup = (t: Pick<Task, 'op'>) => supply && t.op === 'CD0';
  const usesMix = (t: Task) => supply && t.op === 'CD2' && t.order.route.includes('CD0') && Number(t.order.mix) > 0;
  const kgPerM = (o: Order) => Number(o.mix) / 1000 / Math.max(1, o.cores.length); // kg silicone / m lõi
  const preUse: { t: Task; from: number; to: number; rate: number; sl: Slot }[] = [];
  // Xếp lại: silicone đã dùng trước mốc (m cáp) theo từng lô, để khối trộn trước mốc đúng bằng lượng line đã dùng
  const preCons = new Map<string, number>();
  const keptMix: Slot[] = [];
  const consBefore = (t: Task, rs: number, end: number, meters: number) => {
    if (!usesMix(t) || end <= rs) return;
    const part = Math.max(0, Math.min(end, B) - rs) / (end - rs);
    preCons.set(t.order.id, (preCons.get(t.order.id) ?? 0) + (meters * part) / Math.max(1, t.order.cores.length));
  };

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
          const ns = { ...sl, start, runStart: Math.min(rs, e), end: e, rate, meters: mm, part: e < end - 1e-9 || sl.part };
          ns.attend = (sl.attend ?? []).map((a) => ({ ...a, f: a.f * k, t: Math.min(a.t * k, e) })).filter((a) => a.t > a.f);
          m.slots.push(ns); keptMix.push(ns);
        }
        continue;
      }
      // Máy dừng / hỏng / ngừng dùng / bảo dưỡng giữ chỗ: phần chưa chạy trước khi máy dừng xếp lại (sang máy cùng loại hoặc sau khi chạy lại)
      const hit = wins.find((w) => w.machine === sl.machine && end > w.from && start < w.to);
      if (hit) {
        // chưa chạy (sau mốc) hoặc chưa bắt đầu chạy trước giờ máy dừng: xếp lại toàn bộ
        if (start >= B || rs >= hit.from) continue;
        const mm = (hit.from - rs) * rate;
        const ns = { ...sl, start, runStart: rs, end: hit.from, rate, meters: mm, part: true, reason: `Phần đã chạy trước khi ${hit.label}, phần còn lại xếp lại` };
        t.m -= mm;
        m.slots.push(ns);
        keepAttend(ns, sl, k);
        consBefore(t, rs, ns.end, mm);
        if (usesMix(t) && ns.end > B) preUse.push({ t, from: Math.max(B, rs), to: ns.end, rate, sl: ns });
        continue;
      }
      if (start >= B) {
        // Lô đã duyệt lịch: giữ chỗ (khối cố định trên máy và người), việc khác xếp vào khoảng trống trước/sau khối
        if (!keep.has(sl.lineId)) continue;
        const ns = { ...sl, start, runStart: rs, end, rate, reason: sl.reason.startsWith('Giữ chỗ') ? sl.reason : `Giữ chỗ (TP SX đã duyệt lịch lô) · ${sl.reason}` };
        t.m -= sl.meters;
        m.slots.push(ns); m.blocks.push([start, end, KEEP_LABEL]);
        keepAttend(ns, sl, k);
        if (usesMix(t)) preUse.push({ t, from: rs, to: end, rate, sl: ns });
        continue;
      }
      let ns: Slot;
      if (opt.split && end > B) {
        if (rs >= B) continue;
        const mm = (B - rs) * rate;
        ns = { ...sl, start, runStart: rs, end: B, rate, meters: mm, part: true, reason: 'Phần đã chạy trước khi tách lệnh, phần còn lại xếp sau đơn gấp' };
        t.m -= mm;
        consBefore(t, rs, B, mm);
      } else {
        ns = { ...sl, start, runStart: rs, end, rate };
        t.m -= sl.meters;
        consBefore(t, rs, end, sl.meters);
        if (usesMix(t) && end > B) preUse.push({ t, from: Math.max(B, rs), to: end, rate, sl: ns });
      }
      m.slots.push(ns);
      keepAttend(ns, sl, k);
    }
  }
  // Khối trộn giữ lại trước mốc = lượng silicone line đã dùng trước mốc (không tính theo tỷ lệ thời gian)
  if (supply) {
    const byOrder = new Map<string, Slot[]>();
    for (const sl of keptMix) byOrder.set(sl.lineId, [...(byOrder.get(sl.lineId) ?? []), sl]);
    for (const [oid, list] of byOrder) {
      const had = list.reduce((a, x) => a + x.meters, 0), want = preCons.get(oid) ?? 0;
      if (had <= 1e-9) continue;
      const f = want / had;
      for (const x of list) { x.meters *= f; x.rate = x.meters / Math.max(1e-6, x.end - x.runStart); }
    }
  }
  if (opt.credit) for (const [key, mm] of opt.credit) { const t = byKey.get(key); if (t && !isSup(t)) t.m += mm; } // thiếu thì cộng, vượt thì trừ
  for (const w of wins) machines.find((m) => m.code === w.machine)?.blocks.push([w.from, w.to, w.label]);

  const pending = new Set<number>();
  for (const t of tasks) {
    if (isSup(t)) continue;
    if (t.m > 1) { t.run = t.rate > 0 ? t.m / t.rate : Infinity; pending.add(t.id); } else t.m = 0;
  }
  const dead = new Set<number>(); // việc không thể chạy (vd. không có silicone): việc sau cũng không xếp
  for (const m of machines) {
    m.slots.sort((a, b) => a.start - b.start);
    const before = m.slots.filter((x) => x.start < B);
    const l = before[before.length - 1];
    m.free = Math.max(B, l ? l.end : 0);
    m.lastEnd = l ? l.end : null;
    m.owner = l?.operator ?? null;
    m.last = l ? { order: orderById.get(l.lineId)!, op: l.op, color: l.color } : null;
    if (m.last && !m.last.order) m.last = null;
  }

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
  const notBefore = new Map<number, number>(); // thử lại từ lúc này (line silicone chưa có silicone, người khởi động bận)
  const ready = (t: Task, run: number, v: number): number | null => {
    let r = notBefore.get(t.id) ?? 0;
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
  // Xong không sớm hơn: việc trước xong + QC (+ đệm) + chạy bobin cuối trên máy này
  const minEnd = (t: Task, run: number, v: number) => {
    let e = 0;
    for (const p of predOf.get(t.id)!) {
      const sp = tspan.get(p.id); if (!sp || sp.end <= 0) continue;
      e = Math.max(e, sp.end + QC + SAFE(p.op) + Math.min(run, F.unit_m[t.op] / Math.max(1e-6, v)));
    }
    return e;
  };
  const spMemo = new Map<string, Speed>();
  const modeOf = new Map(ctx.machines.map((m) => [m.code, m.data_mode]));
  // Tốc độ trên máy × hệ số tỷ lệ xếp lịch riêng của máy (máy hỏng nhiều chạy ít mét hơn mỗi phút xếp lịch)
  const spOf = (m: string, t: Task) => {
    const k = m + '|' + t.id;
    let v = spMemo.get(k);
    if (!v) {
      v = rateOn(cfg, m, t.op, t.order, modeOf.get(m));
      const af = availFactor(cfg, m);
      if (af < 1 && v.v > 0) v = { ...v, v: v.v * af, note: [v.note, `tỷ lệ xếp lịch riêng ${Math.round(Number(cfg.avail?.[m]?.fill))}% (trừ hỏng ${Math.round(Number(cfg.avail?.[m]?.down_pct ?? 0) * 10) / 10}% 90 ngày)`].filter(Boolean).join(', ') };
      spMemo.set(k, v);
    }
    return v;
  };
  const G = Math.max(0, Math.round(Number(cfg.group_days ?? 0)));
  const due = (o: Order) => o.commit ?? o.due ?? '9999-12-31';
  const byPrio = (a: Order, b: Order) => a.prio - b.prio || (a.seq ?? 0) - (b.seq ?? 0) || due(a).localeCompare(due(b));
  type Cand = { t: Task; r: number; sp: Speed; run: number };
  // Chọn việc cho một máy trong các việc bắt đầu được gần như cùng lúc:
  // 1) lô dẫn đầu = đơn gấp → thứ tự tối ưu → hạn giao sớm nhất → màu sáng; 2) các lô cùng mức gấp, hạn giao không muộn hơn lô dẫn đầu quá G ngày
  // được chạy trước nếu ít phút đổi máy hơn (gom cùng cỡ ruột, cùng màu, cùng mã); 3) bằng nhau: màu sáng trước, hạn sớm trước.
  const pick = <X extends Cand>(pool: X[], last: Prev): { x: X; lead: X; su: number } => {
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

  // ---------- Sổ máy trộn: năng lực theo từng giờ, cấp silicone đúng hạn dùng, người trộn có mặt suốt giờ trộn ----------
  const kghOf = new Map(mixers.map((m) => [m.code, mixerKgh(cfg, m.code) * availFactor(cfg, m.code)]));
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
  type Alloc = { key: string; oid: string; kg: number; co: boolean; useR: number };
  type Bk = {
    t0: number; t1: number; r0: number; r1: number; cap: number; capFull: number; used: number; early: boolean; ot: boolean; alloc: Alloc[];
    mixers: { code: string; kgh: number }[];                                  // máy trộn chạy được trong khoảng này
    staff: { m: string; w: Wk; iv: [number, number, string] | null; cover: boolean }[]; // người trộn đã giữ cho khoảng này
    noStaff: boolean;                                                         // không ai trộn được khoảng này
  };
  const dayEndR = (di: number) => dayH(di) + shStartH[SPD - 1] + shLenH[SPD - 1];
  const bdays = new Map<number, Bk[]>();
  const mkBk = (t0: number, t1: number, r0: number, r1: number, early: boolean, ot: boolean, ms: { code: string; kgh: number }[], cap: number): Bk =>
    ({ t0, t1, r0, r1, cap, capFull: cap, used: 0, early, ot, alloc: [], mixers: ms.filter((x) => x.kgh > 0).sort((a, b) => b.kgh - a.kgh || a.code.localeCompare(b.code)), staff: [], noStaff: false });
  const daysB = (di: number): Bk[] => {
    let b = bdays.get(di); if (b) return b;
    b = [];
    const d0 = di * DAY;
    if (F.mix_early_h > 0 && otOn(di)) {
      // Trộn sẵn trước giờ vào ca (người trộn ca sớm): từng giờ một, giờ càng sớm càng gần hết hạn dùng
      const n = Math.ceil(F.mix_early_h - 1e-9);
      for (let q = n; q >= 1; q--) {
        const len = Math.min(1, F.mix_early_h - (q - 1)), r1 = dayH(di) + shStartH[0] - (q - 1), r0 = r1 - len;
        // máy trộn phải chạy được cả lúc vào ca (khối trộn sớm vẽ ở giờ đầu ca)
        const firstT1 = d0 + S / Math.max(1, Math.round(shLenH[0]));
        const ms = mixers.filter((m) => !mixDown(m.code, d0, d0) && !mixDown(m.code, d0, firstT1)).map((m) => ({ code: m.code, kgh: kghOf.get(m.code)! }));
        b.push(mkBk(d0, d0, r0, r1, true, false, ms, ms.reduce((a, x) => a + x.kgh, 0) * len * fillF));
      }
    }
    for (let j = 0; j < SPD; j++) {
      const n = Math.max(1, Math.round(shLenH[j]));
      for (let q = 0; q < n; q++) {
        const t0 = d0 + j * S + (q * S) / n, t1 = d0 + j * S + ((q + 1) * S) / n;
        const ms = mixers.filter((m) => !mixDown(m.code, t0, t1)).map((m) => ({ code: m.code, kgh: kghOf.get(m.code)! }));
        b.push(mkBk(t0, t1, realAt(t0), realAt(t1, true), false, false, ms, (ms.reduce((a, x) => a + x.kgh, 0) * (t1 - t0)) / 60));
      }
    }
    // Tăng ca máy trộn: trộn sau giờ tan ca (giờ thật), chỉ dùng được cho line chạy tăng ca trong hạn dùng (hoặc sáng hôm sau nếu hạn dùng đủ dài)
    const maxE = Math.max(0, ...mixers.map((m) => extraOf(m.code, di))) / 60;
    for (let q = 0; q < Math.ceil(maxE - 1e-9); q++) {
      const len = Math.min(1, maxE - q), r0 = dayEndR(di) + q;
      // tăng ca sau giờ ca: máy trộn phải chạy được giờ cuối ca (khối tăng ca vẽ ở giờ cuối ca) và lúc hết ca
      const lastT0 = d0 + DAY - S / Math.max(1, Math.round(shLenH[SPD - 1]));
      const ms = mixers.filter((m) => !mixDown(m.code, lastT0, d0 + DAY) && !mixDown(m.code, d0 + DAY - 1e-6, d0 + DAY - 1e-6))
        .map((m) => ({ code: m.code, kgh: kghOf.get(m.code)! * Math.min(1, Math.max(0, extraOf(m.code, di) / 60 - q)) }));
      b.push(mkBk(d0 + DAY, d0 + DAY, r0, r0 + len, false, true, ms, ms.reduce((a, x) => a + x.kgh, 0) * fillF));
    }
    bdays.set(di, b);
    return b;
  };
  // Giữ người trộn cho một khoảng: mỗi máy trộn chạy được một người có tay nghề (hoặc kiêm nhiệm tạm), có mặt suốt khoảng (giờ trong ca)
  // hoặc không vắng (trộn sớm trước ca: nửa đầu; tăng ca sau ca: nửa sau). Thiếu người thì máy đó không trộn trong khoảng này.
  let lastMixer: string | null = null;
  const claim = (bk: Bk, di: number): boolean => {
    const inShift = bk.t1 > bk.t0 + 1e-9;
    const used = new Set<Wk>();
    for (const mx of bk.mixers) {
      let best: Wk | null = null, bkey: number[] = [];
      for (const w of staffOf.get(mx.code) ?? []) {
        if (used.has(w) || !eligible(w, mx.code, Math.min(di, ND - 1))) continue;
        if (inShift ? !w.busy.free(bk.t0, bk.t1 - bk.t0) : absentAt(w, di, bk.early ? 'AM' : 'PM')) continue;
        const key = [w.code === lastMixer ? 0 : 1, w.skills.includes(mx.code) ? 0 : 1, w.mins];
        if (!best || lexLess(key, bkey)) { best = w; bkey = key; }
      }
      if (!best) continue;
      used.add(best);
      const iv = inShift ? best.busy.add(bk.t0, bk.t1, mx.code) : null;
      if (inShift) best.mins += bk.t1 - bk.t0;
      bk.staff.push({ m: mx.code, w: best, iv, cover: !best.skills.includes(mx.code) });
    }
    if (!bk.staff.length) return false;
    const tot = bk.mixers.reduce((a, x) => a + x.kgh, 0);
    const got = bk.mixers.filter((x) => bk.staff.some((s) => s.m === x.code)).reduce((a, x) => a + x.kgh, 0);
    bk.cap = tot > 0 ? bk.capFull * got / tot : 0;
    lastMixer = bk.staff[0].w.code;
    return true;
  };
  const release = (bk: Bk) => {
    for (const s of bk.staff) { s.w.busy.remove(s.iv); if (s.iv) s.w.mins -= bk.t1 - bk.t0; }
    bk.staff = []; bk.cap = bk.capFull;
  };
  // Lấy silicone cho lượng dùng lúc useR (giờ thật): chỉ từ khoảng trộn đã xong trước lúc dùng và chưa quá hạn dùng.
  // Lấy khoảng trộn gần lúc dùng nhất trước (trộn vừa kịp): giữ phần trộn sớm cho các lần dùng sớm hơn của line khác
  // Một mẻ phải trộn xong trước khi dùng: khoảng trộn phải xong trước lúc dùng ít nhất thời gian trộn một mẻ (mix_batch_kg ÷ kg/giờ)
  const batchH = F.mix_batch_kg / Math.max(1e-6, mixers.reduce((a, m) => a + (kghOf.get(m.code) ?? 0), 0));
  type Rec = { bk: Bk; a: number; claimed: boolean };
  const allocate = (t: Task, kg: number, co: boolean, useR: number, di: number, recs?: Rec[]) => {
    let got = 0;
    const back = Math.ceil(F.pot_life_h / 24) + 1;
    for (let d = di; d >= Math.max(0, di - back) && got < kg - 1e-9; d--) for (const bk of [...daysB(d)].reverse()) {
      if (got >= kg - 1e-9) break;
      // mẻ đầu của khoảng phải xong trước lúc dùng; lượng dùng được = phần đã trộn tới lúc dùng; chưa quá hạn dùng
      if (bk.r0 + Math.min(batchH, bk.r1 - bk.r0) > useR + 1e-9 || bk.r0 < useR - F.pot_life_h - 1e-9) continue;
      if (bk.noStaff || bk.capFull <= 1e-9) continue;
      const frac = bk.r1 > bk.r0 ? Math.min(1, (useR - bk.r0) / (bk.r1 - bk.r0)) : 1;
      if (bk.capFull * frac - bk.used <= 1e-9) continue;
      let claimed = false;
      if (!bk.staff.length) { if (!claim(bk, d)) { bk.noStaff = true; continue; } claimed = true; }
      const a = Math.min(bk.cap * frac - bk.used, kg - got);
      if (a <= 1e-9) { if (claimed) release(bk); continue; }
      bk.used += a; got += a;
      bk.alloc.push({ key: t.key, oid: t.order.id, kg: a, co, useR });
      recs?.push({ bk, a, claimed });
    }
    return got;
  };
  const coKg = () => (Number(cfg.changeovers.find((c) => c.code === 'MIX_CODE')?.minutes ?? 0) / 60)
    * mixers.reduce((a, m) => a + kghOf.get(m.code)!, 0);
  const bucketAt = (tau: number) => daysB(Math.floor(tau / DAY)).find((b) => !b.early && !b.ot && b.t1 > tau + 1e-9);
  const undo = (recs: Rec[]) => {
    for (const r of [...recs].reverse()) { r.bk.used -= r.a; r.bk.alloc.pop(); if (r.claimed && r.bk.used <= 1e-9) release(r.bk); }
    recs.length = 0;
  };
  // Line bọc chạy từ rs với tốc độ v; mỗi khoảng chỉ chạy được phần có silicone (thiếu thì line chạy chậm).
  // Chưa có silicone thì chưa chạy (không giữ máy, người); đang chạy mà hết silicone thì dừng tại đó, phần còn lại xếp tiếp.
  // Ngày tăng ca: line chạy nhanh hơn theo tỷ lệ giờ thêm, phần thêm dùng silicone sau giờ tan ca (giờ thật).
  // all: ghi mọi lần lấy silicone (để trả lại khi khối phải dời hoặc cắt)
  const runMix = (t: Task, mcode: string, rs: number, v: number, meters: number, limit: number, co: boolean, all: Rec[]) => {
    const k = kgPerM(t.order);
    let tau = rs, left = meters, wait = 0, coLeft = co ? coKg() : 0, start: number | null = null;
    const hard = Math.min(limit, cal.days.length * DAY);
    for (let g = 0; left > 1e-6 && tau < hard - 1e-9 && g < 200000; g++) {
      const bk = bucketAt(tau);
      const di = Math.floor(tau / DAY), vd = v * boost(mcode, di);
      const ce = Math.min(bk ? bk.t1 : (di + 1) * DAY, hard, tau + left / vd);
      const len = ce - tau;
      if (len <= 1e-9) { tau = bk ? bk.t1 : ce + 1e-6; continue; }
      const useR = realAt(ce, true), recs: Rec[] = [];
      const coGot = coLeft > 0 ? allocate(t, coLeft, true, useR, di, recs) : 0;
      let got = 0;
      if (coLeft - coGot <= 1e-9) {
        const lb = boost(mcode, di), q = vd * len * k, qOt = lb > 1 ? (q * (lb - 1)) / lb : 0;
        got = allocate(t, q - qOt, false, useR, di, recs);
        if (qOt > 0) got += allocate(t, qOt, false, dayEndR(di) + extraOf(mcode, di) / 60, di, recs);
      }
      const mm = Math.min(left, got / k);
      if (mm <= 1e-6) {
        undo(recs);
        if (start !== null) break;   // đang chạy mà hết silicone: dừng tại đây
        tau = ce; continue;          // chưa có silicone: chờ (không giữ máy)
      }
      all.push(...recs);
      coLeft -= coGot;
      if (start === null) start = tau;
      left -= mm; wait += len - mm / vd; tau = ce;
    }
    return { start, end: tau, meters: meters - left, wait, next: tau, horizon: tau >= cal.days.length * DAY - 1e-6 };
  };
  // Việc giữ lại chạy qua mốc: lấy silicone theo nhịp cũ; khoảng nào thiếu (lịch cũ chạy chậm lúc chờ trộn) thì dồn sang khoảng sau,
  // đến cuối khối vẫn thiếu thì bớt mét của khối, phần mét đó xếp lại sau mốc (giữ đủ mét, không dùng silicone chưa trộn)
  for (const u of preUse) {
    const k = kgPerM(u.t.order);
    let carry = 0;
    for (let tau = u.from, g = 0; tau < u.to - 1e-9 && g < 100000; g++) {
      const bk = bucketAt(tau);
      const ce = Math.min(bk ? bk.t1 : (Math.floor(tau / DAY) + 1) * DAY, u.to);
      if (ce - tau > 1e-9) {
        const q = u.rate * (ce - tau) * k + carry;
        carry = q - allocate(u.t, q, false, realAt(ce, true), Math.floor(tau / DAY));
      }
      tau = Math.max(ce, tau + 1e-6);
    }
    if (carry > 1e-6) {
      const mm = Math.min(carry / k, u.sl.meters);
      u.sl.meters -= mm; u.sl.part = true;
      u.sl.rate = u.sl.meters / Math.max(1e-6, u.sl.end - u.sl.runStart);
      u.t.m += mm;
      if (u.t.m > 1 && !pending.has(u.t.id)) {
        u.t.run = u.t.rate > 0 ? u.t.m / u.t.rate : Infinity;
        pending.add(u.t.id);
        opDone.get(key(u.t.order.id, u.t.op))!.left++;
      } else if (pending.has(u.t.id)) u.t.run = u.t.rate > 0 ? u.t.m / u.t.rate : Infinity;
    }
  }
  const mixWait = new Map<string, number>();

  // ---------- Đặt một việc lên máy ----------
  // Máy tự chạy: người có mặt lúc đổi máy + khởi động (liền khối trước, không đổi máy thì không cần); máy chờ người nếu chưa ai rảnh
  const startLen = (m: M, s: number, su: number) => (m.lastEnd !== null && Math.abs(s - m.lastEnd) < 1e-6 && su <= 1e-9 ? 0 : su + START);
  type Pl = { st: number; su: number; why: string; hit: string | null; staff: Staff | null; L: number; wait: number;
    crew?: Wk[]; factor?: number; need?: number; short?: boolean; target?: number };
  const placeAuto = (m: M, c: Cand): Pl | null => {
    const [su, why] = changeover(cfg, m.last, c.t);
    const raw = Math.max(m.free, c.r);
    const f0 = fit(raw, su + c.run, m.blocks);
    if (!Number.isFinite(f0.s)) return null;
    let s = f0.s;
    for (let g = 0; g < 60; g++) {
      const f1 = fit(s, su + c.run, m.blocks);
      if (!Number.isFinite(f1.s)) return null;
      const L = startLen(m, f1.s, su);
      if (L <= 0) return { st: f1.s, su, why, hit: f1.s > raw + 1e-9 ? (f1.hit ?? f0.hit) : null, staff: null, L: 0, wait: f1.s - f0.s };
      const st = findStaff(m.code, f1.s, L, m.owner);
      if (!st) return null;
      if (st.at <= f1.s + 1e-7) return { st: f1.s, su, why, hit: f0.s > raw + 1e-9 ? f0.hit : null, staff: st, L, wait: f1.s - f0.s };
      s = st.at;
    }
    return null;
  };
  // Máy đóng gói: tổ ngày (TP SX đặt, mặc định pack_crew) đứng liên tục; khối không qua ngày (mỗi ngày một tổ);
  // khối kéo dài đến khi một người trong tổ hết rảnh (vắng nửa ca, thay bobin máy khác…), sau đó xếp tiếp với người có mặt;
  // trong ngày có mặt ít người hơn tổ đặt (vắng) thì chạy với số người có mặt; 1 người: tốc độ pack_one_pct %.
  // Người TP SX chọn vào tổ được ưu tiên; tổ còn thiếu thì lấy thêm người có tay nghề / kiêm nhiệm.
  const placePack = (m: M, c: Cand): Pl | null => {
    const [su, why] = changeover(cfg, m.last, c.t);
    const raw = Math.max(m.free, c.r);
    const minLen = su + Math.min(c.run, S / 8);
    let s = raw, hit: string | null = null;
    for (let g = 0; g < 4000; g++) {
      const di = dayOf(s); if (di >= ND) return null;
      const dayEnd = (di + 1) * DAY;
      if (dayEnd - s < minLen - 1e-9) { s = dayEnd; continue; }
      const f1 = fit(s, minLen, m.blocks);
      if (!Number.isFinite(f1.s)) return null;
      if (f1.s > s + 1e-9) { hit = f1.hit; s = f1.s; continue; }
      const row = crewRow(m.code, di);
      const target = Math.round(row?.crew ?? P.pack_crew);
      // người rảnh được ít nhất một đoạn ngắn trong phần còn lại của ngày
      const avail = (staffOf.get(m.code) ?? []).filter((w) => eligible(w, m.code, di) && !w.off.has(di + '|FULL'))
        .map((w) => ({ w, at: earliestFor(w, m.code, s, minLen) })).filter((x) => x.at <= dayEnd - minLen + 1e-9)
        .sort((a, b) => a.at - b.at || (pickedFor(b.w, m.code, di) ? 1 : 0) - (pickedFor(a.w, m.code, di) ? 1 : 0)
          || (a.w.code === m.owner ? -1 : b.w.code === m.owner ? 1 : 0) || (a.w.skills.includes(m.code) ? 0 : 1) - (b.w.skills.includes(m.code) ? 0 : 1) || a.w.mins - b.w.mins);
      if (!avail.length) { s = dayEnd; continue; }
      const N = Math.min(target, avail.length);
      const aN = avail[N - 1].at;
      if (aN > s + 1e-7) { s = aN; continue; }
      const crew = avail.slice(0, N).map((x) => x.w);
      const until = Math.min(dayEnd, ...crew.map((w) => w.busy.freeUntil(s)));
      const factor = N >= 2 ? 1 : P.pack_one_pct / 100;
      // máy cũng phải rảnh suốt khối: dừng trước khối máy dừng kế tiếp
      const nextBlock = m.blocks.filter((b) => b[1] > s + 1e-9).reduce((acc, b) => Math.min(acc, Math.max(b[0], s)), Infinity);
      const need = Math.min(su + c.run / factor, until - s, nextBlock - s);
      if (need < Math.min(minLen, su + c.run / factor) - 1e-9) { s = Math.min(until, nextBlock) + 1e-6; continue; }
      return { st: s, su, why, hit, staff: { w: crew[0], at: s, cover: !crew[0].skills.includes(m.code) }, L: need, wait: s - raw,
        crew, factor, need, short: N < target, target };
    }
    return null;
  };
  // Máy nào cũng không có người đứng được: báo
  for (const m of machines) {
    if ((staffOf.get(m.code) ?? []).length) continue;
    if (m.machine_type === 'MIXER') { if (supply && tasks.some(usesMix)) warnings.add(`Máy trộn ${m.code} chưa có người đứng (Hồ sơ máy → Người đứng máy, hoặc phân công kiêm nhiệm tạm): line silicone không có silicone`); continue; }
    if (tasks.some((t) => canRun(m.machine_type, t) && t.m > 1)) warnings.add(`Máy ${m.code} chưa có người đứng (Hồ sơ máy → Người đứng máy, hoặc Nhân sự xưởng → kiêm nhiệm tạm): không xếp việc lên máy`);
  }

  let guard = 0;
  while (pending.size && guard++ < 50000) {
    type Opt = { m: M; t: Task; r: number; sp: Speed; run: number; lead: Task; pl: Pl };
    const opts: Opt[] = [];
    for (const m of machines) {
      if (!(staffOf.get(m.code) ?? []).length) continue;
      const cands: (Cand & { pl: Pl })[] = [];
      for (const id of pending) {
        const t = tasks[id];
        if (!canRun(m.machine_type, t)) continue;
        const sp = spOf(m.code, t);
        if (!(sp.v > 0)) { warnings.add(`Chưa có tốc độ ${OP_NAME[t.op].toLowerCase()} cho máy ${m.code} (Hồ sơ máy → Tốc độ hoặc Tham số xếp lịch): không xếp việc này lên máy`); continue; }
        const run = t.m / sp.v;
        const r = ready(t, run, sp.v);
        if (r === null || !Number.isFinite(r)) continue;
        const c = { t, r, sp, run };
        const pl = m.machine_type === 'PACKER' ? placePack(m, c) : placeAuto(m, c);
        if (pl) cands.push({ ...c, pl });
      }
      if (!cands.length) continue;
      // Bắt đầu sớm nhất trên máy này (đã tránh khối máy dừng / giữ chỗ và chờ người); gom lô trong các việc bắt đầu gần như cùng lúc
      const minStart = Math.min(...cands.map((x) => x.pl.st));
      const pool = cands.filter((x) => x.pl.st <= minStart + PW);
      const { x, lead } = pick(pool, m.last);
      opts.push({ m, t: x.t, r: x.r, sp: x.sp, run: x.run, lead: lead.t, pl: x.pl });
    }
    if (!opts.length) break;
    // Trong nửa ca đầu: đơn gấp, thứ tự tối ưu, hạn giao sớm; rồi máy xong sớm nhất (máy nhanh hơn thắng)
    const rsOf = (o: Opt) => o.pl.st + o.pl.su;
    const minRs = Math.min(...opts.map(rsOf));
    const best = opts.filter((o) => rsOf(o) <= minRs + PW)
      .sort((a, b) => byPrio(a.t.order, b.t.order) || (rsOf(a) + a.run) - (rsOf(b) + b.run) || rsOf(a) - rsOf(b))[0];
    const { m, t, sp, run, lead, pl } = best;
    const su = pl.su, why = pl.why;
    const pack = m.machine_type === 'PACKER';
    const preds = predOps(t.order.route, t.k, supply);
    const prevOp = preds.length ? preds.reduce((a, b) => (opDone.get(key(t.order.id, b))!.end > opDone.get(key(t.order.id, a))!.end ? b : a)) : null;
    let st0 = pl.st;
    let reason: string;
    const qcTxt = `bobin đầu tiên + QC ${Math.round(F.qc_min)} phút${SAFE(prevOp ?? 'CD0') > 0 ? ` + đệm ${Math.round(Number(F.safety_min[prevOp!]))} phút` : ''}`;
    const realMin = (x: number) => Math.round(x / real2s);
    if (pl.wait > 1e-6) reason = pack ? `Chờ người đóng gói rảnh ${realMin(pl.wait)} phút` : `Chờ người khởi động máy rảnh ${realMin(pl.wait)} phút (người được đứng máy này đang có mặt ở máy khác hoặc vắng)`;
    else if (prevOp && Math.abs(st0 - best.r) < 1e-6 && best.r > m.free) reason = `Chờ ${OP_NAME[prevOp].toLowerCase()} của lệnh này làm xong ${qcTxt} (gối đầu)`;
    else reason = m.last ? 'Máy làm xong việc trước thì chạy tiếp' : 'Máy và người đều sẵn, chạy ngay';
    if (pl.hit) reason += ` · Dời sau ${pl.hit}`;
    if (lead !== t) reason += ` · Gom lô: chạy liền ${what(t)} để giảm đổi máy (hạn ${dmy(t.order.due)}, trong khung ${G} ngày so với ${lead.order.label} hạn ${dmy(lead.order.due)})`;
    else if (m.last && su === 0 && m.last.order.id !== t.order.id) reason += ` · Cùng ${what(t)} với việc trước, không đổi máy`;
    const v1 = Math.round(sp.v * 10) / 10;
    if (sp.src === 'PLC') reason += ` · Tốc độ ${v1} m/phút thực tế PLC 30 ngày (${sp.note})`;
    else if (sp.src === 'MAY') reason += ` · Tốc độ ${v1} m/phút theo bảng tự nhập của máy${sp.pending ? ' (chưa duyệt)' : ''}${sp.note ? ', ' + sp.note : ''}`;
    else if (sp.note) reason += ` · Tốc độ ${v1} m/phút mặc định theo công đoạn, ${sp.note}`;

    let end = 0, meters = t.m, part = false, rate = 0;
    const attend: Attend[] = [];
    let owner: string | null = m.owner;
    let freeAt: number;
    if (pack) {
      // Máy đóng gói: tổ có mặt suốt khối
      const crew = pl.crew!, factor = pl.factor!;
      const full = su + t.m / (sp.v * factor);
      if (full <= pl.need! + 1e-9) end = st0 + full;
      else { end = st0 + pl.need!; meters = Math.min(t.m, (pl.need! - su) * sp.v * factor); part = meters < t.m - 1e-6; }
      rate = meters / Math.max(1e-6, end - st0 - su);
      for (const w of crew) addAttend(attend, w, m.code, st0, end, 'RUN', !w.skills.includes(m.code));
      owner = crew[0].code;
      const covers = crew.filter((w) => !w.skills.includes(m.code)).map((w) => w.code);
      reason += ` · Tổ đóng gói ${crew.length} người: ${crew.map((w) => w.code).join(', ')}${covers.length ? ` (${covers.join(', ')} kiêm nhiệm tạm)` : ''}`
        + (crew.length === 1 ? ` · 1 người: tốc độ ${Math.round(P.pack_one_pct)}%${pl.short ? ` (tổ đặt ${pl.target} người, người còn lại vắng)` : ''}` : '');
      if (part) reason += end >= (dayOf(st0) + 1) * DAY - 1e-6 ? ' · Hết ngày, phần còn lại đóng gói ngày sau'
        : ' · Người trong tổ có việc khác / vắng từ giờ này (hoặc máy dừng): phần còn lại xếp tiếp với người có mặt';
      freeAt = end;
    } else {
      // Máy tự chạy: giờ xong theo tốc độ (tăng ca, silicone), rồi người có mặt lúc khởi động và từng lần thay bobin
      const recs: Rec[] = [];
      const nb = (from: number) => m.blocks.filter((b) => b[1] > from + 1e-9).reduce((a, b) => Math.min(a, Math.max(b[0], from)), Infinity);
      const prevSil = m.last && m.last.op === 'CD2' && m.last.order.product_code === t.order.product_code && m.last.color === t.color;
      let silNote = '', silWait = 0, aborted = false;
      const runBlock = (limit: number): boolean => {
        end = hasOt(m.code) ? advance(m.code, st0 + su, t.m, sp.v) : st0 + su + run; meters = t.m; part = false;
        if (hasOt(m.code)) {
          // ngày tăng ca chạy nhanh hơn: vẫn không được xong trước việc trước + QC + bobin cuối
          const need = minEnd(t, run, sp.v);
          for (let g = 0; g < 5 && end < need - 1e-6; g++) { st0 += need - end; end = advance(m.code, st0 + su, t.m, sp.v); }
        }
        rate = t.m / Math.max(1e-6, end - st0 - su);
        if (usesMix(t)) {
          // Line silicone: chạy theo lượng silicone máy trộn cấp được (đúng hạn dùng); gặp khối máy dừng thì tạm dừng, phần còn lại xếp sau
          const res = runMix(t, m.code, st0 + su, sp.v, t.m, Math.min(nb(st0 + su), limit), !prevSil, recs);
          if (res.start === null || res.meters <= 1e-6) {
            if (res.horizon) { pending.delete(t.id); dead.add(t.id); opDone.get(key(t.order.id, t.op))!.left--; }
            else notBefore.set(t.id, Math.max(res.next, (notBefore.get(t.id) ?? 0) + 1e-3));
            return false;
          }
          const delay = res.start - (st0 + su);
          silNote = '';
          if (delay > 1e-6) { st0 += delay; silNote += ` · Chờ máy trộn có silicone ${realMin(delay)} phút`; }
          end = res.end; meters = res.meters; rate = meters / Math.max(1e-6, end - st0 - su); part = meters < t.m - 1;
          silNote += ` · Máy trộn cấp silicone theo nhịp line (hạn dùng ${F.pot_life_h} giờ)`;
          if (res.wait > S / 16) silNote += ` · Chờ silicone ${realMin(res.wait)} phút: máy trộn không cấp kịp, bình quân ${Math.round(rate * 10) / 10} m/phút`;
          silWait = res.wait;
        } else if (limit < end - 1e-9) {
          meters = Math.max(0, (limit - st0 - su) * rate); end = limit; part = true;
        }
        return true;
      };
      // Người khởi động: giữ người trước khi lấy silicone (máy trộn không giữ người này lúc khởi động);
      // máy dời (chờ silicone, tăng ca) thì kiểm lại người tại giờ mới; chưa ai rảnh thì xếp lại sau
      const holdStart = (at: number, L: number): Staff | null => {
        if (L <= 0) return null;
        const a0 = pl.staff && pl.staff.w.busy.free(at, L) && eligible(pl.staff.w, m.code, dayOf(at))
          && (dayOf(at + L - 1e-6) >= ND || eligible(pl.staff.w, m.code, dayOf(at + L - 1e-6))) ? { ...pl.staff, at } : null;
        if (a0) return a0;
        const s2 = findStaff(m.code, at, L, m.owner);
        return s2 && s2.at <= at + 1e-7 ? s2 : null;
      };
      const st00 = st0;
      let L = startLen(m, st0, su);
      let staff = holdStart(st0, L);
      if (L > 0 && !staff) { notBefore.set(t.id, Math.max(st0 + 1e-3, (notBefore.get(t.id) ?? 0) + 1e-3)); continue; }
      let startIv = staff ? staff.w.busy.add(st0, st0 + L, m.code) : null;
      const dropStart = () => { if (staff && startIv) staff.w.busy.remove(startIv); startIv = null; };
      if (!runBlock(Infinity)) { dropStart(); continue; }
      if (Math.abs(st0 - st00) > 1e-9) {
        dropStart();
        L = startLen(m, st0, su);
        staff = holdStart(st0, L);
        if (L > 0 && !staff) {
          const s2 = findStaff(m.code, st0, L, m.owner);
          undo(recs);
          notBefore.set(t.id, s2 ? Math.max(s2.at, (notBefore.get(t.id) ?? 0) + 1e-3) : Infinity);
          continue;
        }
        startIv = staff ? staff.w.busy.add(st0, st0 + L, m.code) : null;
      }
      if (staff) staff.w.mins += L;
      // Thay bobin: mỗi lần đầy một bobin (mét/bobin của công đoạn) cần một người có mặt; không ai rảnh thì máy dừng tại đó
      // (khối cắt ở lần thay bobin đó, phần còn lại xếp tiếp khi có người); lần dỡ bobin cuối không ai rảnh ngay thì máy chờ
      const unit = Math.max(1, F.unit_m[t.op]);
      const startEnd = L > 0 ? st0 + L : st0;
      const pref = staff?.w.code ?? m.owner;
      type Ev = { w: Wk; f: number; t: number; k: Attend['k']; c: boolean };
      let evs: Ev[] = [], lateFree = 0, cutNote = '';
      for (let pass = 0; pass < 6; pass++) {
        const tmp: { w: Wk; iv: [number, number, string] | null; len: number }[] = [];
        const reg = (w: Wk, f: number, tt: number) => { tmp.push({ w, iv: w.busy.add(f, tt, m.code), len: tt - f }); w.mins += tt - f; };
        const unreg = () => { for (const x of tmp) { x.w.busy.remove(x.iv); x.w.mins -= x.len; } };
        evs = []; lateFree = 0;
        if (staff && L > 0) evs.push({ w: staff.w, f: st0, t: st0 + L, k: 'START', c: staff.cover }); // đã giữ người khởi động ở trên
        let cut: number | null = null;
        if (BOB > 0 && meters > 1e-6) {
          const avg = meters / Math.max(1e-9, end - st0 - su);
          const n = Math.ceil(meters / unit - 1e-9);
          for (let k = 1; k < n; k++) {
            const tk = st0 + su + (k * unit) / avg;
            if (tk - BOB < startEnd - 1e-9) continue;
            const who = findStaff(m.code, tk - BOB, BOB, pref);
            if (!who || who.at > tk - BOB + 1e-7) { cut = tk; break; }
            evs.push({ w: who.w, f: tk - BOB, t: tk, k: 'BOB', c: who.cover }); reg(who.w, tk - BOB, tk);
          }
          if (cut === null && end - BOB >= startEnd - 1e-9) {
            const who = findStaff(m.code, end - BOB, BOB, pref);
            if (who) {
              evs.push({ w: who.w, f: who.at, t: who.at + BOB, k: 'BOB', c: who.cover }); reg(who.w, who.at, who.at + BOB);
              if (who.at > end - BOB + 1e-7) lateFree = who.at + BOB;
            }
          }
        }
        if (cut === null) break;
        // Cắt khối tại lần thay bobin không có người: trả silicone, chạy lại đến giờ cắt
        unreg();
        if (pass === 5) { if (usesMix(t)) undo(recs); aborted = true; break; }   // cắt mãi chưa ổn: xếp lại việc này sau
        cutNote = ` · Tạm dừng lúc đầy bobin: không có người thay bobin (người được đứng máy đang có mặt ở máy khác hoặc vắng), phần còn lại xếp tiếp`;
        if (usesMix(t)) { undo(recs); const s0 = st0; if (!runBlock(cut) || Math.abs(st0 - s0) > 1e-9) { undo(recs); aborted = true; break; } }
        else { meters = Math.max(0, (cut - st0 - su) * (meters / Math.max(1e-9, end - st0 - su))); end = cut; part = true; rate = meters / Math.max(1e-6, end - st0 - su); }
      }
      if (aborted) { dropStart(); if (staff) staff.w.mins -= L; notBefore.set(t.id, Math.max(st0 + S / 8, (notBefore.get(t.id) ?? 0) + 1e-3)); continue; }
      if (meters <= 1e-6) {
        undo(recs); dropStart(); if (staff) staff.w.mins -= L;
        notBefore.set(t.id, Math.max(st0 + S / 8, (notBefore.get(t.id) ?? 0) + 1e-3)); continue;
      }
      for (const e of evs) attend.push(e.c ? { f: e.f, t: e.t, p: e.w.code, k: e.k, c: true } : { f: e.f, t: e.t, p: e.w.code, k: e.k });
      if (staff) owner = staff.w.code;
      reason += silNote;
      if (usesMix(t)) {
        if (silWait > S / 16) mixWait.set(m.code, (mixWait.get(m.code) ?? 0) + silWait / real2s);
      }
      if (hasOt(m.code) && end < st0 + su + run - 1e-6) reason += ` · Ngày tăng ca ${F.ot_from ? `${dmy(F.ot_from)}–${dmy(F.ot_until ?? null)}` : ''}: +${Math.round(Number(F.extra_min[m.code]))} phút/ngày`;
      if (staff) reason += ` · ${staff.w.code}${staff.cover ? ' (kiêm nhiệm tạm)' : ''} khởi động ${Math.round(L)} phút${su > 0 ? ` (gồm đổi máy ${Math.round(su)} phút)` : ''}`;
      const bobs = attend.filter((a) => a.k === 'BOB');
      if (bobs.length) reason += ` · Thay bobin ${bobs.length} lần (${[...new Set(bobs.map((a) => a.p + (a.c ? ' kiêm nhiệm tạm' : '')))].join(', ')})`;
      reason += cutNote;
      if (lateFree > end + 1e-6) reason += ` · Chờ người dỡ bobin cuối ${realMin(lateFree - end)} phút`;
      if (part && !cutNote && usesMix(t)) reason += ' · Tạm dừng, phần còn lại xếp tiếp';
      freeAt = Math.max(end, lateFree);
    }
    m.slots.push({
      key: t.key, lineId: t.order.id, op: t.op, color: t.color, machine: m.code, operator: owner, lane: 0,
      start: st0, runStart: st0 + su, end, setup: su, meters, rate, speed: sp.v, reason, why, part, attend,
      ...(pack ? { crew: pl.crew!.length } : {}),
    });
    m.free = freeAt; m.lastEnd = freeAt; m.owner = owner; m.last = { order: t.order, op: t.op, color: t.color };
    markSpan(t, st0 + su, end, rate);
    const d = opDone.get(key(t.order.id, t.op))!;
    d.start = Math.min(d.start, st0 + su); d.end = Math.max(d.end, end);
    if (part) { t.m -= meters; t.run = t.m / t.rate; continue; }
    d.left--;
    pending.delete(t.id);
  }

  // ---------- Lịch máy trộn: từ sổ cấp silicone ra các khối trộn trên máy trộn (người trộn có mặt suốt khối) ----------
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
        const extra = [...(i === 0 ? early : []), ...(last ? ots : [])];
        const allocs = [...(i === 0 ? early.flatMap((e) => e.alloc) : []), ...b.alloc, ...(last ? ots.flatMap((e) => e.alloc) : [])];
        if (!allocs.length) return;
        const agg = new Map<string, { oid: string; kgM: number; kgC: number }>();
        for (const a of allocs) {
          const g = agg.get(a.oid) ?? { oid: a.oid, kgM: 0, kgC: 0 };
          if (a.co) g.kgC += a.kg; else g.kgM += a.kg;
          agg.set(a.oid, g);
        }
        const capB = b.cap + extra.reduce((s, e) => s + e.cap, 0);
        const tot = [...agg.values()].reduce((s, g) => s + g.kgM + g.kgC, 0);
        // máy trộn và người trộn của khoảng (trong ca: người đã giữ suốt khoảng; chỉ trộn sớm / tăng ca: người trộn lúc đó, không ghi đoạn có mặt trong ca)
        const own = b.staff.map((s) => ({ m: s.m, p: s.w.code, att: true, c: s.cover }));
        const ext = extra.flatMap((e) => e.staff.map((s) => ({ m: s.m, p: s.w.code, att: false, c: s.cover })));
        const list = own.length ? own : ext.filter((x, j) => ext.findIndex((y) => y.m === x.m) === j);
        const useM = list.length ? list : mixers.slice(0, 1).map((mx) => ({ m: mx.code, p: null as string | null, att: false, c: false }));
        const totK = useM.reduce((s, x) => s + (kghOf.get(x.m) ?? 0), 0) || 1;
        for (const u of useM) {
          const share = (kghOf.get(u.m) ?? 0) / totK;
          let x = b.t0;
          for (const g of agg.values()) {
            const o = orderById.get(g.oid)!;
            const len = ((b.t1 - b.t0) * (g.kgM + g.kgC)) / Math.max(tot, capB);
            const su = len * (g.kgC / Math.max(1e-9, g.kgM + g.kgC));
            const meters = ((g.kgM * share) / Number(o.mix)) * 1000;
            const kgh = kghOf.get(u.m)!;
            // mỗi khoảng trộn (theo giờ) một khối: lượng trong khối đều theo thời gian, cắt tại mốc xếp lại đúng lượng
            mixSlots.push({
              key: `${g.oid}|CD0|`, lineId: g.oid, op: 'CD0', color: null, machine: u.m, operator: u.p, lane: 0,
              start: x, runStart: x + su, end: x + len, setup: su, meters, rate: meters / Math.max(1e-6, len - su), speed: kgh,
              reason: `Trộn theo nhịp line silicone, chỉ trộn lượng line dùng hết trong ${F.pot_life_h} giờ (${Math.round(kgh * 10) / 10} kg/giờ${F.mix_early_h > 0 ? `, trộn sẵn trước ca ${F.mix_early_h} giờ` : ''})${u.p ? ` · Người trộn ${u.p}${u.c ? ' (kiêm nhiệm tạm)' : ''} có mặt suốt giờ trộn` : ''}`,
              why: su > 0 ? 'đổi công thức trộn, vệ sinh trục cán' : '', part: false,
              attend: u.att && u.p && len > 1e-9 ? [u.c ? { f: x, t: x + len, p: u.p, k: 'MIX', c: true } : { f: x, t: x + len, p: u.p, k: 'MIX' }] : [],
            });
            x += len;
          }
          // người trộn giữ máy trộn suốt khoảng (giờ): khối cuối của khoảng ghi có mặt đến hết khoảng
          const lastS = mixSlots.at(-1);
          if (u.att && u.p && lastS && lastS.machine === u.m && lastS.attend?.length && b.t1 > lastS.attend[0].t + 1e-9) lastS.attend[0].t = b.t1;
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
    mixLog = { kgh: mixers.reduce((a, m) => a + kghOf.get(m.code)!, 0), pot_life_h: F.pot_life_h, batch_h: batchH, buckets, uses, wait_min: Object.fromEntries(mixWait) };
  }
  // Cảnh báo: một người phụ trách quá watch_max máy tự chạy đang chạy cùng lúc (chỉ cảnh báo, không chặn)
  for (const w of workers) {
    const ev: [number, number][] = [];
    for (const m of machines) if (!isCont(m.code)) for (const s of m.slots) if (s.operator === w.code && s.end > B && s.end > s.runStart)
      { ev.push([Math.max(s.runStart, B), 1]); ev.push([s.end, -1]); }
    ev.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
    let n = 0, at = -1, mx = 0;
    for (const [t, d] of ev) { n += d; if (n > mx) { mx = n; at = t; } }
    if (mx > P.watch_max) warnings.add(`${w.code} phụ trách ${mx} máy chạy cùng lúc (${dmy(dateAt(dayOf(at)))}), quá ${P.watch_max} máy: TP SX xem lại phân công người`);
  }
  const byMachine = new Map(machines.map((m) => [m.code, m.slots.sort((a, b) => a.start - b.start)]));
  return {
    slots: machines.flatMap((m) => m.slots), byMachine, opDone, unplaced: [...pending, ...dead].map((id) => tasks[id]), S, SPD, RUN: cal.RUN, mix: mixLog,
    warnings: [...warnings, ...(supply && mixers.every((m) => !(kghOf.get(m.code)! > 0)) ? ['Máy trộn chưa có năng lực (kg/giờ): line silicone không chạy được'] : []),
      ...[...dead].map((id) => `Không có silicone cho ${tasks[id].order.label} ${tasks[id].order.product_code} màu ${tasks[id].color ?? ''}: máy trộn ngừng hoặc thiếu người trộn`)],
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
