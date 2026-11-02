-- Kiểm thử migration 20261026008100: Quản trị sửa, duyệt, xóa tốc độ chuẩn mọi máy; duyệt tất cả.
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create temp table t (k text primary key, v uuid);
grant all on r, t to authenticated;
grant usage on sequence r_n_seq to authenticated;

create function pg_temp.as_user(p_code text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', (select id::text from core.profiles where employee_code = p_code), true),
         set_config('request.jwt.claim.role', 'authenticated', true)
$$;
create function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_msg; end if;
  insert into r(msg) values (p_msg);
end $$;
create function pg_temp.blocked(p_sql text, p_pattern text, p_msg text) returns void language plpgsql as $$
begin
  begin
    execute 'set local role authenticated';
    execute p_sql;
    execute 'reset role';
  exception when others then
    execute 'reset role';
    if sqlerrm ilike '%' || p_pattern || '%' then insert into r(msg) values (p_msg || ' → chặn: ' || sqlerrm); return; end if;
    raise exception 'FAIL: % — lỗi khác mong đợi: %', p_msg, sqlerrm;
  end;
  raise exception 'FAIL: % — lẽ ra phải bị chặn', p_msg;
end $$;
create function pg_temp.as_api(p_sql text) returns void language plpgsql as $$
begin
  execute 'set local role authenticated';
  execute p_sql;
  execute 'reset role';
end $$;
create function pg_temp.v(p_k text) returns uuid language sql as $$ select v from t where k = p_k $$;
grant execute on function pg_temp.v(text) to authenticated;
create function pg_temp.uid(p_code text) returns uuid language sql as $$ select id from core.profiles where employee_code = p_code $$;
create function pg_temp.sp(p_k text) returns master.machine_speeds language sql as $$ select * from master.machine_speeds where id = pg_temp.v(p_k) $$;
set client_min_messages = notice;

update core.profiles set status = 'INACTIVE' where status = 'ACTIVE';
with u(code) as (values ('S_ADM'),('S_KTTP'),('S_SXTP')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('S_ADM','ADMIN'),('S_KTTP','KT_TP'),('S_SXTP','SX_TP')) u(code, role) on u.code = p.employee_code;

-- Máy bện thật, 5 dòng tốc độ riêng cho 5 mã (không đụng dòng cỡ ruột đang có trên dữ liệu thật)
insert into t select 'm', id from master.machines where machine_type = 'BUNCHER' and inline_with is null order by code limit 1;
insert into t select 'p' || row_number() over (order by code), id from (select id, code from master.products order by code limit 5) x;
insert into master.machine_speeds (machine_id, op_code, product_id, std_mpm, setup_min, rated_mpm, created_by)
select pg_temp.v('m'), 'CD1', pg_temp.v('p' || i), 100 + i, 5, case when i = 1 then 300 end,
       pg_temp.uid(case when i = 5 then 'S_KTTP' else 'S_SXTP' end)
from generate_series(1, 5) i;
insert into t select 's' || row_number() over (order by std_mpm), id from master.machine_speeds where machine_id = pg_temp.v('m') and product_id in (select v from t where k like 'p%');

-- ================================================================ Quyền
select pg_temp.as_user('S_KTTP');
select pg_temp.blocked($q$select app.admin_speed_edit(pg_temp.v('s1'), 150, 5, true, 'thử')$q$, 'Chỉ Quản trị', 'TP KT/QA không dùng được sửa tốc độ của Quản trị');
select pg_temp.blocked($q$select app.admin_speed_delete(pg_temp.v('s1'), 'thử')$q$, 'Chỉ Quản trị', 'TP KT/QA không xóa được tốc độ bằng quyền Quản trị');
select pg_temp.as_user('S_ADM');
select pg_temp.blocked($q$select app.admin_speed_edit(pg_temp.v('s1'), 150, 5, true, ' ')$q$, 'lý do', 'Sửa tốc độ bắt buộc ghi lý do');
select pg_temp.blocked($q$select app.admin_speed_edit(pg_temp.v('s1'), 350, 5, true, 'thử')$q$, 'danh định', 'Không cao hơn tốc độ danh định nhà sản xuất');
select pg_temp.blocked($q$select app.admin_speed_edit(pg_temp.v('s1'), 0, 5, true, 'thử')$q$, 'lớn hơn 0', 'Tốc độ chuẩn phải lớn hơn 0');

-- ================================================================ Sửa dòng chờ duyệt
select pg_temp.as_api($q$select app.admin_speed_edit(pg_temp.v('s1'), 180, 12, false, 'Đo lại thực tế')$q$);
select pg_temp.ok((select std_mpm = 180 and setup_min = 12 and status = 'PENDING' from pg_temp.sp('s1')),
  'Quản trị sửa dòng chờ duyệt (không bấm duyệt): đổi tốc độ, phút đổi máy, vẫn chờ duyệt');
select pg_temp.as_api($q$select app.admin_speed_edit(pg_temp.v('s1'), 200, 10, true, 'Duyệt theo số đo')$q$);
select pg_temp.ok((select std_mpm = 200 and status = 'APPROVED' and approved_by = pg_temp.uid('S_ADM') and not temp_approval from pg_temp.sp('s1')),
  'Quản trị sửa và duyệt luôn: Đã duyệt, không phải duyệt tạm');

-- ================================================================ Sửa dòng đã duyệt
select pg_temp.as_api($q$select app.admin_speed_edit(pg_temp.v('s1'), 220, 8, false, 'Máy đã nâng cấp')$q$);
select pg_temp.ok((select std_mpm = 220 and setup_min = 8 and status = 'APPROVED' from pg_temp.sp('s1')),
  'Quản trị sửa dòng đã duyệt: giữ Đã duyệt, số mới có hiệu lực ngay');

-- Người thường vẫn không sửa thẳng được dòng đã duyệt
select pg_temp.as_user('S_SXTP');
do $$ begin
  execute 'set local role authenticated';
  update master.machine_speeds set std_mpm = 999 where id = pg_temp.v('s1');
  execute 'reset role';
end $$;
select pg_temp.ok((select std_mpm = 220 from pg_temp.sp('s1')), 'Người thường không sửa thẳng được dòng đã duyệt (RLS)');

-- ================================================================ Duyệt tất cả
select pg_temp.as_user('S_KTTP');
select pg_temp.as_api($q$select app.approve_machine_speeds(pg_temp.v('m'))$q$);
select pg_temp.ok((select count(*) = 3 from master.machine_speeds where id in (pg_temp.v('s2'), pg_temp.v('s3'), pg_temp.v('s4')) and status = 'APPROVED')
  and (select status = 'PENDING' from pg_temp.sp('s5')),
  'TP KT/QA "Duyệt tất cả": duyệt dòng người khác nhập, bỏ qua dòng mình nhập');
select pg_temp.as_user('S_ADM');
select pg_temp.as_api($q$select app.approve_machine_speeds(null)$q$);
select pg_temp.ok((select status = 'APPROVED' from pg_temp.sp('s5')), 'Quản trị "Duyệt tất cả" mọi máy, kể cả dòng do TP KT/QA nhập');
select pg_temp.as_user('S_SXTP');
select pg_temp.blocked($q$select app.approve_machine_speeds(pg_temp.v('m'))$q$, 'chưa có quyền duyệt', 'TP SX không có quyền duyệt tốc độ');

-- ================================================================ Xóa dòng đã duyệt
select pg_temp.as_user('S_ADM');
select pg_temp.as_api($q$select app.admin_speed_delete(pg_temp.v('s2'), 'Khai nhầm mã')$q$);
select pg_temp.ok(not exists (select 1 from master.machine_speeds where id = pg_temp.v('s2')), 'Quản trị xóa dòng tốc độ đã duyệt');

select pg_temp.ok((select count(*) = 4 from core.audit_log where action = 'ADMIN_SPEED' and at >= now())
  and exists (select 1 from app.admin_overrides(50) where action = 'ADMIN_SPEED' and doc_type = 'Xóa tốc độ máy'),
  'Nhật ký can thiệp ghi 3 lần sửa + 1 lần xóa tốc độ');
select pg_temp.ok(not has_function_privilege('anon', 'app.admin_speed_edit(uuid,numeric,numeric,boolean,text)', 'execute')
  and not has_function_privilege('anon', 'app.approve_machine_speeds(uuid)', 'execute')
  and not has_function_privilege('authenticated', 'master.speed_label(master.machine_speeds)', 'execute'), 'Khách (anon) không gọi được; hàm nhãn là nội bộ');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
