// Mục Đề xuất chung (migration 20261026010600): loại, nhóm, trạng thái, kiểu dữ liệu dùng chung cho các trang
import type { Tone } from '@/lib/format';

export const REQ_GROUPS: [string, string][] = [
  ['NS', 'Nhân sự'], ['MUA', 'Mua sắm'], ['TC', 'Tài chính'], ['KT', 'Kỹ thuật'], ['GY', 'Góp ý'], ['KHAC', 'Khác'],
];
export const REQ_GROUP_NAME = Object.fromEntries(REQ_GROUPS) as Record<string, string>;

export const REQ_STATUS: Record<string, [string, Tone]> = {
  DRAFT: ['Nháp', 'mute'], PENDING_APPROVAL: ['Chờ duyệt', 'info'], RETURNED: ['Bị trả lại', 'warn'],
  APPROVED: ['Đã duyệt, chờ xử lý', 'info'], DONE: ['Hoàn tất', 'ok'], REFUSED: ['Bị từ chối', 'bad'], CANCELLED: ['Đã hủy', 'mute'],
};

// Bộ phận (core.departments) – nơi nhận của loại Việc khác
export const DEPTS: [string, string][] = [
  ['BGD', 'Ban giám đốc'], ['SX', 'Sản xuất'], ['KHO', 'Kho'], ['KT', 'Kỹ thuật/QA'], ['MUA', 'Mua hàng'],
  ['KTOAN', 'Kế toán'], ['KD', 'Kinh doanh'], ['HCNS', 'Hành chính – Nhân sự'], ['IT', 'Quản trị hệ thống'],
];

export const SHIFTS = ['Ca 1', 'Ca 2', 'Ca 3', 'Ca hành chính'];

export type ReqType = {
  code: string; grp: string; name: string; hint: string | null; form: string; gd_rule: string; gd_threshold: number | null;
  expert_role: string | null; handler_roles: string[]; action: string; private: boolean; sla_hours: number; allow_anonymous: boolean; sort: number;
};

export type ReqItem = { code?: string; name?: string; spec?: string; qty?: number; unit?: string; price?: number };

export type Req = {
  id: string; req_no: string; type_code: string; type_name: string; grp: string; form: string; private: boolean; action: string;
  title: string; content: string | null; reason: string | null; urgent: boolean;
  requester_id: string | null; operator_code: string | null; requester_name: string; dept: string | null; dept_name: string | null;
  date_from: string | null; date_to: string | null; part: string; time_from: string | null; time_to: string | null;
  days: number | null; amount: number | null; paid: boolean | null; machine_id: string | null; machine_code: string | null;
  target_dept: string | null; target_dept_name: string | null; items: ReqItem[]; data: Record<string, string | undefined>; anonymous: boolean;
  status: string; status_label: string; created_by: string | null; creator_name: string; created_at: string;
  handled_by: string | null; handler_name: string | null; handled_at: string | null; handle_note: string | null;
  pr_id: string | null; pr_no: string | null; maint_wo_id: string | null; maint_wo_no: string | null;
  approval_id: string | null; current_level: string | null; current_approvers: { id: string; name: string }[] | null;
  step_due_at: string | null; overdue: boolean | null; steps: unknown; history: unknown; my_turn: boolean; can_handle: boolean; mine: boolean;
};

// Người duyệt dự kiến theo cài đặt loại (hiện ở form lập; MES gán người cụ thể lúc gửi)
export function approvalText(t: ReqType): string {
  const steps = ['Trưởng bộ phận của bạn'];
  if (t.form === 'OTHER') steps.push('trưởng bộ phận nơi nhận');
  else if (t.expert_role === 'KTT') steps.push('Kế toán trưởng');
  if (t.gd_rule === 'ALWAYS') steps.push('Giám đốc');
  else if (t.gd_rule === 'DAYS') steps.push(`Giám đốc khi trên ${t.gd_threshold} ngày`);
  else if (t.gd_rule === 'AMOUNT') steps.push(`Giám đốc khi từ ${Number(t.gd_threshold ?? 0).toLocaleString('vi-VN')} đ`);
  const after: Record<string, string> = {
    ABSENCE: 'Duyệt xong MES ghi lịch nghỉ (công nhân: lịch vắng, TP SX xếp lại lịch).',
    NOTICE: 'Duyệt xong MES báo bộ phận liên quan.',
    PR: 'Duyệt xong Phòng Mua lập đề xuất mua.',
    REPAIR: 'Duyệt xong TP KT/QA mở phiếu sửa chữa.',
    HANDLE: t.handler_roles.length ? 'Duyệt xong người xử lý bấm "Đã xử lý".' : '',
  };
  return `Người duyệt: ${steps.join(' → ')}; hạn ${t.sla_hours < 24 ? `${t.sla_hours} giờ` : '1 ngày'} mỗi bước. ${after[t.action] ?? ''}`.trim();
}

export const isLeave = (form: string) => ['LEAVE', 'MATERNITY', 'TRIP'].includes(form);
export const fmtDays = (n: number | null) => (n === null ? '' : `${String(n).replace('.', ',').replace(/,0$/, '')} ngày`);
