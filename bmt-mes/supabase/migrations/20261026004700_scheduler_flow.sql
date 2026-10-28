-- Thuật toán xếp lịch theo thông số (anh Bình duyệt 28/10/2026, Claude Doc "BMT MES – Quy tắc xếp máy…" mục 5).
-- Bộ xếp lịch web (lib/kh/scheduler.ts + optimize.ts) không còn số cố định: mọi con số lấy từ thông số dưới đây.
--  1. master.planning_config: thông số dòng chảy (QC, mét/bobin, đệm an toàn, hạn dùng silicone, mẻ trộn, giới hạn trộn sớm/tăng ca,
--     ngưỡng cỡ lớn, phút PLC tối thiểu, khung gom lô theo phút) + tăng ca / trộn sớm đang áp dụng (Giám đốc duyệt, có thời hạn).
--  2. plan.qc_learned(): thời gian QC thực tế (trung vị 30 ngày: kết quả QC − giờ xong bobin trên phiếu hoàn thành).
--  3. app.v_kh_config thêm các cột trên + tăng ca hiệu lực hôm nay + QC tự học.
--  4. app.kh_save_flow: TP KT/QA sửa thông số kỹ thuật, Giám đốc sửa mọi thông số; ghi nhật ký, báo TP SX xếp lại.
--  5. Đề xuất tăng ca (plan.overtime_requests, TC-yymm-nnn): TP SX / Kế hoạch SX đề xuất theo MES → Giám đốc duyệt
--     (Giám đốc tự đề xuất thì áp ngay); kiểm ≤ tăng ca tối đa/ngày, ≤ giờ/tháng mỗi người; kết thúc sớm được.
--  6. Nhật ký "Thuật toán xếp lịch" để lịch đang dùng hiện "cần xếp lại".

-- ---------------------------------------------------------------------------
-- 1. Thông số
-- ---------------------------------------------------------------------------
alter table master.planning_config
  add column if not exists qc_min integer not null default 120,
  add column if not exists qc_learn boolean not null default true,
  add column if not exists unit_m jsonb not null default '{"CD0":5000,"CD1":10000,"CD2":10000,"CD3":5000,"CD5":5000,"CD6":500}',
  add column if not exists safety_min jsonb not null default '{}',
  add column if not exists pot_life_h numeric not null default 8,
  add column if not exists mix_batch_kg numeric not null default 25,
  add column if not exists mix_early_max_h numeric not null default 4,
  add column if not exists ot_max_min integer not null default 240,
  add column if not exists ot_month_h integer not null default 40,
  add column if not exists size_large_mm2 numeric not null default 2.5,
  add column if not exists plc_min_run integer not null default 120,
  add column if not exists pick_window_min integer,
  add column if not exists extra_min jsonb not null default '{}',
  add column if not exists mix_early_h numeric not null default 0,
  add column if not exists ot_from date,
  add column if not exists ot_until date,
  add column if not exists ot_request_id uuid;
alter table master.planning_config drop constraint if exists planning_config_flow_chk;
alter table master.planning_config add constraint planning_config_flow_chk check (
  qc_min between 0 and 1440 and pot_life_h between 0.25 and 72 and mix_batch_kg > 0 and mix_batch_kg <= 1000
  and mix_early_max_h between 0 and 8 and ot_max_min between 0 and 240 and ot_month_h between 0 and 40
  and size_large_mm2 > 0 and size_large_mm2 <= 400 and plc_min_run between 10 and 10000
  and (pick_window_min is null or pick_window_min between 0 and 1440) and mix_early_h between 0 and 8
  and jsonb_typeof(unit_m) = 'object' and jsonb_typeof(safety_min) = 'object' and jsonb_typeof(extra_min) = 'object'
  and (ot_until is null or ot_from is null or ot_until >= ot_from));

-- ---------------------------------------------------------------------------
-- 2. Thời gian QC thực tế (phút thật): kết quả QC đầu tiên của lô − giờ xong bobin (phiếu hoàn thành)
-- ---------------------------------------------------------------------------
create or replace function plan.qc_learned(p_days integer default 30) returns jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
  with x as (
    select extract(epoch from (q.at - coalesce(s.ended_at, s.recorded_at))) / 60 as m
    from mfg.bobbin_slips s
    join lateral (select min(i.inspected_at) as at from qa.inspections i
                  where i.lot_id = s.lot_id and i.result is not null and i.inspected_at is not null) q on q.at is not null
    where s.status = 'ACTIVE' and s.lot_id is not null
      and coalesce(s.ended_at, s.recorded_at) > now() - make_interval(days => p_days)
  )
  select jsonb_build_object('median_min', round((percentile_cont(0.5) within group (order by m))::numeric, 0), 'n', count(*))
  from x where m > 0 and m < 1440
$$;
revoke all on function plan.qc_learned(integer) from public, anon;
grant execute on function plan.qc_learned(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. app.v_kh_config: thêm thông số dòng chảy (giữ nguyên các cột cũ, thêm cuối)
-- ---------------------------------------------------------------------------
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
  -- tăng ca / trộn sớm có hiệu lực hôm nay (giờ VN); hết hạn thì coi như không tăng ca
  case when (now() at time zone 'Asia/Ho_Chi_Minh')::date between coalesce(c.ot_from, '-infinity'::date) and coalesce(c.ot_until, 'infinity'::date)
       then c.extra_min else '{}'::jsonb end as extra_min_now,
  case when (now() at time zone 'Asia/Ho_Chi_Minh')::date between coalesce(c.ot_from, '-infinity'::date) and coalesce(c.ot_until, 'infinity'::date)
       then c.mix_early_h else 0 end as mix_early_h_now,
  plan.qc_learned(30) as qc_learned
from master.planning_config c
where c.id = 1;

-- ---------------------------------------------------------------------------
-- 4. Sửa thông số dòng chảy
-- ---------------------------------------------------------------------------
create or replace function app.kh_save_flow(p jsonb, p_reason text) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  c master.planning_config; n integer := 0; k text; ov jsonb; nv jsonb; e record;
  labels jsonb := '{"qc_min":"Thời gian QC một bobin (phút)","qc_learn":"MES tự học thời gian QC từ phiếu hoàn thành",
    "unit_m":"Mét một bobin theo công đoạn","safety_min":"Đệm an toàn công đoạn đi trước (phút)",
    "pot_life_h":"Hạn dùng silicone đã pha lưu hóa (giờ)","mix_batch_kg":"kg một mẻ trộn",
    "mix_early_max_h":"Trộn sớm trước ca tối đa (giờ)","ot_max_min":"Tăng ca tối đa mỗi ngày (phút/người)",
    "ot_month_h":"Tăng ca tối đa mỗi tháng (giờ/người)","size_large_mm2":"Ngưỡng cỡ lớn cho tốc độ mặc định (mm²)",
    "plc_min_run":"Phút chạy tối thiểu để tin tốc độ PLC","pick_window_min":"Khung coi như bắt đầu cùng lúc khi gom lô (phút)"}';
  tech text[] := array['qc_min','qc_learn','unit_m','safety_min','pot_life_h','mix_batch_kg','size_large_mm2','plc_min_run'];
  is_bgd boolean := core.has_role('BGD');
begin
  if not (is_bgd or core.has_role('KT_TP')) then raise exception 'Chỉ Giám đốc hoặc TP KT/QA được sửa thông số xếp lịch'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do thay đổi'; end if;
  if p is null or jsonb_typeof(p) <> 'object' then raise exception 'Thiếu thông số'; end if;
  for k in select jsonb_object_keys(p) loop
    if not labels ? k then raise exception 'Thông số không hợp lệ: %', k; end if;
    if not is_bgd and not (k = any(tech)) then raise exception 'Chỉ Giám đốc được sửa: %', labels ->> k; end if;
  end loop;
  -- Mét/bobin, đệm an toàn: theo công đoạn CD0–CD6, số không âm
  if p ? 'unit_m' then
    if jsonb_typeof(p -> 'unit_m') <> 'object' then raise exception 'Mét một bobin phải theo từng công đoạn'; end if;
    for e in select key, value from jsonb_each(p -> 'unit_m') loop
      if e.key not in ('CD0','CD1','CD2','CD3','CD5','CD6') or jsonb_typeof(e.value) <> 'number' or e.value::numeric <= 0 or e.value::numeric > 1000000 then
        raise exception 'Mét một bobin công đoạn % không hợp lệ', e.key;
      end if;
    end loop;
  end if;
  if p ? 'safety_min' then
    if jsonb_typeof(p -> 'safety_min') <> 'object' then raise exception 'Đệm an toàn phải theo từng công đoạn'; end if;
    for e in select key, value from jsonb_each(p -> 'safety_min') loop
      if e.key not in ('CD0','CD1','CD2','CD3','CD5','CD6') or jsonb_typeof(e.value) <> 'number' or e.value::numeric < 0 or e.value::numeric > 1440 then
        raise exception 'Đệm an toàn công đoạn % phải từ 0 đến 1440 phút', e.key;
      end if;
    end loop;
  end if;
  select * into c from master.planning_config where id = 1 for update;
  for k in select jsonb_object_keys(p) loop
    ov := to_jsonb(c) -> k; nv := p -> k;
    if k = 'unit_m' then nv := ov || nv; end if;   -- mét/bobin: chỉ thay công đoạn được gửi
    if jsonb_typeof(ov) = 'number' and jsonb_typeof(nv) = 'number' and ov::numeric = nv::numeric then continue; end if;
    if jsonb_typeof(ov) = 'number' and jsonb_typeof(nv) = 'string' and nv #>> '{}' ~ '^-?[0-9.]+$' and ov::numeric = (nv #>> '{}')::numeric then continue; end if;
    if ov is not distinct from nv or (coalesce(jsonb_typeof(ov), 'null') = 'null' and coalesce(jsonb_typeof(nv), 'null') = 'null') then continue; end if;
    perform app.kh_log('Tham số xếp lịch', labels ->> k, coalesce(ov #>> '{}', ov::text, 'trống'), coalesce(nv #>> '{}', nv::text, 'trống'), trim(p_reason));
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Không có thay đổi'; end if;
  update master.planning_config set
    qc_min = case when p ? 'qc_min' then (p ->> 'qc_min')::numeric::integer else qc_min end,
    qc_learn = case when p ? 'qc_learn' then (p ->> 'qc_learn')::boolean else qc_learn end,
    unit_m = case when p ? 'unit_m' then unit_m || (p -> 'unit_m') else unit_m end,
    safety_min = case when p ? 'safety_min' then p -> 'safety_min' else safety_min end,
    pot_life_h = case when p ? 'pot_life_h' then (p ->> 'pot_life_h')::numeric else pot_life_h end,
    mix_batch_kg = case when p ? 'mix_batch_kg' then (p ->> 'mix_batch_kg')::numeric else mix_batch_kg end,
    mix_early_max_h = case when p ? 'mix_early_max_h' then (p ->> 'mix_early_max_h')::numeric else mix_early_max_h end,
    ot_max_min = case when p ? 'ot_max_min' then (p ->> 'ot_max_min')::numeric::integer else ot_max_min end,
    ot_month_h = case when p ? 'ot_month_h' then (p ->> 'ot_month_h')::numeric::integer else ot_month_h end,
    size_large_mm2 = case when p ? 'size_large_mm2' then (p ->> 'size_large_mm2')::numeric else size_large_mm2 end,
    plc_min_run = case when p ? 'plc_min_run' then (p ->> 'plc_min_run')::numeric::integer else plc_min_run end,
    pick_window_min = case when p ? 'pick_window_min' then nullif(p ->> 'pick_window_min', '')::numeric::integer else pick_window_min end,
    updated_at = now(), updated_by = auth.uid()
  where id = 1;
  perform app.kh_notify_role('SX_TP', 'Thông số xếp lịch đã đổi', 'Đã sửa ' || n || ' thông số dòng chảy. Bấm Xếp lại lịch để áp dụng.', '/lich-may');
  return n;
exception
  when check_violation then raise exception 'Giá trị ngoài khoảng cho phép, kiểm tra lại các ô vừa sửa';
  when invalid_text_representation then raise exception 'Giá trị không phải số, kiểm tra lại các ô vừa sửa';
end $$;
revoke all on function app.kh_save_flow(jsonb, text) from public, anon;
grant execute on function app.kh_save_flow(jsonb, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Đề xuất tăng ca / trộn sớm
-- ---------------------------------------------------------------------------
create table if not exists plan.overtime_requests (
  id uuid primary key default gen_random_uuid(),
  req_no text not null unique,
  plan_id uuid references plan.production_plans(id) on delete set null,
  extra_min jsonb not null default '{}',        -- phút tăng ca mỗi ngày theo mã máy
  mix_early_h numeric not null default 0,       -- giờ máy trộn chạy trước ca (ca sớm)
  date_from date not null,
  date_to date not null,
  summary jsonb not null default '{}',          -- MES tính: nhóm máy, số người, số ngày, giờ công, ngày xong trước/sau
  reason text not null,
  status text not null default 'PROPOSED' check (status in ('PROPOSED','APPROVED','RETURNED','CANCELLED','ENDED')),
  proposed_by uuid default auth.uid(),
  proposed_at timestamptz not null default now(),
  reviewed_by uuid,
  reviewed_at timestamptz,
  review_note text,
  check (date_to >= date_from), check (jsonb_typeof(extra_min) = 'object'), check (mix_early_h between 0 and 8)
);
alter table plan.overtime_requests enable row level security;
drop policy if exists p_select on plan.overtime_requests;
create policy p_select on plan.overtime_requests for select to authenticated using (app.kh_can_view());
grant select on plan.overtime_requests to authenticated;

create or replace view app.v_kh_overtime with (security_invoker = true) as
select o.*, app.user_name(o.proposed_by) as proposed_by_name, app.user_name(o.reviewed_by) as reviewed_by_name,
  (select p.plan_no from plan.production_plans p where p.id = o.plan_id) as plan_no
from plan.overtime_requests o;
grant select on app.v_kh_overtime to authenticated;

-- Kiểm tra đề xuất: máy có thật, giờ mỗi ngày ≤ tối đa, giờ mỗi tháng (theo ngày làm việc) ≤ giới hạn tháng, trộn sớm ≤ tối đa
create or replace function plan.ot_check(p_extra jsonb, p_early numeric, p_from date, p_to date) returns void
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare c master.planning_config; e record; wd int[]; mo record; days int; v numeric;
begin
  select * into c from master.planning_config where id = 1;
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Chọn khoảng ngày tăng ca (đến ngày không trước từ ngày)'; end if;
  if p_to - p_from > 62 then raise exception 'Mỗi đề xuất tăng ca tối đa 2 tháng'; end if;
  if coalesce(p_early, 0) < 0 or coalesce(p_early, 0) > c.mix_early_max_h then
    raise exception 'Trộn sớm trước ca tối đa % giờ', c.mix_early_max_h;
  end if;
  wd := array(select x::int from jsonb_array_elements_text(coalesce(mfg.machine_setting('shift') -> 'workdays', '[1,2,3,4,5,6]')) x);
  for e in select key, value from jsonb_each(coalesce(p_extra, '{}')) loop
    if jsonb_typeof(e.value) <> 'number' then raise exception 'Giờ tăng ca máy % không hợp lệ', e.key; end if;
    v := e.value::numeric;
    if v < 0 or v > c.ot_max_min then raise exception 'Tăng ca máy % tối đa % phút mỗi ngày', e.key, c.ot_max_min; end if;
    if not exists (select 1 from master.machines m where m.code = e.key and m.active) then raise exception 'Không có máy %', e.key; end if;
    for mo in select date_trunc('month', d)::date as m, count(*) filter (where extract(isodow from d)::int = any(wd)) as n
              from generate_series(p_from, p_to, interval '1 day') d group by 1 loop
      if v / 60 * mo.n > c.ot_month_h then
        raise exception 'Tăng ca máy % tháng %: % giờ mỗi người, vượt % giờ/tháng', e.key, to_char(mo.m, 'MM/YYYY'), round(v / 60 * mo.n, 1), c.ot_month_h;
      end if;
    end loop;
  end loop;
end $$;
revoke all on function plan.ot_check(jsonb, numeric, date, date) from public, anon, authenticated;

-- Áp đề xuất đã duyệt vào tham số xếp lịch (thay đề xuất đang áp dụng trước đó)
create or replace function plan.ot_apply(p_req uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare o plan.overtime_requests; c master.planning_config;
begin
  select * into o from plan.overtime_requests where id = p_req;
  select * into c from master.planning_config where id = 1 for update;
  update plan.overtime_requests set status = 'ENDED', review_note = coalesce(review_note || ' · ', '') || 'Thay bằng ' || o.req_no
  where status = 'APPROVED' and id <> p_req;
  update plan.overtime_requests set status = 'APPROVED', reviewed_by = auth.uid(), reviewed_at = now() where id = p_req;
  update master.planning_config set extra_min = o.extra_min, mix_early_h = o.mix_early_h, ot_from = o.date_from, ot_until = o.date_to,
    ot_request_id = o.id, updated_at = now(), updated_by = auth.uid() where id = 1;
  perform app.kh_log('Tăng ca', 'Tăng ca / trộn sớm đang áp dụng',
    case when c.ot_request_id is null then 'không' else c.extra_min::text || ', trộn sớm ' || c.mix_early_h || ' giờ' end,
    o.req_no || ': ' || o.extra_min::text || ', trộn sớm ' || o.mix_early_h || ' giờ, ' || to_char(o.date_from, 'DD/MM') || '–' || to_char(o.date_to, 'DD/MM'),
    o.reason);
  perform app.kh_notify_role('SX_TP', 'Tăng ca đã duyệt: ' || o.req_no, 'Từ ' || to_char(o.date_from, 'DD/MM') || ' đến ' || to_char(o.date_to, 'DD/MM') || '. Bấm Xếp lại lịch để áp dụng.', '/lich-may?tab=toiuu');
  perform app.kh_notify_role('SX_KH', 'Tăng ca đã duyệt: ' || o.req_no, 'Bấm Xếp lại lịch để áp dụng.', '/lich-may?tab=toiuu');
end $$;
revoke all on function plan.ot_apply(uuid) from public, anon, authenticated;

create or replace function app.kh_ot_propose(p_plan uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid; v_no text; v_extra jsonb; v_early numeric; v_from date; v_to date; v_gd boolean := plan.is_gd();
begin
  if not (core.has_role('SX_TP') or core.has_role('SX_KH') or v_gd) then raise exception 'Chỉ TP SX, Kế hoạch SX hoặc Giám đốc đề xuất tăng ca'; end if;
  if coalesce(trim(p ->> 'reason'), '') = '' then raise exception 'Nhập lý do tăng ca'; end if;
  if jsonb_typeof(coalesce(p -> 'extra_min', '{}')) <> 'object' then raise exception 'Giờ tăng ca phải theo từng máy'; end if;
  if exists (select 1 from jsonb_each(coalesce(p -> 'extra_min', '{}')) where jsonb_typeof(value) <> 'number') then
    raise exception 'Giờ tăng ca phải là số phút';
  end if;
  select coalesce(jsonb_object_agg(key, value), '{}') into v_extra
  from jsonb_each(coalesce(p -> 'extra_min', '{}')) where value::numeric > 0;
  v_early := coalesce(nullif(p ->> 'mix_early_h', '')::numeric, 0);
  v_from := (p ->> 'date_from')::date; v_to := (p ->> 'date_to')::date;
  if v_extra = '{}'::jsonb and v_early = 0 then raise exception 'Chưa có giờ tăng ca hoặc trộn sớm nào'; end if;
  perform plan.ot_check(v_extra, v_early, v_from, v_to);
  update plan.overtime_requests set status = 'CANCELLED', review_note = 'Thay bằng đề xuất mới' where status = 'PROPOSED';
  v_no := core.next_no('TC', 3);
  insert into plan.overtime_requests (req_no, plan_id, extra_min, mix_early_h, date_from, date_to, summary, reason)
  values (v_no, p_plan, v_extra, v_early, v_from, v_to, coalesce(p -> 'summary', '{}'), trim(p ->> 'reason'))
  returning id into v_id;
  if v_gd then
    perform plan.ot_apply(v_id);
  else
    perform wf.notify_users(array_remove(plan.gd_ids(), auth.uid()), 'Đề xuất tăng ca chờ duyệt: ' || v_no,
      trim(p ->> 'reason') || ' (' || to_char(v_from, 'DD/MM') || '–' || to_char(v_to, 'DD/MM') || ')', '/lich-may?tab=toiuu');
  end if;
  return v_id;
exception when invalid_text_representation or datetime_field_overflow or invalid_datetime_format then
  raise exception 'Ngày hoặc số giờ tăng ca không hợp lệ';
end $$;
revoke all on function app.kh_ot_propose(uuid, jsonb) from public, anon;
grant execute on function app.kh_ot_propose(uuid, jsonb) to authenticated;

create or replace function app.kh_ot_review(p_req uuid, p_approve boolean, p_note text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare o plan.overtime_requests;
begin
  if not plan.is_gd() then raise exception 'Chỉ Giám đốc duyệt tăng ca'; end if;
  select * into o from plan.overtime_requests where id = p_req for update;
  if not found then raise exception 'Không tìm thấy đề xuất tăng ca'; end if;
  if o.status <> 'PROPOSED' then raise exception 'Đề xuất % không còn chờ duyệt', o.req_no; end if;
  if o.proposed_by = auth.uid() then raise exception 'Không tự duyệt đề xuất tăng ca mình lập'; end if;
  if p_approve then
    perform plan.ot_check(o.extra_min, o.mix_early_h, o.date_from, o.date_to);
    update plan.overtime_requests set review_note = nullif(trim(p_note), '') where id = p_req;
    perform plan.ot_apply(p_req);
  else
    if coalesce(trim(p_note), '') = '' then raise exception 'Nhập lý do trả lại'; end if;
    update plan.overtime_requests set status = 'RETURNED', reviewed_by = auth.uid(), reviewed_at = now(), review_note = trim(p_note) where id = p_req;
  end if;
  if o.proposed_by is not null then
    perform wf.notify_users(array[o.proposed_by], case when p_approve then 'Giám đốc duyệt tăng ca: ' else 'Giám đốc trả lại đề xuất tăng ca: ' end || o.req_no,
      coalesce(nullif(trim(p_note), ''), case when p_approve then 'Bấm Xếp lại lịch để áp dụng.' else '' end), '/lich-may?tab=toiuu');
  end if;
end $$;
revoke all on function app.kh_ot_review(uuid, boolean, text) from public, anon;
grant execute on function app.kh_ot_review(uuid, boolean, text) to authenticated;

-- Kết thúc tăng ca sớm (Giám đốc, TP SX): bỏ khỏi tham số xếp lịch
create or replace function app.kh_ot_end(p_req uuid, p_note text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare o plan.overtime_requests;
begin
  if not (plan.is_gd() or core.has_role('SX_TP')) then raise exception 'Chỉ Giám đốc hoặc TP SX kết thúc tăng ca'; end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'Nhập lý do'; end if;
  select * into o from plan.overtime_requests where id = p_req for update;
  if not found then raise exception 'Không tìm thấy đề xuất tăng ca'; end if;
  if o.status = 'PROPOSED' then
    update plan.overtime_requests set status = 'CANCELLED', review_note = trim(p_note), reviewed_by = auth.uid(), reviewed_at = now() where id = p_req;
    return;
  end if;
  if o.status <> 'APPROVED' then raise exception 'Đề xuất % không còn hiệu lực', o.req_no; end if;
  update plan.overtime_requests set status = 'ENDED', review_note = coalesce(review_note || ' · ', '') || 'Kết thúc: ' || trim(p_note) where id = p_req;
  update master.planning_config set extra_min = '{}', mix_early_h = 0, ot_from = null, ot_until = null, ot_request_id = null,
    updated_at = now(), updated_by = auth.uid() where id = 1 and ot_request_id = p_req;
  perform app.kh_log('Tăng ca', 'Tăng ca / trộn sớm đang áp dụng', o.req_no, 'không', trim(p_note));
  perform app.kh_notify_role('SX_TP', 'Kết thúc tăng ca: ' || o.req_no, trim(p_note) || '. Bấm Xếp lại lịch.', '/lich-may?tab=toiuu');
end $$;
revoke all on function app.kh_ot_end(uuid, text) from public, anon;
grant execute on function app.kh_ot_end(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Lịch đang dùng cần xếp lại theo thuật toán mới
-- ---------------------------------------------------------------------------
insert into master.planning_param_log (section, item, old_value, new_value, reason)
values ('Tham số xếp lịch', 'Thuật toán xếp lịch', 'Gối đầu 1 ca', 'Theo thông số',
  'Anh Bình duyệt 28/10/2026: gối đầu theo bobin đầu tiên + QC, máy trộn cấp silicone theo nhịp line đúng hạn dùng, MES tối ưu thứ tự lô, tìm máy cổ chai, đề xuất tăng ca');
