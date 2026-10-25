import type { Person, Stage } from '@/components/stage-bar';

export type Approval = {
  id: string; doc_type: string; doc_type_name: string; doc_id: string; doc_no: string; summary: string | null; status: string;
  current_seq: number | null; current_level: string | null; current_role: string | null; current_role_name: string | null;
  current_approvers: Person[]; submitted_by: string; submitted_by_name: string | null; submitted_at: string; finished_at: string | null;
  step_started_at: string; step_due_at: string | null; overdue: boolean; step_index: number; step_total: number;
  my_turn: boolean; i_submitted: boolean; i_acted: boolean; doc_link: string | null;
  steps: Stage[] | null;
  history: { seq: number; action: 'APPROVE' | 'REJECT' | 'COMMENT'; comment: string | null; at: string; actor: string | null; label: string | null }[] | null;
};

// Tên giai đoạn đang hiện ở danh sách: bước đang chờ, hoặc kết quả cuối
export function stageLabel(a: Approval): string {
  if (a.status === 'APPROVED') return 'Hoàn thành';
  if (a.status === 'REJECTED') return `Bị trả lại ở bước ${a.current_level ?? ''}`;
  if (a.status === 'CANCELLED') return 'Đã hủy';
  return `${a.current_level ?? ''}${a.current_role_name ? ' · ' + a.current_role_name : ''}`;
}

// Vị trí hiển thị kiểu Fastcon [n/N], tính cả giai đoạn "Lập phiếu"
export const stagePos = (a: Approval) => ({
  index: a.status === 'APPROVED' ? a.step_total + 1 : a.step_index + 1,
  total: a.step_total + 1,
});
