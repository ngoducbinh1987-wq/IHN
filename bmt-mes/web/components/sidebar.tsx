'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

export type NavItem = { href: string; label: string; code: string; group: string; badge?: number };

export function Sidebar({ items }: { items: NavItem[] }) {
  const path = usePathname();
  const groups = [...new Set(items.map((i) => i.group))];
  return (
    <nav aria-label="Menu chính" className="flex flex-col gap-0.5">
      {groups.map((g) => (
        <div key={g} className="flex flex-col gap-0.5">
          <div className="px-2.5 pb-1 pt-3 text-[10px] font-semibold uppercase tracking-[0.12em] text-[#8EA3B2]">{g}</div>
          {items.filter((i) => i.group === g).map((i) => {
            const on = i.href === '/' ? path === '/' : path.startsWith(i.href);
            return (
              <Link key={i.href} href={i.href}
                className={`flex items-center gap-2.5 rounded-md px-2.5 py-1.5 text-[13px] ${on ? 'bg-[#E9A06E]/20 text-white' : 'text-[#C4D1DA] hover:bg-white/5 hover:text-white'}`}>
                <span className="w-7 font-mono text-[10.5px] opacity-80">{i.code}</span>
                <span className="flex-1">{i.label}</span>
                {!!i.badge && <span className="rounded-full bg-[#E9A06E] px-1.5 text-[11px] font-bold text-[#13202A]">{i.badge}</span>}
              </Link>
            );
          })}
        </div>
      ))}
    </nav>
  );
}
