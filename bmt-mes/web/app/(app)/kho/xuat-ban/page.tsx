import Link from 'next/link';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, StatusPill, Toolbar } from '@/components/ui';
import { df, nf } from '@/lib/format';
import { DELIVERY_STATUS, hasRole } from '@/lib/kho';
import { can, requireMe, requirePage } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { createDelivery } from './actions';
import { ItemsFields, kindLabel, type FgGroup } from './items-fields';

export const metadata = { title: 'Xuất giao hàng' };

export default async function DeliveriesPage({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string }> }) {
  const sp = await searchParams;
  await requirePage('kho-xuat-ban');
  const me = await requireMe();
  const supabase = await createClient();
  const [{ data: dvs }, { data: groups }, { data: customers }] = await Promise.all([
    supabase.schema('app').from('v_deliveries').select('*').order('created_at', { ascending: false }).limit(100),
    supabase.schema('app').from('v_fg_stock').select('*').order('product_code').order('brand').order('pack_m', { ascending: false }).returns<FgGroup[]>(),
    supabase.schema('core').from('partners').select('id, name').eq('is_customer', true).eq('active', true).order('name'),
  ]);
  const canCreate = can(me, 'sales', 'create') || hasRole(me, 'KT_KHO', 'ADMIN');
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Ho_Chi_Minh' });
  const stock = (groups ?? []).filter((g) => g.total_coils > 0);
  return (
    <>
      <Toolbar title="Xuất giao hàng thành phẩm" reload="/kho/xuat-ban" />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /></div>
      <p className="mb-3 text-[13px] text-muted">
        Cuộn thành phẩm chỉ dán tem QC PASS, không quét QR: xuất kho chỉ cần <b>bao nhiêu cuộn, chủng loại nào</b>. Kinh doanh hoặc Kế toán SX lập lệnh giao → <b>Giám đốc duyệt</b> (được sửa số cuộn, ngày giao) →
        Kế toán SX in phiếu xuất cho người giữ kho thành phẩm → giao xong Kế toán SX nhập &quot;đã giao&quot; theo phiếu có chữ ký; MES tự chọn cuộn QC Đạt, lô cũ trước để trừ tồn.
      </p>

      {canCreate && (
        <section className="card mb-4">
          <div className="card-h">Lập lệnh giao</div>
          <form action={createDelivery} className="grid gap-4 p-4 lg:grid-cols-[minmax(0,320px)_minmax(0,1fr)]">
            <div className="flex flex-col gap-3">
              <datalist id="customers">{(customers ?? []).map((c) => <option key={c.id} value={c.name} />)}</datalist>
              <label className="lbl"><span className="req">Khách hàng nhận</span><input className="inp inp-y" name="customer_name" list="customers" required /></label>
              <label className="lbl">Ngày giao<input className="inp" type="date" name="ship_date" defaultValue={today} /></label>
              <label className="lbl">Ghi chú (xe, người nhận, địa điểm…)<input className="inp" name="note" /></label>
            </div>
            <div>
              <div className="mb-1 text-[13px] text-muted">Chủng loại (mã · nhãn · quy cách) và số cuộn</div>
              <ItemsFields groups={groups ?? []} />
              <div className="mt-3 flex flex-wrap gap-2">
                <button className="btn btn-pri" type="submit" name="send" value="1">Lập và gửi Giám đốc duyệt</button>
                <SubmitButton className="btn">Lưu nháp</SubmitButton>
              </div>
            </div>
          </form>
        </section>
      )}

      <section className="card mb-4 overflow-x-auto">
        <div className="card-h">Lệnh giao</div>
        {dvs && dvs.length > 0 ? (
          <table className="tbl">
            <thead><tr><th>Lệnh giao</th><th>Khách hàng</th><th>Ngày giao</th><th className="num">Số cuộn</th><th className="num">Đã xuất</th><th>Trạng thái</th><th>Người lập</th></tr></thead>
            <tbody>{dvs.map((d) => (
              <tr key={d.id}>
                <td><Link className="link mono font-medium" href={`/kho/xuat-ban/${d.id}`}>{d.delivery_no}</Link>{d.so_no && <div className="text-[12px] text-muted">{d.so_no}</div>}</td>
                <td>{d.customer_name}<div className="text-[12px] text-muted">{d.label_brand}</div></td><td>{df(d.ship_date)}</td>
                <td className="num">{d.direct ? d.coil_count : d.reel_count}</td>
                <td className="num">{d.status === 'SHIPPED' ? `${d.direct ? d.shipped_coils : d.reel_count} cuộn · ${nf(d.total_m)} m` : '—'}</td>
                <td><StatusPill map={DELIVERY_STATUS} value={d.status} /></td><td>{d.created_by_name}</td>
              </tr>
            ))}</tbody>
          </table>
        ) : <Empty>Chưa có lệnh giao.</Empty>}
      </section>

      <section className="card overflow-x-auto">
        <div className="card-h">Tồn thành phẩm theo cuộn</div>
        {stock.length ? (
          <table className="tbl">
            <thead><tr><th>Chủng loại</th><th className="num">Chờ QC</th><th className="num" title="QC Đạt, chưa nhập kho (khu chờ QC)">Chờ nhập kho</th><th className="num">Trong kho</th><th className="num">Mét trong kho</th>
              <th className="num" title="Lệnh giao đang chờ duyệt / đã duyệt chưa xuất">Đã hứa giao</th><th className="num">Còn giao được</th><th className="num" title="Cách ly, hàng trả">Giữ lại</th></tr></thead>
            <tbody>{stock.map((g) => (
              <tr key={`${g.product_code}|${g.brand}|${g.pack_m}`}>
                <td>{kindLabel(g.product_code, g.brand, g.pack_m)}</td><td className="num">{g.qc_wait_coils || '—'}</td><td className="num">{g.putaway_coils || '—'}</td>
                <td className="num font-medium">{g.store_coils}</td><td className="num">{nf(g.store_m)}</td><td className="num">{g.committed_coils || '—'}</td>
                <td className="num font-medium text-brand">{g.free_coils}</td><td className="num">{g.hold_coils || '—'}</td>
              </tr>
            ))}</tbody>
          </table>
        ) : <Empty>Kho thành phẩm đang trống.</Empty>}
        <p className="border-t border-line px-4 py-2 text-[12.5px] text-muted">Cuộn QC Đạt phải nhập kho (Kho → Thành phẩm: phiếu nhập kho TP) mới tính vào &quot;còn giao được&quot;. Cuộn lẻ, đoạn cắt đi chung một dòng &quot;cuộn lẻ&quot;.</p>
      </section>
    </>
  );
}
