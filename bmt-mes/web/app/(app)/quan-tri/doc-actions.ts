'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';

// Can thiệp của Quản trị hệ thống: hủy quy trình duyệt, mở lại chứng từ để sửa, xóa chứng từ (database kiểm quyền, ghi nhật ký)
const path = (raw: FormDataEntryValue | null, fallback: string) => {
  const p = String(raw ?? '');
  return /^\/(?!\/)/.test(p) ? p : fallback;
};
const go = (to: string, kind: 'ok' | 'err', msg: string): never =>
  redirect(`${to}${to.includes('?') ? '&' : '?'}${kind}=${encodeURIComponent(msg)}`);

export async function adminCancelRequest(form: FormData) {
  const id = String(form.get('request_id') ?? '');
  const back = path(form.get('back'), `/duyet/${id}`);
  const reason = String(form.get('reason') ?? '').trim();
  if (!reason) go(back, 'err', 'Nhập lý do');
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('admin_cancel_request', { p_request: id, p_reason: reason });
  if (error) go(back, 'err', error.message);
  revalidatePath('/', 'layout');
  go(back, 'ok', 'Đã hủy quy trình duyệt. Chứng từ trở về trạng thái để sửa, người lập đã nhận thông báo.');
}

async function docAction(form: FormData, op: 'reopen' | 'delete') {
  const back = path(form.get('back'), '/duyet');
  const after = path(form.get('after'), '/duyet');
  const reason = String(form.get('reason') ?? '').trim();
  if (!reason) go(back, 'err', 'Nhập lý do');
  if (op === 'delete' && form.get('confirm') !== 'on') go(back, 'err', 'Đánh dấu "Tôi hiểu chứng từ sẽ bị xóa" trước khi xóa');
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc('admin_doc', {
    p_doc_type: String(form.get('doc_type') ?? ''), p_doc_id: String(form.get('doc_id') ?? ''), p_action: op, p_reason: reason,
  });
  if (error) go(back, 'err', error.message);
  revalidatePath('/', 'layout');
  if (op === 'delete') go(after, 'ok', `Đã xóa ${data}. Bản sao nội dung lưu trong nhật ký Quản trị.`);
  go(back, 'ok', `Đã mở lại ${data} về Nháp để sửa. Sửa xong gửi duyệt lại.`);
}

export async function adminReopenDoc(form: FormData) { await docAction(form, 'reopen'); }
export async function adminDeleteDoc(form: FormData) { await docAction(form, 'delete'); }
