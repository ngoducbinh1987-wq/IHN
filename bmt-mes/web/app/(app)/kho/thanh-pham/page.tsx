import Link from 'next/link';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { after } from 'next/server';
import { ScanOne } from '@/components/scan';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Toolbar } from '@/components/ui';
import { df, nf, parseNum } from '@/lib/format';
import { errText, hasRole, keeps, withMsg } from '@/lib/kho';
import { flushEmailOutbox } from '@/lib/notify';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { str } from '../util';

export const metadata = { title: 'Thành phẩm' };

async function split(form: FormData) {
  'use server';
  const parts: number[] = [];
  for (const p of str(form, 'parts').split(/[+;\s]+/).filter(Boolean)) {
    const n = parseNum(p);
    if (n === null || Number.isNaN(n) || n <= 0) redirect(withMsg('/kho/thanh-pham', 'err', `Độ dài "${p}" không hợp lệ`));
    parts.push(n!);
  }
  const scrap = str(form, 'scrap_m') ? parseNum(str(form, 'scrap_m')) : 0;
  if (scrap === null || Number.isNaN(scrap) || scrap < 0) redirect(withMsg('/kho/thanh-pham', 'err', 'Mét phế cắt không hợp lệ'));
  if (!str(form, 'hu_id')) redirect(withMsg('/kho/thanh-pham', 'err', 'Quét bobin cần cắt'));
  const supabase = await createClient();
  const { data, error } = await supabase.schema('inv').rpc('split_hu', { p_hu: str(form, 'hu_id'), p_parts: parts, p_scrap_m: scrap, p_reason: str(form, 'reason') });
  if (error) redirect(withMsg('/kho/thanh-pham', 'err', errText(error.message)));
  revalidatePath('/kho/thanh-pham');
  redirect(withMsg(`/kho/phieu/${data}`, 'ok', 'Đã cắt bobin. In tem cho các đoạn mới.'));
}

async function custReturn(form: FormData) {
  'use server';
  const qty = parseNum(form.get('qty_m'));
  if (qty === null || Number.isNaN(qty) || qty <= 0) redirect(withMsg('/kho/thanh-pham', 'err', 'Nhập số mét khách trả'));
  const supabase = await createClient();
  const { data, error } = await supabase.schema('inv').rpc('customer_return', {
    p_product: str(form, 'product_id'), p_brand: str(form, 'brand'), p_qty_m: qty, p_so: null, p_orig_hu: str(form, 'orig_hu') || null, p_note: str(form, 'note'),
  });
  if (error) redirect(withMsg('/kho/thanh-pham', 'err', errText(error.message)));
  after(async () => { await flushEmailOutbox(); });
  revalidatePath('/kho/thanh-pham');
  redirect(withMsg(`/kho/phieu/${data}`, 'ok', 'Đã nhập hàng trả về khu cách ly. TP Kỹ thuật/QA đã nhận thông báo đánh giá.'));
}

async function reclass(form: FormData) {
  'use server';
  const toScrap = str(form, 'target') === 'SCRAP';
  if (!str(form, 'hu_id')) redirect(withMsg('/kho/thanh-pham', 'err', 'Quét bobin cần xử lý'));
  const supabase = await createClient();
  const { data, error } = await supabase.schema('inv').rpc('reclass_hu', {
    p_hu: str(form, 'hu_id'), p_to_scrap: toScrap, p_product: toScrap ? null : str(form, 'product_id') || null, p_brand: toScrap ? null : str(form, 'brand') || null,
    p_reason: str(form, 'reason'),
  });
  if (error) redirect(withMsg('/kho/thanh-pham', 'err', errText(error.message)));
  revalidatePath('/kho/thanh-pham');
  redirect(withMsg(`/kho/phieu/${data}`, 'ok', toScrap ? 'Đã hủy, chuyển kho phế' : 'Đã đổi mã/hạ cấp. In tem mới cho bobin.'));
}

export default async function FgToolsPage({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string; ma?: string }> }) {
  const sp = await searchParams;
  const me = await requireMe();
  const keeper = keeps(me, 'KTP');
  const tp = hasRole(me, 'KT_TP');
  if (!keeper && !tp) redirect('/kho?err=' + encodeURIComponent('Trang dành cho NV5 (kho thành phẩm) và TP Kỹ thuật/QA'));
  const supabase = await createClient();
  const [{ data: prods }, { data: rem }] = await Promise.all([
    supabase.schema('app').from('v_products').select('id, code, description, spec_status').order('code'),
    supabase.schema('app').from('v_hu').select('id, hu_no, item_code, item_name, qty, location_code, brand, mfg_date').eq('status', 'ACTIVE').eq('is_remnant', true).eq('item_kind', 'FG').order('item_code'),
  ]);
  return (
    <>
      <Toolbar title="Thành phẩm: cắt bobin, hàng trả, đổi mã" reload="/kho/thanh-pham" />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /></div>
      <div className="grid gap-4 lg:grid-cols-2">
        {keeper && (
          <section className="card">
            <div className="card-h">Cắt bobin theo độ dài khách cần</div>
            <form action={split} className="grid gap-3 p-4">
              <ScanOne name="hu_id" label="Bobin cần cắt (quét tem)" initial={sp.ma} />
              <label className="lbl"><span className="req">Các đoạn cắt ra (m), cách nhau bởi dấu +</span><input className="inp inp-y" name="parts" placeholder="300 + 100" required /></label>
              <label className="lbl">Phế khi cắt (m)<input className="inp" name="scrap_m" inputMode="decimal" placeholder="0" /></label>
              <label className="lbl"><span className="req">Lý do (đơn hàng, khách yêu cầu)</span><input className="inp inp-y" name="reason" required /></label>
              <p className="text-[12.5px] text-muted">Phần còn lại giữ trên bobin cũ. Đoạn ngắn hơn chiều dài tối thiểu (mặc định 100 m) được đánh dấu đoạn lẻ.</p>
              <div><SubmitButton>Cắt và tạo tem mới</SubmitButton></div>
            </form>
          </section>
        )}
        {keeper && (
          <section className="card">
            <div className="card-h">Nhận hàng khách trả</div>
            <form action={custReturn} className="grid gap-3 p-4 sm:grid-cols-2">
              <label className="lbl sm:col-span-2"><span className="req">Sản phẩm</span>
                <select className="inp inp-y" name="product_id" required>{(prods ?? []).map((p) => <option key={p.id} value={p.id}>{p.code} · {p.description}</option>)}</select></label>
              <label className="lbl"><span className="req">Thương hiệu</span><select className="inp inp-y" name="brand"><option>KAVIX</option><option>HEIZKA</option></select></label>
              <label className="lbl"><span className="req">Số mét</span><input className="inp inp-y text-right" name="qty_m" inputMode="decimal" required /></label>
              <label className="lbl sm:col-span-2"><span className="req">Lý do khách trả</span><input className="inp inp-y" name="note" required /></label>
              <div className="sm:col-span-2"><SubmitButton>Nhập khu hàng trả (cách ly)</SubmitButton></div>
            </form>
          </section>
        )}
        {tp && (
          <section className="card">
            <div className="card-h">Đổi mã / hạ cấp / hủy theo NCR (TP Kỹ thuật/QA)</div>
            <form action={reclass} className="grid gap-3 p-4 sm:grid-cols-2">
              <div className="sm:col-span-2"><ScanOne name="hu_id" label="Bobin cần xử lý (quét tem)" autoFocus={!keeper} /></div>
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
          <div className="card-h">Đoạn lẻ đang có</div>
          {rem && rem.length > 0 ? (
            <table className="tbl"><tbody>{rem.map((r) => (
              <tr key={r.id}><td><Link className="link mono" href={`/kho/quet?ma=${r.hu_no}`}>{r.hu_no}</Link></td><td><span className="mono">{r.item_code}</span> · {r.brand}</td>
                <td className="num">{nf(r.qty)} m</td><td>{r.location_code}</td><td>{df(r.mfg_date)}</td></tr>
            ))}</tbody></table>
          ) : <Empty>Không có đoạn lẻ.</Empty>}
        </section>
      </div>
    </>
  );
}
