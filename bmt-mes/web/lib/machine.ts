import type { Tone } from './format';

// Danh mục hiển thị của module Quản lý máy
export const M_STATUS: Record<string, [string, Tone]> = {
  RUN: ['Đang chạy', 'ok'], IDLE: ['Chờ việc', 'mute'], STOP: ['Dừng', 'warn'],
  MAINT: ['Bảo dưỡng', 'info'], DOWN: ['Hỏng', 'bad'], OFF: ['Ngừng dùng', 'mute'],
};
export const PLAN_STATE: Record<string, [string, Tone]> = {
  OK: ['Bình thường', 'ok'], SOON: ['Sắp đến hạn', 'warn'], DUE: ['Đến hạn', 'warn'], OVERDUE: ['Quá hạn', 'bad'],
};
export const WO_STATUS: Record<string, [string, Tone]> = {
  OPEN: ['Mới', 'info'], IN_PROGRESS: ['Đang làm', 'warn'], DONE: ['Hoàn thành', 'ok'], CANCELLED: ['Đã hủy', 'mute'],
};
export const SPEED_STATUS: Record<string, [string, Tone]> = {
  PENDING: ['Chờ duyệt', 'warn'], APPROVED: ['Đã duyệt', 'ok'], OBSOLETE: ['Hết hiệu lực', 'mute'],
};
export const SOURCE: Record<string, [string, Tone]> = { NSX: ['Nhà SX', 'ok'], BMT: ['Hồ sơ BMT', 'info'], GD: ['Giả định', 'warn'] };

export const WO_TYPE: Record<string, string> = { PM: 'Bảo dưỡng', CM: 'Sửa chữa' };
export const PLAN_KIND: Record<string, string> = {
  INSPECT: 'Kiểm tra', LUBE: 'Bôi trơn', CLEAN: 'Vệ sinh', REPLACE: 'Thay thế', CALIB: 'Hiệu chuẩn', OTHER: 'Khác',
};
export const LEVEL: Record<string, string> = { MINOR: 'Bảo dưỡng nhỏ', MAJOR: 'Bảo dưỡng lớn' };
export const COMP_KIND: Record<string, string> = {
  SENSOR: 'Cảm biến', MOTOR: 'Động cơ', DRIVE: 'Biến tần', GEARBOX: 'Hộp số', GEAR: 'Bánh răng', BEARING: 'Ổ bi',
  FITTING: 'Cút, khớp nối', CONTROL: 'Điều khiển', SPARE: 'Phụ tùng', OTHER: 'Khác',
};
export const OPR_ROLE: Record<string, string> = { MAIN: 'Đứng chính', LEARNING: 'Đang học' };
export const DOC_KIND: Record<string, string> = {
  SOP: 'Hướng dẫn vận hành', CHECKLIST: 'Checklist', CATALOG: 'Catalog', DRAWING: 'Bản vẽ', MANUAL: 'Sổ tay bảo dưỡng', OTHER: 'Khác',
};
export const ASSIGNEE: Record<string, string> = {
  KT_TP: 'TP Kỹ thuật/QA', SX_TP: 'Quản lý SX', 'KT_TP+SX_TP': 'TP Kỹ thuật/QA + Quản lý SX', VAN_HANH: 'NV vận hành',
};
export const SPEC_GROUPS = ['Chung', 'Điện', 'Điều khiển', 'Cảm biến', 'Cơ khí & truyền động', 'Vận hành', 'Đấu nối'];
export const STATUS_ORDER = ['RUN', 'IDLE', 'STOP', 'MAINT', 'DOWN', 'OFF'];

type PlanLike = {
  every_days: number | null; every_hours: number | null; every_km: number | null;
  used_days: number | null; used_hours: number | null; used_km: number | null;
  days_left: number | null; state: string; trigger: string | null;
};

const vi = (n: number, d = 0) => n.toLocaleString('vi-VN', { maximumFractionDigits: d });

// "14 ngày hoặc 300 giờ chạy"
export function cycleText(p: Pick<PlanLike, 'every_days' | 'every_hours' | 'every_km'>): string {
  const out: string[] = [];
  if (p.every_days) out.push(`${vi(p.every_days)} ngày`);
  if (p.every_hours) out.push(`${vi(Number(p.every_hours))} giờ chạy`);
  if (p.every_km) out.push(`${vi(Number(p.every_km))} km`);
  return out.join(' hoặc ');
}

// Phần chu kỳ đã dùng (0..1+) theo điều kiện gần đến hạn nhất
export function usedFraction(p: PlanLike): number {
  const f: number[] = [];
  if (p.every_days) f.push(Number(p.used_days ?? 0) / p.every_days);
  if (p.every_hours) f.push(Number(p.used_hours ?? 0) / Number(p.every_hours));
  if (p.every_km) f.push(Number(p.used_km ?? 0) / Number(p.every_km));
  return f.length ? Math.max(...f) : 0;
}

// "Quá 3 ngày" / "Còn 38 giờ chạy" / "Còn khoảng 5 ngày"
export function remainText(p: PlanLike): string {
  if (p.state === 'OVERDUE') {
    if (p.every_days && Number(p.used_days) > p.every_days) return `Quá ${vi(Number(p.used_days) - p.every_days)} ngày`;
    if (p.every_hours && Number(p.used_hours) > Number(p.every_hours)) return `Quá ${vi(Number(p.used_hours) - Number(p.every_hours), 1)} giờ chạy`;
    if (p.every_km && Number(p.used_km) > Number(p.every_km)) return `Quá ${vi(Number(p.used_km) - Number(p.every_km), 1)} km`;
    return 'Quá hạn';
  }
  if (p.trigger === 'HOURS' && p.every_hours) return `Còn ${vi(Number(p.every_hours) - Number(p.used_hours ?? 0), 1)} giờ chạy`;
  if (p.trigger === 'KM' && p.every_km) return `Còn ${vi(Number(p.every_km) - Number(p.used_km ?? 0), 1)} km`;
  const d = Number(p.days_left ?? 0);
  if (d < 1) return 'Đến hạn hôm nay';
  return `Còn ${vi(Math.floor(d))} ngày`;
}

export function usedText(p: PlanLike): string {
  const out: string[] = [];
  if (p.every_days) out.push(`${vi(Number(p.used_days ?? 0))}/${vi(p.every_days)} ngày`);
  if (p.every_hours) out.push(`${vi(Number(p.used_hours ?? 0), 1)}/${vi(Number(p.every_hours))} giờ`);
  if (p.every_km) out.push(`${vi(Number(p.used_km ?? 0), 1)}/${vi(Number(p.every_km))} km`);
  return out.join(' · ');
}

// Ô nhập ngày giờ (giờ Việt Nam) → ISO có múi giờ
export function vnDateTime(v: FormDataEntryValue | null): string | null {
  const s = String(v ?? '').trim();
  if (!s) return null;
  return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(s) ? `${s}:00+07:00` : null;
}

// Ngày hôm nay theo giờ Việt Nam (YYYY-MM-DD)
export function vnToday(offsetDays = 0): string {
  const d = new Date(Date.now() + 7 * 3_600_000 + offsetDays * 86_400_000);
  return d.toISOString().slice(0, 10);
}

export function hhmm(iso: string): string {
  return new Date(iso).toLocaleTimeString('vi-VN', { timeZone: 'Asia/Ho_Chi_Minh', hour: '2-digit', minute: '2-digit', hour12: false });
}
