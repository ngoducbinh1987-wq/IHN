import Link from 'next/link';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { after } from 'next/server';
import { Printer } from 'lucide-react';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Toolbar } from '@/components/ui';
import { df, nf, parseNum } from '@/lib/format';
import { LoadErrors, errText, hasRole, keeps, withMsg } from '@/lib/kho';
import { flushEmailOutbox } from '@/lib/notify';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { kindLabel, type FgGroup } from '../xuat-ban/items-fields';
import { str } from '../util';

export const metadata = { title: 'Thành phẩm' };

type Coil = { id: string; hu_no: string; lot_no: string; product_id: string; product_code: string; brand: string; mfg_date: string | null; qc_status: string;
  qty: number; pack_m: number | null; is_remnant: boolean; location_code: string | null; location_kind: string | null; reserved_qty: number };

const back = (kind: 'ok' | 'err', msg: string): never => redirect(withMsg('/kho/thanh-pham', kind, msg));

// Phiếu nhập kho TP: cuộn QC Đạt ở khu chờ QC → khu lưu kho (Kế toán SX nhập từ phiếu giấy người giữ kho TP ký)
async function putaway(form: FormData) {
  'use server';
  const items: Record<string, unknown>[] = [];
  for (const key of form.getAll('kind').map(String)) {
    const n = Number(str(form, `n_${key}`) || 0);
    if (!Number.isInteger(n) || n < 0) back('err', 'Số cuộn nhập kho phải là số nguyên ≥ 0');
    if (!n) continue;
    const [code, brand, pack] = key.split('|');
    items.push({ product_code: code, brand, pack_m: pack ? Number(pack) : null, coils: n });
  }
  if (!items.length) back('err', 'Nhập số cuộn nhập kho của ít nhất một chủng loại');
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc('fg_putaway', { p: { keeper_code: str(form, 'keeper_code') || null, paper_no: str(form, 'paper_no') || null, items } });
  if (error) back('err', errText(error.message));
  revalidatePath('/kho/thanh-pham');
  back('ok', `Đã nhập kho ${(data as { coils?: number })?.coils ?? 0} cuộn thành phẩm (${(data as { doc_no?: string })?.doc_no ?? ''}): tính vào tồn giao được`);
}

async function split(form: FormData) {
  'use server';
  const parts: number[] = [];
  for (const p of str(form, 'parts').split(/[+;\s]+/).filter(Boolean)) {
    const n = parseNum(p);
    if (n === null || Number.isNaN(n) || n <= 0) back('err', `Độ dài "${p}" không hợp lệ`);
    parts.push(n!);
  }
  const scrap = str(form, 'scrap_m') ? parseNum(str(form, 'scrap_m')) : 0;
  if (scrap === null || Number.isNaN(scrap) || scrap < 0) back('err', 'Mét phế cắt không hợp lệ');
  if (!str(form, 'hu_id')) back('err', 'Chọn cuộn cần cắt');
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc('fg_split', {
    p: { hu_id: str(form, 'hu_id'), parts, scrap_m: scrap, reason: str(form, 'reason'), keeper_code: str(form, 'keeper_code') || null, paper_no: str(form, 'paper_no') || null },
  });
  if (error) back('err', errText(error.message));
  revalidatePath('/kho/thanh-pham');
  redirect(withMsg(`/kho/phieu/${data}`, 'ok', 'Đã cắt cuộn. Đoạn cắt tính là cuộn lẻ.'));
}

async function custReturn(form: FormData) {
  'use server';
  const qty = parseNum(form.get('qty_m'));
  if (qty === null || Number.isNaN(qty) || qty <= 0) back('err', 'Nhập số mét khách trả');
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc('fg_customer_return', {
    p: { product_id: str(form, 'product_id'), brand: str(form, 'brand'), qty_m: qty, note: str(form, 'note'), keeper_code: str(form, 'keeper_code') || null,
         paper_no: str(form, 'paper_no') || null },
  });
  if (error) back('err', errText(error.message));
  after(async () => { await flushEmailOutbox(); });
  revalidatePath('/kho/thanh-pham');
  redirect(withMsg(`/kho/phieu/${data}`, 'ok', 'Đã nhập hàng trả về khu cách ly. TP Kỹ thuật/QA đã nhận thông báo đánh giá.'));
}

async function reclass(form: FormData) {
  'use server';
  const toScrap = str(form, 'target') === 'SCRAP';
  if (!str(form, 'hu_id')) back('err', 'Chọn cuộn cần xử lý');
  const supabase = await createClient();
  const { data, error } = await supabase.schema('inv').rpc('reclass_hu', {
    p_hu: str(form, 'hu_id'), p_to_scrap: toScrap, p_product: toScrap ? null : str(form, 'product_id') || null, p_brand: toScrap ? null : str(form, 'brand') || null,
    p_reason: str(form, 'reason'),
  });
  if (error) back('err', errText(error.message));
  revalidatePath('/kho/thanh-pham');
  redirect(withMsg(`/kho/phieu/${data}`, 'ok', toScrap ? 'Đã hủy, chuyển kho phế' : 'Đã đổi mã/hạ cấp'));
}

const coilLabel = (c: Coil) => `${c.product_code} · ${c.brand} · ${nf(c.qty)} m${c.pack_m ? '' : ' (lẻ)'} · lô ${c.lot_no} · ${c.location_code ?? ''} · ${c.hu_no}`;

export default async function FgToolsPage({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string }> }) {
  const sp = await searchParams;
  const me = await requireMe();
  const paper = hasRole(me, 'KT_KHO', 'SX_TP', 'ADMIN');
  const keeper = keeps(me, 'KTP');
  const tp = hasRole(me, 'KT_TP', 'ADMIN');
  if (!paper && !keeper && !tp) redirect('/kho?err=' + encodeURIComponent('Trang dành cho Kế toán SX, TP SX, người giữ kho thành phẩm và TP Kỹ thuật/QA'));
  const supabase = await createClient();
  const le = new LoadErrors();
  const [{ data: prods }, { data: groups }, { data: coils }, { data: keepers }] = le.all(await Promise.all([
    supabase.schema('app').from('v_products').select('id, code, description, spec_status').order('code'),
    supabase.schema('app').from('v_fg_stock').select('*').order('product_code').returns<FgGroup[]>(),
    supabase.schema('app').from('v_fg_coils').select('*').order('product_code').order('mfg_date').returns<Coil[]>(),
    supabase.schema('app').rpc('fg_keepers'),
  ]));
  const kp = (keepers ?? []) as { code: string; full_name: string | null }[];
  const enter = paper || keeper;
  const wait = (groups ?? []).filter((g) => g.putaway_coils > 0);
  const storeCoils = (coils ?? []).filter((c) => c.qc_status === 'PASSED' && ['STORE', 'SHIP'].includes(c.location_kind ?? '') && Number(c.reserved_qty) === 0);
  const remnants = (coils ?? []).filter((c) => c.pack_m === null && c.qc_status === 'PASSED');
  const keeperField = (
    <>
      <label className="lbl"><span className={paper && !keeper ? 'req' : ''}>Người giữ kho TP ký phiếu</span>
        <select className={`inp ${paper && !keeper ? 'inp-y' : ''}`} name="keeper_code" required={paper && !keeper} defaultValue={kp.length === 1 ? kp[0].code : ''}>
          <option value="">{keeper ? 'Tôi (người giữ kho có tài khoản)' : 'Chọn người giữ kho thành phẩm'}</option>
          {kp.map((k) => <option key={k.code} value={k.code}>{k.code}{k.full_name ? ` · ${k.full_name}` : ''}</option>)}
        </select></label>
      <label className="lbl">Số phiếu giấy<input className="inp" name="paper_no" /></label>
    </>
  );
  return (
    <>
      <Toolbar title="Kho thành phẩm: nhập kho, cắt cuộn, hàng trả" reload="/kho/thanh-pham"
        actions={<Link className="btn btn-soft" href="/in/nhap-kho-tp" target="_blank"><Printer size={16} />In phiếu nhập kho TP</Link>} />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /><Flash err={le.text} /></div>
      <p className="mb-3 text-[13px] text-muted">
        Cuộn thành phẩm chỉ dán tem QC PASS, không in, không quét QR. Người giữ kho thành phẩm (khai báo ở Nhân sự xưởng) làm và ký trên phiếu giấy; Kế toán SX nhập vào MES.
        {kp.length === 0 && <b className="text-bad"> Chưa khai báo người giữ kho thành phẩm: TP SX giao ở Nhân sự xưởng → Người.</b>}
      </p>

      {enter && (
        <section className="card mb-4 overflow-x-auto" id="nhap-kho">
          <div className="card-h">Phiếu nhập kho thành phẩm (cuộn QC Đạt đang ở khu chờ QC)</div>
          {wait.length ? (
            <form action={putaway}>
              <table className="tbl">
                <thead><tr><th>Chủng loại</th><th className="num">QC Đạt chờ nhập</th><th className="num">Mét</th><th className="num">Số cuộn nhập kho</th></tr></thead>
                <tbody>{wait.map((g) => {
                  const key = `${g.product_code}|${g.brand}|${g.pack_m ?? ''}`;
                  return (
                    <tr key={key}><td>{kindLabel(g.product_code, g.brand, g.pack_m)}<input type="hidden" name="kind" value={key} /></td>
                      <td className="num">{g.putaway_coils}</td><td className="num">{nf(g.putaway_m)}</td>
                      <td className="num"><input className="inp w-24 text-right" name={`n_${key}`} defaultValue={String(g.putaway_coils)} inputMode="numeric" aria-label={`Số cuộn nhập kho ${g.product_code}`} /></td></tr>
                  );
                })}</tbody>
              </table>
              <div className="grid gap-3 border-t border-line p-4 sm:grid-cols-[1fr_1fr_auto] sm:items-end">
                {keeperField}
                <SubmitButton>Ghi nhập kho</SubmitButton>
              </div>
            </form>
          ) : <Empty>Không có cuộn QC Đạt nào chờ nhập kho.</Empty>}
        </section>
      )}

      <div className="grid gap-4 lg:grid-cols-2">
        {enter && (
          <section className="card">
            <div className="card-h">Cắt cuộn theo độ dài khách cần</div>
            <form action={split} className="grid gap-3 p-4 sm:grid-cols-2">
              <label className="lbl sm:col-span-2"><span className="req">Cuộn cần cắt</span>
                <select className="inp inp-y" name="hu_id" required defaultValue="">
                  <option value="" disabled>Chọn cuộn (mã · nhãn · mét · lô · vị trí)</option>
                  {storeCoils.map((c) => <option key={c.id} value={c.id}>{coilLabel(c)}</option>)}
                </select></label>
              <label className="lbl"><span className="req">Các đoạn cắt ra (m), cách nhau bởi dấu +</span><input className="inp inp-y" name="parts" placeholder="300 + 100" required /></label>
              <label className="lbl">Phế khi cắt (m)<input className="inp" name="scrap_m" inputMode="decimal" placeholder="0" /></label>
              <label className="lbl sm:col-span-2"><span className="req">Lý do (đơn hàng, khách yêu cầu)</span><input className="inp inp-y" name="reason" required /></label>
              {keeperField}
              <p className="text-[12.5px] text-muted sm:col-span-2">Phần còn lại giữ trên cuộn cũ. Đoạn cắt và phần còn lại tính là cuộn lẻ (xuất theo dòng &quot;cuộn lẻ&quot;).</p>
              <div><SubmitButton>Cắt cuộn</SubmitButton></div>
            </form>
          </section>
        )}
        {enter && (
          <section className="card">
            <div className="card-h">Nhận hàng khách trả</div>
            <form action={custReturn} className="grid gap-3 p-4 sm:grid-cols-2">
              <label className="lbl sm:col-span-2"><span className="req">Sản phẩm</span>
                <select className="inp inp-y" name="product_id" required>{(prods ?? []).map((p) => <option key={p.id} value={p.id}>{p.code} · {p.description}</option>)}</select></label>
              <label className="lbl"><span className="req">Thương hiệu</span><select className="inp inp-y" name="brand"><option>KAVIX</option><option>HEIZKA</option></select></label>
              <label className="lbl"><span className="req">Số mét</span><input className="inp inp-y text-right" name="qty_m" inputMode="decimal" required /></label>
              <label className="lbl sm:col-span-2"><span className="req">Lý do khách trả</span><input className="inp inp-y" name="note" required /></label>
              {keeperField}
              <div className="sm:col-span-2"><SubmitButton>Nhập khu hàng trả (cách ly)</SubmitButton></div>
            </form>
          </section>
        )}
        {tp && (
          <section className="card">
            <div className="card-h">Đổi mã / hạ cấp / hủy theo NCR (TP Kỹ thuật/QA)</div>
            <form action={reclass} className="grid gap-3 p-4 sm:grid-cols-2">
              <label className="lbl sm:col-span-2"><span className="req">Cuộn cần xử lý</span>
                <select className="inp inp-y" name="hu_id" required defaultValue="">
                  <option value="" disabled>Chọn cuộn</option>
                  {(coils ?? []).map((c) => <option key={c.id} value={c.id}>{coilLabel(c)}</option>)}
                </select></label>
              <label className="lbl"><span className="req">Xử lý</span><select className="inp inp-y" name="target"><option value="PRODUCT">Đổi sang mã khác / hạ cấp</option><option value="SCRAP">Hủy – chuyển phế</option></select></label>
              <label className="lbl">Thương hiệu mới<select className="inp" name="brand"><option>KAVIX</option><option>HEIZKA</option></select></label>
              <label className="lbl sm:col-span-2">Mã mới (khi đổi mã)
                <select className="inp" name="product_id" defaultValue=""><option value="">—</option>{(prods ?? []).filter((p) => p.spec_status === 'RELEASED').map((p) => <option key={p.id} value={p.id}>{p.code} · {p.description}</option>)}</select></label>
              <label className="lbl sm:col-span-2"><span className="req">Lý do / số NCR</span><input className="inp inp-y" name="reason" required /></label>
              <div className="sm:col-span-2"><SubmitButton className="btn btn-bad-o">Xác nhận xử lý</SubmitButton></div>
            </form>
          </section>
        )}
        <section className="card overflow-x-auto">
          <div className="card-h">Cuộn lẻ, đoạn cắt đang có</div>
          {remnants.length > 0 ? (
            <table className="tbl"><tbody>{remnants.map((r) => (
              <tr key={r.id}><td><span className="mono">{r.product_code}</span> · {r.brand}</td><td className="num">{nf(r.qty)} m</td><td>{r.location_code}</td><td>{df(r.mfg_date)}</td></tr>
            ))}</tbody></table>
          ) : <Empty>Không có cuộn lẻ.</Empty>}
        </section>
      </div>
    </>
  );
}
