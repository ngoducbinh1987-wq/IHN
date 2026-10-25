'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';

const MSG: Record<string, string> = {
  APPROVED: 'Đã phê duyệt bước cuối. Chứng từ có hiệu lực.',
  PENDING: 'Đã ghi nhận. Chứng từ chuyển sang bước tiếp theo.',
  REJECTED: 'Đã trả lại người lập kèm lý do.',
};

async function act(form: FormData, action: 'APPROVE' | 'REJECT' | 'COMMENT') {
  const id = String(form.get('id'));
  const comment = String(form.get('comment') ?? '').trim() || null;
  if (action !== 'APPROVE' && !comment) {
    redirect(`/duyet/${id}?err=` + encodeURIComponent(action === 'REJECT' ? 'Nhập lý do trả lại để người lập biết cần sửa gì' : 'Nhập ý kiến trước khi gửi'));
  }
  const supabase = await createClient();
  const { data, error } = await supabase.schema('wf').rpc('act', { p_request: id, p_action: action, p_comment: comment });
  if (error) redirect(`/duyet/${id}?err=` + encodeURIComponent(error.message));
  revalidatePath('/', 'layout');
  redirect(`/duyet/${id}?ok=` + encodeURIComponent(action === 'COMMENT' ? 'Đã ghi ý kiến' : MSG[data as string] ?? 'Đã xử lý'));
}

export async function approve(form: FormData) { await act(form, 'APPROVE'); }
export async function reject(form: FormData) { await act(form, 'REJECT'); }
export async function comment(form: FormData) { await act(form, 'COMMENT'); }
