'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { after } from 'next/server';
import { flushEmailOutbox } from '@/lib/notify';
import { createClient } from '@/lib/supabase/server';

const MSG: Record<string, string> = {
  APPROVED: 'Đã duyệt bước cuối. Quy trình hoàn thành, chứng từ có hiệu lực.',
  PENDING: 'Đã chuyển giai đoạn tiếp. Người duyệt tiếp theo đã nhận thông báo.',
  REJECTED: 'Đã trả lại người lập kèm lý do.',
};

async function act(form: FormData, action: 'APPROVE' | 'REJECT' | 'COMMENT') {
  const id = String(form.get('id'));
  const comment = String(form.get('comment') ?? '').trim() || null;
  if (action !== 'APPROVE' && !comment) {
    redirect(`/duyet/${id}?err=` + encodeURIComponent(action === 'REJECT' ? 'Nhập lý do trả lại để người lập biết cần sửa gì' : 'Nhập nội dung trao đổi trước khi gửi'));
  }
  const supabase = await createClient();
  const { data, error } = await supabase.schema('wf').rpc('act', { p_request: id, p_action: action, p_comment: comment });
  if (error) redirect(`/duyet/${id}?err=` + encodeURIComponent(error.message));
  after(flushEmailOutbox);
  revalidatePath('/', 'layout');
  const tab = action === 'COMMENT' ? '&tab=trao-doi' : '';
  redirect(`/duyet/${id}?ok=` + encodeURIComponent(action === 'COMMENT' ? 'Đã gửi trao đổi' : MSG[data as string] ?? 'Đã xử lý') + tab);
}

export async function approve(form: FormData) { await act(form, 'APPROVE'); }
export async function reject(form: FormData) { await act(form, 'REJECT'); }
export async function comment(form: FormData) { await act(form, 'COMMENT'); }
