'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';

// Chỉ Quản trị hệ thống: database kiểm lại (core.is_admin) và ghi nhật ký hệ thống
export async function savePages(form: FormData) {
  const grants = form.getAll('g').map(String);
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc('admin_save_role_pages', { p_grants: grants });
  if (error) redirect('/quan-tri/phan-quyen?err=' + encodeURIComponent(error.message));
  revalidatePath('/', 'layout');
  redirect('/quan-tri/phan-quyen?ok=' + encodeURIComponent(`Đã lưu quyền vào mục (${data} ô được tick). Người dùng thấy menu mới khi tải lại trang.`));
}

export async function savePerms(form: FormData) {
  const role = String(form.get('role'));
  const perms = form.getAll('p').map(String);
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc('admin_save_role_perms', { p_role: role, p_perms: perms });
  const back = `/quan-tri/phan-quyen?tab=thao-tac&role=${encodeURIComponent(role)}`;
  if (error) redirect(back + '&err=' + encodeURIComponent(error.message));
  revalidatePath('/', 'layout');
  redirect(back + '&ok=' + encodeURIComponent(`Đã lưu quyền thao tác của vai trò (${data} quyền).`));
}
