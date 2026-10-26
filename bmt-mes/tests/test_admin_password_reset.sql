-- Kiểm thử migration 20261026002700: Quản trị hệ thống đặt lại mật khẩu (kiểm quyền, nhật ký, đăng xuất thiết bị).
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
-- Phần đổi mật khẩu thật (Auth Admin API) chạy ở web, không kiểm ở đây.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create temp table t (k text primary key, v uuid);

create function pg_temp.uid(p_code text) returns uuid language sql as $$ select id from core.profiles where employee_code = p_code $$;
-- Đăng nhập như người dùng p_code, phiên p_sess
create function pg_temp.as_user(p_code text, p_sess uuid default null) returns void language sql as $$
  select set_config('request.jwt.claim.sub', pg_temp.uid(p_code)::text, true),
         set_config('request.jwt.claim.role', 'authenticated', true),
         set_config('request.jwt.claims', jsonb_build_object('sub', pg_temp.uid(p_code), 'role', 'authenticated',
                                                             'session_id', p_sess)::text, true)
$$;
create function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_msg; end if;
  insert into r(msg) values (p_msg);
end $$;
create function pg_temp.blocked(p_sql text, p_pattern text, p_msg text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm ilike '%' || p_pattern || '%' then insert into r(msg) values (p_msg || ' → chặn: ' || sqlerrm); return; end if;
    raise exception 'FAIL: % — lỗi khác mong đợi: %', p_msg, sqlerrm;
  end;
  raise exception 'FAIL: % — lẽ ra phải bị chặn', p_msg;
end $$;
create function pg_temp.sessions(p_code text) returns bigint language sql as $$
  select count(*) from auth.sessions where user_id = pg_temp.uid(p_code)
$$;
set client_min_messages = notice;

-- ---------------------------------------------------------------- người dùng thử
with u(code) as (values ('P_ADMIN'), ('P_ADMIN2'), ('P_BGD'), ('P_VH'), ('P_DELEG')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Thử ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select pg_temp.uid(c), r from (values ('P_ADMIN','ADMIN'), ('P_ADMIN2','ADMIN'), ('P_BGD','BGD'), ('P_VH','VAN_HANH'), ('P_DELEG','VAN_HANH')) x(c, r);
-- P_DELEG được ủy quyền ADMIN: vẫn không được đặt lại mật khẩu
insert into core.delegations (from_user, to_user, role_code, valid_from, valid_to, reason)
values (pg_temp.uid('P_ADMIN2'), pg_temp.uid('P_DELEG'), 'ADMIN', now() - interval '1 day', now() + interval '1 day', 'kiểm thử');
-- Phiên đăng nhập: P_VH 2 thiết bị, P_ADMIN 2 thiết bị (một là phiên đang dùng)
insert into t values ('s_admin_cur', gen_random_uuid()), ('s_admin_old', gen_random_uuid());
insert into auth.sessions (id, user_id) select gen_random_uuid(), pg_temp.uid('P_VH') from generate_series(1, 2);
insert into auth.sessions (id, user_id) select v, pg_temp.uid('P_ADMIN') from t where k like 's_admin_%';

-- ---------------------------------------------------------------- 1. Quyền
select pg_temp.as_user('P_VH');
select pg_temp.blocked($q$select app.admin_password_reset_check(pg_temp.uid('P_BGD'))$q$, 'Chỉ Quản trị hệ thống', 'Vận hành không đặt lại mật khẩu người khác');
select pg_temp.blocked($q$select app.admin_password_reset_done(pg_temp.uid('P_BGD'), true)$q$, 'Chỉ Quản trị hệ thống', 'Vận hành không gọi được bước ghi nhật ký/đăng xuất');
select pg_temp.as_user('P_BGD');
select pg_temp.blocked($q$select app.admin_password_reset_check(pg_temp.uid('P_VH'))$q$, 'Chỉ Quản trị hệ thống', 'Ban giám đốc (chỉ xem quản trị) không đặt lại mật khẩu');
select pg_temp.as_user('P_DELEG');
select pg_temp.ok(core.has_role('ADMIN'), 'Người được ủy quyền ADMIN có vai trò ADMIN theo ủy quyền');
select pg_temp.blocked($q$select app.admin_password_reset_check(pg_temp.uid('P_VH'))$q$, 'Chỉ Quản trị hệ thống', 'Ủy quyền ADMIN không dùng để đặt lại mật khẩu');
select pg_temp.as_user('P_ADMIN', (select v from t where k = 's_admin_cur'));
select pg_temp.ok(app.admin_password_reset_check(pg_temp.uid('P_VH')) = 'p_vh@bmt.test', 'Quản trị hệ thống qua bước kiểm, nhận đúng email');
select pg_temp.blocked($q$select app.admin_password_reset_check(gen_random_uuid())$q$, 'Không tìm thấy tài khoản', 'Tài khoản không tồn tại bị chặn');
select pg_temp.ok(not has_function_privilege('anon', 'app.admin_password_reset_check(uuid)', 'execute')
  and not has_function_privilege('anon', 'app.admin_password_reset_done(uuid, boolean)', 'execute')
  and not has_function_privilege('anon', 'app.admin_password_resets(uuid)', 'execute')
  and has_function_privilege('authenticated', 'app.admin_password_reset_done(uuid, boolean)', 'execute'),
  'Chưa đăng nhập không gọi được 3 hàm; người đăng nhập gọi được (hàm tự kiểm vai trò)');

-- ---------------------------------------------------------------- 2. Đăng xuất + nhật ký
select pg_temp.ok(app.admin_password_reset_done(pg_temp.uid('P_VH'), true) = 2 and pg_temp.sessions('P_VH') = 0,
  'Đặt lại cho Vận hành: đăng xuất cả 2 thiết bị');
select pg_temp.ok((select count(*) = 1 and bool_and(user_id = pg_temp.uid('P_ADMIN') and new_data ->> 'email' = 'p_vh@bmt.test'
                    and (new_data ->> 'sessions_ended')::int = 2 and not (new_data ? 'password'))
                   from core.audit_log where table_name = 'auth.users' and action = 'PASSWORD_RESET' and row_id = pg_temp.uid('P_VH')::text),
  'Nhật ký ghi người đặt lại, email, số phiên; không có mật khẩu');
insert into auth.sessions (id, user_id) values (gen_random_uuid(), pg_temp.uid('P_VH'));
select pg_temp.ok(app.admin_password_reset_done(pg_temp.uid('P_VH'), false) = 0 and pg_temp.sessions('P_VH') = 1,
  'Bỏ chọn "Đăng xuất": giữ phiên của người dùng');
select pg_temp.ok(app.admin_password_reset_done(pg_temp.uid('P_ADMIN'), true) = 1 and pg_temp.sessions('P_ADMIN') = 1
  and exists (select 1 from auth.sessions where id = (select v from t where k = 's_admin_cur')),
  'Tự đặt lại cho mình: đăng xuất thiết bị khác, giữ phiên đang dùng');

-- ---------------------------------------------------------------- 3. Xem lịch sử
select pg_temp.ok((select count(*) = 2 and bool_and(by_name = 'Thử p_admin') from app.admin_password_resets(pg_temp.uid('P_VH'))),
  'Quản trị xem được 2 lần đặt lại của Vận hành');
select pg_temp.ok((select signout = false from app.admin_password_resets(pg_temp.uid('P_VH')) order by at desc, signout limit 1),
  'Lịch sử ghi đúng lựa chọn đăng xuất');
select pg_temp.as_user('P_VH');
select pg_temp.ok(not exists (select 1 from app.admin_password_resets(pg_temp.uid('P_VH'))), 'Vận hành không xem được lịch sử đặt lại');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
