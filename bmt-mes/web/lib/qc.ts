// Chỉ tiêu QC theo công đoạn (quy trình final 27/10/2026, mục 7). Kiểm mỗi bobin + kiểm theo tần suất do TP KT/QA chốt.
export type QcTest = { code: string; label: string; kind: 'num' | 'pf' | 'text'; unit?: string; periodic?: boolean };

const VISUAL: QcTest = { code: 'VISUAL', label: 'Bề mặt, ngoại quan', kind: 'pf' };

export const QC_TESTS: Record<string, QcTest[]> = {
  // Nguyên vật liệu nhập kho
  MAT: [
    { code: 'WIRE_DIA', label: 'Ø sợi đo', kind: 'num', unit: 'mm' },
    { code: 'DENSITY', label: 'Tỷ trọng', kind: 'num', unit: 'g/cm³' },
    VISUAL,
  ],
  MX: [VISUAL],
  // Bện
  CB: [
    { ...VISUAL, label: 'Bề mặt (sợi đứt, xù)' },
    { code: 'COND_DIA', label: 'Đường kính ruột', kind: 'num', unit: 'mm' },
    { code: 'RDC', label: 'Điện trở ruột dẫn (IEC 60228)', kind: 'num', unit: 'Ω/km', periodic: true },
    { code: 'WIRE_COUNT', label: 'Số sợi', kind: 'num', unit: 'sợi', periodic: true },
    { code: 'LAY', label: 'Bước bện', kind: 'num', unit: 'mm', periodic: true },
  ],
  // Bọc cách điện
  LB: [
    { code: 'HV', label: 'Máy thử cao áp không báo lỗi', kind: 'pf' },
    { code: 'OD', label: 'OD lõi', kind: 'num', unit: 'mm' },
    { code: 'COLOR', label: 'Màu', kind: 'pf' },
    VISUAL,
    { code: 'INS_THK', label: 'Chiều dày cách điện (mặt cắt)', kind: 'num', unit: 'mm', periodic: true },
    { code: 'CURE', label: 'Độ lưu hóa', kind: 'pf', periodic: true },
  ],
  // Xoắn + AL/PET
  BL: [
    { code: 'COLOR_ORDER', label: 'Thứ tự màu', kind: 'pf' },
    { code: 'LAY', label: 'Bước xoắn', kind: 'num', unit: 'mm' },
    { code: 'OVERLAP', label: 'Độ chồng mí băng', kind: 'pf' },
    { code: 'DRAIN', label: 'Dây drain', kind: 'pf' },
    { code: 'CONTINUITY', label: 'Thông mạch drain – băng nhôm', kind: 'pf', periodic: true },
  ],
  // Bọc vỏ
  CV: [
    { code: 'OD', label: 'OD cáp', kind: 'num', unit: 'mm' },
    { code: 'RAL', label: 'Màu vỏ (RAL)', kind: 'pf' },
    { code: 'PRINT', label: 'Nội dung in', kind: 'pf' },
    { code: 'METER_MARK', label: 'Vạch mét', kind: 'pf' },
    VISUAL,
    { code: 'SHEATH_THK', label: 'Chiều dày vỏ (mặt cắt)', kind: 'num', unit: 'mm', periodic: true },
  ],
  // Thành phẩm
  FG: [
    { code: 'LENGTH', label: 'Chiều dài cuộn', kind: 'num', unit: 'm' },
    { code: 'LABEL', label: 'Nhãn', kind: 'pf' },
    VISUAL,
    { code: 'RDC', label: 'Điện trở', kind: 'num', unit: 'Ω/km', periodic: true },
    { code: 'HV', label: 'Thử điện áp', kind: 'pf', periodic: true },
    { code: 'STD', label: 'Phép thử theo tiêu chuẩn sản phẩm', kind: 'text', periodic: true },
  ],
};
QC_TESTS.BS = QC_TESTS.BL;

// Bộ chỉ tiêu cho một lô: NVL, thành phẩm hoặc BTP theo công đoạn tạo ra (wip_stage)
export function qcTestsFor(itemKind: string, wipStage: string | null): QcTest[] {
  if (itemKind === 'MAT') return QC_TESTS.MAT;
  if (itemKind === 'FG') return QC_TESTS.FG;
  return QC_TESTS[wipStage ?? ''] ?? [VISUAL];
}

export const STAGE_NAMES: Record<string, string> = {
  MX: 'Phối trộn', CB: 'Bện', LB: 'Bọc cách điện', BL: 'Xoắn', BS: 'Xoắn + AL/PET', CV: 'Bọc vỏ', FG: 'Thành phẩm',
};
