-- BMT MES · 3600 · Quy trình final 27/10/2026 – Đợt 4 + 5
--  1. Phiếu điều chỉnh kế hoạch tháng (thêm mã/lô ngoài kế hoạch, đổi sản lượng, đổi hạn giao, bỏ mã): TP SX lập, Chủ tịch HĐQT duyệt
--     (quy trình PLAN_ADJ); duyệt xong MES áp vào kế hoạch, đánh dấu chạy lại dự trù. Đơn phát sinh (chen lô) thêm bước Chủ tịch.
--     Kế hoạch đã duyệt: Giám đốc vẫn đặt hạn giao lần đầu và đánh dấu gấp, đổi hạn giao đã có phải qua phiếu điều chỉnh.
--  2. Dự trù nhiều tầng TP → BTP → NVL: trừ tồn thành phẩm, bán thành phẩm theo công đoạn trước khi tính vật tư theo BOM từng công đoạn;
--     trừ hàng đang về và đề xuất mua chưa lên PO; cột tồn dự kiến sau sản xuất
--  3. Đề xuất mua từ dự trù có cột nhu cầu, tồn đạt QC, đang về, tồn dự kiến (số mua TP SX sửa được)
--  4. Lịch theo lô: ngày dự kiến (MES xếp), ngày chốt (TP SX), duyệt lịch lô = giữ chỗ trên lịch máy

-- ===========================================================================
-- 0. Cột, bảng mới
-- ===========================================================================
alter table plan.plan_lines
  add column if not exists committed_date date,          -- ngày hoàn thành TP SX chốt
  add column if not exists committed_note text,
  add column if not exists committed_by uuid,
  add column if not exists committed_at timestamptz,
  add column if not exists lot_approved_at timestamptz,  -- TP SX duyệt lịch lô: giữ chỗ trên lịch máy
  add column if not exists lot_approved_by uuid,
  add column if not exists lot_version_id uuid references plan.schedule_versions(id) on delete set null,
  add column if not exists adjustment_id uuid;            -- dòng thêm bằng phiếu điều chỉnh

alter table plan.mrp_lines
  add column if not exists requested numeric(18,4) not null default 0,   -- đề xuất mua đang chờ/đã duyệt chưa lên PO
  add column if not exists projected numeric(18,4);                       -- tồn dự kiến sau SX trước khi mua = tồn + về + đã đề xuất − cấp SX

alter table purchase.pr_lines
  add column if not exists need_qty numeric(18,4),        -- nhu cầu cấp sản xuất theo định mức
  add column if not exists available_qty numeric(18,4),   -- tồn đạt QC lúc lập
  add column if not exists incoming_qty numeric(18,4),    -- hàng đang về + đã đề xuất trước
  add column if not exists mrp_qty numeric(18,4);         -- số MES đề nghị (trước khi TP SX sửa)

-- Dự trù nhiều tầng: phần thành phẩm/BTP có sẵn trừ cho từng dòng kế hoạch
create table if not exists plan.mrp_products (
  id           bigint generated always as identity primary key,
  run_id       uuid not null references plan.mrp_runs(id) on delete cascade,
  plan_line_id uuid not null,
  product_id   uuid not null references master.products(id),
  qty_m        numeric(18,2) not null,      -- số mét kế hoạch
  fg_m         numeric(18,2) not null default 0,   -- thành phẩm sẵn có (đạt QC, chưa giữ cho đơn)
  cv_m         numeric(18,2) not null default 0,   -- cáp đã bọc vỏ (BTP CV)
  bl_m         numeric(18,2) not null default 0,   -- cáp đã xoắn (BTP BL/BS)
  lb_m         numeric(18,2) not null default 0,   -- lõi đã bọc cách điện, quy ra mét cáp
  cb_m         numeric(18,2) not null default 0,   -- ruột đã bện, quy ra mét cáp
  q6 numeric(18,2) not null, q5 numeric(18,2) not null, q34 numeric(18,2) not null, q2 numeric(18,2) not null, q1 numeric(18,2) not null
);
create index if not exists mrp_products_run on plan.mrp_products (run_id);

-- Phiếu điều chỉnh kế hoạch tháng
create table if not exists plan.plan_adjustments (
  id          uuid primary key default gen_random_uuid(),
  adj_no      text unique not null,
  plan_id     uuid not null references plan.production_plans(id) on delete cascade,
  status      text not null default 'DRAFT' check (status in ('DRAFT', 'PENDING_APPROVAL', 'APPROVED', 'CANCELLED')),
  reason      text not null check (length(trim(reason)) > 0),
  applied_at  timestamptz,
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid()
);
create table if not exists plan.plan_adjustment_lines (
  id           uuid primary key default gen_random_uuid(),
  adj_id       uuid not null references plan.plan_adjustments(id) on delete cascade,
  line_no      int not null,
  kind         text not null check (kind in ('ADD', 'QTY', 'DUE', 'REMOVE')),
  plan_line_id uuid references plan.plan_lines(id),
  product_id   uuid references master.products(id),
  qty_m        numeric(18,2),
  due_date     date,
  priority     smallint check (priority in (0, 1)),
  old_qty_m    numeric(18,2),
  old_due_date date,
  note         text,
  new_line_id  uuid
);
create index if not exists plan_adj_lines_adj on plan.plan_adjustment_lines (adj_id);
alter table plan.plan_lines drop constraint if exists plan_lines_adjustment_fk;
alter table plan.plan_lines add constraint plan_lines_adjustment_fk foreign key (adjustment_id) references plan.plan_adjustments(id) on delete set null;

do $$
declare t text;
begin
  foreach t in array array['plan.mrp_products', 'plan.plan_adjustments', 'plan.plan_adjustment_lines'] loop
    execute format('alter table %s enable row level security', t);
    execute format('revoke all on %s from anon, authenticated', t);
    execute format('grant select on %s to authenticated', t);
    execute format('grant all on %s to service_role', t);
    execute format('drop policy if exists p_select on %s', t);
    execute format('create policy p_select on %s for select to authenticated using (core.has_perm(''plan'', ''view''))', t);
  end loop;
end $$;
-- Chốt trạng thái phiếu điều chỉnh (chỉ đổi qua hàm, quy trình duyệt)
drop trigger if exists trg_guard_status on plan.plan_adjustments;
create trigger trg_guard_status before insert or update of status on plan.plan_adjustments for each row
  execute function core.guard_status('status', 'DRAFT', 'DRAFT>PENDING_APPROVAL', 'PENDING_APPROVAL>APPROVED', 'PENDING_APPROVAL>DRAFT', 'DRAFT>CANCELLED');

-- ===========================================================================
-- 1. Người duyệt đích danh, thông báo theo bước
-- ===========================================================================
-- Chủ tịch HĐQT: người được giao ở bước duyệt cuối của kế hoạch tháng (Quản trị → Cài đặt quy trình)
create or replace function plan.chair_ids() returns uuid[]
language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce((select s.assignee_ids from wf.approval_steps s
                   where s.doc_type = 'PLAN' and s.enabled and cardinality(s.assignee_ids) > 0 order by s.seq desc limit 1), '{}')
$$;
revoke execute on function plan.chair_ids() from public, anon, authenticated;

-- Báo bước tiếp theo của đơn phát sinh: bước giao đích danh báo đúng người, còn lại báo theo vai trò
create or replace function plan.notify_step(p_step jsonb, p_title text, p_body text, p_link text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if jsonb_array_length(coalesce(p_step -> 'user_ids', '[]')) > 0 then
    perform wf.notify_users(array(select x::uuid from jsonb_array_elements_text(p_step -> 'user_ids') x), p_title, p_body, p_link);
  else
    perform app.kh_notify_role(p_step ->> 'role', p_title, p_body, p_link);
  end if;
end $$;
revoke execute on function plan.notify_step(jsonb, text, text, text) from public, anon, authenticated;

-- Quy trình duyệt phiếu điều chỉnh: TP SX lập → Chủ tịch HĐQT duyệt
insert into wf.approval_flows (doc_type, name, doc_table, status_col, approved_status, rejected_status, pending_status, submit_label, active)
values ('PLAN_ADJ', 'Phiếu điều chỉnh kế hoạch tháng', 'plan.plan_adjustments', 'status', 'APPROVED', 'DRAFT', 'PENDING_APPROVAL',
        'TP SX lập phiếu điều chỉnh', true)
on conflict (doc_type) do nothing;
insert into wf.approval_steps (doc_type, seq, level_label, role_code, enabled, sla_hours, assignee_ids)
select 'PLAN_ADJ', 1, 'Chủ tịch HĐQT duyệt điều chỉnh kế hoạch tháng', 'BGD', true, 24, plan.chair_ids()
where not exists (select 1 from wf.approval_steps where doc_type = 'PLAN_ADJ');

create or replace function wf.can_submit(p_doc_type text) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce(case p_doc_type
    when 'PR'          then core.has_perm('purchase', 'create') or core.has_role('BGD') or core.has_perm('plan', 'create')
    when 'PO'          then core.has_perm('purchase', 'create')
    when 'PROPOSAL'    then core.has_perm('purchase', 'create') or core.has_perm('plan', 'create')
    when 'SO'          then core.has_perm('sales', 'create')
    when 'SPEC_NEW'    then core.has_perm('spec', 'create')
    when 'SPEC_MINOR'  then core.has_perm('spec', 'create')
    when 'PLAN'        then core.has_role('BGD') or core.has_perm('plan', 'create')
    when 'PLAN_ADJ'    then core.has_role('SX_TP') or core.has_perm('plan', 'create')
    when 'NCR'         then core.has_perm('quality', 'create')
    when 'COST_CLOSE'  then core.has_perm('cost', 'create')
    when 'WO_RELEASE'  then core.has_perm('production', 'create')
    when 'EXTRA_ISSUE' then inv.can_plan_issue() or core.has_role('ADMIN')
    when 'SCRAP_OUT'   then core.has_perm('inventory', 'create')
    when 'DELIVERY'    then core.has_perm('inventory', 'create')
    when 'STOCK_ADJ'   then core.has_role('KT_KHO') or core.has_role('ADMIN')
    when 'STOCK_OPEN'  then core.has_role('KT_KHO') or core.has_role('ADMIN')
  end, false)
$$;

-- ===========================================================================
-- 2. Phiếu điều chỉnh kế hoạch tháng
-- ===========================================================================
-- Kiểm tra trước khi gửi duyệt và trước khi áp
create or replace function plan.check_adjustment(p_adj uuid) returns void
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare a plan.plan_adjustments; pp plan.production_plans; l record; v_n int := 0; w mfg.work_orders; v_done numeric;
begin
  select * into a from plan.plan_adjustments where id = p_adj;
  if not found then raise exception 'Không tìm thấy phiếu điều chỉnh'; end if;
  select * into pp from plan.production_plans where id = a.plan_id;
  if pp.status <> 'APPROVED' then
    raise exception 'Kế hoạch % chưa duyệt (%): sửa thẳng dòng kế hoạch, không cần phiếu điều chỉnh', pp.plan_no, pp.status;
  end if;
  for l in select al.*, p.code, p.current_spec_id, s.status as spec_status
           from plan.plan_adjustment_lines al left join master.products p on p.id = al.product_id
           left join master.product_specs s on s.id = p.current_spec_id
           where al.adj_id = p_adj order by al.line_no loop
    v_n := v_n + 1;
    if l.kind = 'ADD' then
      if l.product_id is null then raise exception 'Dòng %: chọn mã sản phẩm', l.line_no; end if;
      if coalesce(l.spec_status, '') <> 'RELEASED' then raise exception 'Dòng %: mã % chưa có spec phát hành', l.line_no, l.code; end if;
      if coalesce(l.qty_m, 0) <= 0 then raise exception 'Dòng %: nhập số mét > 0', l.line_no; end if;
      if l.due_date is null then raise exception 'Dòng %: nhập hạn giao', l.line_no; end if;
    else
      if l.plan_line_id is null or not exists (select 1 from plan.plan_lines x where x.id = l.plan_line_id and x.plan_id = a.plan_id) then
        raise exception 'Dòng %: chọn dòng kế hoạch cần điều chỉnh', l.line_no;
      end if;
      select * into w from mfg.work_orders where plan_line_id = l.plan_line_id and status not in ('CANCELLED') order by created_at desc limit 1;
      select coalesce(sum(op.qty_m), 0) into v_done from mfg.wo_outputs op join mfg.wo_operations o on o.id = op.wo_op_id
       where o.wo_id = w.id and o.op_code = 'CD6';
      if l.kind = 'QTY' then
        if l.qty_m is null or l.qty_m < 0 then raise exception 'Dòng %: nhập số mét mới', l.line_no; end if;
        if w.id is not null and l.qty_m < v_done then
          raise exception 'Dòng %: lô % đã có % m thành phẩm, không giảm dưới số này', l.line_no, w.wo_no, v_done;
        end if;
      elsif l.kind = 'DUE' then
        if l.due_date is null and l.priority is null then raise exception 'Dòng %: nhập hạn giao mới hoặc mức ưu tiên', l.line_no; end if;
      elsif l.kind = 'REMOVE' then
        if w.status in ('RELEASED', 'IN_PROGRESS', 'COMPLETED', 'CLOSED') then
          raise exception 'Dòng %: lô % đang/đã sản xuất, không bỏ được: giảm số mét thay vì bỏ', l.line_no, w.wo_no;
        end if;
      end if;
    end if;
  end loop;
  if v_n = 0 then raise exception 'Phiếu điều chỉnh chưa có dòng nào'; end if;
end $$;
revoke execute on function plan.check_adjustment(uuid) from public, anon, authenticated;

-- TP SX lập phiếu (nháp)
create or replace function app.adj_create(p_plan uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare pp plan.production_plans; v_id uuid;
begin
  if not wf.can_submit('PLAN_ADJ') then raise exception 'Chỉ TP SX (Kế hoạch SX) lập phiếu điều chỉnh kế hoạch tháng'; end if;
  select * into pp from plan.production_plans where id = p_plan;
  if not found then raise exception 'Không tìm thấy kế hoạch'; end if;
  if pp.status <> 'APPROVED' then raise exception 'Kế hoạch % chưa duyệt: sửa thẳng dòng kế hoạch', pp.plan_no; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do điều chỉnh (đơn hàng mới, khách đổi hạn…)'; end if;
  insert into plan.plan_adjustments (adj_no, plan_id, reason) values (core.next_no('PDC', 3), p_plan, trim(p_reason)) returning id into v_id;
  return v_id;
end $$;

-- Lưu các dòng (thay toàn bộ) khi phiếu còn nháp
-- p_lines: [{kind, plan_line_id, product_code, qty_m, due_date, priority, note}]
create or replace function app.adj_save(p_adj uuid, p_reason text, p_lines jsonb) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare a plan.plan_adjustments; e jsonb; i int := 0; pl plan.plan_lines; v_prod uuid;
begin
  select * into a from plan.plan_adjustments where id = p_adj for update;
  if not found then raise exception 'Không tìm thấy phiếu điều chỉnh'; end if;
  if a.status <> 'DRAFT' then raise exception 'Phiếu % đã gửi duyệt: không sửa được', a.adj_no; end if;
  if a.created_by is distinct from auth.uid() and not core.is_admin() and not wf.can_submit('PLAN_ADJ') then
    raise exception 'Không có quyền sửa phiếu điều chỉnh';
  end if;
  if coalesce(trim(p_reason), '') <> '' then update plan.plan_adjustments set reason = trim(p_reason) where id = p_adj; end if;
  delete from plan.plan_adjustment_lines where adj_id = p_adj;
  for e in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    continue when coalesce(e ->> 'kind', '') = '';
    i := i + 1;
    pl := null; v_prod := null;
    if e ->> 'kind' not in ('ADD', 'QTY', 'DUE', 'REMOVE') then raise exception 'Loại điều chỉnh không hợp lệ'; end if;
    if e ->> 'kind' = 'ADD' then
      select id into v_prod from master.products where code = upper(trim(coalesce(e ->> 'product_code', '')));
      if v_prod is null then raise exception 'Dòng %: không có mã sản phẩm %', i, e ->> 'product_code'; end if;
    else
      select * into pl from plan.plan_lines where id = nullif(e ->> 'plan_line_id', '')::uuid and plan_id = a.plan_id;
      if pl.id is null then raise exception 'Dòng %: chọn dòng kế hoạch cần điều chỉnh', i; end if;
      v_prod := pl.product_id;
    end if;
    insert into plan.plan_adjustment_lines (adj_id, line_no, kind, plan_line_id, product_id, qty_m, due_date, priority, old_qty_m, old_due_date, note)
    values (p_adj, i, e ->> 'kind', pl.id, v_prod, nullif(e ->> 'qty_m', '')::numeric, nullif(e ->> 'due_date', '')::date,
            nullif(e ->> 'priority', '')::smallint, pl.qty_m, pl.due_date, nullif(trim(coalesce(e ->> 'note', '')), ''));
  end loop;
end $$;

-- Gửi Chủ tịch HĐQT duyệt
create or replace function app.adj_submit(p_adj uuid) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare a plan.plan_adjustments; pp plan.production_plans; v_sum text;
begin
  select * into a from plan.plan_adjustments where id = p_adj;
  if not found then raise exception 'Không tìm thấy phiếu điều chỉnh'; end if;
  select * into pp from plan.production_plans where id = a.plan_id;
  select string_agg(case l.kind when 'ADD' then 'Thêm ' || p.code || ' ' || core.vn_num(l.qty_m) || ' m hạn ' || to_char(l.due_date, 'DD/MM')
                                when 'QTY' then p.code || ': ' || core.vn_num(l.old_qty_m) || ' → ' || core.vn_num(l.qty_m) || ' m'
                                when 'DUE' then p.code || ': hạn ' || coalesce(to_char(l.old_due_date, 'DD/MM'), '—') || ' → ' || coalesce(to_char(l.due_date, 'DD/MM'), 'giữ')
                                  || case when l.priority = 0 then ' (gấp)' else '' end
                                else 'Bỏ ' || p.code || ' ' || core.vn_num(l.old_qty_m) || ' m' end, '; ' order by l.line_no)
    into v_sum
    from plan.plan_adjustment_lines l join master.products p on p.id = l.product_id where l.adj_id = p_adj;
  return wf.submit('PLAN_ADJ', p_adj, a.adj_no, pp.plan_no || ' · ' || a.reason || ' · ' || coalesce(v_sum, ''));
end $$;

-- Hủy phiếu nháp
create or replace function app.adj_cancel(p_adj uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare a plan.plan_adjustments;
begin
  select * into a from plan.plan_adjustments where id = p_adj for update;
  if not found then raise exception 'Không tìm thấy phiếu điều chỉnh'; end if;
  if a.status <> 'DRAFT' then raise exception 'Chỉ hủy được phiếu nháp (đang chờ duyệt thì nhờ Chủ tịch trả lại)'; end if;
  if a.created_by is distinct from auth.uid() and not core.is_admin() then raise exception 'Chỉ người lập hủy phiếu'; end if;
  update plan.plan_adjustments set status = 'CANCELLED' where id = p_adj;
end $$;

-- Chủ tịch duyệt xong: áp vào kế hoạch tháng (trigger khi trạng thái sang APPROVED)
create or replace function plan.apply_adjustment() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare l record; v_line uuid; p master.products; pp plan.production_plans;
begin
  if new.status <> 'APPROVED' or old.status = 'APPROVED' then return new; end if;
  perform plan.check_adjustment(new.id);
  select * into pp from plan.production_plans where id = new.plan_id;
  for l in select * from plan.plan_adjustment_lines where adj_id = new.id order by line_no loop
    if l.kind = 'ADD' then
      select * into p from master.products where id = l.product_id;
      insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, run_lots, m_per_pack, pack_type, brand, wo_note, due_date, priority, adjustment_id)
      values (new.plan_id, p.id, p.current_spec_id, l.qty_m, 1, coalesce(p.default_m_per_pack, 500), coalesce(p.default_pack, 'Bobin gỗ'),
              coalesce(p.default_brand, 'KAVIX'), 'Phiếu điều chỉnh ' || new.adj_no || coalesce(' · ' || l.note, ''), l.due_date, coalesce(l.priority, 1), new.id)
      returning id into v_line;
      update plan.plan_adjustment_lines set new_line_id = v_line where id = l.id;
    elsif l.kind = 'QTY' then
      update plan.plan_lines set qty_m = l.qty_m, lot_approved_at = null, lot_approved_by = null, lot_version_id = null where id = l.plan_line_id;
      update mfg.work_orders set qty_m = l.qty_m where plan_line_id = l.plan_line_id and status in ('DRAFT', 'RELEASED', 'IN_PROGRESS') and l.qty_m > 0;
    elsif l.kind = 'DUE' then
      update plan.plan_lines set due_date = coalesce(l.due_date, due_date), priority = coalesce(l.priority, priority),
             lot_approved_at = null, lot_approved_by = null, lot_version_id = null where id = l.plan_line_id;
    else
      update plan.plan_lines set qty_m = 0, lot_approved_at = null, lot_approved_by = null, lot_version_id = null where id = l.plan_line_id;
      update mfg.work_orders set status = 'CANCELLED' where plan_line_id = l.plan_line_id and status = 'DRAFT';
    end if;
  end loop;
  new.applied_at := now();
  update plan.production_plans set mrp_stale = true where id = new.plan_id;
  perform app.kh_log('Điều chỉnh kế hoạch tháng', new.adj_no, null, pp.plan_no, new.reason);
  perform wf.notify_users(inv.role_users(array['SX_TP', 'SX_KH', 'BGD', 'MUA_TP', 'KT_TP']), 'Kế hoạch tháng đã điều chỉnh: ' || new.adj_no,
    pp.plan_no || ' · ' || new.reason || '. TP SX chạy lại dự trù (thiếu vật tư thì đề xuất mua bổ sung) và xếp lại lịch máy.', '/ke-hoach/' || new.plan_id);
  return new;
end $$;
drop trigger if exists trg_apply_adjustment on plan.plan_adjustments;
create trigger trg_apply_adjustment before update of status on plan.plan_adjustments for each row execute function plan.apply_adjustment();

-- Ảnh hưởng vật tư của phiếu (xem trước khi duyệt): nhu cầu thêm theo BOM so với tồn dự kiến của lần dự trù gần nhất
create or replace function app.adj_impact(p_adj uuid)
returns table (material_code text, material_name text, uom text, extra_need numeric, projected_before numeric, projected_after numeric)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare a plan.plan_adjustments; v_run uuid;
begin
  if not core.has_perm('plan', 'view') then raise exception 'Không có quyền xem kế hoạch'; end if;
  select * into a from plan.plan_adjustments where id = p_adj;
  select r.id into v_run from plan.mrp_runs r where r.plan_id = a.plan_id order by r.run_at desc limit 1;
  return query
  with d as (   -- số mét tăng thêm từng mã (thêm mới, tăng sản lượng; giảm/bỏ là số âm)
    select l.product_id, case l.kind when 'ADD' then l.qty_m when 'QTY' then l.qty_m - l.old_qty_m when 'REMOVE' then -l.old_qty_m else 0 end as dm
    from plan.plan_adjustment_lines l where l.adj_id = p_adj
  ), n as (
    select bl.material_id, sum(bl.qty_per_basis * d.dm / 1000 / (1 - bl.loss_rate)) as q
    from d join master.products p on p.id = d.product_id join master.bom_headers h on h.spec_id = p.current_spec_id
    join master.bom_lines bl on bl.bom_id = h.id and bl.basis = 'KM'
    where d.dm <> 0 group by bl.material_id
  )
  select m.code, m.name, m.uom, round(n.q, 3), round(ml.projected + ml.suggest_qty, 3),
         round(coalesce(ml.projected + ml.suggest_qty, coalesce(av.available, 0)) - n.q, 3)
  from n join master.materials m on m.id = n.material_id
  left join plan.mrp_lines ml on ml.run_id = v_run and ml.material_id = n.material_id
  left join inv.v_material_availability av on av.material_id = n.material_id
  where round(n.q, 3) <> 0
  order by round(coalesce(ml.projected + ml.suggest_qty, coalesce(av.available, 0)) - n.q, 3), m.code;
end $$;

revoke execute on function app.adj_create(uuid, text), app.adj_save(uuid, text, jsonb), app.adj_submit(uuid), app.adj_cancel(uuid),
  app.adj_impact(uuid) from public, anon;
grant execute on function app.adj_create(uuid, text), app.adj_save(uuid, text, jsonb), app.adj_submit(uuid), app.adj_cancel(uuid),
  app.adj_impact(uuid) to authenticated;

create or replace view app.v_plan_adjustments with (security_invoker = true) as
select a.id, a.adj_no, a.plan_id, pp.plan_no, a.status, a.reason, a.applied_at, a.created_at, a.created_by, app.user_name(a.created_by) as created_by_name,
       (select count(*) from plan.plan_adjustment_lines l where l.adj_id = a.id) as line_count,
       (select r.id from wf.approval_requests r where r.doc_type = 'PLAN_ADJ' and r.doc_id = a.id order by r.submitted_at desc limit 1) as approval_id
from plan.plan_adjustments a join plan.production_plans pp on pp.id = a.plan_id;
create or replace view app.v_plan_adjustment_lines with (security_invoker = true) as
select l.*, p.code as product_code, p.description as product_name
from plan.plan_adjustment_lines l left join master.products p on p.id = l.product_id;
grant select on app.v_plan_adjustments, app.v_plan_adjustment_lines to authenticated;

-- Kế hoạch đã duyệt: Giám đốc đặt hạn giao lần đầu, đánh dấu gấp; đổi hạn giao đã có phải qua phiếu điều chỉnh (Chủ tịch duyệt)
create or replace function app.kh_set_line(p_line uuid, p_due date, p_priority smallint) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare l plan.plan_lines; v_st text;
begin
  if not core.has_role('BGD') then raise exception 'Chỉ Giám đốc đặt hạn giao, đánh dấu đơn gấp trong kế hoạch tháng'; end if;
  if p_priority not in (0, 1) then raise exception 'Ưu tiên không hợp lệ'; end if;
  select * into l from plan.plan_lines where id = p_line for update;
  if not found then raise exception 'Không tìm thấy dòng kế hoạch'; end if;
  select status into v_st from plan.production_plans where id = l.plan_id;
  if v_st = 'APPROVED' and l.due_date is not null and p_due is distinct from l.due_date then
    raise exception 'Kế hoạch đã duyệt: đổi hạn giao phải lập phiếu điều chỉnh để Chủ tịch HĐQT duyệt (đánh dấu gấp thì vẫn sửa được)';
  end if;
  update plan.plan_lines set due_date = p_due, priority = p_priority where id = p_line;
end $$;

-- Kiểm tra phiếu điều chỉnh khi gửi duyệt (viết lại wf.check_doc của 2600)
create or replace function wf.check_doc(p_doc_type text, p_doc_id uuid) returns void
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare d inv.stock_docs; rq inv.requisitions; v_status text; v_need text;
begin
  if p_doc_type = 'EXTRA_ISSUE' then
    select * into rq from inv.requisitions where id = p_doc_id;
    if not found then raise exception 'Không tìm thấy phiếu lĩnh bổ sung'; end if;
    if rq.kind <> 'EXTRA' then raise exception 'Phiếu lĩnh % là phiếu theo định mức, không cần duyệt', rq.req_no; end if;
    if rq.status <> 'DRAFT' then raise exception 'Phiếu lĩnh % đang ở trạng thái %', rq.req_no, rq.status; end if;
  elsif p_doc_type in ('STOCK_ADJ', 'SCRAP_OUT', 'STOCK_OPEN') then
    select * into d from inv.stock_docs where id = p_doc_id;
    if not found then raise exception 'Không tìm thấy phiếu kho'; end if;
    v_need := case p_doc_type when 'STOCK_ADJ' then 'ADJ' when 'SCRAP_OUT' then 'SCRAP_OUT' else 'OPENING' end;
    if d.doc_type <> v_need then raise exception 'Phiếu % (loại %) không thuộc quy trình này', d.doc_no, d.doc_type; end if;
    if d.status <> 'DRAFT' then raise exception 'Phiếu % đang ở trạng thái %', d.doc_no, d.status; end if;
  elsif p_doc_type = 'PLAN_ADJ' then
    perform plan.check_adjustment(p_doc_id);
  elsif p_doc_type = 'DELIVERY' then
    select status into v_status from sales.deliveries where id = p_doc_id;
    if not found then raise exception 'Không tìm thấy lệnh giao'; end if;
    if v_status <> 'DRAFT' then raise exception 'Lệnh giao đang ở trạng thái %', v_status; end if;
  end if;
end $$;

-- Duyệt: đường dẫn phiếu điều chỉnh (viết lại app.v_approvals của 2600)
create or replace view app.v_approvals with (security_invoker = true) as
with base as (
  select r.*, f.name as doc_type_name, cs as cur_step,
         (cs ->> 'label') as current_level, (cs ->> 'role') as current_role, ro.name as current_role_name,
         coalesce((cs ->> 'sla_hours')::int, 24) as sla_hours,
         jsonb_array_length(r.flow_snapshot -> 'steps') as step_total,
         (select count(*) from jsonb_array_elements(r.flow_snapshot -> 'steps') s where (s ->> 'seq')::int <= r.current_seq) as step_index
  from wf.approval_requests r
  join wf.approval_flows f on f.doc_type = r.doc_type
  left join lateral (select wf.snap_step(r, r.current_seq) as cs) c on true
  left join core.roles ro on ro.code = c.cs ->> 'role'
)
select b.id, b.doc_type, b.doc_type_name, b.doc_id, b.doc_no, b.summary, b.status, b.current_seq,
       b.current_level, b.current_role, b.current_role_name,
       case when b.status = 'PENDING' then app.people(array_remove(wf.step_actor_ids(b.cur_step), b.submitted_by)) else '[]'::jsonb end as current_approvers,
       b.submitted_by, app.user_name(b.submitted_by) as submitted_by_name, b.submitted_at, b.finished_at,
       b.step_started_at, b.step_started_at + make_interval(hours => b.sla_hours) as step_due_at,
       (b.status = 'PENDING' and now() > b.step_started_at + make_interval(hours => b.sla_hours)) as overdue,
       b.step_index, b.step_total,
       (b.status = 'PENDING' and b.submitted_by <> auth.uid() and (wf.can_act_step(b.cur_step, b.step_started_at)).ok) as my_turn,
       (b.submitted_by = auth.uid()) as i_submitted,
       exists (select 1 from wf.approval_actions a where a.request_id = b.id and a.actor_id = auth.uid()) as i_acted,
       case b.doc_type
         when 'SPEC_NEW' then '/san-pham/' || (select p.code from master.product_specs s join master.products p on p.id = s.product_id where s.id = b.doc_id) || '?v=' || b.doc_id
         when 'SPEC_MINOR' then '/san-pham/' || (select p.code from master.product_specs s join master.products p on p.id = s.product_id where s.id = b.doc_id) || '?v=' || b.doc_id
         when 'PLAN' then '/ke-hoach/' || b.doc_id
         when 'PLAN_ADJ' then '/ke-hoach/dieu-chinh/' || b.doc_id
         when 'PR' then '/de-xuat/' || b.doc_id
         when 'EXTRA_ISSUE' then '/kho/cap-phat/' || b.doc_id
         when 'STOCK_ADJ' then '/kho/phieu/' || b.doc_id
         when 'SCRAP_OUT' then '/kho/phieu/' || b.doc_id
         when 'STOCK_OPEN' then '/kho/phieu/' || b.doc_id
         when 'DELIVERY' then '/kho/xuat-ban/' || b.doc_id
       end as doc_link,
       (select jsonb_agg(x order by (x->>'seq')::int) from (
          select jsonb_build_object('seq', 0, 'label', coalesce(b.flow_snapshot #>> '{submit,label}', 'Lập phiếu'), 'role_name', null,
                                    'state', 'done', 'actor', app.user_name(b.submitted_by), 'at', b.submitted_at) as x
          union all
          select jsonb_build_object(
                   'seq', (s ->> 'seq')::int, 'label', s ->> 'label', 'role', s ->> 'role', 'role_name', ro.name,
                   'sla_hours', (s ->> 'sla_hours')::int,
                   'state', case
                              when b.status = 'REJECTED' and (s ->> 'seq')::int = b.current_seq then 'rejected'
                              when b.status = 'APPROVED' or (s ->> 'seq')::int < b.current_seq then 'done'
                              when b.status = 'PENDING' and (s ->> 'seq')::int = b.current_seq then 'current'
                              else 'todo' end,
                   'actor', (select app.user_name(a.actor_id) from wf.approval_actions a
                              where a.request_id = b.id and a.seq = (s ->> 'seq')::int and a.action in ('APPROVE','REJECT') order by a.acted_at desc limit 1),
                   'at', (select a.acted_at from wf.approval_actions a
                           where a.request_id = b.id and a.seq = (s ->> 'seq')::int and a.action in ('APPROVE','REJECT') order by a.acted_at desc limit 1),
                   'approvers', case when b.status = 'PENDING' and (s ->> 'seq')::int >= b.current_seq
                                     then app.people(array_remove(wf.step_actor_ids(s), b.submitted_by)) end)
          from jsonb_array_elements(b.flow_snapshot -> 'steps') s left join core.roles ro on ro.code = s ->> 'role') q) as steps,
       (select jsonb_agg(jsonb_build_object('seq', a.seq, 'action', a.action, 'comment', a.comment, 'at', a.acted_at,
                                            'actor', app.user_name(a.actor_id),
                                            'label', (select s ->> 'label' from jsonb_array_elements(b.flow_snapshot -> 'steps') s where (s ->> 'seq')::int = a.seq))
                         order by a.acted_at)
          from wf.approval_actions a where a.request_id = b.id) as history,
       (b.flow_snapshot #>> '{facts,amount}')::numeric as doc_amount
from base b;

-- ===========================================================================
-- 2b. Đơn phát sinh (chen lô ngoài kế hoạch): thêm bước Chủ tịch HĐQT (viết lại hàm của 2500)
-- ===========================================================================
create or replace function app.kh_create_change(p_plan uuid, p_payload jsonb, p_result jsonb, p_level text, p_steps jsonb) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid; v_no text; v_steps jsonb; v_min text; v_chair jsonb;
begin
  if not app.kh_has_any(array['SX_TP','SX_KH']) then raise exception 'Chỉ Quản lý SX lập đề nghị đơn phát sinh'; end if;
  if p_level not in ('A','B','C') then raise exception 'Mức không hợp lệ'; end if;
  if not exists (select 1 from plan.production_plans where id = p_plan) then raise exception 'Không tìm thấy kế hoạch'; end if;
  v_min := case
    when coalesce(p_payload ->> 'priority', '1') = '0' and coalesce((p_payload ->> 'br')::boolean, false) then 'C'
    when jsonb_array_length(coalesce(p_result -> 'newly', '[]')) > 0
      or not coalesce((p_result ->> 'placed')::boolean, false)
      or coalesce((p_result ->> 'slack')::numeric, 0) < 0 then 'B'
    else 'A' end;
  if p_level < v_min then raise exception 'Kết quả mô phỏng cần tối thiểu mức %', v_min; end if;
  v_steps := jsonb_build_array(jsonb_build_object('role', 'SX_TP', 'label', 'Quản lý SX lập đề nghị, chạy mô phỏng',
                                                  'done_by', auth.uid(), 'done_name', app.user_name(auth.uid()), 'done_at', now()));
  if p_level = 'B' then
    v_steps := v_steps || jsonb_build_array(jsonb_build_object('role', 'BGD', 'label', 'Giám đốc duyệt, chốt ngày giao với kinh doanh'));
  elsif p_level = 'C' then
    v_steps := v_steps || jsonb_build_array(
      jsonb_build_object('role', 'KT_TP', 'label', 'TP Kỹ thuật/QA cho ý kiến: đổi mã, mẫu đầu mã, thông số'),
      jsonb_build_object('role', 'BGD', 'label', 'Giám đốc duyệt chen vào vùng khóa'));
  end if;
  -- Quy trình final: lô ngoài kế hoạch tháng phải được Chủ tịch HĐQT duyệt; Giám đốc chỉ duyệt phần chen lịch (đặt sau Chủ tịch)
  v_chair := jsonb_build_object('role', 'BGD', 'label', 'Chủ tịch HĐQT duyệt lô ngoài kế hoạch tháng', 'user_ids', to_jsonb(plan.chair_ids()));
  if jsonb_array_length(v_steps) > 1 and v_steps -> -1 ->> 'role' = 'BGD' then
    v_steps := (v_steps - (jsonb_array_length(v_steps) - 1)) || jsonb_build_array(v_chair, v_steps -> -1);
  else
    v_steps := v_steps || jsonb_build_array(v_chair);
  end if;
  select core.next_no('DPS', 3) into v_no;
  insert into plan.change_requests (plan_id, req_no, payload, result, level, steps, status)
  values (p_plan, v_no, p_payload, p_result, p_level, v_steps, case when jsonb_array_length(v_steps) = 1 then 'READY' else 'PENDING' end)
  returning id into v_id;
  if jsonb_array_length(v_steps) > 1 then
    perform plan.notify_step(v_steps->1, 'Đơn phát sinh ' || v_no || ' chờ bạn', v_steps->1->>'label', '/lich-may?tab=phatsinh');
  end if;
  return v_id;
end $$;

create or replace function app.kh_change_step(p_req uuid, p_action text, p_comment text default null) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare c plan.change_requests; i integer; n integer; st jsonb; v_role text;
begin
  select * into c from plan.change_requests where id = p_req for update;
  if not found then raise exception 'Không tìm thấy đề nghị'; end if;
  if c.status <> 'PENDING' then raise exception 'Đề nghị không còn chờ duyệt'; end if;
  n := jsonb_array_length(c.steps);
  select min(ord - 1) into i from jsonb_array_elements(c.steps) with ordinality a(e, ord) where e->>'done_at' is null;
  if i is null then raise exception 'Đề nghị đã đủ bước'; end if;
  st := c.steps->i; v_role := st->>'role';
  if not core.has_role(v_role) then raise exception 'Bước này chờ %', st->>'label'; end if;
  -- Bước giao đích danh (Chủ tịch HĐQT): chỉ người được giao hoặc Quản trị hệ thống
  if jsonb_array_length(coalesce(st->'user_ids', '[]')) > 0 and not core.is_admin() and not ((st->'user_ids') ? auth.uid()::text) then
    raise exception 'Bước này chờ %', st->>'label';
  end if;
  if (c.created_by = auth.uid() or exists (select 1 from jsonb_array_elements(c.steps) e where e->>'done_by' = auth.uid()::text)) then
    raise exception 'Bạn đã lập hoặc đã làm bước trước của đề nghị này: không tự duyệt được';
  end if;
  if p_action = 'return' then
    if coalesce(trim(p_comment), '') = '' then raise exception 'Nhập lý do trả lại'; end if;
    update plan.change_requests set status = 'RETURNED', note = trim(p_comment), finished_at = now(),
      steps = jsonb_set(steps, array[i::text], st || jsonb_build_object('done_by', auth.uid(), 'done_name', app.user_name(auth.uid()), 'done_at', now(), 'result', 'Trả lại'))
    where id = p_req;
    insert into wf.notifications (user_id, title, body, link) values (c.created_by, 'Đơn phát sinh ' || c.req_no || ' bị trả lại', trim(p_comment), '/lich-may?tab=phatsinh');
    return 'RETURNED';
  end if;
  update plan.change_requests set
    steps = jsonb_set(steps, array[i::text], st || jsonb_build_object('done_by', auth.uid(), 'done_name', app.user_name(auth.uid()), 'done_at', now(), 'result', 'Đồng ý', 'comment', nullif(trim(coalesce(p_comment, '')), ''))),
    status = case when i = n - 1 then 'READY' else 'PENDING' end
  where id = p_req;
  if i < n - 1 then
    perform plan.notify_step(c.steps->(i + 1), 'Đơn phát sinh ' || c.req_no || ' chờ bạn', c.steps->(i + 1)->>'label', '/lich-may?tab=phatsinh');
    return 'PENDING';
  end if;
  return 'READY';
end $$;

-- ===========================================================================
-- 3. Dự trù nhiều tầng TP → BTP → NVL (viết lại plan.run_mrp của 0700)
-- ===========================================================================
-- Mỗi dòng kế hoạch (theo hạn giao): trừ thành phẩm sẵn có (đạt QC, chưa giữ cho đơn, cùng nhãn), rồi BTP theo công đoạn:
-- cáp đã bọc vỏ (CV) → cáp đã xoắn (BL/BS) → lõi đã bọc (LB, quy ra mét cáp ÷ số lõi) → ruột đã bện (CB). Vật tư BOM tính theo
-- số mét còn phải làm ở đúng công đoạn tiêu thụ (CD1 bện; CD0/CD2 bọc cách điện; CD3/CD4 xoắn, băng; CD5 vỏ; còn lại đóng gói).
-- Thiếu ròng = cấp SX + dự phòng − tồn khả dụng − hàng về kịp − đề xuất mua chưa lên PO; tồn dự kiến = tồn + về + đã đề xuất − cấp SX.
create or replace function plan.run_mrp(p_plan uuid, p_reserve jsonb default '{}') returns uuid
language plpgsql security definer set search_path = plan, master, inv, purchase, public set timezone = 'Asia/Ho_Chi_Minh' as $$
declare p plan.production_plans; v_run uuid; v_set uuid; v_bad text; ln record; v_n numeric; v_take numeric;
        q6 numeric; q5 numeric; q34 numeric; q2 numeric; q1 numeric; v_fg numeric; v_cv numeric; v_bl numeric; v_lb numeric; v_cb numeric;
        v_packs numeric; v_pallets numeric;
begin
  if not core.has_perm('plan', 'create') then raise exception 'Không có quyền chạy MRP'; end if;
  select * into p from plan.production_plans where id = p_plan;
  if p.mode = 'OFFICIAL' then
    select string_agg(pr.code, ', ') into v_bad from plan.plan_lines pl
      join master.product_specs s on s.id = pl.spec_id join master.products pr on pr.id = pl.product_id
     where pl.plan_id = p_plan and pl.qty_m > 0 and s.status <> 'RELEASED';
    if v_bad is not null then
      raise exception 'Spec chưa phát hành: %. Chuyển kế hoạch sang chế độ sơ bộ hoặc chờ KT/QA duyệt (BR-SP-01)', v_bad;
    end if;
  end if;
  select param_set_id into v_set from master.product_specs s join plan.plan_lines pl on pl.spec_id = s.id
   where pl.plan_id = p_plan limit 1;

  insert into plan.mrp_runs (plan_id, need_date, total_m, snapshot)
  select p_plan, p.material_need_date, sum(qty_m),
         jsonb_build_object('specs', jsonb_agg(jsonb_build_object('product', product_id, 'spec', spec_id, 'm', qty_m, 'lots', run_lots)),
                            'param_set', v_set, 'reserve', p_reserve, 'levels', true)
  from plan.plan_lines where plan_id = p_plan
  returning id into v_run;

  -- Tồn TP, BTP dùng được (mét): TP đạt QC chưa giữ; BTP đạt QC hoặc đang chờ QC
  create temp table if not exists _pool (product_id uuid, k text, qty numeric) on commit drop;
  delete from _pool;
  insert into _pool
  select l.product_id, 'FG:' || coalesce(l.brand, ''), sum(b.qty - b.reserved_qty)
  from inv.stock_balances b join inv.lots l on l.id = b.lot_id join inv.warehouses w on w.id = b.warehouse_id
  where w.kind = 'FG' and l.item_kind = 'FG' and l.qc_status = 'PASSED'
    and l.product_id in (select product_id from plan.plan_lines where plan_id = p_plan)
  group by l.product_id, l.brand having sum(b.qty - b.reserved_qty) > 0;
  insert into _pool
  select l.product_id, case when l.wip_stage in ('BL', 'BS') then 'BL' else l.wip_stage end, sum(b.qty - b.reserved_qty)
  from inv.stock_balances b join inv.lots l on l.id = b.lot_id
  where l.item_kind = 'WIP' and l.qc_status in ('PASSED', 'PENDING') and l.wip_stage in ('CV', 'BL', 'BS', 'LB', 'CB')
    and l.product_id in (select product_id from plan.plan_lines where plan_id = p_plan)
  group by l.product_id, case when l.wip_stage in ('BL', 'BS') then 'BL' else l.wip_stage end having sum(b.qty - b.reserved_qty) > 0;

  create temp table if not exists _need (material_id uuid, theo numeric, after_loss numeric, startup numeric) on commit drop;
  delete from _need;

  for ln in select pl.*, s.cores, s.param_set_id from plan.plan_lines pl join master.product_specs s on s.id = pl.spec_id
           where pl.plan_id = p_plan and pl.qty_m > 0 order by pl.due_date nulls last, pl.id loop
    v_n := greatest(coalesce(ln.cores, 1), 1);
    -- Thành phẩm
    select coalesce(sum(qty), 0) into v_take from _pool where product_id = ln.product_id and k = 'FG:' || ln.brand;
    v_fg := least(ln.qty_m, v_take); q6 := ln.qty_m - v_fg;
    update _pool set qty = qty - v_fg where product_id = ln.product_id and k = 'FG:' || ln.brand;
    -- Cáp đã bọc vỏ
    select coalesce(sum(qty), 0) into v_take from _pool where product_id = ln.product_id and k = 'CV';
    v_cv := least(q6, v_take); q5 := q6 - v_cv;
    update _pool set qty = qty - v_cv where product_id = ln.product_id and k = 'CV';
    -- Cáp đã xoắn (+ quấn băng)
    select coalesce(sum(qty), 0) into v_take from _pool where product_id = ln.product_id and k = 'BL';
    v_bl := least(q5, v_take); q34 := q5 - v_bl;
    update _pool set qty = qty - v_bl where product_id = ln.product_id and k = 'BL';
    -- Lõi đã bọc cách điện (mét lõi ÷ số lõi = mét cáp)
    select coalesce(sum(qty), 0) into v_take from _pool where product_id = ln.product_id and k = 'LB';
    v_lb := least(q34, v_take / v_n); q2 := q34 - v_lb;
    update _pool set qty = qty - v_lb * v_n where product_id = ln.product_id and k = 'LB';
    -- Ruột đã bện
    select coalesce(sum(qty), 0) into v_take from _pool where product_id = ln.product_id and k = 'CB';
    v_cb := least(q2, v_take / v_n); q1 := q2 - v_cb;
    update _pool set qty = qty - v_cb * v_n where product_id = ln.product_id and k = 'CB';

    insert into plan.mrp_products (run_id, plan_line_id, product_id, qty_m, fg_m, cv_m, bl_m, lb_m, cb_m, q6, q5, q34, q2, q1)
    values (v_run, ln.id, ln.product_id, ln.qty_m, round(v_fg, 2), round(v_cv, 2), round(v_bl, 2), round(v_lb, 2), round(v_cb, 2),
            round(q6, 2), round(q5, 2), round(q34, 2), round(q2, 2), round(q1, 2));

    v_packs := ceil(q6 / ln.m_per_pack);
    v_pallets := ceil(v_packs / nullif(case when ln.pack_type = 'Bobin gỗ' then master.param(ln.param_set_id, 'palletW')
                                            else master.param(ln.param_set_id, 'palletC') end, 0));
    insert into _need
    select bl.material_id,
           bl.qty_per_basis * x.base,
           bl.qty_per_basis * x.base / (1 - bl.loss_rate),
           case when x.q > 0 then bl.startup_per_lot * ln.run_lots else 0 end
    from master.bom_headers h join master.bom_lines bl on bl.bom_id = h.id
    cross join lateral (
      select case coalesce(bl.operation_code, 'CD6') when 'CD1' then q1 when 'CD0' then q2 when 'CD2' then q2
                                                       when 'CD3' then q34 when 'CD4' then q34 when 'CD5' then q5 else q6 end as q
    ) o
    cross join lateral (
      select o.q, case bl.basis when 'KM' then o.q / 1000 when 'PACK' then v_packs when 'PALLET' then coalesce(v_pallets, 0)
                                else case when o.q > 0 then ln.run_lots else 0 end end as base
    ) x
    where h.spec_id = ln.spec_id;
  end loop;

  with need as (
    select material_id, sum(theo) as theo, sum(after_loss) as after_loss, sum(startup) as startup from _need group by material_id
  ), terms as (
    select distinct on (ms.material_id) ms.* from master.material_suppliers ms
    order by ms.material_id, ms.is_preferred desc, ms.unit_price is null, ms.supplier_id nulls last
  ), incoming as (
    select pol.material_id, sum(pol.qty - pol.received_qty) as qty
    from purchase.po_lines pol join purchase.purchase_orders po on po.id = pol.po_id
    where po.status in ('APPROVED','SENT','PARTIAL_RECEIVED')
      and coalesce(pol.expected_date, po.expected_date) <= coalesce(p.material_need_date, 'infinity'::date)
    group by pol.material_id
  ), requested as (   -- đề xuất mua đang chờ duyệt / đã duyệt mà chưa lên PO (tránh đề xuất trùng khi chạy lại sau điều chỉnh)
    select pl.material_id, sum(greatest(pl.qty - pl.ordered_qty, 0)) as qty
    from purchase.pr_lines pl join purchase.purchase_requests pr on pr.id = pl.pr_id
    where pr.status in ('PENDING_APPROVAL', 'APPROVED', 'PARTIAL_PO')
    group by pl.material_id
  ), calc as (
    select n.material_id, n.theo, n.after_loss, n.startup, n.after_loss + n.startup as total,
           coalesce(a.available, 0) as available, coalesce(a.in_quality, 0) as in_quality,
           coalesce(i.qty, 0) as incoming, coalesce(rq.qty, 0) as requested, coalesce((p_reserve ->> m.code)::numeric, 0) as reserve,
           t.moq, t.pack_multiple, t.unit_price, t.lead_time_days
    from need n
    join master.materials m on m.id = n.material_id
    left join inv.v_material_availability a on a.material_id = n.material_id
    left join incoming i on i.material_id = n.material_id
    left join requested rq on rq.material_id = n.material_id
    left join terms t on t.material_id = n.material_id
  ), res as (
    select c.*, greatest(0, c.total + c.reserve - c.available - c.incoming - c.requested) as net from calc c
  ), sug as (
    select r.*, case when r.net = 0 then 0
                     else ceil(greatest(r.net, coalesce(r.moq, 0)) / coalesce(nullif(r.pack_multiple, 0), 1)) * coalesce(nullif(r.pack_multiple, 0), 1) end as suggest
    from res r
  )
  insert into plan.mrp_lines (run_id, material_id, theoretical, after_loss, startup, total_issue, available, in_quality,
                              incoming, requested, projected, reserve, net_short, moq, pack_multiple, suggest_qty, unit_price, amount,
                              lead_time_days, latest_order_date, status)
  select v_run, material_id, round(theo, 4), round(after_loss, 4), round(startup, 4), round(total, 4), available, in_quality,
         incoming, requested, round(available + incoming + requested - total - reserve, 4), reserve, round(net, 4), moq, pack_multiple, suggest, unit_price,
         case when unit_price is not null then round(suggest * unit_price, 2) end,
         lead_time_days,
         case when suggest > 0 and p.material_need_date is not null and coalesce(lead_time_days, 0) > 0
              then p.material_need_date - lead_time_days end,
         case when suggest = 0 then 'Không cần mua'
              when unit_price is null then 'Cập nhật giá'
              when coalesce(lead_time_days, 0) = 0 then 'Thiếu lead time'
              when p.material_need_date - lead_time_days < (now() at time zone 'Asia/Ho_Chi_Minh')::date then 'Trễ'
              else 'Đặt hàng' end
  from sug where round(total, 4) > 0 or suggest > 0;

  update plan.mrp_runs r set
    budget_vnd = (select sum(amount) from plan.mrp_lines where run_id = v_run),
    missing_price_count = (select count(*) from plan.mrp_lines where run_id = v_run and suggest_qty > 0 and unit_price is null)
  where r.id = v_run;
  return v_run;
end $$;

-- Đề xuất mua từ dự trù (TP SX lập, Giám đốc duyệt): kèm nhu cầu, tồn đạt QC, đang về để tính tồn dự kiến
create or replace function plan.create_pr_from_mrp(p_run uuid) returns uuid
language plpgsql security definer set search_path = plan, purchase, public as $$
declare v_pr uuid; p plan.production_plans;
begin
  if not (core.has_perm('plan', 'create') or core.has_perm('purchase', 'create')) then raise exception 'Không có quyền tạo PR'; end if;
  select pp.* into p from plan.mrp_runs r join plan.production_plans pp on pp.id = r.plan_id where r.id = p_run;
  if p.status <> 'APPROVED' or p.mode <> 'OFFICIAL' then
    raise exception 'Chỉ sinh PR từ kế hoạch chính thức đã được phê duyệt';
  end if;
  if p.mrp_stale then raise exception 'Dòng kế hoạch đã thay đổi sau lần chạy MRP: chạy lại MRP'; end if;
  if exists (select 1 from purchase.purchase_requests pr where pr.mrp_run_id = p_run and pr.status <> 'CANCELLED') then
    raise exception 'Đã sinh đề xuất mua từ kết quả MRP này';
  end if;
  if not exists (select 1 from plan.mrp_lines where run_id = p_run and suggest_qty > 0) then
    raise exception 'Dự trù không thiếu vật tư nào: không cần đề xuất mua';
  end if;
  insert into purchase.purchase_requests (pr_no, source, mrp_run_id, need_date, note)
  values (core.next_no('PR'), 'MRP', p_run, p.material_need_date, 'Từ ' || p.plan_no) returning id into v_pr;
  insert into purchase.pr_lines (pr_id, material_id, qty, need_date, mrp_line_id, note, need_qty, available_qty, incoming_qty, mrp_qty)
  select v_pr, material_id, suggest_qty, coalesce(need_date, latest_order_date), id, note,
         total_issue + reserve, available, incoming + requested, coalesce(orig_suggest_qty, suggest_qty)
  from plan.mrp_lines where run_id = p_run and suggest_qty > 0;
  return v_pr;
end $$;

drop view if exists app.v_mrp_lines;
create view app.v_mrp_lines with (security_invoker = true) as
select l.*, m.code as material_code, m.name as material_name, m.uom,
       coalesce(l.need_date, l.latest_order_date) as eff_need_date, app.user_name(l.adjusted_by) as adjusted_by_name,
       l.projected + l.suggest_qty as projected_after
from plan.mrp_lines l join master.materials m on m.id = l.material_id;
grant select on app.v_mrp_lines to authenticated;

create or replace view app.v_mrp_products with (security_invoker = true) as
select x.*, p.code as product_code, p.description as product_name, s.cores
from plan.mrp_products x join master.products p on p.id = x.product_id left join master.product_specs s on s.id = p.current_spec_id;
grant select on app.v_mrp_products to authenticated;

create or replace view app.v_pr_lines with (security_invoker = true) as
select l.id, l.pr_id, m.code as material_code, m.name as material_name, m.uom, l.qty, l.need_date, l.ordered_qty,
       t.unit_price, t.lead_time_days, a.available,
       l.need_qty, l.available_qty, l.incoming_qty, l.mrp_qty,
       case when l.need_qty is not null then l.available_qty + l.incoming_qty + l.qty - l.need_qty end as projected_qty
from purchase.pr_lines l join master.materials m on m.id = l.material_id
left join lateral (select ms.unit_price, ms.lead_time_days from master.material_suppliers ms where ms.material_id = m.id
                   order by ms.is_preferred desc, ms.supplier_id nulls first limit 1) t on true
left join inv.v_material_availability a on a.material_id = m.id;

-- ===========================================================================
-- 4. Lịch theo lô: ngày dự kiến (lịch máy đang dùng), ngày chốt (TP SX), duyệt lịch lô = giữ chỗ trên lịch máy
-- ===========================================================================
-- Ngày xong dự kiến của dòng kế hoạch theo lịch máy đang dùng
create or replace function plan.lot_eta(p_line uuid) returns date
language sql stable security definer set search_path = pg_catalog, public as $$
  select o.finish_date from plan.schedule_orders o join plan.schedule_versions v on v.id = o.version_id and v.is_current
  where o.plan_line_id = p_line order by v.created_at desc limit 1
$$;

-- TP SX chốt ngày hoàn thành của lô. Sớm hơn ngày dự kiến: web đã mô phỏng và hiện các lô bị lùi, bắt buộc ghi chú;
-- muộn hơn hạn giao khách: bắt buộc ghi chú, báo Giám đốc.
create or replace function app.kh_commit_lot(p_line uuid, p_date date, p_note text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare l plan.plan_lines; pp plan.production_plans; v_eta date; v_code text; v_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  if not app.kh_has_any(array['SX_TP', 'SX_KH']) then raise exception 'Chỉ TP SX chốt ngày hoàn thành của lô'; end if;
  select * into l from plan.plan_lines where id = p_line for update;
  if not found then raise exception 'Không tìm thấy dòng kế hoạch'; end if;
  select * into pp from plan.production_plans where id = l.plan_id;
  if pp.status <> 'APPROVED' then raise exception 'Kế hoạch % chưa được Chủ tịch HĐQT duyệt', pp.plan_no; end if;
  if p_date is null then
    update plan.plan_lines set committed_date = null, committed_note = null, committed_by = null, committed_at = null,
           lot_approved_at = null, lot_approved_by = null, lot_version_id = null where id = p_line;
    return;
  end if;
  if p_date < (now() at time zone 'Asia/Ho_Chi_Minh')::date then raise exception 'Ngày chốt đã qua'; end if;
  v_eta := plan.lot_eta(p_line);
  if v_eta is not null and p_date < v_eta and v_note is null then
    raise exception 'Chốt sớm hơn ngày MES dự kiến (%): ghi rõ lô nào chịu lùi hoặc phương án thêm ca', to_char(v_eta, 'DD/MM');
  end if;
  if l.due_date is not null and p_date > l.due_date and v_note is null then
    raise exception 'Chốt sau hạn giao khách (%): ghi lý do, Giám đốc sẽ được báo', to_char(l.due_date, 'DD/MM');
  end if;
  update plan.plan_lines set committed_date = p_date, committed_note = v_note, committed_by = auth.uid(), committed_at = now(),
         lot_approved_at = null, lot_approved_by = null, lot_version_id = null where id = p_line;
  select code into v_code from master.products where id = l.product_id;
  perform app.kh_log('Lịch lô', v_code || ' (' || pp.plan_no || ')', coalesce(to_char(l.committed_date, 'DD/MM/YYYY'), '—'), to_char(p_date, 'DD/MM/YYYY'),
                     coalesce(v_note, 'Chốt ngày hoàn thành'));
  perform wf.notify_users(array_remove(inv.role_users(array['BGD']), auth.uid()), 'TP SX chốt ngày lô ' || v_code,
    'Xong ' || to_char(p_date, 'DD/MM') || coalesce(' (MES dự kiến ' || to_char(v_eta, 'DD/MM') || ')', '') || coalesce(' · hạn giao ' || to_char(l.due_date, 'DD/MM'), '')
      || coalesce('. ' || v_note, ''), '/lich-may?plan=' || l.plan_id || '&tab=thang');
end $$;

-- TP SX duyệt lịch của lô: giữ chỗ các ca máy của lô trong lịch đang dùng (xếp lại lịch không dời lô đã duyệt)
create or replace function app.kh_approve_lot(p_line uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare l plan.plan_lines; v_ver uuid; v_eta date; v_code text;
begin
  if not app.kh_has_any(array['SX_TP', 'SX_KH']) then raise exception 'Chỉ TP SX duyệt lịch lô'; end if;
  select * into l from plan.plan_lines where id = p_line for update;
  if not found then raise exception 'Không tìm thấy dòng kế hoạch'; end if;
  select code into v_code from master.products where id = l.product_id;
  if not p_approve then
    update plan.plan_lines set lot_approved_at = null, lot_approved_by = null, lot_version_id = null where id = p_line;
    perform app.kh_log('Lịch lô', v_code, 'Đã duyệt, giữ chỗ', 'Bỏ giữ chỗ', 'TP SX bỏ giữ chỗ lịch lô');
    return;
  end if;
  if l.committed_date is null then raise exception 'Chốt ngày hoàn thành của lô trước khi duyệt lịch'; end if;
  select o.version_id, o.finish_date into v_ver, v_eta from plan.schedule_orders o join plan.schedule_versions v on v.id = o.version_id and v.is_current
   where o.plan_line_id = p_line order by v.created_at desc limit 1;
  if v_ver is null or not exists (select 1 from plan.schedule_slots s where s.version_id = v_ver and s.plan_line_id = p_line) then
    raise exception 'Lô chưa có trong lịch máy đang dùng: bấm Xếp lại lịch trước';
  end if;
  if v_eta is null or v_eta > l.committed_date then
    raise exception 'Lịch máy hiện xong % sau ngày chốt %: xếp lại lịch hoặc chốt lại ngày', coalesce(to_char(v_eta, 'DD/MM'), '(chưa xếp đủ)'), to_char(l.committed_date, 'DD/MM');
  end if;
  update plan.plan_lines set lot_approved_at = now(), lot_approved_by = auth.uid(), lot_version_id = v_ver where id = p_line;
  perform app.kh_log('Lịch lô', v_code, null, 'Duyệt, giữ chỗ lịch máy', 'Xong ' || to_char(v_eta, 'DD/MM') || ', chốt ' || to_char(l.committed_date, 'DD/MM'));
  perform wf.notify_users(array_remove(inv.role_users(array['BGD']), auth.uid()), 'Đã duyệt lịch lô ' || v_code,
    'Giữ chỗ trên lịch máy, xong ' || to_char(v_eta, 'DD/MM') || ' (chốt ' || to_char(l.committed_date, 'DD/MM') || '). MES phát lệnh SX từng ngày theo lịch này.',
    '/lich-may?plan=' || l.plan_id || '&tab=thang');
end $$;
revoke execute on function plan.lot_eta(uuid) from public, anon;
grant execute on function plan.lot_eta(uuid) to authenticated;
revoke execute on function app.kh_commit_lot(uuid, date, text), app.kh_approve_lot(uuid, boolean) from public, anon;
grant execute on function app.kh_commit_lot(uuid, date, text), app.kh_approve_lot(uuid, boolean) to authenticated;

-- Dòng kế hoạch cho lịch máy: thêm ngày chốt, giữ chỗ, ngày dự kiến
create or replace view app.v_kh_plan_lines with (security_invoker = true) as
select l.id, l.plan_id, l.product_id, l.qty_m, l.due_date, l.priority, l.change_request_id, l.wo_note, l.so_line_id,
       pp.plan_no, pp.status as plan_status, pp.sched_start,
       p.code as product_code, p.description as product_name, p.group_code,
       s.cores, s.pairs, s.insulation, s.sheath, s.shield, s.sheath_color, s.insulation_colors, l.single_color, s.status as spec_status,
       coalesce(ct.nominal_mm2, 0) as size_mm2,
       (select cr.core_colors from master.color_rules cr where cr.group_code = p.group_code and cr.cores = s.cores) as core_colors,
       (select array_agg(r.op_code order by o.seq) from master.routings r join master.operations o on o.code = r.op_code where r.group_code = p.group_code) as route,
       (select so.so_no from sales.so_lines sl join sales.sales_orders so on so.id = sl.so_id where sl.id = l.so_line_id) as so_no,
       row_number() over (partition by l.plan_id order by (l.change_request_id is not null), p.code, l.due_date nulls last, l.id) as line_no,
       s.core_code,
       l.committed_date, l.committed_note, l.committed_at, app.user_name(l.committed_by) as committed_by_name,
       l.lot_approved_at, app.user_name(l.lot_approved_by) as lot_approved_by_name, l.lot_version_id, plan.lot_eta(l.id) as eta_date,
       l.adjustment_id
from plan.plan_lines l
join plan.production_plans pp on pp.id = l.plan_id
join master.products p on p.id = l.product_id
join master.product_specs s on s.id = l.spec_id
left join master.core_types ct on ct.set_id = s.param_set_id and ct.code = s.core_code;
