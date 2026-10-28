-- Kiểm thử migration 20261026005300_machine_shifts: máy chạy 2–3 ca (TP SX / Kế hoạch SX đề xuất → Giám đốc duyệt, Giám đốc tự lập áp ngay),
-- máy trộn chạy cùng ca line silicone, ca làm việc của người, luật nghỉ 12 giờ khi đổi ca, giờ làm tối đa mỗi ngày.
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
create function pg_temp.fails(p_sql text, p_pattern text, p_msg text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm ilike '%' || p_pattern || '%' then insert into r(msg) values (p_msg || ' → chặn: ' || sqlerrm); return; end if;
    raise exception 'FAIL: % — lỗi khác mong đợi: %', p_msg, sqlerrm;
  end;
  raise exception 'FAIL: % — lẽ ra phải báo lỗi', p_msg;
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
-- Ngày làm việc kế tiếp từ hôm nay + n ngày (theo ngày làm việc của xưởng)
create function pg_temp.wday(p_n int) returns date language sql as $$
  select min(d)::date from generate_series(pg_temp.today() + p_n, pg_temp.today() + p_n + 10, interval '1 day') d
  where extract(isodow from d)::int in (select jsonb_array_elements_text(coalesce(mfg.machine_setting('shift') -> 'workdays', '[1,2,3,4,5,6]'))::int)
$$;
set client_min_messages = notice;

-- Người dùng thử; tài khoản thật tạm khóa trong giao dịch
update core.profiles set status = 'LOCKED' where (employee_code is null or employee_code !~ '^F_') and status = 'ACTIVE';
with u(code) as (values ('F_BGD'),('F_SXTP'),('F_SXKH'),('F_KTTP'),('F_ADM'),('F_VH')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('F_BGD','BGD'),('F_SXTP','SX_TP'),('F_SXKH','SX_KH'),('F_KTTP','KT_TP'),
  ('F_ADM','ADMIN'),('F_VH','VAN_HANH')) u(code, role) on u.code = p.employee_code;
-- Giờ ca trong giao dịch: A 08–17, B 14–22, C 22–06; mọi ngày trừ Chủ nhật là ngày làm việc
update master.shifts set start_time = '08:00', end_time = '17:00', break_min = 60 where code = 'A';
update master.shifts set start_time = '14:00', end_time = '22:00', break_min = 30 where code = 'B';
update master.shifts set start_time = '22:00', end_time = '06:00', break_min = 30 where code = 'C';
update master.machine_settings set value = jsonb_set(value, '{workdays}', '[1,2,3,4,5,6]') where key = 'shift';
update master.machines set active = true where code in ('SIL-MIX','EXT-SI-01','BUN-01');
delete from plan.machine_shifts where true;
delete from plan.operator_shifts where true;
delete from plan.shift_requests where true;
update master.planning_config set day_max_h = 12 where id = 1;
-- Thứ Hai kế tiếp (cách hôm nay ít nhất 1 ngày) để thử luật nghỉ 12 giờ
insert into x values ('mon', to_jsonb((select min(d)::date from generate_series(pg_temp.today() + 1, pg_temp.today() + 8, interval '1 day') d where extract(isodow from d) = 1)));
create function pg_temp.mon(p_n int) returns date language sql as $$ select (select (j #>> '{}')::date from x where k = 'mon') + p_n $$;
create function pg_temp.items(p_m text[], p_n int, p_from date, p_to date) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('machines', to_jsonb(p_m), 'shifts', p_n, 'from', p_from, 'to', p_to, 'group', 'TEST'))
$$;

-- ================================================================ 1. Cấu hình
select pg_temp.as_user('F_SXTP');
select pg_temp.ok(pg_temp.api_val($q$select concat_ws('|', day_max_h, jsonb_typeof(machine_shifts), jsonb_typeof(op_shifts)) from app.v_kh_config$q$) = '12|array|array',
  'Lịch máy đọc giờ làm tối đa mỗi ngày (12), ca máy, ca của người');
select pg_temp.ok(pg_temp.api_val($q$select concat_ws('|', (fill_pct is not null)::text, jsonb_typeof(shifts), jsonb_typeof(maint_plans)) from app.v_kh_config$q$) = 'true|array|array',
  'Các cột cũ của cấu hình lịch vẫn còn');
select pg_temp.api_fails($q$insert into plan.shift_requests (req_no, items, reason) values ('X', '[]', 'x')$q$, 'permission', 'Không ghi thẳng bảng đề xuất thêm ca');
select pg_temp.api_fails($q$insert into plan.operator_shifts (operator_code, date_from, date_to, shift_no) values ('NV1', current_date, current_date, 2)$q$, 'permission', 'Không ghi thẳng bảng ca của người');
select pg_temp.api_fails($q$select plan.shift_apply(gen_random_uuid())$q$, 'permission', 'Hàm áp ca máy là hàm nội bộ');

-- ================================================================ 2. Giờ làm tối đa mỗi ngày (Giám đốc)
select pg_temp.api_fails($q$select app.kh_save_shift_rules(11, 'thử')$q$, 'Chỉ Giám đốc', 'TP SX không sửa giờ làm tối đa mỗi ngày');
select pg_temp.as_user('F_BGD');
select pg_temp.api_fails($q$select app.kh_save_shift_rules(13, 'thử')$q$, 'từ 8 đến 12', 'Không cho quá 12 giờ/ngày (luật)');
select pg_temp.api_fails($q$select app.kh_save_shift_rules(11, '')$q$, 'lý do', 'Bắt buộc lý do');
select pg_temp.api_val($q$select app.kh_save_shift_rules(11, 'Thử 11 giờ')::text$q$);
select pg_temp.ok((select day_max_h = 11 from master.planning_config where id = 1)
  and exists (select 1 from master.planning_param_log where item like 'Giờ làm tối đa%' and new_value = '11'), 'Giám đốc đặt 11 giờ/ngày, ghi nhật ký tham số (lịch cần xếp lại)');
update master.planning_config set day_max_h = 12 where id = 1;

-- ================================================================ 3. Đề xuất thêm ca: kiểm nội dung
select pg_temp.as_user('F_VH');
select pg_temp.api_fails(format($q$select app.kh_shift_propose(null, %L)$q$, jsonb_build_object('reason', 'x', 'items', pg_temp.items(array['BUN-01'], 2, pg_temp.mon(0), pg_temp.mon(4)))),
  'Chỉ TP SX', 'Công nhân không đề xuất thêm ca');
select pg_temp.as_user('F_SXTP');
select pg_temp.api_fails(format($q$select app.kh_shift_propose(null, %L)$q$, jsonb_build_object('reason', '', 'items', pg_temp.items(array['BUN-01'], 2, pg_temp.mon(0), pg_temp.mon(4)))),
  'lý do', 'Bắt buộc lý do thêm ca');
select pg_temp.api_fails(format($q$select app.kh_shift_propose(null, %L)$q$, jsonb_build_object('reason', 'x', 'items', pg_temp.items(array['BUN-01'], 4, pg_temp.mon(0), pg_temp.mon(4)))),
  '2 hoặc 3 ca', 'Chỉ 2 hoặc 3 ca');
select pg_temp.api_fails(format($q$select app.kh_shift_propose(null, %L)$q$, jsonb_build_object('reason', 'x', 'items', pg_temp.items(array['BUN-01'], 2, pg_temp.today() - 1, pg_temp.mon(4)))),
  'ngày đã qua', 'Không thêm ca cho ngày đã qua');
select pg_temp.api_fails(format($q$select app.kh_shift_propose(null, %L)$q$, jsonb_build_object('reason', 'x', 'items', pg_temp.items(array['BUN-01'], 2, pg_temp.mon(0), pg_temp.mon(70)))),
  'tối đa 2 tháng', 'Mỗi lần thêm ca tối đa 2 tháng');
select pg_temp.api_fails(format($q$select app.kh_shift_propose(null, %L)$q$, jsonb_build_object('reason', 'x', 'items', pg_temp.items(array['XYZ-99'], 2, pg_temp.mon(0), pg_temp.mon(4)))),
  'không phải dây chuyền', 'Máy không có thì báo');
select pg_temp.api_fails(format($q$select app.kh_shift_propose(null, %L)$q$, jsonb_build_object('reason', 'x', 'items', pg_temp.items(array['EXT-SI-01'], 2, pg_temp.mon(0), pg_temp.mon(4)))),
  'máy trộn phải chạy cùng ca', 'Line silicone thêm ca thì máy trộn phải chạy cùng ca (hạn dùng silicone)');
select pg_temp.api_fails(format($q$select app.kh_shift_propose(null, %L)$q$, jsonb_build_object('reason', 'x', 'items', pg_temp.items(array['SIL-MIX'], 2, pg_temp.mon(0), pg_temp.mon(4)))),
  'cùng line silicone', 'Máy trộn không thêm ca một mình');
select pg_temp.api_fails(format($q$select app.kh_shift_propose(null, %L)$q$, jsonb_build_object('reason', 'x', 'items',
  pg_temp.items(array['BUN-01'], 2, pg_temp.mon(0), pg_temp.mon(4)) || pg_temp.items(array['BUN-01','TWS-01'], 3, pg_temp.mon(3), pg_temp.mon(6)))),
  'trùng máy', 'Hai dòng trùng máy trùng ngày bị chặn');

-- ================================================================ 4. TP SX đề xuất → Giám đốc duyệt
select pg_temp.as_user('F_SXTP');
insert into t select 'r1', pg_temp.api_val(format($q$select app.kh_shift_propose(null, %L)::text$q$, jsonb_build_object('reason', 'Lô trễ hạn', 'summary', '{"late_before":2}',
  'items', pg_temp.items(array['SIL-MIX','EXT-SI-01'], 2, pg_temp.mon(0), pg_temp.mon(4)))))::uuid;
select pg_temp.ok((select status = 'PROPOSED' and req_no like 'CA-%' from plan.shift_requests where id = (select v from t where k = 'r1'))
  and not exists (select 1 from plan.machine_shifts), 'TP SX đề xuất: chờ Giám đốc duyệt, chưa áp vào lịch');
select pg_temp.ok(pg_temp.nt('F_BGD', 'Đề xuất thêm ca chờ duyệt%') = 1, 'Báo Giám đốc duyệt');
select pg_temp.ok(pg_temp.api_val($q$select count(*)::text from app.v_kh_shift_requests where status = 'PROPOSED'$q$) = '1', 'TP SX xem được đề xuất của mình');
select pg_temp.api_fails(format($q$select app.kh_shift_review(%L, true, null)$q$, (select v from t where k = 'r1')), 'Chỉ Giám đốc', 'TP SX không tự duyệt thêm ca');
-- Kế hoạch SX lập đề xuất mới thay đề xuất cũ
select pg_temp.as_user('F_SXKH');
insert into t select 'r2', pg_temp.api_val(format($q$select app.kh_shift_propose(null, %L)::text$q$, jsonb_build_object('reason', 'Lô trễ hạn (bản 2)',
  'items', pg_temp.items(array['SIL-MIX','EXT-SI-01'], 2, pg_temp.mon(0), pg_temp.mon(4)) || pg_temp.items(array['BUN-01'], 3, pg_temp.mon(1), pg_temp.mon(2)))))::uuid;
select pg_temp.ok((select status = 'CANCELLED' from plan.shift_requests where id = (select v from t where k = 'r1'))
  and pg_temp.nt('F_SXTP', 'Đề xuất thêm ca % được thay bằng %') = 1, 'Đề xuất mới thay đề xuất cũ, báo người lập đề xuất cũ');
select pg_temp.as_user('F_BGD');
select pg_temp.api_fails(format($q$select app.kh_shift_review(%L, false, '')$q$, (select v from t where k = 'r2')), 'lý do trả lại', 'Trả lại phải có lý do');
select pg_temp.api_val(format($q$select app.kh_shift_review(%L, true, 'Đồng ý')::text$q$, (select v from t where k = 'r2')));
select pg_temp.ok((select status = 'APPROVED' from plan.shift_requests where id = (select v from t where k = 'r2'))
  and (select count(*) from plan.machine_shifts where request_id = (select v from t where k = 'r2')) = 3
  and exists (select 1 from plan.machine_shifts where machine_code = 'BUN-01' and shifts = 3 and date_from = pg_temp.mon(1)), 'Giám đốc duyệt: áp 3 dòng ca máy (trộn + line silicone 2 ca, bện 3 ca)');
select pg_temp.ok(pg_temp.nt('F_SXKH', 'Giám đốc duyệt thêm ca%') = 1 and pg_temp.nt('F_SXTP', 'Thêm ca đã duyệt%') = 1, 'Báo người lập và TP SX phân người, xếp lại lịch');
select pg_temp.ok(exists (select 1 from master.planning_param_log where section = 'Ca máy'), 'Ghi nhật ký tham số mục Ca máy (lịch cần xếp lại)');
select pg_temp.ok(pg_temp.api_val($q$select jsonb_array_length(machine_shifts)::text from app.v_kh_config$q$) = '3', 'Lịch máy đọc được 3 dòng ca máy');
select pg_temp.api_fails(format($q$select app.kh_shift_review(%L, true, null)$q$, (select v from t where k = 'r2')), 'không còn chờ duyệt', 'Không duyệt lại đề xuất đã duyệt');

-- ================================================================ 5. Giám đốc tự đề xuất thì áp ngay; ca máy cũ trùng ngày bị thay
insert into t select 'r3', pg_temp.api_val(format($q$select app.kh_shift_propose(null, %L)::text$q$, jsonb_build_object('reason', 'Giám đốc chỉnh',
  'items', pg_temp.items(array['SIL-MIX','EXT-SI-01'], 3, pg_temp.mon(2), pg_temp.mon(5)))))::uuid;
select pg_temp.ok((select status = 'APPROVED' from plan.shift_requests where id = (select v from t where k = 'r3')), 'Giám đốc tự đề xuất: áp ngay');
select pg_temp.ok((select ended_on = pg_temp.mon(1) from plan.machine_shifts where request_id = (select v from t where k = 'r2') and machine_code = 'SIL-MIX')
  and (select ended_on is null from plan.machine_shifts where request_id = (select v from t where k = 'r2') and machine_code = 'BUN-01'),
  'Ca máy cũ của máy trùng ngày kết thúc trước ngày bắt đầu mới; máy khác giữ nguyên');
select pg_temp.ok(pg_temp.api_val(format($q$select concat_ws('|', shifts, eff_to) from app.v_kh_machine_shifts where machine_code = 'SIL-MIX' and request_id = %L$q$, (select v from t where k = 'r2')))
  = '2|' || pg_temp.mon(1)::text, 'Lịch máy thấy ca máy cũ chỉ còn hiệu lực đến ngày trước');

-- ================================================================ 6. Quản trị lập thì vẫn chờ Giám đốc; kết thúc thêm ca
select pg_temp.as_user('F_ADM');
insert into t select 'r4', pg_temp.api_val(format($q$select app.kh_shift_propose(null, %L)::text$q$, jsonb_build_object('reason', 'Quản trị thử',
  'items', pg_temp.items(array['TWS-01'], 2, pg_temp.mon(0), pg_temp.mon(1)))))::uuid;
select pg_temp.ok((select status = 'PROPOSED' from plan.shift_requests where id = (select v from t where k = 'r4')), 'Quản trị lập: vẫn chờ Giám đốc duyệt');
select pg_temp.api_fails(format($q$select app.kh_shift_review(%L, true, null)$q$, (select v from t where k = 'r4')), 'không tự duyệt', 'Quản trị không tự duyệt đề xuất mình lập');
select pg_temp.as_user('F_SXTP');
select pg_temp.api_val(format($q$select app.kh_shift_end(%L, 'Không cần nữa')::text$q$, (select v from t where k = 'r4')));
select pg_temp.ok((select status = 'CANCELLED' from plan.shift_requests where id = (select v from t where k = 'r4')), 'TP SX hủy đề xuất chưa duyệt');
select pg_temp.api_val(format($q$select app.kh_shift_end(%L, 'Hết trễ')::text$q$, (select v from t where k = 'r3')));
select pg_temp.ok((select status = 'ENDED' from plan.shift_requests where id = (select v from t where k = 'r3'))
  and (select bool_and(least(date_to, coalesce(ended_on, date_to)) <= greatest(date_from - 1, pg_temp.today())) from plan.machine_shifts where request_id = (select v from t where k = 'r3')),
  'Kết thúc thêm ca: máy về 1 ca từ ngày mai');
select pg_temp.as_user('F_KTTP');
select pg_temp.api_fails(format($q$select app.kh_shift_end(%L, 'x')$q$, (select v from t where k = 'r2')), 'Chỉ Giám đốc hoặc TP SX', 'TP KT/QA không kết thúc thêm ca');

-- ================================================================ 7. Ca làm việc của người, luật nghỉ 12 giờ khi đổi ca
select pg_temp.api_fails(format($q$select app.kh_save_op_shift(null, 'NV2', %L, %L, 2)$q$, pg_temp.mon(0), pg_temp.mon(4)), 'Chỉ TP SX', 'TP KT/QA không đặt ca của người');
select pg_temp.as_user('F_SXTP');
-- ca 2 (14–22) Thứ Hai–Thứ Sáu: Thứ Bảy về ca 1 (08:00) chỉ nghỉ 10 giờ → chặn
select pg_temp.api_fails(format($q$select app.kh_save_op_shift(null, 'NV2', %L, %L, 2)$q$, pg_temp.mon(0), pg_temp.mon(4)), 'nghỉ ít nhất 12 giờ', 'Ca 2 rồi về ca 1 hôm sau (nghỉ 10 giờ) bị chặn');
-- ca 2 Thứ Hai–Thứ Bảy: Chủ nhật nghỉ → được
insert into t select 'o1', pg_temp.api_val(format($q$select app.kh_save_op_shift(null, 'NV2', %L, %L, 2, 'Bện ca 2')::text$q$, pg_temp.mon(0), pg_temp.mon(5)))::uuid;
select pg_temp.ok((select shift_no = 2 from plan.operator_shifts where id = (select v from t where k = 'o1'))
  and plan.op_shift_on('NV2', pg_temp.mon(3)) = 2 and plan.op_shift_on('NV2', pg_temp.mon(7)) = 1, 'NV2 ca 2 Thứ Hai–Thứ Bảy, ngoài khoảng là ca 1');
select pg_temp.ok(exists (select 1 from master.planning_param_log where section = 'Ca làm việc của người' and item like 'NV2%'), 'Ghi nhật ký ca của người');
select pg_temp.api_fails(format($q$select app.kh_save_op_shift(null, 'NV2', %L, %L, 3)$q$, pg_temp.mon(2), pg_temp.mon(3)), 'trùng ngày', 'Không đặt hai ca trùng ngày cho một người');
select pg_temp.api_fails(format($q$select app.kh_save_op_shift(null, 'NV9', %L, %L, 2)$q$, pg_temp.mon(0), pg_temp.mon(1)), 'không có', 'Người không có thì báo');
select pg_temp.api_fails(format($q$select app.kh_save_op_shift(null, 'NV3', %L, %L, 1)$q$, pg_temp.mon(0), pg_temp.mon(1)), 'ca 2 hoặc ca 3', 'Chỉ đặt ca 2 hoặc ca 3');
-- ca 3 (22–06) Thứ Hai rồi Thứ Ba ca 1 (08:00) chỉ nghỉ 2 giờ → chặn; ca 1 Thứ Hai rồi ca 3 Thứ Ba nghỉ 29 giờ → được
select pg_temp.api_fails(format($q$select app.kh_save_op_shift(null, 'NV3', %L, %L, 3)$q$, pg_temp.mon(0), pg_temp.mon(0)), 'nghỉ ít nhất 12 giờ', 'Ca 3 rồi về ca 1 hôm sau bị chặn');
insert into t select 'o2', pg_temp.api_val(format($q$select app.kh_save_op_shift(null, 'NV3', %L, %L, 3)::text$q$, pg_temp.mon(1), pg_temp.mon(5)))::uuid;
select pg_temp.ok(plan.op_shift_on('NV3', pg_temp.mon(1)) = 3, 'Ca 1 rồi lên ca 3 hôm sau được (nghỉ đủ)');
-- Sửa sang khoảng làm vi phạm thì chặn, giữ nguyên bản cũ
select pg_temp.api_fails(format($q$select app.kh_save_op_shift(%L, 'NV3', %L, %L, 3)$q$, (select v from t where k = 'o2'), pg_temp.mon(1), pg_temp.mon(3)), 'nghỉ ít nhất 12 giờ', 'Sửa làm thiếu giờ nghỉ bị chặn');
select pg_temp.api_fails(format($q$select app.kh_delete_op_shift(%L, '')$q$, (select v from t where k = 'o1')), 'lý do', 'Bỏ ca của người phải có lý do');
select pg_temp.api_val(format($q$select app.kh_delete_op_shift(%L, 'Bện về 1 ca')::text$q$, (select v from t where k = 'o1')));
select pg_temp.ok(plan.op_shift_on('NV2', pg_temp.mon(3)) = 1, 'Bỏ ca: NV2 về ca 1');
select pg_temp.ok(pg_temp.api_val($q$select count(*)::text from app.v_kh_op_shifts$q$) = '1'
  and pg_temp.api_val($q$select jsonb_array_length(op_shifts)::text from app.v_kh_config$q$) = '1', 'Lịch máy đọc ca của người');
select pg_temp.as_user('F_VH');
select pg_temp.api_fails(format($q$select app.kh_delete_op_shift(%L, 'x')$q$, (select v from t where k = 'o2')), 'Chỉ TP SX', 'Công nhân không sửa ca');

do $$ declare v_n int; v_s text; begin
  select count(*), string_agg(r.n || '. ' || r.msg, E'\n' order by r.n) into v_n, v_s from r;
  raise exception 'KET_QUA_OK % kiểm tra đạt:%', v_n, E'\n' || v_s;
end $$;
