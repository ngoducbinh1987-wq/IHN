-- Kiểm thử migration 20261026004400_reviewer_edit: người lập sửa MRP khi nháp; người đang duyệt (Giám đốc, Chủ tịch)
-- sửa dòng kế hoạch, đề nghị mua MRP, đề xuất mua, phiếu điều chỉnh kế hoạch; mọi lần sửa ghi lịch sử duyệt.
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create temp table t (k text primary key, v uuid);

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
-- dòng MRP mới nhất của kế hoạch theo mã vật tư
create function pg_temp.mrp(p_code text) returns plan.mrp_lines language sql as $$
  select ml.* from plan.mrp_lines ml join master.materials m on m.id = ml.material_id and m.code = p_code
  where ml.run_id = (select id from plan.mrp_runs where plan_id = pg_temp.v('plan') order by run_at desc limit 1)
$$;
create function pg_temp.edits(p_req uuid) returns int language sql as $$
  select count(*)::int from wf.approval_actions where request_id = p_req and comment like '[Sửa khi duyệt]%'
$$;
set client_min_messages = notice;

with u(code) as (values ('E_CT'),('E_GD'),('E_SXTP'),('E_MUATP'),('E_MUANV'),('E_VH')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('E_CT','BGD'),('E_GD','BGD'),('E_SXTP','SX_TP'),('E_MUATP','MUA_TP'),
  ('E_MUANV','MUA_NV'),('E_VH','VAN_HANH')) u(code, role) on u.code = p.employee_code;
update core.profiles set status = 'LOCKED' where (employee_code is null or employee_code !~ '^E_') and status = 'ACTIVE';
-- Kế hoạch: TP SX lập → Giám đốc duyệt → Chủ tịch chốt; đề xuất mua: Giám đốc duyệt; điều chỉnh kế hoạch: Chủ tịch duyệt
update wf.approval_steps set enabled = true, assignee_ids = array[pg_temp.uid('E_GD')] where doc_type = 'PLAN' and seq = 1;
update wf.approval_steps set enabled = true, assignee_ids = array[pg_temp.uid('E_CT')] where doc_type = 'PLAN' and seq = 2;
update wf.approval_steps set enabled = false where doc_type = 'PLAN' and seq > 2;
-- Đề xuất mua từ 4500: TP Mua duyệt → Giám đốc duyệt
update wf.approval_steps set assignee_ids = array[pg_temp.uid('E_MUATP')] where doc_type = 'PR' and seq = 1;
update wf.approval_steps set assignee_ids = array[pg_temp.uid('E_GD')] where doc_type = 'PR' and seq = 2;
update wf.approval_steps set assignee_ids = array[pg_temp.uid('E_CT')] where doc_type = 'PLAN_ADJ' and seq = 1;
update wf.approval_flows set submit_role = null, submit_user_ids = '{}' where doc_type in ('PLAN', 'PR', 'PLAN_ADJ');

do $$ begin
  if (select s.status from master.products p join master.product_specs s on s.id = p.current_spec_id where p.code = 'PFR-2C-1P5') <> 'RELEASED' then
    perform set_config('bmt.wf_release', 'on', true);
    perform master.release_spec((select current_spec_id from master.products where code = 'PFR-2C-1P5'));
  end if;
  if (select s.status from master.products p join master.product_specs s on s.id = p.current_spec_id where p.code = 'PFR-2C-2P5') <> 'RELEASED' then
    perform set_config('bmt.wf_release', 'on', true);
    perform master.release_spec((select current_spec_id from master.products where code = 'PFR-2C-2P5'));
  end if;
end $$;
insert into plan.production_plans (plan_no, period_label, material_need_date, status) values ('KH-T44', 'Thử 4400', pg_temp.today() + 10, 'DRAFT');
insert into t select 'plan', id from plan.production_plans where plan_no = 'KH-T44';
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, run_lots, m_per_pack, pack_type, brand)
select pg_temp.v('plan'), p.id, p.current_spec_id, q, 1, 500, 'Bobin gỗ', 'KAVIX'
from master.products p join (values ('PFR-2C-1P5', 10000), ('PFR-2C-2P5', 5000)) x(code, q) on x.code = p.code;
insert into t select 'l15', l.id from plan.plan_lines l join master.products p on p.id = l.product_id where l.plan_id = pg_temp.v('plan') and p.code = 'PFR-2C-1P5';
insert into t select 'l25', l.id from plan.plan_lines l join master.products p on p.id = l.product_id where l.plan_id = pg_temp.v('plan') and p.code = 'PFR-2C-2P5';

-- ================================================================ 1. Kế hoạch nháp: người lập sửa bảng MRP trước khi gửi
select pg_temp.as_user('E_SXTP');
insert into t select 'run1', app.plan_run_mrp(pg_temp.v('plan'));
select pg_temp.ok((pg_temp.mrp('CU-024')).suggest_qty > 0, 'TP SX chạy MRP kế hoạch nháp');
select app.adjust_mrp_line((pg_temp.mrp('REEL-W')).id, (pg_temp.mrp('REEL-W')).suggest_qty + 10, null, 'dự phòng', 'Thêm 10 bobin dự phòng');
select pg_temp.ok((pg_temp.mrp('REEL-W')).orig_suggest_qty is not null and (pg_temp.mrp('REEL-W')).adjusted_by = pg_temp.uid('E_SXTP'),
  'Người lập kế hoạch (TP SX, không phải TP Mua/KT) sửa được đề nghị mua khi kế hoạch còn nháp');
select pg_temp.as_user('E_VH');
select pg_temp.fails($$select app.adjust_mrp_line((pg_temp.mrp('CU-024')).id, 1, null, null, 'x')$$, 'người lập kế hoạch', 'Công nhân không sửa MRP');

-- Gửi Giám đốc duyệt
select pg_temp.as_user('E_SXTP');
insert into t select 'req', wf.submit('PLAN', pg_temp.v('plan'), 'KH-T44', 'thử');
select pg_temp.ok((select status = 'PENDING_APPROVAL' from plan.production_plans where id = pg_temp.v('plan')), 'Gửi Giám đốc duyệt');

-- ================================================================ 2. Đang chờ Giám đốc: chỉ Giám đốc sửa
select pg_temp.fails($$select app.adjust_mrp_line((pg_temp.mrp('CU-024')).id, 1, null, null, 'x')$$, 'Người lập không sửa', 'Người lập không tự sửa MRP khi đang chờ duyệt');
select pg_temp.fails($$select app.plan_run_mrp(pg_temp.v('plan'))$$, 'Người lập không sửa', 'Người lập không tự chạy lại MRP khi đang chờ duyệt');
select pg_temp.fails($$select plan.run_mrp(pg_temp.v('plan'))$$, 'chờ duyệt', 'Chạy thẳng plan.run_mrp khi chờ duyệt bị chặn (giữ số người duyệt sửa)');
select pg_temp.as_user('E_MUATP');
select pg_temp.fails($$select app.adjust_mrp_line((pg_temp.mrp('CU-024')).id, 1, null, null, 'x')$$, 'Giám đốc duyệt', 'TP Mua không sửa MRP khi kế hoạch đang chờ Giám đốc');
select pg_temp.as_user('E_CT');
select pg_temp.fails($$select app.adjust_mrp_line((pg_temp.mrp('CU-024')).id, 1, null, null, 'x')$$, 'Giám đốc duyệt', 'Chủ tịch chưa sửa khi chưa đến bước của mình');
select pg_temp.ok(not app.can_review_edit('PLAN', pg_temp.v('plan')), 'can_review_edit = false với Chủ tịch ở bước 1');

select pg_temp.as_user('E_GD');
select pg_temp.ok(app.can_review_edit('PLAN', pg_temp.v('plan')), 'can_review_edit = true với Giám đốc ở bước 1');
insert into t select 'cu_line', (pg_temp.mrp('CU-024')).id;
select app.adjust_mrp_line(pg_temp.v('cu_line'), 5000, null, null, 'Giảm theo tồn thực tế kho');
select pg_temp.ok((select suggest_qty = 5000 from plan.mrp_lines where id = pg_temp.v('cu_line')), 'Giám đốc sửa đề nghị mua đồng khi duyệt');
select pg_temp.ok((select comment like '[Sửa khi duyệt] Đề nghị mua CU-024:%→ 5.000 kg%' and actor_id = pg_temp.uid('E_GD')
                   from wf.approval_actions where request_id = pg_temp.v('req') order by id desc limit 1),
  'Lịch sử duyệt ghi "[Sửa khi duyệt] Đề nghị mua CU-024: … → 5.000 kg"');
select pg_temp.ok(exists (select 1 from wf.notifications where user_id = pg_temp.uid('E_SXTP') and title like 'Người duyệt đã sửa%'),
  'Người lập nhận thông báo người duyệt đã sửa');
-- Giám đốc sửa dòng kế hoạch: MES chạy lại MRP, giữ điều chỉnh của vật tư không đổi nhu cầu
select app.plan_chair_save_line(pg_temp.v('plan'), pg_temp.v('l25'), null, 6000, 1, 'Bobin gỗ', 500, 'KAVIX', 'Khách tăng đơn');
select pg_temp.ok((select qty_m = 6000 from plan.plan_lines where id = pg_temp.v('l25'))
                  and (select count(*) = 1 from plan.plan_chair_edits where plan_id = pg_temp.v('plan') and action = 'EDIT' and edited_by = pg_temp.uid('E_GD')),
  'Giám đốc (bước 1, trước chỉ Chủ tịch) sửa sản lượng dòng kế hoạch 5.000 → 6.000 m');
select pg_temp.ok((select count(*) = 2 from plan.mrp_runs where plan_id = pg_temp.v('plan')) and not (select mrp_stale from plan.production_plans where id = pg_temp.v('plan')),
  'Sửa dòng thì MES chạy lại MRP ngay (không để kế hoạch "cần chạy lại")');
select pg_temp.ok((select comment like '[Sửa khi duyệt] PFR-2C-2P5: sản lượng 5.000 → 6.000 m%' from wf.approval_actions where request_id = pg_temp.v('req') order by id desc limit 1),
  'Lịch sử duyệt ghi sửa sản lượng PFR-2C-2P5');
select pg_temp.ok((select summary like '%đã chỉnh khi duyệt%' from wf.approval_requests where id = pg_temp.v('req')), 'Tóm tắt yêu cầu duyệt ghi "đã chỉnh khi duyệt"');
-- Bobin gỗ: nhu cầu đổi (thêm 1.000 m) → điều chỉnh cũ không còn đúng, MES dùng số mới; đồng PFR-2C-1P5 + 2P5 cũng đổi
select pg_temp.ok((pg_temp.mrp('REEL-W')).orig_suggest_qty is null, 'Vật tư đổi nhu cầu (bobin gỗ) dùng số MRP mới, bỏ điều chỉnh cũ');
-- vật tư không đổi nhu cầu: chỉ có ở PFR-2C-1P5? Kiểm tổng quát: mọi dòng giữ điều chỉnh đều có số gốc = số MRP mới tính
select pg_temp.ok(not exists (select 1 from plan.mrp_lines ml where ml.run_id = (select id from plan.mrp_runs where plan_id = pg_temp.v('plan') order by run_at desc limit 1)
                               and ml.orig_suggest_qty is not null and ml.adjusted_by is null),
  'Dòng giữ điều chỉnh có người sửa, số gốc');

-- Giám đốc duyệt: mã kiểm không đổi, sang bước Chủ tịch
select pg_temp.ok(wf.act(pg_temp.v('req'), 'APPROVE', 'Đồng ý, đã chỉnh đồng') = 'PENDING', 'Giám đốc duyệt sau khi sửa (không bị báo "đã bị sửa sau khi gửi")');
select pg_temp.fails($$select app.adjust_mrp_line((pg_temp.mrp('PVC-FR')).id, 1, null, null, 'x')$$, 'Chủ tịch', 'Giám đốc hết quyền sửa khi đã chuyển sang bước Chủ tịch');

-- ================================================================ 3. Bước Chủ tịch chốt: Chủ tịch sửa, chốt
select pg_temp.as_user('E_CT');
select app.adjust_mrp_line((pg_temp.mrp('PVC-FR')).id, round((pg_temp.mrp('PVC-FR')).suggest_qty + 25), null, 'mua thêm 1 bao', 'Giá tốt, mua thêm');
select pg_temp.ok((pg_temp.mrp('PVC-FR')).adjusted_by = pg_temp.uid('E_CT'), 'Chủ tịch sửa đề nghị mua khi chốt');
select app.plan_run_mrp(pg_temp.v('plan'));
select pg_temp.ok((pg_temp.mrp('PVC-FR')).adjusted_by = pg_temp.uid('E_CT') and (pg_temp.mrp('PVC-FR')).note = 'mua thêm 1 bao',
  'Chạy lại MRP: vật tư không đổi nhu cầu giữ số Chủ tịch đã sửa');
select pg_temp.ok(wf.act(pg_temp.v('req'), 'APPROVE', 'Chốt') = 'APPROVED', 'Chủ tịch chốt kế hoạch');
select pg_temp.ok(pg_temp.edits(pg_temp.v('req')) >= 4, 'Lịch sử duyệt có đủ các lần sửa của Giám đốc và Chủ tịch');
select pg_temp.ok(exists (select 1 from wf.notifications where user_id = pg_temp.uid('E_SXTP') and title like 'Kế hoạch đã được chỉnh khi duyệt%'),
  'Chốt xong: người lập nhận danh sách dòng đã chỉnh');
select pg_temp.fails($$select app.plan_chair_save_line(pg_temp.v('plan'), pg_temp.v('l25'), null, 7000, 1, 'Bobin gỗ', 500, 'KAVIX', 'x')$$, 'chờ duyệt',
  'Kế hoạch đã duyệt: không sửa dòng qua đường người duyệt (dùng phiếu điều chỉnh)');

-- ================================================================ 4. Đề xuất mua (PR): Giám đốc sửa khi duyệt
select pg_temp.as_user('E_MUANV');
insert into t select 'pr', app.create_pr(pg_temp.today() + 7, 'Mua đồng', '[{"material_code": "CU-024", "qty": 100}, {"material_code": "PVC-FR", "qty": 50}]');
insert into t select 'pr_req', wf.submit('PR', pg_temp.v('pr'), (select pr_no from purchase.purchase_requests where id = pg_temp.v('pr')), 'Mua đồng');
select pg_temp.fails($$select app.save_pr_line(pg_temp.v('pr'), 'CU-024', 120, null)$$, 'Người lập không sửa', 'Người lập không sửa đề xuất đang chờ duyệt');
select pg_temp.as_user('E_GD');
select pg_temp.fails($$select app.save_pr_line(pg_temp.v('pr'), 'CU-024', 120, null)$$, 'TP Mua', 'Giám đốc chưa tới bước của mình thì không sửa');
select pg_temp.as_user('E_MUATP');
select app.save_pr_line(pg_temp.v('pr'), 'CU-024', 90, null);
select pg_temp.ok(wf.act(pg_temp.v('pr_req'), 'APPROVE', null) = 'PENDING', 'TP Mua sửa số mua 100 → 90 rồi duyệt, chuyển Giám đốc');
select pg_temp.as_user('E_GD');
select app.save_pr_line(pg_temp.v('pr'), 'CU-024', 80, null);
select pg_temp.ok((select l.qty = 80 from purchase.pr_lines l join master.materials m on m.id = l.material_id and m.code = 'CU-024' where l.pr_id = pg_temp.v('pr')),
  'Giám đốc sửa số mua đồng 100 → 80 khi duyệt');
select app.delete_pr_line((select l.id from purchase.pr_lines l join master.materials m on m.id = l.material_id and m.code = 'PVC-FR' where l.pr_id = pg_temp.v('pr')));
select pg_temp.fails($$select app.delete_pr_line((select id from purchase.pr_lines where pr_id = pg_temp.v('pr')))$$, 'ít nhất một dòng', 'Không bỏ dòng cuối cùng khi duyệt');
select app.save_pr_header(pg_temp.v('pr'), 'Mua đồng (Giám đốc chỉnh)', pg_temp.today() + 5);
select pg_temp.ok(pg_temp.edits(pg_temp.v('pr_req')) = 4, 'Lịch sử duyệt PR ghi 4 lần sửa (TP Mua: số mua; Giám đốc: số mua, bỏ dòng, ngày cần)');
select pg_temp.ok(wf.act(pg_temp.v('pr_req'), 'APPROVE', null) = 'APPROVED', 'Giám đốc duyệt PR sau khi sửa phần đầu (mã kiểm cập nhật theo lần sửa)');
select pg_temp.fails($$select app.save_pr_line(pg_temp.v('pr'), 'CU-024', 90, null)$$, 'nháp hoặc đang chờ duyệt', 'Đề xuất đã duyệt không sửa được');

-- ================================================================ 5. Phiếu điều chỉnh kế hoạch: Chủ tịch sửa khi duyệt
select pg_temp.as_user('E_SXTP');
insert into t select 'adj', app.adj_create(pg_temp.v('plan'), 'Khách tăng đơn');
select app.adj_save(pg_temp.v('adj'), 'Khách tăng đơn', jsonb_build_array(jsonb_build_object('kind', 'QTY', 'plan_line_id', pg_temp.v('l15'), 'qty_m', 12000)));
insert into t select 'adj_req', app.adj_submit(pg_temp.v('adj'));
select pg_temp.fails($$select app.adj_save(pg_temp.v('adj'), 'x', jsonb_build_array(jsonb_build_object('kind', 'QTY', 'plan_line_id', pg_temp.v('l15'), 'qty_m', 13000)))$$,
  'Người lập không sửa', 'Người lập không sửa phiếu điều chỉnh đang chờ duyệt');
select pg_temp.as_user('E_CT');
select app.adj_save(pg_temp.v('adj'), 'Khách tăng đơn (Chủ tịch chỉnh)', jsonb_build_array(jsonb_build_object('kind', 'QTY', 'plan_line_id', pg_temp.v('l15'), 'qty_m', 11000)));
select pg_temp.ok(pg_temp.edits(pg_temp.v('adj_req')) = 1, 'Chủ tịch sửa phiếu điều chỉnh khi duyệt, ghi lịch sử');
select pg_temp.ok(wf.act(pg_temp.v('adj_req'), 'APPROVE', null) = 'APPROVED', 'Chủ tịch duyệt phiếu đã sửa');
select pg_temp.ok((select qty_m = 11000 from plan.plan_lines where id = pg_temp.v('l15')), 'Kế hoạch áp số Chủ tịch đã sửa (11.000 m, không phải 12.000 m)');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
