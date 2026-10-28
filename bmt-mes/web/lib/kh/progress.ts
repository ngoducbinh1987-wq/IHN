// Tiến độ thực tế sau ca (anh Bình 28/10/2026): so sản lượng máy đạt được (phiếu hoàn thành bobin; máy không có phiếu
// thì báo cáo ca) với lịch đang dùng đến lúc hết ca, ra số mét còn phải làm từng việc (credit: thiếu thì cộng, vượt thì trừ).
// Máy chưa có số liệu ca nào thì MES tạm coi chạy đúng lịch và báo "chưa có phiếu hoàn thành".
import { type Calendar, type Order, type Schedule, BOBBIN, dayIndex, flowOf, type Config } from './scheduler';
import { cutAt, timeT } from './load';

export type SlipRow = { line: string; op: string; machine: string; at: { date: string; min: number }; m: number };
export type ReportRow = { date: string; code: string; machine: string; lines: { key?: string; m: number }[] };
export type MachineProgress = { machine: string; planned: number; actual: number; slips: number; missing: boolean };
export type Progress = {
  credit: Map<string, number>;
  machines: MachineProgress[];               // ca vừa hết: mét theo lịch / thực tế từng máy
  missing: string[];                         // máy có việc trong ca mà chưa có phiếu hoàn thành, báo cáo ca
  short: { line: string; op: string; m: number }[]; // mét bù (+ thiếu, − vượt) từng lô · công đoạn
};

const schedOp = (op: string) => (op === 'CD4' ? 'CD3' : op);

export function progress(
  kh: { cal: Calendar; sch: Schedule; cfg: Pick<Config, 'flow'>; orders: Order[]; machines: { code: string; machine_type: string }[] },
  cut: { date: string; code: string },
  slips: SlipRow[], reports: ReportRow[],
): Progress {
  const { cal, sch } = kh, S = cal.S, SPD = cal.SPD;
  const cutT = cutAt(cal, cut.date, cut.code), cutSeg = Math.round(cutT / S);
  const unit = flowOf(kh.cfg).unit_m;
  const segIdx = cal.shifts.findIndex((x) => x.code === cut.code);
  const finSeg = segIdx >= 0 ? dayIndex(cal, cut.date) * SPD + segIdx : cutSeg - 1;
  const slotsOf = (m: string) => (sch.byMachine.get(m) ?? []).filter((x) => x.op !== 'CD0' && x.meters > 0);
  const planned = (sl: Schedule['slots'][number], a: number, b: number) =>
    Math.min(sl.meters, Math.max(0, Math.min(sl.end, b) - Math.max(sl.runStart, a)) * sl.rate);
  const seg = (T: number) => Math.floor((T - 1e-6) / S);

  // phiếu đến lúc hết ca (phiếu xong sau lúc hết ca thuộc phần sau)
  const sl2 = slips.map((x) => ({ ...x, op: schedOp(x.op), seg: seg(timeT(cal, x.at)) })).filter((x) => x.seg < cutSeg && x.m > 0);
  const credit = new Map<string, number>();
  const add = (k: string, v: number) => credit.set(k, (credit.get(k) ?? 0) + v);
  const keysOf = (line: string, op: string) => [...new Set(sch.slots.filter((x) => x.lineId === line && x.op === op).map((x) => x.key))];
  const machines: MachineProgress[] = [];
  const missing: string[] = [];

  for (const m of kh.machines) {
    if (m.machine_type === 'MIXER') continue;
    const slots = slotsOf(m.code);
    const mySlips = sl2.filter((x) => x.machine === m.code);
    // ca có số liệu: có phiếu hoàn thành xong trong ca, hoặc có báo cáo ca
    const dataSegs = new Set(mySlips.map((x) => x.seg));
    const myReps = reports.filter((r) => r.machine === m.code);
    for (const r of myReps) {
      const j = cal.shifts.findIndex((x) => x.code === r.code);
      const di = dayIndex(cal, r.date);
      const s = j >= 0 ? di * SPD + j : di * SPD + cal.shifts.filter((x) => x.code <= r.code).length - 1;
      if (s < cutSeg) dataSegs.add(s);
    }
    const last = Math.max(-1, ...[...dataSegs].filter((s) => s < cutSeg));
    // lịch: đến lúc hết ca (P); phần sau ca có số liệu cuối cùng coi như đã làm đúng lịch (chưa có phiếu)
    const assumedFrom = (last + 1) * S;
    for (const sl of slots) {
      const p = planned(sl, -Infinity, cutT), a = planned(sl, assumedFrom, cutT);
      if (p - a > 0) add(sl.key, p - a);
    }
    // thực tế: phiếu hoàn thành; ngày máy không có phiếu mà có báo cáo ca thì lấy số khai báo
    const byLineOp = new Map<string, number>();
    for (const x of mySlips) byLineOp.set(x.line + '|' + x.op, (byLineOp.get(x.line + '|' + x.op) ?? 0) + x.m);
    for (const [lo, mm] of byLineOp) {
      const [line, op] = lo.split('|');
      const own = slots.filter((x) => x.lineId === line && x.op === op);
      const base = own.length ? own : sch.slots.filter((x) => x.lineId === line && x.op === op);
      const tot = base.reduce((acc, x) => acc + x.meters, 0);
      if (!base.length) continue;
      const w = new Map<string, number>();
      for (const x of base) w.set(x.key, (w.get(x.key) ?? 0) + (tot > 0 ? x.meters / tot : 1 / base.length));
      for (const [k, f] of w) add(k, -mm * f);
    }
    const slipDays = new Set(mySlips.map((x) => cal.days[Math.floor(x.seg / SPD)]));
    for (const r of myReps) if (!slipDays.has(r.date)) for (const l of r.lines) if (l.key && l.m > 0) add(l.key, -l.m);

    // ca vừa hết: lịch / thực tế của máy
    const pF = slots.reduce((acc, sl) => acc + planned(sl, finSeg * S, (finSeg + 1) * S), 0);
    const inF = mySlips.filter((x) => x.seg === finSeg);
    const aF = inF.reduce((acc, x) => acc + x.m, 0);
    const miss = pF > 1 && !dataSegs.has(finSeg);
    if (pF > 1 || aF > 0) machines.push({ machine: m.code, planned: Math.round(pF), actual: Math.round(aF), slips: inF.length, missing: miss });
    if (miss) missing.push(m.code);
  }
  // dưới một bobin: coi như đúng tiến độ (bobin đang chạy dở lúc hết ca chưa có phiếu)
  const opOf = new Map(sch.slots.map((x) => [x.key, x.op]));
  for (const [k, v] of [...credit]) {
    const op = opOf.get(k) as keyof typeof BOBBIN | undefined;
    const lim = op ? Number(unit[op] ?? BOBBIN[op] ?? 5000) : 5000;
    if (Math.abs(v) < lim) credit.delete(k); else credit.set(k, Math.round(v));
  }
  const short = new Map<string, number>();
  for (const [k, v] of credit) { const [line, op] = k.split('|'); short.set(line + '|' + op, (short.get(line + '|' + op) ?? 0) + v); }
  return {
    credit, machines, missing,
    short: [...short].map(([k, m]) => { const [line, op] = k.split('|'); return { line, op, m }; }),
  };
}
