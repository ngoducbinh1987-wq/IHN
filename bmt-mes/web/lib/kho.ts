import type { Tone } from './format';
import type { Me } from './session';

// Tên loại chứng từ kho
export const DOC_TYPES: Record<string, string> = {
  GR: 'Nhập mua', ISSUE_WO: 'Xuất cho sản xuất', RETURN_WO: 'Trả NVL thừa', WIP_IN: 'Nhập BTP', FG_IN: 'Nhập thành phẩm',
  SCRAP_IN: 'Nhập phế', SALE: 'Xuất bán', SCRAP_OUT: 'Bán phế', TRANSFER: 'Chuyển vị trí/kho', ADJ: 'Điều chỉnh kiểm kê',
  RETURN_SUP: 'Trả nhà cung cấp', OPENING: 'Tồn đầu kỳ', SPLIT: 'Cắt bobin', RECLASS: 'Đổi mã / hủy', CUST_RETURN: 'Hàng khách trả',
};

export const QC_STATUS: Record<string, [string, Tone]> = {
  PENDING: ['Chờ QC', 'warn'], PASSED: ['Đạt', 'ok'], QUARANTINE: ['Cách ly', 'bad'], REJECTED: ['Không nhận', 'bad'], CONSUMED: ['Hết', 'mute'],
};
export const REVIEW_STATUS: Record<string, [string, Tone]> = {
  PENDING: ['Chờ Kế toán SX', 'warn'], CONFIRMED: ['Kế toán SX đã duyệt', 'ok'], RETURNED: ['Kế toán SX trả lại', 'bad'], NA: ['Nội bộ', 'mute'],
};
export const STOCK_DOC_STATUS: Record<string, [string, Tone]> = {
  DRAFT: ['Nháp', 'mute'], PENDING_APPROVAL: ['Chờ duyệt', 'info'], APPROVED: ['Đã duyệt', 'info'], POSTED: ['Đã ghi sổ', 'ok'], CANCELLED: ['Đã hủy', 'mute'],
};
export const REQ_STATUS: Record<string, [string, Tone]> = {
  DRAFT: ['Nháp', 'mute'], PENDING_APPROVAL: ['Chờ TP Kỹ thuật/QA', 'info'], APPROVED: ['Chờ cấp', 'warn'], PARTIAL: ['Đang cấp', 'info'],
  DONE: ['Đã cấp đủ', 'ok'], CANCELLED: ['Đã hủy', 'mute'],
};
export const COUNT_STATUS: Record<string, [string, Tone]> = {
  OPEN: ['Đang đếm', 'warn'], COUNTED: ['Bị trả lại – đếm lại', 'bad'], PENDING_APPROVAL: ['Chờ Kế toán trưởng', 'info'],
  APPROVED: ['Đã duyệt', 'info'], POSTED: ['Đã đóng', 'ok'], CANCELLED: ['Đã hủy', 'mute'],
};
export const DELIVERY_STATUS: Record<string, [string, Tone]> = {
  DRAFT: ['Nháp', 'mute'], PENDING_APPROVAL: ['Chờ duyệt', 'info'], APPROVED: ['Chờ xuất', 'warn'], PICKED: ['Đã soạn', 'info'],
  SHIPPED: ['Đã xuất', 'ok'], CANCELLED: ['Đã hủy', 'mute'],
};
export const HU_STATUS: Record<string, [string, Tone]> = { ACTIVE: ['Có hàng', 'ok'], EMPTY: ['Trống', 'mute'], VOID: ['Đã hủy', 'bad'] };
export const CARRIER_STATUS: Record<string, [string, Tone]> = {
  EMPTY: ['Trống', 'ok'], IN_USE: ['Đang chứa', 'info'], DAMAGED: ['Hỏng', 'bad'], RETIRED: ['Thanh lý', 'mute'],
};
export const KIND_NAMES: Record<string, string> = { MAT: 'NVL', WIP: 'BTP', FG: 'Thành phẩm', SCRAP: 'Phế' };
export const WH_NAMES: Record<string, string> = { KNL: 'Kho nguyên liệu', KBTP: 'Kho bán thành phẩm', KTP: 'Kho thành phẩm', KPL: 'Kho phế liệu' };
export const SCRAP_CAT: Record<string, string> = { STARTUP: 'Khởi động, đổi mã', QUALITY: 'Lỗi chất lượng', LENGTH: 'Chiều dài', OTHER: 'Khác' };
export const LOC_KINDS: Record<string, string> = {
  STORE: 'Lưu kho', QC: 'Chờ kiểm', HOLD: 'Cách ly', LINE: 'Cạnh máy', SHIP: 'Chờ giao', RETURN: 'Hàng trả về', EMPTY: 'Bobin trống',
};

// Mã quét được: tem đơn vị chứa "BMT|<số>", tem vị trí "LOC|<mã>"; máy quét cầm tay gõ thẳng chuỗi rồi Enter
export function scanCode(raw: string): string {
  return raw.trim().replace(/^BMT\|/i, '').toUpperCase();
}
export function locCode(raw: string): string {
  return raw.trim().replace(/^LOC\|/i, '').toUpperCase();
}

// Người giữ kho theo Quy chuẩn: kho NVL, BTP, phế – Quản lý SX (Thủ kho); kho thành phẩm – NV5 (NV kho)
export const keeps = (me: Me, wh: 'KNL' | 'KBTP' | 'KPL' | 'KTP') =>
  me.roles.includes(wh === 'KTP' ? 'KHO_NV' : 'THU_KHO');
export const hasRole = (me: Me, ...roles: string[]) => roles.some((r) => me.roles.includes(r));

export function errText(msg: string | undefined | null): string {
  if (!msg) return 'Có lỗi xảy ra';
  if (msg.includes('row-level security') || msg.includes('permission denied')) return 'Bạn không có quyền thực hiện thao tác này';
  return msg;
}

// Gom lỗi khi tải dữ liệu của một trang: truy vấn lỗi thì trang báo rõ thay vì hiện danh sách trống / "không tìm thấy"
type QRes = { data?: unknown; error?: { message: string } | null };
export class LoadErrors {
  private list: string[] = [];
  one<T extends QRes>(r: T): T {
    if (r.error) this.list.push(errText(r.error.message));
    return r;
  }
  all<T extends readonly QRes[]>(rs: readonly [...T]): T {
    rs.forEach((r) => this.one(r));
    return rs as T;
  }
  get has(): boolean {
    return this.list.length > 0;
  }
  get text(): string | undefined {
    if (!this.list.length) return undefined;
    return `Không tải được đủ dữ liệu (${[...new Set(this.list)].join('; ')}). Số liệu bên dưới có thể thiếu: bấm Tải lại; còn lỗi thì báo Quản trị hệ thống.`;
  }
}

// Đọc hết danh sách dài: máy chủ dữ liệu (PostgREST) trả tối đa 1.000 dòng mỗi lần, nên đọc nối từng trang
// đến khi hết. `page(from, to)` phải dựng truy vấn mới mỗi lần, có sắp xếp ổn định (để các trang không trùng, không sót).
export async function fetchAll<T>(
  page: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: { message: string } | null }>,
  max = 20000,
): Promise<{ data: T[]; error: { message: string } | null; truncated: boolean }> {
  const SIZE = 1000;
  const out: T[] = [];
  while (out.length < max) {
    const { data, error } = await page(out.length, out.length + SIZE - 1);
    if (error) return { data: out, error, truncated: false };
    if (!data || data.length === 0) return { data: out, error: null, truncated: false };
    out.push(...data);
  }
  return { data: out.slice(0, max), error: null, truncated: true };
}

// Đường dẫn kèm thông báo kết quả
export const withMsg = (path: string, kind: 'ok' | 'err', msg: string) =>
  `${path}${path.includes('?') ? '&' : '?'}${kind}=${encodeURIComponent(msg)}`;
