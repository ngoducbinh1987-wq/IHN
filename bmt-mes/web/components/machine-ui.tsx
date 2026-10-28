import Link from 'next/link';
import { Pill, StatusPill } from '@/components/ui';
import { SubmitButton } from '@/components/submit-button';
import { M_STATUS, SOURCE, STATUS_ORDER, hhmm } from '@/lib/machine';
import { df } from '@/lib/format';
import { setStatus } from '@/app/(app)/may/actions';

export function MStatus({ value, since, eta }: { value: string; since?: string | null; eta?: string | null }) {
  return (
    <span className="inline-flex flex-col gap-0.5">
      <StatusPill map={M_STATUS} value={value} />
      {since && <span className="text-[12px] text-muted">từ {df(since, true)}</span>}
      {eta && (value === 'DOWN' || value === 'MAINT') && <span className="text-[12px] text-warn">dự kiến chạy lại {hhmm(eta)} {df(eta)}</span>}
    </span>
  );
}

export function SrcPill({ value }: { value: string | null }) {
  if (!value) return <Pill>Chưa khai</Pill>;
  const [label, tone] = SOURCE[value] ?? [value, 'mute'];
  return <Pill tone={tone}>{label}</Pill>;
}

// Thanh tiến độ chu kỳ bảo dưỡng (0..1+)
export function Meter({ value, tone }: { value: number; tone: 'ok' | 'warn' | 'bad' | 'info' }) {
  const color = { ok: 'bg-brand', warn: 'bg-warn', bad: 'bg-bad', info: 'bg-info' }[tone];
  return (
    <div className="h-2 w-full min-w-[90px] overflow-hidden rounded bg-todo" role="img" aria-label={`Đã dùng ${Math.round(value * 100)}% chu kỳ`}>
      <div className={`h-full ${color}`} style={{ width: `${Math.min(100, Math.max(2, value * 100))}%` }} />
    </div>
  );
}

type Reason = { code: string; name: string };

// Đổi trạng thái máy: TP Kỹ thuật/QA, vắng thì TP SX (công nhân báo TP SX). Dừng / Hỏng bắt buộc lý do và giờ dự kiến chạy lại
export function StatusForm({ machineId, current, reasons, back }: { machineId: string; current: string; reasons: Reason[]; back: string }) {
  return (
    <form action={setStatus} className="grid gap-3 p-4 sm:grid-cols-2 lg:grid-cols-[150px_200px_minmax(0,1fr)_200px_auto] lg:items-end">
      <input type="hidden" name="machine_id" value={machineId} />
      <input type="hidden" name="back" value={back} />
      <label className="lbl">Trạng thái mới
        <select name="status" className="inp" defaultValue={current === 'RUN' ? 'STOP' : 'RUN'}>
          {STATUS_ORDER.map((s) => <option key={s} value={s}>{M_STATUS[s][0]}</option>)}
        </select>
      </label>
      <label className="lbl">Lý do (bắt buộc khi Dừng, Hỏng)
        <select name="reason" className="inp" defaultValue="">
          <option value="">—</option>
          {reasons.map((r) => <option key={r.code} value={r.code}>{r.name}</option>)}
        </select>
      </label>
      <label className="lbl">Ghi chú
        <input name="note" className="inp" placeholder="Ví dụ: biến tần máy kéo báo quá dòng" />
      </label>
      <label className="lbl">Dự kiến chạy lại (bắt buộc khi Dừng, Hỏng)
        <input name="eta" type="datetime-local" className="inp" />
      </label>
      <SubmitButton>Cập nhật</SubmitButton>
      <p className="text-[12.5px] text-muted sm:col-span-2 lg:col-span-5">Dừng, Hỏng, Bảo dưỡng, Ngừng dùng: Lịch máy không xếp việc vào máy đến giờ dự kiến chạy lại; TP SX nhận thông báo bấm Xếp lại lịch. Lý do &quot;Hỏng máy&quot; thì MES ghi trạng thái Hỏng và mở phiếu sửa chữa. Ước lượng giờ chạy lại, sửa lại được khi biết rõ hơn.</p>
    </form>
  );
}

export function MachineLink({ id, code, name }: { id: string; code: string; name?: string | null }) {
  return (
    <Link href={`/may/${id}`} className="font-medium text-brand hover:underline">
      {code}{name && <span className="block text-[12.5px] font-normal text-muted">{name}</span>}
    </Link>
  );
}

// Thẻ gạch chân dùng cho trang có nhiều phần (?tab=)
export function SubTabs({ base, items, active }: { base: string; items: [string, string][]; active: string }) {
  return (
    <nav className="mb-4 flex gap-1 overflow-x-auto border-b border-line" aria-label="Phần thông tin">
      {items.map(([k, label]) => (
        <Link key={k} href={`${base}${base.includes('?') ? '&' : '?'}tab=${k}`} aria-current={k === active ? 'page' : undefined}
          className={`-mb-px whitespace-nowrap border-b-[3px] px-3 py-2.5 text-[14.5px] ${k === active ? 'border-brand font-medium text-brand' : 'border-transparent text-ink/80 hover:text-brand'}`}>
          {label}
        </Link>
      ))}
    </nav>
  );
}
