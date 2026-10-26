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

// Quản trị hệ thống đặt lại mật khẩu cho một người dùng. Mật khẩu không ghi vào database, URL hay nhật ký.
export async function resetPassword(form: FormData) {
  const id = String(form.get('id') ?? '');
  const back = (msg: string) => redirect(`/quan-tri?sua=${id}&err=` + encodeURIComponent(msg));
  const me = await requireMe();
  if (!me.roles.includes('ADMIN')) back('Chỉ Quản trị hệ thống được đặt lại mật khẩu');
  const password = String(form.get('new_password') ?? '');
  const confirm = String(form.get('confirm_password') ?? '');
  if (password.length < 10) back('Mật khẩu mới phải có ít nhất 10 ký tự');
  if (new TextEncoder().encode(password).length > 72) back('Mật khẩu mới quá dài (tối đa 72 ký tự không dấu)');
  if (password.trim() !== password) back('Mật khẩu mới không được có khoảng trắng ở đầu hoặc cuối');
  if (password !== confirm) back('Hai ô mật khẩu mới không khớp');
  const signout = form.get('signout') === 'on';

  // Database kiểm lại quyền (vai trò ADMIN gán trực tiếp) trước khi đổi
  const supabase = await createClient();
  const { data: email, error: e1 } = await supabase.schema('app').rpc('admin_password_reset_check', { p_user: id });
  if (e1) back(e1.message);

  let admin;
  try { admin = createAdminClient(); } catch (e) { back((e as Error).message); }
  const { error: e2 } = await admin!.auth.admin.updateUserById(id, { password });
  if (e2) back('Không đặt lại được mật khẩu: ' + e2.message);

  const { data: ended, error: e3 } = await supabase.schema('app').rpc('admin_password_reset_done', { p_user: id, p_signout: signout });
  if (e3) back('Đã đổi mật khẩu nhưng chưa ghi được nhật ký: ' + e3.message);
  revalidatePath('/quan-tri');
  const extra = signout ? (Number(ended) > 0 ? `, đã đăng xuất ${ended} phiên đang mở` : ', không có phiên nào đang mở') : '';
  redirect(`/quan-tri?sua=${id}&ok=` + encodeURIComponent(`Đã đặt lại mật khẩu cho ${email}${extra}. Gửi mật khẩu mới cho người dùng qua kênh riêng.`));
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
