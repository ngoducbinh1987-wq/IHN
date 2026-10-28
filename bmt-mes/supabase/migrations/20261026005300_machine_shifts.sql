-- Máy bị chậm thì chạy 2 ca, 3 ca; người xếp theo máy, tối đa 12 giờ/ngày (anh Bình duyệt 28/10/2026,
-- Claude Doc "BMT MES – Phương án tháo nút cổ chai: máy chạy 2–3 ca, người theo máy", 5 điểm đã chọn):
--  - máy trộn cần 1 người đứng riêng suốt lúc trộn;
--  - ca dài 12 giờ chỉ dùng tạm khi thiếu người, MES dừng khi người đó hết giờ làm thêm trong tháng;
--  - MES đề xuất thêm ca khi có lô trễ ngày chốt / hạn giao (muốn xong sớm hơn thì TP SX chọn "Xong sớm nhất");
--  - TP SX / Kế hoạch SX đề xuất, Giám đốc duyệt, Chủ tịch không duyệt (Giám đốc tự lập thì áp ngay);
--  - người thật: TP SX khai báo công nhân, tay nghề, ca làm việc của từng người ở Nhân sự xưởng.
-- Giờ ca 2, ca 3 của máy chạy nhiều ca = giờ ca B, ca C ở Tham số xếp lịch (Giám đốc đặt; phần trùng giờ ca A không tính thêm).
-- Bộ xếp lịch web (lib/kh/roster.ts, scheduler.ts) tính giờ chạy thêm theo người có thật: thiếu người thì máy không chạy ca đó.

-- ===========================================================================
-- 1. Thông số: giờ làm tối đa mỗi người mỗi ngày (cả làm thêm)
-- ===========================================================================
alter table master.planning_config add column if not exists day_max_h numeric not null default 12;
alter table master.planning_config drop constraint if exists planning_config_day_max_chk;
alter table master.planning_config add constraint planning_config_day_max_chk check (day_max_h between 8 and 12);

-- ===========================================================================
-- 2. Bảng
-- ===========================================================================
-- Đề xuất thêm ca: mỗi dòng items = {machines:[mã máy], shifts: 2|3, from, to, group}
create table if not exists plan.shift_requests (
  id          uuid primary key default gen_random_uuid(),
  req_no      text not null unique,
  plan_id     uuid references plan.production_plans(id) on delete set null,
  items       jsonb not null default '[]' check (jsonb_typeof(items) = 'array'),
  summary     jsonb not null default '{}',     -- MES tính: ngày xong trước/sau, người cần thêm, thiếu người
  reason      text not null,
  status      text not null default 'PROPOSED' check (status in ('PROPOSED','APPROVED','RETURNED','CANCELLED','ENDED')),
  proposed_by uuid default auth.uid(),
  proposed_at timestamptz not null default now(),
  reviewed_by uuid,
  reviewed_at timestamptz,
  review_note text
);
-- Ca máy đã duyệt (áp vào lịch): máy chạy 2 hoặc 3 ca từ ngày … đến ngày (kết thúc sớm / bị thay: ended_on)
create table if not exists plan.machine_shifts (
  id           uuid primary key default gen_random_uuid(),
  request_id   uuid not null references plan.shift_requests(id) on delete cascade,
  machine_code text not null,
  date_from    date not null,
  date_to      date not null,
  shifts       integer not null check (shifts in (2, 3)),
  ended_on     date,
  created_at   timestamptz not null default now(),
  check (date_to >= date_from)
);
create index if not exists machine_shifts_machine_idx on plan.machine_shifts (machine_code, date_from);
-- Ca làm việc của người (mặc định ca 1 = ca A); TP SX đặt người làm ca 2 / ca 3 theo khoảng ngày
create table if not exists plan.operator_shifts (
  id            uuid primary key default gen_random_uuid(),
  operator_code text not null references master.operators(code) on update cascade on delete cascade,
  date_from     date not null,
  date_to       date not null,
  shift_no      integer not null check (shift_no in (2, 3)),
  note          text,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  check (date_to >= date_from)
);
create index if not exists operator_shifts_op_idx on plan.operator_shifts (operator_code, date_from);

do $$
declare t text;
begin
  foreach t in array array['plan.shift_requests','plan.machine_shifts','plan.operator_shifts'] loop
    execute format('alter table %s enable row level security', t);
    execute format('drop policy if exists p_select on %s', t);
    execute format('create policy p_select on %s for select to authenticated using (app.kh_can_view())', t);
    execute format('grant select on %s to authenticated', t);
  end loop;
end $$;

-- ===========================================================================
-- 3. Hàm hỗ trợ
-- ===========================================================================
-- Ca số → mã ca (1 = A, 2 = B, 3 = C) và giờ ca (phút trong ngày, ca qua nửa đêm: giờ hết + 1440)
create or replace function plan.shift_code(p_no integer) returns text
language sql immutable set search_path = pg_catalog, public as $$ select case p_no when 2 then 'B' when 3 then 'C' else 'A' end $$;

create or replace function plan.shift_span(p_no integer, out start_min integer, out end_min integer)
language sql stable security definer set search_path = pg_catalog, public as $$
  select (extract(hour from s.start_time) * 60 + extract(minute from s.start_time))::int,
         (extract(hour from s.end_time) * 60 + extract(minute from s.end_time))::int
         + case when s.end_time <= s.start_time then 1440 else 0 end
  from master.shifts s where s.code = plan.shift_code(p_no)
$$;
revoke all on function plan.shift_span(integer) from public, anon, authenticated;

-- Giờ nghỉ khi làm ca a ngày d rồi ca b ngày d + 1
create or replace function plan.shift_rest_h(p_a integer, p_b integer) returns numeric
language sql stable security definer set search_path = pg_catalog, public as $$
  select ((1440 + (select start_min from plan.shift_span(p_b))) - (select end_min from plan.shift_span(p_a)))::numeric / 60
$$;
revoke all on function plan.shift_rest_h(integer, integer) from public, anon, authenticated;

create or replace function plan.is_workday(p_d date) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select extract(isodow from p_d)::int in (select x::int from jsonb_array_elements_text(coalesce(mfg.machine_setting('shift') -> 'workdays', '[1,2,3,4,5,6]')) x)
$$;
revoke all on function plan.is_workday(date) from public, anon, authenticated;

-- Ca của một người một ngày (không có khoảng ca 2 / ca 3 thì ca 1)
create or replace function plan.op_shift_on(p_code text, p_d date) returns integer
language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce((select x.shift_no from plan.operator_shifts x where x.operator_code = p_code and p_d between x.date_from and x.date_to
                   order by x.created_at desc limit 1), 1)
$$;
revoke all on function plan.op_shift_on(text, date) from public, anon, authenticated;

-- Đổi ca phải nghỉ ít nhất 12 giờ: kiểm mọi lần chuyển ca giữa hai ngày làm việc liền nhau trong khoảng ngày
create or replace function plan.check_op_rest(p_code text, p_from date, p_to date) returns void
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare d date; a integer; b integer; h numeric;
begin
  for d in select g::date from generate_series(p_from, p_to, interval '1 day') g loop
    if not plan.is_workday(d) or not plan.is_workday(d + 1) then continue; end if;
    a := plan.op_shift_on(p_code, d); b := plan.op_shift_on(p_code, d + 1);
    if a = b then continue; end if;
    h := plan.shift_rest_h(a, b);
    if h < 12 then
      raise exception '% chuyển từ ca % (ngày %) sang ca % (ngày %) chỉ nghỉ % giờ: phải nghỉ ít nhất 12 giờ khi đổi ca, để trống một ngày hoặc đổi ngày',
        p_code, a, to_char(d, 'DD/MM'), b, to_char(d + 1, 'DD/MM'), replace(trim_scale(round(h, 1))::text, '.', ',');
    end if;
  end loop;
end $$;
revoke all on function plan.check_op_rest(text, date, date) from public, anon, authenticated;

-- ===========================================================================
-- 4. Ca làm việc của người (Nhân sự xưởng)
-- ===========================================================================
create or replace function app.kh_save_op_shift(p_id uuid, p_operator text, p_from date, p_to date, p_shift integer, p_note text default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid; v_to date := coalesce(p_to, p_from); o master.operators; old plan.operator_shifts;
begin
  if not plan.can_staff() then raise exception 'Chỉ TP SX / Kế hoạch SX đặt ca làm việc của người'; end if;
  select * into o from master.operators where code = p_operator;
  if not found or not o.active then raise exception 'Người % không có hoặc đã ngừng làm', p_operator; end if;
  if p_from is null then raise exception 'Chọn ngày bắt đầu'; end if;
  if v_to < p_from then raise exception 'Đến ngày phải sau từ ngày'; end if;
  if v_to - p_from > 183 then raise exception 'Mỗi lần đặt tối đa 6 tháng'; end if;
  if p_shift not in (2, 3) then raise exception 'Chọn ca 2 hoặc ca 3 (ngoài khoảng này người làm ca 1)'; end if;
  if v_to < plan.vn_today() then raise exception 'Không đặt ca cho ngày đã qua'; end if;
  if exists (select 1 from plan.operator_shifts x where x.operator_code = p_operator and x.id is distinct from p_id
             and x.date_from <= v_to and x.date_to >= p_from) then
    raise exception '% đã có ca làm việc trùng ngày', p_operator;
  end if;
  if p_id is null then
    insert into plan.operator_shifts (operator_code, date_from, date_to, shift_no, note)
    values (p_operator, p_from, v_to, p_shift, nullif(trim(coalesce(p_note, '')), '')) returning id into v_id;
  else
    select * into old from plan.operator_shifts where id = p_id for update;
    if not found then raise exception 'Không tìm thấy ca làm việc'; end if;
    update plan.operator_shifts set operator_code = p_operator, date_from = p_from, date_to = v_to, shift_no = p_shift,
           note = nullif(trim(coalesce(p_note, '')), '') where id = p_id;
    v_id := p_id;
  end if;
  perform plan.check_op_rest(p_operator, least(p_from, coalesce(old.date_from, p_from)) - 1, greatest(v_to, coalesce(old.date_to, v_to)));
  perform app.kh_log('Ca làm việc của người', p_operator || coalesce(' ' || o.full_name, ''),
    coalesce('ca ' || old.shift_no || ' ' || to_char(old.date_from, 'DD/MM') || '–' || to_char(old.date_to, 'DD/MM'), 'ca 1'),
    'ca ' || p_shift || ' ' || to_char(p_from, 'DD/MM') || '–' || to_char(v_to, 'DD/MM'),
    coalesce(nullif(trim(coalesce(p_note, '')), ''), 'Phân ca cho máy chạy nhiều ca'));
  return v_id;
end $$;

create or replace function app.kh_delete_op_shift(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare x plan.operator_shifts;
begin
  if not plan.can_staff() then raise exception 'Chỉ TP SX / Kế hoạch SX sửa ca làm việc của người'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do bỏ ca làm việc'; end if;
  delete from plan.operator_shifts where id = p_id returning * into x;
  if x.id is null then raise exception 'Không tìm thấy ca làm việc'; end if;
  perform plan.check_op_rest(x.operator_code, x.date_from - 1, x.date_to);
  perform app.kh_log('Ca làm việc của người', x.operator_code, 'ca ' || x.shift_no || ' ' || to_char(x.date_from, 'DD/MM') || '–' || to_char(x.date_to, 'DD/MM'),
    'ca 1', trim(p_reason));
end $$;

-- Giờ làm tối đa mỗi người mỗi ngày (Giám đốc)
create or replace function app.kh_save_shift_rules(p_day_max_h numeric, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_old numeric;
begin
  if not core.has_role('BGD') then raise exception 'Chỉ Giám đốc sửa giờ làm tối đa mỗi ngày'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do thay đổi'; end if;
  if p_day_max_h is null or p_day_max_h < 8 or p_day_max_h > 12 then raise exception 'Giờ làm tối đa mỗi ngày từ 8 đến 12 giờ (luật: không quá 12 giờ kể cả làm thêm)'; end if;
  select day_max_h into v_old from master.planning_config where id = 1 for update;
  if v_old = p_day_max_h then raise exception 'Không có thay đổi'; end if;
  update master.planning_config set day_max_h = p_day_max_h, updated_at = now(), updated_by = auth.uid() where id = 1;
  perform app.kh_log('Tham số xếp lịch', 'Giờ làm tối đa mỗi người mỗi ngày (giờ)', v_old::text, p_day_max_h::text, trim(p_reason));
end $$;

-- ===========================================================================
-- 5. Đề xuất thêm ca: TP SX / Kế hoạch SX đề xuất → Giám đốc duyệt (Giám đốc tự lập thì áp ngay)
-- ===========================================================================
-- Kiểm nội dung: máy xếp lịch, 2 hoặc 3 ca, khoảng ngày từ hôm nay, tối đa 2 tháng; máy trộn chạy cùng ca line silicone;
-- một máy không có hai dòng trùng ngày
create or replace function plan.shift_check(p_items jsonb) returns void
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare it jsonb; m text; v_from date; v_to date; v_n integer; i integer := 0; j integer; it2 jsonb; t text;
  has_line boolean; has_mixer boolean;
begin
  if jsonb_typeof(coalesce(p_items, 'null')) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Chưa có máy nào thêm ca'; end if;
  for it in select value from jsonb_array_elements(p_items) loop
    i := i + 1;
    if jsonb_typeof(it -> 'machines') <> 'array' or jsonb_array_length(it -> 'machines') = 0 then raise exception 'Dòng % chưa chọn máy', i; end if;
    begin
      v_n := (it ->> 'shifts')::int; v_from := (it ->> 'from')::date; v_to := (it ->> 'to')::date;
    exception when others then raise exception 'Dòng %: số ca hoặc ngày không hợp lệ', i;
    end;
    if v_n is null or v_n not in (2, 3) then raise exception 'Dòng %: chọn 2 hoặc 3 ca', i; end if;
    if v_from is null or v_to is null or v_to < v_from then raise exception 'Dòng %: chọn khoảng ngày (đến ngày không trước từ ngày)', i; end if;
    if v_from < plan.vn_today() then raise exception 'Dòng %: không thêm ca cho ngày đã qua', i; end if;
    if v_to - v_from > 62 then raise exception 'Dòng %: mỗi lần thêm ca tối đa 2 tháng', i; end if;
    has_line := false; has_mixer := false;
    for m in select jsonb_array_elements_text(it -> 'machines') loop
      if not plan.is_sched_machine(m) then raise exception 'Máy % không phải dây chuyền xếp lịch', m; end if;
      select machine_type into t from master.machines where code = m;
      if t = 'EXTRUDER_SI' then has_line := true; end if;
      if t = 'MIXER' then has_mixer := true; end if;
    end loop;
    -- silicone đã pha chỉ dùng trong hạn: máy trộn chạy cùng ca, cùng ngày với line silicone
    if has_line and exists (select 1 from master.machines x where x.machine_type = 'MIXER' and x.active and x.inline_with is null
                            and not (it -> 'machines') ? x.code) then
      raise exception 'Dòng %: line silicone chạy thêm ca thì máy trộn phải chạy cùng ca (silicone đã pha chỉ dùng trong hạn)', i;
    end if;
    if has_mixer and not has_line then raise exception 'Dòng %: máy trộn chỉ thêm ca cùng line silicone', i; end if;
    j := 0;
    for it2 in select value from jsonb_array_elements(p_items) loop
      j := j + 1;
      if j <= i then continue; end if;
      if (it2 ->> 'from')::date <= v_to and (it2 ->> 'to')::date >= v_from
         and exists (select 1 from jsonb_array_elements_text(it -> 'machines') a join jsonb_array_elements_text(it2 -> 'machines') b on a = b) then
        raise exception 'Dòng % và dòng % trùng máy, trùng ngày', i, j;
      end if;
    end loop;
  end loop;
end $$;
revoke all on function plan.shift_check(jsonb) from public, anon, authenticated;

-- Áp đề xuất đã duyệt vào lịch: ca máy cũ trùng ngày của cùng máy kết thúc trước ngày bắt đầu của dòng mới
create or replace function plan.shift_apply(p_req uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare o plan.shift_requests; it jsonb; m text; v_from date; v_to date; v_n integer; v_txt text := '';
begin
  select * into o from plan.shift_requests where id = p_req for update;
  for it in select value from jsonb_array_elements(o.items) loop
    v_from := (it ->> 'from')::date; v_to := (it ->> 'to')::date; v_n := (it ->> 'shifts')::int;
    for m in select jsonb_array_elements_text(it -> 'machines') loop
      update plan.machine_shifts s set ended_on = greatest(s.date_from - 1, v_from - 1)
       where s.machine_code = m and s.request_id <> p_req
         and least(s.date_to, coalesce(s.ended_on, s.date_to)) >= v_from and s.date_from <= v_to;
      insert into plan.machine_shifts (request_id, machine_code, date_from, date_to, shifts) values (p_req, m, v_from, v_to, v_n);
    end loop;
    v_txt := v_txt || case when v_txt = '' then '' else '; ' end
      || (select string_agg(x, ', ') from jsonb_array_elements_text(it -> 'machines') x) || ' ' || v_n || ' ca '
      || to_char(v_from, 'DD/MM') || '–' || to_char(v_to, 'DD/MM');
  end loop;
  update plan.shift_requests set status = 'APPROVED', reviewed_by = auth.uid(), reviewed_at = now() where id = p_req;
  perform app.kh_log('Ca máy', 'Máy chạy nhiều ca: ' || o.req_no, '—', v_txt, o.reason);
  perform app.kh_notify_role('SX_TP', 'Thêm ca đã duyệt: ' || o.req_no, v_txt || '. Phân người ca 2, ca 3 ở Nhân sự xưởng, rồi bấm Xếp lại lịch.', '/lich-may?tab=toiuu');
  perform app.kh_notify_role('SX_KH', 'Thêm ca đã duyệt: ' || o.req_no, v_txt || '. Bấm Xếp lại lịch.', '/lich-may?tab=toiuu');
end $$;
revoke all on function plan.shift_apply(uuid) from public, anon, authenticated;

create or replace function app.kh_shift_propose(p_plan uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid; v_no text; v_gd boolean := plan.is_gd(); v_direct boolean := auth.uid() = any(plan.gd_ids()); v_old record;
begin
  if not (core.has_role('SX_TP') or core.has_role('SX_KH') or v_gd) then raise exception 'Chỉ TP SX, Kế hoạch SX hoặc Giám đốc đề xuất thêm ca'; end if;
  if coalesce(trim(p ->> 'reason'), '') = '' then raise exception 'Nhập lý do thêm ca'; end if;
  perform plan.shift_check(p -> 'items');
  v_no := core.next_no('CA', 3);
  -- đề xuất còn chờ duyệt bị thay: báo người lập
  for v_old in select id, req_no, proposed_by from plan.shift_requests where status = 'PROPOSED' for update loop
    update plan.shift_requests set status = 'CANCELLED', review_note = 'Thay bằng ' || v_no, reviewed_by = auth.uid(), reviewed_at = now()
     where id = v_old.id;
    if v_old.proposed_by is not null and v_old.proposed_by is distinct from auth.uid() then
      perform wf.notify_users(array[v_old.proposed_by], 'Đề xuất thêm ca ' || v_old.req_no || ' được thay bằng ' || v_no, trim(p ->> 'reason'), '/lich-may?tab=toiuu');
    end if;
  end loop;
  insert into plan.shift_requests (req_no, plan_id, items, summary, reason)
  values (v_no, p_plan, p -> 'items', coalesce(p -> 'summary', '{}'), trim(p ->> 'reason')) returning id into v_id;
  -- Giám đốc tự đề xuất thì áp ngay; Quản trị hay người khác lập thì chờ Giám đốc duyệt
  if v_direct then
    perform plan.shift_apply(v_id);
  else
    perform wf.notify_users(array_remove(plan.gd_ids(), auth.uid()), 'Đề xuất thêm ca chờ duyệt: ' || v_no, trim(p ->> 'reason'), '/lich-may?tab=toiuu');
  end if;
  return v_id;
end $$;
revoke all on function app.kh_shift_propose(uuid, jsonb) from public, anon;
grant execute on function app.kh_shift_propose(uuid, jsonb) to authenticated;

create or replace function app.kh_shift_review(p_req uuid, p_approve boolean, p_note text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare o plan.shift_requests;
begin
  if not plan.is_gd() then raise exception 'Chỉ Giám đốc duyệt thêm ca'; end if;
  select * into o from plan.shift_requests where id = p_req for update;
  if not found then raise exception 'Không tìm thấy đề xuất thêm ca'; end if;
  if o.status <> 'PROPOSED' then raise exception 'Đề xuất % không còn chờ duyệt', o.req_no; end if;
  if o.proposed_by = auth.uid() then raise exception 'Không tự duyệt đề xuất thêm ca mình lập'; end if;
  if p_approve then
    perform plan.shift_check(o.items);
    update plan.shift_requests set review_note = nullif(trim(p_note), '') where id = p_req;
    perform plan.shift_apply(p_req);
  else
    if coalesce(trim(p_note), '') = '' then raise exception 'Nhập lý do trả lại'; end if;
    update plan.shift_requests set status = 'RETURNED', reviewed_by = auth.uid(), reviewed_at = now(), review_note = trim(p_note) where id = p_req;
  end if;
  if o.proposed_by is not null then
    perform wf.notify_users(array[o.proposed_by], case when p_approve then 'Giám đốc duyệt thêm ca: ' else 'Giám đốc trả lại đề xuất thêm ca: ' end || o.req_no,
      coalesce(nullif(trim(p_note), ''), case when p_approve then 'Phân người ở Nhân sự xưởng, rồi bấm Xếp lại lịch.' else '' end), '/lich-may?tab=toiuu');
  end if;
end $$;
revoke all on function app.kh_shift_review(uuid, boolean, text) from public, anon;
grant execute on function app.kh_shift_review(uuid, boolean, text) to authenticated;

-- Kết thúc thêm ca sớm (Giám đốc, TP SX): máy về 1 ca từ ngày mai
create or replace function app.kh_shift_end(p_req uuid, p_note text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare o plan.shift_requests;
begin
  if not (plan.is_gd() or core.has_role('SX_TP')) then raise exception 'Chỉ Giám đốc hoặc TP SX kết thúc thêm ca'; end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'Nhập lý do'; end if;
  select * into o from plan.shift_requests where id = p_req for update;
  if not found then raise exception 'Không tìm thấy đề xuất thêm ca'; end if;
  if o.status = 'PROPOSED' then
    update plan.shift_requests set status = 'CANCELLED', review_note = trim(p_note), reviewed_by = auth.uid(), reviewed_at = now() where id = p_req;
    return;
  end if;
  if o.status <> 'APPROVED' then raise exception 'Đề xuất % không còn hiệu lực', o.req_no; end if;
  update plan.shift_requests set status = 'ENDED', review_note = coalesce(review_note || ' · ', '') || 'Kết thúc: ' || trim(p_note) where id = p_req;
  update plan.machine_shifts set ended_on = greatest(date_from - 1, plan.vn_today())
   where request_id = p_req and least(date_to, coalesce(ended_on, date_to)) > plan.vn_today();
  perform app.kh_log('Ca máy', 'Máy chạy nhiều ca: ' || o.req_no, 'đang áp dụng', 'kết thúc từ ngày mai', trim(p_note));
  perform app.kh_notify_role('SX_TP', 'Kết thúc thêm ca: ' || o.req_no, trim(p_note) || '. Bấm Xếp lại lịch.', '/lich-may?tab=toiuu');
end $$;
revoke all on function app.kh_shift_end(uuid, text) from public, anon;
grant execute on function app.kh_shift_end(uuid, text) to authenticated;

-- ===========================================================================
-- 6. Views
-- ===========================================================================
create or replace view app.v_kh_shift_requests with (security_invoker = true) as
select r.*, app.user_name(r.proposed_by) as proposed_by_name, app.user_name(r.reviewed_by) as reviewed_by_name,
  (select p.plan_no from plan.production_plans p where p.id = r.plan_id) as plan_no
from plan.shift_requests r;
create or replace view app.v_kh_machine_shifts with (security_invoker = true) as
select s.*, least(s.date_to, coalesce(s.ended_on, s.date_to)) as eff_to, r.req_no, r.status as req_status
from plan.machine_shifts s join plan.shift_requests r on r.id = s.request_id;
create or replace view app.v_kh_op_shifts with (security_invoker = true) as
select x.*, o.full_name, app.user_name(x.created_by) as created_by_name
from plan.operator_shifts x join master.operators o on o.code = x.operator_code;

-- Tham số xếp lịch: giữ nguyên các cột cũ (migration 5000), thêm cuối giờ làm tối đa, ca máy, ca của người
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
            from plan.operator_shifts x where x.date_to >= (now() at time zone 'Asia/Ho_Chi_Minh')::date - 62), '[]') as op_shifts
from master.planning_config c
where c.id = 1;

grant select on app.v_kh_shift_requests, app.v_kh_machine_shifts, app.v_kh_op_shifts, app.v_kh_config to authenticated;
