'use client';

import Link, { useLinkStatus } from 'next/link';
import { usePathname } from 'next/navigation';
import { useEffect, useState } from 'react';
import {
  BarChart3, Bell, BookOpen, Boxes, CalendarRange, CheckSquare, ChevronDown, ClipboardCheck, ClipboardList, Cog, Factory, FileBarChart, FileText, Gauge,
  History, Loader2, Monitor, PackageCheck, PackageMinus, ScanLine, Search, Settings, ShoppingCart, SlidersHorizontal, Timer, Truck, Users, Warehouse,
  Workflow, Wrench,
} from 'lucide-react';

export type NavItem = { href: string; label: string; icon: string; group: string; badge?: number; static?: boolean };

const ICONS = {
  gauge: Gauge, check: CheckSquare, bell: Bell, plan: ClipboardList, spec: FileText, mat: Boxes,
  cart: ShoppingCart, users: Users, factory: Factory, flow: Workflow, screen: Monitor,
  warehouse: Warehouse, scan: ScanLine, issue: PackageMinus, receive: PackageCheck, count: ClipboardCheck, truck: Truck, chart: BarChart3, ledger: BookOpen,
  machine: Cog, wrench: Wrench, checklist: ClipboardCheck, speed: Timer, capacity: BarChart3, history: History,
  report: FileBarChart, settings: Settings,
  calendar: CalendarRange, order: ClipboardCheck, shift: Timer, sliders: SlidersHorizontal,
} as const;

// Biểu tượng của nhóm menu (hiện ở dòng nhóm khi thu gọn)
const GROUP_ICONS: Record<string, keyof typeof ICONS> = {
  'Điều hành': 'gauge', 'Mua hàng': 'cart', 'Sản xuất': 'factory', Kho: 'warehouse', 'Báo cáo': 'report',
  'Kỹ thuật / QA': 'checklist', 'Quản lý máy': 'machine', 'Hệ thống & cài đặt': 'settings',
};
const OPEN_KEY = 'bmt-menu-open';

// Mục đang mở: trang trùng href dài nhất (vd. /de-xuat/du-phong không làm sáng /de-xuat)
function isOn(i: NavItem, items: NavItem[], path: string) {
  if (i.href === '/') return path === '/';
  return path.startsWith(i.href) && !items.some((o) => o.href.length > i.href.length && o.href.startsWith(i.href) && path.startsWith(o.href));
}

export function Sidebar({ items, onNavigate }: { items: NavItem[]; onNavigate?: () => void }) {
  const path = usePathname();
  const [q, setQ] = useState('');
  const current = items.find((i) => isOn(i, items, path))?.group;
  // Menu thu gọn theo nhóm: bấm tên nhóm để thả xuống; nhóm của trang đang xem tự mở; nhớ nhóm đã mở trên máy này
  const [open, setOpen] = useState<string[]>(current ? [current] : []);
  useEffect(() => {
    try {
      const saved = JSON.parse(localStorage.getItem(OPEN_KEY) ?? '[]');
      if (Array.isArray(saved)) setOpen((o) => [...new Set([...saved, ...o])]);
    } catch { /* trình duyệt chặn lưu: chỉ mở nhóm hiện tại */ }
  }, []);
  useEffect(() => { if (current) setOpen((o) => (o.includes(current) ? o : [...o, current])); }, [current]);
  const toggle = (g: string) => setOpen((o) => {
    const next = o.includes(g) ? o.filter((x) => x !== g) : [...o, g];
    try { localStorage.setItem(OPEN_KEY, JSON.stringify(next)); } catch { /* bỏ qua */ }
    return next;
  });

  const shown = items.filter((i) => !q || i.label.toLowerCase().includes(q.toLowerCase()));
  const groups = [...new Set(shown.map((i) => i.group))];
  return (
    <div className="flex flex-col">
      <div className="relative mx-2.5 mb-2">
        <Search size={15} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-side-ink/60" />
        <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Tìm kiếm chức năng" aria-label="Tìm kiếm chức năng"
          className="w-full rounded bg-white/10 py-2.5 pl-9 pr-3 text-[14px] text-white placeholder:text-side-ink/60 focus:bg-white/15 focus:outline-none" />
      </div>
      <nav aria-label="Menu chính" className="flex flex-col pb-3">
        {groups.map((g, gi) => {
          const list = shown.filter((i) => i.group === g);
          // Đang tìm kiếm thì mở mọi nhóm có kết quả
          const expanded = !!q || open.includes(g);
          const total = list.reduce((s, i) => s + (i.badge ?? 0), 0);
          const GIcon = ICONS[GROUP_ICONS[g] ?? 'spec'];
          const id = `menu-nhom-${gi}`;
          const here = g === current;
          return (
            <div key={g} className="flex flex-col" data-group={g}>
              <button type="button" onClick={() => toggle(g)} aria-expanded={expanded} aria-controls={id}
                aria-label={`${g}${!expanded && total ? `, ${total} việc` : ''}`}
                className={`flex items-center gap-3 border-l-4 px-4 py-3 text-left text-[15px] font-medium ${here && !expanded ? 'border-brand bg-side-2 text-white' : 'border-transparent text-white/90 hover:bg-white/5 hover:text-white'}`}>
                <GIcon size={18} className="shrink-0" />
                <span className="flex-1">{g}</span>
                {!expanded && total > 0 && <span className="rounded-full bg-bad px-2 text-[12px] font-medium text-white">{total}</span>}
                <ChevronDown size={16} className={`shrink-0 text-side-ink/70 transition-transform ${expanded ? 'rotate-180' : ''}`} />
              </button>
              {/* Mục con vẫn có trong trang khi thu gọn (ẩn) để tìm kiếm của trình duyệt, trình đọc màn hình không mất mục */}
              <div id={id} hidden={!expanded} className={expanded ? 'flex flex-col pb-1' : 'hidden'}>
                {list.map((i) => {
                  const on = isOn(i, items, path);
                  const Icon = ICONS[i.icon as keyof typeof ICONS] ?? FileText;
                  const cls = `flex items-center gap-3 border-l-4 py-2.5 pl-8 pr-4 text-[14.5px] ${on ? 'border-brand bg-side-2 text-white' : 'border-transparent text-side-ink hover:bg-white/5 hover:text-white'}`;
                  const inner = (
                    <>
                      <Icon size={16} className="shrink-0" />
                      <span className="flex-1">{i.label}</span>
                      {!i.static && <LinkPending />}
                      {!!i.badge && <span className="rounded-full bg-bad px-2 text-[12px] font-medium text-white">{i.badge}</span>}
                    </>
                  );
                  // Trang tĩnh (không thuộc app router) mở bằng liên kết thường
                  return i.static ? (
                    <a key={i.href} href={i.href} onClick={onNavigate} className={cls}>{inner}</a>
                  ) : (
                    <Link key={i.href} href={i.href} onClick={onNavigate} aria-current={on ? 'page' : undefined} className={cls}>{inner}</Link>
                  );
                })}
              </div>
            </div>
          );
        })}
      </nav>
    </div>
  );
}

// Vòng xoay trên mục vừa bấm trong lúc máy chủ chuẩn bị trang (thay cho loading.tsx: loading.tsx làm treo chuyển trang sau server action)
function LinkPending() {
  const { pending } = useLinkStatus();
  return pending ? <Loader2 size={15} className="shrink-0 animate-spin" aria-label="Đang tải" /> : null;
}

// Điện thoại / máy tính bảng dọc: menu trượt từ trái
export function MobileMenu({ items }: { items: NavItem[] }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="lg:hidden">
      <button type="button" className="btn btn-sm" onClick={() => setOpen(true)} aria-expanded={open}>☰ Menu</button>
      {open && (
        <div className="fixed inset-0 z-40 flex" role="dialog" aria-label="Menu">
          <div className="w-[270px] max-w-[85vw] overflow-y-auto bg-side py-3">
            <Sidebar items={items} onNavigate={() => setOpen(false)} />
          </div>
          <button type="button" className="flex-1 bg-black/40" aria-label="Đóng menu" onClick={() => setOpen(false)} />
        </div>
      )}
    </div>
  );
}
