import { Sidebar, type NavItem } from '@/components/sidebar';
import { can, requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { ROLE_NAMES } from '@/lib/format';
import { signOut } from '../login/actions';

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const me = await requireMe();
  const supabase = await createClient();
  const { count: myTurn } = await supabase.schema('app').from('v_approvals')
    .select('id', { count: 'exact', head: true }).eq('my_turn', true);

  const items: NavItem[] = [
    { href: '/', label: 'Tổng quan', code: '◧', group: 'Điều hành' },
    { href: '/duyet', label: 'Hộp duyệt', code: '✓', group: 'Điều hành', badge: myTurn ?? 0 },
  ];
  if (can(me, 'plan', 'view')) items.push({ href: '/ke-hoach', label: 'Kế hoạch & MRP', code: 'KH', group: 'Sản xuất' });
  if (can(me, 'spec', 'view')) items.push({ href: '/san-pham', label: 'Sản phẩm & Spec', code: 'KT', group: 'Kỹ thuật/QA' });
  if (can(me, 'master', 'view')) items.push({ href: '/vat-tu', label: 'Vật tư', code: 'VT', group: 'Danh mục' });
  if (can(me, 'admin', 'view')) items.push({ href: '/quan-tri', label: 'Người dùng & quyền', code: 'QT', group: 'Hệ thống' });

  const initials = me.full_name.split(' ').filter(Boolean).slice(-2).map((w) => w[0]).join('').toUpperCase();
  return (
    <div className="grid min-h-full md:grid-cols-[220px_minmax(0,1fr)]">
      <aside className="bg-side px-2.5 py-3 md:sticky md:top-0 md:h-screen md:overflow-y-auto md:py-4">
        <div className="hidden px-2.5 pb-2 font-display text-[22px] font-bold tracking-wide text-white md:block">BMT <span className="text-[#E9A06E]">MES</span></div>
        <div className="hidden md:block"><Sidebar items={items} /></div>
        {/* Điện thoại: menu thu gọn */}
        <details className="md:hidden">
          <summary className="flex cursor-pointer list-none items-center justify-between px-2.5 font-display text-[20px] font-bold text-white">
            <span>BMT <span className="text-[#E9A06E]">MES</span></span>
            <span className="font-sans text-[13px] font-semibold text-[#C4D1DA]">Menu ▾</span>
          </summary>
          <Sidebar items={items} />
        </details>
      </aside>
      <div className="flex min-w-0 flex-col">
        <header className="flex items-center justify-end gap-3 border-b border-line bg-surface px-4 py-2.5 md:px-6">
          <div className="text-right text-[12px] leading-tight">
            <div className="font-semibold">{me.full_name}</div>
            <div className="text-muted">{me.roles.map((r) => ROLE_NAMES[r] ?? r).join(', ') || 'Chưa có vai trò'}</div>
          </div>
          <div className="grid h-8 w-8 place-items-center rounded-full bg-copper-soft text-[11px] font-bold text-copper">{initials}</div>
          <form action={signOut}><button className="btn" type="submit">Đăng xuất</button></form>
        </header>
        <main className="min-w-0 flex-1 px-4 py-5 md:px-6">{children}</main>
      </div>
    </div>
  );
}
