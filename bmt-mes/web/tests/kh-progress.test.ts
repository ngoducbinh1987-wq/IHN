// Kiểm thử tiến độ thực tế sau ca (progress.ts): so phiếu hoàn thành / báo cáo ca với lịch đến lúc hết ca, ra mét còn phải làm.
// Chạy: node_modules/.bin/jiti tests/kh-progress.test.ts (trong web/)
import { type Config, type MachineInfo, type OperatorInfo, type Order, makeCalendar, schedule } from '../lib/kh/scheduler';
import { progress, type SlipRow, type ReportRow } from '../lib/kh/progress';
import { cutAt } from '../lib/kh/load';

let errs = 0;
const bad = (m: string) => { errs++; console.log('LỖI', m); };
const cfg: Config = {
  fill_pct: 90, frozen_days: 3, cutoff_time: '16:00', downtime_reason_min: 5, plc_dev_pct: 0.5, auto_shifts: 10, plc_loss_min: 10, machines_per_operator: 2,
  workdays: [1, 2, 3, 4, 5, 6],
  shifts: [{ code: 'A', start_time: '06:00', end_time: '14:00', break_min: 30, active: true }, { code: 'B', start_time: '14:00', end_time: '22:00', break_min: 30, active: false }, { code: 'C', start_time: '22:00', end_time: '06:00', break_min: 30, active: false }],
  rates: [['CD1', 100, 80], ['CD2', 80, 70], ['CD3', 50, 50], ['CD4', 60, 60], ['CD5', 60, 45]].map(([op, a, b], i) => ({ op_code: op as string, label: '', unit: '', rate_small: a as number, rate_large: b as number, confirmed: false, sort: i })),
  changeovers: [],
};
const machines: MachineInfo[] = [['BUN-01', 'BUNCHER', ['NV2']], ['EXT-SI-01', 'EXTRUDER_SI', ['NV1']], ['TWS-01', 'TWISTER', ['NV2']], ['EXT-TP-01', 'EXTRUDER_TP', ['NV1']]]
  .map(([c, t, o]) => ({ code: c as string, name: c as string, machine_type: t as string, data_mode: 'MANUAL', tag_count: 0, operators: o as string[] }));
const all = machines.map((m) => m.code);
const operators: OperatorInfo[] = ['NV1', 'NV2', 'NV3'].map((c) => ({ code: c, job: '', extra: '', is_deputy: false, keeps_fg: false, skills: all, learning: [] }));
const o1: Order = { id: 'L1', label: 'D01', product_code: 'PFR-2C-1P5', product_name: 'x', group: 'PFR', size: 1.5, cores: ['Nâu', 'Trắng'], sheath: 'Đỏ', sil: true, shield: false,
  route: ['CD1', 'CD2', 'CD3', 'CD5'], qty: 40000, due: '2026-11-20', prio: 1, source: 'x' };
const orders = [o1];
const cal = makeCalendar(cfg, '2026-11-02');
const sch = schedule(orders, { cfg, cal, machines, operators });
const kh = { cal, sch, cfg, orders, machines };
const cut = { date: '2026-11-03', code: 'A' };            // hết ca 1 ngày làm việc thứ hai
const T = cutAt(cal, cut.date, cut.code);
if (Math.abs(T - 2 * cal.S) > 1e-6) bad(`cutAt ${T} ≠ 2·S`);
const inDay = (sl: (typeof sch.slots)[number], a: number, b: number) => Math.min(sl.meters, Math.max(0, Math.min(sl.end, b) - Math.max(sl.runStart, a)) * sl.rate);
const bun = sch.slots.filter((s) => s.machine === 'BUN-01');
const bunKey = bun[0].key;
const pBefore = bun.reduce((a, s) => a + inDay(s, -Infinity, T), 0);
const pDay2 = bun.reduce((a, s) => a + inDay(s, cal.S, T), 0);
console.log('BUN-01 lịch đến hết ca', Math.round(pBefore), 'm; ca vừa hết', Math.round(pDay2), 'm');
if (pDay2 < 20000) bad('lịch thử: bện ca 2 quá ít mét');
const slip = (m: number, date: string, min: number, machine = 'BUN-01', op = 'CD1'): SlipRow => ({ line: 'L1', op, machine, m, at: { date, min } });
const credOf = (c: Map<string, number>, k: string) => c.get(k) ?? 0;

// 1. Chưa có phiếu nào: coi như chạy đúng lịch, báo máy chưa có phiếu
{
  const p = progress(kh, cut, [], []);
  if (p.credit.size) bad('không phiếu: không được bù mét');
  if (!p.missing.includes('BUN-01')) bad('không phiếu: phải báo BUN-01 chưa có phiếu');
  console.log('1 chưa có phiếu: missing', p.missing.join(','));
}
// 2. Bện thiếu 15.000 m so với lịch (phiếu đến hết ca): bù 15.000 m vào việc bện
{
  const slips = [slip(pBefore - 15000, '2026-11-03', 600)];
  const p = progress(kh, cut, slips, []);
  const c = credOf(p.credit, bunKey);
  if (Math.abs(c - 15000) > 2) bad(`thiếu: bù ${c} ≠ 15000`);
  const m = p.machines.find((x) => x.machine === 'BUN-01');
  if (!m || m.missing || m.slips !== 1) bad('thiếu: BUN-01 có phiếu ca vừa hết');
  if (p.short.find((x) => x.op === 'CD1')?.m !== c) bad('thiếu: short');
  console.log('2 thiếu: bù', c, 'máy', JSON.stringify(m));
}
// 3. Vượt 12.000 m: trừ bớt
{
  const p = progress(kh, cut, [slip(pBefore + 12000, '2026-11-03', 700)], []);
  const c = credOf(p.credit, bunKey);
  if (Math.abs(c + 12000) > 2) bad(`vượt: bù ${c} ≠ −12000`);
  console.log('3 vượt: bù', c);
}
// 4. Thiếu dưới 1 bobin (10.000 m bện): coi như đúng tiến độ
{
  const p = progress(kh, cut, [slip(pBefore - 6000, '2026-11-03', 700)], []);
  if (p.credit.has(bunKey)) bad('dưới 1 bobin: không bù');
}
// 5. Phiếu xong sau lúc hết ca thuộc ca sau: không tính
{
  const p = progress(kh, cut, [slip(pBefore - 15000, '2026-11-03', 700), slip(15000, '2026-11-04', 500)], []);
  if (Math.abs(credOf(p.credit, bunKey) - 15000) > 2) bad('phiếu sau lúc hết ca bị tính vào');
}
// 6. Chỉ có phiếu ca trước, ca vừa hết chưa có: phần ca vừa hết tạm coi đúng lịch, báo thiếu phiếu
{
  const pDay1 = bun.reduce((a, s) => a + inDay(s, -Infinity, cal.S), 0);
  const p = progress(kh, cut, [slip(pDay1 - 15000, '2026-11-02', 700)], []);
  if (Math.abs(credOf(p.credit, bunKey) - 15000) > 2) bad(`ca trước thiếu: bù ${credOf(p.credit, bunKey)}`);
  if (!p.missing.includes('BUN-01')) bad('ca vừa hết chưa có phiếu: phải báo');
}
// 7. Không có phiếu nhưng có báo cáo ca (mét khai báo): dùng báo cáo ca
{
  const reports: ReportRow[] = [
    { date: '2026-11-02', code: 'A', machine: 'BUN-01', lines: [{ key: bunKey, m: bun.reduce((a, s) => a + inDay(s, -Infinity, cal.S), 0) }] },
    { date: '2026-11-03', code: 'A', machine: 'BUN-01', lines: [{ key: bunKey, m: pDay2 - 20000 }] },
  ];
  const p = progress(kh, cut, [], reports);
  if (Math.abs(credOf(p.credit, bunKey) - 20000) > 2) bad(`báo cáo ca: bù ${credOf(p.credit, bunKey)} ≠ 20000`);
  if (p.missing.includes('BUN-01')) bad('có báo cáo ca: không báo thiếu phiếu');
}
// 8. Máy trộn không tính; công đoạn sau đúng tiến độ không bị bù
{
  const p = progress(kh, cut, [slip(pBefore - 15000, '2026-11-03', 600)], []);
  if ([...p.credit.keys()].some((k) => !k.startsWith('L1|CD1'))) bad('chỉ việc bện được bù');
}
console.log(errs ? `${errs} LỖI` : 'kh-progress: đạt');
if (errs) process.exit(1);
