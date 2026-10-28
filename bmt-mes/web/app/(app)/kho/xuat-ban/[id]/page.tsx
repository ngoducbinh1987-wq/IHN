import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ScanList } from '@/components/scan';
import { SubmitButton } from '@/components/submit-button';
import { Flash, StatusPill, Toolbar } from '@/components/ui';
import { df, nf } from '@/lib/format';
import { DELIVERY_STATUS, keeps } from '@/lib/kho';
import { requireMe, requirePage } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { ship } from '../actions';
import { PrintButton } from '@/components/print-button';

export const metadata = { title: 'Lệnh giao' };

export default async function DeliveryDetail({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; err?: string }> }) {
  const { id } = await params;
  const sp = await searchParams;
  await requirePage('kho-xuat-ban');
  const me = await requireMe();
  const supabase = await createClient();
  const { data: d } = await supabase.schema('app').from('v_deliveries').select('*').eq('id', id).maybeSingle();
  if (!d) notFound();
  const { data: lines } = await supabase.schema('app').from('v_delivery_lines').select('*').eq('delivery_id', id).order('hu_no');
  const canShip = d.status === 'APPROVED' && keeps(me, 'KTP');
  return (
    <>
      <Toolbar title={<span>{d.delivery_no} · {d.so_no}</span>} reload={`/kho/xuat-ban/${id}`}
        actions={<>{d.approval_id && <Link className="btn btn-soft print:hidden" href={`/duyet/${d.approval_id}`}>Xem quy trình duyệt</Link>}
          {d.stock_doc_id && <Link className="btn btn-soft print:hidden" href={`/kho/phieu/${d.stock_doc_id}`}>Phiếu xuất kho</Link>}
          <PrintButton /><Link className="btn print:hidden" href="/kho/xuat-ban">Đóng</Link></>} />
      <div className="mt-4 print:hidden"><Flash ok={sp.ok} err={sp.err} /></div>
      <div className="mb-3 flex flex-wrap gap-x-6 gap-y-1 text-[14px]">
        <span><span className="text-muted">Khách hàng:</span> {d.customer_name}</span>
        <span><span className="text-muted">Thương hiệu:</span> {d.label_brand}</span>
        <span><span className="text-muted">Ngày giao:</span> {df(d.ship_date)}</span>
        <span><span className="text-muted">Trạng thái:</span> <StatusPill map={DELIVERY_STATUS} value={d.status} /></span>
        {d.note && <span><span className="text-muted">Ghi chú:</span> {d.note}</span>}
      </div>
      <section className="card mb-4 overflow-x-auto">
        <div className="card-h">Danh sách bobin · {d.reel_count} bobin · {nf(d.total_m)} m</div>
        <table className="tbl">
          <thead><tr><th>#</th><th>Mã QR bobin</th><th>Sản phẩm</th><th>Lô</th><th>Vị trí</th><th className="num">Mét</th></tr></thead>
          <tbody>{(lines ?? []).map((l, i) => (
            <tr key={l.id}><td>{i + 1}</td><td className="mono font-medium">{l.hu_no}</td><td><span className="mono">{l.product_code}</span> · {l.product_name}</td>
              <td className="mono">{l.lot_no}</td><td>{l.location_code ?? '—'}</td><td className="num">{nf(l.qty_m)}</td></tr>
          ))}</tbody>
        </table>
      </section>
      {canShip && (
        <section className="card print:hidden">
          <div className="card-h">Quét đủ từng bobin lên xe</div>
          <form action={ship} className="flex flex-col gap-3 p-4">
            <input type="hidden" name="delivery_id" value={id} />
            <ScanList name="items" warehouse="KTP" kinds={['FG']} hint="Quét sai bobin hoặc thiếu bobin thì hệ thống không cho xuất." />
            <div><SubmitButton>Xuất kho giao hàng</SubmitButton></div>
          </form>
        </section>
      )}
      <div className="mt-10 hidden grid-cols-3 text-center print:grid">
        <div><b>Người giao (NV5)</b></div><div><b>Người nhận</b></div><div><b>Giám đốc</b></div>
      </div>
    </>
  );
}
