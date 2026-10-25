-- BMT MES · 2200 · Kế hoạch sản xuất: lịch máy theo máy và người, lệnh ngày + phiếu lĩnh, đơn phát sinh, ghi nhận ca
-- Theo bản thiết kế đã duyệt và Quy chuẩn vai trò & nhiệm vụ nhân sự nhà máy BMT (25/10/2026).
-- Quyền (một người chịu trách nhiệm cuối cho mỗi việc):
--   Giám đốc (BGD): ca, tham số xếp lịch, cách nhập dữ liệu máy, hạn giao trong kế hoạch tháng, duyệt đơn phát sinh mức B/C
--   TP Kỹ thuật/QA (KT_TP): tốc độ chuẩn, phút đổi máy, ý kiến đơn mức C, duyệt mẫu đầu ca/đầu mã (cùng QC)
--   Quản lý SX (SX_TP, SX_KH): xếp lịch máy, phát lệnh ngày, lập đơn phát sinh; Tổ trưởng (TO_TRUONG) xác nhận ca
--   Kế toán kho (KT_KHO): duyệt phiếu lĩnh · Vận hành (VAN_HANH): nhập sản lượng ca
-- Ghi dữ liệu chỉ qua hàm app.kh_* (security definer, có kiểm quyền); đọc qua view app.v_kh_*.

-- ---------------------------------------------------------------------------
-- 1. Máy
-- ---------------------------------------------------------------------------
alter table master.machines add column if not exists data_mode text not null default 'MANUAL';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'machines_data_mode_chk') then
    alter table master.machines add constraint machines_data_mode_chk check (data_mode in ('MANUAL','BOTH','PLC'));
  end if;
end $$;

insert into master.machines (code, name, machine_type, protocol) values
  ('EXT-SI-02', 'Line đùn silicone 2', 'EXTRUDER_SI', 'S7'),
  ('EXT-TP-02', 'Line đùn vỏ 2 (PVC/HDPE/LSZH)', 'EXTRUDER_TP', 'S7')
on conflict (code) do nothing;
update master.machines set name = 'Line đùn silicone 1' where code = 'EXT-SI-01';
update master.machines set name = 'Line đùn vỏ 1 (PVC/HDPE/LSZH)' where code = 'EXT-TP-01';
update master.machines set name = 'Máy xoắn 800 + quấn AL/PET' where code = 'TWS-01';
update master.machines set name = 'Máy bện 630' where code = 'BUN-01';

-- ---------------------------------------------------------------------------
-- 2. Tham số xếp lịch
-- ---------------------------------------------------------------------------
create table if not exists master.planning_config (
  id                  smallint primary key default 1 check (id = 1),
  fill_pct            numeric not null default 85 check (fill_pct between 60 and 95),
  frozen_days         integer not null default 3 check (frozen_days between 1 and 7),
  cutoff_time         time    not null default '16:00',
  downtime_reason_min integer not null default 5 check (downtime_reason_min between 1 and 30),
  plc_dev_pct         numeric not null default 0.5 check (plc_dev_pct between 0.1 and 2),
  auto_shifts         integer not null default 10 check (auto_shifts between 3 and 30),
  plc_loss_min        integer not null default 10 check (plc_loss_min between 1 and 60),
  machines_per_operator integer not null default 1 check (machines_per_operator between 1 and 3),
  updated_at          timestamptz,
  updated_by          uuid
);
insert into master.planning_config (id) values (1) on conflict (id) do nothing;

create table if not exists master.shifts (
  code       text primary key check (code in ('A','B','C')),
  start_time time not null,
  end_time   time not null,
  break_min  integer not null default 30 check (break_min between 0 and 90),
  active     boolean not null default false
);
insert into master.shifts (code, start_time, end_time, break_min, active) values
  ('A', '06:00', '14:00', 30, true), ('B', '14:00', '22:00', 30, false), ('C', '22:00', '06:00', 30, false)
on conflict (code) do nothing;

-- Tốc độ chuẩn (TP Kỹ thuật/QA ban hành). CD4: quấn AL/PET chạy liền dây trên máy xoắn
create table if not exists master.machine_rates (
  op_code    text primary key,
  label      text not null,
  unit       text not null,
  rate_small numeric not null check (rate_small > 0),   -- cỡ ruột < 2,5 mm²
  rate_large numeric not null check (rate_large > 0),   -- cỡ ruột ≥ 2,5 mm²
  confirmed  boolean not null default false,
  sort       smallint not null default 0
);
insert into master.machine_rates (op_code, label, unit, rate_small, rate_large, sort) values
  ('CD1', 'Bện ruột dẫn', 'm lõi', 100, 80, 1),
  ('CD2', 'Bọc cách điện', 'm lõi', 80, 70, 2),
  ('CD3', 'Xoắn / ghép lõi', 'm cáp', 50, 50, 3),
  ('CD4', 'Quấn AL/PET (liền dây xoắn)', 'm cáp', 60, 60, 4),
  ('CD5', 'Bọc vỏ PVC/HDPE/LSZH', 'm cáp', 60, 45, 5)
on conflict (op_code) do nothing;

create table if not exists master.changeover_rules (
  code    text primary key,
  op_code text not null,
  label   text not null,
  minutes integer not null check (minutes between 0 and 240),
  sort    smallint not null default 0
);
insert into master.changeover_rules (code, op_code, label, minutes, sort) values
  ('INS_UP',   'CD2', 'Màu sáng → tối', 15, 1),
  ('INS_DOWN', 'CD2', 'Màu tối → sáng (purge)', 35, 2),
  ('INS_SIZE', 'CD2', 'Đổi cỡ ruột (thay khuôn)', 45, 3),
  ('SH_COLOR', 'CD5', 'Đổi màu vỏ', 20, 4),
  ('SH_CODE',  'CD5', 'Đổi mã (khuôn, in)', 45, 5),
  ('BUN_SIZE', 'CD1', 'Đổi cỡ ruột', 20, 6),
  ('TWS_CODE', 'CD3', 'Đổi mã (xoắn, AL/PET)', 25, 7)
on conflict (code) do nothing;

-- Người đứng máy và tay nghề (phân công Chủ tịch HĐQT chốt 25/10/2026)
create table if not exists master.operators (
  code       text primary key,
  job        text not null,
  extra      text,
  profile_id uuid references core.profiles(id),
  is_deputy  boolean not null default false,   -- tổ phó: thay Quản lý SX khi vắng
  keeps_fg   boolean not null default false,   -- giữ kho thành phẩm
  active     boolean not null default true,
  sort       smallint not null default 0
);
insert into master.operators (code, job, extra, is_deputy, keeps_fg, sort) values
  ('NV1', 'Chạy line silicone và line vỏ (PVC/HDPE/LSZH)', 'Lấy hàng ở kho, nhập hàng vào kho · Tổ phó: thay Quản lý SX khi vắng', true, false, 1),
  ('NV2', 'Chạy bện, xoắn + quấn AL/PET', 'Nhập hàng vào kho', false, false, 2),
  ('NV3', 'Vận chuyển bobin, đóng gói thành phẩm', 'Giữ kho thành phẩm', false, true, 3),
  ('NV4', 'Vận chuyển bobin, đóng gói thành phẩm', null, false, false, 4),
  ('NV5', 'Chạy line silicone và line vỏ (PVC/HDPE/LSZH)', 'Lấy hàng ở kho, nhập hàng vào kho', false, false, 5)
on conflict (code) do nothing;

create table if not exists master.operator_skills (
  operator_code text not null references master.operators(code) on delete cascade,
  machine_code  text not null references master.machines(code) on delete cascade,
  level         text not null default 'MAIN' check (level in ('MAIN','LEARNING')),
  signed_by     uuid,
  signed_at     timestamptz,
  primary key (operator_code, machine_code)
);
insert into master.operator_skills (operator_code, machine_code, level)
select o, m, 'MAIN' from (values ('NV1'), ('NV5')) a(o), (values ('EXT-SI-01'), ('EXT-SI-02'), ('EXT-TP-01'), ('EXT-TP-02')) b(m)
union all select 'NV2', m, 'MAIN' from (values ('BUN-01'), ('TWS-01')) c(m)
on conflict do nothing;

create table if not exists master.planning_param_log (
  id        bigint generated always as identity primary key,
  at        timestamptz not null default now(),
  user_id   uuid default auth.uid(),
  section   text not null,
  item      text not null,
  old_value text,
  new_value text,
  reason    text not null
);

-- ---------------------------------------------------------------------------
-- 3. Kế hoạch, lịch máy theo phiên bản, lệnh ngày, phiếu lĩnh, đơn phát sinh
-- ---------------------------------------------------------------------------
alter table plan.plan_lines add column if not exists due_date date;
alter table plan.plan_lines add column if not exists priority smallint not null default 1;
alter table plan.plan_lines add column if not exists change_request_id uuid;
alter table plan.production_plans add column if not exists sched_start date;

create table if not exists plan.schedule_versions (
  id          uuid primary key default gen_random_uuid(),
  plan_id     uuid not null references plan.production_plans(id) on delete cascade,
  version     integer not null,
  is_current  boolean not null default true,
  base_date   date not null,          -- ngày làm việc đầu tiên của trục thời gian lịch
  params      jsonb not null,         -- S, SPD, RUN, fill_pct, frozen_days, machines_per_operator, ca
  reason      text not null,
  change_request_id uuid,
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid(),
  unique (plan_id, version)
);
create index if not exists schedule_versions_plan_idx on plan.schedule_versions (plan_id, is_current);

create table if not exists plan.schedule_orders (
  version_id   uuid not null references plan.schedule_versions(id) on delete cascade,
  plan_line_id uuid not null,
  label        text not null,
  product_code text not null,
  product_name text,
  group_code   text,
  qty_m        numeric not null,
  due_date     date,
  priority     smallint not null default 1,
  source       text,
  finish_date  date,                 -- công đoạn cuối xong + 1 ca kiểm tra, đóng gói
  primary key (version_id, plan_line_id)
);

create table if not exists plan.schedule_slots (
  id            uuid primary key default gen_random_uuid(),
  version_id    uuid not null references plan.schedule_versions(id) on delete cascade,
  plan_line_id  uuid not null,
  op_code       text not null,
  color         text,
  machine_code  text not null,
  operator_code text,
  lane          smallint not null default 0,
  start_min     numeric not null,    -- phút xếp lịch tính từ base_date ca đầu
  run_start_min numeric not null,
  end_min       numeric not null,
  setup_min     numeric not null default 0,
  meters        numeric not null,
  rate          numeric not null,    -- m / phút xếp lịch
  speed         numeric not null,    -- tốc độ chuẩn lúc xếp (m/phút)
  reason        text,
  setup_why     text,
  part          boolean not null default false
);
create index if not exists schedule_slots_version_idx on plan.schedule_slots (version_id, machine_code);

create table if not exists plan.daily_releases (
  id          uuid primary key default gen_random_uuid(),
  plan_id     uuid not null references plan.production_plans(id) on delete cascade,
  work_date   date not null,
  revision    integer not null default 1,
  version_id  uuid references plan.schedule_versions(id),
  note        text,
  checks      jsonb,
  released_at timestamptz not null default now(),
  released_by uuid default auth.uid(),
  unique (plan_id, work_date, revision)
);

create table if not exists plan.issue_slips (
  id          uuid primary key default gen_random_uuid(),
  release_id  uuid not null references plan.daily_releases(id) on delete cascade,
  slip_no     text not null,
  work_date   date not null,
  lines       jsonb not null,
  status      text not null default 'PENDING' check (status in ('PENDING','APPROVED')),
  approved_by uuid,
  approved_at timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists issue_slips_release_idx on plan.issue_slips (release_id);

create table if not exists plan.change_requests (
  id          uuid primary key default gen_random_uuid(),
  plan_id     uuid not null references plan.production_plans(id) on delete cascade,
  req_no      text not null,
  payload     jsonb not null,        -- mã, số mét, hạn giao, SO, ưu tiên, chen vùng khóa
  result      jsonb not null,        -- kết quả mô phỏng
  level       text not null check (level in ('A','B','C')),
  steps       jsonb not null,        -- [{role, label, done_by, done_name, done_at}]
  status      text not null default 'PENDING' check (status in ('PENDING','READY','LINE_ADDED','APPLIED','RETURNED')),
  new_line_id uuid,
  note        text,
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid(),
  finished_at timestamptz
);

-- ---------------------------------------------------------------------------
-- 4. Báo cáo ca (ghi nhận sản lượng tại máy)
-- ---------------------------------------------------------------------------
create table if not exists mfg.shift_reports (
  id            uuid primary key default gen_random_uuid(),
  work_date     date not null,
  shift_code    text not null default 'A',
  machine_code  text not null references master.machines(code),
  operator_code text,
  plan_id       uuid,
  source        text not null default 'MANUAL' check (source in ('MANUAL','BOTH','PLC')),
  lines         jsonb not null default '[]',   -- [{plan_line_id, label, product_code, op, color, planned_m, declared_m, plc_m, bobbins}]
  downtime      jsonb not null default '[]',   -- [{from, to, min, reason, src}]
  samples       jsonb not null default '[]',   -- [{kind, product_code, status, by_name, at}]
  scrap_kg      numeric not null default 0,
  scrap_reason  text,
  note          text,
  status        text not null default 'DRAFT' check (status in ('DRAFT','SUBMITTED','CONFIRMED')),
  saved_by      uuid, saved_at timestamptz,
  submitted_by  uuid, submitted_at timestamptz,
  confirmed_by  uuid, confirmed_at timestamptz,
  unique (work_date, shift_code, machine_code)
);

-- ---------------------------------------------------------------------------
-- 5. Quyền đọc: ai xem được sản xuất / kế hoạch / kho đều xem được module. Không cho ghi trực tiếp.
-- ---------------------------------------------------------------------------
create or replace function app.kh_can_view() returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select core.has_perm('plan','view') or core.has_perm('production','view') or core.has_perm('inventory','view')
$$;

create or replace function app.kh_has_any(p_roles text[]) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select exists (select 1 from unnest(p_roles) r where core.has_role(r))
$$;

do $$
declare t text;
begin
  foreach t in array array['master.planning_config','master.shifts','master.machine_rates','master.changeover_rules',
    'master.operators','master.operator_skills','master.planning_param_log','plan.schedule_versions','plan.schedule_orders',
    'plan.schedule_slots','plan.daily_releases','plan.issue_slips','plan.change_requests','mfg.shift_reports'] loop
    execute format('alter table %s enable row level security', t);
    execute format('revoke all on %s from anon, authenticated', t);
    execute format('grant select on %s to authenticated', t);
    execute format('grant all on %s to service_role', t);
    execute format('drop policy if exists p_select on %s', t);
    execute format('create policy p_select on %s for select to authenticated using (app.kh_can_view())', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Hàm ghi
-- ---------------------------------------------------------------------------
create or replace function app.kh_notify_role(p_role text, p_title text, p_body text, p_link text) returns void
language sql security definer set search_path = pg_catalog, public as $$
  insert into wf.notifications (user_id, title, body, link)
  select distinct ur.user_id, p_title, p_body, p_link
  from core.user_roles ur join core.profiles p on p.id = ur.user_id and p.status = 'ACTIVE'
  where ur.role_code = p_role and ur.user_id is distinct from auth.uid()
$$;

create or replace function app.kh_log(p_section text, p_item text, p_old text, p_new text, p_reason text) returns void
language sql security definer set search_path = pg_catalog, public as $$
  insert into master.planning_param_log (section, item, old_value, new_value, reason) values (p_section, p_item, p_old, p_new, p_reason)
$$;

-- Tham số chung: Giám đốc
create or replace function app.kh_save_config(p jsonb, p_reason text) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare c master.planning_config; n integer := 0; k text; lbl text; ov text; nv text;
  labels jsonb := '{"fill_pct":"Tỷ lệ xếp lịch mỗi ca (%)","frozen_days":"Vùng khóa lịch (ngày)","cutoff_time":"Giờ chốt phát lệnh ngày",
    "downtime_reason_min":"Dừng máy bắt buộc lý do khi quá (phút)","plc_dev_pct":"Ngưỡng lệch mét PLC / khai báo (%)",
    "auto_shifts":"Số ca đạt liên tiếp để chuyển tự động","plc_loss_min":"Mất kết nối PLC chuyển nhập tay sau (phút)",
    "machines_per_operator":"Số máy 1 người đứng cùng lúc"}';
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
    updated_at = now(), updated_by = auth.uid()
  where id = 1;
  perform app.kh_notify_role('SX_TP', 'Tham số xếp lịch đã đổi', 'Giám đốc đã sửa ' || n || ' tham số. Bấm Xếp lại lịch để áp dụng.', '/lich-may');
  return n;
exception when check_violation then
  raise exception 'Giá trị ngoài khoảng cho phép, kiểm tra lại các ô vừa sửa';
end $$;

-- Ca làm việc: Giám đốc. p = [{code, start_time, end_time, break_min, active}]
create or replace function app.kh_save_shifts(p jsonb, p_reason text) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare e jsonb; s master.shifts; n integer := 0; v_run integer;
begin
  if not core.has_role('BGD') then raise exception 'Chỉ Giám đốc được sửa ca làm việc'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do thay đổi'; end if;
  for e in select * from jsonb_array_elements(p) loop
    select * into s from master.shifts where code = e->>'code' for update;
    if not found then raise exception 'Không có ca %', e->>'code'; end if;
    if s.code = 'A' and not (e->>'active')::boolean then raise exception 'Ca A luôn chạy'; end if;
    v_run := (extract(epoch from ((e->>'end_time')::time - (e->>'start_time')::time + interval '24 hours')) / 60)::int % 1440;
    if v_run = 0 then v_run := 1440; end if;
    v_run := v_run - (e->>'break_min')::int;
    if (e->>'active')::boolean and v_run < 300 then raise exception 'Ca %: phút chạy phải từ 300 trở lên', s.code; end if;
    if left(s.start_time::text, 5) <> left(e->>'start_time', 5) then perform app.kh_log('Ca làm việc', 'Ca ' || s.code || ' · giờ bắt đầu', left(s.start_time::text, 5), left(e->>'start_time', 5), trim(p_reason)); n := n + 1; end if;
    if left(s.end_time::text, 5) <> left(e->>'end_time', 5) then perform app.kh_log('Ca làm việc', 'Ca ' || s.code || ' · giờ kết thúc', left(s.end_time::text, 5), left(e->>'end_time', 5), trim(p_reason)); n := n + 1; end if;
    if s.break_min <> (e->>'break_min')::int then perform app.kh_log('Ca làm việc', 'Ca ' || s.code || ' · phút nghỉ', s.break_min::text, e->>'break_min', trim(p_reason)); n := n + 1; end if;
    if s.active <> (e->>'active')::boolean then perform app.kh_log('Ca làm việc', 'Ca ' || s.code || ' · trạng thái', case when s.active then 'Dùng' else 'Tắt' end, case when (e->>'active')::boolean then 'Dùng' else 'Tắt' end, trim(p_reason)); n := n + 1; end if;
    update master.shifts set start_time = (e->>'start_time')::time, end_time = (e->>'end_time')::time,
      break_min = (e->>'break_min')::int, active = (e->>'active')::boolean where code = s.code;
  end loop;
  if n = 0 then raise exception 'Không có thay đổi'; end if;
  perform app.kh_notify_role('SX_TP', 'Ca làm việc đã đổi', 'Giám đốc đã sửa ca làm việc. Bấm Xếp lại lịch để áp dụng.', '/lich-may');
  return n;
exception when check_violation then raise exception 'Phút nghỉ phải từ 0 đến 90';
end $$;

-- Tốc độ chuẩn: TP Kỹ thuật/QA. p = [{op_code, rate_small, rate_large}]
create or replace function app.kh_save_rates(p jsonb, p_reason text) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare e jsonb; r master.machine_rates; n integer := 0;
begin
  if not core.has_role('KT_TP') then raise exception 'Chỉ TP Kỹ thuật/QA được sửa tốc độ chuẩn'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do thay đổi'; end if;
  for e in select * from jsonb_array_elements(p) loop
    select * into r from master.machine_rates where op_code = e->>'op_code' for update;
    if not found then continue; end if;
    if (e->>'rate_small')::numeric not between 5 and 300 or (e->>'rate_large')::numeric not between 5 and 300 then
      raise exception '%: tốc độ phải từ 5 đến 300 m/phút', r.label;
    end if;
    if r.rate_small <> (e->>'rate_small')::numeric then perform app.kh_log('Tốc độ chuẩn', r.label || ' · cỡ < 2,5 mm²', r.rate_small::text, e->>'rate_small', trim(p_reason)); n := n + 1; end if;
    if r.rate_large <> (e->>'rate_large')::numeric then perform app.kh_log('Tốc độ chuẩn', r.label || ' · cỡ ≥ 2,5 mm²', r.rate_large::text, e->>'rate_large', trim(p_reason)); n := n + 1; end if;
    update master.machine_rates set rate_small = (e->>'rate_small')::numeric, rate_large = (e->>'rate_large')::numeric, confirmed = true
    where op_code = r.op_code;
  end loop;
  if n = 0 then raise exception 'Không có thay đổi'; end if;
  perform app.kh_notify_role('SX_TP', 'Tốc độ chuẩn đã đổi', 'TP Kỹ thuật/QA đã sửa tốc độ chuẩn. Bấm Xếp lại lịch để áp dụng.', '/lich-may');
  return n;
end $$;

-- Phút đổi máy: TP Kỹ thuật/QA. p = [{code, minutes}]
create or replace function app.kh_save_changeovers(p jsonb, p_reason text) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare e jsonb; r master.changeover_rules; n integer := 0;
begin
  if not core.has_role('KT_TP') then raise exception 'Chỉ TP Kỹ thuật/QA được sửa phút đổi máy'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do thay đổi'; end if;
  for e in select * from jsonb_array_elements(p) loop
    select * into r from master.changeover_rules where code = e->>'code' for update;
    if not found then continue; end if;
    if (e->>'minutes')::int not between 0 and 240 then raise exception '%: phút đổi máy phải từ 0 đến 240', r.label; end if;
    if r.minutes <> (e->>'minutes')::int then
      perform app.kh_log('Phút đổi máy', r.op_code || ' · ' || r.label, r.minutes::text, e->>'minutes', trim(p_reason)); n := n + 1;
      update master.changeover_rules set minutes = (e->>'minutes')::int where code = r.code;
    end if;
  end loop;
  if n = 0 then raise exception 'Không có thay đổi'; end if;
  perform app.kh_notify_role('SX_TP', 'Phút đổi máy đã đổi', 'TP Kỹ thuật/QA đã sửa phút đổi máy. Bấm Xếp lại lịch để áp dụng.', '/lich-may');
  return n;
end $$;

-- Cách nhập dữ liệu máy: Giám đốc; tự động/song song chỉ khi máy đã khai báo tag PLC
create or replace function app.kh_set_machine_mode(p_machine text, p_mode text, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare m master.machines; names jsonb := '{"MANUAL":"Nhập tay","BOTH":"Song song","PLC":"Tự động (PLC)"}';
begin
  if not core.has_role('BGD') then raise exception 'Chỉ Giám đốc được đổi cách nhập dữ liệu máy'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do (ví dụ: theo đề xuất TP Kỹ thuật/QA)'; end if;
  select * into m from master.machines where code = p_machine for update;
  if not found then raise exception 'Không có máy %', p_machine; end if;
  if p_mode not in ('MANUAL','BOTH','PLC') then raise exception 'Cách nhập không hợp lệ'; end if;
  if p_mode <> 'MANUAL' and not exists (select 1 from iot.machine_tags t where t.machine_id = m.id) then
    raise exception 'Máy % chưa khai báo tag PLC: chưa chọn được song song hoặc tự động', p_machine;
  end if;
  if m.data_mode = p_mode then raise exception 'Không có thay đổi'; end if;
  perform app.kh_log('Cách nhập dữ liệu', p_machine, names ->> m.data_mode, names ->> p_mode, trim(p_reason));
  update master.machines set data_mode = p_mode where id = m.id;
end $$;

-- Hạn giao, ưu tiên từng dòng kế hoạch tháng và ngày bắt đầu lịch: Giám đốc (Kế hoạch tháng: Giám đốc A, R)
create or replace function app.kh_set_line(p_line uuid, p_due date, p_priority smallint) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if not core.has_role('BGD') then raise exception 'Chỉ Giám đốc đặt hạn giao trong kế hoạch tháng'; end if;
  if p_priority not in (0, 1) then raise exception 'Ưu tiên không hợp lệ'; end if;
  update plan.plan_lines set due_date = p_due, priority = p_priority where id = p_line;
  if not found then raise exception 'Không tìm thấy dòng kế hoạch'; end if;
end $$;

create or replace function app.kh_set_sched_start(p_plan uuid, p_date date) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if not core.has_role('BGD') then raise exception 'Chỉ Giám đốc đặt ngày bắt đầu chạy'; end if;
  if exists (select 1 from plan.schedule_versions where plan_id = p_plan) then
    raise exception 'Đã có lịch máy cho kế hoạch này: không đổi được ngày bắt đầu';
  end if;
  if extract(isodow from p_date) = 7 then raise exception 'Ngày bắt đầu không được là Chủ nhật'; end if;
  update plan.production_plans set sched_start = p_date where id = p_plan;
end $$;

-- Lưu một phiên bản lịch máy (Quản lý SX hoặc Giám đốc). Thứ tự thời gian do bộ xếp lịch phía web tính.
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
  insert into plan.schedule_orders (version_id, plan_line_id, label, product_code, product_name, group_code, qty_m, due_date, priority, source, finish_date)
  select v_id, (e->>'plan_line_id')::uuid, e->>'label', e->>'product_code', e->>'product_name', e->>'group_code', (e->>'qty_m')::numeric,
         nullif(e->>'due_date', '')::date, coalesce((e->>'priority')::smallint, 1), e->>'source', nullif(e->>'finish_date', '')::date
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

-- Phát lệnh ngày: Quản lý SX. Tạo phiếu lĩnh cả ca, báo Kế toán kho và Giám đốc.
create or replace function app.kh_release_day(p_plan uuid, p_date date, p_note text, p_checks jsonb, p_slip jsonb) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare pp plan.production_plans; v_ver uuid; v_rev integer; v_id uuid; v_no text; v_warn integer;
begin
  if not app.kh_has_any(array['SX_TP','SX_KH']) then raise exception 'Chỉ Quản lý SX được phát lệnh ngày'; end if;
  select * into pp from plan.production_plans where id = p_plan;
  if pp.status <> 'APPROVED' then raise exception 'Kế hoạch tháng % chưa được duyệt: chưa phát lệnh ngày được', pp.plan_no; end if;
  if p_date < (now() at time zone 'Asia/Ho_Chi_Minh')::date then raise exception 'Không phát lệnh cho ngày đã qua'; end if;
  select id into v_ver from plan.schedule_versions where plan_id = p_plan and is_current;
  if v_ver is null then raise exception 'Chưa có lịch máy: bấm Xếp lại lịch trước'; end if;
  select count(*) into v_warn from jsonb_array_elements(coalesce(p_checks, '[]')) e where not coalesce((e->>'ok')::boolean, true);
  if v_warn > 0 and coalesce(trim(p_note), '') = '' then raise exception 'Còn % cảnh báo: ghi cách xử lý vào ô ghi chú', v_warn; end if;
  select coalesce(max(revision), 0) + 1 into v_rev from plan.daily_releases where plan_id = p_plan and work_date = p_date;
  insert into plan.daily_releases (plan_id, work_date, revision, version_id, note, checks)
  values (p_plan, p_date, v_rev, v_ver, nullif(trim(p_note), ''), p_checks) returning id into v_id;
  v_no := 'PL-' || to_char(p_date, 'YYMMDD') || '-' || lpad(v_rev::text, 2, '0');
  insert into plan.issue_slips (release_id, slip_no, work_date, lines) values (v_id, v_no, p_date, coalesce(p_slip, '[]'));
  perform app.kh_notify_role('KT_KHO', 'Phiếu lĩnh ' || v_no || ' chờ duyệt', 'Lệnh ngày ' || to_char(p_date, 'DD/MM') || case when v_rev > 1 then ' (bản ' || v_rev || ')' else '' end || ' đã phát.', '/lenh-ngay?d=' || p_date);
  perform app.kh_notify_role('BGD', 'Đã phát lệnh ngày ' || to_char(p_date, 'DD/MM') || case when v_rev > 1 then ' bản ' || v_rev else '' end, nullif(trim(p_note), ''), '/lenh-ngay?d=' || p_date);
  return v_id;
end $$;

create or replace function app.kh_approve_slip(p_slip uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare s plan.issue_slips;
begin
  if not core.has_role('KT_KHO') then raise exception 'Chỉ Kế toán kho được duyệt phiếu lĩnh'; end if;
  select * into s from plan.issue_slips where id = p_slip for update;
  if not found then raise exception 'Không tìm thấy phiếu lĩnh'; end if;
  if s.status = 'APPROVED' then raise exception 'Phiếu đã duyệt'; end if;
  update plan.issue_slips set status = 'APPROVED', approved_by = auth.uid(), approved_at = now() where id = p_slip;
  perform app.kh_notify_role('THU_KHO', 'Phiếu lĩnh ' || s.slip_no || ' đã duyệt', 'Xuất kho đầu ca ' || to_char(s.work_date, 'DD/MM') || ' theo phiếu.', '/lenh-ngay?d=' || s.work_date);
end $$;

-- Đơn phát sinh
create or replace function app.kh_create_change(p_plan uuid, p_payload jsonb, p_result jsonb, p_level text, p_steps jsonb) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid; v_no text; v_steps jsonb;
begin
  if not app.kh_has_any(array['SX_TP','SX_KH']) then raise exception 'Chỉ Quản lý SX lập đề nghị đơn phát sinh'; end if;
  if p_level not in ('A','B','C') then raise exception 'Mức không hợp lệ'; end if;
  select core.next_no('DPS', 3) into v_no;
  -- bước 1 (lập) ghi ngay người lập
  v_steps := jsonb_set(p_steps, '{0}', (p_steps->0) || jsonb_build_object('done_by', auth.uid(), 'done_name', app.user_name(auth.uid()), 'done_at', now()));
  insert into plan.change_requests (plan_id, req_no, payload, result, level, steps, status)
  values (p_plan, v_no, p_payload, p_result, p_level, v_steps, case when jsonb_array_length(v_steps) = 1 then 'READY' else 'PENDING' end)
  returning id into v_id;
  if jsonb_array_length(v_steps) > 1 then
    perform app.kh_notify_role(v_steps->1->>'role', 'Đơn phát sinh ' || v_no || ' chờ bạn', v_steps->1->>'label', '/lich-may?tab=phatsinh');
  end if;
  return v_id;
end $$;

-- Duyệt / trả lại một bước. Không ai duyệt bước của đề nghị mình lập hoặc mình đã làm bước trước.
create or replace function app.kh_change_step(p_req uuid, p_action text, p_comment text default null) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare c plan.change_requests; i integer; n integer; st jsonb; v_role text;
begin
  select * into c from plan.change_requests where id = p_req for update;
  if not found then raise exception 'Không tìm thấy đề nghị'; end if;
  if c.status <> 'PENDING' then raise exception 'Đề nghị không còn chờ duyệt'; end if;
  n := jsonb_array_length(c.steps);
  select min(ord - 1) into i from jsonb_array_elements(c.steps) with ordinality a(e, ord) where e->>'done_at' is null;
  if i is null then raise exception 'Đề nghị đã đủ bước'; end if;
  st := c.steps->i; v_role := st->>'role';
  if not core.has_role(v_role) then raise exception 'Bước này chờ %', st->>'label'; end if;
  if v_role <> 'SX_TP' and (c.created_by = auth.uid() or exists (select 1 from jsonb_array_elements(c.steps) e where e->>'done_by' = auth.uid()::text)) then
    raise exception 'Bạn đã lập hoặc đã làm bước trước của đề nghị này: không tự duyệt được';
  end if;
  if p_action = 'return' then
    if coalesce(trim(p_comment), '') = '' then raise exception 'Nhập lý do trả lại'; end if;
    update plan.change_requests set status = 'RETURNED', note = trim(p_comment), finished_at = now(),
      steps = jsonb_set(steps, array[i::text], st || jsonb_build_object('done_by', auth.uid(), 'done_name', app.user_name(auth.uid()), 'done_at', now(), 'result', 'Trả lại'))
    where id = p_req;
    insert into wf.notifications (user_id, title, body, link) values (c.created_by, 'Đơn phát sinh ' || c.req_no || ' bị trả lại', trim(p_comment), '/lich-may?tab=phatsinh');
    return 'RETURNED';
  end if;
  update plan.change_requests set
    steps = jsonb_set(steps, array[i::text], st || jsonb_build_object('done_by', auth.uid(), 'done_name', app.user_name(auth.uid()), 'done_at', now(), 'result', 'Đồng ý', 'comment', nullif(trim(coalesce(p_comment, '')), ''))),
    status = case when i = n - 1 then 'READY' else 'PENDING' end
  where id = p_req;
  if i < n - 1 then
    perform app.kh_notify_role(c.steps->(i + 1)->>'role', 'Đơn phát sinh ' || c.req_no || ' chờ bạn', c.steps->(i + 1)->>'label', '/lich-may?tab=phatsinh');
    return 'PENDING';
  end if;
  return 'READY';
end $$;

-- Sau bước duyệt cuối: thêm dòng vào kế hoạch tháng (người áp dụng là người duyệt cuối hoặc Quản lý SX với mức A)
create or replace function app.kh_change_add_line(p_req uuid) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare c plan.change_requests; p master.products; v_line uuid; v_last text;
begin
  select * into c from plan.change_requests where id = p_req for update;
  if c.status = 'LINE_ADDED' then return c.new_line_id; end if;
  if c.status <> 'READY' then raise exception 'Đề nghị chưa đủ bước duyệt'; end if;
  v_last := c.steps->(jsonb_array_length(c.steps) - 1)->>'role';
  if not core.has_role(v_last) and not app.kh_has_any(array['SX_TP','SX_KH']) then raise exception 'Không có quyền áp dụng đề nghị'; end if;
  select * into p from master.products where code = c.payload->>'product_code';
  if p.current_spec_id is null then raise exception 'Mã % chưa có spec', c.payload->>'product_code'; end if;
  insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, run_lots, m_per_pack, pack_type, brand, wo_note, due_date, priority, change_request_id)
  values (c.plan_id, p.id, p.current_spec_id, (c.payload->>'qty_m')::numeric, 1, coalesce(p.default_m_per_pack, 500),
          coalesce(p.default_pack, 'Bobin gỗ'), coalesce(p.default_brand, 'KAVIX'),
          'Đơn phát sinh ' || c.req_no || coalesce(' · ' || nullif(c.payload->>'so', ''), ''),
          (c.payload->>'due_date')::date, case when c.payload->>'priority' = '0' then 0 else 1 end, c.id)
  returning id into v_line;
  update plan.change_requests set status = 'LINE_ADDED', new_line_id = v_line where id = p_req;
  update plan.production_plans set mrp_stale = true where id = c.plan_id;
  perform app.kh_notify_role(r, 'Đơn phát sinh ' || c.req_no || ' đã duyệt (mức ' || c.level || ')',
    (c.payload->>'product_code') || ' · ' || (c.payload->>'qty_m') || ' m · hạn ' || to_char((c.payload->>'due_date')::date, 'DD/MM')
      || '. Kế hoạch tháng thêm dòng mới, cần chạy lại nhu cầu vật tư.', '/lich-may?tab=phatsinh')
  from unnest(array['BGD','MUA_TP','KT_TP','KT_GT']) r;
  return v_line;
end $$;

-- Báo cáo ca: lưu nháp (vận hành, tổ trưởng, quản lý SX)
create or replace function app.kh_save_report(p_date date, p_machine text, p jsonb) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r mfg.shift_reports; v_id uuid;
begin
  if not app.kh_has_any(array['VAN_HANH','TO_TRUONG','SX_TP']) then raise exception 'Chỉ người vận hành, tổ trưởng, Quản lý SX nhập báo cáo ca'; end if;
  select * into r from mfg.shift_reports where work_date = p_date and shift_code = coalesce(p->>'shift_code', 'A') and machine_code = p_machine for update;
  if found and r.status <> 'DRAFT' then raise exception 'Báo cáo ca đã gửi hoặc đã xác nhận: không sửa được'; end if;
  insert into mfg.shift_reports as t (work_date, shift_code, machine_code, operator_code, plan_id, source, lines, downtime, samples,
                                      scrap_kg, scrap_reason, note, saved_by, saved_at)
  values (p_date, coalesce(p->>'shift_code', 'A'), p_machine, p->>'operator_code', nullif(p->>'plan_id', '')::uuid,
          coalesce(p->>'source', 'MANUAL'), coalesce(p->'lines', '[]'), coalesce(p->'downtime', '[]'),
          coalesce(p->'samples', '[]'),
          coalesce((p->>'scrap_kg')::numeric, 0), p->>'scrap_reason', p->>'note', auth.uid(), now())
  on conflict (work_date, shift_code, machine_code) do update set
    operator_code = excluded.operator_code, plan_id = excluded.plan_id, source = excluded.source, lines = excluded.lines,
    downtime = excluded.downtime, scrap_kg = excluded.scrap_kg, scrap_reason = excluded.scrap_reason, note = excluded.note,
    samples = case when jsonb_array_length(t.samples) = 0 then excluded.samples else t.samples end,
    saved_by = auth.uid(), saved_at = now()
  returning id into v_id;
  return v_id;
end $$;

create or replace function app.kh_submit_report(p_id uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r mfg.shift_reports; v_min integer;
begin
  if not app.kh_has_any(array['VAN_HANH','TO_TRUONG','SX_TP']) then raise exception 'Không có quyền gửi báo cáo ca'; end if;
  select * into r from mfg.shift_reports where id = p_id for update;
  if r.status <> 'DRAFT' then raise exception 'Báo cáo đã gửi'; end if;
  select downtime_reason_min into v_min from master.planning_config where id = 1;
  if exists (select 1 from jsonb_array_elements(r.downtime) e where coalesce(e->>'reason', '') = '' and (e->>'min')::numeric > v_min) then
    raise exception 'Còn lần dừng máy trên % phút chưa chọn lý do', v_min;
  end if;
  if exists (select 1 from jsonb_array_elements(r.samples) e where e->>'status' <> 'OK') then
    raise exception 'Mẫu đầu ca/đầu mã chưa đạt: chưa gửi được báo cáo ca';
  end if;
  update mfg.shift_reports set status = 'SUBMITTED', submitted_by = auth.uid(), submitted_at = now() where id = p_id;
  perform app.kh_notify_role('TO_TRUONG', 'Báo cáo ca ' || r.machine_code || ' chờ xác nhận', to_char(r.work_date, 'DD/MM') || ' · ca ' || r.shift_code, '/ghi-nhan-ca?d=' || r.work_date || '&m=' || r.machine_code);
end $$;

create or replace function app.kh_confirm_report(p_id uuid, p_note text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r mfg.shift_reports; v_dev numeric;
begin
  if not app.kh_has_any(array['TO_TRUONG','SX_TP']) then raise exception 'Chỉ Quản lý SX / tổ trưởng (hoặc tổ phó được ủy quyền) xác nhận ca'; end if;
  select * into r from mfg.shift_reports where id = p_id for update;
  if r.status <> 'SUBMITTED' then raise exception 'Báo cáo chưa gửi hoặc đã xác nhận'; end if;
  select plc_dev_pct into v_dev from master.planning_config where id = 1;
  if r.source = 'BOTH' and exists (select 1 from jsonb_array_elements(r.lines) e
       where coalesce((e->>'plc_m')::numeric, 0) > 0
         and abs((e->>'declared_m')::numeric - (e->>'plc_m')::numeric) / (e->>'plc_m')::numeric * 100 > v_dev)
     and coalesce(trim(p_note), '') = '' then
    raise exception 'Mét khai báo lệch PLC trên % %%: cần ghi giải trình', v_dev;
  end if;
  update mfg.shift_reports set status = 'CONFIRMED', confirmed_by = auth.uid(), confirmed_at = now(),
    note = coalesce(nullif(trim(coalesce(p_note, '')), ''), note) where id = p_id;
end $$;

create or replace function app.kh_reopen_report(p_id uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if not app.kh_has_any(array['TO_TRUONG','SX_TP']) then raise exception 'Không có quyền trả lại báo cáo ca'; end if;
  update mfg.shift_reports set status = 'DRAFT' where id = p_id and status = 'SUBMITTED';
  if not found then raise exception 'Chỉ trả lại được báo cáo đang chờ xác nhận'; end if;
end $$;

-- Mẫu đầu ca / đầu mã: TP Kỹ thuật/QA hoặc QC. p_samples là danh sách mẫu cần có của ca (tạo khi chưa có)
create or replace function app.kh_sample(p_date date, p_machine text, p_samples jsonb, p_index integer, p_result text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r mfg.shift_reports; s jsonb;
begin
  if not app.kh_has_any(array['KT_TP','QC']) then raise exception 'Chỉ TP Kỹ thuật/QA hoặc QC duyệt mẫu'; end if;
  if p_result not in ('OK','NG') then raise exception 'Kết quả không hợp lệ'; end if;
  insert into mfg.shift_reports as t (work_date, shift_code, machine_code, samples) values (p_date, 'A', p_machine, coalesce(p_samples, '[]'))
  on conflict (work_date, shift_code, machine_code) do update set
    samples = case when jsonb_array_length(t.samples) = 0 then excluded.samples else t.samples end;
  select * into r from mfg.shift_reports where work_date = p_date and shift_code = 'A' and machine_code = p_machine for update;
  if r.status = 'CONFIRMED' then raise exception 'Ca đã xác nhận'; end if;
  s := r.samples -> p_index;
  if s is null then raise exception 'Không tìm thấy mẫu'; end if;
  update mfg.shift_reports set samples = jsonb_set(samples, array[p_index::text],
    s || jsonb_build_object('status', p_result, 'by_name', app.user_name(auth.uid()), 'at', to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI')))
  where id = r.id;
end $$;

-- ---------------------------------------------------------------------------
-- 7. View đọc cho web app
-- ---------------------------------------------------------------------------
create or replace view app.v_kh_config with (security_invoker = true) as
select c.*, (select jsonb_agg(to_jsonb(s) order by s.code) from master.shifts s) as shifts,
       (select jsonb_agg(to_jsonb(r) order by r.sort) from master.machine_rates r) as rates,
       (select jsonb_agg(to_jsonb(x) order by x.sort) from master.changeover_rules x) as changeovers
from master.planning_config c where c.id = 1;

create or replace view app.v_kh_machines with (security_invoker = true) as
select m.id, m.code, m.name, m.machine_type, m.protocol, m.data_mode, m.active,
       (select count(*) from iot.machine_tags t where t.machine_id = m.id) as tag_count,
       (select max(s.ts) from iot.machine_state s where s.machine_id = m.id) as last_seen,
       coalesce((select array_agg(k.operator_code order by k.operator_code) from master.operator_skills k
                 where k.machine_code = m.code and k.level = 'MAIN'), '{}') as operators
from master.machines m
where m.machine_type in ('BUNCHER','EXTRUDER_SI','TWISTER','EXTRUDER_TP') and m.active;

create or replace view app.v_kh_operators with (security_invoker = true) as
select o.*, app.user_name(o.profile_id) as profile_name,
       coalesce((select array_agg(k.machine_code order by k.machine_code) from master.operator_skills k where k.operator_code = o.code and k.level = 'MAIN'), '{}') as skills,
       coalesce((select array_agg(k.machine_code order by k.machine_code) from master.operator_skills k where k.operator_code = o.code and k.level = 'LEARNING'), '{}') as learning
from master.operators o where o.active;

create or replace view app.v_kh_param_log with (security_invoker = true) as
select l.*, app.user_name(l.user_id) as user_name from master.planning_param_log l;

-- Dòng kế hoạch kèm thông tin để xếp lịch (lõi, màu, cỡ, chống nhiễu, vỏ)
create or replace view app.v_kh_plan_lines with (security_invoker = true) as
select l.id, l.plan_id, l.product_id, l.qty_m, l.due_date, l.priority, l.change_request_id, l.wo_note, l.so_line_id,
       pp.plan_no, pp.status as plan_status, pp.sched_start,
       p.code as product_code, p.description as product_name, p.group_code,
       s.cores, s.pairs, s.insulation, s.sheath, s.shield, s.sheath_color, s.insulation_colors, l.single_color, s.status as spec_status,
       coalesce(ct.nominal_mm2, 0) as size_mm2,
       (select cr.core_colors from master.color_rules cr where cr.group_code = p.group_code and cr.cores = s.cores) as core_colors,
       (select array_agg(r.op_code order by o.seq) from master.routings r join master.operations o on o.code = r.op_code where r.group_code = p.group_code) as route,
       (select so.so_no from sales.so_lines sl join sales.sales_orders so on so.id = sl.so_id where sl.id = l.so_line_id) as so_no,
       row_number() over (partition by l.plan_id order by l.id) as line_no
from plan.plan_lines l
join plan.production_plans pp on pp.id = l.plan_id
join master.products p on p.id = l.product_id
join master.product_specs s on s.id = l.spec_id
left join master.core_types ct on ct.set_id = s.param_set_id and ct.code = s.core_code;

create or replace view app.v_kh_versions with (security_invoker = true) as
select v.id, v.plan_id, v.version, v.is_current, v.base_date, v.params, v.reason, v.created_at, app.user_name(v.created_by) as created_by_name,
       v.change_request_id, (select c.req_no from plan.change_requests c where c.id = v.change_request_id) as change_no
from plan.schedule_versions v;

create or replace view app.v_kh_orders with (security_invoker = true) as select * from plan.schedule_orders;
create or replace view app.v_kh_slots with (security_invoker = true) as select * from plan.schedule_slots;

create or replace view app.v_kh_releases with (security_invoker = true) as
select r.*, app.user_name(r.released_by) as released_by_name,
       s.id as slip_id, s.slip_no, s.lines as slip_lines, s.status as slip_status, s.approved_at, app.user_name(s.approved_by) as approved_by_name
from plan.daily_releases r left join plan.issue_slips s on s.release_id = r.id;

create or replace view app.v_kh_changes with (security_invoker = true) as
select c.*, app.user_name(c.created_by) as created_by_name from plan.change_requests c;

create or replace view app.v_kh_reports with (security_invoker = true) as
select r.*, app.user_name(r.submitted_by) as submitted_by_name, app.user_name(r.confirmed_by) as confirmed_by_name
from mfg.shift_reports r;

grant select on app.v_kh_config, app.v_kh_machines, app.v_kh_operators, app.v_kh_param_log, app.v_kh_plan_lines, app.v_kh_versions,
  app.v_kh_orders, app.v_kh_slots, app.v_kh_releases, app.v_kh_changes, app.v_kh_reports to authenticated, service_role;
revoke all on function app.kh_can_view(), app.kh_has_any(text[]), app.kh_notify_role(text, text, text, text), app.kh_log(text, text, text, text, text),
  app.kh_save_config(jsonb, text), app.kh_save_shifts(jsonb, text), app.kh_save_rates(jsonb, text), app.kh_save_changeovers(jsonb, text),
  app.kh_set_machine_mode(text, text, text), app.kh_set_line(uuid, date, smallint), app.kh_set_sched_start(uuid, date),
  app.kh_save_schedule(uuid, date, jsonb, jsonb, jsonb, text, uuid), app.kh_release_day(uuid, date, text, jsonb, jsonb),
  app.kh_approve_slip(uuid), app.kh_create_change(uuid, jsonb, jsonb, text, jsonb), app.kh_change_step(uuid, text, text),
  app.kh_change_add_line(uuid), app.kh_save_report(date, text, jsonb), app.kh_submit_report(uuid), app.kh_confirm_report(uuid, text),
  app.kh_reopen_report(uuid), app.kh_sample(date, text, jsonb, integer, text) from public, anon;
grant execute on function app.kh_can_view(), app.kh_has_any(text[]),
  app.kh_save_config(jsonb, text), app.kh_save_shifts(jsonb, text), app.kh_save_rates(jsonb, text), app.kh_save_changeovers(jsonb, text),
  app.kh_set_machine_mode(text, text, text), app.kh_set_line(uuid, date, smallint), app.kh_set_sched_start(uuid, date),
  app.kh_save_schedule(uuid, date, jsonb, jsonb, jsonb, text, uuid), app.kh_release_day(uuid, date, text, jsonb, jsonb),
  app.kh_approve_slip(uuid), app.kh_create_change(uuid, jsonb, jsonb, text, jsonb), app.kh_change_step(uuid, text, text),
  app.kh_change_add_line(uuid), app.kh_save_report(date, text, jsonb), app.kh_submit_report(uuid), app.kh_confirm_report(uuid, text),
  app.kh_reopen_report(uuid), app.kh_sample(date, text, jsonb, integer, text) to authenticated, service_role;
