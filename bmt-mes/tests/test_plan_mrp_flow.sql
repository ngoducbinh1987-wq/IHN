-- Kiểm thử migration 2100: sửa dòng kế hoạch, quy cách đóng gói, điều chỉnh MRP, cài đặt quy trình, cảnh báo quá hạn.
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK, không để lại dữ liệu.
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
create function pg_temp.uid(p_code text) returns uuid language sql as $$ select id from core.profiles where employee_code = p_code $$;
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
create function pg_temp.mrp_line(p_run uuid) returns uuid language sql as $$
  select id from plan.mrp_lines where run_id = p_run and suggest_qty > 0 order by suggest_qty desc, material_id limit 1
$$;
set client_min_messages = notice;

with u(code, role) as (values ('T_SXKH','SX_KH'),('T_SXTP','SX_TP'),('T_SXTP2','SX_TP'),('T_BGD','BGD'),('T_MUATP','MUA_TP'),
  ('T_KTTP','KT_TP'),('T_MUANV','MUA_NV'),('T_ADMIN','ADMIN')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('T_SXKH','SX_KH'),('T_SXTP','SX_TP'),('T_SXTP2','SX_TP'),('T_BGD','BGD'),
  ('T_MUATP','MUA_TP'),('T_KTTP','KT_TP'),('T_MUANV','MUA_NV'),('T_ADMIN','ADMIN')) u(code, role) on u.code = p.employee_code;
-- Luồng PLAN: dùng đúng cấu hình gốc trong lúc kiểm thử
update wf.approval_steps set enabled = (seq in (1, 2)), assignee_ids = '{}', sla_hours = 24, warn_hours = 0 where doc_type = 'PLAN';
update wf.approval_flows set submit_role = null, submit_user_ids = '{}' where doc_type = 'PLAN';

-- ================================================================ 2–3. Quy cách đóng gói
-- Database mới chưa phát hành spec nào: phát hành PFR-2C-1P5 (trong transaction, sẽ rollback)
do $$ begin
  if not exists (select 1 from master.products p join master.product_specs s on s.id = p.current_spec_id where s.status = 'RELEASED') then
    perform set_config('request.jwt.claim.sub', (select id::text from core.profiles where employee_code = 'T_ADMIN'), true);
    perform set_config('bmt.wf_release', 'on', true);
    perform master.release_spec((select current_spec_id from master.products where code = 'PFR-2C-1P5'));
  end if;
end $$;
select pg_temp.as_user('T_SXKH');
insert into t select 'prod', p.id from master.products p join master.product_specs s on s.id = p.current_spec_id
 where s.status = 'RELEASED' and exists (select 1 from master.bom_headers h join master.bom_lines bl on bl.bom_id = h.id where h.spec_id = s.id)
 order by p.code limit 1;
insert into plan.production_plans (plan_no, period_label, material_need_date) values ('KH-T21', 'Thử 2100', current_date + 40);
insert into t select 'plan', id from plan.production_plans where plan_no = 'KH-T21';
set local role authenticated;
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, run_lots, m_per_pack, pack_type, brand)
select (select v from t where k = 'plan'), p.id, p.current_spec_id, 1000, 1, 305, 'Bobin gỗ', 'KAVIX' from master.products p where p.id = (select v from t where k = 'prod');
reset role;
select pg_temp.ok((select full_packs = 3 and odd_m = 85 and packs = 4 from app.v_plan_lines where plan_id = (select v from t where k = 'plan')),
  'Bobin gỗ 305 m/kiện: 1.000 m = 3 kiện chẵn + 1 kiện lẻ 85 m (tổng 4 kiện)');
select pg_temp.fails($$update plan.plan_lines set m_per_pack = 333 where plan_id = (select v from t where k = 'plan')$$,
  'Quy cách đóng gói không hợp lệ', 'Chặn m/kiện ngoài danh mục');
update plan.plan_lines set pack_type = 'Cuộn PE', m_per_pack = 200 where plan_id = (select v from t where k = 'plan');
select pg_temp.ok((select pack_type = 'Cuộn PE' and m_per_pack = 200 and packs = 5 and odd_m = 0 from app.v_plan_lines where plan_id = (select v from t where k = 'plan')),
  'Cuộn PE 200 m: lưu và đọc lại đúng, 1.000 m = 5 kiện, không lẻ');
update plan.plan_lines set m_per_pack = 100 where plan_id = (select v from t where k = 'plan');
select pg_temp.ok((select m_per_pack = 100 from plan.plan_lines where plan_id = (select v from t where k = 'plan')), 'Cuộn PE 100 m: lưu được');
update plan.plan_lines set pack_type = 'Bobin gỗ', m_per_pack = 500 where plan_id = (select v from t where k = 'plan');
select pg_temp.ok((select count(*) = 4 from master.pack_options), 'Danh mục giữ Bobin gỗ 500 và Cuộn PE 100 cũ, thêm 305 và 200');

-- ================================================================ 1. Sửa dòng kế hoạch + đánh dấu cần tính lại MRP
set local role authenticated;
update plan.plan_lines set qty_m = 3000, run_lots = 2 where plan_id = (select v from t where k = 'plan');
reset role;
select pg_temp.ok((select total_m = 3000 and total_packs = 6 and not mrp_stale from app.v_plans where id = (select v from t where k = 'plan')),
  'Sửa dòng (Nháp, có quyền): tổng sản lượng 3.000 m, 6 kiện; chưa chạy MRP thì không cần tính lại');
insert into t select 'run1', plan.run_mrp((select v from t where k = 'plan'));
update plan.plan_lines set qty_m = 3500 where plan_id = (select v from t where k = 'plan');
select pg_temp.ok((select mrp_stale from plan.production_plans where id = (select v from t where k = 'plan')), 'Sửa dòng sau khi chạy MRP → đánh dấu cần tính lại');
select pg_temp.fails($$select wf.submit('PLAN', (select v from t where k = 'plan'), 'KH-T21')$$, 'chạy lại MRP', 'Không gửi duyệt khi MRP chưa tính lại');
select pg_temp.as_user('T_MUATP');
select pg_temp.fails($$select app.adjust_mrp_line(pg_temp.mrp_line((select v from t where k = 'run1')), 1, null, null, 'x')$$, 'chạy lại MRP', 'Không sửa MRP cũ khi dòng kế hoạch đã đổi');
select pg_temp.as_user('T_SXKH');
insert into t select 'run2', plan.run_mrp((select v from t where k = 'plan'));
select pg_temp.ok((select not mrp_stale from plan.production_plans where id = (select v from t where k = 'plan')), 'Chạy lại MRP → hết cờ cần tính lại');
select pg_temp.as_user('T_MUANV');
set local role authenticated;
update plan.plan_lines set qty_m = 1 where plan_id = (select v from t where k = 'plan');
reset role;
select pg_temp.ok((select qty_m = 3500 from plan.plan_lines where plan_id = (select v from t where k = 'plan')), 'NV mua (không có quyền sửa kế hoạch) không sửa được dòng (RLS)');

-- ================================================================ 4. Điều chỉnh kết quả MRP
insert into t select 'line', pg_temp.mrp_line((select v from t where k = 'run2'));
select pg_temp.fails($$select app.adjust_mrp_line((select v from t where k = 'line'), 999, null, null, 'thử')$$, 'TP Mua hàng', 'NV mua không sửa được MRP');
select pg_temp.as_user('T_SXTP');
-- 27/10/2026: người lập kế hoạch (TP SX) sửa được MRP khi kế hoạch còn nháp (migration 4400); gửi số cũ → chỉ báo "Không có thay đổi"
select pg_temp.fails($$select app.adjust_mrp_line((select v from t where k = 'line'), (select suggest_qty from plan.mrp_lines where id = (select v from t where k = 'line')), null, null, 'thử')$$,
  'Không có thay đổi', 'TP Sản xuất (người lập kế hoạch) qua kiểm quyền sửa MRP khi kế hoạch nháp');
select pg_temp.as_user('T_MUATP');
select pg_temp.fails($$select app.adjust_mrp_line((select v from t where k = 'line'), 999, null, null, '  ')$$, 'lý do', 'Bắt buộc nhập lý do');
create temp table o as select suggest_qty, latest_order_date from plan.mrp_lines where id = (select v from t where k = 'line');
select app.adjust_mrp_line((select v from t where k = 'line'), 999, current_date + 20, 'Gom đơn với NCC', 'Giá tốt khi mua 999');
select pg_temp.ok((select l.suggest_qty = 999 and l.orig_suggest_qty = o.suggest_qty and l.need_date = current_date + 20 and l.note = 'Gom đơn với NCC'
  and l.latest_order_date is not distinct from o.latest_order_date from plan.mrp_lines l, o where l.id = (select v from t where k = 'line')),
  'TP Mua sửa được số lượng, ngày cần, ghi chú; giữ giá trị gốc');
select pg_temp.as_user('T_KTTP');
select app.adjust_mrp_line((select v from t where k = 'line'), 1000, current_date + 20, 'Gom đơn với NCC', 'Làm tròn bội số');
select pg_temp.ok((select orig_suggest_qty = (select suggest_qty from o) from plan.mrp_lines where id = (select v from t where k = 'line')),
  'TP Kỹ thuật/QA sửa được; giá trị gốc không bị ghi đè');
select pg_temp.ok((select count(*) = 2 and bool_and(reason <> '') from plan.mrp_line_edits where mrp_line_id = (select v from t where k = 'line')),
  'Lịch sử sửa có 2 lần kèm lý do');

-- ================================================================ 5. Cài đặt quy trình
select pg_temp.as_user('T_SXKH');
select pg_temp.fails($$select app.save_flow_step('PLAN', 1::smallint, 'Duyệt', 'SX_TP', array[pg_temp.uid('T_SXTP2')], 8, 2, true)$$,
  'Chỉ quản trị', 'Người không phải quản trị không cài đặt được quy trình');
select pg_temp.as_user('T_ADMIN');
select pg_temp.fails($$select app.save_flow_step('PLAN', 1::smallint, 'Duyệt', 'SX_TP', array[pg_temp.uid('T_MUATP')], 8, 2, true)$$,
  'phải có vai trò', 'Không giao bước cho người không giữ vai trò');
select app.save_flow_step('PLAN', 1::smallint, 'Duyệt kế hoạch', 'SX_TP', array[pg_temp.uid('T_SXTP2')], 8, 2, true);
select app.save_flow_submit('PLAN', 'Lập kế hoạch', 'SX_KH', '{}');
select pg_temp.as_user('T_MUATP');
select pg_temp.fails($$select wf.submit('PLAN', (select v from t where k = 'plan'), 'KH-T21')$$, 'cần vai trò Kế hoạch sản xuất', 'Bước Lập kế hoạch chỉ người có vai trò được cấu hình');
select pg_temp.as_user('T_SXKH');
insert into t select 'req', wf.submit('PLAN', (select v from t where k = 'plan'), 'KH-T21', 'Thử');
select pg_temp.ok((select count(*) = 1 from wf.notifications where user_id in (pg_temp.uid('T_SXTP'), pg_temp.uid('T_SXTP2')) and link = '/duyet/' || (select v from t where k = 'req')),
  'Chỉ người được giao (SX_TP2) nhận thông báo bước Duyệt');
select pg_temp.as_user('T_MUATP');
select pg_temp.fails($$select app.adjust_mrp_line((select v from t where k = 'line'), 5, null, null, 'thử')$$, 'Chỉ người đang duyệt', 'Kế hoạch đang chờ duyệt: chỉ người đang duyệt sửa kết quả MRP');
-- Đổi cấu hình khi hồ sơ đang chạy: hồ sơ giữ cấu hình cũ
select pg_temp.as_user('T_ADMIN');
select app.save_flow_step('PLAN', 1::smallint, 'Duyệt kế hoạch', 'SX_TP', array[pg_temp.uid('T_SXTP')], 8, 2, true);
select pg_temp.as_user('T_SXTP');
select pg_temp.ok((select not my_turn from app.v_approvals where id = (select v from t where k = 'req')), 'Hồ sơ đang chạy giữ cấu hình cũ: SX_TP không thấy là lượt mình');
select pg_temp.fails($$select wf.act((select v from t where k = 'req'), 'APPROVE')$$, 'người được giao', 'Người có vai trò nhưng không được giao không duyệt được');

-- Cảnh báo quá hạn (job máy chủ)
reset role;
update wf.approval_requests set step_started_at = now() - interval '7 hours' where id = (select v from t where k = 'req');
select wf.check_sla();
select pg_temp.ok((select count(*) = 1 from wf.notifications where request_id = (select v from t where k = 'req') and title like 'Sắp đến hạn%' and user_id = pg_temp.uid('T_SXTP2')),
  'Còn 1 giờ (nhắc trước 2 giờ): cảnh báo sắp đến hạn cho người phụ trách');
update wf.approval_requests set step_started_at = now() - interval '9 hours' where id = (select v from t where k = 'req');
select wf.check_sla(); select wf.check_sla();
select pg_temp.ok((select count(*) = 1 from wf.notifications where request_id = (select v from t where k = 'req') and title like 'Quá hạn%'),
  'Quá hạn: tạo đúng 1 cảnh báo dù job chạy nhiều lần (chống trùng)');
select set_config('request.jwt.claim.role', 'service_role', true);
create temp table ob as select * from app.notification_outbox(500);
select pg_temp.ok((select count(*) >= 2 from ob where title like '%KH-T21%'), 'Hàng đợi email có thông báo chờ duyệt + cảnh báo');
select pg_temp.ok((select count(*) = 0 from app.notification_outbox(500) where title like '%KH-T21%'), 'Email đã nhận xử lý không bị lấy lại lần hai (chống gửi trùng)');
update wf.notifications set email_claimed_at = null where request_id = (select v from t where k = 'req') or link = '/duyet/' || (select v from t where k = 'req');

select pg_temp.as_user('T_SXTP2');
select pg_temp.ok((select my_turn and overdue and current_approvers -> 0 ->> 'name' = 'Test t_sxtp2' from app.v_approvals where id = (select v from t where k = 'req')),
  'Hộp duyệt: đúng người được giao, báo quá hạn');
select wf.act((select v from t where k = 'req'), 'APPROVE');
select set_config('request.jwt.claim.role', 'service_role', true);
select pg_temp.ok((select count(*) = 0 from app.notification_outbox(500) where title like 'Quá hạn duyệt: KH-T21' or title like 'Sắp đến hạn duyệt: KH-T21'),
  'Bước đã hoàn tất: không gửi email cảnh báo còn tồn');
select pg_temp.as_user('T_BGD');
update wf.approval_requests set step_started_at = now() - interval '30 hours' where id = (select v from t where k = 'req');
select wf.act((select v from t where k = 'req'), 'APPROVE');
select wf.check_sla();
select pg_temp.ok((select count(*) = 0 from wf.notifications where request_id = (select v from t where k = 'req') and step_seq = 2),
  'Hồ sơ đã duyệt xong: job không cảnh báo nữa');

-- Sau duyệt: TP Mua chỉnh lần cuối, PR dùng số đã chỉnh, rồi khóa
select pg_temp.as_user('T_MUATP');
select app.adjust_mrp_line((select v from t where k = 'line'), 1200, current_date + 25, 'Chốt với NCC', 'Chốt số lượng sau duyệt');
select pg_temp.as_user('T_SXKH');
insert into t select 'pr', plan.create_pr_from_mrp((select v from t where k = 'run2'));
select pg_temp.ok((select qty = 1200 and need_date = current_date + 25 and note = 'Chốt với NCC' from purchase.pr_lines where mrp_line_id = (select v from t where k = 'line')),
  'PR sinh từ MRP dùng đúng số lượng, ngày cần, ghi chú đã điều chỉnh');
select pg_temp.as_user('T_MUATP');
select pg_temp.fails($$select app.adjust_mrp_line((select v from t where k = 'line'), 5, null, null, 'thử')$$, 'Đã sinh đề xuất mua', 'Đã sinh PR: khóa kết quả MRP');
select pg_temp.ok((select count(*) = 3 from plan.mrp_line_edits where plan_id = (select v from t where k = 'plan')), 'Lịch sử điều chỉnh còn đủ 3 lần');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
