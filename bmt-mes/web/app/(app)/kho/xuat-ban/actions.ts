'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { after } from 'next/server';
import { errText, withMsg } from '@/lib/kho';
import { flushEmailOutbox } from '@/lib/notify';
import { createClient } from '@/lib/supabase/server';
import { parseItems, str } from '../util';

// Lệnh giao theo số cuộn (migration 5100): các dòng chủng loại "MÃ|NHÃN|mét/cuộn" × số cuộn; database kiểm quyền, kiểm tồn
function readPayload(form: FormData, fail: (m: string) => never) {
  const items: { product_code: string; brand: string; pack_m: number | null; coils: number }[] = [];
  for (let i = 0; i < 12; i++) {
    const key = str(form, `kind_${i}`);
    const raw = str(form, `coils_${i}`);
    if (!key && !raw) continue;
    if (!key) fail(`Dòng ${i + 1}: chọn chủng loại cáp`);
    const coils = Number(raw);
    if (!Number.isInteger(coils) || coils <= 0) fail(`Dòng ${i + 1}: số cuộn phải là số nguyên > 0`);
    const [code, brand, pack] = key.split('|');
    items.push({ product_code: code, brand, pack_m: pack ? Number(pack) : null, coils });
  }
  if (!items.length) fail('Nhập ít nhất một dòng: chủng loại và số cuộn');
  return { customer_name: str(form, 'customer_name'), ship_date: str(form, 'ship_date') || null, note: str(form, 'note') || null, items };
}

export async function createDelivery(form: FormData) {
  const fail = (m: string): never => redirect(withMsg('/kho/xuat-ban', 'err', m));
  const p = readPayload(form, fail);
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc('delivery_save', { p_id: null, p: p });
  if (error) fail(errText(error.message));
  if (form.get('send') === '1') {
    const { error: e2 } = await supabase.schema('app').rpc('delivery_submit', { p_id: data as string });
    if (e2) redirect(withMsg(`/kho/xuat-ban/${data}`, 'err', 'Đã lưu nháp nhưng chưa gửi duyệt được: ' + errText(e2.message)));
    after(async () => { await flushEmailOutbox(); });
    revalidatePath('/', 'layout');
    redirect(withMsg(`/kho/xuat-ban/${data}`, 'ok', 'Đã lập lệnh giao, gửi Giám đốc duyệt.'));
  }
  redirect(withMsg(`/kho/xuat-ban/${data}`, 'ok', 'Đã lưu lệnh giao nháp. Kiểm tra rồi bấm Gửi Giám đốc duyệt.'));
}

export async function saveDelivery(form: FormData) {
  const id = str(form, 'delivery_id');
  const fail = (m: string): never => redirect(withMsg(`/kho/xuat-ban/${id}`, 'err', m));
  const p = readPayload(form, fail);
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('delivery_save', { p_id: id, p: p });
  if (error) fail(errText(error.message));
  revalidatePath(`/kho/xuat-ban/${id}`);
  redirect(withMsg(`/kho/xuat-ban/${id}`, 'ok', 'Đã lưu lệnh giao'));
}

export async function submitDelivery(form: FormData) {
  const id = str(form, 'delivery_id');
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('delivery_submit', { p_id: id });
  if (error) redirect(withMsg(`/kho/xuat-ban/${id}`, 'err', errText(error.message)));
  after(async () => { await flushEmailOutbox(); });
  revalidatePath('/', 'layout');
  redirect(withMsg(`/kho/xuat-ban/${id}`, 'ok', 'Đã gửi Giám đốc duyệt.'));
}

export async function cancelDelivery(form: FormData) {
  const id = str(form, 'delivery_id');
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('delivery_cancel', { p_id: id, p_reason: str(form, 'reason') });
  if (error) redirect(withMsg(`/kho/xuat-ban/${id}`, 'err', errText(error.message)));
  revalidatePath('/kho/xuat-ban');
  redirect(withMsg(`/kho/xuat-ban/${id}`, 'ok', 'Đã hủy lệnh giao'));
}

// Kế toán SX nhập "đã giao" từ phiếu xuất giấy người giữ kho TP ký: số cuộn đã xuất từng dòng (MES tự chọn cuộn, lô cũ trước)
export async function shipDirect(form: FormData) {
  const id = str(form, 'delivery_id');
  const items: { item_id: string; coils: number }[] = [];
  for (const itemId of form.getAll('item_id').map(String)) {
    const n = Number(str(form, `shipped_${itemId}`));
    if (!Number.isInteger(n) || n < 0) redirect(withMsg(`/kho/xuat-ban/${id}`, 'err', 'Số cuộn đã xuất phải là số nguyên ≥ 0'));
    items.push({ item_id: itemId, coils: n });
  }
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('delivery_ship', {
    p_id: id, p: { giver_code: str(form, 'giver_code') || null, paper_no: str(form, 'paper_no') || null, items },
  });
  if (error) redirect(withMsg(`/kho/xuat-ban/${id}`, 'err', errText(error.message)));
  after(async () => { await flushEmailOutbox(); });
  revalidatePath('/kho/xuat-ban');
  redirect(withMsg(`/kho/xuat-ban/${id}`, 'ok', 'Đã ghi xuất giao, trừ tồn thành phẩm. Phiếu được xác nhận khi Kế toán SX gửi báo cáo ngày.'));
}

// Lệnh giao cũ theo đơn bán (bobin đã giữ): người giữ kho quét đúng bobin
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
