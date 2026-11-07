// Nội dung mục Hướng dẫn sử dụng (/huong-dan). Mọi người dùng xem được.
// Nội dung nằm trong code: mỗi lần đổi quy trình trên MES thì sửa luôn tệp này (anh Bình chốt 04/11/2026).
// Thời gian: hạn MES đang chạy (bước duyệt 24 giờ, QC 2 giờ, bảng ca 12:00 thứ 7, báo cáo ngày 19:30…);
// khâu MES chưa đặt hạn thì ghi mức của quy trình final (đánh dấu "đề xuất").
// Không viết phần Quản trị hệ thống.

export type Dept = 'BGD' | 'CT' | 'SX' | 'MUA' | 'KHO' | 'KT' | 'CN' | 'KD' | 'KTOAN' | 'MES';

export const DEPTS: Record<Dept, { name: string; color: string }> = {
  CT: { name: 'Chủ tịch HĐQT', color: '#7c3aed' },
  BGD: { name: 'Giám đốc', color: '#c2410c' },
  SX: { name: 'Sản xuất', color: '#059b42' },
  MUA: { name: 'Mua hàng', color: '#0e7490' },
  KHO: { name: 'Kế toán SX, kho', color: '#1d4ed8' },
  KT: { name: 'Kỹ thuật / QA', color: '#b45309' },
  CN: { name: 'Công nhân, tổ trưởng', color: '#475569' },
  KD: { name: 'Kinh doanh', color: '#be185d' },
  KTOAN: { name: 'Kế toán', color: '#4338ca' },
  MES: { name: 'MES tự động', color: '#64748b' },
};

export type Step = {
  k: string;          // khâu: việc phải làm
  who: string;        // người phụ trách
  dept: Dept;
  time: string;       // thời gian xử lý
  out: string;        // kết quả công việc
  at?: string;        // màn hình trên MES (đường dẫn)
  back?: string;      // nhánh không đạt / trả lại
  phase?: string;     // tiêu đề giai đoạn bắt đầu từ khâu này
};

export type Guide = {
  slug: string;
  title: string;
  group: string;
  intro: string;
  steps: Step[];
  notes?: string[];
};

// Màn hình MES theo đường dẫn (hiện tên thay cho đường dẫn)
export const SCREENS: Record<string, string> = {
  '/ke-hoach': 'Sản xuất → Kế hoạch & MRP',
  '/ke-hoach/dieu-chinh': 'Sản xuất → Điều chỉnh kế hoạch tháng',
  '/lich-may': 'Sản xuất → Lịch máy',
  '/lich-may?tab=thang': 'Lịch máy → Kế hoạch tháng & công suất',
  '/lich-may?tab=phatsinh': 'Lịch máy → Đơn phát sinh & thay đổi',
  '/lich-may?tab=toiuu': 'Lịch máy → Tối ưu & thêm ca',
  '/lich-may?tab=baoduong': 'Lịch máy → Bảo dưỡng & máy hỏng',
  '/lich-may?tab=tiendo': 'Lịch máy → Tiến độ từng lệnh',
  '/lenh-ngay': 'Sản xuất → Lệnh SX ngày',
  '/ghi-nhan-ca': 'Sản xuất → Ghi nhận ca',
  '/phieu-hoan-thanh': 'Sản xuất → Phiếu hoàn thành bobin',
  '/phieu-xuat-nvl': 'Sản xuất → Phiếu xuất NVL, NVL thừa',
  '/nhan-su-xuong': 'Sản xuất → Nhân sự xưởng',
  '/nhan-su-xuong?tab=ca': 'Nhân sự xưởng → Bảng ca tuần',
  '/don-mua': 'Mua hàng → Đơn mua hàng',
  '/de-xuat': 'Mua hàng → Đề xuất mua hàng',
  '/de-xuat/moi': 'Mua hàng → Đề xuất mua hàng → Thêm mới',
  '/de-xuat/du-phong': 'Mua hàng → Tồn dự phòng',
  '/duyet': 'Điều hành → Quy trình duyệt',
  '/kho/nhan-hang': 'Kho → Tổng quan kho → Nhận hàng',
  '/kho/qc': 'Kỹ thuật / QA → QC bobin, lô hàng',
  '/kho/thanh-pham': 'Kho → Tổng quan kho → Thành phẩm',
  '/kho/xuat-ban': 'Kho → Xuất giao hàng',
  '/kho/kiem-ke': 'Kho → Kiểm kê',
  '/kho/cai-dat': 'Kho → Tổng quan kho → Cài đặt kho',
  '/kho/phe': 'Kho → Tổng quan kho → Phế liệu',
  '/kho/cap-phat': 'Lệnh SX ngày → Cấp NVL (Lĩnh bổ sung vượt định mức)',
  '/kho/ton': 'Kho → Tồn kho',
  '/kho/bobin': 'Kho → Tổng quan kho → Bobin trung gian',
  '/bao-cao/ngay': 'Báo cáo → Báo cáo sản xuất ngày',
  '/bao-cao/hao-hut': 'Báo cáo → Báo cáo hao hụt',
  '/san-pham': 'Kỹ thuật / QA → Sản phẩm & Spec',
  '/san-pham/moi': 'Sản phẩm & Spec → Thêm mới',
  '/may': 'Quản lý máy → Danh sách máy',
  '/may/bao-duong': 'Quản lý máy → Bảo dưỡng, sửa chữa',
  '/may/toc-do': 'Kỹ thuật / QA → Tốc độ sản xuất',
  '/thong-bao': 'Chuông thông báo (góc trên phải)',
};

export const GROUPS = ['Quy trình chung', 'Kế hoạch sản xuất', 'Mua hàng', 'Sản xuất hằng ngày', 'Kho', 'Kỹ thuật / QA', 'Quản lý máy', 'Dùng chung'];

export const GUIDES: Guide[] = [
  // ================================================================ QUY TRÌNH CHUNG
  {
    slug: 'quy-trinh-chung',
    title: 'Quy trình chung: kế hoạch tháng → mua hàng → chạy máy → giao hàng',
    group: 'Quy trình chung',
    intro: 'Toàn bộ dòng việc của một tháng sản xuất trên MES. Mỗi khâu có hướng dẫn chi tiết ở các quy trình riêng bên dưới.',
    steps: [
      { phase: '1. Kế hoạch tháng', k: 'Lập kế hoạch tháng, chạy MRP', who: 'TP SX', dept: 'SX', time: 'Trước khi bắt đầu tháng',
        out: 'Kế hoạch Nháp + bảng vật tư cần mua (MRP)', at: '/ke-hoach' },
      { k: 'Duyệt kế hoạch tháng (được sửa dòng, sửa MRP)', who: 'Giám đốc', dept: 'BGD', time: '24 giờ',
        out: 'Chuyển Chủ tịch HĐQT chốt', at: '/duyet', back: 'Trả lại → TP SX sửa, gửi lại' },
      { k: 'Chốt kế hoạch tháng (được tăng/giảm sản lượng, thêm/bỏ mã)', who: 'Chủ tịch HĐQT', dept: 'CT', time: '24 giờ',
        out: 'Kế hoạch Đã duyệt; MES lập đơn mua hàng tổng từ MRP giao Phòng mua hàng', at: '/duyet', back: 'Trả lại → TP SX sửa, gửi lại' },
      { phase: '2. Mua hàng', k: 'Chốt từng dòng của đơn mua tổng: NCC, đơn giá, điều khoản thanh toán, ngày giao; gom hợp đồng theo NCC, gửi TP Mua',
        who: 'NV mua hàng', dept: 'MUA', time: '5 ngày làm việc từ khi nhận đơn tổng', out: 'Hợp đồng/phiếu mua (mỗi NCC một hợp đồng) chờ TP Mua', at: '/don-mua' },
      { k: 'Duyệt hợp đồng mua', who: 'TP Mua', dept: 'MUA', time: '1 ngày làm việc', out: 'Chuyển Giám đốc', at: '/duyet', back: 'Trả lại → NV mua sửa' },
      { k: 'Duyệt hợp đồng mua', who: 'Giám đốc', dept: 'BGD', time: '1 ngày làm việc',
        out: 'Hợp đồng đã duyệt, gửi NCC; báo NV mua, Kế toán; đủ hợp đồng thì đơn tổng hoàn tất', at: '/duyet', back: 'Trả lại → NV mua sửa' },
      { k: 'Nhận hàng theo đơn mua, in tem', who: 'TP SX (thủ kho NVL)', dept: 'SX', time: 'Khi hàng về',
        out: 'Lô NVL vào kho, trạng thái Chờ QC', at: '/kho/nhan-hang' },
      { k: 'Kiểm NVL nhập', who: 'QC / TP KT/QA', dept: 'KT', time: '≤ 2 giờ', out: 'Đạt: được xuất cho sản xuất',
        at: '/kho/qc', back: 'Không đạt → cách ly, xử lý với NCC' },
      { phase: '3. Lịch máy và ca', k: 'Xếp lịch máy, đệ trình lịch từng lô', who: 'TP SX / Kế hoạch SX', dept: 'SX',
        time: 'Sau khi kế hoạch được duyệt; khi có biến động', out: 'Lịch đề xuất chờ Giám đốc', at: '/lich-may' },
      { k: 'Duyệt lịch máy, lịch lô', who: 'Giám đốc', dept: 'BGD', time: '24 giờ', out: 'Lịch đang dùng (căn cứ phát lệnh ngày)', at: '/lich-may' },
      { k: 'Lập bảng ca tuần sau, Giám đốc duyệt', who: 'TP SX → Giám đốc', dept: 'SX', time: 'Trước 12:00 thứ 7',
        out: 'MES gửi bảng ca cho công nhân, tự xếp lại lịch máy', at: '/nhan-su-xuong?tab=ca' },
      { phase: '4. Sản xuất hằng ngày', k: 'Đề xuất lệnh SX ngày D', who: 'TP SX / Kế hoạch SX', dept: 'SX', time: 'D−1, trước 16:00 (đề xuất)',
        out: 'Lệnh ngày chờ Giám đốc', at: '/lenh-ngay' },
      { k: 'Duyệt phát lệnh SX ngày', who: 'Giám đốc', dept: 'BGD', time: 'D−1, trước 16:00 (đề xuất)', out: 'Lệnh SX + phiếu lĩnh NVL',
        at: '/lenh-ngay', back: 'Trả lại → TP SX sửa, đề xuất lại' },
      { k: 'Duyệt phiếu lĩnh, in phiếu xuất NVL theo lô', who: 'Kế toán SX', dept: 'KHO', time: 'D−1, 16:00–17:00',
        out: 'Phiếu xuất NVL in giấy', at: '/phieu-xuat-nvl' },
      { k: 'Xuất NVL: thủ kho xuất, công nhân nhận, hai bên ký; Kế toán SX nhập số thực xuất', who: 'Thủ kho + Công nhân + Kế toán SX',
        dept: 'KHO', time: 'Trước 17:00 D−1', out: 'NVL ra máy, trừ tồn kho', at: '/phieu-xuat-nvl' },
      { k: 'Chạy máy, ghi phiếu hoàn thành giấy cho từng bobin', who: 'Công nhân đứng máy', dept: 'CN', time: 'Mỗi bobin xong',
        out: 'Phiếu hoàn thành (kg, mét, giờ)' },
      { k: 'Nhập phiếu hoàn thành vào MES', who: 'Kế toán SX', dept: 'KHO', time: 'Ngay khi nhận phiếu',
        out: 'Bobin trong kho, Chờ QC', at: '/phieu-hoan-thanh' },
      { k: 'Kiểm mẫu bobin, dán tem QC PASS', who: 'QC', dept: 'KT', time: '≤ 2 giờ', out: 'Bobin Đạt mới được lắp vào công đoạn sau',
        at: '/kho/qc', back: 'Không đạt → tem đỏ, cách ly' },
      { k: 'Báo cáo ca: sản lượng, dừng máy, phế; NVL thừa nhập lại kho', who: 'Kế toán SX nhập → Tổ trưởng / TP SX chốt', dept: 'KHO',
        time: 'Chốt trước 10:00 D+1 (đề xuất)', out: 'Ca đã chốt; dừng máy vào nhật ký máy', at: '/ghi-nhan-ca' },
      { k: 'Tính lại tiến độ', who: 'MES', dept: 'MES', time: '1 giờ sau khi hết ca',
        out: 'Báo Giám đốc, TP SX lô nhanh/chậm, ngày xong mới', at: '/lich-may?tab=tiendo' },
      { k: 'Đối soát, gửi báo cáo sản xuất ngày', who: 'Kế toán SX', dept: 'KHO', time: 'Trước 19:30 (19:30 MES tự gửi)',
        out: 'Email + thông báo cho TP SX, Ban giám đốc, tổ trưởng', at: '/bao-cao/ngay' },
      { k: 'Giải trình hao hụt mức đỏ', who: 'TP SX', dept: 'SX', time: 'Trước 10:00 D+1', out: 'Giải trình lưu trên báo cáo, báo Giám đốc', at: '/bao-cao/ngay' },
      { phase: '5. Thành phẩm và giao hàng', k: 'Nhập kho thành phẩm theo cuộn (cuộn đã QC Đạt)', who: 'Kế toán SX', dept: 'KHO',
        time: 'Trong ngày', out: 'Thành phẩm trong kho, giao được', at: '/kho/thanh-pham' },
      { k: 'Lập lệnh giao (chủng loại, số cuộn)', who: 'Kinh doanh / Kế toán SX', dept: 'KD', time: 'Khi có đơn khách',
        out: 'Lệnh giao chờ Giám đốc', at: '/kho/xuat-ban' },
      { k: 'Duyệt lệnh giao', who: 'Giám đốc', dept: 'BGD', time: '24 giờ', out: 'Kho được xuất hàng', at: '/duyet' },
      { k: 'Xuất giao, nhập "đã giao" theo phiếu giấy có chữ ký', who: 'Kế toán SX', dept: 'KHO', time: 'Ngày giao',
        out: 'Trừ tồn thành phẩm, lệnh giao hoàn tất', at: '/kho/xuat-ban' },
    ],
    notes: [
      'Chủ tịch HĐQT chỉ duyệt kế hoạch tháng và hiệu chỉnh kế hoạch tháng. Mọi việc sau khi chốt do Giám đốc điều hành, duyệt.',
      'Công nhân dùng giấy (phiếu hoàn thành, phiếu xuất NVL, báo cáo ca); Kế toán SX nhập vào MES.',
      'Người duyệt được sửa nội dung trước khi duyệt; mọi lần sửa ghi vào lịch sử duyệt và báo người lập.',
    ],
  },

  // ================================================================ KẾ HOẠCH
  {
    slug: 'ke-hoach-thang',
    title: 'Lập và duyệt kế hoạch tháng, MRP',
    group: 'Kế hoạch sản xuất',
    intro: 'Mỗi tháng một kế hoạch. Kế hoạch đã chốt là căn cứ mua hàng, xếp lịch máy, phát lệnh ngày.',
    steps: [
      { k: 'Thêm kế hoạch: chọn tháng, năm, ngày cần vật tư', who: 'TP SX', dept: 'SX', time: 'Trước khi bắt đầu tháng', out: 'Kế hoạch Nháp', at: '/ke-hoach' },
      { k: 'Thêm dòng: mã sản phẩm, số mét, đóng gói, nhãn hàng, hạn giao', who: 'TP SX', dept: 'SX', time: 'Cùng ngày',
        out: 'Các dòng kế hoạch (mã phải đã phát hành spec)', at: '/ke-hoach' },
      { k: 'Chạy MRP, kiểm tra vật tư cần mua; sửa số mua nếu cần (ghi lý do)', who: 'TP SX', dept: 'SX', time: 'Cùng ngày',
        out: 'Bảng MRP: nhu cầu, tồn, đang về, cần mua', at: '/ke-hoach' },
      { k: 'Gửi duyệt', who: 'TP SX', dept: 'SX', time: 'Cùng ngày', out: 'Giám đốc nhận thông báo' },
      { k: 'Duyệt; được sửa dòng kế hoạch, số mua MRP', who: 'Giám đốc', dept: 'BGD', time: '24 giờ', out: 'Chuyển Chủ tịch HĐQT',
        at: '/duyet', back: 'Trả lại (ghi lý do) → TP SX sửa, gửi lại' },
      { k: 'Chốt; được tăng/giảm sản lượng, thêm/bỏ mã (ghi lý do)', who: 'Chủ tịch HĐQT', dept: 'CT', time: '24 giờ',
        out: 'Kế hoạch Đã duyệt', at: '/duyet', back: 'Trả lại → TP SX sửa, gửi lại' },
      { k: 'Lập đơn mua hàng tổng từ MRP', who: 'MES', dept: 'MES', time: 'Ngay khi chốt', out: 'Đơn mua tổng giao NV mua (hạn 5 ngày làm việc)', at: '/don-mua' },
    ],
    notes: [
      'Đổi kế hoạch đã duyệt (thêm mã, tăng/giảm, đổi hạn, bỏ mã): dùng "Đề xuất hiệu chỉnh kế hoạch tháng".',
      'Có chỉnh sửa khi duyệt thì MES chạy lại MRP, giữ các số TP Mua đã sửa nếu nhu cầu không đổi.',
      'Kết quả MRP, Dự trù nhiều tầng, Lịch sử điều chỉnh MRP: nút Xuất Excel trên trang kế hoạch (một tệp nhiều trang).',
    ],
  },
  {
    slug: 'hieu-chinh-ke-hoach',
    title: 'Đề xuất hiệu chỉnh kế hoạch tháng',
    group: 'Kế hoạch sản xuất',
    intro: 'Tăng, giảm sản lượng, thêm mã, đổi hạn giao, bỏ mã của kế hoạch tháng đã duyệt.',
    steps: [
      { k: 'Lập đề xuất: chọn kế hoạch đã duyệt, ghi lý do', who: 'TP SX / Kế hoạch SX', dept: 'SX', time: 'Khi phát sinh', out: 'Đề xuất Nháp (PDC-…)', at: '/ke-hoach/dieu-chinh' },
      { k: 'Xem danh mục sản xuất của tháng; thêm dòng: Thêm mã / Đổi số mét / Đổi hạn / Bỏ mã; Lưu nháp', who: 'TP SX', dept: 'SX', time: 'Cùng ngày',
        out: 'Danh mục hiện số mét, hạn sau hiệu chỉnh', at: '/ke-hoach/dieu-chinh' },
      { k: 'Bấm "Chạy MRP hiệu chỉnh" (MES tự chạy khi mở, khi sửa dòng)', who: 'TP SX', dept: 'SX', time: 'Cùng ngày',
        out: 'Bảng MRP ban đầu / hiện tại / chênh lệch, tồn, hàng về, đã đề xuất, dự phòng, thiếu, đề xuất mua, tồn sau SX', at: '/ke-hoach/dieu-chinh' },
      { k: 'Lưu và gửi Giám đốc duyệt', who: 'TP SX', dept: 'SX', time: 'Cùng ngày', out: 'Giám đốc nhận thông báo' },
      { k: 'Duyệt (được sửa dòng)', who: 'Giám đốc', dept: 'BGD', time: '24 giờ', out: 'Chuyển Chủ tịch HĐQT', at: '/duyet', back: 'Trả lại → TP SX sửa' },
      { k: 'Duyệt (được sửa dòng)', who: 'Chủ tịch HĐQT', dept: 'CT', time: '24 giờ', out: 'Đề xuất Đã duyệt', at: '/duyet', back: 'Trả lại → TP SX sửa' },
      { k: 'Áp vào kế hoạch, chạy lại MRP', who: 'MES', dept: 'MES', time: 'Ngay khi duyệt',
        out: 'Kế hoạch mới; mua thêm → đơn mua bổ sung; thừa → giảm đơn/đề xuất mua chưa duyệt (đã duyệt giữ nguyên)' },
    ],
    notes: ['Không giảm dưới số thành phẩm đã làm, không bỏ lô đã phát lệnh SX.', 'Chạy MRP hiệu chỉnh chỉ là chạy thử, không đổi kế hoạch, đơn mua; kết quả lưu lại đến khi sửa dòng hoặc kế hoạch chạy MRP lại.', 'Bảng MRP hiệu chỉnh có nút Xuất Excel.'],
  },
  {
    slug: 'lich-may',
    title: 'Xếp lịch máy, duyệt lịch, lịch theo lô',
    group: 'Kế hoạch sản xuất',
    intro: 'MES tự xếp lịch theo tốc độ máy, người đứng máy, ca, máy hỏng, bảo dưỡng. TP SX đề xuất, Giám đốc duyệt.',
    steps: [
      { k: 'Bấm "Xếp lại lịch" (MES tự tối ưu thứ tự lô, gom lô cùng cỡ/màu)', who: 'TP SX / Kế hoạch SX', dept: 'SX',
        time: 'Sau khi kế hoạch được duyệt; khi lịch báo "cần xếp lại"', out: 'Bản lịch đề xuất', at: '/lich-may' },
      { k: 'Duyệt lịch máy', who: 'Giám đốc', dept: 'BGD', time: '24 giờ', out: 'Lịch đang dùng', at: '/lich-may', back: 'Trả lại (ghi lý do) → TP SX xếp lại' },
      { k: 'Đệ trình ngày chốt từng lô (hoặc "Đệ trình mọi lô theo MES")', who: 'TP SX', dept: 'SX', time: 'Sau khi lịch được duyệt',
        out: 'Lô chờ Giám đốc duyệt', at: '/lich-may?tab=thang' },
      { k: 'Duyệt lịch lô (được sửa ngày chốt, ghi chú)', who: 'Giám đốc', dept: 'BGD', time: '24 giờ', out: 'Lô giữ chỗ trên lịch, ngày chốt để theo dõi trễ', at: '/lich-may?tab=thang' },
      { k: 'Tính lại tiến độ theo sản lượng thực tế', who: 'MES', dept: 'MES', time: '1 giờ sau khi hết ca', out: 'Lịch mới; báo lô nhanh/chậm, trễ so ngày chốt', at: '/lich-may?tab=tiendo' },
    ],
    notes: [
      'Máy chưa khai tốc độ thì MES không xếp việc lên máy đó (menu hiện ALARM): TP KT/QA khai ở Hồ sơ máy → Tốc độ & dải hoạt động.',
      'Lô trễ: xem Lịch máy → Tối ưu & thêm ca để biết máy cổ chai và đề xuất chạy 2–3 ca.',
    ],
  },
  {
    slug: 'don-phat-sinh',
    title: 'Đơn phát sinh (lô ngoài kế hoạch, chen lịch)',
    group: 'Kế hoạch sản xuất',
    intro: 'Đơn gấp, lô ngoài kế hoạch tháng. MES mô phỏng ảnh hưởng và tự chọn mức A/B/C.',
    steps: [
      { k: 'Lập đơn: mã, số mét, hạn; MES mô phỏng lịch', who: 'TP SX / Kế hoạch SX', dept: 'SX', time: 'Khi phát sinh',
        out: 'Mức A (không ảnh hưởng) / B (làm trễ lô khác) / C (chen vùng khóa)', at: '/lich-may?tab=phatsinh' },
      { k: 'Cho ý kiến kỹ thuật (chỉ mức C)', who: 'TP KT/QA', dept: 'KT', time: '4 giờ (đề xuất)', out: 'Chuyển Giám đốc', back: 'Từ chối → đơn dừng' },
      { k: 'Duyệt (được sửa số mét, hạn giao)', who: 'Giám đốc', dept: 'BGD', time: '4 giờ (đề xuất)', out: 'Đơn Đã duyệt', at: '/lich-may?tab=phatsinh', back: 'Từ chối → báo người lập' },
      { k: 'Xếp lại lịch theo đơn đã duyệt', who: 'TP SX', dept: 'SX', time: 'Ngay sau khi duyệt', out: 'Lịch mới dùng ngay', at: '/lich-may' },
    ],
  },
  {
    slug: 'bang-ca-tuan',
    title: 'Bảng ca tuần, máy chạy 2–3 ca',
    group: 'Kế hoạch sản xuất',
    intro: 'Mỗi tuần một bảng ca: máy nào chạy ca 1, ca 2; ai làm ca nào. Giờ ca do Giám đốc khai ở Tham số xếp lịch.',
    steps: [
      { k: 'Bấm "MES lập bảng ca" cho tuần sau; sửa máy chạy ca 2, người từng ca, phụ trách ca 2, người đo mẫu QC', who: 'TP SX', dept: 'SX',
        time: 'Thứ 6 (MES nhắc 08:00)', out: 'Bảng ca Nháp', at: '/nhan-su-xuong?tab=ca' },
      { k: 'Duyệt và gửi Giám đốc', who: 'TP SX', dept: 'SX', time: 'Trước 12:00 thứ 7', out: 'Bảng ca chờ Giám đốc' },
      { k: 'Duyệt và gửi công nhân (được sửa)', who: 'Giám đốc', dept: 'BGD', time: 'Trước 12:00 thứ 7', out: 'Bảng ca Đã duyệt',
        at: '/nhan-su-xuong?tab=ca', back: 'Trả lại (ghi lý do) → TP SX sửa' },
      { k: 'Gửi bảng ca cho công nhân, tổ trưởng, QC; xếp lại lịch máy', who: 'MES', dept: 'MES', time: 'Ngay khi duyệt (áp từ ngày mai)',
        out: 'Công nhân không có tài khoản: in bảng ca dán xưởng' },
    ],
    notes: [
      'Ca 2 phải có ít nhất 2 người, 1 người phụ trách và người đo mẫu QC. Đổi ca phải nghỉ đủ 12 giờ.',
      'MES chọn người theo giờ đứng máy 4 tuần để luân phiên đều (xem tab Sổ giờ).',
      'Quá 12:00 thứ 7 chưa duyệt: MES cảnh báo Giám đốc và TP SX.',
    ],
  },
  {
    slug: 'nhan-su-xuong',
    title: 'Nhân sự xưởng: người đứng máy, lịch vắng, kiêm nhiệm',
    group: 'Kế hoạch sản xuất',
    intro: 'Lịch máy chỉ xếp người có mặt và có tay nghề. Khai báo đúng để lịch đúng.',
    steps: [
      { k: 'Thêm người, tay nghề từng máy (đứng chính / đang học)', who: 'TP SX', dept: 'SX', time: 'Khi có người mới', out: 'Người có trong lịch', at: '/nhan-su-xuong' },
      { k: 'Ký tay nghề', who: 'TP KT/QA', dept: 'KT', time: '3 ngày (đề xuất)', out: 'Tay nghề đã ký', at: '/nhan-su-xuong' },
      { k: 'Ghi lịch vắng (cả ngày / nửa ca)', who: 'TP SX', dept: 'SX', time: 'Trước ngày vắng', out: 'Lịch máy không xếp người đó', at: '/nhan-su-xuong' },
      { k: 'Phân công kiêm nhiệm tạm (người, máy, từ–đến)', who: 'TP SX', dept: 'SX', time: 'Khi thiếu người', out: 'Báo TP KT/QA; lịch dùng người kiêm', at: '/nhan-su-xuong' },
      { k: 'Xếp lại lịch', who: 'TP SX', dept: 'SX', time: 'Sau khi đổi', out: 'Lịch theo người mới', at: '/lich-may' },
    ],
  },

  // ================================================================ MUA HÀNG
  {
    slug: 'don-mua-hang',
    title: 'Đơn mua hàng tổng, hợp đồng mua theo NCC',
    group: 'Mua hàng',
    intro: 'Yêu cầu mua được duyệt (kế hoạch tháng chốt, đề xuất mua Giám đốc duyệt) thì MES lập đơn mua hàng tổng. Mỗi chủng loại có NCC riêng: NCC, giá, điều khoản, ngày giao ghi theo từng dòng.',
    steps: [
      { k: 'Lập đơn mua hàng tổng (DMT-…), giao Phòng mua hàng', who: 'MES', dept: 'MES', time: 'Ngay khi yêu cầu mua được duyệt',
        out: 'Báo NV mua, TP Mua kèm hạn gửi đủ hợp đồng', at: '/don-mua' },
      { k: 'Làm việc với NCC, chốt cho từng dòng: NCC, đơn giá, điều khoản thanh toán, ngày giao dự kiến (bấm Lưu từng dòng)', who: 'NV mua hàng', dept: 'MUA',
        time: 'Trong 5 ngày làm việc', out: 'Dòng đủ thông tin (hết nền vàng)', at: '/don-mua' },
      { k: 'Bấm "Gom và gửi TP Mua": mỗi NCC một hợp đồng (tích dòng để tách nhiều hợp đồng)', who: 'NV mua hàng', dept: 'MUA',
        time: 'Hết hạn 5 ngày làm việc phải gửi đủ', out: 'Hợp đồng/phiếu mua (PO-…) chờ TP Mua', at: '/don-mua',
        back: 'Đổi NCC của hợp đồng nháp: "Trả dòng về đơn tổng" rồi gom lại' },
      { k: 'Duyệt hợp đồng (được sửa số lượng, giá, điều khoản, ngày giao)', who: 'TP Mua', dept: 'MUA', time: '1 ngày làm việc', out: 'Chuyển Giám đốc',
        at: '/duyet', back: 'Trả lại → NV mua sửa' },
      { k: 'Duyệt hợp đồng (được sửa)', who: 'Giám đốc', dept: 'BGD', time: '1 ngày làm việc',
        out: 'Hợp đồng đã duyệt, gửi NCC; báo NV mua, Kế toán kho, Kế toán giá thành, Kế toán trưởng; báo thủ kho chờ hàng', at: '/duyet', back: 'Trả lại → NV mua sửa' },
      { k: 'Đủ hợp đồng được duyệt: đơn tổng hoàn tất', who: 'MES', dept: 'MES', time: 'Ngay khi duyệt hợp đồng cuối', out: 'Báo hoàn tất cho NV mua, Kế toán' },
      { k: 'Nhận hàng theo hợp đồng', who: 'TP SX (thủ kho NVL)', dept: 'SX', time: 'Khi hàng về', out: 'Xem quy trình "Nhận hàng NVL"', at: '/kho/nhan-hang' },
    ],
    notes: [
      'Quá hạn: MES nhắc trước 1 ngày làm việc; quá hạn thì cảnh báo cấp trên (NV mua → TP Mua + Giám đốc; TP Mua → Giám đốc; Giám đốc → Chủ tịch HĐQT). Không ai duyệt thay.',
      'Ngày làm việc theo lịch làm việc của xưởng (Tham số xếp lịch).',
      'Đơn tổng từ đề xuất mua đã duyệt là hàng "đã duyệt mua": hiệu chỉnh kế hoạch tháng không cắt.',
    ],
  },
  {
    slug: 'de-xuat-mua',
    title: 'Đề xuất mua bổ sung, tích trữ, tối ưu',
    group: 'Mua hàng',
    intro: 'Mua ngoài kế hoạch tháng: bù dưới mức dự phòng, mua tích trữ, mua tối ưu giá.',
    steps: [
      { k: 'Lập đề xuất: chọn loại, vật tư, số lượng, ngày cần', who: 'NV mua / TP Mua / TP SX', dept: 'MUA', time: 'Khi phát sinh',
        out: 'Đề xuất Nháp (thấy tồn, đang về, tồn dự kiến)', at: '/de-xuat/moi' },
      { k: 'Gửi duyệt', who: 'Người lập', dept: 'MUA', time: 'Cùng ngày', out: 'TP Mua nhận thông báo' },
      { k: 'Duyệt (được sửa số lượng)', who: 'TP Mua', dept: 'MUA', time: '24 giờ', out: 'Chuyển Giám đốc', at: '/duyet', back: 'Trả lại → người lập sửa' },
      { k: 'Duyệt (được sửa)', who: 'Giám đốc', dept: 'BGD', time: '24 giờ', out: 'Đề xuất Đã duyệt', at: '/duyet', back: 'Trả lại → người lập sửa' },
      { k: 'Lập đơn mua hàng tổng từ đề xuất, rồi đi quy trình "Đơn mua hàng tổng, hợp đồng"', who: 'MES', dept: 'MES', time: 'Ngay khi Giám đốc duyệt', out: 'Đơn mua tổng giao NV mua (hạn 5 ngày làm việc)', at: '/don-mua' },
    ],
    notes: ['Tích trữ, tối ưu chỉ NV mua, TP Mua lập. Vật tư theo kế hoạch tháng không lập đề xuất: MES đã sinh đơn mua.'],
  },
  {
    slug: 'ton-du-phong',
    title: 'Tồn dự phòng',
    group: 'Mua hàng',
    intro: 'Mỗi vật tư có mức tồn dự phòng (thường đủ 1 tháng sản xuất). Dưới mức thì MES cảnh báo.',
    steps: [
      { k: 'Lập phiếu điều chỉnh mức dự phòng (MES gợi ý theo tiêu hao)', who: 'TP Mua', dept: 'MUA', time: 'Khi cần đổi mức', out: 'Phiếu DP Nháp', at: '/de-xuat/du-phong' },
      { k: 'Gửi duyệt', who: 'TP Mua', dept: 'MUA', time: 'Cùng ngày', out: 'Giám đốc nhận thông báo' },
      { k: 'Duyệt (được sửa)', who: 'Giám đốc', dept: 'BGD', time: '24 giờ', out: 'Mức mới áp vào vật tư, MRP dùng mức này', at: '/duyet', back: 'Trả lại → TP Mua sửa' },
      { k: 'Kiểm tra mỗi giờ, báo vật tư dưới mức', who: 'MES', dept: 'MES', time: 'Mỗi giờ; nhắc lại mỗi tuần', out: 'Thông báo TP Mua, NV mua, Kế toán SX, Giám đốc; số đỏ trên menu' },
      { k: 'Bấm "Lập đề xuất mua bổ sung" bù phần thiếu', who: 'NV mua / TP Mua', dept: 'MUA', time: '24 giờ (đề xuất)', out: 'Đề xuất mua bổ sung (duyệt xong MES lập đơn mua tổng)', at: '/de-xuat/du-phong' },
    ],
  },

  // ================================================================ SẢN XUẤT HẰNG NGÀY
  {
    slug: 'lenh-sx-ngay',
    title: 'Lệnh SX ngày, phiếu lĩnh, xuất NVL',
    group: 'Sản xuất hằng ngày',
    intro: 'Từ lịch máy đang dùng, MES tính việc và vật tư của ngày D.',
    steps: [
      { k: 'Xem kiểm tra (spec, BOM, tồn NVL đạt QC, máy, người); bấm "Đề xuất lệnh ngày"', who: 'TP SX / Kế hoạch SX', dept: 'SX',
        time: 'D−1, trước 16:00 (đề xuất)', out: 'Lệnh ngày chờ Giám đốc', at: '/lenh-ngay', back: 'Còn cảnh báo → bắt buộc ghi chú' },
      { k: 'Duyệt phát lệnh', who: 'Giám đốc', dept: 'BGD', time: 'D−1, trước 16:00 (đề xuất)', out: 'Lệnh SX (LSX) + phiếu lĩnh', at: '/lenh-ngay', back: 'Trả lại → TP SX sửa' },
      { k: 'Duyệt phiếu lĩnh', who: 'Kế toán SX', dept: 'KHO', time: 'D−1, 16:00–17:00', out: 'Phiếu lĩnh đã duyệt', at: '/lenh-ngay' },
      { k: 'In phiếu xuất NVL theo lô (kèm phiếu nhập NVL thừa)', who: 'Kế toán SX', dept: 'KHO', time: 'D−1, trước 17:00', out: 'Phiếu giấy', at: '/phieu-xuat-nvl' },
      { k: 'Xuất NVL, ký phiếu', who: 'Thủ kho xuất, công nhân nhận', dept: 'CN', time: 'Trước 17:00 D−1', out: 'Phiếu có 2 chữ ký' },
      { k: 'Nhập số thực xuất (mã tem, số lượng, người nhận)', who: 'Kế toán SX', dept: 'KHO', time: 'Ngay khi nhận phiếu', out: 'Trừ tồn kho theo lô', at: '/phieu-xuat-nvl' },
      { k: 'Cuối ngày: nhập NVL thừa về kho (đồng trên giá xả, nhựa trong phễu chạy tiếp cùng lô thì ghi ở báo cáo ca)', who: 'Kế toán SX', dept: 'KHO',
        time: 'Cuối ngày', out: 'NVL về đúng ống/bao', at: '/phieu-xuat-nvl' },
    ],
    notes: ['Cần thêm NVL vượt định mức: xem quy trình "Lĩnh NVL vượt định mức".'],
  },
  {
    slug: 'phieu-hoan-thanh-qc',
    title: 'Phiếu hoàn thành bobin và QC bobin',
    group: 'Sản xuất hằng ngày',
    intro: 'Mỗi bobin (cuộn) làm xong có một phiếu hoàn thành. Bobin phải QC Đạt mới được lắp vào công đoạn sau.',
    steps: [
      { k: 'In phiếu hoàn thành trống theo lệnh, công đoạn', who: 'Kế toán SX', dept: 'KHO', time: 'Đầu ca', out: 'Phiếu in sẵn lô, mã, công đoạn, máy', at: '/phieu-hoan-thanh' },
      { k: 'Ghi phiếu: số bobin, kg cân, mét (đồng hồ đầu/cuối), giờ, bobin đầu vào, phế', who: 'Công nhân đứng máy', dept: 'CN', time: 'Mỗi bobin xong', out: 'Phiếu giấy' },
      { k: 'Nhập phiếu vào MES', who: 'Kế toán SX (TP SX)', dept: 'KHO', time: 'Ngay khi nhận phiếu', out: 'Lô bobin Chờ QC; báo QC', at: '/phieu-hoan-thanh' },
      { k: 'Lấy mẫu, đo theo chỉ tiêu công đoạn; bấm Đạt / Không đạt; dán tem', who: 'QC', dept: 'KT', time: '≤ 2 giờ (quá hạn MES báo QC, TP KT/QA)', out: 'Đạt: tem QC PASS, được lắp',
        at: '/kho/qc', back: 'Không đạt → tem đỏ, cách ly, phiếu xử lý' },
      { k: 'Lắp bobin Đạt vào công đoạn sau', who: 'Công nhân', dept: 'CN', time: 'Theo lịch', out: 'MES chặn bobin chưa Đạt' },
    ],
    notes: [
      'Bện: chỉ cân kg, MES quy ra mét; mét thật lấy từ đồng hồ line đùn khi bọc.',
      'Đóng gói: nhập số cuộn × mét mỗi cuộn. Bobin phải khai ở Kho → Bobin trung gian và đang trống.',
      'Nhập sai: hủy phiếu có lý do (khi bobin chưa QC xong, chưa dùng).',
    ],
  },
  {
    slug: 'bao-cao-ca',
    title: 'Báo cáo ca',
    group: 'Sản xuất hằng ngày',
    intro: 'Tờ báo cáo ca giấy của từng máy: sản lượng, dừng máy, phế, NVL để lại máy.',
    steps: [
      { k: 'Ghi tờ báo cáo ca (in trống từ MES)', who: 'Công nhân / Tổ trưởng', dept: 'CN', time: 'Cuối ca', out: 'Tờ báo cáo giấy' },
      { k: 'Nhập: sản lượng (MES điền sẵn từ phiếu hoàn thành), dừng máy (giờ, lý do), phế cả ca, NVL để lại máy; gửi chốt', who: 'Kế toán SX',
        dept: 'KHO', time: 'Trong ngày', out: 'Báo cáo chờ chốt', at: '/ghi-nhan-ca' },
      { k: 'Xác nhận chốt ca', who: 'Tổ trưởng / TP SX', dept: 'SX', time: 'Trước 10:00 D+1 (đề xuất)', out: 'Dừng máy vào nhật ký máy; hỏng → mở phiếu sửa chữa; phế vào kho',
        at: '/ghi-nhan-ca', back: 'Mở lại → Kế toán SX sửa' },
    ],
  },
  {
    slug: 'bao-cao-ngay',
    title: 'Báo cáo sản xuất ngày, hao hụt',
    group: 'Sản xuất hằng ngày',
    intro: 'Cuối ngày đối soát sản lượng, QC, hao hụt từng lô (Xanh / Vàng / Đỏ), NVL xuất – trả.',
    steps: [
      { k: 'Kiểm tra báo cáo ngày, đối soát phiếu; bấm "Đã đối soát xong – gửi"', who: 'Kế toán SX', dept: 'KHO', time: 'Trước 19:30',
        out: 'Thông báo + email TP SX, Kế toán SX, Ban giám đốc, tổ trưởng; phiếu kho trong ngày được xác nhận', at: '/bao-cao/ngay' },
      { k: 'Tự gửi nếu chưa ai gửi', who: 'MES', dept: 'MES', time: '19:30', out: 'Báo cáo ngày' },
      { k: 'Giải trình lô hao hụt Đỏ', who: 'TP SX', dept: 'SX', time: 'Trước 10:00 D+1', out: 'Giải trình lưu trên báo cáo, báo Giám đốc', at: '/bao-cao/ngay' },
      { k: 'Nhắc mục Đỏ chưa giải trình', who: 'MES', dept: 'MES', time: '10:00 D+1', out: 'Báo Giám đốc, TP SX' },
    ],
    notes: ['Ngưỡng hao hụt (đồng, nhựa, mét) do TP KT/QA đặt ở Kho → Cài đặt kho.'],
  },

  // ================================================================ KHO
  {
    slug: 'nhan-hang',
    title: 'Nhận hàng NVL và QC nhập',
    group: 'Kho',
    intro: 'Nhận hàng theo hợp đồng mua đã duyệt. NVL phải QC Đạt mới xuất cho sản xuất.',
    steps: [
      { k: 'Chọn hợp đồng mua, dòng hàng; nhập số lượng, lô NCC, hạn dùng, vị trí; in tem', who: 'TP SX (thủ kho NVL)', dept: 'SX', time: 'Khi hàng về',
        out: 'Lô NVL vào kho KNL, Chờ QC', at: '/kho/nhan-hang' },
      { k: 'Kiểm NVL', who: 'QC / TP KT/QA', dept: 'KT', time: '≤ 2 giờ', out: 'Đạt: xuất được cho sản xuất', at: '/kho/qc', back: 'Không đạt → cách ly, báo TP Mua làm việc với NCC' },
      { k: 'Hậu kiểm phiếu nhập (gửi báo cáo ngày là xác nhận)', who: 'Kế toán SX', dept: 'KHO', time: 'Cuối ngày', out: 'Phiếu kho đã hậu kiểm', at: '/bao-cao/ngay' },
    ],
  },
  {
    slug: 'linh-vuot-dinh-muc',
    title: 'Lĩnh NVL vượt định mức',
    group: 'Kho',
    intro: 'Cần thêm vật tư ngoài số MES tính theo định mức.',
    steps: [
      { k: 'Lập phiếu lĩnh bổ sung: lệnh SX, vật tư, số lượng, lý do; gửi duyệt', who: 'TP SX', dept: 'SX', time: 'Khi phát sinh', out: 'Phiếu chờ TP KT/QA', at: '/kho/cap-phat' },
      { k: 'Duyệt cấp vượt định mức', who: 'TP KT/QA', dept: 'KT', time: '24 giờ (quá hạn: Ban giám đốc duyệt thay)', out: 'Phiếu lĩnh đã duyệt', at: '/duyet', back: 'Trả lại → TP SX' },
      { k: 'Xuất NVL theo phiếu, nhập số thực xuất', who: 'Thủ kho + Kế toán SX', dept: 'KHO', time: 'Trong ca', out: 'Trừ tồn kho', at: '/phieu-xuat-nvl' },
    ],
  },
  {
    slug: 'thanh-pham-giao-hang',
    title: 'Nhập kho thành phẩm, giao hàng',
    group: 'Kho',
    intro: 'Thành phẩm quản lý theo cuộn (tem QC PASS, không QR). Xuất giao theo chủng loại và số cuộn.',
    steps: [
      { k: 'Nhập kho thành phẩm: chọn cuộn đã QC Đạt, người giữ kho TP, vị trí; in phiếu nhập', who: 'Kế toán SX', dept: 'KHO', time: 'Trong ngày',
        out: 'Thành phẩm trong kho, giao được', at: '/kho/thanh-pham' },
      { k: 'Lập lệnh giao: khách, chủng loại, quy cách, số cuộn; gửi duyệt', who: 'Kinh doanh / Kế toán SX', dept: 'KD', time: 'Khi có đơn',
        out: 'Lệnh giao chờ Giám đốc (MES kiểm đủ cuộn)', at: '/kho/xuat-ban' },
      { k: 'Duyệt (được sửa)', who: 'Giám đốc', dept: 'BGD', time: '24 giờ', out: 'Báo Kế toán SX, TP SX, NV kho', at: '/duyet', back: 'Trả lại → người lập sửa' },
      { k: 'Xuất hàng, ký phiếu giao giấy', who: 'Người giữ kho TP', dept: 'CN', time: 'Ngày giao', out: 'Phiếu giao có chữ ký' },
      { k: 'Nhập "đã giao" theo phiếu giấy (MES tự chọn cuộn, giao một phần được)', who: 'Kế toán SX', dept: 'KHO', time: 'Ngay khi nhận phiếu',
        out: 'Trừ tồn thành phẩm', at: '/kho/xuat-ban' },
    ],
    notes: ['Khách trả hàng, tách cuộn: Kho → Thành phẩm.'],
  },
  {
    slug: 'kiem-ke',
    title: 'Kiểm kê kho',
    group: 'Kho',
    intro: 'Đếm mù: người đếm không thấy số trên sổ. Chênh lệch phải Kế toán trưởng duyệt.',
    steps: [
      { k: 'Lập phiếu kiểm kê (kho, vị trí)', who: 'Kế toán SX', dept: 'KHO', time: 'Theo lịch kiểm kê', out: 'Phiếu kiểm kê', at: '/kho/kiem-ke' },
      { k: 'Đếm, nhập số đếm', who: 'Kế toán SX + thủ kho', dept: 'KHO', time: 'Ngày kiểm kê', out: 'Chênh lệch so sổ' },
      { k: 'Gửi duyệt chênh lệch', who: 'Kế toán SX', dept: 'KHO', time: 'Cùng ngày', out: 'Chờ Kế toán trưởng' },
      { k: 'Duyệt chênh lệch', who: 'Kế toán trưởng', dept: 'KTOAN', time: '24 giờ (quá hạn: Ban giám đốc duyệt thay)', out: 'Điều chỉnh tồn kho', at: '/duyet', back: 'Trả lại → đếm lại' },
    ],
  },
  {
    slug: 'ton-dau-ky',
    title: 'Tồn kho đầu kỳ',
    group: 'Kho',
    intro: 'Nhập số tồn ban đầu khi bắt đầu dùng kho trên MES.',
    steps: [
      { k: 'Lập tồn đầu kỳ từng kho theo mẫu (NVL; BTP mỗi dòng một bobin; TP theo cuộn)', who: 'Kế toán SX', dept: 'KHO', time: 'Trước ngày dùng kho',
        out: 'Phiếu tồn đầu kỳ', at: '/kho/cai-dat' },
      { k: 'Gửi duyệt', who: 'Kế toán SX', dept: 'KHO', time: 'Cùng ngày', out: 'Chờ Kế toán trưởng' },
      { k: 'Duyệt', who: 'Kế toán trưởng', dept: 'KTOAN', time: '24 giờ', out: 'Tồn kho có số; bobin gắn với lô', at: '/duyet', back: 'Trả lại → Kế toán SX sửa' },
    ],
  },
  {
    slug: 'phe-lieu',
    title: 'Phế liệu: nhập kho, xuất bán / hủy',
    group: 'Kho',
    intro: 'Phế ghi trên phiếu hoàn thành và báo cáo ca tự vào kho phế (KPL).',
    steps: [
      { k: 'Phế vào kho KPL', who: 'MES', dept: 'MES', time: 'Khi chốt ca, gửi báo cáo ngày', out: 'Tồn phế theo mã', at: '/kho/phe' },
      { k: 'Lập phiếu bán / hủy phế, gửi duyệt', who: 'TP SX', dept: 'SX', time: 'Khi bán phế', out: 'Chờ Kế toán SX', at: '/kho/phe' },
      { k: 'Kiểm tra', who: 'Kế toán SX', dept: 'KHO', time: '24 giờ', out: 'Chuyển Giám đốc', at: '/duyet', back: 'Trả lại → TP SX' },
      { k: 'Duyệt', who: 'Giám đốc', dept: 'BGD', time: '24 giờ', out: 'Xuất phế, trừ tồn', at: '/duyet', back: 'Trả lại → TP SX' },
    ],
  },

  // ================================================================ KỸ THUẬT / QA
  {
    slug: 'spec-moi',
    title: 'Spec mới, phiên bản spec mới',
    group: 'Kỹ thuật / QA',
    intro: 'Mã sản phẩm phải có spec Đã phát hành mới đưa vào kế hoạch, sản xuất.',
    steps: [
      { k: 'Thêm mã (IN HOA) hoặc tạo phiên bản mới; nhập thông số ruột dẫn, dây đơn, dây hoàn thiện, màu lõi', who: 'TP KT/QA', dept: 'KT', time: 'Khi có mã mới / thay đổi',
        out: 'Spec Nháp; MES tính định mức, Rdc, đồng bộ BOM', at: '/san-pham' },
      { k: 'Bấm "Tạm tính" để xem số trước khi lưu; sửa BOM; xem Tổng hợp vật tư 1 km', who: 'TP KT/QA', dept: 'KT', time: 'Cùng ngày', out: 'Kiểm tra tự động Đạt' },
      { k: 'Rdc vượt giới hạn: sản xuất mẫu pilot, nhập Rdc đo (thẻ Pilot)', who: 'TP KT/QA + Sản xuất', dept: 'KT', time: 'Khi cần', out: 'Pilot đạt hoặc ghi chấp nhận sai lệch' },
      { k: 'Gửi duyệt', who: 'TP KT/QA', dept: 'KT', time: 'Cùng ngày', out: 'TP SX nhận thông báo' },
      { k: 'Xác nhận sản xuất được', who: 'TP SX', dept: 'SX', time: '24 giờ', out: 'Chuyển Giám đốc', at: '/duyet', back: 'Trả lại → TP KT/QA sửa' },
      { k: 'Phát hành', who: 'Giám đốc', dept: 'BGD', time: '24 giờ', out: 'Spec Đã phát hành; bản cũ hết hiệu lực; kế hoạch chưa xong tự chuyển sang bản mới',
        at: '/duyet', back: 'Trả lại → TP KT/QA sửa' },
    ],
    notes: ['Spec đã phát hành không sửa được: tạo phiên bản mới.', 'Tên quy cách sản phẩm MES tự đặt theo thông số.'],
  },
  {
    slug: 'toc-do-may',
    title: 'Tốc độ máy',
    group: 'Kỹ thuật / QA',
    intro: 'Lịch máy chỉ dùng tốc độ khai cho từng máy. Có tốc độ theo cỡ thì dùng, cỡ không khai dùng tốc độ chung của máy.',
    steps: [
      { k: 'Nhập tốc độ: cỡ ruột (hoặc chung), riêng một mã nếu cần, tốc độ chuẩn, phút đổi máy', who: 'Kỹ thuật / Quản lý SX', dept: 'KT', time: 'Khi có máy, mã mới; khi menu báo ALARM',
        out: 'Dòng tốc độ Chờ duyệt (lịch vẫn dùng tạm)', at: '/may' },
      { k: 'Duyệt (hoặc "Duyệt tất cả")', who: 'TP KT/QA', dept: 'KT', time: '24 giờ (đề xuất)', out: 'Tốc độ Đã duyệt; lịch báo "cần xếp lại"', at: '/may/toc-do', back: 'Không duyệt dòng mình nhập' },
      { k: 'Xếp lại lịch', who: 'TP SX', dept: 'SX', time: 'Sau khi đổi tốc độ', out: 'Lịch theo tốc độ mới', at: '/lich-may' },
    ],
  },

  // ================================================================ QUẢN LÝ MÁY
  {
    slug: 'may-hong',
    title: 'Báo hỏng máy, sửa chữa',
    group: 'Quản lý máy',
    intro: 'Máy Dừng / Hỏng phải có giờ dự kiến chạy lại để lịch tránh máy đó.',
    steps: [
      { k: 'Báo Hỏng / Dừng: lý do, giờ dự kiến chạy lại', who: 'TP KT/QA (vắng: TP SX)', dept: 'KT', time: 'Ngay khi hỏng',
        out: 'Máy Hỏng; báo TP SX, Kế hoạch SX xếp lại; mở phiếu sửa chữa', at: '/may' },
      { k: 'Xếp lại lịch (việc chuyển sang máy cùng loại)', who: 'TP SX', dept: 'SX', time: 'Ngay', out: 'Lịch mới; báo lô bị lùi', at: '/lich-may' },
      { k: 'Sửa máy, ghi nguyên nhân, linh kiện; bấm Xong', who: 'Kỹ thuật', dept: 'KT', time: 'Theo giờ dự kiến', out: 'Phiếu sửa chữa Xong; báo TP SX', at: '/may/bao-duong' },
      { k: 'Xác nhận máy chạy lại đạt', who: 'TP SX', dept: 'SX', time: 'Khi chạy thử xong', out: 'Máy Chạy; lịch dùng lại máy', at: '/may/bao-duong', back: 'Chưa đạt → sửa tiếp' },
    ],
    notes: ['Dừng máy ghi trên báo cáo ca cũng vào nhật ký máy; hỏng chưa có phiếu thì MES mở phiếu sửa chữa.'],
  },
  {
    slug: 'bao-duong',
    title: 'Bảo dưỡng định kỳ',
    group: 'Quản lý máy',
    intro: 'Kế hoạch bảo dưỡng theo ngày, giờ chạy, km. MES nhắc trước hạn và giữ chỗ tạm trên lịch máy.',
    steps: [
      { k: 'Nhắc bảo dưỡng đến hạn (nhỏ trước 7 ngày, lớn trước 30 ngày)', who: 'MES', dept: 'MES', time: 'Tự động', out: 'Thông báo; giữ chỗ tạm trên lịch' },
      { k: 'Đề xuất ngày, cách làm (trong ca / gộp lần đổi máy / ngoài giờ) theo gợi ý MES', who: 'TP KT/QA', dept: 'KT', time: 'Trước ngày đến hạn',
        out: 'Đề xuất chờ chốt', at: '/lich-may?tab=baoduong' },
      { k: 'Chốt ngày bảo dưỡng', who: 'TP SX (trong vùng khóa lịch: Giám đốc)', dept: 'SX', time: '24 giờ (đề xuất)', out: 'Lịch máy giữ chỗ bảo dưỡng',
        at: '/lich-may?tab=baoduong', back: 'Trả lại (ghi lý do) → TP KT/QA đề xuất lại' },
      { k: 'Làm bảo dưỡng, ghi phiếu', who: 'Kỹ thuật', dept: 'KT', time: 'Ngày đã chốt', out: 'Phiếu bảo dưỡng Xong', at: '/may/bao-duong' },
      { k: 'Xác nhận máy chạy lại đạt', who: 'TP SX', dept: 'SX', time: 'Sau bảo dưỡng', out: 'Chu kỳ bảo dưỡng tính lại', at: '/may/bao-duong' },
    ],
  },

  // ================================================================ DÙNG CHUNG
  {
    slug: 'duyet-chung-tu',
    title: 'Nhận thông báo, duyệt chứng từ',
    group: 'Dùng chung',
    intro: 'Cách duyệt chung cho mọi chứng từ: kế hoạch, đề xuất mua, đơn mua, spec, lệnh giao, kiểm kê…',
    steps: [
      { k: 'Nhận thông báo (chuông có số đỏ, email)', who: 'Người giữ bước duyệt', dept: 'MES', time: 'Ngay khi được gửi', out: 'Việc trong "Chờ tôi duyệt"', at: '/thong-bao' },
      { k: 'Mở chứng từ, xem nội dung, lịch sử', who: 'Người duyệt', dept: 'BGD', time: '24 giờ', out: '', at: '/duyet' },
      { k: 'Cần thì bấm "Sửa nội dung trước khi duyệt"', who: 'Người duyệt', dept: 'BGD', time: 'Trong hạn', out: 'Sửa ghi vào lịch sử duyệt, báo người lập' },
      { k: 'Duyệt / Trả lại (bắt buộc lý do)', who: 'Người duyệt', dept: 'BGD', time: 'Trong 24 giờ', out: 'Duyệt: sang bước sau; Trả lại: về người lập sửa, gửi lại' },
      { k: 'Quá hạn', who: 'MES', dept: 'MES', time: 'Sau 24 giờ', out: 'Cảnh báo; bước có duyệt thay thì Ban giám đốc duyệt thay' },
    ],
    notes: [
      'Người lập không tự duyệt chứng từ của mình; người đã duyệt bước trước không duyệt tiếp bước sau nếu còn người khác.',
      'Trang Tổng quan có khung "Việc của tôi" liệt kê mọi việc đang chờ bạn.',
    ],
  },
];

export const guideBySlug = (slug: string) => GUIDES.find((g) => g.slug === slug);
