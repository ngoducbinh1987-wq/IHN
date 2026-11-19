import Link from 'next/link';
import { notFound } from 'next/navigation';
import { MaterialPicker } from '@/components/material-picker';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Pill, Section, StatusPill, Toolbar } from '@/components/ui';
import { df, nf } from '@/lib/format';
import { PO_STATUS, type Po } from '@/lib/purchase';
import { requirePage, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { SUPPLIER_FIELDS, canEditSupplier, groupMaterials, isBuyLead, type MaterialOption, type Supplier, type SupplierMaterial } from '@/lib/suppliers';
import { deleteSupplier, setSupplierActive, setSupplierMaterials, updateSupplier } from '../actions';

export const metadata = { title: 'Nhà cung cấp' };

type Hist = { at: string; user_name: string | null; action: string; changes: Record<string, unknown> | null };
const show = (v: unknown) => (v === null || v === undefined || v === '' ? '(trống)' : String(v));

// Một dòng lịch sử → câu tiếng Việt
function histText(h: Hist): string[] {
  const c = h.changes ?? {};
  if (h.action === 'INSERT') return ['Thêm nhà cung cấp'];
  if (h.action === 'ADMIN_DELETE') return [`Xóa nhà cung cấp. Lý do: ${show(c.reason)}`];
  if (h.action === 'MATERIALS') {
    const added = (c.added as string[] | undefined) ?? [], removed = (c.removed as string[] | undefined) ?? [];
    return [added.length ? `Thêm mặt hàng: ${added.join(', ')}` : '', removed.length ? `Bỏ mặt hàng: ${removed.join(', ')}` : ''].filter(Boolean);
  }
  const out: string[] = [];
  const act = c.active as [unknown, unknown] | undefined;
  if (act) out.push(act[1] === true ? 'Cho dùng lại' : `Ngừng dùng. Lý do: ${show((c.inactive_reason as [unknown, unknown] | undefined)?.[1])}`);
  for (const [k, label] of Object.entries(SUPPLIER_FIELDS)) {
    if (k === 'inactive_reason') continue;
    const d = c[k] as [unknown, unknown] | undefined;
    if (d) out.push(`${label}: ${show(d[0])} → ${show(d[1])}`);
  }
  return out;
}

export default async function SupplierDetail({ params, searchParams }:
  { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; err?: string }> }) {
  const { id } = await params;
  const sp = await searchParams;
  await requirePage('nha-cung-cap');
  const me = await requirePerm('master', 'view');
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const supabase = await createClient();
  const { data: s } = await supabase.schema('app').from('v_suppliers').select('*').eq('id', id).maybeSingle<Supplier>();
  if (!s) notFound();
  const lead = isBuyLead(me.roles);
  const editable = canEditSupplier(me.roles);
  const showPrice = me.can_see_price;
  const [{ data: items }, { data: pos }, { data: hist }, { data: mats }] = await Promise.all([
    supabase.schema('app').from('v_supplier_materials').select('*').eq('supplier_id', id).order('group_name').order('material_code').returns<SupplierMaterial[]>(),
    supabase.schema('app').from('v_pos').select('id, po_no, status, order_date, expected_date, line_count, amount, parent_id, parent_no, cancel_reason, created_at')
      .eq('supplier_id', id).eq('kind', 'HD').order('created_at', { ascending: false }).limit(50).returns<Po[]>(),
    supabase.schema('app').rpc('supplier_history', { p_id: id }),
    lead
      ? supabase.schema('app').from('v_materials').select('id, code, name, uom, group_name').or('group_code.is.null,group_code.neq.SCRAP').order('group_name').order('code').returns<MaterialOption[]>()
      : Promise.resolve({ data: [] as MaterialOption[] }),
  ]);
  const history = ((hist ?? []) as Hist[]).map((h) => ({ ...h, lines: histText(h) })).filter((h) => h.lines.length > 0);
  const list = items ?? [];

  return (
    <>
      <Toolbar title={<span>{s.code} – {s.name}</span>} actions={<Link className="btn" href="/nha-cung-cap">Đóng</Link>} />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /></div>
      {!s.active && (
        <div role="note" className="mb-4 rounded border-l-4 border-warn bg-warn-soft px-4 py-2.5 text-[14px]">
          <b>Đã ngừng dùng</b>{s.inactive_at && <> từ {df(s.inactive_at, true)}</>}{s.inactive_by_name && <> bởi {s.inactive_by_name}</>}. Lý do: {s.inactive_reason ?? '—'}.
          Không còn hiện khi chọn NCC trên đơn mua; đơn mua và lô hàng cũ giữ nguyên.
        </div>
      )}
      {s.active && s.material_count === 0 && (
        <div role="note" className="mb-4 rounded border-l-4 border-warn bg-warn-soft px-4 py-2.5 text-[14px]">
          <b>Chưa khai báo mặt hàng:</b> nhà cung cấp này chưa chọn được trên đơn mua. {lead ? 'Tick mặt hàng ở khung "Mặt hàng bán được cho BMT" bên dưới.' : 'Báo TP Mua khai báo mặt hàng.'}
        </div>
      )}

      <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_340px]">
        <div className="flex min-w-0 flex-col gap-4">
          <Section title="Thông tin nhà cung cấp" right={s.active ? <Pill tone="ok">Đang dùng</Pill> : <Pill>Ngừng dùng</Pill>}>
            {editable ? (
              <form action={updateSupplier} className="grid gap-3 p-4 sm:grid-cols-2 lg:grid-cols-4" id="sua-ncc">
                <input type="hidden" name="id" value={s.id} />
                <label className="lbl">Mã<input className="inp mono" value={s.code} disabled readOnly /></label>
                <label className="lbl sm:col-span-2"><span className="req">Tên nhà cung cấp</span><input className="inp" name="name" required defaultValue={s.name} /></label>
                <label className="lbl">Mã số thuế<input className="inp mono" name="tax_code" inputMode="numeric" defaultValue={s.tax_code ?? ''} /></label>
                <label className="lbl">Người liên hệ<input className="inp" name="contact" defaultValue={s.contact ?? ''} /></label>
                <label className="lbl">Điện thoại<input className="inp" name="phone" inputMode="tel" defaultValue={s.phone ?? ''} /></label>
                <label className="lbl sm:col-span-2">Email<input className="inp" name="email" type="email" defaultValue={s.email ?? ''} /></label>
                <label className="lbl sm:col-span-2">Địa chỉ<input className="inp" name="address" defaultValue={s.address ?? ''} /></label>
                <label className="lbl sm:col-span-2">Điều khoản thanh toán mặc định<input className="inp" name="payment_terms" defaultValue={s.payment_terms ?? ''} placeholder="30 ngày sau khi nhận hàng" /></label>
                <label className="lbl sm:col-span-4">Ghi chú<input className="inp" name="note" defaultValue={s.note ?? ''} /></label>
                <div className="sm:col-span-4"><SubmitButton className="btn btn-pri">Lưu thông tin</SubmitButton></div>
              </form>
            ) : (
              <dl className="grid gap-x-6 gap-y-3 p-4 text-[14px] sm:grid-cols-2 lg:grid-cols-4">
                <div><dt className="text-muted">Mã số thuế</dt><dd>{s.tax_code ?? '—'}</dd></div>
                <div><dt className="text-muted">Người liên hệ</dt><dd>{s.contact ?? '—'}</dd></div>
                <div><dt className="text-muted">Điện thoại</dt><dd>{s.phone ?? '—'}</dd></div>
                <div><dt className="text-muted">Email</dt><dd>{s.email ?? '—'}</dd></div>
                <div className="sm:col-span-2"><dt className="text-muted">Địa chỉ</dt><dd>{s.address ?? '—'}</dd></div>
                <div className="sm:col-span-2"><dt className="text-muted">Điều khoản thanh toán mặc định</dt><dd>{s.payment_terms ?? '—'}</dd></div>
                <div className="sm:col-span-4"><dt className="text-muted">Ghi chú</dt><dd>{s.note ?? '—'}</dd></div>
              </dl>
            )}
          </Section>

          <Section title="Mặt hàng bán được cho BMT" right={<span className="text-[13px] text-muted">{list.length} mặt hàng</span>} className="overflow-x-auto">
            {list.length > 0 ? (
              <table className="tbl" id="mat-hang">
                <thead><tr><th>Vật tư</th><th>Nhóm</th><th>ĐVT</th><th className="num">Hợp đồng đã duyệt</th><th>Mua gần nhất</th>{showPrice && <th className="num">Giá gần nhất (đ)</th>}</tr></thead>
                <tbody>{list.map((m) => (
                  <tr key={m.material_id}>
                    <td className="min-w-[200px]"><span className="mono font-medium">{m.material_code}</span><div className="text-[13px]">{m.material_name}</div></td>
                    <td className="whitespace-nowrap text-muted">{m.group_name ?? '—'}</td>
                    <td>{m.uom}</td>
                    <td className="num">{m.po_count > 0 ? m.po_count : '—'}</td>
                    <td>{m.last_po_id ? <><Link className="link mono" href={`/don-mua/${m.last_po_id}`}>{m.last_po_no}</Link> · {df(m.last_order_date)}</> : <span className="text-muted">Chưa mua</span>}</td>
                    {showPrice && <td className="num">{m.last_price === null ? '—' : nf(m.last_price)}</td>}
                  </tr>
                ))}</tbody>
              </table>
            ) : <Empty>Chưa khai báo mặt hàng nào.</Empty>}
            {lead && (
              <details className="border-t border-line p-4" id="sua-mat-hang" open={list.length === 0}>
                <summary className="cursor-pointer text-[15px] font-medium text-brand">Cập nhật mặt hàng</summary>
                <form action={setSupplierMaterials} className="mt-3 flex flex-col gap-3">
                  <input type="hidden" name="id" value={s.id} />
                  <p className="text-[13px] text-muted">Tick các vật tư NCC này bán được, bỏ tick vật tư không bán nữa rồi bấm Lưu. Vật tư đang nằm trên đơn mua chưa duyệt của NCC này thì chưa bỏ được.</p>
                  <MaterialPicker groups={groupMaterials(mats ?? [])} selected={list.map((m) => m.material_id)} />
                  <div><SubmitButton className="btn btn-pri">Lưu mặt hàng</SubmitButton></div>
                </form>
              </details>
            )}
            {!lead && <div className="border-t border-line px-4 py-3 text-[13px] text-muted">Thêm, bớt mặt hàng: TP Mua.</div>}
          </Section>

          <Section title="Hợp đồng / phiếu mua" right={<span className="text-[13px] text-muted">{s.po_count} hợp đồng{s.open_count > 0 && ` · ${s.open_count} đơn đang mở`}</span>} className="overflow-x-auto">
            {(pos ?? []).length > 0 ? (
              <table className="tbl" id="hop-dong">
                <thead><tr><th>Hợp đồng</th><th>Ngày lập</th><th>Ngày giao</th><th className="num">Dòng</th>{showPrice && <th className="num">Giá trị (đ)</th>}<th>Trạng thái</th></tr></thead>
                <tbody>{(pos ?? []).map((p) => (
                  <tr key={p.id}>
                    <td><Link className="link mono font-medium" href={`/don-mua/${p.id}`}>{p.po_no}</Link>{p.parent_no && <div className="text-[12px] text-muted">theo {p.parent_no}</div>}</td>
                    <td>{df(p.order_date ?? p.created_at)}</td><td>{df(p.expected_date)}</td><td className="num">{p.line_count}</td>
                    {showPrice && <td className="num">{p.amount === null ? '—' : nf(p.amount)}</td>}
                    <td><StatusPill map={PO_STATUS} value={p.status} />{p.cancel_reason && <div className="text-[12px] text-muted">{p.cancel_reason}</div>}</td>
                  </tr>
                ))}</tbody>
              </table>
            ) : <Empty>Chưa có hợp đồng nào với nhà cung cấp này.</Empty>}
          </Section>
        </div>

        <aside className="flex flex-col gap-4">
          {lead && (
            <section className="card p-4" id="trang-thai">
              <h2 className="mb-2 text-[15px] font-medium">{s.active ? 'Ngừng dùng nhà cung cấp' : 'Dùng lại nhà cung cấp'}</h2>
              {s.active ? (
                <form action={setSupplierActive} className="flex flex-col gap-2">
                  <input type="hidden" name="id" value={s.id} /><input type="hidden" name="active" value="0" />
                  <p className="text-[13px] text-muted">NCC không còn hiện khi chọn trên đơn mua mới. Đơn mua đã duyệt, lô hàng cũ giữ nguyên. Còn đơn mua chưa duyệt của NCC này thì MES chặn và báo số đơn.</p>
                  <label className="lbl"><span className="req">Lý do</span><input className="inp" name="reason" required placeholder="Ví dụ: giao chậm nhiều lần" /></label>
                  <div><SubmitButton className="btn btn-bad-o">Ngừng dùng</SubmitButton></div>
                </form>
              ) : (
                <form action={setSupplierActive} className="flex flex-col gap-2">
                  <input type="hidden" name="id" value={s.id} /><input type="hidden" name="active" value="1" />
                  <p className="text-[13px] text-muted">NCC hiện lại khi chọn trên đơn mua (ở các vật tư đã khai báo).</p>
                  <div><SubmitButton className="btn btn-pri">Dùng lại</SubmitButton></div>
                </form>
              )}
            </section>
          )}
          {me.is_admin && (
            <details className="card p-4" id="xoa-ncc">
              <summary className="cursor-pointer text-[15px] font-medium text-bad">Xóa nhà cung cấp (Quản trị)</summary>
              <form action={deleteSupplier} className="mt-3 flex flex-col gap-2">
                <input type="hidden" name="id" value={s.id} />
                <p className="text-[13px] text-muted">Chỉ xóa được NCC chưa phát sinh chứng từ (nhập nhầm, trùng). NCC đã có đơn mua, phiếu nhận, lô hàng thì MES chặn để giữ lịch sử: dùng Ngừng dùng.</p>
                <label className="lbl"><span className="req">Lý do xóa</span><input className="inp" name="reason" required placeholder="Ví dụ: nhập trùng" /></label>
                <div><SubmitButton className="btn btn-bad-o">Xóa hẳn</SubmitButton></div>
              </form>
            </details>
          )}
          <section className="card" id="lich-su">
            <div className="card-h"><h2>Lịch sử thay đổi</h2></div>
            {history.length > 0 ? (
              <ul className="divide-y divide-line text-[13.5px]">
                {history.map((h, i) => (
                  <li key={i} className="px-4 py-2.5">
                    <div className="text-[12.5px] text-muted">{df(h.at, true)} · {h.user_name ?? 'MES'}</div>
                    {h.lines.map((t, j) => <div key={j} className="break-words">{t}</div>)}
                  </li>
                ))}
              </ul>
            ) : <Empty>Chưa có thay đổi nào được ghi.</Empty>}
            <div className="border-t border-line px-4 py-2.5 text-[12.5px] text-muted">Thêm bởi {s.created_by_name ?? 'MES'} · {df(s.created_at, true)}</div>
          </section>
        </aside>
      </div>
    </>
  );
}
