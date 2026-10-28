// Kiểm thử thuật toán xếp lịch theo thông số (máy trộn là nguồn cấp, hạn dùng silicone, gối đầu theo bobin, bộ tối ưu)
// trên dữ liệu thật KH-2610-03 (cấu hình Supabase 28/10/2026). Chạy: node --experimental-strip-types web/tests/kh-flow.test.ts
import { type Config, type FlowCfg, type MachineInfo, type OperatorInfo, type Order, type Op, type Window, makeCalendar, schedule, finishInfo } from '../lib/kh/scheduler.ts';
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

type Sc = { mpo?: number; kgh?: number; flow?: FlowCfg; machines?: MachineInfo[]; ops?: OperatorInfo[]; orders?: Order[]; win?: (D: (d: number) => number) => Window[] };
function ctxOf(sc: Sc) {
  const cfg: Config = JSON.parse(JSON.stringify(baseCfg));
  if (sc.kgh) { const r = cfg.rates.find((x) => x.op_code === 'CD0')!; r.rate_small = r.rate_large = sc.kgh; }
  cfg.flow = sc.flow ?? {};
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
run('máy bện hỏng ngày 1', { win: (D) => [{ machine: 'BUN-01', from: D(0), to: D(1), kind: 'DOWN', label: 'BUN-01 hỏng' }] });
const off = run('line silicone 2 ngừng dùng', { kgh: 200, win: () => [{ machine: 'EXT-SI-02', from: 0, to: Infinity, kind: 'OFF', label: 'EXT-SI-02 ngừng dùng' }] });
if (off.sch.slots.some((s) => s.machine === 'EXT-SI-02')) bad('line ngừng dùng vẫn có việc');
// 6. Người: thiếu NV5; không ai đứng máy trộn → line silicone không chạy (báo chưa xếp, không treo)
const noNv5 = run('vắng NV5', { ops: baseOps.filter((o) => o.code !== 'NV5') });
if (noNv5.score.makespan < k30.score.makespan - 0.05) bad('thiếu người không được nhanh hơn');
const noMixer = run('không ai biết đứng máy trộn', { ops: baseOps.map((o) => ({ ...o, skills: o.skills.filter((x) => x !== 'SIL-MIX') })) }, false);
if (noMixer.v.length) bad('không ai đứng máy trộn: không có người trộn thì không ràng buộc người (phải xếp được)');
const oneLane = run('1 người/1 máy, chỉ NV1 biết trộn', { mpo: 1 }, false);
if (oneLane.v.length) bad(`1 người/1 máy: ${oneLane.v[0]}`);
// NV1 đứng máy trộn thì không đứng line cùng lúc: line silicone chạy cùng lúc máy trộn có việc chỉ do NV5 đứng
for (const s of oneLane.sch.slots) if (s.op === 'CD2' && s.machine.startsWith('EXT-SI') && s.operator === 'NV1') bad('1 người/1 máy: NV1 vừa trộn vừa đứng line silicone');
const mixOff = run('máy trộn ngừng dùng', { win: () => [{ machine: 'SIL-MIX', from: 0, to: Infinity, kind: 'OFF', label: 'SIL-MIX ngừng dùng' }] }, false);
if (!mixOff.sch.unplaced.length) bad('máy trộn ngừng dùng: việc bọc silicone phải báo chưa xếp được');
// 7. Hai máy trộn
const two = run('hai máy trộn', { machines: [...baseMachines, mk('SIL-MIX-2', 'MIXER')], ops: baseOps.map((o) => o.code === 'NV1' ? { ...o, skills: [...o.skills, 'SIL-MIX-2'] } : o) });
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
  const v = validateSchedule(s2, [...c.orders, urgent], c, { from: Bd }).filter((x) => !x.startsWith('mét'));
  if (v.length) bad(`xếp lại có đơn gấp: ${v.slice(0, 3).join('; ')}`);
  const keepSig = (s: typeof s1) => s.slots.filter((x) => x.start < Bd && x.op !== 'CD0').map((x) => x.key + x.machine + x.start.toFixed(1)).sort().join();
  if (keepSig(s1) !== keepSig(s2)) bad('xếp lại làm đổi phần trước mốc');
  console.log('xếp lại có đơn gấp: đơn gấp xong', finishInfo(s2, c.cal, [...c.orders, urgent]).get('L6')?.finDate);
}
// 10. Bộ tối ưu: kịp ngày chốt bằng ít giờ công nhất, không vượt 4 giờ/ngày; máy trộn 200 kg/giờ → đề xuất dồn vào máy xoắn
{
  const c = ctxOf({ flow: {} });
  const tight = c.orders.map((o, i) => ({ ...o, commit: ['2026-10-31', '2026-11-05', '2026-11-05', '2026-11-05'][i] }));
  const t0 = Date.now();
  const r = optimize(tight, c, { windows: [] }, { mode: 'due', early_max_h: 4 });
  console.log(`tối ưu (chốt 05/11): ${r.base.score.makespan.toFixed(2)} → ${r.score.makespan.toFixed(2)} ngày, trễ ${r.base.score.late} → ${r.score.late}, ${r.evals} lần chạy, ${Date.now() - t0} ms`);
  if (!(r.score.late < r.base.score.late)) bad('bộ tối ưu phải giảm trễ hạn');
  if (Object.values(r.flow.extra_min ?? {}).some((x) => x > 240)) bad('tăng ca vượt 4 giờ/ngày');
  const v = validateSchedule(r.sch, r.orders, { ...c, cfg: { ...c.cfg, flow: r.flow } });
  if (v.length) bad(`lịch tối ưu: ${v[0]}`);
  const c2 = ctxOf({ kgh: 200 });
  const r2 = optimize(c2.orders, c2, {}, { mode: 'fastest' });
  const tw = r2.whatIf.find((w) => w.label.startsWith('Máy xoắn'))!, mx = r2.whatIf.find((w) => w.label.startsWith('Máy trộn'))!;
  console.log(`tối ưu (200 kg/giờ, nhanh nhất): cổ chai ${r2.bottleneck[0].group}; thêm 1 giờ máy xoắn ${tw.gain.toFixed(2)} ngày, máy trộn ${mx.gain.toFixed(2)} ngày`);
  if (r2.bottleneck[0].group !== 'TWISTER') bad('200 kg/giờ: cổ chai phải là máy xoắn');
  if (!(tw.gain > mx.gain)) bad('200 kg/giờ: thêm giờ máy xoắn phải lợi hơn máy trộn');
  // Không có ngày chốt, chế độ kịp hạn: không đề xuất tăng ca
  const r3 = optimize(c.orders.map((o) => ({ ...o, commit: null })), c, {}, { mode: 'due' });
  if (r3.proposals.length) bad('không trễ hạn thì không đề xuất tăng ca');
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
  if (!(scoreOf(b, c.cal, c.orders).makespan > scoreOf(a, c.cal, c.orders).makespan)) bad('ngưỡng cỡ lớn 1,5 mm² phải làm lịch dài hơn');
}
console.log(errs ? `${errs} LỖI` : 'TẤT CẢ ĐẠT');
