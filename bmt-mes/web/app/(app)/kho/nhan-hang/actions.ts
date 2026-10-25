'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { errText, withMsg } from '@/lib/kho';
import { flushEmailOutbox } from '@/lib/notify';
import { createClient } from '@/lib/supabase/server';
import { after } from 'next/server';
import { str } from '../util';

export async function receiveGoods(form: FormData) {
  let lines: unknown[] = [];
  try { lines = JSON.parse(str(form, 'lines') || '[]'); } catch { redirect(withMsg('/kho/nhan-hang', 'err', 'Dữ liệu dòng hàng không hợp lệ')); }
  if (!lines.length) redirect(withMsg('/kho/nhan-hang', 'err', 'Thêm ít nhất một dòng hàng'));
  const poId = str(form, 'po_id') || null;
  const supabase = await createClient();
  const { data, error } = await supabase.schema('inv').rpc('receive_goods', {
    p_po: poId, p_supplier: poId ? null : str(form, 'supplier_id') || null, p_no_po_reason: poId ? null : str(form, 'no_po_reason'),
    p_delivery_note: str(form, 'delivery_note') || null, p_lines: lines,
  });
  if (error) redirect(withMsg('/kho/nhan-hang', 'err', errText(error.message)));
  after(async () => { await flushEmailOutbox(); });
  revalidatePath('/kho');
  redirect(withMsg(`/kho/phieu/${data}`, 'ok', 'Đã ghi phiếu nhập. In tem QR và dán cho từng ống/bao trước khi cất. QC đã nhận thông báo kiểm tra.'));
}
