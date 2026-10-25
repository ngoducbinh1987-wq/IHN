'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { after } from 'next/server';
import { parseNum } from '@/lib/format';
import { errText, withMsg } from '@/lib/kho';
import { flushEmailOutbox } from '@/lib/notify';
import { createClient } from '@/lib/supabase/server';
import { str } from '../util';

const back = (id: string, kind: 'ok' | 'err', msg: string) => redirect(withMsg(`/kho/phieu/${id}`, kind, msg));

export async function confirmDoc(form: FormData) { await review(form, true); }
export async function returnDoc(form: FormData) { await review(form, false); }

async function review(form: FormData, ok: boolean) {
  const id = str(form, 'doc_id');
  const supabase = await createClient();
  const { error } = await supabase.schema('inv').rpc('review_doc', { p_doc: id, p_ok: ok, p_note: str(form, 'note') || null });
  if (error) back(id, 'err', errText(error.message));
  if (!ok) after(async () => { await flushEmailOutbox(); });
  revalidatePath('/kho/phieu');
  if (str(form, 'next') === 'list') redirect(withMsg('/kho/phieu?tab=duyet', 'ok', `${str(form, 'doc_no')}: ${ok ? 'đã xác nhận' : 'đã trả lại'}`));
  back(id, 'ok', ok ? 'Đã xác nhận phiếu' : 'Đã trả lại phiếu, người lập và Giám đốc đã nhận thông báo');
}

export async function setPrices(form: FormData) {
  const id = str(form, 'doc_id');
  const prices: Record<string, number> = {};
  for (const [k, v] of form.entries()) {
    if (!k.startsWith('price_') || !String(v).trim()) continue;
    const n = parseNum(v);
    if (n === null || Number.isNaN(n) || n < 0) back(id, 'err', `Đơn giá "${v}" không hợp lệ`);
    prices[k.slice(6)] = n!;
  }
  const supabase = await createClient();
  const { error } = await supabase.schema('inv').rpc('set_receipt_price', { p_doc: id, p_prices: prices });
  if (error) back(id, 'err', errText(error.message));
  revalidatePath('/kho/phieu');
  back(id, 'ok', 'Đã nhập giá và ghi sổ phiếu nhập');
}

export async function reverseDoc(form: FormData) {
  const id = str(form, 'doc_id');
  const supabase = await createClient();
  const { data, error } = await supabase.schema('inv').rpc('reverse_doc', { p_doc: id, p_reason: str(form, 'reason') });
  if (error) back(id, 'err', errText(error.message));
  revalidatePath('/kho/phieu');
  redirect(withMsg(`/kho/phieu/${data}`, 'ok', 'Đã lập và ghi sổ phiếu đảo'));
}

export async function checkReceipt(form: FormData) {
  const id = str(form, 'doc_id');
  const supabase = await createClient();
  const { error } = await supabase.schema('purchase').rpc('check_receipt', { p_doc: id, p_note: str(form, 'note') || null });
  if (error) back(id, 'err', errText(error.message));
  revalidatePath(`/kho/phieu/${id}`);
  back(id, 'ok', 'Đã ghi nhận đối chiếu PO');
}
