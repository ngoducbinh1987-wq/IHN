'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useState } from 'react';
import {
  BarChart3, Bell, BookOpen, Boxes, CalendarRange, CheckSquare, ClipboardCheck, ClipboardList, Cog, Factory, FileBarChart, FileText, Gauge,
  History, Monitor, PackageCheck, PackageMinus, ScanLine, Search, Settings, ShoppingCart, SlidersHorizontal, Timer, Truck, Users, Warehouse,
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

export function Sidebar({ items, onNavigate }: { items: NavItem[]; onNavigate?: () => void }) {
  const path = usePathname();
  const [q, setQ] = useState('');
  const shown = items.filter((i) => !q || i.label.toLowerCase().includes(q.toLowerCase()));
  const groups = [...new Set(shown.map((i) => i.group))];
  return (
    <div className="flex flex-col">
      <div className="relative mx-2.5 mb-2">
        <Search size={15} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-side-ink/60" />
        <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Tìm kiếm chức năng" aria-label="Tìm kiếm chức năng"
          className="w-full rounded bg-white/10 py-2.5 pl-9 pr-3 text-[14px] text-white placeholder:text-side-ink/60 focus:bg-white/15 focus:outline-none" />
      </div>
      <nav aria-label="Menu chính" className="flex flex-col">
        {groups.map((g) => (
          <div key={g} className="flex flex-col">
            <div className="px-5 pb-1 pt-4 text-[11.5px] font-medium uppercase tracking-wider text-side-ink/55">{g}</div>
            {shown.filter((i) => i.group === g).map((i) => {
              const on = i.href === '/' ? path === '/' : path.startsWith(i.href) && !shown.some((o) => o.href.length > i.href.length && o.href.startsWith(i.href) && path.startsWith(o.href));
              const Icon = ICONS[i.icon as keyof typeof ICONS] ?? FileText;
              const cls = `flex items-center gap-3 border-l-4 px-4 py-3 text-[15px] ${on ? 'border-brand bg-side-2 text-white' : 'border-transparent text-side-ink hover:bg-white/5 hover:text-white'}`;
              const inner = (
                <>
                  <Icon size={18} className="shrink-0" />
                  <span className="flex-1">{i.label}</span>
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
        ))}
      </nav>
    </div>
  );
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
