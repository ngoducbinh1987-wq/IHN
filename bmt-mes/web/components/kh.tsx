// Thành phần dùng chung cho module Kế hoạch sản xuất
import Link from 'next/link';
import { Lock } from 'lucide-react';
import type { ReactNode } from 'react';
import { Pill } from '@/components/ui';
import { colorHex } from '@/lib/kh/scheduler';

const WD = ['CN', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7'];
const WDL = ['Chủ nhật', 'Thứ 2', 'Thứ 3', 'Thứ 4', 'Thứ 5', 'Thứ 6', 'Thứ 7'];
export const dd = (d: string | null | undefined) => (d ? `${d.slice(8, 10)}/${d.slice(5, 7)}` : '—');
export const wd = (d: string) => WD[new Date(d + 'T00:00:00Z').getUTCDay()];
export const wdl = (d: string) => WDL[new Date(d + 'T00:00:00Z').getUTCDay()];
export const pc = (v: number) => `${Math.round(v * 100)}%`;

export function FinishPill({ finDate, slack, due, placed }: { finDate: string | null; slack: number | null; due: string | null; placed: boolean }) {
  if (!placed) return <Pill tone="bad">Chưa xếp được</Pill>;
  if (!finDate) return <Pill tone="bad">Xong ngoài tầm lịch</Pill>;
  if (!due) return <Pill tone="info">Chưa có hạn giao</Pill>;
  if (slack !== null && slack < 0) return <Pill tone="bad">Trễ {-slack} ngày</Pill>;
  if (slack !== null && slack <= 1) return <Pill tone="warn">Sát hạn</Pill>;
  return <Pill tone="ok">Kịp hạn</Pill>;
}

export function Swatch({ color }: { color: string | null | undefined }) {
  if (!color) return null;
  return <span className="mr-1 inline-block h-3 w-3 rounded-sm border border-ink/25 align-[-1px]" style={{ background: colorHex(color) }} aria-hidden />;
}

export function LockNote({ children }: { children: ReactNode }) {
  return <span className="inline-flex items-center gap-1.5 text-[13px] text-muted"><Lock size={14} />{children}</span>;
}

export function Alert({ tone = 'info', title, children, action }: { tone?: 'info' | 'warn' | 'bad' | 'ok'; title?: ReactNode; children?: ReactNode; action?: ReactNode }) {
  const cls = { info: 'border-info bg-info-soft', warn: 'border-warn bg-warn-soft', bad: 'border-bad bg-bad-soft', ok: 'border-brand bg-brand-soft' }[tone];
  return (
    <div className={`mb-4 flex flex-wrap items-center gap-3 rounded border-l-4 px-4 py-2.5 text-[14px] ${cls}`}>
      <div className="min-w-0 flex-1">{title && <div className="font-medium">{title}</div>}{children}</div>
      {action}
    </div>
  );
}

export function Bar({ value, mark = 0.85 }: { value: number; mark?: number }) {
  const tone = value >= 1 ? 'bg-bad' : value >= mark ? 'bg-warn' : 'bg-brand';
  return (
    <div className="flex items-center gap-2">
      <div className="relative h-2.5 flex-1 overflow-hidden rounded bg-todo">
        <i className={`absolute inset-y-0 left-0 ${tone}`} style={{ width: `${Math.min(100, value * 100)}%` }} />
        <span className="absolute inset-y-0 w-px bg-ink/50" style={{ left: `${mark * 100}%` }} />
      </div>
      <b className="w-11 text-right tabular-nums">{pc(value)}</b>
    </div>
  );
}

// Thẻ chuyển trang con của module (dạng gạch chân)
export function SubTabs({ items, active }: { items: { key: string; label: string; href: string }[]; active: string }) {
  return (
    <nav className="mb-4 flex gap-1 overflow-x-auto border-b border-line" aria-label="Mục">
      {items.map((t) => (
        <Link key={t.key} href={t.href} scroll={false} aria-current={t.key === active ? 'page' : undefined}
          className={`-mb-px whitespace-nowrap border-b-[3px] px-3 py-2.5 text-[14.5px] ${t.key === active ? 'border-brand text-brand' : 'border-transparent text-ink/80 hover:text-brand'}`}>
          {t.label}
        </Link>
      ))}
    </nav>
  );
}

export const GROUP_BG: Record<string, string> = {
  PFR: '#e8f3ec', CFR: '#e6effc', CTL: '#f6ecdc', SFR: '#efe7f7', SIF: '#fbe9ea', PVC: '#eef0f2',
};
export const GROUP_BORDER: Record<string, string> = {
  PFR: '#059b42', CFR: '#1a5fd0', CTL: '#c27a12', SFR: '#7b4bb3', SIF: '#d93025', PVC: '#68717a',
};
export const GROUP_NAME: Record<string, string> = {
  PFR: 'Cáp điện chống cháy', CFR: 'Điều khiển chống cháy', CTL: 'Điều khiển chống nhiễu', SFR: 'Tín hiệu chống cháy chống nhiễu', SIF: 'Dây đơn chống cháy', PVC: 'Dây PVC',
};
