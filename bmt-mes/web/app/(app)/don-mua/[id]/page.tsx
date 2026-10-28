import Link from 'next/link';
import { notFound } from 'next/navigation';
import { Send, Trash2 } from 'lucide-react';
import { AdminTools } from '@/components/admin-tools';
import { PrintButton } from '@/components/print-button';
import { StageBar, type Stage } from '@/components/stage-bar';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Pill, StatusPill, Toolbar } from '@/components/ui';
import type { Approval } from '@/lib/approvals';
import { df, nf, numIn } from '@/lib/format';
import { PO_STATUS, isBuyer, type Po, type PoLine } from '@/lib/purchase';
import { requirePage, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { addSupplier, cancelPo, deletePoLine, movePoLines, savePoHeader, savePoLine, submitPo } from '../actions';

export const metadata = { title: 'Đơn mua hàng' };

export default async function PoDetail({ params, searchParams }:
  { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; err?: string }> }) {
  const { id } = await params;
  const sp = await searchParams;
  await requirePage('don-mua');
  const me = await requirePerm('purchase', 'view');
  const supabase = await createClient();
  const { data: po } = await supabase.schema('app').from('v_pos').select('*').eq('id', id).maybeSingle<Po>();
  if (!po) notFound();
  const [{ data: lines }, { data: req }, { data: sups }, { data: mats }, { data: flow }] = await Promise.all([
    supabase.schema('app').from('v_po_lines').select('*').eq('po_id', id).order('line_no').returns<PoLine[]>(),
    po.request_id ? supabase.schema('app').from('v_approvals').select('*').eq('id', po.request_id).maybeSingle<Approval>() : Promise.resolve({ data: null }),
    supabase.schema('core').from('partners').select('id, code, name').eq('is_supplier', true).eq('active', true).order('name'),
    supabase.schema('app').from('v_materials').select('code, name, uom').order('code'),
    supabase.schema('wf').from('approval_steps').select('seq, level_label, role_code').eq('doc_type', 'PO').eq('enabled', true).order('seq'),
  ]);
  const draft = po.status === 'DRAFT';
  const { data: reviewEdit } = po.status === 'PENDING_APPROVAL'
    ? await supabase.schema('app').rpc('can_review_edit', { p_doc_type: 'PO', p_doc_id: id })
    : { data: false };
  const reviewer = reviewEdit === true;
  const buyer = isBuyer(me.roles);
  const editable = (draft && buyer) || reviewer;
  const showPrice = me.can_see_price;
  const fromMrp = (lines ?? []).some((l) => l.need_qty !== null);
  const total = (lines ?? []).reduce((s, l) => s + (l.unit_price === null ? 0 : Number(l.qty) * Number(l.unit_price)), 0);
  const stages: Stage[] = req?.steps ?? [
    { seq: 0, label: 'NV mua hàng kiểm tra, duyệt gửi', state: draft ? 'current' : 'done' },
    ...(flow ?? []).map((s) => ({ seq: s.seq, label: s.level_label, role: s.role_code, state: 'todo' as const })),
  ];
  const summary = `${po.supplier_name ?? 'Chưa chọn NCC'} · ${po.line_count} dòng${po.plan_no ? ` · ${po.plan_no}` : ''}${po.pr_no ? ` · ${po.pr_no}` : ''}`;
  const otherSups = (sups ?? []).filter((s) => s.id !== po.supplier_id);

  return (
    <>
      <Toolbar title={<span>{po.po_no} – {po.supplier_name ?? 'chưa chọn NCC'}</span>}
        actions={<>
          {req && <Link className="btn btn-soft print:hidden" href={`/duyet/${req.id}`}>Xem quy trình duyệt</Link>}
          {draft && buyer && (lines?.length ?? 0) > 0 && (
            <form action={submitPo} className="print:hidden">
              <input type="hidden" name="po_id" value={id} /><input type="hidden" name="po_no" value={po.po_no} /><input type="hidden" name="summary" value={summary} />
              <SubmitButton className="btn btn-pri"><Send size={15} />Duyệt, gửi TP Mua</SubmitButton>
            </form>
          )}
          <PrintButton />
          <Link className="btn print:hidden" href="/don-mua">Đóng</Link>
        </>} />
      <div className="-mx-4 mb-4 md:-mx-5 print:hidden"><StageBar stages={stages} /></div>
      <div className="print:hidden"><Flash ok={sp.ok} err={sp.err} /></div>
      {draft && buyer && (
        <div role="note" id="buyer-check" className="mb-4 rounded border-l-4 border-warn bg-warn-soft px-4 py-2.5 text-[14px] print:hidden">
          <b>NV mua kiểm tra trước khi gửi:</b> chọn nhà cung cấp (thêm NCC mới ở khung bên phải), nhập đơn giá, ngày về từng dòng; vật tư mua ở NCC khác thì tích dòng và chuyển sang NCC đó (MES tự tách đơn).
          Xong bấm <b>Duyệt, gửi TP Mua</b>. Không mua nữa thì hủy đơn (ghi lý do).
        </div>
      )}
      {reviewer && (
        <div role="note" id="review-edit" className="mb-4 rounded border-l-4 border-brand bg-brand-soft px-4 py-2.5 text-[14px] print:hidden">
          <b>Bạn đang duyệt đơn mua này</b> nên được sửa nhà cung cấp, số lượng, giá, ngày về trước khi duyệt. Mỗi lần sửa ghi vào lịch sử duyệt và báo NV mua.
          {req && <> Sửa xong bấm duyệt ở <Link className="link" href={`/duyet/${req.id}`}>trang quy trình duyệt</Link>.</>}
        </div>
      )}
      {me.roles.includes('ADMIN') && (
        <div className="print:hidden">
          <AdminTools docType="PO" docId={id} docNo={po.po_no} requestId={req?.id} pending={req?.status === 'PENDING'} canReopen={!draft}
            back={`/don-mua/${id}`} after="/don-mua" />
        </div>
      )}

      <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_340px]">
        <section className="card overflow-x-auto">
          <div className="card-h"><h2>Hàng đặt mua</h2><span className="text-[13px] text-muted">{lines?.length ?? 0} dòng</span></div>
          <table className="tbl">
            <thead><tr>
              {draft && buyer && <th className="print:hidden" />}
              <th>Mã VT</th><th>Vật tư</th>
              {fromMrp && <><th className="num">Nhu cầu SX</th><th className="num">Tồn đạt QC</th><th className="num" title="Hàng đang về theo đơn đã duyệt">Đang về</th></>}
              <th className="num">Số mua</th><th>ĐVT</th>{showPrice && <th className="num">Đơn giá</th>}{showPrice && <th className="num">Thành tiền</th>}
              <th>Ngày về</th><th className="num">Đã nhận</th>{editable && <th className="print:hidden" />}
            </tr></thead>
            <tbody>
              {(lines ?? []).map((l) => (
                <tr key={l.id}>
                  {draft && buyer && <td className="print:hidden"><input type="checkbox" name="line" value={l.id} form="move-form" aria-label={`Chọn ${l.material_code}`} /></td>}
                  <td className="mono font-medium">{l.material_code}</td>
                  <td className="min-w-[170px]">{l.material_name}{l.note && <div className="text-[12px] text-muted">{l.note}</div>}</td>
                  {fromMrp && <><td className="num">{nf(l.need_qty, 2)}</td><td className="num">{nf(l.available, 2)}</td><td className="num">{nf(l.incoming, 2)}</td></>}
                  {editable ? (
                    <td colSpan={showPrice ? 5 : 3} className="print:hidden">
                      <form action={savePoLine} className="flex flex-wrap items-center justify-end gap-1">
                        <input type="hidden" name="po_id" value={id} /><input type="hidden" name="line_id" value={l.id} />
                        <input className="inp w-[100px] py-1 text-right" name="qty" defaultValue={numIn(l.qty)} inputMode="decimal" aria-label={`Số mua ${l.material_code}`} />
                        <span className="w-8 text-[13px]">{l.uom}</span>
                        {showPrice && <input className={`inp w-[110px] py-1 text-right ${l.priced ? '' : 'inp-y'}`} name="unit_price" defaultValue={numIn(l.unit_price)} inputMode="decimal" placeholder="Đơn giá" aria-label={`Đơn giá ${l.material_code}`} />}
                        <input className="inp w-[140px] py-1" type="date" name="expected_date" defaultValue={l.expected_date ?? ''} aria-label={`Ngày về ${l.material_code}`} />
                        <SubmitButton className="btn btn-sm" pendingText="…">Lưu</SubmitButton>
                      </form>
                      {l.mrp_qty !== null && Number(l.mrp_qty) !== Number(l.qty) && <div className="text-right text-[12px] text-warn">MES đề nghị {nf(l.mrp_qty, 2)}</div>}
                    </td>
                  ) : (
                    <>
                      <td className="num font-medium">{nf(l.qty, 2)}{l.mrp_qty !== null && Number(l.mrp_qty) !== Number(l.qty) && <div className="text-[12px] font-normal text-warn">MES đề nghị {nf(l.mrp_qty, 2)}</div>}</td>
                      <td>{l.uom}</td>
                      {showPrice && <td className="num">{l.unit_price === null ? <Pill tone="warn">Chưa có giá</Pill> : nf(l.unit_price)}</td>}
                      {showPrice && <td className="num">{l.amount === null ? '—' : nf(l.amount)}</td>}
                      <td>{df(l.expected_date)}</td>
                    </>
                  )}
                  <td className="num">{Number(l.received_qty) > 0 ? nf(l.received_qty, 2) : '—'}</td>
                  {editable && (
                    <td className="print:hidden"><form action={deletePoLine}><input type="hidden" name="po_id" value={id} /><input type="hidden" name="line_id" value={l.id} />
                      <SubmitButton className="btn btn-sm btn-bad-o" pendingText="…"><Trash2 size={14} />Bỏ</SubmitButton></form></td>
                  )}
                </tr>
              ))}
              {(lines ?? []).length === 0 && <tr><td colSpan={14}><Empty>Chưa có dòng vật tư.</Empty></td></tr>}
            </tbody>
            {showPrice && (lines?.length ?? 0) > 0 && (
              <tfoot><tr><td colSpan={20} className="px-3 py-2 text-right font-medium">Tổng (dòng có giá): {nf(total)} đ</td></tr></tfoot>
            )}
          </table>
          {draft && buyer && otherSups.length > 0 && (
            <form id="move-form" action={movePoLines} className="flex flex-wrap items-end gap-2 border-t border-line bg-sunk/50 p-4 print:hidden">
              <input type="hidden" name="po_id" value={id} />
              <label className="lbl">Chuyển dòng đã tích sang NCC
                <select className="inp" name="supplier_id" required defaultValue="">
                  <option value="" disabled>Chọn nhà cung cấp</option>
                  {otherSups.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
                </select></label>
              <SubmitButton className="btn">Chuyển sang đơn của NCC này</SubmitButton>
              <span className="text-[12.5px] text-muted">MES gom vào đơn nháp của NCC đó (cùng kế hoạch / đề xuất), chưa có thì lập đơn mới.</span>
            </form>
          )}
          {editable && (
            <form action={savePoLine} className="grid gap-3 border-t border-line bg-sunk/50 p-4 md:grid-cols-[2fr_1fr_1fr_1fr_auto] md:items-end print:hidden">
              <input type="hidden" name="po_id" value={id} />
              <datalist id="mats">{(mats ?? []).map((m) => <option key={m.code} value={`${m.code} · ${m.name} (${m.uom})`} />)}</datalist>
              <label className="lbl"><span className="req">Thêm vật tư</span><input className="inp" name="material_code" list="mats" required /></label>
              <label className="lbl"><span className="req">Số lượng</span><input className="inp text-right" name="qty" inputMode="decimal" required /></label>
              {showPrice ? <label className="lbl">Đơn giá<input className="inp text-right" name="unit_price" inputMode="decimal" /></label> : <span />}
              <label className="lbl">Ngày về<input className="inp" type="date" name="expected_date" /></label>
              <SubmitButton className="btn btn-pri">+ Thêm dòng</SubmitButton>
            </form>
          )}
        </section>

        <aside className="flex flex-col gap-4">
          <section className="card p-4">
            <h2 className="mb-2 text-[16px] font-medium">Thông tin đơn mua</h2>
            {editable ? (
              <form action={savePoHeader} className="flex flex-col gap-3">
                <input type="hidden" name="po_id" value={id} />
                <label className="lbl"><span className="req">Nhà cung cấp</span>
                  <select className={`inp ${po.supplier_id ? '' : 'inp-y'}`} name="supplier_id" defaultValue={po.supplier_id ?? ''}>
                    <option value="">Chưa chọn</option>
                    {(sups ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
                  </select></label>
                <label className="lbl">Ngày hàng về<input className="inp" type="date" name="expected_date" defaultValue={po.expected_date ?? ''} /></label>
                <label className="lbl">Điều khoản thanh toán<input className="inp" name="payment_terms" defaultValue={po.payment_terms ?? ''} placeholder="Ví dụ: 30 ngày sau khi nhận hàng" /></label>
                <label className="lbl">Ghi chú<textarea className="inp" name="note" rows={2} defaultValue={po.note ?? ''} /></label>
                <label className="flex items-center gap-2 text-[14px]"><input type="checkbox" name="is_import" defaultChecked={po.is_import} />Hàng nhập khẩu</label>
                <div><SubmitButton className="btn">Lưu thông tin</SubmitButton></div>
              </form>
            ) : (
              <dl className="text-[14px]">
                <dt className="text-muted">Nhà cung cấp</dt><dd className="mb-2">{po.supplier_name ?? '—'}{po.supplier_tax_code && <div className="text-[12.5px] text-muted">MST {po.supplier_tax_code}</div>}</dd>
                <dt className="text-muted">Ngày hàng về</dt><dd className="mb-2">{df(po.expected_date)}</dd>
                <dt className="text-muted">Điều khoản thanh toán</dt><dd className="mb-2">{po.payment_terms ?? '—'}</dd>
                <dt className="text-muted">Ghi chú</dt><dd className="mb-2">{po.note ?? '—'}</dd>
              </dl>
            )}
            <dl className="mt-3 border-t border-line pt-3 text-[14px]">
              <dt className="text-muted">Trạng thái</dt><dd className="mb-2"><StatusPill map={PO_STATUS} value={po.status} />{po.cancel_reason && <div className="text-[12.5px] text-muted">{po.cancel_reason}</div>}</dd>
              <dt className="text-muted">Nguồn</dt><dd className="mb-2">{po.source_label}
                {po.plan_no && <> · <Link className="link" href={`/ke-hoach/${po.plan_id}`}>{po.plan_no}</Link></>}
                {po.adj_no && <> · <Link className="link" href={`/ke-hoach/dieu-chinh/${po.adjustment_id}`}>{po.adj_no}</Link></>}
                {po.pr_no && <> · <Link className="link" href={`/de-xuat/${po.pr_id}`}>{po.pr_no}</Link></>}</dd>
              <dt className="text-muted">Ngày lập</dt><dd className="mb-2">{df(po.created_at, true)}</dd>
              {po.has_receipt && <><dt className="text-muted">Nhận hàng</dt><dd><Link className="link" href={`/kho/phieu?q=${po.po_no}`}>Xem phiếu nhập theo đơn</Link></dd></>}
            </dl>
          </section>
          {editable && buyer && (
            <details className="card p-4 print:hidden">
              <summary className="cursor-pointer text-[15px] font-medium text-brand">Thêm nhà cung cấp mới</summary>
              <form action={addSupplier} className="mt-3 flex flex-col gap-2">
                <input type="hidden" name="po_id" value={id} />
                <label className="lbl"><span className="req">Tên nhà cung cấp</span><input className="inp" name="name" required /></label>
                <label className="lbl">Mã số thuế<input className="inp" name="tax_code" /></label>
                <label className="lbl">Người liên hệ, điện thoại<input className="inp" name="contact" /></label>
                <label className="lbl">Địa chỉ<input className="inp" name="address" /></label>
                <div><SubmitButton className="btn">Thêm và chọn cho đơn này</SubmitButton></div>
              </form>
            </details>
          )}
          {draft && buyer && (
            <details className="card p-4 print:hidden">
              <summary className="cursor-pointer text-[15px] font-medium text-bad">Hủy đơn mua</summary>
              <form action={cancelPo} className="mt-3 flex flex-col gap-2">
                <input type="hidden" name="po_id" value={id} />
                <label className="lbl"><span className="req">Lý do hủy</span><input className="inp" name="reason" required placeholder="Ví dụ: dùng tồn kho, đổi NCC…" /></label>
                <div><SubmitButton className="btn btn-bad-o">Hủy đơn</SubmitButton></div>
              </form>
            </details>
          )}
        </aside>
      </div>
      <div className="mt-10 hidden grid-cols-4 text-center print:grid">
        <div><b>NV mua hàng</b></div><div><b>TP Mua hàng</b></div><div><b>Kế toán</b></div><div><b>Giám đốc</b></div>
      </div>
    </>
  );
}
