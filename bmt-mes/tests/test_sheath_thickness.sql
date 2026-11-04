-- Kiểm thử migration 20261026008700: đổi chiều dày vỏ → OD, định mức vỏ, tổng khối lượng cáp tính lại.
-- Chạy được bằng psql hoặc Supabase MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create temp table t (k text primary key, v uuid);
create temp table s0 as select 1 x;
create function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_msg; end if;
  insert into r(msg) values (p_msg);
end $$;
create function pg_temp.v(p_k text) returns uuid language sql as $$ select v from t where k = p_k $$;
set client_min_messages = notice;

update core.profiles set status = 'INACTIVE' where status = 'ACTIVE';
with ins as (insert into auth.users (id, email) values (gen_random_uuid(), 'st_adm@bmt.test') returning id)
insert into core.profiles (id, employee_code, full_name, status) select id, 'ST_ADM', 'Test ST_ADM', 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code) select id, 'ADMIN' from core.profiles where employee_code = 'ST_ADM';
select set_config('request.jwt.claim.sub', (select id::text from core.profiles where employee_code = 'ST_ADM'), true);

-- Spec có vỏ, có OD và định mức vỏ
insert into t select 's', s.id from master.product_specs s join master.spec_results r on r.spec_id = s.id
 where s.sheath in ('LSZH', 'PVC', 'FR-PVC') and s.sheath_thickness_mm > 0.3 and r.od_mm > 2 and r.sheath_kgkm > 0
 order by s.id limit 1;
drop table s0;
create temp table s0 as select s.sheath_thickness_mm t0, r.od_mm od0, r.sheath_kgkm kg0, r.total_kgkm tot0
  from master.product_specs s join master.spec_results r on r.spec_id = s.id where s.id = pg_temp.v('s');
select set_config('bmt.admin_spec_edit', 'on', true);

-- 1. Đổi chiều dày (+0,2 mm), form gửi lại OD và định mức vỏ cũ
select app.update_spec_draft(pg_temp.v('s'), jsonb_build_object('sheath_thickness_mm', (select t0 + 0.2 from s0),
  'od_mm', (select od0 from s0), 'sheath_kgkm', (select kg0 from s0)));
select pg_temp.ok((select abs(r.od_mm - (s0.od0 + 0.4)) < 0.0005 from master.spec_results r, s0 where r.spec_id = pg_temp.v('s')),
  'Tăng chiều dày vỏ 0,2 mm → OD tăng 0,4 mm (đường kính dưới vỏ giữ nguyên)');
select pg_temp.ok((select abs(r.sheath_kgkm - round(s0.kg0 * ((s0.t0 + 0.2) * (s0.od0 + 0.4 - s0.t0 - 0.2)) / (s0.t0 * (s0.od0 - s0.t0)), 4)) < 0.0002
                     and r.sheath_kgkm > s0.kg0 from master.spec_results r, s0 where r.spec_id = pg_temp.v('s')),
  'Định mức vỏ tăng theo diện tích vành vỏ t × (OD − t)');
select pg_temp.ok((select abs((r.total_kgkm - s0.tot0) - (r.sheath_kgkm - s0.kg0)) < 0.001 from master.spec_results r, s0 where r.spec_id = pg_temp.v('s')),
  'Tổng khối lượng cáp tăng đúng bằng phần vỏ tăng');

-- 2. Trả lại chiều dày cũ → về số cũ
select app.update_spec_draft(pg_temp.v('s'), jsonb_build_object('sheath_thickness_mm', (select t0 from s0)));
select pg_temp.ok((select abs(r.od_mm - s0.od0) < 0.0005 and abs(r.sheath_kgkm - s0.kg0) < 0.001 from master.spec_results r, s0 where r.spec_id = pg_temp.v('s')),
  'Trả chiều dày cũ → OD, định mức vỏ về như trước');

-- 3. Giảm chiều dày; rồi người dùng tự sửa OD
select app.update_spec_draft(pg_temp.v('s'), jsonb_build_object('sheath_thickness_mm', (select t0 - 0.1 from s0), 'od_mm', (select od0 from s0)));
select pg_temp.ok((select r.sheath_kgkm < s0.kg0 from master.spec_results r, s0 where r.spec_id = pg_temp.v('s')),
  'Giảm chiều dày vỏ → định mức vỏ giảm');
select app.update_spec_draft(pg_temp.v('s'), jsonb_build_object('sheath_thickness_mm', (select t0 from s0), 'od_mm', (select od0 + 1 from s0)));
select pg_temp.ok((select abs(r.od_mm - (s0.od0 + 1)) < 0.0005
                     and abs(r.sheath_kgkm - round(s0.kg0 * (s0.t0 * (s0.od0 + 1 - s0.t0)) / (s0.t0 * (s0.od0 - s0.t0)), 4)) < 0.002
                   from master.spec_results r, s0 where r.spec_id = pg_temp.v('s')),
  'Người dùng sửa OD → giữ OD nhập, định mức vỏ tính lại theo OD mới');

-- 4. Người dùng tự nhập định mức vỏ → giữ số nhập
select app.update_spec_draft(pg_temp.v('s'), jsonb_build_object('sheath_thickness_mm', (select t0 + 0.1 from s0), 'sheath_kgkm', 12.3456));
select pg_temp.ok((select r.sheath_kgkm = 12.3456 from master.spec_results r where r.spec_id = pg_temp.v('s')),
  'Tự nhập định mức vỏ → MES giữ số người dùng nhập');

-- 5. Sửa lớp khác không đụng vỏ
select app.update_spec_draft(pg_temp.v('s'), jsonb_build_object('pet_kgkm', 0.9));
select pg_temp.ok((select r.sheath_kgkm = 12.3456 from master.spec_results r where r.spec_id = pg_temp.v('s')),
  'Sửa lớp khác (PET) → định mức vỏ giữ nguyên');

-- 6. Tạm tính (chưa lưu) cũng tính lại
select pg_temp.ok((select ((app.spec_preview(pg_temp.v('s'), jsonb_build_object('sheath_thickness_mm', (select t0 + 0.5 from s0)))) -> 'res' ->> 'od_mm')::numeric
                     > (select od_mm from master.spec_results where spec_id = pg_temp.v('s'))),
  'Tạm tính: tăng chiều dày vỏ → OD tạm tính tăng, chưa lưu');
select pg_temp.ok(not has_function_privilege('anon', 'app.update_spec_draft(uuid, jsonb)', 'execute'), 'Khách (anon) không gọi được');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
