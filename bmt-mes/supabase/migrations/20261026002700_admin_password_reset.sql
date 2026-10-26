-- Quản trị hệ thống đặt lại mật khẩu cho người dùng (yêu cầu của Chủ tịch 26/10/2026).
-- Mật khẩu đổi bằng Auth Admin API ở server web (service role, không qua database).
-- Database lo phần kiểm quyền, ghi nhật ký và đăng xuất người đó khỏi các thiết bị đang mở:
--   1. app.admin_password_reset_check(user) — gọi TRƯỚC khi đổi: chỉ vai trò ADMIN gán trực tiếp (không nhận ủy quyền).
--   2. app.admin_password_reset_done(user, signout) — gọi SAU khi đổi: ghi core.audit_log (không ghi mật khẩu),
--      tùy chọn xóa phiên đăng nhập (auth.sessions; refresh token xóa theo). Tự đặt lại cho mình thì giữ phiên đang dùng.
--   3. app.admin_password_resets(user) — 5 lần đặt lại gần nhất để hiện trên màn hình quản trị.

create or replace function app.admin_password_reset_check(p_user uuid) returns text
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_email text;
begin
  if not exists (select 1 from core.user_roles where user_id = auth.uid() and role_code = 'ADMIN') then
    raise exception 'Chỉ Quản trị hệ thống được đặt lại mật khẩu';
  end if;
  select u.email into v_email from auth.users u join core.profiles p on p.id = u.id where u.id = p_user;
  if v_email is null then raise exception 'Không tìm thấy tài khoản cần đặt lại mật khẩu'; end if;
  return v_email;
end $$;

create or replace function app.admin_password_reset_done(p_user uuid, p_signout boolean default true) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_email text := app.admin_password_reset_check(p_user);
  v_sess  text := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'session_id';
  v_n     integer := 0;
begin
  if p_signout then
    delete from auth.sessions s
    where s.user_id = p_user
      and not (p_user = auth.uid() and s.id::text is not distinct from v_sess);
    get diagnostics v_n = row_count;
  end if;
  insert into core.audit_log (user_id, table_name, row_id, action, new_data)
  values (auth.uid(), 'auth.users', p_user::text, 'PASSWORD_RESET',
          jsonb_build_object('email', v_email, 'signout', p_signout, 'sessions_ended', v_n));
  return v_n;
end $$;

create or replace function app.admin_password_resets(p_user uuid)
returns table (at timestamptz, by_name text, signout boolean, sessions_ended integer)
language sql stable security definer set search_path = pg_catalog, public as $$
  select a.at, coalesce(p.full_name, '—'), (a.new_data ->> 'signout')::boolean, (a.new_data ->> 'sessions_ended')::integer
  from core.audit_log a left join core.profiles p on p.id = a.user_id
  where core.has_perm('admin', 'view') and a.table_name = 'auth.users' and a.action = 'PASSWORD_RESET'
    and a.row_id = p_user::text
  order by a.at desc
  limit 5
$$;

revoke execute on function app.admin_password_reset_check(uuid), app.admin_password_reset_done(uuid, boolean),
  app.admin_password_resets(uuid) from public, anon;
grant execute on function app.admin_password_reset_check(uuid), app.admin_password_reset_done(uuid, boolean),
  app.admin_password_resets(uuid) to authenticated, service_role;
