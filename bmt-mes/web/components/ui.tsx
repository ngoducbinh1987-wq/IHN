import type { ReactNode } from 'react';
import type { Tone } from '@/lib/format';

const TONE: Record<Tone, string> = {
  ok: 'bg-ok-soft text-ok', warn: 'bg-warn-soft text-warn', bad: 'bg-bad-soft text-bad',
  info: 'bg-info-soft text-info', mute: 'bg-sunk text-muted', cu: 'bg-copper-soft text-copper',
};

export function Pill({ tone = 'mute', children }: { tone?: Tone; children: ReactNode }) {
  return <span className={`inline-block whitespace-nowrap rounded-full px-2 py-px text-[11.5px] font-semibold leading-5 ${TONE[tone]}`}>{children}</span>;
}

export function StatusPill({ map, value }: { map: Record<string, [string, Tone]>; value: string | null | undefined }) {
  if (!value) return <Pill>—</Pill>;
  const [label, tone] = map[value] ?? [value, 'mute' as Tone];
  return <Pill tone={tone}>{label}</Pill>;
}

export function PageHeader({ title, sub, actions }: { title: string; sub?: ReactNode; actions?: ReactNode }) {
  return (
    <div className="mb-4 flex flex-wrap items-end justify-between gap-3">
      <div className="min-w-0">
        <h1 className="font-display text-[28px] font-bold leading-tight text-balance">{title}</h1>
        {sub && <div className="mt-0.5 text-[13px] text-muted">{sub}</div>}
      </div>
      {actions && <div className="flex flex-wrap items-center gap-2">{actions}</div>}
    </div>
  );
}

// Thông báo kết quả sau thao tác (?ok=… / ?err=…)
export function Flash({ ok, err }: { ok?: string; err?: string }) {
  if (!ok && !err) return null;
  return (
    <div role="status" className={`mb-4 rounded-md border px-4 py-2.5 text-[13px] ${err ? 'border-bad/40 bg-bad-soft text-bad' : 'border-ok/40 bg-ok-soft text-ok'}`}>
      {err ?? ok}
    </div>
  );
}

export function Kpi({ label, value, hint, tone }: { label: string; value: ReactNode; hint?: ReactNode; tone?: 'bad' | 'warn' | 'ok' | 'cu' }) {
  const color = tone === 'bad' ? 'text-bad' : tone === 'warn' ? 'text-warn' : tone === 'ok' ? 'text-ok' : tone === 'cu' ? 'text-copper' : '';
  return (
    <div className="card px-4 py-3">
      <div className="text-[11px] uppercase tracking-wider text-muted">{label}</div>
      <div className={`font-display text-[30px] font-bold leading-tight tabular-nums ${color}`}>{value}</div>
      {hint && <div className="text-[12px] text-muted">{hint}</div>}
    </div>
  );
}

export function Empty({ children }: { children: ReactNode }) {
  return <div className="px-4 py-10 text-center text-[13px] text-muted">{children}</div>;
}
