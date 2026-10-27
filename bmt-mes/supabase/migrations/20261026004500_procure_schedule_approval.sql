-- BMT MES · 4500 · Chuẩn hóa mua NVL và duyệt lịch sản xuất (anh Bình chốt 28/10/2026)
--  1. Tồn dự phòng (thường 1 tháng sản xuất) theo từng vật tư: TP Mua lập phiếu điều chỉnh mức → Giám đốc duyệt (được sửa khi duyệt);
--     dưới mức thì cảnh báo; dự trù MRP mua bù đủ mức dự phòng; NV/TP Mua lập đề xuất mua bù dự phòng một lần bấm.
--  2. Người duyệt sửa được phiếu (nguyên tắc của 4400) áp thêm cho phiếu dự phòng, đơn phát sinh, ngày chốt lô.
--  3. Chủ tịch HĐQT chỉ duyệt kế hoạch tháng và phiếu điều chỉnh kế hoạch tháng: bước "Giám đốc" theo vai trò không gồm Chủ tịch,
--     bỏ bước Chủ tịch ở PO và đơn phát sinh.
--  4. Lô sản xuất, lô phát sinh: TP SX đệ trình (theo MES khuyến cáo) → Giám đốc duyệt.
--  5. NV mua / TP Mua lập đề xuất mua bổ sung, tích trữ, tối ưu với số lượng bất kỳ; PO bỏ ngưỡng 20 triệu / 200 triệu.
--  6. Giám đốc duyệt cuối: lịch máy (TP SX xếp → chờ Giám đốc duyệt mới thành lịch đang dùng), lịch lô, lệnh SX ngày.
--  7. Đề xuất mua: TP Mua duyệt → Giám đốc duyệt.

-- ===========================================================================
-- 1. Bước "Giám đốc" không gồm Chủ tịch HĐQT
-- ===========================================================================
-- Bước theo vai trò Ban giám đốc (không giao đích danh): bỏ người được giao bước cuối kế hoạch tháng (Chủ tịch),
-- trừ khi không còn ai khác giữ vai trò.
create or replace function wf.step_actor_ids(p_step jsonb) returns uuid[]
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v uuid[]; v_gd uuid[];
begin
  select coalesce(array_agg(distinct ur.user_id), '{}') into v
  from core.user_roles ur join core.profiles p on p.id = ur.user_id and p.status = 'ACTIVE'
  where ur.role_code = p_step ->> 'role'
    and (jsonb_array_length(coalesce(p_step -> 'users', '[]')) = 0
         or (p_step -> 'users') ? ur.user_id::text);
  if p_step ->> 'role' = 'BGD' and jsonb_array_length(coalesce(p_step -> 'users', '[]')) = 0
     and not coalesce((p_step ->> 'all_bgd')::boolean, false) then
    select coalesce(array_agg(u), '{}') into v_gd from unnest(v) u where u <> all(plan.chair_ids());
    if cardinality(v_gd) > 0 then v := v_gd; end if;
  end if;
  return v;
end $$;

-- Lập snapshot quy trình (viết lại của 2200): bước chỉ người lập giữ thì chuyển Ban giám đốc; khi đó được tính cả Chủ tịch
-- (ví dụ Giám đốc tự lập đề xuất mua thì Chủ tịch duyệt thay bước Giám đốc)
create or replace function wf.build_snapshot(p_doc_type text, p_doc_id uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_cfg jsonb; v_facts jsonb; v_steps jsonb; s jsonb; v_out jsonb := '[]'; v_me uuid := auth.uid();
begin
  v_cfg := wf.flow_config(p_doc_type);
  v_facts := wf.doc_facts(p_doc_type, p_doc_id);
  select coalesce(jsonb_agg(x order by (x ->> 'seq')::int), '[]') into v_steps
    from jsonb_array_elements(v_cfg -> 'steps') x where wf.step_applies(x, v_facts);
  for s in select x from jsonb_array_elements(v_steps) x order by (x ->> 'seq')::int loop
    if cardinality(wf.step_actor_ids(s)) = 0 then
      raise exception 'Bước "%" chưa có người thực hiện: gán vai trò % cho người phụ trách (Quản trị → Người dùng & quyền)',
        s ->> 'label', coalesce((select name from core.roles where code = s ->> 'role'), s ->> 'role');
    end if;
    if cardinality(array_remove(wf.step_actor_ids(s), v_me)) = 0 then
      if exists (select 1 from jsonb_array_elements(v_steps) o
                 where (o ->> 'seq') <> (s ->> 'seq') and o ->> 'role' = 'BGD'
                   and cardinality(array_remove(wf.step_actor_ids(o), v_me)) > 0) then
        continue;
      end if;
      s := s || jsonb_build_object('role', 'BGD', 'users', '[]'::jsonb, 'all_bgd', true, 'escalated_from', s ->> 'role',
                                   'label', (s ->> 'label') || ' · chuyển Giám đốc');
      if cardinality(array_remove(wf.step_actor_ids(s), v_me)) = 0 then
        raise exception 'Bước "%" không có người duyệt nào khác người lập', s ->> 'label';
      end if;
    end if;
    v_out := v_out || jsonb_build_array(s);
  end loop;
  return jsonb_set(v_cfg, '{steps}', v_out) || jsonb_build_object('facts', v_facts);
end $$;

-- Giám đốc (người giữ vai trò Ban giám đốc, trừ Chủ tịch)
create or replace function plan.gd_ids() returns uuid[]
language sql stable security definer set search_path = pg_catalog, public as $$
  select wf.step_actor_ids(jsonb_build_object('role', 'BGD'))
$$;
revoke all on function plan.gd_ids() from public, anon, authenticated;

-- Người gọi là Giám đốc: giữ vai trò Ban giám đốc (cả ủy quyền) nhưng không phải Chủ tịch HĐQT (trừ khi không còn Giám đốc nào khác);
-- Quản trị hệ thống làm được mọi khâu
create or replace function plan.is_gd() returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select core.is_admin()
      or (core.has_role('BGD')
          and not (auth.uid() = any(plan.chair_ids()) and exists (select 1 from unnest(plan.gd_ids()) u where u <> auth.uid())))
$$;
revoke all on function plan.is_gd() from public, anon;
grant execute on function plan.is_gd() to authenticated;

-- Báo bước tiếp theo trong module (đơn phát sinh): bước giao đích danh báo đúng người; bước Giám đốc báo Giám đốc (không báo Chủ tịch)
create or replace function plan.notify_step(p_step jsonb, p_title text, p_body text, p_link text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if jsonb_array_length(coalesce(p_step -> 'user_ids', '[]')) > 0 then
    perform wf.notify_users(array(select x::uuid from jsonb_array_elements_text(p_step -> 'user_ids') x), p_title, p_body, p_link);
  elsif p_step ->> 'role' = 'BGD' then
    perform wf.notify_users(array_remove(plan.gd_ids(), auth.uid()), p_title, p_body, p_link);
  else
    perform app.kh_notify_role(p_step ->> 'role', p_title, p_body, p_link);
  end if;
end $$;
revoke execute on function plan.notify_step(jsonb, text, text, text) from public, anon, authenticated;

-- ===========================================================================
-- 2. Đề xuất mua (PR): loại đề xuất; TP Mua duyệt → Giám đốc duyệt
-- ===========================================================================
alter table purchase.purchase_requests add column if not exists pr_kind text not null default 'BO_SUNG';
alter table purchase.purchase_requests drop constraint if exists purchase_requests_pr_kind_check;
alter table purchase.purchase_requests add constraint purchase_requests_pr_kind_check
  check (pr_kind in ('KE_HOACH', 'BO_SUNG', 'TICH_TRU', 'TOI_UU'));
comment on column purchase.purchase_requests.pr_kind is
  'KE_HOACH: theo kế hoạch tháng (MRP); BO_SUNG: mua bổ sung (thiếu, bù dự phòng); TICH_TRU: mua tích trữ; TOI_UU: mua tối ưu (giá, MOQ, rủi ro cung ứng)';
update purchase.purchase_requests set pr_kind = 'KE_HOACH' where source = 'MRP' and pr_kind <> 'KE_HOACH';

-- PR sinh từ MRP luôn là loại "theo kế hoạch"; PR thủ công không được ghi là theo kế hoạch
create or replace function purchase.pr_kind_guard() returns trigger
language plpgsql set search_path = pg_catalog, public as $$
begin
  if new.source = 'MRP' then
    new.pr_kind := 'KE_HOACH';
  elsif new.pr_kind = 'KE_HOACH' then
    raise exception 'Đề xuất lập tay chọn loại Bổ sung, Tích trữ hoặc Tối ưu (loại "Theo kế hoạch" chỉ sinh từ dự trù MRP)';
  end if;
  return new;
end $$;
drop trigger if exists trg_pr_kind on purchase.purchase_requests;
create trigger trg_pr_kind before insert or update of pr_kind, source on purchase.purchase_requests
  for each row execute function purchase.pr_kind_guard();

create or replace function purchase.pr_kind_label(p text) returns text
language sql immutable set search_path = pg_catalog, public as $$
  select case p when 'KE_HOACH' then 'Theo kế hoạch tháng' when 'BO_SUNG' then 'Mua bổ sung'
                when 'TICH_TRU' then 'Mua tích trữ' when 'TOI_UU' then 'Mua tối ưu' else p end
$$;

-- Lập đề xuất mua tay: NV mua / TP Mua (mọi loại), TP SX / Kế hoạch SX (mua bổ sung); số lượng bất kỳ (> 0)
drop function if exists app.create_pr(date, text, jsonb);
create or replace function app.create_pr(p_need_date date, p_note text, p_lines jsonb, p_kind text default 'BO_SUNG') returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_pr uuid; l jsonb; v_mat uuid; v_n int := 0; v_qty numeric;
begin
  if not core.has_perm('purchase', 'create') then raise exception 'Không có quyền lập đề xuất mua'; end if;
  p_kind := coalesce(nullif(p_kind, ''), 'BO_SUNG');
  if p_kind not in ('BO_SUNG', 'TICH_TRU', 'TOI_UU') then raise exception 'Chọn loại đề xuất: Bổ sung, Tích trữ hoặc Tối ưu'; end if;
  if p_kind in ('TICH_TRU', 'TOI_UU') and not (core.has_role('MUA_NV') or core.has_role('MUA_TP')) then
    raise exception 'Đề xuất mua tích trữ / tối ưu do NV mua hoặc TP Mua lập';
  end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'Nhập nội dung / lý do đề xuất'; end if;
  insert into purchase.purchase_requests (pr_no, source, pr_kind, need_date, note)
  values (core.next_no('PR'), 'MANUAL', p_kind, p_need_date, trim(p_note)) returning id into v_pr;
  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    continue when coalesce(l->>'material_code', '') = '';
    select id into v_mat from master.materials where code = upper(trim(l->>'material_code')) and active;
    if v_mat is null then raise exception 'Không có vật tư %', l->>'material_code'; end if;
    v_qty := nullif(l->>'qty', '')::numeric;
    if coalesce(v_qty, 0) <= 0 then raise exception 'Số lượng % phải lớn hơn 0', upper(trim(l->>'material_code')); end if;
    if exists (select 1 from purchase.pr_lines where pr_id = v_pr and material_id = v_mat) then
      raise exception 'Vật tư % nhập hai lần: gộp vào một dòng', upper(trim(l->>'material_code'));
    end if;
    insert into purchase.pr_lines (pr_id, material_id, qty, need_date)
    values (v_pr, v_mat, v_qty, coalesce(nullif(l->>'need_date', '')::date, p_need_date));
    v_n := v_n + 1;
  end loop;
  if v_n = 0 then raise exception 'Nhập ít nhất một vật tư'; end if;
  return v_pr;
end $$;
revoke all on function app.create_pr(date, text, jsonb, text) from public, anon;
grant execute on function app.create_pr(date, text, jsonb, text) to authenticated;

-- Đổi loại đề xuất lập tay (người lập khi nháp, người duyệt khi chờ duyệt)
create or replace function app.set_pr_kind(p_pr uuid, p_kind text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r wf.approval_requests; o purchase.purchase_requests;
begin
  r := purchase.pr_edit_request(p_pr);
  select * into o from purchase.purchase_requests where id = p_pr for update;
  if o.source = 'MRP' then raise exception 'Đề xuất sinh từ dự trù MRP giữ loại "Theo kế hoạch tháng"'; end if;
  if p_kind not in ('BO_SUNG', 'TICH_TRU', 'TOI_UU') then raise exception 'Chọn loại đề xuất: Bổ sung, Tích trữ hoặc Tối ưu'; end if;
  if o.pr_kind = p_kind then return; end if;
  update purchase.purchase_requests set pr_kind = p_kind where id = p_pr;
  if r.id is not null then
    perform wf.log_review_edit(r.id, 'loại đề xuất: ' || purchase.pr_kind_label(o.pr_kind) || ' → ' || purchase.pr_kind_label(p_kind));
  end if;
end $$;
revoke all on function app.set_pr_kind(uuid, text) from public, anon;
grant execute on function app.set_pr_kind(uuid, text) to authenticated;

create or replace view app.v_prs with (security_invoker = true) as
select r.id, r.pr_no, r.source, r.status, r.need_date, r.note, r.created_at, r.created_by,
       app.user_name(r.created_by) as created_by_name,
       (select count(*) from purchase.pr_lines l where l.pr_id = r.id) as line_count,
       (select ar.id from wf.approval_requests ar where ar.doc_type = 'PR' and ar.doc_id = r.id order by ar.submitted_at desc limit 1) as request_id,
       r.pr_kind, purchase.pr_kind_label(r.pr_kind) as pr_kind_label
from purchase.purchase_requests r;

-- Quy trình PR: bước 1 TP Mua duyệt (quá hạn Giám đốc duyệt thay), bước 2 Giám đốc duyệt
update wf.approval_steps set level_label = 'TP Mua duyệt đề xuất mua', role_code = 'MUA_TP', enabled = true,
       fallback_role = 'BGD', min_amount = null, when_flags = '{}'
 where doc_type = 'PR' and seq = 1;
insert into wf.approval_steps (doc_type, seq, level_label, role_code, enabled, sla_hours)
select 'PR', 2, 'Giám đốc duyệt đề xuất mua', 'BGD', true, 24
where not exists (select 1 from wf.approval_steps where doc_type = 'PR' and seq = 2);
update wf.approval_steps set level_label = 'Giám đốc duyệt đề xuất mua', role_code = 'BGD', enabled = true, min_amount = null, when_flags = '{}'
 where doc_type = 'PR' and seq = 2;
update wf.approval_flows set submit_label = 'NV mua / TP Mua / TP SX lập đề xuất mua' where doc_type = 'PR';

-- ===========================================================================
-- 3. PO: bỏ ngưỡng 20 triệu / 200 triệu, bỏ bước Chủ tịch HĐQT (TP Mua → Giám đốc ký với mọi đơn)
-- ===========================================================================
update wf.approval_steps set min_amount = null, when_flags = '{}', level_label = 'TP Mua duyệt đơn mua hàng', enabled = true
 where doc_type = 'PO' and seq = 1;
update wf.approval_steps set enabled = false where doc_type = 'PO' and seq = 3;
update wf.approval_steps set level_label = 'Giám đốc ký đơn mua hàng' where doc_type = 'PO' and seq = 2;

-- ===========================================================================
-- 4. Tồn dự phòng
-- ===========================================================================
alter table master.materials
  add column if not exists safety_days numeric(6,1) check (safety_days is null or (safety_days >= 0 and safety_days <= 366)),
  add column if not exists safety_set_at timestamptz,
  add column if not exists safety_set_by uuid,
  add column if not exists safety_doc_id uuid;
comment on column master.materials.safety_stock is 'Tồn dự phòng (đơn vị vật tư): TP Mua đề xuất, Giám đốc duyệt qua phiếu SAFETY_STOCK; dưới mức thì cảnh báo, MRP mua bù đủ mức';
comment on column master.materials.safety_days is 'Số ngày sản xuất dùng để tính mức dự phòng (thường 30 = 1 tháng); trống = nhập số lượng trực tiếp';

create table if not exists purchase.safety_changes (
  id          uuid primary key default gen_random_uuid(),
  change_no   text unique not null,
  status      text not null default 'DRAFT' check (status in ('DRAFT', 'PENDING_APPROVAL', 'APPROVED', 'CANCELLED')),
  reason      text not null check (length(trim(reason)) > 0),
  applied_at  timestamptz,
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid()
);
create table if not exists purchase.safety_change_lines (
  id          uuid primary key default gen_random_uuid(),
  change_id   uuid not null references purchase.safety_changes(id) on delete cascade,
  line_no     int not null,
  material_id uuid not null references master.materials(id),
  old_qty     numeric(18,4) not null default 0,
  old_days    numeric(6,1),
  per_day     numeric(18,4) not null default 0,    -- tiêu hao bình quân/ngày lúc lập (kế hoạch tháng hoặc thực xuất 90 ngày)
  new_days    numeric(6,1) check (new_days is null or (new_days >= 0 and new_days <= 366)),
  new_qty     numeric(18,4) not null check (new_qty >= 0),
  note        text,
  unique (change_id, material_id)
);
create index if not exists safety_change_lines_change on purchase.safety_change_lines (change_id);

do $$
declare t text;
begin
  foreach t in array array['purchase.safety_changes', 'purchase.safety_change_lines'] loop
    execute format('alter table %s enable row level security', t);
    execute format('revoke all on %s from anon, authenticated', t);
    execute format('grant select on %s to authenticated', t);
    execute format('grant all on %s to service_role', t);
    execute format('drop policy if exists p_select on %s', t);
    execute format('create policy p_select on %s for select to authenticated using (core.has_perm(''purchase'', ''view'') or core.has_perm(''inventory'', ''view'') or core.has_role(''BGD''))', t);
  end loop;
end $$;
drop trigger if exists trg_guard_status on purchase.safety_changes;
create trigger trg_guard_status before insert or update of status on purchase.safety_changes for each row
  execute function core.guard_status('status', 'DRAFT', 'DRAFT>PENDING_APPROVAL', 'PENDING_APPROVAL>APPROVED', 'PENDING_APPROVAL>DRAFT', 'DRAFT>CANCELLED');

-- Quy trình: TP Mua lập → Giám đốc duyệt
insert into wf.approval_flows (doc_type, name, doc_table, status_col, approved_status, rejected_status, pending_status, submit_label, submit_role, active)
values ('SAFETY_STOCK', 'Điều chỉnh mức tồn dự phòng', 'purchase.safety_changes', 'status', 'APPROVED', 'DRAFT', 'PENDING_APPROVAL',
        'TP Mua lập phiếu điều chỉnh mức dự phòng', 'MUA_TP', true)
on conflict (doc_type) do nothing;
insert into wf.approval_steps (doc_type, seq, level_label, role_code, enabled, sla_hours)
select 'SAFETY_STOCK', 1, 'Giám đốc duyệt mức tồn dự phòng', 'BGD', true, 24
where not exists (select 1 from wf.approval_steps where doc_type = 'SAFETY_STOCK');

-- Tiêu hao bình quân/ngày của vật tư: theo kế hoạch tháng đã duyệt gần nhất (cấp SX trong dự trù ÷ 30),
-- chưa có thì theo thực xuất cho sản xuất 90 ngày (xuất − trả) ÷ 90
create or replace function purchase.use_rates()
returns table (material_id uuid, plan_month numeric, plan_no text, issued_90d numeric, per_day numeric)
language sql stable security definer set search_path = pg_catalog, public as $$
  with lp as (
    select r.id as run_id, pp.plan_no from plan.production_plans pp
    join lateral (select id from plan.mrp_runs where plan_id = pp.id order by run_at desc limit 1) r on true
    where pp.status = 'APPROVED' and pp.mode = 'OFFICIAL' order by pp.created_at desc limit 1
  ), pm as (
    select ml.material_id, sum(ml.total_issue) as q from plan.mrp_lines ml where ml.run_id = (select run_id from lp) group by ml.material_id
  ), iss as (
    select l.material_id,
           sum(case when d.doc_type = 'ISSUE_WO' and mv.qty < 0 then -mv.qty when d.doc_type = 'RETURN_WO' and mv.qty > 0 then -mv.qty else 0 end) as q
    from inv.stock_moves mv join inv.stock_docs d on d.id = mv.doc_id join inv.lots l on l.id = mv.lot_id
    where d.doc_type in ('ISSUE_WO', 'RETURN_WO') and mv.moved_at > now() - interval '90 days' and l.material_id is not null
    group by l.material_id
  )
  select m.id, coalesce(pm.q, 0), (select plan_no from lp), greatest(coalesce(iss.q, 0), 0),
         round(case when coalesce(pm.q, 0) > 0 then pm.q / 30 else greatest(coalesce(iss.q, 0), 0) / 90 end, 4)
  from master.materials m left join pm on pm.material_id = m.id left join iss on iss.material_id = m.id
$$;
revoke all on function purchase.use_rates() from public, anon, authenticated;

-- Bảng dự phòng cho web: mức, tồn, hàng đang về, đã đề xuất, tiêu hao, gợi ý MES, còn phải mua
create or replace function app.safety_stock_list()
returns table (material_id uuid, code text, name text, group_code text, uom text, safety_stock numeric, safety_days numeric,
               safety_set_at timestamptz, safety_set_by_name text, available numeric, in_quality numeric, on_hand numeric,
               incoming numeric, requested numeric, plan_month numeric, plan_no text, issued_90d numeric, per_day numeric,
               suggest_qty numeric, below boolean, to_buy numeric, pending_no text, pending_id uuid)
language sql stable security definer set search_path = pg_catalog, public as $$
  with inc as (
    select pol.material_id, sum(greatest(pol.qty - pol.received_qty, 0)) as q
    from purchase.po_lines pol join purchase.purchase_orders po on po.id = pol.po_id
    where po.status in ('APPROVED', 'SENT', 'PARTIAL_RECEIVED') group by pol.material_id
  ), req as (
    select pl.material_id, sum(greatest(pl.qty - pl.ordered_qty, 0)) as q
    from purchase.pr_lines pl join purchase.purchase_requests pr on pr.id = pl.pr_id
    where pr.status in ('DRAFT', 'PENDING_APPROVAL', 'APPROVED', 'PARTIAL_PO') group by pl.material_id   -- gồm cả nháp: không đề xuất trùng
  ), pend as (
    select distinct on (cl.material_id) cl.material_id, c.change_no, c.id
    from purchase.safety_change_lines cl join purchase.safety_changes c on c.id = cl.change_id
    where c.status in ('DRAFT', 'PENDING_APPROVAL') order by cl.material_id, c.created_at desc
  )
  select m.id, m.code, m.name, m.group_code, m.uom, m.safety_stock, m.safety_days, m.safety_set_at, app.user_name(m.safety_set_by),
         coalesce(a.available, 0), coalesce(a.in_quality, 0), coalesce(a.available, 0) + coalesce(a.in_quality, 0),
         coalesce(inc.q, 0), coalesce(req.q, 0), u.plan_month, u.plan_no, u.issued_90d, u.per_day,
         round(u.per_day * coalesce(m.safety_days, 30), 2),
         m.safety_stock > 0 and coalesce(a.available, 0) + coalesce(a.in_quality, 0) < m.safety_stock,
         greatest(0, m.safety_stock - coalesce(a.available, 0) - coalesce(a.in_quality, 0) - coalesce(inc.q, 0) - coalesce(req.q, 0)),
         pend.change_no, pend.id
  from master.materials m
  join purchase.use_rates() u on u.material_id = m.id
  left join inv.v_material_availability a on a.material_id = m.id
  left join inc on inc.material_id = m.id
  left join req on req.material_id = m.id
  left join pend on pend.material_id = m.id
  where m.active and not m.is_scrap
    and (core.has_perm('purchase', 'view') or core.has_perm('inventory', 'view') or core.has_role('BGD'))
  order by (m.safety_stock > 0 and coalesce(a.available, 0) + coalesce(a.in_quality, 0) < m.safety_stock) desc, m.group_code, m.code
$$;
revoke all on function app.safety_stock_list() from public, anon;
grant execute on function app.safety_stock_list() to authenticated;

-- Số vật tư đang dưới mức dự phòng (menu)
create or replace function app.safety_below_count() returns integer
language sql stable security definer set search_path = pg_catalog, public as $$
  select count(*)::int from master.materials m left join inv.v_material_availability a on a.material_id = m.id
  where m.active and not m.is_scrap and m.safety_stock > 0 and coalesce(a.available, 0) + coalesce(a.in_quality, 0) < m.safety_stock
    and (core.has_perm('purchase', 'view') or core.has_perm('inventory', 'view') or core.has_role('BGD'))
$$;
revoke all on function app.safety_below_count() from public, anon;
grant execute on function app.safety_below_count() to authenticated;

-- Ghi các dòng phiếu (thay toàn bộ). p_lines: [{material_code, days, qty, note}]; qty trống thì MES tính = tiêu hao/ngày × số ngày
create or replace function purchase.safety_write_lines(p_id uuid, p_lines jsonb) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare e jsonb; i int := 0; m master.materials; v_days numeric; v_qty numeric; v_rate numeric;
begin
  delete from purchase.safety_change_lines where change_id = p_id;
  for e in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    continue when coalesce(trim(e ->> 'material_code'), '') = '';
    select * into m from master.materials where code = upper(trim(e ->> 'material_code')) and active and not is_scrap;
    if m.id is null then raise exception 'Không có vật tư %', e ->> 'material_code'; end if;
    if exists (select 1 from purchase.safety_change_lines where change_id = p_id and material_id = m.id) then
      raise exception 'Vật tư % nhập hai lần', m.code;
    end if;
    v_days := nullif(trim(coalesce(e ->> 'days', '')), '')::numeric;
    v_qty := nullif(trim(coalesce(e ->> 'qty', '')), '')::numeric;
    if v_days is not null and (v_days < 0 or v_days > 366) then raise exception '%: số ngày dự phòng từ 0 đến 366', m.code; end if;
    select u.per_day into v_rate from purchase.use_rates() u where u.material_id = m.id;
    if v_qty is null then
      if v_days is null then raise exception '%: nhập số ngày sản xuất hoặc số lượng dự phòng', m.code; end if;
      if coalesce(v_rate, 0) = 0 then raise exception '%: chưa có số tiêu hao (kế hoạch tháng / thực xuất): nhập số lượng dự phòng', m.code; end if;
      v_qty := round(v_rate * v_days, 2);
    end if;
    if v_qty < 0 then raise exception '%: mức dự phòng phải ≥ 0', m.code; end if;
    i := i + 1;
    insert into purchase.safety_change_lines (change_id, line_no, material_id, old_qty, old_days, per_day, new_days, new_qty, note)
    values (p_id, i, m.id, m.safety_stock, m.safety_days, coalesce(v_rate, 0), v_days, v_qty, nullif(trim(coalesce(e ->> 'note', '')), ''));
  end loop;
  if i = 0 then raise exception 'Phiếu chưa có vật tư nào'; end if;
  return i;
end $$;
revoke all on function purchase.safety_write_lines(uuid, jsonb) from public, anon, authenticated;

create or replace function purchase.safety_summary(p_id uuid) returns text
language sql stable security definer set search_path = pg_catalog, public as $$
  select string_agg(m.code || ': ' || wf.fmt_qty(l.old_qty) || ' → ' || wf.fmt_qty(l.new_qty) || ' ' || m.uom
                    || coalesce(' (' || wf.fmt_qty(l.new_days) || ' ngày)', ''), '; ' order by l.line_no)
  from purchase.safety_change_lines l join master.materials m on m.id = l.material_id where l.change_id = p_id
$$;
revoke all on function purchase.safety_summary(uuid) from public, anon, authenticated;

-- TP Mua lập phiếu (nháp)
create or replace function app.safety_create(p_reason text, p_lines jsonb) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid;
begin
  if not core.has_role('MUA_TP') then raise exception 'TP Mua hàng lập phiếu điều chỉnh mức tồn dự phòng (Giám đốc duyệt)'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do điều chỉnh (tình hình sản xuất, thời gian giao hàng của NCC…)'; end if;
  insert into purchase.safety_changes (change_no, reason) values (core.next_no('DP', 3), trim(p_reason)) returning id into v_id;
  perform purchase.safety_write_lines(v_id, p_lines);
  return v_id;
end $$;

-- Sửa phiếu: người lập (TP Mua) khi nháp; Giám đốc (người đang duyệt) khi chờ duyệt – ghi lịch sử duyệt, báo người lập
create or replace function app.safety_save(p_id uuid, p_reason text, p_lines jsonb) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare c purchase.safety_changes; r wf.approval_requests; v_before text; v_after text;
begin
  select * into c from purchase.safety_changes where id = p_id for update;
  if not found then raise exception 'Không tìm thấy phiếu điều chỉnh dự phòng'; end if;
  if c.status = 'PENDING_APPROVAL' then
    r := wf.review_request('SAFETY_STOCK', p_id);
  elsif c.status <> 'DRAFT' then
    raise exception 'Phiếu % đã %: không sửa được', c.change_no, case c.status when 'APPROVED' then 'duyệt' else 'hủy' end;
  elsif not (c.created_by = auth.uid() or core.has_role('MUA_TP')) then
    raise exception 'Chỉ TP Mua sửa phiếu nháp';
  end if;
  v_before := purchase.safety_summary(p_id);
  if coalesce(trim(p_reason), '') <> '' and trim(p_reason) is distinct from c.reason then
    update purchase.safety_changes set reason = trim(p_reason) where id = p_id;
  end if;
  perform purchase.safety_write_lines(p_id, p_lines);
  v_after := purchase.safety_summary(p_id);
  if r.id is not null then
    if v_before is not distinct from v_after and coalesce(nullif(trim(p_reason), ''), c.reason) = c.reason then raise exception 'Không có thay đổi'; end if;
    update wf.approval_requests set summary = left(coalesce(nullif(trim(p_reason), ''), c.reason) || ' · ' || v_after, 500) where id = r.id;
    perform wf.log_review_edit(r.id, left('mức dự phòng: ' || coalesce(v_after, ''), 1500));
  end if;
end $$;

create or replace function app.safety_submit(p_id uuid) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare c purchase.safety_changes;
begin
  select * into c from purchase.safety_changes where id = p_id;
  if not found then raise exception 'Không tìm thấy phiếu điều chỉnh dự phòng'; end if;
  return wf.submit('SAFETY_STOCK', p_id, c.change_no, c.reason || ' · ' || coalesce(purchase.safety_summary(p_id), ''));
end $$;

create or replace function app.safety_cancel(p_id uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare c purchase.safety_changes;
begin
  select * into c from purchase.safety_changes where id = p_id for update;
  if not found then raise exception 'Không tìm thấy phiếu điều chỉnh dự phòng'; end if;
  if c.status <> 'DRAFT' then raise exception 'Chỉ hủy được phiếu nháp (đang chờ duyệt thì nhờ Giám đốc trả lại)'; end if;
  if c.created_by is distinct from auth.uid() and not core.is_admin() then raise exception 'Chỉ người lập hủy phiếu'; end if;
  update purchase.safety_changes set status = 'CANCELLED' where id = p_id;
end $$;
revoke all on function app.safety_create(text, jsonb), app.safety_save(uuid, text, jsonb), app.safety_submit(uuid), app.safety_cancel(uuid) from public, anon;
grant execute on function app.safety_create(text, jsonb), app.safety_save(uuid, text, jsonb), app.safety_submit(uuid), app.safety_cancel(uuid) to authenticated;

-- Giám đốc duyệt xong: áp mức mới vào danh mục vật tư
create or replace function purchase.apply_safety_change() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_sum text;
begin
  if new.status <> 'APPROVED' or old.status = 'APPROVED' then return new; end if;
  update master.materials m set safety_stock = l.new_qty, safety_days = l.new_days, safety_set_at = now(),
         safety_set_by = auth.uid(), safety_doc_id = new.id
    from purchase.safety_change_lines l where l.change_id = new.id and m.id = l.material_id;
  new.applied_at := now();
  v_sum := purchase.safety_summary(new.id);
  perform wf.notify_users(array_remove(inv.role_users(array['MUA_TP', 'MUA_NV', 'KT_KHO', 'SX_TP']), auth.uid()),
    'Mức tồn dự phòng mới: ' || new.change_no, left(coalesce(v_sum, ''), 1000), '/de-xuat/du-phong');
  return new;
end $$;
drop trigger if exists trg_apply_safety on purchase.safety_changes;
create trigger trg_apply_safety before update of status on purchase.safety_changes for each row execute function purchase.apply_safety_change();

create or replace view app.v_safety_changes with (security_invoker = true) as
select c.id, c.change_no, c.status, c.reason, c.applied_at, c.created_at, c.created_by, app.user_name(c.created_by) as created_by_name,
       (select count(*) from purchase.safety_change_lines l where l.change_id = c.id) as line_count,
       (select r.id from wf.approval_requests r where r.doc_type = 'SAFETY_STOCK' and r.doc_id = c.id order by r.submitted_at desc limit 1) as approval_id
from purchase.safety_changes c;
create or replace view app.v_safety_change_lines with (security_invoker = true) as
select l.*, m.code as material_code, m.name as material_name, m.uom
from purchase.safety_change_lines l join master.materials m on m.id = l.material_id;
grant select on app.v_safety_changes, app.v_safety_change_lines to authenticated;

-- Cảnh báo dưới mức dự phòng: báo TP Mua, NV mua, Kế toán SX, Giám đốc khi vừa xuống dưới mức, nhắc lại mỗi tuần nếu vẫn thiếu;
-- tồn lên lại đủ mức thì xóa dấu để lần xuống sau báo ngay
create or replace function purchase.safety_alerts() returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r record; v_n int := 0; v_week text := to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'IYYY-IW');
begin
  delete from inv.alert_log al
   where al.kind = 'SAFETY'
     and al.ref_id in (select m.id from master.materials m left join inv.v_material_availability a on a.material_id = m.id
                        where m.safety_stock <= 0 or coalesce(a.available, 0) + coalesce(a.in_quality, 0) >= m.safety_stock);
  for r in select m.id, m.code, m.name, m.uom, m.safety_stock, coalesce(a.available, 0) as available, coalesce(a.in_quality, 0) as in_quality
           from master.materials m left join inv.v_material_availability a on a.material_id = m.id
           where m.active and not m.is_scrap and m.safety_stock > 0
             and coalesce(a.available, 0) + coalesce(a.in_quality, 0) < m.safety_stock loop
    insert into inv.alert_log (kind, ref_id, period_key) values ('SAFETY', r.id, v_week) on conflict do nothing;
    continue when not found;
    perform wf.notify_users(array(select distinct u from unnest(inv.role_users(array['MUA_TP', 'MUA_NV', 'KT_KHO']) || plan.gd_ids()) u),
      'Dưới mức dự phòng: ' || r.code,
      format('%s: còn %s %s (đạt QC %s, chờ QC %s), mức dự phòng %s. NV mua lập đề xuất mua bổ sung.', r.name,
             wf.fmt_qty(r.available + r.in_quality), r.uom, wf.fmt_qty(r.available), wf.fmt_qty(r.in_quality), wf.fmt_qty(r.safety_stock)),
      '/de-xuat/du-phong');
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke execute on function purchase.safety_alerts() from public, anon, authenticated;
grant execute on function purchase.safety_alerts() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('bmt_safety_stock', '17 * * * *', 'select purchase.safety_alerts()');   -- mỗi giờ
  end if;
exception when others then
  raise notice 'Chưa đặt được lịch bmt_safety_stock: %', sqlerrm;
end $$;

-- NV mua / TP Mua: lập đề xuất mua bổ sung cho mọi vật tư còn thiếu so với mức dự phòng (trừ tồn, hàng đang về, đã đề xuất)
create or replace function app.pr_from_safety(p_note text default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_pr uuid; r record; v_n int := 0; v_q numeric; v_today date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
begin
  if not (core.has_role('MUA_NV') or core.has_role('MUA_TP')) then raise exception 'NV mua hoặc TP Mua lập đề xuất mua bù dự phòng'; end if;
  for r in select s.*, t.moq, t.pack_multiple, t.lead_time_days from app.safety_stock_list() s
           left join lateral (select ms.moq, ms.pack_multiple, ms.lead_time_days from master.material_suppliers ms
                               where ms.material_id = s.material_id order by ms.is_preferred desc, ms.supplier_id nulls first limit 1) t on true
           where s.to_buy > 0 order by s.code loop
    if v_pr is null then
      insert into purchase.purchase_requests (pr_no, source, pr_kind, need_date, note)
      values (core.next_no('PR'), 'MANUAL', 'BO_SUNG', v_today + 7,
              coalesce(nullif(trim(p_note), ''), 'Mua bù tồn dự phòng (MES đề nghị theo mức Giám đốc đã duyệt)'))
      returning id into v_pr;
    end if;
    v_q := ceil(greatest(r.to_buy, coalesce(r.moq, 0)) / coalesce(nullif(r.pack_multiple, 0), 1)) * coalesce(nullif(r.pack_multiple, 0), 1);
    insert into purchase.pr_lines (pr_id, material_id, qty, need_date, note, need_qty, available_qty, incoming_qty, mrp_qty)
    values (v_pr, r.material_id, v_q, v_today + greatest(coalesce(r.lead_time_days, 0), 1), 'Bù dự phòng ' || wf.fmt_qty(r.safety_stock) || ' ' || r.uom,
            0, r.on_hand, r.incoming + r.requested, r.to_buy);
    v_n := v_n + 1;
  end loop;
  if v_n = 0 then raise exception 'Không vật tư nào thiếu so với mức dự phòng (đã tính hàng đang về và đề xuất đang chờ)'; end if;
  return v_pr;
end $$;
revoke all on function app.pr_from_safety(text) from public, anon;
grant execute on function app.pr_from_safety(text) to authenticated;

-- Dòng đề xuất mua: thêm mức dự phòng của vật tư
create or replace view app.v_pr_lines with (security_invoker = true) as
select l.id, l.pr_id, m.code as material_code, m.name as material_name, m.uom, l.qty, l.need_date, l.ordered_qty,
       t.unit_price, t.lead_time_days, a.available,
       l.need_qty, l.available_qty, l.incoming_qty, l.mrp_qty,
       case when l.need_qty is not null then l.available_qty + l.incoming_qty + l.qty - l.need_qty end as projected_qty,
       m.safety_stock as safety_qty
from purchase.pr_lines l join master.materials m on m.id = l.material_id
left join lateral (select ms.unit_price, ms.lead_time_days from master.material_suppliers ms where ms.material_id = m.id
                   order by ms.is_preferred desc, ms.supplier_id nulls first limit 1) t on true
left join inv.v_material_availability a on a.material_id = m.id;

-- Dự trù MRP: dự phòng mặc định = mức tồn dự phòng đã duyệt (mua bù đủ mức); tồn dự kiến sau SX không trừ dự phòng
-- (so trực tiếp với mức dự phòng); đề xuất sinh từ MRP ghi nhu cầu = cấp SX (dự phòng hiện ở cột riêng)
do $$
declare d text;
begin
  d := replace(pg_get_functiondef('plan.run_mrp(uuid, jsonb)'::regprocedure), E'\r', '');
  if position('m.safety_stock' in d) = 0 then
    if position('coalesce((p_reserve ->> m.code)::numeric, 0) as reserve' in d) = 0 then raise exception 'plan.run_mrp: không thấy đoạn dự phòng'; end if;
    d := replace(d, 'coalesce((p_reserve ->> m.code)::numeric, 0) as reserve', 'coalesce((p_reserve ->> m.code)::numeric, m.safety_stock, 0) as reserve');
    if position('round(available + incoming + requested - total - reserve, 4)' in d) = 0 then raise exception 'plan.run_mrp: không thấy công thức tồn dự kiến'; end if;
    d := replace(d, 'round(available + incoming + requested - total - reserve, 4)', 'round(available + incoming + requested - total, 4)');
    execute d;
  end if;
  d := replace(pg_get_functiondef('plan.create_pr_from_mrp(uuid)'::regprocedure), E'\r', '');
  if position('total_issue + reserve, available' in d) > 0 then
    execute replace(d, 'total_issue + reserve, available', 'total_issue, available');
  end if;
end $$;

-- Kiểm chứng từ khi gửi duyệt (viết lại của 3600, thêm SAFETY_STOCK)
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
  elsif p_doc_type = 'SAFETY_STOCK' then
    if not exists (select 1 from purchase.safety_change_lines where change_id = p_doc_id) then
      raise exception 'Phiếu điều chỉnh dự phòng chưa có vật tư nào';
    end if;
  elsif p_doc_type = 'DELIVERY' then
    select status into v_status from sales.deliveries where id = p_doc_id;
    if not found then raise exception 'Không tìm thấy lệnh giao'; end if;
    if v_status <> 'DRAFT' then raise exception 'Lệnh giao đang ở trạng thái %', v_status; end if;
  end if;
end $$;

-- Quyền lập: thêm SAFETY_STOCK (TP Mua)
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
    when 'SAFETY_STOCK' then core.has_role('MUA_TP')
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

-- Duyệt: đường dẫn phiếu dự phòng (viết lại app.v_approvals của 3600)
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
         when 'SAFETY_STOCK' then '/de-xuat/du-phong/' || b.doc_id
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
-- 5. Đơn phát sinh (lô ngoài kế hoạch): Chủ tịch không duyệt; Giám đốc duyệt mọi mức; người duyệt sửa được
-- ===========================================================================
create or replace function app.kh_create_change(p_plan uuid, p_payload jsonb, p_result jsonb, p_level text, p_steps jsonb) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid; v_no text; v_steps jsonb; v_min text;
begin
  if not app.kh_has_any(array['SX_TP','SX_KH']) then raise exception 'Chỉ Quản lý SX lập đề nghị đơn phát sinh'; end if;
  if p_level not in ('A','B','C') then raise exception 'Mức không hợp lệ'; end if;
  if not exists (select 1 from plan.production_plans where id = p_plan) then raise exception 'Không tìm thấy kế hoạch'; end if;
  v_min := plan.change_min_level(p_payload, p_result);
  if p_level < v_min then raise exception 'Kết quả mô phỏng cần tối thiểu mức %', v_min; end if;
  v_steps := jsonb_build_array(jsonb_build_object('role', 'SX_TP', 'label', 'TP SX lập đề nghị, chạy mô phỏng',
                                                  'done_by', auth.uid(), 'done_name', app.user_name(auth.uid()), 'done_at', now()));
  if p_level = 'C' then
    v_steps := v_steps || jsonb_build_array(jsonb_build_object('role', 'KT_TP', 'label', 'TP Kỹ thuật/QA cho ý kiến: đổi mã, mẫu đầu mã, thông số'));
  end if;
  v_steps := v_steps || jsonb_build_array(jsonb_build_object('role', 'BGD', 'label', case p_level
    when 'A' then 'Giám đốc duyệt lô phát sinh'
    when 'B' then 'Giám đốc duyệt, chốt ngày giao với kinh doanh'
    else 'Giám đốc duyệt chen vào vùng khóa' end));
  select core.next_no('DPS', 3) into v_no;
  insert into plan.change_requests (plan_id, req_no, payload, result, level, steps, status)
  values (p_plan, v_no, p_payload, p_result, p_level, v_steps, 'PENDING')
  returning id into v_id;
  perform plan.notify_step(v_steps->1, 'Đơn phát sinh ' || v_no || ' chờ bạn', v_steps->1->>'label', '/lich-may?tab=phatsinh');
  return v_id;
end $$;

-- Duyệt / trả lại một bước (viết lại của 3600): Chủ tịch không duyệt bước Giám đốc
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
  -- Bước Giám đốc: Chủ tịch HĐQT không duyệt lô phát sinh (quy trình 28/10/2026)
  if v_role = 'BGD' and jsonb_array_length(coalesce(st->'user_ids', '[]')) = 0 and not plan.is_gd() then
    raise exception 'Bước "%" do Giám đốc duyệt (Chủ tịch HĐQT không duyệt lô phát sinh)', st->>'label';
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

-- Mức tối thiểu theo kết quả mô phỏng (dùng chung cho lập và sửa khi duyệt)
create or replace function plan.change_min_level(p_payload jsonb, p_result jsonb) returns text
language sql immutable set search_path = pg_catalog, public as $$
  select case
    when coalesce(p_payload ->> 'priority', '1') = '0' and coalesce((p_payload ->> 'br')::boolean, false) then 'C'
    when jsonb_array_length(coalesce(p_result -> 'newly', '[]')) > 0
      or not coalesce((p_result ->> 'placed')::boolean, false)
      or coalesce((p_result ->> 'slack')::numeric, 0) < 0 then 'B'
    else 'A' end
$$;

-- Người đang duyệt sửa số mét / hạn giao / ghi chú của đơn phát sinh (web chạy lại mô phỏng và gửi kết quả mới)
create or replace function app.kh_change_edit(p_req uuid, p_payload jsonb, p_result jsonb, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare c plan.change_requests; i integer; st jsonb; v_min text; v_old jsonb; v_new jsonb; v_note text;
begin
  select * into c from plan.change_requests where id = p_req for update;
  if not found then raise exception 'Không tìm thấy đề nghị'; end if;
  if c.status <> 'PENDING' then raise exception 'Đề nghị không còn chờ duyệt: không sửa được'; end if;
  select min(ord - 1) into i from jsonb_array_elements(c.steps) with ordinality a(e, ord) where e->>'done_at' is null;
  st := c.steps -> i;
  if not core.has_role(st->>'role') then raise exception 'Chỉ người đang duyệt bước "%" sửa được đề nghị', st->>'label'; end if;
  if jsonb_array_length(coalesce(st->'user_ids', '[]')) > 0 and not core.is_admin() and not ((st->'user_ids') ? auth.uid()::text) then
    raise exception 'Chỉ người đang duyệt bước "%" sửa được đề nghị', st->>'label';
  end if;
  if st->>'role' = 'BGD' and not plan.is_gd() then raise exception 'Bước "%" do Giám đốc duyệt (Chủ tịch HĐQT không duyệt lô phát sinh)', st->>'label'; end if;
  if c.created_by = auth.uid() then raise exception 'Người lập không sửa đề nghị đang chờ duyệt: người duyệt sửa, hoặc trả lại để sửa'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do sửa'; end if;
  if coalesce((p_payload ->> 'qty_m')::numeric, 0) <= 0 then raise exception 'Số mét phải lớn hơn 0'; end if;
  if nullif(p_payload ->> 'due_date', '') is null then raise exception 'Nhập hạn giao'; end if;
  if (p_payload ->> 'product_code') is distinct from (c.payload ->> 'product_code') then
    raise exception 'Không đổi mã sản phẩm khi duyệt: trả lại để TP SX lập đề nghị mới';
  end if;
  v_min := plan.change_min_level(p_payload, p_result);
  if c.level < v_min then
    raise exception 'Sau khi sửa, kết quả mô phỏng cần mức % (đang mức %): trả lại để TP SX lập lại với đủ bước duyệt', v_min, c.level;
  end if;
  v_old := jsonb_build_object('qty_m', c.payload -> 'qty_m', 'due_date', c.payload -> 'due_date', 'priority', c.payload -> 'priority');
  v_new := jsonb_build_object('qty_m', p_payload -> 'qty_m', 'due_date', p_payload -> 'due_date', 'priority', p_payload -> 'priority');
  if v_old = v_new and (c.payload ->> 'so') is not distinct from (p_payload ->> 'so') then raise exception 'Không có thay đổi'; end if;
  v_note := format('%s sửa khi duyệt: %s m hạn %s → %s m hạn %s. Lý do: %s', app.user_name(auth.uid()),
                   wf.fmt_qty((c.payload ->> 'qty_m')::numeric), c.payload ->> 'due_date',
                   wf.fmt_qty((p_payload ->> 'qty_m')::numeric), p_payload ->> 'due_date', trim(p_reason));
  update plan.change_requests set payload = c.payload || p_payload, result = p_result,
         steps = jsonb_set(steps, array[i::text], st || jsonb_build_object('edits',
                   coalesce(st -> 'edits', '[]') || jsonb_build_array(jsonb_build_object('by', auth.uid(), 'name', app.user_name(auth.uid()),
                     'at', now(), 'old', v_old, 'new', v_new, 'reason', trim(p_reason)))))
   where id = p_req;
  insert into wf.notifications (user_id, title, body, link)
  values (c.created_by, 'Đơn phát sinh ' || c.req_no || ' đã được sửa khi duyệt', v_note, '/lich-may?tab=phatsinh');
end $$;
revoke all on function app.kh_change_edit(uuid, jsonb, jsonb, text) from public, anon;
grant execute on function app.kh_change_edit(uuid, jsonb, jsonb, text) to authenticated;
revoke all on function plan.change_min_level(jsonb, jsonb) from public, anon;

-- ===========================================================================
-- 6. Lịch máy: TP SX xếp → chờ Giám đốc duyệt → lịch đang dùng
-- ===========================================================================
alter table plan.schedule_versions
  add column if not exists status text not null default 'APPROVED',
  add column if not exists approved_by uuid,
  add column if not exists approved_at timestamptz,
  add column if not exists review_note text;
alter table plan.schedule_versions drop constraint if exists schedule_versions_status_check;
alter table plan.schedule_versions add constraint schedule_versions_status_check
  check (status in ('PROPOSED', 'APPROVED', 'RETURNED', 'SUPERSEDED'));
alter table plan.schedule_versions drop constraint if exists schedule_versions_current_approved;
alter table plan.schedule_versions add constraint schedule_versions_current_approved check (not is_current or status = 'APPROVED');

-- Lưu lịch: Giám đốc xếp (hoặc lịch theo đơn phát sinh đã được Giám đốc duyệt) → dùng ngay;
-- TP SX / Kế hoạch SX xếp → bản đề xuất, chờ Giám đốc duyệt (lịch đang dùng giữ nguyên đến khi duyệt)
create or replace function app.kh_save_schedule(p_plan uuid, p_base date, p_params jsonb, p_orders jsonb, p_slots jsonb,
                                               p_reason text, p_change uuid default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid; v_ver integer; v_base date; c plan.change_requests; v_direct boolean; pp plan.production_plans;
begin
  if not app.kh_has_any(array['SX_TP','SX_KH','BGD']) then raise exception 'Chỉ TP SX (Kế hoạch SX) hoặc Giám đốc được xếp lịch máy'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Thiếu lý do xếp lịch'; end if;
  select * into pp from plan.production_plans where id = p_plan for update;
  if not found then raise exception 'Không tìm thấy kế hoạch'; end if;
  select base_date into v_base from plan.schedule_versions where plan_id = p_plan and is_current;
  if v_base is not null and v_base <> p_base then raise exception 'Ngày gốc của lịch không khớp phiên bản đang dùng'; end if;
  if p_change is not null then
    select * into c from plan.change_requests where id = p_change for update;
    if c.status <> 'LINE_ADDED' then raise exception 'Đơn phát sinh chưa đủ bước duyệt'; end if;
  end if;
  v_direct := p_change is not null or plan.is_gd();
  select coalesce(max(version), 0) + 1 into v_ver from plan.schedule_versions where plan_id = p_plan;
  -- bản đề xuất cũ chưa duyệt: thay bằng bản mới
  update plan.schedule_versions set status = 'SUPERSEDED' where plan_id = p_plan and status = 'PROPOSED';
  if v_direct then
    update plan.schedule_versions set is_current = false where plan_id = p_plan and is_current;
  end if;
  insert into plan.schedule_versions (plan_id, version, base_date, params, reason, change_request_id, is_current, status, approved_by, approved_at)
  values (p_plan, v_ver, p_base, p_params, trim(p_reason), p_change, v_direct, case when v_direct then 'APPROVED' else 'PROPOSED' end,
          case when v_direct then auth.uid() end, case when v_direct then now() end)
  returning id into v_id;
  insert into plan.schedule_orders (version_id, plan_line_id, label, product_code, product_name, group_code, qty_m, due_date, priority, source, finish_date, meta)
  select v_id, (e->>'plan_line_id')::uuid, e->>'label', e->>'product_code', e->>'product_name', e->>'group_code', (e->>'qty_m')::numeric,
         nullif(e->>'due_date', '')::date, coalesce((e->>'priority')::smallint, 1), e->>'source', nullif(e->>'finish_date', '')::date,
         coalesce(e->'meta', '{}')
  from jsonb_array_elements(p_orders) e;
  insert into plan.schedule_slots (version_id, plan_line_id, op_code, color, machine_code, operator_code, lane, start_min, run_start_min,
                                   end_min, setup_min, meters, rate, speed, reason, setup_why, part)
  select v_id, (e->>'plan_line_id')::uuid, e->>'op_code', nullif(e->>'color', ''), e->>'machine_code', e->>'operator_code',
         coalesce((e->>'lane')::smallint, 0), (e->>'start_min')::numeric, (e->>'run_start_min')::numeric, (e->>'end_min')::numeric,
         coalesce((e->>'setup_min')::numeric, 0), (e->>'meters')::numeric, (e->>'rate')::numeric, (e->>'speed')::numeric,
         e->>'reason', e->>'setup_why', coalesce((e->>'part')::boolean, false)
  from jsonb_array_elements(p_slots) e;
  if p_change is not null then
    update plan.change_requests set status = 'APPLIED', finished_at = now() where id = p_change;
  end if;
  if not v_direct then
    perform wf.notify_users(array_remove(plan.gd_ids(), auth.uid()), 'Lịch máy chờ duyệt: ' || pp.plan_no || ' bản ' || v_ver,
      app.user_name(auth.uid()) || ' xếp lịch: ' || left(trim(p_reason), 300) || '. Giám đốc duyệt thì lịch mới thay lịch đang dùng.',
      '/lich-may?plan=' || p_plan || '&xem=de-xuat');
  end if;
  return v_id;
end $$;

-- Giám đốc duyệt / trả lại bản lịch đề xuất
create or replace function app.kh_schedule_review(p_version uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v plan.schedule_versions; cur plan.schedule_versions; pp plan.production_plans; v_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  if not plan.is_gd() then raise exception 'Chỉ Giám đốc duyệt lịch máy'; end if;
  select * into v from plan.schedule_versions where id = p_version for update;
  if not found then raise exception 'Không tìm thấy bản lịch'; end if;
  if v.status <> 'PROPOSED' then raise exception 'Bản lịch % không chờ duyệt (%)', v.version, v.status; end if;
  if v.created_by = auth.uid() then raise exception 'Người xếp lịch không tự duyệt'; end if;
  select * into pp from plan.production_plans where id = v.plan_id for update;
  if not p_approve then
    if v_note is null then raise exception 'Nhập lý do trả lại để TP SX xếp lại'; end if;
    update plan.schedule_versions set status = 'RETURNED', review_note = v_note, approved_by = auth.uid(), approved_at = now() where id = p_version;
    perform wf.notify_users(array_remove(array[v.created_by], null), 'Lịch máy bị trả lại: ' || pp.plan_no || ' bản ' || v.version, v_note,
      '/lich-may?plan=' || v.plan_id);
    return;
  end if;
  select * into cur from plan.schedule_versions where plan_id = v.plan_id and is_current;
  if cur.id is not null and cur.created_at > v.created_at then
    raise exception 'Lịch đang dùng đã thay đổi sau khi TP SX xếp bản này: trả lại để xếp lại';
  end if;
  if cur.id is not null and cur.base_date <> v.base_date then raise exception 'Ngày gốc của bản lịch không khớp lịch đang dùng'; end if;
  update plan.schedule_versions set is_current = false where plan_id = v.plan_id and is_current;
  update plan.schedule_versions set is_current = true, status = 'APPROVED', approved_by = auth.uid(), approved_at = now(), review_note = v_note
   where id = p_version;
  perform app.kh_log('Lịch máy', pp.plan_no, coalesce('bản ' || cur.version, '—'), 'bản ' || v.version, coalesce(v_note, 'Giám đốc duyệt lịch máy'));
  perform wf.notify_users(array(select distinct u from unnest(array_remove(array[v.created_by], null) || inv.role_users(array['SX_TP', 'SX_KH'])) u
                                 where u <> auth.uid()),
    'Giám đốc đã duyệt lịch máy ' || pp.plan_no || ' bản ' || v.version, coalesce(v_note, 'Lịch mới là lịch đang dùng: phát lệnh SX ngày theo lịch này.'),
    '/lich-may?plan=' || v.plan_id);
end $$;
revoke all on function app.kh_schedule_review(uuid, boolean, text) from public, anon;
grant execute on function app.kh_schedule_review(uuid, boolean, text) to authenticated;

create or replace view app.v_kh_versions with (security_invoker = true) as
select v.id, v.plan_id, v.version, v.is_current, v.base_date, v.params, v.reason, v.created_at, app.user_name(v.created_by) as created_by_name,
       v.change_request_id, (select c.req_no from plan.change_requests c where c.id = v.change_request_id) as change_no,
       v.status, v.approved_at, app.user_name(v.approved_by) as approved_by_name, v.review_note, v.created_by
from plan.schedule_versions v;

-- ===========================================================================
-- 7. Lịch theo lô: TP SX đệ trình ngày chốt (theo MES dự kiến) → Giám đốc duyệt (được sửa ngày chốt)
-- ===========================================================================
create or replace function app.kh_commit_lot(p_line uuid, p_date date, p_note text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare l plan.plan_lines; pp plan.production_plans; v_eta date; v_code text; v_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  if not app.kh_has_any(array['SX_TP', 'SX_KH']) then raise exception 'Chỉ TP SX đệ trình ngày hoàn thành của lô'; end if;
  select * into l from plan.plan_lines where id = p_line for update;
  if not found then raise exception 'Không tìm thấy dòng kế hoạch'; end if;
  select * into pp from plan.production_plans where id = l.plan_id;
  if pp.status <> 'APPROVED' then raise exception 'Kế hoạch % chưa được duyệt', pp.plan_no; end if;
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
                     coalesce(v_note, 'TP SX đệ trình ngày hoàn thành'));
  perform wf.notify_users(array_remove(plan.gd_ids(), auth.uid()), 'Lô chờ Giám đốc duyệt: ' || v_code,
    'TP SX đệ trình xong ' || to_char(p_date, 'DD/MM') || coalesce(' (MES dự kiến ' || to_char(v_eta, 'DD/MM') || ')', '') || coalesce(' · hạn giao ' || to_char(l.due_date, 'DD/MM'), '')
      || coalesce('. ' || v_note, ''), '/lich-may?plan=' || l.plan_id || '&tab=thang');
end $$;

-- TP SX đệ trình một lần mọi lô chưa chốt theo ngày MES dự kiến (lịch máy đang dùng)
create or replace function app.kh_commit_lots(p_plan uuid) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare pp plan.production_plans; r record; v_n int := 0; v_list text; v_today date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
begin
  if not app.kh_has_any(array['SX_TP', 'SX_KH']) then raise exception 'Chỉ TP SX đệ trình ngày hoàn thành của lô'; end if;
  select * into pp from plan.production_plans where id = p_plan;
  if not found then raise exception 'Không tìm thấy kế hoạch'; end if;
  if pp.status <> 'APPROVED' then raise exception 'Kế hoạch % chưa được duyệt', pp.plan_no; end if;
  for r in select l.id, p.code, plan.lot_eta(l.id) as eta, l.due_date from plan.plan_lines l join master.products p on p.id = l.product_id
           where l.plan_id = p_plan and l.qty_m > 0 and l.committed_date is null order by p.code loop
    continue when r.eta is null or r.eta < v_today;
    update plan.plan_lines set committed_date = r.eta, committed_note = 'Theo ngày MES dự kiến' || case when r.due_date is not null and r.eta > r.due_date
             then ' (sau hạn giao ' || to_char(r.due_date, 'DD/MM') || ')' else '' end,
           committed_by = auth.uid(), committed_at = now(), lot_approved_at = null, lot_approved_by = null, lot_version_id = null
     where id = r.id;
    v_n := v_n + 1;
    v_list := concat_ws(', ', v_list, r.code || ' ' || to_char(r.eta, 'DD/MM'));
  end loop;
  if v_n = 0 then raise exception 'Không còn lô nào chưa chốt có ngày MES dự kiến (xếp lịch máy trước)'; end if;
  perform app.kh_log('Lịch lô', pp.plan_no, null, v_n || ' lô', 'TP SX đệ trình theo ngày MES dự kiến');
  perform wf.notify_users(array_remove(plan.gd_ids(), auth.uid()), v_n || ' lô chờ Giám đốc duyệt: ' || pp.plan_no,
    left('TP SX đệ trình theo ngày MES dự kiến: ' || v_list, 900), '/lich-may?plan=' || p_plan || '&tab=thang');
  return v_n;
end $$;
revoke all on function app.kh_commit_lots(uuid) from public, anon;
grant execute on function app.kh_commit_lots(uuid) to authenticated;

-- Giám đốc duyệt lịch lô: giữ chỗ ca máy của lô trong lịch đang dùng. Được sửa ngày chốt khi duyệt (bắt buộc ghi chú).
drop function if exists app.kh_approve_lot(uuid, boolean);
create or replace function app.kh_approve_lot(p_line uuid, p_approve boolean, p_date date default null, p_note text default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare l plan.plan_lines; v_ver uuid; v_eta date; v_code text; v_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  if not plan.is_gd() then raise exception 'Chỉ Giám đốc duyệt lịch lô (TP SX đệ trình ngày chốt)'; end if;
  select * into l from plan.plan_lines where id = p_line for update;
  if not found then raise exception 'Không tìm thấy dòng kế hoạch'; end if;
  select code into v_code from master.products where id = l.product_id;
  if not p_approve then
    update plan.plan_lines set lot_approved_at = null, lot_approved_by = null, lot_version_id = null where id = p_line;
    perform app.kh_log('Lịch lô', v_code, 'Đã duyệt, giữ chỗ', 'Bỏ giữ chỗ', coalesce(v_note, 'Giám đốc bỏ giữ chỗ lịch lô'));
    return;
  end if;
  if l.committed_date is null and p_date is null then raise exception 'TP SX chưa đệ trình ngày hoàn thành của lô'; end if;
  if l.committed_by = auth.uid() then raise exception 'Người đệ trình ngày chốt không tự duyệt lịch lô'; end if;
  if p_date is not null and p_date is distinct from l.committed_date then
    if v_note is null then raise exception 'Giám đốc sửa ngày chốt: ghi lý do'; end if;
    if p_date < (now() at time zone 'Asia/Ho_Chi_Minh')::date then raise exception 'Ngày chốt đã qua'; end if;
    perform app.kh_log('Lịch lô', v_code, coalesce(to_char(l.committed_date, 'DD/MM/YYYY'), '—'), to_char(p_date, 'DD/MM/YYYY'), 'Giám đốc sửa khi duyệt: ' || v_note);
    update plan.plan_lines set committed_date = p_date,
           committed_note = concat_ws(' · ', committed_note, 'Giám đốc sửa ' || coalesce(to_char(l.committed_date, 'DD/MM'), '—') || ' → ' || to_char(p_date, 'DD/MM') || ': ' || v_note),
           committed_by = coalesce(committed_by, auth.uid()), committed_at = coalesce(committed_at, now())
     where id = p_line;
    l.committed_date := p_date;
  end if;
  select o.version_id, o.finish_date into v_ver, v_eta from plan.schedule_orders o join plan.schedule_versions v on v.id = o.version_id and v.is_current
   where o.plan_line_id = p_line order by v.created_at desc limit 1;
  if v_ver is null or not exists (select 1 from plan.schedule_slots s where s.version_id = v_ver and s.plan_line_id = p_line) then
    raise exception 'Lô chưa có trong lịch máy đang dùng: duyệt lịch máy trước';
  end if;
  if v_eta is null or v_eta > l.committed_date then
    raise exception 'Lịch máy hiện xong % sau ngày chốt %: TP SX xếp lại lịch hoặc chốt lại ngày', coalesce(to_char(v_eta, 'DD/MM'), '(chưa xếp đủ)'), to_char(l.committed_date, 'DD/MM');
  end if;
  update plan.plan_lines set lot_approved_at = now(), lot_approved_by = auth.uid(), lot_version_id = v_ver where id = p_line;
  perform app.kh_log('Lịch lô', v_code, null, 'Giám đốc duyệt, giữ chỗ lịch máy', 'Xong ' || to_char(v_eta, 'DD/MM') || ', chốt ' || to_char(l.committed_date, 'DD/MM'));
  perform wf.notify_users(array(select distinct u from unnest(array_remove(array[l.committed_by], null) || inv.role_users(array['SX_TP', 'SX_KH'])) u
                                 where u <> auth.uid()),
    'Giám đốc đã duyệt lịch lô ' || v_code,
    'Giữ chỗ trên lịch máy, xong ' || to_char(v_eta, 'DD/MM') || ' (chốt ' || to_char(l.committed_date, 'DD/MM') || ').',
    '/lich-may?plan=' || l.plan_id || '&tab=thang');
end $$;
revoke all on function app.kh_approve_lot(uuid, boolean, date, text) from public, anon;
grant execute on function app.kh_approve_lot(uuid, boolean, date, text) to authenticated;

-- Giám đốc duyệt một lần mọi lô TP SX đã đệ trình; lô không duyệt được thì trả danh sách lý do
create or replace function app.kh_approve_lots(p_plan uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r record; v_ok int := 0; v_fail jsonb := '[]';
begin
  if not plan.is_gd() then raise exception 'Chỉ Giám đốc duyệt lịch lô (TP SX đệ trình ngày chốt)'; end if;
  for r in select l.id, p.code from plan.plan_lines l join master.products p on p.id = l.product_id
           where l.plan_id = p_plan and l.committed_date is not null and l.lot_approved_at is null and l.qty_m > 0 order by p.code loop
    begin
      perform app.kh_approve_lot(r.id, true);
      v_ok := v_ok + 1;
    exception when others then
      v_fail := v_fail || jsonb_build_array(jsonb_build_object('code', r.code, 'msg', sqlerrm));
    end;
  end loop;
  return jsonb_build_object('ok', v_ok, 'fail', v_fail);
end $$;
revoke all on function app.kh_approve_lots(uuid) from public, anon;
grant execute on function app.kh_approve_lots(uuid) to authenticated;

-- ===========================================================================
-- 8. Lệnh SX ngày: TP SX đề xuất → Giám đốc duyệt phát lệnh (Giám đốc tự phát thì phát ngay)
-- ===========================================================================
alter table plan.daily_releases
  add column if not exists status text not null default 'RELEASED',
  add column if not exists proposed_by uuid,
  add column if not exists proposed_at timestamptz,
  add column if not exists review_note text;
alter table plan.daily_releases drop constraint if exists daily_releases_status_check;
alter table plan.daily_releases add constraint daily_releases_status_check check (status in ('PROPOSED', 'RELEASED', 'RETURNED', 'SUPERSEDED'));
alter table plan.daily_releases alter column released_at drop not null, alter column released_at drop default, alter column released_by drop default;
update plan.daily_releases set proposed_by = released_by, proposed_at = released_at where proposed_at is null;

-- Phát lệnh đã duyệt: phiếu lĩnh lệnh ngày + lệnh SX cho dòng có việc, báo Kế toán SX duyệt phiếu lĩnh
create or replace function plan.release_execute(p_release uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare d plan.daily_releases; v_prev jsonb; v_no text; r record; v_wos text;
begin
  select * into d from plan.daily_releases where id = p_release;
  v_prev := app.kh_day_preview(d.plan_id, d.work_date);
  update plan.daily_releases set checks = v_prev -> 'checks' where id = p_release;
  v_no := 'PL-' || to_char(d.work_date, 'YYMMDD') || '-' || lpad(d.revision::text, 2, '0');
  insert into plan.issue_slips (release_id, slip_no, work_date, lines) values (p_release, v_no, d.work_date, v_prev -> 'slip');
  for r in select distinct w.plan_line_id from plan.day_work(d.version_id, d.work_date) w loop
    perform plan.ensure_wo(r.plan_line_id, d.work_date);
  end loop;
  select string_agg(wo.wo_no, ', ' order by wo.wo_no) into v_wos
    from mfg.work_orders wo where wo.plan_line_id in (select distinct w.plan_line_id from plan.day_work(d.version_id, d.work_date) w)
     and wo.status in ('RELEASED', 'IN_PROGRESS');
  perform app.kh_notify_role('KT_KHO', 'Phiếu lĩnh ' || v_no || ' chờ duyệt', 'Lệnh ngày ' || to_char(d.work_date, 'DD/MM')
    || case when d.revision > 1 then ' (bản ' || d.revision || ')' else '' end || ' đã phát. Lệnh SX: ' || coalesce(v_wos, '—'), '/lenh-ngay?d=' || d.work_date);
  perform wf.notify_users(array(select distinct u from unnest(array_remove(array[d.proposed_by], null) || inv.role_users(array['SX_TP', 'SX_KH'])) u
                                 where u <> auth.uid()),
    'Đã phát lệnh SX ngày ' || to_char(d.work_date, 'DD/MM') || case when d.revision > 1 then ' bản ' || d.revision else '' end,
    concat_ws(' · ', 'Lệnh SX: ' || coalesce(v_wos, '—'), d.review_note), '/lenh-ngay?d=' || d.work_date);
end $$;
revoke all on function plan.release_execute(uuid) from public, anon, authenticated;

create or replace function app.kh_release_day(p_plan uuid, p_date date, p_note text, p_checks jsonb, p_slip jsonb) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare pp plan.production_plans; v_ver uuid; v_rev integer; v_id uuid; v_warn integer; v_prev jsonb; v_direct boolean;
begin
  if not app.kh_has_any(array['SX_TP','SX_KH','BGD']) then raise exception 'Chỉ TP SX đề xuất phát lệnh ngày (Giám đốc duyệt)'; end if;
  select * into pp from plan.production_plans where id = p_plan for update;
  if pp.status <> 'APPROVED' then raise exception 'Kế hoạch tháng % chưa được duyệt: chưa phát lệnh ngày được', pp.plan_no; end if;
  if p_date < (now() at time zone 'Asia/Ho_Chi_Minh')::date then raise exception 'Không phát lệnh cho ngày đã qua'; end if;
  select id into v_ver from plan.schedule_versions where plan_id = p_plan and is_current;
  if v_ver is null then raise exception 'Chưa có lịch máy đã duyệt: TP SX xếp lịch, Giám đốc duyệt trước'; end if;
  v_prev := app.kh_day_preview(p_plan, p_date);
  if not exists (select 1 from plan.day_work(v_ver, p_date)) then raise exception 'Không có việc nào trong ngày % theo lịch máy', to_char(p_date, 'DD/MM'); end if;
  select count(*) into v_warn from jsonb_array_elements(v_prev -> 'checks') e where not (e ->> 'ok')::boolean;
  if v_warn > 0 and coalesce(trim(p_note), '') = '' then raise exception 'Còn % cảnh báo: ghi cách xử lý vào ô ghi chú', v_warn; end if;
  v_direct := plan.is_gd();
  update plan.daily_releases set status = 'SUPERSEDED' where plan_id = p_plan and work_date = p_date and status = 'PROPOSED';
  select coalesce(max(revision), 0) + 1 into v_rev from plan.daily_releases where plan_id = p_plan and work_date = p_date;
  insert into plan.daily_releases (plan_id, work_date, revision, version_id, note, checks, status, proposed_by, proposed_at, released_at, released_by)
  values (p_plan, p_date, v_rev, v_ver, nullif(trim(p_note), ''), v_prev -> 'checks', case when v_direct then 'RELEASED' else 'PROPOSED' end,
          auth.uid(), now(), case when v_direct then now() end, case when v_direct then auth.uid() end)
  returning id into v_id;
  if v_direct then
    perform plan.release_execute(v_id);
  else
    perform wf.notify_users(array_remove(plan.gd_ids(), auth.uid()), 'Lệnh SX ngày ' || to_char(p_date, 'DD/MM') || ' chờ duyệt',
      concat_ws(' · ', pp.plan_no || case when v_rev > 1 then ' bản ' || v_rev else '' end,
                case when v_warn > 0 then v_warn || ' cảnh báo' end, nullif(trim(p_note), '')), '/lenh-ngay?d=' || p_date);
  end if;
  return v_id;
end $$;

-- Giám đốc duyệt / trả lại lệnh ngày TP SX đề xuất (ghi chú của Giám đốc kèm theo lệnh)
create or replace function app.kh_release_review(p_release uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare d plan.daily_releases; pp plan.production_plans; v_cur uuid; v_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  if not plan.is_gd() then raise exception 'Chỉ Giám đốc duyệt phát lệnh SX ngày'; end if;
  select * into d from plan.daily_releases where id = p_release for update;
  if not found then raise exception 'Không tìm thấy lệnh ngày'; end if;
  if d.status <> 'PROPOSED' then raise exception 'Lệnh ngày % không chờ duyệt', to_char(d.work_date, 'DD/MM'); end if;
  if d.proposed_by = auth.uid() then raise exception 'Người đề xuất không tự duyệt lệnh ngày'; end if;
  select * into pp from plan.production_plans where id = d.plan_id for update;
  if not p_approve then
    if v_note is null then raise exception 'Nhập lý do trả lại để TP SX sửa'; end if;
    update plan.daily_releases set status = 'RETURNED', review_note = v_note where id = p_release;
    perform wf.notify_users(array_remove(array[d.proposed_by], null), 'Lệnh SX ngày ' || to_char(d.work_date, 'DD/MM') || ' bị trả lại', v_note,
      '/lenh-ngay?d=' || d.work_date);
    return;
  end if;
  if pp.status <> 'APPROVED' then raise exception 'Kế hoạch tháng % không còn ở trạng thái đã duyệt', pp.plan_no; end if;
  if d.work_date < (now() at time zone 'Asia/Ho_Chi_Minh')::date then raise exception 'Ngày sản xuất đã qua: trả lại'; end if;
  select id into v_cur from plan.schedule_versions where plan_id = d.plan_id and is_current;
  if v_cur is distinct from d.version_id then raise exception 'Lịch máy đã đổi sau khi TP SX đề xuất: trả lại để đề xuất lại theo lịch mới'; end if;
  update plan.daily_releases set status = 'RELEASED', released_at = now(), released_by = auth.uid(), review_note = v_note where id = p_release;
  perform plan.release_execute(p_release);
end $$;
revoke all on function app.kh_release_review(uuid, boolean, text) from public, anon;
grant execute on function app.kh_release_review(uuid, boolean, text) to authenticated;

-- Kế toán SX duyệt phiếu lĩnh: không phải người đề xuất / người duyệt phát lệnh
do $$
declare d text;
  v_old text := $x$if d.released_by = auth.uid() then raise exception 'Người phát lệnh ngày không tự duyệt phiếu lĩnh'; end if;$x$;
  v_new text := $x$if d.status <> 'RELEASED' then raise exception 'Lệnh ngày chưa được Giám đốc duyệt phát'; end if;
  if auth.uid() in (d.released_by, d.proposed_by) then raise exception 'Người phát lệnh ngày không tự duyệt phiếu lĩnh'; end if;$x$;
begin
  d := replace(pg_get_functiondef('app.kh_approve_slip(uuid)'::regprocedure), E'\r', '');
  if position('d.proposed_by' in d) > 0 then return; end if;
  if position(v_old in d) = 0 then raise exception 'app.kh_approve_slip: không thấy đoạn kiểm người phát lệnh'; end if;
  execute replace(d, v_old, v_new);
end $$;

create or replace view app.v_kh_releases with (security_invoker = true) as
select r.id, r.plan_id, r.work_date, r.revision, r.version_id, r.note, r.checks, r.released_at, r.released_by,
       app.user_name(r.released_by) as released_by_name,
       s.id as slip_id, s.slip_no, s.lines as slip_lines, s.status as slip_status, s.approved_at,
       app.user_name(s.approved_by) as approved_by_name,
       (select coalesce(jsonb_agg(jsonb_build_object('id', rq.id, 'req_no', rq.req_no, 'status', rq.status, 'wo_no', wo.wo_no,
                                                     'product_code', p.code) order by rq.req_no), '[]')
          from inv.requisitions rq join mfg.work_orders wo on wo.id = rq.wo_id join master.products p on p.id = wo.product_id
         where rq.slip_id = s.id) as requisitions,
       r.status, r.proposed_by, r.proposed_at, app.user_name(r.proposed_by) as proposed_by_name, r.review_note
from plan.daily_releases r left join plan.issue_slips s on s.release_id = r.id;
grant select on app.v_kh_releases to authenticated, service_role;
