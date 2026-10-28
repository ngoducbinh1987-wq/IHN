import { redirect } from 'next/navigation';
import { cache } from 'react';
import { createClient } from './supabase/server';

export type Me = {
  id: string;
  full_name: string;
  employee_code: string | null;
  email: string | null;
  status: string;
  roles: string[];
  delegated_roles?: string[];   // vai trò đang được ủy quyền: "THU_KHO:Tên người ủy quyền"
  perms: string[];
  pages?: string[];             // mục menu được vào (core.role_pages; Quản trị: tất cả)
  is_admin?: boolean;           // Quản trị hệ thống gán trực tiếp (không qua ủy quyền)
  can_see_price: boolean;
};

// Người dùng hiện tại (hồ sơ + vai trò + quyền). Một lần mỗi request.
export const getMe = cache(async (): Promise<Me | null> => {
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc('me');
  // Lỗi cấu hình (chưa mở schema cho Data API, sai khóa…): chuyển sang trang hướng dẫn thay vì màn hình lỗi trống
  if (error) redirect('/loi-ket-noi?code=' + encodeURIComponent(error.code ?? '') + '&msg=' + encodeURIComponent(error.message));
  return (data as Me | null) ?? null;
});

export async function requireMe(): Promise<Me> {
  const me = await getMe();
  if (!me) redirect('/khoi-tao');
  return me;
}

export const can = (me: Me, module: string, action: string) => me.perms.includes(`${module}:${action}`);

export async function requirePerm(module: string, action: string): Promise<Me> {
  const me = await requireMe();
  if (!can(me, module, action)) redirect('/?err=' + encodeURIComponent('Bạn chưa được cấp quyền vào trang này'));
  return me;
}

// Mục theo bộ phận (Quản trị → Phân quyền). Database chưa trả danh sách (trước migration 4700) thì không chặn.
export const canPage = (me: Me, key: string) => !me.pages || me.is_admin === true || me.pages.includes(key);

export async function requirePage(key: string): Promise<Me> {
  const me = await requireMe();
  if (!canPage(me, key)) redirect('/?err=' + encodeURIComponent('Mục này không thuộc bộ phận của bạn. Cần vào thì liên hệ Quản trị hệ thống'));
  return me;
}
