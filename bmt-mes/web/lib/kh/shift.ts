// Ghi nhận ca: kế hoạch của một máy trong một ca, mẫu đầu ca/đầu mã
import type { Kh } from './load';
import { dayIndex, shiftPlan } from './scheduler';

export const DT_REASONS: Record<string, string> = {
  DT_BREAKDOWN: 'Hỏng máy', DT_CLEAN: 'Vệ sinh / purge', DT_COLOR: 'Đổi màu', DT_DIE: 'Thay khuôn', DT_MATERIAL: 'Chờ NVL', DT_POWER: 'Mất điện', DT_QC: 'Chờ QC',
};
export const SCRAP_REASONS: Record<string, string> = {
  SC_STARTUP: 'Phế khởi động', SC_BREAK: 'Đứt dây', SC_OD: 'Sai OD / chiều dày', SC_COLOR: 'Sai màu / đổi màu', SC_PRINT: 'Lỗi in',
  SC_SPARK: 'Hỏng cao áp / spark', SC_TAIL: 'Đuôi bobin', SC_PURGE: 'Purge / vệ sinh máy',
};

export type PlanLine = { key: string; plan_line_id: string; label: string; product_code: string; op: string; color: string | null; planned_m: number; newCode: boolean };
export type Sample = { kind: string; product_code: string; status: 'PENDING' | 'OK' | 'NG'; by_name?: string; at?: string };

// Việc kế hoạch của máy trong ca (theo lịch đang dùng)
export function shiftLines(kh: Kh, date: string, machine: string, shift: string): PlanLine[] {
  if (!kh.sch) return [];
  const di = dayIndex(kh.cal, date);
  const j = kh.cal.shifts.findIndex((s) => s.code === shift);
  if (di < 0 || kh.cal.days[di] !== date || j < 0) return [];
  const s = di * kh.cal.SPD + j;
  const orderOf = new Map(kh.orders.map((o) => [o.id, o]));
  return shiftPlan(kh.sch.byMachine.get(machine) ?? [], s, kh.cal.S).map((r) => {
    const o = orderOf.get(r.sl.lineId);
    return {
      key: r.sl.key, plan_line_id: r.sl.lineId, label: o?.label ?? '', product_code: o?.product_code ?? '', op: r.sl.op, color: r.sl.color,
      planned_m: Math.round(r.m), newCode: r.sl.runStart > s * kh.cal.S + 1 && r.su > 0.5,
    };
  });
}

export function sampleTemplate(lines: PlanLine[]): Sample[] {
  // Đầu ca luôn lấy mẫu; giữa ca chỉ lấy mẫu khi đổi mã / đổi màu (có phút đổi máy)
  return lines.flatMap((l, i): Sample[] => (i === 0 || l.newCode ? [{
    kind: i === 0 ? 'Mẫu đầu ca' : 'Mẫu đầu mã',
    product_code: `${l.product_code}${l.color ? ' · ' + l.color : ''}`, status: 'PENDING',
  }] : []));
}

export const minutesOf = (from: string, to: string) => {
  if (!/^\d{1,2}:\d{2}$/.test(from) || !/^\d{1,2}:\d{2}$/.test(to)) return 0;
  const [a, b] = from.split(':').map(Number), [c, d] = to.split(':').map(Number);
  return (((c * 60 + d) - (a * 60 + b)) + 1440) % 1440;
};
