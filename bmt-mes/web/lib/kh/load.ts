// Đọc dữ liệu module Kế hoạch sản xuất từ database và dựng lịch máy để hiển thị / xếp lại.
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  type Calendar, type Config, type MachineInfo, type Op, type OperatorInfo, type Order, type PrevSchedule, type Schedule, type Slot,
  OPS, dayIndex, finishInfo, makeCalendar, nextWorkday, schedule, shiftPlan, toMin,
} from './scheduler';

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

// Ngày giờ hiện tại theo giờ Việt Nam
export function vnNow() {
  const p = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Ho_Chi_Minh', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false })
    .formatToParts(new Date());
  const g = (t: string) => p.find((x) => x.type === t)?.value ?? '00';
  return { date: `${g('year')}-${g('month')}-${g('day')}`, min: (Number(g('hour')) % 24) * 60 + Number(g('minute')) };
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
  const ORDER = ['SIL-MIX', 'BUN-01', 'EXT-SI-01', 'EXT-SI-02', 'TWS-01', 'EXT-TP-01', 'EXT-TP-02', 'PACK-01'];
  const machines = ((m ?? []) as MachineInfo[]).map((x) => ({ ...x, tag_count: Number(x.tag_count) }))
    .sort((a, b) => (ORDER.indexOf(a.code) + 1 || 99) - (ORDER.indexOf(b.code) + 1 || 99) || a.code.localeCompare(b.code));
  return { cfg, machines, operators: (o ?? []) as OperatorInfo[], updated_at: c.updated_at as string | null };
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
    source: r.so_no ?? (r.change_request_id ? 'Đơn phát sinh' : r.adjustment_id ? 'Phiếu điều chỉnh' : 'Kế hoạch tháng'),
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
  params: { S: number; SPD: number; RUN: number; fill_pct: number; frozen_days: number; machines_per_operator: number; plan_no?: string; workdays?: number[];
    group_days?: number; speeds_sig?: string; shifts: { code: string; start_time: string; end_time: string; break_min: number }[] };
};

export type Kh = Awaited<ReturnType<typeof loadKh>>;

// Dữ liệu cho các màn hình: kế hoạch đang chọn, lịch máy đang dùng, lệnh, ngày xong
export async function loadKh(db: Db, opts: { plan?: string | null; roles: string[] }) {
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
  const version = current.find((v) => v.plan_id === planId) ?? null;

  const [{ data: lineRows }, { data: ordRows }, { data: slotRows }, { data: lastLog }] = await Promise.all([
    planId && plan ? app(db).from('v_kh_plan_lines').select('*').eq('plan_id', planId).order('line_no') : Promise.resolve({ data: [] as LineRow[] }),
    version ? app(db).from('v_kh_orders').select('*').eq('version_id', version.id) : Promise.resolve({ data: [] as Record<string, unknown>[] }),
    version ? app(db).from('v_kh_slots').select('*').eq('version_id', version.id).order('start_min') : Promise.resolve({ data: [] as Record<string, unknown>[] }),
    app(db).from('v_kh_param_log').select('at').order('at', { ascending: false }).limit(1),
  ]);
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
    || (lastParamAt && lastParamAt > version.created_at)));
  const missing = version ? orders.filter((o) => !sch!.slots.some((s) => s.lineId === o.id)) : [];

  return {
    ...base, now, plans: visiblePlans, planId, planNo, planStatus, schedStart, lines, orders, fromPlan, version, cal, sch, fin,
    todayIdx, nowT, frozenFrom, frozenTo, dirty, missing, roles: opts.roles,
  };
}

// Dựng lịch mới (xếp lại) từ dữ liệu hiện tại; giữ phần trước mốc
export function rebuild(kh: Kh, orders: Order[], opt: { split?: boolean; credit?: Map<string, number> } = {}) {
  const base = kh.version ? kh.version.base_date : kh.cal.base;
  const cal = makeCalendar(kh.cfg, base);
  const todayIdx = dayIndex(cal, kh.now.date);
  const boundaryDay = opt.split ? Math.max(0, todayIdx + 1) : Math.max(0, todayIdx + kh.cfg.frozen_days);
  const prev: PrevSchedule | null = kh.sch && kh.version ? { S: kh.version.params.S, SPD: kh.version.params.SPD, slots: kh.sch.slots } : null;
  // Lô TP SX đã duyệt lịch: giữ chỗ trên lịch máy khi xếp lại
  const keep = new Set(kh.lines.filter((l) => l.lot_approved_at).map((l) => l.id));
  const sch = schedule(orders, { cfg: kh.cfg, cal, machines: kh.machines, operators: kh.operators }, {
    from: prev, boundary: prev ? boundaryDay * cal.SPD * cal.S : 0, split: opt.split, credit: opt.credit, keep,
  });
  return { cal, sch, fin: finishInfo(sch, cal, orders), boundaryDay };
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
