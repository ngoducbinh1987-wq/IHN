-- Kiểm thử migration 20261026009700_adj_mrp_table: Đề xuất hiệu chỉnh kế hoạch tháng – bảng MRP hiệu chỉnh đủ cột
-- (MRP ban đầu, MRP hiện tại, chênh lệch, tồn kho, hàng về, đã đề xuất, dự phòng, thiếu, đề xuất mua, tồn sau SX),
-- nút Chạy MRP hiệu chỉnh, lưu kết quả lần chạy, tự chạy lại khi sửa dòng / kế hoạch chạy MRP lại.
-- Dựng dữ liệu như test_plan_revise (mục 1–2). Chạy bằng psql hoặc Supabase (net.http_get + DO). Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
-- Kho thật đã có tồn khởi tạo (migration 8900, 04/11/2026): kịch bản giả định kho trống → ẩn tồn khởi tạo trong giao dịch (rollback)
delete from inv.stock_moves m using inv.stock_docs d where d.id = m.doc_id and d.doc_type = 'OPENING';
delete from cost.item_valuation v where v.material_id in (select l.material_id from inv.lots l where l.attrs ->> 'opening' = 'true');
delete from inv.stock_balances b using inv.lots l where l.id = b.lot_id and l.attrs ->> 'opening' = 'true';
delete from inv.stock_doc_lines dl using inv.stock_docs d where d.id = dl.doc_id and d.doc_type = 'OPENING';
update inv.carriers c set current_hu_id = null from inv.handling_units h join inv.lots l on l.id = h.lot_id where h.id = c.current_hu_id and l.attrs ->> 'opening' = 'true';
delete from inv.handling_units h using inv.lots l where l.id = h.lot_id and l.attrs ->> 'opening' = 'true';
delete from inv.lots l where l.attrs ->> 'opening' = 'true';
delete from inv.stock_docs d where d.doc_type = 'OPENING';
-- Dữ liệu thật có đơn mua/đề xuất mua đang mở (đơn đang về, đơn nháp từ MRP): MRP, tồn dự phòng coi là hàng về → tạm hủy trong giao dịch
update purchase.purchase_orders set status = 'CANCELLED' where status in ('DRAFT', 'PENDING_APPROVAL', 'APPROVED', 'SENT', 'PARTIAL_RECEIVED');
update purchase.purchase_requests set status = 'CANCELLED' where status in ('DRAFT', 'PENDING_APPROVAL', 'APPROVED', 'PARTIAL_PO');
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

with u(code) as (values ('V_CT'),('V_GD'),('V_SXKH'),('V_MUATP'),('V_VH'),('V_MUANV'),('V_KT')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('V_CT','BGD'),('V_GD','BGD'),('V_SXKH','SX_KH'),('V_MUATP','MUA_TP'),('V_VH','VAN_HANH'),('V_MUANV','MUA_NV'),('V_KT','KT_KHO')) u(code, role)
  on u.code = p.employee_code;
update core.profiles set status = 'LOCKED' where (employee_code is null or employee_code !~ '^V_') and status = 'ACTIVE';
-- PR: TP Mua duyệt → Giám đốc duyệt (migration 4600)
update wf.approval_steps set assignee_ids = array[pg_temp.uid('V_MUATP')] where doc_type = 'PR' and seq = 1;
update wf.approval_steps set assignee_ids = array[pg_temp.uid('V_GD')] where (doc_type = 'PR' and seq = 2) or (doc_type = 'PLAN_ADJ' and seq = 1);
update wf.approval_steps set assignee_ids = array[pg_temp.uid('V_CT')] where doc_type = 'PLAN_ADJ' and seq = 2;
update wf.approval_flows set submit_role = null, submit_user_ids = '{}' where doc_type in ('PR', 'PLAN_ADJ', 'PO');
-- Đơn mua (migration 5100): NV mua duyệt gửi → TP Mua → Giám đốc
update wf.approval_steps set assignee_ids = array[pg_temp.uid('V_MUATP')] where doc_type = 'PO' and seq = 1;
update wf.approval_steps set assignee_ids = array[pg_temp.uid('V_GD')] where doc_type = 'PO' and seq = 2;
-- số lượng một vật tư trong các đơn mua (chưa hủy) sinh theo một đề xuất hiệu chỉnh
create function pg_temp.poq(p_adj uuid, p_code text) returns numeric language sql as $$
  select coalesce(sum(l.qty), 0) from purchase.po_lines l join purchase.purchase_orders po on po.id = l.po_id and po.status <> 'CANCELLED'
  join master.materials m on m.id = l.material_id and m.code = p_code where po.adjustment_id = p_adj
$$;

do $$ begin
  if (select s.status from master.products p join master.product_specs s on s.id = p.current_spec_id where p.code = 'HOME-KV15X2FP') <> 'RELEASED' then
    perform set_config('bmt.wf_release', 'on', true);
    perform master.release_spec((select current_spec_id from master.products where code = 'HOME-KV15X2FP'));
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
from master.products p where p.code = 'HOME-KV15X2FP';
insert into t select 'line', id from plan.plan_lines where plan_id = pg_temp.v('plan');
update plan.production_plans set status = 'APPROVED' where id = pg_temp.v('plan');
insert into t select 'run0', app.plan_run_mrp(pg_temp.v('plan'));
insert into t select 'pr1', plan.create_pr_from_mrp(pg_temp.v('run0'));
insert into t select 'pr1_req', wf.submit('PR', pg_temp.v('pr1'), (select pr_no from purchase.purchase_requests where id = pg_temp.v('pr1')), 'thử');
select pg_temp.as_user('V_MUATP');
select wf.act(pg_temp.v('pr1_req'), 'APPROVE', null);
select pg_temp.as_user('V_GD');
select wf.act(pg_temp.v('pr1_req'), 'APPROVE', null);
create temp table pr1_before as select material_id, qty from purchase.pr_lines where pr_id = pg_temp.v('pr1');
select pg_temp.ok((select status = 'APPROVED' from purchase.purchase_requests where id = pg_temp.v('pr1')) and pg_temp.prq(pg_temp.v('pr1'), 'CU-024') > 0,
  'Kế hoạch 10.000 m: đề xuất mua PR1 (có đồng) Giám đốc đã duyệt');

-- ================================================================ 9700. Bảng MRP hiệu chỉnh đủ cột
create function pg_temp.trow(p_res jsonb, p_code text) returns jsonb language sql as $$
  select e from jsonb_array_elements(p_res -> 'table') e where e ->> 'code' = p_code
$$;
select pg_temp.as_user('V_SXKH');
insert into t select 'a1', app.adj_create(pg_temp.v('plan'), 'Khách tăng đơn');
select app.adj_save(pg_temp.v('a1'), null, jsonb_build_array(jsonb_build_object('kind', 'QTY', 'plan_line_id', pg_temp.v('line'), 'qty_m', 14000)));
insert into j select 'p1', app.adj_mrp(pg_temp.v('a1'));
select pg_temp.ok((select jsonb_array_length(v -> 'table') > 0 and (v ->> 'preview')::boolean and v ->> 'error' is null from j where k = 'p1'),
  'Mở đề xuất: MES chạy MRP hiệu chỉnh, bảng có vật tư');
select pg_temp.ok((select (pg_temp.trow(v, 'CU-024') ->> 'mrp_old')::numeric
                     = (select total_issue from plan.mrp_lines l join master.materials m on m.id = l.material_id and m.code = 'CU-024' where l.run_id = pg_temp.v('run0'))
                   from j where k = 'p1'),
  'MRP ban đầu = cấp SX đồng của lần chạy MRP gần nhất của kế hoạch');
select pg_temp.ok((select (x ->> 'mrp_new')::numeric > (x ->> 'mrp_old')::numeric
                      and abs((x ->> 'diff')::numeric - ((x ->> 'mrp_new')::numeric - (x ->> 'mrp_old')::numeric)) < 0.001
                      and abs((x ->> 'mrp_new')::numeric / (x ->> 'mrp_old')::numeric - 1.4) < 0.02
                   from (select pg_temp.trow(v, 'CU-024') x from j where k = 'p1') q),
  'MRP hiện tại đồng ≈ 1,4 × ban đầu (10.000 → 14.000 m), chênh lệch = hiện tại − ban đầu');
select pg_temp.ok((select x ?& array['available', 'incoming', 'requested', 'reserve', 'shortage', 'suggest', 'projected_after']
                      and abs((x ->> 'projected_after')::numeric - ((x ->> 'available')::numeric + (x ->> 'incoming')::numeric + (x ->> 'requested')::numeric
                              + (x ->> 'suggest')::numeric - (x ->> 'mrp_new')::numeric - (x ->> 'reserve')::numeric)) < 0.01
                      and (x ->> 'suggest')::numeric >= (x ->> 'shortage')::numeric
                   from (select pg_temp.trow(v, 'CU-024') x from j where k = 'p1') q),
  'Đủ cột tồn kho, hàng về, đã đề xuất, dự phòng, thiếu, đề xuất mua; tồn sau SX = tồn + về + đã đề xuất + mua − MRP hiện tại − dự phòng');
select pg_temp.ok((select qty_m = 10000 from plan.plan_lines where id = pg_temp.v('line'))
   and (select r.id = pg_temp.v('run0') from plan.mrp_runs r where r.plan_id = pg_temp.v('plan') order by r.run_at desc limit 1),
  'Chạy thử không đổi kế hoạch, không thêm lần MRP');
select pg_temp.ok(exists (select 1 from plan.adj_mrp_previews where adj_id = pg_temp.v('a1') and old_run_id = pg_temp.v('run0')),
  'Kết quả chạy thử được lưu');
select pg_temp.ok((app.adj_mrp(pg_temp.v('a1')) ->> 'cached')::boolean, 'Mở lại trang: dùng kết quả đã lưu (không chạy lại)');
select pg_temp.ok((select (r ->> 'cached') is null and (r -> 'table') = (select v -> 'table' from j where k = 'p1')
                   from (select app.adj_run_mrp(pg_temp.v('a1')) r) q),
  'Bấm Chạy MRP hiệu chỉnh: chạy lại, cùng số liệu');
-- sửa dòng → chạy lại theo dòng mới
select app.adj_save(pg_temp.v('a1'), null, jsonb_build_array(jsonb_build_object('kind', 'QTY', 'plan_line_id', pg_temp.v('line'), 'qty_m', 12000)));
insert into j select 'p2', app.adj_mrp(pg_temp.v('a1'));
select pg_temp.ok((select (v ->> 'cached') is null and (pg_temp.trow(v, 'CU-024') ->> 'mrp_new')::numeric
                     < (select (pg_temp.trow(v, 'CU-024') ->> 'mrp_new')::numeric from j where k = 'p1') from j where k = 'p2'),
  'Sửa dòng 14.000 → 12.000 m: MES tự chạy lại, MRP hiện tại giảm');
-- kế hoạch chạy MRP lại → kết quả cũ hết đúng
-- (trong một giao dịch now() không đổi: lùi giờ lần chạy cũ để lần chạy mới là gần nhất như thật)
update plan.mrp_runs set run_at = run_at - interval '1 minute' where plan_id = pg_temp.v('plan');
insert into t select 'run1', app.plan_run_mrp(pg_temp.v('plan'));
insert into j select 'p3', app.adj_mrp(pg_temp.v('a1'));
select pg_temp.ok((select (v ->> 'cached') is null from j where k = 'p3')
   and exists (select 1 from plan.adj_mrp_previews where adj_id = pg_temp.v('a1') and old_run_id = pg_temp.v('run1')),
  'Kế hoạch chạy MRP lại: MRP ban đầu theo lần chạy mới, bảng tự chạy lại');
-- đề xuất chưa có dòng
insert into t select 'a0', app.adj_create(pg_temp.v('plan'), 'Nháp trống');
select pg_temp.fails($$select app.adj_run_mrp(pg_temp.v('a0'))$$, 'chưa có dòng', 'Đề xuất chưa có dòng: Chạy MRP báo cần thêm dòng');
-- duyệt: bảng lúc áp có đủ cột
insert into t select 'a1_req', app.adj_submit(pg_temp.v('a1'));
select pg_temp.as_user('V_GD');
select wf.act(pg_temp.v('a1_req'), 'APPROVE', null);
select pg_temp.as_user('V_CT');
select wf.act(pg_temp.v('a1_req'), 'APPROVE', null);
select pg_temp.ok((select (r ->> 'applied')::boolean and jsonb_array_length(r -> 'table') > 0 and pg_temp.trow(r, 'CU-024') ? 'projected_after'
                   from (select app.adj_mrp(pg_temp.v('a1')) r) q),
  'Đã duyệt: bảng MRP hiệu chỉnh lúc áp có đủ cột');
select pg_temp.fails($$select app.adj_run_mrp(pg_temp.v('a1'))$$, 'đã chốt lúc duyệt', 'Đã duyệt: không chạy lại MRP hiệu chỉnh');
select pg_temp.ok(not has_function_privilege('anon', 'app.adj_run_mrp(uuid)', 'execute')
   and not has_function_privilege('authenticated', 'plan.adj_preview(uuid)', 'execute')
   and not has_function_privilege('authenticated', 'plan.adj_mrp_table(uuid,uuid)', 'execute'),
  'Quyền: anon không gọi Chạy MRP; hàm nội bộ không mở cho người dùng');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
