// Đọc dữ liệu module Kế hoạch sản xuất từ database và dựng lịch máy để hiển thị / xếp lại.
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  type Calendar, type Config, type FlowCfg, type MachineInfo, type Op, type OperatorInfo, type Order, type PrevSchedule, type Schedule, type Slot, type Window,
  OPS, dayIndex, finishInfo, flowOf, isWorkday, makeCalendar, nextWorkday, schedule, shiftPlan, toMin,
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

// Khoảng máy không chạy được theo lịch cal: hỏng / bảo dưỡng đến giờ dự kiến chạy lại (chưa có giờ: tạm 1 ngày), ngừng dùng,
// bảo dưỡng đã chốt "trong ca" (khối giữ chỗ = phút dừng máy quy ra phút xếp lịch)
export function machineWindows(machines: MachineInfo[], maint: MaintRow[], cal: Calendar, now: { date: string; min: number }): Window[] {
  const nowT = timeT(cal, now);
  const out: Window[] = [];
  for (const m of machines) {
    if (m.status === 'OFF') out.push({ machine: m.code, from: nowT, to: Infinity, kind: 'OFF', label: `${m.code} ngừng dùng` });
    else if (m.status === 'DOWN' || m.status === 'MAINT') {
      const to = m.status_eta ? timeT(cal, vnNow(new Date(m.status_eta))) : nowT + cal.SPD * cal.S;
      const what = m.status === 'DOWN' ? 'hỏng' : 'bảo dưỡng';
      if (to > nowT) out.push({ machine: m.code, from: nowT, to, kind: m.status, label: `${m.code} ${what}${m.status_eta ? `, dự kiến chạy lại ${hm(m.status_eta)}` : ' (chưa có giờ chạy lại, tạm tính 1 ngày)'}` });
    }
  }
  for (const w of maint) {
    if (w.status !== 'OPEN' || w.sched_status !== 'CONFIRMED' || w.sched_mode !== 'IN_SHIFT' || !w.planned_date || w.planned_date < now.date) continue;
    if (!isWorkday(w.planned_date, cal.wd) || !machines.some((m) => m.code === w.machine_code)) continue;
    const from = dayIndex(cal, w.planned_date) * cal.SPD * cal.S;
    const to = from + (Number(w.est_minutes ?? w.stop_minutes ?? 0) * cal.S) / Math.max(1, cal.RUN);
    if (to > nowT && to > from) out.push({ machine: w.machine_code, from, to, kind: 'PM', label: `bảo dưỡng ${w.wo_no} (${w.est_minutes ?? 0} phút, đã chốt)` });
  }
  return out;
}

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
    levers: { ot_max_min: num(c.ot_max_min) ?? 240, ot_month_h: num(c.ot_month_h) ?? 40, early_max_h: num(c.mix_early_max_h) ?? 0 } as Required<Pick<Levers, 'ot_max_min' | 'ot_month_h' | 'early_max_h'>>,
    ot: { extra_min: (c.extra_min ?? {}) as Record<string, number>, mix_early_h: Number(c.mix_early_h ?? 0), from: (c.ot_from as string | null) ?? null, until: (c.ot_until as string | null) ?? null,
      request_id: (c.ot_request_id as string | null) ?? null,
      // đang có hiệu lực hôm nay (view tính theo giờ VN)
      active: Object.keys((c.extra_min_now ?? {}) as object).length > 0 || Number(c.mix_early_h_now ?? 0) > 0,
      planned: Object.keys(cfg.flow.extra_min ?? {}).length > 0 || Number(cfg.flow.mix_early_h) > 0 },
  };
  const ORDER = ['SIL-MIX', 'BUN-01', 'EXT-SI-01', 'EXT-SI-02', 'TWS-01', 'EXT-TP-01', 'EXT-TP-02', 'PACK-01'];
  const machines = ((m ?? []) as MachineInfo[]).map((x) => ({ ...x, tag_count: Number(x.tag_count) }))
    .sort((a, b) => (ORDER.indexOf(a.code) + 1 || 99) - (ORDER.indexOf(b.code) + 1 || 99) || a.code.localeCompare(b.code));
  return { cfg, machines, operators: (o ?? []) as OperatorInfo[], updated_at: c.updated_at as string | null, flowMeta };
}
// Số mẫu QC tối thiểu (30 ngày) để MES dùng thời gian QC thực tế thay số TP KT/QA nhập
export const QC_LEARN_MIN_SAMPLES = 10;
// Dấu vân tay thông số dòng chảy: đổi (TP KT/QA sửa, tăng ca được duyệt/hết hạn, QC tự học thay đổi) thì lịch đang dùng cần xếp lại
export const flowSig = (cfg: Pick<Config, 'flow'>) => JSON.stringify(flowOf(cfg));
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
    group_days?: number; speeds_sig?: string; flow_sig?: string; seq?: Record<string, number>; flow?: unknown; shifts: { code: string; start_time: string; end_time: string; break_min: number }[] };
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
  const nowT = Math.max(0, (todayIdx * SPD + (todayIdx >= 0 && cal.days.includes(now.date) ? sIn : 0)) * S);
  const frozenFrom = Math.max(0, todayIdx), frozenTo = Math.max(0, todayIdx + base.cfg.frozen_days);

  // Lịch cần xếp lại khi tham số đổi sau lần xếp gần nhất
  const cfgCal = makeCalendar(base.cfg, cal.base);
  const lastParamAt = (lastLog?.[0]?.at as string | undefined) ?? null;
  const dirty = Boolean(version && (cfgCal.S !== version.params.S || cfgCal.SPD !== version.params.SPD
    || base.cfg.machines_per_operator !== Number(version.params.machines_per_operator)
    || cfgCal.wd.join() !== cal.wd.join()
    || (version.params.speeds_sig ?? '') !== speedSig(base.cfg)
    || (version.params.flow_sig ?? '') !== flowSig(base.cfg)
    || (lastParamAt && lastParamAt > version.created_at)));
  const missing = version ? orders.filter((o) => !sch!.slots.some((s) => s.lineId === o.id)) : [];

  // Máy hỏng / bảo dưỡng / ngừng dùng: lịch đang dùng còn việc trong khoảng máy không chạy được → cần xếp lại
  const windows = machineWindows(base.machines, maint, cal, now);
  const machAlerts: string[] = [];
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
export function rebuild(kh: Kh, orders: Order[], opt: { split?: boolean; credit?: Map<string, number>; optimize?: boolean; levers?: Levers } = {}) {
  const base = kh.version ? kh.version.base_date : kh.cal.base;
  const cal = makeCalendar(kh.cfg, base);
  const todayIdx = dayIndex(cal, kh.now.date);
  const windows = machineWindows(kh.machines, kh.maint, cal, kh.now);
  const frozenEnd = Math.max(0, todayIdx + kh.cfg.frozen_days) * cal.SPD * cal.S;
  const early = windows.some((w) => w.from < frozenEnd);
  const boundaryDay = opt.split || early ? Math.max(0, todayIdx + 1) : Math.max(0, todayIdx + kh.cfg.frozen_days);
  const prev: PrevSchedule | null = kh.sch && kh.version ? { S: kh.version.params.S, SPD: kh.version.params.SPD, slots: kh.sch.slots } : null;
  // Lô TP SX đã duyệt lịch: giữ chỗ trên lịch máy khi xếp lại
  const keep = new Set(kh.lines.filter((l) => l.lot_approved_at).map((l) => l.id));
  const sopt = { from: prev, boundary: prev ? boundaryDay * cal.SPD * cal.S : 0, split: opt.split, credit: opt.credit, keep, windows };
  const ctx = { cfg: kh.cfg, cal, machines: kh.machines, operators: kh.operators };
  let ords = orders, best: OptResult | null = null;
  let sch: Schedule;
  if (opt.optimize) {
    best = optimize(orders, ctx, sopt, { levers: false, time_ms: 3000, ...opt.levers });
    ords = best.orders; sch = best.sch;
  } else sch = schedule(orders, ctx, sopt);
  return { cal, sch, orders: ords, fin: finishInfo(sch, cal, ords), boundaryDay, windows, early: early && !opt.split, best };
}

// Phân tích tối ưu cho thẻ "Tối ưu & tăng ca": máy cổ chai, nếu thêm giờ thì sao, đề xuất tăng ca / trộn sớm để kịp ngày chốt
export function analyze(kh: Kh, mode: 'due' | 'fastest' = 'due') {
  const lv: Levers = { ...kh.flowMeta.levers, mode, time_ms: 4000, levers: true };
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
  for (let di = 0; di < kh.todayIdx && di < kh.cal.days.length; di++) {
    const date = kh.cal.days[di];
    for (let j = 0; j < kh.cal.SPD; j++) {
      const s = di * kh.cal.SPD + j, code = kh.cal.shifts[j].code;
      for (const m of kh.machines) {
        const plan = shiftPlan(kh.sch.byMachine.get(m.code) ?? [], s, kh.cal.S);
        if (!plan.length) continue;
        const rep = reps.find((r) => r.work_date === date && r.shift_code === code && r.machine_code === m.code && r.status === 'CONFIRMED');
        if (!rep) { missingReports++; continue; }
        checked++;
        for (const p of plan) {
          const act = rep.lines.filter((l) => l.key === p.sl.key).reduce((a, l) => a + Number(l.declared_m ?? l.plc_m ?? 0), 0);
          credit.set(p.sl.key, (credit.get(p.sl.key) ?? 0) + (p.m - act));
        }
      }
    }
  }
  return { credit, checked, missingReports };
}
