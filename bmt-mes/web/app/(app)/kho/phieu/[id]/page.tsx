import Link from 'next/link';
import { Printer } from 'lucide-react';
import { notFound } from 'next/navigation';
import { SubmitButton } from '@/components/submit-button';
import { Flash, InfoRow, Pill, StatusPill, Toolbar } from '@/components/ui';
import { df, nf } from '@/lib/format';
import { DOC_TYPES, QC_STATUS, REVIEW_STATUS, STOCK_DOC_STATUS, hasRole } from '@/lib/kho';
import { requirePage, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { checkReceipt, confirmDoc, returnDoc, reverseDoc, setPrices } from '../actions';

export const metadata = { title: 'Phiếu kho' };

const REVERSIBLE = ['GR', 'ISSUE_WO', 'RETURN_WO', 'SCRAP_IN', 'FG_IN', 'WIP_IN', 'CUST_RETURN', 'RETURN_SUP'];

export default async function DocDetail({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; err?: string }> }) {
  const { id } = await params;
  const sp = await searchParams;
  await requirePage('kho-phieu');
  const me = await requirePerm('inventory', 'view');
  const supabase = await createClient();
  const { data: d } = await supabase.schema('app').from('v_stock_docs').select('*').eq('id', id).maybeSingle();
  if (!d) notFound();
  const [{ data: lines }, { data: prices }, { data: gr }] = await Promise.all([
    supabase.schema('app').from('v_stock_doc_lines').select('*').eq('doc_id', id).order('line_no'),
    me.can_see_price ? supabase.schema('app').rpc('doc_line_prices', { p_doc: id }) : Promise.resolve({ data: [] as { line_id: string; unit_cost: number | null; amount: number | null }[] }),
    d.doc_type === 'GR' && d.ref_type === 'GR'
      ? supabase.schema('purchase').from('goods_receipts').select('gr_no, delivery_note, no_po_reason, checked_by, checked_at, check_note').eq('id', d.ref_id).maybeSingle()
      : Promise.resolve({ data: null }),
  ]);
  const price = (lineId: string) => (prices ?? []).find((p: { line_id: string }) => p.line_id === lineId) as { unit_cost: number | null; amount: number | null } | undefined;
  const kt = hasRole(me, 'KT_KHO');
  const mine = d.created_by === me.id || d.posted_by === me.id;
  const canReview = kt && d.status === 'POSTED' && d.review_status === 'PENDING' && !mine;
  const canPrice = kt && d.price_pending && d.status === 'DRAFT';
  const canReverse = kt && d.status === 'POSTED' && !d.reversal_of && !d.reversed_by && REVERSIBLE.includes(d.doc_type);
  const canCheck = hasRole(me, 'MUA_NV', 'MUA_TP') && gr && !gr.checked_at;
  // Cuộn thành phẩm không in tem QR (chỉ dán tem QC PASS)
  const hus = (lines ?? []).filter((l) => l.hu_id && Number(l.qty) > 0 && l.item_kind !== 'FG').map((l) => l.hu_id);
  const total = (prices ?? []).reduce((s: number, p: { amount: number | null }) => s + Number(p.amount ?? 0), 0);
  return (
    <>
      <Toolbar title={<span>{d.doc_no} · {DOC_TYPES[d.doc_type] ?? d.doc_type}</span>} reload={`/kho/phieu/${id}`}
        actions={<>
          {hus.length > 0 && <Link className="btn btn-soft" href={`/in/tem?doc=${id}`} target="_blank"><Printer size={16} />In tem ({hus.length})</Link>}
          {d.approval_id && <Link className="btn btn-soft" href={`/duyet/${d.approval_id}`}>Xem quy trình duyệt</Link>}
          <Link className="btn" href="/kho/phieu">Đóng</Link>
        </>} />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /></div>
      <div className="grid gap-4 lg:grid-cols-[1fr_340px]">
        <section className="card overflow-x-auto">
          <div className="card-h">Dòng phiếu · {lines?.length ?? 0} dòng</div>
          <table className="tbl">
            <thead><tr><th>#</th><th>Mã QR</th><th>Hàng</th><th>Lô</th><th>Vị trí</th><th className="num">Số lượng</th>{d.doc_type === 'GR' && <th className="num">Cân tổng / bì</th>}
              {me.can_see_price && <><th className="num">Đơn giá</th><th className="num">Thành tiền</th></>}<th>Ghi chú</th></tr></thead>
            <tbody>{(lines ?? []).map((l) => {
              const p = price(l.id);
              return (
                <tr key={l.id}>
                  <td>{l.line_no}</td>
                  <td>{l.hu_no ? <Link className="link mono" href={`/kho/quet?ma=${l.hu_no}`}>{l.hu_no}</Link> : '—'}</td>
                  <td className="min-w-[160px]"><span className="mono">{l.item_code}</span> · {l.item_name}</td>
                  <td className="mono">{l.lot_no}<div><StatusPill map={QC_STATUS} value={l.qc_status} /></div></td>
                  <td className="whitespace-nowrap">{l.location_code ?? '—'}{l.to_location_code ? ` → ${l.to_location_code}` : ''}</td>
                  <td className={`num font-medium ${Number(l.qty) < 0 ? 'text-bad' : ''}`}>{nf(l.qty, 3)} {l.uom}</td>
                  {d.doc_type === 'GR' && <td className="num text-muted">{l.gross_kg ? `${nf(l.gross_kg, 2)} / ${nf(l.tare_kg, 2)}` : '—'}</td>}
                  {me.can_see_price && <>
                    <td className="num">{canPrice
                      ? <input form="price-form" className="inp inp-y w-28 text-right" name={`price_${l.id}`} defaultValue={p?.unit_cost ?? ''} placeholder="đ/đơn vị" aria-label={`Đơn giá dòng ${l.line_no}`} />
                      : p?.unit_cost != null ? nf(p.unit_cost) : '—'}</td>
                    <td className="num">{p?.amount != null ? nf(p.amount) : '—'}</td></>}
                  <td className="text-[13px]">{l.reason ?? l.note ?? ''}</td>
                </tr>
              );
            })}</tbody>
          </table>
          {me.can_see_price && total > 0 && <div className="border-t border-line px-4 py-2 text-right text-[14px]">Tổng giá trị: <b>{nf(total)} đ</b></div>}
          {canPrice && <form action={setPrices} id="price-form" className="border-t border-line p-3"><input type="hidden" name="doc_id" value={id} />
            <p className="mb-2 text-[12.5px] text-muted">Nhập đơn giá theo hóa đơn (một dòng mỗi lô là đủ, các đơn vị cùng lô dùng chung giá). Ghi sổ ngay sau khi lưu.</p>
            <SubmitButton className="btn btn-pri">Lưu giá và ghi sổ</SubmitButton></form>}
        </section>

        <aside className="flex flex-col gap-4">
          <section className="card px-4 py-2">
            <InfoRow label="Trạng thái">{d.price_pending ? <Pill tone="warn">Chờ Kế toán SX nhập giá</Pill> : <StatusPill map={STOCK_DOC_STATUS} value={d.status} />}</InfoRow>
            <InfoRow label="Kho">{d.warehouse_code}{d.to_warehouse_code && d.to_warehouse_code !== d.warehouse_code ? ` → ${d.to_warehouse_code}` : ''}</InfoRow>
            {d.ref_no && <InfoRow label="Tham chiếu">{d.ref_no}{d.req_no ? ` · ${d.req_no}` : ''}</InfoRow>}
            <InfoRow label="Người lập">{d.created_by_name ?? '—'} · {df(d.created_at, true)}</InfoRow>
            {d.posted_at && <InfoRow label="Ghi sổ">{d.posted_by_name ?? '—'} · {df(d.posted_at, true)}</InfoRow>}
            {d.receiver_name && <InfoRow label="Người nhận">{d.receiver_name}{d.received_at ? ` · đã nhận ${df(d.received_at, true)}` : ' · chưa xác nhận'}</InfoRow>}
            {d.delegated && <InfoRow label="Giữ kho">theo ủy quyền · chứng kiến: {d.witness_name ?? '—'}</InfoRow>}
            {d.off_hours_reason && <InfoRow label="Ngoài giờ">{d.off_hours_reason}</InfoRow>}
            {d.reason_name && <InfoRow label="Lý do">{d.reason_name}</InfoRow>}
            {d.note && <InfoRow label="Ghi chú">{d.note}</InfoRow>}
            {d.reversal_of && <InfoRow label="Đảo phiếu"><Link className="link" href={`/kho/phieu/${d.reversal_of}`}>xem phiếu gốc</Link></InfoRow>}
            {d.reversed_by && <InfoRow label="Đã đảo bởi"><Link className="link" href={`/kho/phieu/${d.reversed_by}`}>xem phiếu đảo</Link></InfoRow>}
            {gr && <InfoRow label="Đối chiếu PO">{gr.checked_at ? `NV mua đã đối chiếu ${df(gr.checked_at, true)}${gr.check_note ? ' · ' + gr.check_note : ''}` : 'chưa đối chiếu'}{gr.no_po_reason ? ` · không theo PO: ${gr.no_po_reason}` : ''}{gr.delivery_note ? ` · PGH ${gr.delivery_note}` : ''}</InfoRow>}
          </section>

          {d.status === 'POSTED' && (
            <section className="card">
              <div className="card-h">Kế toán SX duyệt<StatusPill map={REVIEW_STATUS} value={d.review_status} /></div>
              <div className="p-4 text-[14px]">
                {d.reviewed_by_name && <p className="mb-2">{d.reviewed_by_name} · {df(d.reviewed_at, true)}{d.review_note ? <><br /><span className="text-muted">{d.review_note}</span></> : null}</p>}
                {canReview ? (
                  <form action={confirmDoc} className="flex flex-col gap-2">
                    <input type="hidden" name="doc_id" value={id} />
                    <label className="lbl">Ghi chú (bắt buộc khi trả lại)<input className="inp" name="note" /></label>
                    <div className="flex flex-wrap gap-2">
                      <SubmitButton className="btn btn-ok">Xác nhận đúng</SubmitButton>
                      <SubmitButton className="btn btn-bad-o" formAction={returnDoc}>Trả lại</SubmitButton>
                    </div>
                  </form>
                ) : kt && mine && d.review_status === 'PENDING' ? <p className="text-muted">Bạn lập/ghi sổ phiếu này nên không tự duyệt.</p> : null}
              </div>
            </section>
          )}

          {canCheck && (
            <form action={checkReceipt} className="card flex flex-col gap-2 p-4">
              <input type="hidden" name="doc_id" value={id} />
              <b className="text-[14px]">NV mua hàng đối chiếu PO</b>
              <label className="lbl">Ghi chú (sai, thiếu, lỗi…)<input className="inp" name="note" /></label>
              <SubmitButton className="btn btn-soft">Đã đối chiếu</SubmitButton>
            </form>
          )}

          {canReverse && (
            <form action={reverseDoc} className="card flex flex-col gap-2 p-4">
              <input type="hidden" name="doc_id" value={id} />
              <b className="text-[14px]">Đảo phiếu (hủy phiếu đã ghi sổ)</b>
              <p className="text-[12.5px] text-muted">Tạo phiếu ngược chiều cùng số lượng, giá theo phiếu gốc. Phiếu gốc giữ nguyên để tra cứu.</p>
              <label className="lbl"><span className="req">Lý do</span><input className="inp" name="reason" required /></label>
              <SubmitButton className="btn btn-bad-o">Lập phiếu đảo</SubmitButton>
            </form>
          )}
        </aside>
      </div>
    </>
  );
}
