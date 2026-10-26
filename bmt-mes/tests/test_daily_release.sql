-- Kiểm thử migration 20261026002600: lệnh ngày do database tính kiểm tra + phiếu lĩnh theo BOM, nối Kho.
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create temp table t (k text primary key, v uuid);
create temp table x (k text primary key, j jsonb);

create function pg_temp.as_user(p_code text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', (select id::text from core.profiles where employee_code = p_code), true),
         set_config('request.jwt.claim.role', 'authenticated', true)
$$;
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
set client_min_messages = notice;

-- Người dùng thử
with u(code, role) as (values ('W_SXKH','SX_KH'),('W_SXTP','SX_TP'),('W_KTKHO','KT_KHO'),('W_BOTH','SX_KH'),('W_BOTH','KT_KHO'),
  ('W_THUKHO','THU_KHO'),('W_ADMIN','ADMIN')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from (select distinct code from u) c returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('W_SXKH','SX_KH'),('W_SXTP','SX_TP'),('W_KTKHO','KT_KHO'),('W_BOTH','SX_KH'),
  ('W_BOTH','KT_KHO'),('W_THUKHO','THU_KHO'),('W_ADMIN','ADMIN')) u(code, role) on u.code = p.employee_code;
-- Không để tài khoản thật nhận thông báo/được tính trong lúc thử
update core.profiles set status = 'LOCKED' where (employee_code is null or employee_code !~ '^W_') and status = 'ACTIVE';

-- Spec mẫu đã phát hành (database mới: phát hành PFR-2C-1P5 trong giao dịch)
do $$ begin
  if (select s.status from master.products p join master.product_specs s on s.id = p.current_spec_id where p.code = 'PFR-2C-1P5') <> 'RELEASED' then
    perform set_config('request.jwt.claim.sub', (select id::text from core.profiles where employee_code = 'W_ADMIN'), true);
    perform set_config('bmt.wf_release', 'on', true);
    perform master.release_spec((select current_spec_id from master.products where code = 'PFR-2C-1P5'));
    perform set_config('bmt.wf_release', '', true);
  end if;
end $$;

-- Kế hoạch đã duyệt + lịch máy: hôm nay bện (BUN-01) 2.000 m lõi và bọc cách điện (EXT-SI-01) 1.000 m lõi; bọc vỏ ngày mai
insert into plan.production_plans (plan_no, period_label, status) values ('KH-DR1', 'Thử lệnh ngày', 'APPROVED');
insert into t select 'plan', id from plan.production_plans where plan_no = 'KH-DR1';
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, run_lots, m_per_pack, pack_type, brand)
select (select v from t where k = 'plan'), p.id, p.current_spec_id, 1000, 1, 500, 'Bobin gỗ', 'KAVIX' from master.products p where p.code = 'PFR-2C-1P5';
insert into t select 'line', id from plan.plan_lines where plan_id = (select v from t where k = 'plan');
insert into plan.schedule_versions (plan_id, version, is_current, base_date, params, reason)
values ((select v from t where k = 'plan'), 1, true, pg_temp.today(),
        '{"S":420,"SPD":1,"workdays":[1,2,3,4,5,6,7],"shifts":[{"code":"A","start_time":"08:00","end_time":"17:00","break_min":60}]}', 'Thử');
insert into t select 'ver', id from plan.schedule_versions where plan_id = (select v from t where k = 'plan');
insert into plan.schedule_orders (version_id, plan_line_id, label, product_code, qty_m, meta)
values ((select v from t where k = 'ver'), (select v from t where k = 'line'), 'D01', 'PFR-2C-1P5', 1000, '{"cores":["Đỏ","Đen"]}');
insert into plan.schedule_slots (version_id, plan_line_id, op_code, color, machine_code, start_min, run_start_min, end_min, setup_min, meters, rate, speed)
values ((select v from t where k = 'ver'), (select v from t where k = 'line'), 'CD1', null, 'BUN-01', 0, 10, 210, 10, 2000, 10, 10),
       ((select v from t where k = 'ver'), (select v from t where k = 'line'), 'CD2', 'Đỏ', 'EXT-SI-01', 210, 220, 420, 10, 1000, 5, 5),
       ((select v from t where k = 'ver'), (select v from t where k = 'line'), 'CD5', 'Đen', 'EXT-TP-01', 500, 520, 620, 20, 1000, 10, 10);

-- ================================================================ 1. Việc + vật tư theo BOM
select pg_temp.ok((select count(*) = 2 and sum(meters) = 3000 and bool_and(first_slot) from plan.day_work((select v from t where k = 'ver'), pg_temp.today())),
  'Hôm nay 2 việc: bện 2.000 m lõi + bọc cách điện 1.000 m lõi (lượt đầu tiên); bọc vỏ để ngày mai');
-- Định mức tính độc lập từ BOM: bện 1.000 m cáp (2 lõi) → nhóm CD1; bọc 500 m cáp → nhóm CD2 + phối trộn CD0
create temp table expect as
select bl.material_id, round(sum(bl.qty_per_basis * em / 1000 / (1 - bl.loss_rate) + bl.startup_per_lot), 3) as qty
from (values ('CD1', 1000::numeric), ('CD2', 500), ('CD0', 500)) v(op, em)
join master.bom_lines bl on bl.operation_code = v.op and bl.basis = 'KM'
join master.bom_headers h on h.id = bl.bom_id
where h.spec_id = (select spec_id from plan.plan_lines where id = (select v from t where k = 'line'))
group by bl.material_id;
select pg_temp.ok((select count(*) > 0 from expect)
  and not exists (select 1 from expect e full join plan.day_materials((select v from t where k = 'ver'), pg_temp.today()) d on d.material_id = e.material_id
                  where d.qty is distinct from e.qty),
  'Vật tư trong ngày khớp định mức BOM (mét lõi quy ra mét cáp, cộng hao hụt khởi động lượt đầu)');

select pg_temp.as_user('W_SXKH');
insert into x select 'pv', app.kh_day_preview((select v from t where k = 'plan'), pg_temp.today());
select pg_temp.ok((select j -> 'checks' -> 0 ->> 'ok' = 'true' and j -> 'checks' -> 1 ->> 't' = '2 việc trên 2 máy' from x where k = 'pv'),
  'Kiểm tra: kế hoạch đã duyệt, 2 việc trên 2 máy');
select pg_temp.ok(exists (select 1 from x, jsonb_array_elements(x.j -> 'checks') e where x.k = 'pv' and e ->> 't' like 'Máy không chạy cả ngày:%TWS-01%'),
  'Kiểm tra: báo máy không chạy cả ngày');
select pg_temp.ok(exists (select 1 from x, jsonb_array_elements(x.j -> 'checks') e where x.k = 'pv' and e ->> 't' like 'Thiếu vật tư:%'),
  'Kiểm tra: báo thiếu vật tư theo tồn kho NVL đạt QC');
select pg_temp.ok((select jsonb_array_length(j -> 'slip') = (select count(*) from expect)
  and (select sum((e ->> 'qty')::numeric) from jsonb_array_elements(j -> 'slip') e) = (select sum(qty) from expect) from x where k = 'pv'),
  'Phiếu lĩnh dự kiến = vật tư theo BOM');

-- ================================================================ 2. Phát lệnh ngày
select pg_temp.fails($$select app.kh_release_day((select v from t where k = 'plan'), pg_temp.today(), '', '[]', '[]')$$,
  'cảnh báo', 'Còn cảnh báo (database tự tính, không tin kiểm tra web gửi) mà không ghi chú: chặn');
select pg_temp.as_user('W_BOTH');
insert into t select 'rel1', app.kh_release_day((select v from t where k = 'plan'), pg_temp.today(), 'Thử: chờ hàng về', '[]',
  '[{"item":"Đồng giả","qty":1,"unit":"kg","note":"web gửi"}]');
select pg_temp.ok((select s.lines = (select j -> 'slip' from x where k = 'pv') from plan.issue_slips s where s.release_id = (select v from t where k = 'rel1')),
  'Phiếu lĩnh lưu theo database tính, bỏ dòng do web gửi');
select pg_temp.ok((select count(*) = 1 and bool_and(wo.status = 'RELEASED') and bool_and(exists (select 1 from mfg.wo_operations o where o.wo_id = wo.id))
  from mfg.work_orders wo where wo.plan_line_id = (select v from t where k = 'line')), 'Phát lệnh ngày gắn lệnh SX (đã phát, có công đoạn) cho dòng có việc');
insert into t select 'wo', id from mfg.work_orders where plan_line_id = (select v from t where k = 'line');

-- ================================================================ 3. Duyệt phiếu lĩnh → phiếu lĩnh Kho
insert into t select 'slip1', id from plan.issue_slips where release_id = (select v from t where k = 'rel1');
select pg_temp.as_user('W_SXKH');
select pg_temp.fails($$select app.kh_approve_slip((select v from t where k = 'slip1'))$$, 'Chỉ Kế toán kho', 'Quản lý SX không duyệt phiếu lĩnh');
select pg_temp.as_user('W_BOTH');
select pg_temp.fails($$select app.kh_approve_slip((select v from t where k = 'slip1'))$$, 'không tự duyệt', 'Người phát lệnh ngày (có cả vai trò Kế toán kho) không tự duyệt phiếu lĩnh');
select pg_temp.as_user('W_KTKHO');
select app.kh_approve_slip((select v from t where k = 'slip1'));
insert into t select 'req1', id from inv.requisitions where slip_id = (select v from t where k = 'slip1');
select pg_temp.ok((select rq.status = 'APPROVED' and rq.kind = 'NORM' and rq.wo_id = (select v from t where k = 'wo') and rq.work_date = pg_temp.today()
  from inv.requisitions rq where rq.id = (select v from t where k = 'req1')), 'Duyệt phiếu lĩnh → phiếu lĩnh Kho đã duyệt theo lệnh SX, đúng ngày');
select pg_temp.ok(not exists (select 1 from expect e full join inv.requisition_lines rl on rl.material_id = e.material_id and rl.req_id = (select v from t where k = 'req1')
                              where rl.qty_req is distinct from e.qty),
  'Dòng phiếu lĩnh Kho = định mức BOM của ngày');
select pg_temp.ok(exists (select 1 from wf.notifications n join core.profiles p on p.id = n.user_id where p.employee_code = 'W_THUKHO' and n.link = '/kho/cap-phat'),
  'Thủ kho nhận thông báo cấp đầu ca');
select pg_temp.ok((select jsonb_array_length(requisitions) = 1 from app.v_kh_releases where id = (select v from t where k = 'rel1')),
  'Màn hình lệnh ngày thấy phiếu lĩnh Kho đã tạo');

-- ================================================================ 4. Phát lại bản 2 → bản trước chưa cấp thì tự hủy
select pg_temp.as_user('W_SXTP');
insert into t select 'rel2', app.kh_release_day((select v from t where k = 'plan'), pg_temp.today(), 'Bản 2', '[]', '[]');
select pg_temp.ok((select count(*) = 1 from mfg.work_orders where plan_line_id = (select v from t where k = 'line')), 'Phát lại dùng lại lệnh SX đang chạy, không tạo trùng');
select pg_temp.as_user('W_KTKHO');
select app.kh_approve_slip((select id from plan.issue_slips where release_id = (select v from t where k = 'rel2')));
select pg_temp.ok((select status = 'CANCELLED' from inv.requisitions where id = (select v from t where k = 'req1'))
  and (select count(*) = 1 from inv.requisitions rq join plan.issue_slips s on s.id = rq.slip_id where s.release_id = (select v from t where k = 'rel2') and rq.status = 'APPROVED'),
  'Bản 2 duyệt: phiếu lĩnh Kho của bản 1 chưa cấp thì hủy, tạo phiếu mới');

-- ================================================================ 5. Không có việc
select pg_temp.as_user('W_SXTP');
select pg_temp.fails($$select app.kh_release_day((select v from t where k = 'plan'), pg_temp.today() + 30, 'x', '[]', '[]')$$,
  'Không có việc', 'Ngày không có việc trong lịch máy: không phát lệnh');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
