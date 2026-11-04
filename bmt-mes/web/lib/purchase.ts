import type { Tone } from './format';

// Trạng thái hợp đồng / phiếu mua (PO): NV mua gom từ đơn mua tổng → TP Mua → Giám đốc (migration 9500)
export const PO_STATUS: Record<string, [string, Tone]> = {
  DRAFT: ['Nháp, chờ NV mua gửi', 'warn'], PENDING_APPROVAL: ['Đang duyệt', 'info'], APPROVED: ['Đã duyệt, chờ hàng', 'ok'],
  SENT: ['Đã gửi NCC', 'info'], PARTIAL_RECEIVED: ['Nhận một phần', 'warn'], RECEIVED: ['Đã nhận đủ', 'ok'], CLOSED: ['Đã đóng', 'mute'],
  CANCELLED: ['Đã hủy', 'mute'],
};

export type Po = {
  id: string; po_no: string; status: string; source: string; source_label: string; supplier_id: string | null; supplier_name: string | null;
  supplier_tax_code: string | null; order_date: string | null; expected_date: string | null; payment_terms: string | null; note: string | null;
  is_import: boolean; cancel_reason: string | null; plan_id: string | null; plan_no: string | null; pr_id: string | null; pr_no: string | null;
  adjustment_id: string | null; adj_no: string | null; mrp_run_id: string | null; line_count: number; amount: number | null; missing_price: number;
  has_receipt: boolean; created_at: string; created_by: string | null; created_by_name: string | null; request_id: string | null;
  kind: 'TONG' | 'HD'; parent_id: string | null; parent_no: string | null; due_date: string | null; all_submitted_at: string | null;
  done_at: string | null; contract_count: number; contract_approved: number; contract_draft: number; lines_ready: number; overdue: boolean;
};
export type PoLine = {
  id: string; po_id: string; line_no: number; material_id: string; material_code: string; material_name: string; uom: string;
  supplier_item_code: string | null; qty: number; received_qty: number; expected_date: string | null; note: string | null;
  pr_line_id: string | null; mrp_line_id: string | null; mrp_qty: number | null; unit_price: number | null; amount: number | null; priced: boolean;
  need_qty: number | null; available: number | null; incoming: number | null; safety_qty: number | null; moq: number | null;
  pack_multiple: number | null; lead_time_days: number | null;
  supplier_id: string | null; supplier_name: string | null; payment_terms: string | null; ready: boolean;
};

// Đơn mua hàng tổng: NV mua chốt từng dòng, gom hợp đồng theo NCC, gửi đủ trong 5 ngày làm việc
export function tongState(p: Po): [string, Tone] {
  if (p.status === 'CANCELLED') return ['Đã hủy', 'mute'];
  if (p.done_at) return ['Hoàn tất', 'ok'];
  if (p.all_submitted_at) return ['Đã gửi đủ hợp đồng, chờ duyệt', 'info'];
  if (p.overdue) return ['Quá hạn gửi hợp đồng', 'bad'];
  return ['NV mua đang chốt', 'warn'];
}

// NV mua / TP Mua: sửa đơn nháp, lập đơn từ đề xuất, chia NCC (database kiểm lại)
export const isBuyer = (roles: string[]) => roles.includes('MUA_NV') || roles.includes('MUA_TP') || roles.includes('ADMIN');
