'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';

// Mở thông báo: đánh dấu đã đọc rồi chuyển tới chứng từ
export async function openNotification(form: FormData) {
  const id = Number(form.get('id'));
  const link = String(form.get('link') ?? '');
  const supabase = await createClient();
  await supabase.schema('app').rpc('mark_read', { p_id: id });
  revalidatePath('/', 'layout');
  redirect(link.startsWith('/') ? link : '/thong-bao');
}

export async function markAllRead() {
  const supabase = await createClient();
  await supabase.schema('app').rpc('mark_read', { p_id: null });
  revalidatePath('/', 'layout');
  redirect('/thong-bao');
}
