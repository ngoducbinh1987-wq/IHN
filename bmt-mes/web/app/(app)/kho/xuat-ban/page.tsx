import Link from 'next/link';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, StatusPill, Toolbar } from '@/components/ui';
import { df, nf } from '@/lib/format';
import { DELIVERY_STATUS, keeps } from '@/lib/kho';
import { requireMe, requirePage } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { createDelivery } from './actions';

export const metadata = { title: 'Xuất giao hàng' };

type Res = { so_id: string; so_no: string; label_brand: string; customer_name: string | null; required_date: string; hu_id: string; hu_no: string;
  qty_m: number; product_code: string; product_name: string; location_code: string | null };

export default async function DeliveriesPage({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string }> }) {
  const sp = await searchParams;
  await requirePage('kho-xuat-ban');
  const me = await requireMe();
  const supabase = await createClient();
  const [{ data: dvs }, { data: res }] = await Promise.all([
    supabase.schema('app').from('v_deliveries').select('*').order('created_at', { ascending: false }).limit(100),
    keeps(me, 'KTP') ? supabase.schema('app').from('v_so_reserved').select('*').order('required_date').order('so_no').order('hu_no').returns<Res[]>() : Promise.resolve({ data: [] as Res[] }),
  ]);
  const bySo = new Map<string, Res[]>();
  for (const r of res ?? []) bySo.set(r.so_id, [...(bySo.get(r.so_id) ?? []), r]);
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Ho_Chi_Minh' });
  return (
    <>
      <Toolbar title="Xuất giao hàng thành phẩm" reload="/kho/xuat-ban" />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /></div>
      <p className="mb-3 text-[13px] text-muted">NV5 lập lệnh giao từ bobin đã giữ cho đơn bán → TP Kỹ thuật/QA xác nhận phiếu kiểm tra → Giám đốc duyệt → NV5 quét đủ đúng bobin rồi xuất (Quy chuẩn mục 9).</p>
      <section className="card mb-4 overflow-x-auto">
        <div className="card-h">Lệnh giao</div>
        {dvs && dvs.length > 0 ? (
          <table className="tbl">
            <thead><tr><th>Lệnh giao</th><th>Đơn bán</th><th>Khách hàng</th><th>Ngày giao</th><th className="num">Bobin</th><th className="num">Mét</th><th>Trạng thái</th><th>Người lập</th></tr></thead>
            <tbody>{dvs.map((d) => (
              <tr key={d.id}>
                <td><Link className="link mono font-medium" href={`/kho/xuat-ban/${d.id}`}>{d.delivery_no}</Link></td>
                <td className="mono">{d.so_no} · {d.label_brand}</td><td>{d.customer_name}</td><td>{df(d.ship_date)}</td>
                <td className="num">{d.reel_count}</td><td className="num">{nf(d.total_m)}</td><td><StatusPill map={DELIVERY_STATUS} value={d.status} /></td><td>{d.created_by_name}</td>
              </tr>
            ))}</tbody>
          </table>
        ) : <Empty>Chưa có lệnh giao.</Empty>}
      </section>
      {keeps(me, 'KTP') && (
        <section className="card">
          <div className="card-h">Lập lệnh giao từ hàng đã giữ</div>
          {bySo.size === 0 ? <Empty>Không có bobin nào đang giữ cho đơn bán đã duyệt (Kinh doanh giữ hàng trên đơn bán).</Empty> : (
            <div className="flex flex-col divide-y divide-line">
              {[...bySo.values()].map((rows) => (
                <form key={rows[0].so_id} action={createDelivery} className="p-4">
                  <input type="hidden" name="so_id" value={rows[0].so_id} />
                  <div className="mb-2 text-[14px]"><b className="mono">{rows[0].so_no}</b> · {rows[0].customer_name} · {rows[0].label_brand} · cần giao {df(rows[0].required_date)}</div>
                  <table className="tbl mb-3">
                    <tbody>{rows.map((r) => (
                      <tr key={r.hu_id}>
                        <td className="w-8"><input type="checkbox" name="hu" value={r.hu_id} defaultChecked aria-label={`Chọn ${r.hu_no}`} /></td>
                        <td className="mono">{r.hu_no}</td><td><span className="mono">{r.product_code}</span> · {r.product_name}</td><td>{r.location_code ?? '—'}</td><td className="num">{nf(r.qty_m)} m</td>
                      </tr>
                    ))}</tbody>
                  </table>
                  <div className="grid gap-3 sm:grid-cols-[180px_1fr_auto] sm:items-end">
                    <label className="lbl">Ngày giao<input className="inp" type="date" name="ship_date" defaultValue={today} /></label>
                    <label className="lbl">Ghi chú (xe, người nhận…)<input className="inp" name="note" /></label>
                    <SubmitButton>Lập lệnh giao, gửi duyệt</SubmitButton>
                  </div>
                </form>
              ))}
            </div>
          )}
        </section>
      )}
    </>
  );
}
