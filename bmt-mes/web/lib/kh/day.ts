// Lệnh sản xuất ngày: dòng việc theo ca, kiểm tra trước khi phát, phiếu lĩnh cả ca
import { type Kh, dayPlan } from './load';
import { BOBBIN, UNIT } from './scheduler';

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
export function infoChecks(kh: Kh, date: string): Check[] {
  const { work } = dayData(kh, date);
  const people = [...new Set(work.map((x) => x.r.sl.operator).filter(Boolean))] as string[];
  const changes = work.filter((x) => x.r.su > 0.5).length;
  return [
    { ok: true, info: true, t: 'Người đứng máy', d: `${people.join(', ') || '—'} · ${kh.operators.filter((w) => !w.skills.length).map((w) => w.code).join(', ')} vận chuyển bobin, đóng gói` },
    { ok: true, info: true, t: `${changes} lần đổi mã trong ngày cần mẫu đầu mã`, d: 'TP Kỹ thuật/QA, QC nhận thông báo giờ đổi mã ở màn hình Ghi nhận ca' },
  ];
}

export const bobbins = (op: keyof typeof BOBBIN, m: number) => Math.max(1, Math.round(m / BOBBIN[op]));
export { UNIT };
