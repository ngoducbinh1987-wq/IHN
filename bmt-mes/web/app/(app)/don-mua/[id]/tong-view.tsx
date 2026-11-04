import Link from 'next/link';
import { Layers, Send } from 'lucide-react';
import { AdminTools } from '@/components/admin-tools';
import { PrintButton } from '@/components/print-button';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Pill, StatusPill, Toolbar } from '@/components/ui';
import { df, nf, numIn } from '@/lib/format';
import { PO_STATUS, isBuyer, tongState, type Po, type PoLine } from '@/lib/purchase';
import type { Me } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { addSupplierOnly, cancelPo, makeContracts, setPoLine } from '../actions';

// Gợi ý điều khoản thanh toán hay dùng (NV mua gõ tự do được)
const TERMS = ['Trả ngay khi nhận hàng', '30 ngày sau khi nhận hàng', '45 ngày sau khi nhận hàng', 'Tạm ứng 30 %, còn lại khi giao hàng', 'Thanh toán trước 100 %'];

// Đơn mua hàng tổng (migration 9500): NV mua chốt từng dòng (NCC, giá, điều khoản, ngày giao), gom hợp đồng theo NCC, gửi TP Mua
export async function TongView({ po, me, sp }: { po: Po; me: Me; sp: { ok?: string; err?: string } }) {
  const supabase = await createClient();
  const [{ data: lines }, { data: sups }, { data: contracts }] = await Promise.all([
    supabase.schema('app').from('v_po_lines').select('*').eq('po_id', po.id).order('line_no').returns<PoLine[]>(),
    supabase.schema('core').from('partners').select('id, name').eq('is_supplier', true).eq('active', true).order('name'),
    supabase.schema('app').from('v_pos').select('*').eq('parent_id', po.id).order('created_at').returns<Po[]>(),
  ]);
  const buyer = isBuyer(me.roles);
  const open = po.status === 'DRAFT';
  const edit = open && buyer;
  const showPrice = me.can_see_price;
  const [stLabel, stTone] = tongState(po);
  const ready = (lines ?? []).filter((l) => l.ready).length;
  const live = (contracts ?? []).filter((c) => c.status !== 'CANCELLED');
  const fromMrp = (lines ?? []).some((l) => l.need_qty !== null);

  return (
    <>
      <Toolbar title={<span>{po.po_no} – Đơn mua hàng tổng</span>}
        actions={<><PrintButton /><Link className="btn print:hidden" href="/don-mua">Đóng</Link></>} />
      <div className="print:hidden"><Flash ok={sp.ok} err={sp.err} /></div>

      <section className="card mb-4 grid gap-x-6 gap-y-2 p-4 text-[14px] sm:grid-cols-2 lg:grid-cols-4" id="tong-info">
        <div><div className="text-[12.5px] text-muted">Trạng thái</div><Pill tone={stTone}>{stLabel}</Pill></div>
        <div><div className="text-[12.5px] text-muted">Nhận đơn</div>{df(po.created_at, true)}</div>
        <div><div className="text-[12.5px] text-muted">Hạn gửi đủ hợp đồng (5 ngày làm việc)</div>
          <b className={po.overdue ? 'text-bad' : ''}>{df(po.due_date)}</b>{po.overdue && <span className="text-bad"> · quá hạn</span>}
          {po.all_submitted_at && <div className="text-[12.5px] text-muted">Gửi đủ lúc {df(po.all_submitted_at, true)}</div>}</div>
        <div><div className="text-[12.5px] text-muted">Nguồn</div>{po.source_label}
          {po.plan_no && <> · <Link className="link" href={`/ke-hoach/${po.plan_id}`}>{po.plan_no}</Link></>}
          {po.adj_no && <> · <Link className="link" href={`/ke-hoach/dieu-chinh/${po.adjustment_id}`}>{po.adj_no}</Link></>}
          {po.pr_no && <> · <Link className="link" href={`/de-xuat/${po.pr_id}`}>{po.pr_no}</Link></>}</div>
        <div><div className="text-[12.5px] text-muted">Dòng chưa gom hợp đồng</div><b>{lines?.length ?? 0}</b>{(lines?.length ?? 0) > 0 && <span className="text-muted"> · {ready} dòng đã chốt đủ</span>}</div>
        <div><div className="text-[12.5px] text-muted">Hợp đồng</div><b>{live.length}</b>{live.length > 0 && <span className="text-muted"> · {po.contract_approved} Giám đốc đã duyệt</span>}</div>
        {po.done_at && <div><div className="text-[12.5px] text-muted">Hoàn tất</div>{df(po.done_at, true)}</div>}
        {po.cancel_reason && <div><div className="text-[12.5px] text-muted">Lý do hủy</div>{po.cancel_reason}</div>}
      </section>

      {edit && (lines?.length ?? 0) > 0 && (
        <div role="note" id="buyer-check" className="mb-4 rounded border-l-4 border-warn bg-warn-soft px-4 py-2.5 text-[14px] print:hidden">
          <b>NV mua:</b> làm việc với nhà cung cấp, chốt cho <b>từng dòng</b>: NCC, đơn giá, điều khoản thanh toán, ngày giao dự kiến (bấm Lưu từng dòng).
          Rồi bấm <b>Gom và gửi TP Mua</b>: MES gom các dòng cùng NCC thành một hợp đồng. Tích dòng để gom một phần (tách nhiều hợp đồng);
          không tích thì gom mọi dòng đã chốt đủ. Hạn gửi đủ hợp đồng: hết ngày <b>{df(po.due_date)}</b>; TP Mua và Giám đốc mỗi người có 1 ngày làm việc để duyệt.
        </div>
      )}
      {me.roles.includes('ADMIN') && (
        <div className="print:hidden">
          <AdminTools docType="PO" docId={po.id} docNo={po.po_no} canReopen={false} back={`/don-mua/${po.id}`} after="/don-mua" />
        </div>
      )}

      <section className="card mb-4 overflow-x-auto" id="dong-tong">
        <div className="card-h"><h2>Vật tư cần mua, chưa vào hợp đồng</h2><span className="text-[13px] text-muted">{lines?.length ?? 0} dòng</span></div>
        {(lines ?? []).length > 0 ? (
          <table className="tbl">
            <thead><tr>
              {edit && <th className="print:hidden" />}
              <th>Vật tư</th>{fromMrp && <th className="num">Nhu cầu SX</th>}<th className="num">Số mua</th>
              <th>Nhà cung cấp</th>{showPrice && <th className="num">Đơn giá</th>}<th>Điều khoản thanh toán</th><th>Ngày giao</th>{edit && <th className="print:hidden" />}
            </tr></thead>
            <tbody>
              {(lines ?? []).map((l) => {
                const f = `r-${l.id}`;
                return (
                  <tr key={l.id} className={edit && !l.ready ? 'bg-warn-soft/30' : undefined}>
                    {edit && <td className="print:hidden"><input type="checkbox" name="line" value={l.id} form="gom-form" disabled={!l.ready} aria-label={`Chọn ${l.material_code}`} /></td>}
                    <td className="min-w-[170px]"><span className="mono font-medium">{l.material_code}</span><div className="text-[13px]">{l.material_name}</div></td>
                    {fromMrp && <td className="num">{nf(l.need_qty, 2)}</td>}
                    {edit ? (
                      <>
                        <td className="num"><div className="flex items-center justify-end gap-1">
                          <input form={f} className="inp w-[96px] py-1 text-right" name="qty" defaultValue={numIn(l.qty)} inputMode="decimal" aria-label={`Số mua ${l.material_code}`} />
                          <span className="text-[13px]">{l.uom}</span></div>
                          {l.mrp_qty !== null && Number(l.mrp_qty) !== Number(l.qty) && <div className="text-[12px] text-warn">MES đề nghị {nf(l.mrp_qty, 2)}</div>}</td>
                        <td><select form={f} className={`inp min-w-[170px] py-1 ${l.supplier_id ? '' : 'inp-y'}`} name="supplier_id" defaultValue={l.supplier_id ?? ''} aria-label={`NCC ${l.material_code}`}>
                          <option value="">Chọn NCC</option>{(sups ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></td>
                        {showPrice && <td><input form={f} className={`inp w-[110px] py-1 text-right ${l.priced ? '' : 'inp-y'}`} name="unit_price" defaultValue={numIn(l.unit_price)} inputMode="decimal" placeholder="Đơn giá" aria-label={`Đơn giá ${l.material_code}`} /></td>}
                        <td><input form={f} className={`inp min-w-[180px] py-1 ${l.payment_terms ? '' : 'inp-y'}`} name="payment_terms" list="terms" defaultValue={l.payment_terms ?? ''} placeholder="Điều khoản" aria-label={`Điều khoản ${l.material_code}`} /></td>
                        <td><input form={f} className={`inp w-[140px] py-1 ${l.expected_date ? '' : 'inp-y'}`} type="date" name="expected_date" defaultValue={l.expected_date ?? ''} aria-label={`Ngày giao ${l.material_code}`} /></td>
                        <td className="print:hidden"><form id={f} action={setPoLine}><input type="hidden" name="po_id" value={po.id} /><input type="hidden" name="line_id" value={l.id} />
                          {!showPrice && <input type="hidden" name="unit_price" value={l.unit_price ?? ''} />}
                          <SubmitButton className="btn btn-sm" pendingText="…">Lưu</SubmitButton></form></td>
                      </>
                    ) : (
                      <>
                        <td className="num">{nf(l.qty, 2)} {l.uom}</td><td>{l.supplier_name ?? '—'}</td>
                        {showPrice && <td className="num">{l.unit_price === null ? '—' : nf(l.unit_price)}</td>}
                        <td>{l.payment_terms ?? '—'}</td><td>{df(l.expected_date)}</td>
                      </>
                    )}
                  </tr>
                );
              })}
            </tbody>
          </table>
        ) : <Empty>{live.length ? 'Mọi dòng đã vào hợp đồng.' : 'Đơn tổng không còn dòng nào.'}</Empty>}
        <datalist id="terms">{TERMS.map((t) => <option key={t} value={t} />)}</datalist>
        {edit && (lines?.length ?? 0) > 0 && (
          <form id="gom-form" action={makeContracts} className="flex flex-wrap items-center gap-2 border-t border-line bg-sunk/50 p-4 print:hidden">
            <input type="hidden" name="po_id" value={po.id} />
            <SubmitButton className="btn btn-pri" name="submit" value="1"><Send size={15} />Gom và gửi TP Mua</SubmitButton>
            <SubmitButton className="btn" name="submit" value="0"><Layers size={15} />Gom thành hợp đồng nháp</SubmitButton>
            <span className="text-[12.5px] text-muted">{ready} / {lines?.length ?? 0} dòng đã chốt đủ NCC, giá, điều khoản, ngày giao. Mỗi NCC một hợp đồng.</span>
          </form>
        )}
      </section>

      <section className="card mb-4 overflow-x-auto" id="hop-dong">
        <div className="card-h"><h2>Hợp đồng / phiếu mua theo đơn tổng</h2><span className="text-[13px] text-muted">TP Mua 1 ngày làm việc → Giám đốc 1 ngày làm việc</span></div>
        {(contracts ?? []).length > 0 ? (
          <table className="tbl">
            <thead><tr><th>Hợp đồng</th><th>Nhà cung cấp</th><th className="num">Dòng</th>{showPrice && <th className="num">Giá trị (đ)</th>}<th>Thanh toán</th><th>Ngày giao</th><th>Trạng thái</th></tr></thead>
            <tbody>{(contracts ?? []).map((c) => (
              <tr key={c.id}>
                <td><Link className="link mono font-medium" href={`/don-mua/${c.id}`}>{c.po_no}</Link></td>
                <td>{c.supplier_name}</td><td className="num">{c.line_count}</td>
                {showPrice && <td className="num">{c.amount === null ? '—' : nf(c.amount)}</td>}
                <td>{c.payment_terms ?? '—'}</td><td>{df(c.expected_date)}</td>
                <td><StatusPill map={PO_STATUS} value={c.status} />{c.cancel_reason && <div className="text-[12px] text-muted">{c.cancel_reason}</div>}</td>
              </tr>
            ))}</tbody>
          </table>
        ) : <Empty>Chưa gom hợp đồng nào.</Empty>}
      </section>

      {edit && (
        <div className="grid gap-4 md:grid-cols-2 print:hidden">
          <details className="card p-4">
            <summary className="cursor-pointer text-[15px] font-medium text-brand">Thêm nhà cung cấp mới</summary>
            <form action={addSupplierOnly} className="mt-3 flex flex-col gap-2">
              <input type="hidden" name="po_id" value={po.id} />
              <label className="lbl"><span className="req">Tên nhà cung cấp</span><input className="inp" name="name" required /></label>
              <label className="lbl">Mã số thuế<input className="inp" name="tax_code" /></label>
              <label className="lbl">Người liên hệ, điện thoại<input className="inp" name="contact" /></label>
              <label className="lbl">Địa chỉ<input className="inp" name="address" /></label>
              <div><SubmitButton className="btn">Thêm (chọn ở cột NCC từng dòng)</SubmitButton></div>
            </form>
          </details>
          {(lines?.length ?? 0) > 0 && (
            <details className="card p-4">
              <summary className="cursor-pointer text-[15px] font-medium text-bad">Hủy các dòng còn lại của đơn tổng</summary>
              <form action={cancelPo} className="mt-3 flex flex-col gap-2">
                <input type="hidden" name="po_id" value={po.id} />
                <label className="lbl"><span className="req">Lý do</span><input className="inp" name="reason" required placeholder="Ví dụ: dùng tồn kho, không mua nữa…" /></label>
                <div><SubmitButton className="btn btn-bad-o">Hủy đơn tổng</SubmitButton></div>
              </form>
            </details>
          )}
        </div>
      )}
    </>
  );
}
