-- Kiểm thử migration 20261026004900_dashboard: Trang tổng quan theo phân quyền (app.dashboard).
-- Mỗi khối chỉ có khi người xem có quyền; số liệu sản lượng, lô, việc của tôi, dự phòng, QC, hao hụt, hiệu suất máy, giá trị tồn kho, giá thành.
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create temp table t (k text primary key, v uuid);
create temp table j (k text primary key, v jsonb);

create function pg_temp.as_user(p_code text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', coalesce((select id::text from core.profiles where employee_code = p_code), gen_random_uuid()::text), true),
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
-- tổng quan của một người dùng
create function pg_temp.dash(p_code text) returns jsonb language plpgsql as $$
begin
  perform pg_temp.as_user(p_code);
  return app.dashboard();
end $$;
create function pg_temp.task(p_d jsonb, p_key text) returns jsonb language sql as $$
  select e from jsonb_array_elements(p_d -> 'tasks' -> 'items') e where e ->> 'key' = p_key
$$;
set client_min_messages = notice;

-- Người dùng thử
with u(code) as (values ('Q_BGD'),('Q_SXTP'),('Q_KTKHO'),('Q_QC'),('Q_MUATP'),('Q_VH'),('Q_KTT'),('Q_KD'),('Q_KTTP')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('Q_BGD','BGD'),('Q_SXTP','SX_TP'),('Q_KTKHO','KT_KHO'),('Q_QC','QC'),('Q_MUATP','MUA_TP'),
  ('Q_VH','VAN_HANH'),('Q_KTT','KTT'),('Q_KD','KD_NV'),('Q_KTTP','KT_TP')) u(code, role) on u.code = p.employee_code;
update core.profiles set status = 'LOCKED' where (employee_code is null or employee_code !~ '^Q_') and status = 'ACTIVE';
update master.operators set profile_id = null where profile_id is not null;
-- Dữ liệu thật: tạm đóng các kế hoạch đã duyệt, bỏ gán tháng của kế hoạch tháng này, xóa mức dự phòng (trong giao dịch, rollback)
update plan.production_plans set status = 'CLOSED' where status = 'APPROVED';
update plan.production_plans set period_month = null where period_month = date_trunc('month', pg_temp.today())::date;
update master.materials set safety_stock = 0 where safety_stock <> 0;
insert into inv.carriers (code, carrier_type, tare_kg, owner, status) values ('Q901', 'B630', 20, 'BMT', 'EMPTY');
-- Mốc trước khi thử (dữ liệu thật có thể đã có tồn, xuất kho, báo cáo trong kỳ)
select pg_temp.as_user('Q_BGD');
insert into j select 'base', app.dashboard();

-- ================================================================ 1. Chưa đăng nhập, quyền xem
select pg_temp.as_user('KHONG_CO');
select pg_temp.fails($$select app.dashboard()$$, 'Chưa đăng nhập', 'Chưa đăng nhập không xem được tổng quan');
select pg_temp.ok((select (d ? 'output') and (d ? 'lots') and (d ? 'tasks') and (d ? 'safety') and (d ? 'qc') and (d ? 'loss') and (d ? 'oee')
                          and (d ? 'stock') and (d ? 'cost') from (select pg_temp.dash('Q_BGD') d) x),
  'Ban giám đốc thấy đủ 9 khối: sản lượng, lô, việc, dự phòng, QC, hao hụt, hiệu suất máy, giá trị tồn kho, giá thành');
select pg_temp.ok((select (d ? 'output') and (d ? 'lots') and (d ? 'qc') and (d ? 'oee') and not (d ? 'stock') and not (d ? 'cost')
                   from (select pg_temp.dash('Q_SXTP') d) x),
  'TP SX thấy sản xuất, lô, QC, hiệu suất máy; không thấy giá trị tồn kho, giá thành (không được xem giá)');
select pg_temp.ok((select (d ? 'safety') and (d ? 'stock') and not (d ? 'cost')
                   from (select pg_temp.dash('Q_MUATP') d) x),
  'TP Mua thấy dự phòng, giá trị tồn kho; không thấy giá thành');
select pg_temp.ok((select (d ? 'stock') and (d ? 'cost') from (select pg_temp.dash('Q_KTT') d) x), 'Kế toán trưởng thấy giá trị tồn kho và giá thành');
select pg_temp.ok((select not (d ? 'stock') and not (d ? 'cost') and not (d ? 'safety') and not (d ? 'qc') and (d ? 'tasks')
                          and (d ? 'output') = (core.has_perm('production', 'view') or core.has_perm('plan', 'view'))
                   from (select pg_temp.dash('Q_VH') d) x),
  'Công nhân không thấy giá, dự phòng, QC (không thuộc mục của bộ phận); sản lượng theo quyền xem sản xuất');
-- Quản trị tick mục "Tồn dự phòng" cho Vận hành → khối dự phòng hiện (công nhân có quyền xem kho)
insert into core.role_pages (role_code, page_key) values ('VAN_HANH', 'du-phong') on conflict do nothing;
select pg_temp.ok((select (d ? 'safety') from (select pg_temp.dash('Q_VH') d) x), 'Tick thêm mục cho bộ phận thì khối tương ứng hiện ngay');
delete from core.role_pages where role_code = 'VAN_HANH' and page_key = 'du-phong';
-- Quản trị bỏ quyền xem giá thành của Kế toán trưởng → khối giá thành biến mất
delete from core.role_permissions where role_code = 'KTT' and module = 'cost' and action = 'view';
select pg_temp.ok((select not (d ? 'cost') from (select pg_temp.dash('Q_KTT') d) x), 'Bỏ tick "cost: Xem" ở Phân quyền thì khối giá thành ẩn ngay');
insert into core.role_permissions (role_code, module, action) values ('KTT', 'cost', 'view');

-- ================================================================ 2. Dựng dữ liệu: kế hoạch tháng, lệnh SX, sản lượng
insert into plan.production_plans (plan_no, period_label, period_month, material_need_date, status)
values ('KH-Q48', 'Thử 4800', date_trunc('month', pg_temp.today())::date, pg_temp.today(), 'APPROVED');
insert into t select 'plan', id from plan.production_plans where plan_no = 'KH-Q48';
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, m_per_pack, pack_type, brand, due_date)
select pg_temp.v('plan'), p.id, p.current_spec_id, q, 500, 'Bobin gỗ', 'KAVIX', pg_temp.today() + dd
from (values ('PFR-2C-1P5', 10000, -1), ('SFR-2P-1', 5000, 3)) v(code, q, dd) join master.products p on p.code = v.code;
insert into t select 'l_late', l.id from plan.plan_lines l join master.products p on p.id = l.product_id where l.plan_id = pg_temp.v('plan') and p.code = 'PFR-2C-1P5';
insert into t select 'l_risk', l.id from plan.plan_lines l join master.products p on p.id = l.product_id where l.plan_id = pg_temp.v('plan') and p.code = 'SFR-2P-1';
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, m_per_pack, pack_type, brand, due_date, committed_date, committed_by, committed_at)
select pg_temp.v('plan'), p.id, p.current_spec_id, 3000, 500, 'Bobin gỗ', 'KAVIX', pg_temp.today() + 30, pg_temp.today() + 25, pg_temp.uid('Q_SXTP'), now()
from master.products p where p.code = (select code from master.products where code not in ('PFR-2C-1P5', 'SFR-2P-1') and current_spec_id is not null order by code limit 1);
insert into mfg.work_orders (wo_no, product_id, spec_id, bom_id, qty_m, m_per_pack, pack_type, brand, status, plan_line_id)
select 'LSX-Q48', p.id, p.current_spec_id, (select h.id from master.bom_headers h where h.spec_id = p.current_spec_id limit 1), 10000, 500, 'Bobin gỗ', 'KAVIX', 'RELEASED',
       pg_temp.v('l_late')
from master.products p where p.code = 'PFR-2C-1P5';
insert into t select 'wo', id from mfg.work_orders where wo_no = 'LSX-Q48';
insert into mfg.wo_operations (wo_id, op_code, seq, planned_m)
select pg_temp.v('wo'), o.code, o.seq, 10000 from master.operations o where o.code in ('CD1', 'CD2', 'CD5', 'CD6');
-- Thành phẩm hôm nay: 2.000 m đạt QC + 500 m chờ QC; 1 lô bị hủy phiếu không tính
insert into inv.lots (lot_no, item_kind, product_id, spec_id, uom, wo_op_id, qc_status, attrs)
select x.no, 'FG', w.product_id, w.spec_id, 'm', o.id, x.st, x.attrs::jsonb
from (values ('TP-Q48-1', 'PASSED', '{}'), ('TP-Q48-2', 'PENDING', '{}'), ('TP-Q48-3', 'REJECTED', '{"void_slip": true}')) x(no, st, attrs)
join mfg.work_orders w on w.id = pg_temp.v('wo') join mfg.wo_operations o on o.wo_id = w.id and o.op_code = 'CD6';
insert into mfg.wo_outputs (wo_op_id, lot_id, qty_m)
select l.wo_op_id, l.id, case l.lot_no when 'TP-Q48-1' then 2000 when 'TP-Q48-2' then 500 else 900 end from inv.lots l where l.lot_no like 'TP-Q48-%';
-- Bện hôm nay: phiếu hoàn thành bobin (vào Chờ QC)
select pg_temp.as_user('Q_KTKHO');
select app.record_bobbin(jsonb_build_object('wo_id', pg_temp.v('wo'), 'op_code', 'CD1', 'machine_code', 'BUN-01', 'carrier', 'Q901', 'gross_kg', 125,
  'operator_code', 'NV2', 'started_at', to_char((now() at time zone 'Asia/Ho_Chi_Minh') - interval '3 minutes', 'YYYY-MM-DD"T"HH24:MI'),
  'ended_at', to_char((now() at time zone 'Asia/Ho_Chi_Minh') - interval '1 minute', 'YYYY-MM-DD"T"HH24:MI')));

insert into j select 'bgd', pg_temp.dash('Q_BGD');
select pg_temp.ok((select (d -> 'output' ->> 'today_m')::numeric = (b -> 'output' ->> 'today_m')::numeric + 2500
                          and (d -> 'output' ->> 'today_passed_m')::numeric = (b -> 'output' ->> 'today_passed_m')::numeric + 2000
                   from (select v d from j where k = 'bgd') a, (select v b from j where k = 'base') bb),
  'Sản lượng thành phẩm hôm nay: 2.500 m (2.000 m đạt QC), không tính lô đã hủy phiếu');
select pg_temp.ok((select jsonb_array_length(d -> 'output' -> 'days') = 14 and (d -> 'output' -> 'days' -> 13 ->> 'date')::date = pg_temp.today()
                          and (d -> 'output' ->> 'month_target_m')::numeric = 18000
                   from (select v d from j where k = 'bgd') a),
  'Biểu đồ 14 ngày đến hôm nay; mục tiêu tháng = 18.000 m của kế hoạch tháng này đã duyệt');
select pg_temp.ok((select (e ->> 'total_m')::numeric = 18000 and (e ->> 'done_m')::numeric = 2500
                   from (select v d from j where k = 'bgd') a, jsonb_array_elements(d -> 'output' -> 'plans') e where e ->> 'plan_no' = 'KH-Q48'),
  'Tiến độ kế hoạch đang thực hiện: 2.500 / 18.000 m thành phẩm');
select pg_temp.ok((select (e ->> 'bobbins')::int >= 1 and (e ->> 'm')::numeric > 0
                   from (select v d from j where k = 'bgd') a, jsonb_array_elements(d -> 'output' -> 'stages_today') e where e ->> 'op_code' = 'CD1'),
  'Bán thành phẩm hôm nay theo công đoạn (bện: số bobin, mét ước tính)');

-- ================================================================ 3. Lô kế hoạch tháng
select pg_temp.ok((select (d -> 'lots' ->> 'total')::int = 3 and (d -> 'lots' ->> 'late')::int = 1 and (d -> 'lots' ->> 'risk')::int = 1
                          and (d -> 'lots' ->> 'ok')::int = 1 and (d -> 'lots' ->> 'not_submitted')::int = 2 and (d -> 'lots' ->> 'wait_approve')::int = 1
                   from (select v d from j where k = 'bgd') a),
  'Lô: 3 lô, 1 trễ hạn (quá hạn giao chưa xong), 1 nguy cơ (hạn 3 ngày chưa có lịch), 1 đúng tiến độ; 2 lô chưa đệ trình, 1 lô chờ Giám đốc duyệt');
select pg_temp.ok((select d -> 'lots' -> 'items' -> 0 ->> 'state' = 'LATE' and (d -> 'lots' -> 'items' -> 0 ->> 'done_m')::numeric = 2500
                          and d -> 'lots' -> 'items' -> 1 ->> 'state' = 'RISK' and jsonb_array_length(d -> 'lots' -> 'items') = 2
                   from (select v d from j where k = 'bgd') a),
  'Danh sách lô cần chú ý: trễ hạn trước, nguy cơ sau, kèm mét đã làm');

-- ================================================================ 4. Việc của tôi: Giám đốc, TP SX, QC, Kế toán SX
insert into plan.daily_releases (plan_id, work_date, revision, status, proposed_by, proposed_at, released_at, released_by)
values (pg_temp.v('plan'), pg_temp.today() + 1, 1, 'PROPOSED', pg_temp.uid('Q_SXTP'), now(), null, null);
insert into mfg.shift_reports (work_date, shift_code, machine_code, operator_code, lines, downtime, status, submitted_by, submitted_at)
values (pg_temp.today(), 'A', 'BUN-01', 'NV2', '[{"key":"a","planned_m":1000,"declared_m":800}]',
        '[{"from":"09:00","to":"10:00","min":60,"reason":"DT_BREAKDOWN"}]', 'CONFIRMED', pg_temp.uid('Q_KTKHO'), now()),
       (pg_temp.today(), 'A', 'EXT-SI-01', 'NV1', '[{"key":"b","planned_m":2000,"declared_m":2000}]',
        '[{"from":"13:00","to":"13:30","min":30,"reason":"DT_COLOR"}]', 'SUBMITTED', pg_temp.uid('Q_KTKHO'), now());
insert into plan.overtime_requests (req_no, plan_id, extra_min, date_from, date_to, reason, proposed_by)
values ('TC-Q48', pg_temp.v('plan'), '{"BUN-01": 60}', pg_temp.today(), pg_temp.today() + 2, 'thử', pg_temp.uid('Q_SXTP'));
insert into j select 'bgd2', pg_temp.dash('Q_BGD');
select pg_temp.ok((select (pg_temp.task(d, 'release') ->> 'n')::int = 1 and (pg_temp.task(d, 'lot') ->> 'n')::int = 1 and (pg_temp.task(d, 'overtime') ->> 'n')::int = 1
                          and pg_temp.task(d, 'release') ->> 'href' like '/lenh-ngay%' and (d -> 'tasks' ? 'all_pending')
                   from (select v d from j where k = 'bgd2') a),
  'Giám đốc: lệnh SX ngày, lịch lô, đề xuất tăng ca TP SX gửi hiện ở "Việc của tôi", kèm số quy trình toàn hệ thống');
select pg_temp.ok((select pg_temp.task(d, 'release') is null and pg_temp.task(d, 'lot') is null and pg_temp.task(d, 'overtime') is null and (pg_temp.task(d, 'shift') ->> 'n')::int = 1
                          and not (d -> 'tasks' ? 'all_pending')
                   from (select pg_temp.dash('Q_SXTP') d) a),
  'TP SX: không có việc của Giám đốc (không tự duyệt đề xuất của mình); có báo cáo ca chờ chốt');
select pg_temp.ok((select (pg_temp.task(d, 'qc') ->> 'n')::int >= 2 and pg_temp.task(d, 'qc') ->> 'href' = '/kho/qc'
                   from (select pg_temp.dash('Q_QC') d) a),
  'QC: bobin, lô chờ QC (bobin bện + thành phẩm chờ)');
select pg_temp.ok((select pg_temp.task(d, 'shift') is null from (select pg_temp.dash('Q_KTKHO') d) a),
  'Kế toán SX không thấy việc chốt ca của chính báo cáo mình gửi');

-- ================================================================ 5. QC, hiệu suất máy
select pg_temp.ok((select (d -> 'qc' ->> 'pending')::int >= 2 and (d -> 'qc' ->> 'passed_7d')::int >= 1 and (d -> 'qc' ? 'late') and (d -> 'qc' ? 'limit_min')
                   from (select v d from j where k = 'bgd2') a),
  'QC: số chờ, quá hạn, đạt 7 ngày, ngưỡng phút trả kết quả');
select pg_temp.ok((select (e ->> 'down_min')::numeric = 60 and (e ->> 'attainment')::numeric = 0.8
                          and abs((e ->> 'availability')::numeric - round((s.m - 60) / s.m, 4)) < 0.0001
                   from (select v d from j where k = 'bgd2') a, jsonb_array_elements(d -> 'oee' -> 'machines') e,
                        (select (extract(epoch from (end_time - start_time)) / 60 - break_min)::numeric as m from master.shifts where code = 'A') s
                   where e ->> 'code' = 'BUN-01'),
  'Hiệu suất BUN-01: dừng 60 phút (hỏng máy) → sẵn sàng = (giờ ca − 60) / giờ ca; đạt kế hoạch 800 / 1.000 m = 80 %');
select pg_temp.ok((select exists (select 1 from jsonb_array_elements(d -> 'oee' -> 'reasons') e where e ->> 'reason' = 'DT_BREAKDOWN' and (e ->> 'min')::numeric >= 60)
                          and (d -> 'oee' ->> 'reports')::int >= 2 and (d -> 'oee' ? 'availability')
                   from (select v d from j where k = 'bgd2') a),
  'Dừng máy theo lý do (7 ngày) và hiệu suất chung từ báo cáo ca đã gửi/chốt');

-- ================================================================ 6. Giá trị tồn kho, NVL xuất, giá thành, dự phòng
select pg_temp.as_user('Q_KTKHO');
insert into t select 'op', inv.create_opening(inv.wh('KNL'), pg_temp.today(), '[{"code":"CU-024","qty":200,"unit_cost":250000,"units":2}]');
select pg_temp.as_user('Q_KTT');
select wf.act((select id from wf.approval_requests where doc_id = pg_temp.v('op')), 'APPROVE');
select pg_temp.as_user('Q_KTKHO');
insert into inv.requisitions (req_no, wo_id, kind, work_date, status, note) values ('PL-Q48', pg_temp.v('wo'), 'NORM', pg_temp.today(), 'APPROVED', 'thử');
insert into t select 'req', id from inv.requisitions where req_no = 'PL-Q48';
insert into inv.requisition_lines (req_id, material_id, qty_norm, qty_req) select pg_temp.v('req'), id, 150, 150 from master.materials where code = 'CU-024';
select app.paper_issue(pg_temp.v('req'), jsonb_build_object('receiver_code', 'NV1', 'paper_no', 'PX-Q48', 'items', jsonb_build_array(
  jsonb_build_object('code', (select h.hu_no from inv.handling_units h join inv.stock_doc_lines dl on dl.lot_id = h.lot_id where dl.doc_id = pg_temp.v('op') order by h.hu_no limit 1)))));
insert into j select 'ktt', pg_temp.dash('Q_KTT');
select pg_temp.ok((select (d -> 'stock' -> 'by_kind' ->> 'MAT')::numeric = (b -> 'stock' -> 'by_kind' ->> 'MAT')::numeric + 100 * 250000
                          and (d -> 'stock' ->> 'issued_month')::numeric = (b -> 'stock' ->> 'issued_month')::numeric + 100 * 250000
                   from (select v d from j where k = 'ktt') a, (select v b from j where k = 'base') bb),
  'Giá trị tồn NVL: nhập 200 kg đồng × 250.000 đ, xuất 100 kg cho sản xuất → còn 25 triệu; NVL đã xuất trong tháng 25 triệu');
select pg_temp.ok((select (d -> 'cost' ->> 'month_material')::numeric = (d -> 'stock' ->> 'issued_month')::numeric
                          and (d -> 'cost' ->> 'month_fg_m')::numeric >= 2500 and (d -> 'cost' ->> 'est_material_per_m')::numeric > 0
                   from (select v d from j where k = 'ktt') a),
  'Giá thành tạm tính tháng này: chi phí NVL đã xuất ÷ mét thành phẩm (khi chưa chốt kỳ giá thành)');
insert into cost.cost_periods (period, status) values (to_char(pg_temp.today(), 'YYYY-MM'), 'CALCULATED') on conflict (period) do nothing;
insert into cost.wo_costs (wo_id, period_id, good_m, std_material, act_material, std_labor, act_labor, status)
select pg_temp.v('wo'), id, 2000, 20000000, 22000000, 2000000, 2000000, 'DRAFT' from cost.cost_periods where period = to_char(pg_temp.today(), 'YYYY-MM');
select pg_temp.ok((select (e ->> 'per_m')::numeric >= 12000 and (e ->> 'wos')::int >= 1
                          and (case when (e ->> 'wos')::int = 1 then (e ->> 'per_m')::numeric = 12000 and (e ->> 'var_pct')::numeric = 9.09 else true end)
                   from (select pg_temp.dash('Q_KTT') d) a, jsonb_array_elements(d -> 'cost' -> 'periods') e where e ->> 'period' = to_char(pg_temp.today(), 'YYYY-MM')),
  'Giá thành kỳ: 24 triệu ÷ 2.000 m = 12.000 đ/m, vượt định mức 9,09 %');
-- Dự phòng: đặt mức đồng 1.000 kg → dưới mức, TP Mua có việc
update master.materials set safety_stock = 1000 where code = 'CU-024';
select pg_temp.ok((select (d -> 'safety' ->> 'below')::int >= 1 and (pg_temp.task(d, 'safety') ->> 'n')::int >= 1
                          and exists (select 1 from jsonb_array_elements(d -> 'safety' -> 'items') e where e ->> 'code' = 'CU-024' and (e ->> 'to_buy')::numeric > 0)
                   from (select pg_temp.dash('Q_MUATP') d) a),
  'Dưới mức dự phòng: đồng CU-024 hiện ở khối dự phòng (còn phải mua) và ở "Việc của tôi" của TP Mua');

-- ================================================================ 7. Hao hụt
select pg_temp.ok((select (d -> 'loss' ? 'counts') and (d -> 'loss' ? 'items') and (d -> 'loss' ? 'red_open_7d') and (d -> 'loss' ? 'scrap_month_kg')
                   from (select pg_temp.dash('Q_SXTP') d) a),
  'Hao hụt hôm nay theo mức xanh/vàng/đỏ, mục đỏ chưa giải trình 7 ngày, phế trong tháng');
select pg_temp.ok((select not (d ? 'loss') from (select pg_temp.dash('Q_MUATP') d) a),
  'TP Mua không thấy hao hụt: mục báo cáo sản xuất không thuộc bộ phận Mua');

do $$ declare v text; begin
  select string_agg(n || '. ' || msg, E'\n' order by n) into v from r;
  raise exception 'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:%', (select count(*) from r), E'\n' || v;
end $$;
rollback;
