-- Ca làm việc khai báo tự do + luân phiên đứng máy + bảng phân ca tuần (anh Bình duyệt 28/10/2026, Claude Doc
-- "BMT MES – Phương án sử dụng nhân lực: ca 2 và luân phiên đứng máy", 11 điểm; điểm 1 sửa lại):
--  1. Giờ ca là biến số, Giám đốc khai báo ở Tham số xếp lịch (ca 1, ca 2, ca 3 nối tiếp nhau, không chồng giờ). Tạm tính ca 1 06:00–14:00,
--     ca 2 14:00–22:00 (ca 3 22:00–06:00). Ca 1 là ca cả xưởng; ca 2, ca 3 chỉ máy được duyệt trong bảng ca tuần.
--  2. Mỗi người làm ca 2 trọn tuần, đổi ca vào Chủ nhật (nghỉ ≥ 12 giờ khi đổi ca).
--  3. Ca 2 tối thiểu 2 người, TP SX chỉ định 1 người phụ trách ca.
--  4. MES đề xuất người rảnh làm ca 2, xoay vòng theo số tuần đã làm ca 2; TP SX sửa; Giám đốc duyệt một lần cả ca máy và ca người.
--     Bổ sung: trước 12:00 thứ 7 hằng tuần MES gửi lịch ca cho nhân viên sau khi TP SX, Giám đốc duyệt; lịch máy ghi rõ máy nào chạy ca 1, ca 2.
--  5–7. Xếp người ít giờ đứng máy cộng dồn 4 tuần trước (không để máy chờ); máy trộn, đóng gói đổi người đầu ngày khi lệch quá 15 %;
--     sổ giờ đứng máy, cảnh báo TP SX khi lệch quá 15 % (Giám đốc sửa ngưỡng).
--  8. Mọi công nhân đứng chính mọi máy (không chuyên trách dây chuyền nào); TP KT/QA ký lại tay nghề.
--  9. MES đề xuất thêm ca cả khi không trễ hạn, nếu có người rảnh cả ngày.
-- 10. Ca 2 phải có người đo mẫu QC: QC làm ca 2 hoặc ủy quyền người phụ trách ca 2.
-- Bộ xếp lịch, đề xuất bảng ca ở web (lib/kh/scheduler.ts, lib/kh/roster.ts).

-- ===========================================================================
-- 1. Ca làm việc: ca 1, ca 2, ca 3 nối tiếp nhau, giờ do Giám đốc khai báo
-- ===========================================================================
alter table master.planning_config add column if not exists balance_pct numeric not null default 15;
alter table master.planning_config drop constraint if exists planning_config_balance_chk;
alter table master.planning_config add constraint planning_config_balance_chk check (balance_pct between 5 and 50);

-- Phút trong ngày của một giờ (time)
create or replace function plan.tmin(p time) returns integer
language sql immutable set search_path = pg_catalog, public as $$ select (extract(hour from p) * 60 + extract(minute from p))::int $$;

-- p = [{code, start_time, end_time, break_min}] (thiếu ca nào thì giữ giá trị cũ); ca 1 luôn chạy cả xưởng, ca 2 / ca 3 chỉ máy được duyệt
create or replace function app.kh_save_shifts(p jsonb, p_reason text) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare e jsonb; s master.shifts; n integer := 0; v jsonb := '{}'; c text; st time; en time; br int; span int;
  sA int; sB int; sC int; oB int; oC int; v_lbl jsonb := '{"A":"Ca 1","B":"Ca 2","C":"Ca 3"}';
begin
  if not core.has_role('BGD') then raise exception 'Chỉ Giám đốc được sửa ca làm việc'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do thay đổi'; end if;
  if jsonb_typeof(coalesce(p, 'null')) <> 'array' then raise exception 'Thiếu giờ ca'; end if;
  -- giá trị mới của 3 ca (ca không gửi lên giữ giá trị cũ)
  for s in select * from master.shifts where code in ('A', 'B', 'C') loop
    v := v || jsonb_build_object(s.code, jsonb_build_object('start', s.start_time, 'end', s.end_time, 'break', s.break_min));
  end loop;
  for e in select * from jsonb_array_elements(p) loop
    c := e ->> 'code';
    if c not in ('A', 'B', 'C') then raise exception 'Không có ca %', c; end if;
    begin
      st := (e ->> 'start_time')::time; en := (e ->> 'end_time')::time; br := (e ->> 'break_min')::int;
    exception when others then raise exception '%: giờ nhập dạng HH:MM, phút nghỉ là số nguyên', v_lbl ->> c;
    end;
    if st is null or en is null or br is null then raise exception '%: nhập đủ giờ bắt đầu, giờ kết thúc, phút nghỉ', v_lbl ->> c; end if;
    v := jsonb_set(v, array[c], jsonb_build_object('start', st, 'end', en, 'break', br));
  end loop;
  for c in select unnest(array['A', 'B', 'C']) loop
    st := (v -> c ->> 'start')::time; en := (v -> c ->> 'end')::time; br := (v -> c ->> 'break')::int;
    span := (plan.tmin(en) - plan.tmin(st) + 1440) % 1440;
    if span = 0 then span := 1440; end if;
    if br < 0 or br > 90 then raise exception '%: phút nghỉ từ 0 đến 90', v_lbl ->> c; end if;
    if span < 240 or span > 720 then raise exception '%: một ca dài từ 4 đến 12 giờ (đang % giờ)', v_lbl ->> c, replace(trim_scale(round(span / 60.0, 2))::text, '.', ','); end if;
    if span - br < 180 then raise exception '%: phút chạy (trừ nghỉ) phải từ 180 trở lên', v_lbl ->> c; end if;
  end loop;
  -- ca 2 bắt đầu khi (hoặc sau khi) ca 1 kết thúc, ca 3 sau ca 2, ca 3 kết thúc trước giờ vào ca 1 hôm sau
  sA := (plan.tmin((v -> 'A' ->> 'end')::time) - plan.tmin((v -> 'A' ->> 'start')::time) + 1440) % 1440; if sA = 0 then sA := 1440; end if;
  sB := (plan.tmin((v -> 'B' ->> 'end')::time) - plan.tmin((v -> 'B' ->> 'start')::time) + 1440) % 1440; if sB = 0 then sB := 1440; end if;
  sC := (plan.tmin((v -> 'C' ->> 'end')::time) - plan.tmin((v -> 'C' ->> 'start')::time) + 1440) % 1440; if sC = 0 then sC := 1440; end if;
  oB := (plan.tmin((v -> 'B' ->> 'start')::time) - plan.tmin((v -> 'A' ->> 'start')::time) + 1440) % 1440;
  oC := (plan.tmin((v -> 'C' ->> 'start')::time) - plan.tmin((v -> 'A' ->> 'start')::time) + 1440) % 1440;
  if oB < sA then raise exception 'Ca 2 phải bắt đầu từ lúc ca 1 kết thúc (ca 1 % – %) trở đi: hai ca không chồng giờ',
    left(v -> 'A' ->> 'start', 5), left(v -> 'A' ->> 'end', 5); end if;
  if oC < oB + sB then raise exception 'Ca 3 phải bắt đầu từ lúc ca 2 kết thúc (ca 2 % – %) trở đi', left(v -> 'B' ->> 'start', 5), left(v -> 'B' ->> 'end', 5); end if;
  if oC + sC > 1440 then raise exception 'Ca 3 phải kết thúc trước giờ vào ca 1 hôm sau (%)', left(v -> 'A' ->> 'start', 5); end if;
  for s in select * from master.shifts where code in ('A', 'B', 'C') order by code for update loop
    c := s.code; st := (v -> c ->> 'start')::time; en := (v -> c ->> 'end')::time; br := (v -> c ->> 'break')::int;
    if s.start_time <> st then perform app.kh_log('Ca làm việc', (v_lbl ->> c) || ' · giờ bắt đầu', left(s.start_time::text, 5), left(st::text, 5), trim(p_reason)); n := n + 1; end if;
    if s.end_time <> en then perform app.kh_log('Ca làm việc', (v_lbl ->> c) || ' · giờ kết thúc', left(s.end_time::text, 5), left(en::text, 5), trim(p_reason)); n := n + 1; end if;
    if s.break_min <> br then perform app.kh_log('Ca làm việc', (v_lbl ->> c) || ' · phút nghỉ', s.break_min::text, br::text, trim(p_reason)); n := n + 1; end if;
    if s.active <> (c = 'A') then perform app.kh_log('Ca làm việc', (v_lbl ->> c) || ' · trạng thái', case when s.active then 'Cả xưởng' else 'Theo máy' end,
      case when c = 'A' then 'Cả xưởng' else 'Theo máy (bảng ca tuần)' end, trim(p_reason)); n := n + 1; end if;
    update master.shifts set start_time = st, end_time = en, break_min = br, active = (c = 'A') where code = c;
  end loop;
  if n = 0 then raise exception 'Không có thay đổi'; end if;
  perform app.kh_notify_role('SX_TP', 'Ca làm việc đã đổi', 'Giám đốc đã sửa giờ ca làm việc. Bấm Xếp lại lịch để áp dụng.', '/lich-may');
  return n;
end $$;

-- Tạm tính theo anh Bình 28/10/2026 (Giám đốc chỉnh lại ở Tham số xếp lịch): ca 1 06:00–14:00, ca 2 14:00–22:00, ca 3 22:00–06:00;
-- nghỉ giữa ca 30 phút (ca 3 làm đêm: 45 phút, Bộ luật Lao động Điều 109)
do $$
declare s master.shifts; v jsonb := '{"A":["06:00","14:00",30],"B":["14:00","22:00",30],"C":["22:00","06:00",45]}'; c text;
  v_lbl jsonb := '{"A":"Ca 1","B":"Ca 2","C":"Ca 3"}'; v_why text := 'Anh Bình 28/10/2026: tạm tính ca 1 06:00–14:00, ca 2 14:00–22:00; Giám đốc chỉnh ở Tham số xếp lịch';
begin
  for s in select * from master.shifts where code in ('A', 'B', 'C') order by code loop
    c := s.code;
    if left(s.start_time::text, 5) <> v -> c ->> 0 then perform app.kh_log('Ca làm việc', (v_lbl ->> c) || ' · giờ bắt đầu', left(s.start_time::text, 5), v -> c ->> 0, v_why); end if;
    if left(s.end_time::text, 5) <> v -> c ->> 1 then perform app.kh_log('Ca làm việc', (v_lbl ->> c) || ' · giờ kết thúc', left(s.end_time::text, 5), v -> c ->> 1, v_why); end if;
    if s.break_min <> (v -> c ->> 2)::int then perform app.kh_log('Ca làm việc', (v_lbl ->> c) || ' · phút nghỉ', s.break_min::text, v -> c ->> 2, v_why); end if;
    update master.shifts set start_time = (v -> c ->> 0)::time, end_time = (v -> c ->> 1)::time, break_min = (v -> c ->> 2)::int, active = (c = 'A')
     where code = c;
  end loop;
end $$;

-- Ngưỡng lệch giờ đứng máy (Giám đốc)
create or replace function app.kh_save_balance(p_pct numeric, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_old numeric;
begin
  if not core.has_role('BGD') then raise exception 'Chỉ Giám đốc sửa ngưỡng lệch giờ đứng máy'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do thay đổi'; end if;
  if p_pct is null or p_pct < 5 or p_pct > 50 then raise exception 'Ngưỡng lệch giờ đứng máy từ 5 đến 50 %%'; end if;
  select balance_pct into v_old from master.planning_config where id = 1 for update;
  if v_old = p_pct then raise exception 'Không có thay đổi'; end if;
  update master.planning_config set balance_pct = p_pct, updated_at = now(), updated_by = auth.uid() where id = 1;
  perform app.kh_log('Tham số xếp lịch', 'Giờ đứng máy lệch tối đa so với bình quân (%)', v_old::text, p_pct::text, trim(p_reason));
end $$;
revoke all on function app.kh_save_balance(numeric, text) from public, anon;
grant execute on function app.kh_save_balance(numeric, text) to authenticated;

-- ===========================================================================
-- 2. Tay nghề: mọi công nhân đứng chính mọi máy (anh Bình 28/10/2026); TP KT/QA ký lại
-- ===========================================================================
insert into master.operator_skills (operator_code, machine_code, level)
select o.code, m.code, 'MAIN' from master.operators o cross join master.machines m
where o.active and plan.is_sched_machine(m.code)
on conflict (operator_code, machine_code) do update set level = 'MAIN', signed_by = null, signed_at = null
  where master.operator_skills.level <> 'MAIN';

do $$
begin
  if exists (select 1 from master.operators where active) then
    perform app.kh_log('Người đứng máy', (select string_agg(code, ', ' order by sort) from master.operators where active) || ' · mọi máy',
      'Theo dây chuyền', 'Đứng chính mọi máy', 'Anh Bình 28/10/2026: công nhân vận hành được mọi thiết bị, không chuyên trách dây chuyền nào');
    perform app.kh_notify_role('KT_TP', 'Tay nghề chờ ký: công nhân đứng chính mọi máy',
      'Anh Bình 28/10/2026: mọi công nhân vận hành được mọi thiết bị. TP KT/QA ký lại tay nghề ở Nhân sự xưởng → Người × máy (Ký tất cả).', '/nhan-su-xuong?tab=tay-nghe');
  end if;
end $$;

-- TP SX giao một người đứng chính mọi máy xếp lịch (người mới vào)
create or replace function app.kh_skill_all(p_code text, p_reason text default null) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare n integer;
begin
  if not (core.has_role('SX_TP') or core.has_perm('machine', 'config')) then raise exception 'Chỉ Quản lý SX hoặc TP Kỹ thuật/QA giao người đứng máy'; end if;
  if not exists (select 1 from master.operators where code = p_code and active) then raise exception 'Không có người đứng máy %', p_code; end if;
  insert into master.operator_skills (operator_code, machine_code, level, assigned_by)
  select p_code, m.code, 'MAIN', auth.uid() from master.machines m where plan.is_sched_machine(m.code)
  on conflict (operator_code, machine_code) do update set level = 'MAIN', assigned_by = excluded.assigned_by, signed_by = null, signed_at = null
    where master.operator_skills.level <> 'MAIN';
  get diagnostics n = row_count;
  if n = 0 then raise exception '% đã đứng chính mọi máy', p_code; end if;
  perform app.kh_log('Người đứng máy', p_code || ' · mọi máy', 'Một số máy', 'Đứng chính mọi máy', coalesce(nullif(trim(coalesce(p_reason, '')), ''), 'Đứng được mọi máy'));
  perform app.kh_notify_role('KT_TP', 'Tay nghề chờ ký: ' || p_code || ' · mọi máy', n || ' máy mới giao. Ký ở Nhân sự xưởng → Người × máy.', '/nhan-su-xuong?tab=tay-nghe');
  return n;
end $$;
revoke all on function app.kh_skill_all(text, text) from public, anon;
grant execute on function app.kh_skill_all(text, text) to authenticated;

-- TP KT/QA ký một lần mọi tay nghề chưa ký (của một người hoặc của mọi người); không ký tay nghề do chính mình giao
create or replace function app.sign_skills_all(p_operator text default null) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare n integer;
begin
  if not core.has_role('KT_TP') then raise exception 'Chỉ TP Kỹ thuật/QA xác nhận tay nghề'; end if;
  update master.operator_skills k set signed_by = auth.uid(), signed_at = now()
   where k.signed_at is null and k.assigned_by is distinct from auth.uid() and (p_operator is null or k.operator_code = p_operator)
     and exists (select 1 from master.operators o where o.code = k.operator_code and o.active);
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Không còn tay nghề nào chờ ký (tay nghề do chính bạn giao chờ TP KT/QA khác ký)'; end if;
  return n;
end $$;
revoke all on function app.sign_skills_all(text) from public, anon;
grant execute on function app.sign_skills_all(text) to authenticated;

-- ===========================================================================
-- 3. Sổ giờ đứng máy theo lịch máy đang dùng (phút thật mỗi người mỗi ngày, gồm giờ làm đêm)
-- ===========================================================================
-- Bộ xếp lịch web tính giờ có mặt của từng người (khởi động, thay bobin, đứng máy trộn / đóng gói) và lưu trong params.hours của bản lịch;
-- khi bản lịch thành lịch đang dùng thì ghi vào sổ từ hôm nay (ngày đã qua giữ như lịch lúc đó).
create table if not exists plan.operator_day_hours (
  plan_id       uuid not null references plan.production_plans(id) on delete cascade,
  work_date     date not null,
  operator_code text not null,
  attend_min    numeric not null default 0,
  night_min     numeric not null default 0,
  shift_no      integer not null default 1,
  version_id    uuid,
  updated_at    timestamptz not null default now(),
  primary key (plan_id, work_date, operator_code)
);
create index if not exists operator_day_hours_op_idx on plan.operator_day_hours (operator_code, work_date);
alter table plan.operator_day_hours enable row level security;
drop policy if exists p_select on plan.operator_day_hours;
create policy p_select on plan.operator_day_hours for select to authenticated using (app.kh_can_view());
grant select on plan.operator_day_hours to authenticated;

create or replace function plan.ledger_apply(p_version uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v plan.schedule_versions; v_today date := plan.vn_today();
begin
  select * into v from plan.schedule_versions where id = p_version;
  if not found or not v.is_current then return; end if;
  delete from plan.operator_day_hours where plan_id = v.plan_id and work_date >= v_today;
  insert into plan.operator_day_hours (plan_id, work_date, operator_code, attend_min, night_min, shift_no, version_id)
  select v.plan_id, (e ->> 'd')::date, e ->> 'p', round(sum((e ->> 'm')::numeric), 1), round(sum(coalesce((e ->> 'n')::numeric, 0)), 1),
         max(coalesce((e ->> 's')::int, 1)), v.id
  from jsonb_array_elements(case when jsonb_typeof(v.params -> 'hours') = 'array' then v.params -> 'hours' else '[]'::jsonb end) e
  where (e ->> 'd')::date >= v_today and exists (select 1 from master.operators o where o.code = e ->> 'p')
  group by (e ->> 'd')::date, e ->> 'p';
end $$;
revoke all on function plan.ledger_apply(uuid) from public, anon, authenticated;

create or replace function plan.trg_ledger() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if new.is_current and (tg_op = 'INSERT' or not old.is_current) then perform plan.ledger_apply(new.id); end if;
  return new;
end $$;
drop trigger if exists schedule_versions_ledger on plan.schedule_versions;
create trigger schedule_versions_ledger after insert or update of is_current on plan.schedule_versions
  for each row execute function plan.trg_ledger();

create or replace view app.v_kh_op_hours with (security_invoker = true) as
select h.operator_code, h.work_date, sum(h.attend_min) as attend_min, sum(h.night_min) as night_min, max(h.shift_no) as shift_no
from plan.operator_day_hours h group by h.operator_code, h.work_date;
grant select on app.v_kh_op_hours to authenticated;

-- ===========================================================================
-- 4. Bảng phân ca tuần: MES lập (web) → TP SX sửa, gửi → Giám đốc duyệt (được sửa) → gửi nhân viên trước 12:00 thứ 7
-- ===========================================================================
create table if not exists plan.week_rosters (
  id           uuid primary key default gen_random_uuid(),
  roster_no    text not null unique,
  week_start   date not null check (extract(isodow from week_start) = 1),
  plan_id      uuid references plan.production_plans(id) on delete set null,
  status       text not null default 'DRAFT' check (status in ('DRAFT', 'PROPOSED', 'APPROVED', 'RETURNED', 'CANCELLED', 'REPLACED')),
  machines     jsonb not null default '[]' check (jsonb_typeof(machines) = 'array'),   -- [{machine, date, shifts 2|3}] (không có: 1 ca)
  people       jsonb not null default '[]' check (jsonb_typeof(people) = 'array'),     -- [{code, shift 1|2|3, lead}] (không có: ca 1)
  qc           jsonb not null default '{}',                                            -- {mode: QC | LEAD, who}
  summary      jsonb not null default '{}',                                            -- MES tính: ngày xong, giờ mỗi người, thiếu người
  note         text,
  edits        jsonb not null default '[]',                                            -- Giám đốc sửa khi duyệt
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  submitted_by uuid,
  submitted_at timestamptz,
  reviewed_by  uuid,
  reviewed_at  timestamptz,
  review_note  text,
  sent_at      timestamptz,
  sent_late    boolean,
  request_id   uuid references plan.shift_requests(id) on delete set null
);
create unique index if not exists week_rosters_open on plan.week_rosters (week_start) where status in ('DRAFT', 'PROPOSED', 'RETURNED');
create index if not exists week_rosters_week_idx on plan.week_rosters (week_start, status);
alter table plan.week_rosters enable row level security;
drop policy if exists p_select on plan.week_rosters;
create policy p_select on plan.week_rosters for select to authenticated using (app.kh_can_view());
grant select on plan.week_rosters to authenticated;

-- Hạn gửi nhân viên: 12:00 thứ 7 trước tuần (giờ VN)
create or replace function plan.roster_deadline(p_week date) returns timestamptz
language sql immutable set search_path = pg_catalog, public as $$ select ((p_week - 2)::timestamp + interval '12 hours') at time zone 'Asia/Ho_Chi_Minh' $$;

create or replace function plan.shift_label(p_no integer) returns text
language sql stable security definer set search_path = pg_catalog, public as $$
  select 'ca ' || p_no || ' (' || to_char(s.start_time, 'HH24:MI') || '–' || to_char(s.end_time, 'HH24:MI') || ')'
  from master.shifts s where s.code = plan.shift_code(p_no)
$$;
revoke all on function plan.shift_label(integer) from public, anon, authenticated;

-- Kiểm nội dung bảng ca
create or replace function plan.roster_check(p_week date, p_machines jsonb, p_people jsonb, p_qc jsonb) returns void
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare it jsonb; m text; d date; n int; t text; i int := 0; v_max int := 1; v_no int; v_cnt int; v_lead int; x record;
begin
  if p_week is null or extract(isodow from p_week) <> 1 then raise exception 'Tuần phải bắt đầu từ thứ 2'; end if;
  if jsonb_typeof(coalesce(p_machines, 'null')) <> 'array' or jsonb_typeof(coalesce(p_people, 'null')) <> 'array' then raise exception 'Thiếu ca máy hoặc ca người'; end if;
  for it in select value from jsonb_array_elements(p_machines) loop
    i := i + 1;
    m := it ->> 'machine';
    begin d := (it ->> 'date')::date; n := (it ->> 'shifts')::int;
    exception when others then raise exception 'Ca máy dòng %: ngày hoặc số ca không hợp lệ', i; end;
    if not plan.is_sched_machine(coalesce(m, '')) then raise exception 'Máy % không phải dây chuyền xếp lịch', m; end if;
    if d is null or d < p_week or d > p_week + 6 then raise exception 'Máy %: ngày % không thuộc tuần %', m, to_char(d, 'DD/MM'), to_char(p_week, 'DD/MM'); end if;
    if not plan.is_workday(d) then raise exception 'Máy %: % là ngày nghỉ', m, to_char(d, 'DD/MM'); end if;
    if n is null or n not in (2, 3) then raise exception 'Máy % ngày %: chọn 2 hoặc 3 ca', m, to_char(d, 'DD/MM'); end if;
    v_max := greatest(v_max, n);
  end loop;
  if exists (select 1 from jsonb_array_elements(p_machines) a group by a ->> 'machine', a ->> 'date' having count(*) > 1) then
    raise exception 'Một máy một ngày chỉ một dòng ca';
  end if;
  -- silicone đã pha chỉ dùng trong hạn: line silicone chạy ca nào thì máy trộn chạy ca đó; máy trộn không chạy thêm ca một mình
  for x in select (a ->> 'date')::date as d, max(case when mm.machine_type = 'EXTRUDER_SI' then (a ->> 'shifts')::int end) as line_n,
                  max(case when mm.machine_type = 'MIXER' then (a ->> 'shifts')::int end) as mix_n
           from jsonb_array_elements(p_machines) a join master.machines mm on mm.code = a ->> 'machine' group by 1 loop
    if x.line_n is not null and exists (select 1 from master.machines z where z.machine_type = 'MIXER' and z.active and z.inline_with is null
         and coalesce((select (b ->> 'shifts')::int from jsonb_array_elements(p_machines) b where b ->> 'machine' = z.code and (b ->> 'date')::date = x.d), 1) < x.line_n) then
      raise exception 'Ngày %: line silicone chạy % ca thì máy trộn cũng chạy % ca (silicone đã pha chỉ dùng trong hạn)', to_char(x.d, 'DD/MM'), x.line_n, x.line_n;
    end if;
    if x.mix_n is not null and coalesce(x.line_n, 1) < x.mix_n then
      raise exception 'Ngày %: máy trộn chỉ thêm ca cùng line silicone', to_char(x.d, 'DD/MM');
    end if;
  end loop;
  -- người
  i := 0;
  for it in select value from jsonb_array_elements(p_people) loop
    i := i + 1;
    t := it ->> 'code';
    if not exists (select 1 from master.operators o where o.code = t and o.active) then raise exception 'Người % không có hoặc đã ngừng làm', t; end if;
    begin n := (it ->> 'shift')::int; exception when others then raise exception '%: ca không hợp lệ', t; end;
    if n is null or n not in (1, 2, 3) then raise exception '%: chọn ca 1, 2 hoặc 3', t; end if;
    if coalesce((it ->> 'lead')::boolean, false) and n = 1 then raise exception '%: người phụ trách chỉ chọn trong ca 2, ca 3', t; end if;
  end loop;
  if exists (select 1 from jsonb_array_elements(p_people) a group by a ->> 'code' having count(*) > 1) then raise exception 'Mỗi người chỉ một dòng ca'; end if;
  for v_no in 2..3 loop
    select count(*), count(*) filter (where coalesce((a ->> 'lead')::boolean, false)) into v_cnt, v_lead
    from jsonb_array_elements(p_people) a where (a ->> 'shift')::int = v_no;
    if exists (select 1 from jsonb_array_elements(p_machines) a where (a ->> 'shifts')::int >= v_no) then
      if v_cnt < 2 then raise exception 'Ca % cần ít nhất 2 người (không ai làm ca một mình), đang có %', v_no, v_cnt; end if;
      if v_lead <> 1 then raise exception 'Ca %: chọn đúng 1 người phụ trách ca', v_no; end if;
    elsif v_cnt > 0 then
      raise exception 'Có người làm ca % nhưng không máy nào chạy ca % trong tuần', v_no, v_no;
    end if;
  end loop;
  if v_max >= 2 then
    if coalesce(p_qc ->> 'mode', '') not in ('QC', 'LEAD') then raise exception 'Ca 2 phải có người đo mẫu QC: chọn QC làm ca 2 hoặc ủy quyền người phụ trách ca'; end if;
    if p_qc ->> 'mode' = 'QC' and coalesce(trim(p_qc ->> 'who'), '') = '' then raise exception 'Nhập tên người QC làm ca 2'; end if;
  end if;
end $$;
revoke all on function plan.roster_check(date, jsonb, jsonb, jsonb) from public, anon, authenticated;

-- Tóm tắt một dòng cho thông báo, nhật ký
create or replace function plan.roster_text(r plan.week_rosters) returns text
language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce(
    (select 'Máy chạy 2–3 ca: ' || string_agg(x.mc || ' ' || x.n || ' ca (' || x.k || ' ngày)', ', ' order by x.mc)
     from (select a ->> 'machine' as mc, max((a ->> 'shifts')::int) as n, count(*) as k from jsonb_array_elements(r.machines) a group by 1) x),
    'Mọi máy chạy ca 1')
  || coalesce(' · Ca 2: ' || (select string_agg(a ->> 'code' || case when coalesce((a ->> 'lead')::boolean, false) then ' (phụ trách)' else '' end, ', ' order by a ->> 'code')
                              from jsonb_array_elements(r.people) a where (a ->> 'shift')::int = 2), '')
  || coalesce(' · Ca 3: ' || (select string_agg(a ->> 'code' || case when coalesce((a ->> 'lead')::boolean, false) then ' (phụ trách)' else '' end, ', ' order by a ->> 'code')
                              from jsonb_array_elements(r.people) a where (a ->> 'shift')::int = 3), '')
$$;
revoke all on function plan.roster_text(plan.week_rosters) from public, anon, authenticated;

-- Lưu bảng ca: TP SX / Kế hoạch SX khi nháp hoặc bị trả lại; Giám đốc sửa khi đang chờ duyệt (ghi lịch sử, báo người gửi)
-- p = {id?, week_start, plan_id, machines, people, qc, summary, note}
create or replace function app.roster_save(p jsonb) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid; ws date; r plan.week_rosters; v_mon date := plan.vn_today() - (extract(isodow from plan.vn_today())::int - 1);
begin
  begin ws := (p ->> 'week_start')::date; v_id := nullif(p ->> 'id', '')::uuid;
  exception when others then raise exception 'Tuần hoặc mã bảng ca không hợp lệ'; end;
  if v_id is null then
    if ws is null then raise exception 'Chọn tuần'; end if;
    select id into v_id from plan.week_rosters where week_start = ws and status in ('DRAFT', 'PROPOSED', 'RETURNED');
  end if;
  if v_id is null then
    if not plan.can_staff() then raise exception 'Chỉ TP SX / Kế hoạch SX lập bảng ca tuần'; end if;
    if ws < v_mon then raise exception 'Không lập bảng ca cho tuần đã qua'; end if;
    perform plan.roster_check(ws, p -> 'machines', p -> 'people', coalesce(p -> 'qc', '{}'));
    insert into plan.week_rosters (roster_no, week_start, plan_id, machines, people, qc, summary, note)
    values (core.next_no('PCA', 3), ws, nullif(p ->> 'plan_id', '')::uuid, p -> 'machines', p -> 'people', coalesce(p -> 'qc', '{}'),
            coalesce(p -> 'summary', '{}'), nullif(trim(coalesce(p ->> 'note', '')), ''))
    returning id into v_id;
    return v_id;
  end if;
  select * into r from plan.week_rosters where id = v_id for update;
  if not found then raise exception 'Không tìm thấy bảng ca'; end if;
  if r.status in ('DRAFT', 'RETURNED') then
    if not plan.can_staff() then raise exception 'Chỉ TP SX / Kế hoạch SX sửa bảng ca nháp'; end if;
  elsif r.status = 'PROPOSED' then
    if not plan.is_gd() then raise exception 'Bảng ca % đang chờ Giám đốc duyệt: chỉ Giám đốc sửa', r.roster_no; end if;
    if r.submitted_by = auth.uid() then raise exception 'Người gửi không sửa bảng ca đang chờ duyệt'; end if;
  else
    raise exception 'Bảng ca % đã %: lập bảng mới cho tuần này để thay', r.roster_no,
      case r.status when 'APPROVED' then 'duyệt' when 'REPLACED' then 'được thay' else 'hủy' end;
  end if;
  perform plan.roster_check(r.week_start, p -> 'machines', p -> 'people', coalesce(p -> 'qc', '{}'));
  update plan.week_rosters set machines = p -> 'machines', people = p -> 'people', qc = coalesce(p -> 'qc', '{}'),
         summary = coalesce(p -> 'summary', summary), note = coalesce(nullif(trim(coalesce(p ->> 'note', '')), ''), note),
         plan_id = coalesce(nullif(p ->> 'plan_id', '')::uuid, plan_id), updated_at = now(),
         edits = case when r.status = 'PROPOSED' then edits || jsonb_build_array(jsonb_build_object('by', auth.uid(), 'by_name', app.user_name(auth.uid()), 'at', now(),
                   'before', plan.roster_text(r), 'note', nullif(trim(coalesce(p ->> 'edit_note', '')), ''))) else edits end
   where id = v_id;
  if r.status = 'PROPOSED' then
    select * into r from plan.week_rosters where id = v_id;
    perform wf.notify_users(array_remove(array[r.submitted_by], null), 'Giám đốc sửa bảng ca ' || r.roster_no,
      plan.roster_text(r) || coalesce(' · ' || nullif(trim(coalesce(p ->> 'edit_note', '')), ''), ''), '/nhan-su-xuong?tab=ca&w=' || r.week_start);
  end if;
  return v_id;
end $$;
revoke all on function app.roster_save(jsonb) from public, anon;
grant execute on function app.roster_save(jsonb) to authenticated;

-- TP SX duyệt, gửi Giám đốc
create or replace function app.roster_submit(p_id uuid, p_note text default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r plan.week_rosters;
begin
  if not core.has_role('SX_TP') then raise exception 'Chỉ TP SX duyệt và gửi bảng ca tuần'; end if;
  select * into r from plan.week_rosters where id = p_id for update;
  if not found then raise exception 'Không tìm thấy bảng ca'; end if;
  if r.status not in ('DRAFT', 'RETURNED') then raise exception 'Bảng ca % không ở trạng thái nháp', r.roster_no; end if;
  if r.week_start + 6 < plan.vn_today() then raise exception 'Tuần % đã qua', to_char(r.week_start, 'DD/MM'); end if;
  perform plan.roster_check(r.week_start, r.machines, r.people, r.qc);
  update plan.week_rosters set status = 'PROPOSED', submitted_by = auth.uid(), submitted_at = now(), updated_at = now(),
         note = coalesce(nullif(trim(coalesce(p_note, '')), ''), note)
   where id = p_id;
  perform wf.notify_users(array_remove(plan.gd_ids(), auth.uid()), 'Bảng ca tuần chờ duyệt: ' || to_char(r.week_start, 'DD/MM') || '–' || to_char(r.week_start + 6, 'DD/MM'),
    plan.roster_text(r) || '. Duyệt trước 12:00 thứ 7 ' || to_char(r.week_start - 2, 'DD/MM') || ' để MES gửi lịch ca cho công nhân.',
    '/nhan-su-xuong?tab=ca&w=' || r.week_start);
end $$;
revoke all on function app.roster_submit(uuid, text) from public, anon;
grant execute on function app.roster_submit(uuid, text) to authenticated;

-- Áp bảng ca đã duyệt: ca máy (qua plan.machine_shifts, như đề xuất thêm ca), ca người (plan.operator_shifts) trong tuần (từ hôm nay);
-- gửi lịch ca cho công nhân (người có tài khoản), TP SX, Kế hoạch SX, tổ trưởng, QC
create or replace function plan.roster_apply(p_id uuid, p_note text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r plan.week_rosters; v_from date; v_to date; v_req uuid; s plan.machine_shifts; o record; x plan.operator_shifts; v_items jsonb;
  v_txt text; a jsonb; v_wk text; v_no int; v_lead text; v_qc text;
begin
  select * into r from plan.week_rosters where id = p_id for update;
  v_from := greatest(r.week_start, plan.vn_today()); v_to := r.week_start + 6;
  if v_to < v_from then raise exception 'Tuần % đã qua', to_char(r.week_start, 'DD/MM'); end if;
  v_wk := to_char(r.week_start, 'DD/MM') || '–' || to_char(v_to, 'DD/MM');
  update plan.week_rosters set status = 'REPLACED', updated_at = now() where week_start = r.week_start and status = 'APPROVED' and id <> r.id;
  -- ca máy: các khoảng ngày liền nhau cùng số ca
  select coalesce(jsonb_agg(jsonb_build_object('machines', jsonb_build_array(g.mc), 'shifts', g.n, 'from', g.f, 'to', g.t) order by g.mc, g.f), '[]')
    into v_items
  from (select mc, n, min(d) as f, max(d) as t
        from (select a2 ->> 'machine' as mc, (a2 ->> 'shifts')::int as n, (a2 ->> 'date')::date as d,
                     (a2 ->> 'date')::date - (row_number() over (partition by a2 ->> 'machine', (a2 ->> 'shifts')::int order by (a2 ->> 'date')::date))::int as grp
              from jsonb_array_elements(r.machines) a2 where (a2 ->> 'date')::date >= v_from) q
        group by mc, n, grp) g;
  insert into plan.shift_requests (req_no, plan_id, items, summary, reason, status, proposed_by, proposed_at, reviewed_by, reviewed_at, review_note)
  values (core.next_no('CA', 3), r.plan_id, v_items, jsonb_build_object('roster', r.roster_no), 'Bảng ca tuần ' || r.roster_no || ' (' || v_wk || ')',
          'APPROVED', r.submitted_by, coalesce(r.submitted_at, now()), auth.uid(), now(), nullif(trim(coalesce(p_note, '')), ''))
  returning id into v_req;
  -- bảng ca thay mọi ca máy cũ trong tuần (từ hôm nay); phần sau tuần giữ lại
  for s in select * from plan.machine_shifts m where m.date_from <= v_to and least(m.date_to, coalesce(m.ended_on, m.date_to)) >= v_from
             and least(m.date_to, coalesce(m.ended_on, m.date_to)) >= m.date_from loop
    if least(s.date_to, coalesce(s.ended_on, s.date_to)) > v_to then
      insert into plan.machine_shifts (request_id, machine_code, date_from, date_to, shifts, ended_on)
      values (s.request_id, s.machine_code, v_to + 1, s.date_to, s.shifts, s.ended_on);
    end if;
    update plan.machine_shifts set ended_on = v_from - 1 where id = s.id;
  end loop;
  insert into plan.machine_shifts (request_id, machine_code, date_from, date_to, shifts)
  select v_req, it -> 'machines' ->> 0, (it ->> 'from')::date, (it ->> 'to')::date, (it ->> 'shifts')::int from jsonb_array_elements(v_items) it;
  -- ca người: mọi người làm ca 1 trong tuần trừ người bảng ca đặt ca 2 / ca 3 (cả tuần, đổi ca vào Chủ nhật)
  for x in select * from plan.operator_shifts m where m.date_from <= v_to and m.date_to >= v_from loop
    if x.date_to > v_to then
      insert into plan.operator_shifts (operator_code, date_from, date_to, shift_no, note, created_by)
      values (x.operator_code, v_to + 1, x.date_to, x.shift_no, x.note, x.created_by);
    end if;
    if x.date_from < v_from then update plan.operator_shifts set date_to = v_from - 1 where id = x.id;
    else delete from plan.operator_shifts where id = x.id; end if;
  end loop;
  insert into plan.operator_shifts (operator_code, date_from, date_to, shift_no, note)
  select a2 ->> 'code', v_from, v_to, (a2 ->> 'shift')::int, 'Bảng ca tuần ' || r.roster_no
  from jsonb_array_elements(r.people) a2 where (a2 ->> 'shift')::int >= 2;
  for o in select distinct a2 ->> 'code' as code from jsonb_array_elements(r.people) a2 loop
    perform plan.check_op_rest(o.code, v_from - 1, v_to + 1);
  end loop;
  update plan.week_rosters set status = 'APPROVED', reviewed_by = auth.uid(), reviewed_at = now(), review_note = nullif(trim(coalesce(p_note, '')), ''),
         request_id = v_req, sent_at = now(), sent_late = now() > plan.roster_deadline(r.week_start), updated_at = now()
   where id = p_id;
  select * into r from plan.week_rosters where id = p_id;
  v_txt := plan.roster_text(r);
  perform app.kh_log('Bảng ca tuần', r.roster_no || ' (' || v_wk || ')', '—', v_txt, coalesce(nullif(trim(coalesce(p_note, '')), ''), 'Giám đốc duyệt'));
  -- gửi lịch ca cho từng công nhân có tài khoản
  for o in select op.code, op.profile_id, coalesce((a2 ->> 'shift')::int, 1) as sh, coalesce((a2 ->> 'lead')::boolean, false) as lead
           from master.operators op left join jsonb_array_elements(r.people) a2 on a2 ->> 'code' = op.code
           where op.active and op.profile_id is not null loop
    perform wf.notify_users(array[o.profile_id], 'Lịch ca tuần ' || v_wk || ': ' || plan.shift_label(o.sh),
      o.code || ' làm ' || plan.shift_label(o.sh) || ' cả tuần ' || v_wk || case when o.lead then ', phụ trách ca' else '' end || '.', '/in/bang-ca?id=' || r.id);
  end loop;
  select string_agg(a2 ->> 'code', ', ') into v_lead from jsonb_array_elements(r.people) a2 where coalesce((a2 ->> 'lead')::boolean, false);
  perform wf.notify_users(array(select distinct u from unnest(array_remove(array[r.submitted_by, r.created_by], null)
                                   || inv.role_users(array['SX_TP', 'SX_KH', 'TO_TRUONG'])) u where u is distinct from auth.uid()),
    'Bảng ca tuần ' || v_wk || ' đã duyệt' || case when r.sent_late then ' (gửi sau 12:00 thứ 7)' else '' end,
    v_txt || '. Đã gửi công nhân có tài khoản; in bảng ca dán ở xưởng. Lịch máy: bấm Xếp lại lịch nếu MES chưa tự xếp.', '/in/bang-ca?id=' || r.id);
  if exists (select 1 from jsonb_array_elements(r.machines)) then
    v_qc := case when r.qc ->> 'mode' = 'QC' then 'QC làm ca 2: ' || coalesce(r.qc ->> 'who', '')
                 else 'Ủy quyền người phụ trách ca (' || coalesce(v_lead, '') || ') đo mẫu QC' end;
    perform wf.notify_users(array(select u from unnest(inv.role_users(array['QC', 'KT_TP'])) u where u is distinct from auth.uid()),
      'QC ca 2 tuần ' || v_wk, v_qc || '. Bobin xong ca 2 có kết quả QC trong ca, công đoạn sau không phải chờ sáng hôm sau.', '/in/bang-ca?id=' || r.id);
  end if;
end $$;
revoke all on function plan.roster_apply(uuid, text) from public, anon, authenticated;

-- Giám đốc duyệt (gửi nhân viên) / trả lại
create or replace function app.roster_review(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r plan.week_rosters;
begin
  if not plan.is_gd() then raise exception 'Chỉ Giám đốc duyệt bảng ca tuần'; end if;
  select * into r from plan.week_rosters where id = p_id for update;
  if not found then raise exception 'Không tìm thấy bảng ca'; end if;
  if r.status <> 'PROPOSED' then raise exception 'Bảng ca % không chờ duyệt', r.roster_no; end if;
  if r.submitted_by = auth.uid() then raise exception 'Người gửi không tự duyệt bảng ca'; end if;
  if p_approve then
    perform plan.roster_check(r.week_start, r.machines, r.people, r.qc);
    perform plan.roster_apply(p_id, p_note);
  else
    if coalesce(trim(p_note), '') = '' then raise exception 'Nhập lý do trả lại'; end if;
    update plan.week_rosters set status = 'RETURNED', reviewed_by = auth.uid(), reviewed_at = now(), review_note = trim(p_note), updated_at = now() where id = p_id;
    perform wf.notify_users(array(select distinct u from unnest(array_remove(array[r.submitted_by, r.created_by], null)) u where u is distinct from auth.uid()),
      'Giám đốc trả lại bảng ca ' || r.roster_no, trim(p_note), '/nhan-su-xuong?tab=ca&w=' || r.week_start);
  end if;
end $$;
revoke all on function app.roster_review(uuid, boolean, text) from public, anon;
grant execute on function app.roster_review(uuid, boolean, text) to authenticated;

create or replace function app.roster_cancel(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r plan.week_rosters;
begin
  if not (plan.can_staff() or plan.is_gd()) then raise exception 'Chỉ TP SX / Kế hoạch SX / Giám đốc hủy bảng ca'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do hủy'; end if;
  select * into r from plan.week_rosters where id = p_id for update;
  if not found then raise exception 'Không tìm thấy bảng ca'; end if;
  if r.status not in ('DRAFT', 'PROPOSED', 'RETURNED') then raise exception 'Bảng ca % đã duyệt hoặc đã hủy', r.roster_no; end if;
  update plan.week_rosters set status = 'CANCELLED', review_note = trim(p_reason), updated_at = now() where id = p_id;
end $$;
revoke all on function app.roster_cancel(uuid, text) from public, anon;
grant execute on function app.roster_cancel(uuid, text) to authenticated;

create or replace view app.v_kh_rosters with (security_invoker = true) as
select r.*, app.user_name(r.created_by) as created_by_name, app.user_name(r.submitted_by) as submitted_by_name,
       app.user_name(r.reviewed_by) as reviewed_by_name, r.week_start + 6 as week_end, plan.roster_deadline(r.week_start) as deadline,
       (select req_no from plan.shift_requests q where q.id = r.request_id) as req_no,
       (select p.plan_no from plan.production_plans p where p.id = r.plan_id) as plan_no
from plan.week_rosters r;
grant select on app.v_kh_rosters to authenticated;

-- Nhắc hạn: thứ 6 08:00 TP SX lập bảng ca tuần sau (kèm cảnh báo lệch giờ đứng máy 4 tuần); thứ 7 08:00 nhắc Giám đốc duyệt;
-- thứ 7 12:00 chưa duyệt thì cảnh báo Giám đốc, TP SX
-- p_at: giờ VN để kiểm thử (mặc định bây giờ)
create or replace function plan.roster_reminders(p_at timestamp default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare n timestamp := coalesce(p_at, now() at time zone 'Asia/Ho_Chi_Minh'); dow int := extract(isodow from n)::int; h int := extract(hour from n)::int;
  ws date; r plan.week_rosters; v_key uuid := '00000000-0000-0000-0000-000000000000'; v_wk text; c master.planning_config; v_avg numeric; v_list text;
begin
  if dow not in (5, 6) then return; end if;
  ws := n::date + (8 - dow);
  v_wk := to_char(ws, 'DD/MM') || '–' || to_char(ws + 6, 'DD/MM');
  select * into r from plan.week_rosters where week_start = ws and status in ('DRAFT', 'PROPOSED', 'RETURNED', 'APPROVED')
   order by (status = 'APPROVED') desc, created_at desc limit 1;
  if dow = 5 then
    if coalesce(r.status, '') not in ('PROPOSED', 'APPROVED')
       and not exists (select 1 from inv.alert_log where kind = 'ROSTER' and ref_id = v_key and period_key = ws || ':FRI') then
      insert into inv.alert_log (kind, ref_id, period_key) values ('ROSTER', v_key, ws || ':FRI');
      perform app.kh_notify_role('SX_TP', 'Lập bảng ca tuần ' || v_wk, 'MES đã đề xuất ở Nhân sự xưởng → Bảng ca tuần. TP SX sửa rồi gửi Giám đốc duyệt trước 12:00 thứ 7 '
        || to_char(ws - 2, 'DD/MM') || ' để MES gửi lịch ca cho công nhân.', '/nhan-su-xuong?tab=ca&w=' || ws);
      perform app.kh_notify_role('SX_KH', 'Lập bảng ca tuần ' || v_wk, 'Hạn gửi Giám đốc: 12:00 thứ 7 ' || to_char(ws - 2, 'DD/MM') || '.', '/nhan-su-xuong?tab=ca&w=' || ws);
    end if;
    -- giờ đứng máy 4 tuần qua lệch quá ngưỡng (một lần mỗi tuần)
    select * into c from master.planning_config where id = 1;
    with t as (select o.code, coalesce((select sum(h2.attend_min) from plan.operator_day_hours h2 where h2.operator_code = o.code
                                         and h2.work_date between n::date - 27 and n::date), 0) as m
               from master.operators o where o.active)
    select avg(m), string_agg(code || ' ' || round(m / 60) || ' giờ (' || case when m > avg_m then '+' else '−' end || round(abs(m - avg_m) / nullif(avg_m, 0) * 100) || ' %)', ', ' order by code)
           filter (where abs(m - avg_m) > avg_m * c.balance_pct / 100)
      into v_avg, v_list
    from (select t.*, avg(t.m) over () as avg_m from t) q;
    if coalesce(v_avg, 0) > 60 and v_list is not null
       and not exists (select 1 from inv.alert_log where kind = 'ROSTER' and ref_id = v_key and period_key = ws || ':BAL') then
      insert into inv.alert_log (kind, ref_id, period_key) values ('ROSTER', v_key, ws || ':BAL');
      perform app.kh_notify_role('SX_TP', 'Giờ đứng máy 4 tuần qua lệch quá ' || trim_scale(c.balance_pct) || ' %',
        v_list || ' (bình quân ' || round(v_avg / 60) || ' giờ/người). Bảng ca tuần sau ưu tiên người ít giờ (MES đã tính sẵn).', '/nhan-su-xuong?tab=so-gio');
    end if;
    return;
  end if;
  if coalesce(r.status, '') = 'APPROVED' then return; end if;
  if h < 12 then
    if not exists (select 1 from inv.alert_log where kind = 'ROSTER' and ref_id = v_key and period_key = ws || ':SAT') then
      insert into inv.alert_log (kind, ref_id, period_key) values ('ROSTER', v_key, ws || ':SAT');
      if r.status = 'PROPOSED' then
        perform wf.notify_users(plan.gd_ids(), 'Duyệt bảng ca tuần ' || v_wk || ' trước 12:00 hôm nay', plan.roster_text(r), '/nhan-su-xuong?tab=ca&w=' || ws);
      else
        perform app.kh_notify_role('SX_TP', 'Chưa gửi bảng ca tuần ' || v_wk, 'Hạn Giám đốc duyệt, MES gửi công nhân: 12:00 hôm nay.', '/nhan-su-xuong?tab=ca&w=' || ws);
      end if;
    end if;
  elsif not exists (select 1 from inv.alert_log where kind = 'ROSTER' and ref_id = v_key and period_key = ws || ':LATE') then
    insert into inv.alert_log (kind, ref_id, period_key) values ('ROSTER', v_key, ws || ':LATE');
    perform wf.notify_users(plan.gd_ids() || inv.role_users(array['SX_TP']), 'Bảng ca tuần ' || v_wk || ' chưa duyệt trước 12:00 thứ 7',
      'Công nhân chưa nhận lịch ca tuần sau. ' || case when r.status = 'PROPOSED' then 'Bảng ca đang chờ Giám đốc duyệt.' else 'TP SX chưa gửi bảng ca.' end
      || ' Chưa duyệt thì tuần sau mọi máy chạy ca 1.', '/nhan-su-xuong?tab=ca&w=' || ws);
  end if;
end $$;
revoke all on function plan.roster_reminders(timestamp) from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('bmt_roster_remind', '0 1,5 * * 5,6', 'select plan.roster_reminders()');   -- 08:00, 12:00 giờ VN thứ 6, thứ 7
  end if;
exception when others then
  raise notice 'Chưa đặt được lịch bmt_roster_remind: %', sqlerrm;
end $$;

-- ===========================================================================
-- 5. Tham số xếp lịch cho web: thêm cuối ngưỡng lệch giờ, sổ giờ (để luân phiên), ngày ca 2 / ca 3 có người đo mẫu QC
-- ===========================================================================
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
  plan.kh_maint_due() as maint_plans,
  -- 5300: máy chạy 2–3 ca, ca làm việc của người, giờ làm tối đa mỗi người mỗi ngày
  c.day_max_h,
  coalesce((select jsonb_agg(jsonb_build_object('machine', s.machine_code, 'from', s.date_from, 'to', least(s.date_to, coalesce(s.ended_on, s.date_to)),
              'shifts', s.shifts, 'req', r.req_no) order by s.date_from, s.machine_code)
            from plan.machine_shifts s join plan.shift_requests r on r.id = s.request_id
            where least(s.date_to, coalesce(s.ended_on, s.date_to)) >= s.date_from
              and least(s.date_to, coalesce(s.ended_on, s.date_to)) >= (now() at time zone 'Asia/Ho_Chi_Minh')::date - 62), '[]') as machine_shifts,
  coalesce((select jsonb_agg(jsonb_build_object('code', x.operator_code, 'from', x.date_from, 'to', x.date_to, 'shift', x.shift_no) order by x.date_from)
            from plan.operator_shifts x where x.date_to >= (now() at time zone 'Asia/Ho_Chi_Minh')::date - 62), '[]') as op_shifts,
  -- 5400: luân phiên đứng máy, ca 2 có người đo mẫu QC
  c.balance_pct,
  coalesce((select jsonb_agg(jsonb_build_object('code', h.operator_code, 'date', h.work_date, 'min', h.m) order by h.work_date, h.operator_code)
            from (select operator_code, work_date, sum(attend_min) as m from plan.operator_day_hours
                  where work_date between (now() at time zone 'Asia/Ho_Chi_Minh')::date - 45 and (now() at time zone 'Asia/Ho_Chi_Minh')::date + 30
                  group by operator_code, work_date) h), '[]') as op_hours,
  coalesce((select jsonb_agg(jsonb_build_object('from', w.week_start, 'to', w.week_start + 6, 'mode', w.qc ->> 'mode') order by w.week_start)
            from plan.week_rosters w where w.status = 'APPROVED' and w.qc ->> 'mode' in ('QC', 'LEAD')
              and w.week_start + 6 >= (now() at time zone 'Asia/Ho_Chi_Minh')::date - 62), '[]') as qc_cover
from master.planning_config c
where c.id = 1;
grant select on app.v_kh_config to authenticated;
