import Link from 'next/link';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { after } from 'next/server';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Toolbar } from '@/components/ui';
import { df, nf, parseNum } from '@/lib/format';
import { LoadErrors, SCRAP_CAT, errText, keeps, withMsg } from '@/lib/kho';
import { flushEmailOutbox } from '@/lib/notify';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { str } from '../util';

export const metadata = { title: 'Phế liệu' };

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
  const le = new LoadErrors();
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Ho_Chi_Minh' });
  const [{ data: recs }, { data: bags }] = le.all(await Promise.all([
    supabase.schema('app').rpc('loss_scrap', { p_from: today, p_to: today }),
    keeps(me, 'KPL') ? supabase.schema('app').from('v_hu').select('id, hu_no, item_code, item_name, qty, location_code, lot_no').eq('warehouse_code', 'KPL').eq('status', 'ACTIVE').order('hu_no') : Promise.resolve({ data: [] as never[] }),
  ]));
  type Rec = { reason_name: string; category: string; op_code: string; machine_code: string | null; scrap_code: string; kg: number; times: number };
  return (
    <>
      <Toolbar title="Phế liệu" reload="/kho/phe" actions={<Link className="btn btn-soft" href="/bao-cao/hao-hut">Báo cáo hao hụt</Link>} />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /><Flash err={le.text} /></div>
      <p className="mb-3 text-[13px] text-muted">Phế cân theo lý do, ghi trên phiếu hoàn thành và báo cáo ca; nhập kho phế liệu với giá trị 0. Bán phế: Kế toán SX kiểm tra, Giám đốc duyệt.</p>
      <div className="grid gap-4 lg:grid-cols-2">
        <section className="card p-4 text-[14px]">
          <div className="mb-1 font-medium">Phế vào kho phế tự động</div>
          <p className="text-muted">Phế ghi trên <Link className="link" href="/phieu-hoan-thanh">phiếu hoàn thành bobin</Link> và <Link className="link" href="/ghi-nhan-ca">báo cáo ca</Link> (cân theo lý do, phế đồng để thùng riêng).
            Khi TP SX chốt ca, MES tự nhập phế của ca vào kho phế theo mã phế (mỗi mã một bao/ngày, giá trị 0); phần còn lại nhập khi Kế toán SX gửi báo cáo ngày.</p>
        </section>
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
