// Kiểm thử thuật toán xếp lịch theo thông số (máy trộn là nguồn cấp, hạn dùng silicone, gối đầu theo bobin, bộ tối ưu)
// trên dữ liệu thật KH-2610-03 (cấu hình Supabase 28/10/2026). Chạy: node --experimental-strip-types web/tests/kh-flow.test.ts
import { type Config, type FlowCfg, type MachineInfo, type OperatorInfo, type Order, type Op, type PeopleCfg, type Window, makeCalendar, schedule, finishInfo } from '../lib/kh/scheduler.ts';
import { validateSchedule } from '../lib/kh/validate.ts';
import { optimize, groupLoads, scoreOf } from '../lib/kh/optimize.ts';

let errs = 0;
const bad = (m: string) => { errs++; console.log('LỖI', m); };
const baseCfg: Config = {
  fill_pct: 90, frozen_days: 3, cutoff_time: '16:00', downtime_reason_min: 5, plc_dev_pct: 0.5, auto_shifts: 10, plc_loss_min: 10,
  machines_per_operator: 2, group_days: 7, workdays: [1, 2, 3, 4, 5, 6],
  shifts: [{ code: 'A', active: true, start_time: '08:00', end_time: '17:00', break_min: 60 },
    { code: 'B', active: false, start_time: '14:00', end_time: '22:00', break_min: 30 }, { code: 'C', active: false, start_time: '22:00', end_time: '06:00', break_min: 30 }],
  rates: [['CD0', 30, 30], ['CD1', 100, 80], ['CD2', 80, 70], ['CD3', 50, 50], ['CD4', 60, 60], ['CD5', 60, 45], ['CD6', 120, 100]]
    .map(([op, a, b], i) => ({ op_code: op as string, label: '', unit: '', rate_small: a as number, rate_large: b as number, confirmed: false, sort: i })),
  changeovers: [['INS_UP', 15], ['INS_DOWN', 35], ['INS_SIZE', 45], ['SH_COLOR', 20], ['SH_CODE', 45], ['BUN_SIZE', 20], ['TWS_CODE', 25], ['MIX_CODE', 15], ['PK_CODE', 10]]
    .map(([code, minutes], i) => ({ code: code as string, op_code: '', label: '', minutes: minutes as number, sort: i })),
  speeds: [['M1', 250], ['M1.5', 200], ['M2.5', 150]].map(([core, v]) => ({ machine_code: 'BUN-01', op_code: 'CD1', product_id: null, group_code: null, core_code: core as string,
    std_mpm: v as number, rated_mpm: null, max_mpm: null, status: 'PENDING' })),
};
const mk = (code: string, type: string): MachineInfo => ({ code, name: code, machine_type: type, data_mode: 'MANUAL', tag_count: 0, operators: [], status: 'IDLE' });
const baseMachines = [mk('SIL-MIX', 'MIXER'), mk('BUN-01', 'BUNCHER'), mk('EXT-SI-01', 'EXTRUDER_SI'), mk('EXT-SI-02', 'EXTRUDER_SI'),
  mk('TWS-01', 'TWISTER'), mk('EXT-TP-01', 'EXTRUDER_TP'), mk('EXT-TP-02', 'EXTRUDER_TP'), mk('PACK-01', 'PACKER')];
const op = (code: string, skills: string[]): OperatorInfo => ({ code, job: '', extra: null, is_deputy: false, keeps_fg: false, skills, learning: [] });
const EX = ['EXT-SI-01', 'EXT-SI-02', 'EXT-TP-01', 'EXT-TP-02'];
const baseOps = [op('NV1', [...EX, 'SIL-MIX']), op('NV2', ['BUN-01', 'TWS-01']), op('NV3', ['PACK-01']), op('NV4', ['PACK-01']), op('NV5', EX)];
const route: Op[] = ['CD0', 'CD1', 'CD2', 'CD3', 'CD5', 'CD6'];
const L = (i: number, code: string, size: number, colors: string[], qty: number, core: string, mix: number | null, commit: string | null = null): Order => ({
  id: 'L' + i, label: 'D0' + i, product_code: code, product_name: code, group: code.slice(0, 3), size, cores: colors, sheath: 'RAL 6037', sil: true, shield: false,
  route: mix ? route : route.filter((x) => x !== 'CD0'), qty, due: null, commit, prio: 1, source: 'KH', product_id: null, core, mix,
});
const ORD = [L(1, 'CFR-2C-1', 1, ['Lõi 1', 'Lõi 2'], 10000, 'M1', 10.456, '2026-10-31'), L(2, 'PFR-2C-1P5', 1.5, ['Nâu', 'Trắng'], 80000, 'M1.5', 13.695),
  L(3, 'PFR-2C-2P5', 2.5, ['Nâu', 'Trắng'], 50000, 'M2.5', 20.345), L(4, 'PFR-3C-1P5', 1.5, ['Nâu', 'Nâu', 'Trắng'], 20000, 'M1.5', 20.542)];

type Sc = { mpo?: number; kgh?: number; flow?: FlowCfg; people?: PeopleCfg; avail?: Config['avail']; machines?: MachineInfo[]; ops?: OperatorInfo[]; orders?: Order[]; win?: (D: (d: number) => number) => Window[] };
function ctxOf(sc: Sc) {
  const cfg: Config = JSON.parse(JSON.stringify(baseCfg));
  if (sc.kgh) { const r = cfg.rates.find((x) => x.op_code === 'CD0')!; r.rate_small = r.rate_large = sc.kgh; }
  cfg.flow = sc.flow ?? {};
  if (sc.people) cfg.people = sc.people;
  if (sc.avail) cfg.avail = sc.avail;
  if (sc.mpo) cfg.machines_per_operator = sc.mpo;
  const cal = makeCalendar(cfg, '2026-10-28');
  const D = (d: number) => d * cal.S * cal.SPD;
  return { cfg, cal, machines: sc.machines ?? baseMachines, operators: sc.ops ?? baseOps, windows: sc.win ? sc.win(D) : [], orders: sc.orders ?? ORD, D };
}
function run(tag: string, sc: Sc = {}, expectValid = true) {
  const c = ctxOf(sc);
  const t0 = Date.now();
  const sch = schedule(c.orders, c, { windows: c.windows });
  const ms = Date.now() - t0;
  const v = validateSchedule(sch, c.orders, c, { windows: c.windows });
  if (expectValid && v.length) bad(`${tag}: ${v.slice(0, 4).join('; ')}`);
  if (ms > 2000) bad(`${tag}: chạy quá lâu ${ms} ms`);
  const sc0 = scoreOf(sch, c.cal, c.orders);
  const top = groupLoads(sch, c.machines)[0];
  console.log(`${tag}: ${sc0.makespan.toFixed(2)} ngày, cổ chai ${top.group} ${(top.util * 100).toFixed(0)}%, chưa xếp ${sch.unplaced.length}, ${ms} ms`);
  return { sch, score: sc0, c, top, v };
}

// 1. Năng lực máy trộn đổi → ngày xong và máy cổ chai tự đổi theo
const k30 = run('trộn 30 kg/giờ'), k50 = run('trộn 50 kg/giờ', { kgh: 50 }), k200 = run('trộn 200 kg/giờ', { kgh: 200 });
if (!(k50.score.makespan < k30.score.makespan - 0.05 && k200.score.makespan <= k50.score.makespan + 0.05)) bad('máy trộn nhanh hơn phải xong sớm hơn');
if (k30.top.group !== 'MIXER') bad('30 kg/giờ: máy trộn phải là cổ chai');
if (k200.top.group === 'MIXER') bad('200 kg/giờ: máy trộn không còn là cổ chai');
if (Object.values(k200.sch.mix!.wait_min).reduce((a, x) => a + x, 0) > 180) bad('200 kg/giờ: line silicone không được chờ silicone nhiều');
// 2. Hạn dùng silicone: không lần cấp nào quá hạn; hạn ngắn hơn không làm nhanh hơn đáng kể
const p4 = run('hạn dùng 4 giờ', { kgh: 50, flow: { pot_life_h: 4, mix_early_h: 3 } });
const p8 = run('hạn dùng 8 giờ', { kgh: 50, flow: { pot_life_h: 8, mix_early_h: 3 } });
const p24 = run('hạn dùng 24 giờ', { kgh: 50, flow: { pot_life_h: 24, mix_early_h: 3 } });
if (p24.score.makespan > p8.score.makespan + 0.1 || p8.score.makespan > p4.score.makespan + 0.1) bad('hạn dùng dài hơn không được chậm hơn');
// 3. Tăng ca riêng máy trộn: hạn 8 giờ thì vô ích (trộn tối, sáng mai đã quá hạn); hạn 24 giờ thì có ích
const ot8 = run('tăng ca máy trộn 2 giờ, hạn 8 giờ', { flow: { extra_min: { 'SIL-MIX': 120 } } });
const ot24 = run('tăng ca máy trộn 2 giờ, hạn 24 giờ', { flow: { pot_life_h: 24, extra_min: { 'SIL-MIX': 120 } } });
const b24 = run('không tăng ca, hạn 24 giờ', { flow: { pot_life_h: 24 } });
if (ot8.score.makespan < k30.score.makespan - 0.05) bad('hạn 8 giờ: tăng ca riêng máy trộn không được rút ngắn lịch');
if (!(ot24.score.makespan < b24.score.makespan - 0.3)) bad('hạn 24 giờ: tăng ca máy trộn phải rút ngắn lịch');
const otPair = run('tăng ca máy trộn + 2 line silicone 2 giờ', { flow: { extra_min: { 'SIL-MIX': 120, 'EXT-SI-01': 120, 'EXT-SI-02': 120 } } });
if (!(otPair.score.makespan < k30.score.makespan - 0.5)) bad('tăng ca cùng lúc máy trộn + line silicone phải rút ngắn lịch');
// 4. Trộn sớm trước ca
const e4 = run('trộn sớm 4 giờ', { flow: { mix_early_h: 4 } });
if (!(e4.score.makespan < k30.score.makespan - 1)) bad('trộn sớm 4 giờ phải rút ngắn lịch rõ rệt');
// 5. Máy dừng: máy trộn hỏng 1 ngày, máy bện hỏng 1 ngày, một line silicone ngừng dùng
const mixDown = run('máy trộn hỏng ngày 2', { win: (D) => [{ machine: 'SIL-MIX', from: D(1), to: D(2), kind: 'DOWN', label: 'SIL-MIX hỏng' }] });
if (mixDown.sch.mix!.buckets.some((b) => b.used > 1e-6 && b.t0 >= mixDown.c.D(1) && b.t1 <= mixDown.c.D(2) && b.t1 > b.t0)) bad('máy trộn hỏng vẫn có trộn');
if (mixDown.score.makespan < k30.score.makespan - 0.05) bad('máy trộn hỏng không được nhanh hơn');
// máy trộn hỏng thì máy khác (bện) vẫn làm việc của mình, không đứng chờ theo
if (!mixDown.sch.slots.some((s) => s.machine === 'BUN-01' && s.start < mixDown.c.D(2) && s.end > mixDown.c.D(1))) bad('máy trộn hỏng: máy bện không được dừng theo');
run('máy bện hỏng ngày 1', { win: (D) => [{ machine: 'BUN-01', from: D(0), to: D(1), kind: 'DOWN', label: 'BUN-01 hỏng' }] });
const off = run('line silicone 2 ngừng dùng', { kgh: 200, win: () => [{ machine: 'EXT-SI-02', from: 0, to: Infinity, kind: 'OFF', label: 'EXT-SI-02 ngừng dùng' }] });
if (off.sch.slots.some((s) => s.machine === 'EXT-SI-02')) bad('line ngừng dùng vẫn có việc');
// 6. Người: thiếu NV5; không ai đứng máy trộn → line silicone không chạy (báo chưa xếp, không treo)
const noNv5 = run('vắng NV5', { ops: baseOps.filter((o) => o.code !== 'NV5') });
if (noNv5.score.makespan < k30.score.makespan - 0.05) bad('thiếu người không được nhanh hơn');
// Máy trộn cần người đứng liên tục: không ai có tay nghề máy trộn (và không ai kiêm nhiệm) thì line silicone không có silicone → báo, không treo
const noMixer = run('không ai biết đứng máy trộn', { ops: baseOps.map((o) => ({ ...o, skills: o.skills.filter((x) => x !== 'SIL-MIX') })) }, false);
if (!noMixer.sch.unplaced.length || !(noMixer.sch.warnings ?? []).some((w) => w.includes('chưa có người đứng'))) bad('không ai đứng máy trộn: phải báo chưa xếp được và thiếu người trộn');
// Kiêm nhiệm tạm: NV5 kiêm máy trộn (chưa có tay nghề) thì xếp được, MES ghi kiêm nhiệm tạm
const coverMix = run('NV5 kiêm nhiệm tạm máy trộn', { ops: baseOps.map((o) => ({ ...o, skills: o.skills.filter((x) => x !== 'SIL-MIX') })),
  people: { covers: [{ code: 'NV5', machine: 'SIL-MIX', from: '2026-10-01', to: '2027-01-31' }] } });
if (coverMix.sch.unplaced.length) bad('kiêm nhiệm tạm máy trộn: phải xếp được');
if (!coverMix.sch.slots.some((s) => s.op === 'CD0' && s.operator === 'NV5')) bad('kiêm nhiệm tạm máy trộn: NV5 phải là người trộn');
if (!coverMix.sch.slots.some((s) => (s.attend ?? []).some((a) => a.c))) bad('kiêm nhiệm tạm: phải đánh dấu kiêm nhiệm tạm trên khối');
// Người đang trộn không rời máy trộn: không có đoạn khởi động / thay bobin nào của NV1 trong giờ NV1 đang trộn (validateSchedule kiểm chồng giờ)
const nv1Mix = k30.sch.slots.filter((s) => s.op === 'CD0').flatMap((s) => s.attend ?? []).filter((a) => a.p === 'NV1');
const nv1Line = k30.sch.slots.filter((s) => s.op !== 'CD0').flatMap((s) => s.attend ?? []).filter((a) => a.p === 'NV1');
if (nv1Mix.some((a) => nv1Line.some((b) => b.f < a.t - 1e-6 && a.f < b.t - 1e-6))) bad('NV1 vừa trộn vừa thay bobin / khởi động line');
const mixOff = run('máy trộn ngừng dùng', { win: () => [{ machine: 'SIL-MIX', from: 0, to: Infinity, kind: 'OFF', label: 'SIL-MIX ngừng dùng' }] }, false);
if (!mixOff.sch.unplaced.length) bad('máy trộn ngừng dùng: việc bọc silicone phải báo chưa xếp được');
// 7. Hai máy trộn
// Hai máy trộn cần hai người trộn (mỗi máy một người đứng liên tục): thêm NV6 đứng máy trộn 2
const two = run('hai máy trộn', { machines: [...baseMachines, mk('SIL-MIX-2', 'MIXER')], ops: [...baseOps, op('NV6', ['SIL-MIX-2'])] });
if (!(two.score.makespan < k30.score.makespan - 1)) bad('hai máy trộn phải nhanh hơn rõ rệt');
// 8. Mã không cần trộn (không có silicone trong BOM) chạy bình thường
run('mã không cần trộn', { orders: [...ORD, L(5, 'HFR-2C-1P5', 1.5, ['Đỏ', 'Đen'], 20000, 'M1.5', null)] });
// 9. Xếp lại từ ngày 3 có đơn gấp tách lệnh: phần trước mốc giữ nguyên, sau mốc hợp lệ
{
  const c = ctxOf({ kgh: 50 });
  const s1 = schedule(c.orders, c);
  const Bd = c.D(3);
  const urgent = { ...L(6, 'PFR-2C-1', 1, ['Đỏ', 'Đen'], 10000, 'M1', 10.5, '2026-11-02'), prio: 0 };
  const s2 = schedule([...c.orders, urgent], c, { from: { S: s1.S, SPD: s1.SPD, slots: s1.slots }, boundary: Bd, split: true });
  const v = validateSchedule(s2, [...c.orders, urgent], c, { from: Bd });
  if (v.length) bad(`xếp lại có đơn gấp: ${v.slice(0, 3).join('; ')}`);
  const keepSig = (s: typeof s1) => s.slots.filter((x) => x.start < Bd && x.op !== 'CD0').map((x) => x.key + x.machine + x.start.toFixed(1)).sort().join();
  if (keepSig(s1) !== keepSig(s2)) bad('xếp lại làm đổi phần trước mốc');
  console.log('xếp lại có đơn gấp: đơn gấp xong', finishInfo(s2, c.cal, [...c.orders, urgent]).get('L6')?.finDate);
}
// 9b. Xếp lại từ nhiều mốc (không thêm đơn): đủ mét từng công đoạn, phần trước mốc giữ nguyên, silicone đủ và đúng hạn
for (const kgh of [30, 50]) for (const day of [2, 3, 5]) {
  const c = ctxOf({ kgh });
  const s1 = schedule(c.orders, c);
  const Bd = c.D(day);
  const s2 = schedule(c.orders, c, { from: { S: s1.S, SPD: s1.SPD, slots: s1.slots }, boundary: Bd });
  const v = validateSchedule(s2, c.orders, c, { from: Bd });
  if (v.length) bad(`xếp lại từ ngày ${day + 1} (trộn ${kgh} kg/giờ): ${v.slice(0, 3).join('; ')}`);
  const d1 = scoreOf(s1, c.cal, c.orders).makespan, d2 = scoreOf(s2, c.cal, c.orders).makespan;
  if (d2 > d1 + 0.5) bad(`xếp lại từ ngày ${day + 1} (trộn ${kgh} kg/giờ) không được chậm hơn nhiều: ${d1.toFixed(2)} → ${d2.toFixed(2)}`);
}
// 9b'. Xếp lại mỗi ngày liên tiếp (như TP SX bấm Xếp lại hằng ngày): lịch vẫn hợp lệ, không chậm dần
for (const kgh of [30, 50]) {
  const c = ctxOf({ kgh });
  let s = schedule(c.orders, c);
  const d0 = scoreOf(s, c.cal, c.orders).makespan;
  for (let day = 1; day <= 8; day++) {
    s = schedule(c.orders, c, { from: { S: s.S, SPD: s.SPD, slots: s.slots }, boundary: c.D(day) });
    const v = validateSchedule(s, c.orders, c, { from: c.D(day) });
    if (v.length) { bad(`xếp lại hằng ngày (trộn ${kgh} kg/giờ) ngày ${day + 1}: ${v.slice(0, 2).join('; ')}`); break; }
  }
  const d1 = scoreOf(s, c.cal, c.orders).makespan;
  console.log(`xếp lại hằng ngày 8 lần (trộn ${kgh} kg/giờ): ${d0.toFixed(2)} → ${d1.toFixed(2)} ngày`);
  if (d1 > d0 + 0.5) bad(`xếp lại hằng ngày (trộn ${kgh} kg/giờ) chậm dần: ${d0.toFixed(2)} → ${d1.toFixed(2)}`);
}
// 9c. Tăng ca theo khoảng ngày: chỉ tính trong khoảng → ngày xong nằm giữa "không tăng ca" và "tăng ca mọi ngày"
{
  const ex = { 'SIL-MIX': 120, 'EXT-SI-01': 120, 'EXT-SI-02': 120 };
  const all = run('tăng ca mọi ngày', { flow: { extra_min: ex } });
  const part = run('tăng ca 29–31/10', { flow: { extra_min: ex, ot_from: '2026-10-29', ot_until: '2026-10-31' } });
  const none = run('tăng ca đã hết hạn', { flow: { extra_min: ex, ot_from: '2026-10-01', ot_until: '2026-10-27' } });
  if (Math.abs(none.score.makespan - k30.score.makespan) > 0.01) bad('tăng ca hết hạn vẫn được tính');
  if (!(part.score.makespan <= none.score.makespan + 0.01 && part.score.makespan >= all.score.makespan - 0.01)) bad('tăng ca theo khoảng ngày phải nằm giữa không tăng ca và tăng ca mọi ngày');
  if (!(part.score.makespan < none.score.makespan - 0.05)) bad('tăng ca 3 ngày phải rút ngắn lịch');
}
// 10. Bộ tối ưu: thứ tự lô; thêm ca (máy chạy 2–3 ca) chỉ khi trễ ngày chốt; máy trộn đi cùng line silicone; chạy lại cùng kết quả
{
  const c = ctxOf({ flow: {} });
  const tight = c.orders.map((o, i) => ({ ...o, commit: ['2026-10-31', '2026-11-05', '2026-11-05', '2026-11-05'][i] }));
  const t0 = Date.now();
  const r = optimize(tight, c, { windows: [] }, { mode: 'due' });
  console.log(`tối ưu (chốt 05/11): ${r.base.score.makespan.toFixed(2)} → đủ người ${r.staffed?.score.makespan.toFixed(2)} ngày, trễ ${r.base.score.late} → ${r.staffed?.score.late}, người thật trễ ${r.realPlan?.score.late}; ${r.shiftPlan.map((x) => `${x.group} ${x.shifts} ca`).join(', ')}; ${r.evals} lần chạy, ${Date.now() - t0} ms`);
  if (!r.shiftPlan.length || !r.staffed || !(r.staffed.score.late < r.ordered.score.late)) bad('trễ ngày chốt: bộ tối ưu phải đề xuất thêm ca làm bớt trễ');
  if (r.shiftPlan.some((x) => x.shifts > 3 || x.shifts < 2)) bad('số ca đề xuất phải là 2 hoặc 3');
  if (r.shiftPlan.some((x) => x.from < '2026-10-28' || x.to < x.from)) bad('khoảng ngày thêm ca không hợp lệ');
  const sil = r.shiftPlan.find((x) => x.group === 'SIL');
  if (sil && !(sil.machines.includes('SIL-MIX') && sil.machines.includes('EXT-SI-01'))) bad('máy trộn phải thêm ca cùng line silicone');
  if (r.shiftPlan.some((x) => x.group !== 'SIL' && x.machines.includes('SIL-MIX'))) bad('máy trộn không thêm ca riêng');
  if (sil && sil.persons !== 2) bad(`ca thêm máy trộn + 2 line silicone cần 2 người (1 người đứng riêng máy trộn), được ${sil.persons}`);
  for (const x of [r.staffed, r.realPlan]) if (x) {
    const v = validateSchedule(x.sch, x.ords, { ...c, cal: x.cal, cfg: { ...c.cfg, machine_shifts: r.machineShifts } });
    if (v.length) bad(`lịch thêm ca: ${v[0]}`);
  }
  if (!(r.realPlan!.sch.warnings ?? []).some((w) => w.startsWith('Thiếu người ca'))) bad('người hiện có chỉ làm ca 1: phải báo thiếu người ca thêm');
  const c2 = ctxOf({ kgh: 200 });
  const r2 = optimize(c2.orders, c2, {}, { mode: 'fastest' });
  console.log(`tối ưu (200 kg/giờ, nhanh nhất): cổ chai ${r2.bottleneck[0].group}; ${r2.whatIf.filter((w) => w.kind === 'shift').map((w) => `${w.group} +${w.gain.toFixed(2)}`).join(', ')}`);
  if (r2.bottleneck[0].group !== 'TWISTER') bad('200 kg/giờ: cổ chai phải là máy xoắn');
  const tw = r2.whatIf.find((w) => w.group === 'TWISTER' && w.kind === 'shift'), sl = r2.whatIf.find((w) => w.group === 'SIL' && w.kind === 'shift');
  if (!tw || !sl || !(tw.gain > sl.gain)) bad('200 kg/giờ: thêm ca máy xoắn phải lợi hơn thêm ca máy trộn');
  // Không có ngày chốt, chế độ kịp hạn: không đề xuất thêm ca
  const r3 = optimize(c.orders.map((o) => ({ ...o, commit: null })), c, {}, { mode: 'due' });
  if (r3.shiftPlan.length) bad('không trễ hạn thì không đề xuất thêm ca');
  // Thứ tự lô trả về phải đúng với lịch trả về (kể cả khi giữ thứ tự cũ)
  const again = schedule(r.orders, { ...c, cfg: { ...c.cfg } }, { windows: [] });
  if (Math.abs(scoreOf(again, c.cal, r.orders).makespan - r.score.makespan) > 1e-6) bad('thứ tự lô bộ tối ưu trả về không cho ra đúng lịch');
  // Kết quả không phụ thuộc tốc độ máy chủ: chạy lại cho cùng kết quả
  const r4 = optimize(tight, c, { windows: [] }, { mode: 'due' });
  if (Math.abs((r4.staffed?.score.makespan ?? 0) - (r.staffed?.score.makespan ?? 0)) > 1e-9 || r4.evals !== r.evals) bad('bộ tối ưu chạy lại cho kết quả khác');
}

// 11. Thiếu thông số: không đoán số, báo rõ
{
  const c = ctxOf({ kgh: 50 });
  const cfgNoRate = { ...c.cfg, rates: c.cfg.rates.filter((r) => r.op_code !== 'CD5'), changeovers: c.cfg.changeovers.filter((x) => x.code !== 'SH_COLOR') };
  const s = schedule(c.orders, { ...c, cfg: cfgNoRate });
  const w = s.warnings ?? [];
  if (!w.some((x) => x.includes('Chưa có tốc độ bọc vỏ'))) bad('thiếu tốc độ bọc vỏ phải cảnh báo');
  if (!w.some((x) => x.includes('SH_COLOR'))) bad('thiếu phút đổi máy SH_COLOR phải cảnh báo');
  if (!s.unplaced.some((t) => t.op === 'CD5')) bad('thiếu tốc độ bọc vỏ: việc bọc vỏ phải báo chưa xếp');
  console.log('thiếu thông số:', w.slice(0, 2).join(' | '));
  // Ngưỡng cỡ lớn là thông số: hạ xuống 1,5 mm² thì mã 1,5 mm² dùng tốc độ cỡ lớn (chậm hơn) → lâu hơn
  const a = schedule(c.orders, c), b = schedule(c.orders, { ...c, cfg: { ...c.cfg, flow: { size_large_mm2: 1.5 } } });
  const runOf = (x: typeof a) => x.slots.filter((s) => s.op === 'CD1' || s.op === 'CD2').reduce((acc, s) => acc + (s.end - s.runStart), 0);
  if (!(runOf(b) > runOf(a))) bad('ngưỡng cỡ lớn 1,5 mm² phải làm bện, bọc chạy lâu hơn');
}
// 12. Mô hình người đứng máy (quyết định 28/10/2026)
{
  const runPack = (s: ReturnType<typeof run>) => s.sch.slots.filter((x) => x.op === 'CD6').reduce((a, x) => a + (x.end - x.runStart), 0);
  // Đóng gói mặc định 2 người; TP SX đặt 1 người cho mọi ngày → tốc độ 50 % (chạy lâu gấp đôi), MES vẫn ghi đủ người có mặt suốt khối
  const two = k30;
  const days = Array.from({ length: 60 }, (_, i) => { const d = new Date(Date.UTC(2026, 9, 28 + i)); return d.toISOString().slice(0, 10); });
  const one = run('đóng gói 1 người mọi ngày', { people: { crews: days.map((d) => ({ date: d, machine: 'PACK-01', crew: 1 })) } });
  const r = runPack(one) / runPack(two);
  if (!(r > 1.9 && r < 2.1)) bad(`đóng gói 1 người phải chạy lâu gấp đôi (được ${r.toFixed(2)})`);
  if (!two.sch.slots.filter((x) => x.op === 'CD6').every((x) => x.crew === 2)) bad('đóng gói mặc định 2 người');
  if (!one.sch.slots.filter((x) => x.op === 'CD6').every((x) => x.crew === 1)) bad('đóng gói 1 người: khối phải ghi 1 người');
  for (const s of two.sch.slots.filter((x) => x.op === 'CD6')) {
    const ps = new Set((s.attend ?? []).filter((a) => a.k === 'RUN').map((a) => a.p));
    if (ps.size !== 2) { bad(`khối đóng gói ${s.key} phải có 2 người có mặt`); break; }
  }
  // Tổ đóng gói đặt sẵn người cụ thể
  const named = run('tổ đóng gói chỉ định NV4', { people: { crews: days.map((d) => ({ date: d, machine: 'PACK-01', crew: 1, members: ['NV4'] })) } });
  if (named.sch.slots.filter((x) => x.op === 'CD6').some((x) => (x.attend ?? []).some((a) => a.k === 'RUN' && a.p !== 'NV4'))) bad('tổ đóng gói chỉ định NV4: chỉ NV4 đứng máy');
  // TP SX chọn 1 người nhưng tổ 2 người: thêm người có tay nghề cho đủ tổ
  const pick1 = run('tổ 2 người, TP SX chọn NV3', { people: { crews: days.map((d) => ({ date: d, machine: 'PACK-01', crew: 2, members: ['NV3'] })) } });
  if (!pick1.sch.slots.filter((x) => x.op === 'CD6').every((x) => x.crew === 2 && (x.attend ?? []).some((a) => a.p === 'NV3'))) bad('tổ 2 người chọn NV3: phải đủ 2 người, có NV3');
  // Một người trong tổ vắng nửa ca sau: buổi sáng 2 người, buổi chiều 1 người vẫn đóng gói (không bỏ trống cả ngày)
  {
    const D = k30.c.D(1);
    // ngày đóng gói kín cả ngày trên lịch gốc (có khối qua giữa ngày)
    const packDay = k30.sch.slots.filter((x) => x.op === 'CD6').map((x) => Math.floor(x.start / D))
      .find((d) => k30.sch.slots.some((x) => x.op === 'CD6' && x.start < d * D + D / 2 - 30 && x.end > d * D + D / 2 + 30))!;
    const date = k30.c.cal.days[packDay];
    const pm = run(`NV3 vắng chiều ${date}`, { people: { absences: [{ code: 'NV3', from: date, to: date, part: 'PM' }] } });
    const onDay = pm.sch.slots.filter((x) => x.op === 'CD6' && Math.floor(x.start / D) === packDay);
    const half = packDay * D + D / 2;
    if (!onDay.some((x) => x.crew === 2 && x.start < half)) bad('vắng nửa ca sau: buổi sáng vẫn đóng gói 2 người');
    if (!onDay.some((x) => x.crew === 1 && x.end > half)) bad('vắng nửa ca sau: buổi chiều đóng gói 1 người');
    if (pm.score.makespan > k30.score.makespan + 0.3) bad('một người vắng nửa ca không được làm chậm cả ngày');
  }
  // Người đóng gói kiêm thay bobin máy xoắn: đóng gói ngắt quãng ngắn, không bỏ trống cả ngày
  const pk2 = run('NV4 kiêm máy xoắn', { ops: baseOps.map((o) => o.code === 'NV4' ? { ...o, skills: ['PACK-01', 'TWS-01'] } : o) });
  if (pk2.score.makespan > k30.score.makespan + 0.3) bad('người đóng gói kiêm thay bobin máy khác không được làm chậm cả ngày');
  // NV3 nghỉ phép cả tháng: đóng gói còn 1 người (NV4) → chậm như tổ 1 người, không ai vắng mà vẫn được xếp
  const abs = run('NV3 nghỉ phép', { people: { absences: [{ code: 'NV3', from: '2026-10-28', to: '2026-12-31', part: 'FULL' }] } });
  if (abs.sch.slots.some((x) => (x.attend ?? []).some((a) => a.p === 'NV3'))) bad('NV3 nghỉ phép vẫn có việc');
  if (!(runPack(abs) > runPack(two) * 1.9)) bad('NV3 nghỉ phép: đóng gói còn 1 người phải chậm');
  // NV2 (bện, xoắn) nghỉ 2 ngày đầu: không có đoạn có mặt của NV2 trong 2 ngày đó; máy bện/xoắn không khởi động khi không ai đứng
  const abs2 = run('NV2 nghỉ 2 ngày đầu', { people: { absences: [{ code: 'NV2', from: '2026-10-28', to: '2026-10-29', part: 'FULL' }] } });
  const D2 = abs2.c.D(2);
  if (abs2.sch.slots.some((x) => (x.attend ?? []).some((a) => a.p === 'NV2' && a.f < D2 - 1e-6))) bad('NV2 vắng 2 ngày đầu vẫn được xếp có mặt');
  if (abs2.sch.slots.some((x) => (x.machine === 'BUN-01' || x.machine === 'TWS-01') && x.start < D2 - 1e-6)) bad('máy bện/xoắn khởi động khi người đứng máy vắng');
  // Vắng nửa ca sau ngày đầu: không có mặt sau giờ nghỉ trưa
  const half = run('NV2 vắng chiều ngày đầu', { people: { absences: [{ code: 'NV2', from: '2026-10-28', to: '2026-10-28', part: 'PM' }] } });
  const H = half.c.cal.S / 2, D1 = half.c.D(1);
  if (half.sch.slots.some((x) => (x.attend ?? []).some((a) => a.p === 'NV2' && a.t > H + 1e-6 && a.f < D1 - 1e-6))) bad('NV2 vắng chiều vẫn được xếp có mặt buổi chiều');
  // Người đang học không tự đứng máy: NV2 chỉ "đang học" máy bện → máy bện không chạy
  const learn = run('chỉ có người đang học máy bện', { ops: baseOps.map((o) => o.code === 'NV2' ? { ...o, skills: ['TWS-01'], learning: ['BUN-01'] } : o) }, false);
  if (learn.sch.slots.some((x) => x.machine === 'BUN-01')) bad('người đang học không được tự đứng máy bện');
  // Kiêm nhiệm tạm theo khoảng ngày: NV1 kiêm máy bện từ 30/10 → máy bện chỉ chạy từ 30/10 với người NV1
  const cov = run('NV1 kiêm nhiệm máy bện từ 30/10', { ops: baseOps.map((o) => o.code === 'NV2' ? { ...o, skills: ['TWS-01'] } : o),
    people: { covers: [{ code: 'NV1', machine: 'BUN-01', from: '2026-10-30', to: '2026-12-31' }] } });
  const D30 = cov.c.D(2);
  const bun = cov.sch.slots.filter((x) => x.machine === 'BUN-01');
  if (!bun.length || bun.some((x) => x.start < D30 - 1e-6)) bad('kiêm nhiệm từ 30/10: máy bện chỉ chạy từ 30/10');
  if (bun.some((x) => (x.attend ?? []).some((a) => a.p !== 'NV1' || !a.c))) bad('kiêm nhiệm tạm: người có mặt ở máy bện phải là NV1, đánh dấu kiêm nhiệm');
  // Máy tự chạy: người chỉ có mặt lúc khởi động (phút đổi máy + 20 phút) và mỗi lần thay bobin (5 phút), không giữ người suốt khối
  const s1 = k30.sch.slots.find((x) => x.machine === 'BUN-01')!;
  const st = (s1.attend ?? []).filter((a) => a.k === 'START'), bob = (s1.attend ?? []).filter((a) => a.k === 'BOB');
  const presence = (s1.attend ?? []).reduce((a, x) => a + x.t - x.f, 0);
  if (st.length !== 1 || Math.abs(st[0].t - st[0].f - ((s1.runStart - s1.start) + 20)) > 1e-6) bad('khởi động: người có mặt = phút đổi máy + 20 phút');
  if (!bob.length || bob.some((a) => Math.abs(a.t - a.f - 5) > 1e-6)) bad('thay bobin: mỗi lần 5 phút');
  if (presence > (s1.end - s1.start) * 0.5) bad('máy tự chạy: người không đứng suốt khối');
  // Số lần thay bobin ≈ mét ÷ mét một bobin (10.000 m ở bện)
  const bunAll = k30.sch.slots.filter((x) => x.op === 'CD1');
  const nBob = bunAll.reduce((a, x) => a + (x.attend ?? []).filter((y) => y.k === 'BOB').length, 0);
  const meters = bunAll.reduce((a, x) => a + x.qty, 0);
  if (Math.abs(nBob - meters / 10000) > bunAll.length + 1) bad(`số lần thay bobin bện ${nBob} lệch xa ${(meters / 10000).toFixed(1)}`);
  // Thông số phút thay bobin lớn hơn → người bận hơn, không nhanh hơn
  const slowBob = run('thay bobin 30 phút', { people: { bobbin_min: 30, start_min: 60 } });
  if (slowBob.score.makespan < k30.score.makespan - 0.05) bad('khởi động / thay bobin lâu hơn không được nhanh hơn');
  // Ngưỡng cảnh báo số máy/người: chỉ cảnh báo, không chặn
  const w1 = run('cảnh báo quá 1 máy/người', { people: { watch_max: 1 } });
  if (!(w1.sch.warnings ?? []).some((w) => w.includes('quá 1 máy'))) bad('watch_max 1: phải cảnh báo một người phụ trách nhiều máy');
  if (Math.abs(w1.score.makespan - k30.score.makespan) > 1e-6) bad('watch_max chỉ cảnh báo, không đổi lịch');
  // Tỷ lệ xếp lịch riêng: máy xoắn 60 % (hỏng nhiều) → xoắn chạy chậm theo tỷ lệ, lịch không nhanh hơn
  const av = run('máy xoắn tỷ lệ riêng 60 %', { kgh: 200, avail: { 'TWS-01': { fill: 60 } } });
  const twRun = (s: ReturnType<typeof run>) => s.sch.slots.filter((x) => x.machine === 'TWS-01').reduce((a, x) => a + (x.end - x.runStart), 0);
  const av0 = run('máy xoắn tỷ lệ chung', { kgh: 200 });
  const ratio = twRun(av) / twRun(av0);
  if (!(ratio > 1.4 && ratio < 1.6)) bad(`tỷ lệ riêng 60 %/90 %: máy xoắn phải chạy lâu hơn ~1,5 lần (được ${ratio.toFixed(2)})`);
  if (av.score.makespan < av0.score.makespan - 0.05) bad('tỷ lệ riêng thấp hơn không được nhanh hơn');
  // Máy Dừng (STOP) có giờ chạy lại: chặn lịch như máy hỏng
  const stop = run('EXT-SI-02 dừng 3 ngày', { win: (D) => [{ machine: 'EXT-SI-02', from: 0, to: D(3), kind: 'STOP', label: 'EXT-SI-02 dừng' }] });
  if (stop.sch.slots.some((x) => x.machine === 'EXT-SI-02' && x.start < stop.c.D(3) - 1e-6)) bad('máy Dừng vẫn có việc trước giờ chạy lại');
  // Bảo dưỡng giữ chỗ tạm (chưa chốt) vẫn trừ giờ máy
  const pm = run('BUN-01 bảo dưỡng giữ chỗ tạm ngày 2', { win: (D) => [{ machine: 'BUN-01', from: D(1), to: D(1) + 240, kind: 'PM', label: 'BD tạm', tentative: true }] });
  if (pm.sch.slots.some((x) => x.machine === 'BUN-01' && x.start < pm.c.D(1) + 240 - 1e-6 && x.end > pm.c.D(1) + 1e-6)) bad('bảo dưỡng giữ chỗ tạm: máy bện vẫn chạy trong giờ giữ chỗ');
}
// 13. Máy chạy 2–3 ca (anh Bình duyệt 28/10/2026): người theo ca, máy trộn 1 người riêng, ca dài chỉ khi thiếu người, tối đa 12 giờ/ngày
{
  type MS = { machine: string; from: string; to: string; shifts: number };
  const SIL = ['SIL-MIX', 'EXT-SI-01', 'EXT-SI-02'];
  const rng = (ms: string[], n: number, from = '2026-10-28', to = '2026-12-31'): MS[] => ms.map((m) => ({ machine: m, from, to, shifts: n }));
  const go = (tag: string, ms: MS[], o: { assume?: boolean; ops?: OperatorInfo[]; people?: PeopleCfg; shifts?: Config['shifts']; prev?: { sch: ReturnType<typeof schedule>; B: number } } = {}) => {
    const c = ctxOf({ ops: o.ops, people: o.people });
    c.cfg.machine_shifts = ms;
    if (o.shifts) c.cfg.shifts = o.shifts;
    const cal = makeCalendar(c.cfg, '2026-10-28');
    const ctx = { ...c, cal };
    const t0 = Date.now();
    const sopt = o.prev ? { from: { S: o.prev.sch.S, SPD: o.prev.sch.SPD, slots: o.prev.sch.slots }, boundary: o.prev.B * cal.S * cal.SPD } : {};
    const sch = schedule(c.orders, ctx, { ...sopt, assumeStaff: o.assume });
    const ms0 = Date.now() - t0;
    const v = validateSchedule(sch, c.orders, ctx, { from: o.prev ? o.prev.B * cal.S * cal.SPD : 0 });
    if (v.length) bad(`${tag}: ${v.slice(0, 3).join('; ')}`);
    if (ms0 > 2000) bad(`${tag}: chạy quá lâu ${ms0} ms`);
    const sc = scoreOf(sch, cal, c.orders);
    console.log(`${tag}: ${cal.SPD} ca/ngày, ${sc.makespan.toFixed(2)} ngày, chưa xếp ${sch.unplaced.length}, ${ms0} ms`);
    return { sch, sc, cal, c };
  };
  const one = go('1 ca', []);
  const empty = go('lịch 3 ca, không máy nào thêm ca', [{ machine: 'ZZZ', from: '2026-10-28', to: '2026-12-31', shifts: 3 }]);
  if (Math.abs(empty.sc.makespan - one.sc.makespan) > one.sc.makespan * 0.05) bad('lịch có ca 2, ca 3 nhưng máy nào cũng 1 ca phải gần như lịch 1 ca');
  if (empty.sch.slots.some((x) => (x.attend ?? []).some((a) => Math.floor(a.f / empty.cal.S) % 3 !== 0))) bad('máy 1 ca: người chỉ có mặt trong ca 1');
  // Máy trộn + line silicone chạy 2 ca, đủ người: nhanh hơn rõ; 3 ca nhanh hơn nữa
  const s2 = go('trộn + line silicone 2 ca (đủ người)', rng(SIL, 2), { assume: true });
  const s3 = go('trộn + line silicone 3 ca (đủ người)', rng(SIL, 3), { assume: true });
  if (!(s2.sc.makespan < one.sc.makespan - 1.5)) bad('máy cổ chai chạy 2 ca phải xong sớm hơn rõ');
  if (!(s3.sc.makespan <= s2.sc.makespan + 0.05)) bad('3 ca không được chậm hơn 2 ca');
  // Máy không chạy ca thêm: không có việc trong ca 2, ca 3 (validateSchedule kiểm giờ máy không chạy)
  const S2 = s2.cal.S;
  if (s2.sch.slots.some((x) => !SIL.includes(x.machine) && x.end > x.start + 1e-6 && Math.floor((x.start + 1e-6) / S2) % 3 !== 0)) bad('máy 1 ca có việc ngoài ca 1');
  if (!s2.sch.slots.some((x) => SIL.includes(x.machine) && Math.floor((x.start + x.end) / 2 / S2) % 3 === 1)) bad('máy chạy 2 ca phải có việc trong ca 2');
  // Người thật chỉ làm ca 1: ca 2 thiếu người → người ca 1 làm ca dài (≤ 4 giờ/ngày, ≤ 40 giờ/tháng), hết giờ tháng thì máy không chạy ca 2
  const real = go('trộn + line silicone 2 ca, người hiện có', rng(SIL, 2));
  const R = real.sch.roster!;
  if (!R.ext.length) bad('thiếu người ca 2: người ca 1 phải làm ca dài');
  if (R.ext.some((e) => e.hours > 4 + 1e-9)) bad('ca dài: làm thêm tối đa 4 giờ/ngày (12 giờ/ngày)');
  for (const [p, mo] of Object.entries(R.ot)) for (const [mon, h] of Object.entries(mo)) if (h > 40 + 1e-9) bad(`${p} làm thêm ${h} giờ tháng ${mon} > 40`);
  if (!R.shortages.some((x) => x.why.includes('hết giờ làm thêm'))) bad('hết 40 giờ làm thêm tháng: phải báo thiếu người');
  if (!(real.sch.warnings ?? []).some((w) => w.startsWith('Thiếu người ca 2'))) bad('phải cảnh báo thiếu người ca 2');
  if (real.sc.makespan > one.sc.makespan + 0.3) bad('thêm ca với người hiện có không được chậm hơn 1 ca');
  // Giờ làm tối đa 10 giờ/ngày → ca dài chỉ thêm 2 giờ
  const r10 = go('giờ làm tối đa 10 giờ/ngày', rng(SIL, 2), { people: { day_max_h: 10 } });
  if (!r10.sch.roster!.ext.length || r10.sch.roster!.ext.some((e) => e.hours > 2 + 1e-9)) bad('10 giờ/ngày: ca dài tối đa 2 giờ');
  // Có người làm ca 2: NV6 đứng máy trộn, NV7 đứng line silicone → không thiếu người, không ca dài; NV6, NV7 không có mặt ca 1
  const ops2 = [...baseOps, op('NV6', ['SIL-MIX']), op('NV7', ['EXT-SI-01', 'EXT-SI-02'])];
  const shift2 = [{ code: 'NV6', from: '2026-10-28', to: '2026-12-31', shift: 2 }, { code: 'NV7', from: '2026-10-28', to: '2026-12-31', shift: 2 }];
  const w2 = go('trộn + line silicone 2 ca, NV6 + NV7 làm ca 2', rng(SIL, 2), { ops: ops2, people: { op_shifts: shift2 } });
  if (w2.sch.roster!.shortages.length || w2.sch.roster!.ext.length) bad('đủ người ca 2: không thiếu người, không ca dài');
  const inSeg = (x: { f: number }, j: number) => Math.floor((x.f + 1e-6) / w2.cal.S) % 3 === j;
  const att = w2.sch.slots.flatMap((x) => (x.attend ?? []).map((a) => ({ ...a, m: x.machine })));
  if (att.some((a) => (a.p === 'NV6' || a.p === 'NV7') && !inSeg(a, 1))) bad('người ca 2 chỉ có mặt trong ca 2');
  if (!att.some((a) => a.p === 'NV6' && a.k === 'MIX')) bad('NV6 phải đứng máy trộn ca 2');
  if (att.some((a) => a.p === 'NV6' && a.k !== 'MIX')) bad('người đứng máy trộn chỉ đứng máy trộn (1 người riêng)');
  if (!(w2.sc.makespan < one.sc.makespan - 1)) bad('đủ người ca 2: phải nhanh hơn 1 ca');
  // Một người ca 2 đứng cả máy trộn lẫn line silicone: máy trộn giữ người suốt giờ trộn nên line ca 2 không có người khởi động / thay bobin
  // khi đang trộn (không có đoạn có mặt chồng nhau)
  const solo = go('một người ca 2 đứng cả máy trộn và line', rng(SIL, 2), { ops: [...baseOps, op('NV6', [...SIL])], people: { op_shifts: [shift2[0]] } });
  const sAtt = solo.sch.slots.flatMap((x) => (x.attend ?? []).filter((a) => a.p === 'NV6'));
  if (!sAtt.length) bad('NV6 ca 2 phải có việc');
  // Người ca 2 vắng nửa sau ca: không có mặt nửa sau ca 2 ngày đó
  const pm = go('NV6 vắng nửa sau ca 2 ngày 30/10', rng(SIL, 2), { ops: ops2, people: { op_shifts: shift2, absences: [{ code: 'NV6', from: '2026-10-30', to: '2026-10-30', part: 'PM' }] } });
  const di = pm.cal.days.indexOf('2026-10-30'), D = pm.cal.S * 3, mid = di * D + pm.cal.S * 1.5;
  if (pm.sch.slots.some((x) => (x.attend ?? []).some((a) => a.p === 'NV6' && a.t > mid + 1e-6 && a.f < di * D + 2 * pm.cal.S - 1e-6))) bad('người ca 2 vắng nửa sau ca vẫn có mặt');
  // Đổi ca phải nghỉ đủ: database kiểm (tests/test_machine_shifts.sql); lịch chỉ đọc ca của người
  // Ca B trùng giờ ca A (B 14–22, A đến 17): phần trùng không tính thêm, máy chạy ca 2 từ 17:00
  const roomB = (r: typeof s2) => { const L = r.sch.roster!.closed['EXT-SI-01'] ?? []; const d0 = 3 * r.cal.S * 3 + r.cal.S; return L.filter(([x, y]) => x < d0 + r.cal.S && y > d0).map(([x, y]) => [Math.max(x, d0) - d0, Math.min(y, d0 + r.cal.S) - d0]); };
  const ov = roomB(s2);
  if (!ov.length || Math.abs(ov[0][0]) > 1e-6 || Math.abs(ov[0][1] - s2.cal.S * 3 / 8) > 1) bad(`ca B 14–22 trùng ca A đến 17:00: 3/8 đầu ca B phải đóng (được ${JSON.stringify(ov)})`);
  const shB = baseCfg.shifts.map((x) => x.code === 'B' ? { ...x, start_time: '17:00', end_time: '01:00' } : x.code === 'C' ? { ...x, start_time: '01:00', end_time: '08:00' } : x);
  const s2b = go('ca 2 17:00–01:00 (đủ người)', rng(SIL, 2), { assume: true, shifts: shB });
  const ov2 = roomB(s2b);
  if (ov2.some(([x]) => x < 1)) bad('ca B 17–01 không trùng ca A: đầu ca B phải chạy');
  if (!(s2b.sc.makespan <= s2.sc.makespan + 0.05)) bad('ca 2 không trùng ca 1 (nhiều giờ hơn) không được chậm hơn');
  // Máy đóng gói 2 ca (đủ người): tổ 2 người ca 2
  const pk = go('đóng gói 2 ca (đủ người)', rng(['PACK-01'], 2), { assume: true });
  if (!pk.sch.slots.some((x) => x.op === 'CD6' && x.crew === 2 && Math.floor((x.start + 1e-6) / pk.cal.S) % 3 === 1)) bad('đóng gói ca 2: tổ 2 người');
  // Xếp lại: lịch cũ 1 ca, từ ngày thứ 3 máy trộn + line silicone chạy 2 ca → phần trước mốc giữ, đủ mét, hợp lệ
  const rb = go('xếp lại từ ngày 3 sang 2 ca', rng(SIL, 2, '2026-10-31'), { assume: true, prev: { sch: one.sch, B: 3 } });
  if (!(rb.sc.makespan < one.sc.makespan - 0.5)) bad('xếp lại sang 2 ca từ ngày 3 phải xong sớm hơn');
}
// 14. Luân phiên đứng máy, ca 2 xoay theo tuần (anh Bình duyệt 28/10/2026, bản 2): mọi người đứng mọi máy; người ít giờ cộng dồn xếp trước;
//     máy trộn / đóng gói đổi người đầu ngày khi lệch quá 15 %; sổ giờ đứng máy; QC ca 2; máy dừng thì việc chạy dở chuyển máy khác
{
  const ALL = baseMachines.map((m) => m.code);
  const allOps = baseOps.map((o) => ({ ...o, skills: [...ALL] }));
  const ca1 = { code: 'A', active: true, start_time: '06:00', end_time: '14:00', break_min: 30 };
  const SH = [ca1, { code: 'B', active: false, start_time: '14:00', end_time: '22:00', break_min: 30 }, { code: 'C', active: false, start_time: '22:00', end_time: '06:00', break_min: 45 }];
  const go = (tag: string, o: { people?: PeopleCfg; ms?: { machine: string; from: string; to: string; shifts: number }[]; ops?: OperatorInfo[]; shifts?: Config['shifts']; win?: (D: (d: number) => number) => Window[] } = {}) => {
    const c = ctxOf({ ops: o.ops ?? allOps, people: o.people });
    c.cfg.shifts = o.shifts ?? SH;
    c.cfg.machine_shifts = o.ms ?? [];
    const cal = makeCalendar(c.cfg, '2026-10-28');
    const D = (d: number) => d * cal.S * cal.SPD;
    const windows = o.win ? o.win(D) : [];
    const ctx = { ...c, cal };
    const sch = schedule(c.orders, ctx, { windows });
    const v = validateSchedule(sch, c.orders, ctx, { windows });
    if (v.length) bad(`${tag}: ${v.slice(0, 3).join('; ')}`);
    const sc = scoreOf(sch, cal, c.orders);
    const tot = new Map<string, number>();
    for (const h of sch.hours ?? []) tot.set(h.p, (tot.get(h.p) ?? 0) + h.m);
    const vals = (o.ops ?? allOps).map((w) => tot.get(w.code) ?? 0), avg = vals.reduce((a, x) => a + x, 0) / vals.length;
    const dev = Math.max(...vals.map((x) => Math.abs(x - avg) / Math.max(1, avg)));
    console.log(`${tag}: ${sc.makespan.toFixed(2)} ngày, giờ đứng máy ${(o.ops ?? allOps).map((w) => `${w.code} ${Math.round((tot.get(w.code) ?? 0) / 60)}`).join(', ')}, lệch ±${Math.round(dev * 100)} %`);
    return { sch, sc, cal, tot, dev, D };
  };
  const narrow = go('tay nghề hẹp (như trước), ca 1 06–14', { ops: baseOps });
  const rot = go('mọi người mọi máy, luân phiên', {});
  if (!(narrow.dev > 0.5)) bad('tay nghề hẹp: giờ đứng máy phải lệch nhiều (đối chứng)');
  // dữ liệu thử ngắn (3 tuần, mỗi ngày đứng máy trộn / đóng gói 7,5 giờ ≈ 17 % bình quân): yêu cầu lệch giảm hơn một nửa và dưới 40 %
  if (!(rot.dev <= 0.4 && rot.dev < narrow.dev / 2)) bad(`luân phiên: giờ đứng máy mỗi người phải gần bình quân (lệch ±${Math.round(rot.dev * 100)} %)`);
  if (rot.sc.makespan > narrow.sc.makespan + 0.5) bad('luân phiên không được làm kế hoạch chậm hơn rõ');
  if (!(narrow.sch.warnings ?? []).some((w) => w.startsWith('Giờ đứng máy 4 tuần tới lệch quá'))) bad('tay nghề hẹp: phải cảnh báo lệch giờ đứng máy');
  // máy trộn: mỗi ngày một người trộn (không đổi giữa ca), đổi người qua các ngày
  const mixBy = new Map<number, Set<string>>();
  for (const x of rot.sch.slots.filter((y) => y.op === 'CD0')) for (const a of x.attend ?? []) {
    const d = Math.floor(a.f / (rot.cal.S * rot.cal.SPD)); const st = mixBy.get(d) ?? new Set<string>(); st.add(a.p); mixBy.set(d, st);
  }
  const oneADay = [...mixBy.values()].filter((st) => st.size === 1).length;
  if (oneADay < mixBy.size * 0.8) bad(`máy trộn: phần lớn các ngày chỉ một người trộn (được ${oneADay}/${mixBy.size})`);
  if (new Set([...mixBy.values()].flatMap((st) => [...st])).size < 3) bad('máy trộn: người trộn phải luân phiên qua các ngày');
  // sổ giờ 4 tuần trước: NV1 đã đứng nhiều thì được xếp ít hơn
  const led = [] as { code: string; date: string; min: number }[];
  for (let i = 1; i <= 24; i++) led.push({ code: 'NV1', date: new Date(Date.parse('2026-10-28') - i * 864e5).toISOString().slice(0, 10), min: 420 });
  const hist = go('NV1 đã đứng máy nhiều 4 tuần trước', { people: { ledger: led } });
  const avgH = [...hist.tot.values()].reduce((a, x) => a + x, 0) / allOps.length;
  if (!((hist.tot.get('NV1') ?? 0) < avgH * 0.9)) bad('người nhiều giờ cộng dồn 4 tuần trước phải được xếp ít hơn');
  // sổ giờ: có dòng mỗi người mỗi ngày; ca 1 06–14 không có giờ đêm; ca 2 17–01 có giờ đêm
  if (!(rot.sch.hours ?? []).length || (rot.sch.hours ?? []).some((h) => h.n > 0)) bad('sổ giờ: ca 1 06–14 phải có giờ đứng máy, không có giờ đêm');
  const SIL = ['SIL-MIX', 'EXT-SI-01', 'EXT-SI-02'];
  const ms = SIL.map((m) => ({ machine: m, from: '2026-10-28', to: '2026-11-07', shifts: 2 }));
  const ca2 = [{ code: 'NV3', from: '2026-10-28', to: '2026-11-07', shift: 2 }, { code: 'NV4', from: '2026-10-28', to: '2026-11-07', shift: 2 }];
  const SH17 = [{ ...ca1, start_time: '08:00', end_time: '17:00', break_min: 60 }, { code: 'B', active: false, start_time: '17:00', end_time: '01:00', break_min: 45 }, { code: 'C', active: false, start_time: '01:00', end_time: '08:00', break_min: 30 }];
  const night = go('ca 2 17:00–01:00, NV3 + NV4 làm ca 2', { ms, shifts: SH17, people: { op_shifts: ca2, qc_cover: [{ from: '2026-10-28', to: '2026-11-07' }] } });
  if (!(night.sch.hours ?? []).some((h) => (h.p === 'NV3' || h.p === 'NV4') && h.n > 0 && h.s === 2)) bad('sổ giờ: người ca 2 17–01 phải có giờ đêm, ghi ca 2');
  if ((night.sch.hours ?? []).some((h) => h.p !== 'NV3' && h.p !== 'NV4' && h.n > 0)) bad('sổ giờ: người ca 1 không có giờ đêm');
  // QC ca 2: có người đo mẫu thì bobin ca 2 không chờ sáng hôm sau; không có thì chậm hơn hoặc bằng
  const cov = go('ca 2 14–22 có người đo mẫu QC', { ms, people: { op_shifts: ca2, qc_cover: [{ from: '2026-10-28', to: '2026-11-07' }] } });
  const noc = go('ca 2 14–22 không có người đo mẫu QC', { ms, people: { op_shifts: ca2 } });
  if (noc.sc.makespan < cov.sc.makespan - 0.05) bad('không có người đo mẫu ca 2 không được nhanh hơn có người đo mẫu');
  // Máy chạy 2 ca mà line silicone đang chạy dở bị hỏng: việc chuyển sang line còn lại (không treo, không "Không có silicone")
  const down = go('2 ca, EXT-SI-02 hỏng từ ngày 3', { ms, people: { op_shifts: ca2, qc_cover: [{ from: '2026-10-28', to: '2026-11-07' }] },
    win: (D) => [{ machine: 'EXT-SI-02', from: D(2), to: Infinity, kind: 'DOWN', label: 'EXT-SI-02 hỏng' }] });
  if (down.sch.unplaced.length || (down.sch.warnings ?? []).some((w) => w.startsWith('Không có silicone'))) bad('line hỏng giữa chừng: việc chạy dở phải chuyển line khác, không treo');
}
console.log(errs ? `${errs} LỖI` : 'TẤT CẢ ĐẠT');
