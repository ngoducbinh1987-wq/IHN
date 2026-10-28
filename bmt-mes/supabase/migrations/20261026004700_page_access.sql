-- BMT MES · 4700 · Phân quyền theo bộ phận (anh Bình duyệt 28/10/2026, Claude Doc "BMT MES – Phương án phân quyền theo bộ phận")
--  1. Mục trên menu theo vai trò: core.pages (danh mục mục), core.role_pages (vai trò được vào mục). Ai thuộc bộ phận nào vào mục
--     của bộ phận đó; Tổng quan, Thông báo, Quy trình duyệt, Trung tâm điều hành luôn mở. app.me() trả thêm 'pages'.
--  2. Thông tin chung mọi người cùng biết: Kế hoạch sản xuất chung (kế hoạch tháng, lô, KH–Thực tế), Danh sách máy (tình trạng),
--     Bảo dưỡng, sửa chữa; Tổng quan thêm 3 thẻ (app.shared_overview, không có giá).
--  3. Ô tick phân quyền: chỉ Quản trị hệ thống (core.is_admin) xem và lưu: quyền vào mục, quyền thao tác (core.role_permissions).
--  Quyền thao tác trong database (lập, sửa, duyệt) không đổi, chỉ bổ sung quyền xem dữ liệu cho các mục mới mở.

-- ===========================================================================
-- 1. Danh mục mục menu + vai trò được vào
-- ===========================================================================
create table if not exists core.pages (
  key   text primary key,
  path  text not null,
  label text not null,
  grp   text not null,
  sort  int  not null
);
create table if not exists core.role_pages (
  role_code text not null references core.roles(code) on delete cascade,
  page_key  text not null references core.pages(key) on delete cascade,
  primary key (role_code, page_key)
);
alter table core.pages enable row level security;
alter table core.role_pages enable row level security;
drop policy if exists p_select on core.pages;
create policy p_select on core.pages for select to authenticated using (true);
drop policy if exists p_select on core.role_pages;
create policy p_select on core.role_pages for select to authenticated using (true);
grant select on core.pages, core.role_pages to authenticated;

insert into core.pages (key, path, label, grp, sort) values
  ('de-xuat',            '/de-xuat',             'Đề xuất mua hàng',              'Mua hàng',        10),
  ('du-phong',           '/de-xuat/du-phong',    'Tồn dự phòng',                  'Mua hàng',        11),
  ('vat-tu',             '/vat-tu',              'Vật tư',                        'Mua hàng',        12),
  ('ke-hoach',           '/ke-hoach',            'Kế hoạch & MRP',                'Sản xuất',        20),
  ('dieu-chinh',         '/ke-hoach/dieu-chinh', 'Điều chỉnh kế hoạch tháng',     'Sản xuất',        21),
  ('kh-chung',           '/kh-thuc-te',          'Kế hoạch sản xuất chung',       'Sản xuất',        22),
  ('lich-may',           '/lich-may',            'Lịch máy',                      'Sản xuất',        23),
  ('lenh-ngay',          '/lenh-ngay',           'Lệnh SX ngày',                  'Sản xuất',        24),
  ('ghi-nhan-ca',        '/ghi-nhan-ca',         'Ghi nhận ca',                   'Sản xuất',        25),
  ('phieu-hoan-thanh',   '/phieu-hoan-thanh',    'Phiếu hoàn thành bobin',        'Sản xuất',        26),
  ('phieu-xuat-nvl',     '/phieu-xuat-nvl',      'Phiếu xuất NVL, NVL thừa',      'Sản xuất',        27),
  ('tham-so',            '/tham-so',             'Tham số xếp lịch',              'Sản xuất',        28),
  ('kho',                '/kho',                 'Tổng quan kho',                 'Kho',             30),
  ('kho-ton',            '/kho/ton',             'Tồn kho',                       'Kho',             31),
  ('kho-phieu',          '/kho/phieu',           'Phiếu kho',                     'Kho',             32),
  ('kho-kiem-ke',        '/kho/kiem-ke',         'Kiểm kê',                       'Kho',             33),
  ('kho-xuat-ban',       '/kho/xuat-ban',        'Xuất giao hàng',                'Kho',             34),
  ('bc-ngay',            '/bao-cao/ngay',        'Báo cáo sản xuất ngày',         'Báo cáo',         40),
  ('bc-hao-hut',         '/bao-cao/hao-hut',     'Báo cáo hao hụt',               'Báo cáo',         41),
  ('kho-so-cai',         '/kho/so-cai',          'Nhập – xuất – tồn',             'Báo cáo',         42),
  ('san-pham',           '/san-pham',            'Sản phẩm & Spec',               'Kỹ thuật / QA',   50),
  ('kho-qc',             '/kho/qc',              'QC bobin, lô hàng',             'Kỹ thuật / QA',   51),
  ('may',                '/may',                 'Danh sách máy',                 'Quản lý máy',     60),
  ('may-checklist',      '/may/checklist',       'Checklist đầu ca',              'Quản lý máy',     61),
  ('may-bao-duong',      '/may/bao-duong',       'Bảo dưỡng, sửa chữa',           'Quản lý máy',     62),
  ('may-toc-do',         '/may/toc-do',          'Tốc độ sản xuất',               'Quản lý máy',     63),
  ('may-kiem-tra',       '/may/kiem-tra',        'Kiểm tra năng lực',             'Quản lý máy',     64),
  ('may-lich-su',        '/may/lich-su',         'Lịch sử vận hành',              'Quản lý máy',     65),
  ('may-bao-cao',        '/may/bao-cao',         'Báo cáo bảo trì',               'Quản lý máy',     66),
  ('may-cai-dat',        '/may/cai-dat',         'Cài đặt máy',                   'Quản lý máy',     67),
  ('quan-tri',           '/quan-tri',            'Người dùng & quyền',            'Hệ thống',        90),
  ('quan-tri-quy-trinh', '/quan-tri/quy-trinh',  'Cài đặt quy trình',             'Hệ thống',        91)
on conflict (key) do update set path = excluded.path, label = excluded.label, grp = excluded.grp, sort = excluded.sort;

-- Bộ phận → vai trò (ma trận đã duyệt). Quản trị hệ thống vào mọi mục (không cần dòng).
do $$
declare
  d jsonb := '{
    "BGD": ["BGD"], "SX": ["SX_TP","SX_KH"], "CN": ["TO_TRUONG","VAN_HANH"], "TT": ["TO_TRUONG"], "KHO": ["THU_KHO","KHO_NV"],
    "KTQA": ["KT_TP","KT_NV","QC"], "KTTP": ["KT_TP"], "MUA": ["MUA_TP","MUA_NV"], "KT": ["KTT","KT_KHO","KT_GT"], "KD": ["KD_TP","KD_NV"],
    "ALL": ["BGD","SX_TP","SX_KH","TO_TRUONG","VAN_HANH","THU_KHO","KHO_NV","KT_TP","KT_NV","QC","MUA_TP","MUA_NV","KTT","KT_KHO","KT_GT","KD_TP","KD_NV"]}';
  m jsonb := '{
    "de-xuat": ["BGD","SX","MUA","KT"],
    "du-phong": ["BGD","SX","KHO","MUA","KT"],
    "vat-tu": ["BGD","SX","KHO","KTQA","MUA","KT"],
    "ke-hoach": ["BGD","SX","KHO","KTQA","MUA","KT"],
    "dieu-chinh": ["BGD","SX","KHO","KTQA","MUA","KT"],
    "kh-chung": ["ALL"],
    "lich-may": ["BGD","SX","CN","KHO","KTQA"],
    "lenh-ngay": ["BGD","SX","CN","KHO","KT"],
    "ghi-nhan-ca": ["BGD","SX","CN","KTQA","KT"],
    "phieu-hoan-thanh": ["BGD","SX","KHO","KTQA","KT"],
    "phieu-xuat-nvl": ["BGD","SX","KHO","KT"],
    "tham-so": ["BGD","SX","KTQA"],
    "kho": ["BGD","SX","TT","KHO","KT"],
    "kho-ton": ["BGD","SX","KHO","KTQA","MUA","KT","KD"],
    "kho-phieu": ["BGD","SX","KHO","KT"],
    "kho-kiem-ke": ["BGD","SX","KHO","KT"],
    "kho-xuat-ban": ["BGD","KHO","KTQA","KT","KD"],
    "bc-ngay": ["BGD","SX","KTQA","KT"],
    "bc-hao-hut": ["BGD","SX","KTQA","KT"],
    "kho-so-cai": ["BGD","SX","KHO","KT"],
    "san-pham": ["BGD","SX","KTQA","MUA","KT","KD"],
    "kho-qc": ["BGD","SX","KHO","KTQA","KT"],
    "may": ["ALL"],
    "may-checklist": ["BGD","SX","CN","KTQA"],
    "may-bao-duong": ["ALL"],
    "may-toc-do": ["BGD","SX","KTQA"],
    "may-kiem-tra": ["BGD","SX","KTQA"],
    "may-lich-su": ["BGD","SX","KTQA"],
    "may-bao-cao": ["BGD","SX","KTQA"],
    "may-cai-dat": ["BGD","KTTP"],
    "quan-tri": ["BGD"],
    "quan-tri-quy-trinh": ["BGD"]}';
  k text;
begin
  -- Chỉ nạp mặc định lần đầu (Quản trị chỉnh sau ở Phân quyền thì giữ)
  if exists (select 1 from core.role_pages) then return; end if;
  for k in select jsonb_object_keys(m) loop
    insert into core.role_pages (role_code, page_key)
    select distinct r, k
    from jsonb_array_elements_text(m -> k) dep, jsonb_array_elements_text(d -> dep) r
    where exists (select 1 from core.roles where code = r)
    on conflict do nothing;
  end loop;
end $$;

-- ===========================================================================
-- 2. Quyền xem dữ liệu cho các mục mới mở theo ma trận
-- ===========================================================================
insert into core.role_permissions (role_code, module, action)
select r, m, 'view' from (values
  ('KD_TP','machine'), ('KD_NV','machine'),                         -- tình trạng máy, bảo dưỡng: thông tin chung
  ('THU_KHO','plan'), ('KHO_NV','plan'), ('KT_GT','plan'), ('QC','plan'),   -- Kế hoạch & MRP: Kho, Kế toán, KT/QA xem
  ('THU_KHO','quality'), ('KHO_NV','quality'), ('KTT','quality'), ('KT_GT','quality'), ('SX_KH','quality'),  -- QC bobin, lô hàng: xem
  ('KT_GT','purchase')                                              -- Đề xuất mua hàng: Kế toán xem
) v(r, m)
where exists (select 1 from core.roles where code = r)
on conflict do nothing;

-- ===========================================================================
-- 3. app.me() trả thêm danh sách mục được vào
-- ===========================================================================
create or replace function app.me() returns jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
  with r as (
    select ur.role_code from core.user_roles ur where ur.user_id = auth.uid()
    union
    select d.role_code from core.delegations d where d.to_user = auth.uid() and now() between d.valid_from and d.valid_to
  )
  select jsonb_build_object(
    'id', p.id, 'full_name', p.full_name, 'employee_code', p.employee_code, 'status', p.status,
    'email', (select email from auth.users where id = p.id),
    'roles', coalesce((select jsonb_agg(r.role_code order by r.role_code) from r), '[]'),
    'delegated_roles', coalesce((select jsonb_agg(d.role_code || ':' || app.user_name(d.from_user)) from core.delegations d
                                 where d.to_user = p.id and now() between d.valid_from and d.valid_to), '[]'),
    'perms', coalesce((select jsonb_agg(distinct rp.module || ':' || rp.action)
                       from r join core.role_permissions rp on rp.role_code = r.role_code), '[]'),
    'pages', case when core.is_admin() then (select coalesce(jsonb_agg(key order by sort), '[]') from core.pages)
                  else coalesce((select jsonb_agg(distinct rp.page_key) from r join core.role_pages rp on rp.role_code = r.role_code), '[]') end,
    'is_admin', core.is_admin(),
    'can_see_price', core.can_see_price())
  from core.profiles p where p.id = auth.uid()
$$;

-- ===========================================================================
-- 4. Ô tick phân quyền: chỉ Quản trị hệ thống
-- ===========================================================================
-- Toàn bộ ma trận: mục, vai trò, quyền vào mục, quyền thao tác
create or replace function app.admin_access_matrix() returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if not core.is_admin() then raise exception 'Chỉ Quản trị hệ thống xem phân quyền'; end if;
  return jsonb_build_object(
    'pages', (select jsonb_agg(jsonb_build_object('key', key, 'label', label, 'grp', grp) order by sort) from core.pages),
    'roles', (select jsonb_agg(jsonb_build_object('code', code, 'name', name) order by code) from core.roles where code <> 'ADMIN'),
    'grants', coalesce((select jsonb_agg(role_code || '|' || page_key) from core.role_pages where role_code <> 'ADMIN'), '[]'),
    'perms', coalesce((select jsonb_agg(role_code || '|' || module || ':' || action) from core.role_permissions where role_code <> 'ADMIN'), '[]'),
    'modules', (select jsonb_agg(distinct module) from core.role_permissions));
end $$;

-- Lưu quyền vào mục: thay toàn bộ (trừ Quản trị); p_grants = ["ROLE|page", …]
create or replace function app.admin_save_role_pages(p_grants jsonb) returns int
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_old jsonb; v_new jsonb; n int;
begin
  if not core.is_admin() then raise exception 'Chỉ Quản trị hệ thống sửa phân quyền'; end if;
  if jsonb_typeof(p_grants) <> 'array' then raise exception 'Dữ liệu phân quyền không hợp lệ'; end if;
  select coalesce(jsonb_agg(role_code || '|' || page_key order by role_code, page_key), '[]') into v_old from core.role_pages where role_code <> 'ADMIN';
  create temp table if not exists _rp (role_code text, page_key text) on commit drop;
  delete from _rp where true;
  insert into _rp
  select distinct split_part(g, '|', 1), split_part(g, '|', 2) from jsonb_array_elements_text(p_grants) g;
  if exists (select 1 from _rp x where not exists (select 1 from core.roles where code = x.role_code) or x.role_code = 'ADMIN'
                                   or not exists (select 1 from core.pages where key = x.page_key)) then
    raise exception 'Có vai trò hoặc mục không hợp lệ';
  end if;
  delete from core.role_pages rp where rp.role_code <> 'ADMIN'
    and not exists (select 1 from _rp x where x.role_code = rp.role_code and x.page_key = rp.page_key);
  insert into core.role_pages (role_code, page_key) select role_code, page_key from _rp on conflict do nothing;
  select coalesce(jsonb_agg(role_code || '|' || page_key order by role_code, page_key), '[]'), count(*) into v_new, n from core.role_pages where role_code <> 'ADMIN';
  if v_new is distinct from v_old then
    insert into core.audit_log (user_id, table_name, action, old_data, new_data)
    values (auth.uid(), 'core.role_pages', 'ACCESS_PAGES', v_old, v_new);
  end if;
  return n;
end $$;

-- Lưu quyền thao tác của một vai trò: p_perms = ["module:action", …]
create or replace function app.admin_save_role_perms(p_role text, p_perms jsonb) returns int
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_old jsonb; v_new jsonb; n int;
begin
  if not core.is_admin() then raise exception 'Chỉ Quản trị hệ thống sửa phân quyền'; end if;
  if p_role = 'ADMIN' then raise exception 'Không sửa quyền của vai trò Quản trị hệ thống'; end if;
  if not exists (select 1 from core.roles where code = p_role) then raise exception 'Không có vai trò %', p_role; end if;
  if jsonb_typeof(p_perms) <> 'array' then raise exception 'Dữ liệu phân quyền không hợp lệ'; end if;
  if exists (select 1 from jsonb_array_elements_text(p_perms) x
             where split_part(x, ':', 2) not in ('view','create','edit','approve','export','config')
                or split_part(x, ':', 1) not in (select distinct module from core.role_permissions)) then
    raise exception 'Có quyền không hợp lệ';
  end if;
  select coalesce(jsonb_agg(module || ':' || action order by module, action), '[]') into v_old from core.role_permissions where role_code = p_role;
  delete from core.role_permissions rp where rp.role_code = p_role
    and not exists (select 1 from jsonb_array_elements_text(p_perms) x where x = rp.module || ':' || rp.action);
  insert into core.role_permissions (role_code, module, action)
  select distinct p_role, split_part(x, ':', 1), split_part(x, ':', 2) from jsonb_array_elements_text(p_perms) x
  on conflict do nothing;
  select coalesce(jsonb_agg(module || ':' || action order by module, action), '[]'), count(*) into v_new, n from core.role_permissions where role_code = p_role;
  if v_new is distinct from v_old then
    insert into core.audit_log (user_id, table_name, action, old_data, new_data)
    values (auth.uid(), 'core.role_permissions', 'ACCESS_PERMS', jsonb_build_object('role', p_role, 'perms', v_old), jsonb_build_object('role', p_role, 'perms', v_new));
  end if;
  return n;
end $$;

revoke all on function app.admin_access_matrix(), app.admin_save_role_pages(jsonb), app.admin_save_role_perms(text, jsonb) from public, anon;
grant execute on function app.admin_access_matrix(), app.admin_save_role_pages(jsonb), app.admin_save_role_perms(text, jsonb) to authenticated;

-- ===========================================================================
-- 5. Thông tin chung cho Tổng quan (mọi tài khoản đang hoạt động; chỉ số lượng, ngày, trạng thái – không có giá)
-- ===========================================================================
create or replace function app.shared_overview() returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_today date := (now() at time zone 'Asia/Ho_Chi_Minh')::date; p plan.production_plans; v_plan jsonb; v_mach jsonb; v_maint jsonb;
begin
  if not exists (select 1 from core.profiles where id = auth.uid() and status = 'ACTIVE') then
    raise exception 'Chưa đăng nhập';
  end if;
  -- Kế hoạch tháng này (đã duyệt, chưa có thì kế hoạch của tháng đang chờ duyệt)
  select * into p from plan.production_plans
   where period_month = date_trunc('month', v_today)::date and status in ('APPROVED', 'CLOSED', 'PENDING_APPROVAL')
   order by (status = 'PENDING_APPROVAL'), created_at desc limit 1;
  if found then
    select jsonb_build_object(
      'plan_id', p.id, 'plan_no', p.plan_no, 'label', p.period_label, 'status', p.status,
      'lines', count(*), 'total_m', coalesce(sum(l.qty_m), 0),
      'done_m', coalesce(sum(d.done_m), 0),
      'late', count(*) filter (where l.due_date is not null and l.due_date < v_today and coalesce(d.done_m, 0) < l.qty_m))
    into v_plan
    from plan.plan_lines l
    left join lateral (
      select sum(o.qty_m) as done_m
      from mfg.work_orders w join mfg.wo_operations op on op.wo_id = w.id
      join mfg.wo_outputs o on o.wo_op_id = op.id join inv.lots lt on lt.id = o.lot_id and lt.item_kind = 'FG'
      where w.plan_line_id = l.id) d on true
    where l.plan_id = p.id and l.qty_m > 0;
  end if;
  -- Máy: dây chuyền (không tính máy con), theo trạng thái; máy đang hỏng/bảo dưỡng kèm giờ chạy lại
  select jsonb_build_object(
    'total', coalesce(sum(n), 0),
    'by_status', coalesce(jsonb_object_agg(st, n), '{}'),
    'down', (select coalesce(jsonb_agg(jsonb_build_object('code', m.code, 'name', m.name, 'status', m.status,
                                                          'since', m.status_since, 'eta', m.status_eta, 'note', m.status_note)
                                        order by m.status_since), '[]')
             from master.machines m where m.active and m.inline_with is null and m.status in ('DOWN', 'MAINT')))
  into v_mach
  from (select coalesce(m.status, 'IDLE') st, count(*) n from master.machines m where m.active and m.inline_with is null group by 1) s;
  -- Bảo dưỡng 7 ngày tới: phiếu đã đặt ngày + kế hoạch đến hạn/quá hạn chưa có phiếu
  select coalesce(jsonb_agg(x order by x ->> 'date' nulls first), '[]') into v_maint from (
    select jsonb_build_object('kind', 'WO', 'no', w.wo_no, 'title', w.title, 'machine', m.code, 'date', w.planned_date,
                              'status', w.status, 'confirmed', w.sched_status = 'CONFIRMED') x
    from mfg.maint_work_orders w join master.machines m on m.id = w.machine_id
    where w.status in ('OPEN', 'IN_PROGRESS') and (w.planned_date is null or w.planned_date <= v_today + 7)
    union all
    select jsonb_build_object('kind', 'PLAN', 'no', null, 'title', mp.name, 'machine', mp.machine_code, 'date', mp.due_date,
                              'status', case when mp.due_date < v_today then 'OVERDUE' else 'DUE' end, 'confirmed', false)
    from app.v_maint_plans mp
    where mp.active and mp.open_wo is null and mp.due_date <= v_today + 7
  ) t;
  return jsonb_build_object('today', v_today, 'plan', v_plan, 'machines', v_mach, 'maint', v_maint);
end $$;
revoke all on function app.shared_overview() from public, anon;
grant execute on function app.shared_overview() to authenticated;
