-- BMT MES · 1800 · Tầng đọc cho web app (schema app) + khởi tạo quản trị viên đầu tiên
-- View dùng security_invoker: RLS của bảng gốc vẫn áp dụng theo người đang đăng nhập.

create schema if not exists app;
grant usage on schema app to authenticated, service_role;

-- Số chứng từ: người dùng không ghi thẳng core.number_sequences, nên hàm chạy với quyền chủ sở hữu
alter function core.next_no(text, int) security definer;

-- ---------------------------------------------------------------------------
-- Người dùng hiện tại: hồ sơ, vai trò, quyền
-- ---------------------------------------------------------------------------
create or replace function app.me() returns jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
  select jsonb_build_object(
    'id', p.id, 'full_name', p.full_name, 'employee_code', p.employee_code, 'status', p.status,
    'email', (select email from auth.users where id = p.id),
    'roles', coalesce((select jsonb_agg(ur.role_code order by ur.role_code) from core.user_roles ur where ur.user_id = p.id), '[]'),
    'perms', coalesce((select jsonb_agg(distinct rp.module || ':' || rp.action)
                       from core.user_roles ur join core.role_permissions rp on rp.role_code = ur.role_code
                       where ur.user_id = p.id), '[]'),
    'can_see_price', core.can_see_price())
  from core.profiles p where p.id = auth.uid()
$$;

-- Chỉ dùng khi hệ thống chưa có ADMIN nào: người gọi trở thành quản trị viên đầu tiên
create or replace function app.claim_first_admin(p_full_name text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then raise exception 'Cần đăng nhập'; end if;
  if exists (select 1 from core.user_roles where role_code = 'ADMIN') then
    raise exception 'Hệ thống đã có quản trị viên. Liên hệ quản trị viên để được cấp quyền.';
  end if;
  insert into core.profiles (id, full_name, department, title, status)
  values (auth.uid(), coalesce(nullif(trim(p_full_name), ''), 'Quản trị viên'), 'IT', 'Quản trị hệ thống', 'ACTIVE')
  on conflict (id) do update set status = 'ACTIVE';
  insert into core.user_roles (user_id, role_code) values (auth.uid(), 'ADMIN') on conflict do nothing;
end $$;

create or replace function app.needs_first_admin() returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select not exists (select 1 from core.user_roles where role_code = 'ADMIN')
$$;

-- Quản trị: tạo/cập nhật hồ sơ và vai trò (tài khoản đăng nhập do server tạo bằng service key)
create or replace function app.admin_upsert_user(p_user uuid, p_full_name text, p_employee_code text,
                                                 p_department text, p_title text, p_roles text[], p_status text default 'ACTIVE')
returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if not core.has_perm('admin', 'edit') then raise exception 'Không có quyền quản trị người dùng'; end if;
  if p_user = auth.uid() and not ('ADMIN' = any(p_roles)) then
    raise exception 'Không tự gỡ vai trò ADMIN của chính mình';
  end if;
  insert into core.profiles (id, full_name, employee_code, department, title, status)
  values (p_user, p_full_name, nullif(trim(p_employee_code), ''), nullif(p_department, ''), p_title, p_status)
  on conflict (id) do update set full_name = excluded.full_name, employee_code = excluded.employee_code,
    department = excluded.department, title = excluded.title, status = excluded.status;
  delete from core.user_roles where user_id = p_user and role_code <> all(p_roles);
  insert into core.user_roles (user_id, role_code) select p_user, unnest(p_roles) on conflict do nothing;
end $$;

-- QC/Kỹ thuật nhập kết quả đo pilot cho spec chưa phát hành
create or replace function app.record_pilot(p_spec uuid, p_kgkm numeric, p_rdc numeric, p_od numeric) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if not (core.has_perm('quality', 'edit') or core.has_perm('spec', 'edit')) then
    raise exception 'Không có quyền nhập kết quả pilot';
  end if;
  if (select status from master.product_specs where id = p_spec) in ('RELEASED', 'OBSOLETE') then
    raise exception 'Spec đã phát hành: tạo phiên bản mới để nhập pilot';
  end if;
  update master.spec_results set pilot_kgkm = p_kgkm, pilot_rdc = p_rdc, pilot_od_mm = p_od where spec_id = p_spec;
  insert into core.audit_log (user_id, table_name, row_id, action, new_data)
  values (auth.uid(), 'master.spec_results', p_spec::text, 'PILOT',
          jsonb_build_object('pilot_kgkm', p_kgkm, 'pilot_rdc', p_rdc, 'pilot_od_mm', p_od));
end $$;

-- Dòng kế hoạch: người có quyền sửa kế hoạch được xóa dòng khi kế hoạch còn Nháp
drop policy if exists p_delete on plan.plan_lines;
create policy p_delete on plan.plan_lines for delete to authenticated
  using (core.has_perm('plan', 'config')
         or (core.has_perm('plan', 'edit')
             and exists (select 1 from plan.production_plans pp where pp.id = plan_id and pp.status = 'DRAFT')));

-- ---------------------------------------------------------------------------
-- View cho màn hình
-- ---------------------------------------------------------------------------
-- Email/lần đăng nhập nằm trong auth.users (người dùng thường không đọc được): chỉ trả cho người có quyền quản trị
create or replace function app.auth_users() returns table (id uuid, email text, last_sign_in_at timestamptz)
language sql stable security definer set search_path = pg_catalog, public as $$
  select u.id, u.email::text, u.last_sign_in_at from auth.users u where core.has_perm('admin', 'view')
$$;

create or replace view app.v_users with (security_invoker = true) as
select p.id, p.full_name, p.employee_code, p.department, p.title, p.status, u.email, u.last_sign_in_at,
       coalesce((select array_agg(ur.role_code order by ur.role_code) from core.user_roles ur where ur.user_id = p.id), '{}') as roles
from core.profiles p left join app.auth_users() u on u.id = p.id;

create or replace view app.v_products with (security_invoker = true) as
select p.id, p.code, p.group_code, g.name as group_name, p.description, p.default_brand, p.default_pack, p.default_m_per_pack,
       s.id as spec_id, s.version, s.status as spec_status, s.core_code, s.cores, s.insulation, s.sheath, s.brand,
       r.metal_kgkm, r.ins_kgkm, r.total_kgkm, r.od_mm, r.rdc_calc, r.rdc_limit, r.pilot_rdc, r.pilot_kgkm, r.tech_check,
       (r.rdc_limit is not null and r.rdc_calc > r.rdc_limit) as rdc_over,
       (select ar.status from wf.approval_requests ar where ar.doc_id = s.id order by ar.submitted_at desc limit 1) as last_request_status
from master.products p
join master.product_groups g on g.code = p.group_code
left join master.product_specs s on s.id = p.current_spec_id
left join master.spec_results r on r.spec_id = s.id;

create or replace view app.v_bom_lines with (security_invoker = true) as
select h.spec_id, l.id, m.code as material_code, m.name as material_name, m.uom, l.basis, l.qty_per_basis,
       l.loss_rate, l.startup_per_lot, l.operation_code
from master.bom_lines l join master.bom_headers h on h.id = l.bom_id join master.materials m on m.id = l.material_id;

create or replace view app.v_materials with (security_invoker = true) as
select m.id, m.code, m.name, m.group_code, g.name as group_name, m.uom, m.loss_rate, m.purchase_spec,
       m.has_expiry, m.requires_coa, m.check_note, m.target_months,
       t.id as terms_id, t.moq, t.pack_multiple, t.lead_time_days, t.unit_price, t.supplier_item_code,
       a.available, a.in_quality
from master.materials m
join master.material_groups g on g.code = m.group_code
left join lateral (select * from master.material_suppliers ms where ms.material_id = m.id
                   order by ms.is_preferred desc, ms.supplier_id nulls first limit 1) t on true
left join inv.v_material_availability a on a.material_id = m.id
where not m.is_scrap;

create or replace view app.v_approvals with (security_invoker = true) as
select r.id, r.doc_type, f.name as doc_type_name, r.doc_id, r.doc_no, r.summary, r.status, r.current_seq,
       st.level_label as current_level, st.role_code as current_role,
       r.submitted_by, sp.full_name as submitted_by_name, r.submitted_at, r.finished_at,
       (r.status = 'PENDING' and r.submitted_by <> auth.uid() and core.has_role(st.role_code)) as my_turn,
       (select jsonb_agg(jsonb_build_object('seq', s.seq, 'label', s.level_label, 'role', s.role_code) order by s.seq)
          from wf.approval_steps s where s.doc_type = r.doc_type and s.enabled) as steps,
       (select jsonb_agg(jsonb_build_object('seq', a.seq, 'action', a.action, 'comment', a.comment, 'at', a.acted_at,
                                            'actor', ap.full_name) order by a.acted_at)
          from wf.approval_actions a left join core.profiles ap on ap.id = a.actor_id where a.request_id = r.id) as history
from wf.approval_requests r
join wf.approval_flows f on f.doc_type = r.doc_type
left join wf.approval_steps st on st.doc_type = r.doc_type and st.seq = r.current_seq
left join core.profiles sp on sp.id = r.submitted_by;

create or replace view app.v_plans with (security_invoker = true) as
select pp.*, (select count(*) from plan.plan_lines l where l.plan_id = pp.id) as line_count,
       (select sum(qty_m) from plan.plan_lines l where l.plan_id = pp.id) as total_m,
       (select id from plan.mrp_runs r where r.plan_id = pp.id order by run_at desc limit 1) as last_run_id
from plan.production_plans pp;

create or replace view app.v_plan_lines with (security_invoker = true) as
select l.*, p.code as product_code, p.description, s.status as spec_status, s.version as spec_version,
       r.total_kgkm, ceil(l.qty_m / l.m_per_pack) as packs,
       round(r.total_kgkm * l.m_per_pack / 1000, 2) as kg_per_pack
from plan.plan_lines l join master.products p on p.id = l.product_id
join master.product_specs s on s.id = l.spec_id left join master.spec_results r on r.spec_id = s.id;

create or replace view app.v_mrp_lines with (security_invoker = true) as
select l.*, m.code as material_code, m.name as material_name, m.uom
from plan.mrp_lines l join master.materials m on m.id = l.material_id;

create or replace view app.v_dashboard with (security_invoker = true) as
select
  (select count(*) from master.products) as products,
  (select count(*) from master.product_specs s join master.products p on p.current_spec_id = s.id where s.status = 'RELEASED') as specs_released,
  (select count(*) from master.spec_results r join master.products p on p.current_spec_id = r.spec_id where r.rdc_limit is not null and r.rdc_calc > r.rdc_limit) as specs_rdc_over,
  (select count(*) from master.material_suppliers where unit_price is null) as materials_no_price,
  (select count(*) from master.material_suppliers where lead_time_days = 0) as materials_no_leadtime,
  (select count(*) from wf.approval_requests where status = 'PENDING') as approvals_pending,
  (select count(*) from plan.production_plans where status in ('DRAFT','PENDING_APPROVAL')) as plans_open;

grant select on all tables in schema app to authenticated, service_role;
revoke all on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;
