-- BMT MES · 4200 · Quy trình duyệt kế hoạch sản xuất tháng (anh Bình chốt 28/10/2026)
--  TP SX lập kế hoạch, chạy MRP → Giám đốc duyệt → Chủ tịch HĐQT chốt.
--  Ở bước Chủ tịch, Chủ tịch được sửa sản lượng, thêm mã, bỏ mã rồi chốt; mỗi lần sửa MES chạy lại MRP và ghi lịch sử.
--  Các quy trình khác (phiếu điều chỉnh kế hoạch, đơn phát sinh…) giữ nguyên.

-- ===========================================================================
-- 1. Cấu hình quy trình PLAN: bước 1 Giám đốc duyệt, bước 2 Chủ tịch chốt
-- ===========================================================================
do $$
declare v_chair uuid[] := plan.chair_ids(); v_gd uuid[];
begin
  -- Giám đốc = người giữ vai trò Ban giám đốc, trừ Chủ tịch (người được giao bước cuối)
  select coalesce(array_agg(distinct ur.user_id), '{}') into v_gd
    from core.user_roles ur join core.profiles p on p.id = ur.user_id and p.status = 'ACTIVE'
   where ur.role_code = 'BGD' and ur.user_id <> all(v_chair);
  update wf.approval_steps set level_label = 'Giám đốc duyệt kế hoạch tháng', role_code = 'BGD', enabled = true,
         assignee_ids = v_gd, sla_hours = 24, warn_hours = 0, fallback_role = null
   where doc_type = 'PLAN' and seq = 1;
  update wf.approval_steps set level_label = 'Chủ tịch HĐQT chốt kế hoạch tháng', role_code = 'BGD', enabled = true
   where doc_type = 'PLAN' and seq = 2;
  update wf.approval_flows set submit_label = 'TP SX lập kế hoạch tháng, chạy MRP' where doc_type = 'PLAN';
end $$;

-- ===========================================================================
-- 2. Lịch sử Chủ tịch sửa kế hoạch khi chốt
-- ===========================================================================
create table if not exists plan.plan_chair_edits (
  id          bigint generated always as identity primary key,
  plan_id     uuid not null references plan.production_plans(id) on delete cascade,
  request_id  uuid,
  line_id     uuid,
  product_id  uuid not null references master.products(id),
  action      text not null check (action in ('ADD', 'EDIT', 'REMOVE')),
  old_data    jsonb,
  new_data    jsonb,
  reason      text not null,
  edited_by   uuid not null default auth.uid(),
  edited_at   timestamptz not null default now()
);
create index if not exists plan_chair_edits_plan on plan.plan_chair_edits (plan_id, edited_at);
alter table plan.plan_chair_edits enable row level security;
drop policy if exists p_select on plan.plan_chair_edits;
create policy p_select on plan.plan_chair_edits for select to authenticated using (core.has_perm('plan', 'view'));
grant select on plan.plan_chair_edits to authenticated;

create or replace view app.v_plan_chair_edits with (security_invoker = true) as
select e.id, e.plan_id, e.request_id, e.line_id, e.action, e.old_data, e.new_data, e.reason, e.edited_at,
       p.code as product_code, p.description as product_name, app.user_name(e.edited_by) as edited_by_name
from plan.plan_chair_edits e join master.products p on p.id = e.product_id;
grant select on app.v_plan_chair_edits to authenticated;

-- ===========================================================================
-- 3. MRP chạy lại khi Chủ tịch sửa (Chủ tịch không có quyền plan:create)
-- ===========================================================================
do $$
declare d text; v_old text := $x$if not core.has_perm('plan', 'create') then raise exception 'Không có quyền chạy MRP'; end if;$x$;
begin
  d := pg_get_functiondef('plan.run_mrp(uuid, jsonb)'::regprocedure);
  if position(v_old in d) = 0 then raise exception 'plan.run_mrp: không thấy đoạn kiểm quyền cần sửa'; end if;
  d := replace(d, v_old, $x$if not (core.has_perm('plan', 'create') or coalesce(current_setting('bmt.chair_edit', true), '') = 'on') then raise exception 'Không có quyền chạy MRP'; end if;$x$);
  execute d;
end $$;

-- ===========================================================================
-- 4. Chủ tịch sửa / thêm / bỏ dòng khi kế hoạch đang ở bước chốt
-- ===========================================================================
-- Yêu cầu duyệt đang ở bước cuối (Chủ tịch chốt) và người gọi được xử lý bước đó
create or replace function plan.chair_request(p_plan uuid) returns wf.approval_requests
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare r wf.approval_requests; v_last int; v_step jsonb;
begin
  if (select status from plan.production_plans where id = p_plan) is distinct from 'PENDING_APPROVAL' then
    raise exception 'Kế hoạch không ở trạng thái chờ duyệt';
  end if;
  select * into r from wf.approval_requests where doc_type = 'PLAN' and doc_id = p_plan and status = 'PENDING'
   order by submitted_at desc limit 1;
  if not found then raise exception 'Kế hoạch không có quy trình duyệt đang chạy'; end if;
  select max((s ->> 'seq')::int) into v_last from jsonb_array_elements(r.flow_snapshot -> 'steps') s;
  v_step := wf.snap_step(r, r.current_seq);
  if r.current_seq <> v_last then
    raise exception 'Chỉ sửa kế hoạch ở bước "%" (đang ở bước "%")',
      (select s ->> 'label' from jsonb_array_elements(r.flow_snapshot -> 'steps') s where (s ->> 'seq')::int = v_last), v_step ->> 'label';
  end if;
  if not (wf.can_act_step(v_step, r.step_started_at)).ok then
    raise exception 'Chỉ người chốt kế hoạch (%) được sửa ở bước này',
      coalesce((select string_agg(full_name, ', ') from core.profiles where id = any(wf.step_actor_ids(v_step))), v_step ->> 'role');
  end if;
  if auth.uid() = r.submitted_by then raise exception 'Người lập không sửa kế hoạch ở bước chốt'; end if;
  return r;
end $$;
revoke all on function plan.chair_request(uuid) from public, anon, authenticated;

-- Sau khi sửa: chạy lại MRP (giữ dự phòng của lần chạy trước), cập nhật tóm tắt của yêu cầu duyệt
create or replace function plan.chair_after_edit(p_plan uuid, p_req uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_reserve jsonb; p plan.production_plans; v_n int; v_m numeric;
begin
  select * into p from plan.production_plans where id = p_plan;
  select coalesce(r.snapshot -> 'reserve', '{}') into v_reserve from plan.mrp_runs r where r.plan_id = p_plan order by r.run_at desc limit 1;
  perform set_config('bmt.chair_edit', 'on', true);
  perform plan.run_mrp(p_plan, coalesce(v_reserve, '{}'));
  perform set_config('bmt.chair_edit', 'off', true);
  select count(*), coalesce(sum(qty_m), 0) into v_n, v_m from plan.plan_lines where plan_id = p_plan and qty_m > 0;
  update wf.approval_requests
     set summary = left(format('%s: %s SKU, %s m (Chủ tịch đã chỉnh)', p.period_label, v_n,
                               replace(to_char(v_m, 'FM999G999G999G990'), ',', '.')), 500)
   where id = p_req;
end $$;
revoke all on function plan.chair_after_edit(uuid, uuid) from public, anon, authenticated;

-- Thêm (p_line null) hoặc sửa một dòng: sản lượng, số lô, đóng gói, thương hiệu; bắt buộc lý do
create or replace function app.plan_chair_save_line(p_plan uuid, p_line uuid, p_product uuid, p_qty numeric, p_lots int,
                                                    p_pack_type text, p_m_per_pack numeric, p_brand text, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r wf.approval_requests; l plan.plan_lines; p plan.production_plans; pr master.products; v_id uuid; v_new jsonb;
begin
  r := plan.chair_request(p_plan);
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do chỉnh kế hoạch'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Sản lượng phải lớn hơn 0 (bỏ mã thì bấm Bỏ)'; end if;
  if p_lots is null or p_lots < 1 then raise exception 'Số lô chạy phải ≥ 1'; end if;
  if p_m_per_pack is null or p_m_per_pack <= 0 then raise exception 'Chọn quy cách m/kiện'; end if;
  select * into p from plan.production_plans where id = p_plan;
  v_new := jsonb_build_object('qty_m', p_qty, 'run_lots', p_lots, 'pack_type', p_pack_type, 'm_per_pack', p_m_per_pack, 'brand', p_brand);

  if p_line is null then
    select * into pr from master.products where id = p_product;
    if not found then raise exception 'Không tìm thấy sản phẩm'; end if;
    if pr.current_spec_id is null then raise exception 'Sản phẩm % chưa có spec', pr.code; end if;
    if p.mode = 'OFFICIAL' and (select status from master.product_specs where id = pr.current_spec_id) <> 'RELEASED' then
      raise exception 'Mã % chưa phát hành spec: kế hoạch chính thức chỉ nhận mã đã phát hành', pr.code;
    end if;
    if exists (select 1 from plan.plan_lines where plan_id = p_plan and product_id = p_product) then
      raise exception '% đã có trong kế hoạch: sửa dòng có sẵn', pr.code;
    end if;
    insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, run_lots, m_per_pack, pack_type, brand)
    values (p_plan, p_product, pr.current_spec_id, p_qty, p_lots, p_m_per_pack, p_pack_type, p_brand)
    returning id into v_id;
    insert into plan.plan_chair_edits (plan_id, request_id, line_id, product_id, action, new_data, reason)
    values (p_plan, r.id, v_id, p_product, 'ADD', v_new, trim(p_reason));
  else
    select * into l from plan.plan_lines where id = p_line and plan_id = p_plan for update;
    if not found then raise exception 'Không tìm thấy dòng kế hoạch'; end if;
    if p_product is not null and p_product <> l.product_id then
      raise exception 'Không đổi mã của dòng có sẵn: bỏ dòng rồi thêm mã mới';
    end if;
    if l.qty_m = p_qty and l.run_lots = p_lots and l.pack_type = p_pack_type and l.m_per_pack = p_m_per_pack and l.brand = p_brand then
      raise exception 'Không có thay đổi';
    end if;
    update plan.plan_lines set qty_m = p_qty, run_lots = p_lots, pack_type = p_pack_type, m_per_pack = p_m_per_pack, brand = p_brand
     where id = p_line;
    insert into plan.plan_chair_edits (plan_id, request_id, line_id, product_id, action, old_data, new_data, reason)
    values (p_plan, r.id, p_line, l.product_id, 'EDIT',
            jsonb_build_object('qty_m', l.qty_m, 'run_lots', l.run_lots, 'pack_type', l.pack_type, 'm_per_pack', l.m_per_pack, 'brand', l.brand),
            v_new, trim(p_reason));
    v_id := p_line;
  end if;
  perform plan.chair_after_edit(p_plan, r.id);
  return v_id;
end $$;

create or replace function app.plan_chair_remove_line(p_line uuid, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r wf.approval_requests; l plan.plan_lines;
begin
  select * into l from plan.plan_lines where id = p_line;
  if not found then raise exception 'Không tìm thấy dòng kế hoạch'; end if;
  r := plan.chair_request(l.plan_id);
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do bỏ mã'; end if;
  if not exists (select 1 from plan.plan_lines where plan_id = l.plan_id and id <> p_line and qty_m > 0) then
    raise exception 'Kế hoạch phải còn ít nhất một mã: muốn bỏ cả kế hoạch thì bấm Trả lại';
  end if;
  delete from plan.plan_lines where id = p_line;
  insert into plan.plan_chair_edits (plan_id, request_id, line_id, product_id, action, old_data, reason)
  values (l.plan_id, r.id, p_line, l.product_id, 'REMOVE',
          jsonb_build_object('qty_m', l.qty_m, 'run_lots', l.run_lots, 'pack_type', l.pack_type, 'm_per_pack', l.m_per_pack, 'brand', l.brand),
          trim(p_reason));
  perform plan.chair_after_edit(l.plan_id, r.id);
end $$;

revoke all on function app.plan_chair_save_line(uuid, uuid, uuid, numeric, int, text, numeric, text, text), app.plan_chair_remove_line(uuid, text) from public, anon;
grant execute on function app.plan_chair_save_line(uuid, uuid, uuid, numeric, int, text, numeric, text, text), app.plan_chair_remove_line(uuid, text) to authenticated;

-- ===========================================================================
-- 5. Chốt xong: báo người lập và Giám đốc các dòng Chủ tịch đã chỉnh
-- ===========================================================================
create or replace function plan.notify_chair_edits() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r wf.approval_requests; v_body text; v_users uuid[];
begin
  select * into r from wf.approval_requests where doc_type = 'PLAN' and doc_id = new.id order by submitted_at desc limit 1;
  if not found then return new; end if;
  select string_agg(p.code || ': ' || case e.action
           when 'ADD' then 'thêm ' || replace(to_char((e.new_data ->> 'qty_m')::numeric, 'FM999G999G990'), ',', '.') || ' m'
           when 'REMOVE' then 'bỏ (' || replace(to_char((e.old_data ->> 'qty_m')::numeric, 'FM999G999G990'), ',', '.') || ' m)'
           else replace(to_char((e.old_data ->> 'qty_m')::numeric, 'FM999G999G990'), ',', '.') || ' → '
                || replace(to_char((e.new_data ->> 'qty_m')::numeric, 'FM999G999G990'), ',', '.') || ' m' end, '; ' order by e.id)
    into v_body
    from plan.plan_chair_edits e join master.products p on p.id = e.product_id where e.request_id = r.id;
  if v_body is null then return new; end if;
  select coalesce(array_agg(distinct a.actor_id), '{}') into v_users
    from wf.approval_actions a where a.request_id = r.id and a.action = 'APPROVE' and a.actor_id <> auth.uid();
  perform wf.notify_users(array(select distinct u from unnest(v_users || r.submitted_by) u where u is not null and u <> auth.uid()),
    'Chủ tịch đã chỉnh khi chốt ' || new.plan_no, left(v_body, 1000), '/ke-hoach/' || new.id);
  return new;
end $$;
revoke all on function plan.notify_chair_edits() from public, anon, authenticated;
drop trigger if exists trg_notify_chair_edits on plan.production_plans;
create trigger trg_notify_chair_edits after update of status on plan.production_plans
  for each row when (new.status = 'APPROVED' and old.status is distinct from 'APPROVED') execute function plan.notify_chair_edits();
