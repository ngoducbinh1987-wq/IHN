-- Kiểm thử migration 20261026008300: máy khai cả tốc độ chung và theo cỡ → cỡ có khai dùng tốc độ theo cỡ, cỡ không khai dùng tốc độ chung;
-- cáp chống nhiễu: máy xoắn chưa khai riêng quấn AL/PET chạy theo tốc độ xoắn, không báo thiếu.
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create temp table t (k text primary key, v uuid);
create function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_msg; end if;
  insert into r(msg) values (p_msg);
end $$;
create function pg_temp.v(p_k text) returns uuid language sql as $$ select v from t where k = p_k $$;
-- Phút cần của nhóm máy trong kiểm tra năng lực cho 10.000 m một mã
create function pg_temp.req(p_product uuid, p_type text) returns numeric language sql as $$
  select (o ->> 'req_min')::numeric from jsonb_array_elements(app.check_capacity(null, (now() at time zone 'Asia/Ho_Chi_Minh')::date,
    (now() at time zone 'Asia/Ho_Chi_Minh')::date + 27, 1, 0, jsonb_build_array(jsonb_build_object('product_id', p_product, 'qty_m', 10000))) -> 'ops') o
   where o ->> 'op_code' = p_type
$$;
create function pg_temp.issues(p_product uuid) returns text language sql as $$
  select coalesce(string_agg(i ->> 'text', '; '), '') from jsonb_array_elements(app.check_capacity(null, (now() at time zone 'Asia/Ho_Chi_Minh')::date,
    (now() at time zone 'Asia/Ho_Chi_Minh')::date + 27, 1, 0, jsonb_build_array(jsonb_build_object('product_id', p_product, 'qty_m', 10000))) -> 'issues') i
$$;
set client_min_messages = notice;

update core.profiles set status = 'INACTIVE' where status = 'ACTIVE';
with ins as (insert into auth.users (id, email) values (gen_random_uuid(), 'p_adm@bmt.test') returning id)
insert into core.profiles (id, employee_code, full_name, status) select id, 'P_ADM', 'Test P_ADM', 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code) select id, 'ADMIN' from core.profiles where employee_code = 'P_ADM';
select set_config('request.jwt.claim.sub', (select id::text from core.profiles where employee_code = 'P_ADM'), true);

-- Hai mã khác cỡ ruột, mã chống nhiễu nhiều lõi
insert into t select 'p1', p.id from master.products p join master.product_specs s on s.id = p.current_spec_id where s.core_code is not null order by p.code limit 1;
insert into t select 'p2', p.id from master.products p join master.product_specs s on s.id = p.current_spec_id
 where s.core_code is not null and s.core_code <> (select s1.core_code from master.products p1 join master.product_specs s1 on s1.id = p1.current_spec_id where p1.id = pg_temp.v('p1'))
 order by p.code limit 1;
insert into t select 'sh', p.id from master.products p join master.product_specs s on s.id = p.current_spec_id
 where coalesce(s.shield, false) and coalesce(s.cores, 1) > 1 order by p.code limit 1;
create temp table cores as select p.id, greatest(1, coalesce(s.cores, 1)) n, s.core_code from master.products p join master.product_specs s on s.id = p.current_spec_id;

-- Máy bện: chung 60, riêng cỡ của mã 1 là 80 (trong giao dịch)
delete from master.machine_speeds where machine_id in (select id from master.machines where machine_type in ('BUNCHER', 'TWISTER'));
delete from master.machine_ranges where machine_id in (select id from master.machines where machine_type in ('BUNCHER', 'TWISTER'));
insert into master.machine_speeds (machine_id, op_code, std_mpm, setup_min, status)
select id, 'CD1', 60, 0, 'APPROVED' from master.machines where machine_type = 'BUNCHER' and inline_with is null and active;
insert into master.machine_speeds (machine_id, op_code, core_code, std_mpm, setup_min, status)
select m.id, 'CD1', c.core_code, 80, 0, 'APPROVED' from master.machines m, cores c where m.machine_type = 'BUNCHER' and m.inline_with is null and m.active and c.id = pg_temp.v('p1');
update master.machines set status = 'IDLE' where machine_type in ('BUNCHER', 'TWISTER') and status in ('OFF', 'DOWN', 'STOP', 'MAINT');

select pg_temp.ok(abs(pg_temp.req(pg_temp.v('p1'), 'BUNCHER') - 10000 * (select n from cores where id = pg_temp.v('p1')) / 80.0) < 0.6,
  'Cỡ có khai riêng: bện dùng tốc độ theo cỡ (80 m/ph), không dùng tốc độ chung');
select pg_temp.ok(abs(pg_temp.req(pg_temp.v('p2'), 'BUNCHER') - 10000 * (select n from cores where id = pg_temp.v('p2')) / 60.0) < 0.6,
  'Cỡ không khai riêng: bện dùng tốc độ chung của máy (60 m/ph)');
-- Dòng theo cỡ chờ duyệt vẫn ưu tiên hơn dòng chung (lịch dùng, ghi "chưa duyệt")
update master.machine_speeds set status = 'PENDING' where core_code is not null and machine_id in (select id from master.machines where machine_type = 'BUNCHER');
select pg_temp.ok(abs(pg_temp.req(pg_temp.v('p1'), 'BUNCHER') - 10000 * (select n from cores where id = pg_temp.v('p1')) / 80.0) < 0.6,
  'Dòng theo cỡ đang chờ duyệt vẫn được ưu tiên hơn dòng chung');

-- Máy xoắn chỉ khai xoắn chung (CD3), không khai riêng quấn AL/PET (CD4): cáp chống nhiễu chạy theo tốc độ xoắn, không báo thiếu
insert into master.machine_speeds (machine_id, op_code, std_mpm, setup_min, status)
select id, 'CD3', 50, 0, 'APPROVED' from master.machines where machine_type = 'TWISTER' and inline_with is null and active;
select pg_temp.ok(abs(pg_temp.req(pg_temp.v('sh'), 'TWISTER') - 10000 / 50.0) < 0.6, 'Cáp chống nhiễu: máy xoắn chạy theo tốc độ xoắn 50 m/ph');
select pg_temp.ok(pg_temp.issues(pg_temp.v('sh')) not like '%Máy chưa khai tốc độ cho: Xoắn%' and pg_temp.issues(pg_temp.v('sh')) not like '%giả định%',
  'Cáp chống nhiễu: không báo nhầm thiếu tốc độ / số giả định khi máy xoắn chưa khai riêng quấn AL/PET');
-- Máy bện chưa khai gì: báo thiếu (cảnh báo)
delete from master.machine_speeds where machine_id in (select id from master.machines where machine_type = 'BUNCHER');
select pg_temp.ok(pg_temp.issues(pg_temp.v('p1')) like '%Chưa có tốc độ chuẩn%', 'Máy chưa khai tốc độ: báo thiếu tốc độ chuẩn');
select pg_temp.ok(position('Dùng tốc độ mặc định theo công đoạn' in pg_get_functiondef('app.check_capacity'::regproc)) = 0, 'Không còn câu "Dùng tốc độ mặc định theo công đoạn"');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
