'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { after } from 'next/server';
import { parseNum } from '@/lib/format';
import { errText, withMsg } from '@/lib/kho';
import { flushEmailOutbox } from '@/lib/notify';
import { createClient } from '@/lib/supabase/server';
import { optUuid, parseItems, str } from '../util';

export async function createRequisition(form: FormData) {
  const qty = parseNum(form.get('qty_m'));
  if (qty === null || Number.isNaN(qty) || qty <= 0) redirect(withMsg('/kho/cap-phat', 'err', 'Nhập số mét sản xuất của ca/ngày'));
  const supabase = await createClient();
  const { data, error } = await supabase.schema('inv').rpc('create_requisition', {
    p_wo: str(form, 'wo_id'), p_qty_m: qty, p_work_date: str(form, 'work_date') || null, p_note: str(form, 'note') || null,
  });
  if (error) redirect(withMsg('/kho/cap-phat', 'err', errText(error.message)));
  after(async () => { await flushEmailOutbox(); });
  revalidatePath('/kho/cap-phat');
  redirect(withMsg(`/kho/cap-phat/${data}`, 'ok', 'Đã tạo phiếu lĩnh theo định mức. Thủ kho đã nhận thông báo.'));
}

// Dòng vật tư dạng "CU-024 5" hoặc "CU-024; 5,5" mỗi dòng
export async function createExtra(form: FormData) {
  const lines: { material_code: string; qty: number }[] = [];
  for (const row of str(form, 'lines').split(/\r?\n/)) {
    const s = row.trim();
    if (!s) continue;
    const m = s.match(/^([A-Za-z0-9._-]+)[\s;,:|]+(.+)$/);
    const q = m ? parseNum(m[2].trim()) : null;
    if (!m || q === null || Number.isNaN(q) || q <= 0) redirect(withMsg('/kho/cap-phat', 'err', `Dòng "${s}" chưa đúng dạng: MÃ_VẬT_TƯ số_lượng`));
    lines.push({ material_code: m![1].toUpperCase(), qty: q! });
  }
  if (!lines.length) redirect(withMsg('/kho/cap-phat', 'err', 'Nhập ít nhất một vật tư cần lĩnh thêm'));
  const supabase = await createClient();
  const { data, error } = await supabase.schema('inv').rpc('create_extra_requisition', {
    p_wo: str(form, 'wo_id'), p_lines: lines, p_reason: str(form, 'reason'), p_note: str(form, 'note') || null,
  });
  if (error) redirect(withMsg('/kho/cap-phat', 'err', errText(error.message)));
  after(async () => { await flushEmailOutbox(); });
  revalidatePath('/kho/cap-phat');
  redirect(withMsg(`/kho/cap-phat/${data}`, 'ok', 'Đã gửi phiếu lĩnh bổ sung cho TP Kỹ thuật/QA duyệt.'));
}

export async function issuePick(form: FormData) {
  const id = str(form, 'req_id');
  const back = `/kho/cap-phat/${id}`;
  const { items, error: e1 } = parseItems(form.get('items'));
  if (e1) redirect(withMsg(back, 'err', e1));
  if (!items.length) redirect(withMsg(back, 'err', 'Quét ít nhất một ống/bao/cuộn'));
  const supabase = await createClient();
  const { data, error } = await supabase.schema('inv').rpc('issue_pick', {
    p_req: id, p_items: items.map((i) => ({ hu_id: i.hu_id, qty: i.qty, reason: i.reason })),
    p_receiver: optUuid(form, 'receiver_id'), p_witness: optUuid(form, 'witness_id'), p_off_hours_reason: str(form, 'off_hours_reason') || null,
  });
  if (error) redirect(withMsg(back, 'err', errText(error.message)));
  const { data: doc } = await supabase.schema('inv').from('stock_docs').select('doc_no').eq('id', data as string).maybeSingle();
  after(async () => { await flushEmailOutbox(); });
  revalidatePath(back);
  redirect(withMsg(back, 'ok', `Đã xuất kho, phiếu ${doc?.doc_no ?? ''}. Công nhân nhận hàng xác nhận tại máy.`));
}

export async function cancelRequisition(form: FormData) {
  const id = str(form, 'req_id');
  const supabase = await createClient();
  const { error } = await supabase.schema('inv').rpc('cancel_requisition', { p_req: id, p_reason: str(form, 'reason') });
  if (error) redirect(withMsg(`/kho/cap-phat/${id}`, 'err', errText(error.message)));
  revalidatePath('/kho/cap-phat');
  redirect(withMsg(`/kho/cap-phat/${id}`, 'ok', 'Đã hủy phiếu lĩnh'));
}
