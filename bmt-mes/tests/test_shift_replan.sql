-- Kiểm thử migration 20261026005500_shift_replan: tính lại tiến độ sau ca (1 giờ sau khi hết ca), nhận lượt chống trùng,
-- lưu lịch tính lại thành lịch đang dùng (giữ thứ tự lô, số mét), so ngày xong từng lô, báo Giám đốc / TP SX.
-- Chạy được bằng psql hoặc MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create temp table t (k text primary key, v uuid);
grant all on r, t to authenticated;
grant usage on sequence r_n_seq to authenticated;

create function pg_temp.as_user(p_code text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', coalesce((select id::text from core.profiles where employee_code = p_code), ''), true),
         set_config('request.jwt.claims', json_build_object('sub', (select id::text from core.profiles where employee_code = p_code), 'role', 'authenticated')::text, true),
         set_config('request.jwt.claim.role', 'authenticated', true)
$$;
create function pg_temp.as_service() returns void language sql as $$
  select set_config('request.jwt.claim.sub', '', true), set_config('request.jwt.claims', '{"role":"service_role"}', true),
         set_config('request.jwt.claim.role', 'service_role', true)
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
create function pg_temp.v(p_k text) returns uuid language sql as $$ select v from t where k = p_k $$;
create function pg_temp.today() returns date language sql as $$ select (now() at time zone 'Asia/Ho_Chi_Minh')::date $$;
create function pg_temp.nt(p_code text, p_like text) returns bigint language sql as $$
  select count(*) from wf.notifications n join core.profiles p on p.id = n.user_id where p.employee_code = p_code and n.title like p_like
$$;
set client_min_messages = notice;

-- Người dùng thử; tài khoản thật tạm khóa trong giao dịch
update core.profiles set status = 'LOCKED' where (employee_code is null or employee_code !~ '^RP_') and status = 'ACTIVE';
with u(code) as (values ('RP_BGD'),('RP_SXTP'),('RP_VH')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('RP_BGD','BGD'),('RP_SXTP','SX_TP'),('RP_VH','VAN_HANH')) u(code, role) on u.code = p.employee_code;

-- Mọi ngày là ngày làm việc; ca 1 vừa hết cách đây 2 giờ (giờ VN), ca 2 / ca 3 không chạy (không bảng ca, không cả xưởng)
update master.machine_settings set value = jsonb_set(value, '{workdays}', '[1,2,3,4,5,6,7]') where key = 'shift';
update master.shifts set start_time = ((now() at time zone 'Asia/Ho_Chi_Minh') - interval '10 hours')::time,
       end_time = ((now() at time zone 'Asia/Ho_Chi_Minh') - interval '2 hours')::time, break_min = 30, active = true where code = 'A';
update master.shifts set active = false where code in ('B', 'C');
delete from plan.machine_shifts where true;
update master.planning_config set replan_after_min = 60 where id = 1;
-- ngày làm việc của ca vừa hết (ca qua nửa đêm thì là hôm qua)
insert into t select 'd0', null;
create function pg_temp.d0() returns date language sql as $$
  select case when ((now() at time zone 'Asia/Ho_Chi_Minh') - interval '2 hours')::time < ((now() at time zone 'Asia/Ho_Chi_Minh') - interval '10 hours')::time
              then ((now() at time zone 'Asia/Ho_Chi_Minh') - interval '2 hours')::date - 1 else ((now() at time zone 'Asia/Ho_Chi_Minh') - interval '2 hours')::date end $$;

-- ================================================================ 1. Giờ hết ca, ca chạy trong ngày
select pg_temp.ok(abs(extract(epoch from plan.shift_end_at(pg_temp.d0(), 'A') - (now() - interval '2 hours'))) < 120, 'Giờ hết ca 1 theo giờ khai báo (giờ VN)');
update master.shifts set start_time = '22:00', end_time = '06:00' where code = 'C';
select pg_temp.ok(plan.shift_end_at(date '2026-11-02', 'C') = timestamptz '2026-11-03 06:00:00+07', 'Ca 3 qua nửa đêm: hết ca sáng hôm sau');
select pg_temp.ok(plan.shift_runs_on(pg_temp.today(), 'A') and not plan.shift_runs_on(pg_temp.today(), 'B'), 'Ca 1 chạy mọi ngày làm việc; ca 2 không chạy khi không có bảng ca');
insert into plan.shift_requests (req_no, items, reason, status) values ('CA-RP-1', '[]', 'thử', 'APPROVED');
insert into plan.machine_shifts (request_id, machine_code, date_from, date_to, shifts)
select id, 'BUN-01', pg_temp.today() + 5, pg_temp.today() + 6, 2 from plan.shift_requests where req_no = 'CA-RP-1';
select pg_temp.ok(plan.shift_runs_on(pg_temp.today() + 5, 'B') and not plan.shift_runs_on(pg_temp.today() + 5, 'C') and not plan.shift_runs_on(pg_temp.today() + 7, 'B'),
  'Ca 2 chạy những ngày có máy chạy 2 ca');
select pg_temp.ok((select shift_code = 'A' and work_date = pg_temp.d0() from plan.last_shift_end(now())), 'Ca gần nhất đã hết: ca 1');

-- ================================================================ 2. Kế hoạch đã duyệt, lịch đang dùng lập trước khi hết ca
insert into plan.production_plans (plan_no, period_label, status) values ('KH-RP-1', 'Thử tính lại', 'APPROVED');
insert into t select 'plan', id from plan.production_plans where plan_no = 'KH-RP-1';
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, m_per_pack, pack_type, brand, due_date, committed_date)
select pg_temp.v('plan'), p.id, p.current_spec_id, q, 500, 'Bobin gỗ', 'KAVIX', pg_temp.today() + dd, pg_temp.today() + cd
from (values ('PFR-2C-1P5', 10000, 10, 8), ('SFR-2P-1', 5000, 12, null)) v(code, q, dd, cd) join master.products p on p.code = v.code;
insert into t select 'l1', l.id from plan.plan_lines l join master.products p on p.id = l.product_id where l.plan_id = pg_temp.v('plan') and p.code = 'PFR-2C-1P5';
insert into t select 'l2', l.id from plan.plan_lines l join master.products p on p.id = l.product_id where l.plan_id = pg_temp.v('plan') and p.code = 'SFR-2P-1';
insert into plan.schedule_versions (plan_id, version, is_current, base_date, params, reason, status, created_at)
values (pg_temp.v('plan'), 1, true, pg_temp.today() - 3, '{"S":405,"SPD":1,"seq":{"x":1}}', 'thử', 'APPROVED', now() - interval '1 day');
insert into t select 'v1', id from plan.schedule_versions where plan_id = pg_temp.v('plan') and version = 1;
insert into plan.schedule_orders (version_id, plan_line_id, label, product_code, qty_m, finish_date)
values (pg_temp.v('v1'), pg_temp.v('l1'), 'D01', 'PFR-2C-1P5', 10000, pg_temp.today() + 6),
       (pg_temp.v('v1'), pg_temp.v('l2'), 'D02', 'SFR-2P-1', 5000, pg_temp.today() + 9);
-- TP SX đang có bản lịch đề xuất (sẽ cũ khi MES tính lại)
insert into plan.schedule_versions (plan_id, version, is_current, base_date, params, reason, status, created_by)
values (pg_temp.v('plan'), 2, false, pg_temp.today() - 3, '{"S":405,"SPD":1}', 'TP SX xếp lại', 'PROPOSED', (select id from core.profiles where employee_code = 'RP_SXTP'));

-- ================================================================ 3. Ai được tính, đến lượt, nhận lượt chống trùng
select pg_temp.as_user('RP_VH');
select pg_temp.api_fails(format($q$select app.replan_claim(%L, true)$q$, pg_temp.v('plan')), 'Chỉ TP SX', 'Công nhân không tính lại tiến độ');
select pg_temp.ok(pg_temp.api_val($q$select app.replan_due()::text$q$) = '[]', 'Công nhân không thấy kế hoạch đến lượt');
select pg_temp.api_fails($q$select plan.replan_job()$q$, 'permission', 'Job máy chủ là hàm nội bộ');
select pg_temp.api_fails(format($q$insert into plan.replan_runs (plan_id, work_date, shift_code, shift_end) values (%L, current_date, 'A', now())$q$, pg_temp.v('plan')), 'permission', 'Không ghi thẳng nhật ký tính lại');
select pg_temp.as_user('RP_SXTP');
update master.planning_config set replan_after_min = 180 where id = 1;
select pg_temp.ok(pg_temp.api_val($q$select app.replan_due()::text$q$) not like '%' || pg_temp.v('plan') || '%', 'Chưa đủ 3 giờ sau khi hết ca: chưa đến lượt');
update master.planning_config set replan_after_min = 60 where id = 1;
select pg_temp.ok(pg_temp.api_val($q$select app.replan_due()::text$q$) like '%' || pg_temp.v('plan') || '%', 'Hết ca 1 hơn 1 giờ: kế hoạch đến lượt tính lại');
insert into t select 'run1', (pg_temp.api_val(format($q$select app.replan_claim(%L)->>'run_id'$q$, pg_temp.v('plan'))))::uuid;
select pg_temp.ok(pg_temp.v('run1') is not null and (select status = 'RUNNING' and shift_code = 'A' and work_date = pg_temp.d0() and kind = 'SHIFT' from plan.replan_runs where id = pg_temp.v('run1')),
  'TP SX nhận lượt tính lại ca 1');
select pg_temp.ok(pg_temp.api_val(format($q$select coalesce(app.replan_claim(%L)::text, 'null')$q$, pg_temp.v('plan'))) = 'null', 'Đang có người tính ca này: không nhận trùng');
select pg_temp.ok(pg_temp.api_val($q$select app.replan_due()::text$q$) not like '%' || pg_temp.v('plan') || '%', 'Đang tính: không còn đến lượt');

-- ================================================================ 4. Lưu lịch tính lại
create function pg_temp.save(p_run uuid, p_seq jsonb, p_q1 numeric, p_f1 date, p_f2 date) returns text language sql as $$
  select format($q$select app.kh_replan_save(%L, %L, %L, %L, '[]', %L)::text$q$, p_run, pg_temp.today() - 3,
    jsonb_build_object('S', 405, 'SPD', 1, 'seq', p_seq),
    jsonb_build_array(jsonb_build_object('plan_line_id', pg_temp.v('l1'), 'label', 'D01', 'product_code', 'PFR-2C-1P5', 'qty_m', p_q1, 'finish_date', p_f1),
                      jsonb_build_object('plan_line_id', pg_temp.v('l2'), 'label', 'D02', 'product_code', 'SFR-2P-1', 'qty_m', 5000, 'finish_date', p_f2)),
    jsonb_build_object('machines', jsonb_build_array(jsonb_build_object('machine', 'BUN-01', 'planned', 10000, 'actual', 8000, 'slips', 1, 'missing', false),
                                                     jsonb_build_object('machine', 'TWS-01', 'planned', 3000, 'actual', 0, 'slips', 0, 'missing', true)),
                       'missing', jsonb_build_array('TWS-01')))
$$;
select pg_temp.api_fails(pg_temp.save(pg_temp.v('run1'), '{"x":2}', 10000, pg_temp.today() + 8, pg_temp.today() + 7), 'thứ tự lô', 'Tính lại không được đổi thứ tự lô');
select pg_temp.api_fails(pg_temp.save(pg_temp.v('run1'), '{"x":1}', 12000, pg_temp.today() + 8, pg_temp.today() + 7), 'số mét', 'Tính lại không được đổi số mét');
select pg_temp.as_user('RP_VH');
select pg_temp.api_fails(pg_temp.save(pg_temp.v('run1'), '{"x":1}', 10000, pg_temp.today() + 8, pg_temp.today() + 7), 'Chỉ TP SX', 'Công nhân không lưu lịch tính lại');
select pg_temp.as_user('RP_SXTP');
select pg_temp.api_val(pg_temp.save(pg_temp.v('run1'), '{"x":1}', 10000, pg_temp.today() + 8, pg_temp.today() + 7));
select pg_temp.ok((select count(*) = 1 from plan.schedule_versions where plan_id = pg_temp.v('plan') and is_current and version = 3 and status = 'APPROVED' and reason like 'MES tính lại%'),
  'Lịch tính lại thành lịch đang dùng (không chờ Giám đốc duyệt: chỉ phản ánh sản lượng thực tế)');
select pg_temp.ok((select status from plan.schedule_versions where id = pg_temp.v('v1')) = 'APPROVED' and not (select is_current from plan.schedule_versions where id = pg_temp.v('v1'))
  and (select status from plan.schedule_versions where plan_id = pg_temp.v('plan') and version = 2) = 'SUPERSEDED',
  'Lịch cũ thôi dùng; bản TP SX đề xuất trước đó thành cũ');
select pg_temp.ok(pg_temp.nt('RP_SXTP', 'Bản lịch đề xuất KH-RP-1 đã cũ') = 1, 'Báo người lập bản đề xuất đã cũ');
select pg_temp.ok((select status = 'DONE' and (result ->> 'slower')::int = 1 and (result ->> 'faster')::int = 1 and (result ->> 'late')::int = 0
  and (select (x ->> 'diff')::int = 2 and (x ->> 'target_kind') = 'chốt' from jsonb_array_elements(lots) x where x ->> 'label' = 'D01') from plan.replan_runs where id = pg_temp.v('run1')),
  'So ngày xong từng lô: D01 chậm 2 ngày (vẫn kịp ngày chốt), D02 nhanh 2 ngày');
select pg_temp.ok(pg_temp.nt('RP_BGD', 'Tiến độ sau ca 1 % · KH-RP-1: 1 lô chậm, 1 lô nhanh') = 1 and pg_temp.nt('RP_SXTP', 'Tiến độ sau ca 1 %: 1 lô chậm, 1 lô nhanh') = 1,
  'Báo Giám đốc, TP SX lô nhanh / chậm');
select pg_temp.ok((select body like '%D01 PFR-2C-1P5: xong % → % (chậm 2 ngày; kịp chốt %' and body like '%BUN-01 8.000/10.000 m (80 %)%' and body like '%Chưa có phiếu hoàn thành: TWS-01%'
  from wf.notifications n join core.profiles p on p.id = n.user_id where p.employee_code = 'RP_BGD' and n.title like 'Tiến độ sau ca 1%'),
  'Nội dung: ngày xong cũ → mới, so ngày chốt, máy đạt / lịch, máy chưa có phiếu');
select pg_temp.api_fails(pg_temp.save(pg_temp.v('run1'), '{"x":1}', 10000, pg_temp.today() + 8, pg_temp.today() + 7), 'không còn hiệu lực', 'Một lượt chỉ lưu một lần');
select pg_temp.ok(pg_temp.api_val($q$select app.replan_due()::text$q$) not like '%' || pg_temp.v('plan') || '%', 'Đã tính ca này: không tính lại tự động');
select pg_temp.ok(pg_temp.api_val(format($q$select count(*)::text from app.v_kh_replans where plan_id = %L and version = 3$q$, pg_temp.v('plan'))) = '1', 'TP SX xem nhật ký tính lại');

-- ================================================================ 5. Tính lại bấm tay; không đổi ngày xong thì chỉ báo TP SX; lỗi
insert into t select 'run2', (pg_temp.api_val(format($q$select app.replan_claim(%L, true)->>'run_id'$q$, pg_temp.v('plan'))))::uuid;
select pg_temp.ok((select kind from plan.replan_runs where id = pg_temp.v('run2')) = 'MANUAL', 'TP SX bấm tính lại ngay (không chờ 1 giờ, tính lại được ca đã tính)');
select pg_temp.api_val(pg_temp.save(pg_temp.v('run2'), '{"x":1}', 10000, pg_temp.today() + 8, pg_temp.today() + 7));
select pg_temp.ok(pg_temp.nt('RP_BGD', 'Tiến độ sau ca 1 % · KH-RP-1: lịch hoàn thành không đổi') = 0 and pg_temp.nt('RP_SXTP', '% · KH-RP-1: lịch hoàn thành không đổi') = 1,
  'Ngày xong không đổi: chỉ báo TP SX, không làm phiền Giám đốc');
insert into t select 'run3', (pg_temp.api_val(format($q$select app.replan_claim(%L, true)->>'run_id'$q$, pg_temp.v('plan'))))::uuid;
select pg_temp.api_val(format($q$select app.replan_fail(%L, 'thử lỗi')::text$q$, pg_temp.v('run3')));
select pg_temp.ok((select status = 'ERROR' and error = 'thử lỗi' from plan.replan_runs where id = pg_temp.v('run3')), 'Lỗi khi tính: ghi lại để xem');

-- ================================================================ 6. Máy chủ (service role); kế hoạch chưa duyệt; lịch lập sau khi hết ca
delete from plan.replan_runs where plan_id = pg_temp.v('plan');
update plan.schedule_versions set created_at = now() - interval '1 day' where plan_id = pg_temp.v('plan');
select pg_temp.as_service();
select pg_temp.ok(pg_temp.api_val($q$select app.replan_due()::text$q$) like '%' || pg_temp.v('plan') || '%', 'Job máy chủ (service role) thấy kế hoạch đến lượt');
select pg_temp.ok(pg_temp.api_val(format($q$select app.replan_claim(%L)->>'shift_code'$q$, pg_temp.v('plan'))) = 'A', 'Job máy chủ nhận lượt tính lại');
delete from plan.replan_runs where plan_id = pg_temp.v('plan');
update plan.schedule_versions set created_at = now() where plan_id = pg_temp.v('plan') and is_current;
select pg_temp.ok(pg_temp.api_val($q$select app.replan_due()::text$q$) not like '%' || pg_temp.v('plan') || '%', 'Lịch đã xếp lại sau khi hết ca 1 giờ: không cần tính tự động');
update plan.schedule_versions set created_at = now() - interval '1 day' where plan_id = pg_temp.v('plan');
update plan.production_plans set status = 'CLOSED' where id = pg_temp.v('plan');
select pg_temp.ok(pg_temp.api_val($q$select app.replan_due()::text$q$) not like '%' || pg_temp.v('plan') || '%', 'Kế hoạch không còn ở trạng thái đã duyệt: không tính');
select pg_temp.as_user('RP_SXTP');
select pg_temp.api_fails(format($q$select app.replan_claim(%L, true)$q$, pg_temp.v('plan')), 'Chưa có ca nào', 'Bấm tay khi kế hoạch chưa duyệt: báo rõ');

do $$ declare v_n int; v_s text; begin
  select count(*), string_agg(r.n || '. ' || r.msg, E'\n' order by r.n) into v_n, v_s from r;
  raise exception 'KET_QUA_OK % kiểm tra đạt:%', v_n, E'\n' || v_s;
end $$;
