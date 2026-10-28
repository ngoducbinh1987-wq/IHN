import Link from 'next/link';
import { Bell, LogOut } from 'lucide-react';
import { MobileMenu, Sidebar, type NavItem } from '@/components/sidebar';
import { can, canPage, requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { ROLE_NAMES } from '@/lib/format';
import { signOut } from '../login/actions';
import { after } from 'next/server';
import { replanDue } from '@/lib/kh/replan';

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient();
  // Hồ sơ người dùng và các số đếm trên menu chạy song song (một lượt hỏi database thay vì hai)
  const [me, { count: myTurn }, { count: unread }, { count: maintAll }, { count: qcWait }, { data: safetyBelow }, { count: poDraft }] = await Promise.all([
    requireMe(),
    supabase.schema('app').from('v_approvals').select('id', { count: 'exact', head: true }).eq('my_turn', true),
    supabase.schema('app').from('v_notifications').select('id', { count: 'exact', head: true }).is('read_at', null),
    // Việc bảo dưỡng quá hạn chưa có phiếu (RLS chỉ trả dòng cho người có quyền xem máy)
    supabase.schema('app').from('v_maint_plans').select('id', { count: 'exact', head: true }).eq('active', true).eq('state', 'OVERDUE').is('open_wo', null),
    // Bobin, lô chờ QC (RLS: chỉ người xem được kho)
    supabase.schema('inv').from('lots').select('id', { count: 'exact', head: true }).eq('qc_status', 'PENDING'),
    // Vật tư dưới mức tồn dự phòng (hàm tự kiểm quyền mua hàng / kho / Ban giám đốc)
    supabase.schema('app').rpc('safety_below_count'),
    // Đơn mua MES tự sinh chờ NV mua kiểm tra (RLS: người xem được mua hàng)
    supabase.schema('purchase').from('purchase_orders').select('id', { count: 'exact', head: true }).eq('status', 'DRAFT'),
  ]);
  // Tính lại tiến độ sau ca: 1 giờ sau khi hết ca, lần đầu TP SX / Kế hoạch SX / Giám đốc mở MES thì MES tính (sau khi trả trang,
  // không làm chậm trang); job máy chủ bmt_replan làm việc này khi đã cấu hình CRON_SECRET + khóa máy chủ
  if (me.roles.some((r) => ['SX_TP', 'SX_KH', 'BGD', 'ADMIN'].includes(r))) {
    after(async () => { try { await replanDue(supabase, me.roles); } catch { /* lần sau thử lại */ } });
  }
  const buyer = me.roles.includes('MUA_NV') || me.roles.includes('MUA_TP');
  const maintDue = can(me, 'machine', 'view') ? maintAll : 0;

  // Menu theo bộ phận: mục nào hiện do Quản trị tick ở Hệ thống → Phân quyền (core.role_pages); trang tự kiểm lại (requirePage)
  const items: NavItem[] = [
    { href: '/', label: 'Tổng quan', icon: 'gauge', group: 'Điều hành' },
    { href: '/dieu-hanh', label: 'Trung tâm điều hành', icon: 'screen', group: 'Điều hành', static: true },
    { href: '/duyet', label: 'Quy trình duyệt', icon: 'check', group: 'Điều hành', badge: myTurn ?? 0 },
  ];
  const PAGES: (NavItem & { key: string })[] = [
    { key: 'de-xuat', href: '/de-xuat', label: 'Đề xuất mua hàng', icon: 'cart', group: 'Mua hàng' },
    { key: 'don-mua', href: '/don-mua', label: 'Đơn mua hàng', icon: 'receive', group: 'Mua hàng', badge: buyer ? poDraft ?? 0 : 0 },
    { key: 'du-phong', href: '/de-xuat/du-phong', label: 'Tồn dự phòng', icon: 'warehouse', group: 'Mua hàng', badge: Number(safetyBelow ?? 0) },
    { key: 'vat-tu', href: '/vat-tu', label: 'Vật tư', icon: 'mat', group: 'Mua hàng' },
    { key: 'ke-hoach', href: '/ke-hoach', label: 'Kế hoạch & MRP', icon: 'plan', group: 'Sản xuất' },
    { key: 'dieu-chinh', href: '/ke-hoach/dieu-chinh', label: 'Điều chỉnh kế hoạch tháng', icon: 'flow', group: 'Sản xuất' },
    { key: 'kh-chung', href: '/kh-thuc-te', label: 'Kế hoạch sản xuất chung', icon: 'chart', group: 'Sản xuất' },
    { key: 'lich-may', href: '/lich-may', label: 'Lịch máy', icon: 'calendar', group: 'Sản xuất' },
    { key: 'lenh-ngay', href: '/lenh-ngay', label: 'Lệnh SX ngày', icon: 'order', group: 'Sản xuất' },
    { key: 'ghi-nhan-ca', href: '/ghi-nhan-ca', label: 'Ghi nhận ca', icon: 'shift', group: 'Sản xuất' },
    { key: 'phieu-hoan-thanh', href: '/phieu-hoan-thanh', label: 'Phiếu hoàn thành bobin', icon: 'checklist', group: 'Sản xuất' },
    { key: 'phieu-xuat-nvl', href: '/phieu-xuat-nvl', label: 'Phiếu xuất NVL, NVL thừa', icon: 'issue', group: 'Sản xuất' },
    { key: 'nhan-su-xuong', href: '/nhan-su-xuong', label: 'Nhân sự xưởng', icon: 'users', group: 'Sản xuất' },
    // Thông báo không có trên menu: chuông có số trên đầu trang. Checklist đầu ca (công nhân dùng giấy) mở từ Bảo dưỡng, Danh sách máy.
    // Quy trình final: xuất NVL bằng phiếu giấy, công nhân không dùng điện thoại → Quét mã QR, Cấp NVL, Nhận NVL tại máy
    // không có trên menu (trang vẫn còn, mở từ đường dẫn mã tem)
    { key: 'kho', href: '/kho', label: 'Tổng quan kho', icon: 'warehouse', group: 'Kho' },
    { key: 'kho-ton', href: '/kho/ton', label: 'Tồn kho', icon: 'mat', group: 'Kho' },
    { key: 'kho-phieu', href: '/kho/phieu', label: 'Phiếu kho', icon: 'spec', group: 'Kho' },
    { key: 'kho-kiem-ke', href: '/kho/kiem-ke', label: 'Kiểm kê', icon: 'count', group: 'Kho' },
    { key: 'kho-xuat-ban', href: '/kho/xuat-ban', label: 'Xuất giao hàng', icon: 'truck', group: 'Kho' },
    { key: 'bc-ngay', href: '/bao-cao/ngay', label: 'Báo cáo sản xuất ngày', icon: 'report', group: 'Báo cáo' },
    { key: 'bc-hao-hut', href: '/bao-cao/hao-hut', label: 'Báo cáo hao hụt', icon: 'chart', group: 'Báo cáo' },
    { key: 'kho-so-cai', href: '/kho/so-cai', label: 'Nhập – xuất – tồn', icon: 'ledger', group: 'Báo cáo' },
    { key: 'may-lich-su', href: '/may/lich-su', label: 'Lịch sử vận hành', icon: 'history', group: 'Báo cáo' },
    { key: 'may-bao-cao', href: '/may/bao-cao', label: 'Báo cáo bảo trì', icon: 'report', group: 'Báo cáo' },
    { key: 'san-pham', href: '/san-pham', label: 'Sản phẩm & Spec', icon: 'spec', group: 'Kỹ thuật / QA' },
    { key: 'kho-qc', href: '/kho/qc', label: 'QC bobin, lô hàng', icon: 'checklist', group: 'Kỹ thuật / QA', badge: qcWait ?? 0 },
    { key: 'may-toc-do', href: '/may/toc-do', label: 'Tốc độ sản xuất', icon: 'speed', group: 'Kỹ thuật / QA' },
    { key: 'may', href: '/may', label: 'Danh sách máy', icon: 'machine', group: 'Quản lý máy' },
    { key: 'may-bao-duong', href: '/may/bao-duong', label: 'Bảo dưỡng, sửa chữa', icon: 'wrench', group: 'Quản lý máy', badge: maintDue ?? 0 },
    { key: 'quan-tri', href: '/quan-tri', label: 'Người dùng', icon: 'users', group: 'Hệ thống & cài đặt' },
    { key: 'quan-tri-quy-trinh', href: '/quan-tri/quy-trinh', label: 'Cài đặt quy trình', icon: 'flow', group: 'Hệ thống & cài đặt' },
    { key: 'tham-so', href: '/tham-so', label: 'Tham số xếp lịch', icon: 'sliders', group: 'Hệ thống & cài đặt' },
    { key: 'may-cai-dat', href: '/may/cai-dat', label: 'Cài đặt máy', icon: 'settings', group: 'Hệ thống & cài đặt' },
  ];
  for (const { key, ...it } of PAGES) if (canPage(me, key)) items.push(it);
  // Ô tick phân quyền: chỉ Quản trị hệ thống thấy
  if (me.is_admin) items.push({ href: '/quan-tri/phan-quyen', label: 'Phân quyền', icon: 'users', group: 'Hệ thống & cài đặt' });
  const menu = items;

  const initials = me.full_name.split(' ').filter(Boolean).slice(-2).map((w) => w[0]).join('').toUpperCase();
  const delegated = (me.delegated_roles ?? []).map((d) => d.split(':')[0]);
  const roleText = me.roles.map((r) => (ROLE_NAMES[r] ?? r) + (delegated.includes(r) ? ' (ủy quyền)' : '')).join(', ') || 'Chưa có vai trò';
  return (
    <div className="min-h-full lg:grid lg:grid-cols-[250px_minmax(0,1fr)]">
      <aside className="hidden bg-side print:!hidden lg:sticky lg:top-0 lg:block lg:h-screen lg:overflow-y-auto">
        <Link href="/" className="flex items-center gap-3 px-4 py-3.5">
          <span className="rounded bg-white px-2 py-1.5"><img src="/logo-bmt.png" alt="BMTcable" className="h-6 w-auto" /></span>
          <span className="text-[19px] font-medium text-white">MES</span>
        </Link>
        <Sidebar items={menu} />
      </aside>
      <div className="flex min-w-0 flex-col">
        <header className="sticky top-0 z-30 flex print:hidden h-14 items-center gap-3 border-b border-line bg-surface px-4 md:px-5">
          <MobileMenu items={menu} />
          <Link href="/" className="lg:hidden"><img src="/logo-bmt.png" alt="BMTcable" className="h-6 w-auto" /></Link>
          <div className="ml-auto flex items-center gap-2">
            <Link href="/thong-bao" className="relative rounded-full p-2 text-brand hover:bg-brand-soft" aria-label={`Thông báo, ${unread ?? 0} chưa đọc`}>
              <Bell size={22} />
              {!!unread && <span className="absolute -right-0.5 -top-0.5 min-w-[18px] rounded-full bg-bad px-1 text-center text-[11px] font-medium leading-[18px] text-white">{unread}</span>}
            </Link>
            <details className="relative">
              <summary className="flex cursor-pointer list-none items-center gap-2 rounded px-1.5 py-1 hover:bg-sunk">
                <span className="grid h-9 w-9 place-items-center rounded-full bg-brand text-[13px] font-medium text-white">{initials}</span>
                <span className="hidden text-left leading-tight sm:block">
                  <span className="block text-[14px] font-medium uppercase">{me.full_name}</span>
                  <span className="block max-w-[220px] truncate text-[12px] text-muted">{roleText}</span>
                </span>
              </summary>
              <div className="absolute right-0 mt-1 w-64 rounded border border-line bg-surface p-3 shadow-lg">
                <div className="text-[14px] font-medium">{me.full_name}</div>
                <div className="mb-2 text-[12.5px] text-muted">{me.email}</div>
                <div className="mb-3 text-[12.5px] text-muted">{roleText}</div>
                <form action={signOut}><button className="btn w-full" type="submit"><LogOut size={15} />Đăng xuất</button></form>
              </div>
            </details>
          </div>
        </header>
        <main className="min-w-0 flex-1 p-4 md:p-5 print:p-0">{children}</main>
      </div>
    </div>
  );
}
