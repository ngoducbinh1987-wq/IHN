-- Kiểm thử migration 20261026003600 (quy trình final – Đợt 4 + 5): phiếu điều chỉnh kế hoạch tháng (Chủ tịch HĐQT duyệt),
-- đơn phát sinh thêm bước Chủ tịch, dự trù nhiều tầng TP → BTP → NVL, đề xuất mua có tồn dự kiến, lịch theo lô (ngày chốt, giữ chỗ).
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create temp table t (k text primary key, v uuid);

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
create function pg_temp.today() returns date language sql as $$ select (now() at time zone 'Asia/Ho_Chi_Minh')::date $$;
-- Tồn TP/BTP thử: một đơn vị chứa trong kho
create function pg_temp.stock(p_kind text, p_stage text, p_wh text, p_loc text, p_qty numeric) returns void language plpgsql as $$
declare v_lot uuid; v_hu uuid;
begin
  insert into inv.lots (lot_no, item_kind, product_id, spec_id, wip_stage, brand, uom, qc_status)
  select 'T36-' || p_kind || '-' || coalesce(p_stage, 'TP'), p_kind, p.id, p.current_spec_id, p_stage, 'KAVIX', 'm', 'PASSED'
  from master.products p where p.code = 'PFR-2C-1P5' returning id into v_lot;
  v_hu := inv.new_hu(v_lot, 'REEL', p_qty, inv.wh(p_wh), inv.loc(p_loc));
  perform inv.bal_add(inv.wh(p_wh), inv.loc(p_loc), v_lot, v_hu, p_qty);
end $$;
set client_min_messages = notice;

-- Người dùng thử: Chủ tịch HĐQT (được giao ở bước duyệt kế hoạch tháng), Giám đốc, TP SX, Kế hoạch SX, TP mua
with u(code) as (values ('P_CT'),('P_GD'),('P_SXTP'),('P_SXKH'),('P_MUATP'),('P_KTTP'),('P_VH')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('P_CT','BGD'),('P_GD','BGD'),('P_SXTP','SX_TP'),('P_SXKH','SX_KH'),('P_MUATP','MUA_TP'),
  ('P_KTTP','KT_TP'),('P_VH','VAN_HANH')) u(code, role) on u.code = p.employee_code;
update core.profiles set status = 'LOCKED' where (employee_code is null or employee_code !~ '^P_') and status = 'ACTIVE';
update wf.approval_steps set assignee_ids = array[pg_temp.uid('P_CT')] where doc_type in ('PLAN', 'PLAN_ADJ') and seq = (case doc_type when 'PLAN' then 2 else 1 end);
update wf.approval_steps set enabled = true where doc_type = 'PLAN' and seq = 2;

-- Spec PFR-2C-1P5 phát hành (database mới chưa phát hành)
do $$ begin
  if (select s.status from master.products p join master.product_specs s on s.id = p.current_spec_id where p.code = 'PFR-2C-1P5') <> 'RELEASED' then
    perform set_config('bmt.wf_release', 'on', true);
    perform master.release_spec((select current_spec_id from master.products where code = 'PFR-2C-1P5'));
  end if;
end $$;
-- Kế hoạch tháng đã duyệt: PFR-2C-1P5 10.000 m hạn giao +20 ngày
insert into plan.production_plans (plan_no, period_label, material_need_date, status) values ('KH-T36', 'Thử 3600', pg_temp.today() + 10, 'DRAFT');
insert into t select 'plan', id from plan.production_plans where plan_no = 'KH-T36';
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, run_lots, m_per_pack, pack_type, brand, due_date)
select (select v from t where k = 'plan'), p.id, p.current_spec_id, 10000, 1, 500, 'Bobin gỗ', 'KAVIX', pg_temp.today() + 20
from master.products p where p.code = 'PFR-2C-1P5';
insert into t select 'line', id from plan.plan_lines where plan_id = (select v from t where k = 'plan');
update plan.production_plans set status = 'APPROVED' where id = (select v from t where k = 'plan');

-- ================================================================ 1. Dự trù nhiều tầng TP → BTP → NVL
-- Có sẵn: 1.000 m thành phẩm, 500 m cáp đã bọc vỏ, 2.000 m lõi đã bọc (= 1.000 m cáp 2 lõi)
select pg_temp.stock('FG', null, 'KTP', 'KTP-QC', 1000);
select pg_temp.stock('WIP', 'CV', 'KBTP', 'KBTP-W', 500);
select pg_temp.stock('WIP', 'LB', 'KBTP', 'KBTP-W', 2000);
-- Đề xuất mua đồng 50 kg đang chờ duyệt (chưa lên PO)
insert into purchase.purchase_requests (pr_no, source, status, note) values ('PR-T36', 'MANUAL', 'PENDING_APPROVAL', 'thử');
insert into purchase.pr_lines (pr_id, material_id, qty) select pr.id, m.id, 50 from purchase.purchase_requests pr, master.materials m where pr.pr_no = 'PR-T36' and m.code = 'CU-024';
select pg_temp.as_user('P_SXKH');
insert into t select 'run', plan.run_mrp((select v from t where k = 'plan'));
select pg_temp.ok((select fg_m = 1000 and cv_m = 500 and bl_m = 0 and lb_m = 1000 and q6 = 9000 and q5 = 8500 and q34 = 8500 and q2 = 7500 and q1 = 7500
                   from plan.mrp_products where run_id = (select v from t where k = 'run')),
  'Trừ tồn từng tầng: 10.000 − 1.000 TP = 9.000 m đóng gói; − 500 cáp CV = 8.500 bọc vỏ, xoắn; − 2.000 m lõi ÷ 2 lõi = 7.500 m bọc cách điện, bện');
select pg_temp.ok((select abs(ml.theoretical - round(bl.qty_per_basis * 7.5, 4)) < 0.001
                   from plan.mrp_lines ml join master.materials m on m.id = ml.material_id and m.code = 'CU-024'
                   join master.bom_lines bl on bl.material_id = m.id and bl.bom_id = (select h.id from master.bom_headers h join master.products p on p.current_spec_id = h.spec_id where p.code = 'PFR-2C-1P5' limit 1)
                   where ml.run_id = (select v from t where k = 'run')),
  'Đồng (CD1) tính trên 7.500 m còn phải bện, không phải 10.000 m kế hoạch');
select pg_temp.ok((select abs(ml.theoretical - round(bl.qty_per_basis * 8.5, 4)) < 0.001
                   from plan.mrp_lines ml join master.materials m on m.id = ml.material_id and m.code = 'PVC-FR'
                   join master.bom_lines bl on bl.material_id = m.id and bl.bom_id = (select h.id from master.bom_headers h join master.products p on p.current_spec_id = h.spec_id where p.code = 'PFR-2C-1P5' limit 1)
                   where ml.run_id = (select v from t where k = 'run'))
  and (select ml.theoretical = 18 from plan.mrp_lines ml join master.materials m on m.id = ml.material_id and m.code = 'REEL-W' where ml.run_id = (select v from t where k = 'run')),
  'Nhựa vỏ (CD5) tính trên 8.500 m; bobin gỗ đóng gói 9.000 m ÷ 500 = 18 bộ');
select pg_temp.ok((select requested = 50 and projected = round(available + incoming + 50 - total_issue - reserve, 4)
                          and net_short = round(greatest(total_issue + reserve - available - incoming - 50, 0), 4)
                   from plan.mrp_lines ml join master.materials m on m.id = ml.material_id and m.code = 'CU-024' where ml.run_id = (select v from t where k = 'run')),
  'Trừ 50 kg đồng đã đề xuất mua (chưa lên PO); tồn dự kiến = tồn + về + đã đề xuất − cấp SX');

-- ================================================================ 2. Đề xuất mua từ dự trù: nhu cầu, tồn, đang về, tồn dự kiến
insert into t select 'pr', plan.create_pr_from_mrp((select v from t where k = 'run'));
select pg_temp.ok((select bool_and(need_qty is not null and available_qty is not null and incoming_qty is not null and mrp_qty = qty
                                   and projected_qty = available_qty + incoming_qty + qty - need_qty)
                   from app.v_pr_lines where pr_id = (select v from t where k = 'pr')),
  'Đề xuất mua có cột nhu cầu, tồn đạt QC, đang về (+ đã đề xuất), tồn dự kiến sau SX = tồn + về + mua − nhu cầu');
select pg_temp.ok((select incoming_qty = 50 from app.v_pr_lines where pr_id = (select v from t where k = 'pr') and material_code = 'CU-024'),
  'Đồng: cột đang về gồm 50 kg đã đề xuất trước');
select pg_temp.ok(wf.can_submit('PR'), 'Kế hoạch SX (TP SX) gửi duyệt đề xuất mua được');

-- ================================================================ 3. Phiếu điều chỉnh kế hoạch tháng: TP SX lập, Chủ tịch HĐQT duyệt
select pg_temp.as_user('P_VH');
select pg_temp.fails($$select app.adj_create((select v from t where k = 'plan'), 'x')$$, 'TP SX', 'Công nhân không lập phiếu điều chỉnh');
select pg_temp.as_user('P_GD');
select pg_temp.fails($$select app.kh_set_line((select v from t where k = 'line'), pg_temp.today() + 25, 1::smallint)$$, 'phiếu điều chỉnh',
  'Kế hoạch đã duyệt: Giám đốc không tự đổi hạn giao đã có');
select app.kh_set_line((select v from t where k = 'line'), pg_temp.today() + 20, 0::smallint);
select pg_temp.ok((select priority = 0 from plan.plan_lines where id = (select v from t where k = 'line')), 'Giám đốc vẫn đánh dấu đơn gấp được');
select pg_temp.as_user('P_SXKH');
select pg_temp.fails($$select app.adj_create((select v from t where k = 'plan'), ' ')$$, 'lý do', 'Phiếu điều chỉnh bắt buộc lý do');
insert into t select 'adj', app.adj_create((select v from t where k = 'plan'), 'Khách ABC đặt thêm, đổi hạn');
select pg_temp.fails($$select app.adj_submit((select v from t where k = 'adj'))$$, 'chưa có dòng', 'Phiếu chưa có dòng thì không gửi được');
select app.adj_save((select v from t where k = 'adj'), null, jsonb_build_array(
  jsonb_build_object('kind', 'ADD', 'product_code', 'pfr-2c-1p5', 'qty_m', 3000, 'due_date', pg_temp.today() + 30, 'note', 'Đơn ABC-12'),
  jsonb_build_object('kind', 'QTY', 'plan_line_id', (select v from t where k = 'line'), 'qty_m', 12000),
  jsonb_build_object('kind', 'DUE', 'plan_line_id', (select v from t where k = 'line'), 'due_date', pg_temp.today() + 15)));
select pg_temp.ok((select count(*) = 3 and bool_and(old_qty_m is not distinct from case kind when 'ADD' then null else 10000 end)
                   from plan.plan_adjustment_lines where adj_id = (select v from t where k = 'adj')),
  'Lưu 3 dòng: thêm mã, đổi sản lượng (giữ số cũ 10.000 m), đổi hạn giao');
create temp table imp as select * from app.adj_impact((select v from t where k = 'adj'));
select pg_temp.ok((select count(*) > 0 and bool_and(extra_need > 0) from imp) and exists (select 1 from imp where material_code = 'CU-024'),
  'Xem trước ảnh hưởng vật tư: nhu cầu thêm theo BOM (thêm 3.000 m + tăng 2.000 m)');
insert into t select 'adj_req', app.adj_submit((select v from t where k = 'adj'));
select pg_temp.ok((select status = 'PENDING_APPROVAL' from plan.plan_adjustments where id = (select v from t where k = 'adj'))
  and exists (select 1 from wf.notifications where user_id = pg_temp.uid('P_CT') and title like '%PDC-%'),
  'Gửi duyệt: phiếu chờ Chủ tịch HĐQT, Chủ tịch nhận thông báo');
select pg_temp.fails($$select app.adj_save((select v from t where k = 'adj'), null, '[]')$$, 'Người lập không sửa', 'Đã gửi duyệt thì người lập không sửa dòng (người duyệt sửa)');
select pg_temp.as_user('P_GD');
select pg_temp.fails($$select wf.act((select v from t where k = 'adj_req'), 'APPROVE', null)$$, '', 'Giám đốc (không phải Chủ tịch) không duyệt phiếu điều chỉnh kế hoạch tháng');
select pg_temp.as_user('P_CT');
select wf.act((select v from t where k = 'adj_req'), 'APPROVE', 'Đồng ý');
select pg_temp.ok((select status = 'APPROVED' and applied_at is not null from plan.plan_adjustments where id = (select v from t where k = 'adj'))
  and (select qty_m = 12000 and due_date = pg_temp.today() + 15 from plan.plan_lines where id = (select v from t where k = 'line'))
  and exists (select 1 from plan.plan_lines where plan_id = (select v from t where k = 'plan') and adjustment_id = (select v from t where k = 'adj') and qty_m = 3000)
  and (select mrp_stale from plan.production_plans where id = (select v from t where k = 'plan')),
  'Chủ tịch duyệt: MES áp vào kế hoạch (thêm dòng 3.000 m, 12.000 m, hạn mới), đánh dấu chạy lại dự trù');
select pg_temp.ok(exists (select 1 from wf.notifications where user_id = pg_temp.uid('P_SXTP') and title like 'Kế hoạch tháng đã điều chỉnh%'),
  'TP SX, Giám đốc, mua hàng được báo chạy lại dự trù, xếp lại lịch');
select pg_temp.ok((select doc_link like '/ke-hoach/dieu-chinh/%' from app.v_approvals where id = (select v from t where k = 'adj_req')),
  'Trang duyệt mở đúng phiếu điều chỉnh');
-- Bỏ dòng đang sản xuất → chặn
select pg_temp.as_user('P_SXKH');
insert into mfg.work_orders (wo_no, plan_line_id, product_id, spec_id, bom_id, qty_m, m_per_pack, pack_type, brand, status)
select 'LSX-T36', l.id, l.product_id, l.spec_id, (select h.id from master.bom_headers h where h.spec_id = l.spec_id limit 1), l.qty_m, 500, 'Bobin gỗ', 'KAVIX', 'IN_PROGRESS'
from plan.plan_lines l where l.id = (select v from t where k = 'line');
insert into t select 'adj2', app.adj_create((select v from t where k = 'plan'), 'Khách hủy');
select app.adj_save((select v from t where k = 'adj2'), null, jsonb_build_array(jsonb_build_object('kind', 'REMOVE', 'plan_line_id', (select v from t where k = 'line'))));
select pg_temp.fails($$select app.adj_submit((select v from t where k = 'adj2'))$$, 'không bỏ được', 'Lô đang sản xuất không bỏ được: giảm số mét thay vì bỏ');

-- ================================================================ 4. Đơn phát sinh: lô ngoài kế hoạch phải qua Chủ tịch HĐQT
insert into t select 'dps', app.kh_create_change((select v from t where k = 'plan'),
  '{"product_code":"PFR-2C-1P5","qty_m":500,"priority":"1","due_date":"2099-01-01"}', '{"placed":true,"slack":-1,"newly":["x"]}', 'B', '[]');
select pg_temp.ok((select jsonb_array_length(steps) = 3 and steps->1->>'label' like 'Chủ tịch HĐQT%' and steps->2->>'role' = 'BGD'
                          and (steps->1->'user_ids') ? pg_temp.uid('P_CT')::text
                   from plan.change_requests where id = (select v from t where k = 'dps')),
  'Đơn phát sinh mức B: lập → Chủ tịch HĐQT (đích danh) → Giám đốc');
select pg_temp.as_user('P_GD');
select pg_temp.fails($$select app.kh_change_step((select v from t where k = 'dps'), 'approve', null)$$, 'Chủ tịch', 'Giám đốc không duyệt thay bước Chủ tịch');
select pg_temp.as_user('P_CT');
select pg_temp.ok(app.kh_change_step((select v from t where k = 'dps'), 'approve', null) = 'PENDING', 'Chủ tịch duyệt lô ngoài kế hoạch, chuyển Giám đốc duyệt chen lịch');
select pg_temp.as_user('P_GD');
select pg_temp.ok(app.kh_change_step((select v from t where k = 'dps'), 'approve', null) = 'READY', 'Giám đốc duyệt phần chen lịch');

-- ================================================================ 5. Lịch theo lô: ngày dự kiến, ngày chốt, giữ chỗ
-- Lịch máy đang dùng: lô xong dự kiến +12 ngày
insert into plan.schedule_versions (plan_id, version, is_current, base_date, params, reason)
values ((select v from t where k = 'plan'), 1, true, pg_temp.today(), '{}', 'thử');
insert into t select 'ver', id from plan.schedule_versions where plan_id = (select v from t where k = 'plan');
insert into plan.schedule_orders (version_id, plan_line_id, label, product_code, qty_m, finish_date)
values ((select v from t where k = 'ver'), (select v from t where k = 'line'), 'D01', 'PFR-2C-1P5', 12000, pg_temp.today() + 12);
insert into plan.schedule_slots (version_id, plan_line_id, op_code, machine_code, start_min, run_start_min, end_min, meters, rate, speed)
values ((select v from t where k = 'ver'), (select v from t where k = 'line'), 'CD1', 'BUN-01', 0, 10, 400, 10000, 25, 25);
select pg_temp.ok((select eta_date = pg_temp.today() + 12 from app.v_kh_plan_lines where id = (select v from t where k = 'line')), 'Ngày dự kiến xong lấy từ lịch máy đang dùng');
select pg_temp.as_user('P_GD');
select pg_temp.fails($$select app.kh_commit_lot((select v from t where k = 'line'), pg_temp.today() + 14, null)$$, 'TP SX', 'Chỉ TP SX chốt ngày lô');
select pg_temp.as_user('P_SXTP');
select pg_temp.fails($$select app.kh_approve_lot((select v from t where k = 'line'), true)$$, 'Chốt ngày', 'Chưa chốt ngày thì chưa duyệt lịch lô');
select pg_temp.fails($$select app.kh_commit_lot((select v from t where k = 'line'), pg_temp.today() + 10, null)$$, 'sớm hơn',
  'Chốt sớm hơn ngày MES dự kiến phải ghi rõ lô nào chịu lùi');
select app.kh_commit_lot((select v from t where k = 'line'), pg_temp.today() + 10, 'Lùi D02 2 ngày, khách D02 đồng ý');
select pg_temp.fails($$select app.kh_approve_lot((select v from t where k = 'line'), true)$$, 'sau ngày chốt', 'Lịch hiện xong sau ngày chốt: phải xếp lại lịch trước khi duyệt');
select app.kh_commit_lot((select v from t where k = 'line'), pg_temp.today() + 14, null);
select app.kh_approve_lot((select v from t where k = 'line'), true);
select pg_temp.ok((select lot_version_id = (select v from t where k = 'ver') and lot_approved_at is not null and committed_date = pg_temp.today() + 14
                   from plan.plan_lines where id = (select v from t where k = 'line'))
  and exists (select 1 from wf.notifications where user_id = pg_temp.uid('P_GD') and title like 'Đã duyệt lịch lô%'),
  'TP SX duyệt lịch lô: giữ chỗ theo lịch đang dùng, Giám đốc được báo');
select app.kh_commit_lot((select v from t where k = 'line'), pg_temp.today() + 16, 'Khách lùi nhận hàng');
select pg_temp.ok((select lot_approved_at is null from plan.plan_lines where id = (select v from t where k = 'line')), 'Đổi ngày chốt thì bỏ giữ chỗ, TP SX duyệt lại');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
