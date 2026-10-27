// Kiểm thử bộ xếp lịch máy (không cần database): node --experimental-strip-types web/tests/kh-scheduler.test.ts
import { schedule, makeCalendar, finishInfo, buildTasks, machineSpeed, rateOn, plcSpeed, predOps, type Order, type Config, type MachineInfo, type OperatorInfo, type SpeedCfg, type PlcSpeedCfg } from '../lib/kh/scheduler.ts';
const cfg: Config = { fill_pct: 85, frozen_days: 3, cutoff_time: '16:00', downtime_reason_min: 5, plc_dev_pct: 0.5, auto_shifts: 10, plc_loss_min: 10, machines_per_operator: 1,
  shifts: [{ code: 'A', start_time: '06:00', end_time: '14:00', break_min: 30, active: true }, { code: 'B', start_time: '14:00', end_time: '22:00', break_min: 30, active: false }, { code: 'C', start_time: '22:00', end_time: '06:00', break_min: 30, active: false }],
  rates: [['CD1', 100, 80], ['CD2', 80, 70], ['CD3', 50, 50], ['CD4', 60, 60], ['CD5', 60, 45]].map(([op, a, b], i) => ({ op_code: op as string, label: '', unit: '', rate_small: a as number, rate_large: b as number, confirmed: false, sort: i })),
  changeovers: [['INS_UP', 15], ['INS_DOWN', 35], ['INS_SIZE', 45], ['SH_COLOR', 20], ['SH_CODE', 45], ['BUN_SIZE', 20], ['TWS_CODE', 25]].map(([c, m], i) => ({ code: c as string, op_code: '', label: '', minutes: m as number, sort: i })) };
const machines: MachineInfo[] = [['BUN-01', 'BUNCHER', ['NV2']], ['EXT-SI-01', 'EXTRUDER_SI', ['NV1', 'NV5']], ['EXT-SI-02', 'EXTRUDER_SI', ['NV1', 'NV5']], ['TWS-01', 'TWISTER', ['NV2']], ['EXT-TP-01', 'EXTRUDER_TP', ['NV1', 'NV5']], ['EXT-TP-02', 'EXTRUDER_TP', ['NV1', 'NV5']]]
  .map(([c, t, o]) => ({ code: c as string, name: c as string, machine_type: t as string, data_mode: 'MANUAL', tag_count: 0, operators: o as string[] }));
const ex = ['EXT-SI-01', 'EXT-SI-02', 'EXT-TP-01', 'EXT-TP-02'];
const operators: OperatorInfo[] = [
  { code: 'NV1', job: '', extra: '', is_deputy: true, keeps_fg: false, skills: ex, learning: [] },
  { code: 'NV2', job: '', extra: '', is_deputy: false, keeps_fg: false, skills: ['BUN-01', 'TWS-01'], learning: [] },
  { code: 'NV3', job: '', extra: '', is_deputy: false, keeps_fg: true, skills: [], learning: [] },
  { code: 'NV4', job: '', extra: '', is_deputy: false, keeps_fg: false, skills: [], learning: [] },
  { code: 'NV5', job: '', extra: '', is_deputy: false, keeps_fg: false, skills: ex, learning: [] },
];
const mk = (i: number, code: string, g: string, size: number, cores: string[], sheath: string | null, qty: number, due: string, sil = true, shield = false, prio = 1): Order => ({
  id: 'L' + i, label: 'D' + String(i).padStart(2, '0'), product_code: code, product_name: code, group: g, size, cores, sheath, sil, shield,
  route: (g === 'SIF' ? ['CD1', 'CD2'] : ['CD1', 'CD2', 'CD3', 'CD5']) as Order['route'], qty, due, prio, source: 'x' });
const orders: Order[] = [
  mk(1, 'PFR-2C-1P5', 'PFR', 1.5, ['Nâu', 'Trắng'], 'RAL 6037', 30000, '2026-11-10'),
  mk(2, 'CTL-1P-A14', 'CTL', 2.08, ['Trắng', 'Đen'], 'Xám (Gray)', 10000, '2026-11-12', false, true),
  mk(3, 'CFR-4C-1P5', 'CFR', 1.5, ['Trắng', 'Xám', 'Nâu', 'Đen'], 'Đỏ', 10000, '2026-11-14'),
  mk(4, 'SIF-1C-1P5', 'SIF', 1.5, ['Đỏ'], null, 40000, '2026-11-14'),
  mk(5, 'PFR-2C-1', 'PFR', 1, ['Nâu', 'Trắng'], 'Đỏ', 25000, '2026-11-20'),
  mk(6, 'CTL-1P-A14', 'CTL', 2.08, ['Trắng', 'Trắng'], 'Xám', 25000, '2026-11-21', false, true),
  mk(7, 'PFR-3C-2P5', 'PFR', 2.5, ['Nâu', 'Đen', 'Xám'], 'Đỏ', 10000, '2026-11-26'),
];
const cal = makeCalendar(cfg, '2026-11-02');
console.log('cal', cal.S, cal.SPD, cal.RUN, cal.base, cal.days.slice(0, 7).join(','));
const ctx = { cfg, cal, machines, operators };
const r = schedule(orders, ctx);
const fin = finishInfo(r, cal, orders);
let errs = 0; const bad = (m: string) => { errs++; console.log('LỖI', m); };
function check(sch: typeof r, ords: Order[], tag: string) {
  // 1 trùng giờ trên máy
  for (const [m, sl] of sch.byMachine) for (let i = 1; i < sl.length; i++) if (sl[i].start < sl[i - 1].end - 1e-6) bad(`${tag} trùng giờ ${m} ${sl[i - 1].key} ${sl[i].key}`);
  // 2 người đứng 1 máy
  for (const w of ['NV1', 'NV2', 'NV5']) { const sl = sch.slots.filter((s) => s.operator === w).sort((a, b) => a.start - b.start); for (let i = 1; i < sl.length; i++) if (sl[i].start < sl[i - 1].end - 1e-6) bad(`${tag} ${w} đứng 2 máy ${sl[i - 1].machine}/${sl[i].machine} @${sl[i].start.toFixed(0)}`); }
  // 3 bảo toàn mét
  const tasks = buildTasks(ords, cfg);
  for (const t of tasks) { const got = sch.slots.filter((s) => s.key === t.key).reduce((a, s) => a + s.meters, 0); if (Math.abs(got - t.full) > 2) bad(`${tag} mét ${t.key} ${got.toFixed(0)} ≠ ${t.full}`); }
  // 4 gối đầu ≥ 1 ca
  for (const o of ords) for (let k = 1; k < o.route.length; k++) {
    const p = sch.opDone.get(o.id + '|' + o.route[k - 1])!, c = sch.opDone.get(o.id + '|' + o.route[k])!;
    if (c.start < p.start + sch.S - 1e-6) bad(`${tag} gối đầu ${o.label} ${o.route[k]} bắt đầu ${c.start.toFixed(0)} < ${p.start.toFixed(0)}+S`);
    if (c.end < p.end - 1e-6) bad(`${tag} ${o.label} ${o.route[k]} xong trước công đoạn trước`);
  }
  // 5 CD2 HDPE trên line vỏ, SIL trên line silicone
  for (const s of sch.slots) if (s.op === 'CD2') { const o = ords.find((x) => x.id === s.lineId)!; if (o.sil !== s.machine.startsWith('EXT-SI')) bad(`${tag} CD2 sai máy ${o.label} ${s.machine}`); }
  if (sch.unplaced.length) bad(`${tag} chưa xếp ${sch.unplaced.length}`);
}
check(r, orders, 'v1');
for (const o of orders) { const f = fin.get(o.id)!; console.log(o.label, o.product_code, 'xong', f.finDate, 'hạn', o.due, 'dư', f.slack); }
console.log('slots', r.slots.length, 'CTL CD2 máy', [...new Set(r.slots.filter((s) => s.lineId === 'L2' && s.op === 'CD2').map((s) => s.machine))]);
// Xếp lại: giữ phần trước mốc ngày 3 (vùng khóa)
const B = 3 * cal.SPD * cal.S;
const r2 = schedule(orders, ctx, { from: { S: r.S, SPD: r.SPD, slots: r.slots }, boundary: B });
check(r2, orders, 'v2');
const before = r.slots.filter((s) => s.start < B).map((s) => s.key + s.start.toFixed(2) + s.machine).sort().join();
const after = r2.slots.filter((s) => s.start < B).map((s) => s.key + s.start.toFixed(2) + s.machine).sort().join();
if (before !== after) bad('xếp lại làm đổi phần trước mốc');
// Bật ca B: k = 2
const cfg2 = { ...cfg, shifts: cfg.shifts.map((s) => s.code === 'B' ? { ...s, active: true } : s) };
const cal2 = makeCalendar(cfg2, '2026-11-02');
const r3 = schedule(orders, { ...ctx, cfg: cfg2, cal: cal2 }, { from: { S: r.S, SPD: r.SPD, slots: r.slots }, boundary: 3 * cal2.SPD * cal2.S });
check(r3, orders, 'caB');
const f3 = finishInfo(r3, cal2, orders);
console.log('ca B: ', orders.map((o) => `${o.label} ${fin.get(o.id)!.finDate}→${f3.get(o.id)!.finDate}`).join(' | '));
// Đơn gấp chen vùng khóa (tách)
const urgent = { ...mk(8, 'CFR-2C-1P5', 'CFR', 1.5, ['Đỏ', 'Đen'], 'Đỏ', 10000, '2026-11-09'), prio: 0 };
const r4 = schedule([...orders, urgent], ctx, { from: { S: r.S, SPD: r.SPD, slots: r.slots }, boundary: 2 * cal.SPD * cal.S, split: true });
check(r4, [...orders, urgent], 'gấp');
const f4 = finishInfo(r4, cal, [...orders, urgent]);
console.log('gấp xong', f4.get('L8')!.finDate, 'hạn 09/11; ảnh hưởng', orders.filter((o) => f4.get(o.id)!.finDate !== fin.get(o.id)!.finDate).map((o) => o.label).join(','));
// Credit (thiếu 5000 m bện D01 ở ngày đã qua)
const r5 = schedule(orders, ctx, { from: { S: r.S, SPD: r.SPD, slots: r.slots }, boundary: B, credit: new Map([['L1|CD1|', 5000]]) });
const got = r5.slots.filter((s) => s.key === 'L1|CD1|').reduce((a, s) => a + s.meters, 0);
console.log('credit D01 bện', got, '(=60000+5000)');
if (Math.abs(got - 65000) > 2) bad('credit');

// ---------- Gom lô cùng cỡ ruột, cùng màu (khung gom lô) ----------
// 8 lô xen kẽ cỡ/màu, hạn giao cách nhau 1 ngày: gom phải giảm phút đổi máy, không lô nào trễ hạn hơn khung gom
const mix: Order[] = [
  mk(11, 'SIF-1C-1P5', 'SIF', 1.5, ['Đen'], null, 15000, '2026-11-16'),
  mk(12, 'SIF-1C-2P5', 'SIF', 2.5, ['Trắng'], null, 15000, '2026-11-17'),
  mk(13, 'SIF-1C-1P5', 'SIF', 1.5, ['Trắng'], null, 15000, '2026-11-18'),
  mk(14, 'SIF-1C-2P5', 'SIF', 2.5, ['Đen'], null, 15000, '2026-11-19'),
  mk(15, 'SIF-1C-1P5', 'SIF', 1.5, ['Đen'], null, 15000, '2026-11-20'),
  mk(16, 'SIF-1C-2P5', 'SIF', 2.5, ['Trắng'], null, 15000, '2026-11-21'),
  mk(17, 'SIF-1C-1P5', 'SIF', 1.5, ['Trắng'], null, 15000, '2026-11-22'),
  mk(18, 'SIF-1C-2P5', 'SIF', 2.5, ['Đen'], null, 15000, '2026-11-23'),
];
const setupMin = (sch: typeof r) => sch.slots.reduce((a, s) => a + s.setup, 0);
const changes = (sch: typeof r) => sch.slots.filter((s) => s.setup > 0).length;
const g0 = schedule(mix, { ...ctx, cfg: { ...cfg, group_days: 0 } });
const g7 = schedule(mix, { ...ctx, cfg: { ...cfg, group_days: 7 } });
check(g0, mix, 'gom0'); check(g7, mix, 'gom7');
console.log('ngày xong (khung 0 → 7):', mix.map((o) => `${o.label} ${finishInfo(g0, cal, mix).get(o.id)!.finDate?.slice(5)}→${finishInfo(g7, cal, mix).get(o.id)!.finDate?.slice(5)} hạn ${o.due!.slice(5)}`).join(' | '));
console.log('gom: phút đổi máy', setupMin(g0), '→', setupMin(g7), '; số lần đổi', changes(g0), '→', changes(g7));
if (!(setupMin(g7) < setupMin(g0))) bad('gom lô không giảm phút đổi máy');
const f0 = finishInfo(g0, cal, mix), f7 = finishInfo(g7, cal, mix);
for (const o of mix) {
  const a = f0.get(o.id)!, b = f7.get(o.id)!;
  if (b.slack != null && a.slack != null && b.slack < Math.min(0, a.slack) - 7) bad(`gom làm ${o.label} trễ quá khung`);
}
// Trên mỗi máy: trong một đợt cùng cỡ, màu sáng trước tối (không có tối → sáng giữa hai việc cùng cỡ khi còn việc sáng cùng cỡ chờ)
for (const [m, sl] of g7.byMachine) if (m.startsWith('EXT-SI')) console.log(m, sl.map((s) => mix.find((o) => o.id === s.lineId)!.size + (s.color ?? '')).join(' → '));
// Khung 0 ngày: giữ đúng thứ tự hạn giao trên từng máy
for (const [m, sl] of g0.byMachine) for (let i = 1; i < sl.length; i++) {
  if (sl[i].op !== 'CD2') continue;
  const a = mix.find((o) => o.id === sl[i - 1].lineId)!, b = mix.find((o) => o.id === sl[i].lineId)!;
  if (sl[i - 1].op === 'CD2' && a.due! > b.due!) bad(`khung 0: ${m} chạy ${a.label} trước ${b.label} hạn sớm hơn`);
}
// Đơn gấp không bị lô thường gom vượt
const urg = { ...mk(19, 'SIF-1C-2P5', 'SIF', 2.5, ['Đen'], null, 15000, '2026-11-30'), prio: 0 };
const gu = schedule([...mix, urg], { ...ctx, cfg: { ...cfg, group_days: 30 } });
check(gu, [...mix, urg], 'gấp+gom');
const uStart = gu.opDone.get('L19|CD2')!.start, firstCd2 = Math.min(...gu.slots.filter((s) => s.op === 'CD2').map((s) => s.runStart));
console.log('đơn gấp bọc bắt đầu', uStart.toFixed(0), 'việc bọc đầu tiên', firstCd2.toFixed(0));
if (uStart > firstCd2 + cal.S) bad('đơn gấp bị gom lô đẩy sau');

// ---------- Tốc độ theo khai báo máy ----------
const sp = (machine_code: string, op_code: string, std_mpm: number, x: Partial<SpeedCfg> = {}): SpeedCfg =>
  ({ machine_code, op_code, product_id: null, group_code: null, core_code: null, std_mpm, rated_mpm: null, max_mpm: null, status: 'APPROVED', submitted_at: '2026-10-27', ...x });
const speeds: SpeedCfg[] = [
  sp('EXT-SI-01', 'CD2', 120), sp('EXT-SI-02', 'CD2', 40),
  sp('EXT-SI-01', 'CD2', 90, { group_code: 'SIF' }),                       // riêng nhóm SIF trên line 1
  sp('EXT-SI-01', 'CD2', 70, { product_id: 'P-SIF', status: 'PENDING' }),  // riêng mã, chờ duyệt
  sp('EXT-SI-02', 'CD2', 200, { rated_mpm: 150, max_mpm: 60, group_code: 'XYZ' }),
  sp('TWS-01', 'CD3', 80), sp('TWS-01', 'CD4', 30),
  sp('BUN-01', 'CD1', 500, { status: 'OBSOLETE' }),
];
const cfgS = { ...cfg, speeds };
const oS = { ...mix[0], product_id: 'P-SIF' }, oG = mix[0], oX = { ...mix[0], group: 'XYZ' };
const eq = (a: number, b: number, m: string) => { if (Math.abs(a - b) > 1e-9) bad(`${m}: ${a} ≠ ${b}`); };
eq(machineSpeed(cfgS, 'EXT-SI-01', 'CD2', oS)!.v, 70, 'tốc độ riêng mã');
if (!machineSpeed(cfgS, 'EXT-SI-01', 'CD2', oS)!.pending) bad('tốc độ chờ duyệt phải đánh dấu');
eq(machineSpeed(cfgS, 'EXT-SI-01', 'CD2', oG)!.v, 90, 'tốc độ riêng nhóm');
eq(machineSpeed(cfgS, 'EXT-SI-02', 'CD2', oG)!.v, 40, 'tốc độ chung của máy');
eq(machineSpeed(cfgS, 'EXT-SI-02', 'CD2', oX)!.v, 60, 'giới hạn theo dải hoạt động');
if (machineSpeed(cfgS, 'BUN-01', 'CD1', oG) !== null) bad('dòng OBSOLETE không được dùng');
eq(rateOn(cfgS, 'BUN-01', 'CD1', oG).v, 100, 'máy chưa khai báo dùng mặc định');
eq(rateOn(cfgS, 'TWS-01', 'CD3', { ...mix[0], shield: true }).v, 30, 'xoắn + AL/PET lấy tốc độ chậm hơn');
const gs = schedule(mix, { ...ctx, cfg: { ...cfgS, group_days: 7 } });
check(gs, mix, 'tốc độ máy');
for (const s of gs.slots) if (s.op === 'CD2') {
  const want = s.machine === 'EXT-SI-01' ? 90 : 40;
  if (Math.abs(s.rate - want) > 1e-9) bad(`slot ${s.key} ${s.machine} tốc độ ${s.rate} ≠ ${want}`);
  if (Math.abs((s.end - s.runStart) * s.rate - s.meters) > 1) bad(`slot ${s.key} phút chạy không khớp tốc độ`);
}
console.log('tốc độ: line 1', gs.byMachine.get('EXT-SI-01')!.length, 'việc, line 2', gs.byMachine.get('EXT-SI-02')!.length, 'việc; lý do mẫu:', gs.slots.find((s) => s.machine === 'EXT-SI-01')!.reason);
// ---------- Chế độ Tự động: tốc độ thực tế từ PLC ----------
const plc = (machine_code: string, op_code: string, meters: number, run_min: number, x: Partial<PlcSpeedCfg> = {}): PlcSpeedCfg =>
  ({ machine_code, op_code, product_id: null, group_code: 'SIF', core_code: '1P5', meters, run_min, ...x });
const cfgP = { ...cfgS, plc_speeds: [
  plc('EXT-SI-01', 'CD2', 6000, 100), plc('EXT-SI-01', 'CD2', 4000, 50, { group_code: 'PFR' }),   // cùng cỡ 1P5: 10000 m / 150 phút
  plc('EXT-SI-02', 'CD2', 3000, 60),                                                               // chưa đủ 120 phút
  plc('TWS-01', 'CD4', 5000, 125, { group_code: 'CTL', core_code: 'A14' }),
] };
const oP = { ...mix[0], core: '1P5' };
eq(plcSpeed(cfgP, 'EXT-SI-01', 'CD2', oP)!.v, 10000 / 150, 'PLC: gộp cùng cỡ ruột khi nhóm chưa đủ phút chạy');
eq(rateOn(cfgP, 'EXT-SI-01', 'CD2', oP, 'PLC').v, 10000 / 150, 'Máy chế độ Tự động dùng tốc độ PLC');
eq(rateOn(cfgP, 'EXT-SI-01', 'CD2', oP, 'MANUAL').v, 90, 'Máy chế độ Nhập tay dùng bảng tự nhập (bỏ qua PLC)');
eq(rateOn(cfgP, 'EXT-SI-01', 'CD2', oP, 'BOTH').v, 90, 'Chế độ Song song vẫn dùng bảng tự nhập');
const fb = rateOn(cfgP, 'EXT-SI-02', 'CD2', oP, 'PLC');
eq(fb.v, 40, 'PLC chưa đủ 120 phút chạy thì dùng bảng tự nhập');
if (!fb.note) bad('phải ghi chú PLC chưa đủ dữ liệu');
eq(rateOn(cfgP, 'TWS-01', 'CD3', { ...mix[0], group: 'CTL', core: 'A14', shield: true }, 'PLC').v, 40, 'Xoắn + AL/PET: PLC đo tốc độ chung');
const mP = machines.map((m) => m.code === 'EXT-SI-01' ? { ...m, data_mode: 'PLC' } : m);
const mixP = mix.map((o) => ({ ...o, core: o.size === 1.5 ? '1P5' : '2P5' }));
const gp = schedule(mixP, { ...ctx, machines: mP, cfg: { ...cfgP, group_days: 7 } });
check(gp, mixP, 'PLC');
for (const s of gp.slots) if (s.op === 'CD2' && s.machine === 'EXT-SI-01') {
  const o = mixP.find((x) => x.id === s.lineId)!;
  const want = o.core === '1P5' ? 10000 / 150 : 90;
  if (Math.abs(s.rate - want) > 1e-9) bad(`PLC slot ${s.key} tốc độ ${s.rate} ≠ ${want}`);
}
console.log('PLC lý do mẫu:', gp.slots.find((s) => s.machine === 'EXT-SI-01' && s.reason.includes('PLC'))?.reason);
// Giữ chỗ lô đã duyệt lịch: xếp lại có thêm đơn gấp, lô giữ chỗ không đổi máy/giờ sau mốc; việc khác không chồng lên khối giữ chỗ
const lastLine = [...orders].sort((a, b) => (fin.get(b.id)!.end - fin.get(a.id)!.end))[0].id;
const urgK = { ...mk(9, 'CFR-2C-1P5', 'CFR', 1.5, ['Đỏ', 'Đen'], 'Đỏ', 20000, '2026-11-10'), prio: 0 };
const rk = schedule([...orders, urgK], ctx, { from: { S: r.S, SPD: r.SPD, slots: r.slots }, boundary: B, keep: new Set([lastLine]) });
check(rk, [...orders, urgK], 'giữ chỗ');
const sig = (sl: typeof r.slots) => sl.filter((x) => x.lineId === lastLine && x.start >= B).map((x) => x.key + x.machine + x.start.toFixed(2)).sort().join();
if (!sig(r.slots) || sig(r.slots) !== sig(rk.slots)) bad('lô giữ chỗ bị dời khi xếp lại');
const rn = schedule([...orders, urgK], ctx, { from: { S: r.S, SPD: r.SPD, slots: r.slots }, boundary: B });
if (sig(rn.slots) === sig(r.slots)) console.log('(lưu ý: không giữ chỗ thì lô cuối cũng không đổi giờ trong bộ dữ liệu này)');
console.log('Giữ chỗ', orders.find((o) => o.id === lastLine)?.label, ': đơn gấp xong', finishInfo(rk, cal, [...orders, urgK]).get(urgK.id)?.finDate,
  '(không giữ chỗ:', finishInfo(rn, cal, [...orders, urgK]).get(urgK.id)?.finDate + ')');
// Máy hỏng (đợt A): EXT-SI-02 hỏng từ đầu ngày 1 đến hết ngày 3 → không việc nào nằm trên máy trong khoảng hỏng,
// việc đang chạy cắt tại giờ hỏng, mét vẫn đủ; bọc silicone chuyển sang EXT-SI-01. Bảo dưỡng giữ chỗ EXT-SI-01 ngày 5 (1/2 ca)
const D = (d: number) => d * cal.SPD * cal.S;
const down = { machine: 'EXT-SI-02', from: D(1), to: D(4), kind: 'DOWN' as const, label: 'EXT-SI-02 hỏng' };
const pm = { machine: 'EXT-SI-01', from: D(5), to: D(5) + cal.S / 2, kind: 'PM' as const, label: 'bảo dưỡng EXT-SI-01' };
const rd = schedule(orders, ctx, { from: { S: r.S, SPD: r.SPD, slots: r.slots }, boundary: D(1), windows: [down, pm] });
check(rd, orders, 'máy hỏng');
for (const s of rd.slots) for (const w of [down, pm]) if (s.machine === w.machine && s.end > w.from + 1e-6 && s.start < w.to - 1e-6) bad(`việc ${s.key} nằm trong khoảng ${w.label}`);
const siBefore = (sch: typeof r) => sch.slots.filter((s) => s.machine === 'EXT-SI-01' && s.start >= D(1) && s.start < D(4)).length;
if (siBefore(rd) < siBefore(r)) bad('máy hỏng: line silicone còn lại không nhận thêm việc');
const cut = rd.slots.find((s) => s.machine === 'EXT-SI-02' && s.part && s.reason.includes('EXT-SI-02 hỏng'));
console.log('Máy hỏng: việc trên EXT-SI-01 trong ngày 1–3', siBefore(r), '→', siBefore(rd), cut ? `· cắt ${cut.key} tại giờ hỏng` : '· không có việc chạy dở',
  '· lý do mẫu:', rd.slots.find((s) => s.reason.includes('Dời sau'))?.reason.split(' · ').find((x) => x.startsWith('Dời sau')) ?? '(không dời)');
const off = schedule(orders, ctx, { windows: [{ machine: 'EXT-SI-02', from: 0, to: Infinity, kind: 'OFF', label: 'EXT-SI-02 ngừng dùng' }] });
check(off, orders, 'ngừng dùng');
if (off.slots.some((s) => s.machine === 'EXT-SI-02')) bad('máy ngừng dùng vẫn được xếp việc');
// ---------- Trộn silicone (kg/giờ) và đóng gói trên máy cuốn bobin ----------
{
  const cfgM: Config = { ...cfg, rates: [...cfg.rates, { op_code: 'CD0', label: '', unit: 'kg/giờ', rate_small: 30, rate_large: 30, confirmed: false, sort: 0 },
    { op_code: 'CD6', label: '', unit: 'm cáp', rate_small: 120, rate_large: 100, confirmed: false, sort: 6 }],
    changeovers: [...cfg.changeovers, { code: 'MIX_CODE', op_code: 'CD0', label: '', minutes: 15, sort: 8 }, { code: 'PK_CODE', op_code: 'CD6', label: '', minutes: 10, sort: 9 }] };
  const mach2: MachineInfo[] = [...machines, { code: 'SIL-MIX', name: 'SIL-MIX', machine_type: 'MIXER', data_mode: 'MANUAL', tag_count: 0, operators: ['NV1'] },
    { code: 'PACK-01', name: 'PACK-01', machine_type: 'PACKER', data_mode: 'MANUAL', tag_count: 0, operators: ['NV4'] }];
  const ops2 = operators.map((w) => w.code === 'NV1' ? { ...w, skills: [...w.skills, 'SIL-MIX'] } : w.code === 'NV4' ? { ...w, skills: ['PACK-01'] } : w);
  const sifM: Order = { ...mk(21, 'SIF-1C-1P5', 'SIF', 1.5, ['Đỏ'], null, 20000, '2026-11-20'), route: ['CD0', 'CD1', 'CD2', 'CD6'], mix: 12 };
  const pfrM: Order = { ...mk(22, 'PFR-2C-1P5', 'PFR', 1.5, ['Nâu', 'Trắng'], 'Đỏ', 10000, '2026-11-25'), route: ['CD0', 'CD1', 'CD2', 'CD3', 'CD5', 'CD6'], mix: 28.6 };
  const ordM = [sifM, pfrM];
  const calM = makeCalendar(cfgM, '2026-11-02');
  const gm = schedule(ordM, { cfg: cfgM, cal: calM, machines: mach2, operators: ops2 });
  if (gm.unplaced.length) bad(`trộn/đóng gói chưa xếp ${gm.unplaced.length}`);
  const sp = (o: Order, op: string) => gm.opDone.get(o.id + '|' + op)!;
  for (const o of ordM) {
    if (o === sifM && sp(o, 'CD1').start > 1e-6) bad('bện phải chạy ngay, không chờ trộn');
    if (sp(o, 'CD2').start < sp(o, 'CD0').start + gm.S - 1e-6) bad(`${o.label} bọc trước khi trộn đủ 1 ca`);
    if (sp(o, 'CD2').start < sp(o, 'CD1').start + gm.S - 1e-6) bad(`${o.label} bọc trước khi bện đủ 1 ca`);
    const last = o.route[o.route.length - 2];
    if (sp(o, 'CD6').start < sp(o, last).start + gm.S - 1e-6 || sp(o, 'CD6').end < sp(o, last).end - 1e-6) bad(`${o.label} đóng gói không theo sau ${last}`);
  }
  // Máy trộn: phút chạy = kg ÷ (kg/giờ) × 60 (SIF 20 km × 12 kg/km = 240 kg ÷ 30 kg/giờ = 480 phút)
  const mixRun = gm.slots.filter((s) => s.lineId === sifM.id && s.op === 'CD0').reduce((a, s) => a + (s.end - s.runStart), 0);
  if (Math.abs(mixRun - 480) > 1) bad(`phút trộn SIF ${mixRun.toFixed(1)} ≠ 480`);
  if (!gm.slots.every((s) => s.op !== 'CD0' || s.machine === 'SIL-MIX')) bad('trộn phải trên máy trộn');
  if (!gm.slots.every((s) => s.op !== 'CD6' || s.machine === 'PACK-01')) bad('đóng gói phải trên máy đóng gói');
  if (predOps(['CD0', 'CD1', 'CD2', 'CD6'], 1).length !== 0 || predOps(['CD0', 'CD1', 'CD2', 'CD6'], 3).join() !== 'CD2') bad('predOps sai');
  const fm = finishInfo(gm, calM, ordM).get(sifM.id)!;
  console.log('trộn + đóng gói: SIF trộn', mixRun.toFixed(0), 'phút; xong', fm.finDate, '; lý do trộn:', gm.slots.find((s) => s.op === 'CD0')!.reason);
}
console.log(errs ? `${errs} LỖI` : 'TẤT CẢ ĐẠT');
