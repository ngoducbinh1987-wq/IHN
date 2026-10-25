import Link from 'next/link';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { after } from 'next/server';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Toolbar } from '@/components/ui';
import { df, nf, parseNum } from '@/lib/format';
import { SCRAP_CAT, errText, keeps, withMsg } from '@/lib/kho';
import { flushEmailOutbox } from '@/lib/notify';
import { can, requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { str } from '../util';

export const metadata = { title: 'Phế liệu' };

async function recordScrap(form: FormData) {
  'use server';
  const qty = parseNum(form.get('qty_kg'));
  if (qty === null || Number.isNaN(qty) || qty <= 0) redirect(withMsg('/kho/phe', 'err', 'Nhập số kg phế (cân)'));
  const [wo, op] = str(form, 'wo_op').split('|');
  const supabase = await createClient();
  const { error } = await supabase.schema('inv').rpc('record_scrap', {
    p_wo: wo, p_op_code: op, p_material_code: str(form, 'scrap_code'), p_qty_kg: qty, p_reason: str(form, 'reason'),
    p_machine: str(form, 'machine_id') || null, p_note: str(form, 'note') || null,
  });
  if (error) redirect(withMsg('/kho/phe', 'err', errText(error.message)));
  revalidatePath('/kho/phe');
  redirect(withMsg('/kho/phe', 'ok', `Đã ghi ${nf(qty, 2)} kg phế vào kho phế liệu`));
}

async function scrapSale(form: FormData) {
  'use server';
  const items: { hu_id: string; qty: number }[] = [];
  for (const id of form.getAll('hu').map(String)) {
    const q = parseNum(form.get(`qty_${id}`));
    if (q === null || Number.isNaN(q) || q <= 0) redirect(withMsg('/kho/phe', 'err', 'Số kg bán phải > 0'));
    items.push({ hu_id: id, qty: q! });
  }
  if (!items.length) redirect(withMsg('/kho/phe', 'err', 'Chọn bao phế cần bán'));
  const supabase = await createClient();
  const { error } = await supabase.schema('inv').rpc('create_scrap_sale', { p_items: items, p_buyer: str(form, 'buyer'), p_note: str(form, 'note') || null });
  if (error) redirect(withMsg('/kho/phe', 'err', errText(error.message)));
  after(async () => { await flushEmailOutbox(); });
  revalidatePath('/kho/phe');
  redirect(withMsg('/kho/phe', 'ok', 'Đã lập phiếu bán phế: Kế toán SX kiểm tra, Giám đốc duyệt rồi mới xuất.'));
}

export default async function ScrapPage({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string }> }) {
  const sp = await searchParams;
  const me = await requireMe();
  const supabase = await createClient();
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Ho_Chi_Minh' });
  const [{ data: wos }, { data: mats }, { data: reasons }, { data: machines }, { data: recs }, { data: bags }] = await Promise.all([
    supabase.schema('app').from('v_wo_for_scrap').select('*').order('wo_no', { ascending: false }),
    supabase.schema('master').from('materials').select('code, name').eq('is_scrap', true).order('code'),
    supabase.schema('master').from('reason_codes').select('code, name').eq('kind', 'SCRAP').order('code'),
    supabase.schema('master').from('machines').select('id, code, name').eq('active', true).order('code'),
    supabase.schema('app').rpc('loss_scrap', { p_from: today, p_to: today }),
    keeps(me, 'KPL') ? supabase.schema('app').from('v_hu').select('id, hu_no, item_code, item_name, qty, location_code, lot_no').eq('warehouse_code', 'KPL').eq('status', 'ACTIVE').order('hu_no') : Promise.resolve({ data: [] as never[] }),
  ]);
  const canRecord = can(me, 'production', 'create');
  type Rec = { reason_name: string; category: string; op_code: string; machine_code: string | null; scrap_code: string; kg: number; times: number };
  return (
    <>
      <Toolbar title="Phế liệu" reload="/kho/phe" actions={<Link className="btn btn-soft" href="/bao-cao/hao-hut">Báo cáo hao hụt</Link>} />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /></div>
      <p className="mb-3 text-[13px] text-muted">NV4 gom và cân phế theo từng lệnh sản xuất, ghi đúng công đoạn và nguyên nhân (Quy chuẩn mục 4). Phế nhập kho phế liệu với giá trị 0.</p>
      <div className="grid gap-4 lg:grid-cols-2">
        {canRecord && (
          <section className="card">
            <div className="card-h">Ghi phế theo lệnh</div>
            {wos && wos.length > 0 ? (
              <form action={recordScrap} className="grid gap-3 p-4 sm:grid-cols-2">
                <label className="lbl sm:col-span-2"><span className="req">Lệnh SX · công đoạn</span>
                  <select className="inp inp-y" name="wo_op" required>
                    {wos.flatMap((w) => (w.ops ?? []).map((op: string) => <option key={w.id + op} value={`${w.id}|${op}`}>{w.wo_no} · {w.product_code} · {op}</option>))}
                  </select></label>
                <label className="lbl"><span className="req">Loại phế</span>
                  <select className="inp inp-y" name="scrap_code" required>{(mats ?? []).map((m) => <option key={m.code} value={m.code}>{m.code} · {m.name}</option>)}</select></label>
                <label className="lbl"><span className="req">Số kg (cân)</span><input className="inp inp-y text-right" name="qty_kg" inputMode="decimal" required /></label>
                <label className="lbl"><span className="req">Nguyên nhân</span>
                  <select className="inp inp-y" name="reason" required>{(reasons ?? []).map((r) => <option key={r.code} value={r.code}>{r.name}</option>)}</select></label>
                <label className="lbl">Máy<select className="inp" name="machine_id" defaultValue=""><option value="">Theo công đoạn</option>{(machines ?? []).map((m) => <option key={m.id} value={m.id}>{m.code} · {m.name}</option>)}</select></label>
                <label className="lbl sm:col-span-2">Ghi chú<input className="inp" name="note" /></label>
                <div className="sm:col-span-2"><SubmitButton>Ghi phế</SubmitButton></div>
              </form>
            ) : <Empty>Chưa có lệnh sản xuất đang chạy.</Empty>}
          </section>
        )}
        <section className="card overflow-x-auto">
          <div className="card-h">Phế hôm nay</div>
          {recs && (recs as Rec[]).length > 0 ? (
            <table className="tbl">
              <thead><tr><th>Nguyên nhân</th><th>Nhóm</th><th>CĐ</th><th>Máy</th><th>Loại</th><th className="num">kg</th><th className="num">Lần</th></tr></thead>
              <tbody>{(recs as Rec[]).sort((a, b) => Number(b.kg) - Number(a.kg)).map((r, i) => (
                <tr key={i}><td>{r.reason_name}</td><td>{SCRAP_CAT[r.category] ?? r.category}</td><td>{r.op_code}</td><td>{r.machine_code ?? '—'}</td>
                  <td className="mono">{r.scrap_code}</td><td className="num font-medium">{nf(r.kg, 2)}</td><td className="num">{r.times}</td></tr>
              ))}</tbody>
            </table>
          ) : <Empty>Chưa ghi phế hôm nay ({df(today)}).</Empty>}
        </section>
      </div>

      {keeps(me, 'KPL') && (
        <section className="card mt-4 overflow-x-auto">
          <div className="card-h">Bán phế (Kế toán SX kiểm tra → Giám đốc duyệt)</div>
          {bags && bags.length > 0 ? (
            <form action={scrapSale}>
              <table className="tbl">
                <thead><tr><th /><th>Bao</th><th>Loại phế</th><th>Vị trí</th><th className="num">Tồn (kg)</th><th>Bán (kg)</th></tr></thead>
                <tbody>{bags.map((b) => (
                  <tr key={b.id}>
                    <td><input type="checkbox" name="hu" value={b.id} aria-label={`Chọn ${b.hu_no}`} /></td>
                    <td className="mono">{b.hu_no}</td><td><span className="mono">{b.item_code}</span> · {b.item_name}</td><td>{b.location_code}</td>
                    <td className="num">{nf(b.qty, 2)}</td>
                    <td><input className="inp w-28 text-right" name={`qty_${b.id}`} defaultValue={String(b.qty).replace('.', ',')} inputMode="decimal" aria-label={`Kg bán ${b.hu_no}`} /></td>
                  </tr>
                ))}</tbody>
              </table>
              <div className="grid gap-3 border-t border-line p-4 sm:grid-cols-[1fr_1fr_auto] sm:items-end">
                <label className="lbl"><span className="req">Người mua</span><input className="inp inp-y" name="buyer" required /></label>
                <label className="lbl">Ghi chú (giá thỏa thuận, xe…)<input className="inp" name="note" /></label>
                <SubmitButton>Lập phiếu bán phế</SubmitButton>
              </div>
            </form>
          ) : <Empty>Kho phế đang trống.</Empty>}
        </section>
      )}
    </>
  );
}
