import type { Tone } from './format';

// Trạng thái đơn mua hàng (PO): MES tự sinh khi Chủ tịch chốt kế hoạch tháng → NV mua kiểm tra → TP Mua → Giám đốc
export const PO_STATUS: Record<string, [string, Tone]> = {
  DRAFT: ['Chờ NV mua kiểm tra', 'warn'], PENDING_APPROVAL: ['Đang duyệt', 'info'], APPROVED: ['Đã duyệt, chờ hàng', 'ok'],
  SENT: ['Đã gửi NCC', 'info'], PARTIAL_RECEIVED: ['Nhận một phần', 'warn'], RECEIVED: ['Đã nhận đủ', 'ok'], CLOSED: ['Đã đóng', 'mute'],
  CANCELLED: ['Đã hủy', 'mute'],
};

export type Po = {
  id: string; po_no: string; status: string; source: string; source_label: string; supplier_id: string | null; supplier_name: string | null;
  supplier_tax_code: string | null; order_date: string | null; expected_date: string | null; payment_terms: string | null; note: string | null;
  is_import: boolean; cancel_reason: string | null; plan_id: string | null; plan_no: string | null; pr_id: string | null; pr_no: string | null;
  adjustment_id: string | null; adj_no: string | null; mrp_run_id: string | null; line_count: number; amount: number | null; missing_price: number;
  has_receipt: boolean; created_at: string; created_by: string | null; created_by_name: string | null; request_id: string | null;
};
export type PoLine = {
  id: string; po_id: string; line_no: number; material_id: string; material_code: string; material_name: string; uom: string;
  supplier_item_code: string | null; qty: number; received_qty: number; expected_date: string | null; note: string | null;
  pr_line_id: string | null; mrp_line_id: string | null; mrp_qty: number | null; unit_price: number | null; amount: number | null; priced: boolean;
  need_qty: number | null; available: number | null; incoming: number | null; safety_qty: number | null; moq: number | null;
  pack_multiple: number | null; lead_time_days: number | null;
};

// NV mua / TP Mua: sửa đơn nháp, lập đơn từ đề xuất, chia NCC (database kiểm lại)
export const isBuyer = (roles: string[]) => roles.includes('MUA_NV') || roles.includes('MUA_TP') || roles.includes('ADMIN');
