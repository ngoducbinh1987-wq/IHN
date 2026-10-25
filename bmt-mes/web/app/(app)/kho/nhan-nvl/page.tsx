import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Toolbar } from '@/components/ui';
import { df, nf } from '@/lib/format';
import { errText, withMsg } from '@/lib/kho';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Nhận NVL tại máy' };

async function confirm(form: FormData) {
  'use server';
  const supabase = await createClient();
  const { error } = await supabase.schema('inv').rpc('confirm_issue', { p_doc: String(form.get('doc_id')) });
  if (error) redirect(withMsg('/kho/nhan-nvl', 'err', errText(error.message)));
  revalidatePath('/kho/nhan-nvl');
  redirect(withMsg('/kho/nhan-nvl', 'ok', `Đã xác nhận nhận ${form.get('doc_no')}`));
}

export default async function ReceiveAtMachine({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string }> }) {
  const sp = await searchParams;
  const me = await requireMe();
  const supabase = await createClient();
  const { data: docs } = await supabase.schema('app').from('v_stock_docs')
    .select('id, doc_no, posted_at, posted_by_name, ref_no, req_no, received_at').eq('doc_type', 'ISSUE_WO').eq('receiver_id', me.id)
    .order('posted_at', { ascending: false }).limit(40);
  const ids = (docs ?? []).map((d) => d.id);
  const { data: lines } = ids.length
    ? await supabase.schema('app').from('v_stock_doc_lines').select('doc_id, hu_no, item_code, item_name, qty, uom, lot_no').in('doc_id', ids).order('line_no')
    : { data: [] as never[] };
  const pending = (docs ?? []).filter((d) => !d.received_at);
  const done = (docs ?? []).filter((d) => d.received_at).slice(0, 10);
  return (
    <>
      <Toolbar title="Nhận nguyên vật liệu tại máy" reload="/kho/nhan-nvl" />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /></div>
      <p className="mb-3 text-[13px] text-muted">Kiểm đúng mã, đủ số ống/bao trên tem QR rồi bấm Xác nhận. Người xuất kho không tự nhận thay.</p>
      {pending.length === 0 && <div className="card mb-4"><Empty>Không có hàng chờ bạn xác nhận.</Empty></div>}
      <div className="flex flex-col gap-3">
        {pending.map((d) => (
          <section key={d.id} className="card">
            <div className="card-h flex-wrap"><span><span className="mono">{d.doc_no}</span> · lệnh {d.ref_no} · {d.req_no}</span>
              <span className="text-[12.5px] font-normal text-muted">{d.posted_by_name} xuất lúc {df(d.posted_at, true)}</span></div>
            <ul className="divide-y divide-line">
              {(lines ?? []).filter((l) => l.doc_id === d.id).map((l) => (
                <li key={l.hu_no} className="flex flex-wrap justify-between gap-2 px-4 py-2 text-[14px]">
                  <span><b className="mono">{l.hu_no}</b> · <span className="mono">{l.item_code}</span> {l.item_name}</span>
                  <b>{nf(l.qty, 3)} {l.uom}</b>
                </li>
              ))}
            </ul>
            <form action={confirm} className="border-t border-line p-3">
              <input type="hidden" name="doc_id" value={d.id} /><input type="hidden" name="doc_no" value={d.doc_no} />
              <SubmitButton className="btn btn-pri w-full sm:w-auto">Xác nhận đã nhận đủ</SubmitButton>
            </form>
          </section>
        ))}
      </div>
      {done.length > 0 && (
        <section className="card mt-4 overflow-x-auto">
          <div className="card-h">Đã nhận gần đây</div>
          <table className="tbl"><tbody>{done.map((d) => (
            <tr key={d.id}><td className="mono">{d.doc_no}</td><td>lệnh {d.ref_no}</td><td className="whitespace-nowrap">nhận {df(d.received_at, true)}</td></tr>
          ))}</tbody></table>
        </section>
      )}
    </>
  );
}
