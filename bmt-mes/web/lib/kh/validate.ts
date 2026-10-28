// Kiểm tra một lịch máy có đúng mọi quy tắc của thuật toán không (dùng cho kiểm thử và cảnh báo trên màn hình).
// Trả về danh sách vi phạm (trống = lịch hợp lệ).
import { type Calendar, type Config, type OperatorInfo, type Order, type Schedule, type Window, buildTasks, flowOf, peopleOf, predOps, shiftRun } from './scheduler.ts';

export function validateSchedule(
  sch: Schedule, orders: Order[], ctx: { cfg: Config; cal: Calendar; operators?: OperatorInfo[]; machines?: { code: string; machine_type: string }[] }, opt: { windows?: Window[]; from?: number; supply?: boolean } = {},
): string[] {
  const bad: string[] = [];
  const { cfg, cal } = ctx;
  const F = flowOf(cfg);
  const from = opt.from ?? 0;
  const eps = 1e-4;
  // 1. Một máy không chạy hai việc cùng lúc
  for (const [m, sl] of sch.byMachine) for (let i = 1; i < sl.length; i++)
    if (sl[i].start < sl[i - 1].end - eps) bad.push(`trùng giờ trên ${m}: ${sl[i - 1].key} và ${sl[i].key}`);
  // 2. Người: một người không có hai đoạn có mặt chồng nhau (khởi động, thay bobin, đứng máy trộn / đóng gói); không xếp người vắng;
  //    người phải được đứng máy (tay nghề đứng chính, kiêm nhiệm tạm, tổ đóng gói TP SX chọn); máy đóng gói có người suốt khối
  const P = peopleOf(cfg);
  const DAY = sch.S * cal.SPD;
  const att = new Map<string, { f: number; t: number; key: string; m: string }[]>();
  for (const s of sch.slots) for (const a of s.attend ?? []) if (a.t > from + eps) att.set(a.p, [...(att.get(a.p) ?? []), { f: a.f, t: a.t, key: s.key, m: s.machine }]);
  for (const [p, list] of att) {
    list.sort((a, b) => a.f - b.f);
    // so với đoạn kết thúc muộn nhất trước đó (bắt cả đoạn ngắn nằm trong đoạn dài)
    let last = list[0];
    for (let i = 1; i < list.length; i++) {
      if (list[i].f < last.t - eps && list[i].f >= from - eps) bad.push(`người ${p} có mặt cùng lúc ở ${last.m} và ${list[i].m} (${list[i].f.toFixed(0)})`);
      if (list[i].t > last.t) last = list[i];
    }
    const R = sch.roster;
    const hitIv = (iv: [number, number][] | undefined, f: number, t: number) => (iv ?? []).some(([x, y]) => f < y - eps && t > x + eps);
    for (const a of list) {
      if (a.t < from + eps) continue;
      if (R?.multi) {
        // máy chạy nhiều ca: người chỉ có mặt trong ca của mình (hoặc giờ làm ca dài), không có mặt lúc vắng
        if (hitIv(R.off[p], Math.max(a.f, from), a.t)) bad.push(`người ${p} có mặt ở ${a.m} ngoài ca của mình (${a.f.toFixed(0)})`);
        if (hitIv(R.absent[p], Math.max(a.f, from), a.t)) bad.push(`người ${p} vắng nhưng có mặt ở ${a.m} (${a.f.toFixed(0)})`);
        if (ctx.operators && !R.virtual.includes(p)) {
          const w = ctx.operators.find((x) => x.code === p);
          for (let di = Math.floor(Math.max(a.f, from) / DAY + 1e-9); di * DAY < a.t - eps; di++) {
            const d = cal.days[di]; if (!d) continue;
            const crew = P.crews.find((c) => c.machine === a.m && c.date === d);
            const ok = Boolean(crew?.members?.includes(p) || w?.skills.includes(a.m) || P.covers.some((c) => c.code === p && c.machine === a.m && c.from <= d && d <= c.to));
            if (!ok) bad.push(`người ${p} không được đứng ${a.m} ngày ${d}`);
          }
        }
        continue;
      }
      // mọi nửa ngày mà đoạn có mặt đi qua (đoạn đóng gói có thể từ sáng sang chiều)
      const f0 = Math.max(a.f, from);
      for (let di = Math.floor(f0 / DAY + 1e-9); di * DAY < a.t - eps; di++) {
        const d = cal.days[di];
        if (!d) continue;
        const halves = (['AM', 'PM'] as const).filter((h) => {
          const hf = di * DAY + (h === 'PM' ? DAY / 2 : 0), ht = hf + DAY / 2;
          return f0 < ht - eps && a.t > hf + eps;
        });
        if (P.absences.some((x) => x.code === p && x.from <= d && d <= x.to && (x.part === 'FULL' || (halves as readonly string[]).includes(x.part)))) bad.push(`người ${p} vắng ${d} nhưng có mặt ở ${a.m}`);
        if (ctx.operators) {
          const w = ctx.operators.find((x) => x.code === p);
          const crew = P.crews.find((c) => c.machine === a.m && c.date === d);
          const ok = Boolean(crew?.members?.includes(p) || w?.skills.includes(a.m) || P.covers.some((c) => c.code === p && c.machine === a.m && c.from <= d && d <= c.to));
          if (!ok) bad.push(`người ${p} không được đứng ${a.m} ngày ${d}`);
        }
      }
    }
  }
  const typeOf = new Map((ctx.machines ?? []).map((m) => [m.code, m.machine_type]));
  for (const s of sch.slots) if (s.start >= from - eps && typeOf.get(s.machine) === 'PACKER') {
    const run = (s.attend ?? []).filter((a) => a.k === 'RUN' && a.f <= s.start + eps && a.t >= s.end - eps);
    if (!run.length || run.length !== (s.crew ?? run.length)) bad.push(`đóng gói ${s.key} thiếu người đứng suốt khối`);
  }
  // 2b. Máy chạy ít ca hơn lịch / ca thêm thiếu người: không có việc trong giờ máy không chạy
  for (const s of sch.slots) if (s.start >= from - eps && s.end > s.start + eps)
    for (const [x, y] of sch.roster?.closed[s.machine] ?? []) if (s.start < y - eps && s.end > x + eps) { bad.push(`${s.key} trên ${s.machine} chạy vào giờ máy không chạy (${x.toFixed(0)}–${y.toFixed(0)})`); break; }
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
    const bh = sch.mix.batch_h;
    const perBucket = new Map<string, typeof sch.mix.uses>();
    for (const u of sch.mix.uses) {
      // mẻ đầu của khoảng trộn phải xong trước lúc dùng; không quá hạn dùng
      if (u.mixR0 + Math.min(bh, u.mixR1 - u.mixR0) > u.useR + 1e-6) bad.push(`${u.key}: dùng silicone trước khi trộn xong mẻ đầu`);
      if (u.mixR0 < u.useR - sch.mix.pot_life_h - 1e-6) bad.push(`${u.key}: silicone quá hạn dùng (${(u.useR - u.mixR0).toFixed(2)} giờ > ${sch.mix.pot_life_h})`);
      const k = u.mixR0 + '|' + u.mixR1;
      perBucket.set(k, [...(perBucket.get(k) ?? []), u]);
    }
    // tới lúc dùng, lượng đã lấy từ một khoảng trộn không vượt phần đã trộn được tới lúc đó
    for (const b of sch.mix.buckets) {
      const list = (perBucket.get(b.r0 + '|' + b.r1) ?? []).sort((x, y) => x.useR - y.useR);
      let cum = 0;
      for (const u of list) {
        cum += u.kg;
        const frac = b.r1 > b.r0 ? Math.min(1, (u.useR - b.r0) / (b.r1 - b.r0)) : 1;
        if (cum > b.cap * frac + 1e-6) { bad.push(`${u.key}: dùng nhiều hơn lượng đã trộn tới lúc đó`); break; }
      }
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
