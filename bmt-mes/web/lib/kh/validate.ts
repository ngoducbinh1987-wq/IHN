// Kiểm tra một lịch máy có đúng mọi quy tắc của thuật toán không (dùng cho kiểm thử và cảnh báo trên màn hình).
// Trả về danh sách vi phạm (trống = lịch hợp lệ).
import { type Calendar, type Config, type Order, type Schedule, type Window, buildTasks, flowOf, predOps, shiftRun } from './scheduler.ts';

export function validateSchedule(
  sch: Schedule, orders: Order[], ctx: { cfg: Config; cal: Calendar }, opt: { windows?: Window[]; from?: number; supply?: boolean } = {},
): string[] {
  const bad: string[] = [];
  const { cfg, cal } = ctx;
  const F = flowOf(cfg);
  const from = opt.from ?? 0;
  const eps = 1e-4;
  // 1. Một máy không chạy hai việc cùng lúc
  for (const [m, sl] of sch.byMachine) for (let i = 1; i < sl.length; i++)
    if (sl[i].start < sl[i - 1].end - eps) bad.push(`trùng giờ trên ${m}: ${sl[i - 1].key} và ${sl[i].key}`);
  // 2. Một làn người không đứng hai máy cùng lúc (khối trộn theo sổ máy trộn tính riêng)
  const lanes = new Map<string, typeof sch.slots>();
  for (const s of sch.slots) if (s.operator && s.op !== 'CD0') { const k = s.operator + '|' + s.lane; lanes.set(k, [...(lanes.get(k) ?? []), s]); }
  for (const [k, sl] of lanes) {
    sl.sort((a, b) => a.start - b.start);
    for (let i = 1; i < sl.length; i++) if (sl[i].start < sl[i - 1].end - eps) bad.push(`người ${k} đứng 2 máy ${sl[i - 1].machine}/${sl[i].machine}`);
  }
  // 3. Đủ mét từng việc
  const tasks = buildTasks(orders, cfg);
  for (const t of tasks) {
    const got = sch.slots.filter((s) => s.key === t.key).reduce((a, s) => a + s.meters, 0);
    if (Math.abs(got - t.full) > Math.max(2, t.full * 1e-6)) bad.push(`mét ${t.key}: ${got.toFixed(0)} ≠ ${t.full}`);
  }
  // 4. Gối đầu theo bobin đầu tiên + QC (+ đệm), xong sau việc trước (chỉ kiểm việc sau mốc xếp lại)
  const shLen = cal.shifts.map((s) => shiftRun(s) + Number(s.break_min));
  const real2s = sch.S / (shLen.reduce((a, x) => a + x, 0) / Math.max(1, shLen.length));
  const span = (key: string) => {
    const sl = sch.slots.filter((s) => s.key === key && s.meters > 1e-6).sort((a, b) => a.runStart - b.runStart);
    if (!sl.length) return null;
    return { start: sl[0].runStart, rate: sl[0].rate, end: Math.max(...sl.map((s) => s.end)), lastRun: sl.at(-1)! };
  };
  for (const t of tasks) {
    const me = span(t.key); if (!me || me.start < from - eps) continue;
    for (const pop of predOps(t.order.route, t.k, opt.supply ?? true)) for (const p of tasks.filter((x) => x.oi === t.oi && x.op === pop)) {
      const ps = span(p.key); if (!ps) continue;
      const g = (F.qc_min + Number(F.safety_min[p.op] ?? 0)) * real2s;
      const lead = Math.min(F.unit_m[p.op] / ps.rate, ps.end - ps.start) + g;
      if (me.start < ps.start + lead - 1e-3) bad.push(`${t.order.label} ${t.op}${t.color ? ' ' + t.color : ''} bắt đầu trước khi ${p.op} xong bobin đầu + QC (${me.start.toFixed(0)} < ${(ps.start + lead).toFixed(0)})`);
      if (me.end < ps.end + g - 1e-3) bad.push(`${t.order.label} ${t.op} xong trước khi ${p.op} xong + QC`);
    }
  }
  // 5. Máy dừng (hỏng, bảo dưỡng, ngừng dùng): không có việc trong khoảng dừng (trừ phần đã chạy trước mốc)
  for (const w of opt.windows ?? []) for (const s of sch.slots)
    if (s.machine === w.machine && s.end > w.from + eps && s.start < w.to - eps && s.start >= from - eps) bad.push(`${s.key} nằm trong khoảng ${w.label}`);
  // 6. Máy trộn: không vượt năng lực từng giờ; silicone dùng trong hạn; đủ lượng cho line
  if (sch.mix) {
    for (const b of sch.mix.buckets) if (b.used > b.cap + 1e-6) bad.push(`máy trộn vượt năng lực (${b.used.toFixed(1)} > ${b.cap.toFixed(1)} kg)`);
    for (const u of sch.mix.uses) {
      if (u.mixR1 > u.useR + 1e-6) bad.push(`${u.key}: dùng silicone trước khi trộn xong`);
      if (u.mixR0 < u.useR - sch.mix.pot_life_h - 1e-6) bad.push(`${u.key}: silicone quá hạn dùng (${(u.useR - u.mixR0).toFixed(2)} giờ > ${sch.mix.pot_life_h})`);
    }
    for (const o of orders) if (o.route.includes('CD0') && Number(o.mix) > 0) {
      const need = sch.slots.filter((s) => s.lineId === o.id && s.op === 'CD2' && s.start >= from - eps).reduce((a, s) => a + s.meters, 0) * Number(o.mix) / 1000 / Math.max(1, o.cores.length);
      const mixed = sch.mix.uses.filter((u) => u.key.startsWith(o.id + '|CD2')).reduce((a, u) => a + u.kg, 0);
      if (mixed < need - 0.5) bad.push(`${o.label}: line dùng ${need.toFixed(0)} kg silicone nhưng chỉ trộn ${mixed.toFixed(0)} kg`);
    }
  }
  if (sch.unplaced.length) bad.push(`chưa xếp được ${sch.unplaced.length} việc: ${sch.unplaced.map((t) => t.key).join(', ')}`);
  return bad;
}
