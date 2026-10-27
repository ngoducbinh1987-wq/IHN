-- Kiểm thử migration 20261026004200: duyệt kế hoạch tháng TP SX lập, chạy MRP → Giám đốc duyệt → Chủ tịch HĐQT chốt;
-- ở bước chốt Chủ tịch sửa sản lượng, thêm mã, bỏ mã (MRP tự chạy lại, ghi lịch sử, báo người lập và Giám đốc khi chốt).
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create temp table t (k text primary key, v uuid);
grant all on r, t to authenticated;
grant usage on sequence r_n_seq to authenticated;

create function pg_temp.as_user(p_code text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', (select id::text from core.profiles where employee_code = p_code), true),
         set_config('request.jwt.claims', json_build_object('sub', (select id::text from core.profiles where employee_code = p_code), 'role', 'authenticated')::text, true),
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
-- Chạy một câu lệnh như qua API (role authenticated, có RLS); trả số dòng bị ảnh hưởng hoặc lỗi
create function pg_temp.api_rows(p_sql text) returns text language plpgsql as $$
declare n int;
begin
  set local role authenticated;
  execute p_sql;
  get diagnostics n = row_count;
  reset role;
  return n::text;
exception when others then
  reset role;
  return 'ERR ' || sqlerrm;
end $$;
create function pg_temp.today() returns date language sql as $$ select (now() at time zone 'Asia/Ho_Chi_Minh')::date $$;
create function pg_temp.line(p_code text) returns uuid language sql as $$
  select l.id from plan.plan_lines l join master.products p on p.id = l.product_id
   where l.plan_id = (select v from t where k = 'plan') and p.code = p_code
$$;
create function pg_temp.req() returns uuid language sql as $$
  select id from wf.approval_requests where doc_id = (select v from t where k = 'plan') order by submitted_at desc limit 1
$$;
set client_min_messages = notice;

-- Người dùng thử: Chủ tịch, Giám đốc (cùng vai trò Ban giám đốc), TP SX, TP Mua, Quản trị
with u(code) as (values ('H_CT'),('H_GD'),('H_SXTP'),('H_MUATP'),('H_ADM')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('H_CT','BGD'),('H_GD','BGD'),('H_SXTP','SX_TP'),('H_MUATP','MUA_TP'),('H_ADM','ADMIN')) u(code, role)
  on u.code = p.employee_code;
update core.profiles set status = 'LOCKED' where (employee_code is null or employee_code !~ '^H_') and status = 'ACTIVE';

-- ================================================================ 1. Cấu hình quy trình
select pg_temp.ok((select string_agg(level_label || ':' || role_code, ' | ' order by seq) from wf.approval_steps where doc_type = 'PLAN' and enabled)
  = 'Giám đốc duyệt kế hoạch tháng:BGD | Chủ tịch HĐQT chốt kế hoạch tháng:BGD', 'Kế hoạch tháng: bước 1 Giám đốc duyệt, bước 2 Chủ tịch HĐQT chốt');
select pg_temp.ok((select submit_role is null and submit_label = 'TP SX lập kế hoạch tháng, chạy MRP' from wf.approval_flows where doc_type = 'PLAN'),
  'TP SX lập kế hoạch tháng, chạy MRP');
select pg_temp.ok((select enabled and cardinality(steps) = 1 from (select bool_and(enabled) enabled, array_agg(seq) steps from wf.approval_steps where doc_type = 'PLAN_ADJ') x),
  'Phiếu điều chỉnh kế hoạch tháng giữ nguyên một bước Chủ tịch');
-- Giao đích danh như cấu hình thật: bước 1 Giám đốc, bước 2 Chủ tịch
update wf.approval_steps set assignee_ids = array[pg_temp.uid('H_GD')] where doc_type = 'PLAN' and seq = 1;
update wf.approval_steps set assignee_ids = array[pg_temp.uid('H_CT')] where doc_type = 'PLAN' and seq = 2;
select pg_temp.ok(plan.chair_ids() = array[pg_temp.uid('H_CT')], 'Chủ tịch = người được giao bước cuối kế hoạch tháng');

-- Spec phát hành (database mới chưa phát hành)
do $$
declare c text;
begin
  perform set_config('bmt.wf_release', 'on', true);
  foreach c in array array['PFR-2C-1P5', 'SIF-1C-1P5'] loop
    if (select s.status from master.products p join master.product_specs s on s.id = p.current_spec_id where p.code = c) <> 'RELEASED' then
      perform master.release_spec((select current_spec_id from master.products where code = c));
    end if;
  end loop;
  perform set_config('bmt.wf_release', 'off', true);
end $$;

-- Kế hoạch tháng: PFR-2C-1P5 10.000 m, SIF-1C-1P5 5.000 m
select pg_temp.as_user('H_SXTP');
insert into plan.production_plans (plan_no, period_label, material_need_date) values ('KH-T42', 'Thử 4200', pg_temp.today() + 10);
insert into t select 'plan', id from plan.production_plans where plan_no = 'KH-T42';
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, run_lots, m_per_pack, pack_type, brand)
select (select v from t where k = 'plan'), p.id, p.current_spec_id, x.qty, 1, x.mpp, x.pack, 'KAVIX'
from (values ('PFR-2C-1P5', 10000, 500, 'Bobin gỗ'), ('SIF-1C-1P5', 5000, 200, 'Cuộn PE')) x(code, qty, mpp, pack)
join master.products p on p.code = x.code;
insert into t select 'run1', plan.run_mrp((select v from t where k = 'plan'));

-- ================================================================ 2. Gửi duyệt, bước Giám đốc
insert into t select 'req', wf.submit('PLAN', (select v from t where k = 'plan'), 'KH-T42', 'Thử');
select pg_temp.ok(exists (select 1 from wf.notifications where user_id = pg_temp.uid('H_GD') and title = 'Chờ duyệt: KH-T42')
  and not exists (select 1 from wf.notifications where user_id = pg_temp.uid('H_CT') and title = 'Chờ duyệt: KH-T42'),
  'Gửi duyệt: Giám đốc nhận thông báo trước, Chủ tịch chưa nhận');
select pg_temp.as_user('H_CT');
select pg_temp.fails($$select wf.act((select v from t where k = 'req'), 'APPROVE')$$, 'cần vai trò', 'Chủ tịch không duyệt thay bước Giám đốc');
select pg_temp.fails($$select app.plan_chair_save_line((select v from t where k = 'plan'), pg_temp.line('PFR-2C-1P5'), null, 12000, 1, 'Bobin gỗ', 500, 'KAVIX', 'Tăng')$$,
  'Chỉ sửa kế hoạch ở bước', 'Đang ở bước Giám đốc: Chủ tịch chưa sửa được');
select pg_temp.as_user('H_GD');
select pg_temp.fails($$select app.plan_chair_save_line((select v from t where k = 'plan'), pg_temp.line('PFR-2C-1P5'), null, 12000, 1, 'Bobin gỗ', 500, 'KAVIX', 'Tăng')$$,
  'Chỉ sửa kế hoạch ở bước', 'Giám đốc duyệt hoặc trả lại, không sửa kế hoạch');
-- TP SX không sửa được dòng khi đã gửi duyệt (RLS chỉ cho sửa khi Nháp)
select pg_temp.as_user('H_SXTP');
select pg_temp.ok(pg_temp.api_rows(format($$update plan.plan_lines set qty_m = 1 where id = %L$$, pg_temp.line('PFR-2C-1P5'))) = '0',
  'TP SX không sửa dòng kế hoạch khi đang chờ duyệt');
select pg_temp.as_user('H_GD');
select wf.act((select v from t where k = 'req'), 'APPROVE', 'Đồng ý');
select pg_temp.ok((select status from plan.production_plans where id = (select v from t where k = 'plan')) = 'PENDING_APPROVAL'
  and exists (select 1 from wf.notifications where user_id = pg_temp.uid('H_CT') and title = 'Chờ duyệt: KH-T42'),
  'Giám đốc duyệt → chuyển Chủ tịch chốt, Chủ tịch nhận thông báo');
select pg_temp.fails($$select wf.act((select v from t where k = 'req'), 'APPROVE')$$, 'cần vai trò', 'Giám đốc không chốt thay Chủ tịch');

-- ================================================================ 3. Chủ tịch chỉnh khi chốt
select pg_temp.as_user('H_SXTP');
select pg_temp.fails($$select app.plan_chair_save_line((select v from t where k = 'plan'), pg_temp.line('PFR-2C-1P5'), null, 12000, 1, 'Bobin gỗ', 500, 'KAVIX', 'Tăng')$$,
  'Chỉ người chốt kế hoạch', 'TP SX không sửa ở bước chốt');
select pg_temp.as_user('H_CT');
select pg_temp.fails($$select app.plan_chair_save_line((select v from t where k = 'plan'), pg_temp.line('PFR-2C-1P5'), null, 12000, 1, 'Bobin gỗ', 500, 'KAVIX', ' ')$$,
  'lý do', 'Chủ tịch sửa phải ghi lý do');
select pg_temp.fails($$select app.plan_chair_save_line((select v from t where k = 'plan'), pg_temp.line('PFR-2C-1P5'), null, 0, 1, 'Bobin gỗ', 500, 'KAVIX', 'x')$$,
  'lớn hơn 0', 'Sản lượng 0: phải dùng Bỏ mã');
select pg_temp.fails($$select app.plan_chair_save_line((select v from t where k = 'plan'), pg_temp.line('PFR-2C-1P5'), null, 10000, 1, 'Bobin gỗ', 500, 'KAVIX', 'x')$$,
  'Không có thay đổi', 'Không thay đổi gì thì báo');
select app.plan_chair_save_line((select v from t where k = 'plan'), pg_temp.line('PFR-2C-1P5'), null, 12000, 2, 'Bobin gỗ', 500, 'KAVIX', 'Khách tăng đơn');
select pg_temp.ok((select qty_m = 12000 and run_lots = 2 from plan.plan_lines where id = pg_temp.line('PFR-2C-1P5')), 'Chủ tịch tăng sản lượng PFR-2C-1P5 lên 12.000 m');
select pg_temp.ok((select count(*) from plan.mrp_runs where plan_id = (select v from t where k = 'plan')) = 2
  and not (select mrp_stale from plan.production_plans where id = (select v from t where k = 'plan'))
  and (select total_m from plan.mrp_runs where plan_id = (select v from t where k = 'plan') order by run_at desc, id limit 1) = 17000,
  'Sửa xong MES tự chạy lại MRP (17.000 m), không còn cờ cần chạy lại');
select pg_temp.ok((select summary like 'Thử 4200: 2 SKU, 17.000 m%' from wf.approval_requests where id = (select v from t where k = 'req')),
  'Tóm tắt hồ sơ duyệt cập nhật theo số mới');
-- Thêm mã: chưa phát hành spec thì chặn; mã đã có thì chặn; mã đã phát hành thì thêm được
-- Mã chưa phát hành spec: SFR-2P-1 (dữ liệu thật đã phát hành thì tạm đưa spec về nháp trong giao dịch thử)
update master.product_specs set status = 'DRAFT' where id = (select current_spec_id from master.products where code = 'SFR-2P-1') and status = 'RELEASED';
insert into t select 'draft_prod', id from master.products where code = 'SFR-2P-1';
select pg_temp.fails($$select app.plan_chair_save_line((select v from t where k = 'plan'), null, (select v from t where k = 'draft_prod'), 3000, 1, 'Bobin gỗ', 500, 'KAVIX', 'Thêm')$$,
  'chưa phát hành spec', 'Thêm mã chưa phát hành spec vào kế hoạch chính thức: chặn');
select pg_temp.fails($$select app.plan_chair_save_line((select v from t where k = 'plan'), null, (select id from master.products where code = 'SIF-1C-1P5'), 3000, 1, 'Cuộn PE', 200, 'KAVIX', 'Thêm')$$,
  'đã có trong kế hoạch', 'Thêm mã đã có: chặn, sửa dòng có sẵn');
-- Bỏ mã SIF rồi thêm lại với số khác
select app.plan_chair_remove_line(pg_temp.line('SIF-1C-1P5'), 'Chuyển sang tháng sau');
select pg_temp.ok(pg_temp.line('SIF-1C-1P5') is null, 'Chủ tịch bỏ mã SIF-1C-1P5');
select pg_temp.fails($$select app.plan_chair_remove_line(pg_temp.line('PFR-2C-1P5'), 'Bỏ hết')$$, 'ít nhất một mã', 'Không bỏ mã cuối cùng: dùng Trả lại');
select app.plan_chair_save_line((select v from t where k = 'plan'), null, (select id from master.products where code = 'SIF-1C-1P5'), 3000, 1, 'Cuộn PE', 200, 'HEIZKA', 'Làm 3.000 m nhãn HEIZKA');
select pg_temp.ok((select qty_m = 3000 and brand = 'HEIZKA' from plan.plan_lines where id = pg_temp.line('SIF-1C-1P5')), 'Chủ tịch thêm mã SIF-1C-1P5 3.000 m');
select pg_temp.ok((select string_agg(action, ',' order by id) from plan.plan_chair_edits where plan_id = (select v from t where k = 'plan')) = 'EDIT,REMOVE,ADD'
  and (select count(*) from app.v_plan_chair_edits where plan_id = (select v from t where k = 'plan') and edited_by_name = 'Test h_ct') = 3,
  'Lịch sử chỉnh: sửa, bỏ, thêm (người, lý do)');
select pg_temp.ok((select count(*) from plan.mrp_runs where plan_id = (select v from t where k = 'plan')) = 4
  and (select total_m from plan.mrp_runs where plan_id = (select v from t where k = 'plan') order by run_at desc, id limit 1) = 15000,
  'MRP chạy lại sau mỗi lần sửa (15.000 m)');

-- ================================================================ 4. Chốt
select wf.act((select v from t where k = 'req'), 'APPROVE', 'Chốt');
select pg_temp.ok((select status from plan.production_plans where id = (select v from t where k = 'plan')) = 'APPROVED', 'Chủ tịch chốt: kế hoạch Đã duyệt');
select pg_temp.ok((select body like 'PFR-2C-1P5: 10.000 → 12.000 m; SIF-1C-1P5: bỏ (5.000 m); SIF-1C-1P5: thêm 3.000 m%' from wf.notifications
                   where user_id = pg_temp.uid('H_SXTP') and title = 'Chủ tịch đã chỉnh khi chốt KH-T42')
  and exists (select 1 from wf.notifications where user_id = pg_temp.uid('H_GD') and title = 'Chủ tịch đã chỉnh khi chốt KH-T42'),
  'Chốt xong báo TP SX và Giám đốc các dòng Chủ tịch đã chỉnh');
select pg_temp.fails($$select app.plan_chair_save_line((select v from t where k = 'plan'), pg_temp.line('PFR-2C-1P5'), null, 13000, 1, 'Bobin gỗ', 500, 'KAVIX', 'x')$$,
  'không ở trạng thái chờ duyệt', 'Đã chốt: không sửa trực tiếp nữa (dùng phiếu điều chỉnh)');
select pg_temp.as_user('H_SXTP');
insert into t select 'pr', plan.create_pr_from_mrp((select id from plan.mrp_runs where plan_id = (select v from t where k = 'plan') order by run_at desc, id limit 1));
select pg_temp.ok((select count(*) > 0 from purchase.pr_lines where pr_id = (select v from t where k = 'pr')), 'TP SX sinh đề xuất mua từ MRP sau khi Chủ tịch chốt');

-- ================================================================ 5. Trả lại, Quản trị
insert into plan.production_plans (plan_no, period_label, material_need_date) values ('KH-T42B', 'Thử 4200 B', pg_temp.today() + 10);
insert into t select 'plan2', id from plan.production_plans where plan_no = 'KH-T42B';
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, run_lots, m_per_pack, pack_type, brand)
select (select v from t where k = 'plan2'), p.id, p.current_spec_id, 2000, 1, 500, 'Bobin gỗ', 'KAVIX' from master.products p where p.code = 'PFR-2C-1P5';
select plan.run_mrp((select v from t where k = 'plan2'));
insert into t select 'req2', wf.submit('PLAN', (select v from t where k = 'plan2'), 'KH-T42B', 'Thử');
select pg_temp.as_user('H_GD');
select wf.act((select v from t where k = 'req2'), 'APPROVE');
select pg_temp.as_user('H_ADM');
select app.plan_chair_save_line((select v from t where k = 'plan2'), (select id from plan.plan_lines where plan_id = (select v from t where k = 'plan2')), null,
  2500, 1, 'Bobin gỗ', 500, 'KAVIX', 'Quản trị chỉnh thay');
select pg_temp.ok((select qty_m from plan.plan_lines where plan_id = (select v from t where k = 'plan2')) = 2500, 'Quản trị sửa được ở bước chốt (như duyệt mọi bước)');
select pg_temp.as_user('H_CT');
select wf.act((select v from t where k = 'req2'), 'REJECT', 'Làm lại theo đơn mới');
select pg_temp.ok((select status from plan.production_plans where id = (select v from t where k = 'plan2')) = 'DRAFT',
  'Chủ tịch trả lại: kế hoạch về Nháp để TP SX sửa');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
