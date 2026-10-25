'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { parseNum } from '@/lib/format';
import { submitForApproval } from '@/lib/notify';
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
  const { error } = await supabase.schema('purchase').from('purchase_requests').update({
    note: String(form.get('note') ?? '').trim(), need_date: String(form.get('need_date') || '') || null,
  }).eq('id', id).eq('status', 'DRAFT');
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
