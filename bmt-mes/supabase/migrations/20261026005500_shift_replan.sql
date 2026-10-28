-- Tính lại tiến độ sau mỗi ca (anh Bình 28/10/2026 20:04): 1 giờ sau khi hết ca, MES rà sản lượng máy đạt được thực tế
-- (phiếu hoàn thành bobin, báo cáo ca), tính lại sản lượng còn phải làm theo từng lô, xếp lại lịch máy từ cuối ca đó;
-- gửi Giám đốc, TP SX các lô nhanh / chậm hơn và ngày hoàn thành mới.
-- Bộ xếp lịch chạy trên web (TypeScript): web gọi app.replan_claim → tính → app.kh_replan_save. Lịch tính lại theo tiến độ
-- là lịch đang dùng ngay (giữ thứ tự lô, lô đã duyệt lịch, không thêm/bớt lô, không đổi số mét: chỉ phản ánh thực tế).

alter table master.planning_config add column if not exists replan_after_min integer not null default 60
  check (replan_after_min between 0 and 240);

-- ===========================================================================
-- 1. Nhật ký tính lại
-- ===========================================================================
create table if not exists plan.replan_runs (
  id          uuid primary key default gen_random_uuid(),
  plan_id     uuid not null references plan.production_plans(id) on delete cascade,
  kind        text not null default 'SHIFT' check (kind in ('SHIFT', 'MANUAL')),
  work_date   date not null,
  shift_code  text not null check (shift_code in ('A', 'B', 'C')),
  shift_end   timestamptz not null,
  status      text not null default 'RUNNING' check (status in ('RUNNING', 'DONE', 'ERROR', 'SKIPPED')),
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  run_by      uuid,
  version_id  uuid references plan.schedule_versions(id) on delete set null,
  result      jsonb not null default '{}',   -- web tính: máy đạt / kế hoạch trong ca, máy chưa có phiếu, mét bù từng lô
  lots        jsonb not null default '[]',   -- database so: ngày xong cũ → mới từng lô
  error       text
);
create unique index if not exists replan_runs_shift on plan.replan_runs (plan_id, work_date, shift_code) where kind = 'SHIFT';
create index if not exists replan_runs_plan_idx on plan.replan_runs (plan_id, started_at desc);
alter table plan.replan_runs enable row level security;
drop policy if exists p_select on plan.replan_runs;
create policy p_select on plan.replan_runs for select to authenticated using (app.kh_can_view());
grant select on plan.replan_runs to authenticated;

-- ===========================================================================
-- 2. Ca nào chạy ngày nào, giờ hết ca (giờ VN)
-- ===========================================================================
create or replace function plan.shift_no_of(p_code text) returns integer
language sql immutable set search_path = pg_catalog, public as $$ select case p_code when 'B' then 2 when 'C' then 3 else 1 end $$;

create or replace function plan.shift_end_at(p_d date, p_code text) returns timestamptz
language sql stable security definer set search_path = pg_catalog, public as $$
  select ((p_d + s.end_time + case when s.end_time <= s.start_time then interval '1 day' else interval '0' end)::timestamp)
         at time zone 'Asia/Ho_Chi_Minh'
  from master.shifts s where s.code = p_code
$$;
revoke all on function plan.shift_end_at(date, text) from public, anon, authenticated;

-- Ca có chạy trong ngày: ca 1 mọi ngày làm việc; ca 2, ca 3 khi cả xưởng chạy hoặc có máy chạy thêm ca (bảng ca tuần)
create or replace function plan.shift_runs_on(p_d date, p_code text) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select plan.is_workday(p_d) and (
    p_code = 'A'
    or exists (select 1 from master.shifts s where s.code = p_code and s.active)
    or exists (select 1 from plan.machine_shifts m
               where m.date_from <= p_d and least(m.date_to, coalesce(m.ended_on, m.date_to)) >= p_d
                 and m.shifts >= plan.shift_no_of(p_code)))
$$;
revoke all on function plan.shift_runs_on(date, text) from public, anon, authenticated;

-- Ca gần nhất đã hết trước p_at (xét 3 ngày gần nhất, giờ VN)
create or replace function plan.last_shift_end(p_at timestamptz, out work_date date, out shift_code text, out shift_end timestamptz)
language sql stable security definer set search_path = pg_catalog, public as $$
  select d, c, plan.shift_end_at(d, c)
  from generate_series((p_at at time zone 'Asia/Ho_Chi_Minh')::date - 2, (p_at at time zone 'Asia/Ho_Chi_Minh')::date, interval '1 day') g(dd)
  cross join lateral (select g.dd::date as d) x
  cross join unnest(array['A', 'B', 'C']) c
  where plan.shift_runs_on(d, c) and plan.shift_end_at(d, c) <= p_at
  order by plan.shift_end_at(d, c) desc limit 1
$$;
revoke all on function plan.last_shift_end(timestamptz) from public, anon, authenticated;

-- Ai được chạy: máy chủ (service role, job sau ca) hoặc người xếp lịch (TP SX, Kế hoạch SX, Giám đốc; Quản trị qua has_role)
create or replace function plan.replan_allowed() returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce(auth.role(), '') = 'service_role' or app.kh_has_any(array['SX_TP', 'SX_KH', 'BGD'])
$$;
revoke all on function plan.replan_allowed() from public, anon, authenticated;

-- Ca cần tính lại của một kế hoạch: ca gần nhất đã hết ít nhất replan_after_min phút, chưa tính, không quá 18 giờ
create or replace function plan.replan_due_shift(p_plan uuid, p_manual boolean,
  out work_date date, out shift_code text, out shift_end timestamptz)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_delay int; x record;
begin
  if not exists (select 1 from plan.production_plans p where p.id = p_plan and p.status = 'APPROVED')
     or not exists (select 1 from plan.schedule_versions v where v.plan_id = p_plan and v.is_current) then return; end if;
  select coalesce(c.replan_after_min, 60) into v_delay from master.planning_config c where c.id = 1;
  select * into x from plan.last_shift_end(now() - case when p_manual then interval '0' else make_interval(mins => coalesce(v_delay, 60)) end);
  if x.shift_end is null or x.shift_end < now() - interval '18 hours' then return; end if;
  -- lịch đang dùng lập sau khi hết ca (đã tính lại / xếp lại) thì không cần tính tự động
  if not p_manual and exists (select 1 from plan.schedule_versions v where v.plan_id = p_plan and v.is_current
                              and v.created_at >= x.shift_end + make_interval(mins => coalesce(v_delay, 60))) then return; end if;
  if not p_manual and exists (select 1 from plan.replan_runs r where r.plan_id = p_plan and r.kind = 'SHIFT'
       and r.work_date = x.work_date and r.shift_code = x.shift_code
       and (r.status <> 'RUNNING' or r.started_at > now() - interval '15 minutes')) then return; end if;
  work_date := x.work_date; shift_code := x.shift_code; shift_end := x.shift_end;
end $$;
revoke all on function plan.replan_due_shift(uuid, boolean) from public, anon, authenticated;

-- Kế hoạch đến lượt tính lại (web và job máy chủ gọi trước khi tính)
create or replace function app.replan_due() returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if not plan.replan_allowed() then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(p.id order by p.created_at) from plan.production_plans p
                   where p.status = 'APPROVED' and (select d.shift_end from plan.replan_due_shift(p.id, false) d) is not null), '[]'::jsonb);
end $$;
revoke all on function app.replan_due() from public, anon;
grant execute on function app.replan_due() to authenticated, service_role;

-- Nhận lượt tính (chặn hai nơi cùng tính một ca)
create or replace function app.replan_claim(p_plan uuid, p_manual boolean default false) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare x record; v_id uuid; v_label text;
begin
  if not plan.replan_allowed() then raise exception 'Chỉ TP SX, Kế hoạch SX, Giám đốc tính lại tiến độ'; end if;
  perform 1 from plan.production_plans where id = p_plan for update;
  if not found then raise exception 'Không tìm thấy kế hoạch'; end if;
  select * into x from plan.replan_due_shift(p_plan, p_manual);
  if x.shift_end is null then
    if p_manual then raise exception 'Chưa có ca nào đã hết để tính lại (kế hoạch phải đã duyệt và có lịch đang dùng)'; end if;
    return null;
  end if;
  if p_manual then
    insert into plan.replan_runs (plan_id, kind, work_date, shift_code, shift_end, run_by)
    values (p_plan, 'MANUAL', x.work_date, x.shift_code, x.shift_end, auth.uid()) returning id into v_id;
  else
    insert into plan.replan_runs (plan_id, kind, work_date, shift_code, shift_end, run_by)
    values (p_plan, 'SHIFT', x.work_date, x.shift_code, x.shift_end, auth.uid())
    on conflict (plan_id, work_date, shift_code) where kind = 'SHIFT'
    do update set status = 'RUNNING', started_at = now(), run_by = excluded.run_by, error = null
       where plan.replan_runs.status = 'RUNNING' and plan.replan_runs.started_at <= now() - interval '15 minutes'
    returning id into v_id;
    if v_id is null then return null; end if;
  end if;
  v_label := 'ca ' || plan.shift_no_of(x.shift_code) || ' ' || to_char(x.work_date, 'DD/MM');
  return jsonb_build_object('run_id', v_id, 'plan_id', p_plan, 'work_date', x.work_date, 'shift_code', x.shift_code,
                            'shift_no', plan.shift_no_of(x.shift_code), 'shift_end', x.shift_end, 'label', v_label);
end $$;
revoke all on function app.replan_claim(uuid, boolean) from public, anon;
grant execute on function app.replan_claim(uuid, boolean) to authenticated, service_role;

create or replace function app.replan_fail(p_run uuid, p_error text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if not plan.replan_allowed() then raise exception 'Không có quyền'; end if;
  update plan.replan_runs set status = 'ERROR', finished_at = now(), error = left(coalesce(p_error, ''), 1000)
   where id = p_run and status = 'RUNNING';
end $$;
revoke all on function app.replan_fail(uuid, text) from public, anon;
grant execute on function app.replan_fail(uuid, text) to authenticated, service_role;

-- ===========================================================================
-- 3. Lưu lịch tính lại + so ngày xong từng lô + báo Giám đốc, TP SX
-- ===========================================================================
create or replace function app.kh_replan_save(p_run uuid, p_base date, p_params jsonb, p_orders jsonb, p_slots jsonb, p_result jsonb)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r plan.replan_runs; pp plan.production_plans; v plan.schedule_versions; v_id uuid; v_ver int; v_lab text;
  v_lots jsonb; v_slow int; v_fast int; v_late int; v_body text; v_mach text; v_miss text; v_title text; v_link text; o record;
begin
  if not plan.replan_allowed() then raise exception 'Chỉ TP SX, Kế hoạch SX, Giám đốc tính lại tiến độ'; end if;
  select * into r from plan.replan_runs where id = p_run for update;
  if not found or r.status <> 'RUNNING' then raise exception 'Lượt tính lại không còn hiệu lực'; end if;
  select * into pp from plan.production_plans where id = r.plan_id for update;
  select * into v from plan.schedule_versions where plan_id = r.plan_id and is_current;
  if not found then raise exception 'Kế hoạch chưa có lịch đang dùng'; end if;
  if v.base_date <> p_base then raise exception 'Ngày gốc của lịch không khớp phiên bản đang dùng'; end if;
  -- chỉ phản ánh thực tế: giữ thứ tự lô, không thêm / bớt lô, không đổi số mét
  if coalesce(p_params -> 'seq', '{}'::jsonb) <> coalesce(v.params -> 'seq', '{}'::jsonb) then
    raise exception 'Tính lại theo tiến độ không được đổi thứ tự lô (muốn đổi thì Xếp lại lịch, Giám đốc duyệt)';
  end if;
  if exists (select 1 from jsonb_array_elements(p_orders) e
             left join plan.plan_lines l on l.id = (e ->> 'plan_line_id')::uuid and l.plan_id = r.plan_id
             where l.id is null or round(l.qty_m, 3) <> round((e ->> 'qty_m')::numeric, 3)) then
    raise exception 'Lô hoặc số mét khác kế hoạch tháng';
  end if;
  v_lab := 'ca ' || plan.shift_no_of(r.shift_code) || ' ' || to_char(r.work_date, 'DD/MM');
  select coalesce(max(version), 0) + 1 into v_ver from plan.schedule_versions where plan_id = r.plan_id;
  -- bản TP SX đề xuất dựa trên lịch cũ: không còn đúng, báo người lập
  for o in select distinct created_by from plan.schedule_versions where plan_id = r.plan_id and status = 'PROPOSED' and created_by is not null loop
    perform wf.notify_users(array[o.created_by], 'Bản lịch đề xuất ' || pp.plan_no || ' đã cũ',
      'MES vừa tính lại lịch theo sản lượng thực tế ' || v_lab || '. Mở Lịch máy, xếp lại nếu cần.', '/lich-may?plan=' || r.plan_id);
  end loop;
  update plan.schedule_versions set status = 'SUPERSEDED' where plan_id = r.plan_id and status = 'PROPOSED';
  update plan.schedule_versions set is_current = false where plan_id = r.plan_id and is_current;
  insert into plan.schedule_versions (plan_id, version, base_date, params, reason, is_current, status, approved_at)
  values (r.plan_id, v_ver, p_base, p_params, 'MES tính lại theo sản lượng thực tế sau ' || v_lab, true, 'APPROVED', now())
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

  -- So ngày xong từng lô với lịch trước
  select coalesce(jsonb_agg(jsonb_build_object(
           'line', n.plan_line_id, 'label', n.label, 'product', n.product_code,
           'old', o2.finish_date, 'new', n.finish_date, 'target', coalesce(l.committed_date, l.due_date),
           'target_kind', case when l.committed_date is not null then 'chốt' when l.due_date is not null then 'hạn giao' end,
           'diff', case when n.finish_date is not null and o2.finish_date is not null then n.finish_date - o2.finish_date end,
           'late', case when n.finish_date is not null and coalesce(l.committed_date, l.due_date) is not null
                        then greatest(0, n.finish_date - coalesce(l.committed_date, l.due_date)) end)
           order by n.label), '[]'::jsonb)
    into v_lots
  from plan.schedule_orders n
  left join plan.schedule_orders o2 on o2.version_id = v.id and o2.plan_line_id = n.plan_line_id
  left join plan.plan_lines l on l.id = n.plan_line_id
  where n.version_id = v_id;
  select count(*) filter (where (x ->> 'diff')::int > 0), count(*) filter (where (x ->> 'diff')::int < 0),
         count(*) filter (where (x ->> 'late')::int > 0)
    into v_slow, v_fast, v_late from jsonb_array_elements(v_lots) x;

  update plan.replan_runs set status = 'DONE', finished_at = now(), version_id = v_id, lots = v_lots,
         result = coalesce(p_result, '{}'::jsonb) || jsonb_build_object('slower', v_slow, 'faster', v_fast, 'late', v_late, 'version', v_ver)
   where id = p_run;

  -- Thông báo: lô nhanh / chậm, ngày xong mới; máy đạt so với lịch trong ca; máy chưa có phiếu hoàn thành
  select string_agg(x ->> 'label' || ' ' || (x ->> 'product') || ': xong ' || coalesce(to_char((x ->> 'old')::date, 'DD/MM'), '?') || ' → '
           || coalesce(to_char((x ->> 'new')::date, 'DD/MM'), 'chưa xếp được')
           || case when (x ->> 'diff')::int > 0 then ' (chậm ' || (x ->> 'diff') || ' ngày'
                   when (x ->> 'diff')::int < 0 then ' (nhanh ' || abs((x ->> 'diff')::int) || ' ngày' else ' (không đổi' end
           || case when (x ->> 'late')::int > 0 then '; trễ ' || (x ->> 'late') || ' ngày so với ' || (x ->> 'target_kind') || ' ' || to_char((x ->> 'target')::date, 'DD/MM')
                   when x ->> 'target' is not null then '; kịp ' || (x ->> 'target_kind') || ' ' || to_char((x ->> 'target')::date, 'DD/MM') else '' end || ')',
           E'\n' order by (x ->> 'diff')::int desc nulls last, x ->> 'label')
    into v_body
  from jsonb_array_elements(v_lots) x
  where coalesce((x ->> 'diff')::int, 0) <> 0 or (x ->> 'late')::int > 0 or x ->> 'new' is null;
  select string_agg(m ->> 'machine' || ' ' || replace(to_char(round((m ->> 'actual')::numeric), 'FM999G999G999'), ',', '.') || '/' || replace(to_char(round((m ->> 'planned')::numeric), 'FM999G999G999'), ',', '.') || ' m'
           || case when (m ->> 'planned')::numeric > 0 then ' (' || round((m ->> 'actual')::numeric / (m ->> 'planned')::numeric * 100) || ' %)' else '' end, ', ')
    into v_mach
  from jsonb_array_elements(coalesce(p_result -> 'machines', '[]'::jsonb)) m where coalesce((m ->> 'missing')::boolean, false) = false;
  select string_agg(value, ', ') into v_miss from jsonb_array_elements_text(coalesce(p_result -> 'missing', '[]'::jsonb));
  v_title := 'Tiến độ sau ' || v_lab || ' · ' || pp.plan_no || ': '
    || case when v_slow + v_fast = 0 then 'lịch hoàn thành không đổi'
            else concat_ws(', ', case when v_slow > 0 then v_slow || ' lô chậm' end, case when v_fast > 0 then v_fast || ' lô nhanh' end) end
    || case when v_late > 0 then ' · ' || v_late || ' lô trễ hạn' else '' end;
  v_body := concat_ws(E'\n',
    case when v_body is not null then v_body else 'Mọi lô giữ ngày hoàn thành.' end,
    case when v_mach is not null then 'Máy đạt trong ca (thực tế/lịch): ' || v_mach end,
    case when v_miss is not null then 'Chưa có phiếu hoàn thành: ' || v_miss || ' (MES tạm coi chạy đúng lịch; Kế toán SX nhập phiếu rồi bấm Tính lại).' end);
  v_link := '/lich-may?plan=' || r.plan_id || '&tab=tiendo';
  if v_slow + v_fast + v_late > 0 then
    perform wf.notify_users(array(select distinct u from unnest(plan.gd_ids() || inv.role_users(array['SX_TP', 'SX_KH'])) u where u is not null),
                            left(v_title, 200), left(v_body, 1900), v_link);
  else
    perform wf.notify_users(array(select distinct u from unnest(inv.role_users(array['SX_TP', 'SX_KH'])) u where u is not null),
                            left(v_title, 200), left(v_body, 1900), v_link);
  end if;
  return jsonb_build_object('version_id', v_id, 'version', v_ver, 'slower', v_slow, 'faster', v_fast, 'late', v_late, 'lots', v_lots);
end $$;
revoke all on function app.kh_replan_save(uuid, date, jsonb, jsonb, jsonb, jsonb) from public, anon;
grant execute on function app.kh_replan_save(uuid, date, jsonb, jsonb, jsonb, jsonb) to authenticated, service_role;

create or replace view app.v_kh_replans with (security_invoker = true) as
select r.*, p.plan_no, v.version, app.user_name(r.run_by) as run_by_name, plan.shift_no_of(r.shift_code) as shift_no
from plan.replan_runs r join plan.production_plans p on p.id = r.plan_id
left join plan.schedule_versions v on v.id = r.version_id;
grant select on app.v_kh_replans to authenticated;

-- ===========================================================================
-- 4. Máy chủ: job pg_cron 10 phút/lần gọi web tính lại khi có kế hoạch đến lượt
--    (cần Vault mes_app_url, mes_cron_secret và CRON_SECRET, SUPABASE_SERVICE_ROLE_KEY trên Vercel;
--     chưa có thì web tự tính khi TP SX / Giám đốc mở MES)
-- ===========================================================================
create or replace function plan.replan_job() returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_url text; v_secret text;
begin
  if not exists (select 1 from plan.production_plans p where p.status = 'APPROVED'
                 and (select d.shift_end from plan.replan_due_shift(p.id, false) d) is not null) then return; end if;
  begin
    select decrypted_secret into v_url from vault.decrypted_secrets where name = 'mes_app_url';
    select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'mes_cron_secret';
  exception when others then return;
  end;
  if v_url is null or v_secret is null then return; end if;
  perform net.http_post(url := rtrim(v_url, '/') || '/api/cron/replan',
                        headers := jsonb_build_object('Authorization', 'Bearer ' || v_secret, 'Content-Type', 'application/json'),
                        body := '{}'::jsonb, timeout_milliseconds := 60000);
end $$;
revoke all on function plan.replan_job() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') and exists (select 1 from pg_extension where extname = 'pg_net') then
    perform cron.schedule('bmt_replan', '5-59/10 * * * *', 'select plan.replan_job()');
  end if;
exception when others then
  raise notice 'Chưa đặt được lịch bmt_replan: %', sqlerrm;
end $$;

-- Máy chủ (service role) đọc dữ liệu kế hoạch để tính lại (web dùng các view app.v_kh_* như người dùng)
do $$
declare s text;
begin
  if not exists (select 1 from pg_roles where rolname = 'service_role') then return; end if;
  foreach s in array array['app', 'plan', 'master', 'mfg', 'core', 'inv', 'qa', 'purchase', 'sales', 'wf', 'cost'] loop
    if exists (select 1 from pg_namespace where nspname = s) then
      execute format('grant usage on schema %I to service_role', s);
      execute format('grant select on all tables in schema %I to service_role', s);
      execute format('alter default privileges in schema %I grant select on tables to service_role', s);
    end if;
  end loop;
  -- hàm view gọi khi đọc (core.can_see_price, app.user_name…): máy chủ là tài khoản tin cậy
  foreach s in array array['app', 'core', 'plan', 'mfg', 'master', 'inv', 'wf', 'purchase', 'sales', 'qa', 'cost'] loop
    if exists (select 1 from pg_namespace where nspname = s) then
      execute format('grant execute on all functions in schema %I to service_role', s);
      execute format('alter default privileges in schema %I grant execute on functions to service_role', s);
    end if;
  end loop;
end $$;
