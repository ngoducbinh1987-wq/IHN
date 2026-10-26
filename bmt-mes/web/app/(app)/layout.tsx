import Link from 'next/link';
import { Bell, LogOut } from 'lucide-react';
import { MobileMenu, Sidebar, type NavItem } from '@/components/sidebar';
import { can, requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { ROLE_NAMES } from '@/lib/format';
import { signOut } from '../login/actions';

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const me = await requireMe();
  const supabase = await createClient();
  const [{ count: myTurn }, { count: unread }, { count: maintDue }] = await Promise.all([
    supabase.schema('app').from('v_approvals').select('id', { count: 'exact', head: true }).eq('my_turn', true),
    supabase.schema('app').from('v_notifications').select('id', { count: 'exact', head: true }).is('read_at', null),
    // Việc bảo dưỡng quá hạn chưa có phiếu (chỉ đếm khi có quyền xem máy)
    can(me, 'machine', 'view')
      ? supabase.schema('app').from('v_maint_plans').select('id', { count: 'exact', head: true }).eq('active', true).eq('state', 'OVERDUE').is('open_wo', null)
      : Promise.resolve({ count: 0 }),
  ]);

  const items: NavItem[] = [
    { href: '/', label: 'Tổng quan', icon: 'gauge', group: 'Điều hành' },
    { href: '/dieu-hanh', label: 'Trung tâm điều hành', icon: 'screen', group: 'Điều hành', static: true },
    { href: '/duyet', label: 'Quy trình duyệt', icon: 'check', group: 'Điều hành', badge: myTurn ?? 0 },
    { href: '/thong-bao', label: 'Thông báo', icon: 'bell', group: 'Điều hành', badge: unread ?? 0 },
  ];
  if (can(me, 'purchase', 'view')) items.push({ href: '/de-xuat', label: 'Đề xuất mua hàng', icon: 'cart', group: 'Mua hàng' });
  if (can(me, 'master', 'view')) items.push({ href: '/vat-tu', label: 'Vật tư', icon: 'mat', group: 'Mua hàng' });
  if (can(me, 'plan', 'view')) items.push({ href: '/ke-hoach', label: 'Kế hoạch & MRP', icon: 'plan', group: 'Sản xuất' });
  if (can(me, 'plan', 'view') || can(me, 'production', 'view') || can(me, 'inventory', 'view')) {
    items.push(
      { href: '/lich-may', label: 'Lịch máy', icon: 'calendar', group: 'Sản xuất' },
      { href: '/lenh-ngay', label: 'Lệnh SX ngày', icon: 'order', group: 'Sản xuất' },
      { href: '/ghi-nhan-ca', label: 'Ghi nhận ca', icon: 'shift', group: 'Sản xuất' },
      { href: '/kh-thuc-te', label: 'Kế hoạch – Thực tế', icon: 'chart', group: 'Sản xuất' },
      { href: '/tham-so', label: 'Máy, người & tham số', icon: 'sliders', group: 'Sản xuất' },
    );
  }
  const inv = can(me, 'inventory', 'view');
  const floor = me.roles.some((r) => r === 'VAN_HANH' || r === 'TO_TRUONG');
  const office = me.roles.some((r) => r !== 'VAN_HANH' && r !== 'TO_TRUONG');   // công nhân, tổ trưởng chỉ thấy việc tại máy
  if (inv || can(me, 'production', 'view') || floor) {
    items.push({ href: '/kho', label: 'Tổng quan kho', icon: 'warehouse', group: 'Kho' });
    items.push({ href: '/kho/quet', label: 'Quét mã QR', icon: 'scan', group: 'Kho' });
    items.push({ href: '/kho/cap-phat', label: 'Cấp NVL cho SX', icon: 'issue', group: 'Kho' });
  }
  if (floor) items.push({ href: '/kho/nhan-nvl', label: 'Nhận NVL tại máy', icon: 'receive', group: 'Kho' });
  if (inv && office) {
    items.push({ href: '/kho/ton', label: 'Tồn kho', icon: 'mat', group: 'Kho' });
    items.push({ href: '/kho/phieu', label: 'Phiếu kho', icon: 'spec', group: 'Kho' });
    items.push({ href: '/kho/kiem-ke', label: 'Kiểm kê', icon: 'count', group: 'Kho' });
  }
  if (office && (inv || can(me, 'sales', 'view'))) items.push({ href: '/kho/xuat-ban', label: 'Xuất giao hàng', icon: 'truck', group: 'Kho' });
  if (can(me, 'production', 'view') || inv || can(me, 'cost', 'view')) items.push({ href: '/bao-cao/hao-hut', label: 'Báo cáo hao hụt', icon: 'chart', group: 'Báo cáo' });
  if (inv && office) items.push({ href: '/kho/so-cai', label: 'Nhập – xuất – tồn', icon: 'ledger', group: 'Báo cáo' });
  if (can(me, 'spec', 'view')) items.push({ href: '/san-pham', label: 'Sản phẩm & Spec', icon: 'spec', group: 'Kỹ thuật / QA' });
  if (can(me, 'machine', 'view')) {
    items.push({ href: '/may', label: 'Danh sách máy', icon: 'machine', group: 'Quản lý máy' });
    items.push({ href: '/may/checklist', label: 'Checklist đầu ca', icon: 'checklist', group: 'Quản lý máy' });
    items.push({ href: '/may/bao-duong', label: 'Bảo dưỡng, sửa chữa', icon: 'wrench', group: 'Quản lý máy', badge: maintDue ?? 0 });
    items.push({ href: '/may/toc-do', label: 'Tốc độ sản xuất', icon: 'speed', group: 'Quản lý máy' });
    items.push({ href: '/may/kiem-tra', label: 'Kiểm tra năng lực', icon: 'capacity', group: 'Quản lý máy' });
    items.push({ href: '/may/lich-su', label: 'Lịch sử vận hành', icon: 'history', group: 'Quản lý máy' });
    items.push({ href: '/may/bao-cao', label: 'Báo cáo bảo trì', icon: 'report', group: 'Quản lý máy' });
    if (can(me, 'machine', 'config') || me.roles.includes('BGD')) items.push({ href: '/may/cai-dat', label: 'Cài đặt máy', icon: 'settings', group: 'Quản lý máy' });
  }
  if (can(me, 'admin', 'view')) items.push({ href: '/quan-tri', label: 'Người dùng & quyền', icon: 'users', group: 'Hệ thống' });
  if (can(me, 'admin', 'view')) items.push({ href: '/quan-tri/quy-trinh', label: 'Cài đặt quy trình', icon: 'flow', group: 'Hệ thống' });
  // Công nhân, tổ trưởng (không giữ vai trò văn phòng) chỉ thấy việc tại máy; các trang khác vẫn tự kiểm quyền
  const FLOOR_MENU = ['/', '/thong-bao', '/lenh-ngay', '/ghi-nhan-ca', '/kho/quet', '/kho/nhan-nvl', '/may/checklist', '/may/bao-duong'];
  const LEAD_MENU = ['/duyet', '/lich-may', '/kh-thuc-te', '/kho', '/kho/cap-phat'];
  const menu = floor && !office
    ? items.filter((i) => FLOOR_MENU.includes(i.href) || (me.roles.includes('TO_TRUONG') && LEAD_MENU.includes(i.href)))
    : items;

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
