-- BMT MES · 2000 · Hỗ trợ giao diện quy trình kiểu Fastcon + các chức năng "Thêm mới"
--  1. Hạn xử lý từng bước duyệt (SLA), thời điểm bắt đầu bước, đánh dấu đã gửi email thông báo
--  2. View hộp duyệt: thanh giai đoạn, người đang giữ bước, người duyệt tiếp theo, quá hạn
--  3. Thông báo: danh sách của tôi, đánh dấu đã đọc, hàng đợi email (chỉ service_role)
--  4. Thêm mới: spec/sản phẩm (từ mã mẫu), sửa spec nháp + BOM, vật tư, đề xuất mua (PR thủ công)

-- ---------------------------------------------------------------------------
-- 1. SLA bước duyệt
-- ---------------------------------------------------------------------------
alter table wf.approval_steps add column if not exists sla_hours integer not null default 24 check (sla_hours > 0);
alter table wf.approval_requests add column if not exists step_started_at timestamptz not null default now();
alter table wf.notifications add column if not exists emailed_at timestamptz;
update wf.notifications set emailed_at = created_at where emailed_at is null;   -- không gửi lại thông báo cũ

create or replace function wf.touch_step() returns trigger
language plpgsql as $$
begin
  if new.current_seq is distinct from old.current_seq then new.step_started_at := now(); end if;
  return new;
end $$;
drop trigger if exists trg_touch_step on wf.approval_requests;
create trigger trg_touch_step before update on wf.approval_requests
  for each row execute function wf.touch_step();

-- Người đang giữ một vai trò (để hiện "người duyệt tiếp theo"): tên + chức danh, không lộ thông tin khác
create or replace function app.role_holders(p_role text) returns jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.full_name, 'title', p.title) order by p.full_name), '[]')
  from core.user_roles ur join core.profiles p on p.id = ur.user_id and p.status = 'ACTIVE'
  where ur.role_code = p_role and auth.uid() is not null
$$;

create or replace function app.user_name(p_user uuid) returns text
language sql stable security definer set search_path = pg_catalog, public as $$
  select full_name from core.profiles where id = p_user and auth.uid() is not null
$$;

-- ---------------------------------------------------------------------------
-- 2. Hộp duyệt
-- ---------------------------------------------------------------------------
drop view if exists app.v_approvals;
create view app.v_approvals with (security_invoker = true) as
with base as (
  select r.*, f.name as doc_type_name, st.level_label as current_level, st.role_code as current_role,
         ro.name as current_role_name, st.sla_hours,
         (select count(*) from wf.approval_steps s where s.doc_type = r.doc_type and s.enabled) as step_total,
         (select count(*) from wf.approval_steps s where s.doc_type = r.doc_type and s.enabled and s.seq <= r.current_seq) as step_index
  from wf.approval_requests r
  join wf.approval_flows f on f.doc_type = r.doc_type
  left join wf.approval_steps st on st.doc_type = r.doc_type and st.seq = r.current_seq
  left join core.roles ro on ro.code = st.role_code
)
select b.id, b.doc_type, b.doc_type_name, b.doc_id, b.doc_no, b.summary, b.status, b.current_seq,
       b.current_level, b.current_role, b.current_role_name,
       case when b.status = 'PENDING' then app.role_holders(b.current_role) else '[]'::jsonb end as current_approvers,
       b.submitted_by, app.user_name(b.submitted_by) as submitted_by_name, b.submitted_at, b.finished_at,
       b.step_started_at, b.step_started_at + make_interval(hours => coalesce(b.sla_hours, 24)) as step_due_at,
       (b.status = 'PENDING' and now() > b.step_started_at + make_interval(hours => coalesce(b.sla_hours, 24))) as overdue,
       b.step_index, b.step_total,
       (b.status = 'PENDING' and b.submitted_by <> auth.uid() and core.has_role(b.current_role)) as my_turn,
       (b.submitted_by = auth.uid()) as i_submitted,
       exists (select 1 from wf.approval_actions a where a.request_id = b.id and a.actor_id = auth.uid()) as i_acted,
       case b.doc_type
         when 'SPEC_NEW' then '/san-pham/' || (select p.code from master.product_specs s join master.products p on p.id = s.product_id where s.id = b.doc_id) || '?v=' || b.doc_id
         when 'SPEC_MINOR' then '/san-pham/' || (select p.code from master.product_specs s join master.products p on p.id = s.product_id where s.id = b.doc_id) || '?v=' || b.doc_id
         when 'PLAN' then '/ke-hoach/' || b.doc_id
         when 'PR' then '/de-xuat/' || b.doc_id
       end as doc_link,
       -- Các giai đoạn: 0 = Lập phiếu, sau đó là các bước đang bật; trạng thái done/current/todo/rejected
       (select jsonb_agg(x order by (x->>'seq')::int) from (
          select jsonb_build_object('seq', 0, 'label', 'Lập phiếu', 'role_name', null, 'state', 'done',
                                    'actor', app.user_name(b.submitted_by), 'at', b.submitted_at) as x
          union all
          select jsonb_build_object(
                   'seq', s.seq, 'label', s.level_label, 'role', s.role_code, 'role_name', ro.name, 'sla_hours', s.sla_hours,
                   'state', case
                              when b.status = 'REJECTED' and s.seq = b.current_seq then 'rejected'
                              when b.status = 'APPROVED' or s.seq < b.current_seq then 'done'
                              when b.status = 'PENDING' and s.seq = b.current_seq then 'current'
                              else 'todo' end,
                   'actor', (select app.user_name(a.actor_id) from wf.approval_actions a
                              where a.request_id = b.id and a.seq = s.seq and a.action in ('APPROVE','REJECT') order by a.acted_at desc limit 1),
                   'at', (select a.acted_at from wf.approval_actions a
                           where a.request_id = b.id and a.seq = s.seq and a.action in ('APPROVE','REJECT') order by a.acted_at desc limit 1),
                   'approvers', case when b.status = 'PENDING' and s.seq >= b.current_seq then app.role_holders(s.role_code) end)
          from wf.approval_steps s left join core.roles ro on ro.code = s.role_code
          where s.doc_type = b.doc_type and s.enabled) q) as steps,
       (select jsonb_agg(jsonb_build_object('seq', a.seq, 'action', a.action, 'comment', a.comment, 'at', a.acted_at,
                                            'actor', app.user_name(a.actor_id),
                                            'label', (select s.level_label from wf.approval_steps s where s.doc_type = b.doc_type and s.seq = a.seq))
                         order by a.acted_at)
          from wf.approval_actions a where a.request_id = b.id) as history
from base b;

-- ---------------------------------------------------------------------------
-- 3. Thông báo
-- ---------------------------------------------------------------------------
create or replace view app.v_notifications with (security_invoker = true) as
select id, title, body, link, read_at, created_at from wf.notifications;

create or replace function app.mark_read(p_id bigint default null) returns void
language sql security definer set search_path = pg_catalog, public as $$
  update wf.notifications set read_at = now()
  where user_id = auth.uid() and read_at is null and (p_id is null or id = p_id)
$$;

-- Hàng đợi email: chỉ server (service_role) đọc; trả email người nhận từ auth.users
create or replace function app.notification_outbox(p_limit int default 50)
returns table (id bigint, email text, full_name text, title text, body text, link text)
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Chỉ máy chủ được đọc hàng đợi email'; end if;
  return query
  select n.id, u.email::text, p.full_name, n.title, n.body, n.link
  from wf.notifications n join core.profiles p on p.id = n.user_id join auth.users u on u.id = n.user_id
  where n.emailed_at is null and n.created_at > now() - interval '2 days'
  order by n.id limit p_limit;
end $$;

create or replace function app.mark_emailed(p_ids bigint[]) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Chỉ máy chủ được cập nhật hàng đợi email'; end if;
  update wf.notifications set emailed_at = now() where id = any(p_ids);
end $$;

-- ---------------------------------------------------------------------------
-- 4a. Spec/sản phẩm mới: sao chép từ mã mẫu gần giống rồi sửa thông số
-- ---------------------------------------------------------------------------
create or replace function app.create_spec(p_code text, p_group text, p_description text, p_template uuid, p_params jsonb default '{}')
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_product uuid; v_spec uuid; s master.product_specs; t master.products;
begin
  if not core.has_perm('spec', 'create') then raise exception 'Không có quyền tạo spec mới'; end if;
  p_code := trim(p_code);   -- giữ nguyên chữ thường theo quy ước mã (1p5 = 1,5 mm²)
  if coalesce(p_code, '') = '' then raise exception 'Nhập mã sản phẩm'; end if;
  if exists (select 1 from master.products where code = p_code) then raise exception 'Mã % đã tồn tại', p_code; end if;
  select * into s from master.product_specs where id = p_template;
  if not found then raise exception 'Chọn mã mẫu để sao chép thông số'; end if;
  select * into t from master.products where id = s.product_id;

  insert into master.products (code, group_code, description, default_brand, default_pack, default_m_per_pack)
  values (p_code, coalesce(nullif(p_group, ''), t.group_code), coalesce(nullif(trim(p_description), ''), p_code),
          coalesce(p_params->>'brand', s.brand, t.default_brand), coalesce(p_params->>'pack_type', s.pack_type, t.default_pack),
          coalesce((p_params->>'m_per_pack')::numeric, s.m_per_pack, t.default_m_per_pack))
  returning id into v_product;

  s.id := gen_random_uuid(); s.product_id := v_product; s.version := 1; s.status := 'DRAFT'; s.change_level := 'NEW';
  s.released_at := null; s.released_by := null; s.rdc_deviation_note := null;
  s.config_note := 'Tạo mới từ mẫu ' || t.code;
  s.created_at := now(); s.created_by := auth.uid(); s.updated_at := now(); s.updated_by := null;
  insert into master.product_specs select s.*;
  v_spec := s.id;
  update master.products set current_spec_id = v_spec where id = v_product;

  insert into master.spec_results (spec_id, cable_bundle_mm, od_mm, sheath_kgkm, pp_kgkm, pet_kgkm, alpet_kgkm, drain_kgkm)
  select v_spec, cable_bundle_mm, od_mm, sheath_kgkm, pp_kgkm, pet_kgkm, alpet_kgkm, drain_kgkm
  from master.spec_results where spec_id = p_template;
  insert into master.bom_headers (spec_id, status, note) values (v_spec, 'DRAFT', 'Sao chép BOM từ ' || t.code);
  insert into master.bom_lines (bom_id, material_id, basis, qty_per_basis, loss_rate, startup_per_lot, operation_code, note)
  select (select id from master.bom_headers where spec_id = v_spec), l.material_id, l.basis, l.qty_per_basis, l.loss_rate,
         l.startup_per_lot, l.operation_code, l.note
  from master.bom_lines l join master.bom_headers h on h.id = l.bom_id where h.spec_id = p_template;

  perform app.update_spec_draft(v_spec, p_params);
  return v_spec;
end $$;

-- Sửa thông số spec còn nháp (chưa gửi duyệt / bị trả lại), tính lại định mức
create or replace function app.update_spec_draft(p_spec uuid, p jsonb) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_status text;
begin
  if not (core.has_perm('spec', 'edit') or core.has_perm('spec', 'create')) then raise exception 'Không có quyền sửa spec'; end if;
  select status into v_status from master.product_specs where id = p_spec;
  if v_status not in ('DRAFT', 'PILOT_PENDING', 'PILOT') then
    raise exception 'Spec đang ở trạng thái %: chỉ sửa được spec nháp', v_status;
  end if;
  update master.product_specs set
    core_code   = coalesce(nullif(p->>'core_code', ''), core_code),
    cores       = coalesce((nullif(p->>'cores', ''))::int, cores),
    pairs       = coalesce((nullif(p->>'pairs', ''))::int, pairs),
    insulation  = coalesce(nullif(p->>'insulation', ''), insulation),
    sheath      = coalesce(nullif(p->>'sheath', ''), sheath),
    ins_thickness_mm    = coalesce((nullif(p->>'ins_thickness_mm', ''))::numeric, ins_thickness_mm),
    sheath_thickness_mm = coalesce((nullif(p->>'sheath_thickness_mm', ''))::numeric, sheath_thickness_mm),
    lay_factor  = coalesce((nullif(p->>'lay_factor', ''))::numeric, lay_factor),
    conductor_mat = coalesce(nullif(p->>'conductor_mat', ''), conductor_mat),
    wire_dia_mm = coalesce((nullif(p->>'wire_dia_mm', ''))::numeric, wire_dia_mm),
    wire_count  = coalesce((nullif(p->>'wire_count', ''))::int, wire_count),
    pitch_mm    = coalesce((nullif(p->>'pitch_mm', ''))::numeric, pitch_mm),
    drain_mat   = coalesce(nullif(p->>'drain_mat', ''), drain_mat),
    brand       = coalesce(nullif(p->>'brand', ''), brand),
    pack_type   = coalesce(nullif(p->>'pack_type', ''), pack_type),
    m_per_pack  = coalesce((nullif(p->>'m_per_pack', ''))::numeric, m_per_pack),
    sheath_color = coalesce(nullif(p->>'sheath_color', ''), sheath_color),
    insulation_colors = coalesce(nullif(p->>'insulation_colors', ''), insulation_colors),
    config_note = coalesce(nullif(p->>'config_note', ''), config_note),
    status = 'DRAFT'
  where id = p_spec;
  update master.spec_results set
    sheath_kgkm = coalesce((nullif(p->>'sheath_kgkm', ''))::numeric, sheath_kgkm),
    pp_kgkm     = coalesce((nullif(p->>'pp_kgkm', ''))::numeric, pp_kgkm),
    pet_kgkm    = coalesce((nullif(p->>'pet_kgkm', ''))::numeric, pet_kgkm),
    alpet_kgkm  = coalesce((nullif(p->>'alpet_kgkm', ''))::numeric, alpet_kgkm),
    drain_kgkm  = coalesce((nullif(p->>'drain_kgkm', ''))::numeric, drain_kgkm),
    od_mm       = coalesce((nullif(p->>'od_mm', ''))::numeric, od_mm)
  where spec_id = p_spec;
  if p ? 'description' and coalesce(trim(p->>'description'), '') <> '' then
    update master.products set description = trim(p->>'description')
    where id = (select product_id from master.product_specs where id = p_spec);
  end if;
  perform master.calc_spec(p_spec);
end $$;

-- Thêm/sửa/xóa dòng BOM của spec nháp
create or replace function app.save_bom_line(p_spec uuid, p_material_code text, p_basis text, p_qty numeric,
                                             p_loss numeric default null, p_startup numeric default 0, p_operation text default null)
returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_bom uuid; v_mat master.materials;
begin
  if not (core.has_perm('spec', 'edit') or core.has_perm('spec', 'create')) then raise exception 'Không có quyền sửa BOM'; end if;
  select h.id into v_bom from master.bom_headers h join master.product_specs s on s.id = h.spec_id
   where h.spec_id = p_spec and h.status = 'DRAFT' and s.status in ('DRAFT', 'PILOT_PENDING', 'PILOT');
  if v_bom is null then raise exception 'Chỉ sửa được BOM của spec nháp'; end if;
  select * into v_mat from master.materials where code = upper(trim(p_material_code));
  if not found then raise exception 'Không có vật tư %', p_material_code; end if;
  if coalesce(p_qty, 0) <= 0 then raise exception 'Định mức phải lớn hơn 0'; end if;
  insert into master.bom_lines (bom_id, material_id, basis, qty_per_basis, loss_rate, startup_per_lot, operation_code)
  values (v_bom, v_mat.id, coalesce(nullif(p_basis, ''), 'KM'), p_qty, coalesce(p_loss, v_mat.loss_rate), coalesce(p_startup, 0), nullif(p_operation, ''))
  on conflict (bom_id, material_id, basis) do update set qty_per_basis = excluded.qty_per_basis, loss_rate = excluded.loss_rate,
    startup_per_lot = excluded.startup_per_lot, operation_code = excluded.operation_code;
end $$;

create or replace function app.delete_bom_line(p_line uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if not (core.has_perm('spec', 'edit') or core.has_perm('spec', 'create')) then raise exception 'Không có quyền sửa BOM'; end if;
  delete from master.bom_lines l using master.bom_headers h, master.product_specs s
   where l.id = p_line and h.id = l.bom_id and s.id = h.spec_id and h.status = 'DRAFT' and s.status in ('DRAFT', 'PILOT_PENDING', 'PILOT');
  if not found then raise exception 'Chỉ xóa được dòng BOM của spec nháp'; end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4b. Vật tư mới
-- ---------------------------------------------------------------------------
create or replace function app.create_material(p_code text, p_name text, p_group text, p_uom text,
                                               p_loss numeric default 0, p_purchase_spec text default null,
                                               p_moq numeric default 0, p_multiple numeric default 1,
                                               p_lead_days int default 0, p_price numeric default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid;
begin
  if not (core.has_perm('master', 'create') or core.has_perm('master', 'edit')) then raise exception 'Không có quyền thêm vật tư'; end if;
  p_code := upper(trim(p_code));
  if coalesce(p_code, '') = '' or coalesce(trim(p_name), '') = '' then raise exception 'Nhập mã và tên vật tư'; end if;
  if exists (select 1 from master.materials where code = p_code) then raise exception 'Mã vật tư % đã tồn tại', p_code; end if;
  insert into master.materials (code, name, group_code, uom, loss_rate, purchase_spec)
  values (p_code, trim(p_name), nullif(p_group, ''), p_uom, coalesce(p_loss, 0), nullif(trim(p_purchase_spec), ''))
  returning id into v_id;
  insert into master.material_suppliers (material_id, moq, pack_multiple, lead_time_days, unit_price, is_preferred)
  values (v_id, coalesce(p_moq, 0), greatest(coalesce(p_multiple, 1), 0.0001), coalesce(p_lead_days, 0),
          case when core.can_see_price() then p_price end, true);
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 4c. Đề xuất mua (PR thủ công)
-- ---------------------------------------------------------------------------
create or replace function app.create_pr(p_need_date date, p_note text, p_lines jsonb) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_pr uuid; l jsonb; v_mat uuid;
begin
  if not core.has_perm('purchase', 'create') then raise exception 'Không có quyền lập đề xuất mua'; end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'Nhập nội dung / lý do đề xuất'; end if;
  insert into purchase.purchase_requests (pr_no, source, need_date, note)
  values (core.next_no('PR'), 'MANUAL', p_need_date, trim(p_note)) returning id into v_pr;
  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    continue when coalesce(l->>'material_code', '') = '';
    select id into v_mat from master.materials where code = upper(trim(l->>'material_code'));
    if v_mat is null then raise exception 'Không có vật tư %', l->>'material_code'; end if;
    insert into purchase.pr_lines (pr_id, material_id, qty, need_date)
    values (v_pr, v_mat, (l->>'qty')::numeric, coalesce(nullif(l->>'need_date', '')::date, p_need_date));
  end loop;
  return v_pr;
end $$;

create or replace function app.save_pr_line(p_pr uuid, p_material_code text, p_qty numeric, p_need_date date default null)
returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_mat uuid;
begin
  if not core.has_perm('purchase', 'create') then raise exception 'Không có quyền sửa đề xuất mua'; end if;
  if (select status from purchase.purchase_requests where id = p_pr) <> 'DRAFT' then
    raise exception 'Chỉ sửa được đề xuất đang nháp hoặc bị trả lại';
  end if;
  select id into v_mat from master.materials where code = upper(trim(p_material_code));
  if v_mat is null then raise exception 'Không có vật tư %', p_material_code; end if;
  if coalesce(p_qty, 0) <= 0 then raise exception 'Số lượng phải lớn hơn 0'; end if;
  update purchase.pr_lines set qty = p_qty, need_date = coalesce(p_need_date, need_date) where pr_id = p_pr and material_id = v_mat;
  if not found then
    insert into purchase.pr_lines (pr_id, material_id, qty, need_date)
    values (p_pr, v_mat, p_qty, coalesce(p_need_date, (select need_date from purchase.purchase_requests where id = p_pr)));
  end if;
end $$;

create or replace function app.delete_pr_line(p_line uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if not core.has_perm('purchase', 'create') then raise exception 'Không có quyền sửa đề xuất mua'; end if;
  delete from purchase.pr_lines l using purchase.purchase_requests r
   where l.id = p_line and r.id = l.pr_id and r.status = 'DRAFT';
  if not found then raise exception 'Chỉ xóa được dòng của đề xuất đang nháp'; end if;
end $$;

create or replace view app.v_prs with (security_invoker = true) as
select r.id, r.pr_no, r.source, r.status, r.need_date, r.note, r.created_at, r.created_by,
       app.user_name(r.created_by) as created_by_name,
       (select count(*) from purchase.pr_lines l where l.pr_id = r.id) as line_count,
       (select ar.id from wf.approval_requests ar where ar.doc_type = 'PR' and ar.doc_id = r.id order by ar.submitted_at desc limit 1) as request_id
from purchase.purchase_requests r;

create or replace view app.v_pr_lines with (security_invoker = true) as
select l.id, l.pr_id, m.code as material_code, m.name as material_name, m.uom, l.qty, l.need_date, l.ordered_qty,
       t.unit_price, t.lead_time_days, a.available
from purchase.pr_lines l join master.materials m on m.id = l.material_id
left join lateral (select ms.unit_price, ms.lead_time_days from master.material_suppliers ms where ms.material_id = m.id
                   order by ms.is_preferred desc, ms.supplier_id nulls first limit 1) t on true
left join inv.v_material_availability a on a.material_id = m.id;

-- Các phiên bản spec của một sản phẩm (cho trang chi tiết)
create or replace view app.v_spec_versions with (security_invoker = true) as
select s.id, s.product_id, p.code as product_code, s.version, s.status, s.change_level, s.created_at, s.released_at,
       app.user_name(s.created_by) as created_by_name, app.user_name(s.released_by) as released_by_name,
       (p.current_spec_id = s.id) as is_current
from master.product_specs s join master.products p on p.id = s.product_id;

grant select on all tables in schema app to authenticated, service_role;
revoke all on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;
