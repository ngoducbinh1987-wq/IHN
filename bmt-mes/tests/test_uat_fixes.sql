-- Kiểm thử migration 20261026003000 (sửa lỗi chạy thử UAT 26/10): Quản trị duyệt mọi khâu + hủy hồ sơ kẹt (L1),
-- NV kho TP xem đơn bán (L2), mã sản phẩm IN HOA (L3), spec mới → kế hoạch dùng bản mới (L4), hai cấp duyệt hai người (L6),
-- module máy không tự duyệt + báo việc chờ (L7).
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
-- Trên dữ liệu thật: tạm ngưng mọi tài khoản thật trong giao dịch (rollback ở cuối).
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create temp table t (k text primary key, v uuid);
grant all on r, t to authenticated;
grant usage on sequence r_n_seq to authenticated;

create function pg_temp.as_user(p_code text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', (select id::text from core.profiles where employee_code = p_code), true),
         set_config('request.jwt.claims', json_build_object('sub', (select id from core.profiles where employee_code = p_code), 'role', 'authenticated')::text, true),
         set_config('request.jwt.claim.role', 'authenticated', true)
$$;
create function pg_temp.uid(p_code text) returns uuid language sql as $$ select id from core.profiles where employee_code = p_code $$;
create function pg_temp.v(p_k text) returns uuid language sql as $$ select v from t where k = p_k $$;
create function pg_temp.req(p_doc uuid) returns uuid language sql as $$ select id from wf.approval_requests where doc_id = p_doc and status = 'PENDING' $$;
create function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_msg; end if;
  insert into r(msg) values (p_msg);
end $$;
-- Chạy dưới vai trò authenticated (như gọi qua API), mong đợi bị chặn với thông báo chứa p_pattern
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
create function pg_temp.api(p_sql text) returns text language plpgsql as $$
declare v text;
begin
  execute 'set local role authenticated';
  execute p_sql into v;
  execute 'reset role';
  return v;
end $$;
grant execute on all functions in schema pg_temp to authenticated;
set client_min_messages = notice;

-- ---------------------------------------------------------------- người dùng thử, tạm ngưng tài khoản thật
update core.profiles set status = 'INACTIVE' where coalesce(employee_code, '') not like 'Q\_%';
with u(code, role) as (values ('Q_ADM','ADMIN'),('Q_BGD','BGD'),('Q_SXTP','SX_TP'),('Q_CT','BGD'),('Q_CT','SX_TP'),('Q_MUA','MUA_NV'),
                              ('Q_KHONV','KHO_NV'),('Q_KTTP','KT_TP'),('Q_KTTP','QC'),('Q_KTTP2','KT_TP')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from (select distinct code from u) x returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('Q_ADM','ADMIN'),('Q_BGD','BGD'),('Q_SXTP','SX_TP'),('Q_CT','BGD'),('Q_CT','SX_TP'),('Q_MUA','MUA_NV'),
  ('Q_KHONV','KHO_NV'),('Q_KTTP','KT_TP'),('Q_KTTP','QC'),('Q_KTTP2','KT_TP')) u(code, role) on u.code = p.employee_code;
-- Bước Chủ tịch HĐQT của kế hoạch tháng giao đích danh Q_CT
update wf.approval_steps set assignee_ids = array[pg_temp.uid('Q_CT')] where doc_type = 'PLAN' and seq = 2;

-- ================================================================ 0. Quản trị làm được mọi khâu
select pg_temp.as_user('Q_ADM');
select pg_temp.ok(pg_temp.api($$select (core.has_role('KT_KHO') and core.has_role('BGD') and core.is_admin())::text$$) = 'true',
  'Quản trị được coi là có mọi vai trò khi duyệt');
select pg_temp.as_user('Q_BGD');
select pg_temp.ok(pg_temp.api($$select (core.has_role('KT_KHO') or core.is_admin())::text$$) = 'false', 'Người không phải Quản trị không có thêm vai trò');

-- PR: Quản trị (không giữ vai trò Giám đốc) duyệt bước Giám đốc
select pg_temp.as_user('Q_MUA');
insert into t select 'pr', pg_temp.api($$select app.create_pr(null, 'Thử UAT', '[{"material_code":"CU-024","qty":100}]')::text$$)::uuid;
select pg_temp.api(format($$select wf.submit('PR', %L, '', 'Thử')::text$$, pg_temp.v('pr')));
select pg_temp.as_user('Q_ADM');
select pg_temp.api(format($$select wf.act(%L, 'APPROVE', 'Quản trị duyệt')$$, pg_temp.req(pg_temp.v('pr'))));
select pg_temp.ok((select status from purchase.purchase_requests where id = pg_temp.v('pr')) = 'APPROVED', 'Quản trị duyệt được bước Giám đốc của PR');

-- Kế hoạch tháng: bước Chủ tịch giao đích danh → Quản trị vẫn duyệt được; người khác thì không
insert into plan.production_plans (plan_no, period_label, material_need_date) values ('KH-Q1', 'Thử', current_date + 10), ('KH-Q2', 'Thử', current_date + 10),
  ('KH-Q3', 'Thử', current_date + 10), ('KH-Q4', 'Thử', current_date + 10), ('KH-Q5', 'Thử', current_date + 10);
insert into t select lower(replace(plan_no, '-', '_')), id from plan.production_plans where plan_no like 'KH-Q_';
select pg_temp.as_user('Q_BGD');
select pg_temp.api(format($$select wf.submit('PLAN', %L, '', 'Thử')::text$$, pg_temp.v('kh_q1')));
select pg_temp.as_user('Q_SXTP');
select pg_temp.api(format($$select wf.act(%L, 'APPROVE', 'Đủ năng lực')$$, pg_temp.req(pg_temp.v('kh_q1'))));
select pg_temp.blocked(format($$select wf.act(%L, 'APPROVE')$$, pg_temp.req(pg_temp.v('kh_q1'))), 'cần vai trò', 'Quản lý SX không duyệt bước Chủ tịch HĐQT');
select pg_temp.as_user('Q_ADM');
select pg_temp.api(format($$select wf.act(%L, 'APPROVE')$$, pg_temp.req(pg_temp.v('kh_q1'))));
select pg_temp.ok((select status from plan.production_plans where id = pg_temp.v('kh_q1')) = 'APPROVED', 'Quản trị duyệt được bước giao đích danh (Chủ tịch HĐQT)');

-- ================================================================ 5. L6: hai cấp duyệt là hai người
select pg_temp.as_user('Q_BGD');
select pg_temp.api(format($$select wf.submit('PLAN', %L, '', 'Thử')::text$$, pg_temp.v('kh_q2')));
select pg_temp.as_user('Q_ADM');
select pg_temp.api(format($$select wf.act(%L, 'APPROVE')$$, pg_temp.req(pg_temp.v('kh_q2'))));
select pg_temp.blocked(format($$select wf.act(%L, 'APPROVE')$$, pg_temp.req(pg_temp.v('kh_q2'))), 'đã duyệt bước trước',
  'Người đã duyệt bước 1 không duyệt tiếp bước 2 khi còn người khác');
select pg_temp.as_user('Q_CT');
select pg_temp.api(format($$select wf.act(%L, 'APPROVE')$$, pg_temp.req(pg_temp.v('kh_q2'))));
select pg_temp.ok((select status from plan.production_plans where id = pg_temp.v('kh_q2')) = 'APPROVED', 'Người được giao bước 2 duyệt xong');
-- Bước 2 chỉ còn đúng người đã duyệt bước 1 → được duyệt tiếp, lịch sử ghi rõ
select pg_temp.as_user('Q_BGD');
select pg_temp.api(format($$select wf.submit('PLAN', %L, '', 'Thử')::text$$, pg_temp.v('kh_q3')));
insert into t select 'rq3', pg_temp.req(pg_temp.v('kh_q3'));
select pg_temp.as_user('Q_CT');
select pg_temp.api(format($$select wf.act(%L, 'APPROVE')$$, pg_temp.v('rq3')));
select pg_temp.api(format($$select wf.act(%L, 'APPROVE')$$, pg_temp.v('rq3')));
select pg_temp.ok((select status from plan.production_plans where id = pg_temp.v('kh_q3')) = 'APPROVED'
  and exists (select 1 from wf.approval_actions where request_id = pg_temp.v('rq3') and comment like '[Duyệt tiếp: bước này không còn người khác]%'),
  'Bước không còn người khác: người duyệt bước trước được duyệt tiếp, lịch sử ghi rõ');

-- ================================================================ 1. L1: hồ sơ Quản trị lập; Quản trị hủy quy trình (migration 2900)
select pg_temp.as_user('Q_ADM');
select pg_temp.api(format($$select wf.submit('PLAN', %L, '', 'Quản trị lập')::text$$, pg_temp.v('kh_q4')));
insert into t select 'rq4', pg_temp.req(pg_temp.v('kh_q4'));
select pg_temp.blocked(format($$select wf.act(%L, 'APPROVE')$$, pg_temp.v('rq4')), 'Người lập không tự duyệt', 'Quản trị vẫn không tự duyệt hồ sơ mình lập');
select pg_temp.api(format($$select app.admin_cancel_request(%L, 'Hồ sơ kẹt, lập lại')::text$$, pg_temp.v('rq4')));
select pg_temp.ok((select status from wf.approval_requests where id = pg_temp.v('rq4')) = 'CANCELLED'
  and (select status from plan.production_plans where id = pg_temp.v('kh_q4')) = 'DRAFT',
  'Quản trị hủy được quy trình của hồ sơ chính mình lập: hồ sơ về Nháp');
select pg_temp.blocked(format($$select wf.act(%L, 'APPROVE')$$, gen_random_uuid()), 'Không tìm thấy yêu cầu', 'Yêu cầu không tồn tại báo rõ');
select pg_temp.ok(pg_temp.api(format($$select wf.submit('PLAN', %L, '', 'Gửi lại')::text$$, pg_temp.v('kh_q4'))) is not null, 'Sau khi hủy, người lập gửi duyệt lại được');

-- Quá hạn mà bước không còn ai duyệt được → báo Quản trị
select pg_temp.as_user('Q_BGD');
select pg_temp.api(format($$select wf.submit('PLAN', %L, '', 'Thử')::text$$, pg_temp.v('kh_q5')));
update wf.approval_requests set step_started_at = now() - interval '25 hours' where id = pg_temp.req(pg_temp.v('kh_q5'));
update core.profiles set status = 'INACTIVE' where employee_code in ('Q_SXTP', 'Q_CT');
select wf.check_sla();
select pg_temp.ok(exists (select 1 from wf.notifications where user_id = pg_temp.uid('Q_ADM') and title = 'Không ai duyệt được: KH-Q5'),
  'Quá hạn mà không còn người duyệt: báo Quản trị');
update core.profiles set status = 'ACTIVE' where employee_code in ('Q_SXTP', 'Q_CT');

-- ================================================================ 2. L2: NV kho thành phẩm xem đơn bán
insert into sales.sales_orders (so_no, customer_id, label_brand, required_date, status)
select 'SO-Q1', id, 'KAVIX', current_date + 7, 'APPROVED' from core.partners where code = 'KAVIX';
select pg_temp.as_user('Q_KHONV');
select pg_temp.ok(pg_temp.api($$select count(*)::text from sales.sales_orders where so_no = 'SO-Q1'$$) = '1', 'NV kho thành phẩm xem được đơn bán (lệnh giao, hàng đã giữ)');

-- ================================================================ 3. L3: mã sản phẩm IN HOA
select pg_temp.ok(not exists (select 1 from master.products where code <> upper(code)), 'Mọi mã sản phẩm đã viết IN HOA (1p5 → 1P5)');
select pg_temp.ok(exists (select 1 from master.products where code = 'PFR-2C-1P5'), 'PFR-2C-1p5 đổi thành PFR-2C-1P5');
do $$ begin
  begin
    insert into master.products (code, group_code, description) values ('PFR-2C-9p5', (select group_code from master.products limit 1), 'x');
    raise exception 'FAIL: mã chữ thường lẽ ra bị chặn';
  exception when check_violation then insert into r(msg) values ('Database chặn mã sản phẩm chữ thường');
  end;
  begin
    insert into master.materials (code, name, uom) values ('cu-test', 'x', 'kg');
    raise exception 'FAIL: mã vật tư chữ thường lẽ ra bị chặn';
  exception when check_violation then insert into r(msg) values ('Database chặn mã vật tư chữ thường');
  end;
end $$;
select pg_temp.as_user('Q_KTTP');
select pg_temp.blocked($$select app.create_spec('PFR-2C-9p5', null, 'x', (select current_spec_id from master.products where code = 'PFR-2C-1P5'))$$,
  'IN HOA', 'Tạo mã mới chữ thường bị chặn, báo viết IN HOA');

-- ================================================================ 4. L4: phát hành spec mới → kế hoạch, lệnh SX nháp dùng bản mới
select set_config('bmt.wf_release', 'on', true);
select master.release_spec(p.current_spec_id) from master.products p join master.product_specs s on s.id = p.current_spec_id
 where p.code = 'PFR-2C-1P5' and s.status <> 'RELEASED';
select set_config('bmt.wf_release', 'off', true);
insert into t select 'v1', current_spec_id from master.products where code = 'PFR-2C-1P5';
insert into plan.production_plans (plan_no, period_label, material_need_date, status) values ('KH-Q6', 'Thử', current_date + 10, 'APPROVED'), ('KH-Q7', 'Thử', current_date + 10, 'CLOSED');
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, run_lots, m_per_pack, pack_type, brand)
select pp.id, p.id, p.current_spec_id, 1000, 1, 500, 'Bobin gỗ', 'KAVIX' from plan.production_plans pp, master.products p
 where pp.plan_no in ('KH-Q6', 'KH-Q7') and p.code = 'PFR-2C-1P5';
insert into mfg.work_orders (wo_no, product_id, spec_id, bom_id, qty_m, m_per_pack, pack_type, brand)
select 'LSX-Q1', p.id, p.current_spec_id, h.id, 1000, 500, 'Bobin gỗ', 'KAVIX'
from master.products p join master.bom_headers h on h.spec_id = p.current_spec_id where p.code = 'PFR-2C-1P5';
select pg_temp.as_user('Q_KTTP');
insert into t select 'v2', pg_temp.api(format($$select master.new_spec_version(%L, 'MAJOR')::text$$, pg_temp.v('v1')))::uuid;
select set_config('bmt.wf_release', 'on', true);
select master.release_spec(pg_temp.v('v2'));
select set_config('bmt.wf_release', 'off', true);
select pg_temp.ok((select l.spec_id from plan.plan_lines l join plan.production_plans pp on pp.id = l.plan_id where pp.plan_no = 'KH-Q6') = pg_temp.v('v2'),
  'Kế hoạch đã duyệt: dòng chuyển sang spec mới phát hành');
select pg_temp.ok((select l.spec_id from plan.plan_lines l join plan.production_plans pp on pp.id = l.plan_id where pp.plan_no = 'KH-Q7') = pg_temp.v('v1'),
  'Kế hoạch đã đóng giữ nguyên spec cũ');
select pg_temp.ok((select spec_id = pg_temp.v('v2') and bom_id = (select id from master.bom_headers where spec_id = pg_temp.v('v2')) from mfg.work_orders where wo_no = 'LSX-Q1'),
  'Lệnh SX nháp chuyển sang spec + BOM mới');
select pg_temp.ok(exists (select 1 from wf.notifications where user_id = pg_temp.uid('Q_BGD') and title like 'Spec PFR-2C-1P5 v% đã phát hành' and body like '%KH-Q6%'),
  'Giám đốc được báo kế hoạch nào đã chuyển spec');

-- ================================================================ 6. L7: module máy – đề xuất và báo việc chờ
select pg_temp.as_user('Q_SXTP');
insert into t select 'sp', pg_temp.api($$insert into master.machine_speeds (machine_id, op_code, std_mpm, setup_min, source)
  select id, 'CD2', 70, 30, 'BMT' from master.machines where code = 'EXT-SI-01' returning id::text$$)::uuid;
select pg_temp.ok(pg_temp.v('sp') is not null, 'Quản lý SX đề xuất được tốc độ chuẩn');
select pg_temp.ok(exists (select 1 from wf.notifications where user_id = pg_temp.uid('Q_KTTP') and title = 'Tốc độ chuẩn chờ duyệt: EXT-SI-01'),
  'TP Kỹ thuật/QA được báo tốc độ chờ duyệt');
select pg_temp.as_user('Q_KTTP');
select pg_temp.api(format($$select app.approve_machine_speed(%L)::text$$, pg_temp.v('sp')));
select pg_temp.ok((select status from master.machine_speeds where id = pg_temp.v('sp')) = 'APPROVED', 'TP Kỹ thuật/QA duyệt tốc độ do Quản lý SX đề xuất');
select pg_temp.as_user('Q_SXTP');
select pg_temp.api($$select app.set_operator_skill((select id from master.machines where code = 'EXT-TP-01'), 'NV3', 'LEARNING', 'Đào tạo')::text$$);
select pg_temp.ok(exists (select 1 from wf.notifications where user_id = pg_temp.uid('Q_KTTP') and title = 'Tay nghề chờ ký: NV3 · EXT-TP-01'),
  'TP Kỹ thuật/QA được báo tay nghề chờ ký');
select pg_temp.as_user('Q_KTTP');
select pg_temp.api($$select app.sign_operator_skill((select id from master.machines where code = 'EXT-TP-01'), 'NV3')::text$$);
select pg_temp.ok((select signed_by = pg_temp.uid('Q_KTTP') from master.operator_skills where operator_code = 'NV3' and machine_code = 'EXT-TP-01'),
  'TP Kỹ thuật/QA ký tay nghề do Quản lý SX giao');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
rollback;
