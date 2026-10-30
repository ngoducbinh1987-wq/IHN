import Link from 'next/link';
import { notFound } from 'next/navigation';
import { PrintButton } from '@/components/print-button';
import { ScanList } from '@/components/scan';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, StatusPill, Toolbar } from '@/components/ui';
import { df, nf } from '@/lib/format';
import { DELIVERY_STATUS, LoadErrors, hasRole, keeps } from '@/lib/kho';
import { can, requireMe, requirePage } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { cancelDelivery, saveDelivery, ship, shipDirect, submitDelivery } from '../actions';
import { ItemsFields, kindLabel, type FgGroup } from '../items-fields';

export const metadata = { title: 'Lệnh giao' };

type Item = { id: string; line_no: number; product_code: string; product_name: string | null; brand: string; pack_m: number | null; coils: number;
  shipped_coils: number | null; shipped_m: number | null; free_coils: number };

export default async function DeliveryDetail({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; err?: string }> }) {
  const { id } = await params;
  const sp = await searchParams;
  await requirePage('kho-xuat-ban');
  const me = await requireMe();
  const supabase = await createClient();
  const le = new LoadErrors();
  const { data: d } = le.one(await supabase.schema('app').from('v_deliveries').select('*').eq('id', id).maybeSingle());
  if (!d) {
    // Lỗi tải dữ liệu thì báo rõ, không báo nhầm "không tìm thấy"
    if (le.has) return <><Toolbar title="Lệnh giao" /><div className="mt-4"><Flash err={le.text} /></div></>;
    notFound();
  }
  const [{ data: items }, { data: lines }, { data: groups }, { data: keepers }] = le.all(await Promise.all([
    supabase.schema('app').from('v_delivery_items').select('*').eq('delivery_id', id).order('line_no').returns<Item[]>(),
    supabase.schema('app').from('v_delivery_lines').select('*').eq('delivery_id', id).order('hu_no'),
    supabase.schema('app').from('v_fg_stock').select('*').order('product_code').returns<FgGroup[]>(),
    supabase.schema('app').rpc('fg_keepers'),
  ]));
  const { data: reviewEdit } = d.status === 'PENDING_APPROVAL' && d.direct
    ? le.one(await supabase.schema('app').rpc('can_review_edit', { p_doc_type: 'DELIVERY', p_doc_id: id }))
    : { data: false };
  const reviewer = reviewEdit === true;
  const maker = can(me, 'sales', 'create') || hasRole(me, 'KT_KHO', 'ADMIN');
  const editable = d.direct && ((d.status === 'DRAFT' && maker) || reviewer);
  const paperEntry = hasRole(me, 'KT_KHO', 'SX_TP', 'ADMIN') || keeps(me, 'KTP');
  const canShipDirect = d.direct && d.status === 'APPROVED' && paperEntry;
  const canShipScan = !d.direct && d.status === 'APPROVED' && keeps(me, 'KTP');
  const kp = (keepers ?? []) as { code: string; full_name: string | null }[];
  return (
    <>
      <Toolbar title={<span>{d.delivery_no} · {d.customer_name}</span>} reload={`/kho/xuat-ban/${id}`}
        actions={<>{d.approval_id && <Link className="btn btn-soft print:hidden" href={`/duyet/${d.approval_id}`}>Xem quy trình duyệt</Link>}
          {d.status === 'DRAFT' && maker && d.direct && (
            <form action={submitDelivery} className="print:hidden"><input type="hidden" name="delivery_id" value={id} /><SubmitButton>Gửi Giám đốc duyệt</SubmitButton></form>
          )}
          {d.stock_doc_id && <Link className="btn btn-soft print:hidden" href={`/kho/phieu/${d.stock_doc_id}`}>Phiếu xuất kho</Link>}
          <PrintButton /><Link className="btn print:hidden" href="/kho/xuat-ban">Đóng</Link></>} />
      <div className="mt-4 print:hidden"><Flash ok={sp.ok} err={sp.err} /><Flash err={le.text} /></div>
      <h2 className="mb-2 hidden text-center text-[20px] font-bold print:block">PHIẾU XUẤT KHO THÀNH PHẨM</h2>
      <div className="mb-3 flex flex-wrap gap-x-6 gap-y-1 text-[14px]">
        <span><span className="text-muted">Khách hàng:</span> <b>{d.customer_name}</b></span>
        <span><span className="text-muted">Ngày giao:</span> {df(d.ship_date)}</span>
        <span className="print:hidden"><span className="text-muted">Trạng thái:</span> <StatusPill map={DELIVERY_STATUS} value={d.status} /></span>
        {d.note && <span><span className="text-muted">Ghi chú:</span> {d.note}</span>}
        {d.giver_code && <span><span className="text-muted">Người giao:</span> {d.giver_code}{d.giver_name ? ` · ${d.giver_name}` : ''}</span>}
        {d.paper_no && <span><span className="text-muted">Số phiếu giấy:</span> {d.paper_no}</span>}
      </div>
      {reviewer && (
        <div role="note" id="review-edit" className="mb-4 rounded border-l-4 border-brand bg-brand-soft px-4 py-2.5 text-[14px] print:hidden">
          <b>Bạn đang duyệt lệnh giao này</b> nên được sửa số cuộn, ngày giao trước khi duyệt; mỗi lần sửa ghi vào lịch sử duyệt và báo người lập.
          {d.approval_id && <> Sửa xong bấm duyệt ở <Link className="link" href={`/duyet/${d.approval_id}`}>trang quy trình duyệt</Link>.</>}
        </div>
      )}

      {d.direct ? (
        <section className="card mb-4 overflow-x-auto">
          <div className="card-h">Hàng giao · {d.coil_count} cuộn</div>
          <table className="tbl">
            <thead><tr><th>#</th><th>Mã</th><th>Tên hàng</th><th>Nhãn</th><th>Quy cách</th><th className="num">Số cuộn</th>
              <th className="num print:hidden">Kho còn giao được</th><th className="num">Đã xuất</th><th className="num">Mét thực xuất</th></tr></thead>
            <tbody>{(items ?? []).map((i) => (
              <tr key={i.id}>
                <td>{i.line_no}</td><td className="mono font-medium">{i.product_code}</td><td>{i.product_name}</td><td>{i.brand}</td>
                <td>{i.pack_m ? `${nf(i.pack_m)} m/cuộn` : 'Cuộn lẻ'}</td><td className="num font-medium">{i.coils}</td>
                <td className={`num print:hidden ${['DRAFT', 'PENDING_APPROVAL', 'APPROVED'].includes(d.status) && i.free_coils < i.coils ? 'text-bad' : ''}`}>{d.status === 'SHIPPED' || d.status === 'CANCELLED' ? '—' : i.free_coils}</td>
                <td className="num">{i.shipped_coils ?? '—'}</td><td className="num">{i.shipped_m === null ? '—' : nf(i.shipped_m)}</td>
              </tr>
            ))}</tbody>
          </table>
          {editable && (
            <form action={saveDelivery} className="border-t border-line bg-sunk/50 p-4 print:hidden">
              <input type="hidden" name="delivery_id" value={id} />
              <div className="mb-3 grid gap-3 sm:grid-cols-3">
                <label className="lbl"><span className="req">Khách hàng</span><input className="inp" name="customer_name" defaultValue={d.customer_name ?? ''} required /></label>
                <label className="lbl">Ngày giao<input className="inp" type="date" name="ship_date" defaultValue={d.ship_date ?? ''} /></label>
                <label className="lbl">Ghi chú<input className="inp" name="note" defaultValue={d.note ?? ''} /></label>
              </div>
              <ItemsFields groups={groups ?? []} rows={(items ?? []).map((i) => ({ product_code: i.product_code, brand: i.brand, pack_m: i.pack_m, coils: i.coils }))} extraRows={2} />
              <div className="mt-3"><SubmitButton className="btn">Lưu lệnh giao</SubmitButton></div>
            </form>
          )}
        </section>
      ) : (
        <section className="card mb-4 overflow-x-auto">
          <div className="card-h">Bobin theo đơn bán {d.so_no} · {d.reel_count} bobin · {nf(d.total_m)} m</div>
          <table className="tbl">
            <thead><tr><th>#</th><th>Bobin</th><th>Sản phẩm</th><th>Lô</th><th>Vị trí</th><th className="num">Mét</th></tr></thead>
            <tbody>{(lines ?? []).map((l, i) => (
              <tr key={l.id}><td>{i + 1}</td><td className="mono font-medium">{l.hu_no}</td><td><span className="mono">{l.product_code}</span> · {l.product_name}</td>
                <td className="mono">{l.lot_no}</td><td>{l.location_code ?? '—'}</td><td className="num">{nf(l.qty_m)}</td></tr>
            ))}</tbody>
          </table>
        </section>
      )}

      {canShipDirect && (
        <section className="card mb-4 print:hidden" id="ship">
          <div className="card-h">Nhập &quot;đã giao&quot; theo phiếu xuất có chữ ký</div>
          <form action={shipDirect} className="flex flex-col gap-3 p-4">
            <input type="hidden" name="delivery_id" value={id} />
            <div className="grid gap-3 sm:grid-cols-2">
              <label className="lbl"><span className="req">Người giữ kho TP đã giao (ký phiếu)</span>
                <select className="inp inp-y" name="giver_code" required defaultValue={kp.length === 1 ? kp[0].code : ''}>
                  <option value="" disabled>Chọn người giữ kho thành phẩm</option>
                  {kp.map((k) => <option key={k.code} value={k.code}>{k.code}{k.full_name ? ` · ${k.full_name}` : ''}</option>)}
                </select></label>
              <label className="lbl">Số phiếu giấy<input className="inp" name="paper_no" /></label>
            </div>
            {kp.length === 0 && <p className="text-[13px] text-bad">Chưa khai báo người giữ kho thành phẩm: TP SX giao ở Nhân sự xưởng → Người.</p>}
            <table className="tbl">
              <thead><tr><th>Chủng loại</th><th className="num">Lệnh giao</th><th className="num">Số cuộn đã xuất</th></tr></thead>
              <tbody>{(items ?? []).map((i) => (
                <tr key={i.id}>
                  <td>{kindLabel(i.product_code, i.brand, i.pack_m)}</td><td className="num">{i.coils}</td>
                  <td className="num"><input type="hidden" name="item_id" value={i.id} />
                    <input className="inp w-24 text-right" name={`shipped_${i.id}`} defaultValue={String(i.coils)} inputMode="numeric" aria-label={`Số cuộn đã xuất ${i.product_code}`} /></td>
                </tr>
              ))}</tbody>
            </table>
            <p className="text-[12.5px] text-muted">MES tự chọn cuộn QC Đạt trong kho, lô cũ trước, để trừ tồn (không cần quét QR). Giao thiếu thì nhập đúng số cuộn thực giao, Giám đốc nhận thông báo.</p>
            <div><SubmitButton>Ghi đã giao, trừ tồn</SubmitButton></div>
          </form>
        </section>
      )}
      {canShipScan && (
        <section className="card print:hidden">
          <div className="card-h">Quét đủ từng bobin lên xe</div>
          <form action={ship} className="flex flex-col gap-3 p-4">
            <input type="hidden" name="delivery_id" value={id} />
            <ScanList name="items" warehouse="KTP" kinds={['FG']} hint="Quét sai bobin hoặc thiếu bobin thì hệ thống không cho xuất." />
            <div><SubmitButton>Xuất kho giao hàng</SubmitButton></div>
          </form>
        </section>
      )}
      {d.direct && d.status === 'DRAFT' && maker && (
        <details className="card p-4 print:hidden">
          <summary className="cursor-pointer text-[15px] font-medium text-bad">Hủy lệnh giao</summary>
          <form action={cancelDelivery} className="mt-3 flex flex-wrap items-end gap-2">
            <input type="hidden" name="delivery_id" value={id} />
            <label className="lbl"><span className="req">Lý do hủy</span><input className="inp w-72" name="reason" required /></label>
            <SubmitButton className="btn btn-bad-o">Hủy lệnh giao</SubmitButton>
          </form>
        </details>
      )}
      {d.direct && d.status === 'SHIPPED' && (lines ?? []).length > 0 && (
        <details className="card overflow-x-auto">
          <summary className="card-h cursor-pointer">Cuộn MES đã trừ tồn ({(lines ?? []).length})</summary>
          {(lines ?? []).length ? (
            <table className="tbl"><thead><tr><th>Số cuộn trong MES</th><th>Sản phẩm</th><th>Lô</th><th className="num">Mét</th></tr></thead>
              <tbody>{(lines ?? []).map((l) => (
                <tr key={l.id}><td className="mono">{l.hu_no}</td><td>{l.product_code}</td><td className="mono">{l.lot_no}</td><td className="num">{nf(l.qty_m)}</td></tr>
              ))}</tbody></table>
          ) : <Empty>—</Empty>}
        </details>
      )}
      <div className="mt-10 hidden grid-cols-4 text-center print:grid">
        <div><b>Người giao (giữ kho TP)</b></div><div><b>Người nhận</b></div><div><b>Kế toán SX</b></div><div><b>Giám đốc</b></div>
      </div>
    </>
  );
}
