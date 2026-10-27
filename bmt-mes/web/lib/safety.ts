// Tồn dự phòng: trạng thái phiếu điều chỉnh mức (TP Mua lập → Giám đốc duyệt)
export const SS_STATUS: Record<string, [string, 'ok' | 'warn' | 'info' | 'mute']> = {
  DRAFT: ['Nháp', 'warn'], PENDING_APPROVAL: ['Chờ Giám đốc duyệt', 'info'], APPROVED: ['Đã duyệt, đã áp', 'ok'], CANCELLED: ['Đã hủy', 'mute'],
};
