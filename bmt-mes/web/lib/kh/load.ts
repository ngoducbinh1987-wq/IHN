// Đọc dữ liệu module Kế hoạch sản xuất từ database và dựng lịch máy để hiển thị / xếp lại.
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  type Absence, type Attend, type Calendar, type Config, type Cover, type CrewDay, type FlowCfg, type MachineInfo, type MachineShift, type Op, type OperatorInfo, type OpShift, type Order,
  type PrevSchedule, type Schedule, type Slot, type Window,
  OPS, dayIndex, finishInfo, flowOf, isWorkday, makeCalendar, nextWorkday, peopleOf, schedule, shiftPlan, toMin,
} from './scheduler';
import { type Levers, type OptResult, optimize } from './optimize';

type Db = SupabaseClient;
const app = (db: Db) => db.schema('app');

export const ROLE = {
  plan: ['SX_TP', 'SX_KH', 'BGD'],          // xếp lịch máy
  release: ['SX_TP', 'SX_KH'],              // phát lệnh ngày, lập đơn phát sinh
  params: ['BGD'],                           // ca, tham số chung, cách nhập dữ liệu, hạn giao
  rates: ['KT_TP'],                          // tốc độ chuẩn, phút đổi máy
  sample: ['KT_TP', 'QC'],                   // duyệt mẫu đầu ca/đầu mã
  submit: ['VAN_HANH', 'TO_TRUONG', 'SX_TP', 'KT_KHO'], // nhập báo cáo ca (Kế toán SX nhập từ tờ giấy)
  confirm: ['TO_TRUONG', 'SX_TP'],           // xác nhận ca
  slip: ['KT_KHO'],                          // duyệt phiếu lĩnh
};
export const hasRole = (roles: string[], list: string[]) => list.some((r) => roles.includes(r));

// Ngày giờ theo giờ Việt Nam (mặc định: bây giờ)
export function vnNow(at: Date = new Date()) {
  const p = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Ho_Chi_Minh', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false })
    .formatToParts(at);
  const g = (t: string) => p.find((x) => x.type === t)?.value ?? '00';
  return { date: `${g('year')}-${g('month')}-${g('day')}`, min: (Number(g('hour')) % 24) * 60 + Number(g('minute')) };
}

// Một thời điểm (ngày + phút trong ngày, giờ VN) đổi ra phút xếp lịch; ngày nghỉ → đầu ngày làm việc kế tiếp
export function timeT(cal: Calendar, t: { date: string; min: number }): number {
  const di = dayIndex(cal, t.date);
  if (cal.SPD > 1 && isWorkday(t.date, cal.wd)) {
    // nhiều ca: giờ nằm trong ca nào thì tính theo giờ ca đó; giữa hai ca → đầu ca sau; sau ca cuối → hết ngày
    for (let j = 0; j < cal.SPD; j++) {
      const a = toMin(cal.shifts[j].start_time); let b = toMin(cal.shifts[j].end_time); if (b <= a) b += 1440;
      if (t.min < a) return (di * cal.SPD + j) * cal.S;
      if (t.min < b) return (di * cal.SPD + j + (t.min - a) / (b - a)) * cal.S;
    }
    return (di + 1) * cal.SPD * cal.S;
  }
  const first = cal.shifts[0] ? toMin(cal.shifts[0].start_time) : 360;
  const shiftLen = cal.shifts[0] ? cal.RUN + Number(cal.shifts[0].break_min) : 480;
  const sIn = isWorkday(t.date, cal.wd) ? Math.max(0, Math.min(cal.SPD, (t.min - first) / shiftLen)) : 0;
  return (di * cal.SPD + sIn) * cal.S;
}

// Phiếu bảo dưỡng định kỳ đang mở (app.v_kh_maint)
export type MaintRow = {
  id: string; wo_no: string; title: string; status: string; plan_id: string | null; planned_date: string | null; est_minutes: number | null; off_shift: boolean;
  sched_mode: 'IN_SHIFT' | 'CHANGEOVER' | 'OFF_SHIFT' | null; sched_status: 'PROPOSED' | 'CONFIRMED' | null; sched_note: string | null;
  sched_at: string | null; sched_ok_at: string | null; sched_by_name: string | null; sched_ok_by_name: string | null; sched_by: string | null;
  unit_code: string; machine_code: string; plan_name: string | null; level: string | null; kind: string | null; stop_minutes: number | null; in_frozen: boolean;
};
const hm = (iso: string) => { const v = vnNow(new Date(iso)); return `${String(Math.floor(v.min / 60)).padStart(2, '0')}:${String(v.min % 60).padStart(2, '0')} ${v.date.slice(8, 10)}/${v.date.slice(5, 7)}`; };

// Kế hoạch bảo dưỡng của dây chuyền xếp lịch (plan.kh_maint_due): để lịch máy tự giữ chỗ tạm
export type MaintPlanRow = {
  id: string; name: string; level: string | null; line_code: string; due_date: string; trigger: 'DAYS' | 'HOURS' | 'KM' | null; state: string;
  every_hours: number | null; every_km: number | null; used_hours: number | null; used_km: number | null; stop_minutes: number; off_shift: boolean;
  open_wo: string | null; open_wo_no: string | null;
};
// Ngày đến hạn bảo dưỡng theo giờ chạy / km: cộng giờ, km đã chạy với giờ, mét của lịch đang dùng trên máy (từ bây giờ);
// lịch không đủ dài thì dùng ngày database ước tính theo nhịp chạy thực tế
export function maintDueDate(p: MaintPlanRow, sch: Schedule | null, cal: Calendar, nowT: number): string {
  if (!sch || (p.trigger !== 'HOURS' && p.trigger !== 'KM')) return p.due_date;
  const left = p.trigger === 'HOURS' ? (Number(p.every_hours) - Number(p.used_hours ?? 0)) * 60 : (Number(p.every_km) - Number(p.used_km ?? 0)) * 1000;
  if (!(left > 0)) return p.due_date;
  let acc = 0;
  for (const sl of (sch.byMachine.get(p.line_code) ?? []).filter((x) => x.end > nowT).sort((a, b) => a.runStart - b.runStart)) {
    const from = Math.max(sl.runStart, nowT), len = Math.max(0, sl.end - from);
    const add = p.trigger === 'HOURS' ? len : sl.rate * len;
    if (acc + add >= left) {
      const t = from + (p.trigger === 'HOURS' ? left - acc : (left - acc) / Math.max(1e-9, sl.rate));
      const di = Math.floor(t / (cal.S * cal.SPD));
      return cal.days[Math.min(Math.max(0, di), cal.days.length - 1)];
    }
    acc += add;
  }
  return p.due_date;
}

// Khoảng máy không chạy được theo lịch cal:
//  - Dừng / hỏng / bảo dưỡng đến giờ dự kiến chạy lại (chưa có giờ: tạm đến hết ngày làm việc kế tiếp), ngừng dùng;
//  - bảo dưỡng đã chốt "trong ca" (khối giữ chỗ = phút dừng máy quy ra phút xếp lịch);
//  - giữ chỗ tạm: phiếu bảo dưỡng đã đề xuất / chưa chốt, kế hoạch bảo dưỡng đến hạn chưa có phiếu (theo ngày, giờ chạy, km).
export function machineWindows(machines: MachineInfo[], maint: MaintRow[], cal: Calendar, now: { date: string; min: number },
  plans: MaintPlanRow[] = [], sch: Schedule | null = null): Window[] {
  const nowT = timeT(cal, now);
  const DAY = cal.SPD * cal.S;
  const out: Window[] = [];
  // hết ngày làm việc kế tiếp sau hôm nay (theo ngày VN; sau giờ ca hay ngày nghỉ vẫn tính đúng một ngày làm việc)
  const nextEnd = (dayIndex(cal, nextWorkday(addDays1(now.date), cal.wd)) + 1) * DAY;
  for (const m of machines) {
    if (m.status === 'OFF') out.push({ machine: m.code, from: nowT, to: Infinity, kind: 'OFF', label: `${m.code} ngừng dùng` });
    else if (m.status === 'DOWN' || m.status === 'MAINT' || m.status === 'STOP') {
      const etaT = m.status_eta ? timeT(cal, vnNow(new Date(m.status_eta))) : null;
      // giờ chạy lại đã qua mà máy vẫn chưa chạy: coi như chưa có giờ (máy vẫn không chạy được)
      const passed = m.status_eta != null && new Date(m.status_eta).getTime() <= Date.now();
      const to = etaT != null && !passed ? etaT : nextEnd;
      const what = m.status === 'DOWN' ? 'hỏng' : m.status === 'STOP' ? 'dừng' : 'bảo dưỡng';
      const note = !m.status_eta ? ' (chưa có giờ chạy lại, tạm tính hết ngày làm việc kế tiếp)'
        : passed ? ` (giờ chạy lại ${hm(m.status_eta)} đã qua, máy chưa chạy: tạm tính hết ngày làm việc kế tiếp)` : `, dự kiến chạy lại ${hm(m.status_eta)}`;
      if (to > nowT) out.push({ machine: m.code, from: nowT, to, kind: m.status, label: `${m.code} ${what}${note}` });
    }
  }
  const pmLen = (min: number) => (Number(min) * cal.S) / Math.max(1, cal.RUN);
  const lineOf = (code: string) => machines.some((m) => m.code === code) ? code : null;
  const reserved = new Set<string>();
  for (const w of maint) {
    if (w.status !== 'OPEN' || !lineOf(w.machine_code)) continue;
    if (w.sched_mode && w.sched_mode !== 'IN_SHIFT') continue;   // gộp lần đổi máy lớn / ngoài giờ ca: không chặn giờ máy
    // phiếu chưa có ngày, đã quá ngày hoặc đã qua giờ giữ chỗ mà chưa làm: giữ chỗ tạm ngày làm việc kế tiếp; ngày nghỉ: dời sang ngày làm việc
    const mins = Number(w.est_minutes ?? w.stop_minutes ?? 0);
    if (!(mins > 0)) continue;
    const tomorrow = nextWorkday(addDays1(now.date), cal.wd);
    let late = !w.planned_date || w.planned_date < now.date;
    let day = late ? tomorrow : nextWorkday(w.planned_date!, cal.wd);
    let from = dayIndex(cal, day) * DAY, to = from + pmLen(mins);
    if (!(to > nowT)) { late = true; day = tomorrow; from = dayIndex(cal, day) * DAY; to = from + pmLen(mins); }
    if (from >= cal.days.length * DAY || !(to > nowT)) continue;
    const moved = day !== w.planned_date;
    if (w.plan_id) reserved.add(w.plan_id);
    if (w.sched_status === 'CONFIRMED' && !moved) out.push({ machine: w.machine_code, from, to, kind: 'PM', label: `bảo dưỡng ${w.wo_no} (${mins} phút, đã chốt)` });
    else out.push({ machine: w.machine_code, from, to, kind: 'PM', tentative: true,
      label: `bảo dưỡng ${w.wo_no} (${mins} phút, giữ chỗ tạm${!w.planned_date ? ', chưa có ngày'
        : moved ? `, ngày ${w.planned_date.slice(8, 10)}/${w.planned_date.slice(5, 7)} ${late ? 'chưa làm' : 'là ngày nghỉ'}` : ''}, chờ TP SX chốt)` });
  }
  // Kế hoạch bảo dưỡng đến hạn chưa có phiếu: giữ chỗ tạm đầu ngày đến hạn (đã quá hạn: ngày làm việc kế tiếp)
  for (const p of plans) {
    if (p.open_wo || p.off_shift || !(Number(p.stop_minutes) > 0) || reserved.has(p.id) || !lineOf(p.line_code)) continue;
    let d = maintDueDate(p, sch, cal, nowT);
    if (d <= now.date) d = nextWorkday(addDays1(now.date), cal.wd);
    d = nextWorkday(d, cal.wd);
    const from = dayIndex(cal, d) * DAY, to = from + pmLen(p.stop_minutes);
    if (from >= cal.days.length * DAY || !(to > nowT)) continue;
    const by = p.trigger === 'HOURS' ? 'theo giờ chạy' : p.trigger === 'KM' ? 'theo km' : 'theo ngày';
    out.push({ machine: p.line_code, from, to, kind: 'PM', tentative: true, label: `bảo dưỡng ${p.name} (${p.stop_minutes} phút, đến hạn ${by}, giữ chỗ tạm)` });
  }
  return out;
}
const addDays1 = (d: string) => { const x = new Date(d + 'T00:00:00Z'); x.setUTCDate(x.getUTCDate() + 1); return x.toISOString().slice(0, 10); };

export async function loadConfig(db: Db) {
  const [{ data: c, error }, { data: m }, { data: o }] = await Promise.all([
    app(db).from('v_kh_config').select('*').single(),
    app(db).from('v_kh_machines').select('*').order('code'),
    app(db).from('v_kh_operators').select('*').order('sort'),
  ]);
  if (error || !c) throw new Error('Không đọc được tham số xếp lịch: ' + (error?.message ?? 'trống'));
  const cfg: Config = {
    fill_pct: Number(c.fill_pct), frozen_days: Number(c.frozen_days), cutoff_time: String(c.cutoff_time).slice(0, 5),
    downtime_reason_min: Number(c.downtime_reason_min), plc_dev_pct: Number(c.plc_dev_pct), auto_shifts: Number(c.auto_shifts),
    plc_loss_min: Number(c.plc_loss_min), machines_per_operator: Number(c.machines_per_operator),
    shifts: (c.shifts ?? []).map((s: Record<string, unknown>) => ({ ...s, start_time: String(s.start_time).slice(0, 5), end_time: String(s.end_time).slice(0, 5), break_min: Number(s.break_min) })),
    rates: (c.rates ?? []).map((r: Record<string, unknown>) => ({ ...r, rate_small: Number(r.rate_small), rate_large: Number(r.rate_large) })),
    changeovers: (c.changeovers ?? []).map((r: Record<string, unknown>) => ({ ...r, minutes: Number(r.minutes) })),
    workdays: Array.isArray(c.workdays) && c.workdays.length ? (c.workdays as number[]).map(Number) : null,
    group_days: Number(c.group_days ?? 7),
    speeds: ((c.speeds ?? []) as Record<string, unknown>[]).map((x) => ({
      ...x, std_mpm: Number(x.std_mpm), rated_mpm: x.rated_mpm == null ? null : Number(x.rated_mpm), max_mpm: x.max_mpm == null ? null : Number(x.max_mpm),
    })) as Config['speeds'],
    plc_speeds: ((c.plc_speeds ?? []) as Record<string, unknown>[]).map((x) => ({ ...x, meters: Number(x.meters), run_min: Number(x.run_min) })) as Config['plc_speeds'],
  } as Config;
  // Thông số dòng chảy (migration 4800): QC dùng số tự học (làm tròn 10 phút) khi bật và đủ mẫu;
  // tăng ca / trộn sớm đã duyệt chỉ tính trong khoảng ngày áp dụng (bộ xếp lịch kiểm theo từng ngày)
  const learned = (c.qc_learned ?? {}) as { median_min?: number | null; n?: number };
  const qcSet = c.qc_min == null ? undefined : Number(c.qc_min);
  const useLearned = c.qc_learn !== false && Number(learned.n ?? 0) >= QC_LEARN_MIN_SAMPLES && Number(learned.median_min) > 0;
  const num = (v: unknown) => (v == null || v === '' ? undefined : Number(v));
  cfg.flow = {
    qc_min: useLearned ? Math.max(10, Math.round(Number(learned.median_min) / 10) * 10) : qcSet,
    unit_m: (c.unit_m ?? undefined) as FlowCfg['unit_m'],
    safety_min: (c.safety_min ?? undefined) as FlowCfg['safety_min'],
    pot_life_h: num(c.pot_life_h), mix_batch_kg: num(c.mix_batch_kg),
    mix_early_h: num(c.mix_early_h) ?? 0,
    extra_min: Object.fromEntries(Object.entries((c.extra_min ?? {}) as Record<string, unknown>).map(([k, v]) => [k, Number(v)]).filter(([, v]) => Number(v) > 0)),
    ot_from: (c.ot_from as string | null) ?? null, ot_until: (c.ot_until as string | null) ?? null,
    size_large_mm2: num(c.size_large_mm2), plc_min_run: num(c.plc_min_run), pick_window_min: c.pick_window_min == null ? null : Number(c.pick_window_min),
  };
  const flowMeta = {
    qc_set: qcSet ?? 120, qc_learn: c.qc_learn !== false, qc_learned: { median: learned.median_min == null ? null : Number(learned.median_min), n: Number(learned.n ?? 0) }, qc_used: flowOf(cfg).qc_min,
    levers: { ot_max_min: num(c.ot_max_min) ?? 240, ot_month_h: num(c.ot_month_h) ?? 40, early_max_h: num(c.mix_early_max_h) ?? 0, day_max_h: num(c.day_max_h) ?? 12 },
    ot: { extra_min: (c.extra_min ?? {}) as Record<string, number>, mix_early_h: Number(c.mix_early_h ?? 0), from: (c.ot_from as string | null) ?? null, until: (c.ot_until as string | null) ?? null,
      request_id: (c.ot_request_id as string | null) ?? null,
      // đang có hiệu lực hôm nay (view tính theo giờ VN)
      active: Object.keys((c.extra_min_now ?? {}) as object).length > 0 || Number(c.mix_early_h_now ?? 0) > 0,
      planned: Object.keys(cfg.flow.extra_min ?? {}).length > 0 || Number(cfg.flow.mix_early_h) > 0 },
  };
  // Người đứng máy (migration 5000): phút có mặt, tổ đóng gói, lịch vắng, kiêm nhiệm tạm; tỷ lệ xếp lịch riêng từng máy
  cfg.people = {
    start_min: num(c.start_min), bobbin_min: num(c.bobbin_min), watch_max: num(c.watch_max), pack_crew: num(c.pack_crew), pack_one_pct: num(c.pack_one_pct),
    absences: ((c.absences ?? []) as Absence[]), covers: ((c.covers ?? []) as Cover[]), crews: ((c.crews ?? []) as CrewDay[]),
    // Máy chạy 2–3 ca (migration 5300): ca của người, giờ làm tối đa/ngày, làm thêm tối đa ngày / tháng (ca dài khi thiếu người)
    op_shifts: ((c.op_shifts ?? []) as OpShift[]).map((x) => ({ ...x, shift: Number(x.shift) })),
    day_max_h: num(c.day_max_h), ot_day_min: num(c.ot_max_min), ot_month_h: num(c.ot_month_h),
    // Luân phiên đứng máy (migration 5400): sổ giờ đứng máy theo lịch, ngưỡng lệch, ngày ca 2 / ca 3 có người đo mẫu QC
    ledger: ((c.op_hours ?? []) as { code: string; date: string; min: number }[]).map((x) => ({ code: x.code, date: String(x.date), min: Number(x.min) })),
    balance_pct: num(c.balance_pct),
    qc_cover: ((c.qc_cover ?? []) as { from: string; to: string }[]).map((x) => ({ from: String(x.from), to: String(x.to) })),
  };
  cfg.machine_shifts = ((c.machine_shifts ?? []) as MachineShift[]).map((x) => ({ ...x, shifts: Number(x.shifts) }));
  cfg.avail = Object.fromEntries(Object.entries((c.avail ?? {}) as Record<string, { fill: number; down_pct?: number; days?: number }>)
    .map(([k, v]) => [k, { fill: Number(v.fill), down_pct: Number(v.down_pct ?? 0), days: Number(v.days ?? 0) }]));
  const maintPlans = ((c.maint_plans ?? []) as MaintPlanRow[]).map((p) => ({ ...p, stop_minutes: Number(p.stop_minutes) }));
  const ORDER = ['SIL-MIX', 'BUN-01', 'EXT-SI-01', 'EXT-SI-02', 'TWS-01', 'EXT-TP-01', 'EXT-TP-02', 'PACK-01'];
  const machines = ((m ?? []) as MachineInfo[]).map((x) => ({ ...x, tag_count: Number(x.tag_count) }))
    .sort((a, b) => (ORDER.indexOf(a.code) + 1 || 99) - (ORDER.indexOf(b.code) + 1 || 99) || a.code.localeCompare(b.code));
  return { cfg, machines, operators: (o ?? []) as OperatorInfo[], updated_at: c.updated_at as string | null, flowMeta, maintPlans };
}
// Số mẫu QC tối thiểu (30 ngày) để MES dùng thời gian QC thực tế thay số TP KT/QA nhập
export const QC_LEARN_MIN_SAMPLES = 10;
// Dấu vân tay thông số dòng chảy: đổi (TP KT/QA sửa, tăng ca được duyệt/hết hạn, QC tự học thay đổi) thì lịch đang dùng cần xếp lại
export const flowSig = (cfg: Pick<Config, 'flow'>) => JSON.stringify(flowOf(cfg));
// Dấu vân tay thông số người đứng máy + tỷ lệ xếp lịch riêng (làm tròn %): đổi thì lịch cần xếp lại.
// Lịch vắng, kiêm nhiệm, tổ đóng gói đổi thì ghi nhật ký tham số nên cũng làm lịch cần xếp lại.
export const peopleSig = (cfg: Pick<Config, 'people' | 'avail'>) => {
  const p = peopleOf(cfg);
  return JSON.stringify([p.start_min, p.bobbin_min, p.watch_max, p.pack_crew, p.pack_one_pct, ...(p.balance_pct !== 15 ? [p.balance_pct] : []),
    Object.entries(cfg.avail ?? {}).map(([k, v]) => k + ':' + Math.round(Number(v.fill))).sort()]);
};
// Thứ tự lô bộ tối ưu đã chọn (lưu trong phiên bản lịch): lô mới thêm chen theo hạn giao
export function applySeq(orders: Order[], seq?: Record<string, number> | null): Order[] {
  if (!seq || !Object.keys(seq).length) return orders;
  const due = (o: Order) => o.commit ?? o.due ?? '9999-12-31';
  const known = orders.filter((o) => seq[o.id] != null).sort((a, b) => seq[a.id] - seq[b.id]);
  const list = [...known];
  for (const o of orders.filter((x) => seq[x.id] == null).sort((a, b) => due(a).localeCompare(due(b)))) {
    const at = list.findIndex((x) => due(x) > due(o));
    if (at < 0) list.push(o); else list.splice(at, 0, o);
  }
  const pos = new Map(list.map((o, i) => [o.id, i]));
  return orders.map((o) => ({ ...o, seq: pos.get(o.id)! }));
}

type LineRow = {
  id: string; plan_id: string; qty_m: number; due_date: string | null; priority: number; change_request_id: string | null; line_no: number;
  product_code: string; product_name: string; group_code: string; cores: number; insulation: string | null; shield: boolean | null;
  sheath_color: string | null; single_color: string | null; core_colors: string[] | null; route: string[] | null; size_mm2: number;
  so_no: string | null; spec_status: string; plan_no: string; plan_status: string; sched_start: string | null;
  product_id: string | null; core_code: string | null; mix_kg_km?: number | null;
  committed_date?: string | null; committed_note?: string | null; committed_by_name?: string | null;
  lot_approved_at?: string | null; lot_approved_by_name?: string | null; eta_date?: string | null; adjustment_id?: string | null;
};
export type OrderMeta = {
  group: string; size: number; cores: string[]; sheath: string | null; sil: boolean; shield: boolean; route: Op[];
  product_id?: string | null; core?: string | null; mix?: number | null;
};

export function orderFrom(r: Omit<LineRow, 'plan_id' | 'plan_no' | 'plan_status' | 'sched_start' | 'line_no' | 'qty_m' | 'due_date' | 'priority' | 'change_request_id' | 'so_no' | 'id'> & Partial<LineRow>, label: string): Order {
  // Trộn silicone chỉ xếp khi BOM có hỗn hợp cần trộn (kg/km cáp)
  const mix = Number(r.mix_kg_km) || 0;
  const route = ((r.route ?? []) as string[]).filter((x): x is Op => (OPS as string[]).includes(x) && (x !== 'CD0' || mix > 0));
  const n = Math.max(1, Number(r.cores) || 1);
  let cores = (r.core_colors ?? []).filter(Boolean);
  if (n === 1 && r.single_color) cores = [r.single_color];
  if (!cores.length) cores = Array.from({ length: n }, (_, i) => `Lõi ${i + 1}`);
  return {
    id: r.id ?? '', label, product_code: r.product_code, product_name: r.product_name ?? '', group: r.group_code,
    size: Number(r.size_mm2) || 0, cores, sheath: route.includes('CD5') ? (r.sheath_color || 'Chưa rõ màu') : null,
    sil: (r.insulation ?? '').toUpperCase().startsWith('SIL'), shield: Boolean(r.shield), route,
    qty: Number(r.qty_m) || 0, due: r.due_date ?? null, commit: r.committed_date ?? null, prio: Number(r.priority ?? 1),
    source: r.so_no ?? (r.change_request_id ? 'Đơn phát sinh' : r.adjustment_id ? 'Hiệu chỉnh kế hoạch' : 'Kế hoạch tháng'),
    product_id: r.product_id ?? null, core: r.core_code ?? null, mix: mix || null,
  };
}
export const metaOf = (o: Order): OrderMeta => ({
  group: o.group, size: o.size, cores: o.cores, sheath: o.sheath, sil: o.sil, shield: o.shield, route: o.route, product_id: o.product_id ?? null, core: o.core ?? null, mix: o.mix ?? null,
});
// Dấu vân tay tốc độ khai báo theo máy: đổi (duyệt, thêm, bỏ) thì lịch đang dùng cần xếp lại
export const speedSig = (cfg: Pick<Config, 'speeds'>) => (cfg.speeds ?? [])
  .map((x) => [x.machine_code, x.op_code, x.product_id ?? '', x.group_code ?? '', x.core_code ?? '', x.std_mpm, x.rated_mpm ?? '', x.max_mpm ?? '', x.status].join(':'))
  .sort().join('|');

export type VersionRow = {
  id: string; plan_id: string; version: number; is_current: boolean; base_date: string; created_at: string; created_by_name: string | null;
  reason: string; change_no: string | null;
  // Từ 28/10/2026: TP SX xếp → bản đề xuất (PROPOSED) chờ Giám đốc duyệt mới thành lịch đang dùng
  status?: 'PROPOSED' | 'APPROVED' | 'RETURNED' | 'SUPERSEDED'; approved_at?: string | null; approved_by_name?: string | null; review_note?: string | null; created_by?: string | null;
  params: { S: number; SPD: number; RUN: number; fill_pct: number; frozen_days: number; machines_per_operator: number; plan_no?: string; workdays?: number[];
    group_days?: number; speeds_sig?: string; flow_sig?: string; people_sig?: string; seq?: Record<string, number>; flow?: unknown; shifts: { code: string; start_time: string; end_time: string; break_min: number }[] };
};

export type Kh = Awaited<ReturnType<typeof loadKh>>;

// Dữ liệu cho các màn hình: kế hoạch đang chọn, lịch máy đang dùng, lệnh, ngày xong
export async function loadKh(db: Db, opts: { plan?: string | null; roles: string[]; ver?: string | null }) {
  const base = await loadConfig(db);
  const now = vnNow();
  // Kế hoạch: người xem được kế hoạch tháng chọn trong danh sách; người khác xem lịch đang dùng mới nhất
  const { data: plans } = await app(db).from('v_plans').select('id, plan_no, period_label, status, created_at').neq('status', 'CANCELLED').order('created_at', { ascending: false });
  const { data: vers } = await app(db).from('v_kh_versions').select('*').eq('is_current', true).order('created_at', { ascending: false });
  const current = (vers ?? []) as VersionRow[];
  const visiblePlans = (plans ?? []) as { id: string; plan_no: string; period_label: string; status: string }[];
  let planId = opts.plan ?? null;
  if (!planId) planId = visiblePlans.find((p) => p.status === 'APPROVED' && current.some((v) => v.plan_id === p.id))?.id
    ?? visiblePlans.find((p) => current.some((v) => v.plan_id === p.id))?.id
    ?? visiblePlans.find((p) => p.status === 'APPROVED')?.id ?? visiblePlans[0]?.id ?? current[0]?.plan_id ?? null;
  const plan = visiblePlans.find((p) => p.id === planId) ?? null;
  const currentVersion = current.find((v) => v.plan_id === planId) ?? null;
  // Bản lịch TP SX xếp đang chờ Giám đốc duyệt; xem một bản khác (đề xuất, bản cũ) qua opts.ver
  const [{ data: propRows }, { data: verRow }] = await Promise.all([
    planId ? app(db).from('v_kh_versions').select('*').eq('plan_id', planId).eq('status', 'PROPOSED').order('created_at', { ascending: false }).limit(1)
      : Promise.resolve({ data: [] as VersionRow[] }),
    opts.ver && planId ? app(db).from('v_kh_versions').select('*').eq('id', opts.ver).eq('plan_id', planId).maybeSingle() : Promise.resolve({ data: null }),
  ]);
  const proposal = ((propRows ?? [])[0] ?? null) as VersionRow | null;
  const version = (verRow as VersionRow | null) ?? currentVersion;
  const viewingOther = Boolean(version && version.id !== currentVersion?.id);

  const [{ data: lineRows }, { data: ordRows }, { data: slotRows }, { data: lastLog }, { data: maintRows }] = await Promise.all([
    planId && plan ? app(db).from('v_kh_plan_lines').select('*').eq('plan_id', planId).order('line_no') : Promise.resolve({ data: [] as LineRow[] }),
    version ? app(db).from('v_kh_orders').select('*').eq('version_id', version.id) : Promise.resolve({ data: [] as Record<string, unknown>[] }),
    version ? app(db).from('v_kh_slots').select('*').eq('version_id', version.id).order('start_min') : Promise.resolve({ data: [] as Record<string, unknown>[] }),
    app(db).from('v_kh_param_log').select('at').order('at', { ascending: false }).limit(1),
    app(db).from('v_kh_maint').select('*').order('planned_date', { nullsFirst: false }),
  ]);
  const maint = (maintRows ?? []) as MaintRow[];
  const lines = (lineRows ?? []) as LineRow[];
  // Lệnh: lấy từ kế hoạch tháng (đang có hiệu lực); không xem được kế hoạch thì lấy bản lưu kèm lịch
  let orders: Order[] = lines.map((l) => orderFrom(l, `D${String(l.line_no).padStart(2, '0')}`)).filter((o) => o.route.length && o.qty > 0);
  const fromPlan = orders.length > 0;
  if (!fromPlan && ordRows?.length) {
    orders = (ordRows as Record<string, unknown>[]).map((r) => {
      const m = (r.meta ?? {}) as Partial<OrderMeta>;
      return {
        id: String(r.plan_line_id), label: String(r.label), product_code: String(r.product_code), product_name: String(r.product_name ?? ''),
        group: String(r.group_code ?? m.group ?? ''), size: Number(m.size ?? 0), cores: m.cores ?? [], sheath: m.sheath ?? null,
        sil: Boolean(m.sil), shield: Boolean(m.shield), route: ((m.route ?? []) as Op[]).filter((x) => x !== 'CD0' || Number(m.mix) > 0), qty: Number(r.qty_m), due: (r.due_date as string) ?? null,
        prio: Number(r.priority ?? 1), source: String(r.source ?? ''), product_id: m.product_id ?? null, core: m.core ?? null, mix: m.mix ?? null,
      } as Order;
    }).sort((a, b) => a.label.localeCompare(b.label));
  }
  // Thứ tự lô bộ tối ưu đã chọn ở lần xếp lịch (lô mới chen theo hạn giao)
  orders = applySeq(orders, version?.params.seq);
  const planStatus = lines[0]?.plan_status ?? plan?.status ?? null;
  const planNo = plan?.plan_no ?? version?.params.plan_no ?? lines[0]?.plan_no ?? '';
  const schedStart = lines[0]?.sched_start ?? null;

  // Lịch đang dùng (đã lưu)
  let cal: Calendar;
  let sch: Schedule | null = null;
  if (version) {
    const p = version.params;
    cal = makeCalendar({ fill_pct: p.fill_pct, shifts: p.shifts.map((s) => ({ ...s, active: true })), workdays: p.workdays ?? base.cfg.workdays }, version.base_date);
    cal.S = p.S; cal.SPD = p.SPD; cal.RUN = p.RUN;
    const slots: Slot[] = ((slotRows ?? []) as Record<string, unknown>[]).map((r) => ({
      id: String(r.id), key: `${r.plan_line_id}|${r.op_code}|${r.color ?? ''}`, lineId: String(r.plan_line_id), op: r.op_code as Op,
      color: (r.color as string) ?? null, machine: String(r.machine_code), operator: (r.operator_code as string) ?? null, lane: Number(r.lane ?? 0),
      start: Number(r.start_min), runStart: Number(r.run_start_min), end: Number(r.end_min), setup: Number(r.setup_min), meters: Number(r.meters),
      rate: Number(r.rate), speed: Number(r.speed), reason: String(r.reason ?? ''), why: String(r.setup_why ?? ''), part: Boolean(r.part),
      attend: Array.isArray(r.attend) ? (r.attend as Attend[]).map((a) => ({ ...a, f: Number(a.f), t: Number(a.t) })) : undefined,
      crew: r.crew == null ? undefined : Number(r.crew),
    }));
    const byMachine = new Map(base.machines.map((m) => [m.code, slots.filter((s) => s.machine === m.code)]));
    const opDone = new Map<string, { start: number; end: number; left: number }>();
    for (const o of orders) for (const op of o.route) opDone.set(o.id + '|' + op, { start: Infinity, end: 0, left: 0 });
    for (const s of slots) { const d = opDone.get(s.lineId + '|' + s.op); if (d) { d.start = Math.min(d.start, s.runStart); d.end = Math.max(d.end, s.end); } }
    // lệnh có trong kế hoạch nhưng chưa có trong lịch (thêm sau): đánh dấu chưa xếp
    const inSched = new Set(slots.map((s) => s.lineId));
    for (const o of orders) if (!inSched.has(o.id)) for (const op of o.route) opDone.get(o.id + '|' + op)!.left = 1;
    sch = { slots, byMachine, opDone, unplaced: [], S: p.S, SPD: p.SPD, RUN: p.RUN };
  } else {
    cal = makeCalendar(base.cfg, nextWorkday(schedStart && schedStart > now.date ? schedStart : now.date, base.cfg.workdays ?? undefined));
  }
  const fin = sch ? finishInfo(sch, cal, orders) : new Map();

  // Mốc thời gian: hôm nay, bây giờ, vùng khóa
  const todayIdx = dayIndex(cal, now.date);
  const S = cal.S, SPD = cal.SPD;
  const first = cal.shifts[0] ? toMin(cal.shifts[0].start_time) : 360;
  const shiftLen = cal.shifts[0] ? cal.RUN + Number(cal.shifts[0].break_min) : 480;
  const el = now.min - first;
  const sIn = el <= 0 ? 0 : Math.min(SPD, el / shiftLen);
  const nowT = SPD > 1 && todayIdx >= 0 && cal.days.includes(now.date) ? Math.max(0, timeT(cal, now))
    : Math.max(0, (todayIdx * SPD + (todayIdx >= 0 && cal.days.includes(now.date) ? sIn : 0)) * S);
  const frozenFrom = Math.max(0, todayIdx), frozenTo = Math.max(0, todayIdx + base.cfg.frozen_days);

  // Lịch cần xếp lại khi tham số đổi sau lần xếp gần nhất
  const cfgCal = makeCalendar(base.cfg, cal.base);
  const lastParamAt = (lastLog?.[0]?.at as string | undefined) ?? null;
  const dirty = Boolean(version && (cfgCal.S !== version.params.S || cfgCal.SPD !== version.params.SPD
    || base.cfg.machines_per_operator !== Number(version.params.machines_per_operator)
    || cfgCal.wd.join() !== cal.wd.join()
    || (version.params.speeds_sig ?? '') !== speedSig(base.cfg)
    || (version.params.flow_sig ?? '') !== flowSig(base.cfg)
    || (version.params.people_sig !== undefined && version.params.people_sig !== peopleSig(base.cfg))
    || (lastParamAt && lastParamAt > version.created_at)));
  const missing = version ? orders.filter((o) => !sch!.slots.some((s) => s.lineId === o.id)) : [];

  // Máy hỏng / bảo dưỡng / ngừng dùng: lịch đang dùng còn việc trong khoảng máy không chạy được → cần xếp lại
  const windows = machineWindows(base.machines, maint, cal, now, base.maintPlans, sch);
  const machAlerts: string[] = [];
  for (const m of base.machines) if ((m.status === 'STOP' || m.status === 'DOWN' || m.status === 'MAINT')
    && (!m.status_eta || new Date(m.status_eta).getTime() <= Date.now()))
    machAlerts.push(`${m.code} ${m.status === 'DOWN' ? 'hỏng' : m.status === 'STOP' ? 'dừng' : 'bảo dưỡng'} ${m.status_eta ? `quá giờ dự kiến chạy lại (${hm(m.status_eta)}) mà chưa chạy` : 'chưa có giờ dự kiến chạy lại'}: MES tạm không xếp việc đến hết ngày làm việc kế tiếp. TP KT/QA nhập giờ chạy lại mới (hoặc chuyển máy về Chờ việc nếu đã chạy được) ở Hồ sơ máy`);
  if (sch) for (const w of windows) {
    const n = sch.slots.filter((x) => x.machine === w.machine && x.end > w.from + 1 && x.start < w.to - 1 && x.end > nowT).length;
    if (n) machAlerts.push(`${w.label}: lịch đang dùng còn ${n} việc trên máy trong thời gian này`);
  }
  if (version) for (const m of base.machines) {
    if ((m.status === 'IDLE' || m.status === 'RUN') && m.status_since && m.status_since > version.created_at && !windows.some((w) => w.machine === m.code))
      machAlerts.push(`${m.code} chuyển ${m.status === 'RUN' ? 'Đang chạy' : 'Chờ việc'} lúc ${hm(m.status_since)}${m.status_note ? ` (${m.status_note})` : ''}, sau lần xếp lịch gần nhất: máy vừa sửa xong thì xếp lại để dùng lại máy`);
  }

  return {
    ...base, now, plans: visiblePlans, planId, planNo, planStatus, schedStart, lines, orders, fromPlan, version, currentVersion, proposal, viewingOther, cal, sch, fin,
    todayIdx, nowT, frozenFrom, frozenTo, dirty, missing, roles: opts.roles, maint, windows, machAlerts,
  };
}

// Dựng lịch mới (xếp lại) từ dữ liệu hiện tại; giữ phần trước mốc.
// Máy hỏng / ngừng dùng / bảo dưỡng đã chốt rơi vào vùng khóa: xếp lại từ ngày mai để chuyển việc sang máy cùng loại.
// optimize: chạy bộ tối ưu (đổi thứ tự lô để ít trễ hạn, xong sớm, ít đổi máy; không tự thêm giờ tăng ca) – dùng khi bấm Xếp lịch
// fromDate: xếp lại từ ngày này nếu sớm hơn hết vùng khóa (bảng ca tuần vừa duyệt: tuần mới áp dụng ca máy, ca người mới; không sớm hơn ngày mai)
export function rebuild(kh: Kh, orders: Order[], opt: { split?: boolean; credit?: Map<string, number>; optimize?: boolean; levers?: Levers; fromDate?: string | null } = {}) {
  const base = kh.version ? kh.version.base_date : kh.cal.base;
  const cal = makeCalendar(kh.cfg, base);
  const todayIdx = dayIndex(cal, kh.now.date);
  const windows = machineWindows(kh.machines, kh.maint, cal, kh.now, kh.maintPlans, kh.sch);
  const frozenEnd = Math.max(0, todayIdx + kh.cfg.frozen_days) * cal.SPD * cal.S;
  // Máy hỏng / dừng / ngừng dùng / bảo dưỡng đã chốt mà lịch đang dùng còn việc trên máy đó trong vùng khóa: xếp lại từ ngày mai
  // (chuyển việc sang máy cùng loại); giữ chỗ bảo dưỡng tạm (chưa chốt) hay máy không có việc trong vùng khóa thì giữ vùng khóa
  const oldFrozen = Math.max(0, kh.todayIdx + kh.cfg.frozen_days) * kh.cal.SPD * kh.cal.S;
  const early = frozenEnd > 0 && kh.windows.some((w) => !w.tentative && w.from < oldFrozen
    && (kh.sch?.slots ?? []).some((x) => x.machine === w.machine && x.end > Math.max(w.from, kh.nowT) + 1e-6 && x.start < Math.min(w.to, oldFrozen) - 1e-6));
  let boundaryDay = opt.split || early ? Math.max(0, todayIdx + 1) : Math.max(0, todayIdx + kh.cfg.frozen_days);
  if (opt.fromDate) boundaryDay = Math.min(boundaryDay, Math.max(0, todayIdx + 1, dayIndex(cal, opt.fromDate)));
  const prev: PrevSchedule | null = kh.sch && kh.version
    ? { S: kh.version.params.S, SPD: kh.version.params.SPD, slots: kh.sch.slots, codes: (kh.version.params.shifts ?? []).map((x) => x.code) } : null;
  // Lô TP SX đã duyệt lịch: giữ chỗ trên lịch máy khi xếp lại
  const keep = new Set(kh.lines.filter((l) => l.lot_approved_at).map((l) => l.id));
  const sopt = { from: prev, boundary: prev ? boundaryDay * cal.SPD * cal.S : 0, split: opt.split, credit: opt.credit, keep, windows };
  // Bộ tối ưu thử thêm ca 2 / ca 3: số ca mỗi ngày đổi thì dựng lại lịch ca, mốc xếp lại, khoảng máy dừng theo lịch mới
  const remake = (cfg2: Config) => {
    const cal2 = makeCalendar(cfg2, base);
    return { cal: cal2, opt: { ...sopt, boundary: prev ? boundaryDay * cal2.SPD * cal2.S : 0, windows: machineWindows(kh.machines, kh.maint, cal2, kh.now, kh.maintPlans, kh.sch) } };
  };
  const ctx = { cfg: kh.cfg, cal, machines: kh.machines, operators: kh.operators, remake };
  let ords = orders, best: OptResult | null = null;
  let sch: Schedule;
  if (opt.optimize) {
    best = optimize(orders, ctx, sopt, { levers: false, time_ms: 3000, ...opt.levers });
    ords = best.orders; sch = best.sch;
  } else sch = schedule(orders, ctx, sopt);
  return { cal, sch, orders: ords, fin: finishInfo(sch, cal, ords), boundaryDay, windows, early: early && !opt.split, best };
}

// Phân tích tối ưu cho thẻ "Tối ưu & thêm ca": máy cổ chai, nếu thêm ca / thêm người thì sao, đề xuất máy chạy 2–3 ca để kịp ngày chốt
export function analyze(kh: Kh, mode: 'due' | 'fastest' = 'due') {
  const lv: Levers = { mode, time_ms: 6000, levers: true };
  return rebuild(kh, kh.orders, { optimize: true, levers: lv });
}

// Mét kế hoạch theo máy, theo ca của một ngày
export function dayPlan(sch: Schedule, cal: Calendar, machines: MachineInfo[], date: string) {
  const di = dayIndex(cal, date);
  const rows: { s: number; shift: string; machine: MachineInfo; r?: ReturnType<typeof shiftPlan>[number] }[] = [];
  if (di < 0 || cal.days[di] !== date) return rows;
  for (let j = 0; j < cal.SPD; j++) {
    const s = di * cal.SPD + j;
    for (const m of machines) {
      const list = shiftPlan(sch.byMachine.get(m.code) ?? [], s, cal.S);
      if (!list.length) rows.push({ s, shift: cal.shifts[j].code, machine: m });
      list.forEach((r) => rows.push({ s, shift: cal.shifts[j].code, machine: m, r }));
    }
  }
  return rows;
}

// Mét thực tế mỗi việc trong các ngày đã qua có báo cáo ca đã xác nhận (để chuyển phần thiếu sang ca sau)
export async function carryOver(db: Db, kh: Kh) {
  const credit = new Map<string, number>();
  if (!kh.sch || kh.todayIdx <= 0) return { credit, checked: 0, missingReports: 0 };
  const from = kh.cal.days[0], to = kh.cal.days[Math.min(kh.todayIdx, kh.cal.days.length) - 1];
  const { data } = await app(db).from('v_kh_reports').select('work_date, shift_code, machine_code, status, lines').gte('work_date', from).lte('work_date', to);
  const reps = (data ?? []) as { work_date: string; shift_code: string; machine_code: string; status: string; lines: { key?: string; declared_m?: number; plc_m?: number }[] }[];
  let checked = 0, missingReports = 0;
  // Theo máy × ngày: cộng mét kế hoạch mọi ca của ngày, so với mét khai báo trên mọi báo cáo ca đã xác nhận của máy ngày đó
  // (máy chạy 2–3 ca có thể báo cáo theo từng ca hoặc gộp)
  for (let di = 0; di < kh.todayIdx && di < kh.cal.days.length; di++) {
    const date = kh.cal.days[di];
    for (const m of kh.machines) {
      const plan = Array.from({ length: kh.cal.SPD }, (_, j) => shiftPlan(kh.sch!.byMachine.get(m.code) ?? [], di * kh.cal.SPD + j, kh.cal.S)).flat();
      if (!plan.length) continue;
      const reps2 = reps.filter((r) => r.work_date === date && r.machine_code === m.code && r.status === 'CONFIRMED');
      if (!reps2.length) { missingReports++; continue; }
      checked++;
      const planned = new Map<string, number>();
      for (const p of plan) planned.set(p.sl.key, (planned.get(p.sl.key) ?? 0) + p.m);
      for (const [k, pm] of planned) {
        const act = reps2.flatMap((r) => r.lines).filter((l) => l.key === k).reduce((a, l) => a + Number(l.declared_m ?? l.plc_m ?? 0), 0);
        credit.set(k, (credit.get(k) ?? 0) + (pm - act));
      }
    }
  }
  return { credit, checked, missingReports };
}

const r3 = (v: number) => Math.round(v * 1000) / 1000;
// Gói lịch để lưu thành phiên bản mới
export function schedulePayload(kh: Kh, orders: Order[], r: ReturnType<typeof rebuild>) {
  return {
    p_base: r.cal.base,
    p_params: {
      S: r.cal.S, SPD: r.cal.SPD, RUN: r.cal.RUN, fill_pct: kh.cfg.fill_pct, frozen_days: kh.cfg.frozen_days,
      machines_per_operator: kh.cfg.machines_per_operator, plan_no: kh.planNo, workdays: r.cal.wd,
      group_days: kh.cfg.group_days ?? 0, speeds_sig: speedSig(kh.cfg), flow_sig: flowSig(kh.cfg), people_sig: peopleSig(kh.cfg), flow: flowOf(kh.cfg),
      // thứ tự lô (bộ tối ưu chọn): xếp lại sau giữ thứ tự này, lô mới chen theo hạn giao
      seq: Object.fromEntries(r.orders.filter((o) => o.seq != null).map((o) => [o.id, o.seq!])),
      shifts: r.cal.shifts.map((s) => ({ code: s.code, start_time: s.start_time, end_time: s.end_time, break_min: s.break_min })),
      // sổ giờ đứng máy theo lịch này (database ghi vào sổ khi bản lịch thành lịch đang dùng, từ hôm nay)
      hours: r.sch.hours ?? [],
    },
    p_orders: orders.map((o) => ({
      plan_line_id: o.id, label: o.label, product_code: o.product_code, product_name: o.product_name, group_code: o.group, qty_m: o.qty,
      due_date: o.due, priority: o.prio, source: o.source, finish_date: r.fin.get(o.id)?.finDate ?? null, meta: metaOf(o),
    })),
    p_slots: r.sch.slots.map((s) => ({
      plan_line_id: s.lineId, op_code: s.op, color: s.color, machine_code: s.machine, operator_code: s.operator, lane: s.lane,
      start_min: r3(s.start), run_start_min: r3(s.runStart), end_min: r3(s.end), setup_min: r3(s.setup), meters: r3(s.meters),
      rate: r3(s.rate), speed: r3(s.speed), reason: s.reason, setup_why: s.why, part: s.part,
      attend: (s.attend ?? []).map((a) => ({ ...a, f: r3(a.f), t: r3(a.t) })), crew: s.crew ?? null,
    })),
  };
}

