-- Kiểm thử migration 20261026004700: phân quyền theo bộ phận (mục menu theo vai trò), ô tick phân quyền chỉ Quản trị hệ thống,
-- thông tin chung cho mọi người (app.shared_overview). Chạy bằng psql hoặc Supabase SQL Editor / MCP execute_sql; kết thúc bằng
-- "lỗi" KET_QUA_OK để ROLLBACK.
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
-- Gọi như qua API (role authenticated)
create function pg_temp.api(p_sql text) returns text language plpgsql as $$
declare v text;
begin
  set local role authenticated;
  execute p_sql into v;
  reset role;
  return v;
exception when others then
  reset role;
  return 'ERR ' || sqlerrm;
end $$;
create function pg_temp.pages(p_code text) returns jsonb language plpgsql as $$
begin
  perform pg_temp.as_user(p_code);
  return app.me() -> 'pages';
end $$;
set client_min_messages = notice;

with u(code, role) as (values ('A_ADM','ADMIN'),('A_BGD','BGD'),('A_VH','VAN_HANH'),('A_TT','TO_TRUONG'),('A_MUA','MUA_TP'),('A_KD','KD_NV'),
                              ('A_KTT','KTT'),('A_KHO','THU_KHO'),('A_QC','QC'),('A_SX','SX_TP'),('A_MIX','MUA_NV'),('A_MIX','THU_KHO')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from (select distinct code from u) x returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('A_ADM','ADMIN'),('A_BGD','BGD'),('A_VH','VAN_HANH'),('A_TT','TO_TRUONG'),('A_MUA','MUA_TP'),
  ('A_KD','KD_NV'),('A_KTT','KTT'),('A_KHO','THU_KHO'),('A_QC','QC'),('A_SX','SX_TP'),('A_MIX','MUA_NV'),('A_MIX','THU_KHO')) u(code, role) on u.code = p.employee_code;

-- ================================================================ 1. Danh mục mục + mặc định theo ma trận đã duyệt
select pg_temp.ok((select count(*) from core.pages) = 33, 'Danh mục có 33 mục menu theo bộ phận (thêm Nhân sự xưởng, Đơn mua hàng, bỏ Kiểm tra năng lực 28/10)');
select pg_temp.ok((select count(distinct role_code) from core.role_pages where page_key in ('kh-chung', 'may', 'may-bao-duong')) =
                  (select count(*) from core.roles where code <> 'ADMIN')
  and not exists (select 1 from core.roles ro where ro.code <> 'ADMIN' and
                  (select count(*) from core.role_pages rp where rp.role_code = ro.code and rp.page_key in ('kh-chung', 'may', 'may-bao-duong')) < 3),
  'Thông tin chung (Kế hoạch sản xuất chung, Danh sách máy, Bảo dưỡng) mở cho mọi vai trò');
select pg_temp.ok(exists (select 1 from core.role_permissions where role_code = 'KD_NV' and module = 'machine' and action = 'view')
  and exists (select 1 from core.role_permissions where role_code = 'THU_KHO' and module = 'plan' and action = 'view')
  and exists (select 1 from core.role_permissions where role_code = 'KTT' and module = 'quality' and action = 'view'),
  'Bổ sung quyền xem dữ liệu: Kinh doanh xem máy, Kho xem kế hoạch, Kế toán xem QC');

-- ================================================================ 2. app.me() trả mục được vào theo vai trò
select pg_temp.ok(pg_temp.pages('A_VH') ?& array['lenh-ngay', 'ghi-nhan-ca', 'may-checklist', 'may-bao-duong', 'kh-chung', 'may', 'lich-may']
  and not (pg_temp.pages('A_VH') ?| array['vat-tu', 'ke-hoach', 'kho-ton', 'kho-phieu', 'bc-hao-hut', 'quan-tri', 'tham-so']),
  'Vận hành: việc tại máy + thông tin chung; không vào Vật tư, Kế hoạch & MRP, Kho, báo cáo hao hụt, Quản trị');
select pg_temp.ok(pg_temp.pages('A_TT') ? 'kho' and not pg_temp.pages('A_VH') ? 'kho', 'Tổ trưởng thêm Tổng quan kho, vận hành thì không');
select pg_temp.ok(pg_temp.pages('A_MUA') ?& array['de-xuat', 'du-phong', 'vat-tu', 'ke-hoach', 'kho-ton', 'san-pham', 'kh-chung', 'may']
  and not (pg_temp.pages('A_MUA') ?| array['lich-may', 'lenh-ngay', 'ghi-nhan-ca', 'phieu-hoan-thanh', 'kho-phieu', 'kho-kiem-ke', 'kho-so-cai', 'bc-ngay', 'may-checklist']),
  'TP Mua: mục Mua hàng + tồn kho + thông tin chung; không còn Lịch máy, Ghi nhận ca, Phiếu kho, Kiểm kê, báo cáo SX');
select pg_temp.ok(pg_temp.pages('A_KD') ?& array['kho-ton', 'kho-xuat-ban', 'san-pham', 'kh-chung', 'may', 'may-bao-duong']
  and not (pg_temp.pages('A_KD') ?| array['de-xuat', 'ke-hoach', 'kho-phieu', 'lich-may', 'bc-hao-hut']),
  'Kinh doanh: tồn kho, xuất giao hàng, spec + thông tin chung (máy, bảo dưỡng)');
select pg_temp.ok(pg_temp.pages('A_KTT') ?& array['kho-phieu', 'kho-so-cai', 'phieu-xuat-nvl', 'bc-hao-hut', 'de-xuat']
  and not (pg_temp.pages('A_KTT') ?| array['lich-may', 'tham-so', 'may-toc-do', 'may-checklist']),
  'Kế toán trưởng: Kho, báo cáo, phiếu xuất NVL, đề xuất mua; không còn Lịch máy, Tham số, Tốc độ máy');
select pg_temp.ok(pg_temp.pages('A_KHO') ?& array['kho', 'kho-ton', 'kho-phieu', 'kho-kiem-ke', 'kho-qc', 'lenh-ngay', 'phieu-xuat-nvl', 'ke-hoach'],
  'Thủ kho: mục Kho, QC, Lệnh SX ngày, Phiếu xuất NVL, xem kế hoạch');
select pg_temp.ok(pg_temp.pages('A_MIX') ?& array['de-xuat', 'kho-phieu'], 'Người giữ hai vai trò được vào tổng các mục');
select pg_temp.ok(jsonb_array_length(pg_temp.pages('A_ADM')) = 33 and (app.me() ->> 'is_admin')::boolean, 'Quản trị hệ thống vào mọi mục');
select pg_temp.ok(not pg_temp.pages('A_BGD') ? 'quan-tri-phan-quyen' and pg_temp.pages('A_BGD') ? 'quan-tri'
  and not coalesce((app.me() ->> 'is_admin')::boolean, false), 'Giám đốc xem Người dùng nhưng không phải Quản trị');
-- Ủy quyền vai trò Quản trị không làm người nhận thành Quản trị
insert into core.delegations (from_user, to_user, role_code, valid_from, valid_to, reason)
values (pg_temp.uid('A_ADM'), pg_temp.uid('A_KD'), 'ADMIN', now() - interval '1 hour', now() + interval '1 day', 'thử');
select pg_temp.as_user('A_KD');
select pg_temp.ok(not coalesce((app.me() ->> 'is_admin')::boolean, false), 'Nhận ủy quyền vai trò Quản trị không mở Phân quyền');
delete from core.delegations where to_user = pg_temp.uid('A_KD');

-- ================================================================ 3. Ô tick phân quyền: chỉ Quản trị hệ thống
select pg_temp.as_user('A_BGD');
select pg_temp.ok(pg_temp.api('select app.admin_access_matrix()::text') like 'ERR Chỉ Quản trị%', 'Giám đốc không xem được ma trận phân quyền');
select pg_temp.ok(pg_temp.api($q$select app.admin_save_role_pages('["VAN_HANH|vat-tu"]')::text$q$) like 'ERR Chỉ Quản trị%', 'Giám đốc không lưu được quyền vào mục');
select pg_temp.ok(pg_temp.api($q$select app.admin_save_role_perms('VAN_HANH', '["plan:view"]')::text$q$) like 'ERR Chỉ Quản trị%', 'Giám đốc không lưu được quyền thao tác');
select pg_temp.ok(pg_temp.api($q$insert into core.role_pages values ('VAN_HANH', 'vat-tu') returning 'x'$q$) like 'ERR%', 'Không ghi thẳng bảng quyền vào mục qua API');
select pg_temp.as_user('A_ADM');
select pg_temp.ok(pg_temp.api($q$select (app.admin_access_matrix() -> 'pages')::text$q$) like '[%', 'Quản trị xem được ma trận phân quyền');
-- Bỏ Lịch máy của vận hành, thêm Vật tư; các ô khác giữ nguyên
select pg_temp.ok(pg_temp.api($q$select app.admin_save_role_pages((select jsonb_agg(g) from (
    select role_code || '|' || page_key g from core.role_pages where role_code <> 'ADMIN' and not (role_code = 'VAN_HANH' and page_key = 'lich-may')
    union all select 'VAN_HANH|vat-tu') x))::text$q$) ~ '^\d+$', 'Quản trị lưu quyền vào mục');
select pg_temp.ok(pg_temp.pages('A_VH') ? 'vat-tu' and not pg_temp.pages('A_VH') ? 'lich-may', 'Tick/bỏ tick có hiệu lực ngay với người dùng');
select pg_temp.ok(exists (select 1 from core.audit_log where table_name = 'core.role_pages' and action = 'ACCESS_PAGES' and user_id = pg_temp.uid('A_ADM')),
  'Lưu quyền vào mục ghi nhật ký hệ thống');
select pg_temp.as_user('A_ADM');
select pg_temp.ok(pg_temp.api($q$select app.admin_save_role_pages('["VAN_HANH|khong-co"]')::text$q$) like 'ERR Có vai trò hoặc mục không hợp lệ%', 'Mục không có trong danh mục bị chặn');
select pg_temp.ok(pg_temp.api($q$select app.admin_save_role_pages('["ADMIN|vat-tu"]')::text$q$) like 'ERR Có vai trò hoặc mục không hợp lệ%', 'Không đặt mục cho vai trò Quản trị');
-- Quyền thao tác
select pg_temp.ok(pg_temp.api($q$select app.admin_save_role_perms('ADMIN', '["plan:view"]')::text$q$) like 'ERR Không sửa quyền của vai trò Quản trị%', 'Không sửa quyền của vai trò Quản trị');
select pg_temp.ok(pg_temp.api($q$select app.admin_save_role_perms('VAN_HANH', '["plan:xoa"]')::text$q$) like 'ERR Có quyền không hợp lệ%', 'Quyền không hợp lệ bị chặn');
select pg_temp.ok(pg_temp.api($q$select app.admin_save_role_perms('KD_NV', (select jsonb_agg(module || ':' || action) from core.role_permissions
    where role_code = 'KD_NV' and not (module = 'sales' and action = 'export')))::text$q$) ~ '^\d+$', 'Quản trị bỏ quyền Xuất file bán hàng của NV kinh doanh');
select pg_temp.ok(not exists (select 1 from core.role_permissions where role_code = 'KD_NV' and module = 'sales' and action = 'export')
  and exists (select 1 from core.role_permissions where role_code = 'KD_NV' and module = 'sales' and action = 'view')
  and exists (select 1 from core.audit_log where table_name = 'core.role_permissions' and action = 'ACCESS_PERMS'),
  'Quyền thao tác đổi đúng ô, ghi nhật ký');
select pg_temp.as_user('A_KD');
select pg_temp.ok(not (app.me() -> 'perms') ? 'sales:export', 'Người dùng mất quyền ngay sau khi Quản trị bỏ tick');

-- ================================================================ 4. Thông tin chung cho mọi người
select pg_temp.as_user('A_VH');
select pg_temp.ok(pg_temp.api('select app.shared_overview()::text') like '{%', 'Vận hành xem được thông tin chung');
select pg_temp.ok((app.shared_overview() -> 'machines' ->> 'total')::int =
                  (select count(*) from master.machines where active and inline_with is null), 'Đếm máy theo dây chuyền (không tính máy con)');
-- Máy hỏng hiện trong danh sách kèm giờ chạy lại
update master.machines set status = 'DOWN', status_since = now(), status_eta = now() + interval '3 hour', status_note = 'Thử hỏng'
 where id = (select id from master.machines where active and inline_with is null order by code limit 1);
select pg_temp.ok(exists (select 1 from jsonb_array_elements(app.shared_overview() -> 'machines' -> 'down') x where x ->> 'note' = 'Thử hỏng' and x ->> 'eta' is not null),
  'Máy hỏng hiện ở Tổng quan kèm giờ dự kiến chạy lại');
-- Bảo dưỡng đến hạn trong 7 ngày
insert into mfg.maint_plans (machine_id, name, kind, level, every_days, last_done_at, active)
select id, 'Thử bảo dưỡng 7 ngày', 'INSPECT', 'MINOR', 30, now() - interval '27 days', true
from master.machines where active and inline_with is null order by code limit 1;
select pg_temp.ok(exists (select 1 from jsonb_array_elements(app.shared_overview() -> 'maint') x where x ->> 'title' = 'Thử bảo dưỡng 7 ngày' and x ->> 'kind' = 'PLAN'),
  'Kế hoạch bảo dưỡng đến hạn trong 7 ngày hiện ở Tổng quan');
select pg_temp.ok(app.shared_overview()::text !~* '(price|amount|cost|budget|đơn giá)', 'Thông tin chung không có giá, chi phí');
-- Kế hoạch tháng này: sản lượng đã làm tính theo thành phẩm (chỉ thử khi tháng này chưa có kế hoạch thật)
do $$
declare v_plan uuid; v_line uuid; v_wo uuid; v_op uuid; v_lot uuid; v_m date := date_trunc('month', (now() at time zone 'Asia/Ho_Chi_Minh')::date)::date;
begin
  if exists (select 1 from plan.production_plans where period_month = v_m and status <> 'CANCELLED') then
    insert into r(msg) values ('Tháng này đã có kế hoạch thật: bỏ qua phần thử sản lượng đã làm');
    return;
  end if;
  insert into plan.production_plans (plan_no, period_label, period_month, material_need_date, status)
  values ('KH-T47', 'Thử 4700', v_m, v_m + 5, 'APPROVED') returning id into v_plan;
  insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, run_lots, m_per_pack, pack_type, brand)
  select v_plan, id, current_spec_id, 2000, 1, 500, 'Bobin gỗ', 'KAVIX' from master.products where code = 'PFR-2C-1P5' returning id into v_line;
  insert into mfg.work_orders (wo_no, plan_line_id, product_id, spec_id, bom_id, qty_m, m_per_pack, pack_type, brand, status)
  select 'LSX-T47', v_line, p.id, p.current_spec_id, (select h.id from master.bom_headers h where h.spec_id = p.current_spec_id limit 1),
         2000, 500, 'Bobin gỗ', 'KAVIX', 'RELEASED' from master.products p where p.code = 'PFR-2C-1P5' returning id into v_wo;
  insert into mfg.wo_operations (wo_id, op_code, seq, planned_m) values (v_wo, 'CD6', 6, 2000) returning id into v_op;
  insert into inv.lots (lot_no, item_kind, product_id, uom, qc_status) select 'T47-FG', 'FG', id, 'm', 'PASSED' from master.products where code = 'PFR-2C-1P5' returning id into v_lot;
  insert into mfg.wo_outputs (wo_op_id, lot_id, qty_m) values (v_op, v_lot, 500);
  if not ((app.shared_overview() -> 'plan' ->> 'total_m')::numeric = 2000 and (app.shared_overview() -> 'plan' ->> 'done_m')::numeric = 500) then
    raise exception 'FAIL: Sản lượng tháng này: 500 / 2.000 m thành phẩm — được %', app.shared_overview() -> 'plan';
  end if;
  insert into r(msg) values ('Sản lượng tháng này: kế hoạch 2.000 m, đã làm 500 m thành phẩm');
end $$;

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
