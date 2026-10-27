-- Kiểm thử migration 20261026004500_plan_month_revise: kế hoạch theo tháng/năm (một tháng một kế hoạch, chính thức),
-- đề xuất hiệu chỉnh kế hoạch tháng TP SX → Giám đốc → Chủ tịch, bảng MRP hiệu chỉnh: tăng thì mua thêm, giảm thì
-- giảm đề xuất mua chưa duyệt của kế hoạch, đề xuất Giám đốc đã duyệt giữ nguyên.
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create temp table t (k text primary key, v uuid);
create temp table j (k text primary key, v jsonb);

create function pg_temp.as_user(p_code text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', (select id::text from core.profiles where employee_code = p_code), true),
         set_config('request.jwt.claims', json_build_object('sub', (select id::text from core.profiles where employee_code = p_code), 'role', 'authenticated')::text, true),
         set_config('request.jwt.claim.role', 'authenticated', true)
$$;
create function pg_temp.uid(p_code text) returns uuid language sql as $$ select id from core.profiles where employee_code = p_code $$;
create function pg_temp.v(p_k text) returns uuid language sql as $$ select v from t where k = p_k $$;
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
-- số lượng một vật tư trong đề xuất mua
create function pg_temp.prq(p_pr uuid, p_code text) returns numeric language sql as $$
  select coalesce(sum(l.qty), 0) from purchase.pr_lines l join master.materials m on m.id = l.material_id and m.code = p_code where l.pr_id = p_pr
$$;
-- dòng của bảng MRP hiệu chỉnh theo mã vật tư
create function pg_temp.row(p_res jsonb, p_code text) returns jsonb language sql as $$
  select e from jsonb_array_elements(p_res -> 'rows') e where e ->> 'code' = p_code
$$;
-- lập, gửi, duyệt (Giám đốc → Chủ tịch) một đề xuất hiệu chỉnh đổi sản lượng dòng kế hoạch
create function pg_temp.revise(p_key text, p_qty numeric) returns void language plpgsql as $$
declare v_adj uuid; v_req uuid;
begin
  perform pg_temp.as_user('V_SXKH');
  v_adj := app.adj_create(pg_temp.v('plan'), 'Khách đổi sản lượng ' || p_qty);
  perform app.adj_save(v_adj, null, jsonb_build_array(jsonb_build_object('kind', 'QTY', 'plan_line_id', pg_temp.v('line'), 'qty_m', p_qty)));
  insert into j values (p_key || '_preview', app.adj_mrp(v_adj));
  v_req := app.adj_submit(v_adj);
  perform pg_temp.as_user('V_GD');
  perform wf.act(v_req, 'APPROVE', null);
  perform pg_temp.as_user('V_CT');
  perform wf.act(v_req, 'APPROVE', null);
  insert into t values (p_key, v_adj), (p_key || '_req', v_req);
  insert into j select p_key, mrp_result from plan.plan_adjustments where id = v_adj;
end $$;
set client_min_messages = notice;

with u(code) as (values ('V_CT'),('V_GD'),('V_SXKH'),('V_MUATP'),('V_VH')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('V_CT','BGD'),('V_GD','BGD'),('V_SXKH','SX_KH'),('V_MUATP','MUA_TP'),('V_VH','VAN_HANH')) u(code, role)
  on u.code = p.employee_code;
update core.profiles set status = 'LOCKED' where (employee_code is null or employee_code !~ '^V_') and status = 'ACTIVE';
update wf.approval_steps set assignee_ids = array[pg_temp.uid('V_GD')] where doc_type in ('PR', 'PLAN_ADJ') and seq = 1;
update wf.approval_steps set assignee_ids = array[pg_temp.uid('V_CT')] where doc_type = 'PLAN_ADJ' and seq = 2;
update wf.approval_flows set submit_role = null, submit_user_ids = '{}' where doc_type in ('PR', 'PLAN_ADJ');

do $$ begin
  if (select s.status from master.products p join master.product_specs s on s.id = p.current_spec_id where p.code = 'PFR-2C-1P5') <> 'RELEASED' then
    perform set_config('bmt.wf_release', 'on', true);
    perform master.release_spec((select current_spec_id from master.products where code = 'PFR-2C-1P5'));
  end if;
end $$;

-- ================================================================ 1. Kế hoạch tháng: chọn tháng + năm, một tháng một kế hoạch
select pg_temp.ok((select string_agg(level_label, ' → ' order by seq) from wf.approval_steps where doc_type = 'PLAN_ADJ' and enabled)
  = 'Giám đốc duyệt đề xuất hiệu chỉnh kế hoạch tháng → Chủ tịch HĐQT duyệt hiệu chỉnh kế hoạch tháng'
  and (select name from wf.approval_flows where doc_type = 'PLAN_ADJ') = 'Đề xuất hiệu chỉnh kế hoạch tháng',
  'Đề xuất hiệu chỉnh kế hoạch tháng: TP SX lập → Giám đốc duyệt → Chủ tịch HĐQT duyệt');
-- tháng còn trống của năm sau (dữ liệu thật có thể đã có vài tháng)
insert into j select 'ym', to_jsonb(min(d)::date) from generate_series(make_date(extract(year from pg_temp.today())::int + 1, 1, 1),
  make_date(extract(year from pg_temp.today())::int + 1, 12, 1), interval '1 month') d
  where not exists (select 1 from plan.production_plans where period_month = d::date and status <> 'CANCELLED');
select pg_temp.as_user('V_VH');
select pg_temp.fails($$select app.create_plan(2027, 1, current_date)$$, 'quyền', 'Công nhân không lập kế hoạch tháng');
select pg_temp.as_user('V_SXKH');
select pg_temp.fails($$select app.create_plan(extract(year from pg_temp.today())::int, 13, pg_temp.today())$$, '1–12', 'Tháng phải từ 1 đến 12');
select pg_temp.fails($$select app.create_plan(extract(year from pg_temp.today())::int + 2, 1, pg_temp.today())$$, 'Chọn năm', 'Chỉ năm nay hoặc năm sau');
select pg_temp.fails($$select app.create_plan(extract(year from pg_temp.today())::int, 5, null)$$, 'ngày cần vật tư', 'Bắt buộc ngày cần vật tư');
insert into t select 'mplan', app.create_plan(extract(year from (select (v #>> '{}')::date from j where k = 'ym'))::int,
  extract(month from (select (v #>> '{}')::date from j where k = 'ym'))::int, pg_temp.today() + 30);
select pg_temp.ok((select mode = 'OFFICIAL' and status = 'DRAFT' and period_month = (select (v #>> '{}')::date from j where k = 'ym')
                          and period_label = 'Tháng ' || to_char(period_month, 'MM/YYYY') and created_by = pg_temp.uid('V_SXKH')
                   from plan.production_plans where id = pg_temp.v('mplan')),
  'Lập kế hoạch tháng: nhãn "Tháng MM/YYYY", chế độ chính thức, người lập là TP SX');
select pg_temp.fails(format($$select app.create_plan(%s, %s, pg_temp.today())$$,
  extract(year from (select (v #>> '{}')::date from j where k = 'ym'))::int, extract(month from (select (v #>> '{}')::date from j where k = 'ym'))::int),
  'Đề xuất hiệu chỉnh', 'Một tháng một kế hoạch: tháng đã có kế hoạch thì phải lập đề xuất hiệu chỉnh');

-- ================================================================ 2. Kế hoạch đã duyệt + đề xuất mua Giám đốc đã duyệt
select pg_temp.as_user('V_SXKH');
insert into plan.production_plans (plan_no, period_label, material_need_date, status) values ('KH-T45', 'Thử 4500', pg_temp.today() + 10, 'DRAFT');
insert into t select 'plan', id from plan.production_plans where plan_no = 'KH-T45';
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, run_lots, m_per_pack, pack_type, brand, due_date)
select pg_temp.v('plan'), p.id, p.current_spec_id, 10000, 1, 500, 'Bobin gỗ', 'KAVIX', pg_temp.today() + 20
from master.products p where p.code = 'PFR-2C-1P5';
insert into t select 'line', id from plan.plan_lines where plan_id = pg_temp.v('plan');
update plan.production_plans set status = 'APPROVED' where id = pg_temp.v('plan');
insert into t select 'run0', app.plan_run_mrp(pg_temp.v('plan'));
insert into t select 'pr1', plan.create_pr_from_mrp(pg_temp.v('run0'));
insert into t select 'pr1_req', wf.submit('PR', pg_temp.v('pr1'), (select pr_no from purchase.purchase_requests where id = pg_temp.v('pr1')), 'thử');
select pg_temp.as_user('V_GD');
select wf.act(pg_temp.v('pr1_req'), 'APPROVE', null);
create temp table pr1_before as select material_id, qty from purchase.pr_lines where pr_id = pg_temp.v('pr1');
select pg_temp.ok((select status = 'APPROVED' from purchase.purchase_requests where id = pg_temp.v('pr1')) and pg_temp.prq(pg_temp.v('pr1'), 'CU-024') > 0,
  'Kế hoạch 10.000 m: đề xuất mua PR1 (có đồng) Giám đốc đã duyệt');

-- ================================================================ 3. Hiệu chỉnh tăng 10.000 → 14.000 m: MRP hiệu chỉnh ra số mua thêm
select pg_temp.revise('up', 14000);
select pg_temp.ok((select status = 'APPROVED' and mrp_run_id is not null from plan.plan_adjustments where id = pg_temp.v('up'))
  and (select qty_m = 14000 from plan.plan_lines where id = pg_temp.v('line'))
  and (select not mrp_stale from plan.production_plans where id = pg_temp.v('plan')),
  'Giám đốc rồi Chủ tịch duyệt: MES áp 14.000 m và chạy MRP hiệu chỉnh ngay (không còn cờ chạy lại MRP)');
select pg_temp.ok((select (v ->> 'buy_count')::int > 0 and (v ->> 'cut_count')::int = 0 from j where k = 'up')
  and (select pg_temp.row(v, 'CU-024') ->> 'action' = 'BUY' and (pg_temp.row(v, 'CU-024') ->> 'buy_more')::numeric > 0
              and (pg_temp.row(v, 'CU-024') ->> 'approved')::numeric = pg_temp.prq(pg_temp.v('pr1'), 'CU-024')
              and (pg_temp.row(v, 'CU-024') ->> 'delta')::numeric > 0 from j where k = 'up'),
  'Bảng MRP hiệu chỉnh: nhu cầu đồng tăng, đã duyệt mua (PR1) được trừ, ra số đồng mua thêm');
select pg_temp.ok((select (pg_temp.row(p.v, 'CU-024') ->> 'buy_more') = (pg_temp.row(a.v, 'CU-024') ->> 'buy_more') from j p, j a where p.k = 'up_preview' and a.k = 'up')
  and (select (v ->> 'preview')::boolean from j where k = 'up_preview'),
  'Xem trước khi gửi duyệt cho đúng số mua thêm như khi áp thật');
select pg_temp.ok(not exists (select 1 from pr1_before b left join purchase.pr_lines l on l.pr_id = pg_temp.v('pr1') and l.material_id = b.material_id
                              where l.qty is distinct from b.qty), 'PR1 Giám đốc đã duyệt giữ nguyên');
select pg_temp.ok(exists (select 1 from wf.notifications where user_id = pg_temp.uid('V_SXKH') and title like 'Kế hoạch tháng đã hiệu chỉnh%' and body like '%mua thêm%'),
  'TP SX được báo vật tư cần mua thêm');
-- TP SX lập đề xuất mua bổ sung PR2 từ MRP hiệu chỉnh, gửi Giám đốc (chưa duyệt)
select pg_temp.as_user('V_SXKH');
insert into t select 'pr2', plan.create_pr_from_mrp((select mrp_run_id from plan.plan_adjustments where id = pg_temp.v('up')));
insert into t select 'pr2_req', wf.submit('PR', pg_temp.v('pr2'), (select pr_no from purchase.purchase_requests where id = pg_temp.v('pr2')), 'bổ sung');
insert into j select 'cu2', to_jsonb(pg_temp.prq(pg_temp.v('pr2'), 'CU-024'));
insert into j select 'pv2', to_jsonb(pg_temp.prq(pg_temp.v('pr2'), 'PVC-FR'));
select pg_temp.ok((select (v #>> '{}')::numeric > 0 from j where k = 'cu2') and (select (v #>> '{}')::numeric > 0 from j where k = 'pv2'),
  'PR2 (bổ sung) có đồng, nhựa vỏ, đang chờ Giám đốc duyệt');
insert into t select 'run_re', app.plan_run_mrp(pg_temp.v('plan'));
select pg_temp.ok((select ml.requested >= pg_temp.prq(pg_temp.v('pr2'), 'CU-024') and ml.suggest_qty = 0
                   from plan.mrp_lines ml join master.materials m on m.id = ml.material_id and m.code = 'CU-024'
                   where ml.run_id = pg_temp.v('run_re')),
  'Chạy lại MRP: đề xuất mua nháp/chờ duyệt tính vào "đã đề xuất", không đề xuất trùng');

-- ================================================================ 4. Hiệu chỉnh giảm 14.000 → 12.000 m: giảm PR2 chưa duyệt
select pg_temp.as_user('V_SXKH');
insert into t select 'dn', app.adj_create(pg_temp.v('plan'), 'Khách giảm đơn');
select app.adj_save(pg_temp.v('dn'), null, jsonb_build_array(jsonb_build_object('kind', 'QTY', 'plan_line_id', pg_temp.v('line'), 'qty_m', 12000)));
insert into j select 'dn_preview', app.adj_mrp(pg_temp.v('dn'));
select pg_temp.ok((select pg_temp.row(v, 'PVC-FR') ->> 'action' = 'CUT'
                          and (pg_temp.row(v, 'PVC-FR') ->> 'pending_before')::numeric = (select (v #>> '{}')::numeric from j where k = 'pv2')
                          and (pg_temp.row(v, 'PVC-FR') ->> 'pending_after')::numeric < (pg_temp.row(v, 'PVC-FR') ->> 'pending_before')::numeric
                          and (pg_temp.row(v, 'PVC-FR') ->> 'buy_more')::numeric = 0 from j where k = 'dn_preview'),
  'Xem trước MRP hiệu chỉnh: nhựa vỏ thừa → giảm PR2 chưa duyệt, không mua thêm');
select pg_temp.ok((select qty_m = 14000 from plan.plan_lines where id = pg_temp.v('line'))
  and pg_temp.prq(pg_temp.v('pr2'), 'PVC-FR') = (select (v #>> '{}')::numeric from j where k = 'pv2')
  and (select status = 'DRAFT' from plan.plan_adjustments where id = pg_temp.v('dn')),
  'Xem trước không đổi kế hoạch, đề xuất mua (chạy thử rồi hủy)');
insert into t select 'dn_req', app.adj_submit(pg_temp.v('dn'));
select pg_temp.as_user('V_CT');
select pg_temp.fails($$select wf.act(pg_temp.v('dn_req'), 'APPROVE', null)$$, '', 'Chủ tịch chưa duyệt khi Giám đốc chưa duyệt');
select pg_temp.as_user('V_GD');
select pg_temp.ok(wf.act(pg_temp.v('dn_req'), 'APPROVE', null) = 'PENDING', 'Giám đốc duyệt bước 1');
select pg_temp.as_user('V_CT');
select pg_temp.ok(wf.act(pg_temp.v('dn_req'), 'APPROVE', null) = 'APPROVED', 'Chủ tịch duyệt bước 2');
insert into j select 'dn', mrp_result from plan.plan_adjustments where id = pg_temp.v('dn');
select pg_temp.ok(pg_temp.prq(pg_temp.v('pr2'), 'PVC-FR') = (select (pg_temp.row(v, 'PVC-FR') ->> 'pending_after')::numeric from j where k = 'dn_preview')
  and pg_temp.prq(pg_temp.v('pr2'), 'PVC-FR') < (select (v #>> '{}')::numeric from j where k = 'pv2')
  and (select status = 'PENDING_APPROVAL' from purchase.purchase_requests where id = pg_temp.v('pr2')),
  'Duyệt xong: MES giảm nhựa vỏ trong PR2 đúng số đã xem trước, PR2 vẫn chờ Giám đốc duyệt');
select pg_temp.ok(exists (select 1 from wf.approval_actions where request_id = pg_temp.v('pr2_req') and comment like '[Giảm theo hiệu chỉnh kế hoạch PDC-%PVC-FR%')
  and exists (select 1 from wf.notifications where user_id = pg_temp.uid('V_GD') and title like 'Đề xuất mua % giảm theo hiệu chỉnh%'),
  'Lịch sử duyệt PR2 ghi lần giảm; Giám đốc (người duyệt PR2) được báo');
select pg_temp.ok((select wf.doc_hash('purchase.purchase_requests', pg_temp.v('pr2')) = data_hash from wf.approval_requests where id = pg_temp.v('pr2_req')),
  'Mã kiểm PR2 cập nhật: Giám đốc vẫn duyệt được');
select pg_temp.ok(not exists (select 1 from pr1_before b left join purchase.pr_lines l on l.pr_id = pg_temp.v('pr1') and l.material_id = b.material_id
                              where l.qty is distinct from b.qty), 'PR1 Giám đốc đã duyệt vẫn giữ nguyên khi giảm sản lượng');
select pg_temp.ok((select ml.projected >= 0 and ml.suggest_qty = 0 from plan.mrp_lines ml join master.materials m on m.id = ml.material_id and m.code = 'CU-024'
                   where ml.run_id = (select mrp_run_id from plan.plan_adjustments where id = pg_temp.v('dn'))),
  'MRP sau hiệu chỉnh: đồng không thiếu, không đề nghị mua');
select pg_temp.ok((select (pg_temp.row(v, 'CU-024') ->> 'action' = 'PACK' and (pg_temp.row(v, 'CU-024') ->> 'pending_after')::numeric = (select (v #>> '{}')::numeric from j where k = 'cu2'))
                          or (pg_temp.row(v, 'CU-024') ->> 'action' = 'CUT')
                   from j where k = 'dn'),
  'Đồng: giảm theo bội số đóng gói; dư chưa đủ một bội số thì giữ dòng PR2, ghi rõ lý do (PACK)');

-- ================================================================ 5. Giảm sâu 12.000 → 8.000 m (dưới kế hoạch gốc): hủy PR2, giữ PR1
select pg_temp.revise('down', 8000);
select pg_temp.ok((select status = 'CANCELLED' from purchase.purchase_requests where id = pg_temp.v('pr2'))
  and (select status = 'CANCELLED' from wf.approval_requests where id = pg_temp.v('pr2_req')),
  'PR2 chưa duyệt không còn cần: MES hủy đề xuất và dừng quy trình duyệt');
select pg_temp.ok(not exists (select 1 from pr1_before b left join purchase.pr_lines l on l.pr_id = pg_temp.v('pr1') and l.material_id = b.material_id
                              where l.qty is distinct from b.qty)
  and (select status = 'APPROVED' from purchase.purchase_requests where id = pg_temp.v('pr1')),
  'PR1 Giám đốc đã duyệt theo kế hoạch trước giữ nguyên (không giảm)');
select pg_temp.ok((select exists (select 1 from jsonb_array_elements(v -> 'rows') e where e ->> 'action' = 'KEEP' and (e ->> 'approved')::numeric > 0
                                  and (e ->> 'new_need')::numeric < (e ->> 'old_need')::numeric and (e ->> 'buy_more')::numeric = 0)
                   from j where k = 'down'),
  'Bảng MRP hiệu chỉnh ghi "giữ nguyên, đã duyệt mua" cho vật tư giảm nhu cầu chỉ có trong PR1');

-- ================================================================ 6. Xem trước khi phiếu lỗi / đã duyệt
select pg_temp.as_user('V_SXKH');
insert into t select 'empty', app.adj_create(pg_temp.v('plan'), 'Nháp trống');
select pg_temp.ok((select (app.adj_mrp(pg_temp.v('empty')) ->> 'error') like '%chưa có dòng%'), 'Đề xuất chưa có dòng: bảng MRP hiệu chỉnh báo lỗi, không hỏng trang');
select pg_temp.ok((select (app.adj_mrp(pg_temp.v('dn')) ->> 'applied')::boolean and jsonb_array_length(app.adj_mrp(pg_temp.v('dn')) -> 'reductions') > 0),
  'Đề xuất đã duyệt: trả kết quả MRP hiệu chỉnh đã lưu, có danh sách đề xuất mua đã giảm');
select pg_temp.as_user('V_VH');
select pg_temp.ok(not core.has_perm('plan', 'view') or app.adj_mrp(pg_temp.v('dn')) is not null, 'Người có quyền xem kế hoạch xem được bảng MRP hiệu chỉnh');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
