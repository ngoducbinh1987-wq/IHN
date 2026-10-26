import { Empty, Pill } from '@/components/ui';
import { M_STATUS, WO_TYPE, hhmm } from '@/lib/machine';
import { df } from '@/lib/format';

const KIND_TEXT: Record<string, [string, 'ok' | 'warn' | 'bad' | 'info' | 'mute']> = {
  STATUS: ['Trạng thái', 'mute'], WO_OPEN: ['Mở phiếu', 'info'], WO_DONE: ['Xong phiếu', 'ok'], CHECK: ['Checklist', 'mute'], CHANGE: ['Sửa thông số', 'info'], PEOPLE: ['Người đứng máy', 'info'], ALARM: ['Báo động PLC', 'bad'],
};
type Ev = { at: string; kind: string; sub: string; detail: string; source: string; who: string | null; machine_id: string };
export function HistoryTable({ rows, codes }: { rows: Ev[]; codes?: Record<string, string> }) {
  if (!rows.length) return <Empty>Chưa có sự kiện.</Empty>;
  return (
    <table className="tbl">
      <thead><tr><th>Thời điểm</th>{codes && <th>Máy</th>}<th>Loại</th><th>Nội dung</th><th>Nguồn</th><th>Người</th></tr></thead>
      <tbody>
        {rows.map((e, i) => {
          const [label, tone] = e.kind === 'STATUS' ? [M_STATUS[e.sub]?.[0] ?? e.sub, M_STATUS[e.sub]?.[1] ?? 'mute'] : e.kind === 'CHECK' && e.sub === 'ISSUE' ? ['Checklist', 'warn' as const] : KIND_TEXT[e.kind] ?? [e.kind, 'mute' as const];
          return (
            <tr key={i}>
              <td className="whitespace-nowrap tabular-nums">{df(e.at)} {hhmm(e.at)}</td>
              {codes && <td className="mono">{codes[e.machine_id] ?? ''}</td>}
              <td><Pill tone={tone}>{e.kind === 'WO_OPEN' || e.kind === 'WO_DONE' ? `${label} ${WO_TYPE[e.sub]?.toLowerCase() ?? ''}` : label}</Pill></td>
              <td className="min-w-[240px]">{e.detail || '—'}</td>
              <td className="text-[13px]">{{ TAY: 'Nhập tay', PLC: 'PLC', HE_THONG: 'Hệ thống' }[e.source] ?? e.source}</td>
              <td className="text-[13px]">{e.who ?? '—'}</td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}

