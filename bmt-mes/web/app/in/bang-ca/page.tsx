import { PrintButton } from '@/components/print-button';
import { df } from '@/lib/format';
import { loadConfig, vnNow } from '@/lib/kh/load';
import { mondayOf, weekDays } from '@/lib/kh/roster';
import { addDays, nightHours, toMin } from '@/lib/kh/scheduler';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'In bảng ca tuần' };

type Row = {
  id: string; roster_no: string; week_start: string; week_end: string; status: string; machines: { machine: string; date: string; shifts: number }[];
  people: { code: string; shift: number; lead?: boolean }[]; qc: { mode?: string; who?: string | null }; note: string | null;
  submitted_by_name: string | null; submitted_at: string | null; reviewed_by_name: string | null; reviewed_at: string | null; sent_at: string | null;
};
const dd = (d: string) => `${d.slice(8, 10)}/${d.slice(5, 7)}`;
const WD = ['CN', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7'];
const ST: Record<string, string> = { DRAFT: 'NHÁP – chưa duyệt', PROPOSED: 'CHỜ GIÁM ĐỐC DUYỆT', APPROVED: 'Đã duyệt', RETURNED: 'Bị trả lại', CANCELLED: 'Đã hủy', REPLACED: 'Đã thay bằng bảng mới' };

// Bảng phân ca tuần dán ở xưởng (anh Bình 28/10/2026): ai làm ca nào cả tuần, ai phụ trách ca, máy nào chạy ca 1, ca 2
export default async function PrintRoster({ searchParams }: { searchParams: Promise<{ id?: string; w?: string }> }) {
  const sp = await searchParams;
  await requireMe();
  const db = await createClient();
  const { cfg, machines } = await loadConfig(db);
  let q = db.schema('app').from('v_kh_rosters').select('*');
  q = sp.id ? q.eq('id', sp.id) : q.eq('week_start', mondayOf(sp.w && /^\d{4}-\d{2}-\d{2}$/.test(sp.w) ? sp.w : addDays(mondayOf(vnNow().date), 7))).eq('status', 'APPROVED');
  const { data } = await q.order('created_at', { ascending: false }).limit(1);
  const r = ((data ?? [])[0] ?? null) as Row | null;
  if (!r) return <main className="p-6 text-[14px]">Không tìm thấy bảng ca tuần.</main>;
  const { data: ops } = await db.schema('app').from('v_kh_operators').select('code, full_name').order('sort');
  const name = new Map(((ops ?? []) as { code: string; full_name: string | null }[]).map((o) => [o.code, o.full_name ?? '']));
  const days = weekDays(r.week_start, cfg.workdays ?? [1, 2, 3, 4, 5, 6]);
  const sh = (no: number) => {
    const s = cfg.shifts.find((x) => x.code === (no === 2 ? 'B' : no === 3 ? 'C' : 'A'));
    if (!s) return { t: `Ca ${no}`, night: 0 };
    const a = toMin(s.start_time), b0 = toMin(s.end_time), b = b0 <= a ? b0 + 1440 : b0;
    return { t: `Ca ${no}: ${s.start_time.slice(0, 5)}–${s.end_time.slice(0, 5)}`, night: nightHours(a / 60, b / 60) };
  };
  const nOf = (m: string, d: string) => r.machines.find((x) => x.machine === m && x.date === d)?.shifts ?? 1;
  const cell = '[&_td]:border [&_td]:border-ink/50 [&_td]:px-2 [&_td]:py-1.5 [&_th]:border [&_th]:border-ink/50 [&_th]:bg-sunk [&_th]:px-2 [&_th]:py-1 [&_th]:text-left [&_th]:font-medium';
  const people = [...r.people].sort((a, b) => a.shift - b.shift || a.code.localeCompare(b.code));
  const lead = r.people.filter((p) => p.lead).map((p) => p.code).join(', ');
  return (
    <main className="mx-auto max-w-[820px] bg-white p-4 text-[12.5px] text-ink print:p-0">
      <div className="mb-3 flex items-center justify-between gap-3 print:hidden"><div>Bảng ca tuần {dd(r.week_start)}–{dd(r.week_end)} · {r.roster_no}</div><PrintButton /></div>
      <section className="border border-ink/60 p-3">
        <div className="mb-2 flex items-start justify-between">
          <div><div className="text-[16px] font-medium">BẢNG PHÂN CA TUẦN {dd(r.week_start)} – {dd(r.week_end)}/{r.week_end.slice(0, 4)}</div>
            <div>{r.roster_no} · {ST[r.status] ?? r.status}{r.sent_at ? ` · gửi công nhân ${df(r.sent_at, true)}` : ''}</div>
            <div className="text-[11.5px]">{[1, 2, 3].filter((n) => n === 1 || r.people.some((p) => p.shift === n)).map((n) => sh(n).t + (sh(n).night > 0 ? ` (${sh(n).night} giờ làm đêm)` : '')).join(' · ')}</div></div>
          <div className="text-right text-[11px] text-muted">BMT MES<br />Đổi ca vào Chủ nhật</div>
        </div>
        <table className={`w-full border-collapse ${cell}`}>
          <thead><tr><th className="w-[12%]">Mã</th><th>Họ tên</th><th className="w-[26%]">Ca cả tuần</th><th className="w-[14%]">Phụ trách ca</th><th className="w-[18%]">Ký nhận</th></tr></thead>
          <tbody>{people.map((p) => (
            <tr key={p.code}><td><b>{p.code}</b></td><td>{name.get(p.code) ?? ''}</td><td>{sh(p.shift).t}</td><td>{p.lead ? 'Phụ trách' : ''}</td><td>&nbsp;</td></tr>
          ))}</tbody>
        </table>
        <table className={`mt-3 w-full border-collapse ${cell}`}>
          <thead><tr><th>Máy</th>{days.map((d) => <th key={d} className="text-center">{WD[new Date(d + 'T00:00:00Z').getUTCDay()]} {dd(d)}</th>)}</tr></thead>
          <tbody>{machines.map((m) => (
            <tr key={m.code}><td><b>{m.code}</b></td>{days.map((d) => { const n = nOf(m.code, d); return <td key={d} className={`text-center ${n > 1 ? 'font-semibold' : ''}`}>{n === 3 ? 'Ca 1+2+3' : n === 2 ? 'Ca 1+2' : 'Ca 1'}</td>; })}</tr>
          ))}</tbody>
        </table>
        {r.machines.length > 0 && <p className="mt-2">Đo mẫu QC ca 2: <b>{r.qc.mode === 'QC' ? `QC làm ca 2 (${r.qc.who ?? ''})` : `ủy quyền người phụ trách ca (${lead})`}</b>. Ca 2 không ai làm một mình.</p>}
        {r.note && <p className="mt-1">Ghi chú: {r.note}</p>}
        <div className="mt-4 grid grid-cols-2 gap-4 text-center text-[12px]">
          <div><b>TP SX</b><div className="text-muted">{r.submitted_by_name ?? '(ký, ghi rõ họ tên)'}{r.submitted_at ? ` · ${df(r.submitted_at, true)}` : ''}</div><div className="h-12" /></div>
          <div><b>Giám đốc duyệt</b><div className="text-muted">{r.reviewed_by_name ?? '(ký, ghi rõ họ tên)'}{r.reviewed_at ? ` · ${df(r.reviewed_at, true)}` : ''}</div><div className="h-12" /></div>
        </div>
      </section>
    </main>
  );
}
