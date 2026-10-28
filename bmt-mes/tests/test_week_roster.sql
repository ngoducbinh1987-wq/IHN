-- Kiểm thử migration 20261026005400_week_roster: ca làm việc khai báo tự do (ca 1, 2, 3 nối tiếp, không chồng giờ),
-- mọi công nhân đứng chính mọi máy, sổ giờ đứng máy theo lịch, ngưỡng lệch, bảng phân ca tuần
-- (MES lập → TP SX gửi → Giám đốc duyệt / sửa / trả lại → áp ca máy, ca người, gửi công nhân), nhắc hạn 12:00 thứ 7.
-- Chạy được bằng psql hoặc MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create temp table t (k text primary key, v uuid);
create temp table x (k text primary key, j jsonb);
grant all on r, t, x to authenticated;
grant usage on sequence r_n_seq to authenticated;

create function pg_temp.as_user(p_code text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', (select id::text from core.profiles where employee_code = p_code), true),
         set_config('request.jwt.claims', json_build_object('sub', (select id::text from core.profiles where employee_code = p_code), 'role', 'authenticated')::text, true),
         set_config('request.jwt.claim.role', 'authenticated', true)
$$;
create function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_msg; end if;
  insert into r(msg) values (p_msg);
end $$;
create function pg_temp.api_fails(p_sql text, p_pattern text, p_msg text) returns void language plpgsql as $$
begin
  begin
    execute 'set local role authenticated';
    execute p_sql;
    execute 'reset role';
  exception when others then
    execute 'reset role';
    if sqlerrm ilike '%' || p_pattern || '%' then insert into r(msg) values (p_msg || ' → chặn: ' || sqlerrm); return; end if;
    raise exception 'FAIL: % — lỗi khác mong đợi: %', p_msg, sqlerrm;
  end;
  raise exception 'FAIL: % — lẽ ra phải bị chặn', p_msg;
end $$;
create function pg_temp.api_val(p_sql text) returns text language plpgsql as $$
declare v text;
begin
  execute 'set local role authenticated';
  execute p_sql into v;
  execute 'reset role';
  return v;
end $$;
create function pg_temp.today() returns date language sql as $$ select (now() at time zone 'Asia/Ho_Chi_Minh')::date $$;
create function pg_temp.nt(p_code text, p_like text) returns bigint language sql as $$
  select count(*) from wf.notifications n join core.profiles p on p.id = n.user_id where p.employee_code = p_code and n.title like p_like
$$;
set client_min_messages = notice;

-- Người dùng thử; tài khoản thật tạm khóa trong giao dịch
update core.profiles set status = 'LOCKED' where (employee_code is null or employee_code !~ '^G_') and status = 'ACTIVE';
with u(code) as (values ('G_BGD'),('G_SXTP'),('G_SXKH'),('G_KTTP'),('G_QC'),('G_VH'),('G_TT')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('G_BGD','BGD'),('G_SXTP','SX_TP'),('G_SXKH','SX_KH'),('G_KTTP','KT_TP'),
  ('G_QC','QC'),('G_VH','VAN_HANH'),('G_TT','TO_TRUONG')) u(code, role) on u.code = p.employee_code;
-- Giờ ca chuẩn trong giao dịch; mọi ngày trừ Chủ nhật là ngày làm việc; không còn ca máy, ca người, bảng ca cũ
update master.shifts set start_time = '06:00', end_time = '14:00', break_min = 30, active = true where code = 'A';
update master.shifts set start_time = '14:00', end_time = '22:00', break_min = 30, active = false where code = 'B';
update master.shifts set start_time = '22:00', end_time = '06:00', break_min = 45, active = false where code = 'C';
update master.machine_settings set value = jsonb_set(value, '{workdays}', '[1,2,3,4,5,6]') where key = 'shift';
update master.planning_config set balance_pct = 15 where id = 1;
delete from plan.week_rosters where true;
delete from plan.machine_shifts where true;
delete from plan.operator_shifts where true;
delete from plan.shift_requests where true;
delete from plan.operator_absences where true;
update master.operators set active = false where code !~ '^NV[1-5]$';
update master.operators set active = true, profile_id = null where code ~ '^NV[1-5]$';
-- Thứ Hai kế tiếp (ít nhất từ ngày mai)
insert into x values ('mon', to_jsonb((select min(d)::date from generate_series(pg_temp.today() + 1, pg_temp.today() + 8, interval '1 day') d where extract(isodow from d) = 1)));
create function pg_temp.mon(p_n int) returns date language sql as $$ select (select (j #>> '{}')::date from x where k = 'mon') + p_n $$;
-- Bảng ca thử: máy trộn + line silicone 1 chạy 2 ca thứ Hai–thứ Bảy; NV3 (phụ trách), NV4 làm ca 2
create function pg_temp.ms(p_m text[], p_n int, p_days int[]) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_object('machine', m, 'date', pg_temp.mon(d), 'shifts', p_n)), '[]') from unnest(p_m) m, unnest(p_days) d
$$;
create function pg_temp.pp(p_ca2 text[], p_lead text) returns jsonb language sql as $$
  select jsonb_agg(case when o.code = any(p_ca2) then jsonb_build_object('code', o.code, 'shift', 2, 'lead', o.code = p_lead)
                        else jsonb_build_object('code', o.code, 'shift', 1) end order by o.code)
  from master.operators o where o.active
$$;
create function pg_temp.rp(p_week date, p_ms jsonb, p_pp jsonb, p_qc jsonb default '{"mode":"LEAD"}') returns jsonb language sql as $$
  select jsonb_build_object('week_start', p_week, 'machines', p_ms, 'people', p_pp, 'qc', p_qc, 'summary', '{"reason":"thử"}')
$$;

-- ================================================================ 1. Cấu hình, quyền
select pg_temp.as_user('G_SXTP');
select pg_temp.ok(pg_temp.api_val($q$select concat_ws('|', balance_pct, jsonb_typeof(op_hours), jsonb_typeof(qc_cover), day_max_h, jsonb_typeof(op_shifts)) from app.v_kh_config$q$)
  = '15|array|array|12|array', 'Lịch máy đọc ngưỡng lệch (15 %), sổ giờ, ngày ca 2 có người đo mẫu QC; cột cũ vẫn còn');
select pg_temp.api_fails($q$insert into plan.week_rosters (roster_no, week_start) values ('X', date '2026-11-02')$q$, 'permission', 'Không ghi thẳng bảng ca tuần');
select pg_temp.api_fails($q$insert into plan.operator_day_hours (plan_id, work_date, operator_code) values (gen_random_uuid(), current_date, 'NV1')$q$, 'permission', 'Không ghi thẳng sổ giờ');
select pg_temp.api_fails($q$select plan.roster_apply(gen_random_uuid(), 'x')$q$, 'permission', 'Hàm áp bảng ca là hàm nội bộ');
select pg_temp.api_fails($q$select plan.roster_reminders()$q$, 'permission', 'Hàm nhắc hạn là hàm nội bộ');

-- ================================================================ 2. Ca làm việc: Giám đốc khai báo, ca 1, 2, 3 nối tiếp, không chồng giờ
select pg_temp.api_fails($q$select app.kh_save_shifts('[{"code":"A","start_time":"07:00","end_time":"15:00","break_min":30}]', 'thử')$q$, 'Chỉ Giám đốc', 'TP SX không sửa giờ ca');
select pg_temp.as_user('G_BGD');
select pg_temp.api_fails($q$select app.kh_save_shifts('[{"code":"A","start_time":"07:00","end_time":"15:00","break_min":30}]', '')$q$, 'lý do', 'Bắt buộc lý do');
select pg_temp.api_fails($q$select app.kh_save_shifts('[{"code":"A","start_time":"08:00","end_time":"17:00","break_min":60}]', 'thử')$q$, 'Ca 2 phải bắt đầu từ lúc ca 1 kết thúc',
  'Ca 1 08–17 chồng ca 2 14–22: chặn');
select pg_temp.api_fails($q$select app.kh_save_shifts('[{"code":"B","start_time":"14:00","end_time":"23:00","break_min":30}]', 'thử')$q$, 'Ca 3 phải bắt đầu từ lúc ca 2 kết thúc',
  'Ca 2 14–23 chồng ca 3 22–06: chặn');
select pg_temp.api_fails($q$select app.kh_save_shifts('[{"code":"C","start_time":"22:00","end_time":"07:00","break_min":45}]', 'thử')$q$, 'trước giờ vào ca 1',
  'Ca 3 22–07 sang giờ ca 1 hôm sau: chặn');
select pg_temp.api_fails($q$select app.kh_save_shifts('[{"code":"A","start_time":"01:00","end_time":"14:00","break_min":30}]', 'thử')$q$, 'từ 4 đến 12 giờ', 'Một ca không quá 12 giờ');
select pg_temp.api_fails($q$select app.kh_save_shifts('[{"code":"A","start_time":"06:00","end_time":"14:00","break_min":30}]', 'thử')$q$, 'Không có thay đổi', 'Không đổi thì báo');
update master.shifts set active = true where code = 'B';   -- dữ liệu cũ: ca 2 "cả xưởng"
select pg_temp.api_val($q$select app.kh_save_shifts('[{"code":"A","start_time":"07:00","end_time":"15:00","break_min":30},
  {"code":"B","start_time":"15:00","end_time":"23:00","break_min":30},{"code":"C","start_time":"23:00","end_time":"07:00","break_min":45}]', 'Theo giờ xưởng')::text$q$);
select pg_temp.ok((select string_agg(code || to_char(start_time, 'HH24MI') || to_char(end_time, 'HH24MI') || active::text, ',' order by code) from master.shifts where code in ('A','B','C'))
  = 'A07001500true,B15002300false,C23000700false', 'Giám đốc đổi giờ 3 ca nối tiếp; ca 2, ca 3 chỉ máy trong bảng ca tuần (không còn "cả xưởng")');
select pg_temp.ok((select count(*) from master.planning_param_log where at >= now() and section = 'Ca làm việc' and item like 'Ca 2 ·%') >= 3,
  'Ghi nhật ký tham số (lịch cần xếp lại)');
select pg_temp.ok((mfg.machine_setting('shift') -> 'sessions' -> 0 ->> 0) = '07:00', 'Module máy đọc giờ ca 1 mới');
-- Lịch làm việc (Cài đặt máy) đổi ca 1 mà chồng ca 2 thì cũng bị chặn
select pg_temp.api_fails($q$select app.save_work_calendar('07:00', '11:00', '12:00', '16:00', '{1,2,3,4,5,6}', 90, 2, 'thử')$q$, 'Ca 2 phải bắt đầu', 'Lịch làm việc cũng kiểm chồng giờ');
update master.shifts set start_time = '06:00', end_time = '14:00' where code = 'A';
update master.shifts set start_time = '14:00', end_time = '22:00' where code = 'B';
update master.shifts set start_time = '22:00', end_time = '06:00' where code = 'C';

-- Ngưỡng lệch giờ đứng máy
select pg_temp.api_fails($q$select app.kh_save_balance(60, 'thử')$q$, 'từ 5 đến 50', 'Ngưỡng lệch 5–50 %');
select pg_temp.api_val($q$select app.kh_save_balance(20, 'Thử 20 %')::text$q$);
select pg_temp.ok((select balance_pct = 20 from master.planning_config where id = 1), 'Giám đốc đặt ngưỡng lệch giờ đứng máy');
select pg_temp.as_user('G_SXTP');
select pg_temp.api_fails($q$select app.kh_save_balance(15, 'thử')$q$, 'Chỉ Giám đốc', 'TP SX không sửa ngưỡng lệch');
update master.planning_config set balance_pct = 15 where id = 1;

-- ================================================================ 3. Tay nghề: mọi công nhân đứng chính mọi máy
select pg_temp.ok(not exists (select 1 from master.operators o cross join master.machines m where o.active and plan.is_sched_machine(m.code)
  and not exists (select 1 from master.operator_skills k where k.operator_code = o.code and k.machine_code = m.code and k.level = 'MAIN')),
  'Migration: mọi công nhân đang làm đứng chính mọi máy xếp lịch');
insert into x select 'nv', to_jsonb(pg_temp.api_val($q$select app.kh_save_operator(null, 'Người Thử', 'Chạy máy')$q$));
select pg_temp.api_val(format($q$select app.kh_skill_all(%L)::text$q$, (select j #>> '{}' from x where k = 'nv')));
select pg_temp.ok((select count(*) from master.operator_skills where operator_code = (select j #>> '{}' from x where k = 'nv') and level = 'MAIN' and signed_at is null)
  = (select count(*) from master.machines m where plan.is_sched_machine(m.code)), 'Người mới: TP SX giao đứng chính mọi máy, chờ TP KT/QA ký');
select pg_temp.ok(pg_temp.nt('G_KTTP', 'Tay nghề chờ ký:%mọi máy') >= 1, 'Báo TP KT/QA ký tay nghề');
select pg_temp.api_fails(format($q$select app.kh_skill_all(%L)$q$, (select j #>> '{}' from x where k = 'nv')), 'đã đứng chính mọi máy', 'Đã đứng mọi máy thì báo');
select pg_temp.as_user('G_VH');
select pg_temp.api_fails($q$select app.kh_skill_all('NV1')$q$, 'Chỉ Quản lý SX', 'Công nhân không tự giao máy');
select pg_temp.api_fails($q$select app.sign_skills_all()$q$, 'Chỉ TP Kỹ thuật', 'Công nhân không ký tay nghề');
select pg_temp.as_user('G_KTTP');
select pg_temp.ok(pg_temp.api_val($q$select app.sign_skills_all()::text$q$)::int >= (select count(*) from master.machines m where plan.is_sched_machine(m.code)),
  'TP KT/QA ký một lần mọi tay nghề chưa ký');
select pg_temp.ok(not exists (select 1 from master.operator_skills k join master.operators o on o.code = k.operator_code where o.active and k.signed_at is null),
  'Không còn tay nghề chờ ký');
select pg_temp.api_fails($q$select app.sign_skills_all()$q$, 'Không còn tay nghề', 'Ký lại khi không còn gì: báo');
update master.operators set active = false where code = (select j #>> '{}' from x where k = 'nv');

-- ================================================================ 4. Sổ giờ đứng máy: ghi khi bản lịch thành lịch đang dùng (từ hôm nay)
with p as (insert into plan.production_plans (plan_no, period_label) values ('KH-TEST-PCA', 'Thử bảng ca') returning id) insert into t select 'plan', id from p;
insert into plan.operator_day_hours (plan_id, work_date, operator_code, attend_min) values ((select v from t where k = 'plan'), pg_temp.today() - 5, 'NV3', 400);
insert into plan.schedule_versions (plan_id, version, base_date, params, reason, is_current, status)
values ((select v from t where k = 'plan'), 1, pg_temp.today() - 6, jsonb_build_object('hours', jsonb_build_array(
   jsonb_build_object('d', pg_temp.today() - 1, 'p', 'NV1', 'm', 300, 'n', 0, 's', 1),
   jsonb_build_object('d', pg_temp.today(), 'p', 'NV1', 'm', 120, 'n', 0, 's', 1),
   jsonb_build_object('d', pg_temp.today(), 'p', 'NV1', 'm', 30, 'n', 0, 's', 1),
   jsonb_build_object('d', pg_temp.today() + 1, 'p', 'NV2', 'm', 200, 'n', 60, 's', 2),
   jsonb_build_object('d', pg_temp.today() + 1, 'p', 'XX9', 'm', 50, 'n', 0, 's', 1))), 'thử', true, 'APPROVED');
select pg_temp.ok((select attend_min from plan.operator_day_hours where operator_code = 'NV1' and work_date = pg_temp.today()) = 150
  and (select attend_min = 200 and night_min = 60 and shift_no = 2 from plan.operator_day_hours where operator_code = 'NV2' and work_date = pg_temp.today() + 1),
  'Bản lịch thành lịch đang dùng: ghi sổ giờ từ hôm nay (cộng các đoạn cùng ngày, giờ đêm, ca)');
select pg_temp.ok(not exists (select 1 from plan.operator_day_hours where operator_code = 'NV1' and work_date = pg_temp.today() - 1)
  and not exists (select 1 from plan.operator_day_hours where operator_code = 'XX9'), 'Không ghi ngày đã qua, không ghi người không có');
insert into plan.schedule_versions (plan_id, version, base_date, params, reason, is_current, status)
values ((select v from t where k = 'plan'), 2, pg_temp.today() - 6, jsonb_build_object('hours', jsonb_build_array(
   jsonb_build_object('d', pg_temp.today(), 'p', 'NV1', 'm', 60, 'n', 0, 's', 1))), 'thử 2', false, 'PROPOSED');
select pg_temp.ok((select attend_min from plan.operator_day_hours where operator_code = 'NV1' and work_date = pg_temp.today()) = 150, 'Bản đề xuất chưa duyệt không đổi sổ giờ');
update plan.schedule_versions set is_current = false where plan_id = (select v from t where k = 'plan') and version = 1;
update plan.schedule_versions set is_current = true, status = 'APPROVED' where plan_id = (select v from t where k = 'plan') and version = 2;
select pg_temp.ok((select attend_min from plan.operator_day_hours where operator_code = 'NV1' and work_date = pg_temp.today()) = 60
  and not exists (select 1 from plan.operator_day_hours where operator_code = 'NV2' and work_date = pg_temp.today() + 1)
  and (select attend_min from plan.operator_day_hours where operator_code = 'NV3' and work_date = pg_temp.today() - 5) = 400,
  'Giám đốc duyệt bản mới: sổ giờ từ hôm nay theo bản mới, ngày đã qua giữ nguyên');
select pg_temp.as_user('G_SXTP');
select pg_temp.ok(pg_temp.api_val($q$select sum(attend_min)::text from app.v_kh_op_hours where operator_code = 'NV1' and work_date = (now() at time zone 'Asia/Ho_Chi_Minh')::date$q$)::numeric = 60
  and pg_temp.api_val($q$select count(*)::text from app.v_kh_config, jsonb_array_elements(op_hours) h where h ->> 'code' = 'NV3'$q$) = '1',
  'TP SX đọc sổ giờ; lịch máy đọc sổ giờ 45 ngày để luân phiên');

-- ================================================================ 5. Bảng ca tuần: kiểm nội dung
select pg_temp.as_user('G_VH');
select pg_temp.api_fails(format($q$select app.roster_save(%L)$q$, pg_temp.rp(pg_temp.mon(0), '[]', pg_temp.pp('{}', null))), 'Chỉ TP SX', 'Công nhân không lập bảng ca');
select pg_temp.as_user('G_SXKH');
select pg_temp.api_fails(format($q$select app.roster_save(%L)$q$, pg_temp.rp(pg_temp.mon(1), '[]', pg_temp.pp('{}', null))), 'thứ 2', 'Tuần phải bắt đầu từ thứ 2');
select pg_temp.api_fails(format($q$select app.roster_save(%L)$q$, pg_temp.rp(pg_temp.mon(-14), '[]', pg_temp.pp('{}', null))), 'đã qua', 'Không lập bảng ca tuần đã qua');
select pg_temp.api_fails(format($q$select app.roster_save(%L)$q$, pg_temp.rp(pg_temp.mon(0), pg_temp.ms('{SIL-MIX,EXT-SI-01}', 2, '{0,1,2,3,4,5}'), pg_temp.pp('{NV3}', 'NV3'))),
  'ít nhất 2 người', 'Ca 2 tối thiểu 2 người');
select pg_temp.api_fails(format($q$select app.roster_save(%L)$q$, pg_temp.rp(pg_temp.mon(0), pg_temp.ms('{SIL-MIX,EXT-SI-01}', 2, '{0,1,2,3,4,5}'), pg_temp.pp('{NV3,NV4}', null))),
  'đúng 1 người phụ trách', 'Ca 2 phải có 1 người phụ trách');
select pg_temp.api_fails(format($q$select app.roster_save(%L)$q$, pg_temp.rp(pg_temp.mon(0), '[]', pg_temp.pp('{NV3,NV4}', 'NV3'))),
  'không máy nào chạy ca 2', 'Người làm ca 2 mà không máy nào chạy ca 2: chặn');
select pg_temp.api_fails(format($q$select app.roster_save(%L)$q$, pg_temp.rp(pg_temp.mon(0), pg_temp.ms('{EXT-SI-01}', 2, '{0,1}'), pg_temp.pp('{NV3,NV4}', 'NV3'))),
  'máy trộn cũng chạy', 'Line silicone thêm ca thì máy trộn cùng ca');
select pg_temp.api_fails(format($q$select app.roster_save(%L)$q$, pg_temp.rp(pg_temp.mon(0), pg_temp.ms('{SIL-MIX}', 2, '{0,1}'), pg_temp.pp('{NV3,NV4}', 'NV3'))),
  'cùng line silicone', 'Máy trộn không thêm ca một mình');
select pg_temp.api_fails(format($q$select app.roster_save(%L)$q$, pg_temp.rp(pg_temp.mon(0), pg_temp.ms('{BUN-01}', 2, '{6}'), pg_temp.pp('{NV3,NV4}', 'NV3'))),
  'ngày nghỉ', 'Không thêm ca ngày nghỉ');
select pg_temp.api_fails(format($q$select app.roster_save(%L)$q$, pg_temp.rp(pg_temp.mon(0), pg_temp.ms('{BUN-01}', 2, '{7}'), pg_temp.pp('{NV3,NV4}', 'NV3'))),
  'không thuộc tuần', 'Ngày ngoài tuần bị chặn');
select pg_temp.api_fails(format($q$select app.roster_save(%L)$q$, pg_temp.rp(pg_temp.mon(0), pg_temp.ms('{BUN-01}', 2, '{0}'), pg_temp.pp('{NV3,NV4}', 'NV3'), '{}')),
  'người đo mẫu QC', 'Ca 2 phải có người đo mẫu QC');
select pg_temp.api_fails(format($q$select app.roster_save(%L)$q$, pg_temp.rp(pg_temp.mon(0), pg_temp.ms('{BUN-01}', 2, '{0}'), pg_temp.pp('{NV3,NV4}', 'NV3'), '{"mode":"QC"}')),
  'tên người QC', 'QC làm ca 2 phải có tên');
select pg_temp.api_fails(format($q$select app.roster_save(%L)$q$, pg_temp.rp(pg_temp.mon(0), pg_temp.ms('{BUN-01}', 4, '{0}'), pg_temp.pp('{NV3,NV4}', 'NV3'))),
  '2 hoặc 3 ca', 'Chỉ 2 hoặc 3 ca');

-- ================================================================ 6. Lập → TP SX gửi → Giám đốc sửa → duyệt, áp ca máy, ca người, gửi công nhân
-- Ca máy, ca người cũ kéo qua tuần: phần trong tuần bị bảng ca thay, phần sau tuần giữ lại
insert into plan.shift_requests (id, req_no, items, reason, status) values (gen_random_uuid(), 'CA-TEST-001', '[]', 'cũ', 'APPROVED');
insert into plan.machine_shifts (request_id, machine_code, date_from, date_to, shifts)
values ((select id from plan.shift_requests where req_no = 'CA-TEST-001'), 'BUN-01', pg_temp.mon(0), pg_temp.mon(12), 2);
insert into plan.operator_shifts (operator_code, date_from, date_to, shift_no) values ('NV2', pg_temp.mon(0), pg_temp.mon(12), 2);
insert into t select 'w1', pg_temp.api_val(format($q$select app.roster_save(%L)::text$q$,
  pg_temp.rp(pg_temp.mon(0), pg_temp.ms('{SIL-MIX,EXT-SI-01}', 2, '{0,1,2,3,4,5}'), pg_temp.pp('{NV3,NV4}', 'NV3'))))::uuid;
select pg_temp.ok((select status = 'DRAFT' and roster_no like 'PCA-%' from plan.week_rosters where id = (select v from t where k = 'w1')), 'Kế hoạch SX lập bảng ca (nháp, số PCA-…)');
select pg_temp.ok(pg_temp.api_val(format($q$select app.roster_save(%L)::text$q$,
  pg_temp.rp(pg_temp.mon(0), pg_temp.ms('{SIL-MIX,EXT-SI-01}', 2, '{0,1,2,3,4,5}'), pg_temp.pp('{NV3,NV4}', 'NV3'))))::uuid = (select v from t where k = 'w1')
  and (select count(*) from plan.week_rosters where week_start = pg_temp.mon(0)) = 1, 'Lập lại cùng tuần: sửa bảng đang mở, không tạo bảng thứ hai');
select pg_temp.api_fails(format($q$select app.roster_submit(%L)$q$, (select v from t where k = 'w1')), 'Chỉ TP SX', 'Kế hoạch SX không tự gửi Giám đốc (TP SX duyệt gửi)');
select pg_temp.as_user('G_SXTP');
select pg_temp.api_val(format($q$select app.roster_submit(%L, 'Máy trộn cổ chai')::text$q$, (select v from t where k = 'w1')));
select pg_temp.ok((select status = 'PROPOSED' and submitted_by is not null from plan.week_rosters where id = (select v from t where k = 'w1')), 'TP SX duyệt, gửi Giám đốc');
select pg_temp.ok(pg_temp.nt('G_BGD', 'Bảng ca tuần chờ duyệt:%') = 1, 'Báo Giám đốc duyệt (hạn 12:00 thứ 7)');
select pg_temp.api_fails(format($q$select app.roster_save(%L)$q$, pg_temp.rp(pg_temp.mon(0), pg_temp.ms('{SIL-MIX,EXT-SI-01}', 2, '{0,1}'), pg_temp.pp('{NV3,NV4}', 'NV3'))
  || jsonb_build_object('id', (select v from t where k = 'w1'))), 'chỉ Giám đốc sửa', 'Đang chờ duyệt: TP SX không sửa');
select pg_temp.api_fails(format($q$select app.roster_review(%L, true)$q$, (select v from t where k = 'w1')), 'Chỉ Giám đốc', 'TP SX không duyệt bảng ca');
select pg_temp.as_user('G_BGD');
select pg_temp.api_val(format($q$select app.roster_save(%L)::text$q$, pg_temp.rp(pg_temp.mon(0), pg_temp.ms('{SIL-MIX,EXT-SI-01}', 2, '{0,1,2,3,4,5}'), pg_temp.pp('{NV3,NV4,NV5}', 'NV3'))
  || jsonb_build_object('id', (select v from t where k = 'w1'), 'edit_note', 'Thêm NV5 ca 2')));
select pg_temp.ok((select jsonb_array_length(edits) = 1 and edits -> 0 ->> 'note' = 'Thêm NV5 ca 2' from plan.week_rosters where id = (select v from t where k = 'w1'))
  and pg_temp.nt('G_SXTP', 'Giám đốc sửa bảng ca%') = 1, 'Giám đốc sửa khi duyệt: ghi lịch sử, báo TP SX');
select pg_temp.api_fails(format($q$select app.roster_review(%L, false, '')$q$, (select v from t where k = 'w1')), 'lý do', 'Trả lại phải có lý do');
update master.operators set profile_id = (select id from core.profiles where employee_code = 'G_VH') where code = 'NV3';
select pg_temp.api_val(format($q$select app.roster_review(%L, true, 'Đồng ý')::text$q$, (select v from t where k = 'w1')));
select pg_temp.ok((select status = 'APPROVED' and sent_at is not null and sent_late = (now() > plan.roster_deadline(week_start)) and request_id is not null
  from plan.week_rosters where id = (select v from t where k = 'w1')), 'Giám đốc duyệt: đã gửi, ghi đúng/sau hạn 12:00 thứ 7');
select pg_temp.ok((select count(*) from plan.machine_shifts s join plan.shift_requests q on q.id = s.request_id
  where q.summary ->> 'roster' is not null and s.machine_code in ('SIL-MIX','EXT-SI-01') and s.date_from = pg_temp.mon(0) and s.date_to = pg_temp.mon(5) and s.shifts = 2) = 2,
  'Ca máy: máy trộn + line silicone 2 ca thứ Hai–thứ Bảy (đề xuất thêm ca đã duyệt theo bảng ca)');
select pg_temp.ok(not exists (select 1 from app.v_kh_machine_shifts where machine_code = 'BUN-01' and eff_to >= date_from and date_from <= pg_temp.mon(6) and eff_to >= pg_temp.mon(0))
  and exists (select 1 from app.v_kh_machine_shifts where machine_code = 'BUN-01' and date_from = pg_temp.mon(7) and eff_to = pg_temp.mon(12)),
  'Ca máy cũ: phần trong tuần bị bảng ca thay, phần sau tuần giữ lại');
select pg_temp.ok(plan.op_shift_on('NV3', pg_temp.mon(2)) = 2 and plan.op_shift_on('NV5', pg_temp.mon(5)) = 2 and plan.op_shift_on('NV1', pg_temp.mon(2)) = 1
  and plan.op_shift_on('NV2', pg_temp.mon(2)) = 1 and plan.op_shift_on('NV2', pg_temp.mon(8)) = 2, 'Ca người: NV3, NV4, NV5 ca 2 cả tuần; NV2 về ca 1 trong tuần, ca cũ sau tuần giữ lại');
select pg_temp.ok(pg_temp.nt('G_VH', 'Lịch ca tuần%ca 2 (14:00–22:00)') = 1, 'Gửi lịch ca cho công nhân có tài khoản (NV3: ca 2)');
select pg_temp.ok(pg_temp.nt('G_TT', 'Bảng ca tuần%đã duyệt%') = 1 and pg_temp.nt('G_SXKH', 'Bảng ca tuần%đã duyệt%') = 1, 'Gửi tổ trưởng, Kế hoạch SX');
select pg_temp.ok(pg_temp.nt('G_QC', 'QC ca 2 tuần%') = 1, 'Báo QC: người phụ trách ca 2 được ủy quyền đo mẫu');
select pg_temp.ok(exists (select 1 from master.planning_param_log where section = 'Bảng ca tuần' and at >= now()), 'Ghi nhật ký tham số: lịch máy cần xếp lại');
select pg_temp.as_user('G_SXTP');
select pg_temp.ok(pg_temp.api_val(format($q$select count(*)::text from app.v_kh_config, jsonb_array_elements(qc_cover) c where (c ->> 'from')::date = %L$q$, pg_temp.mon(0))) = '1',
  'Lịch máy biết tuần này ca 2 có người đo mẫu QC');
select pg_temp.as_user('G_VH');
select pg_temp.ok(pg_temp.api_val($q$select count(*)::text from app.v_kh_rosters$q$)::int >= 1, 'Công nhân xem được bảng ca (in dán xưởng)');

-- ================================================================ 7. Bảng mới thay bảng đã duyệt; luật nghỉ 12 giờ khi đổi ca; hủy
select pg_temp.as_user('G_SXTP');
insert into t select 'w2', pg_temp.api_val(format($q$select app.roster_save(%L)::text$q$,
  pg_temp.rp(pg_temp.mon(0), pg_temp.ms('{BUN-01}', 2, '{0,1,2,3,4,5}'), pg_temp.pp('{NV1,NV2}', 'NV1'))))::uuid;
select pg_temp.ok((select v from t where k = 'w2') <> (select v from t where k = 'w1'), 'Tuần đã duyệt: lập bảng mới để thay');
select pg_temp.api_val(format($q$select app.roster_submit(%L)::text$q$, (select v from t where k = 'w2')));
-- Chủ nhật là ngày làm việc: NV3 làm ca 2 Chủ nhật trước tuần, sang thứ Hai về ca 1 chỉ nghỉ 8 giờ → chặn
update master.machine_settings set value = jsonb_set(value, '{workdays}', '[1,2,3,4,5,6,7]') where key = 'shift';
insert into plan.operator_shifts (operator_code, date_from, date_to, shift_no) values ('NV3', pg_temp.mon(-1), pg_temp.mon(-1), 2);
select pg_temp.as_user('G_BGD');
select pg_temp.api_fails(format($q$select app.roster_review(%L, true)$q$, (select v from t where k = 'w2')), 'nghỉ ít nhất 12 giờ', 'Đổi ca thiếu 12 giờ nghỉ: không duyệt được');
select pg_temp.ok((select status from plan.week_rosters where id = (select v from t where k = 'w2')) = 'PROPOSED', 'Duyệt bị chặn thì bảng ca vẫn chờ duyệt, không đổi gì');
update master.machine_settings set value = jsonb_set(value, '{workdays}', '[1,2,3,4,5,6]') where key = 'shift';
delete from plan.operator_shifts where operator_code = 'NV3' and date_from = pg_temp.mon(-1);
select pg_temp.api_val(format($q$select app.roster_review(%L, true)$q$, (select v from t where k = 'w2')));
select pg_temp.ok((select status from plan.week_rosters where id = (select v from t where k = 'w1')) = 'REPLACED'
  and (select status from plan.week_rosters where id = (select v from t where k = 'w2')) = 'APPROVED'
  and plan.op_shift_on('NV3', pg_temp.mon(2)) = 1 and plan.op_shift_on('NV1', pg_temp.mon(2)) = 2
  and not exists (select 1 from app.v_kh_machine_shifts where machine_code = 'SIL-MIX' and eff_to >= date_from and date_from <= pg_temp.mon(5) and eff_to >= pg_temp.mon(0)),
  'Bảng mới duyệt: bảng cũ "đã thay", ca máy, ca người theo bảng mới');
select pg_temp.as_user('G_SXKH');
insert into t select 'w3', pg_temp.api_val(format($q$select app.roster_save(%L)::text$q$, pg_temp.rp(pg_temp.mon(7), '[]', pg_temp.pp('{}', null))))::uuid;
select pg_temp.as_user('G_VH');
select pg_temp.api_fails(format($q$select app.roster_cancel(%L, 'x')$q$, (select v from t where k = 'w3')), 'Chỉ TP SX', 'Công nhân không hủy bảng ca');
select pg_temp.as_user('G_SXKH');
select pg_temp.api_fails(format($q$select app.roster_cancel(%L, '')$q$, (select v from t where k = 'w3')), 'lý do', 'Hủy phải có lý do');
select pg_temp.api_val(format($q$select app.roster_cancel(%L, 'Lập lại')::text$q$, (select v from t where k = 'w3')));
select pg_temp.ok((select status from plan.week_rosters where id = (select v from t where k = 'w3')) = 'CANCELLED', 'Hủy bảng ca nháp');
select pg_temp.api_fails(format($q$select app.roster_cancel(%L, 'x')$q$, (select v from t where k = 'w2')), 'đã duyệt', 'Không hủy bảng đã duyệt');

-- ================================================================ 8. Nhắc hạn tuần sau (mon + 7): thứ 6 08:00 TP SX lập; thứ 7 08:00 nhắc; thứ 7 12:00 chưa duyệt thì cảnh báo
select pg_temp.as_user('KHONG_AI');   -- pg_cron chạy không có người dùng
select plan.roster_reminders();
select plan.roster_reminders((pg_temp.mon(1) + time '08:00')::timestamp);
select pg_temp.ok(pg_temp.nt('G_SXTP', 'Lập bảng ca tuần%') = 0, 'Không phải thứ 6 / thứ 7: không nhắc');
select plan.roster_reminders((pg_temp.mon(4) + time '08:00')::timestamp);
select plan.roster_reminders((pg_temp.mon(4) + time '12:00')::timestamp);
select pg_temp.ok(pg_temp.nt('G_SXTP', 'Lập bảng ca tuần%') = 1 and pg_temp.nt('G_SXKH', 'Lập bảng ca tuần%') = 1, 'Thứ 6: nhắc TP SX, Kế hoạch SX lập bảng ca tuần sau (một lần)');
select pg_temp.ok(pg_temp.nt('G_SXTP', 'Giờ đứng máy 4 tuần qua lệch%') = 1, 'Thứ 6: giờ đứng máy 4 tuần lệch quá ngưỡng thì cảnh báo TP SX');
select plan.roster_reminders((pg_temp.mon(5) + time '08:00')::timestamp);
select pg_temp.ok(pg_temp.nt('G_SXTP', 'Chưa gửi bảng ca tuần%') = 1, 'Thứ 7 08:00 chưa gửi: nhắc TP SX');
select plan.roster_reminders((pg_temp.mon(5) + time '12:00')::timestamp);
select plan.roster_reminders((pg_temp.mon(5) + time '12:00')::timestamp);
select pg_temp.ok(pg_temp.nt('G_BGD', '%chưa duyệt trước 12:00 thứ 7') = 1 and pg_temp.nt('G_SXTP', '%chưa duyệt trước 12:00 thứ 7') = 1,
  'Thứ 7 12:00 chưa duyệt: cảnh báo Giám đốc, TP SX (một lần)');
-- tuần đã có bảng chờ duyệt: thứ 7 sáng nhắc Giám đốc
select pg_temp.as_user('G_SXTP');
insert into t select 'w4', pg_temp.api_val(format($q$select app.roster_save(%L)::text$q$, pg_temp.rp(pg_temp.mon(14), '[]', pg_temp.pp('{}', null))))::uuid;
select pg_temp.api_val(format($q$select app.roster_submit(%L)::text$q$, (select v from t where k = 'w4')));
select pg_temp.as_user('KHONG_AI');
select plan.roster_reminders((pg_temp.mon(12) + time '08:00')::timestamp);
select pg_temp.ok(pg_temp.nt('G_BGD', 'Duyệt bảng ca tuần%trước 12:00 hôm nay') = 1, 'Thứ 7 08:00 bảng ca chờ duyệt: nhắc Giám đốc');

do $$ declare v_n int; v_s text; begin
  select count(*), string_agg(r.n || '. ' || r.msg, E'\n' order by r.n) into v_n, v_s from r;
  raise exception 'KET_QUA_OK % kiểm tra đạt:%', v_n, E'\n' || v_s;
end $$;
