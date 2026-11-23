-- Kiểm thử migration 20261026010600_general_requests: mục Đề xuất chung.
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_msg; end if;
  insert into r(msg) values (p_msg);
end $$;
create function pg_temp.uid(p_code text) returns uuid language sql as $$ select id from core.profiles where employee_code = p_code $$;
-- Chạy một câu lệnh với tư cách người dùng; trả kết quả (text) hoặc 'ERR: <lỗi>'
create function pg_temp.run(p_code text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.uid(p_code), 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', pg_temp.uid(p_code)::text, true);
  begin
    execute 'set local role authenticated';
    execute p_sql into v;
    execute 'reset role';
  exception when others then
    v := 'ERR: ' || sqlerrm;
  end;
  execute 'reset role';
  return v;
end $$;
set client_min_messages = notice;

-- Người dùng thật tạm ngưng trong giao dịch (không nhận việc duyệt của kịch bản)
update core.profiles set status = 'INACTIVE' where status = 'ACTIVE';
with u(code, dept) as (values ('RQ_CT','BGD'),('RQ_GD','BGD'),('RQ_SXTP','SX'),('RQ_TT','SX'),('RQ_VH','SX'),('RQ_KTT','KTOAN'),
                              ('RQ_KTGT','KTOAN'),('RQ_MUA','MUA'),('RQ_KTTP','KT'),('RQ_HR','HCNS'),('RQ_KD','KD'),('RQ_TK','KHO'),('RQ_ADMIN','IT')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, department, status)
select i.id, upper(split_part(i.email, '@', 1)), 'Test ' || split_part(i.email, '@', 1), u.dept, 'ACTIVE'
  from ins i join u on lower(u.code) = split_part(i.email, '@', 1);
insert into core.user_roles (user_id, role_code)
select p.id, x.role from core.profiles p join (values ('RQ_CT','BGD'),('RQ_GD','BGD'),('RQ_SXTP','SX_TP'),('RQ_TT','TO_TRUONG'),('RQ_VH','VAN_HANH'),
  ('RQ_KTT','KTT'),('RQ_KTGT','KT_GT'),('RQ_MUA','MUA_NV'),('RQ_KTTP','KT_TP'),('RQ_HR','HCNS'),('RQ_KD','KD_NV'),('RQ_TK','THU_KHO'),
  ('RQ_ADMIN','ADMIN')) x(code, role) on x.code = p.employee_code;
-- Chủ tịch = người được giao bước cuối kế hoạch tháng
update wf.approval_steps set assignee_ids = array[pg_temp.uid('RQ_CT')]
 where doc_type = 'PLAN' and seq = (select max(seq) from wf.approval_steps where doc_type = 'PLAN' and enabled);
insert into master.operators (code, job, full_name, active) values ('RQNV1', 'Thử đề xuất', 'Công nhân thử', true);

do $$
declare d0 date; v text; id1 uuid; id2 uuid; id3 uuid; q wf.approval_requests; v_steps jsonb; n int; v_pr uuid; m text;
begin
  -- thứ Hai sau ít nhất 7 ngày (ngày làm việc mặc định thứ 2–thứ 7)
  d0 := plan.vn_today() + 7; d0 := d0 + ((8 - extract(isodow from d0)::int) % 7);

  perform pg_temp.ok(not has_function_privilege('anon', 'app.req_save(jsonb)', 'execute'), 'Người chưa đăng nhập không lập được đề xuất');
  perform pg_temp.ok((select count(*) from wf.request_types where active) = 15, '15 loại đề xuất');

  -- 1. Công nhân có tài khoản xin nghỉ phép 2 ngày → TP SX duyệt; tóm tắt không ghi lý do riêng tư
  v := pg_temp.run('RQ_VH', format($s$select app.req_save('{"type":"PHEP_NAM","content":"Về quê lo việc nhà riêng tư","date_from":"%s","date_to":"%s"}')::text$s$, d0, d0 + 1));
  id1 := v::uuid;
  perform pg_temp.ok((select days from wf.requests where id = id1) = 2, 'Nghỉ phép thứ 2–thứ 3: 2 ngày làm việc');
  v := pg_temp.run('RQ_VH', format('select app.req_submit(%L)::text', id1));
  select * into q from wf.approval_requests where doc_type = 'REQUEST' and doc_id = id1;
  perform pg_temp.ok(q.status = 'PENDING' and jsonb_array_length(q.flow_snapshot -> 'steps') = 1
                     and q.flow_snapshot #>> '{steps,0,role}' = 'SX_TP' and q.flow_snapshot #>> '{steps,0,label}' = 'Trưởng bộ phận Sản xuất duyệt',
                     'Nghỉ ≤ 3 ngày: chỉ Trưởng bộ phận Sản xuất duyệt (MES tự gán)');
  perform pg_temp.ok(q.summary like 'Nghỉ phép năm · Test rq_vh%' and position('riêng tư' in q.summary) = 0,
                     'Tóm tắt trên Quy trình duyệt không ghi lý do đề xuất riêng tư: ' || q.summary);
  perform pg_temp.ok(exists (select 1 from wf.notifications where user_id = pg_temp.uid('RQ_SXTP') and title like 'Chờ duyệt: DX-%'),
                     'TP SX nhận thông báo Chờ duyệt');
  perform pg_temp.ok(pg_temp.run('RQ_SXTP', format('select my_turn::text from app.v_approvals where doc_id = %L', id1)) = 'true',
                     'Đề xuất hiện ở "Chờ tôi duyệt" của TP SX (Điều hành → Quy trình duyệt)');
  perform pg_temp.ok(pg_temp.run('RQ_SXTP', format('select doc_link from app.v_approvals where doc_id = %L', id1)) = '/de-xuat-chung/' || id1,
                     'Quy trình duyệt dẫn sang trang đề xuất');
  perform pg_temp.ok(pg_temp.run('RQ_KD', format('select count(*)::text from app.v_requests where id = %L', id1)) = '0'
                     and pg_temp.run('RQ_MUA', format('select count(*)::text from wf.requests where id = %L', id1)) = '0',
                     'Đề xuất nghỉ riêng tư: Kinh doanh, Mua hàng không xem được');
  perform pg_temp.ok(pg_temp.run('RQ_SXTP', format('select count(*)::text from app.v_requests where id = %L', id1)) = '1'
                     and pg_temp.run('RQ_GD', format('select count(*)::text from app.v_requests where id = %L', id1)) = '1'
                     and pg_temp.run('RQ_VH', format('select count(*)::text from app.v_requests where id = %L', id1)) = '1',
                     'Người gửi, người duyệt, Ban giám đốc xem được');
  perform pg_temp.ok(pg_temp.run('RQ_VH', format('select jsonb_typeof(steps) || current_level from app.v_requests where id = %L', id1)) = 'arrayTrưởng bộ phận Sản xuất duyệt',
                     'Người gửi (công nhân) thấy đề xuất đang ở bước nào');
  -- người lập không sửa khi đang chờ; người duyệt sửa (rút còn 1 ngày), ghi lịch sử
  v := pg_temp.run('RQ_VH', format($s$select app.req_save('{"id":"%s","type":"PHEP_NAM","content":"x","date_from":"%s"}')::text$s$, id1, d0));
  perform pg_temp.ok(v like 'ERR: Người lập không sửa%', 'Người lập không sửa đề xuất đang chờ duyệt');
  v := pg_temp.run('RQ_SXTP', format($s$select app.req_save('{"id":"%s","type":"PHEP_NAM","content":"Về quê lo việc nhà riêng tư","date_from":"%s","date_to":"%s"}')::text$s$, id1, d0, d0));
  perform pg_temp.ok((select days from wf.requests where id = id1) = 1
                     and exists (select 1 from wf.approval_actions where request_id = q.id and comment like '[Sửa khi duyệt]%ngày%'),
                     'Người duyệt sửa số ngày trước khi duyệt, ghi lịch sử duyệt');
  v := pg_temp.run('RQ_SXTP', format('select wf.act(%L, %L, null)', q.id, 'APPROVE'));
  perform pg_temp.ok(v = 'APPROVED' and (select status from wf.requests where id = id1) = 'DONE',
                     'TP SX duyệt (sau khi sửa) → Hoàn tất: ' || v);
  perform pg_temp.ok(exists (select 1 from wf.notifications where user_id = pg_temp.uid('RQ_HR') and title like 'Nhân sự: DX-%'),
                     'Hành chính – Nhân sự nhận tin đề xuất nghỉ đã duyệt');

  -- 2. Tổ trưởng lập thay công nhân chưa có tài khoản, nghỉ 4 ngày → TP SX → Giám đốc → lịch vắng
  v := pg_temp.run('RQ_VH', format($s$select app.req_save('{"type":"PHEP_NAM","operator_code":"RQNV1","content":"Nghỉ","date_from":"%s"}')::text$s$, d0));
  perform pg_temp.ok(v like 'ERR: Chỉ Tổ trưởng%', 'Công nhân không lập thay người khác');
  id2 := pg_temp.run('RQ_TT', format($s$select app.req_save('{"type":"PHEP_NAM","operator_code":"rqnv1","content":"Cưới em gái","date_from":"%s","date_to":"%s"}')::text$s$, d0 + 7, d0 + 10))::uuid;
  v := pg_temp.run('RQ_TT', format('select app.req_submit(%L)::text', id2));
  select * into q from wf.approval_requests where doc_type = 'REQUEST' and doc_id = id2;
  perform pg_temp.ok(jsonb_array_length(q.flow_snapshot -> 'steps') = 2 and q.flow_snapshot #>> '{steps,1,label}' = 'Giám đốc duyệt',
                     'Nghỉ 4 ngày: Trưởng bộ phận → Giám đốc');
  perform pg_temp.ok(pg_temp.run('RQ_GD', format('select wf.act(%L, %L, null)', q.id, 'APPROVE')) like 'ERR: Bước%',
                     'Giám đốc chưa duyệt được khi TP SX chưa duyệt');
  v := pg_temp.run('RQ_SXTP', format('select wf.act(%L, %L, null)', q.id, 'APPROVE'));
  v := pg_temp.run('RQ_GD', format('select wf.act(%L, %L, null)', q.id, 'APPROVE'));
  perform pg_temp.ok(v = 'APPROVED' and exists (select 1 from plan.operator_absences where operator_code = 'RQNV1' and date_from = d0 + 7
                                                 and date_to = d0 + 10 and kind = 'PHEP' and note like 'Theo đề xuất DX-%')
                     and (select status from wf.requests where id = id2) = 'DONE',
                     'Duyệt xong: MES ghi lịch vắng công nhân, đề xuất Hoàn tất');
  perform pg_temp.ok(exists (select 1 from wf.notifications where user_id = pg_temp.uid('RQ_SXTP') and title like 'Công nhân vắng: RQNV1%'),
                     'TP SX nhận tin công nhân vắng, xếp lại lịch');

  -- 3. Trưởng phòng gửi: bỏ bước Trưởng bộ phận, lên Giám đốc
  id3 := pg_temp.run('RQ_SXTP', format($s$select app.req_save('{"type":"OM","content":"Sốt","date_from":"%s"}')::text$s$, d0))::uuid;
  v := pg_temp.run('RQ_SXTP', format('select app.req_submit(%L)::text', id3));
  select * into q from wf.approval_requests where doc_type = 'REQUEST' and doc_id = id3;
  perform pg_temp.ok(jsonb_array_length(q.flow_snapshot -> 'steps') = 1 and q.flow_snapshot #>> '{steps,0,role}' = 'BGD'
                     and q.flow_snapshot #>> '{steps,0,sla_hours}' = '4',
                     'TP SX xin nghỉ ốm: chuyển thẳng Giám đốc, hạn 4 giờ (loại gấp)');
  perform pg_temp.ok(not (pg_temp.uid('RQ_CT') = any(wf.step_actor_ids(q.flow_snapshot -> 'steps' -> 0))),
                     'Bước Giám đốc không giao Chủ tịch HĐQT');

  -- 4. Giám đốc gửi → Chủ tịch HĐQT duyệt
  id3 := pg_temp.run('RQ_GD', format($s$select app.req_save('{"type":"CONG_TAC","content":"Gặp khách","date_from":"%s","date_to":"%s","data":{"place":"TP HCM"}}')::text$s$, d0, d0 + 2))::uuid;
  v := pg_temp.run('RQ_GD', format('select app.req_submit(%L)::text', id3));
  select * into q from wf.approval_requests where doc_type = 'REQUEST' and doc_id = id3;
  perform pg_temp.ok(q.flow_snapshot #>> '{steps,0,label}' = 'Chủ tịch HĐQT duyệt'
                     and wf.step_actor_ids(q.flow_snapshot -> 'steps' -> 0) = array[pg_temp.uid('RQ_CT')],
                     'Giám đốc gửi đề xuất: Chủ tịch HĐQT duyệt');
  perform pg_temp.ok(pg_temp.run('RQ_GD', format('select wf.act(%L, %L, null)', q.id, 'APPROVE')) like 'ERR:%', 'Giám đốc không tự duyệt');

  -- 5. Tạm ứng: Kế toán trưởng kiểm; từ 5 triệu Giám đốc duyệt; trưởng phòng là người kiểm thì bỏ bước đó
  id3 := pg_temp.run('RQ_KTGT', $s$select app.req_save('{"type":"TAM_UNG","content":"Mua vật tư lẻ","amount":3000000}')::text$s$)::uuid;
  v := pg_temp.run('RQ_KTGT', format('select app.req_submit(%L)::text', id3));
  select flow_snapshot -> 'steps' into v_steps from wf.approval_requests where doc_type = 'REQUEST' and doc_id = id3;
  perform pg_temp.ok(jsonb_array_length(v_steps) = 1 and v_steps #>> '{0,role}' = 'KTT', 'Tạm ứng 3 triệu: Kế toán trưởng duyệt, không lên Giám đốc');
  id3 := pg_temp.run('RQ_KTGT', $s$select app.req_save('{"type":"TAM_UNG","content":"Đặt cọc","amount":6000000}')::text$s$)::uuid;
  v := pg_temp.run('RQ_KTGT', format('select app.req_submit(%L)::text', id3));
  select flow_snapshot -> 'steps' into v_steps from wf.approval_requests where doc_type = 'REQUEST' and doc_id = id3;
  perform pg_temp.ok(jsonb_array_length(v_steps) = 2 and v_steps #>> '{1,role}' = 'BGD', 'Tạm ứng 6 triệu: Kế toán trưởng → Giám đốc');
  id3 := pg_temp.run('RQ_KTT', $s$select app.req_save('{"type":"TAM_UNG","content":"Công tác phí","amount":2000000}')::text$s$)::uuid;
  v := pg_temp.run('RQ_KTT', format('select app.req_submit(%L)::text', id3));
  select flow_snapshot -> 'steps' into v_steps from wf.approval_requests where doc_type = 'REQUEST' and doc_id = id3;
  perform pg_temp.ok(jsonb_array_length(v_steps) = 1 and v_steps #>> '{0,role}' = 'BGD', 'Kế toán trưởng xin tạm ứng: lên Giám đốc');
  perform pg_temp.ok(pg_temp.run('RQ_HR', format('select count(*)::text from wf.requests where id = %L', id3)) = '0',
                     'Đề xuất tài chính: Nhân sự không xem được');

  -- 6. Mua NVL: TP SX xác nhận → Phòng Mua lập đề xuất mua
  id3 := pg_temp.run('RQ_VH', $s$select app.req_save('{"type":"MUA_NVL","content":"Thiếu đồng cho lô gấp","items":[{"code":"cu-024","qty":100},{"name":"Băng keo giấy","qty":5,"unit":"cuộn"}]}')::text$s$)::uuid;
  v := pg_temp.run('RQ_VH', format('select app.req_submit(%L)::text', id3));
  select * into q from wf.approval_requests where doc_type = 'REQUEST' and doc_id = id3;
  perform pg_temp.ok(pg_temp.run('RQ_MUA', format('select can_handle::text from app.v_requests where id = %L', id3)) = 'false'
                     and pg_temp.run('RQ_MUA', format('select app.req_make_pr(%L)::text', id3)) like 'ERR:%',
                     'Phòng Mua thấy nhu cầu mua nhưng chưa xử lý được khi chưa duyệt');
  v := pg_temp.run('RQ_SXTP', format('select wf.act(%L, %L, null)', q.id, 'APPROVE'));
  perform pg_temp.ok((select status from wf.requests where id = id3) = 'APPROVED'
                     and exists (select 1 from wf.notifications where user_id = pg_temp.uid('RQ_MUA') and title like 'Đề xuất cần xử lý: DX-%'),
                     'Duyệt xong: chờ Phòng Mua xử lý, NV mua nhận thông báo');
  perform pg_temp.ok(pg_temp.run('RQ_MUA', 'select (app.menu_counts() ->> ''req_todo'')') = '1', 'Số đề xuất chờ xử lý trên menu của NV mua');
  perform pg_temp.ok(pg_temp.run('RQ_VH', format('select app.req_make_pr(%L)::text', id3)) like 'ERR: Bạn không phải người xử lý%',
                     'Người gửi không tự lập đề xuất mua');
  v_pr := pg_temp.run('RQ_MUA', format('select app.req_make_pr(%L)::text', id3))::uuid;
  perform pg_temp.ok((select pr_kind from purchase.purchase_requests where id = v_pr) = 'BO_SUNG'
                     and (select count(*) from purchase.pr_lines where pr_id = v_pr) = 1
                     and (select note from purchase.purchase_requests where id = v_pr) like '%Hàng chưa có mã: Băng keo giấy%'
                     and (select status from wf.requests where id = id3) = 'DONE'
                     and (select pr_id from wf.requests where id = id3) = v_pr,
                     'Phòng Mua lập đề xuất mua bổ sung NVL từ đề xuất, đề xuất Hoàn tất');

  -- 7. Trả lại → sửa gửi lại; Từ chối → đóng
  id3 := pg_temp.run('RQ_VH', format($s$select app.req_save('{"type":"DI_MUON","content":"Đưa con đi khám","date_from":"%s","time_from":"08:00","time_to":"10:00"}')::text$s$, d0))::uuid;
  v := pg_temp.run('RQ_VH', format('select app.req_submit(%L)::text', id3));
  select * into q from wf.approval_requests where doc_type = 'REQUEST' and doc_id = id3;
  v := pg_temp.run('RQ_SXTP', format('select wf.act(%L, %L, %L)', q.id, 'REJECT', 'Ghi rõ giờ về'));
  perform pg_temp.ok((select status from wf.requests where id = id3) = 'RETURNED', 'Trả lại: đề xuất về Bị trả lại');
  v := pg_temp.run('RQ_VH', format($s$select app.req_save('{"id":"%s","type":"DI_MUON","content":"Đưa con đi khám, về 10:00","date_from":"%s","time_from":"08:00","time_to":"10:00"}')::text$s$, id3, d0));
  v := pg_temp.run('RQ_VH', format('select app.req_submit(%L)::text', id3));
  perform pg_temp.ok((select status from wf.requests where id = id3) = 'PENDING_APPROVAL', 'Sửa xong gửi lại được');
  perform pg_temp.ok(pg_temp.run('RQ_KD', format('select app.req_refuse(%L, %L)::text', id3, 'x')) like 'ERR: Chỉ người đang duyệt%',
                     'Người không giữ bước không từ chối được');
  v := pg_temp.run('RQ_SXTP', format('select app.req_refuse(%L, %L)::text', id3, 'Đang thiếu người'));
  perform pg_temp.ok((select status from wf.requests where id = id3) = 'REFUSED'
                     and pg_temp.run('RQ_VH', format('select app.req_submit(%L)::text', id3)) like 'ERR:%',
                     'Từ chối: đóng hồ sơ, không gửi lại được');

  -- 8. Rút lại khi chưa ai duyệt
  id3 := pg_temp.run('RQ_VH', format($s$select app.req_save('{"type":"DOI_CA","content":"Đổi ca","date_from":"%s","data":{"from_shift":"Ca 1","to_shift":"Ca 2"}}')::text$s$, d0))::uuid;
  v := pg_temp.run('RQ_VH', format('select app.req_submit(%L)::text', id3));
  v := pg_temp.run('RQ_VH', format('select app.req_withdraw(%L)::text', id3));
  perform pg_temp.ok((select status from wf.requests where id = id3) = 'DRAFT'
                     and not exists (select 1 from wf.approval_requests where doc_id = id3 and status = 'PENDING'),
                     'Người lập rút lại khi chưa ai duyệt → về Nháp');
  perform pg_temp.ok(pg_temp.run('RQ_SXTP', format($s$select wf.submit('REQUEST', %L, 'x', 'x')::text$s$, id3)) like 'ERR: Chỉ người lập%',
                     'Không ai gửi duyệt hộ đề xuất của người khác');

  -- 9. Góp ý ẩn danh: Giám đốc không thấy tên, Quản trị thấy
  id3 := pg_temp.run('RQ_VH', $s$select app.req_save('{"type":"CAI_TIEN","content":"Lắp quạt hút ở line đùn","anonymous":true}')::text$s$)::uuid;
  v := pg_temp.run('RQ_VH', format('select app.req_submit(%L)::text', id3));
  perform pg_temp.ok(pg_temp.run('RQ_GD', format('select submitted_by_name from app.v_approvals where doc_id = %L', id3)) = 'Ẩn danh'
                     and pg_temp.run('RQ_GD', format('select requester_name from app.v_requests where id = %L', id3)) = 'Ẩn danh'
                     and pg_temp.run('RQ_ADMIN', format('select requester_name from app.v_requests where id = %L', id3)) = 'Test rq_vh',
                     'Góp ý ẩn danh: Giám đốc thấy "Ẩn danh", Quản trị thấy tên');
  perform pg_temp.ok(pg_temp.run('RQ_VH', $s$select app.req_save('{"type":"OM","content":"x","date_from":"2026-12-01","anonymous":true}')::text$s$) like 'ERR: Loại%',
                     'Đề xuất nghỉ không gửi ẩn danh');

  -- 10. Việc khác: trưởng bộ phận nơi nhận xem xét
  id3 := pg_temp.run('RQ_VH', $s$select app.req_save('{"type":"KHAC","content":"Thêm kệ để bobin","target_dept":"KHO"}')::text$s$)::uuid;
  v := pg_temp.run('RQ_VH', format('select app.req_submit(%L)::text', id3));
  select flow_snapshot -> 'steps' into v_steps from wf.approval_requests where doc_type = 'REQUEST' and doc_id = id3;
  perform pg_temp.ok(jsonb_array_length(v_steps) = 2 and v_steps #>> '{1,role}' = 'THU_KHO' and v_steps #>> '{1,label}' = 'Trưởng bộ phận Kho xem xét',
                     'Việc khác: Trưởng bộ phận người gửi → trưởng bộ phận nơi nhận');

  -- 11. Bộ phận chưa có trưởng: chuyển Giám đốc
  id3 := pg_temp.run('RQ_KD', format($s$select app.req_save('{"type":"OM","content":"Khám răng","date_from":"%s","part":"AM"}')::text$s$, d0))::uuid;
  perform pg_temp.ok((select days from wf.requests where id = id3) = 0.5, 'Nghỉ nửa ca: 0,5 ngày');
  v := pg_temp.run('RQ_KD', format('select app.req_submit(%L)::text', id3));
  select flow_snapshot -> 'steps' into v_steps from wf.approval_requests where doc_type = 'REQUEST' and doc_id = id3;
  perform pg_temp.ok(v not like 'ERR%' and v_steps #>> '{0,role}' = 'BGD', 'Bộ phận Kinh doanh chưa có trưởng phòng: chuyển Giám đốc');

  -- 12. Sửa chữa máy: TP KT/QA mở phiếu sửa chữa
  select code into m from master.machines order by code limit 1;
  id3 := pg_temp.run('RQ_VH', format($s$select app.req_save('{"type":"SUA_CHUA","content":"Rò dầu hộp số","machine_code":"%s"}')::text$s$, m))::uuid;
  v := pg_temp.run('RQ_VH', format('select app.req_submit(%L)::text', id3));
  select * into q from wf.approval_requests where doc_type = 'REQUEST' and doc_id = id3;
  -- 12a. Quá hạn: báo Giám đốc (cấp trên), không ai duyệt thay
  update wf.approval_requests set step_started_at = now() - interval '5 hours' where id = q.id;
  perform wf.check_sla();
  perform pg_temp.ok(exists (select 1 from wf.notifications where user_id = pg_temp.uid('RQ_GD') and title like 'Đề xuất quá hạn duyệt: DX-%'),
                     'Quá hạn duyệt: Giám đốc nhận cảnh báo');
  v := pg_temp.run('RQ_SXTP', format('select wf.act(%L, %L, null)', q.id, 'APPROVE'));
  v := pg_temp.run('RQ_KTTP', format('select app.req_make_repair(%L)::text', id3));
  perform pg_temp.ok(exists (select 1 from mfg.maint_work_orders where id = v::uuid and wo_type = 'CM' and note like 'Theo đề xuất DX-%')
                     and (select status from wf.requests where id = id3) = 'DONE',
                     'TP KT/QA mở phiếu sửa chữa từ đề xuất: ' || v);

  -- 13. Tài khoản chưa có bộ phận
  update core.profiles set department = null where id = pg_temp.uid('RQ_ADMIN');
  delete from core.user_roles where user_id = pg_temp.uid('RQ_ADMIN');
  insert into core.user_roles (user_id, role_code) values (pg_temp.uid('RQ_ADMIN'), 'KD_NV');
  perform pg_temp.ok(wf.user_dept(pg_temp.uid('RQ_ADMIN')) = 'KD', 'Chưa ghi bộ phận: MES lấy theo vai trò');
end $$;

do $$ begin
  raise exception 'KET_QUA_OK %', (select count(*) from r) || ' kiểm tra đạt: ' || (select string_agg(msg, ' | ' order by n) from r);
end $$;
rollback;
