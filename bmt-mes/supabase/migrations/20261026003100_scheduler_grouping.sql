-- Xếp lịch máy (27/10/2026, yêu cầu anh Bình):
--  1. Tự gom các lô cùng cỡ ruột, cùng màu để giảm số lần đổi máy, màu sáng trước tối.
--     Tham số mới master.planning_config.group_days = "khung gom lô" (ngày): lô có hạn giao không muộn hơn
--     lô hạn sớm nhất đang chờ cùng máy quá số ngày này thì được chạy liền nếu ít phút đổi máy hơn. 0 = không gom.
--  2. Tốc độ lấy theo khai báo ở phần Máy (master.machine_speeds, riêng từng máy × công đoạn × sản phẩm/nhóm/lõi);
--     máy chưa khai báo thì dùng tốc độ mặc định theo công đoạn (master.machine_rates) như trước.
--     app.v_kh_config trả thêm cột speeds (đọc theo quyền machine:view của người xem) và group_days.
--  3. app.v_kh_plan_lines thêm core_code (mã lõi của spec) để chọn tốc độ theo lõi.

alter table master.planning_config add column if not exists group_days integer not null default 7;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'planning_config_group_days_check') then
    alter table master.planning_config add constraint planning_config_group_days_check check (group_days between 0 and 30);
  end if;
end $$;
comment on column master.planning_config.group_days is
  'Khung gom lô (ngày): lô có hạn giao không muộn hơn lô hạn sớm nhất quá số ngày này được chạy liền để giảm đổi máy; 0 = không gom';

-- c.* đổi số cột nên phải tạo lại view
drop view if exists app.v_kh_config;
create view app.v_kh_config with (security_invoker = true) as
select c.*, (select jsonb_agg(to_jsonb(s) order by s.code) from master.shifts s) as shifts,
       (select jsonb_agg(to_jsonb(r) order by r.sort) from master.machine_rates r) as rates,
       (select jsonb_agg(to_jsonb(x) order by x.sort) from master.changeover_rules x) as changeovers,
       coalesce(mfg.machine_setting('shift') -> 'workdays', '[1,2,3,4,5,6]'::jsonb) as workdays,
       -- Tốc độ khai báo theo máy (đang hiệu lực hoặc chờ duyệt); tốc độ dùng = min(chuẩn, danh định, tốc độ tối đa của dải hoạt động)
       (select jsonb_agg(jsonb_build_object(
                 'machine_code', m.code, 'op_code', s.op_code, 'product_id', s.product_id, 'group_code', s.group_code,
                 'core_code', s.core_code, 'std_mpm', s.std_mpm, 'rated_mpm', s.rated_mpm,
                 'max_mpm', (select rg.max_value from master.machine_ranges rg where rg.machine_id = s.machine_id and rg.param = 'SPEED_MPM' limit 1),
                 'status', s.status, 'submitted_at', s.submitted_at, 'label', s.label)
               order by m.code, s.op_code, s.submitted_at)
          from master.machine_speeds s join master.machines m on m.id = s.machine_id
         where s.status <> 'OBSOLETE' and m.active) as speeds
from master.planning_config c where c.id = 1;
grant select on app.v_kh_config to authenticated, service_role;

create or replace view app.v_kh_plan_lines with (security_invoker = true) as
select l.id, l.plan_id, l.product_id, l.qty_m, l.due_date, l.priority, l.change_request_id, l.wo_note, l.so_line_id,
       pp.plan_no, pp.status as plan_status, pp.sched_start,
       p.code as product_code, p.description as product_name, p.group_code,
       s.cores, s.pairs, s.insulation, s.sheath, s.shield, s.sheath_color, s.insulation_colors, l.single_color, s.status as spec_status,
       coalesce(ct.nominal_mm2, 0) as size_mm2,
       (select cr.core_colors from master.color_rules cr where cr.group_code = p.group_code and cr.cores = s.cores) as core_colors,
       (select array_agg(r.op_code order by o.seq) from master.routings r join master.operations o on o.code = r.op_code where r.group_code = p.group_code) as route,
       (select so.so_no from sales.so_lines sl join sales.sales_orders so on so.id = sl.so_id where sl.id = l.so_line_id) as so_no,
       row_number() over (partition by l.plan_id order by (l.change_request_id is not null), p.code, l.due_date nulls last, l.id) as line_no,
       s.core_code
from plan.plan_lines l
join plan.production_plans pp on pp.id = l.plan_id
join master.products p on p.id = l.product_id
join master.product_specs s on s.id = l.spec_id
left join master.core_types ct on ct.set_id = s.param_set_id and ct.code = s.core_code;

-- Tham số chung: Giám đốc (thêm khung gom lô)
create or replace function app.kh_save_config(p jsonb, p_reason text) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare c master.planning_config; n integer := 0; k text; lbl text; ov text; nv text;
  labels jsonb := '{"fill_pct":"Tỷ lệ xếp lịch mỗi ca (%)","frozen_days":"Vùng khóa lịch (ngày)","cutoff_time":"Giờ chốt phát lệnh ngày",
    "downtime_reason_min":"Dừng máy bắt buộc lý do khi quá (phút)","plc_dev_pct":"Ngưỡng lệch mét PLC / khai báo (%)",
    "auto_shifts":"Số ca đạt liên tiếp để chuyển tự động","plc_loss_min":"Mất kết nối PLC chuyển nhập tay sau (phút)",
    "machines_per_operator":"Số máy 1 người đứng cùng lúc","group_days":"Khung gom lô cùng cỡ ruột, cùng màu (ngày)"}';
begin
  if not core.has_role('BGD') then raise exception 'Chỉ Giám đốc được sửa tham số xếp lịch'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do thay đổi'; end if;
  select * into c from master.planning_config where id = 1 for update;
  for k in select jsonb_object_keys(labels) loop
    if not p ? k then continue; end if;
    ov := to_jsonb(c) ->> k;
    nv := p ->> k;
    if k = 'cutoff_time' then ov := left(ov, 5); nv := left(nv, 5); end if;
    if nv is distinct from ov and not (k <> 'cutoff_time' and ov::numeric = nv::numeric) then
      lbl := labels ->> k;
      perform app.kh_log('Tham số xếp lịch', lbl, ov, nv, trim(p_reason));
      n := n + 1;
    end if;
  end loop;
  if n = 0 then raise exception 'Không có thay đổi'; end if;
  update master.planning_config set
    fill_pct = coalesce((p->>'fill_pct')::numeric, fill_pct),
    frozen_days = coalesce((p->>'frozen_days')::int, frozen_days),
    cutoff_time = coalesce((p->>'cutoff_time')::time, cutoff_time),
    downtime_reason_min = coalesce((p->>'downtime_reason_min')::int, downtime_reason_min),
    plc_dev_pct = coalesce((p->>'plc_dev_pct')::numeric, plc_dev_pct),
    auto_shifts = coalesce((p->>'auto_shifts')::int, auto_shifts),
    plc_loss_min = coalesce((p->>'plc_loss_min')::int, plc_loss_min),
    machines_per_operator = coalesce((p->>'machines_per_operator')::int, machines_per_operator),
    group_days = coalesce((p->>'group_days')::int, group_days),
    updated_at = now(), updated_by = auth.uid()
  where id = 1;
  perform app.kh_notify_role('SX_TP', 'Tham số xếp lịch đã đổi', 'Giám đốc đã sửa ' || n || ' tham số. Bấm Xếp lại lịch để áp dụng.', '/lich-may');
  return n;
exception when check_violation then
  raise exception 'Giá trị ngoài khoảng cho phép, kiểm tra lại các ô vừa sửa';
end $$;
revoke all on function app.kh_save_config(jsonb, text) from public, anon;
grant execute on function app.kh_save_config(jsonb, text) to authenticated, service_role;
