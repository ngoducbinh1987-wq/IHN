-- Kiểm thử migration 20261026004600: tồn dự phòng (TP Mua lập → Giám đốc duyệt, cảnh báo, mua bù, MRP), đề xuất mua theo loại
-- (TP Mua → Giám đốc), PO bỏ ngưỡng, Chủ tịch HĐQT ra khỏi bước Giám đốc, lịch máy / lệnh SX ngày chờ Giám đốc duyệt.
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
create function pg_temp.steps(p_req uuid) returns text language sql as $$
  select string_agg(s ->> 'label', ' | ' order by (s ->> 'seq')::int)
  from wf.approval_requests r, jsonb_array_elements(r.flow_snapshot -> 'steps') s where r.id = p_req
$$;
create function pg_temp.notified(p_code text, p_like text) returns boolean language sql as $$
  select exists (select 1 from wf.notifications n where n.user_id = pg_temp.uid(p_code) and n.title like p_like)
$$;
set client_min_messages = notice;

-- Người dùng thử: Giám đốc, Chủ tịch HĐQT (giữ vai trò Ban giám đốc, được giao bước chốt kế hoạch tháng), TP Mua, NV mua, TP SX, Kế hoạch SX, Kế toán SX
with u(code, role) as (values ('G_GD','BGD'),('G_CT','BGD'),('G_MUATP','MUA_TP'),('G_MUANV','MUA_NV'),('G_SXTP','SX_TP'),('G_SXKH','SX_KH'),
  ('G_KTKHO','KT_KHO'),('G_ADMIN','ADMIN')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from (select distinct code from u) c returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('G_GD','BGD'),('G_CT','BGD'),('G_MUATP','MUA_TP'),('G_MUANV','MUA_NV'),('G_SXTP','SX_TP'),
  ('G_SXKH','SX_KH'),('G_KTKHO','KT_KHO'),('G_ADMIN','ADMIN')) u(code, role) on u.code = p.employee_code;
update core.profiles set status = 'LOCKED' where (employee_code is null or employee_code !~ '^G_') and status = 'ACTIVE';
update wf.approval_steps set enabled = true, assignee_ids = array[pg_temp.uid('G_CT')] where doc_type = 'PLAN' and seq = 2;
update wf.approval_steps set assignee_ids = '{}' where doc_type in ('PR', 'PO', 'SAFETY_STOCK');
update wf.approval_flows set submit_user_ids = '{}' where doc_type in ('PR', 'SAFETY_STOCK');

-- Spec mẫu đã phát hành (database mới: phát hành PFR-2C-1P5 trong giao dịch)
do $$ begin
  if (select s.status from master.products p join master.product_specs s on s.id = p.current_spec_id where p.code = 'PFR-2C-1P5') <> 'RELEASED' then
    perform set_config('request.jwt.claim.sub', (select id::text from core.profiles where employee_code = 'G_ADMIN'), true);
    perform set_config('bmt.wf_release', 'on', true);
    perform master.release_spec((select current_spec_id from master.products where code = 'PFR-2C-1P5'));
    perform set_config('bmt.wf_release', '', true);
  end if;
end $$;
-- Vật tư thử: chưa có tồn, mức dự phòng 0 (đặt lại trong giao dịch)
update master.materials set safety_stock = 0, safety_days = null where safety_stock <> 0 or safety_days is not null;
insert into t select 'm_other', id from master.materials where code not in ('CU-024', 'PVC-FR') and not is_scrap and active order by code limit 1;

-- ================================================================ 1. Chủ tịch HĐQT ra khỏi bước Giám đốc
select pg_temp.ok(plan.gd_ids() = array[pg_temp.uid('G_GD')], 'Giám đốc = người giữ vai trò Ban giám đốc, trừ Chủ tịch HĐQT');
select pg_temp.ok(not (pg_temp.uid('G_CT') = any(wf.step_actor_ids('{"role":"BGD"}'))) and pg_temp.uid('G_CT') = any(wf.step_actor_ids('{"role":"BGD","all_bgd":true}')),
  'Bước Giám đốc theo vai trò không gồm Chủ tịch (trừ bước chuyển Ban giám đốc khi Giám đốc tự lập)');
select pg_temp.ok((select min_amount is null and when_flags = '{}' and enabled from wf.approval_steps where doc_type = 'PO' and seq = 1)
  and (select not enabled from wf.approval_steps where doc_type = 'PO' and seq = 3),
  'PO: bỏ ngưỡng 20 triệu / 200 triệu, tắt bước Chủ tịch HĐQT');

-- ================================================================ 2. Đề xuất mua theo loại: TP Mua duyệt → Giám đốc duyệt
select pg_temp.as_user('G_SXTP');
select pg_temp.fails($$select app.create_pr(null, 'Tích trữ', '[{"material_code":"CU-024","qty":10}]', 'TICH_TRU')$$, 'NV mua hoặc TP Mua',
  'TP SX không lập đề xuất mua tích trữ / tối ưu');
select pg_temp.as_user('G_MUANV');
select pg_temp.fails($$select app.create_pr(null, 'x', '[{"material_code":"CU-024","qty":10}]', 'KE_HOACH')$$, 'Bổ sung, Tích trữ hoặc Tối ưu',
  'Đề xuất lập tay không ghi loại "theo kế hoạch"');
select pg_temp.fails($$select app.create_pr(null, 'x', '[]', 'BO_SUNG')$$, 'ít nhất một vật tư', 'Đề xuất phải có vật tư');
insert into t select 'pr', app.create_pr(pg_temp.today() + 20, 'Giá đồng đang thấp, mua trước quý I',
  jsonb_build_array(jsonb_build_object('material_code', (select code from master.materials where id = pg_temp.v('m_other')), 'qty', 123456.5)), 'TOI_UU');
select pg_temp.ok((select pr_kind = 'TOI_UU' and pr_kind_label = 'Mua tối ưu' and source = 'MANUAL' from app.v_prs where id = pg_temp.v('pr'))
  and (select qty = 123456.5 from purchase.pr_lines where pr_id = pg_temp.v('pr')),
  'NV mua lập đề xuất mua tối ưu với số lượng bất kỳ');
insert into t select 'pr_req', wf.submit('PR', pg_temp.v('pr'), '', 'Mua tối ưu');
select pg_temp.ok(pg_temp.steps(pg_temp.v('pr_req')) = 'TP Mua duyệt đề xuất mua | Giám đốc duyệt đề xuất mua', 'PR qua 2 bước: TP Mua duyệt → Giám đốc duyệt');
select pg_temp.ok(pg_temp.notified('G_MUATP', 'Chờ duyệt:%') and not pg_temp.notified('G_GD', 'Chờ duyệt:%'), 'Gửi duyệt báo TP Mua trước, chưa báo Giám đốc');
select pg_temp.as_user('G_GD');
select pg_temp.fails($$select wf.act(pg_temp.v('pr_req'), 'APPROVE')$$, 'cần vai trò', 'Giám đốc không duyệt trước TP Mua');
select pg_temp.as_user('G_MUATP');
select app.set_pr_kind(pg_temp.v('pr'), 'TICH_TRU');
select pg_temp.ok((select pr_kind = 'TICH_TRU' from purchase.purchase_requests where id = pg_temp.v('pr'))
  and exists (select 1 from wf.approval_actions where request_id = pg_temp.v('pr_req') and comment like '[Sửa khi duyệt] loại đề xuất%'),
  'TP Mua sửa loại đề xuất khi duyệt, ghi lịch sử');
select pg_temp.ok(wf.act(pg_temp.v('pr_req'), 'APPROVE') = 'PENDING' and pg_temp.notified('G_GD', 'Chờ duyệt:%') and not pg_temp.notified('G_CT', 'Chờ duyệt:%'),
  'TP Mua duyệt → chuyển Giám đốc (không báo Chủ tịch)');
select pg_temp.as_user('G_CT');
select pg_temp.fails($$select wf.act(pg_temp.v('pr_req'), 'APPROVE')$$, 'cần vai trò', 'Chủ tịch HĐQT không duyệt đề xuất mua');
select pg_temp.as_user('G_GD');
select pg_temp.ok(wf.act(pg_temp.v('pr_req'), 'APPROVE') = 'APPROVED', 'Giám đốc duyệt đề xuất mua');

-- ================================================================ 3. Tồn dự phòng: TP Mua lập → Giám đốc duyệt (được sửa)
select pg_temp.as_user('G_MUANV');
select pg_temp.fails($$select app.safety_create('x', '[{"material_code":"CU-024","qty":500}]')$$, 'TP Mua', 'NV mua không lập phiếu điều chỉnh mức dự phòng');
select pg_temp.as_user('G_MUATP');
select pg_temp.fails($$select app.safety_create('x', '[{"material_code":"CU-024","days":30}]')$$, 'chưa có số tiêu hao',
  'Chưa có kế hoạch / thực xuất thì phải nhập số lượng dự phòng');
select pg_temp.fails($$select app.safety_create(' ', '[{"material_code":"CU-024","qty":500}]')$$, 'lý do', 'Phiếu dự phòng phải có lý do');
insert into t select 'ss', app.safety_create('Dự phòng 1 tháng sản xuất', '[{"material_code":"CU-024","qty":500,"days":30},{"material_code":"PVC-FR","qty":200}]');
select pg_temp.ok((select count(*) = 2 and bool_and(old_qty = 0) from purchase.safety_change_lines where change_id = pg_temp.v('ss'))
  and (select change_no like 'DP-%' and status = 'DRAFT' from purchase.safety_changes where id = pg_temp.v('ss')),
  'TP Mua lập phiếu điều chỉnh dự phòng (nháp)');
insert into t select 'ss_req', app.safety_submit(pg_temp.v('ss'));
select pg_temp.ok(pg_temp.steps(pg_temp.v('ss_req')) = 'Giám đốc duyệt mức tồn dự phòng' and pg_temp.notified('G_GD', 'Chờ duyệt: DP-%')
  and not pg_temp.notified('G_CT', 'Chờ duyệt: DP-%'), 'Gửi Giám đốc duyệt (không báo Chủ tịch)');
select pg_temp.fails($$select app.safety_save(pg_temp.v('ss'), null, '[{"material_code":"CU-024","qty":600}]')$$, 'Người lập không sửa',
  'Người lập không sửa phiếu đang chờ duyệt');
select pg_temp.as_user('G_GD');
select app.safety_save(pg_temp.v('ss'), null, '[{"material_code":"CU-024","qty":400,"days":25},{"material_code":"PVC-FR","qty":200}]');
select pg_temp.ok((select new_qty = 400 and new_days = 25 from purchase.safety_change_lines l join master.materials m on m.id = l.material_id
                   where l.change_id = pg_temp.v('ss') and m.code = 'CU-024')
  and exists (select 1 from wf.approval_actions where request_id = pg_temp.v('ss_req') and comment like '[Sửa khi duyệt] mức dự phòng%')
  and pg_temp.notified('G_MUATP', 'Người duyệt đã sửa%'),
  'Giám đốc sửa mức dự phòng khi duyệt (500 → 400), ghi lịch sử, báo TP Mua');
select pg_temp.ok(wf.act(pg_temp.v('ss_req'), 'APPROVE') = 'APPROVED', 'Giám đốc duyệt phiếu dự phòng');
select pg_temp.ok((select safety_stock = 400 and safety_days = 25 and safety_set_by = pg_temp.uid('G_GD') and safety_doc_id = pg_temp.v('ss')
                   from master.materials where code = 'CU-024')
  and (select safety_stock = 200 from master.materials where code = 'PVC-FR')
  and (select applied_at is not null from purchase.safety_changes where id = pg_temp.v('ss')),
  'Duyệt xong: mức dự phòng mới áp vào danh mục vật tư');

-- Cảnh báo dưới mức
select pg_temp.as_user('G_MUANV');
select pg_temp.ok(app.safety_below_count() >= 2
  and (select below and to_buy = 400 and suggest_qty = 0 from app.safety_stock_list() where code = 'CU-024'),
  'Bảng dự phòng: CU-024 dưới mức, còn phải mua 400');
select pg_temp.ok(purchase.safety_alerts() >= 2 and pg_temp.notified('G_MUATP', 'Dưới mức dự phòng: CU-024') and pg_temp.notified('G_MUANV', 'Dưới mức dự phòng: CU-024')
  and pg_temp.notified('G_GD', 'Dưới mức dự phòng: CU-024') and not pg_temp.notified('G_CT', 'Dưới mức dự phòng%'),
  'Dưới mức dự phòng: báo TP Mua, NV mua, Giám đốc (không báo Chủ tịch)');
select pg_temp.ok(purchase.safety_alerts() = 0, 'Không báo trùng trong tuần');
-- Mua bù dự phòng
select pg_temp.as_user('G_SXTP');
select pg_temp.fails($$select app.pr_from_safety(null)$$, 'NV mua hoặc TP Mua', 'TP SX không lập đề xuất mua bù dự phòng');
select pg_temp.as_user('G_MUANV');
insert into t select 'pr_ss', app.pr_from_safety(null);
select pg_temp.ok((select pr_kind = 'BO_SUNG' and status = 'DRAFT' from purchase.purchase_requests where id = pg_temp.v('pr_ss'))
  and (select l.qty >= 400 and l.mrp_qty = 400 from purchase.pr_lines l join master.materials m on m.id = l.material_id where l.pr_id = pg_temp.v('pr_ss') and m.code = 'CU-024'),
  'NV mua lập đề xuất mua bổ sung bù dự phòng một lần bấm');
select pg_temp.fails($$select app.pr_from_safety(null)$$, 'Không vật tư nào thiếu', 'Đã đề xuất (kể cả nháp) thì không đề xuất trùng');
select pg_temp.ok((select safety_qty = 400 from app.v_pr_lines where pr_id = pg_temp.v('pr_ss') and material_code = 'CU-024'), 'Dòng đề xuất hiện mức dự phòng');
-- Tồn đủ mức lại: xóa dấu cảnh báo để lần sau báo ngay
update master.materials set safety_stock = 0 where code = 'PVC-FR';
select purchase.safety_alerts();
select pg_temp.ok(not exists (select 1 from inv.alert_log al join master.materials m on m.id = al.ref_id where al.kind = 'SAFETY' and m.code = 'PVC-FR'),
  'Hết thiếu thì xóa dấu cảnh báo');

-- ================================================================ 4. Kế hoạch + lịch máy: MRP mua bù dự phòng
insert into plan.production_plans (plan_no, period_label, status) values ('KH-G1', 'Thử dự phòng', 'APPROVED');
insert into t select 'plan', id from plan.production_plans where plan_no = 'KH-G1';
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, run_lots, m_per_pack, pack_type, brand)
select pg_temp.v('plan'), p.id, p.current_spec_id, 1000, 1, 500, 'Bobin gỗ', 'KAVIX' from master.products p where p.code = 'PFR-2C-1P5';
insert into t select 'line', id from plan.plan_lines where plan_id = pg_temp.v('plan');
select pg_temp.as_user('G_SXTP');
insert into t select 'run', app.plan_run_mrp(pg_temp.v('plan'));
select pg_temp.ok((select reserve = 400 and net_short = round(greatest(0, total_issue + 400 - available - incoming - requested), 4)
                          and projected = round(available + incoming + requested - total_issue - 400, 4)
                   from plan.mrp_lines l join master.materials m on m.id = l.material_id where l.run_id = pg_temp.v('run') and m.code = 'CU-024'),
  'MRP: dự phòng = mức đã duyệt, đề nghị mua bù đủ mức; tồn dự kiến sau SX tính sau khi giữ mức dự phòng');
select pg_temp.ok((select x.per_day > 0 and x.plan_no = 'KH-G1' from purchase.use_rates() x where x.material_id = (select id from master.materials where code = 'CU-024')),
  'Tiêu hao/ngày tính theo kế hoạch tháng đã duyệt (gợi ý mức dự phòng)');

-- Lịch máy đang dùng (Giám đốc đã duyệt): hôm nay bện + bọc
insert into plan.schedule_versions (plan_id, version, is_current, base_date, params, reason)
values (pg_temp.v('plan'), 1, true, pg_temp.today(),
        '{"S":420,"SPD":1,"workdays":[1,2,3,4,5,6,7],"shifts":[{"code":"A","start_time":"08:00","end_time":"17:00","break_min":60}]}', 'Thử');
insert into t select 'ver1', id from plan.schedule_versions where plan_id = pg_temp.v('plan');
insert into plan.schedule_orders (version_id, plan_line_id, label, product_code, qty_m, meta)
values (pg_temp.v('ver1'), pg_temp.v('line'), 'D01', 'PFR-2C-1P5', 1000, '{"cores":["Đỏ","Đen"]}');
insert into plan.schedule_slots (version_id, plan_line_id, op_code, color, machine_code, start_min, run_start_min, end_min, setup_min, meters, rate, speed)
values (pg_temp.v('ver1'), pg_temp.v('line'), 'CD1', null, 'BUN-01', 0, 10, 210, 10, 2000, 10, 10),
       (pg_temp.v('ver1'), pg_temp.v('line'), 'CD2', 'Đỏ', 'EXT-SI-01', 210, 220, 420, 10, 1000, 5, 5);

-- ================================================================ 5. Lệnh SX ngày: Kế hoạch SX đề xuất → Giám đốc duyệt
select pg_temp.as_user('G_SXKH');
insert into t select 'rel1', app.kh_release_day(pg_temp.v('plan'), pg_temp.today(), 'Thiếu vật tư: chờ hàng về', '[]', '[]');
select pg_temp.ok((select status = 'PROPOSED' and proposed_by = pg_temp.uid('G_SXKH') from plan.daily_releases where id = pg_temp.v('rel1'))
  and not exists (select 1 from mfg.work_orders where plan_line_id = pg_temp.v('line')),
  'Kế hoạch SX đề xuất lệnh ngày: chưa phát lệnh SX');
select pg_temp.ok(pg_temp.notified('G_GD', 'Lệnh SX ngày%chờ duyệt') and not pg_temp.notified('G_CT', 'Lệnh SX ngày%'), 'Báo Giám đốc duyệt lệnh ngày (không báo Chủ tịch)');
insert into t select 'rel2', app.kh_release_day(pg_temp.v('plan'), pg_temp.today(), 'Bản sửa', '[]', '[]');
select pg_temp.ok((select status = 'SUPERSEDED' from plan.daily_releases where id = pg_temp.v('rel1')), 'Đề xuất lại thì bản đề xuất cũ bị thay');
select pg_temp.as_user('G_CT');
select pg_temp.fails($$select app.kh_release_review(pg_temp.v('rel2'), true, null)$$, 'Chỉ Giám đốc', 'Chủ tịch HĐQT không duyệt lệnh ngày');
select pg_temp.as_user('G_GD');
select pg_temp.fails($$select app.kh_release_review(pg_temp.v('rel1'), true, null)$$, 'không chờ duyệt', 'Bản đã bị thay không duyệt được');
select app.kh_release_review(pg_temp.v('rel2'), false, 'Kiểm lại tồn đồng');
select pg_temp.ok((select status = 'RETURNED' from plan.daily_releases where id = pg_temp.v('rel2')) and pg_temp.notified('G_SXKH', 'Lệnh SX ngày%bị trả lại'),
  'Giám đốc trả lại lệnh ngày, báo người đề xuất');
select pg_temp.as_user('G_SXKH');
insert into t select 'rel3', app.kh_release_day(pg_temp.v('plan'), pg_temp.today(), 'Đã kiểm tồn', '[]', '[]');
select pg_temp.as_user('G_GD');
select app.kh_release_review(pg_temp.v('rel3'), true, 'Đồng ý');
select pg_temp.ok((select status = 'RELEASED' and released_by = pg_temp.uid('G_GD') from plan.daily_releases where id = pg_temp.v('rel3'))
  and exists (select 1 from plan.issue_slips where release_id = pg_temp.v('rel3'))
  and exists (select 1 from mfg.work_orders where plan_line_id = pg_temp.v('line') and status = 'RELEASED')
  and pg_temp.notified('G_KTKHO', 'Phiếu lĩnh%chờ duyệt'),
  'Giám đốc duyệt: phát lệnh SX, phiếu lĩnh chờ Kế toán SX');
insert into t select 'rel4', app.kh_release_day(pg_temp.v('plan'), pg_temp.today(), 'Giám đốc phát bổ sung', '[]', '[]');
select pg_temp.ok((select status = 'RELEASED' and revision = 4 from plan.daily_releases where id = pg_temp.v('rel4')), 'Giám đốc tự phát lệnh ngày thì phát ngay');

-- ================================================================ 6. Lịch máy: TP SX xếp → chờ Giám đốc duyệt
select pg_temp.as_user('G_SXKH');
insert into t select 'ver2', app.kh_save_schedule(pg_temp.v('plan'), pg_temp.today(), '{}', '[]', '[]', 'Xếp lại sau khi máy chạy lại');
select pg_temp.ok((select status = 'PROPOSED' and not is_current from plan.schedule_versions where id = pg_temp.v('ver2'))
  and (select is_current from plan.schedule_versions where id = pg_temp.v('ver1')),
  'TP SX xếp lịch: bản đề xuất, lịch đang dùng giữ nguyên');
select pg_temp.ok(pg_temp.notified('G_GD', 'Lịch máy chờ duyệt%') and not pg_temp.notified('G_CT', 'Lịch máy%'), 'Báo Giám đốc duyệt lịch máy');
select pg_temp.fails($$select app.kh_schedule_review(pg_temp.v('ver2'), true, null)$$, 'Chỉ Giám đốc', 'Kế hoạch SX không tự duyệt lịch');
select pg_temp.as_user('G_SXTP');
insert into t select 'ver3', app.kh_save_schedule(pg_temp.v('plan'), pg_temp.today(), '{}', '[]', '[]', 'Gom lô cùng màu');
select pg_temp.ok((select status = 'SUPERSEDED' from plan.schedule_versions where id = pg_temp.v('ver2')), 'Bản đề xuất mới thay bản đề xuất cũ');
select pg_temp.as_user('G_GD');
select pg_temp.fails($$select app.kh_schedule_review(pg_temp.v('ver3'), false, '')$$, 'lý do', 'Trả lại lịch phải ghi lý do');
select app.kh_schedule_review(pg_temp.v('ver3'), false, 'Ưu tiên lô gấp D01');
select pg_temp.ok((select status = 'RETURNED' and not is_current from plan.schedule_versions where id = pg_temp.v('ver3')) and pg_temp.notified('G_SXTP', 'Lịch máy bị trả lại%'),
  'Giám đốc trả lại lịch, báo TP SX');
select pg_temp.as_user('G_SXTP');
insert into t select 'ver4', app.kh_save_schedule(pg_temp.v('plan'), pg_temp.today(), '{}', '[]', '[]', 'Ưu tiên D01');
select pg_temp.as_user('G_GD');
select app.kh_schedule_review(pg_temp.v('ver4'), true, null);
select pg_temp.ok((select status = 'APPROVED' and is_current and approved_by = pg_temp.uid('G_GD') from plan.schedule_versions where id = pg_temp.v('ver4'))
  and (select not is_current from plan.schedule_versions where id = pg_temp.v('ver1'))
  and pg_temp.notified('G_SXTP', 'Giám đốc đã duyệt lịch máy%'),
  'Giám đốc duyệt: bản mới thành lịch đang dùng');
insert into t select 'ver5', app.kh_save_schedule(pg_temp.v('plan'), pg_temp.today(), '{}', '[]', '[]', 'Giám đốc tự xếp');
select pg_temp.ok((select status = 'APPROVED' and is_current from plan.schedule_versions where id = pg_temp.v('ver5')), 'Giám đốc tự xếp lịch thì dùng ngay');
select pg_temp.ok((select count(*) = 1 from plan.schedule_versions where plan_id = pg_temp.v('plan') and is_current), 'Luôn chỉ một lịch đang dùng');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
