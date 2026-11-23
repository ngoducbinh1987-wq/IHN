import { PrintButton } from '@/components/print-button';
import { df, dmy, nf } from '@/lib/format';
import { REQ_STATUS, fmtDays, type Req } from '@/lib/requests';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'In đơn đề xuất' };

// Đơn đề xuất in ra giấy (công nhân chưa có tài khoản ký nhận; lưu hồ sơ nhân sự)
export default async function PrintRequest({ searchParams }: { searchParams: Promise<{ id?: string }> }) {
  const sp = await searchParams;
  await requireMe();
  const db = await createClient();
  const { data: r } = await db.schema('app').from('v_requests').select('*').eq('id', sp.id ?? '').maybeSingle<Req>();
  if (!r) return <main className="p-6 text-[14px]">Không tìm thấy đề xuất hoặc bạn không có quyền xem.</main>;
  const d = r.data ?? {};
  type H = { action: string; actor: string | null; at: string; label: string | null; comment: string | null };
  const approvals = ((r.history ?? []) as H[]).filter((h) => h.action === 'APPROVE');
  const rows: [string, string | null][] = [
    ['Người đề xuất', `${r.requester_name}${r.dept_name ? ' – ' + r.dept_name : ''}`],
    ['Loại đề xuất', r.type_name],
    ['Tiêu đề', r.title],
    ['Thời gian', r.date_from ? `${dmy(r.date_from)}${r.date_to && r.date_to !== r.date_from ? ' đến ' + dmy(r.date_to) : ''}${r.days !== null ? ` (${fmtDays(Number(r.days))})` : ''}` : null],
    ['Giờ', r.time_from || r.time_to ? `${r.time_from?.slice(0, 5) ?? '…'} – ${r.time_to?.slice(0, 5) ?? '…'}` : null],
    ['Hưởng lương', r.paid === null ? null : r.paid ? 'Có lương' : 'Không lương'],
    ['Số tiền', r.amount !== null ? `${nf(r.amount)} đồng` : null],
    ['Máy', r.machine_code], ['Bộ phận nhận', r.target_dept_name], ['Nơi công tác', d.place ?? null],
    ['Ngày dự sinh', d.due_date ? dmy(d.due_date) : null], ['Bàn giao việc cho', d.handover ?? null],
    ['Đổi ca', d.from_shift || d.to_shift ? `${d.from_shift} → ${d.to_shift}` : null],
    ['Nội dung / lý do', r.content],
  ];
  return (
    <main className="mx-auto max-w-[760px] p-6 text-[14px] leading-relaxed print:p-0">
      <div className="mb-4 flex items-center justify-between print:hidden"><span className="text-muted">Khổ A4 dọc</span><PrintButton /></div>
      <div className="flex items-start justify-between">
        <div><b>CÔNG TY BMT</b><div className="text-[12px]">Nhà máy cáp BMTcable</div></div>
        <div className="text-right text-[12px]">Số: <b>{r.req_no}</b><div>Lập: {df(r.created_at, true)}</div></div>
      </div>
      <h1 className="my-5 text-center text-[20px] font-bold uppercase">Đơn đề xuất – {r.type_name}</h1>
      <table className="w-full border-collapse">
        <tbody>{rows.filter(([, v]) => v).map(([k, v]) => (
          <tr key={k}><td className="w-44 border border-black px-2 py-1.5 align-top font-medium">{k}</td><td className="whitespace-pre-wrap border border-black px-2 py-1.5">{v}</td></tr>
        ))}</tbody>
      </table>
      {r.items?.length > 0 && (
        <table className="mt-3 w-full border-collapse text-[13px]">
          <thead><tr>{['#', 'Mã VT', 'Tên hàng', 'Quy cách', 'Số lượng', 'ĐVT'].map((h) => <th key={h} className="border border-black px-2 py-1">{h}</th>)}</tr></thead>
          <tbody>{r.items.map((it, i) => (
            <tr key={i}><td className="border border-black px-2 py-1">{i + 1}</td><td className="border border-black px-2 py-1">{it.code ?? ''}</td><td className="border border-black px-2 py-1">{it.name}</td>
              <td className="border border-black px-2 py-1">{it.spec ?? ''}</td><td className="border border-black px-2 py-1 text-right">{nf(it.qty ?? 0, 2)}</td><td className="border border-black px-2 py-1">{it.unit ?? ''}</td></tr>
          ))}</tbody>
        </table>
      )}
      <p className="mt-3">Trạng thái trên MES: <b>{REQ_STATUS[r.status]?.[0] ?? r.status}</b>
        {approvals.map((h, i) => <span key={i}>; {h.label}: {h.actor} ({df(h.at, true)})</span>)}.</p>
      <div className="mt-8 grid grid-cols-3 text-center">
        <div><b>Người đề xuất</b><div className="text-[12px]">(ký, ghi rõ họ tên)</div></div>
        <div><b>Trưởng bộ phận</b><div className="text-[12px]">(ký, ghi rõ họ tên)</div></div>
        <div><b>Giám đốc</b><div className="text-[12px]">(ký, ghi rõ họ tên)</div></div>
      </div>
      <div className="h-24" />
    </main>
  );
}
