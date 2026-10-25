'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { can, requireMe } from '@/lib/session';
import { createAdminClient, createClient } from '@/lib/supabase/server';

const fail = (msg: string) => redirect('/quan-tri?them=1&err=' + encodeURIComponent(msg));

function profileArgs(form: FormData, id: string) {
  return {
    p_user: id,
    p_full_name: String(form.get('full_name') ?? '').trim(),
    p_employee_code: String(form.get('employee_code') ?? ''),
    p_department: String(form.get('department') ?? ''),
    p_title: String(form.get('title') ?? '').trim(),
    p_roles: form.getAll('roles').map(String),
    p_status: String(form.get('status') ?? 'ACTIVE'),
  };
}

export async function createUser(form: FormData) {
  const me = await requireMe();
  if (!can(me, 'admin', 'edit')) fail('Không có quyền quản trị người dùng');
  const email = String(form.get('email') ?? '').trim().toLowerCase();
  const password = String(form.get('password') ?? '');
  if (password.length < 10) fail('Mật khẩu tạm phải có ít nhất 10 ký tự');
  if (form.getAll('roles').length === 0) fail('Chọn ít nhất một vai trò');

  // Tạo tài khoản đăng nhập bằng service key (chỉ chạy trên server), rồi ghi hồ sơ + vai trò bằng phiên của quản trị viên
  const admin = createAdminClient();
  const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (error || !data.user) fail(error?.message.includes('already') ? `Email ${email} đã có tài khoản` : error?.message ?? 'Không tạo được tài khoản');
  const supabase = await createClient();
  const { error: e2 } = await supabase.schema('app').rpc('admin_upsert_user', profileArgs(form, data.user!.id));
  if (e2) {
    await admin.auth.admin.deleteUser(data.user!.id);
    fail(e2.message);
  }
  const { error: e3 } = await supabase.schema('app').rpc('admin_set_warehouses', { p_user: data.user!.id, p_codes: form.getAll('warehouses').map(String) });
  if (e3) redirect(`/quan-tri?sua=${data.user!.id}&err=` + encodeURIComponent('Đã tạo tài khoản nhưng chưa lưu được kho: ' + e3.message));
  revalidatePath('/quan-tri');
  redirect('/quan-tri?ok=' + encodeURIComponent(`Đã tạo tài khoản ${email}`));
}

export async function updateUser(form: FormData) {
  const id = String(form.get('id'));
  if (form.getAll('roles').length === 0) redirect(`/quan-tri?sua=${id}&err=` + encodeURIComponent('Chọn ít nhất một vai trò'));
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('admin_upsert_user', profileArgs(form, id));
  if (error) redirect(`/quan-tri?sua=${id}&err=` + encodeURIComponent(error.message));
  const { error: e2 } = await supabase.schema('app').rpc('admin_set_warehouses', { p_user: id, p_codes: form.getAll('warehouses').map(String) });
  if (e2) redirect(`/quan-tri?sua=${id}&err=` + encodeURIComponent(e2.message));
  revalidatePath('/quan-tri');
  redirect('/quan-tri?ok=' + encodeURIComponent('Đã lưu người dùng'));
}
