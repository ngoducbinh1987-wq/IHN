-- Tốc độ xếp lịch theo chế độ nhập dữ liệu của máy (27/10/2026, yêu cầu anh Bình):
--  - Nhập tay (MANUAL) / Song song (BOTH): dùng bảng tốc độ tự nhập theo chủng loại × cỡ ruột (master.machine_speeds).
--  - Tự động (PLC): dùng tốc độ thực tế đo từ PLC = mét ÷ phút chạy (iot.telemetry_1m), 30 ngày gần nhất,
--    theo máy × công đoạn × mã sản phẩm / nhóm / mã lõi (qua lệnh SX gắn vào phút chạy). Chưa đủ dữ liệu thì dùng bảng tự nhập.
-- PLC chỉ đọc, không ghi xuống.

-- Tổng hợp nội bộ (đọc bảng iot đã khóa với người dùng)
create or replace function mfg.plc_speeds(p_days integer default 30)
returns table (machine_code text, op_code text, product_id uuid, group_code text, core_code text, meters numeric, run_min numeric, last_at timestamptz)
language sql stable security definer set search_path = pg_catalog, public as $$
  select m.code, o.op_code, w.product_id, p.group_code, s.core_code,
         round(sum(t.meters)::numeric, 1), round(sum(t.run_seconds)::numeric / 60, 1), max(t.bucket)
  from iot.telemetry_1m t
  join master.machines m on m.id = t.machine_id
  join mfg.wo_operations o on o.id = t.wo_op_id
  join mfg.work_orders w on w.id = o.wo_id
  join master.products p on p.id = w.product_id
  left join master.product_specs s on s.id = w.spec_id
  where t.bucket >= now() - make_interval(days => greatest(1, least(p_days, 365)))
    and t.run_seconds >= 30 and t.meters > 0
    and t.meters / (t.run_seconds / 60.0) < 2000          -- bỏ phút bộ đếm mét PLC nhảy (đặt lại, lỗi tín hiệu)
  group by 1, 2, 3, 4, 5
$$;
revoke all on function mfg.plc_speeds(integer) from public, anon, authenticated;

-- Cho web: người xem được máy mới thấy
create or replace function app.kh_plc_speeds() returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if not (core.has_perm('machine', 'view') or app.kh_can_view()) then return null; end if;
  return (select jsonb_agg(to_jsonb(x) order by x.machine_code, x.op_code) from mfg.plc_speeds(30) x);
end $$;
revoke all on function app.kh_plc_speeds() from public, anon;
grant execute on function app.kh_plc_speeds() to authenticated, service_role;

create or replace view app.v_kh_config with (security_invoker = true) as
select c.*, (select jsonb_agg(to_jsonb(s) order by s.code) from master.shifts s) as shifts,
       (select jsonb_agg(to_jsonb(r) order by r.sort) from master.machine_rates r) as rates,
       (select jsonb_agg(to_jsonb(x) order by x.sort) from master.changeover_rules x) as changeovers,
       coalesce(mfg.machine_setting('shift') -> 'workdays', '[1,2,3,4,5,6]'::jsonb) as workdays,
       (select jsonb_agg(jsonb_build_object(
                 'machine_code', m.code, 'op_code', s.op_code, 'product_id', s.product_id, 'group_code', s.group_code,
                 'core_code', s.core_code, 'std_mpm', s.std_mpm, 'rated_mpm', s.rated_mpm,
                 'max_mpm', (select rg.max_value from master.machine_ranges rg where rg.machine_id = s.machine_id and rg.param = 'SPEED_MPM' limit 1),
                 'status', s.status, 'submitted_at', s.submitted_at, 'label', s.label)
               order by m.code, s.op_code, s.submitted_at)
          from master.machine_speeds s join master.machines m on m.id = s.machine_id
         where s.status <> 'OBSOLETE' and m.active) as speeds,
       app.kh_plc_speeds() as plc_speeds
from master.planning_config c where c.id = 1;
grant select on app.v_kh_config to authenticated, service_role;
