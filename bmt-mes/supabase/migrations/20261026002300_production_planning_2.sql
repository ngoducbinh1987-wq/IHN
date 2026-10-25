-- BMT MES · 2300 · Kế hoạch sản xuất (bổ sung cho màn hình web)
-- 1. Danh mục sản phẩm kèm thông số xếp lịch (cho đơn phát sinh)
-- 2. Duyệt mẫu theo từng ca (trước đây cố định ca A)

create or replace view app.v_kh_products with (security_invoker = true) as
select p.id, p.code as product_code, p.description as product_name, p.group_code,
       s.cores, s.pairs, s.insulation, s.sheath, s.shield, s.sheath_color, s.insulation_colors, s.status as spec_status,
       coalesce(ct.nominal_mm2, 0) as size_mm2,
       (select cr.core_colors from master.color_rules cr where cr.group_code = p.group_code and cr.cores = s.cores) as core_colors,
       (select array_agg(r.op_code order by o.seq) from master.routings r join master.operations o on o.code = r.op_code where r.group_code = p.group_code) as route
from master.products p
join master.product_specs s on s.id = p.current_spec_id
left join master.core_types ct on ct.set_id = s.param_set_id and ct.code = s.core_code
where p.active and s.status = 'RELEASED';
grant select on app.v_kh_products to authenticated, service_role;

-- Bản cũ app.kh_sample(date, text, jsonb, integer, text) giữ lại (không dùng nữa) để migration không có lệnh xóa
create or replace function app.kh_sample(p_date date, p_machine text, p_shift text, p_samples jsonb, p_index integer, p_result text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r mfg.shift_reports; s jsonb;
begin
  if not app.kh_has_any(array['KT_TP','QC']) then raise exception 'Chỉ TP Kỹ thuật/QA hoặc QC duyệt mẫu'; end if;
  if p_result not in ('OK','NG') then raise exception 'Kết quả không hợp lệ'; end if;
  if p_shift not in ('A','B','C') then raise exception 'Ca không hợp lệ'; end if;
  insert into mfg.shift_reports as t (work_date, shift_code, machine_code, samples) values (p_date, p_shift, p_machine, coalesce(p_samples, '[]'))
  on conflict (work_date, shift_code, machine_code) do update set
    samples = case when jsonb_array_length(t.samples) = 0 then excluded.samples else t.samples end;
  select * into r from mfg.shift_reports where work_date = p_date and shift_code = p_shift and machine_code = p_machine for update;
  if r.status = 'CONFIRMED' then raise exception 'Ca đã xác nhận'; end if;
  s := r.samples -> p_index;
  if s is null then raise exception 'Không tìm thấy mẫu'; end if;
  update mfg.shift_reports set samples = jsonb_set(samples, array[p_index::text],
    s || jsonb_build_object('status', p_result, 'by_name', app.user_name(auth.uid()), 'at', to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI')))
  where id = r.id;
end $$;
revoke all on function app.kh_sample(date, text, text, jsonb, integer, text) from public, anon;
grant execute on function app.kh_sample(date, text, text, jsonb, integer, text) to authenticated, service_role;

-- 3. Lưu kèm thông số xếp lịch của từng lệnh (đường đi công đoạn, chống nhiễu, cách điện, màu) để người không xem được
--    kế hoạch tháng (vận hành, kho, QC) vẫn đọc được lịch máy
alter table plan.schedule_orders add column if not exists meta jsonb not null default '{}';

create or replace function app.kh_save_schedule(p_plan uuid, p_base date, p_params jsonb, p_orders jsonb, p_slots jsonb,
                                               p_reason text, p_change uuid default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid; v_ver integer; v_base date; c plan.change_requests;
begin
  if not app.kh_has_any(array['SX_TP','SX_KH','BGD']) then raise exception 'Chỉ Quản lý SX hoặc Giám đốc được xếp lịch máy'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Thiếu lý do xếp lịch'; end if;
  perform 1 from plan.production_plans where id = p_plan for update;
  if not found then raise exception 'Không tìm thấy kế hoạch'; end if;
  select base_date into v_base from plan.schedule_versions where plan_id = p_plan and is_current;
  if v_base is not null and v_base <> p_base then raise exception 'Ngày gốc của lịch không khớp phiên bản đang dùng'; end if;
  if p_change is not null then
    select * into c from plan.change_requests where id = p_change for update;
    if c.status <> 'LINE_ADDED' then raise exception 'Đơn phát sinh chưa đủ bước duyệt'; end if;
  end if;
  select coalesce(max(version), 0) + 1 into v_ver from plan.schedule_versions where plan_id = p_plan;
  update plan.schedule_versions set is_current = false where plan_id = p_plan and is_current;
  insert into plan.schedule_versions (plan_id, version, base_date, params, reason, change_request_id)
  values (p_plan, v_ver, p_base, p_params, trim(p_reason), p_change) returning id into v_id;
  insert into plan.schedule_orders (version_id, plan_line_id, label, product_code, product_name, group_code, qty_m, due_date, priority, source, finish_date, meta)
  select v_id, (e->>'plan_line_id')::uuid, e->>'label', e->>'product_code', e->>'product_name', e->>'group_code', (e->>'qty_m')::numeric,
         nullif(e->>'due_date', '')::date, coalesce((e->>'priority')::smallint, 1), e->>'source', nullif(e->>'finish_date', '')::date,
         coalesce(e->'meta', '{}')
  from jsonb_array_elements(p_orders) e;
  insert into plan.schedule_slots (version_id, plan_line_id, op_code, color, machine_code, operator_code, lane, start_min, run_start_min,
                                   end_min, setup_min, meters, rate, speed, reason, setup_why, part)
  select v_id, (e->>'plan_line_id')::uuid, e->>'op_code', nullif(e->>'color', ''), e->>'machine_code', e->>'operator_code',
         coalesce((e->>'lane')::smallint, 0), (e->>'start_min')::numeric, (e->>'run_start_min')::numeric, (e->>'end_min')::numeric,
         coalesce((e->>'setup_min')::numeric, 0), (e->>'meters')::numeric, (e->>'rate')::numeric, (e->>'speed')::numeric,
         e->>'reason', e->>'setup_why', coalesce((e->>'part')::boolean, false)
  from jsonb_array_elements(p_slots) e;
  if p_change is not null then
    update plan.change_requests set status = 'APPLIED', finished_at = now() where id = p_change;
  end if;
  return v_id;
end $$;

create or replace view app.v_kh_orders with (security_invoker = true) as select * from plan.schedule_orders;

-- 4. Số dòng kế hoạch theo mã sản phẩm (ổn định, dễ đọc) thay vì theo id ngẫu nhiên
create or replace view app.v_kh_plan_lines with (security_invoker = true) as
select l.id, l.plan_id, l.product_id, l.qty_m, l.due_date, l.priority, l.change_request_id, l.wo_note, l.so_line_id,
       pp.plan_no, pp.status as plan_status, pp.sched_start,
       p.code as product_code, p.description as product_name, p.group_code,
       s.cores, s.pairs, s.insulation, s.sheath, s.shield, s.sheath_color, s.insulation_colors, l.single_color, s.status as spec_status,
       coalesce(ct.nominal_mm2, 0) as size_mm2,
       (select cr.core_colors from master.color_rules cr where cr.group_code = p.group_code and cr.cores = s.cores) as core_colors,
       (select array_agg(r.op_code order by o.seq) from master.routings r join master.operations o on o.code = r.op_code where r.group_code = p.group_code) as route,
       (select so.so_no from sales.so_lines sl join sales.sales_orders so on so.id = sl.so_id where sl.id = l.so_line_id) as so_no,
       row_number() over (partition by l.plan_id order by (l.change_request_id is not null), p.code, l.due_date nulls last, l.id) as line_no
from plan.plan_lines l
join plan.production_plans pp on pp.id = l.plan_id
join master.products p on p.id = l.product_id
join master.product_specs s on s.id = l.spec_id
left join master.core_types ct on ct.set_id = s.param_set_id and ct.code = s.core_code;

-- 5. Dùng chung với module Quản lý máy (migration 20261025002300_machines):
--    ngày làm việc trong tuần lấy từ mfg.machine_setting('shift') (Giám đốc sửa ở Cài đặt máy);
--    máy con (in, đo OD… gắn vào dây chuyền) không xếp lịch riêng
create or replace view app.v_kh_config with (security_invoker = true) as
select c.*, (select jsonb_agg(to_jsonb(s) order by s.code) from master.shifts s) as shifts,
       (select jsonb_agg(to_jsonb(r) order by r.sort) from master.machine_rates r) as rates,
       (select jsonb_agg(to_jsonb(x) order by x.sort) from master.changeover_rules x) as changeovers,
       coalesce(mfg.machine_setting('shift') -> 'workdays', '[1,2,3,4,5,6]'::jsonb) as workdays
from master.planning_config c where c.id = 1;

create or replace view app.v_kh_machines with (security_invoker = true) as
select m.id, m.code, m.name, m.machine_type, m.protocol, m.data_mode, m.active,
       (select count(*) from iot.machine_tags t where t.machine_id = m.id) as tag_count,
       (select max(s.ts) from iot.machine_state s where s.machine_id = m.id) as last_seen,
       coalesce((select array_agg(k.operator_code order by k.operator_code) from master.operator_skills k
                 where k.machine_code = m.code and k.level = 'MAIN'), '{}') as operators
from master.machines m
where m.machine_type in ('BUNCHER','EXTRUDER_SI','TWISTER','EXTRUDER_TP') and m.active and m.inline_with is null;
