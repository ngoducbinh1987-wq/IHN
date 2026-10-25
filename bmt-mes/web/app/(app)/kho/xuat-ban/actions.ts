'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { after } from 'next/server';
import { errText, withMsg } from '@/lib/kho';
import { flushEmailOutbox } from '@/lib/notify';
import { createClient } from '@/lib/supabase/server';
import { parseItems, str } from '../util';

export async function createDelivery(form: FormData) {
  const hus = form.getAll('hu').map(String).filter(Boolean);
  if (!hus.length) redirect(withMsg('/kho/xuat-ban', 'err', 'Chọn bobin cần giao'));
  const supabase = await createClient();
  const { data, error } = await supabase.schema('sales').rpc('create_delivery', {
    p_so: str(form, 'so_id'), p_hus: hus, p_ship_date: str(form, 'ship_date') || null, p_note: str(form, 'note') || null,
  });
  if (error) redirect(withMsg('/kho/xuat-ban', 'err', errText(error.message)));
  after(async () => { await flushEmailOutbox(); });
  revalidatePath('/kho/xuat-ban');
  redirect(withMsg(`/kho/xuat-ban/${data}`, 'ok', 'Đã lập lệnh giao: TP Kỹ thuật/QA xác nhận chất lượng, Giám đốc duyệt.'));
}

export async function ship(form: FormData) {
  const id = str(form, 'delivery_id');
  const { items, error: e1 } = parseItems(form.get('items'));
  if (e1) redirect(withMsg(`/kho/xuat-ban/${id}`, 'err', e1));
  const supabase = await createClient();
  const { error } = await supabase.schema('inv').rpc('ship_delivery', { p_delivery: id, p_scanned: items.map((i) => i.hu_id) });
  if (error) redirect(withMsg(`/kho/xuat-ban/${id}`, 'err', errText(error.message)));
  revalidatePath('/kho/xuat-ban');
  redirect(withMsg(`/kho/xuat-ban/${id}`, 'ok', 'Đã xuất kho giao hàng. In phiếu giao kèm danh sách bobin.'));
}
