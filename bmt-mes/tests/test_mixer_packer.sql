-- Kiểm thử migration 20261026003900 + 20261026004000: máy trộn silicone (CD0, kg/giờ) và máy đóng gói (CD6) vào lịch máy, năng lực, vật tư ngày.
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create temp table t (k text primary key, v uuid);
grant all on t, r to authenticated;

create function pg_temp.as_user(p_code text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', (select id::text from core.profiles where employee_code = p_code), true),
         set_config('request.jwt.claim.role', 'authenticated', true)
$$;
create function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_msg; end if;
  insert into r(msg) values (p_msg);
end $$;
create function pg_temp.today() returns date language sql as $$ select (now() at time zone 'Asia/Ho_Chi_Minh')::date $$;
set client_min_messages = notice;

with ins as (insert into auth.users (id, email) values (gen_random_uuid(), 'x_sxtp@bmt.test') returning id)
insert into core.profiles (id, employee_code, full_name, status) select id, 'X_SXTP', 'Test SX TP', 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code) select id, 'SX_TP' from core.profiles where employee_code = 'X_SXTP';

-- ================================================================ 1. Khai báo máy, người, tốc độ mặc định
select pg_temp.ok((select machine_type = 'MIXER' and op_code = 'CD0' and active from master.machines where code = 'SIL-MIX'), 'Máy trộn silicone SIL-MIX làm công đoạn CD0');
select pg_temp.ok((select machine_type = 'PACKER' and op_code = 'CD6' and active and inline_with is null from master.machines where code = 'PACK-01'), 'Máy đóng gói PACK-01 làm công đoạn CD6');
select pg_temp.ok((select count(*) = 2 from app.v_kh_machines where code in ('SIL-MIX', 'PACK-01')), 'Lịch máy thấy máy trộn và máy đóng gói');
select pg_temp.ok((select operators @> array['NV3', 'NV4'] from app.v_kh_machines where code = 'PACK-01')
  and (select operators @> array['NV1'] from app.v_kh_machines where code = 'SIL-MIX'), 'Người đứng máy: NV3, NV4 đóng gói; NV1 trộn');
select pg_temp.ok((select unit = 'kg/giờ' and rate_small between 10 and 50 from master.machine_rates where op_code = 'CD0')
  and (select rate_small between 50 and 200 from master.machine_rates where op_code = 'CD6'), 'Tốc độ mặc định: trộn kg/giờ (10–50), đóng gói 50–200 m/phút');
select pg_temp.ok((select count(*) = 2 from master.changeover_rules where code in ('MIX_CODE', 'PK_CODE')), 'Phút đổi máy trộn, đóng gói');
select pg_temp.ok((select count(*) >= 4 from master.machine_specs s join master.machines m on m.id = s.machine_id where m.code = 'PACK-01' and s.grp = 'Công nghệ' and s.value is not null)
  and (select value = '10–50' from master.machine_specs s join master.machines m on m.id = s.machine_id where m.code = 'SIL-MIX' and s.label = 'Công suất trộn'),
  'Thông số công nghệ: bobin gỗ 500/305 m, 50–200 m/phút; trộn 10–50 kg/giờ');
select pg_temp.ok((select max_value = 200 from master.machine_ranges rg join master.machines m on m.id = rg.machine_id where m.code = 'PACK-01' and rg.param = 'SPEED_MPM'),
  'Tốc độ cuốn tối đa 200 m/phút');

-- ================================================================ 2. Kg hỗn hợp/km cáp
insert into t select 'sif', id from master.products where code = 'SIF-1C-1P5';
insert into t select 'pvc', id from master.products where group_code = 'PVC' order by code limit 1;
select pg_temp.ok(plan.mix_kg_km((select current_spec_id from master.products where id = (select v from t where k = 'sif'))) > 0, 'Mã silicone có kg hỗn hợp cần trộn / km cáp');
select pg_temp.ok(plan.mix_kg_km((select current_spec_id from master.products where id = (select v from t where k = 'pvc'))) is null, 'Mã PVC không cần trộn silicone');

-- ================================================================ 3. Năng lực: máy trộn tính theo kg
-- Dải tiết diện chỉ áp cho máy bện, đùn, xoắn, bọc vỏ: dải nhập nhầm ở máy trộn / máy đóng gói không chặn mã
insert into master.machine_ranges (machine_id, param, label, min_value, max_value, uom)
select id, 'SIZE_MM2', 'Thử dải nhầm', 10, 35, 'mm²' from master.machines where code in ('SIL-MIX', 'PACK-01');
select pg_temp.as_user('X_SXTP');
set local role authenticated;
create temp table cap as select app.check_capacity(null, pg_temp.today(), pg_temp.today() + 6, 1, 0,
  jsonb_build_array(jsonb_build_object('product_id', (select v from t where k = 'sif'), 'qty_m', 10000))) as j;
reset role;
select pg_temp.ok((select (o ->> 'req_min')::numeric between
      (select 10000 * plan.mix_kg_km(p.current_spec_id) / 1000 / (r.rate_small / 60) from master.products p, master.machine_rates r where p.id = (select v from t where k = 'sif') and r.op_code = 'CD0') - 1
  and (select 10000 * plan.mix_kg_km(p.current_spec_id) / 1000 / (r.rate_small / 60) from master.products p, master.machine_rates r where p.id = (select v from t where k = 'sif') and r.op_code = 'CD0') + 1
    from cap, jsonb_array_elements(j -> 'ops') o where o ->> 'op_code' = 'MIXER'),
  'Phút trộn = mét cáp × kg/km ÷ kg/giờ × 60');
select pg_temp.ok((select (o ->> 'req_min')::numeric between 10000 / 120.0 - 1 and 10000 / 120.0 + 1 from cap, jsonb_array_elements(j -> 'ops') o where o ->> 'op_code' = 'PACKER'),
  'Phút đóng gói = mét cáp ÷ tốc độ cuốn');
select pg_temp.ok((select (j -> 'issues')::text not like '%Chưa có tốc độ chuẩn%' from cap), 'Không còn báo thiếu tốc độ chuẩn cho trộn / đóng gói');
select pg_temp.ok((select (j -> 'issues')::text not like '%ngoài dải%' from cap), 'Dải tiết diện không áp cho máy trộn, máy đóng gói');
select pg_temp.ok((select (o ->> 'name') like 'Trộn silicone%' from cap, jsonb_array_elements(j -> 'ops') o where o ->> 'op_code' = 'MIXER'), 'Nhãn nhóm máy trộn');

-- ================================================================ 4. Vật tư theo việc trong ngày
insert into plan.production_plans (plan_no, period_label, status) values ('KH-MP1', 'Thử trộn, đóng gói', 'APPROVED');
insert into t select 'plan', id from plan.production_plans where plan_no = 'KH-MP1';
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, run_lots, m_per_pack, pack_type, brand)
select (select v from t where k = 'plan'), p.id, p.current_spec_id, 1000, 1, 500, 'Bobin gỗ', 'KAVIX' from master.products p where p.id = (select v from t where k = 'sif');
insert into t select 'line', id from plan.plan_lines where plan_id = (select v from t where k = 'plan');
-- Lịch mới: hôm nay trộn 1.000 m cáp, bọc 1.000 m lõi, đóng gói 1.000 m cáp
insert into plan.schedule_versions (plan_id, version, is_current, base_date, params, reason)
values ((select v from t where k = 'plan'), 1, true, pg_temp.today(),
        '{"S":420,"SPD":1,"workdays":[1,2,3,4,5,6,7],"shifts":[{"code":"A","start_time":"08:00","end_time":"17:00","break_min":60}]}', 'Thử');
insert into t select 'ver', id from plan.schedule_versions where plan_id = (select v from t where k = 'plan') and version = 1;
insert into plan.schedule_orders (version_id, plan_line_id, label, product_code, qty_m, meta)
values ((select v from t where k = 'ver'), (select v from t where k = 'line'), 'D01', 'SIF-1C-1P5', 1000, '{"cores":["Đỏ"]}');
insert into plan.schedule_slots (version_id, plan_line_id, op_code, color, machine_code, start_min, run_start_min, end_min, setup_min, meters, rate, speed)
values ((select v from t where k = 'ver'), (select v from t where k = 'line'), 'CD0', null, 'SIL-MIX', 0, 0, 100, 0, 1000, 10, 10),
       ((select v from t where k = 'ver'), (select v from t where k = 'line'), 'CD2', 'Đỏ', 'EXT-SI-01', 100, 100, 200, 0, 1000, 10, 10),
       ((select v from t where k = 'ver'), (select v from t where k = 'line'), 'CD6', null, 'PACK-01', 300, 300, 310, 0, 1000, 100, 100);
-- Lịch cũ (không có việc trộn, đóng gói): bọc gồm vật tư trộn như trước
insert into plan.schedule_versions (plan_id, version, is_current, base_date, params, reason)
values ((select v from t where k = 'plan'), 2, false, pg_temp.today(),
        '{"S":420,"SPD":1,"workdays":[1,2,3,4,5,6,7],"shifts":[{"code":"A","start_time":"08:00","end_time":"17:00","break_min":60}]}', 'Thử cũ');
insert into t select 'old', id from plan.schedule_versions where plan_id = (select v from t where k = 'plan') and version = 2;
insert into plan.schedule_orders (version_id, plan_line_id, label, product_code, qty_m, meta)
values ((select v from t where k = 'old'), (select v from t where k = 'line'), 'D01', 'SIF-1C-1P5', 1000, '{"cores":["Đỏ"]}');
insert into plan.schedule_slots (version_id, plan_line_id, op_code, color, machine_code, start_min, run_start_min, end_min, setup_min, meters, rate, speed)
values ((select v from t where k = 'old'), (select v from t where k = 'line'), 'CD2', 'Đỏ', 'EXT-SI-01', 100, 100, 200, 0, 1000, 10, 10);

create temp table expect as
select bl.material_id, bl.operation_code,
       round(bl.qty_per_basis * 1000 / 1000 / (1 - bl.loss_rate) + bl.startup_per_lot, 3) as q
from master.bom_lines bl join master.bom_headers h on h.id = bl.bom_id
where h.spec_id = (select spec_id from plan.plan_lines where id = (select v from t where k = 'line')) and bl.basis = 'KM' and bl.operation_code in ('CD0', 'CD2');
create temp table got_new as select * from plan.day_materials((select v from t where k = 'ver'), pg_temp.today());
create temp table got_old as select * from plan.day_materials((select v from t where k = 'old'), pg_temp.today());
select pg_temp.ok((select count(*) > 0 from expect where operation_code = 'CD0'), 'BOM mã silicone có vật tư trộn CD0');
select pg_temp.ok(not exists (
    select 1 from (select material_id, sum(q) q from expect group by material_id) e
    full join got_new g on g.material_id = e.material_id
    where abs(coalesce(e.q, 0) - coalesce(g.qty, 0)) > 0.002 and g.material_id in (select material_id from expect)),
  'Lịch mới: vật tư trộn lĩnh theo việc trộn, bọc chỉ lĩnh vật tư bọc (không lĩnh trùng)');
select pg_temp.ok(not exists (
    select 1 from (select material_id, sum(q) q from expect group by material_id) e
    full join got_old g on g.material_id = e.material_id
    where abs(coalesce(e.q, 0) - coalesce(g.qty, 0)) > 0.002),
  'Lịch cũ: bọc cách điện gồm vật tư trộn như trước');
select pg_temp.ok(exists (select 1 from got_new g join master.bom_lines bl on bl.material_id = g.material_id and bl.operation_code = 'CD6' and bl.basis = 'PACK'
                            join master.bom_headers h on h.id = bl.bom_id and h.spec_id = (select spec_id from plan.plan_lines where id = (select v from t where k = 'line')))
                  or not exists (select 1 from master.bom_lines bl join master.bom_headers h on h.id = bl.bom_id
                                 where h.spec_id = (select spec_id from plan.plan_lines where id = (select v from t where k = 'line')) and bl.operation_code = 'CD6' and bl.basis = 'PACK'),
  'Lịch mới: vật tư đóng gói (bobin gỗ, nhãn, màng) lĩnh theo việc đóng gói');
select pg_temp.ok(not exists (select 1 from got_old g join master.bom_lines bl on bl.material_id = g.material_id and bl.operation_code = 'CD6'
                                join master.bom_headers h on h.id = bl.bom_id and h.spec_id = (select spec_id from plan.plan_lines where id = (select v from t where k = 'line'))),
  'Lịch cũ mã không bọc vỏ: không lĩnh vật tư đóng gói theo ca như trước');

do $$ begin raise exception 'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt: %', (select count(*) from r), (select string_agg(msg, ' | ' order by n) from r); end $$;
rollback;
