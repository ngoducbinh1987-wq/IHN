-- Kiểm thử migration 20261026009950_v_users_invoker: danh sách người dùng chạy theo quyền người xem.
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_msg; end if;
  insert into r(msg) values (p_msg);
end $$;
set client_min_messages = notice;

with u(code) as (values ('VU_ADMIN'),('VU_BGD'),('VU_SXTP'),('VU_VH'),('VU_NONE')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('VU_ADMIN','ADMIN'),('VU_BGD','BGD'),('VU_SXTP','SX_TP'),('VU_VH','VAN_HANH')) u(code, role)
  on u.code = p.employee_code;
insert into core.user_scopes (user_id, scope_type, scope_id)
select p.id, 'WAREHOUSE', (select id from inv.warehouses order by code limit 1) from core.profiles p where p.employee_code = 'VU_VH';

do $$
declare
  u record; n_rows int; n_vh_roles int; vh_wh text[]; vh_mail text; own_roles text[]; me uuid;
  vh uuid := (select id from core.profiles where employee_code = 'VU_VH');
begin
  -- 1. View không còn chạy dưới chủ sở hữu
  perform pg_temp.ok((select coalesce(reloptions::text, '') ~ 'security_invoker=(true|on)' from pg_class where oid = 'app.v_users'::regclass),
                     'app.v_users chạy theo quyền người xem (security_invoker)');
  perform pg_temp.ok(not has_table_privilege('anon', 'app.v_users', 'select'), 'Người chưa đăng nhập không đọc được danh sách người dùng');

  for u in select p.id, p.employee_code from core.profiles p where p.employee_code like 'VU\_%' order by 2 loop
    me := u.id;
    perform set_config('request.jwt.claims', json_build_object('sub', me, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', me::text, true);
    execute 'set local role authenticated';
    select count(*) into n_rows from app.v_users;
    select coalesce(array_length(roles, 1), 0), warehouses, email into n_vh_roles, vh_wh, vh_mail from app.v_users where id = vh;
    select roles into own_roles from app.v_users where id = me;
    execute 'reset role';

    if u.employee_code in ('VU_ADMIN', 'VU_BGD') then
      perform pg_temp.ok(n_vh_roles = 1 and coalesce(array_length(vh_wh, 1), 0) = 1 and vh_mail = 'vu_vh@bmt.test',
        u.employee_code || ' (quyền xem Quản trị) thấy vai trò, kho, email người khác');
    elsif u.employee_code = 'VU_VH' then
      perform pg_temp.ok(n_vh_roles = 1 and vh_mail is null, 'VU_VH thấy vai trò của chính mình, không thấy email');
    elsif u.employee_code in ('VU_SXTP') then
      perform pg_temp.ok(n_rows > 1 and n_vh_roles = 0 and coalesce(array_length(vh_wh, 1), 0) = 0 and vh_mail is null,
        'VU_SXTP thấy tên người (Nhân sự xưởng liên kết tài khoản) nhưng không thấy vai trò, kho, email người khác');
      perform pg_temp.ok(own_roles = array['SX_TP'], 'VU_SXTP thấy vai trò của chính mình');
    else
      perform pg_temp.ok(n_rows = 1 and coalesce(n_vh_roles, 0) = 0, 'VU_NONE (không vai trò) chỉ thấy chính mình (' || n_rows || ' dòng)');
    end if;
  end loop;
end $$;

do $$ begin
  raise exception 'KET_QUA_OK %', (select count(*) from r) || ' kiểm tra đạt: ' || (select string_agg(msg, ' | ' order by n) from r);
end $$;
rollback;
