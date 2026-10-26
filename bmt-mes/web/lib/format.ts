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
//   "1234.5" / "1.5" / "0.254" → số thập phân (không phải nhóm nghìn: thiếu nhóm 3 chữ số hoặc bắt đầu bằng 0)
//   "1,234.5" (kiểu Anh, dấu phẩy đứng trước dấu chấm) → 1234.5 · "1,234,567" → 1234567
export function parseNum(raw: FormDataEntryValue | null): number | null {
  if (raw === null) return null;
  const s = String(raw).trim().replace(/\s/g, '');
  if (s === '') return null;
  const comma = s.lastIndexOf(','), dot = s.lastIndexOf('.');
  let norm = s;
  if (comma >= 0 && dot > comma) norm = s.replace(/,/g, '');
  else if (comma >= 0) norm = /,.*,/.test(s) ? s.replace(/,/g, '') : s.replace(/\./g, '').replace(',', '.');
  else if (/^-?[1-9]\d{0,2}(\.\d{3})+$/.test(s)) norm = s.replace(/\./g, '');
  const n = Number(norm);
  return Number.isFinite(n) ? n : NaN;
}

// Giá trị điền sẵn vào ô nhập số: đủ chữ số (không làm tròn), dấu phẩy thập phân, không dấu nghìn → parseNum đọc lại đúng
export function numIn(v: number | string | null | undefined): string {
  if (v === null || v === undefined || v === '') return '';
  const n = typeof v === 'string' ? Number(v) : v;
  return Number.isFinite(n) ? String(n).replace('.', ',') : String(v);
}

export const SPEC_STATUS: Record<string, [string, Tone]> = {
  DRAFT: ['Nháp', 'mute'],
  PILOT_PENDING: ['Chờ pilot', 'warn'],
  PILOT: ['Pilot', 'warn'],
  PENDING_APPROVAL: ['Đang duyệt', 'info'],
  RELEASED: ['Đã phát hành', 'ok'],
  OBSOLETE: ['Ngưng dùng', 'mute'],
};

export const DOC_STATUS: Record<string, [string, Tone]> = {
  DRAFT: ['Nháp', 'mute'],
  PENDING_APPROVAL: ['Đang xử lý', 'info'],
  PENDING: ['Đang xử lý', 'info'],
  APPROVED: ['Hoàn thành', 'ok'],
  REJECTED: ['Bị trả lại', 'bad'],
  CANCELLED: ['Đã hủy', 'mute'],
  CLOSED: ['Đã đóng', 'mute'],
  RELEASED: ['Đã phát hành', 'ok'],
  PARTIAL_PO: ['Đã lên PO một phần', 'warn'],
};

// "Quá hạn 1 ngày" / "Quá hạn 5 giờ"
export function overdueText(due: string | null | undefined): string | null {
  if (!due) return null;
  const ms = Date.now() - new Date(due).getTime();
  if (ms <= 0) return null;
  const h = Math.floor(ms / 3_600_000);
  return h >= 24 ? `Quá hạn ${Math.floor(h / 24)} ngày` : `Quá hạn ${Math.max(h, 1)} giờ`;
}

export type Tone = 'ok' | 'warn' | 'bad' | 'info' | 'mute' | 'cu';

export const ROLE_NAMES: Record<string, string> = {
  BGD: 'Ban giám đốc', KD_NV: 'NV kinh doanh', KD_TP: 'TP kinh doanh', KT_NV: 'NV kỹ thuật', KT_TP: 'TP Kỹ thuật/QA',
  QC: 'Kiểm tra chất lượng', KHO_NV: 'NV kho', THU_KHO: 'Thủ kho', MUA_NV: 'NV mua hàng', MUA_TP: 'TP mua hàng',
  KT_KHO: 'Kế toán kho', KT_GT: 'Kế toán giá thành', KTT: 'Kế toán trưởng', SX_TP: 'Quản lý sản xuất', SX_KH: 'Kế hoạch SX',
  TO_TRUONG: 'Tổ trưởng ca', VAN_HANH: 'Vận hành máy', ADMIN: 'Quản trị hệ thống',
};
