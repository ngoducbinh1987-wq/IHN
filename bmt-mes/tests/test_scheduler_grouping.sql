-- Kiểm thử migration 20261026003100_scheduler_grouping và 20261026003200_plc_speeds: khung gom lô, tốc độ theo máy trong app.v_kh_config, core_code trong v_kh_plan_lines.
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
grant all on r to authenticated;
grant usage on sequence r_n_seq to authenticated;

create function pg_temp.as_user(p_code text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', (select id::text from core.profiles where employee_code = p_code), true),
         set_config('request.jwt.claims', json_build_object('sub', (select id::text from core.profiles where employee_code = p_code), 'role', 'authenticated')::text, true),
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
-- Đọc một giá trị dưới vai trò authenticated (như qua API)
create function pg_temp.api_val(p_sql text) returns text language plpgsql as $$
declare v text;
begin
  execute 'set local role authenticated';
  execute p_sql into v;
  execute 'reset role';
  return v;
end $$;
grant execute on function pg_temp.ok(boolean, text) to authenticated;
set client_min_messages = notice;

-- Tạm ngưng tài khoản thật trong giao dịch (khỏi gửi thông báo cho người thật); dùng người thử G_*
update core.profiles set status = 'INACTIVE' where employee_code not like 'G\_%' and status = 'ACTIVE';
with u(code) as (values ('G_BGD'), ('G_SXTP'), ('G_KD')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('G_BGD','BGD'),('G_SXTP','SX_TP'),('G_KD','KD_NV')) u(code, role) on u.code = p.employee_code;

-- ================================================================ 1. Khung gom lô
select pg_temp.ok((select group_days = 7 from master.planning_config where id = 1) or
                  exists (select 1 from master.planning_param_log where item like 'Khung gom lô%'),
  'Khung gom lô mặc định 7 ngày (hoặc đã được Giám đốc sửa có nhật ký)');
select pg_temp.as_user('G_SXTP');
select pg_temp.ok(pg_temp.api_val($q$select group_days::text from app.v_kh_config$q$) is not null, 'Quản lý SX đọc được khung gom lô qua app.v_kh_config');
select pg_temp.blocked($q$select app.kh_save_config('{"group_days": 3}', 'thử')$q$, 'Chỉ Giám đốc', 'Quản lý SX không tự sửa khung gom lô');
select pg_temp.as_user('G_BGD');
select pg_temp.blocked($q$select app.kh_save_config('{"group_days": 31}', 'thử')$q$, 'ngoài khoảng', 'Khung gom lô quá 30 ngày bị từ chối');
update master.planning_config set group_days = 7 where id = 1;
select pg_temp.ok(pg_temp.api_val($q$select app.kh_save_config('{"group_days": 5}', 'Chạy thử gom 5 ngày')::text$q$) = '1', 'Giám đốc sửa khung gom lô');
select pg_temp.ok((select group_days = 5 from master.planning_config where id = 1), 'Khung gom lô lưu 5 ngày');
select pg_temp.ok(exists (select 1 from master.planning_param_log where item = 'Khung gom lô cùng cỡ ruột, cùng màu (ngày)' and old_value = '7' and new_value = '5'),
  'Nhật ký tham số ghi Khung gom lô 7 → 5 (lịch đang dùng hiện "cần xếp lại")');
select pg_temp.ok(pg_temp.api_val($q$select app.kh_save_config('{"group_days": 0}', 'Tắt gom')::text$q$) = '1', 'Giám đốc tắt gom lô (0 ngày)');
select pg_temp.ok((select group_days = 0 from master.planning_config where id = 1), 'Khung gom lô lưu 0 ngày (chạy đúng thứ tự hạn giao)');

-- ================================================================ 2. Tốc độ theo máy trong app.v_kh_config
insert into master.machine_speeds (machine_id, op_code, std_mpm, rated_mpm, status, label)
select id, 'CD2', 95, 90, 'APPROVED', 'Thử G1' from master.machines where code = 'EXT-SI-01';
insert into master.machine_speeds (machine_id, op_code, std_mpm, status, label)
select id, 'CD2', 70, 'OBSOLETE', 'Thử G2' from master.machines where code = 'EXT-SI-01';
select pg_temp.as_user('G_SXTP');
select pg_temp.ok(pg_temp.api_val($q$select count(*)::text from app.v_kh_config, jsonb_array_elements(speeds) x
  where x->>'machine_code' = 'EXT-SI-01' and x->>'label' = 'Thử G1' and (x->>'std_mpm')::numeric = 95 and (x->>'rated_mpm')::numeric = 90
    and x->>'status' = 'APPROVED'$q$) = '1', 'Quản lý SX đọc được tốc độ khai báo của máy (chuẩn, danh định, trạng thái)');
select pg_temp.ok(pg_temp.api_val($q$select count(*)::text from app.v_kh_config, jsonb_array_elements(speeds) x where x->>'label' = 'Thử G2'$q$) = '0',
  'Tốc độ đã thay (OBSOLETE) không đưa vào xếp lịch');
select pg_temp.as_user('G_KD');
select pg_temp.ok(coalesce(pg_temp.api_val($q$select count(*)::text from app.v_kh_config, jsonb_array_elements(coalesce(speeds, '[]')) x where x->>'label' like 'Thử G%'$q$), '0') = '0',
  'Người không có quyền xem máy không đọc được tốc độ máy (RLS)');

-- ================================================================ 3. Mã lõi trong dòng kế hoạch
select pg_temp.ok(exists (select 1 from information_schema.columns where table_schema = 'app' and table_name = 'v_kh_plan_lines' and column_name = 'core_code'),
  'app.v_kh_plan_lines có cột core_code (chọn tốc độ theo mã lõi)');
select pg_temp.ok(not has_function_privilege('anon', 'app.kh_save_config(jsonb,text)', 'execute'), 'anon không gọi được app.kh_save_config');

-- ================================================================ 4. Tốc độ thực tế từ PLC (migration 20261026003200)
create temp table g (k text primary key, v uuid);
with x as (
  insert into mfg.work_orders (wo_no, product_id, spec_id, bom_id, qty_m, m_per_pack, pack_type, brand)
  select 'LSX-G1', p.id, p.current_spec_id, h.id, 1000, 500, 'Bobin gỗ', 'KAVIX'
  from master.products p join master.bom_headers h on h.spec_id = p.current_spec_id
  order by p.code limit 1 returning id)
insert into g select 'wo', id from x;
with x as (
  insert into mfg.wo_operations (wo_id, op_code, seq, machine_id)
  select (select v from g where k = 'wo'), 'CD2', 2, id from master.machines where code = 'EXT-SI-01' returning id)
insert into g select 'op', id from x;
insert into iot.telemetry_1m (machine_id, bucket, wo_op_id, run_seconds, avg_speed, meters)
select m.id, date_trunc('minute', now()) - interval '1 day' + n * interval '1 minute', (select v from g where k = 'op'), 60, 80, 80
from master.machines m, generate_series(1, 150) n where m.code = 'EXT-SI-01'
union all  -- bộ đếm nhảy: bỏ
select m.id, date_trunc('minute', now()) - interval '2 days', (select v from g where k = 'op'), 60, 80, 999999 from master.machines m where m.code = 'EXT-SI-01'
union all  -- quá 30 ngày: bỏ
select m.id, date_trunc('minute', now()) - interval '40 days', (select v from g where k = 'op'), 60, 80, 50 from master.machines m where m.code = 'EXT-SI-01'
union all  -- dừng gần hết phút: bỏ
select m.id, date_trunc('minute', now()) - interval '3 days', (select v from g where k = 'op'), 10, 80, 13 from master.machines m where m.code = 'EXT-SI-01'
on conflict do nothing;
select pg_temp.as_user('G_SXTP');
select pg_temp.ok(pg_temp.api_val($q$select x->>'run_min' || '|' || (x->>'meters') from app.v_kh_config, jsonb_array_elements(plc_speeds) x
  where x->>'machine_code' = 'EXT-SI-01' and x->>'op_code' = 'CD2' and x->>'product_id' = (select product_id::text from mfg.work_orders where wo_no = 'LSX-G1')$q$) = '150.0|12000.0',
  'Tốc độ PLC 30 ngày: 12.000 m / 150 phút chạy (bỏ phút bộ đếm nhảy, phút dừng, dữ liệu quá 30 ngày)');
select pg_temp.ok(not has_function_privilege('authenticated', 'mfg.plc_speeds(integer)', 'execute')
  and not has_function_privilege('anon', 'app.kh_plc_speeds()', 'execute'), 'Người dùng không gọi thẳng hàm tổng hợp PLC; anon không đọc được');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
