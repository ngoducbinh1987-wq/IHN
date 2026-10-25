-- BMT MES · 2300 · Module Quản lý máy
-- Duyệt 25/10/2026 (bản thiết kế lần 2, đã đối chiếu "Quy chuẩn vai trò & nhiệm vụ nhân sự nhà máy BMT"):
--   * Dây chuyền và máy con dùng chung master.machines (cột inline_with = thuộc dây chuyền).
--   * Thông số, linh kiện, dải hoạt động, tốc độ theo sản phẩm, người đứng máy, tài liệu: người dùng tự khai báo.
--   * Bảo dưỡng: chu kỳ theo ngày / giờ chạy / km do người dùng đặt; nhắc trên thông báo trước 7 ngày (bảo dưỡng nhỏ),
--     trước 30 ngày (bảo dưỡng lớn); checklist đầu ca; phiếu bảo dưỡng (BD) và sửa chữa (SC).
--   * Ca làm việc 08:00–12:00, 13:00–17:00; có tăng ca, thêm ca. Ca, tỷ lệ xếp lịch, số máy một người đứng dùng chung
--     với module Kế hoạch sản xuất (master.shifts ca A, master.planning_config), Giám đốc sửa.
--   * Kiểm tra năng lực kế hoạch theo tốc độ, tình trạng máy, bảo dưỡng, người đứng máy.
--   * Email báo cáo bảo trì bảo dưỡng hằng tháng cho Ban giám đốc (Giám đốc, Chủ tịch).
-- Không tạo schema mới: dùng master (khai báo) và mfg (vận hành) đã mở cho Data API.

-- ===========================================================================
-- 1. Quyền: phân hệ "machine"
-- ===========================================================================
insert into core.permissions (module, action)
select 'machine', a from unnest(array['view','create','edit','approve','export','config']) a
on conflict do nothing;

create temporary table _rp (role_code text, acts text);
insert into _rp values
  ('ADMIN','view,create,edit,approve,export,config'),
  ('BGD','view,approve,export'),
  ('KT_TP','view,create,edit,approve,export,config'),
  ('KT_NV','view,create,edit'), ('QC','view,create,edit'),
  ('SX_TP','view,create,edit,export'), ('SX_KH','view,export'),
  ('TO_TRUONG','view,create,edit'), ('VAN_HANH','view,create'),
  ('THU_KHO','view'), ('KHO_NV','view'), ('KT_KHO','view'), ('KT_GT','view'), ('KTT','view'),
  ('MUA_NV','view'), ('MUA_TP','view');
insert into core.role_permissions (role_code, module, action)
select r.role_code, 'machine', a from _rp r, unnest(string_to_array(r.acts, ',')) a
where exists (select 1 from core.roles where code = r.role_code)
on conflict do nothing;
drop table _rp;

-- ===========================================================================
-- 2. Máy: thêm cột cho dây chuyền / máy con
-- ===========================================================================
do $$
declare c text;
begin
  for c in select conname from pg_constraint where conrelid = 'master.machines'::regclass and contype = 'c'
           and pg_get_constraintdef(oid) like '%machine_type%' loop
    execute format('alter table master.machines drop constraint %I', c);
  end loop;
end $$;
alter table master.machines add constraint machines_machine_type_check check (machine_type in
  ('MIXER','BUNCHER','EXTRUDER_SI','EXTRUDER_TP','TWISTER','TAPER','PRINTER','GAUGE','TESTER','PACKER','OTHER'));

alter table master.machines
  add column if not exists op_code      text references master.operations(code),
  add column if not exists seq          smallint not null default 0,
  add column if not exists critical     boolean not null default false,   -- máy con quan trọng: hỏng là dừng cả dây chuyền
  add column if not exists unit_kind    text,                              -- loại máy con do người dùng đặt (lò lưu hóa, máy kéo…)
  add column if not exists vendor       text,
  add column if not exists model        text,
  add column if not exists serial_no    text,
  add column if not exists year_made    smallint,
  add column if not exists location     text,
  add column if not exists note         text,
  add column if not exists status       text not null default 'IDLE',
  add column if not exists status_since timestamptz not null default now(),
  add column if not exists status_note  text,
  add column if not exists status_eta   timestamptz;                      -- giờ dự kiến chạy lại khi hỏng / bảo dưỡng
do $$ begin
  alter table master.machines add constraint machines_status_check check (status in ('RUN','IDLE','STOP','MAINT','DOWN','OFF'));
exception when duplicate_object then null; end $$;
create index if not exists machines_inline_idx on master.machines (inline_with);

update master.machines set op_code = case machine_type when 'BUNCHER' then 'CD1' when 'EXTRUDER_SI' then 'CD2'
                                                 when 'TWISTER' then 'CD3' when 'EXTRUDER_TP' then 'CD5' end
 where op_code is null and inline_with is null and machine_type in ('BUNCHER','EXTRUDER_SI','TWISTER','EXTRUDER_TP');
update master.machines set unit_kind = 'Máy in', seq = 50 where code = 'PRN-01' and unit_kind is null;
update master.machines set unit_kind = 'Máy đo OD', seq = 60 where code = 'GAU-01' and unit_kind is null;

-- Công đoạn tính theo từng lõi (bện ruột, bọc cách điện): mét cần chạy = mét cáp × số lõi
alter table master.operations add column if not exists per_core boolean not null default false;
update master.operations set per_core = true where code in ('CD1','CD2');
-- Quấn băng AL/PET là thành phần của máy xoắn, không tách rời (chốt 25/10/2026)
update master.operations set machine_type = 'TWISTER' where code = 'CD4';

insert into master.reason_codes (code, kind, name, planned) values
  ('DT_PM', 'DOWNTIME', 'Bảo dưỡng định kỳ', true),
  ('DT_NOPEOPLE', 'DOWNTIME', 'Thiếu người vận hành', false),
  ('DT_OTHER', 'DOWNTIME', 'Lý do khác', false)
on conflict (code) do nothing;

-- ===========================================================================
-- 3. Khai báo máy (người dùng tự khai báo)
-- ===========================================================================
create table if not exists master.machine_settings (
  key   text primary key,
  label text not null,
  value jsonb not null
);
select core.add_audit_cols('master.machine_settings');
insert into master.machine_settings (key, label, value) values
  -- Chỉ lưu ngày làm việc; giờ ca, tỷ lệ xếp lịch lấy từ master.shifts (ca A) và master.planning_config (xem mfg.machine_setting)
  ('shift', 'Ngày làm việc trong tuần', '{"workdays":[1,2,3,4,5,6]}'),
  ('remind_days', 'Nhắc trước khi đến hạn bảo dưỡng (ngày)', '{"MINOR":7,"MAJOR":30}'),
  ('speed_deviation', 'Đề xuất sửa tốc độ chuẩn khi lệch', '{"pct":10,"shifts":10}'),
  ('report_roles', 'Vai trò nhận email báo cáo bảo trì tháng', '["BGD"]'),
  ('remind_roles', 'Vai trò nhận nhắc bảo dưỡng', '["KT_TP","SX_TP"]'),
  ('overdue_roles', 'Vai trò nhận cảnh báo quá hạn, máy hỏng', '["KT_TP","SX_TP","BGD"]')
on conflict (key) do nothing;

create table if not exists master.machine_specs (
  id         uuid primary key default gen_random_uuid(),
  machine_id uuid not null references master.machines(id) on delete cascade,
  grp        text not null,
  label      text not null,
  value      text,
  uom        text,
  source     text check (source in ('NSX','BMT','GD')),   -- nhà sản xuất / hồ sơ BMT / giả định
  sort       int not null default 0,
  unique (machine_id, grp, label)
);
select core.add_audit_cols('master.machine_specs');
select core.enable_audit('master.machine_specs');

create table if not exists master.machine_components (
  id          uuid primary key default gen_random_uuid(),
  machine_id  uuid not null references master.machines(id) on delete cascade,
  kind        text not null check (kind in ('SENSOR','MOTOR','DRIVE','GEARBOX','GEAR','BEARING','FITTING','CONTROL','SPARE','OTHER')),
  name        text not null,
  spec        text,
  qty         numeric,
  position    text,
  material_id uuid references master.materials(id),
  min_stock   numeric,
  note        text
);
select core.add_audit_cols('master.machine_components');
create index if not exists machine_components_m_idx on master.machine_components (machine_id);

create table if not exists master.machine_ranges (
  id          uuid primary key default gen_random_uuid(),
  machine_id  uuid not null references master.machines(id) on delete cascade,
  param       text not null default 'OTHER' check (param in ('SIZE_MM2','OD_MM','SPEED_MPM','CORES','TEMP_C','OTHER')),
  label       text not null,
  min_value   numeric,
  max_value   numeric,
  text_value  text,
  uom         text,
  source      text check (source in ('NSX','BMT','GD')),
  sort        int not null default 0,
  unique (machine_id, label)
);
select core.add_audit_cols('master.machine_ranges');

-- Tốc độ sản xuất theo máy × công đoạn × sản phẩm. Thứ tự chọn: mã SP → nhóm + mã lõi → mã lõi → nhóm → mặc định máy
create table if not exists master.machine_speeds (
  id            uuid primary key default gen_random_uuid(),
  machine_id    uuid not null references master.machines(id) on delete cascade,
  op_code       text not null references master.operations(code),
  product_id    uuid references master.products(id),
  group_code    text references master.product_groups(code),
  core_code     text,
  label         text,
  rated_mpm     numeric check (rated_mpm > 0),          -- danh định nhà sản xuất
  std_mpm       numeric not null check (std_mpm > 0),    -- chuẩn dùng lập kế hoạch
  setup_min     numeric not null default 0 check (setup_min >= 0),   -- phút đổi máy mỗi lô
  source        text check (source in ('NSX','BMT','GD')),
  status        text not null default 'PENDING' check (status in ('PENDING','APPROVED','OBSOLETE')),
  submitted_at  timestamptz not null default now(),
  approved_by   uuid references core.profiles(id),
  approved_at   timestamptz,
  temp_approval boolean not null default false,          -- Giám đốc duyệt tạm khi TP Kỹ thuật/QA chưa duyệt sau 1 ngày
  note          text
);
select core.add_audit_cols('master.machine_speeds');
select core.enable_audit('master.machine_speeds');
create unique index if not exists machine_speeds_approved_uq on master.machine_speeds
  (machine_id, op_code, coalesce(product_id::text, ''), coalesce(group_code, ''), coalesce(core_code, ''))
  where status = 'APPROVED';

create table if not exists master.machine_operators (
  id           uuid primary key default gen_random_uuid(),
  machine_id   uuid not null references master.machines(id) on delete cascade,
  person       text not null,                                       -- "NV1 – Nguyễn Văn A"
  profile_id   uuid references core.profiles(id),
  role         text not null default 'PRIMARY' check (role in ('PRIMARY','BACKUP','TRAINEE')),
  certified_at date,                                                -- ngày TP Kỹ thuật/QA ký xác nhận tay nghề
  certified_by uuid references core.profiles(id),
  note         text,
  unique (machine_id, person)
);
select core.add_audit_cols('master.machine_operators');

create table if not exists master.machine_docs (
  id         uuid primary key default gen_random_uuid(),
  machine_id uuid not null references master.machines(id) on delete cascade,
  title      text not null,
  url        text,
  kind       text not null default 'OTHER' check (kind in ('SOP','CHECKLIST','CATALOG','DRAWING','MANUAL','OTHER')),
  status     text not null default 'ISSUED' check (status in ('DRAFT','ISSUED')),
  note       text
);
select core.add_audit_cols('master.machine_docs');

-- ===========================================================================
-- 4. Vận hành: nhật ký trạng thái, bảo dưỡng, checklist đầu ca
-- ===========================================================================
create table if not exists mfg.machine_status_log (
  id          uuid primary key default gen_random_uuid(),
  machine_id  uuid not null references master.machines(id) on delete cascade,
  status      text not null check (status in ('RUN','IDLE','STOP','MAINT','DOWN','OFF')),
  started_at  timestamptz not null default now(),
  ended_at    timestamptz,
  reason_code text references master.reason_codes(code),
  note        text,
  source      text not null default 'TAY' check (source in ('TAY','PLC','HE_THONG')),
  maint_wo_id uuid,
  created_by  uuid default auth.uid()
);
create index if not exists machine_status_log_idx on mfg.machine_status_log (machine_id, started_at desc);

create table if not exists mfg.maint_plans (
  id            uuid primary key default gen_random_uuid(),
  machine_id    uuid not null references master.machines(id) on delete cascade,
  name          text not null,
  kind          text not null default 'INSPECT' check (kind in ('INSPECT','LUBE','CLEAN','REPLACE','CALIB','OTHER')),
  level         text not null default 'MINOR' check (level in ('MINOR','MAJOR')),
  every_days    int check (every_days > 0),
  every_hours   numeric check (every_hours > 0),
  every_km      numeric check (every_km > 0),
  remind_days   int not null default 7 check (remind_days >= 0),
  stop_minutes  int not null default 0 check (stop_minutes >= 0),
  off_shift     boolean not null default false,           -- làm ngoài giờ ca: không trừ năng lực máy
  assignee_role text not null default 'KT_TP',
  steps         text[] not null default '{}',
  parts         text,
  last_done_at  timestamptz not null default now(),       -- mốc tính chu kỳ
  base_hours    numeric not null default 0,               -- giờ chạy đã có trước mốc theo dõi (nhập khi khai báo)
  base_km       numeric not null default 0,
  active        boolean not null default true,
  note          text,
  check (coalesce(every_days::numeric, every_hours, every_km) is not null)
);
select core.add_audit_cols('mfg.maint_plans');
create index if not exists maint_plans_m_idx on mfg.maint_plans (machine_id);

create table if not exists mfg.maint_work_orders (
  id            uuid primary key default gen_random_uuid(),
  wo_no         text unique not null,
  wo_type       text not null check (wo_type in ('PM','CM')),     -- PM bảo dưỡng, CM sửa chữa
  plan_id       uuid references mfg.maint_plans(id) on delete set null,
  machine_id    uuid not null references master.machines(id),
  title         text not null,
  status        text not null default 'OPEN' check (status in ('OPEN','IN_PROGRESS','DONE','CANCELLED')),
  planned_date  date,
  off_shift     boolean not null default false,
  est_minutes   int,
  started_at    timestamptz,
  finished_at   timestamptz,
  eta           timestamptz,                                       -- dự kiến chạy lại (phiếu sửa chữa)
  cause         text,
  action_taken  text,
  result        text check (result in ('OK','NOT_OK')),
  steps         jsonb not null default '[]',                       -- [{"label": "...", "done": true}]
  assignee_role text,
  done_by       uuid references core.profiles(id),
  confirmed_by  uuid references core.profiles(id),
  confirmed_at  timestamptz,
  note          text
);
select core.add_audit_cols('mfg.maint_work_orders');
create index if not exists maint_wo_m_idx on mfg.maint_work_orders (machine_id, status);
do $$ begin
  alter table mfg.machine_status_log add constraint machine_status_log_wo_fk foreign key (maint_wo_id) references mfg.maint_work_orders(id) on delete set null;
exception when duplicate_object then null; end $$;

-- Phụ tùng dùng cho phiếu. Phiếu xuất kho tạo từ đây khi module Kho chạy (Quản lý SX xuất, Kế toán SX duyệt)
create table if not exists mfg.maint_wo_parts (
  id          uuid primary key default gen_random_uuid(),
  wo_id       uuid not null references mfg.maint_work_orders(id) on delete cascade,
  material_id uuid references master.materials(id),
  item        text not null,
  qty         numeric not null check (qty > 0),
  uom         text,
  issued      boolean not null default false,
  note        text
);
select core.add_audit_cols('mfg.maint_wo_parts');

create table if not exists mfg.maint_check_items (
  id         uuid primary key default gen_random_uuid(),
  machine_id uuid references master.machines(id) on delete cascade,   -- trống = mọi dây chuyền
  label      text not null,
  sort       int not null default 0,
  active     boolean not null default true
);
select core.add_audit_cols('mfg.maint_check_items');
insert into mfg.maint_check_items (label, sort)
select l, s from (values ('Vệ sinh máy', 1), ('Tra dầu, mỡ các điểm bôi trơn', 2), ('Kiểm tra áp khí nén', 3), ('Kiểm tra nước làm mát', 4)) v(l, s)
where not exists (select 1 from mfg.maint_check_items where machine_id is null);

create table if not exists mfg.maint_checks (
  id         uuid primary key default gen_random_uuid(),
  machine_id uuid not null references master.machines(id) on delete cascade,
  check_date date not null default (now() at time zone 'Asia/Ho_Chi_Minh')::date,
  results    jsonb not null default '[]',      -- [{"label": "...", "ok": true, "note": "..."}]
  has_issue  boolean not null default false,
  note       text,
  done_by    uuid default auth.uid() references core.profiles(id),
  done_at    timestamptz not null default now(),
  checked_by uuid references core.profiles(id),
  checked_at timestamptz,
  unique (machine_id, check_date)
);

-- Đã gửi nhắc nào (mỗi mốc chỉ nhắc một lần)
create table if not exists mfg.maint_alerts (
  kind       text not null,
  ref_id     uuid not null,
  period_key text not null,
  created_at timestamptz not null default now(),
  primary key (kind, ref_id, period_key)
);

-- ===========================================================================
-- 5. Hàm tính toán
-- ===========================================================================
-- Ca làm việc dùng chung với Kế hoạch sản xuất: ca A (giờ bắt đầu, kết thúc, phút nghỉ giữa ca), tỷ lệ xếp lịch,
-- số máy một người đứng. Nghỉ trưa đặt giữa ca: 08:00–17:00 nghỉ 60 phút → 08:00–12:00 và 13:00–17:00.
create or replace function mfg.shift_setting() returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare a master.shifts; v_fill numeric; v_span int; v_work int; v_half int; v_wd jsonb;
begin
  select * into a from master.shifts where code = 'A';
  select fill_pct into v_fill from master.planning_config where id = 1;
  select value -> 'workdays' into v_wd from master.machine_settings where key = 'shift';
  if a.code is null then
    return jsonb_build_object('sessions', '[["08:00","12:00"],["13:00","17:00"]]'::jsonb, 'minutes', 480,
      'fill', coalesce(v_fill, 85) / 100, 'workdays', coalesce(v_wd, '[1,2,3,4,5,6]'));
  end if;
  v_span := (extract(epoch from (a.end_time - a.start_time + interval '24 hours')) / 60)::int % 1440;
  if v_span = 0 then v_span := 1440; end if;
  v_work := greatest(60, v_span - a.break_min);
  v_half := v_work / 2;
  return jsonb_build_object(
    'sessions', jsonb_build_array(
      jsonb_build_array(to_char(a.start_time, 'HH24:MI'), to_char(a.start_time + make_interval(mins => v_half), 'HH24:MI')),
      jsonb_build_array(to_char(a.start_time + make_interval(mins => v_half + a.break_min), 'HH24:MI'), to_char(a.end_time, 'HH24:MI'))),
    'minutes', v_work, 'break_min', a.break_min,
    'fill', coalesce(v_fill, 85) / 100, 'workdays', coalesce(v_wd, '[1,2,3,4,5,6]'));
end $$;

create or replace function mfg.machine_setting(p_key text) returns jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
  select case p_key
    when 'shift' then mfg.shift_setting()
    when 'max_machines_per_operator' then (select to_jsonb(machines_per_operator) from master.planning_config where id = 1)
    else (select value from master.machine_settings where key = p_key) end
$$;

-- Dây chuyền của một máy (máy con thuộc dây chuyền nào)
create or replace function mfg.line_of(p_machine uuid) returns uuid
language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce(inline_with, id) from master.machines where id = p_machine
$$;

-- Ngày làm việc (theo cài đặt ca, 1 = thứ 2 … 7 = chủ nhật) trong [p_from, p_to]
create or replace function mfg.workdays(p_from date, p_to date) returns int
language sql stable security definer set search_path = pg_catalog, public as $$
  select count(*)::int from generate_series(p_from, p_to, interval '1 day') d
  where extract(isodow from d)::int in (select jsonb_array_elements_text(coalesce(mfg.machine_setting('shift') -> 'workdays', '[1,2,3,4,5,6]'))::int)
$$;

-- Số phút ở một trạng thái trong khoảng thời gian
create or replace function mfg.status_minutes(p_machine uuid, p_status text, p_from timestamptz, p_to timestamptz) returns numeric
language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce(sum(greatest(0, extract(epoch from least(coalesce(ended_at, now()), p_to) - greatest(started_at, p_from)) / 60)), 0)
  from mfg.machine_status_log
  where machine_id = p_machine and status = p_status and started_at < p_to and coalesce(ended_at, now()) > p_from
$$;

-- Giờ chạy, km của dây chuyền từ một mốc: PLC (telemetry_1m) → báo cáo công đoạn (wo_operations) → nhật ký trạng thái "Đang chạy"
create or replace function mfg.machine_usage(p_line uuid, p_since timestamptz, out hours numeric, out km numeric)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare t_h numeric; t_km numeric; w_h numeric; w_km numeric;
begin
  select coalesce(sum(run_seconds), 0) / 3600.0, coalesce(sum(meters), 0) / 1000.0 into t_h, t_km
    from iot.telemetry_1m where machine_id = p_line and bucket >= p_since;
  select coalesce(sum(run_minutes), 0) / 60.0, coalesce(sum(good_m), 0) / 1000.0 into w_h, w_km
    from mfg.wo_operations where machine_id = p_line and coalesce(ended_at, started_at) >= p_since;
  hours := case when t_h > 0 then t_h when w_h > 0 then w_h else mfg.status_minutes(p_line, 'RUN', p_since, now()) / 60.0 end;
  km := case when t_km > 0 then t_km else w_km end;
end $$;

-- Giờ chạy, km trung bình mỗi ngày làm việc (30 ngày gần nhất); chưa có dữ liệu thì lấy theo ca
create or replace function mfg.machine_daily_rate(p_line uuid, out hours_per_day numeric, out km_per_day numeric)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare u record; d int; s jsonb := mfg.machine_setting('shift'); v_std numeric;
begin
  select * into u from mfg.machine_usage(p_line, now() - interval '30 days');
  d := greatest(1, mfg.workdays(((now() at time zone 'Asia/Ho_Chi_Minh') - interval '30 days')::date, (now() at time zone 'Asia/Ho_Chi_Minh')::date));
  hours_per_day := case when u.hours / d >= 0.5 then u.hours / d
                        else coalesce((s ->> 'minutes')::numeric, 480) * coalesce((s ->> 'fill')::numeric, 0.85) / 60 end;
  if u.km / d > 0.05 then km_per_day := u.km / d;
  else
    select avg(std_mpm) into v_std from master.machine_speeds where machine_id = p_line and status <> 'OBSOLETE';
    km_per_day := case when v_std is null then null else hours_per_day * 60 * v_std / 1000 end;
  end if;
end $$;

-- Tình trạng một kế hoạch bảo dưỡng: đã dùng, còn lại, ngày đến hạn dự kiến, mức nhắc
create or replace function mfg.maint_plan_state(p_plan uuid,
  out used_days numeric, out used_hours numeric, out used_km numeric,
  out days_left numeric, out due_date date, out trigger text, out state text, out open_wo uuid, out open_wo_no text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare p mfg.maint_plans; u record; r record; v_today date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
        v_left numeric; v_per_week numeric; v_wd int;
begin
  select * into p from mfg.maint_plans where id = p_plan;
  if not found then return; end if;
  select * into u from mfg.machine_usage(mfg.line_of(p.machine_id), p.last_done_at);
  select * into r from mfg.machine_daily_rate(mfg.line_of(p.machine_id));
  v_wd := greatest(1, jsonb_array_length(coalesce(mfg.machine_setting('shift') -> 'workdays', '[1,2,3,4,5,6]')));
  v_per_week := 7.0 / v_wd;                                   -- đổi ngày làm việc ra ngày lịch
  used_days := v_today - (p.last_done_at at time zone 'Asia/Ho_Chi_Minh')::date;
  used_hours := round(p.base_hours + u.hours, 1);
  used_km := round(p.base_km + u.km, 1);
  days_left := null;
  if p.every_days is not null then
    days_left := p.every_days - used_days; trigger := 'DAYS';
  end if;
  if p.every_hours is not null then
    v_left := (p.every_hours - used_hours) / greatest(r.hours_per_day, 0.1) * v_per_week;
    if days_left is null or v_left < days_left then days_left := v_left; trigger := 'HOURS'; end if;
  end if;
  if p.every_km is not null and r.km_per_day is not null then
    v_left := (p.every_km - used_km) / greatest(r.km_per_day, 0.01) * v_per_week;
    if days_left is null or v_left < days_left then days_left := v_left; trigger := 'KM'; end if;
  elsif p.every_km is not null and days_left is null then
    days_left := case when used_km > p.every_km then -1 else 9999 end; trigger := 'KM';
  end if;
  days_left := round(days_left, 1);
  due_date := v_today + greatest(-3650, least(3650, floor(days_left)))::int;
  state := case
    when (p.every_days is not null and used_days > p.every_days) or (p.every_hours is not null and used_hours > p.every_hours)
      or (p.every_km is not null and used_km > p.every_km) then 'OVERDUE'
    when days_left < 1 then 'DUE'
    when days_left <= p.remind_days then 'SOON'
    else 'OK' end;
  select id, wo_no into open_wo, open_wo_no from mfg.maint_work_orders
   where plan_id = p.id and status in ('OPEN','IN_PROGRESS') order by created_at desc limit 1;
end $$;

-- Gửi thông báo trong app (không email) cho người có các vai trò
create or replace function mfg.notify_roles(p_roles text[], p_title text, p_body text, p_link text, p_email boolean default false)
returns int language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_n int;
begin
  insert into wf.notifications (user_id, title, body, link, emailed_at)
  select distinct ur.user_id, p_title, p_body, p_link, case when p_email then null else now() end
  from core.user_roles ur join core.profiles pr on pr.id = ur.user_id and pr.status = 'ACTIVE'
  where ur.role_code = any(p_roles);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- Mỗi mốc chỉ nhắc một lần: trả true nếu là lần đầu
create or replace function mfg.alert_once(p_kind text, p_ref uuid, p_key text) returns boolean
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  insert into mfg.maint_alerts (kind, ref_id, period_key) values (p_kind, p_ref, p_key) on conflict do nothing;
  return found;
end $$;

create or replace function mfg.roles_setting(p_key text, p_default text[]) returns text[]
language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce((select array_agg(x) from jsonb_array_elements_text(mfg.machine_setting(p_key)) x), p_default)
$$;

-- ===========================================================================
-- 6. Thao tác nghiệp vụ (gọi từ web app)
-- ===========================================================================
-- Tạo dây chuyền (p_parent trống) hoặc máy con, kèm bộ trường thông số mẫu
create or replace function app.create_machine(p_parent uuid, p_code text, p_name text, p_unit_kind text,
  p_op_code text, p_critical boolean, p_seq int, p_template boolean default true) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid; v_type text := 'OTHER';
begin
  if not core.has_perm('machine', 'config') then raise exception 'Bạn chưa có quyền khai báo máy'; end if;
  if coalesce(trim(p_code), '') = '' or coalesce(trim(p_name), '') = '' then raise exception 'Nhập mã máy và tên máy'; end if;
  if p_parent is null then
    if p_op_code is null then raise exception 'Chọn công đoạn của dây chuyền'; end if;
    select machine_type into v_type from master.operations where code = p_op_code;
  elsif exists (select 1 from master.machines where id = p_parent and inline_with is not null) then
    raise exception 'Chỉ thêm máy con vào dây chuyền, không thêm vào máy con khác';
  end if;
  insert into master.machines (code, name, machine_type, inline_with, op_code, unit_kind, critical, seq, protocol)
  values (upper(trim(p_code)), trim(p_name), coalesce(v_type, 'OTHER'), p_parent, case when p_parent is null then p_op_code end,
          nullif(trim(coalesce(p_unit_kind, '')), ''), coalesce(p_critical, false), coalesce(p_seq, 0), 'NONE')
  returning id into v_id;
  if p_template then
    insert into master.machine_specs (machine_id, grp, label, uom, sort)
    select v_id, g, l, u, s from (values
      ('Chung', 'Hãng / model', null, 1), ('Chung', 'Số serial', null, 2), ('Chung', 'Năm sản xuất', null, 3),
      ('Điện', 'Điện áp', 'V', 10), ('Điện', 'Công suất', 'kW', 11), ('Điện', 'Dòng định mức', 'A', 12), ('Điện', 'Biến tần', null, 13),
      ('Điều khiển', 'PLC / bộ điều khiển', null, 20), ('Điều khiển', 'Giao thức', null, 21),
      ('Cảm biến', 'Loại cảm biến', null, 30),
      ('Cơ khí & truyền động', 'Loại hộp số / bánh răng', null, 40), ('Cơ khí & truyền động', 'Tỷ số truyền', null, 41),
      ('Đấu nối', 'Cút khí nén (kích thước)', 'mm', 50), ('Đấu nối', 'Áp suất khí nén', 'MPa', 51), ('Đấu nối', 'Cút nước làm mát (kích thước)', null, 52)
    ) t(g, l, u, s);
  end if;
  return v_id;
exception when unique_violation then
  raise exception 'Mã máy % đã có', upper(trim(p_code));
end $$;

-- Đổi trạng thái máy: ghi nhật ký, dừng máy (downtime_events), máy hỏng thì mở phiếu sửa chữa và báo người phụ trách
create or replace function app.set_machine_status(p_machine uuid, p_status text, p_reason text default null,
  p_note text default null, p_eta timestamptz default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare m master.machines; v_now timestamptz := now(); v_wo uuid; v_no text; v_line master.machines;
begin
  if not core.has_perm('machine', 'create') then raise exception 'Bạn chưa có quyền cập nhật trạng thái máy'; end if;
  select * into m from master.machines where id = p_machine for update;
  if not found then raise exception 'Không tìm thấy máy'; end if;
  if p_status not in ('RUN','IDLE','STOP','MAINT','DOWN','OFF') then raise exception 'Trạng thái không hợp lệ'; end if;
  if p_status in ('STOP','DOWN') and p_reason is null then raise exception 'Chọn lý do dừng máy (BR-SX-04)'; end if;
  if p_status = m.status and p_status not in ('STOP','DOWN') then return; end if;

  update mfg.machine_status_log set ended_at = v_now where machine_id = p_machine and ended_at is null;
  update mfg.downtime_events set ended_at = v_now
   where machine_id = p_machine and ended_at is null and source = 'MANUAL';
  insert into mfg.machine_status_log (machine_id, status, started_at, reason_code, note, source)
  values (p_machine, p_status, v_now, p_reason, nullif(trim(coalesce(p_note, '')), ''), 'TAY');
  if p_status in ('STOP','DOWN','MAINT') then
    insert into mfg.downtime_events (machine_id, started_at, reason_code, source, note)
    values (p_machine, v_now, coalesce(p_reason, case when p_status = 'MAINT' then 'DT_PM' end), 'MANUAL', p_note);
  end if;
  update master.machines set status = p_status, status_since = v_now, status_note = nullif(trim(coalesce(p_note, '')), ''),
         status_eta = case when p_status in ('DOWN','MAINT') then p_eta end
   where id = p_machine;

  if p_status = 'DOWN' then
    select id into v_wo from mfg.maint_work_orders where machine_id = p_machine and wo_type = 'CM' and status in ('OPEN','IN_PROGRESS') limit 1;
    if v_wo is null then
      v_no := core.next_no('SC');
      insert into mfg.maint_work_orders (wo_no, wo_type, machine_id, title, eta, cause, assignee_role)
      values (v_no, 'CM', p_machine, 'Sửa chữa ' || m.code || coalesce(': ' || nullif(trim(coalesce(p_note, '')), ''), ''), p_eta, p_note, 'KT_TP')
      returning id into v_wo;
      perform mfg.notify_roles(mfg.roles_setting('overdue_roles', array['KT_TP','SX_TP','BGD']),
        'Máy hỏng: ' || m.code, coalesce(p_note, m.name) || '. Phiếu sửa chữa ' || v_no || coalesce(', dự kiến chạy lại ' || to_char(p_eta at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM'), ''),
        '/may/bao-duong/phieu/' || v_wo);
    elsif p_eta is not null then
      update mfg.maint_work_orders set eta = p_eta where id = v_wo;
    end if;
    -- Máy con quan trọng hỏng: cả dây chuyền chuyển sang Hỏng
    if m.critical and m.inline_with is not null then
      select * into v_line from master.machines where id = m.inline_with;
      if v_line.status <> 'DOWN' then
        perform app.set_machine_status(m.inline_with, 'DOWN', p_reason, 'Máy con ' || m.code || ' hỏng' || coalesce(': ' || p_note, ''), p_eta);
      end if;
    end if;
  end if;
end $$;

-- Duyệt tốc độ chuẩn: TP Kỹ thuật/QA; Giám đốc duyệt tạm. Bản duyệt cũ cùng khóa chuyển "Hết hiệu lực"
create or replace function app.approve_machine_speed(p_id uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare s master.machine_speeds;
begin
  if not core.has_perm('machine', 'approve') then raise exception 'Bạn chưa có quyền duyệt tốc độ chuẩn'; end if;
  select * into s from master.machine_speeds where id = p_id for update;
  if not found or s.status <> 'PENDING' then raise exception 'Tốc độ này không ở trạng thái chờ duyệt'; end if;
  update master.machine_speeds set status = 'OBSOLETE'
   where status = 'APPROVED' and machine_id = s.machine_id and op_code = s.op_code
     and coalesce(product_id::text, '') = coalesce(s.product_id::text, '') and coalesce(group_code, '') = coalesce(s.group_code, '')
     and coalesce(core_code, '') = coalesce(s.core_code, '');
  update master.machine_speeds set status = 'APPROVED', approved_by = auth.uid(), approved_at = now(),
         temp_approval = not core.has_role('KT_TP') and not core.has_role('ADMIN')
   where id = p_id;
end $$;

-- Tạo phiếu bảo dưỡng từ kế hoạch
create or replace function app.create_maint_wo(p_plan uuid, p_date date default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare p mfg.maint_plans; v_id uuid; v_no text; m master.machines;
begin
  if not core.has_perm('machine', 'create') then raise exception 'Bạn chưa có quyền tạo phiếu bảo dưỡng'; end if;
  select * into p from mfg.maint_plans where id = p_plan;
  if not found then raise exception 'Không tìm thấy kế hoạch bảo dưỡng'; end if;
  select id into v_id from mfg.maint_work_orders where plan_id = p_plan and status in ('OPEN','IN_PROGRESS') limit 1;
  if v_id is not null then return v_id; end if;
  select * into m from master.machines where id = p.machine_id;
  v_no := core.next_no('BD');
  insert into mfg.maint_work_orders (wo_no, wo_type, plan_id, machine_id, title, planned_date, off_shift, est_minutes, steps, assignee_role)
  values (v_no, 'PM', p.id, p.machine_id, p.name || ' · ' || m.code,
          coalesce(p_date, (select due_date from mfg.maint_plan_state(p.id))), p.off_shift, p.stop_minutes,
          coalesce((select jsonb_agg(jsonb_build_object('label', s, 'done', false)) from unnest(p.steps) s), '[]'), p.assignee_role)
  returning id into v_id;
  return v_id;
end $$;

-- Bắt đầu làm phiếu: bảo dưỡng trong ca thì máy chuyển "Bảo dưỡng"
create or replace function app.start_maint_wo(p_id uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare w mfg.maint_work_orders;
begin
  if not core.has_perm('machine', 'edit') then raise exception 'Bạn chưa có quyền làm phiếu'; end if;
  select * into w from mfg.maint_work_orders where id = p_id for update;
  if w.status <> 'OPEN' then raise exception 'Phiếu không ở trạng thái Mới'; end if;
  update mfg.maint_work_orders set status = 'IN_PROGRESS', started_at = now() where id = p_id;
  if w.wo_type = 'PM' and not w.off_shift then
    perform app.set_machine_status(w.machine_id, 'MAINT', 'DT_PM', w.wo_no || ' ' || w.title, null);
    update mfg.machine_status_log set maint_wo_id = p_id where machine_id = w.machine_id and ended_at is null;
  end if;
end $$;

-- Hoàn thành phiếu: ghi kết quả; phiếu bảo dưỡng đặt lại mốc chu kỳ; máy đang Bảo dưỡng / Hỏng trở về Chờ việc
create or replace function app.finish_maint_wo(p_id uuid, p_result text, p_action text, p_steps jsonb, p_cause text default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare w mfg.maint_work_orders; m master.machines; v_now timestamptz := now();
begin
  if not core.has_perm('machine', 'edit') then raise exception 'Bạn chưa có quyền làm phiếu'; end if;
  select * into w from mfg.maint_work_orders where id = p_id for update;
  if w.status not in ('OPEN','IN_PROGRESS') then raise exception 'Phiếu đã đóng'; end if;
  if p_result not in ('OK','NOT_OK') then raise exception 'Chọn kết quả Đạt / Chưa đạt'; end if;
  if coalesce(trim(p_action), '') = '' then raise exception 'Ghi việc đã làm'; end if;
  update mfg.maint_work_orders set status = 'DONE', result = p_result, action_taken = trim(p_action),
         steps = coalesce(p_steps, steps), cause = coalesce(nullif(trim(coalesce(p_cause, '')), ''), cause),
         started_at = coalesce(started_at, v_now), finished_at = v_now, done_by = auth.uid()
   where id = p_id;
  if w.wo_type = 'PM' and w.plan_id is not null and p_result = 'OK' then
    update mfg.maint_plans set last_done_at = v_now, base_hours = 0, base_km = 0 where id = w.plan_id;
  end if;
  select * into m from master.machines where id = w.machine_id;
  if p_result = 'OK' and m.status in ('MAINT','DOWN') then
    perform app.set_machine_status(w.machine_id, 'IDLE', null, 'Xong phiếu ' || w.wo_no, null);
    if m.critical and m.inline_with is not null
       and (select status from master.machines where id = m.inline_with) = 'DOWN'
       and not exists (select 1 from master.machines c where c.inline_with = m.inline_with and c.critical and c.status = 'DOWN') then
      perform app.set_machine_status(m.inline_with, 'IDLE', null, 'Máy con ' || m.code || ' đã sửa xong', null);
    end if;
  end if;
end $$;

-- TP Kỹ thuật/QA xác nhận phiếu đã làm
create or replace function app.confirm_maint_wo(p_id uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if not core.has_perm('machine', 'approve') then raise exception 'Chỉ TP Kỹ thuật/QA xác nhận phiếu'; end if;
  update mfg.maint_work_orders set confirmed_by = auth.uid(), confirmed_at = now()
   where id = p_id and status = 'DONE' and confirmed_at is null;
  if not found then raise exception 'Phiếu chưa hoàn thành hoặc đã xác nhận'; end if;
end $$;

-- Lịch làm việc (Giám đốc): giờ làm sáng/chiều → ca A của Kế hoạch SX, ngày làm việc, tỷ lệ xếp lịch, số máy một người.
-- Dùng lại app.kh_save_shifts, app.kh_save_config (kiểm quyền Giám đốc, ghi nhật ký thay đổi tham số).
create or replace function app.save_work_calendar(p_s1_from time, p_s1_to time, p_s2_from time, p_s2_to time, p_workdays int[],
  p_fill numeric, p_max_op int, p_reason text) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare a master.shifts; c master.planning_config; n int := 0; v_old jsonb; v_new jsonb; v_cfg jsonb := '{}';
begin
  if not core.has_role('BGD') then raise exception 'Chỉ Giám đốc được sửa lịch làm việc'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do thay đổi'; end if;
  if not (p_s1_from < p_s1_to and p_s1_to <= p_s2_from and p_s2_from < p_s2_to) then
    raise exception 'Giờ làm không hợp lệ: buổi sáng phải trước buổi chiều'; end if;
  if p_s1_to - p_s1_from <> p_s2_to - p_s2_from then
    raise exception 'Buổi sáng và buổi chiều phải dài bằng nhau (ví dụ 08:00–12:00 và 13:00–17:00)'; end if;
  if coalesce(array_length(p_workdays, 1), 0) = 0 or exists (select 1 from unnest(p_workdays) d where d not between 1 and 7) then
    raise exception 'Chọn ít nhất một ngày làm việc'; end if;
  select * into a from master.shifts where code = 'A';
  if a.start_time <> p_s1_from or a.end_time <> p_s2_to or a.break_min <> (extract(epoch from p_s2_from - p_s1_to) / 60)::int then
    n := n + app.kh_save_shifts(jsonb_build_array(jsonb_build_object('code', 'A', 'start_time', to_char(p_s1_from, 'HH24:MI'),
      'end_time', to_char(p_s2_to, 'HH24:MI'), 'break_min', (extract(epoch from p_s2_from - p_s1_to) / 60)::int, 'active', true)), p_reason);
  end if;
  select * into c from master.planning_config where id = 1;
  if c.fill_pct <> p_fill then v_cfg := v_cfg || jsonb_build_object('fill_pct', p_fill); end if;
  if c.machines_per_operator <> p_max_op then v_cfg := v_cfg || jsonb_build_object('machines_per_operator', p_max_op); end if;
  if v_cfg <> '{}' then n := n + app.kh_save_config(v_cfg, p_reason); end if;
  select value -> 'workdays' into v_old from master.machine_settings where key = 'shift';
  select to_jsonb(array_agg(distinct d order by d)) into v_new from unnest(p_workdays) d;
  if v_old is distinct from v_new then
    update master.machine_settings set value = jsonb_set(value, '{workdays}', v_new) where key = 'shift';
    perform app.kh_log('Ca làm việc', 'Ngày làm việc trong tuần', v_old::text, v_new::text, trim(p_reason));
    n := n + 1;
  end if;
  if n = 0 then raise exception 'Không có thay đổi'; end if;
  return n;
end $$;

-- Checklist đầu ca: NV vận hành ghi; sửa lại được trong ngày khi TP Kỹ thuật/QA chưa kiểm tra
create or replace function app.save_daily_check(p_machine uuid, p_results jsonb, p_note text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid; v_today date := (now() at time zone 'Asia/Ho_Chi_Minh')::date; c mfg.maint_checks; v_issue boolean; m master.machines;
begin
  if not core.has_perm('machine', 'create') then raise exception 'Bạn chưa có quyền ghi checklist'; end if;
  if jsonb_typeof(p_results) <> 'array' or jsonb_array_length(p_results) = 0 then raise exception 'Chưa có mục kiểm tra'; end if;
  select * into m from master.machines where id = p_machine;
  if m.inline_with is not null then raise exception 'Checklist ghi theo dây chuyền'; end if;
  v_issue := exists (select 1 from jsonb_array_elements(p_results) e where not coalesce((e ->> 'ok')::boolean, false));
  if v_issue and coalesce(trim(p_note), '') = '' and not exists (
       select 1 from jsonb_array_elements(p_results) e where not coalesce((e ->> 'ok')::boolean, false) and coalesce(trim(e ->> 'note'), '') <> '') then
    raise exception 'Có mục không đạt: ghi rõ vấn đề';
  end if;
  select * into c from mfg.maint_checks where machine_id = p_machine and check_date = v_today;
  if found then
    if c.checked_at is not null then raise exception 'TP Kỹ thuật/QA đã kiểm tra checklist hôm nay, không sửa được'; end if;
    update mfg.maint_checks set results = p_results, has_issue = v_issue, note = nullif(trim(coalesce(p_note, '')), ''),
           done_by = auth.uid(), done_at = now() where id = c.id returning id into v_id;
  else
    insert into mfg.maint_checks (machine_id, check_date, results, has_issue, note)
    values (p_machine, v_today, p_results, v_issue, nullif(trim(coalesce(p_note, '')), '')) returning id into v_id;
  end if;
  if v_issue then
    perform mfg.notify_roles(mfg.roles_setting('remind_roles', array['KT_TP','SX_TP']),
      'Checklist đầu ca có vấn đề: ' || m.code, coalesce(nullif(trim(coalesce(p_note, '')), ''),
        (select string_agg((e ->> 'label') || coalesce(': ' || nullif(e ->> 'note', ''), ''), '; ')
           from jsonb_array_elements(p_results) e where not coalesce((e ->> 'ok')::boolean, false))),
      '/may/checklist');
  end if;
  return v_id;
end $$;

create or replace function app.review_daily_check(p_id uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if not core.has_perm('machine', 'approve') then raise exception 'Chỉ TP Kỹ thuật/QA kiểm tra checklist'; end if;
  update mfg.maint_checks set checked_by = auth.uid(), checked_at = now() where id = p_id and checked_at is null;
end $$;

-- ===========================================================================
-- 7. Kiểm tra năng lực kế hoạch (tốc độ, tình trạng máy, bảo dưỡng, người đứng máy)
--    p_extra: [{"product_id": "...", "qty_m": 10000}] đơn thử, không ghi vào kế hoạch
-- ===========================================================================
create or replace function app.check_capacity(p_plan uuid, p_from date, p_to date, p_shifts int default 1,
  p_ot_hours numeric default 0, p_extra jsonb default '[]') returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  s jsonb := mfg.machine_setting('shift');
  v_min numeric := coalesce((s ->> 'minutes')::numeric, 480);
  v_fill numeric := coalesce((s ->> 'fill')::numeric, 0.85);
  v_days int; v_from timestamptz; v_to timestamptz;
  v_issues jsonb := '[]'; v_ops jsonb := '[]'; v_lines jsonb := '[]'; v_skipped jsonb := '[]';
  v_maxop int := coalesce((mfg.machine_setting('max_machines_per_operator'))::text::int, 2);
  r record; o record; mc record; sp record; v_cap numeric; v_req numeric; v_load numeric; v_mach jsonb;
  v_prev_type text; v_meters numeric; v_speed numeric; v_n int; v_line_issues jsonb; v_unapproved boolean := false;
  v_size_ok boolean; v_maint numeric; v_down numeric; v_eta timestamptz; v_note text;
begin
  if not core.has_perm('machine', 'view') and not core.has_perm('plan', 'view') then raise exception 'Bạn chưa có quyền xem năng lực máy'; end if;
  if p_to < p_from then raise exception 'Ngày kết thúc phải sau ngày bắt đầu'; end if;
  p_shifts := greatest(1, least(3, coalesce(p_shifts, 1)));
  v_days := mfg.workdays(p_from, p_to);
  v_from := p_from::timestamp at time zone 'Asia/Ho_Chi_Minh';
  v_to := (p_to + 1)::timestamp at time zone 'Asia/Ho_Chi_Minh';

  -- Nhu cầu: dòng kế hoạch + đơn thử
  drop table if exists _dem; drop table if exists _req;
  create temporary table _dem on commit drop as
  select p.id as product_id, p.code, p.description, p.group_code, sp2.core_code, sp2.cores, ct.nominal_mm2,
         sum(d.qty_m) as qty_m, sum(d.lots) as lots, bool_or(d.trial) as trial
  from (
    select l.product_id, l.qty_m, l.run_lots as lots, false as trial from plan.plan_lines l where l.plan_id = p_plan
    union all
    select (e ->> 'product_id')::uuid, (e ->> 'qty_m')::numeric, 1, true from jsonb_array_elements(coalesce(p_extra, '[]')) e
  ) d
  join master.products p on p.id = d.product_id
  join master.product_specs sp2 on sp2.id = p.current_spec_id
  left join master.core_types ct on ct.code = sp2.core_code and ct.set_id = sp2.param_set_id
  group by 1, 2, 3, 4, 5, 6, 7;

  create temporary table _req (op_code text, minutes numeric) on commit drop;

  for r in select * from _dem loop
    v_line_issues := '[]'; v_prev_type := null;
    for o in select op.code, op.name, op.machine_type, op.per_core
             from master.routings rt join master.operations op on op.code = rt.op_code
             where rt.group_code = r.group_code order by op.seq loop
      -- Công đoạn liền kề chạy cùng loại máy (xoắn + quấn AL/PET): tính một lần
      if o.machine_type = v_prev_type then continue; end if;
      v_prev_type := o.machine_type;
      select count(*) into v_n from master.machines mm where mm.active and mm.inline_with is null and mm.op_code = o.code and mm.status <> 'OFF';
      if v_n = 0 then
        if not v_skipped @> to_jsonb(array[o.name]) then v_skipped := v_skipped || to_jsonb(array[o.name]); end if;
        continue;
      end if;
      -- Dải hoạt động: tiết diện ruột
      select bool_or(rg.id is null or r.nominal_mm2 is null
                     or (r.nominal_mm2 >= coalesce(rg.min_value, -1) - 0.0001 and r.nominal_mm2 <= coalesce(rg.max_value, 1e9) + 0.0001)) into v_size_ok
      from master.machines mm left join master.machine_ranges rg on rg.machine_id = mm.id and rg.param = 'SIZE_MM2'
      where mm.active and mm.inline_with is null and mm.op_code = o.code and mm.status <> 'OFF';
      if not coalesce(v_size_ok, true) then
        v_line_issues := v_line_issues || jsonb_build_object('lvl', 'bad', 'op', o.name, 'text', format('Tiết diện %s mm² ngoài dải của máy', round(r.nominal_mm2, 2)));
        continue;
      end if;
      -- Tốc độ: trung bình tốc độ hiệu lực của các máy cùng công đoạn
      select avg(x.eff) as eff, avg(x.setup) as setup, bool_or(x.status <> 'APPROVED') as pending into sp from (
        select distinct on (mm.id) mm.id, s2.status, s2.setup_min as setup,
               least(s2.std_mpm, coalesce(s2.rated_mpm, s2.std_mpm),
                     coalesce((select max_value from master.machine_ranges rg where rg.machine_id = mm.id and rg.param = 'SPEED_MPM'), s2.std_mpm)) as eff
        from master.machines mm join master.machine_speeds s2 on s2.machine_id = mm.id and s2.op_code = o.code and s2.status <> 'OBSOLETE'
        where mm.active and mm.inline_with is null and mm.op_code = o.code and mm.status <> 'OFF'
          and (s2.product_id = r.product_id or s2.product_id is null)
          and (s2.group_code = r.group_code or s2.group_code is null)
          and (s2.core_code = r.core_code or s2.core_code is null)
        order by mm.id, (s2.product_id is not null) desc, (s2.group_code is not null and s2.core_code is not null) desc,
                 (s2.core_code is not null) desc, (s2.group_code is not null) desc, (s2.status = 'APPROVED') desc, s2.submitted_at desc
      ) x;
      if sp.eff is null then
        v_line_issues := v_line_issues || jsonb_build_object('lvl', 'bad', 'op', o.name, 'text', 'Chưa có tốc độ chuẩn');
        continue;
      end if;
      if sp.pending then v_unapproved := true; end if;
      v_meters := r.qty_m * case when o.per_core then greatest(r.cores, 1) else 1 end;
      insert into _req values (o.code, v_meters / sp.eff + coalesce(sp.setup, 0) * greatest(r.lots, 1));
    end loop;
    v_lines := v_lines || jsonb_build_object('product_id', r.product_id, 'code', r.code, 'description', r.description,
      'qty_m', r.qty_m, 'trial', r.trial, 'issues', v_line_issues);
    if jsonb_array_length(v_line_issues) > 0 then
      v_issues := v_issues || (select jsonb_agg(jsonb_build_object('lvl', 'bad', 'text', r.code || ': ' || (i ->> 'text') || ' (' || (i ->> 'op') || ')',
        'hint', case when i ->> 'text' like 'Chưa có tốc độ%' then 'TP Kỹ thuật/QA khai báo tốc độ trong Hồ sơ máy trước khi lập kế hoạch.'
                     else 'Không máy nào trong xưởng làm được. Từ chối đơn hoặc thuê gia công ngoài.' end))
        from jsonb_array_elements(v_line_issues) i);
    end if;
  end loop;

  -- Năng lực từng công đoạn
  for o in select op.code, op.name from master.operations op
           where exists (select 1 from master.machines mm where mm.active and mm.inline_with is null and mm.op_code = op.code)
           order by op.seq loop
    v_cap := 0; v_mach := '[]';
    for mc in select mm.* from master.machines mm where mm.active and mm.inline_with is null and mm.op_code = o.code order by mm.code loop
      -- Bảo dưỡng trong ca đến hạn trong kỳ (kể cả máy con của dây chuyền)
      select coalesce(sum(p.stop_minutes * greatest(1, 1 + floor(greatest(0, (p_to - greatest(st.due_date, p_from))::numeric)
                 / greatest(1, coalesce(p.every_days, 9999))))), 0) into v_maint
      from mfg.maint_plans p join master.machines um on um.id = p.machine_id
      cross join lateral mfg.maint_plan_state(p.id) st
      where p.active and not p.off_shift and p.stop_minutes > 0 and coalesce(um.inline_with, um.id) = mc.id
        and st.open_wo is null and st.due_date <= p_to;
      -- Máy hỏng / bảo dưỡng: trừ ngày làm việc tới giờ dự kiến chạy lại (chưa có giờ dự kiến: trừ 1 ngày)
      v_down := 0; v_note := null;
      if mc.status in ('DOWN','MAINT') then
        v_eta := coalesce(mc.status_eta, now() + interval '1 day');
        if v_eta > v_from then
          v_down := mfg.workdays(greatest(p_from, (now() at time zone 'Asia/Ho_Chi_Minh')::date),
                                 least(p_to, ((v_eta at time zone 'Asia/Ho_Chi_Minh') - interval '1 minute')::date)) * v_min * p_shifts * v_fill;
          v_down := least(v_down, v_days * v_min * p_shifts * v_fill);
        end if;
        v_note := case mc.status when 'DOWN' then 'Hỏng' else 'Bảo dưỡng' end || coalesce(', dự kiến chạy lại ' || to_char(mc.status_eta at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM'), ', chưa có giờ dự kiến');
      end if;
      v_cap := v_cap + greatest(0, v_days * (v_min * p_shifts + coalesce(p_ot_hours, 0) * 60) * v_fill - v_maint - v_down);
      v_mach := v_mach || jsonb_build_object('id', mc.id, 'code', mc.code, 'name', mc.name, 'status', mc.status, 'note', v_note,
        'gross_min', round(v_days * (v_min * p_shifts + coalesce(p_ot_hours, 0) * 60) * v_fill), 'maint_min', round(v_maint), 'down_min', round(v_down),
        'operator', (select person from master.machine_operators mo where mo.machine_id = mc.id and mo.role = 'PRIMARY' order by created_at limit 1));
      if mc.status in ('DOWN','MAINT') then
        v_issues := v_issues || jsonb_build_object('lvl', 'warn', 'text', mc.code || ' ' || lower(v_note),
          'hint', format('Đã trừ %s giờ máy. Sửa lâu hơn thì cập nhật giờ dự kiến trên phiếu để tính lại.', round(v_down / 60, 1)));
      end if;
    end loop;
    select coalesce(sum(minutes), 0) into v_req from _req where op_code = o.code;
    v_load := case when v_cap > 0 then v_req / v_cap when v_req > 0 then 9.99 else 0 end;
    v_ops := v_ops || jsonb_build_object('op_code', o.code, 'name', o.name, 'req_min', round(v_req), 'cap_min', round(v_cap),
                                         'load', round(v_load, 4), 'machines', v_mach);
    if v_load > 1 then
      v_issues := v_issues || jsonb_build_object('lvl', 'bad', 'text', format('%s quá tải %s%%', o.name, round(v_load * 100)),
        'hint', format('Thiếu %s giờ máy. Tăng ca, thêm ca, dời hạn hoặc bớt đơn.', round((v_req - v_cap) / 60)));
    elsif v_load >= 0.85 then
      v_issues := v_issues || jsonb_build_object('lvl', 'warn', 'text', format('%s tải %s%%, còn %s giờ dự phòng', o.name, round(v_load * 100), round((v_cap - v_req) / 60)),
        'hint', 'Một lần hỏng máy dài có thể trễ đơn. Ưu tiên bảo dưỡng ngoài giờ ca.');
    end if;
  end loop;

  -- Bảo dưỡng quá hạn
  v_issues := v_issues || coalesce((select jsonb_agg(jsonb_build_object('lvl', 'warn',
      'text', m.code || ' quá hạn bảo dưỡng: ' || p.name,
      'hint', case when p.off_shift then 'Làm ngoài giờ ca, không trừ năng lực. Làm ngay sau ca.' else format('Đã giữ %s phút dừng máy. Quản lý SX xếp vào kế hoạch ngày.', p.stop_minutes) end))
    from mfg.maint_plans p join master.machines m on m.id = p.machine_id cross join lateral mfg.maint_plan_state(p.id) st
    where p.active and st.state = 'OVERDUE' and st.open_wo is null), '[]');

  -- Người đứng máy
  v_issues := v_issues || coalesce((select jsonb_agg(jsonb_build_object('lvl', 'warn', 'text', m.code || ' chưa có người đứng máy chính',
      'hint', 'Khai báo người vận hành trong Hồ sơ máy. Chỉ giao người đã được TP Kỹ thuật/QA xác nhận tay nghề.'))
    from master.machines m where m.active and m.inline_with is null and m.status <> 'OFF'
      and not exists (select 1 from master.machine_operators mo where mo.machine_id = m.id and mo.role = 'PRIMARY')), '[]');
  v_issues := v_issues || coalesce((select jsonb_agg(jsonb_build_object('lvl', 'warn',
      'text', format('%s đứng chính %s máy, quá mức %s máy cùng lúc', x.person, x.n, v_maxop),
      'hint', 'Quản lý SX giao bớt máy hoặc không chạy các máy này cùng lúc.'))
    from (select mo.person, count(*) n from master.machine_operators mo join master.machines m on m.id = mo.machine_id
          where mo.role = 'PRIMARY' and m.active and m.inline_with is null group by mo.person having count(*) > v_maxop) x), '[]');

  if v_unapproved then
    v_issues := v_issues || jsonb_build_object('lvl', 'info', 'text', 'Có tốc độ đang dùng là số chờ duyệt',
      'hint', 'Kết quả để tham khảo. TP Kỹ thuật/QA duyệt tốc độ chuẩn; chờ quá 1 ngày làm việc thì Giám đốc duyệt tạm.');
  end if;

  return jsonb_build_object('from', p_from, 'to', p_to, 'workdays', v_days, 'shifts', p_shifts, 'ot_hours', coalesce(p_ot_hours, 0),
    'shift_minutes', v_min, 'fill', v_fill, 'ops', v_ops, 'lines', v_lines, 'skipped_ops', v_skipped,
    'issues', (select coalesce(jsonb_agg(i order by case i ->> 'lvl' when 'bad' then 0 when 'warn' then 1 else 2 end), '[]') from jsonb_array_elements(v_issues) i));
end $$;

-- ===========================================================================
-- 8. Báo cáo bảo trì bảo dưỡng tháng
-- ===========================================================================
create or replace function mfg.maint_report(p_month date) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_m date := date_trunc('month', p_month)::date; v_from timestamptz; v_to timestamptz; v_lines jsonb; v_wd int;
begin
  v_from := v_m::timestamp at time zone 'Asia/Ho_Chi_Minh';
  v_to := (v_m + interval '1 month')::timestamp at time zone 'Asia/Ho_Chi_Minh';
  v_wd := mfg.workdays(v_m, least((v_m + interval '1 month' - interval '1 day')::date, (now() at time zone 'Asia/Ho_Chi_Minh')::date));
  select coalesce(jsonb_agg(x order by x ->> 'code'), '[]') into v_lines from (
    select jsonb_build_object(
      'id', m.id, 'code', m.code, 'name', m.name,
      'run_h', round(mfg.status_minutes(m.id, 'RUN', v_from, v_to) / 60, 1),
      'down_h', round(mfg.status_minutes(m.id, 'DOWN', v_from, v_to) / 60, 1),
      'stop_h', round(mfg.status_minutes(m.id, 'STOP', v_from, v_to) / 60, 1),
      'maint_h', round(mfg.status_minutes(m.id, 'MAINT', v_from, v_to) / 60, 1),
      'pm_done', (select count(*) from mfg.maint_work_orders w join master.machines u on u.id = w.machine_id
                  where coalesce(u.inline_with, u.id) = m.id and w.wo_type = 'PM' and w.status = 'DONE' and w.finished_at >= v_from and w.finished_at < v_to),
      'cm_count', (select count(*) from mfg.maint_work_orders w join master.machines u on u.id = w.machine_id
                   where coalesce(u.inline_with, u.id) = m.id and w.wo_type = 'CM' and w.created_at >= v_from and w.created_at < v_to),
      'cm_hours', (select round(coalesce(sum(extract(epoch from w.finished_at - w.created_at)) / 3600, 0), 1) from mfg.maint_work_orders w join master.machines u on u.id = w.machine_id
                   where coalesce(u.inline_with, u.id) = m.id and w.wo_type = 'CM' and w.status = 'DONE' and w.finished_at >= v_from and w.finished_at < v_to),
      'overdue_now', (select count(*) from mfg.maint_plans p join master.machines u on u.id = p.machine_id cross join lateral mfg.maint_plan_state(p.id) st
                      where coalesce(u.inline_with, u.id) = m.id and p.active and st.state = 'OVERDUE'),
      'checks_done', (select count(*) from mfg.maint_checks c where c.machine_id = m.id and c.check_date >= v_m and c.check_date < (v_m + interval '1 month')::date),
      'checks_issue', (select count(*) from mfg.maint_checks c where c.machine_id = m.id and c.has_issue and c.check_date >= v_m and c.check_date < (v_m + interval '1 month')::date)
    ) x
    from master.machines m where m.active and m.inline_with is null
  ) t;
  return jsonb_build_object(
    'month', to_char(v_m, 'MM/YYYY'), 'month_key', to_char(v_m, 'YYYY-MM'), 'workdays', v_wd, 'lines', v_lines,
    'run_h', (select coalesce(sum((l ->> 'run_h')::numeric), 0) from jsonb_array_elements(v_lines) l),
    'down_h', (select coalesce(sum((l ->> 'down_h')::numeric), 0) from jsonb_array_elements(v_lines) l),
    'pm_done', (select coalesce(sum((l ->> 'pm_done')::int), 0) from jsonb_array_elements(v_lines) l),
    'cm_count', (select coalesce(sum((l ->> 'cm_count')::int), 0) from jsonb_array_elements(v_lines) l),
    'overdue_now', (select coalesce(sum((l ->> 'overdue_now')::int), 0) from jsonb_array_elements(v_lines) l),
    'repairs', coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'wo_no', w.wo_no, 'machine', m.code, 'title', w.title, 'status', w.status,
                 'created_at', w.created_at, 'finished_at', w.finished_at, 'cause', w.cause, 'action', w.action_taken) order by w.created_at)
               from mfg.maint_work_orders w join master.machines m on m.id = w.machine_id
               where w.wo_type = 'CM' and w.created_at >= v_from and w.created_at < v_to), '[]'),
    'upcoming_major', coalesce((select jsonb_agg(jsonb_build_object('machine', m.code, 'name', p.name, 'due_date', st.due_date, 'stop_minutes', p.stop_minutes) order by st.due_date)
               from mfg.maint_plans p join master.machines m on m.id = p.machine_id cross join lateral mfg.maint_plan_state(p.id) st
               where p.active and p.level = 'MAJOR' and st.due_date < (v_m + interval '2 month')::date), '[]'),
    'low_stock', coalesce((select jsonb_agg(jsonb_build_object('machine', m.code, 'name', c.name, 'stock', a.available, 'min', c.min_stock))
               from master.machine_components c join master.machines m on m.id = c.machine_id
               join inv.v_material_availability a on a.material_id = c.material_id
               where c.min_stock is not null and a.available < c.min_stock), '[]'));
end $$;

create or replace function app.maint_report(p_month date) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if not core.has_perm('machine', 'view') then raise exception 'Bạn chưa có quyền xem báo cáo bảo trì'; end if;
  return mfg.maint_report(p_month);
end $$;

-- ===========================================================================
-- 9. Việc chạy nền (pg_cron)
-- ===========================================================================
-- 07:00 hằng ngày: nhắc bảo dưỡng (nhỏ trước 7 ngày, lớn trước 30 ngày), đến hạn, quá hạn; tốc độ chờ duyệt quá 1 ngày; phụ tùng dưới tối thiểu
create or replace function mfg.maint_daily_job() returns int
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r record; v_n int := 0; v_key text; v_remind text[] := mfg.roles_setting('remind_roles', array['KT_TP','SX_TP']);
        v_over text[] := mfg.roles_setting('overdue_roles', array['KT_TP','SX_TP','BGD']);
begin
  for r in select p.*, st.state, st.due_date, st.days_left, m.code as mcode, m.name as mname,
                  coalesce(l.code, m.code) as line_code
           from mfg.maint_plans p join master.machines m on m.id = p.machine_id left join master.machines l on l.id = m.inline_with
           cross join lateral mfg.maint_plan_state(p.id) st
           where p.active and st.open_wo is null and st.state <> 'OK' loop
    v_key := to_char(r.last_done_at, 'YYYYMMDDHH24MISS');
    if r.state = 'SOON' and mfg.alert_once('MAINT_SOON', r.id, v_key) then
      v_n := v_n + mfg.notify_roles(v_remind,
        case r.level when 'MAJOR' then 'Sắp đến hạn bảo dưỡng lớn: ' else 'Sắp đến hạn bảo dưỡng: ' end || r.line_code,
        format('%s (%s). Dự kiến đến hạn %s.%s', r.name, r.mname, to_char(r.due_date, 'DD/MM/YYYY'),
               case when r.off_shift then ' Làm ngoài giờ ca.' else format(' Dừng máy %s phút: Quản lý SX xếp vào kế hoạch ngày.', r.stop_minutes) end),
        '/may/bao-duong');
    elsif r.state = 'DUE' and mfg.alert_once('MAINT_DUE', r.id, v_key) then
      v_n := v_n + mfg.notify_roles(v_remind, 'Đến hạn bảo dưỡng: ' || r.line_code, r.name || ' (' || r.mname || ')', '/may/bao-duong');
    elsif r.state = 'OVERDUE' and mfg.alert_once('MAINT_OVERDUE', r.id, v_key) then
      v_n := v_n + mfg.notify_roles(v_over, 'Quá hạn bảo dưỡng: ' || r.line_code, r.name || ' (' || r.mname || '). Tạo phiếu và làm ngay.', '/may/bao-duong');
    end if;
  end loop;
  -- Tốc độ chuẩn chờ duyệt quá 1 ngày làm việc: báo Giám đốc duyệt tạm
  for r in select s.*, m.code from master.machine_speeds s join master.machines m on m.id = s.machine_id
           where s.status = 'PENDING' and mfg.workdays((s.submitted_at at time zone 'Asia/Ho_Chi_Minh')::date + 1, (now() at time zone 'Asia/Ho_Chi_Minh')::date - 1) >= 1 loop
    if mfg.alert_once('SPEED_PENDING', r.id, 'x') then
      v_n := v_n + mfg.notify_roles(array['BGD','KT_TP'], 'Tốc độ chuẩn chờ duyệt quá 1 ngày: ' || r.code,
        format('%s: %s m/ph. Giám đốc duyệt tạm nếu TP Kỹ thuật/QA chưa duyệt.', coalesce(r.label, r.op_code), r.std_mpm), '/may/toc-do');
    end if;
  end loop;
  -- Phụ tùng dưới mức tối thiểu: báo TP Kỹ thuật/QA (đề nghị mua) và NV mua hàng, mỗi tuần một lần
  for r in select c.*, m.code, a.available from master.machine_components c join master.machines m on m.id = c.machine_id
           join inv.v_material_availability a on a.material_id = c.material_id where c.min_stock is not null and a.available < c.min_stock loop
    if mfg.alert_once('LOW_STOCK', r.id, to_char(now(), 'IYYY-IW')) then
      v_n := v_n + mfg.notify_roles(array['KT_TP','MUA_NV'], 'Phụ tùng dưới mức tối thiểu: ' || r.name,
        format('Máy %s. Tồn %s, tối thiểu %s. TP Kỹ thuật/QA đề nghị mua.', r.code, r.available, r.min_stock), '/may/' || r.machine_id || '?tab=thong-so');
    end if;
  end loop;
  return v_n;
end $$;

-- 09:00 ngày làm việc: dây chuyền chưa làm checklist đầu ca → báo Quản lý SX
create or replace function mfg.maint_checklist_job() returns int
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_today date := (now() at time zone 'Asia/Ho_Chi_Minh')::date; v_list text;
begin
  if mfg.workdays(v_today, v_today) = 0 then return 0; end if;
  select string_agg(m.code, ', ' order by m.code) into v_list from master.machines m
  where m.active and m.inline_with is null and m.status not in ('OFF','DOWN')
    and not exists (select 1 from mfg.maint_checks c where c.machine_id = m.id and c.check_date = v_today);
  if v_list is null or not mfg.alert_once('CHECKLIST', '00000000-0000-0000-0000-000000000000', v_today::text) then return 0; end if;
  return mfg.notify_roles(array['SX_TP','TO_TRUONG'], 'Chưa làm checklist đầu ca: ' || v_list, 'NV vận hành làm checklist trước khi chạy máy.', '/may/checklist');
end $$;

-- 07:30 ngày 1 hằng tháng: báo cáo tháng trước, gửi thông báo + email cho Ban giám đốc
create or replace function mfg.maint_monthly_job(p_month date default null) returns int
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_m date := coalesce(date_trunc('month', p_month)::date, (date_trunc('month', now() at time zone 'Asia/Ho_Chi_Minh') - interval '1 month')::date);
        r jsonb; v_body text; v_lines text;
begin
  if not mfg.alert_once('MONTHLY', '00000000-0000-0000-0000-000000000000', to_char(v_m, 'YYYY-MM')) then return 0; end if;
  r := mfg.maint_report(v_m);
  select string_agg(format('- %s: chạy %s giờ, dừng do hỏng %s giờ (%s%%), bảo dưỡng xong %s phiếu, sửa chữa %s lần, quá hạn %s việc',
           l ->> 'code', l ->> 'run_h', l ->> 'down_h',
           case when (l ->> 'run_h')::numeric > 0 then round((l ->> 'down_h')::numeric / (l ->> 'run_h')::numeric * 100, 1)::text else '0' end,
           l ->> 'pm_done', l ->> 'cm_count', l ->> 'overdue_now'), E'\n')
    into v_lines from jsonb_array_elements(r -> 'lines') l;
  v_body := format(E'Tổng: chạy %s giờ, dừng do hỏng %s giờ (mục tiêu ≤ 3%% thời gian chạy), bảo dưỡng xong %s phiếu, sửa chữa %s lần, đang quá hạn %s việc.\n%s%s%s',
    r ->> 'run_h', r ->> 'down_h', r ->> 'pm_done', r ->> 'cm_count', r ->> 'overdue_now', coalesce(v_lines, ''),
    case when jsonb_array_length(r -> 'upcoming_major') > 0 then E'\nBảo dưỡng lớn sắp tới: ' ||
      (select string_agg(format('%s – %s (%s)', u ->> 'machine', u ->> 'name', to_char((u ->> 'due_date')::date, 'DD/MM')), '; ') from jsonb_array_elements(r -> 'upcoming_major') u) else '' end,
    case when jsonb_array_length(r -> 'low_stock') > 0 then E'\nPhụ tùng dưới mức tối thiểu: ' ||
      (select string_agg(format('%s (%s)', s ->> 'name', s ->> 'machine'), '; ') from jsonb_array_elements(r -> 'low_stock') s) else '' end);
  return mfg.notify_roles(mfg.roles_setting('report_roles', array['BGD']),
    'Báo cáo bảo trì bảo dưỡng tháng ' || to_char(v_m, 'MM/YYYY'), v_body, '/may/bao-cao?thang=' || to_char(v_m, 'YYYY-MM'), true);
end $$;

-- ===========================================================================
-- 10. View cho web app
-- ===========================================================================
create or replace view app.v_machines with (security_invoker = true) as
select m.id, m.code, m.name, m.machine_type, m.inline_with as line_id, l.code as line_code, l.name as line_name,
       m.op_code, o.name as op_name, m.seq, m.critical, m.unit_kind, m.vendor, m.model, m.serial_no, m.year_made, m.location, m.note,
       m.plc_model, m.protocol, m.rated_kw, m.active, m.status, m.status_since, m.status_note, m.status_eta,
       (select count(*) from master.machines c where c.inline_with = m.id) as unit_count,
       (select count(*) from master.machine_specs s where s.machine_id = m.id or s.machine_id in (select c.id from master.machines c where c.inline_with = m.id)) as spec_total,
       (select count(*) from master.machine_specs s where (s.machine_id = m.id or s.machine_id in (select c.id from master.machines c where c.inline_with = m.id)) and coalesce(s.value, '') <> '') as spec_filled,
       (select string_agg(mo.person, ', ' order by mo.created_at) from master.machine_operators mo where mo.machine_id = coalesce(m.inline_with, m.id) and mo.role = 'PRIMARY') as operators,
       (select w.id from mfg.maint_work_orders w where w.machine_id = m.id and w.wo_type = 'CM' and w.status in ('OPEN','IN_PROGRESS') limit 1) as open_repair_id
from master.machines m
left join master.machines l on l.id = m.inline_with
left join master.operations o on o.code = coalesce(m.op_code, l.op_code);

create or replace view app.v_machine_specs with (security_invoker = true) as select * from master.machine_specs;
create or replace view app.v_machine_ranges with (security_invoker = true) as select * from master.machine_ranges;
create or replace view app.v_machine_docs with (security_invoker = true) as select * from master.machine_docs;
create or replace view app.v_machine_operators with (security_invoker = true) as
select o.*, app.user_name(o.certified_by) as certified_by_name from master.machine_operators o;

create or replace view app.v_machine_components with (security_invoker = true) as
select c.*, mt.code as material_code, mt.name as material_name, mt.uom as material_uom, a.available as stock,
       (c.min_stock is not null and a.available is not null and a.available < c.min_stock) as low_stock
from master.machine_components c
left join master.materials mt on mt.id = c.material_id
left join inv.v_material_availability a on a.material_id = c.material_id;

create or replace view app.v_machine_speeds with (security_invoker = true) as
select s.*, m.code as machine_code, m.name as machine_name, o.name as op_name, p.code as product_code, g.name as group_name,
       app.user_name(s.approved_by) as approved_by_name,
       (select max_value from master.machine_ranges rg where rg.machine_id = s.machine_id and rg.param = 'SPEED_MPM') as range_max,
       mfg.workdays((s.submitted_at at time zone 'Asia/Ho_Chi_Minh')::date + 1, (now() at time zone 'Asia/Ho_Chi_Minh')::date - 1) as wait_days
from master.machine_speeds s
join master.machines m on m.id = s.machine_id
join master.operations o on o.code = s.op_code
left join master.products p on p.id = s.product_id
left join master.product_groups g on g.code = s.group_code;

create or replace view app.v_maint_plans with (security_invoker = true) as
select p.*, m.code as machine_code, m.name as machine_name, m.unit_kind, coalesce(l.id, m.id) as line_id, coalesce(l.code, m.code) as line_code,
       st.used_days, st.used_hours, st.used_km, st.days_left, st.due_date, st.trigger, st.state, st.open_wo, st.open_wo_no
from mfg.maint_plans p
join master.machines m on m.id = p.machine_id
left join master.machines l on l.id = m.inline_with
cross join lateral mfg.maint_plan_state(p.id) st;

create or replace view app.v_maint_wos with (security_invoker = true) as
select w.*, m.code as machine_code, m.name as machine_name, coalesce(l.code, m.code) as line_code, coalesce(l.id, m.id) as line_id,
       app.user_name(w.done_by) as done_by_name, app.user_name(w.confirmed_by) as confirmed_by_name, app.user_name(w.created_by) as created_by_name,
       p.level as plan_level
from mfg.maint_work_orders w
join master.machines m on m.id = w.machine_id
left join master.machines l on l.id = m.inline_with
left join mfg.maint_plans p on p.id = w.plan_id;

create or replace view app.v_maint_checks with (security_invoker = true) as
select c.*, m.code as machine_code, app.user_name(c.done_by) as done_by_name, app.user_name(c.checked_by) as checked_by_name
from mfg.maint_checks c join master.machines m on m.id = c.machine_id;

create or replace view app.v_machine_status_log with (security_invoker = true) as
select g.*, m.code as machine_code, r.name as reason_name, app.user_name(g.created_by) as created_by_name
from mfg.machine_status_log g join master.machines m on m.id = g.machine_id left join master.reason_codes r on r.code = g.reason_code;

-- Nhật ký vận hành gộp: trạng thái, phiếu bảo dưỡng/sửa chữa, checklist có vấn đề, sửa thông số/tốc độ, báo động PLC
-- View quyền chủ sở hữu (đọc được nhật ký sửa thông số trong core.audit_log), mỗi nhánh tự lọc theo quyền machine:view
drop view if exists app.v_machine_history;
create view app.v_machine_history as
select g.machine_id, mfg.line_of(g.machine_id) as line_id, g.started_at as at, 'STATUS'::text as kind, g.status as sub,
       coalesce(r.name, '') || case when g.note is not null then case when r.name is null then '' else ': ' end || g.note else '' end as detail,
       g.source, app.user_name(g.created_by) as who
from mfg.machine_status_log g left join master.reason_codes r on r.code = g.reason_code where core.has_perm('machine', 'view')
union all
select w.machine_id, mfg.line_of(w.machine_id), w.created_at, 'WO_OPEN', w.wo_type, w.wo_no || ' ' || w.title, 'HE_THONG', app.user_name(w.created_by)
from mfg.maint_work_orders w where core.has_perm('machine', 'view')
union all
select w.machine_id, mfg.line_of(w.machine_id), w.finished_at, 'WO_DONE', w.wo_type,
       w.wo_no || ' xong · ' || case w.result when 'OK' then 'đạt' else 'chưa đạt' end || coalesce(' · ' || w.action_taken, ''), 'HE_THONG', app.user_name(w.done_by)
from mfg.maint_work_orders w where w.status = 'DONE' and core.has_perm('machine', 'view')
union all
select c.machine_id, c.machine_id, c.done_at, 'CHECK', case when c.has_issue then 'ISSUE' else 'OK' end,
       'Checklist đầu ca' || case when c.has_issue then ' có vấn đề' || coalesce(': ' || c.note, '') else ' đạt' end, 'TAY', app.user_name(c.done_by)
from mfg.maint_checks c where core.has_perm('machine', 'view')
union all
select (a.new_data ->> 'machine_id')::uuid, mfg.line_of((coalesce(a.new_data, a.old_data) ->> 'machine_id')::uuid), a.at, 'CHANGE',
       case a.table_name when 'master.machine_speeds' then 'SPEED' else 'SPEC' end,
       case a.table_name when 'master.machine_speeds'
         then 'Tốc độ ' || coalesce(a.new_data ->> 'label', a.new_data ->> 'op_code', '') || ': ' || coalesce(a.old_data ->> 'std_mpm', '—') || ' → ' || coalesce(a.new_data ->> 'std_mpm', '—') || ' m/ph (' || coalesce(a.new_data ->> 'status', '') || ')'
         else 'Thông số ' || coalesce(a.new_data ->> 'label', a.old_data ->> 'label', '') || ': ' || coalesce(a.old_data ->> 'value', '—') || ' → ' || coalesce(a.new_data ->> 'value', '—') end,
       'TAY', app.user_name(a.user_id)
from core.audit_log a
where a.table_name in ('master.machine_specs','master.machine_speeds') and a.action = 'UPDATE' and core.has_perm('machine', 'view')
  and (a.old_data ->> 'value' is distinct from a.new_data ->> 'value' or a.old_data ->> 'std_mpm' is distinct from a.new_data ->> 'std_mpm' or a.old_data ->> 'status' is distinct from a.new_data ->> 'status')
union all
select e.machine_id, mfg.line_of(e.machine_id), e.ts, 'ALARM', e.event_type, coalesce(e.code || ': ', '') || coalesce(e.message, ''), 'PLC', null
from iot.machine_events e where core.has_perm('machine', 'view');


create or replace view app.v_machine_settings with (security_invoker = true) as
select s.key, s.label, case when s.key = 'shift' then mfg.machine_setting('shift') else s.value end as value
  from master.machine_settings s
union all
select 'max_machines_per_operator', 'Số máy tối đa một người đứng cùng lúc', mfg.machine_setting('max_machines_per_operator');
create or replace view app.v_maint_check_items with (security_invoker = true) as select * from mfg.maint_check_items;

-- ===========================================================================
-- 11. Quyền truy cập
-- ===========================================================================
insert into core.table_modules (table_name, module) values
  ('master.machine_settings','machine'), ('master.machine_specs','machine'), ('master.machine_components','machine'),
  ('master.machine_ranges','machine'), ('master.machine_speeds','machine'), ('master.machine_operators','machine'),
  ('master.machine_docs','machine'), ('mfg.machine_status_log','machine'), ('mfg.maint_plans','machine'),
  ('mfg.maint_work_orders','machine'), ('mfg.maint_wo_parts','machine'), ('mfg.maint_check_items','machine'),
  ('mfg.maint_checks','machine'), ('mfg.maint_alerts','machine')
on conflict (table_name) do update set module = excluded.module;
update core.table_modules set module = 'machine' where table_name = 'master.machines';

grant select, insert, update, delete on master.machine_settings, master.machine_specs, master.machine_components, master.machine_ranges,
  master.machine_speeds, master.machine_operators, master.machine_docs, mfg.maint_plans, mfg.maint_work_orders, mfg.maint_wo_parts,
  mfg.maint_check_items, mfg.maint_checks to authenticated;
grant select on mfg.machine_status_log to authenticated;
grant all on master.machine_settings, master.machine_specs, master.machine_components, master.machine_ranges, master.machine_speeds,
  master.machine_operators, master.machine_docs, mfg.machine_status_log, mfg.maint_plans, mfg.maint_work_orders, mfg.maint_wo_parts,
  mfg.maint_check_items, mfg.maint_checks, mfg.maint_alerts to service_role;

do $$
declare t text;
begin
  -- Khai báo: ai có machine:view xem; TP Kỹ thuật/QA (machine:config) thêm, sửa, xóa
  foreach t in array array['master.machine_specs','master.machine_components','master.machine_ranges','master.machine_operators',
                           'master.machine_docs','mfg.maint_plans','mfg.maint_check_items'] loop
    execute format('alter table %s enable row level security', t);
    execute format('drop policy if exists p_select on %s', t);
    execute format('drop policy if exists p_insert on %s', t);
    execute format('drop policy if exists p_update on %s', t);
    execute format('drop policy if exists p_delete on %s', t);
    execute format('create policy p_select on %s for select to authenticated using (core.has_perm(''machine'', ''view''))', t);
    execute format('create policy p_insert on %s for insert to authenticated with check (core.has_perm(''machine'', ''config''))', t);
    execute format('create policy p_update on %s for update to authenticated using (core.has_perm(''machine'', ''config'')) with check (core.has_perm(''machine'', ''config''))', t);
    execute format('create policy p_delete on %s for delete to authenticated using (core.has_perm(''machine'', ''config''))', t);
  end loop;
  -- Vận hành: thêm = create, sửa = edit, xóa = config
  foreach t in array array['mfg.maint_work_orders','mfg.maint_wo_parts','mfg.maint_checks'] loop
    execute format('alter table %s enable row level security', t);
    execute format('drop policy if exists p_select on %s', t);
    execute format('drop policy if exists p_insert on %s', t);
    execute format('drop policy if exists p_update on %s', t);
    execute format('drop policy if exists p_delete on %s', t);
    execute format('create policy p_select on %s for select to authenticated using (core.has_perm(''machine'', ''view''))', t);
    execute format('create policy p_insert on %s for insert to authenticated with check (core.has_perm(''machine'', ''create''))', t);
    execute format('create policy p_update on %s for update to authenticated using (core.has_perm(''machine'', ''edit'')) with check (core.has_perm(''machine'', ''edit''))', t);
    execute format('create policy p_delete on %s for delete to authenticated using (core.has_perm(''machine'', ''config''))', t);
  end loop;
end $$;

-- Tốc độ: TP Kỹ thuật/QA khai báo; chỉ duyệt qua hàm app.approve_machine_speed
alter table master.machine_speeds enable row level security;
drop policy if exists p_select on master.machine_speeds;
drop policy if exists p_insert on master.machine_speeds;
drop policy if exists p_update on master.machine_speeds;
drop policy if exists p_delete on master.machine_speeds;
create policy p_select on master.machine_speeds for select to authenticated using (core.has_perm('machine', 'view'));
create policy p_insert on master.machine_speeds for insert to authenticated
  with check (core.has_perm('machine', 'config') and status = 'PENDING' and approved_by is null);
create policy p_update on master.machine_speeds for update to authenticated
  using (core.has_perm('machine', 'config') and status = 'PENDING') with check (core.has_perm('machine', 'config') and status = 'PENDING' and approved_by is null);
create policy p_delete on master.machine_speeds for delete to authenticated using (core.has_perm('machine', 'config') and status <> 'APPROVED');

-- Cài đặt: mọi người đăng nhập đọc; TP Kỹ thuật/QA, Quản trị sửa
alter table master.machine_settings enable row level security;
drop policy if exists p_select on master.machine_settings;
drop policy if exists p_update on master.machine_settings;
drop policy if exists p_insert on master.machine_settings;
drop policy if exists p_delete on master.machine_settings;
create policy p_select on master.machine_settings for select to authenticated using (true);
create policy p_update on master.machine_settings for update to authenticated using (core.has_perm('machine', 'config')) with check (core.has_perm('machine', 'config'));

-- Nhật ký trạng thái, nhắc: chỉ ghi qua hàm
alter table mfg.machine_status_log enable row level security;
drop policy if exists p_select on mfg.machine_status_log;
create policy p_select on mfg.machine_status_log for select to authenticated using (core.has_perm('machine', 'view'));
alter table mfg.maint_alerts enable row level security;
revoke all on mfg.maint_alerts from authenticated;

-- Máy: khai báo bằng machine:config (trước đây theo master:create/edit)
drop policy if exists p_insert on master.machines;
drop policy if exists p_update on master.machines;
drop policy if exists p_delete on master.machines;
create policy p_insert on master.machines for insert to authenticated with check (core.has_perm('machine', 'config'));
create policy p_update on master.machines for update to authenticated using (core.has_perm('machine', 'config')) with check (core.has_perm('machine', 'config'));
create policy p_delete on master.machines for delete to authenticated using (core.has_perm('machine', 'config'));

-- Hàm
revoke execute on function mfg.maint_daily_job(), mfg.maint_checklist_job(), mfg.maint_monthly_job(date),
  mfg.notify_roles(text[], text, text, text, boolean), mfg.alert_once(text, uuid, text) from public, anon, authenticated;
grant execute on function mfg.maint_daily_job(), mfg.maint_checklist_job(), mfg.maint_monthly_job(date) to service_role;
revoke execute on function mfg.maint_report(date) from public, anon;
grant execute on function app.create_machine(uuid, text, text, text, text, boolean, int, boolean), app.set_machine_status(uuid, text, text, text, timestamptz),
  app.approve_machine_speed(uuid), app.create_maint_wo(uuid, date), app.start_maint_wo(uuid), app.finish_maint_wo(uuid, text, text, jsonb, text),
  app.confirm_maint_wo(uuid), app.save_daily_check(uuid, jsonb, text), app.review_daily_check(uuid),
  app.check_capacity(uuid, date, date, int, numeric, jsonb), app.maint_report(date),
  app.save_work_calendar(time, time, time, time, int[], numeric, int, text) to authenticated;
revoke execute on function app.create_machine(uuid, text, text, text, text, boolean, int, boolean), app.set_machine_status(uuid, text, text, text, timestamptz),
  app.approve_machine_speed(uuid), app.create_maint_wo(uuid, date), app.start_maint_wo(uuid), app.finish_maint_wo(uuid, text, text, jsonb, text),
  app.confirm_maint_wo(uuid), app.save_daily_check(uuid, jsonb, text), app.review_daily_check(uuid),
  app.check_capacity(uuid, date, date, int, numeric, jsonb), app.maint_report(date),
  app.save_work_calendar(time, time, time, time, int[], numeric, int, text) from public, anon;
grant select on all tables in schema app to authenticated, service_role;
-- Hàm tính dùng trong view (security_invoker): người đăng nhập cần quyền gọi
grant execute on function mfg.shift_setting(), mfg.machine_setting(text), mfg.line_of(uuid), mfg.workdays(date, date),
  mfg.status_minutes(uuid, text, timestamptz, timestamptz), mfg.machine_usage(uuid, timestamptz), mfg.machine_daily_rate(uuid),
  mfg.maint_plan_state(uuid), mfg.roles_setting(text, text[]) to authenticated, service_role;

-- Lịch làm việc theo chỉ đạo 25/10/2026: 08:00–12:00, 13:00–17:00 (ca A, nghỉ trưa 60 phút); NV được kiêm nhiệm 2 máy.
-- Chỉ đổi khi còn giá trị mặc định ban đầu (06:00–14:00, 1 máy/người), có ghi nhật ký thay đổi tham số.
do $$ begin
  if exists (select 1 from master.shifts where code = 'A' and start_time = '06:00' and end_time = '14:00' and break_min = 30) then
    update master.shifts set start_time = '08:00', end_time = '17:00', break_min = 60 where code = 'A';
    insert into master.planning_param_log (section, item, old_value, new_value, reason) values
      ('Ca làm việc', 'Ca A · giờ bắt đầu', '06:00', '08:00', 'Giờ làm 8h–12h, 13h–17h (chỉ đạo 25/10/2026)'),
      ('Ca làm việc', 'Ca A · giờ kết thúc', '14:00', '17:00', 'Giờ làm 8h–12h, 13h–17h (chỉ đạo 25/10/2026)'),
      ('Ca làm việc', 'Ca A · phút nghỉ', '30', '60', 'Nghỉ trưa 12h–13h (chỉ đạo 25/10/2026)');
  end if;
  if exists (select 1 from master.planning_config where id = 1 and machines_per_operator = 1 and updated_at is null) then
    update master.planning_config set machines_per_operator = 2 where id = 1;
    insert into master.planning_param_log (section, item, old_value, new_value, reason) values
      ('Tham số xếp lịch', 'Số máy 1 người đứng cùng lúc', '1', '2', 'NV được kiêm nhiệm (chỉ đạo 25/10/2026)');
  end if;
end $$;

-- Trạng thái hiện tại của các máy có sẵn được ghi làm mốc đầu nhật ký
insert into mfg.machine_status_log (machine_id, status, started_at, source, note)
select m.id, m.status, now(), 'HE_THONG', 'Bắt đầu theo dõi trên BMT MES'
from master.machines m where not exists (select 1 from mfg.machine_status_log g where g.machine_id = m.id);

-- Lịch chạy (chỉ khi máy chủ có pg_cron). Giờ UTC: 00:00 = 07:00, 02:00 = 09:00, 00:30 = 07:30 giờ Việt Nam
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('bmt-may-daily', '0 0 * * *', 'select mfg.maint_daily_job()');
    perform cron.schedule('bmt-may-checklist', '0 2 * * 1-6', 'select mfg.maint_checklist_job()');
    perform cron.schedule('bmt-may-monthly', '30 0 1 * *', 'select mfg.maint_monthly_job()');
  end if;
end $$;
