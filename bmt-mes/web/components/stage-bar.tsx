import { AlertTriangle } from 'lucide-react';
import { df } from '@/lib/format';

export type Person = { id: string; name: string; title?: string | null };
export type Stage = {
  seq: number; label: string; role?: string; role_name?: string | null; state: 'done' | 'current' | 'todo' | 'rejected';
  actor?: string | null; at?: string | null; approvers?: Person[] | null; sla_hours?: number;
};

const FILL: Record<Stage['state'], string> = {
  done: 'bg-brand text-white',
  current: 'text-white bg-info bg-[repeating-linear-gradient(135deg,rgba(255,255,255,0.18)_0_14px,transparent_14px_28px)]',
  rejected: 'bg-bad text-white',
  todo: 'bg-todo text-ink/70',
};

// Hình mũi tên nối nhau: ô đầu không khuyết bên trái, ô cuối không nhọn bên phải
const clip = (i: number, n: number, notch: number) => {
  const first = i === 0, last = i === n - 1;
  return `polygon(0 0, calc(100% - ${last ? 0 : notch}px) 0, 100% 50%, calc(100% - ${last ? 0 : notch}px) 100%, 0 100%, ${first ? 0 : notch}px 50%)`;
};

// Thanh giai đoạn lớn ở trang chi tiết: tên bước, người đã duyệt / đang giữ
export function StageBar({ stages }: { stages: Stage[] }) {
  return (
    <ol className="flex w-full overflow-x-auto" aria-label="Các giai đoạn duyệt">
      {stages.map((s, i) => {
        const who = s.state === 'done' || s.state === 'rejected'
          ? s.actor
          : (s.approvers ?? []).map((p) => p.name).join(', ') || s.role_name;
        return (
          <li key={s.seq} aria-current={s.state === 'current' ? 'step' : undefined}
            className={`-ml-1.5 flex min-h-[54px] min-w-[132px] flex-1 flex-col justify-center py-1.5 pl-6 pr-5 first:ml-0 first:pl-3 ${FILL[s.state]}`}
            style={{ clipPath: clip(i, stages.length, 14) }}
            title={`${s.label}${s.role_name ? ' · ' + s.role_name : ''}${who ? ' · ' + who : ''}`}>
            <span className="truncate text-[14px] font-medium leading-tight">{s.label}</span>
            <span className="truncate text-[12px] leading-tight opacity-90">
              {s.state === 'done' ? `${s.actor ?? ''}${s.at ? ' · ' + df(s.at, true) : ''}`
                : s.state === 'rejected' ? `Trả lại · ${s.actor ?? ''}`
                : who ?? ''}
            </span>
          </li>
        );
      })}
    </ol>
  );
}

// Thanh giai đoạn nhỏ trong danh sách + dòng "[3/4] Tên bước"
export function StageMini({ stages, index, total, label, overdue }:
  { stages: Stage[]; index: number; total: number; label?: string | null; overdue?: boolean }) {
  return (
    <div className="min-w-[200px]">
      <div className="flex h-[18px]" aria-hidden>
        {stages.map((s, i) => (
          <span key={s.seq} className={`-ml-[3px] h-full flex-1 first:ml-0 ${FILL[s.state]}`} style={{ clipPath: clip(i, stages.length, 6) }} />
        ))}
      </div>
      {label && (
        <div className="mt-1 flex items-start gap-1 text-[13.5px] leading-snug">
          {overdue && <AlertTriangle size={15} className="mt-0.5 shrink-0 text-bad" aria-label="Quá hạn" />}
          <span>[{index}/{total}] {label}</span>
        </div>
      )}
    </div>
  );
}
