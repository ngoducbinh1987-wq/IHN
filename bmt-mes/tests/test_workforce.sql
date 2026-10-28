-- Kiểm thử migration 20261026005000_workforce_availability: máy Dừng/Hỏng bắt buộc giờ chạy lại, tỷ lệ xếp lịch 90 %,
-- nhân sự xưởng (người, lịch vắng, kiêm nhiệm tạm, tổ đóng gói), thông số người đứng máy, tỷ lệ xếp lịch riêng theo tỷ lệ hỏng 90 ngày,
-- lưu đoạn người có mặt trên lịch máy, kiểm tra năng lực. Chạy được bằng psql hoặc MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
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
update core.profiles set status = 'LOCKED' where (employee_code is null or employee_code !~ '^W_') and status = 'ACTIVE';
with u(code) as (values ('W_KTTP'),('W_SXTP'),('W_SXKH'),('W_BGD'),('W_VH'),('W_TT'),('W_LINK')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('W_KTTP','KT_TP'),('W_SXTP','SX_TP'),('W_SXKH','SX_KH'),('W_BGD','BGD'),
  ('W_VH','VAN_HANH'),('W_TT','TO_TRUONG')) u(code, role) on u.code = p.employee_code;
insert into t select 'bun', id from master.machines where code = 'BUN-01';
insert into t select 'link', id from core.profiles where employee_code = 'W_LINK';
update master.machines set status = 'IDLE', status_eta = null where code = 'BUN-01';
update mfg.maint_work_orders set status = 'CANCELLED' where machine_id = (select v from t where k = 'bun') and status in ('OPEN','IN_PROGRESS');
-- Thông số về mặc định trong giao dịch (dữ liệu thật có thể đã sửa)
update master.planning_config set start_min = 20, bobbin_min = 5, watch_max = 6, pack_crew = 2, pack_one_pct = 50,
  avail_learn = true, avail_days = 90, avail_min_days = 30, avail_floor_pct = 60, fill_pct = 90 where id = 1;
delete from plan.operator_absences where true;
delete from plan.operator_covers where true;
delete from plan.crew_days where true;

-- ================================================================ 1. Tỷ lệ xếp lịch chung 90 %, thông số người đứng máy trong cấu hình lịch
select pg_temp.ok((select fill_pct = 90 from master.planning_config where id = 1), 'Tỷ lệ xếp lịch chung 90 %');
select pg_temp.ok(exists (select 1 from master.planning_param_log where item = 'Người đứng máy, máy dừng, bảo dưỡng'), 'Nhật ký: thuật toán mới làm lịch đang dùng cần xếp lại');
select pg_temp.as_user('W_SXTP');
select pg_temp.ok(pg_temp.api_val($q$select concat_ws('|', start_min, bobbin_min, watch_max, pack_crew, pack_one_pct, jsonb_typeof(absences), jsonb_typeof(covers), jsonb_typeof(crews), jsonb_typeof(avail), jsonb_typeof(maint_plans)) from app.v_kh_config$q$)
  = '20|5|6|2|50|array|array|array|object|array', 'Lịch máy đọc thông số người đứng máy, lịch vắng, kiêm nhiệm, tổ đóng gói, tỷ lệ riêng, bảo dưỡng');
select pg_temp.ok(pg_temp.api_val($q$select count(*)::text from app.v_kh_slots where attend is not null or crew is not null$q$) is not null, 'Lịch máy lưu được đoạn người có mặt (attend) và số người đóng gói (crew)');

-- ================================================================ 2. Đợt 1: Dừng / Hỏng bắt buộc giờ chạy lại; lý do hỏng → Hỏng
select pg_temp.as_user('W_VH');
select pg_temp.fails($$select app.set_machine_status((select v from t where k = 'bun'), 'STOP', 'DT_MATERIAL', 'x', now() + interval '2 hours')$$,
  'TP Kỹ thuật/QA', 'Công nhân không đổi trạng thái máy');
select pg_temp.as_user('W_KTTP');
select pg_temp.fails($$select app.set_machine_status((select v from t where k = 'bun'), 'STOP', 'DT_MATERIAL', 'Hết đồng')$$,
  'giờ dự kiến chạy lại', 'Báo Dừng bắt buộc giờ dự kiến chạy lại');
select pg_temp.fails($$select app.set_machine_status((select v from t where k = 'bun'), 'STOP', 'DT_MATERIAL', 'x', now() - interval '1 hour')$$,
  'sau bây giờ', 'Giờ chạy lại của máy Dừng phải sau bây giờ');
select app.set_machine_status((select v from t where k = 'bun'), 'STOP', 'DT_MATERIAL', 'Chờ đồng', now() + interval '3 hours');
select pg_temp.ok((select status = 'STOP' and status_eta > now() + interval '170 minutes' from master.machines where id = (select v from t where k = 'bun')),
  'Máy Dừng lưu giờ dự kiến chạy lại (lịch máy chặn đến giờ này)');
select pg_temp.ok(pg_temp.nt('W_SXTP', 'Máy không chạy được: BUN-01') = 1 and pg_temp.nt('W_SXKH', 'Máy không chạy được: BUN-01') = 1,
  'Máy Dừng: báo TP SX, Kế hoạch SX xếp lại lịch');
select pg_temp.ok((select status = 'STOP' and status_eta is not null from app.v_kh_machines where code = 'BUN-01'), 'Lịch máy đọc trạng thái Dừng + giờ chạy lại');
select app.set_machine_status((select v from t where k = 'bun'), 'STOP', 'DT_BREAKDOWN', 'Kẹt trục', now() + interval '1 day');
select pg_temp.ok((select status = 'DOWN' from master.machines where id = (select v from t where k = 'bun')), 'Dừng với lý do Hỏng máy: MES ghi trạng thái Hỏng');
select pg_temp.ok((select count(*) from mfg.maint_work_orders where machine_id = (select v from t where k = 'bun') and wo_type = 'CM' and status = 'OPEN') = 1,
  'Hỏng: mở phiếu sửa chữa');
select app.set_machine_status((select v from t where k = 'bun'), 'IDLE', null, 'Đã sửa', null);
select pg_temp.ok(pg_temp.nt('W_SXTP', 'Máy chạy lại: BUN-01') = 1, 'Máy chạy lại: báo TP SX xếp lại lịch để dùng lại máy');
-- Kiểm tra năng lực: máy Dừng trừ năng lực như máy hỏng
select app.set_machine_status((select v from t where k = 'bun'), 'STOP', 'DT_MATERIAL', 'Chờ đồng', now() + interval '2 days');
select pg_temp.as_user('W_SXTP');
select pg_temp.ok((select count(*) from jsonb_array_elements(app.shared_overview() -> 'machines' -> 'down') d where d ->> 'code' = 'BUN-01' and d ->> 'status' = 'STOP') = 1,
  'Tổng quan (thông tin chung): máy Dừng nằm trong danh sách máy không chạy');
select pg_temp.ok(position($x$('DOWN','STOP','MAINT','OFF')$x$ in pg_get_functiondef('app.kh_day_preview(uuid, date)'::regprocedure)) > 0,
  'Kiểm tra lệnh ngày: máy Dừng còn việc trong ngày bị cảnh báo');
insert into x select 'cap', app.check_capacity(null, pg_temp.today(), pg_temp.today() + 13, 1, 0, '[]');
select pg_temp.ok((select (m ->> 'down_min')::numeric > 0 and m ->> 'note' like 'Dừng%' from x, jsonb_array_elements(j -> 'ops') o, jsonb_array_elements(o -> 'machines') m
  where x.k = 'cap' and m ->> 'code' = 'BUN-01'), 'Kiểm tra năng lực: máy Dừng trừ giờ đến giờ chạy lại');
select pg_temp.as_user('W_KTTP');
select app.set_machine_status((select v from t where k = 'bun'), 'IDLE', null, 'Có đồng', null);

-- ================================================================ 3. Nhân sự xưởng: thêm / sửa / ngừng người
select pg_temp.as_user('W_KTTP');
select pg_temp.fails($$select app.kh_save_operator(null, 'Nguyễn Văn Thử', 'Đóng gói')$$, 'Chỉ TP SX', 'TP KT/QA không quản lý nhân sự xưởng');
select pg_temp.as_user('W_SXTP');
select pg_temp.fails($$select app.kh_save_operator(null, ' ', 'Đóng gói')$$, 'họ tên', 'Bắt buộc họ tên');
select pg_temp.fails($$select app.kh_save_operator(null, 'Nguyễn Văn Thử', '')$$, 'công việc', 'Bắt buộc công việc chính');
insert into t select 'nv', null;
update t set v = null where k = 'nv';
insert into x select 'nv', to_jsonb(app.kh_save_operator(null, 'Nguyễn Văn Thử', 'Đóng gói', 'Vận chuyển bobin', null, (select v from t where k = 'link'), 'Tuyển thêm'));
select pg_temp.ok((select j #>> '{}' ~ '^NV[0-9]+$' from x where k = 'nv')
  and (select full_name = 'Nguyễn Văn Thử' and active and profile_id = (select v from t where k = 'link') from master.operators where code = (select j #>> '{}' from x where k = 'nv')),
  'TP SX thêm người: MES tự cấp mã NV kế tiếp, liên kết tài khoản');
select pg_temp.fails($$select app.kh_save_operator(null, 'Người khác', 'Đóng gói', null, null, (select v from t where k = 'link'))$$, 'đã liên kết', 'Một tài khoản chỉ liên kết một người');
select pg_temp.ok(pg_temp.api_val($q$select count(*)::text from app.v_kh_operators where full_name = 'Nguyễn Văn Thử'$q$) = '1', 'Người mới có trong danh sách xếp lịch');
select pg_temp.fails($$select app.kh_set_operator_active((select j #>> '{}' from x where k = 'nv'), false, ' ')$$, 'lý do', 'Ngừng người bắt buộc lý do');
select app.kh_set_operator_active((select j #>> '{}' from x where k = 'nv'), false, 'Nghỉ việc');
select pg_temp.ok(pg_temp.api_val($q$select count(*)::text from app.v_kh_operators where full_name = 'Nguyễn Văn Thử'$q$) = '0'
  and pg_temp.api_val($q$select (not active and stopped_at is not null)::text from app.v_operators_all where full_name = 'Nguyễn Văn Thử'$q$) = 'true',
  'Người ngừng làm: không xếp lịch, vẫn giữ lịch sử');
select app.kh_set_operator_active((select j #>> '{}' from x where k = 'nv'), true, 'Đi làm lại');

-- ================================================================ 4. Lịch vắng
select pg_temp.fails($$select app.kh_save_absence(null, 'NV5', pg_temp.wday(2), pg_temp.wday(2) + 1, 'AM', 'PHEP')$$, 'một ngày', 'Vắng nửa ca chỉ cho một ngày');
select pg_temp.fails($$select app.kh_save_absence(null, 'NV5', pg_temp.wday(3), pg_temp.wday(2), 'FULL', 'PHEP')$$, 'sau từ ngày', 'Đến ngày phải sau từ ngày');
select pg_temp.fails($$select app.kh_save_absence(null, 'NV5', pg_temp.wday(2), null, 'FULL', 'XX')$$, 'loại vắng', 'Loại vắng không hợp lệ');
insert into x select 'ab1', to_jsonb(app.kh_save_absence(null, 'NV5', pg_temp.wday(2), pg_temp.wday(2) + 2, 'FULL', 'PHEP', 'Về quê'));
select pg_temp.ok((select count(*) from plan.operator_absences where operator_code = 'NV5') = 1, 'TP SX nhập NV5 nghỉ phép 3 ngày');
select pg_temp.fails($$select app.kh_save_absence(null, 'NV5', pg_temp.wday(2) + 1, null, 'PM', 'OM')$$, 'trùng ngày', 'Không nhập trùng ngày vắng');
select app.kh_save_absence(null, 'NV2', pg_temp.wday(1), null, 'AM', 'RIENG', 'Đi khám');
select app.kh_save_absence(null, 'NV2', pg_temp.wday(1), null, 'PM', 'RIENG', 'Đi khám');
select pg_temp.ok((select count(*) from plan.operator_absences where operator_code = 'NV2') = 2, 'Nửa đầu ca và nửa sau ca cùng một ngày là hai lần vắng riêng');
select pg_temp.ok(pg_temp.api_val($q$select count(*)::text from app.v_kh_config, jsonb_array_elements(absences) a where a ->> 'code' = 'NV5'$q$) = '1', 'Lịch máy đọc lịch vắng');
select pg_temp.ok(exists (select 1 from master.planning_param_log where section = 'Lịch vắng' and item like 'NV5%'), 'Lịch vắng ghi nhật ký (lịch máy cần xếp lại)');
select pg_temp.fails($$select app.kh_delete_absence((select (j #>> '{}')::uuid from x where k = 'ab1'), '')$$, 'lý do', 'Bỏ lịch vắng bắt buộc lý do');
select app.kh_delete_absence((select (j #>> '{}')::uuid from x where k = 'ab1'), 'Đổi ngày');
select app.kh_save_absence(null, 'NV5', pg_temp.wday(2), pg_temp.wday(2) + 2, 'FULL', 'PHEP', 'Về quê');
select pg_temp.as_user('W_VH');
select pg_temp.fails($$select app.kh_save_absence(null, 'NV1', pg_temp.wday(5), null, 'FULL', 'PHEP')$$, 'Chỉ TP SX', 'Công nhân không nhập lịch vắng');

-- ================================================================ 5. Kiêm nhiệm tạm
-- từ migration 5400 mọi công nhân đứng chính mọi máy: bỏ tay nghề của NV2, NV3 ở line silicone để thử kiêm nhiệm
delete from master.operator_skills where operator_code in ('NV2', 'NV3') and machine_code like 'EXT-SI-%';
select pg_temp.as_user('W_SXKH');
select pg_temp.fails($$select app.kh_save_cover(null, 'NV1', 'EXT-SI-01', pg_temp.wday(2), null, 'NV5 nghỉ')$$, 'đứng chính', 'Người đã đứng chính máy không cần kiêm nhiệm');
select pg_temp.fails($$select app.kh_save_cover(null, 'NV2', 'EXT-SI-01', pg_temp.wday(2), null, ' ')$$, 'lý do', 'Kiêm nhiệm bắt buộc lý do');
select pg_temp.fails($$select app.kh_save_cover(null, 'NV2', 'GAU-01', pg_temp.wday(2), null, 'x')$$, 'không phải dây chuyền', 'Chỉ kiêm nhiệm dây chuyền xếp lịch');
select pg_temp.fails($$select app.kh_save_cover(null, 'NV2', 'EXT-SI-01', pg_temp.today() - 5, pg_temp.today() - 1, 'x')$$, 'đã qua', 'Không phân công cho ngày đã qua');
select pg_temp.fails($$select app.kh_save_cover(null, 'NV2', 'EXT-SI-01', pg_temp.wday(2), pg_temp.wday(2) + 120, 'x')$$, '3 tháng', 'Kiêm nhiệm tạm tối đa 3 tháng');
insert into x select 'cv', to_jsonb(app.kh_save_cover(null, 'NV3', 'EXT-SI-01', pg_temp.wday(2), pg_temp.wday(2) + 2, 'NV5 nghỉ phép'));
select pg_temp.ok(pg_temp.api_val($q$select skill from app.v_kh_covers where operator_code = 'NV3' and machine_code = 'EXT-SI-01'$q$) = 'NONE',
  'QLSX phân công người chưa có tay nghề đứng máy: ghi kiêm nhiệm tạm');
select pg_temp.ok(pg_temp.nt('W_KTTP', 'Kiêm nhiệm tạm: NV3 đứng EXT-SI-01') = 1, 'Báo TP KT/QA kèm người kiêm nhiệm chưa có tay nghề');
select pg_temp.fails($$select app.kh_save_cover(null, 'NV3', 'EXT-SI-01', pg_temp.wday(3), null, 'x')$$, 'trùng ngày', 'Không phân công trùng ngày');
select pg_temp.ok(pg_temp.api_val($q$select count(*)::text from app.v_kh_config, jsonb_array_elements(covers) c where c ->> 'code' = 'NV3' and c ->> 'machine' = 'EXT-SI-01'$q$) = '1',
  'Lịch máy đọc kiêm nhiệm tạm');
select app.kh_delete_cover((select (j #>> '{}')::uuid from x where k = 'cv'), 'NV5 đi làm lại');
select pg_temp.ok((select count(*) from plan.operator_covers) = 0, 'Bỏ phân công kiêm nhiệm');
select app.kh_save_cover(null, 'NV3', 'EXT-SI-01', pg_temp.wday(2), pg_temp.wday(2) + 2, 'NV5 nghỉ phép');

-- ================================================================ 6. Tổ đóng gói theo ngày
select pg_temp.as_user('W_SXTP');
select pg_temp.fails($$select app.kh_set_crew(pg_temp.wday(1), 'BUN-01', 1)$$, 'không phải máy đóng gói', 'Tổ đóng gói chỉ cho máy đóng gói');
select pg_temp.fails($$select app.kh_set_crew(pg_temp.wday(1), 'PACK-01', 3)$$, '1 hoặc 2', 'Tổ đóng gói 1 hoặc 2 người');
select pg_temp.fails($$select app.kh_set_crew(pg_temp.wday(1), 'PACK-01', 1, array['NV3','NV4'])$$, 'tối đa', 'Chọn người không quá số người của tổ');
select pg_temp.fails($$select app.kh_set_crew(pg_temp.wday(2), 'PACK-01', 2, array['NV5','NV4'])$$, 'vắng', 'Không chọn người vắng vào tổ đóng gói');
select pg_temp.fails($$select app.kh_set_crew(pg_temp.today() - 1, 'PACK-01', 1)$$, 'hôm nay', 'Không đặt tổ cho ngày đã qua');
select app.kh_set_crew(pg_temp.wday(1), 'PACK-01', 1, array['NV4'], 'Sản lượng ít');
select pg_temp.ok((select crew = 1 and members = array['NV4'] from plan.crew_days where machine_code = 'PACK-01' and work_date = pg_temp.wday(1)), 'TP SX đặt tổ đóng gói 1 người (NV4) đầu ca');
select pg_temp.ok(exists (select 1 from master.planning_param_log where section = 'Tổ đóng gói' and new_value like '1 người (NV4)%tốc độ 50 %%'), 'Tổ đóng gói ghi nhật ký, nêu tốc độ 1 người');
select app.kh_set_crew(pg_temp.wday(1), 'PACK-01', null);
select pg_temp.ok((select count(*) from plan.crew_days) = 0, 'Bỏ tổ đặt riêng: về mặc định');
select app.kh_set_crew(pg_temp.wday(1), 'PACK-01', 2);

-- ================================================================ 7. Thông số người đứng máy
select pg_temp.fails($$select app.kh_save_people('{"start_min": 25}', 'thử')$$, 'Chỉ Giám đốc hoặc TP KT/QA', 'TP SX không sửa thông số người đứng máy');
select pg_temp.as_user('W_KTTP');
select pg_temp.fails($$select app.kh_save_people('{"avail_days": 60}', 'thử')$$, 'Chỉ Giám đốc', 'TP KT/QA không sửa tỷ lệ xếp lịch riêng');
select pg_temp.fails($$select app.kh_save_people('{"start_min": 300}', 'thử')$$, 'từ 0 đến 240', 'Phút khởi động ngoài khoảng bị chặn');
select pg_temp.fails($$select app.kh_save_people('{"pack_crew": 3}', 'thử')$$, 'từ 1 đến 2', 'Tổ đóng gói mặc định 1–2 người');
select pg_temp.fails($$select app.kh_save_people('{"bobbin_min": 2.5}', 'thử')$$, 'số nguyên', 'Phút phải là số nguyên');
select pg_temp.fails($$select app.kh_save_people('{"start_min": 20}', 'thử')$$, 'Không có thay đổi', 'Không đổi gì thì báo');
select pg_temp.ok(app.kh_save_people('{"start_min": 25, "bobbin_min": 4}', 'Bấm giờ thực tế') = 2, 'TP KT/QA sửa phút khởi động, thay bobin');
select pg_temp.ok((select start_min = 25 and bobbin_min = 4 from master.planning_config where id = 1), 'Thông số đã lưu');
select pg_temp.as_user('W_BGD');
select pg_temp.fails($$select app.kh_save_people('{"avail_min_days": 120}', 'thử')$$, 'không lớn hơn', 'Ngày tối thiểu không lớn hơn số ngày tính');
select pg_temp.ok(app.kh_save_people('{"watch_max": 5, "pack_one_pct": 60}', 'Giám đốc chỉnh') = 2, 'Giám đốc sửa ngưỡng cảnh báo, tốc độ đóng gói 1 người');

-- ================================================================ 8. Tỷ lệ xếp lịch riêng = 90 % − tỷ lệ dừng do hỏng 90 ngày
reset role;
-- Máy bện theo dõi từ 50 ngày trước; một lần hỏng phủ trọn giờ ca của một ngày làm việc ~20 ngày trước, một lần đang hỏng (không tính)
insert into mfg.machine_status_log (machine_id, status, started_at, ended_at, source, note)
values ((select v from t where k = 'bun'), 'IDLE', now() - interval '50 days', now() - interval '49 days', 'HE_THONG', 'thử');
insert into x select 'D', to_jsonb(pg_temp.wday(-20));
insert into mfg.downtime_events (machine_id, started_at, ended_at, reason_code, source, note)
select (select v from t where k = 'bun'),
       ((x.j #>> '{}')::date + s.start_time - interval '1 hour') at time zone 'Asia/Ho_Chi_Minh',
       ((x.j #>> '{}')::date + s.end_time + interval '1 hour') at time zone 'Asia/Ho_Chi_Minh', 'DT_BREAKDOWN', 'MANUAL', 'Hỏng thử'
from x, master.shifts s where x.k = 'D' and s.code = 'A';
insert into mfg.downtime_events (machine_id, started_at, ended_at, reason_code, source, note)
values ((select v from t where k = 'bun'), now() - interval '1 hour', null, 'DT_BREAKDOWN', 'MANUAL', 'Đang hỏng');
select plan.calc_machine_avail();
insert into x select 'exp', jsonb_build_object(
  'days', mfg.workdays(pg_temp.today() - 50, pg_temp.today() - 1),
  'run', (select (extract(epoch from (end_time - start_time)) / 60 - break_min) / 60 from master.shifts where code = 'A'));
select pg_temp.ok((select a.tracked_days = (e.j ->> 'days')::int and abs(a.down_hours - (e.j ->> 'run')::numeric) < 0.05 and a.events = 1 and a.enough
  from master.machine_avail a, x e where a.machine_code = 'BUN-01' and e.k = 'exp'),
  'Giờ hỏng = trọn giờ ca một ngày (trừ giờ nghỉ), lần đang hỏng không tính, đủ ≥ 30 ngày dữ liệu');
select pg_temp.ok((select abs(a.down_pct - round(100.0 / (e.j ->> 'days')::int, 2)) < 0.02 and abs(a.fill_pct - round(90 - a.down_pct, 1)) < 0.01
  from master.machine_avail a, x e where a.machine_code = 'BUN-01' and e.k = 'exp'),
  'Tỷ lệ xếp lịch riêng = 90 % − tỷ lệ hỏng');
select pg_temp.ok(abs(plan.avail_factor('BUN-01') - (select fill_pct / 90 from master.machine_avail where machine_code = 'BUN-01')) < 1e-6 and plan.avail_factor('TWS-01') = 1,
  'Hệ số năng lực riêng của máy hỏng < 1, máy không hỏng = 1');
update master.planning_config set fill_pct = 80 where id = 1;
select pg_temp.ok(abs(plan.avail_factor('BUN-01') - round(80 - (select down_pct from master.machine_avail where machine_code = 'BUN-01'), 1) / 80) < 1e-6,
  'Giám đốc đổi tỷ lệ chung: tỷ lệ riêng tính theo tỷ lệ chung mới ngay (không chờ lần tính đêm)');
update master.planning_config set fill_pct = 90 where id = 1;
select pg_temp.as_user('W_SXTP');
select pg_temp.ok(pg_temp.api_val($q$select (avail ? 'BUN-01')::text from app.v_kh_config$q$) = 'true', 'Lịch máy đọc tỷ lệ riêng của máy bện');
delete from x where k = 'cap';
insert into x select 'cap', app.check_capacity(null, pg_temp.today(), pg_temp.today() + 13, 1, 0, '[]');
select pg_temp.ok((select (m ->> 'gross_min')::numeric < (t2 ->> 'gross_min')::numeric
  from x, jsonb_array_elements(j -> 'ops') o, jsonb_array_elements(o -> 'machines') m, jsonb_array_elements(j -> 'ops') o2, jsonb_array_elements(o2 -> 'machines') t2
  where x.k = 'cap' and m ->> 'code' = 'BUN-01' and t2 ->> 'code' = 'TWS-01'), 'Kiểm tra năng lực trừ giờ theo tỷ lệ riêng của máy hỏng nhiều');
select pg_temp.ok(pg_temp.api_val($q$select count(*)::text from app.avail_events('BUN-01') where note in ('Hỏng thử','Đang hỏng')$q$) = '2' and pg_temp.api_val($q$select count(*)::text from app.avail_events('BUN-01') where note = 'Hỏng thử' and not excluded$q$) = '1', 'Xem các lần hỏng trong khoảng tính');
select pg_temp.fails($$select app.avail_exclude((select id from mfg.downtime_events where note = 'Hỏng thử'), true, 'thử')$$, 'Chỉ Giám đốc', 'TP SX không bỏ qua lần hỏng');
select pg_temp.as_user('W_BGD');
select pg_temp.fails($$select app.avail_exclude((select id from mfg.downtime_events where note = 'Hỏng thử'), true, ' ')$$, 'lý do', 'Bỏ qua lần hỏng bắt buộc lý do');
select app.avail_exclude((select id from mfg.downtime_events where note = 'Hỏng thử'), true, 'Đã thay hẳn hộp số');
select pg_temp.ok((select down_hours = 0 and fill_pct = 90 and events = 0 from master.machine_avail where machine_code = 'BUN-01'), 'Giám đốc bỏ qua một lần hỏng: tính lại tỷ lệ riêng ngay');
select app.avail_exclude((select id from mfg.downtime_events where note = 'Hỏng thử'), false, 'Tính lại');
-- Hỏng nhiều: chạm sàn 60 %, báo Giám đốc + TP KT/QA
reset role;
insert into mfg.downtime_events (machine_id, started_at, ended_at, reason_code, source, note)
values ((select v from t where k = 'bun'), now() - interval '45 days', now() - interval '3 days', 'DT_BREAKDOWN', 'MANUAL', 'Hỏng dài');
select plan.calc_machine_avail();
select pg_temp.ok((select fill_pct = 60 and below_floor from master.machine_avail where machine_code = 'BUN-01'), 'Hỏng nhiều: tỷ lệ riêng không thấp hơn sàn 60 %');
select pg_temp.ok(pg_temp.nt('W_BGD', 'Máy hỏng nhiều: BUN-01') = 1 and pg_temp.nt('W_KTTP', 'Máy hỏng nhiều: BUN-01') = 1, 'Chạm sàn: báo Giám đốc và TP KT/QA');
-- Chưa đủ 30 ngày dữ liệu: dùng tỷ lệ chung
update master.planning_config set avail_min_days = 365, avail_days = 365 where id = 1;
select plan.calc_machine_avail();
select pg_temp.ok((select not enough and fill_pct = 90 from master.machine_avail where machine_code = 'BUN-01') and plan.avail_factor('BUN-01') = 1,
  'Chưa đủ ngày dữ liệu: dùng tỷ lệ chung 90 %');

-- ================================================================ 9. Quyền: không ghi thẳng bảng, không gọi hàm nội bộ; mục menu
select pg_temp.as_user('W_SXTP');
select pg_temp.api_fails($q$insert into plan.operator_absences (operator_code, date_from, date_to) values ('NV1', current_date, current_date)$q$, 'permission denied', 'Không ghi thẳng lịch vắng qua API');
select pg_temp.api_fails($q$insert into plan.operator_covers (operator_code, machine_code, date_from, date_to, reason) values ('NV1', 'BUN-01', current_date, current_date, 'x')$q$, 'permission denied', 'Không ghi thẳng kiêm nhiệm qua API');
select pg_temp.api_fails($q$update master.machine_avail set fill_pct = 99 where true$q$, 'permission denied', 'Không sửa thẳng tỷ lệ riêng qua API');
select pg_temp.api_fails($q$select plan.calc_machine_avail()$q$, 'permission denied', 'Người dùng không gọi thẳng hàm tính tỷ lệ riêng');
select pg_temp.api_fails($q$update master.operators set active = false where code = 'NV1'$q$, 'permission denied', 'Không ghi thẳng danh sách người qua API');
select pg_temp.ok(exists (select 1 from core.pages where key = 'nhan-su-xuong' and path = '/nhan-su-xuong')
  and (select count(*) from core.role_pages where page_key = 'nhan-su-xuong' and role_code in ('BGD','SX_TP','SX_KH','TO_TRUONG','KT_TP')) = 5,
  'Mục menu Nhân sự xưởng cho Giám đốc, SX, tổ trưởng, TP KT/QA');

do $$ declare v_n int; v_s text; begin
  select count(*), string_agg(r.n || '. ' || r.msg, E'\n' order by r.n) into v_n, v_s from r;
  raise exception 'KET_QUA_OK % kiểm tra đạt:%', v_n, E'\n' || v_s;
end $$;
