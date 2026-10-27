-- Kiểm thử migration 20261026003800_machine_schedule_link (Quản lý máy đợt A): báo hỏng qua TP KT/QA – TP SX, dừng máy từ
-- báo cáo ca vào nhật ký máy, giữ chỗ bảo dưỡng (TP KT/QA đề xuất, TP SX / Giám đốc chốt), lệnh ngày cảnh báo máy hỏng,
-- TP SX xác nhận phiếu bảo dưỡng / sửa chữa. Chạy được bằng psql hoặc MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create temp table t (k text primary key, v uuid);
create temp table x (k text primary key, j jsonb);

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
create function pg_temp.today() returns date language sql as $$ select (now() at time zone 'Asia/Ho_Chi_Minh')::date $$;
create function pg_temp.nt(p_code text, p_like text) returns bigint language sql as $$
  select count(*) from wf.notifications n join core.profiles p on p.id = n.user_id where p.employee_code = p_code and n.title like p_like
$$;
set client_min_messages = notice;

-- Người dùng thử; tài khoản thật tạm khóa trong giao dịch
update core.profiles set status = 'LOCKED' where (employee_code is null or employee_code !~ '^Y_') and status = 'ACTIVE';
with u(code, role) as (values ('Y_KTTP','KT_TP'),('Y_KTTP2','KT_TP'),('Y_SXTP','SX_TP'),('Y_SXKH','SX_KH'),('Y_BGD','BGD'),('Y_VH','VAN_HANH'),
  ('Y_TT','TO_TRUONG'),('Y_ADMIN','ADMIN')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from (select distinct code from u) c returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('Y_KTTP','KT_TP'),('Y_KTTP2','KT_TP'),('Y_SXTP','SX_TP'),('Y_SXKH','SX_KH'),('Y_BGD','BGD'),
  ('Y_VH','VAN_HANH'),('Y_TT','TO_TRUONG'),('Y_ADMIN','ADMIN')) u(code, role) on u.code = p.employee_code;
insert into t select 'si2', id from master.machines where code = 'EXT-SI-02';
update master.machines set status = 'IDLE', status_eta = null where code in ('EXT-SI-01','EXT-SI-02','BUN-01');
update mfg.maint_work_orders set status = 'CANCELLED' where machine_id in (select id from master.machines where code = 'EXT-SI-02' or inline_with = (select v from t where k = 'si2'))
  and status in ('OPEN','IN_PROGRESS');

-- ================================================================ 1. M1: báo hỏng
select pg_temp.as_user('Y_VH');
select pg_temp.fails($$select app.set_machine_status((select v from t where k = 'si2'), 'DOWN', 'DT_BREAKDOWN', 'x', now() + interval '1 day')$$,
  'TP Kỹ thuật/QA', 'Công nhân không đổi trạng thái máy trên MES (báo TP SX)');
select pg_temp.as_user('Y_TT');
select pg_temp.fails($$select app.set_machine_status((select v from t where k = 'si2'), 'STOP', 'DT_MATERIAL')$$,
  'TP Kỹ thuật/QA', 'Tổ trưởng không đổi trạng thái máy');
select pg_temp.as_user('Y_SXTP');
select pg_temp.fails($$select app.set_machine_status((select v from t where k = 'si2'), 'DOWN', 'DT_BREAKDOWN', 'Đứt dây trục vít')$$,
  'dự kiến chạy lại', 'Báo hỏng bắt buộc giờ dự kiến chạy lại');
select pg_temp.fails($$select app.set_machine_status((select v from t where k = 'si2'), 'DOWN', 'DT_BREAKDOWN', 'x', now() - interval '1 hour')$$,
  'sau bây giờ', 'Giờ dự kiến chạy lại phải sau bây giờ');
select pg_temp.as_user('Y_KTTP');
select app.set_machine_status((select v from t where k = 'si2'), 'DOWN', 'DT_BREAKDOWN', 'Đứt dây trục vít', now() + interval '2 days');
select pg_temp.ok((select status = 'DOWN' and status_eta > now() + interval '47 hours' from master.machines where id = (select v from t where k = 'si2')),
  'TP KT/QA báo hỏng: máy Hỏng, lưu giờ dự kiến chạy lại');
select pg_temp.ok((select count(*) from mfg.maint_work_orders where machine_id = (select v from t where k = 'si2') and wo_type = 'CM' and status = 'OPEN') = 1,
  'Mở phiếu sửa chữa');
select pg_temp.ok(pg_temp.nt('Y_SXTP', 'Máy không chạy được: EXT-SI-02') = 1 and pg_temp.nt('Y_SXKH', 'Máy không chạy được: EXT-SI-02') = 1,
  'Báo TP SX, Kế hoạch SX bấm Xếp lại lịch');
select pg_temp.ok((select status = 'DOWN' and status_eta is not null from app.v_kh_machines where code = 'EXT-SI-02'),
  'Lịch máy đọc trạng thái + giờ chạy lại qua app.v_kh_machines');
-- TP SX (TP KT/QA vắng) cập nhật giờ chạy lại
select pg_temp.as_user('Y_SXTP');
select app.set_machine_status((select v from t where k = 'si2'), 'DOWN', 'DT_BREAKDOWN', 'Chờ linh kiện', now() + interval '3 days');
select pg_temp.ok((select status_eta > now() + interval '71 hours' from master.machines where id = (select v from t where k = 'si2'))
  and (select count(*) from mfg.maint_work_orders where machine_id = (select v from t where k = 'si2') and wo_type = 'CM' and status = 'OPEN') = 1,
  'TP SX cập nhật giờ chạy lại, không mở thêm phiếu');
insert into t select 'cm', id from mfg.maint_work_orders where machine_id = (select v from t where k = 'si2') and wo_type = 'CM' and status = 'OPEN';

-- ================================================================ 2. M4: lệnh ngày cảnh báo máy hỏng còn việc
insert into plan.production_plans (plan_no, period_label, status) values ('KH-MA1', 'Thử máy hỏng', 'APPROVED');
insert into t select 'plan', id from plan.production_plans where plan_no = 'KH-MA1';
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, run_lots, m_per_pack, pack_type, brand)
select (select v from t where k = 'plan'), p.id, p.current_spec_id, 1000, 1, 500, 'Bobin gỗ', 'KAVIX' from master.products p where p.code = 'PFR-2C-1P5';
insert into t select 'line', id from plan.plan_lines where plan_id = (select v from t where k = 'plan');
insert into plan.schedule_versions (plan_id, version, is_current, base_date, params, reason)
values ((select v from t where k = 'plan'), 1, true, pg_temp.today(),
        '{"S":420,"SPD":1,"workdays":[1,2,3,4,5,6,7],"shifts":[{"code":"A","start_time":"08:00","end_time":"17:00","break_min":60}]}', 'Thử');
insert into t select 'ver', id from plan.schedule_versions where plan_id = (select v from t where k = 'plan');
insert into plan.schedule_slots (version_id, plan_line_id, op_code, color, machine_code, start_min, run_start_min, end_min, setup_min, meters, rate, speed)
values ((select v from t where k = 'ver'), (select v from t where k = 'line'), 'CD2', 'Đỏ', 'EXT-SI-02', 0, 10, 210, 10, 1000, 5, 5);
select pg_temp.as_user('Y_SXKH');
insert into x select 'pv', app.kh_day_preview((select v from t where k = 'plan'), pg_temp.today());
select pg_temp.ok(exists (select 1 from x, jsonb_array_elements(x.j -> 'checks') e where x.k = 'pv' and e ->> 'ok' = 'false'
                           and e ->> 't' like 'Máy không chạy được còn việc trong ngày: EXT-SI-02 hỏng, dự kiến chạy lại%'),
  'Lệnh ngày: cảnh báo máy hỏng còn việc trong ngày (phải Xếp lại lịch)');

-- ================================================================ 3. Sửa xong, TP SX xác nhận máy chạy lại (điểm 4)
select pg_temp.as_user('Y_KTTP');
select app.finish_maint_wo((select v from t where k = 'cm'), 'OK', 'Thay dây trục vít', '[]', 'Dây đứt do mỏi');
select pg_temp.ok((select status from master.machines where id = (select v from t where k = 'si2')) = 'IDLE', 'Sửa xong: máy về Chờ việc');
select pg_temp.ok(pg_temp.nt('Y_SXTP', 'Máy chạy lại: EXT-SI-02') = 1, 'Báo TP SX máy chạy lại để xếp lại lịch');
select pg_temp.ok(pg_temp.nt('Y_SXTP', 'Xác nhận máy chạy lại:%') = 1 and pg_temp.nt('Y_KTTP2', 'Phiếu chờ xác nhận:%') = 0,
  'Phiếu xong: báo TP SX xác nhận (không còn báo TP KT/QA)');
select pg_temp.as_user('Y_KTTP2');
select pg_temp.fails($$select app.confirm_maint_wo((select v from t where k = 'cm'))$$, 'TP SX', 'TP KT/QA không xác nhận máy chạy lại');
select pg_temp.as_user('Y_SXTP');
select app.confirm_maint_wo((select v from t where k = 'cm'));
select pg_temp.ok((select confirmed_by = (select id from core.profiles where employee_code = 'Y_SXTP') from mfg.maint_work_orders where id = (select v from t where k = 'cm')),
  'TP SX xác nhận máy chạy lại đạt');

-- ================================================================ 4. M5: giữ chỗ bảo dưỡng
insert into mfg.maint_plans (machine_id, name, kind, level, every_days, stop_minutes, steps)
values ((select v from t where k = 'si2'), 'Vệ sinh trục vít', 'CLEAN', 'MINOR', 30, 90, '{"Tháo đầu","Vệ sinh"}');
insert into t select 'mp', id from mfg.maint_plans where machine_id = (select v from t where k = 'si2') and name = 'Vệ sinh trục vít';
select pg_temp.as_user('Y_SXTP');
select pg_temp.fails($$select app.maint_propose((select v from t where k = 'mp'), null, pg_temp.today() + 20, 'IN_SHIFT')$$,
  'TP Kỹ thuật/QA', 'Chỉ TP KT/QA đề xuất ngày bảo dưỡng');
select pg_temp.as_user('Y_KTTP');
select pg_temp.fails($$select app.maint_propose((select v from t where k = 'mp'), null, pg_temp.today() - 1, 'IN_SHIFT')$$,
  'từ hôm nay', 'Không đề xuất ngày đã qua');
insert into t values ('pm', app.maint_propose((select v from t where k = 'mp'), null, pg_temp.today() + 20, 'IN_SHIFT', 'Đầu ca'));
select pg_temp.ok((select planned_date = pg_temp.today() + 20 and sched_status = 'PROPOSED' and sched_mode = 'IN_SHIFT' and not off_shift and est_minutes = 90
                   from mfg.maint_work_orders where id = (select v from t where k = 'pm')),
  'Đề xuất: tạo phiếu BD từ kế hoạch, ngày + trong ca 90 phút, chờ chốt');
select pg_temp.ok(pg_temp.nt('Y_SXTP', 'Chốt ngày bảo dưỡng EXT-SI-02%') = 1, 'Ngoài vùng khóa: báo TP SX chốt');
select pg_temp.fails($$select app.maint_confirm((select v from t where k = 'pm'), true)$$, 'TP SX', 'TP KT/QA không tự chốt');
select pg_temp.as_user('Y_SXTP');
select pg_temp.fails($$select app.maint_confirm((select v from t where k = 'pm'), false, '')$$, 'lý do', 'Trả lại phải ghi lý do');
select app.maint_confirm((select v from t where k = 'pm'), true);
select pg_temp.ok((select sched_status = 'CONFIRMED' and sched_ok_by is not null from mfg.maint_work_orders where id = (select v from t where k = 'pm')),
  'TP SX chốt ngày bảo dưỡng');
select pg_temp.ok(pg_temp.nt('Y_KTTP', 'Đã chốt ngày bảo dưỡng EXT-SI-02%') = 1, 'Báo TP KT/QA đã chốt');
select pg_temp.ok((select machine_code = 'EXT-SI-02' and sched_status = 'CONFIRMED' and not in_frozen from app.v_kh_maint where id = (select v from t where k = 'pm')),
  'Lịch máy đọc phiếu đã chốt qua app.v_kh_maint (khối giữ chỗ)');
-- Đổi sang hôm nay (vùng khóa): Giám đốc chốt
select pg_temp.as_user('Y_KTTP');
select app.maint_propose(null, (select v from t where k = 'pm'), pg_temp.today(), 'CHANGEOVER');
select pg_temp.ok((select sched_status = 'PROPOSED' and sched_ok_by is null from mfg.maint_work_orders where id = (select v from t where k = 'pm')),
  'Đổi ngày: quay về chờ chốt');
select pg_temp.ok(pg_temp.nt('Y_BGD', 'Chốt ngày bảo dưỡng EXT-SI-02%') = 1, 'Ngày trong vùng khóa: báo Giám đốc chốt');
select pg_temp.as_user('Y_SXKH');
insert into x select 'pv2', app.kh_day_preview((select v from t where k = 'plan'), pg_temp.today());
select pg_temp.ok(exists (select 1 from x, jsonb_array_elements(x.j -> 'checks') e where x.k = 'pv2' and e ->> 'ok' = 'false' and e ->> 't' like 'Bảo dưỡng chưa chốt ngày: EXT-SI-02%'),
  'Lệnh ngày: báo bảo dưỡng chưa chốt ngày');
select pg_temp.as_user('Y_SXTP');
select pg_temp.fails($$select app.maint_confirm((select v from t where k = 'pm'), true)$$, 'Giám đốc chốt', 'Trong vùng khóa TP SX không chốt');
select pg_temp.as_user('Y_BGD');
select app.maint_confirm((select v from t where k = 'pm'), true);
select pg_temp.as_user('Y_SXKH');
insert into x select 'pv3', app.kh_day_preview((select v from t where k = 'plan'), pg_temp.today());
select pg_temp.ok(exists (select 1 from x, jsonb_array_elements(x.j -> 'checks') e where x.k = 'pv3' and e ->> 't' like 'Bảo dưỡng đã chốt trong ngày: EXT-SI-02%gộp lần đổi máy%'),
  'Giám đốc chốt; lệnh ngày hiện bảo dưỡng đã chốt (gộp lần đổi máy)');
-- Người đề xuất không tự chốt (Quản trị giữ cả hai quyền)
select pg_temp.as_user('Y_ADMIN');
select app.maint_propose(null, (select v from t where k = 'pm'), pg_temp.today() + 20, 'OFF_SHIFT');
select pg_temp.fails($$select app.maint_confirm((select v from t where k = 'pm'), true)$$, 'không tự chốt', 'Người đề xuất không tự chốt');
select pg_temp.ok((select off_shift from mfg.maint_work_orders where id = (select v from t where k = 'pm')), 'Ngoài giờ ca: phiếu đánh dấu off_shift (không trừ năng lực)');
select pg_temp.as_user('Y_SXTP');
select app.maint_confirm((select v from t where k = 'pm'), false, 'Ngày đó chạy lô gấp');
select pg_temp.ok((select sched_status is null and sched_note like '%Trả lại: Ngày đó chạy lô gấp%' from mfg.maint_work_orders where id = (select v from t where k = 'pm')),
  'Trả lại: bỏ đề xuất, ghi lý do');

-- ================================================================ 5. M3: dừng máy trong báo cáo ca → nhật ký máy
insert into mfg.shift_reports (work_date, shift_code, machine_code, status, lines, downtime, submitted_at)
values (pg_temp.today() - 1, 'A', 'EXT-SI-02', 'SUBMITTED', '[]',
        '[{"from":"09:00","to":"10:30","min":90,"reason":"DT_BREAKDOWN","src":"MANUAL"},{"from":"14:00","to":"14:20","min":20,"reason":"DT_MATERIAL","src":"MANUAL"},{"from":"","to":"","min":0,"reason":"","src":"MANUAL"}]', now());
insert into t select 'rep', id from mfg.shift_reports where machine_code = 'EXT-SI-02' and work_date = pg_temp.today() - 1 and shift_code = 'A';
select pg_temp.as_user('Y_SXTP');
select app.kh_confirm_report((select v from t where k = 'rep'), null);
select pg_temp.ok((select count(*) from mfg.machine_status_log where shift_report_id = (select v from t where k = 'rep')) = 2
  and exists (select 1 from mfg.machine_status_log where shift_report_id = (select v from t where k = 'rep') and status = 'DOWN' and reason_code = 'DT_BREAKDOWN'
              and ended_at - started_at = interval '90 minutes' and (started_at at time zone 'Asia/Ho_Chi_Minh')::time = '09:00')
  and exists (select 1 from mfg.machine_status_log where shift_report_id = (select v from t where k = 'rep') and status = 'STOP' and reason_code = 'DT_MATERIAL'),
  'Chốt ca: 2 lần dừng vào nhật ký trạng thái máy (hỏng = Hỏng, chờ NVL = Dừng), đúng giờ VN');
select pg_temp.ok((select count(*) from mfg.downtime_events where shift_report_id = (select v from t where k = 'rep')) = 2, 'Ghi downtime_events');
select pg_temp.ok(mfg.status_minutes((select v from t where k = 'si2'), 'DOWN', (pg_temp.today() - 1)::timestamp at time zone 'Asia/Ho_Chi_Minh',
                                     pg_temp.today()::timestamp at time zone 'Asia/Ho_Chi_Minh') = 90,
  'Báo cáo bảo trì tính 90 phút hỏng của ngày đó');
select pg_temp.ok((select count(*) from mfg.maint_work_orders where machine_id = (select v from t where k = 'si2') and wo_type = 'CM' and status = 'OPEN'
                   and title like '%hỏng máy trong báo cáo ca%') = 1,
  'Hỏng trong ca chưa có phiếu: mở phiếu sửa chữa để TP KT/QA ghi nguyên nhân');
select pg_temp.ok(pg_temp.nt('Y_KTTP', 'Hỏng máy trong ca: EXT-SI-02') = 1, 'Báo TP KT/QA');
select pg_temp.ok(exists (select 1 from app.machine_history((select v from t where k = 'si2'), null, null, null, 200)
                          where kind = 'STATUS' and sub = 'DOWN' and detail like '%Báo cáo ca A%'),
  'Lịch sử vận hành hiện lần hỏng từ báo cáo ca');
-- Mở lại, chốt lại: không ghi trùng, không mở thêm phiếu
update mfg.shift_reports set status = 'SUBMITTED' where id = (select v from t where k = 'rep');
select app.kh_confirm_report((select v from t where k = 'rep'), null);
select pg_temp.ok((select count(*) from mfg.machine_status_log where shift_report_id = (select v from t where k = 'rep')) = 2
  and (select count(*) from mfg.maint_work_orders where machine_id = (select v from t where k = 'si2') and wo_type = 'CM' and status = 'OPEN') = 1,
  'Chốt lại ca: không ghi trùng nhật ký, không mở thêm phiếu');

-- ================================================================ 6. Cảnh báo đỏ lô trễ hạn
select pg_temp.as_user('Y_VH');
select pg_temp.fails($$select app.kh_late_alert((select v from t where k = 'plan'), 'x', array['D01'])$$, 'Quản lý SX', 'Chỉ Quản lý SX gửi cảnh báo trễ');
select pg_temp.as_user('Y_SXTP');
select app.kh_late_alert((select v from t where k = 'plan'), 'Xếp lại lịch (EXT-SI-02 hỏng)', array['D01 PFR-2C-1P5 xong 05/11, hạn 03/11']);
select pg_temp.ok(pg_temp.nt('Y_BGD', 'Cảnh báo đỏ: 1 lô trễ hạn giao (KH-MA1)') = 1, 'Lô trễ hạn sau khi xếp lại: cảnh báo đỏ Giám đốc');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
