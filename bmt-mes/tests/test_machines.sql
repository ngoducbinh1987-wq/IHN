-- Kiểm thử module Quản lý máy (migration 2300 + 20261026002400): quyền, khai báo máy, tốc độ, bảo dưỡng, nhắc lịch, trạng thái, checklist,
-- kiểm tra năng lực, báo cáo tháng. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK, không để lại dữ liệu.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create temp table t (k text primary key, v uuid);
grant all on r, t to authenticated;
grant usage on sequence r_n_seq to authenticated;

create function pg_temp.as_user(p_code text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', (select id::text from core.profiles where employee_code = p_code), true),
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
create function pg_temp.v(p_k text) returns uuid language sql as $$ select v from t where k = p_k $$;
set client_min_messages = notice;

with u(code, role) as (values ('M_KTTP','KT_TP'),('M_SXTP','SX_TP'),('M_VH','VAN_HANH'),('M_BGD','BGD'),('M_KD','KD_NV'),('M_BGD2','BGD'),('M_KTTP2','KT_TP')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('M_KTTP','KT_TP'),('M_SXTP','SX_TP'),('M_VH','VAN_HANH'),('M_BGD','BGD'),('M_KD','KD_NV'),('M_BGD2','BGD'),('M_KTTP2','KT_TP')) u(code, role)
  on u.code = p.employee_code;

-- ============================================================ 1. Khai báo dây chuyền, máy con, thông số
select pg_temp.as_user('M_KTTP');
set local role authenticated;
insert into t values ('line', app.create_machine(null, 'test-si-09', 'Line silicone thử', null, 'CD2', false, 0, true));
insert into t values ('oven', app.create_machine(pg_temp.v('line'), 'TEST-SI-09-CV', 'Lò lưu hóa', 'Lò lưu hóa', null, true, 30, true));
insert into t values ('cool', app.create_machine(pg_temp.v('line'), 'TEST-SI-09-CT', 'Máng làm mát', 'Máng làm mát', null, false, 40, false));
select pg_temp.ok((select code from master.machines where id = pg_temp.v('line')) = 'TEST-SI-09', 'Tạo dây chuyền, mã tự viết hoa');
select pg_temp.ok((select machine_type from master.machines where id = pg_temp.v('line')) = 'EXTRUDER_SI', 'Dây chuyền lấy loại máy theo công đoạn');
select pg_temp.ok((select count(*) from master.machine_specs where machine_id = pg_temp.v('oven')) = 15, 'Máy con có bộ 15 trường thông số mẫu');
select pg_temp.ok((select count(*) from master.machine_specs where machine_id = pg_temp.v('cool')) = 0, 'Không chọn mẫu thì không thêm trường');
select pg_temp.fails($$select app.create_machine('$$ || pg_temp.v('oven') || $$', 'X1', 'X', null, null, false, 0, false)$$, 'máy con', 'Không thêm máy con vào máy con');
select pg_temp.fails($$select app.create_machine(null, 'TEST-SI-09', 'Trùng', null, 'CD2', false, 0, false)$$, 'đã có', 'Chặn trùng mã máy');
update master.machine_specs set value = '380 V, 3 pha', source = 'BMT' where machine_id = pg_temp.v('oven') and label = 'Điện áp';
insert into master.machine_specs (machine_id, grp, label, value, uom, source) values (pg_temp.v('oven'), 'Đấu nối', 'Cút nước vào', 'DN25', null, 'GD');
insert into master.machine_components (machine_id, kind, name, spec, qty) values (pg_temp.v('oven'), 'SENSOR', 'Cặp nhiệt loại K', '0–800 °C', 12);
insert into master.machine_ranges (machine_id, param, label, min_value, max_value, uom) values
  (pg_temp.v('line'), 'SIZE_MM2', 'Tiết diện ruột', 0.75, 4, 'mm²'), (pg_temp.v('line'), 'SPEED_MPM', 'Tốc độ dây', 10, 120, 'm/ph');
select app.set_operator_skill(pg_temp.v('line'), 'NV1', 'MAIN', 'Thử');
select pg_temp.ok((select count(*) from app.machine_history(null, pg_temp.v('oven')) where kind = 'CHANGE') >= 1, 'Sửa thông số ghi vào lịch sử vận hành');
reset role;

-- Quyền: SX_TP không khai báo thông số; vận hành không tạo máy; KD không xem
select pg_temp.as_user('M_SXTP');
set local role authenticated;
select pg_temp.fails($$insert into master.machine_specs (machine_id, grp, label) values ('$$ || pg_temp.v('oven') || $$', 'Điện', 'X')$$, 'row-level', 'Quản lý SX không sửa thông số máy');
select pg_temp.ok((select count(*) from app.v_machines where id = pg_temp.v('line')) = 1, 'Quản lý SX xem được máy');
reset role;
select pg_temp.as_user('M_VH');
set local role authenticated;
select pg_temp.fails($$select app.create_machine(null, 'X2', 'X', null, 'CD2', false, 0, false)$$, 'quyền', 'Vận hành không khai báo máy');
reset role;
select pg_temp.as_user('M_KD');
set local role authenticated;
select pg_temp.ok((select count(*) from app.v_machine_specs) = 0, 'Kinh doanh không xem thông số máy');
select pg_temp.ok((select count(*) from app.machine_history()) = 0, 'Kinh doanh không xem lịch sử vận hành');
reset role;

-- Người đứng máy: dùng chung NV1–NV5 với Lịch máy
select pg_temp.as_user('M_VH');
set local role authenticated;
select pg_temp.fails($$select app.set_operator_skill('$$ || pg_temp.v('line') || $$', 'NV5', 'LEARNING')$$, 'Chỉ Quản lý SX', 'Vận hành không giao người đứng máy');
select pg_temp.ok((select count(*) from app.machine_rate_defaults()) = 5, 'Vận hành xem được tốc độ mặc định theo công đoạn');
reset role;
select pg_temp.as_user('M_SXTP');
set local role authenticated;
select app.set_operator_skill(pg_temp.v('line'), 'NV5', 'LEARNING', 'Kèm học');
select pg_temp.ok((select level from app.v_machine_operators where machine_id = pg_temp.v('line') and operator_code = 'NV5') = 'LEARNING', 'Quản lý SX giao người đang học');
select pg_temp.fails($$select app.sign_operator_skill('$$ || pg_temp.v('line') || $$', 'NV5')$$, 'TP Kỹ thuật', 'Quản lý SX không ký xác nhận tay nghề');
select pg_temp.fails($$select app.set_operator_skill('$$ || pg_temp.v('line') || $$', 'NV5', 'LEARNING')$$, 'Không có thay đổi', 'Giao trùng thì báo');
select pg_temp.fails($$select app.set_operator_skill('$$ || pg_temp.v('oven') || $$', 'NV5', 'MAIN')$$, 'máy con', 'Không giao người cho máy con');
select pg_temp.fails($$select app.set_operator_skill('$$ || pg_temp.v('line') || $$', 'NV9', 'MAIN')$$, 'Không có người', 'Không giao người không có trong danh sách');
reset role;
select pg_temp.as_user('M_KTTP');
set local role authenticated;
select pg_temp.fails($$select app.sign_operator_skill('$$ || pg_temp.v('line') || $$', 'NV1')$$, 'không tự ký', 'Người giao người đứng máy không tự ký tay nghề');
reset role;
select pg_temp.as_user('M_KTTP2');
set local role authenticated;
select app.sign_operator_skill(pg_temp.v('line'), 'NV1');
reset role;
select pg_temp.as_user('M_KTTP');
set local role authenticated;
select pg_temp.ok((select signed_at is not null and signed_by_name is not null from app.v_machine_operators where machine_id = pg_temp.v('line') and operator_code = 'NV1'), 'TP Kỹ thuật/QA ký xác nhận tay nghề');
select app.set_operator_skill(pg_temp.v('line'), 'NV5', 'MAIN', 'Đã học xong');
select pg_temp.ok((select signed_at is null from app.v_machine_operators where machine_id = pg_temp.v('line') and operator_code = 'NV5'), 'Đổi mức tay nghề thì phải ký lại');
select app.remove_operator_skill(pg_temp.v('line'), 'NV5', 'Thử bỏ');
select pg_temp.ok(not exists (select 1 from app.v_machine_operators where machine_id = pg_temp.v('line') and operator_code = 'NV5'), 'Bỏ giao người đứng máy');
select pg_temp.ok((select operators from app.v_machines where id = pg_temp.v('oven')) = 'NV1', 'Máy con hiện người đứng chính của dây chuyền');
select pg_temp.ok((select count(*) from app.machine_history(pg_temp.v('line')) where kind = 'PEOPLE') = 4, 'Đổi người đứng máy ghi lịch sử vận hành');
select pg_temp.ok((select count(*) from master.planning_param_log where at >= now() and section = 'Người đứng máy') = 4, 'Ghi nhật ký tham số như Lịch máy');
reset role;

-- ============================================================ 2. Tốc độ chuẩn, duyệt
select pg_temp.as_user('M_KTTP');
set local role authenticated;
with i as (insert into master.machine_speeds (machine_id, op_code, core_code, label, rated_mpm, std_mpm, setup_min, source)
values (pg_temp.v('line'), 'CD2', 'M1.5', 'Lõi 1,5 mm²', 120, 80, 45, 'BMT') returning id) insert into t select 's1', id from i;
insert into master.machine_speeds (machine_id, op_code, label, std_mpm, setup_min) values (pg_temp.v('line'), 'CD2', 'Mặc định', 70, 45);
select pg_temp.fails($$insert into master.machine_speeds (machine_id, op_code, std_mpm, status) values ('$$ || pg_temp.v('line') || $$', 'CD2', 90, 'APPROVED')$$,
  'row-level', 'Không tự ghi tốc độ đã duyệt, phải qua bước duyệt');
select pg_temp.fails($$select app.approve_machine_speed('$$ || pg_temp.v('s1') || $$')$$, 'không tự duyệt', 'Người nhập tốc độ không tự duyệt');
reset role;
select pg_temp.as_user('M_KTTP2');
set local role authenticated;
select app.approve_machine_speed(pg_temp.v('s1'));
reset role;
select pg_temp.as_user('M_KTTP');
set local role authenticated;
select pg_temp.ok((select status = 'APPROVED' and not temp_approval from master.machine_speeds where id = pg_temp.v('s1')), 'TP Kỹ thuật/QA duyệt tốc độ chuẩn');
with u as (update master.machine_speeds set std_mpm = 99 where id = pg_temp.v('s1') returning 1)
select pg_temp.ok((select count(*) from u) = 0, 'Không sửa được tốc độ đã duyệt (phải tạo bản mới)');
with i as (insert into master.machine_speeds (machine_id, op_code, core_code, label, std_mpm, setup_min) values (pg_temp.v('line'), 'CD2', 'M1.5', 'Lõi 1,5 mm² (mới)', 75, 45) returning id) insert into t select 's2', id from i;
reset role;
select pg_temp.as_user('M_BGD');
set local role authenticated;
select app.approve_machine_speed(pg_temp.v('s2'));
select pg_temp.ok((select status = 'APPROVED' and temp_approval from master.machine_speeds where id = pg_temp.v('s2')), 'Giám đốc duyệt tạm, đánh dấu duyệt tạm');
select pg_temp.ok((select status from master.machine_speeds where id = pg_temp.v('s1')) = 'OBSOLETE', 'Bản duyệt cũ cùng khóa chuyển hết hiệu lực');
reset role;
select pg_temp.as_user('M_SXTP');
set local role authenticated;
select pg_temp.fails($$select app.approve_machine_speed('$$ || pg_temp.v('s2') || $$')$$, 'quyền', 'Quản lý SX không duyệt tốc độ');
reset role;

-- ============================================================ 3. Kế hoạch bảo dưỡng, trạng thái, nhắc lịch
select pg_temp.as_user('M_KTTP');
set local role authenticated;
with i as (insert into mfg.maint_plans (machine_id, name, level, every_days, remind_days, stop_minutes, last_done_at)
values (pg_temp.v('oven'), 'Vệ sinh lò', 'MINOR', 14, 7, 240, now() - interval '9 days') returning id) insert into t select 'p1', id from i;
with i as (insert into mfg.maint_plans (machine_id, name, level, every_days, remind_days, stop_minutes, off_shift, last_done_at, steps)
values (pg_temp.v('cool'), 'Thay nước máng', 'MINOR', 3, 1, 60, true, now() - interval '5 days', array['Xả nước', 'Châm nước mới']) returning id) insert into t select 'p2', id from i;
with i as (insert into mfg.maint_plans (machine_id, name, level, every_hours, remind_days, stop_minutes, base_hours)
values (pg_temp.v('line'), 'Đại tu hộp số', 'MAJOR', 2000, 30, 480, 1950) returning id) insert into t select 'p3', id from i;
with i as (insert into mfg.maint_plans (machine_id, name, level, every_days, remind_days) values (pg_temp.v('line'), 'Kiểm tra tủ điện', 'MINOR', 90, 7) returning id) insert into t select 'p4', id from i;
select pg_temp.ok((select state from app.v_maint_plans where id = pg_temp.v('p1')) = 'SOON', 'Bảo dưỡng nhỏ còn 5 ngày, nhắc trước 7 ngày: Sắp đến hạn');
select pg_temp.ok((select state from app.v_maint_plans where id = pg_temp.v('p2')) = 'OVERDUE', 'Quá chu kỳ 3 ngày: Quá hạn');
select pg_temp.ok((select state from app.v_maint_plans where id = pg_temp.v('p3')) = 'SOON', 'Bảo dưỡng lớn còn 50 giờ chạy (khoảng 9 ngày), nhắc trước 30 ngày: Sắp đến hạn');
select pg_temp.ok((select state from app.v_maint_plans where id = pg_temp.v('p4')) = 'OK', 'Còn 90 ngày: Bình thường');
select pg_temp.ok((select used_hours from app.v_maint_plans where id = pg_temp.v('p3')) = 1950, 'Giờ chạy = giờ đã có khi khai báo + giờ theo dõi');
select pg_temp.fails($$insert into mfg.maint_plans (machine_id, name) values ('$$ || pg_temp.v('line') || $$', 'Không chu kỳ')$$, 'check', 'Bắt buộc có ít nhất một chu kỳ');
reset role;

select pg_temp.ok(mfg.maint_daily_job() > 0, 'Việc 07:00 gửi nhắc bảo dưỡng');
select pg_temp.ok((select count(*) from wf.notifications n join core.profiles p on p.id = n.user_id where p.employee_code = 'M_KTTP' and n.title like 'Sắp đến hạn bảo dưỡng lớn: TEST-SI-09') = 1,
  'TP Kỹ thuật/QA nhận nhắc bảo dưỡng lớn');
select pg_temp.ok((select count(*) from wf.notifications n join core.profiles p on p.id = n.user_id where p.employee_code = 'M_BGD' and n.title like 'Quá hạn bảo dưỡng: TEST-SI-09') = 1,
  'Quá hạn báo thêm Ban giám đốc');
select pg_temp.ok((select count(*) from wf.notifications n join core.profiles p on p.id = n.user_id where p.employee_code = 'M_BGD' and n.title like 'Sắp đến hạn%TEST-SI-09') = 0,
  'Sắp đến hạn không báo Ban giám đốc');
select pg_temp.ok(not exists (select 1 from wf.notifications where title like '%bảo dưỡng%TEST-SI-09%' and emailed_at is null), 'Nhắc bảo dưỡng chỉ trên thông báo, không gửi email');
create temp table _cnt as select count(*) as n from wf.notifications where title like '%bảo dưỡng%TEST-SI-09%';
select mfg.maint_daily_job();
select pg_temp.ok((select count(*) from wf.notifications where title like '%bảo dưỡng%TEST-SI-09%') = (select n from _cnt), 'Chạy lại không nhắc trùng');
select pg_temp.ok((select count(*) from wf.notifications n join core.profiles p on p.id = n.user_id where p.employee_code like 'M\_%' and n.title = 'Quá hạn bảo dưỡng: TEST-SI-09') = 5, 'Quá hạn: 2 TP Kỹ thuật/QA + 1 Quản lý SX + 2 Ban giám đốc');

-- ============================================================ 4. Trạng thái máy, hỏng, phiếu sửa chữa
select pg_temp.as_user('M_VH');
set local role authenticated;
select pg_temp.fails($$select app.set_machine_status('$$ || pg_temp.v('oven') || $$', 'DOWN')$$, 'lý do', 'Dừng / hỏng phải chọn lý do');
select app.set_machine_status(pg_temp.v('oven'), 'DOWN', 'DT_BREAKDOWN', 'Thanh gia nhiệt module 7 hỏng', now() + interval '1 day');
reset role;
select pg_temp.ok((select status from master.machines where id = pg_temp.v('oven')) = 'DOWN', 'Vận hành báo hỏng máy con');
select pg_temp.ok((select status from master.machines where id = pg_temp.v('line')) = 'DOWN', 'Máy con quan trọng hỏng: cả dây chuyền chuyển Hỏng');
select pg_temp.ok((select count(*) from mfg.maint_work_orders where machine_id = pg_temp.v('oven') and wo_type = 'CM' and status = 'OPEN') = 1, 'Tự mở phiếu sửa chữa cho máy hỏng');
select pg_temp.ok((select count(*) from mfg.downtime_events where machine_id = pg_temp.v('oven') and ended_at is null and reason_code = 'DT_BREAKDOWN') = 1, 'Ghi lần dừng máy');
select pg_temp.ok((select count(*) from wf.notifications where title = 'Máy hỏng: TEST-SI-09-CV') >= 3, 'Báo TP Kỹ thuật/QA, Quản lý SX, Ban giám đốc');
insert into t select 'cm', id from mfg.maint_work_orders where machine_id = pg_temp.v('oven') and wo_type = 'CM';
select pg_temp.as_user('M_VH');
set local role authenticated;
select pg_temp.fails($$select app.finish_maint_wo('$$ || pg_temp.v('cm') || $$', 'OK', 'Thay thanh', '[]')$$, 'quyền', 'Vận hành không đóng phiếu sửa chữa');
reset role;
select pg_temp.as_user('M_KTTP');
set local role authenticated;
select pg_temp.fails($$select app.finish_maint_wo('$$ || pg_temp.v('cm') || $$', 'OK', '', '[]')$$, 'việc đã làm', 'Phải ghi việc đã làm');
select app.finish_maint_wo(pg_temp.v('cm'), 'OK', 'Thay thanh gia nhiệt module 7', '[]', 'Thanh gia nhiệt đứt');
reset role;
select pg_temp.ok((select status from master.machines where id = pg_temp.v('oven')) = 'IDLE', 'Sửa xong: máy con về Chờ việc');
select pg_temp.ok((select status from master.machines where id = pg_temp.v('line')) = 'IDLE', 'Sửa xong máy con quan trọng: dây chuyền về Chờ việc');
select pg_temp.ok((select count(*) from mfg.downtime_events where machine_id = pg_temp.v('oven') and ended_at is null) = 0, 'Đóng lần dừng máy');
select pg_temp.ok((select count(*) from mfg.machine_status_log where machine_id = pg_temp.v('line')) >= 2, 'Nhật ký trạng thái dây chuyền');
select pg_temp.as_user('M_SXTP');
set local role authenticated;
select pg_temp.fails($$select app.confirm_maint_wo('$$ || pg_temp.v('cm') || $$')$$, 'TP Kỹ thuật', 'Quản lý SX không xác nhận phiếu');
reset role;
select pg_temp.as_user('M_KTTP');
set local role authenticated;
select pg_temp.fails($$select app.confirm_maint_wo('$$ || pg_temp.v('cm') || $$')$$, 'không tự xác nhận', 'Người làm phiếu không tự xác nhận');
reset role;
select pg_temp.as_user('M_KTTP2');
set local role authenticated;
select app.confirm_maint_wo(pg_temp.v('cm'));
reset role;
select pg_temp.as_user('M_KTTP');
set local role authenticated;
select pg_temp.ok((select confirmed_at is not null from mfg.maint_work_orders where id = pg_temp.v('cm')), 'TP Kỹ thuật/QA xác nhận phiếu');

-- ============================================================ 5. Phiếu bảo dưỡng từ kế hoạch
insert into t values ('pm', app.create_maint_wo(pg_temp.v('p1'), null));
select pg_temp.ok(app.create_maint_wo(pg_temp.v('p1'), null) = pg_temp.v('pm'), 'Một kế hoạch chỉ có một phiếu đang mở');
select pg_temp.ok((select wo_no like 'BD-%' from mfg.maint_work_orders where id = pg_temp.v('pm')), 'Số phiếu bảo dưỡng BD-YYMM-####');
select pg_temp.ok((select state from app.v_maint_plans where id = pg_temp.v('p1')) = 'SOON' and (select open_wo_no from app.v_maint_plans where id = pg_temp.v('p1')) is not null, 'Kế hoạch hiện phiếu đang mở');
select app.start_maint_wo(pg_temp.v('pm'));
select pg_temp.ok((select status from master.machines where id = pg_temp.v('oven')) = 'MAINT', 'Bảo dưỡng trong ca: máy chuyển Bảo dưỡng');
select app.finish_maint_wo(pg_temp.v('pm'), 'OK', 'Đã vệ sinh 12 module', '[{"label":"Hút bụi","done":true}]');
select pg_temp.ok((select state from app.v_maint_plans where id = pg_temp.v('p1')) = 'OK' and (select used_days from app.v_maint_plans where id = pg_temp.v('p1')) = 0, 'Xong bảo dưỡng: đặt lại chu kỳ');
select pg_temp.ok((select status from master.machines where id = pg_temp.v('oven')) = 'IDLE', 'Xong bảo dưỡng: máy về Chờ việc');
insert into t values ('pm2', app.create_maint_wo(pg_temp.v('p2'), null));
select app.start_maint_wo(pg_temp.v('pm2'));
select pg_temp.ok((select status from master.machines where id = pg_temp.v('cool')) = 'IDLE', 'Bảo dưỡng ngoài giờ ca: không đổi trạng thái máy');
select pg_temp.ok((select jsonb_array_length(steps) from mfg.maint_work_orders where id = pg_temp.v('pm2')) = 2, 'Phiếu chép các bước từ kế hoạch');
reset role;

-- ============================================================ 6. Checklist đầu ca
select pg_temp.as_user('M_VH');
set local role authenticated;
select pg_temp.fails($$select app.save_daily_check('$$ || pg_temp.v('line') || $$', '[{"label":"Vệ sinh máy","ok":true},{"label":"Kiểm tra áp khí nén","ok":false}]', '')$$,
  'ghi rõ', 'Mục không đạt phải ghi vấn đề');
insert into t values ('chk', app.save_daily_check(pg_temp.v('line'), '[{"label":"Vệ sinh máy","ok":true},{"label":"Kiểm tra áp khí nén","ok":false,"note":"0,45 MPa"}]', null));
select pg_temp.fails($$select app.save_daily_check('$$ || pg_temp.v('oven') || $$', '[{"label":"Vệ sinh máy","ok":true}]', null)$$, 'dây chuyền', 'Checklist ghi theo dây chuyền');
select pg_temp.fails($$select app.review_daily_check('$$ || pg_temp.v('chk') || $$')$$, 'TP Kỹ thuật', 'Vận hành không tự kiểm tra checklist');
reset role;
select pg_temp.ok((select has_issue from mfg.maint_checks where id = pg_temp.v('chk')), 'Checklist có mục không đạt được đánh dấu');
select pg_temp.ok((select count(*) from wf.notifications where title = 'Checklist đầu ca có vấn đề: TEST-SI-09') >= 2, 'Báo TP Kỹ thuật/QA và Quản lý SX khi checklist có vấn đề');
select pg_temp.as_user('M_KTTP');
set local role authenticated;
select app.review_daily_check(pg_temp.v('chk'));
reset role;
select pg_temp.as_user('M_VH');
set local role authenticated;
select pg_temp.fails($$select app.save_daily_check('$$ || pg_temp.v('line') || $$', '[{"label":"Vệ sinh máy","ok":true}]', null)$$, 'đã kiểm tra', 'Không sửa checklist đã được kiểm tra');
reset role;

-- ============================================================ 7. Kiểm tra năng lực
select pg_temp.as_user('M_KTTP');
set local role authenticated;
insert into t select 'p15', id from master.products where code = 'SIF-1C-1P5';
insert into t select 'p6', p.id from master.products p join master.product_specs s on s.id = p.current_spec_id join master.core_types ct on ct.code = s.core_code and ct.set_id = s.param_set_id
  where ct.nominal_mm2 > 4 and upper(s.insulation) like 'SIL%' order by p.code limit 1;
insert into t select 'pvc', p.id from master.products p join master.product_specs s on s.id = p.current_spec_id where upper(coalesce(s.insulation, '')) not like 'SIL%' order by p.code limit 1;
insert into t select 'sfr', p.id from master.products p join master.product_specs s on s.id = p.current_spec_id where p.group_code = 'SFR' order by p.code limit 1;
select app.remove_operator_skill(pg_temp.v('line'), 'NV1', 'Thử thiếu người');
create temp table _cap as select app.check_capacity(null, current_date, current_date + 27, 1, 0,
  jsonb_build_array(jsonb_build_object('product_id', pg_temp.v('p15'), 'qty_m', 200000))) as j;
select pg_temp.ok((select (o ->> 'req_min')::numeric > 0 from _cap, jsonb_array_elements(j -> 'ops') o where o ->> 'op_code' = 'EXTRUDER_SI'), 'Tính giờ cần cho line silicone (bọc cách điện silicone)');
select pg_temp.ok((select jsonb_array_length(j -> 'ops') >= 1 from _cap), 'Có năng lực từng công đoạn');
select pg_temp.ok((select (j -> 'issues')::text like '%chưa có người đứng máy chính%' from _cap), 'Cảnh báo dây chuyền chưa có người đứng máy');
select pg_temp.ok((select (j -> 'issues')::text like '%tốc độ mặc định%' from _cap), 'Máy bện chưa có tốc độ riêng: dùng tốc độ mặc định của công đoạn');
select pg_temp.ok((select (o ->> 'req_min')::numeric > 0 from _cap, jsonb_array_elements(j -> 'ops') o where o ->> 'op_code' = 'BUNCHER'), 'Máy bện vẫn tính được giờ cần theo tốc độ mặc định');
select pg_temp.ok((select (j -> 'issues')::text like '%Thay nước máng%' from _cap) is false, 'Phiếu đang mở thì không báo quá hạn nữa');
drop table _cap;
insert into master.machine_ranges (machine_id, param, label, min_value, max_value, uom)
select id, 'SIZE_MM2', 'Tiết diện ruột', 0.75, 4, 'mm²' from master.machines where op_code = 'CD2' and id <> pg_temp.v('line');
create temp table _cap as select app.check_capacity(null, current_date, current_date + 27, 1, 0,
  jsonb_build_array(jsonb_build_object('product_id', pg_temp.v('p6'), 'qty_m', 1000))) as j;
select pg_temp.ok((select (j -> 'issues')::text like '%ngoài dải%' from _cap), 'Sản phẩm ngoài dải tiết diện của máy bị chặn');
drop table _cap;
create temp table _cap as select app.check_capacity(null, current_date, current_date + 27, 1, 0,
  jsonb_build_array(jsonb_build_object('product_id', pg_temp.v('pvc'), 'qty_m', 5000))) as j;
select pg_temp.ok((select (o ->> 'req_min')::numeric > 0 from _cap, jsonb_array_elements(j -> 'ops') o where o ->> 'op_code' = 'EXTRUDER_TP')
  and (select (o ->> 'req_min')::numeric = 0 from _cap, jsonb_array_elements(j -> 'ops') o where o ->> 'op_code' = 'EXTRUDER_SI'), 'Bọc cách điện PVC/HDPE tính trên line vỏ như Lịch máy');
drop table _cap;
create temp table _cap as select app.check_capacity(null, current_date, current_date + 4, 1, 0,
  jsonb_build_array(jsonb_build_object('product_id', pg_temp.v('sfr'), 'qty_m', 400000))) as j;
select pg_temp.ok((select (j -> 'issues')::text like '%Thiếu người%' from _cap), 'Cảnh báo thiếu người khi phải chạy nhiều dây chuyền cùng lúc');
select pg_temp.ok((select count(*) from _cap, jsonb_array_elements(j -> 'ops') o where o ->> 'op_code' = 'TWISTER') = 1, 'Xoắn + quấn AL/PET tính chung máy xoắn');
drop table _cap;
-- Gọi hai lần trong cùng giao dịch
select pg_temp.ok((select app.check_capacity(null, current_date, current_date + 6, 2, 1, '[]') ->> 'shifts') = '2', 'Chọn 2 ca, tăng ca 1 giờ');
reset role;

-- ============================================================ 8. Báo cáo tháng, email Ban giám đốc
select pg_temp.ok(mfg.maint_monthly_job(current_date) >= 2, 'Báo cáo tháng gửi Ban giám đốc');
select pg_temp.ok((select count(*) from wf.notifications where title like 'Báo cáo bảo trì bảo dưỡng tháng%' and emailed_at is null) >= 2, 'Báo cáo tháng có gửi email');
select pg_temp.ok(not exists (select 1 from wf.notifications n join core.user_roles ur on ur.user_id = n.user_id
  where n.title like 'Báo cáo bảo trì bảo dưỡng tháng%' and n.user_id not in (select user_id from core.user_roles where role_code = 'BGD')), 'Chỉ Ban giám đốc nhận báo cáo tháng');
select pg_temp.ok(mfg.maint_monthly_job(current_date) = 0, 'Mỗi tháng chỉ gửi một lần');
select pg_temp.as_user('M_BGD');
set local role authenticated;
select pg_temp.ok((select (app.maint_report(current_date) -> 'lines')::text like '%TEST-SI-09%'), 'Ban giám đốc xem báo cáo tháng');
reset role;
select pg_temp.as_user('M_KD');
set local role authenticated;
select pg_temp.fails($$select app.maint_report(current_date)$$, 'quyền', 'Kinh doanh không xem báo cáo bảo trì');
reset role;

-- ============================================================ 9. Lịch làm việc dùng chung với Kế hoạch SX
select pg_temp.ok((mfg.machine_setting('shift') -> 'sessions')::text = (
  select format('[["%s", "%s"], ["%s", "%s"]]', to_char(start_time, 'HH24:MI'), to_char(start_time + make_interval(mins => ((extract(epoch from end_time - start_time) / 60)::int - break_min) / 2), 'HH24:MI'),
    to_char(start_time + make_interval(mins => ((extract(epoch from end_time - start_time) / 60)::int - break_min) / 2 + break_min), 'HH24:MI'), to_char(end_time, 'HH24:MI'))
  from master.shifts where code = 'A'), 'Giờ làm lấy từ ca A của Kế hoạch SX');
select pg_temp.as_user('M_KTTP');
set local role authenticated;
select pg_temp.fails($$select app.save_work_calendar('07:30', '11:30', '12:30', '16:30', '{1,2,3,4,5}', 80, 2, 'thử')$$, 'Giám đốc', 'TP Kỹ thuật không sửa lịch làm việc');
reset role;
select pg_temp.as_user('M_BGD');
set local role authenticated;
select pg_temp.fails($$select app.save_work_calendar('07:30', '11:30', '12:30', '16:30', '{1,2,3,4,5}', 80, 2, '')$$, 'lý do', 'Bắt buộc lý do');
select pg_temp.fails($$select app.save_work_calendar('07:30', '11:30', '12:30', '17:30', '{1,2,3,4,5}', 80, 2, 'x')$$, 'dài bằng nhau', 'Sáng chiều phải dài bằng nhau');
select pg_temp.ok(app.save_work_calendar('07:30', '11:30', '12:30', '16:30', '{1,2,3,4,5}', 80, 2, 'Thử giờ hè') >= 4, 'Giám đốc sửa giờ làm, ngày làm, tỷ lệ');
select pg_temp.ok((mfg.machine_setting('shift') -> 'sessions')::text = '[["07:30", "11:30"], ["12:30", "16:30"]]', 'Giờ làm mới đọc lại đúng');
select pg_temp.ok((select start_time = '07:30' and end_time = '16:30' and break_min = 60 from master.shifts where code = 'A'), 'Ca A của Kế hoạch SX cập nhật theo');
select pg_temp.ok((select fill_pct = 80 from master.planning_config where id = 1) and (mfg.machine_setting('shift') ->> 'fill')::numeric = 0.8, 'Tỷ lệ xếp lịch dùng chung');
select pg_temp.ok(mfg.workdays(date '2026-11-02', date '2026-11-08') = 5, 'Ngày làm việc T2–T6');
select pg_temp.ok((select count(*) from master.planning_param_log where at >= now() and item = 'Ngày làm việc trong tuần') = 1, 'Ghi nhật ký tham số');
select pg_temp.fails($$select app.save_work_calendar('07:30', '11:30', '12:30', '16:30', '{1,2,3,4,5}', 80, 2, 'x')$$, 'Không có thay đổi', 'Không đổi gì thì báo');
reset role;

select pg_temp.ok(not has_function_privilege('anon', 'mfg.machine_usage(uuid, timestamptz)', 'execute')
  and not has_function_privilege('anon', 'app.machine_history(uuid, uuid, timestamptz, timestamptz, integer)', 'execute'), 'Người chưa đăng nhập không gọi được hàm của module máy');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
