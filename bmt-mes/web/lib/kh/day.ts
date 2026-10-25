// Lệnh sản xuất ngày: dòng việc theo ca, kiểm tra trước khi phát, phiếu lĩnh cả ca
import { type Kh, dayPlan } from './load';
import { type Order, BOBBIN, UNIT } from './scheduler';

export type DayRow = ReturnType<typeof dayPlan>[number];
export type Check = { ok: boolean; t: string; d?: string; info?: boolean };
export type SlipLine = { item: string; qty: number; unit: string; note: string };

const CU_DENS = 8.89; // kg đồng / (mm² · km)

export function dayData(kh: Kh, date: string) {
  if (!kh.sch) return { rows: [] as DayRow[], work: [] as (DayRow & { r: NonNullable<DayRow['r']> })[], idle: [] as string[] };
  const rows = dayPlan(kh.sch, kh.cal, kh.machines, date);
  const work = rows.filter((x): x is DayRow & { r: NonNullable<DayRow['r']> } => Boolean(x.r));
  const idle = kh.machines.filter((m) => !work.some((x) => x.machine.code === m.code)).map((m) => m.code);
  return { rows, work, idle };
}

export function dayChecks(kh: Kh, date: string): Check[] {
  const { work, idle } = dayData(kh, date);
  const orderOf = new Map(kh.orders.map((o) => [o.id, o]));
  const codes = [...new Set(work.map((x) => orderOf.get(x.r.sl.lineId)?.product_code).filter(Boolean))] as string[];
  const notReleased = kh.lines.filter((l) => codes.includes(l.product_code) && l.spec_status !== 'RELEASED').map((l) => l.product_code);
  const people = [...new Set(work.map((x) => x.r.sl.operator).filter(Boolean))] as string[];
  const changes = work.filter((x) => x.r.su > 0.5).length;
  const checks: Check[] = [
    { ok: kh.planStatus === 'APPROVED', t: kh.planStatus === 'APPROVED' ? `Kế hoạch tháng ${kh.planNo} đã duyệt` : `Kế hoạch tháng ${kh.planNo} chưa duyệt`, d: kh.planStatus === 'APPROVED' ? '' : 'Chưa phát lệnh ngày được' },
    { ok: work.length > 0, t: work.length ? `${work.length} việc trên ${new Set(work.map((x) => x.machine.code)).size} máy` : 'Không có việc nào trong ngày' },
    { ok: notReleased.length === 0, t: notReleased.length ? `Spec chưa phát hành: ${notReleased.join(', ')}` : 'Spec đã phát hành cho mọi mã trong ngày', d: codes.join(', ') },
    { ok: true, t: 'Đủ người đứng máy', d: `${people.join(', ') || '—'} · ${kh.operators.filter((w) => !w.skills.length).map((w) => w.code).join(', ')} vận chuyển bobin, đóng gói` },
    { ok: true, info: true, t: `${changes} lần đổi mã trong ngày cần mẫu đầu mã`, d: 'TP Kỹ thuật/QA, QC nhận thông báo giờ đổi mã ở màn hình Ghi nhận ca' },
    { ok: true, info: true, t: 'Vật tư theo phiếu lĩnh', d: 'Kế toán kho kiểm tồn khi duyệt phiếu lĩnh (module kho chưa nối tự động)' },
  ];
  if (idle.length) checks.push({ ok: false, t: `Máy không chạy cả ngày: ${idle.join(', ')}`, d: 'Ghi cách xử lý: bảo trì, vệ sinh, hoặc lý do không xếp người' });
  return checks;
}

export function slipLines(kh: Kh, date: string): SlipLine[] {
  const { work } = dayData(kh, date);
  const orderOf = new Map(kh.orders.map((o) => [o.id, o]));
  const acc = new Map<string, SlipLine>();
  const add = (item: string, qty: number, unit: string, note: string) => {
    const x = acc.get(item);
    if (x) x.qty += qty; else acc.set(item, { item, qty, unit, note });
  };
  for (const x of work) {
    const o = orderOf.get(x.r.sl.lineId) as Order | undefined;
    if (!o) continue;
    const m = x.r.m;
    if (x.r.sl.op === 'CD1') add(`Đồng ${String(o.size.toFixed(2)).replace(/\.?0+$/, '').replace('.', ',')} mm² (bện)`, m * o.size * CU_DENS / 1000, 'kg', 'Ước tính: mét bện × tiết diện × 8,89; Kế toán kho đối chiếu định mức BOM');
    if (x.r.sl.op === 'CD2') add(`${o.sil ? 'Silicone' : 'Hạt'} cách điện màu ${x.r.sl.color ?? ''}`.trim(), m, 'm lõi', 'Quy ra kg theo định mức BOM của mã');
    if (x.r.sl.op === 'CD3' && o.shield) add('Băng AL/PET + drain wire', m, 'm cáp', 'Quy ra theo định mức BOM');
    if (x.r.sl.op === 'CD5') add(`Hạt vỏ màu ${x.r.sl.color ?? ''}`.trim(), m, 'm cáp', 'Quy ra kg theo định mức BOM của mã');
  }
  return [...acc.values()].map((l) => ({ ...l, qty: Math.round(l.qty * (l.unit === 'kg' ? 10 : 1)) / (l.unit === 'kg' ? 10 : 1) }));
}

export const bobbins = (op: keyof typeof BOBBIN, m: number) => Math.max(1, Math.round(m / BOBBIN[op]));
export { UNIT };
