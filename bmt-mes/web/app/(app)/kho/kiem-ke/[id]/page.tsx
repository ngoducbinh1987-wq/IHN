import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ScanOne } from '@/components/scan';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, StatusPill, Toolbar } from '@/components/ui';
import { df, nf } from '@/lib/format';
import { COUNT_STATUS, hasRole } from '@/lib/kho';
import { requirePage, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { cancelCount, closeCount, scanCount } from '../actions';

export const metadata = { title: 'Phiếu kiểm kê' };

export default async function CountDetail({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; err?: string }> }) {
  const { id } = await params;
  const sp = await searchParams;
  await requirePage('kho-kiem-ke');
  const me = await requirePerm('inventory', 'view');
  const supabase = await createClient();
  const { data: c } = await supabase.schema('app').from('v_counts').select('*').eq('id', id).maybeSingle();
  if (!c) notFound();
  const [{ data: lines }, { data: locs }, { data: adj }] = await Promise.all([
    supabase.schema('app').from('v_count_lines').select('*').eq('count_id', id).order('location_code').order('item_code').order('hu_no'),
    supabase.schema('app').from('v_locations').select('id, code, name').eq('warehouse_code', c.warehouse_code).eq('active', true).order('sort'),
    c.adj_doc_id ? supabase.schema('app').from('v_stock_docs').select('id, doc_no, approval_id, status').eq('id', c.adj_doc_id).maybeSingle() : Promise.resolve({ data: null }),
  ]);
  const kt = hasRole(me, 'KT_KHO');
  const counting = ['OPEN', 'COUNTED'].includes(c.status);
  const canCount = counting && (kt || hasRole(me, c.warehouse_code === 'KTP' ? 'KHO_NV' : 'THU_KHO'));
  const left = (lines ?? []).filter((l) => l.counted_qty === null);
  return (
    <>
      <Toolbar title={<span>{c.count_no} · {c.warehouse_code} · {c.count_type === 'SAMPLE' ? 'chọn mẫu' : 'toàn bộ'}</span>} reload={`/kho/kiem-ke/${id}`}
        actions={<>{adj?.approval_id && <Link className="btn btn-soft" href={`/duyet/${adj.approval_id}`}>Biên bản chờ duyệt</Link>}<Link className="btn" href="/kho/kiem-ke">Đóng</Link></>} />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /></div>
      <div className="mb-3 flex flex-wrap gap-x-6 gap-y-1 text-[14px]">
        <span><span className="text-muted">Trạng thái:</span> <StatusPill map={COUNT_STATUS} value={c.status} /></span>
        <span><span className="text-muted">Đã đếm:</span> {c.counted}/{c.line_count}</span>
        <span><span className="text-muted">Mở:</span> {c.created_by_name} · {df(c.count_date)}</span>
        {c.note && <span><span className="text-muted">Ghi chú:</span> {c.note}</span>}
        {adj && <span><span className="text-muted">Biên bản điều chỉnh:</span> <Link className="link mono" href={`/kho/phieu/${adj.id}`}>{adj.doc_no}</Link></span>}
      </div>

      {canCount && (
        <form action={scanCount} className="card mb-4 grid gap-4 p-4 md:grid-cols-2">
          <input type="hidden" name="count_id" value={id} />
          <ScanOne name="hu_id" label="Quét tem QR hàng đang đếm" />
          <div className="grid content-start gap-3">
            <label className="lbl"><span className="req">Số đếm thực tế ({c.warehouse_code === 'KNL' || c.warehouse_code === 'KPL' ? 'kg cân lại / cái' : 'mét'})</span>
              <input className="inp inp-y h-11 text-right text-[16px]" name="counted" inputMode="decimal" required /></label>
            <label className="lbl">Vị trí thấy hàng
              <select className="inp" name="location_id" defaultValue=""><option value="">Theo vị trí trên sổ</option>{(locs ?? []).map((l) => <option key={l.id} value={l.id}>{l.code} · {l.name}</option>)}</select></label>
            <label className="lbl">Ghi chú<input className="inp" name="note" /></label>
            <div><SubmitButton>Ghi số đếm</SubmitButton></div>
          </div>
        </form>
      )}

      <section className="card mb-4 overflow-x-auto">
        <div className="card-h">Danh sách đếm{!kt && counting && <span className="text-[12.5px] font-normal text-muted">Đếm mù: số sổ sách chỉ Kế toán SX thấy</span>}</div>
        {lines && lines.length > 0 ? (
          <table className="tbl">
            <thead><tr><th>Vị trí</th><th>Mã QR</th><th>Hàng</th><th>Lô</th>{kt && <th className="num">Sổ sách</th>}<th className="num">Đếm</th>{kt && <th className="num">Chênh</th>}<th>Người đếm</th>{canCount && <th />}</tr></thead>
            <tbody>{lines.map((l) => (
              <tr key={l.id} className={l.diff ? 'bg-bad-soft/40' : ''}>
                <td>{l.location_code ?? '—'}</td><td className="mono">{l.hu_no ?? '—'}</td>
                <td className="min-w-[150px]"><span className="mono">{l.item_code}</span> · {l.item_name}</td><td className="mono">{l.lot_no}</td>
                {kt && <td className="num">{nf(l.system_qty, 3)}</td>}
                <td className="num font-medium">{l.counted_qty === null ? <span className="text-muted">chưa đếm</span> : nf(l.counted_qty, 3)} {l.uom}</td>
                {kt && <td className={`num ${l.diff ? 'font-medium text-bad' : 'text-muted'}`}>{l.diff === null ? '—' : nf(l.diff, 3)}</td>}
                <td className="text-[13px]">{l.counted_by_name ?? ''}{l.note ? <div className="text-muted">{l.note}</div> : null}</td>
                {canCount && <td>{!l.hu_id && (
                  <form action={scanCount} className="flex gap-1"><input type="hidden" name="count_id" value={id} /><input type="hidden" name="line_id" value={l.id} />
                    <input className="inp inp-y w-24 text-right" name="counted" inputMode="decimal" required aria-label={`Số đếm ${l.item_code}`} />
                    <SubmitButton className="btn btn-sm btn-soft" pendingText="…">Ghi</SubmitButton></form>)}</td>}
              </tr>
            ))}</tbody>
          </table>
        ) : <Empty>Không có dòng nào.</Empty>}
      </section>

      {kt && counting && (
        <div className="grid gap-4 md:grid-cols-2">
          <form action={closeCount} className="card flex flex-col gap-2 p-4">
            <input type="hidden" name="count_id" value={id} />
            <b className="text-[14px]">Đóng phiếu, lập biên bản chênh lệch</b>
            {left.length > 0 && <label className="flex items-center gap-2 text-[13.5px]"><input type="checkbox" name="missing_zero" />{left.length} dòng chưa đếm: tính là 0 (không tìm thấy)</label>}
            <SubmitButton>Đóng phiếu kiểm kê</SubmitButton>
          </form>
          <form action={cancelCount} className="card flex flex-col gap-2 p-4">
            <input type="hidden" name="count_id" value={id} />
            <label className="lbl">Lý do hủy<input className="inp" name="reason" required /></label>
            <SubmitButton className="btn btn-bad-o">Hủy phiếu kiểm kê</SubmitButton>
          </form>
        </div>
      )}
    </>
  );
}
