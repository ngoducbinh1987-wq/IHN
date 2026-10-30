import Link from 'next/link';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, StatusPill, Toolbar } from '@/components/ui';
import { df } from '@/lib/format';
import { COUNT_STATUS, LoadErrors, hasRole } from '@/lib/kho';
import { requirePage, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { openCount } from './actions';

export const metadata = { title: 'Kiểm kê' };

export default async function CountsPage({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string }> }) {
  const sp = await searchParams;
  await requirePage('kho-kiem-ke');
  const me = await requirePerm('inventory', 'view');
  const supabase = await createClient();
  const le = new LoadErrors();
  const [{ data: counts }, { data: whs }, { data: locs }] = le.all(await Promise.all([
    supabase.schema('app').from('v_counts').select('*').order('count_date', { ascending: false }).limit(100),
    supabase.schema('inv').from('warehouses').select('id, code, name').order('code'),
    supabase.schema('app').from('v_locations').select('id, code, name, warehouse_code').eq('active', true).order('warehouse_code').order('sort'),
  ]));
  const kt = hasRole(me, 'KT_KHO');
  return (
    <>
      <Toolbar title="Kiểm kê" reload="/kho/kiem-ke" />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /><Flash err={le.text} /></div>
      <p className="mb-3 text-[13px] text-muted">
        Kiểm kê chọn mẫu hằng tuần và toàn bộ cuối tháng (Quy chuẩn mục 3, 5). Kế toán SX chủ trì, Quản lý SX và NV5 đếm mù (không thấy số sổ sách),
        Kế toán trưởng duyệt biên bản chênh lệch. Chỉ tiêu: chênh lệch ≤ 0,5% giá trị tồn.
      </p>
      {kt && (
        <form action={openCount} className="card mb-4 grid gap-3 p-4 md:grid-cols-[1fr_1fr_2fr_1.5fr_auto] md:items-end">
          <label className="lbl"><span className="req">Kho</span>
            <select className="inp inp-y" name="warehouse_id" required>{(whs ?? []).map((w) => <option key={w.id} value={w.id}>{w.code} · {w.name}</option>)}</select></label>
          <label className="lbl"><span className="req">Loại</span>
            <select className="inp inp-y" name="count_type"><option value="SAMPLE">Chọn mẫu (tuần)</option><option value="FULL">Toàn bộ (cuối tháng)</option></select></label>
          <label className="lbl">Chỉ các vị trí (giữ Ctrl để chọn nhiều; để trống = cả kho)
            <select className="inp" name="locations" multiple size={3}>{(locs ?? []).map((l) => <option key={l.id} value={l.id}>{l.warehouse_code} · {l.code}</option>)}</select></label>
          <label className="lbl">Ghi chú<input className="inp" name="note" placeholder="Tuần 44, cuối tháng 10…" /></label>
          <SubmitButton>Mở phiếu kiểm kê</SubmitButton>
        </form>
      )}
      <section className="card overflow-x-auto">
        {counts && counts.length > 0 ? (
          <table className="tbl">
            <thead><tr><th>Phiếu</th><th>Kho</th><th>Loại</th><th>Ngày</th><th>Tiến độ</th><th>Chênh lệch</th><th>Trạng thái</th><th>Người mở</th></tr></thead>
            <tbody>{counts.map((c) => (
              <tr key={c.id}>
                <td><Link className="link mono font-medium" href={`/kho/kiem-ke/${c.id}`}>{c.count_no}</Link></td>
                <td>{c.warehouse_code}{c.location_codes?.length ? <div className="text-[12px] text-muted">{c.location_codes.join(', ')}</div> : null}</td>
                <td>{c.count_type === 'SAMPLE' ? 'Chọn mẫu' : 'Toàn bộ'}</td><td>{df(c.count_date)}</td>
                <td>{c.counted}/{c.line_count}</td><td>{c.diff_lines ? <span className="text-bad">{c.diff_lines} dòng</span> : '—'}</td>
                <td><StatusPill map={COUNT_STATUS} value={c.status} /></td><td>{c.created_by_name}</td>
              </tr>
            ))}</tbody>
          </table>
        ) : <Empty>Chưa có phiếu kiểm kê.</Empty>}
      </section>
    </>
  );
}
