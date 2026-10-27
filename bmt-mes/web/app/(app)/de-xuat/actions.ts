'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { after } from 'next/server';
import { parseNum } from '@/lib/format';
import { flushEmailOutbox, submitForApproval } from '@/lib/notify';
import { createClient } from '@/lib/supabase/server';

const back = (id: string, kind: 'ok' | 'err', msg: string) => redirect(`/de-xuat/${id}?${kind}=${encodeURIComponent(msg)}`);

export async function createPr(form: FormData) {
  const codes = form.getAll('material_code').map(String);
  const qtys = form.getAll('qty');
  const lines: { material_code: string; qty: number }[] = [];
  for (let i = 0; i < codes.length; i++) {
    const code = codes[i].split(' · ')[0].trim();
    if (!code) continue;
    const qty = parseNum(qtys[i] ?? null);
    if (qty === null || Number.isNaN(qty) || qty <= 0) redirect('/de-xuat/moi?err=' + encodeURIComponent(`Dòng ${i + 1} (${code}): số lượng phải lớn hơn 0`));
    lines.push({ material_code: code, qty: qty! });
  }
  if (lines.length === 0) redirect('/de-xuat/moi?err=' + encodeURIComponent('Nhập ít nhất một dòng vật tư'));
  const supabase = await createClient();
  const { data: id, error } = await supabase.schema('app').rpc('create_pr', {
    p_need_date: String(form.get('need_date') || '') || null,
    p_note: String(form.get('note') ?? ''),
    p_lines: lines,
    p_kind: String(form.get('kind') || 'BO_SUNG'),
  });
  if (error) redirect('/de-xuat/moi?err=' + encodeURIComponent(error.message));
  if (form.get('send') === '1') {
    const { data: pr } = await supabase.schema('purchase').from('purchase_requests').select('pr_no, note').eq('id', id as string).single();
    const { error: e2 } = await submitForApproval('PR', id as string, pr!.pr_no, pr!.note ?? '');
    if (e2) back(id as string, 'err', 'Đã lưu nháp nhưng chưa gửi duyệt được: ' + e2.message);
    revalidatePath('/', 'layout');
    back(id as string, 'ok', `Đã tạo ${pr!.pr_no} và gửi duyệt`);
  }
  back(id as string, 'ok', 'Đã lưu đề xuất nháp. Kiểm tra lại rồi bấm Gửi duyệt.');
}

export async function savePrLine(form: FormData) {
  const id = String(form.get('pr_id'));
  const qty = parseNum(form.get('qty'));
  if (qty === null || Number.isNaN(qty) || qty <= 0) back(id, 'err', 'Số lượng phải lớn hơn 0');
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('save_pr_line', {
    p_pr: id, p_material_code: String(form.get('material_code') ?? '').split(' · ')[0].trim(), p_qty: qty,
    p_need_date: String(form.get('need_date') || '') || null,
  });
  if (error) back(id, 'err', error.message);
  revalidatePath(`/de-xuat/${id}`);
  back(id, 'ok', 'Đã lưu dòng vật tư');
}

export async function deletePrLine(form: FormData) {
  const id = String(form.get('pr_id'));
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('delete_pr_line', { p_line: String(form.get('line_id')) });
  if (error) back(id, 'err', error.message);
  revalidatePath(`/de-xuat/${id}`);
  back(id, 'ok', 'Đã xóa dòng');
}

export async function savePrHeader(form: FormData) {
  const id = String(form.get('pr_id'));
  const supabase = await createClient();
  // qua hàm database: người lập sửa khi nháp, người đang duyệt sửa khi chờ duyệt (ghi lịch sử duyệt)
  const { error } = await supabase.schema('app').rpc('save_pr_header', {
    p_pr: id, p_note: String(form.get('note') ?? '').trim(), p_need_date: String(form.get('need_date') || '') || null,
  });
  if (error) back(id, 'err', error.message);
  back(id, 'ok', 'Đã lưu');
}

export async function submitPr(form: FormData) {
  const id = String(form.get('pr_id'));
  const { error } = await submitForApproval('PR', id, String(form.get('pr_no')), String(form.get('note') ?? ''));
  if (error) back(id, 'err', error.message);
  revalidatePath('/', 'layout');
  back(id, 'ok', 'Đã gửi duyệt. Người duyệt đã nhận thông báo.');
}

export async function setPrKind(form: FormData) {
  const id = String(form.get('pr_id'));
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('set_pr_kind', { p_pr: id, p_kind: String(form.get('kind')) });
  if (error) back(id, 'err', error.message);
  revalidatePath(`/de-xuat/${id}`);
  back(id, 'ok', 'Đã đổi loại đề xuất');
}

// NV mua / TP Mua: đề xuất mua bổ sung cho vật tư dưới mức tồn dự phòng
export async function prFromSafety() {
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc('pr_from_safety', { p_note: null });
  if (error) redirect('/de-xuat/du-phong?err=' + encodeURIComponent(error.message));
  back(data as string, 'ok', 'Đã lập đề xuất mua bổ sung bù tồn dự phòng (nháp). Kiểm tra số lượng rồi gửi duyệt.');
}

// ---------------- Tồn dự phòng: TP Mua lập phiếu điều chỉnh mức → Giám đốc duyệt (được sửa khi duyệt) ----------------
const ssBack = (id: string, kind: 'ok' | 'err', msg: string) => redirect(`/de-xuat/du-phong/${id}?${kind}=${encodeURIComponent(msg)}`);

// Các dòng của form (tối đa 60): mã vật tư, số ngày sản xuất, số lượng dự phòng (trống = MES tính theo số ngày), ghi chú
function ssLines(form: FormData, fail: (msg: string) => never) {
  const lines: Record<string, unknown>[] = [];
  for (let i = 0; i < 60; i++) {
    const code = String(form.get(`code_${i}`) ?? '').split(' · ')[0].trim().toUpperCase();
    if (!code) continue;
    const rawQty = String(form.get(`qty_${i}`) ?? '').trim();
    const rawDays = String(form.get(`days_${i}`) ?? '').trim();
    const qty = rawQty ? parseNum(rawQty) : null;
    const days = rawDays ? parseNum(rawDays) : null;
    if (rawQty && (qty === null || Number.isNaN(qty) || qty < 0)) fail(`${code}: số lượng "${rawQty}" không hợp lệ`);
    if (rawDays && (days === null || Number.isNaN(days) || days < 0)) fail(`${code}: số ngày "${rawDays}" không hợp lệ`);
    lines.push({ material_code: code, qty, days, note: String(form.get(`note_${i}`) ?? '').trim() });
  }
  return lines;
}

export async function createSafety(form: FormData) {
  const fail = (msg: string): never => redirect('/de-xuat/du-phong?err=' + encodeURIComponent(msg));
  const lines = ssLines(form, fail);
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc('safety_create', { p_reason: String(form.get('reason') ?? ''), p_lines: lines });
  if (error) fail(error.message);
  ssBack(data as string, 'ok', 'Đã lập phiếu nháp. Kiểm tra mức dự phòng rồi gửi Giám đốc duyệt.');
}

export async function saveSafety(form: FormData) {
  const id = String(form.get('id'));
  const lines = ssLines(form, (msg) => ssBack(id, 'err', msg));
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('safety_save', { p_id: id, p_reason: String(form.get('reason') ?? ''), p_lines: lines });
  if (error) ssBack(id, 'err', error.message);
  revalidatePath(`/de-xuat/du-phong/${id}`);
  ssBack(id, 'ok', 'Đã lưu phiếu');
}

export async function submitSafety(form: FormData) {
  const id = String(form.get('id'));
  const lines = ssLines(form, (msg) => ssBack(id, 'err', msg));
  const supabase = await createClient();
  const save = await supabase.schema('app').rpc('safety_save', { p_id: id, p_reason: String(form.get('reason') ?? ''), p_lines: lines });
  if (save.error) ssBack(id, 'err', save.error.message);
  const { error } = await supabase.schema('app').rpc('safety_submit', { p_id: id });
  if (error) ssBack(id, 'err', error.message);
  after(async () => { await flushEmailOutbox(); });
  revalidatePath('/', 'layout');
  ssBack(id, 'ok', 'Đã gửi Giám đốc duyệt. Duyệt xong MES áp mức mới và cảnh báo khi tồn thấp hơn mức.');
}

export async function cancelSafety(form: FormData) {
  const id = String(form.get('id'));
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('safety_cancel', { p_id: id });
  if (error) ssBack(id, 'err', error.message);
  revalidatePath(`/de-xuat/du-phong/${id}`);
  ssBack(id, 'ok', 'Đã hủy phiếu nháp');
}
