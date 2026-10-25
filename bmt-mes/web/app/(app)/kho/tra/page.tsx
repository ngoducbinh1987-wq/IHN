import Link from 'next/link';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { ScanOne } from '@/components/scan';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Toolbar } from '@/components/ui';
import { df, nf, parseNum } from '@/lib/format';
import { errText, keeps, withMsg } from '@/lib/kho';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Trả NVL thừa' };

type Person = { id: string; name: string };

async function returnHu(form: FormData) {
  'use server';
  const qty = parseNum(form.get('qty'));
  if (!form.get('hu_id')) redirect(withMsg('/kho/tra', 'err', 'Quét mã QR ống/bao cần trả'));
  if (qty === null || Number.isNaN(qty) || qty <= 0) redirect(withMsg('/kho/tra', 'err', 'Nhập số kg cân lại (> 0)'));
  const supabase = await createClient();
  const { error } = await supabase.schema('inv').rpc('return_hu', {
    p_hu: String(form.get('hu_id')), p_qty: qty, p_location: String(form.get('location_id') ?? '') || null, p_witness: String(form.get('witness_id') ?? '') || null,
  });
  if (error) redirect(withMsg('/kho/tra', 'err', errText(error.message)));
  revalidatePath('/kho/tra');
  redirect(withMsg('/kho/tra', 'ok', `Đã nhận lại ${nf(qty, 3)} vào kho. In lại tem nếu số trên tem cũ đã sai.`));
}

export default async function ReturnPage({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string; ma?: string }> }) {
  const sp = await searchParams;
  const me = await requireMe();
  if (!keeps(me, 'KNL')) redirect('/kho?err=' + encodeURIComponent('Trả NVL do Quản lý SX (thủ kho NVL) nhận'));
  const supabase = await createClient();
  const [{ data: locs }, { data: kt }, { data: recent }] = await Promise.all([
    supabase.schema('app').from('v_locations').select('id, code, name').eq('warehouse_code', 'KNL').eq('active', true).order('sort'),
    supabase.schema('app').rpc('role_holders', { p_role: 'KT_KHO' }),
    supabase.schema('app').from('v_stock_docs').select('id, doc_no, posted_at, ref_no, total_qty, created_by_name').eq('doc_type', 'RETURN_WO')
      .order('posted_at', { ascending: false }).limit(15),
  ]);
  return (
    <>
      <Toolbar title="Trả nguyên vật liệu thừa cuối ca" reload="/kho/tra" />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /></div>
      <p className="mb-3 text-[13px] text-muted">NV4 cân phần dùng dở, Quản lý SX quét tem cũ và nhập kg. Hàng về đúng lô cũ; tiêu hao của lệnh = cấp − trả.</p>
      <form action={returnHu} className="card mb-4 grid gap-4 p-4 md:grid-cols-2">
        <ScanOne name="hu_id" label="Ống/bao/cuộn trả về (quét tem QR)" initial={sp.ma} />
        <div className="grid gap-3">
          <label className="lbl"><span className="req">Số lượng cân lại (kg tịnh)</span><input className="inp inp-y h-11 text-right text-[16px]" name="qty" inputMode="decimal" required /></label>
          <label className="lbl">Cất vào vị trí
            <select className="inp" name="location_id" defaultValue=""><option value="">Vị trí lúc xuất</option>{(locs ?? []).map((l) => <option key={l.id} value={l.id}>{l.code} · {l.name}</option>)}</select></label>
          <label className="lbl">Kế toán SX chứng kiến (khi giữ kho theo ủy quyền)
            <select className="inp" name="witness_id" defaultValue=""><option value="">Không</option>{((kt ?? []) as Person[]).filter((p) => p.id !== me.id).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></label>
          <div><SubmitButton>Nhận lại vào kho</SubmitButton></div>
        </div>
      </form>
      <section className="card overflow-x-auto">
        <div className="card-h">Phiếu trả gần đây</div>
        {recent && recent.length > 0 ? (
          <table className="tbl"><tbody>{recent.map((d) => (
            <tr key={d.id}><td><Link className="link mono" href={`/kho/phieu/${d.id}`}>{d.doc_no}</Link></td><td>lệnh {d.ref_no}</td>
              <td className="num">{nf(d.total_qty, 3)}</td><td>{d.created_by_name}</td><td className="whitespace-nowrap">{df(d.posted_at, true)}</td></tr>
          ))}</tbody></table>
        ) : <Empty>Chưa có phiếu trả.</Empty>}
      </section>
    </>
  );
}
