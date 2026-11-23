// Định dạng số và ngày theo kiểu Việt Nam (1.234,56; dd/mm/yyyy)
export function nf(v: number | string | null | undefined, digits = 0): string {
  if (v === null || v === undefined || v === '') return '—';
  const n = typeof v === 'string' ? Number(v) : v;
  if (!Number.isFinite(n)) return '—';
  return n.toLocaleString('vi-VN', { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

// Quy định MES (anh Bình 19/11/2026): mọi ngày hiển thị dd/mm/yyyy; có giờ thì "dd/mm/yyyy HH:mm" (giờ Việt Nam).
const VN_PARTS = new Intl.DateTimeFormat('en-GB', {
  timeZone: 'Asia/Ho_Chi_Minh', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
});
/** Ngày "YYYY-MM-DD" (không giờ) → "dd/mm/yyyy", không đổi múi giờ. Giá trị khác trả nguyên. */
export function dmy(v: string | null | undefined, empty = '—'): string {
  if (!v) return empty;
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(v);
  return m ? `${m[3]}/${m[2]}/${m[1]}` : v;
}
/** "dd/mm/yyyy" (cho phép thiếu số 0, năm 2 chữ số, dấu - . hoặc liền 8 số) → ISO; '' khi trống; null khi sai */
export function parseVnDate(raw: string): string | null {
  const s = raw.trim();
  if (!s) return '';
  let m = /^(\d{1,2})[/.\-\s](\d{1,2})[/.\-\s](\d{2}|\d{4})$/.exec(s) ?? /^(\d{2})(\d{2})(\d{4})$/.exec(s);
  if (!m) {
    const iso = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
    if (!iso) return null;
    m = [s, iso[3], iso[2], iso[1]] as unknown as RegExpExecArray;
  }
  const d = Number(m[1]), mo = Number(m[2]);
  const y = m[3].length === 2 ? 2000 + Number(m[3]) : Number(m[3]);
  const dt = new Date(Date.UTC(y, mo - 1, d));
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== mo - 1 || dt.getUTCDate() !== d) return null;
  return `${y}-${String(mo).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
}

export function df(v: string | null | undefined, withTime = false): string {
  if (!v) return '—';
  if (!withTime && /^\d{4}-\d{2}-\d{2}$/.test(v)) return dmy(v);
  const d = new Date(v);
  if (Number.isNaN(d.getTime())) return v;
  const p = Object.fromEntries(VN_PARTS.formatToParts(d).map((x) => [x.type, x.value]));
  const date = `${p.day}/${p.month}/${p.year}`;
  return withTime ? `${date} ${p.hour}:${p.minute}` : date;
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
  TO_TRUONG: 'Tổ trưởng ca', VAN_HANH: 'Vận hành máy', HCNS: 'Hành chính – Nhân sự', ADMIN: 'Quản trị hệ thống',
};
