// Lệnh sản xuất ngày: dòng việc theo ca, kiểm tra trước khi phát, phiếu lĩnh cả ca
import { type Kh, dayPlan } from './load';
import { BOBBIN, type Slot, UNIT, dayIndex, peopleOf } from './scheduler';

export type DayRow = ReturnType<typeof dayPlan>[number];
export type Check = { ok: boolean; t: string; d?: string; info?: boolean };
// Phiếu lĩnh do database tính theo định mức BOM (app.kh_day_preview / plan.issue_slips.lines)
export type SlipLine = { item: string; qty: number; unit: string; note: string; material_code?: string; available?: number };


export function dayData(kh: Kh, date: string) {
  if (!kh.sch) return { rows: [] as DayRow[], work: [] as (DayRow & { r: NonNullable<DayRow['r']> })[], idle: [] as string[] };
  const rows = dayPlan(kh.sch, kh.cal, kh.machines, date);
  const work = rows.filter((x): x is DayRow & { r: NonNullable<DayRow['r']> } => Boolean(x.r));
  const idle = kh.machines.filter((m) => !work.some((x) => x.machine.code === m.code)).map((m) => m.code);
  return { rows, work, idle };
}

// Lưu ý thêm cho người phát lệnh (không chặn phát). Các kiểm tra bắt buộc do database tính: app.kh_day_preview.
// Người có mặt trên một khối trong ngày (khởi động, thay bobin, đứng máy trộn / đóng gói); c = kiêm nhiệm tạm
export function dayPeople(kh: Kh, sl: Slot, date: string) {
  if (!kh.sch) return [] as { p: string; c: boolean }[];
  const DAY = kh.sch.S * kh.cal.SPD, di = dayIndex(kh.cal, date), d0 = di * DAY, d1 = d0 + DAY;
  const out = new Map<string, boolean>();
  for (const a of sl.attend ?? []) if (a.t > d0 && a.f < d1) out.set(a.p, (out.get(a.p) ?? false) || Boolean(a.c));
  if (!out.size && sl.operator) out.set(sl.operator, false);
  return [...out.entries()].map(([p, c]) => ({ p, c }));
}

export function infoChecks(kh: Kh, date: string): Check[] {
  const { work } = dayData(kh, date);
  const all = work.flatMap((x) => dayPeople(kh, x.r.sl, date));
  const people = [...new Set(all.map((x) => x.p))];
  const covers = [...new Set(all.filter((x) => x.c).map((x) => x.p))];
  const P = peopleOf(kh.cfg);
  const off = P.absences.filter((a) => a.from <= date && date <= a.to).map((a) => `${a.code}${a.part === 'FULL' ? '' : a.part === 'AM' ? ' (nửa đầu ca)' : ' (nửa sau ca)'}`);
  const changes = work.filter((x) => x.r.su > 0.5).length;
  return [
    { ok: true, info: true, t: 'Người có mặt tại máy', d: `${people.join(', ') || '—'}${covers.length ? ` · kiêm nhiệm tạm: ${covers.join(', ')}` : ''}${off.length ? ` · vắng: ${off.join(', ')}` : ''}` },
    { ok: true, info: true, t: `${changes} lần đổi mã trong ngày cần mẫu đầu mã`, d: 'TP Kỹ thuật/QA, QC nhận thông báo giờ đổi mã ở màn hình Ghi nhận ca' },
  ];
}

export const bobbins = (op: keyof typeof BOBBIN, m: number) => Math.max(1, Math.round(m / BOBBIN[op]));
export { UNIT };
