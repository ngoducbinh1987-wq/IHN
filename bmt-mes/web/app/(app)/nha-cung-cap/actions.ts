'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';

// Danh mục nhà cung cấp: quyền (thêm mới, ngừng dùng, mặt hàng = TP Mua; sửa = NV mua, TP Mua; xóa = Quản trị) do database kiểm
const txt = (f: FormData, k: string) => String(f.get(k) ?? '').trim();
const friendly = (m: string) => m.replace(/^.*?ERROR:\s*/, '');
const go = (path: string, kind: 'ok' | 'err', msg: string): never => redirect(`${path}?${kind}=${encodeURIComponent(msg)}`);
const fields = (f: FormData) => ({
  p_name: txt(f, 'name'), p_tax_code: txt(f, 'tax_code') || null, p_contact: txt(f, 'contact') || null, p_phone: txt(f, 'phone') || null,
  p_email: txt(f, 'email') || null, p_address: txt(f, 'address') || null, p_payment_terms: txt(f, 'payment_terms') || null, p_note: txt(f, 'note') || null,
});
const materials = (f: FormData) => [...new Set(f.getAll('material').map(String).filter(Boolean))];

export async function createSupplier(f: FormData) {
  const db = await createClient();
  const { data, error } = await db.schema('app').rpc('supplier_save', { p_id: null, ...fields(f) });
  if (error) go('/nha-cung-cap/moi', 'err', friendly(error.message));
  const id = data as string;
  const mats = materials(f);
  revalidatePath('/nha-cung-cap');
  if (mats.length > 0) {
    const { error: e2 } = await db.schema('app').rpc('supplier_set_materials', { p_id: id, p_materials: mats });
    if (e2) go(`/nha-cung-cap/${id}`, 'err', 'Đã thêm nhà cung cấp nhưng chưa lưu được mặt hàng: ' + friendly(e2.message));
    go(`/nha-cung-cap/${id}`, 'ok', `Đã thêm nhà cung cấp "${txt(f, 'name')}" với ${mats.length} mặt hàng`);
  }
  go(`/nha-cung-cap/${id}`, 'ok', `Đã thêm nhà cung cấp "${txt(f, 'name')}". Chưa có mặt hàng: khai báo mặt hàng thì mới chọn được trên đơn mua`);
}

export async function updateSupplier(f: FormData) {
  const id = txt(f, 'id');
  const db = await createClient();
  const { error } = await db.schema('app').rpc('supplier_save', { p_id: id, ...fields(f) });
  if (error) go(`/nha-cung-cap/${id}`, 'err', friendly(error.message));
  revalidatePath('/nha-cung-cap');
  go(`/nha-cung-cap/${id}`, 'ok', 'Đã lưu thông tin nhà cung cấp');
}

export async function setSupplierMaterials(f: FormData) {
  const id = txt(f, 'id');
  const db = await createClient();
  const { data, error } = await db.schema('app').rpc('supplier_set_materials', { p_id: id, p_materials: materials(f) });
  if (error) go(`/nha-cung-cap/${id}`, 'err', friendly(error.message));
  const r = data as { added: number; removed: number; total: number };
  revalidatePath('/nha-cung-cap');
  go(`/nha-cung-cap/${id}`, 'ok', r.added + r.removed === 0
    ? 'Danh sách mặt hàng không đổi'
    : `Đã lưu mặt hàng: thêm ${r.added}, bỏ ${r.removed}, đang có ${r.total}`);
}

export async function setSupplierActive(f: FormData) {
  const id = txt(f, 'id');
  const active = txt(f, 'active') === '1';
  const db = await createClient();
  const { error } = await db.schema('app').rpc('supplier_set_active', { p_id: id, p_active: active, p_reason: txt(f, 'reason') || null });
  if (error) go(`/nha-cung-cap/${id}`, 'err', friendly(error.message));
  revalidatePath('/nha-cung-cap');
  go(`/nha-cung-cap/${id}`, 'ok', active ? 'Đã cho dùng lại nhà cung cấp' : 'Đã ngừng dùng nhà cung cấp: không còn hiện khi chọn NCC trên đơn mua');
}

export async function deleteSupplier(f: FormData) {
  const id = txt(f, 'id');
  const db = await createClient();
  const { data, error } = await db.schema('app').rpc('supplier_delete', { p_id: id, p_reason: txt(f, 'reason') });
  if (error) go(`/nha-cung-cap/${id}`, 'err', friendly(error.message));
  revalidatePath('/nha-cung-cap');
  go('/nha-cung-cap', 'ok', `Đã xóa nhà cung cấp ${data as string}`);
}
