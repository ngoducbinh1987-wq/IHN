'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { after } from 'next/server';
import { parseNum } from '@/lib/format';
import { flushEmailOutbox, submitForApproval } from '@/lib/notify';
import { createClient } from '@/lib/supabase/server';

// Đơn mua hàng: mọi kiểm tra quyền (NV mua sửa nháp, người đang duyệt sửa khi chờ duyệt), ghi lịch sử do database làm
const txt = (f: FormData, k: string) => String(f.get(k) ?? '').trim();
const back = (id: string, kind: 'ok' | 'err', msg: string): never => redirect(`/don-mua/${id}?${kind}=${encodeURIComponent(msg)}`);
const friendly = (m: string) => m.replace(/^.*?ERROR:\s*/, '');

export async function savePoHeader(f: FormData) {
  const id = txt(f, 'po_id');
  const db = await createClient();
  const { error } = await db.schema('app').rpc('po_save_header', {
    p_po: id, p_supplier: txt(f, 'supplier_id') || null, p_expected: txt(f, 'expected_date') || null,
    p_terms: txt(f, 'payment_terms') || null, p_note: txt(f, 'note') || null, p_is_import: f.get('is_import') === 'on',
  });
  if (error) back(id, 'err', friendly(error.message));
  revalidatePath(`/don-mua/${id}`);
  back(id, 'ok', 'Đã lưu thông tin đơn mua');
}

export async function savePoLine(f: FormData) {
  const id = txt(f, 'po_id');
  const qty = parseNum(f.get('qty'));
  const rawPrice = txt(f, 'unit_price');
  const price = rawPrice ? parseNum(rawPrice) : null;
  if (qty === null || Number.isNaN(qty) || qty <= 0) back(id, 'err', 'Số lượng phải lớn hơn 0');
  if (price !== null && (Number.isNaN(price) || price < 0)) back(id, 'err', 'Đơn giá không hợp lệ');
  const db = await createClient();
  const { error } = await db.schema('app').rpc('po_save_line', {
    p_po: id, p_line: txt(f, 'line_id') || null, p_material_code: txt(f, 'material_code').split(' · ')[0].trim() || null,
    p_qty: qty, p_price: price, p_date: txt(f, 'expected_date') || null, p_note: txt(f, 'note') || null,
  });
  if (error) back(id, 'err', friendly(error.message));
  revalidatePath(`/don-mua/${id}`);
  back(id, 'ok', txt(f, 'line_id') ? 'Đã lưu dòng' : 'Đã thêm dòng vật tư');
}

export async function deletePoLine(f: FormData) {
  const id = txt(f, 'po_id');
  const db = await createClient();
  const { error } = await db.schema('app').rpc('po_delete_line', { p_line: txt(f, 'line_id') });
  if (error) back(id, 'err', friendly(error.message));
  revalidatePath(`/don-mua/${id}`);
  back(id, 'ok', 'Đã bỏ dòng');
}

// Chia đơn: các dòng đã tích chuyển sang NCC khác (MES gom vào đơn nháp cùng nguồn của NCC đó, chưa có thì lập đơn mới)
export async function movePoLines(f: FormData) {
  const id = txt(f, 'po_id');
  const lines = f.getAll('line').map(String).filter(Boolean);
  if (!lines.length) back(id, 'err', 'Tích chọn dòng cần chuyển sang NCC khác');
  const db = await createClient();
  const { data, error } = await db.schema('app').rpc('po_move_lines', { p_po: id, p_lines: lines, p_supplier: txt(f, 'supplier_id') || null });
  if (error) back(id, 'err', friendly(error.message));
  revalidatePath('/don-mua');
  redirect(`/don-mua/${data}?ok=` + encodeURIComponent(`Đã chuyển ${lines.length} dòng sang đơn của NCC đã chọn`));
}

export async function cancelPo(f: FormData) {
  const id = txt(f, 'po_id');
  const db = await createClient();
  const { error } = await db.schema('app').rpc('po_cancel', { p_po: id, p_reason: txt(f, 'reason') });
  if (error) back(id, 'err', friendly(error.message));
  revalidatePath('/don-mua');
  back(id, 'ok', 'Đã hủy đơn mua');
}

// NV mua kiểm tra xong: duyệt, gửi TP Mua (wf.submit kiểm NCC, giá, quyền)
export async function submitPo(f: FormData) {
  const id = txt(f, 'po_id');
  const { error } = await submitForApproval('PO', id, txt(f, 'po_no'), txt(f, 'summary'));
  if (error) back(id, 'err', friendly(error.message));
  revalidatePath('/', 'layout');
  back(id, 'ok', 'Đã duyệt, gửi TP Mua. TP Mua duyệt xong chuyển Giám đốc và báo Kế toán.');
}

// NCC mới ngay trên đơn mua: tạo rồi chọn luôn cho đơn
export async function addSupplier(f: FormData) {
  const id = txt(f, 'po_id');
  const db = await createClient();
  const { data, error } = await db.schema('app').rpc('save_supplier', {
    p_name: txt(f, 'name'), p_tax_code: txt(f, 'tax_code') || null, p_contact: txt(f, 'contact') || null, p_address: txt(f, 'address') || null,
  });
  if (error) back(id, 'err', friendly(error.message));
  const { data: po } = await db.schema('purchase').from('purchase_orders').select('expected_date, payment_terms, note, is_import').eq('id', id).single();
  const { error: e2 } = await db.schema('app').rpc('po_save_header', {
    p_po: id, p_supplier: data as string, p_expected: po?.expected_date ?? null, p_terms: po?.payment_terms ?? null, p_note: po?.note ?? null,
    p_is_import: po?.is_import ?? false,
  });
  if (e2) back(id, 'err', 'Đã thêm NCC nhưng chưa gán cho đơn: ' + friendly(e2.message));
  revalidatePath(`/don-mua/${id}`);
  back(id, 'ok', `Đã thêm NCC "${txt(f, 'name')}" và chọn cho đơn này`);
}

// Từ đề xuất mua đã duyệt (bổ sung, tích trữ, tối ưu…)
export async function poFromPr(f: FormData) {
  const prId = txt(f, 'pr_id');
  const db = await createClient();
  const { data, error } = await db.schema('app').rpc('po_from_pr', { p_pr: prId });
  if (error) redirect(`/de-xuat/${prId}?err=` + encodeURIComponent(friendly(error.message)));
  const ids = ((data as { po_ids?: string[] })?.po_ids ?? []);
  const nos = ((data as { po_nos?: string[] })?.po_nos ?? []).join(', ');
  revalidatePath('/don-mua');
  if (ids.length === 1) redirect(`/don-mua/${ids[0]}?ok=` + encodeURIComponent(`Đã lập ${nos}. Kiểm tra NCC, giá rồi bấm "Duyệt, gửi TP Mua".`));
  redirect(`/don-mua?ok=` + encodeURIComponent(`Đã lập ${ids.length} đơn mua (${nos}) theo NCC. Kiểm tra từng đơn rồi gửi TP Mua.`));
}

// Phần MRP còn thiếu của kế hoạch tháng đã chốt (MES đã tự sinh khi Chủ tịch chốt; dùng khi lỡ hủy đơn)
export async function poFromMrp(f: FormData) {
  const planId = txt(f, 'plan_id');
  const db = await createClient();
  const { data, error } = await db.schema('app').rpc('po_from_mrp', { p_plan: planId });
  if (error) redirect(`/ke-hoach/${planId}?err=` + encodeURIComponent(friendly(error.message)));
  after(async () => { await flushEmailOutbox(); });
  revalidatePath('/don-mua');
  redirect(`/ke-hoach/${planId}?ok=` + encodeURIComponent(`Đã lập ${(data as { count?: number })?.count ?? 0} đơn mua cho phần còn thiếu, NV mua đã nhận thông báo`) + '#don-mua');
}
