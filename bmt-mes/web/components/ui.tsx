import Link from 'next/link';
import type { ReactNode } from 'react';
import { Plus, RotateCw, Search } from 'lucide-react';
import type { Tone } from '@/lib/format';

const TONE: Record<Tone, string> = {
  ok: 'bg-brand text-white', warn: 'bg-warn text-white', bad: 'bg-bad text-white',
  info: 'bg-info text-white', mute: 'bg-todo text-ink/70', cu: 'bg-brand-soft text-brand-dark',
};

export function Pill({ tone = 'mute', children }: { tone?: Tone; children: ReactNode }) {
  return <span className={`inline-block whitespace-nowrap rounded px-2 py-0.5 text-[12px] font-medium leading-5 ${TONE[tone]}`}>{children}</span>;
}

export function StatusPill({ map, value }: { map: Record<string, [string, Tone]>; value: string | null | undefined }) {
  if (!value) return <Pill>—</Pill>;
  const [label, tone] = map[value] ?? [value, 'mute' as Tone];
  return <Pill tone={tone}>{label}</Pill>;
}

// Thanh công cụ đầu trang kiểu Fastcon: tiêu đề · Tải lại · ô tìm kiếm · + Thêm mới · tiện ích
export function Toolbar({ title, reload, search, add, actions, hidden }: {
  title: ReactNode;
  reload?: string;
  search?: { placeholder: string; value?: string; name?: string };
  add?: { href: string; label: string };
  actions?: ReactNode;
  hidden?: Record<string, string | undefined>;
}) {
  return (
    <div className="-mx-4 -mt-4 mb-0 flex flex-wrap items-center gap-2 border-b border-line bg-surface px-4 py-2.5 md:-mx-5 md:-mt-5 md:px-5">
      <h1 className="mr-auto min-w-0 truncate text-[22px] font-normal leading-tight">{title}</h1>
      {reload && <Link href={reload} className="btn border-[#BFE7DA] bg-[#E3F6EF] text-brand-dark hover:bg-[#D3F0E5]"><RotateCw size={15} />Tải lại</Link>}
      {search && (
        <form role="search" className="relative w-full sm:w-72">
          {Object.entries(hidden ?? {}).map(([k, v]) => v ? <input key={k} type="hidden" name={k} value={v} /> : null)}
          <Search size={16} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-muted" />
          <input className="inp pl-9" name={search.name ?? 'q'} defaultValue={search.value} placeholder={search.placeholder} aria-label={search.placeholder} />
        </form>
      )}
      {add && <Link href={add.href} className="btn btn-pri"><Plus size={16} strokeWidth={2.5} />{add.label}</Link>}
      {actions}
    </div>
  );
}

// Thẻ lọc dạng gạch chân (Đang thực hiện / Đã thực hiện / Tất cả)
export function Tabs({ items, active }: { items: { key: string; label: string; href: string; count?: number }[]; active: string }) {
  return (
    <nav className="-mx-4 mb-4 flex gap-1 overflow-x-auto border-b border-line bg-surface px-4 md:-mx-5 md:px-5" aria-label="Lọc">
      {items.map((t) => (
        <Link key={t.key} href={t.href} aria-current={t.key === active ? 'page' : undefined}
          className={`-mb-px whitespace-nowrap border-b-[3px] px-3 py-3 text-[15px] ${t.key === active ? 'border-brand text-brand' : 'border-transparent text-ink/80 hover:text-brand'}`}>
          {t.label}{t.count !== undefined && <span className={`ml-1.5 rounded-full px-1.5 text-[12px] ${t.key === active ? 'bg-brand text-white' : 'bg-todo'}`}>{t.count}</span>}
        </Link>
      ))}
    </nav>
  );
}

// Thông báo kết quả sau thao tác (?ok=… / ?err=…)
export function Flash({ ok, err }: { ok?: string; err?: string }) {
  if (!ok && !err) return null;
  return (
    <div role="status" className={`mb-4 rounded border-l-4 px-4 py-2.5 text-[14px] ${err ? 'border-bad bg-bad-soft text-bad' : 'border-brand bg-brand-soft text-brand-dark'}`}>
      {err ?? ok}
    </div>
  );
}

export function Kpi({ label, value, hint, tone, href }: { label: string; value: ReactNode; hint?: ReactNode; tone?: 'bad' | 'warn' | 'ok' | 'info'; href?: string }) {
  const bar = tone === 'bad' ? 'border-l-bad' : tone === 'warn' ? 'border-l-warn' : tone === 'info' ? 'border-l-info' : 'border-l-brand';
  const body = (
    <>
      <div className="text-[13px] text-muted">{label}</div>
      <div className="text-[28px] font-medium leading-tight tabular-nums">{value}</div>
      {hint && <div className="text-[12.5px] text-muted">{hint}</div>}
    </>
  );
  return href
    ? <Link href={href} className={`card block border-l-4 px-4 py-3 hover:bg-sunk/60 ${bar}`}>{body}</Link>
    : <div className={`card border-l-4 px-4 py-3 ${bar}`}>{body}</div>;
}

export function Empty({ children }: { children: ReactNode }) {
  return <div className="px-4 py-10 text-center text-[14px] text-muted">{children}</div>;
}

// Dòng thông tin dạng nhãn: giá trị (khung bên phải trang chi tiết)
export function InfoRow({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="grid grid-cols-[130px_1fr] gap-2 py-2 text-[14px]">
      <div className="text-ink/80">{label}:</div>
      <div className="min-w-0 text-brand">{children}</div>
    </div>
  );
}

export function Section({ title, right, children, className = '' }: { title: ReactNode; right?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <section className={`card ${className}`}>
      <div className="card-h"><h2>{title}</h2>{right}</div>
      {children}
    </section>
  );
}
