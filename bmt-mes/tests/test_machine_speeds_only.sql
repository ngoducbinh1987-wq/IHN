-- Kiểm thử migration 20261026008200: bỏ tốc độ giả định theo công đoạn, chỉ dùng tốc độ khai báo của máy; Alarm máy thiếu thông số.
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
create function pg_temp.v(p_k text) returns uuid language sql as $$ select v from t where k = p_k $$;
-- Gọi hàm web dưới vai authenticated, trả số
create function pg_temp.api_int(p_sql text) returns int language plpgsql as $$
declare n int;
begin
  execute 'set local role authenticated';
  execute p_sql into n;
  execute 'reset role';
  return n;
end $$;
set client_min_messages = notice;

-- 1. Không còn tốc độ giả định
select pg_temp.ok((select count(*) = 0 from master.machine_rates), 'Bảng tốc độ mặc định theo công đoạn (giả định) đã xóa hết');
select pg_temp.ok(exists (select 1 from master.planning_param_log where section = 'Tốc độ chuẩn' and item like '%(mặc định công đoạn)' and new_value = 'đã xóa'),
  'Nhật ký tham số ghi việc xóa tốc độ giả định');
select pg_temp.ok((select count(*) = 0 from app.machine_rate_defaults()), 'Không còn bảng tốc độ mặc định để hiện');
do $$ begin
  perform app.kh_save_rates('[{"op_code":"CD1","rate_small":90,"rate_large":80}]', 'thử');
  raise exception 'FAIL: kh_save_rates lẽ ra bị chặn';
exception when others then
  if sqlerrm not like 'Đã bỏ tốc độ mặc định%' then raise; end if;
  insert into r(msg) values ('Không sửa được tốc độ mặc định nữa → ' || sqlerrm);
end $$;
select pg_temp.ok(position('Tham số xếp lịch.' in pg_get_functiondef('app.check_capacity'::regproc)) = 0
  and position('xác nhận tốc độ mặc định' in pg_get_functiondef('app.check_capacity'::regproc)) = 0,
  'Kiểm tra năng lực không còn nhắc tốc độ mặc định ở Tham số xếp lịch');

-- 2. Alarm máy thiếu thông số: máy bện, 2 mã cùng nhóm khác cỡ ruột đã phát hành spec
update core.profiles set status = 'INACTIVE' where status = 'ACTIVE';
with u(code) as (values ('G_ADM'), ('G_NONE')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code) select id, 'ADMIN' from core.profiles where employee_code = 'G_ADM';

insert into t select 'm', id from master.machines where machine_type = 'BUNCHER' and inline_with is null and active order by code limit 1;
update master.machines set status = 'IDLE' where id = pg_temp.v('m') and status = 'OFF';
delete from master.machine_speeds where machine_id = pg_temp.v('m');
delete from master.machine_ranges where machine_id = pg_temp.v('m');
select pg_temp.ok(exists (select 1 from master.machine_param_gaps() where machine_id = pg_temp.v('m') and op_code = 'CD1' and kind = 'NONE'
                            and message = 'Chưa có tốc độ bện ruột dẫn'), 'Máy bện chưa khai tốc độ → Alarm "Chưa có tốc độ bện ruột dẫn"');

-- Hai mã có spec khác mã lõi, cho phát hành trong giao dịch (dữ liệu cục bộ chưa phát hành)
insert into t select 'p1', p.id from master.products p join master.product_specs s on s.id = p.current_spec_id
 where s.core_code is not null order by p.code limit 1;
insert into t select 'p2', p.id from master.products p join master.product_specs s on s.id = p.current_spec_id
 where s.core_code is not null and s.core_code <> (select s2.core_code from master.products p2 join master.product_specs s2 on s2.id = p2.current_spec_id where p2.id = pg_temp.v('p1'))
 order by p.code limit 1;
select set_config('bmt.admin_spec_edit', 'on', true), set_config('bmt.allow_release', 'on', true);
update master.product_specs s set status = 'RELEASED' from master.products p
 where p.current_spec_id = s.id and p.id in (pg_temp.v('p1'), pg_temp.v('p2')) and s.status <> 'RELEASED';
-- Máy chỉ khai tốc độ theo cỡ ruột của mã 1 → thiếu cỡ ruột của mã 2
insert into master.machine_speeds (machine_id, op_code, core_code, std_mpm, setup_min, status)
select pg_temp.v('m'), 'CD1', s.core_code, 200, 0, 'APPROVED' from master.products p join master.product_specs s on s.id = p.current_spec_id where p.id = pg_temp.v('p1');
select pg_temp.ok(exists (select 1 from master.machine_param_gaps() g, master.products p join master.product_specs s on s.id = p.current_spec_id
                           where g.machine_id = pg_temp.v('m') and g.kind = 'CORE' and p.id = pg_temp.v('p2') and s.core_code = any (g.cores))
  and not exists (select 1 from master.machine_param_gaps() g, master.products p join master.product_specs s on s.id = p.current_spec_id
                   where g.machine_id = pg_temp.v('m') and p.id = pg_temp.v('p1') and s.core_code = any (coalesce(g.cores, '{}'))),
  'Khai theo cỡ ruột: Alarm liệt kê cỡ còn thiếu (mã 2), không báo cỡ đã khai (mã 1)');
-- Thêm dòng chung của máy → hết Alarm
insert into master.machine_speeds (machine_id, op_code, std_mpm, setup_min, status) values (pg_temp.v('m'), 'CD1', 150, 0, 'APPROVED');
select pg_temp.ok(not exists (select 1 from master.machine_param_gaps() where machine_id = pg_temp.v('m')), 'Có tốc độ chung của máy → máy bện hết Alarm');
-- Dòng chờ duyệt cũng tính là đã khai (lịch dùng, ghi "chưa duyệt")
delete from master.machine_speeds where machine_id = pg_temp.v('m');
insert into master.machine_speeds (machine_id, op_code, std_mpm, setup_min, status) values (pg_temp.v('m'), 'CD1', 150, 0, 'PENDING');
select pg_temp.ok(not exists (select 1 from master.machine_param_gaps() where machine_id = pg_temp.v('m')), 'Dòng chờ duyệt vẫn tính là đã khai tốc độ');
delete from master.machine_speeds where machine_id = pg_temp.v('m');

-- 3. Quyền
select pg_temp.as_user('G_ADM');
select pg_temp.ok(pg_temp.api_int('select app.machine_param_alarm_count()') >= 1
  and pg_temp.api_int($q$select count(*)::int from app.machine_param_gaps() where machine_id = '$q$ || pg_temp.v('m') || $q$'$q$) = 1,
  'Quản trị thấy Alarm trên menu (số máy) và danh sách máy thiếu thông số');
select pg_temp.as_user('G_NONE');
select pg_temp.ok(pg_temp.api_int('select app.machine_param_alarm_count()') = 0 and pg_temp.api_int('select count(*)::int from app.machine_param_gaps()') = 0,
  'Người không xem máy / kế hoạch không thấy Alarm');
select pg_temp.ok(not has_function_privilege('anon', 'app.machine_param_gaps()', 'execute')
  and not has_function_privilege('anon', 'app.machine_param_alarm_count()', 'execute')
  and not has_function_privilege('authenticated', 'master.machine_param_gaps()', 'execute'), 'Khách (anon) không gọi được; hàm master là nội bộ');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
