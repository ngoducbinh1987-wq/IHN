// Định dạng số và ngày theo kiểu Việt Nam (1.234,56; dd/mm/yyyy)
export function nf(v: number | string | null | undefined, digits = 0): string {
  if (v === null || v === undefined || v === '') return '—';
  const n = typeof v === 'string' ? Number(v) : v;
  if (!Number.isFinite(n)) return '—';
  return n.toLocaleString('vi-VN', { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

export function df(v: string | null | undefined, withTime = false): string {
  if (!v) return '—';
  const d = new Date(v);
  return withTime
    ? d.toLocaleString('vi-VN', { timeZone: 'Asia/Ho_Chi_Minh', dateStyle: 'short', timeStyle: 'short' })
    : d.toLocaleDateString('vi-VN', { timeZone: 'Asia/Ho_Chi_Minh' });
}

// Đọc số người dùng gõ theo thói quen Việt Nam:
//   "1.234,5" → 1234.5 · "3.500" / "268.000" → 3500 / 268000 (dấu chấm phân cách nghìn)
//   "1234.5" / "1.5" / "0.75" → số thập phân (không đủ nhóm 3 chữ số sau dấu chấm)
export function parseNum(raw: FormDataEntryValue | null): number | null {
  if (raw === null) return null;
  const s = String(raw).trim().replace(/\s/g, '');
  if (s === '') return null;
  let norm = s;
  if (s.includes(',')) norm = s.replace(/\./g, '').replace(',', '.');
  else if (/^-?\d{1,3}(\.\d{3})+$/.test(s)) norm = s.replace(/\./g, '');
  const n = Number(norm);
  return Number.isFinite(n) ? n : NaN;
}

export const SPEC_STATUS: Record<string, [string, Tone]> = {
  DRAFT: ['Nháp', 'mute'],
  PILOT_PENDING: ['Chờ pilot', 'info'],
  PILOT: ['Pilot', 'info'],
  PENDING_APPROVAL: ['Chờ duyệt', 'warn'],
  RELEASED: ['Đã phát hành', 'ok'],
  OBSOLETE: ['Ngưng dùng', 'mute'],
};

export const DOC_STATUS: Record<string, [string, Tone]> = {
  DRAFT: ['Nháp', 'mute'],
  PENDING_APPROVAL: ['Chờ duyệt', 'warn'],
  PENDING: ['Chờ duyệt', 'warn'],
  APPROVED: ['Đã duyệt', 'ok'],
  REJECTED: ['Bị trả lại', 'bad'],
  CANCELLED: ['Đã hủy', 'mute'],
  CLOSED: ['Đã đóng', 'mute'],
  RELEASED: ['Đã phát hành', 'ok'],
};

export type Tone = 'ok' | 'warn' | 'bad' | 'info' | 'mute' | 'cu';

export const ROLE_NAMES: Record<string, string> = {
  BGD: 'Ban giám đốc', KD_NV: 'NV kinh doanh', KD_TP: 'TP kinh doanh', KT_NV: 'NV kỹ thuật', KT_TP: 'TP Kỹ thuật/QA',
  QC: 'Kiểm tra chất lượng', KHO_NV: 'NV kho', THU_KHO: 'Thủ kho', MUA_NV: 'NV mua hàng', MUA_TP: 'TP mua hàng',
  KT_KHO: 'Kế toán kho', KT_GT: 'Kế toán giá thành', KTT: 'Kế toán trưởng', SX_TP: 'TP sản xuất', SX_KH: 'Kế hoạch SX',
  TO_TRUONG: 'Tổ trưởng ca', VAN_HANH: 'Vận hành máy', ADMIN: 'Quản trị hệ thống',
};
