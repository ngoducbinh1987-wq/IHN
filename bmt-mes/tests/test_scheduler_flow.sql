-- Kiểm thử migration 20261026004700_scheduler_flow: thông số dòng chảy, sửa thông số theo vai trò, đề xuất / duyệt / kết thúc tăng ca.
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
grant all on r to authenticated;
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
create function pg_temp.blocked(p_sql text, p_pattern text, p_msg text) returns void language plpgsql as $$
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
set client_min_messages = notice;

-- Tạm ngưng tài khoản thật trong giao dịch; dùng người thử F_*
update core.profiles set status = 'INACTIVE' where employee_code not like 'F\_%' and status = 'ACTIVE';
with u(code) as (values ('F_BGD'), ('F_SXTP'), ('F_KTTP'), ('F_SXKH'), ('F_ADM')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('F_BGD','BGD'),('F_SXTP','SX_TP'),('F_KTTP','KT_TP'),('F_SXKH','SX_KH'),('F_ADM','ADMIN')) u(code, role) on u.code = p.employee_code;
-- Đưa thông số về mặc định trong giao dịch (dữ liệu thật có thể đã sửa)
update master.planning_config set qc_min = 120, qc_learn = true, pot_life_h = 8, mix_batch_kg = 25, mix_early_max_h = 4, ot_max_min = 240, ot_month_h = 40,
  size_large_mm2 = 2.5, plc_min_run = 120, pick_window_min = null, extra_min = '{}', mix_early_h = 0, ot_from = null, ot_until = null, ot_request_id = null,
  unit_m = '{"CD0":5000,"CD1":10000,"CD2":10000,"CD3":5000,"CD5":5000,"CD6":500}', safety_min = '{}' where id = 1;
create temp table m1 as select code from master.machines where active order by code limit 2;
grant select on m1 to authenticated;
create temp table today as select (now() at time zone 'Asia/Ho_Chi_Minh')::date as d;
grant select on today to authenticated;

-- ================================================================ 1. Thông số trong app.v_kh_config
select pg_temp.as_user('F_SXTP');
select pg_temp.ok(pg_temp.api_val($q$select concat_ws('|', qc_min, qc_learn, pot_life_h, mix_batch_kg, mix_early_max_h, ot_max_min, ot_month_h, size_large_mm2, plc_min_run, coalesce(pick_window_min::text, 'null'))
  from app.v_kh_config$q$) = '120|t|8|25|4|240|40|2.5|120|null', 'Quản lý SX đọc được thông số dòng chảy mặc định');
select pg_temp.ok(pg_temp.api_val($q$select (unit_m ->> 'CD1') || '/' || (unit_m ->> 'CD6') from app.v_kh_config$q$) = '10000/500', 'Mét một bobin mặc định (bện 10.000, đóng gói 500)');
select pg_temp.ok(pg_temp.api_val($q$select extra_min_now::text || '|' || mix_early_h_now from app.v_kh_config$q$) = '{}|0', 'Chưa có tăng ca đang áp dụng');
select pg_temp.ok(pg_temp.api_val($q$select (qc_learned ? 'n')::text from app.v_kh_config$q$) = 'true', 'Có số liệu QC tự học (trung vị, số mẫu)');

-- ================================================================ 2. Sửa thông số theo vai trò
select pg_temp.blocked($q$select app.kh_save_flow('{"pot_life_h": 6}', 'thử')$q$, 'Chỉ Giám đốc hoặc TP KT/QA', 'Quản lý SX không sửa thông số dòng chảy');
select pg_temp.as_user('F_KTTP');
select pg_temp.blocked($q$select app.kh_save_flow('{"ot_max_min": 180}', 'thử')$q$, 'Chỉ Giám đốc được sửa', 'TP KT/QA không sửa giới hạn tăng ca');
select pg_temp.blocked($q$select app.kh_save_flow('{"pot_life_h": 6}', ' ')$q$, 'lý do', 'Bắt buộc lý do');
select pg_temp.blocked($q$select app.kh_save_flow('{"pot_life_h": 100}', 'thử')$q$, 'ngoài khoảng', 'Hạn dùng silicone quá 72 giờ bị từ chối');
select pg_temp.blocked($q$select app.kh_save_flow('{"unit_m": {"CD9": 100}}', 'thử')$q$, 'không hợp lệ', 'Mét/bobin công đoạn lạ bị từ chối');
select pg_temp.blocked($q$select app.kh_save_flow('{"unit_m": {"CD1": -5}}', 'thử')$q$, 'không hợp lệ', 'Mét/bobin âm bị từ chối');
select pg_temp.blocked($q$select app.kh_save_flow('{"safety_min": {"CD1": 2000}}', 'thử')$q$, '0 đến 1440', 'Đệm an toàn quá 1440 phút bị từ chối');
select pg_temp.blocked($q$select app.kh_save_flow('{"abc": 1}', 'thử')$q$, 'không hợp lệ', 'Thông số lạ bị từ chối');
select pg_temp.blocked($q$select app.kh_save_flow('{"pot_life_h": 8}', 'thử')$q$, 'Không có thay đổi', 'Không đổi gì thì báo');
select pg_temp.ok(pg_temp.api_val($q$select app.kh_save_flow('{"pot_life_h": 6, "unit_m": {"CD1": 12000}, "qc_min": 90, "safety_min": {"CD1": 60}}', 'Đo thực tế tuần 1')::text$q$) = '4',
  'TP KT/QA sửa hạn dùng, mét/bobin bện, thời gian QC, đệm bện (4 thông số)');
select pg_temp.ok((select pot_life_h = 6 and qc_min = 90 and (unit_m ->> 'CD1')::int = 12000 and (unit_m ->> 'CD2')::int = 10000 and (safety_min ->> 'CD1')::int = 60
  from master.planning_config where id = 1), 'Lưu đúng; mét/bobin các công đoạn khác giữ nguyên');
select pg_temp.ok((select count(*) from master.planning_param_log where section = 'Tham số xếp lịch' and reason = 'Đo thực tế tuần 1') = 4, 'Nhật ký ghi 4 thay đổi (lịch hiện "cần xếp lại")');
select pg_temp.blocked($q$select app.kh_save_flow('{"unit_m": {"CD1": 12000, "CD2": 10000}}', 'thử')$q$, 'Không có thay đổi', 'Gửi lại mét/bobin y như cũ (gửi một phần) không tính là thay đổi');
select pg_temp.as_user('F_BGD');
select pg_temp.blocked($q$select app.kh_save_flow('{"ot_month_h": 50}', 'thử')$q$, 'ngoài khoảng', 'Tăng ca quá 40 giờ/tháng bị từ chối (luật)');
select pg_temp.blocked($q$select app.kh_save_flow('{"ot_max_min": 300}', 'thử')$q$, 'ngoài khoảng', 'Tăng ca quá 4 giờ/ngày bị từ chối');
select pg_temp.ok(pg_temp.api_val($q$select app.kh_save_flow('{"ot_max_min": 180, "pick_window_min": 120, "size_large_mm2": 2}', 'Giám đốc chốt')::text$q$) = '3', 'Giám đốc sửa giới hạn tăng ca, khung gom lô, ngưỡng cỡ lớn');
select pg_temp.ok(pg_temp.api_val($q$select app.kh_save_flow('{"pick_window_min": null}', 'Về nửa ca')::text$q$) = '1', 'Giám đốc đặt khung gom lô về mặc định (trống = nửa ca)');
select pg_temp.ok((select pick_window_min is null and ot_max_min = 180 from master.planning_config where id = 1), 'Khung gom lô trống, tăng ca tối đa 180 phút');

-- ================================================================ 3. Đề xuất tăng ca: TP SX → Giám đốc
select pg_temp.as_user('F_SXTP');
select pg_temp.blocked($q$select app.kh_ot_propose(null, jsonb_build_object('extra_min', jsonb_build_object((select code from m1 limit 1), 200), 'date_from', (select d from today), 'date_to', (select d + 5 from today), 'reason', 'thử'))$q$,
  'tối đa 180', 'Tăng ca quá giới hạn ngày bị chặn');
select pg_temp.blocked($q$select app.kh_ot_propose(null, jsonb_build_object('extra_min', '{"KHONG-CO": 60}'::jsonb, 'date_from', (select d from today), 'date_to', (select d + 5 from today), 'reason', 'thử'))$q$,
  'Không có máy', 'Máy không có bị chặn');
select pg_temp.blocked($q$select app.kh_ot_propose(null, jsonb_build_object('extra_min', jsonb_build_object((select code from m1 limit 1), 180), 'date_from', date_trunc('month', (select d from today))::date, 'date_to', (date_trunc('month', (select d from today)) + interval '1 month - 1 day')::date, 'reason', 'thử'))$q$,
  'vượt 40 giờ/tháng', 'Tăng ca 3 giờ mỗi ngày cả tháng (> 40 giờ) bị chặn');
select pg_temp.blocked($q$select app.kh_ot_propose(null, jsonb_build_object('mix_early_h', 5, 'date_from', (select d from today), 'date_to', (select d + 5 from today), 'reason', 'thử'))$q$,
  'tối đa 4 giờ', 'Trộn sớm quá giới hạn bị chặn');
select pg_temp.blocked($q$select app.kh_ot_propose(null, jsonb_build_object('extra_min', jsonb_build_object((select code from m1 limit 1), 60), 'date_from', (select d from today), 'date_to', (select d + 90 from today), 'reason', 'thử'))$q$,
  'tối đa 2 tháng', 'Khoảng quá 2 tháng bị chặn');
select pg_temp.blocked($q$select app.kh_ot_propose(null, jsonb_build_object('date_from', (select d from today), 'date_to', (select d + 5 from today), 'reason', 'thử'))$q$,
  'Chưa có giờ', 'Không có giờ nào thì báo');
select pg_temp.blocked($q$select app.kh_ot_propose(null, jsonb_build_object('mix_early_h', 2, 'date_from', (select d from today), 'date_to', (select d + 5 from today), 'reason', ' '))$q$,
  'lý do', 'Bắt buộc lý do tăng ca');
create temp table ot1 as select null::uuid as id;
grant all on ot1 to authenticated;
select pg_temp.ok(pg_temp.api_val($q$with x as (select app.kh_ot_propose(null, jsonb_build_object('extra_min', jsonb_build_object((select code from m1 limit 1), 120, (select code from m1 offset 1 limit 1), 0),
  'mix_early_h', 2, 'date_from', (select d from today), 'date_to', (select d + 6 from today), 'reason', 'Lô D03 trễ ngày chốt', 'summary', '{"gain_days": 1.2}'::jsonb)) as id)
  update ot1 set id = (select id from x) returning (id is not null)::text$q$) = 'true', 'TP SX đề xuất tăng ca 2 giờ + trộn sớm 2 giờ trong 7 ngày');
select pg_temp.ok((select status = 'PROPOSED' and req_no like 'TC-%' and extra_min = jsonb_build_object((select code from m1 limit 1), 120) and summary ->> 'gain_days' = '1.2'
  from plan.overtime_requests where id = (select id from ot1)), 'Đề xuất chờ duyệt, bỏ máy 0 phút, lưu tóm tắt MES');
select pg_temp.ok((select extra_min = '{}' and mix_early_h = 0 from master.planning_config where id = 1), 'Chưa duyệt thì chưa áp vào xếp lịch');
select pg_temp.ok(exists (select 1 from wf.notifications n join core.profiles p on p.id = n.user_id where p.employee_code = 'F_BGD' and n.title like 'Đề xuất tăng ca chờ duyệt%'),
  'Giám đốc nhận thông báo đề xuất tăng ca');
select pg_temp.blocked($q$select app.kh_ot_review((select id from ot1), true, '')$q$, 'Chỉ Giám đốc', 'TP SX không tự duyệt tăng ca');
select pg_temp.as_user('F_BGD');
select pg_temp.blocked($q$select app.kh_ot_review((select id from ot1), false, ' ')$q$, 'lý do trả lại', 'Trả lại phải có lý do');
select pg_temp.ok(pg_temp.api_val($q$select app.kh_ot_review((select id from ot1), true, 'Đồng ý, người lao động đã đồng ý')::text$q$) = '', 'Giám đốc duyệt tăng ca');
select pg_temp.ok((select extra_min = jsonb_build_object((select code from m1 limit 1), 120) and mix_early_h = 2 and ot_from = (select d from today) and ot_until = (select d + 6 from today)
  and ot_request_id = (select id from ot1) from master.planning_config where id = 1), 'Duyệt xong áp vào tham số xếp lịch (máy, giờ, khoảng ngày)');
select pg_temp.as_user('F_SXTP');
select pg_temp.ok(pg_temp.api_val($q$select (extra_min_now ->> (select code from m1 limit 1)) || '|' || mix_early_h_now from app.v_kh_config$q$) = '120|2', 'Tăng ca có hiệu lực hôm nay');
select pg_temp.ok(exists (select 1 from master.planning_param_log where section = 'Tăng ca'), 'Nhật ký ghi tăng ca (lịch hiện "cần xếp lại")');
select pg_temp.ok(exists (select 1 from wf.notifications n join core.profiles p on p.id = n.user_id where p.employee_code = 'F_SXTP' and n.title like 'Giám đốc duyệt tăng ca%'),
  'Người đề xuất nhận thông báo đã duyệt');
select pg_temp.blocked($q$select app.kh_ot_review((select id from ot1), true, '')$q$, 'Chỉ Giám đốc', 'Duyệt lại đề xuất đã duyệt bị chặn');
-- Hết hạn: coi như không tăng ca
update master.planning_config set ot_from = (select d - 10 from today), ot_until = (select d - 1 from today) where id = 1;
select pg_temp.ok(pg_temp.api_val($q$select extra_min_now::text || '|' || mix_early_h_now from app.v_kh_config$q$) = '{}|0', 'Tăng ca hết hạn thì bộ xếp lịch không dùng');
update master.planning_config set ot_from = (select d from today), ot_until = (select d + 6 from today) where id = 1;

-- ================================================================ 4. Giám đốc tự đề xuất: áp ngay, thay đề xuất cũ; kết thúc sớm
select pg_temp.as_user('F_BGD');
create temp table ot2 as select null::uuid as id;
grant all on ot2 to authenticated;
select pg_temp.ok(pg_temp.api_val($q$with x as (select app.kh_ot_propose(null, jsonb_build_object('mix_early_h', 3, 'date_from', (select d from today), 'date_to', (select d + 3 from today), 'reason', 'Giám đốc chỉ đạo trộn sớm')) as id)
  update ot2 set id = (select id from x) returning (id is not null)::text$q$) = 'true', 'Giám đốc tự đề xuất trộn sớm 3 giờ');
select pg_temp.ok((select status = 'APPROVED' from plan.overtime_requests where id = (select id from ot2)) and (select status = 'ENDED' from plan.overtime_requests where id = (select id from ot1)),
  'Đề xuất của Giám đốc áp ngay, đề xuất cũ kết thúc');
select pg_temp.ok((select extra_min = '{}' and mix_early_h = 3 and ot_request_id = (select id from ot2) from master.planning_config where id = 1), 'Tham số chỉ còn trộn sớm 3 giờ');
select pg_temp.as_user('F_SXKH');
select pg_temp.blocked($q$select app.kh_ot_end((select id from ot2), 'thử')$q$, 'Chỉ Giám đốc hoặc TP SX', 'Kế hoạch SX không kết thúc tăng ca');
select pg_temp.as_user('F_SXTP');
select pg_temp.blocked($q$select app.kh_ot_end((select id from ot2), ' ')$q$, 'lý do', 'Kết thúc phải có lý do');
select pg_temp.ok(pg_temp.api_val($q$select app.kh_ot_end((select id from ot2), 'Máy trộn đủ năng lực')::text$q$) = '', 'TP SX kết thúc trộn sớm');
select pg_temp.ok((select extra_min = '{}' and mix_early_h = 0 and ot_request_id is null and ot_from is null from master.planning_config where id = 1)
  and (select status = 'ENDED' and ended_on = (select d from today) from plan.overtime_requests where id = (select id from ot2)), 'Kết thúc: tham số về không tăng ca, ghi ngày cuối có hiệu lực');
select pg_temp.ok((select ended_on = date_from - 1 from plan.overtime_requests where id = (select id from ot1)), 'Đề xuất bị thay từ ngày đầu: không còn ngày nào tính giờ tháng');
-- Đề xuất mới thay đề xuất đang chờ
select pg_temp.ok(pg_temp.api_val($q$select (app.kh_ot_propose(null, jsonb_build_object('mix_early_h', 1, 'date_from', (select d from today), 'date_to', (select d + 1 from today), 'reason', 'A')) is not null)::text$q$) = 'true', 'Đề xuất A');
select pg_temp.ok(pg_temp.api_val($q$select (app.kh_ot_propose(null, jsonb_build_object('mix_early_h', 2, 'date_from', (select d from today), 'date_to', (select d + 1 from today), 'reason', 'B')) is not null)::text$q$) = 'true', 'Đề xuất B');
select pg_temp.ok((select count(*) from plan.overtime_requests where status = 'PROPOSED') = 1 and (select status = 'CANCELLED' from plan.overtime_requests where reason = 'A'),
  'Chỉ còn một đề xuất chờ duyệt (A bị thay bằng B)');
select pg_temp.ok(pg_temp.api_val($q$select count(*)::text from app.v_kh_overtime where reason in ('A', 'B') and proposed_by_name is not null$q$) = '2', 'Danh sách đề xuất tăng ca xem được qua app.v_kh_overtime');
select pg_temp.as_user('F_BGD');
select pg_temp.ok(pg_temp.api_val($q$select app.kh_ot_review((select id from plan.overtime_requests where reason = 'B'), false, 'Chưa cần')::text$q$) = '', 'Giám đốc trả lại đề xuất B');
select pg_temp.ok((select status = 'RETURNED' and review_note = 'Chưa cần' from plan.overtime_requests where reason = 'B'), 'Đề xuất B bị trả lại có ý kiến');
-- Đề xuất của người khác bị thay thì người đó nhận thông báo
select pg_temp.as_user('F_SXKH');
select pg_temp.ok(pg_temp.api_val($q$select (app.kh_ot_propose(null, jsonb_build_object('mix_early_h', 1, 'date_from', (select d from today), 'date_to', (select d + 1 from today), 'reason', 'C')) is not null)::text$q$) = 'true', 'Kế hoạch SX đề xuất C');
select pg_temp.as_user('F_SXTP');
select pg_temp.ok(pg_temp.api_val($q$select (app.kh_ot_propose(null, jsonb_build_object('mix_early_h', 1, 'date_from', (select d from today), 'date_to', (select d + 1 from today), 'reason', 'D')) is not null)::text$q$) = 'true', 'TP SX đề xuất D thay C');
select pg_temp.ok(exists (select 1 from wf.notifications n join core.profiles p on p.id = n.user_id where p.employee_code = 'F_SXKH' and n.title like 'Đề xuất tăng ca % được thay bằng %'),
  'Người lập C nhận thông báo đề xuất bị thay');
-- Quản trị đề xuất: không tự áp, chờ Giám đốc duyệt
select pg_temp.as_user('F_ADM');
select pg_temp.ok(pg_temp.api_val($q$select (app.kh_ot_propose(null, jsonb_build_object('mix_early_h', 1, 'date_from', (select d from today), 'date_to', (select d + 1 from today), 'reason', 'E')) is not null)::text$q$) = 'true', 'Quản trị đề xuất E');
select pg_temp.ok((select status = 'PROPOSED' from plan.overtime_requests where reason = 'E') and (select mix_early_h = 0 and ot_request_id is null from master.planning_config where id = 1),
  'Đề xuất của Quản trị chờ Giám đốc duyệt, chưa áp');
select pg_temp.as_user('F_BGD');
select pg_temp.ok(pg_temp.api_val($q$select app.kh_ot_review((select id from plan.overtime_requests where reason = 'E'), false, 'Không cần')::text$q$) = '', 'Giám đốc trả lại E');

-- ================================================================ 4b. Giới hạn ngày (tăng ca + trộn sớm) và giới hạn tháng cộng dồn
select pg_temp.blocked($q$select app.kh_ot_propose(null, jsonb_build_object('extra_min', '{"SIL-MIX": 150}'::jsonb, 'mix_early_h', 1, 'date_from', (select d + 1 from today), 'date_to', (select d + 2 from today), 'reason', 'thử'))$q$,
  'tăng ca + trộn sớm', 'Người trộn: tăng ca 150 phút + trộn sớm 1 giờ > 180 phút/ngày bị chặn');
create temp table mo as select (date_trunc('month', (select d from today)) + interval '2 month')::date as m;
grant select on mo to authenticated;
select pg_temp.ok(pg_temp.api_val($q$select (app.kh_ot_propose(null, jsonb_build_object('extra_min', '{"BUN-01": 150}'::jsonb, 'date_from', (select m from mo), 'date_to', (select m + 11 from mo), 'reason', 'X')) is not null)::text$q$) = 'true',
  'Giám đốc duyệt ngay tăng ca X: bện 150 phút/ngày, 12 ngày đầu tháng');
select pg_temp.blocked($q$select app.kh_ot_propose(null, jsonb_build_object('extra_min', '{"BUN-01": 150}'::jsonb, 'date_from', (select m + 12 from mo), 'date_to', (select m + 23 from mo), 'reason', 'Y'))$q$,
  'đã duyệt trước', 'Tăng ca Y nửa sau tháng: cộng dồn với X vượt 40 giờ/tháng bị chặn');
select pg_temp.ok(pg_temp.api_val($q$select (app.kh_ot_propose(null, jsonb_build_object('extra_min', '{"BUN-01": 30}'::jsonb, 'date_from', (select m + 12 from mo), 'date_to', (select m + 23 from mo), 'reason', 'Y2')) is not null)::text$q$) = 'true',
  'Tăng ca Y2 30 phút/ngày nửa sau tháng: cộng dồn vẫn trong 40 giờ');
select pg_temp.ok((select status = 'ENDED' and ended_on = (select m + 11 from mo) from plan.overtime_requests where reason = 'X'),
  'X kết thúc khi Y2 bắt đầu: tính đủ 12 ngày đã áp');
select pg_temp.blocked($q$select app.kh_ot_propose(null, jsonb_build_object('extra_min', '{"BUN-01": 150}'::jsonb, 'date_from', (select m + 24 from mo), 'date_to', (select (m + interval '1 month - 1 day')::date from mo), 'reason', 'Z'))$q$,
  'đã duyệt trước', 'Cuối tháng thêm 150 phút/ngày: X + phần trước của Y2 đã gần đủ giờ tháng → bị chặn');

-- ================================================================ 5. Quyền: người ngoài không gọi được hàm nội bộ
select pg_temp.blocked($q$select plan.ot_apply((select id from ot1))$q$, 'permission denied', 'Người dùng không gọi thẳng hàm áp tăng ca');
select pg_temp.blocked($q$select plan.ot_check('{}', 0, current_date, current_date)$q$, 'permission denied', 'Người dùng không gọi thẳng hàm kiểm tăng ca');
select pg_temp.blocked($q$update master.planning_config set extra_min = '{"X":1}' where id = 1$q$, 'permission denied', 'Không ghi thẳng tham số tăng ca qua API');
select pg_temp.blocked($q$insert into plan.overtime_requests (req_no, date_from, date_to, reason) values ('X', current_date, current_date, 'x')$q$, 'permission denied', 'Không ghi thẳng đề xuất tăng ca qua API');

do $$ declare v_n int; v_s text; begin
  select count(*), string_agg(r.n || '. ' || r.msg, E'\n' order by r.n) into v_n, v_s from r;
  raise exception 'KET_QUA_OK % kiểm tra đạt:%', v_n, E'\n' || v_s;
end $$;
