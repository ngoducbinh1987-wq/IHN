-- Xếp lịch theo người, máy dừng, bảo dưỡng (anh Bình duyệt 28/10/2026 10:44, Claude Doc "BMT MES – Phương án xếp lịch theo người,
-- máy dừng, bảo dưỡng (bản 2)", 7 điểm "Theo đề xuất"):
--  Đợt 1. Mọi trạng thái máy không chạy được (Dừng, Hỏng, Bảo dưỡng, Ngừng dùng) đều chặn lịch. Dừng/Hỏng bắt buộc giờ dự kiến chạy lại;
--         lý do "Hỏng máy" thì MES ghi trạng thái Hỏng. Mọi lần máy dừng / chạy lại báo TP SX xếp lại lịch. Tỷ lệ xếp lịch chung 90 %.
--  Đợt 2. Người đứng máy: máy tự chạy (bện, đùn, xoắn) chỉ cần người lúc đổi máy + khởi động (20 phút) và mỗi lần thay bobin (5 phút);
--         máy trộn cần 1 người liên tục; máy đóng gói cần người liên tục, mặc định 2 người, TP SX đặt 1 hoặc 2 đầu ca (1 người: tốc độ 50 %);
--         một người trông quá 6 máy chỉ cảnh báo. Bộ xếp lịch web (lib/kh/scheduler.ts) đọc các thông số dưới đây.
--  Đợt 3. Nhân sự xưởng: thêm / ngừng người, lịch vắng theo ngày (cả ngày, nửa ca), kiêm nhiệm tạm (QLSX phân công, được cả người chưa có
--         tay nghề, MES ghi "kiêm nhiệm tạm"), tổ đóng gói theo ngày.
--  Đợt 4. Bảo dưỡng theo kế hoạch tự giữ chỗ trên lịch (web, theo ngày / giờ chạy / km); tỷ lệ xếp lịch riêng từng máy
--         = 90 % − tỷ lệ dừng do hỏng 90 ngày (≥ 30 ngày dữ liệu, sàn 60 %, tính mỗi đêm, Giám đốc bỏ qua được một lần hỏng có lý do).

-- ===========================================================================
-- 1. Thông số
-- ===========================================================================
alter table master.planning_config
  add column if not exists start_min       integer not null default 20,   -- phút người có mặt khi khởi động máy tự chạy (sau đổi máy)
  add column if not exists bobbin_min      integer not null default 5,    -- phút người có mặt mỗi lần thay bobin
  add column if not exists watch_max       integer not null default 6,    -- cảnh báo khi một người trông quá số máy đang chạy cùng lúc
  add column if not exists pack_crew       integer not null default 2,    -- số người máy đóng gói mặc định
  add column if not exists pack_one_pct    integer not null default 50,   -- đóng gói 1 người: % tốc độ
  add column if not exists avail_learn     boolean not null default true, -- dùng tỷ lệ xếp lịch riêng từng máy (trừ tỷ lệ hỏng)
  add column if not exists avail_days      integer not null default 90,   -- số ngày gần nhất tính tỷ lệ hỏng
  add column if not exists avail_min_days  integer not null default 30,   -- ngày làm việc tối thiểu có dữ liệu
  add column if not exists avail_floor_pct integer not null default 60;   -- tỷ lệ xếp lịch riêng không thấp hơn
alter table master.planning_config drop constraint if exists planning_config_people_chk;
alter table master.planning_config add constraint planning_config_people_chk check (
  start_min between 0 and 240 and bobbin_min between 0 and 60 and watch_max between 1 and 30 and pack_crew between 1 and 2
  and pack_one_pct between 10 and 100 and avail_days between 30 and 365 and avail_min_days between 7 and avail_days
  and avail_floor_pct between 30 and 100);

-- Mọi máy dùng chung tỷ lệ xếp lịch 90 % (anh Bình 28/10/2026)
do $$
declare v numeric;
begin
  select fill_pct into v from master.planning_config where id = 1;
  if v is distinct from 90 then
    update master.planning_config set fill_pct = 90, updated_at = now() where id = 1;
    insert into master.planning_param_log (section, item, old_value, new_value, reason)
    values ('Tham số chung', 'Tỷ lệ xếp lịch mỗi ca (%)', coalesce(v::text, 'trống'), '90', 'Anh Bình chốt 28/10/2026: mọi máy dùng chung tỷ lệ xếp lịch 90 %');
  end if;
end $$;

-- ===========================================================================
-- 2. Nhân sự xưởng: người, lịch vắng, kiêm nhiệm tạm, tổ đóng gói theo ngày
-- ===========================================================================
alter table master.operators
  add column if not exists full_name  text,
  add column if not exists note       text,
  add column if not exists stopped_at date,
  add column if not exists created_at timestamptz not null default now();

create table if not exists plan.operator_absences (
  id            uuid primary key default gen_random_uuid(),
  operator_code text not null references master.operators(code) on update cascade on delete cascade,
  date_from     date not null,
  date_to       date not null,
  part          text not null default 'FULL' check (part in ('FULL','AM','PM')),   -- cả ngày, nửa đầu ca, nửa sau ca
  kind          text not null default 'PHEP' check (kind in ('PHEP','OM','RIENG','CONG_TAC','KHAC')),
  note          text,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  check (date_to >= date_from and date_to - date_from <= 366),
  check (part = 'FULL' or date_from = date_to)
);
create index if not exists operator_absences_idx on plan.operator_absences (operator_code, date_from);

create table if not exists plan.operator_covers (
  id            uuid primary key default gen_random_uuid(),
  operator_code text not null references master.operators(code) on update cascade on delete cascade,
  machine_code  text not null references master.machines(code) on update cascade on delete cascade,
  date_from     date not null,
  date_to       date not null,
  reason        text not null,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  check (date_to >= date_from and date_to - date_from <= 92)
);
create index if not exists operator_covers_idx on plan.operator_covers (machine_code, date_from);

create table if not exists plan.crew_days (
  work_date    date not null,
  machine_code text not null references master.machines(code) on update cascade on delete cascade,
  crew         smallint not null check (crew between 1 and 2),
  members      text[] not null default '{}',
  note         text,
  set_by       uuid default auth.uid(),
  set_at       timestamptz not null default now(),
  primary key (work_date, machine_code)
);

-- Tỷ lệ xếp lịch riêng từng máy (tính mỗi đêm) và các lần hỏng Giám đốc cho bỏ qua
create table if not exists master.machine_avail (
  machine_code text primary key references master.machines(code) on update cascade on delete cascade,
  from_date    date,
  to_date      date,
  tracked_days integer not null default 0,
  plan_hours   numeric not null default 0,
  down_hours   numeric not null default 0,
  events       integer not null default 0,
  down_pct     numeric not null default 0,
  fill_pct     numeric not null,
  enough       boolean not null default false,
  below_floor  boolean not null default false,
  computed_at  timestamptz not null default now()
);
create table if not exists mfg.avail_excludes (
  event_id uuid primary key references mfg.downtime_events(id) on delete cascade,
  reason   text not null,
  by_user  uuid default auth.uid(),
  at       timestamptz not null default now()
);

-- Lịch máy: các đoạn người có mặt của từng khối (người, từ, đến, loại, kiêm nhiệm tạm) và số người đóng gói
alter table plan.schedule_slots
  add column if not exists attend jsonb,
  add column if not exists crew   smallint;

do $$
declare t text;
begin
  foreach t in array array['plan.operator_absences','plan.operator_covers','plan.crew_days','master.machine_avail','mfg.avail_excludes'] loop
    execute format('alter table %s enable row level security', t);
    execute format('revoke all on %s from anon, authenticated', t);
    execute format('grant select on %s to authenticated', t);
    execute format('grant all on %s to service_role', t);
    execute format('drop policy if exists p_select on %s', t);
    execute format('create policy p_select on %s for select to authenticated using (app.kh_can_view() or core.has_perm(''machine'', ''view''))', t);
  end loop;
end $$;

-- ===========================================================================
-- 3. Hàm hỗ trợ
-- ===========================================================================
-- TP SX / Kế hoạch SX (Quản trị qua has_role) quản lý nhân sự xưởng
create or replace function plan.can_staff() returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select core.has_role('SX_TP') or core.has_role('SX_KH')
$$;
revoke all on function plan.can_staff() from public, anon;
grant execute on function plan.can_staff() to authenticated;

create or replace function plan.vn_today() returns date
language sql stable set search_path = pg_catalog, public as $$ select (now() at time zone 'Asia/Ho_Chi_Minh')::date $$;

-- Máy xếp lịch được (dây chuyền, không phải máy con)
create or replace function plan.is_sched_machine(p_code text) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select exists (select 1 from master.machines m where m.code = p_code and m.active and m.inline_with is null
                 and m.machine_type in ('MIXER','BUNCHER','EXTRUDER_SI','TWISTER','EXTRUDER_TP','PACKER'))
$$;
revoke all on function plan.is_sched_machine(text) from public, anon, authenticated;

-- Hệ số năng lực riêng của máy = tỷ lệ xếp lịch riêng ÷ tỷ lệ chung (≤ 1); chưa đủ dữ liệu hoặc tắt: 1
create or replace function plan.avail_factor(p_code text) returns numeric
language sql stable security definer set search_path = pg_catalog, public as $$
  -- tính theo tỷ lệ chung hiện tại (Giám đốc đổi tỷ lệ chung thì có hiệu lực ngay, không chờ lần tính đêm)
  select coalesce((select least(1, greatest(0.1, greatest(c.avail_floor_pct, round(c.fill_pct - a.down_pct, 1)) / nullif(c.fill_pct, 0)))
                   from master.machine_avail a cross join master.planning_config c
                   where a.machine_code = p_code and a.enough and c.id = 1 and c.avail_learn), 1)
$$;
revoke all on function plan.avail_factor(text) from public, anon;
grant execute on function plan.avail_factor(text) to authenticated;

-- ===========================================================================
-- 4. Đợt 1: đổi trạng thái máy (Dừng/Hỏng bắt buộc giờ chạy lại; lý do hỏng → Hỏng; báo xếp lại mọi lần dừng / chạy lại)
-- ===========================================================================
create or replace function app.set_machine_status(p_machine uuid, p_status text, p_reason text default null,
  p_note text default null, p_eta timestamptz default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare m master.machines; v_now timestamptz := now(); v_wo uuid; v_no text; v_line master.machines;
        v_sys boolean := coalesce(current_setting('bmt.machine_sys', true) = 'on', false); v_msg text; v_title text;
begin
  if not v_sys and not (core.has_role('KT_TP') or core.has_role('SX_TP')) then
    raise exception 'Chỉ TP Kỹ thuật/QA (vắng thì TP SX) đổi trạng thái máy, báo hỏng. Công nhân báo TP SX.';
  end if;
  select * into m from master.machines where id = p_machine for update;
  if not found then raise exception 'Không tìm thấy máy'; end if;
  if p_status not in ('RUN','IDLE','STOP','MAINT','DOWN','OFF') then raise exception 'Trạng thái không hợp lệ'; end if;
  if p_status in ('STOP','DOWN') and p_reason is null then raise exception 'Chọn lý do dừng máy (BR-SX-04)'; end if;
  -- Lý do "Hỏng máy": MES ghi trạng thái Hỏng (mở phiếu sửa chữa), không để Dừng
  if p_status = 'STOP' and p_reason = 'DT_BREAKDOWN' then p_status := 'DOWN'; end if;
  if p_status in ('STOP','DOWN') and not v_sys and p_eta is null and m.inline_with is null then
    raise exception 'Báo Dừng / Hỏng: nhập giờ dự kiến chạy lại để lịch máy không xếp việc vào máy (ước lượng, sửa lại được)';
  end if;
  if p_eta is not null and p_eta <= v_now and p_status in ('STOP','DOWN','MAINT') then raise exception 'Giờ dự kiến chạy lại phải sau bây giờ'; end if;
  if p_status = m.status and p_status not in ('STOP','DOWN','MAINT') then return; end if;

  update mfg.machine_status_log set ended_at = v_now where machine_id = p_machine and ended_at is null;
  update mfg.downtime_events set ended_at = v_now
   where machine_id = p_machine and ended_at is null and source = 'MANUAL';
  insert into mfg.machine_status_log (machine_id, status, started_at, reason_code, note, source)
  values (p_machine, p_status, v_now, p_reason, nullif(trim(coalesce(p_note, '')), ''), case when v_sys then 'HE_THONG' else 'TAY' end);
  if p_status in ('STOP','DOWN','MAINT') then
    insert into mfg.downtime_events (machine_id, started_at, reason_code, source, note)
    values (p_machine, v_now, coalesce(p_reason, case when p_status = 'MAINT' then 'DT_PM' end), 'MANUAL', p_note);
  end if;
  update master.machines set status = p_status, status_since = v_now, status_note = nullif(trim(coalesce(p_note, '')), ''),
         status_eta = case when p_status in ('STOP','DOWN','MAINT') then p_eta end
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
        perform set_config('bmt.machine_sys', 'on', true);
        perform app.set_machine_status(m.inline_with, 'DOWN', p_reason, 'Máy con ' || m.code || ' hỏng' || coalesce(': ' || p_note, ''), p_eta);
        perform set_config('bmt.machine_sys', case when v_sys then 'on' else 'off' end, true);
      end if;
    end if;
  end if;

  -- Dây chuyền xếp lịch (cả máy trộn, máy đóng gói) chuyển sang / khỏi trạng thái không chạy được: báo TP SX, Kế hoạch SX xếp lại lịch
  if m.inline_with is null and m.machine_type in ('MIXER','BUNCHER','EXTRUDER_SI','TWISTER','EXTRUDER_TP','PACKER')
     and (p_status in ('STOP','DOWN','OFF','MAINT') or m.status in ('STOP','DOWN','OFF','MAINT'))
     and (p_status is distinct from m.status or p_status in ('STOP','DOWN','MAINT'))
     and not (p_status = 'MAINT' and v_sys) and not (m.status = 'MAINT' and v_sys and p_status in ('IDLE','RUN')) then
    v_msg := case
      when p_status in ('STOP','DOWN') then m.code || case p_status when 'DOWN' then ' hỏng' else ' dừng' end
           || coalesce(', dự kiến chạy lại ' || to_char(p_eta at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM'), '')
           || '. Bấm Xếp lại lịch: MES chuyển việc sang máy cùng loại và chỉ ra lô bị lùi.'
      when p_status = 'OFF' then m.code || ' ngừng dùng. Bấm Xếp lại lịch để chuyển việc sang máy khác.'
      when p_status = 'MAINT' then m.code || ' đang bảo dưỡng' || coalesce(', dự kiến chạy lại ' || to_char(p_eta at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM'), '') || '. Bấm Xếp lại lịch.'
      else m.code || ' đã chạy lại. Bấm Xếp lại lịch để dùng lại máy.' end;
    v_title := case when p_status in ('STOP','DOWN','OFF','MAINT') then 'Máy không chạy được: ' else 'Máy chạy lại: ' end || m.code;
    perform app.kh_notify_role('SX_TP', v_title, v_msg, '/lich-may?tab=baoduong');
    perform app.kh_notify_role('SX_KH', v_title, v_msg, '/lich-may?tab=baoduong');
  end if;
end $$;

-- ===========================================================================
-- 5. Đợt 3: ghi nhân sự xưởng (chỉ qua hàm; TP SX / Kế hoạch SX, Quản trị)
-- ===========================================================================
-- Thêm / sửa người (mã tự cấp NV6, NV7…); liên kết tài khoản để chặn tự ký QC
create or replace function app.kh_save_operator(p_code text, p_name text, p_job text, p_extra text default null,
  p_note text default null, p_profile uuid default null, p_reason text default null) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare o master.operators; v_code text := nullif(upper(trim(coalesce(p_code, ''))), ''); v_name text := nullif(trim(coalesce(p_name, '')), '');
        v_job text := nullif(trim(coalesce(p_job, '')), ''); v_old text; v_new text;
begin
  if not plan.can_staff() then raise exception 'Chỉ TP SX / Kế hoạch SX quản lý nhân sự xưởng'; end if;
  if v_name is null then raise exception 'Nhập họ tên người đứng máy'; end if;
  if v_job is null then raise exception 'Nhập công việc chính (ví dụ: chạy line đùn, đóng gói)'; end if;
  if p_profile is not null then
    if not exists (select 1 from core.profiles where id = p_profile and status = 'ACTIVE') then raise exception 'Tài khoản liên kết không tồn tại hoặc đã khóa'; end if;
    if exists (select 1 from master.operators where profile_id = p_profile and code is distinct from v_code) then
      raise exception 'Tài khoản này đã liên kết với người khác';
    end if;
  end if;
  if v_code is null then
    select 'NV' || (coalesce(max((substring(code from '^NV([0-9]+)$'))::int), 0) + 1) into v_code from master.operators;
    insert into master.operators (code, job, extra, full_name, note, profile_id, sort, active)
    values (v_code, v_job, nullif(trim(coalesce(p_extra, '')), ''), v_name, nullif(trim(coalesce(p_note, '')), ''), p_profile,
            coalesce((select max(sort) from master.operators), 0) + 1, true);
    perform app.kh_log('Nhân sự xưởng', v_code, '—', v_name || ' · ' || v_job, coalesce(nullif(trim(coalesce(p_reason, '')), ''), 'Thêm người'));
    return v_code;
  end if;
  select * into o from master.operators where code = v_code for update;
  if not found then raise exception 'Không tìm thấy người %', v_code; end if;
  v_old := concat_ws(' · ', o.full_name, o.job, o.extra, app.user_name(o.profile_id));
  update master.operators set full_name = v_name, job = v_job, extra = nullif(trim(coalesce(p_extra, '')), ''),
         note = nullif(trim(coalesce(p_note, '')), ''), profile_id = p_profile
   where code = v_code;
  v_new := concat_ws(' · ', v_name, v_job, nullif(trim(coalesce(p_extra, '')), ''), app.user_name(p_profile));
  if v_old is distinct from v_new then
    perform app.kh_log('Nhân sự xưởng', v_code, coalesce(v_old, '—'), v_new, coalesce(nullif(trim(coalesce(p_reason, '')), ''), 'Sửa thông tin người'));
  end if;
  return v_code;
end $$;

-- Ngừng / làm lại: người ngừng không được xếp lịch, giữ lịch sử
create or replace function app.kh_set_operator_active(p_code text, p_active boolean, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare o master.operators;
begin
  if not plan.can_staff() then raise exception 'Chỉ TP SX / Kế hoạch SX quản lý nhân sự xưởng'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do'; end if;
  select * into o from master.operators where code = p_code for update;
  if not found then raise exception 'Không tìm thấy người %', p_code; end if;
  if o.active = p_active then raise exception '% đã ở trạng thái này', p_code; end if;
  update master.operators set active = p_active, stopped_at = case when p_active then null else plan.vn_today() end where code = p_code;
  perform app.kh_log('Nhân sự xưởng', p_code || coalesce(' ' || o.full_name, ''), case when o.active then 'Đang làm' else 'Ngừng' end,
    case when p_active then 'Đang làm' else 'Ngừng' end, trim(p_reason));
  perform app.kh_notify_role('SX_KH', 'Nhân sự xưởng: ' || p_code || case when p_active then ' làm lại' else ' ngừng' end,
    trim(p_reason) || '. Bấm Xếp lại lịch để lịch máy tính theo người hiện có.', '/lich-may');
end $$;

-- Lịch vắng: cả ngày (nhiều ngày) hoặc nửa ca (một ngày); không trùng ngày vắng khác của cùng người
create or replace function app.kh_save_absence(p_id uuid, p_operator text, p_from date, p_to date, p_part text default 'FULL',
  p_kind text default 'PHEP', p_note text default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid; v_part text := coalesce(p_part, 'FULL'); v_to date := coalesce(p_to, p_from); o master.operators; old plan.operator_absences;
        k jsonb := '{"PHEP":"nghỉ phép","OM":"ốm","RIENG":"việc riêng","CONG_TAC":"đi công tác","KHAC":"khác"}';
        pa jsonb := '{"FULL":"cả ngày","AM":"nửa đầu ca","PM":"nửa sau ca"}';
begin
  if not plan.can_staff() then raise exception 'Chỉ TP SX / Kế hoạch SX nhập lịch vắng'; end if;
  select * into o from master.operators where code = p_operator;
  if not found or not o.active then raise exception 'Người % không có hoặc đã ngừng làm', p_operator; end if;
  if p_from is null then raise exception 'Chọn ngày vắng'; end if;
  if v_to < p_from then raise exception 'Đến ngày phải sau từ ngày'; end if;
  if v_to - p_from > 366 then raise exception 'Mỗi lần nhập tối đa một năm'; end if;
  if v_part not in ('FULL','AM','PM') then raise exception 'Chọn cả ngày hoặc nửa ca'; end if;
  if v_part <> 'FULL' and v_to <> p_from then raise exception 'Vắng nửa ca chỉ nhập cho một ngày'; end if;
  if not (k ? coalesce(p_kind, '')) then raise exception 'Chọn loại vắng'; end if;
  if v_to < plan.vn_today() - 60 then raise exception 'Không nhập vắng quá 60 ngày trước'; end if;
  if exists (select 1 from plan.operator_absences a where a.operator_code = p_operator and a.id is distinct from p_id
             and a.date_from <= v_to and a.date_to >= p_from and (a.part = 'FULL' or v_part = 'FULL' or a.part = v_part)) then
    raise exception '% đã có lịch vắng trùng ngày', p_operator;
  end if;
  if p_id is null then
    insert into plan.operator_absences (operator_code, date_from, date_to, part, kind, note)
    values (p_operator, p_from, v_to, v_part, p_kind, nullif(trim(coalesce(p_note, '')), '')) returning id into v_id;
    perform app.kh_log('Lịch vắng', p_operator || coalesce(' ' || o.full_name, ''), '—',
      to_char(p_from, 'DD/MM') || case when v_to > p_from then '–' || to_char(v_to, 'DD/MM') else '' end || ' ' || (pa ->> v_part) || ', ' || (k ->> p_kind),
      coalesce(nullif(trim(coalesce(p_note, '')), ''), 'Nhập lịch vắng'));
  else
    select * into old from plan.operator_absences where id = p_id for update;
    if not found then raise exception 'Không tìm thấy lịch vắng'; end if;
    update plan.operator_absences set operator_code = p_operator, date_from = p_from, date_to = v_to, part = v_part, kind = p_kind,
           note = nullif(trim(coalesce(p_note, '')), '') where id = p_id;
    v_id := p_id;
    perform app.kh_log('Lịch vắng', p_operator || coalesce(' ' || o.full_name, ''),
      to_char(old.date_from, 'DD/MM') || '–' || to_char(old.date_to, 'DD/MM') || ' ' || (pa ->> old.part),
      to_char(p_from, 'DD/MM') || '–' || to_char(v_to, 'DD/MM') || ' ' || (pa ->> v_part) || ', ' || (k ->> p_kind),
      coalesce(nullif(trim(coalesce(p_note, '')), ''), 'Sửa lịch vắng'));
  end if;
  return v_id;
end $$;

create or replace function app.kh_delete_absence(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare a plan.operator_absences;
begin
  if not plan.can_staff() then raise exception 'Chỉ TP SX / Kế hoạch SX sửa lịch vắng'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do bỏ lịch vắng'; end if;
  delete from plan.operator_absences where id = p_id returning * into a;
  if a.id is null then raise exception 'Không tìm thấy lịch vắng'; end if;
  perform app.kh_log('Lịch vắng', a.operator_code, to_char(a.date_from, 'DD/MM') || '–' || to_char(a.date_to, 'DD/MM'), 'Bỏ', trim(p_reason));
end $$;

-- Kiêm nhiệm tạm: QLSX phân công người đứng thêm một máy trong khoảng ngày (được cả người chưa có tay nghề máy đó)
create or replace function app.kh_save_cover(p_id uuid, p_operator text, p_machine text, p_from date, p_to date, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid; v_to date := coalesce(p_to, p_from); o master.operators; v_skill text; old plan.operator_covers;
begin
  if not plan.can_staff() then raise exception 'Chỉ TP SX / Kế hoạch SX phân công kiêm nhiệm'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do kiêm nhiệm (ví dụ: NV5 nghỉ phép)'; end if;
  select * into o from master.operators where code = p_operator;
  if not found or not o.active then raise exception 'Người % không có hoặc đã ngừng làm', p_operator; end if;
  if not plan.is_sched_machine(p_machine) then raise exception 'Máy % không phải dây chuyền xếp lịch', p_machine; end if;
  if p_from is null then raise exception 'Chọn ngày bắt đầu kiêm nhiệm'; end if;
  if v_to < p_from then raise exception 'Đến ngày phải sau từ ngày'; end if;
  if v_to - p_from > 92 then raise exception 'Kiêm nhiệm tạm tối đa 3 tháng mỗi lần'; end if;
  if v_to < plan.vn_today() then raise exception 'Không phân công kiêm nhiệm cho ngày đã qua'; end if;
  select level into v_skill from master.operator_skills where operator_code = p_operator and machine_code = p_machine;
  if v_skill = 'MAIN' then raise exception '% đã đứng chính máy %, không cần kiêm nhiệm', p_operator, p_machine; end if;
  if exists (select 1 from plan.operator_covers c where c.operator_code = p_operator and c.machine_code = p_machine
             and c.id is distinct from p_id and c.date_from <= v_to and c.date_to >= p_from) then
    raise exception '% đã kiêm nhiệm máy % trùng ngày', p_operator, p_machine;
  end if;
  if p_id is null then
    insert into plan.operator_covers (operator_code, machine_code, date_from, date_to, reason)
    values (p_operator, p_machine, p_from, v_to, trim(p_reason)) returning id into v_id;
  else
    select * into old from plan.operator_covers where id = p_id for update;
    if not found then raise exception 'Không tìm thấy phân công kiêm nhiệm'; end if;
    update plan.operator_covers set operator_code = p_operator, machine_code = p_machine, date_from = p_from, date_to = v_to, reason = trim(p_reason)
     where id = p_id;
    v_id := p_id;
  end if;
  perform app.kh_log('Kiêm nhiệm tạm', p_operator || coalesce(' ' || o.full_name, '') || ' → ' || p_machine,
    coalesce(to_char(old.date_from, 'DD/MM') || '–' || to_char(old.date_to, 'DD/MM'), '—'),
    to_char(p_from, 'DD/MM') || '–' || to_char(v_to, 'DD/MM') || case when v_skill = 'LEARNING' then ' (đang học máy này)' when v_skill is null then ' (chưa có tay nghề máy này)' else '' end,
    trim(p_reason));
  -- Người chưa có tay nghề đứng máy: báo TP KT/QA để kèm, kiểm tra mẫu đầu ca
  if coalesce(v_skill, '') <> 'MAIN' then
    perform app.kh_notify_role('KT_TP', 'Kiêm nhiệm tạm: ' || p_operator || ' đứng ' || p_machine,
      coalesce(o.full_name || ' ', '') || case when v_skill = 'LEARNING' then 'đang học máy này' else 'chưa có tay nghề máy này' end
      || ', từ ' || to_char(p_from, 'DD/MM') || ' đến ' || to_char(v_to, 'DD/MM') || '. Lý do: ' || trim(p_reason) || '. Kèm, kiểm tra mẫu đầu ca.',
      '/nhan-su-xuong?tab=kiem-nhiem');
  end if;
  return v_id;
end $$;

create or replace function app.kh_delete_cover(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare c plan.operator_covers;
begin
  if not plan.can_staff() then raise exception 'Chỉ TP SX / Kế hoạch SX sửa phân công kiêm nhiệm'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do bỏ kiêm nhiệm'; end if;
  delete from plan.operator_covers where id = p_id returning * into c;
  if c.id is null then raise exception 'Không tìm thấy phân công kiêm nhiệm'; end if;
  perform app.kh_log('Kiêm nhiệm tạm', c.operator_code || ' → ' || c.machine_code, to_char(c.date_from, 'DD/MM') || '–' || to_char(c.date_to, 'DD/MM'), 'Bỏ', trim(p_reason));
end $$;

-- Tổ đóng gói theo ngày: TP SX đặt 1 hoặc 2 người (và chọn người) đầu ca; p_crew null = về mặc định
create or replace function app.kh_set_crew(p_date date, p_machine text, p_crew integer, p_members text[] default '{}', p_note text default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_old text; v_members text[] := coalesce(p_members, '{}'); x text; v_def int;
begin
  if not plan.can_staff() then raise exception 'Chỉ TP SX / Kế hoạch SX đặt tổ đóng gói'; end if;
  if p_date is null or p_date < plan.vn_today() then raise exception 'Chọn ngày từ hôm nay trở đi'; end if;
  if not exists (select 1 from master.machines where code = p_machine and machine_type = 'PACKER' and active) then
    raise exception 'Máy % không phải máy đóng gói', p_machine;
  end if;
  select pack_crew into v_def from master.planning_config where id = 1;
  select crew || ' người' || coalesce(' (' || nullif(array_to_string(members, ', '), '') || ')', '') into v_old
    from plan.crew_days where work_date = p_date and machine_code = p_machine;
  if p_crew is null then
    delete from plan.crew_days where work_date = p_date and machine_code = p_machine;
    if v_old is not null then
      perform app.kh_log('Tổ đóng gói', p_machine || ' ' || to_char(p_date, 'DD/MM'), v_old, 'Mặc định ' || v_def || ' người', coalesce(nullif(trim(coalesce(p_note, '')), ''), 'Về mặc định'));
    end if;
    return;
  end if;
  if p_crew not in (1, 2) then raise exception 'Tổ đóng gói 1 hoặc 2 người'; end if;
  if cardinality(v_members) > p_crew then raise exception 'Chọn tối đa % người', p_crew; end if;
  foreach x in array v_members loop
    if not exists (select 1 from master.operators where code = x and active) then raise exception 'Người % không có hoặc đã ngừng làm', x; end if;
    if exists (select 1 from plan.operator_absences a where a.operator_code = x and p_date between a.date_from and a.date_to and a.part = 'FULL') then
      raise exception '% vắng ngày %', x, to_char(p_date, 'DD/MM');
    end if;
  end loop;
  if (select count(distinct m) from unnest(v_members) m) <> cardinality(v_members) then raise exception 'Trùng người'; end if;
  insert into plan.crew_days (work_date, machine_code, crew, members, note, set_by, set_at)
  values (p_date, p_machine, p_crew, v_members, nullif(trim(coalesce(p_note, '')), ''), auth.uid(), now())
  on conflict (work_date, machine_code) do update set crew = excluded.crew, members = excluded.members, note = excluded.note,
     set_by = excluded.set_by, set_at = excluded.set_at;
  perform app.kh_log('Tổ đóng gói', p_machine || ' ' || to_char(p_date, 'DD/MM'), coalesce(v_old, 'Mặc định ' || v_def || ' người'),
    p_crew || ' người' || coalesce(' (' || nullif(array_to_string(v_members, ', '), '') || ')', '')
    || case when p_crew = 1 then ', tốc độ ' || (select pack_one_pct from master.planning_config where id = 1) || ' %' else '' end,
    coalesce(nullif(trim(coalesce(p_note, '')), ''), 'TP SX bố trí đầu ca'));
end $$;

-- Thông số người đứng máy (Giám đốc, TP KT/QA) và tỷ lệ xếp lịch riêng (Giám đốc)
create or replace function app.kh_save_people(p jsonb, p_reason text) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare c master.planning_config; n integer := 0; k text; ov text; nv text; v numeric;
  labels jsonb := '{"start_min":"Phút khởi động máy tự chạy (người có mặt)","bobbin_min":"Phút thay một bobin (người có mặt)",
    "watch_max":"Cảnh báo khi một người trông quá (máy)","pack_crew":"Máy đóng gói: số người mặc định",
    "pack_one_pct":"Đóng gói 1 người: tốc độ (%)","avail_learn":"Trừ tỷ lệ hỏng riêng từng máy",
    "avail_days":"Tính tỷ lệ hỏng trong (ngày gần nhất)","avail_min_days":"Ngày làm việc tối thiểu có dữ liệu",
    "avail_floor_pct":"Tỷ lệ xếp lịch riêng không thấp hơn (%)"}';
  lim jsonb := '{"start_min":[0,240],"bobbin_min":[0,60],"watch_max":[1,30],"pack_crew":[1,2],"pack_one_pct":[10,100],
    "avail_days":[30,365],"avail_min_days":[7,365],"avail_floor_pct":[30,100]}';
  bgd_only text[] := array['avail_learn','avail_days','avail_min_days','avail_floor_pct'];
  is_bgd boolean := core.has_role('BGD');
begin
  if not (is_bgd or core.has_role('KT_TP')) then raise exception 'Chỉ Giám đốc hoặc TP KT/QA được sửa thông số người đứng máy'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do thay đổi'; end if;
  if p is null or jsonb_typeof(p) <> 'object' then raise exception 'Thiếu thông số'; end if;
  select * into c from master.planning_config where id = 1 for update;
  for k in select jsonb_object_keys(p) loop
    if not labels ? k then raise exception 'Thông số không hợp lệ: %', k; end if;
    if not is_bgd and k = any(bgd_only) then raise exception 'Chỉ Giám đốc được sửa: %', labels ->> k; end if;
    if k = 'avail_learn' then
      if jsonb_typeof(p -> k) <> 'boolean' then raise exception '% phải là có / không', labels ->> k; end if;
      nv := (p ->> k);
    else
      if jsonb_typeof(p -> k) not in ('number', 'string') or (p ->> k) !~ '^[0-9]+$' then raise exception '% phải là số nguyên', labels ->> k; end if;
      v := (p ->> k)::numeric;
      if v < (lim -> k ->> 0)::numeric or v > (lim -> k ->> 1)::numeric then
        raise exception '% phải từ % đến %', labels ->> k, lim -> k ->> 0, lim -> k ->> 1;
      end if;
      nv := v::text;
    end if;
    ov := to_jsonb(c) ->> k;
    if ov is not distinct from nv then continue; end if;
    perform app.kh_log('Tham số xếp lịch', labels ->> k, coalesce(ov, 'trống'), nv, trim(p_reason));
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Không có thay đổi'; end if;
  if coalesce((p ->> 'avail_min_days')::int, c.avail_min_days) > coalesce((p ->> 'avail_days')::int, c.avail_days) then
    raise exception 'Ngày tối thiểu có dữ liệu không lớn hơn số ngày tính tỷ lệ hỏng';
  end if;
  update master.planning_config set
    start_min = coalesce((p ->> 'start_min')::int, start_min), bobbin_min = coalesce((p ->> 'bobbin_min')::int, bobbin_min),
    watch_max = coalesce((p ->> 'watch_max')::int, watch_max), pack_crew = coalesce((p ->> 'pack_crew')::int, pack_crew),
    pack_one_pct = coalesce((p ->> 'pack_one_pct')::int, pack_one_pct), avail_learn = coalesce((p ->> 'avail_learn')::boolean, avail_learn),
    avail_days = coalesce((p ->> 'avail_days')::int, avail_days), avail_min_days = coalesce((p ->> 'avail_min_days')::int, avail_min_days),
    avail_floor_pct = coalesce((p ->> 'avail_floor_pct')::int, avail_floor_pct), updated_at = now(), updated_by = auth.uid()
  where id = 1;
  if p ?| bgd_only then perform plan.calc_machine_avail(); end if;
  perform app.kh_notify_role('SX_TP', 'Thông số người đứng máy đã đổi', trim(p_reason) || '. Bấm Xếp lại lịch.', '/lich-may');
  return n;
end $$;

-- ===========================================================================
-- 6. Đợt 4: tỷ lệ xếp lịch riêng từng máy = tỷ lệ chung − tỷ lệ dừng do hỏng (90 ngày gần nhất)
-- ===========================================================================
-- Giờ hỏng: các lần dừng lý do "Hỏng máy" đã kết thúc (báo cáo ca đã chốt + lần báo Hỏng/Dừng do hỏng trên MES), gộp giờ trùng,
-- chỉ phần nằm trong giờ ca của ngày làm việc (trừ giờ nghỉ theo tỷ lệ). Lần hỏng đang diễn ra không tính (lịch đã chặn đến giờ chạy lại).
create or replace function plan.calc_machine_avail() returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare c master.planning_config; a master.shifts; m record; n integer := 0; v_today date := plan.vn_today();
        v_from date; v_to date; v_track timestamptz; v_days int; v_run numeric; v_span numeric; v_plan numeric; v_down numeric; v_ev int;
        v_pct numeric; v_fill numeric; v_enough boolean; v_below boolean; v_was boolean; v_wd int[];
begin
  select * into c from master.planning_config where id = 1;
  select * into a from master.shifts where code = 'A';
  if a.code is null then return 0; end if;
  v_span := (extract(epoch from (a.end_time - a.start_time + interval '24 hours')) / 60)::numeric % 1440;
  if v_span = 0 then v_span := 1440; end if;
  v_run := greatest(60, v_span - a.break_min);
  select array_agg(x::int) into v_wd from jsonb_array_elements_text(coalesce(mfg.machine_setting('shift') -> 'workdays', '[1,2,3,4,5,6]')) x;
  for m in select mm.id, mm.code, mm.created_at from master.machines mm
           where mm.active and mm.inline_with is null and mm.machine_type in ('MIXER','BUNCHER','EXTRUDER_SI','TWISTER','EXTRUDER_TP','PACKER') loop
    select min(l.started_at) into v_track from mfg.machine_status_log l where l.machine_id = m.id;
    v_track := coalesce(v_track, m.created_at, now());
    v_from := greatest((v_track at time zone 'Asia/Ho_Chi_Minh')::date, v_today - c.avail_days);
    v_to := v_today - 1;
    v_days := case when v_to >= v_from then mfg.workdays(v_from, v_to) else 0 end;
    v_plan := v_days * v_run / 60;
    with ev as (
      select e.id, tstzrange(greatest(e.started_at, (v_from::timestamp) at time zone 'Asia/Ho_Chi_Minh'),
                             least(e.ended_at, ((v_to + 1)::timestamp) at time zone 'Asia/Ho_Chi_Minh')) as r
      from mfg.downtime_events e
      where e.machine_id = m.id and e.reason_code = 'DT_BREAKDOWN' and e.ended_at is not null and e.ended_at > e.started_at
        and v_to >= v_from
        and e.ended_at > (v_from::timestamp) at time zone 'Asia/Ho_Chi_Minh' and e.started_at < ((v_to + 1)::timestamp) at time zone 'Asia/Ho_Chi_Minh'
        and not exists (select 1 from mfg.avail_excludes x where x.event_id = e.id)
    ), agg as (select range_agg(r) as mr, count(*) as cnt from ev where not isempty(r)),
    days as (
      select d::date as d from generate_series(v_from::timestamp, v_to::timestamp, interval '1 day') d
      where v_to >= v_from and extract(isodow from d)::int = any(v_wd)
    )
    select coalesce((select sum(extract(epoch from (upper(x) - lower(x)))) from days, agg,
                     unnest(agg.mr * tstzmultirange(tstzrange((days.d + a.start_time) at time zone 'Asia/Ho_Chi_Minh',
                       (days.d + a.start_time + make_interval(mins => v_span::int)) at time zone 'Asia/Ho_Chi_Minh'))) x), 0) / 3600 * v_run / v_span,
           (select cnt from agg)
      into v_down, v_ev;
    v_pct := case when v_plan > 0 then round(least(100, v_down / v_plan * 100), 2) else 0 end;
    v_enough := v_days >= c.avail_min_days;
    v_below := v_enough and c.fill_pct - v_pct < c.avail_floor_pct;
    v_fill := case when v_enough then greatest(c.avail_floor_pct, round(c.fill_pct - v_pct, 1)) else c.fill_pct end;
    select below_floor into v_was from master.machine_avail where machine_code = m.code;
    insert into master.machine_avail (machine_code, from_date, to_date, tracked_days, plan_hours, down_hours, events, down_pct, fill_pct, enough, below_floor, computed_at)
    values (m.code, v_from, v_to, v_days, round(v_plan, 2), round(v_down, 2), coalesce(v_ev, 0), v_pct, v_fill, v_enough, v_below, now())
    on conflict (machine_code) do update set from_date = excluded.from_date, to_date = excluded.to_date, tracked_days = excluded.tracked_days,
      plan_hours = excluded.plan_hours, down_hours = excluded.down_hours, events = excluded.events, down_pct = excluded.down_pct,
      fill_pct = excluded.fill_pct, enough = excluded.enough, below_floor = excluded.below_floor, computed_at = excluded.computed_at;
    if v_below and not coalesce(v_was, false) then
      perform wf.notify_users(plan.gd_ids(), 'Máy hỏng nhiều: ' || m.code,
        format('Tỷ lệ dừng do hỏng %s%% trong %s ngày làm việc gần nhất: tỷ lệ xếp lịch riêng còn %s%% (sàn %s%%). Kiểm tra nguyên nhân, kế hoạch bảo dưỡng.',
               round(v_pct, 1), v_days, v_fill, c.avail_floor_pct), '/tham-so#ty-le-rieng');
      perform app.kh_notify_role('KT_TP', 'Máy hỏng nhiều: ' || m.code,
        format('Tỷ lệ dừng do hỏng %s%% trong %s ngày làm việc gần nhất. Kiểm tra nguyên nhân, kế hoạch bảo dưỡng.', round(v_pct, 1), v_days), '/tham-so#ty-le-rieng');
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function plan.calc_machine_avail() from public, anon, authenticated;

-- Giám đốc bỏ qua / tính lại một lần hỏng (ví dụ đã thay hẳn bộ phận), bắt buộc lý do
create or replace function app.avail_exclude(p_event uuid, p_exclude boolean, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare e mfg.downtime_events; v_code text;
begin
  if not plan.is_gd() then raise exception 'Chỉ Giám đốc bỏ qua một lần hỏng khi tính tỷ lệ xếp lịch riêng'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do'; end if;
  select * into e from mfg.downtime_events where id = p_event;
  if not found or e.reason_code is distinct from 'DT_BREAKDOWN' then raise exception 'Không tìm thấy lần hỏng máy'; end if;
  select code into v_code from master.machines where id = e.machine_id;
  if p_exclude then
    insert into mfg.avail_excludes (event_id, reason) values (p_event, trim(p_reason))
    on conflict (event_id) do update set reason = excluded.reason, by_user = auth.uid(), at = now();
  else
    delete from mfg.avail_excludes where event_id = p_event;
  end if;
  perform app.kh_log('Tỷ lệ xếp lịch riêng', v_code || ' hỏng ' || to_char(e.started_at at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM'),
    case when p_exclude then 'Tính' else 'Bỏ qua' end, case when p_exclude then 'Bỏ qua' else 'Tính' end, trim(p_reason));
  perform plan.calc_machine_avail();
end $$;

-- Các lần hỏng trong khoảng tính tỷ lệ của một máy (để Giám đốc xem, bỏ qua)
create or replace function app.avail_events(p_machine text) returns table (id uuid, started_at timestamptz, ended_at timestamptz, minutes numeric,
  source text, note text, excluded boolean, exclude_reason text)
language sql stable security definer set search_path = pg_catalog, public as $$
  select e.id, e.started_at, e.ended_at, round(extract(epoch from (coalesce(e.ended_at, now()) - e.started_at)) / 60, 1), e.source, e.note,
         x.event_id is not null, x.reason
  from mfg.downtime_events e
  join master.machines m on m.id = e.machine_id and m.code = p_machine
  left join mfg.avail_excludes x on x.event_id = e.id
  cross join master.planning_config c
  where c.id = 1 and e.reason_code = 'DT_BREAKDOWN' and e.started_at > now() - make_interval(days => c.avail_days)
    and (app.kh_can_view() or core.has_perm('machine', 'view'))
  order by e.started_at desc
$$;

-- Bảo dưỡng theo kế hoạch của các dây chuyền xếp lịch (để lịch máy tự giữ chỗ tạm)
create or replace function plan.kh_maint_due() returns jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'level', p.level, 'line_code', coalesce(l.code, m.code),
      'due_date', st.due_date, 'trigger', st.trigger, 'state', st.state, 'every_hours', p.every_hours, 'every_km', p.every_km,
      'used_hours', st.used_hours, 'used_km', st.used_km, 'stop_minutes', p.stop_minutes, 'off_shift', p.off_shift,
      'open_wo', st.open_wo, 'open_wo_no', st.open_wo_no) order by st.due_date), '[]')
  from mfg.maint_plans p
  join master.machines m on m.id = p.machine_id
  left join master.machines l on l.id = m.inline_with
  cross join lateral mfg.maint_plan_state(p.id) st
  where p.active and coalesce(p.stop_minutes, 0) > 0 and not p.off_shift
    and st.due_date <= plan.vn_today() + 120
    and (app.kh_can_view() or core.has_perm('machine', 'view'))
$$;
revoke all on function plan.kh_maint_due() from public, anon;
grant execute on function plan.kh_maint_due() to authenticated;

-- ===========================================================================
-- 7. Views
-- ===========================================================================
create or replace view app.v_kh_operators with (security_invoker = true) as
select o.code, o.job, o.extra, o.profile_id, o.is_deputy, o.keeps_fg, o.active, o.sort,
       app.user_name(o.profile_id) as profile_name,
       coalesce((select array_agg(k.machine_code order by k.machine_code) from master.operator_skills k where k.operator_code = o.code and k.level = 'MAIN'), '{}') as skills,
       coalesce((select array_agg(k.machine_code order by k.machine_code) from master.operator_skills k where k.operator_code = o.code and k.level = 'LEARNING'), '{}') as learning,
       o.full_name, o.note
from master.operators o where o.active;

-- Mọi người (cả người đã ngừng) cho màn hình Nhân sự xưởng
create or replace view app.v_operators_all with (security_invoker = true) as
select o.code, o.full_name, o.job, o.extra, o.note, o.active, o.stopped_at, o.sort, o.is_deputy, o.keeps_fg, o.profile_id,
       app.user_name(o.profile_id) as profile_name, o.created_at,
       coalesce((select jsonb_agg(jsonb_build_object('machine', k.machine_code, 'level', k.level, 'signed', k.signed_at is not null) order by k.machine_code)
                 from master.operator_skills k where k.operator_code = o.code), '[]') as skills
from master.operators o;

create or replace view app.v_kh_absences with (security_invoker = true) as
select a.*, o.full_name, app.user_name(a.created_by) as created_by_name
from plan.operator_absences a join master.operators o on o.code = a.operator_code;

create or replace view app.v_kh_covers with (security_invoker = true) as
select c.*, o.full_name, app.user_name(c.created_by) as created_by_name,
       coalesce((select k.level from master.operator_skills k where k.operator_code = c.operator_code and k.machine_code = c.machine_code), 'NONE') as skill
from plan.operator_covers c join master.operators o on o.code = c.operator_code;

create or replace view app.v_kh_crew_days with (security_invoker = true) as
select c.*, app.user_name(c.set_by) as set_by_name from plan.crew_days c;

create or replace view app.v_machine_avail with (security_invoker = true) as
select a.*, m.name as machine_name, m.machine_type, cfg.fill_pct as base_fill_pct, cfg.avail_learn, cfg.avail_min_days, cfg.avail_floor_pct, cfg.avail_days,
  -- tỷ lệ riêng theo tỷ lệ chung hiện tại (lịch máy dùng số này)
  least(cfg.fill_pct, greatest(cfg.avail_floor_pct, round(cfg.fill_pct - a.down_pct, 1))) as fill_now
from master.machine_avail a join master.machines m on m.code = a.machine_code cross join master.planning_config cfg where cfg.id = 1;

-- Lịch máy: thêm cột đoạn người có mặt (attend) và số người đóng gói (crew) – thêm cuối
create or replace view app.v_kh_slots with (security_invoker = true) as select * from plan.schedule_slots;

-- Tham số xếp lịch: giữ nguyên các cột cũ (migration 4800), thêm thông số người, lịch vắng, kiêm nhiệm, tổ đóng gói, tỷ lệ riêng, bảo dưỡng
create or replace view app.v_kh_config with (security_invoker = true) as
select c.id, c.fill_pct, c.frozen_days, c.cutoff_time, c.downtime_reason_min, c.plc_dev_pct, c.auto_shifts, c.plc_loss_min,
  c.machines_per_operator, c.updated_at, c.updated_by, c.group_days,
  (select jsonb_agg(to_jsonb(s.*) order by s.code) from master.shifts s) as shifts,
  (select jsonb_agg(to_jsonb(r.*) order by r.sort) from master.machine_rates r) as rates,
  (select jsonb_agg(to_jsonb(x.*) order by x.sort) from master.changeover_rules x) as changeovers,
  coalesce(mfg.machine_setting('shift') -> 'workdays', '[1, 2, 3, 4, 5, 6]'::jsonb) as workdays,
  (select jsonb_agg(jsonb_build_object('machine_code', m.code, 'op_code', s.op_code, 'product_id', s.product_id, 'group_code', s.group_code,
      'core_code', s.core_code, 'std_mpm', s.std_mpm, 'rated_mpm', s.rated_mpm,
      'max_mpm', (select rg.max_value from master.machine_ranges rg where rg.machine_id = s.machine_id and rg.param = 'SPEED_MPM' limit 1),
      'status', s.status, 'submitted_at', s.submitted_at, 'label', s.label) order by m.code, s.op_code, s.submitted_at)
   from master.machine_speeds s join master.machines m on m.id = s.machine_id
   where s.status <> 'OBSOLETE' and m.active) as speeds,
  app.kh_plc_speeds() as plc_speeds,
  c.qc_min, c.qc_learn, c.unit_m, c.safety_min, c.pot_life_h, c.mix_batch_kg, c.mix_early_max_h, c.ot_max_min, c.ot_month_h,
  c.size_large_mm2, c.plc_min_run, c.pick_window_min, c.extra_min, c.mix_early_h, c.ot_from, c.ot_until, c.ot_request_id,
  case when (now() at time zone 'Asia/Ho_Chi_Minh')::date between coalesce(c.ot_from, '-infinity'::date) and coalesce(c.ot_until, 'infinity'::date)
       then c.extra_min else '{}'::jsonb end as extra_min_now,
  case when (now() at time zone 'Asia/Ho_Chi_Minh')::date between coalesce(c.ot_from, '-infinity'::date) and coalesce(c.ot_until, 'infinity'::date)
       then c.mix_early_h else 0 end as mix_early_h_now,
  plan.qc_learned(30) as qc_learned,
  -- 5000: người đứng máy, nhân sự xưởng, tỷ lệ riêng, bảo dưỡng theo kế hoạch
  c.start_min, c.bobbin_min, c.watch_max, c.pack_crew, c.pack_one_pct, c.avail_learn, c.avail_days, c.avail_min_days, c.avail_floor_pct,
  coalesce((select jsonb_agg(jsonb_build_object('code', a.operator_code, 'from', a.date_from, 'to', a.date_to, 'part', a.part) order by a.date_from)
            from plan.operator_absences a where a.date_to >= (now() at time zone 'Asia/Ho_Chi_Minh')::date - 60), '[]') as absences,
  coalesce((select jsonb_agg(jsonb_build_object('code', v.operator_code, 'machine', v.machine_code, 'from', v.date_from, 'to', v.date_to) order by v.date_from)
            from plan.operator_covers v where v.date_to >= (now() at time zone 'Asia/Ho_Chi_Minh')::date - 60), '[]') as covers,
  coalesce((select jsonb_agg(jsonb_build_object('date', d.work_date, 'machine', d.machine_code, 'crew', d.crew, 'members', d.members) order by d.work_date)
            from plan.crew_days d where d.work_date >= (now() at time zone 'Asia/Ho_Chi_Minh')::date - 60), '[]') as crews,
  coalesce((select jsonb_object_agg(a.machine_code, jsonb_build_object('fill', least(c.fill_pct, greatest(c.avail_floor_pct, round(c.fill_pct - a.down_pct, 1))), 'down_pct', a.down_pct, 'days', a.tracked_days))
            from master.machine_avail a where a.enough and c.avail_learn), '{}') as avail,
  plan.kh_maint_due() as maint_plans
from master.planning_config c
where c.id = 1;

grant select on app.v_kh_operators, app.v_operators_all, app.v_kh_absences, app.v_kh_covers, app.v_kh_crew_days, app.v_machine_avail,
  app.v_kh_slots, app.v_kh_config to authenticated;

-- ===========================================================================
-- 8. Lưu lịch máy: thêm đoạn người có mặt (attend) và số người đóng gói (crew)
-- ===========================================================================
create or replace function app.kh_save_schedule(p_plan uuid, p_base date, p_params jsonb, p_orders jsonb, p_slots jsonb,
                                               p_reason text, p_change uuid default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid; v_ver integer; v_base date; c plan.change_requests; v_direct boolean; pp plan.production_plans;
begin
  if not app.kh_has_any(array['SX_TP','SX_KH','BGD']) then raise exception 'Chỉ TP SX (Kế hoạch SX) hoặc Giám đốc được xếp lịch máy'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Thiếu lý do xếp lịch'; end if;
  select * into pp from plan.production_plans where id = p_plan for update;
  if not found then raise exception 'Không tìm thấy kế hoạch'; end if;
  select base_date into v_base from plan.schedule_versions where plan_id = p_plan and is_current;
  if v_base is not null and v_base <> p_base then raise exception 'Ngày gốc của lịch không khớp phiên bản đang dùng'; end if;
  if p_change is not null then
    select * into c from plan.change_requests where id = p_change for update;
    if c.status <> 'LINE_ADDED' then raise exception 'Đơn phát sinh chưa đủ bước duyệt'; end if;
  end if;
  v_direct := p_change is not null or plan.is_gd();
  select coalesce(max(version), 0) + 1 into v_ver from plan.schedule_versions where plan_id = p_plan;
  update plan.schedule_versions set status = 'SUPERSEDED' where plan_id = p_plan and status = 'PROPOSED';
  if v_direct then
    update plan.schedule_versions set is_current = false where plan_id = p_plan and is_current;
  end if;
  insert into plan.schedule_versions (plan_id, version, base_date, params, reason, change_request_id, is_current, status, approved_by, approved_at)
  values (p_plan, v_ver, p_base, p_params, trim(p_reason), p_change, v_direct, case when v_direct then 'APPROVED' else 'PROPOSED' end,
          case when v_direct then auth.uid() end, case when v_direct then now() end)
  returning id into v_id;
  insert into plan.schedule_orders (version_id, plan_line_id, label, product_code, product_name, group_code, qty_m, due_date, priority, source, finish_date, meta)
  select v_id, (e->>'plan_line_id')::uuid, e->>'label', e->>'product_code', e->>'product_name', e->>'group_code', (e->>'qty_m')::numeric,
         nullif(e->>'due_date', '')::date, coalesce((e->>'priority')::smallint, 1), e->>'source', nullif(e->>'finish_date', '')::date,
         coalesce(e->'meta', '{}')
  from jsonb_array_elements(p_orders) e;
  insert into plan.schedule_slots (version_id, plan_line_id, op_code, color, machine_code, operator_code, lane, start_min, run_start_min,
                                   end_min, setup_min, meters, rate, speed, reason, setup_why, part, attend, crew)
  select v_id, (e->>'plan_line_id')::uuid, e->>'op_code', nullif(e->>'color', ''), e->>'machine_code', e->>'operator_code',
         coalesce((e->>'lane')::smallint, 0), (e->>'start_min')::numeric, (e->>'run_start_min')::numeric, (e->>'end_min')::numeric,
         coalesce((e->>'setup_min')::numeric, 0), (e->>'meters')::numeric, (e->>'rate')::numeric, (e->>'speed')::numeric,
         e->>'reason', e->>'setup_why', coalesce((e->>'part')::boolean, false),
         case when jsonb_typeof(e->'attend') = 'array' then e->'attend' end, nullif(e->>'crew', '')::smallint
  from jsonb_array_elements(p_slots) e;
  if p_change is not null then
    update plan.change_requests set status = 'APPLIED', finished_at = now() where id = p_change;
  end if;
  if not v_direct then
    perform wf.notify_users(array_remove(plan.gd_ids(), auth.uid()), 'Lịch máy chờ duyệt: ' || pp.plan_no || ' bản ' || v_ver,
      app.user_name(auth.uid()) || ' xếp lịch: ' || left(trim(p_reason), 300) || '. Giám đốc duyệt thì lịch mới thay lịch đang dùng.',
      '/lich-may?plan=' || p_plan || '&xem=de-xuat');
  end if;
  return v_id;
end $$;

-- ===========================================================================
-- 9. Kiểm tra năng lực (app.check_capacity): máy Dừng trừ năng lực như máy Hỏng, tỷ lệ riêng từng máy,
--    cảnh báo người theo ngưỡng "một người trông quá N máy" (không còn giới hạn 2 máy/người)
-- ===========================================================================
do $$
declare d text; o text;
begin
  d := pg_get_functiondef('app.check_capacity(uuid, date, date, integer, numeric, jsonb)'::regprocedure);
  o := d;
  d := replace(d, $x$v_maxop int := coalesce((mfg.machine_setting('max_machines_per_operator'))::text::int, 2);$x$,
                  $x$v_maxop int := coalesce((select watch_max from master.planning_config where id = 1), 6);$x$);
  d := replace(d, $x$v_gross := v_days * (v_min * p_shifts + coalesce(p_ot_hours, 0) * 60) * v_fill;$x$,
                  $x$v_gross := v_days * (v_min * p_shifts + coalesce(p_ot_hours, 0) * 60) * v_fill * plan.avail_factor(mc.code);$x$);
  d := replace(d, $x$if mc.status in ('DOWN','MAINT') then$x$, $x$if mc.status in ('DOWN','MAINT','STOP') then$x$);
  d := replace(d, $x$v_note := case mc.status when 'DOWN' then 'Hỏng' else 'Bảo dưỡng' end$x$,
                  $x$v_note := case mc.status when 'DOWN' then 'Hỏng' when 'STOP' then 'Dừng' else 'Bảo dưỡng' end$x$);
  d := replace(d, $x$'text', format('Thiếu người: cần chạy cùng lúc khoảng %s dây chuyền, %s người đứng chính chỉ đứng được %s máy (tối đa %s máy/người)', v_need, v_people, v_pcap, v_maxop),$x$,
                  $x$'text', format('Thiếu người: cần chạy cùng lúc khoảng %s dây chuyền, %s người đứng chính chỉ trông được %s máy (cảnh báo khi một người trông quá %s máy)', v_need, v_people, v_pcap, v_maxop),$x$);
  if position('watch_max from master.planning_config' in d) = 0 or position('plan.avail_factor(mc.code)' in d) = 0
     or position($x$('DOWN','MAINT','STOP')$x$ in d) = 0 or position('cảnh báo khi một người trông quá' in d) = 0 then
    raise exception 'Không vá được app.check_capacity (định nghĩa khác bản dự kiến)';
  end if;
  execute d;
end $$;

-- Kiểm tra lệnh ngày, thông tin chung trên Tổng quan: máy Dừng cũng là máy không chạy được
do $$
declare d text;
begin
  d := pg_get_functiondef('app.kh_day_preview(uuid, date)'::regprocedure);
  d := replace(d, $x$case m.status when 'DOWN' then 'hỏng' when 'MAINT' then 'đang bảo dưỡng' else 'ngừng dùng' end$x$,
                  $x$case m.status when 'DOWN' then 'hỏng' when 'STOP' then 'dừng' when 'MAINT' then 'đang bảo dưỡng' else 'ngừng dùng' end$x$);
  d := replace(d, $x$where m.status in ('DOWN','MAINT','OFF')$x$, $x$where m.status in ('DOWN','STOP','MAINT','OFF')$x$);
  if position($x$('DOWN','STOP','MAINT','OFF')$x$ in d) = 0 or position($x$when 'STOP' then 'dừng'$x$ in d) = 0 then
    raise exception 'Không vá được app.kh_day_preview (định nghĩa khác bản dự kiến)';
  end if;
  execute d;
  d := pg_get_functiondef('app.shared_overview()'::regprocedure);
  d := replace(d, $x$m.status in ('DOWN', 'MAINT')))$x$, $x$m.status in ('DOWN', 'STOP', 'MAINT')))$x$);
  if position($x$('DOWN', 'STOP', 'MAINT')$x$ in d) = 0 then raise exception 'Không vá được app.shared_overview (định nghĩa khác bản dự kiến)'; end if;
  execute d;
end $$;

-- ===========================================================================
-- 10. Mục menu Nhân sự xưởng
-- ===========================================================================
insert into core.pages (key, path, label, grp, sort) values ('nhan-su-xuong', '/nhan-su-xuong', 'Nhân sự xưởng', 'Sản xuất', 29)
on conflict (key) do update set path = excluded.path, label = excluded.label, grp = excluded.grp, sort = excluded.sort;
insert into core.role_pages (role_code, page_key)
select r, 'nhan-su-xuong' from unnest(array['BGD','SX_TP','SX_KH','TO_TRUONG','KT_TP']) r
where exists (select 1 from core.roles where code = r)
on conflict do nothing;

-- ===========================================================================
-- 11. Quyền gọi hàm, lịch chạy hằng đêm
-- ===========================================================================
revoke all on function app.kh_save_operator(text, text, text, text, text, uuid, text), app.kh_set_operator_active(text, boolean, text),
  app.kh_save_absence(uuid, text, date, date, text, text, text), app.kh_delete_absence(uuid, text),
  app.kh_save_cover(uuid, text, text, date, date, text), app.kh_delete_cover(uuid, text),
  app.kh_set_crew(date, text, integer, text[], text), app.kh_save_people(jsonb, text),
  app.avail_exclude(uuid, boolean, text), app.avail_events(text) from public, anon;
grant execute on function app.kh_save_operator(text, text, text, text, text, uuid, text), app.kh_set_operator_active(text, boolean, text),
  app.kh_save_absence(uuid, text, date, date, text, text, text), app.kh_delete_absence(uuid, text),
  app.kh_save_cover(uuid, text, text, date, date, text), app.kh_delete_cover(uuid, text),
  app.kh_set_crew(date, text, integer, text[], text), app.kh_save_people(jsonb, text),
  app.avail_exclude(uuid, boolean, text), app.avail_events(text) to authenticated;

select plan.calc_machine_avail();

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('bmt_machine_avail', '5 17 * * *', 'select plan.calc_machine_avail()');   -- 00:05 giờ VN
  end if;
exception when others then
  raise notice 'Chưa đặt được lịch bmt_machine_avail: %', sqlerrm;
end $$;

-- Lịch đang dùng cần xếp lại (thuật toán người đứng máy mới, tỷ lệ 90 %)
insert into master.planning_param_log (section, item, old_value, new_value, reason)
values ('Thuật toán xếp lịch', 'Người đứng máy, máy dừng, bảo dưỡng', 'Giữ người suốt khối, 2 máy/người, bỏ qua máy Dừng',
        'Người có mặt lúc khởi động, thay bobin; trộn, đóng gói liên tục; máy Dừng chặn lịch; giữ chỗ bảo dưỡng; tỷ lệ riêng theo hỏng',
        'Anh Bình duyệt 28/10/2026 (phương án bản 2)');
