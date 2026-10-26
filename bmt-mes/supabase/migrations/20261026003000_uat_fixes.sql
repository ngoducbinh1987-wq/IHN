-- Sửa lỗi chạy thử UAT 26/10/2026 (báo cáo "BMT MES – Báo cáo chạy thử quy trình phê duyệt"), theo chỉ đạo của người dùng:
--  0. Quản trị hệ thống (ADMIN) được làm mọi khâu duyệt; vẫn không tự duyệt hồ sơ mình lập
--  1. L1: hủy quy trình kẹt dùng app.admin_cancel_request (migration 2900); ở đây thêm: quá hạn mà không còn ai duyệt được thì báo Quản trị
--  2. L2: NV kho thành phẩm (KHO_NV) xem được đơn bán / hàng đã giữ / lệnh giao
--  3. L3: mã sản phẩm viết IN HOA (1p5 → 1P5, 0p75 → 0P75), khóa nhập chữ thường khi tạo mã mới
--  4. L4: phát hành spec mới thì kế hoạch, lệnh SX nháp đang dùng bản cũ chuyển sang bản mới, báo người liên quan
--  5. L6: người đã duyệt bước trước không duyệt bước sau của cùng hồ sơ (trừ khi không còn ai khác)
--  6. L7: module máy không tự duyệt: tốc độ chuẩn, tay nghề, phiếu bảo dưỡng; báo TP Kỹ thuật/QA việc chờ

-- ===========================================================================
-- 0. Quản trị hệ thống làm được mọi khâu
-- ===========================================================================
-- core.is_admin() có từ migration 20261026002900_admin_override

-- Mọi kiểm tra "cần vai trò X" (duyệt mẫu, xác nhận ca, duyệt phiếu lĩnh, đơn phát sinh, hậu kiểm kho…) nhận Quản trị
create or replace function core.has_role(p_role text) returns boolean
language sql stable security definer set search_path = core, public as $$
  select exists (select 1 from core.user_roles where user_id = auth.uid() and role_code = p_role)
      or exists (select 1 from core.delegations where to_user = auth.uid() and role_code = p_role
                 and now() between valid_from and valid_to)
      or core.is_admin()
$$;

-- Bước duyệt chung: Quản trị xử lý được mọi bước, kể cả bước giao đích danh (Chủ tịch HĐQT)
create or replace function wf.can_act_step(p_step jsonb, out ok boolean, out on_behalf uuid)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  ok := auth.uid() = any(wf.step_actor_ids(p_step));
  if not ok then
    select d.from_user into on_behalf from core.delegations d
     where d.to_user = auth.uid() and d.role_code = p_step ->> 'role' and now() between d.valid_from and d.valid_to
       and d.from_user = any(wf.step_actor_ids(p_step))
     limit 1;
    ok := on_behalf is not null;
  end if;
  if not ok then ok := core.is_admin(); end if;
end $$;

-- ===========================================================================
-- 5. L6 + 0: wf.act – không duyệt hai bước liên tiếp của cùng hồ sơ; yêu cầu không tồn tại báo rõ
-- ===========================================================================
create or replace function wf.act(p_request uuid, p_action text, p_comment text default null) returns text
language plpgsql security definer set search_path = wf, core, public as $$
declare r wf.approval_requests; f wf.approval_flows; v_step jsonb; v_next jsonb; v_hash text;
        v_ok boolean; v_behalf uuid; v_fallback boolean; v_comment text := p_comment; v_prev uuid[]; v_others uuid[];
begin
  select * into r from wf.approval_requests where id = p_request for update;
  if not found then raise exception 'Không tìm thấy yêu cầu duyệt'; end if;
  if r.status <> 'PENDING' then raise exception 'Yêu cầu đã kết thúc (%)', r.status; end if;
  if p_action not in ('APPROVE', 'REJECT', 'COMMENT') then raise exception 'Thao tác không hợp lệ'; end if;
  select * into f from wf.approval_flows where doc_type = r.doc_type;
  v_step := wf.snap_step(r, r.current_seq);

  select c.ok, c.on_behalf, c.fallback into v_ok, v_behalf, v_fallback from wf.can_act_step(v_step, r.step_started_at) c;
  if not v_ok then
    raise exception 'Bước "%" cần vai trò % – người được giao: %', v_step ->> 'label',
      coalesce((select name from core.roles where code = v_step ->> 'role'), v_step ->> 'role'),
      coalesce((select string_agg(full_name, ', ') from core.profiles where id = any(wf.step_actor_ids(v_step))), 'chưa có');
  end if;
  if auth.uid() = r.submitted_by then raise exception 'Người lập không tự duyệt chứng từ của mình'; end if;
  if p_action = 'REJECT' and coalesce(trim(p_comment), '') = '' then
    raise exception 'Nhập lý do trả lại để người lập biết cần sửa gì';
  end if;
  -- Hai cấp duyệt phải là hai người: ai đã duyệt bước trước thì không duyệt bước này,
  -- trừ khi bước này không còn ai khác (ngoài người lập và người đã duyệt) – khi đó ghi rõ vào lịch sử
  if p_action = 'APPROVE' then
    select coalesce(array_agg(distinct a.actor_id), '{}') into v_prev
      from wf.approval_actions a where a.request_id = p_request and a.action = 'APPROVE' and a.seq < r.current_seq;
    if auth.uid() = any(v_prev) then
      select coalesce(array_agg(u), '{}') into v_others
        from unnest(wf.step_actor_ids(v_step)) u where u <> r.submitted_by and u <> all(v_prev);
      if cardinality(v_others) > 0 then
        raise exception 'Bạn đã duyệt bước trước của hồ sơ này: bước "%" cần người khác duyệt (%)', v_step ->> 'label',
          (select string_agg(full_name, ', ') from core.profiles where id = any(v_others));
      end if;
      v_comment := '[Duyệt tiếp: bước này không còn người khác] ' || coalesce(v_comment, '');
    end if;
  end if;
  if v_fallback then v_comment := '[Duyệt thay do quá hạn] ' || coalesce(v_comment, ''); end if;
  v_hash := wf.doc_hash(f.doc_table, r.doc_id);
  if v_hash <> r.data_hash then raise exception 'Chứng từ đã bị sửa sau khi gửi duyệt: gửi duyệt lại'; end if;

  insert into wf.approval_actions (request_id, seq, on_behalf_of, action, comment, data_hash)
  values (p_request, r.current_seq, v_behalf, p_action, nullif(trim(v_comment), ''), v_hash);

  if p_action = 'COMMENT' then return 'PENDING'; end if;

  if p_action = 'REJECT' then
    update wf.approval_requests set status = 'REJECTED', finished_at = now() where id = p_request;
    perform wf._undo_doc(r, f);
    insert into wf.notifications (user_id, title, body, link) values (r.submitted_by, 'Bị trả lại: ' || r.doc_no, p_comment, '/duyet/' || p_request);
    return 'REJECTED';
  end if;

  select s into v_next from jsonb_array_elements(r.flow_snapshot -> 'steps') s
   where (s ->> 'seq')::int > r.current_seq order by (s ->> 'seq')::int limit 1;
  if v_next is not null then
    update wf.approval_requests set current_seq = (v_next ->> 'seq')::smallint where id = p_request;
    perform wf.notify_users(array_remove(wf.step_actor_ids(v_next), r.submitted_by), 'Chờ duyệt: ' || r.doc_no, r.summary, '/duyet/' || p_request);
    return 'PENDING';
  end if;

  update wf.approval_requests set status = 'APPROVED', finished_at = now() where id = p_request;
  perform set_config('bmt.wf_release', 'on', true);
  if r.doc_type like 'SPEC%' then
    perform master.release_spec(r.doc_id);
  elsif r.doc_type = 'WO_RELEASE' then
    perform mfg.release_wo(r.doc_id);
  else
    execute format('update %s set %I = $1 where id = $2', f.doc_table, f.status_col) using f.approved_status, r.doc_id;
    -- kho: chứng từ kho được duyệt thì ghi sổ ngay; phiếu lĩnh bổ sung / lệnh giao được duyệt thì báo người giữ kho
    if r.doc_type in ('STOCK_ADJ', 'SCRAP_OUT', 'STOCK_OPEN') then
      perform inv._post(r.doc_id);
      if r.doc_type = 'STOCK_ADJ' then
        update inv.stock_counts set status = 'POSTED' where adj_doc_id = r.doc_id;
      end if;
    elsif r.doc_type = 'EXTRA_ISSUE' then
      perform wf.notify_users(inv.role_users(array['THU_KHO']), 'Phiếu lĩnh bổ sung đã duyệt: ' || r.doc_no, r.summary, '/kho/cap-phat/' || r.doc_id);
    elsif r.doc_type = 'DELIVERY' then
      perform wf.notify_users(inv.role_users(array['KHO_NV']), 'Lệnh giao đã duyệt: ' || r.doc_no, r.summary, '/kho/xuat-ban/' || r.doc_id);
    end if;
  end if;
  perform set_config('bmt.wf_release', 'off', true);
  insert into wf.notifications (user_id, title, link) values (r.submitted_by, 'Đã duyệt: ' || r.doc_no, '/duyet/' || p_request);
  return 'APPROVED';
end $$;

-- Trả chứng từ về trạng thái trả lại
create or replace function wf._undo_doc(r wf.approval_requests, f wf.approval_flows) returns void
language plpgsql security definer set search_path = wf, core, public as $$
begin
  execute format('update %s set %I = $1 where id = $2', f.doc_table, f.status_col) using f.rejected_status, r.doc_id;
  -- kho: kiểm kê bị trả lại → mở lại để đếm/đóng lại; tồn đầu kỳ bị trả lại → hủy đơn vị chứa đã tạo
  if r.doc_type = 'STOCK_ADJ' then
    update inv.stock_counts set status = 'COUNTED' where adj_doc_id = r.doc_id and status = 'PENDING_APPROVAL';
  elsif r.doc_type = 'STOCK_OPEN' then
    update inv.handling_units set status = 'VOID', void_reason = 'Tồn đầu kỳ bị trả lại'
     where id in (select dl.hu_id from inv.stock_doc_lines dl where dl.doc_id = r.doc_id);
  end if;
end $$;
revoke all on function wf._undo_doc(wf.approval_requests, wf.approval_flows) from public, anon, authenticated;

-- ===========================================================================
-- 1. L1
-- ===========================================================================
-- Quá hạn mà bước không còn ai duyệt được (ngoài người lập) → báo Quản trị thay vì không báo ai
create or replace function wf.check_sla() returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r record; v_kind text; v_n int := 0; v_due timestamptz; v_users uuid[]; v_backup uuid[];
begin
  for r in select q.*, wf.snap_step(q, q.current_seq) as st from wf.approval_requests q where q.status = 'PENDING' loop
    v_due := r.step_started_at + make_interval(hours => coalesce((r.st ->> 'sla_hours')::int, 24));
    v_kind := case when now() >= v_due then 'OVERDUE'
                   when coalesce((r.st ->> 'warn_hours')::int, 0) > 0
                        and now() >= v_due - make_interval(hours => (r.st ->> 'warn_hours')::int) then 'WARN' end;
    continue when v_kind is null;
    insert into wf.sla_alerts (request_id, seq, step_started_at, kind) values (r.id, r.current_seq, r.step_started_at, v_kind)
    on conflict do nothing;
    continue when not found;
    v_users := array_remove(wf.step_actor_ids(r.st), r.submitted_by);
    perform wf.notify_users(v_users,
      case v_kind when 'OVERDUE' then 'Quá hạn duyệt: ' else 'Sắp đến hạn duyệt: ' end || r.doc_no,
      format('Bước "%s" hạn %s. %s', r.st ->> 'label', to_char(v_due at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM/YYYY'), coalesce(r.summary, '')),
      '/duyet/' || r.id, r.id, r.current_seq);
    v_n := v_n + cardinality(v_users);
    if v_kind = 'OVERDUE' and (r.st ->> 'fallback') is not null then
      select coalesce(array_agg(u), '{}') into v_backup
        from unnest(wf.step_actor_ids(jsonb_build_object('role', r.st ->> 'fallback'))) u
       where u <> r.submitted_by and u <> all(v_users);
      perform wf.notify_users(v_backup, 'Có thể duyệt thay: ' || r.doc_no,
        format('Bước "%s" đã quá hạn từ %s. Bạn được duyệt thay theo quy chuẩn.', r.st ->> 'label',
               to_char(v_due at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM/YYYY')),
        '/duyet/' || r.id, r.id, r.current_seq);
      v_n := v_n + cardinality(v_backup);
    end if;
    if v_kind = 'OVERDUE' and cardinality(v_users) = 0 then
      v_backup := inv.role_users(array['ADMIN']);
      perform wf.notify_users(v_backup, 'Không ai duyệt được: ' || r.doc_no,
        format('Bước "%s" không còn người duyệt nào ngoài người lập. Quản trị duyệt thay hoặc hủy quy trình để người lập gửi lại.', r.st ->> 'label'),
        '/duyet/' || r.id, r.id, r.current_seq);
      v_n := v_n + cardinality(v_backup);
    end if;
  end loop;
  return v_n;
end $$;
revoke execute on function wf.check_sla() from authenticated, anon, public;
grant execute on function wf.check_sla() to service_role;

-- ===========================================================================
-- 2. L2: NV kho thành phẩm xem đơn bán (hàng đã giữ, lệnh giao)
-- ===========================================================================
insert into core.role_permissions (role_code, module, action) values ('KHO_NV', 'sales', 'view')
on conflict do nothing;

-- ===========================================================================
-- 3. L3: mã sản phẩm IN HOA
-- ===========================================================================
do $$
declare p record;
begin
  for p in select code as old_code, upper(code) as new_code from master.products where code <> upper(code) loop
    if exists (select 1 from master.products where code = p.new_code) then
      raise exception 'Không đổi được % → %: mã viết hoa đã tồn tại', p.old_code, p.new_code;
    end if;
    update wf.approval_requests set doc_no = replace(doc_no, p.old_code, p.new_code), summary = replace(summary, p.old_code, p.new_code)
     where doc_no like '%' || p.old_code || '%' or summary like '%' || p.old_code || '%';
    update wf.notifications set title = replace(title, p.old_code, p.new_code), body = replace(body, p.old_code, p.new_code)
     where title like '%' || p.old_code || '%' or body like '%' || p.old_code || '%';
  end loop;
  update master.products set code = upper(code) where code <> upper(code);
end $$;
alter table master.products drop constraint if exists products_code_upper;
alter table master.products add constraint products_code_upper check (code = upper(code));
alter table master.materials drop constraint if exists materials_code_upper;
alter table master.materials add constraint materials_code_upper check (code = upper(code));
comment on column master.products.code is 'Mã sản phẩm, viết IN HOA (PFR-2C-0P75 = 0,75 mm²)';

-- Tạo mã mới: không nhận chữ thường (không tự đổi, để người nhập biết quy ước)
create or replace function app.create_spec(p_code text, p_group text, p_description text, p_template uuid, p_params jsonb default '{}')
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_product uuid; v_spec uuid; s master.product_specs; t master.products;
begin
  if not core.has_perm('spec', 'create') then raise exception 'Không có quyền tạo spec mới'; end if;
  p_code := trim(p_code);
  if coalesce(p_code, '') = '' then raise exception 'Nhập mã sản phẩm'; end if;
  if p_code <> upper(p_code) then raise exception 'Mã sản phẩm phải viết IN HOA (ví dụ PFR-2C-1P5): %', p_code; end if;
  if p_code !~ '^[A-Z0-9][A-Z0-9.-]*$' then raise exception 'Mã sản phẩm chỉ gồm chữ in hoa, số, dấu gạch ngang: %', p_code; end if;
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

-- ===========================================================================
-- 4. L4: phát hành spec mới → kế hoạch, lệnh SX nháp dùng bản mới
-- ===========================================================================
-- Chuyển dòng kế hoạch còn hiệu lực + lệnh SX chưa phát của một sản phẩm sang spec đang phát hành; trả danh sách kế hoạch bị đổi
create or replace function plan.follow_released_spec(p_product uuid) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_spec uuid; v_bom uuid; v_plans text; v_wos text;
begin
  select p.current_spec_id into v_spec from master.products p join master.product_specs s on s.id = p.current_spec_id
   where p.id = p_product and s.status = 'RELEASED';
  if v_spec is null then return null; end if;
  select id into v_bom from master.bom_headers where spec_id = v_spec;
  with moved as (
    update plan.plan_lines l set spec_id = v_spec
      from plan.production_plans pp
     where pp.id = l.plan_id and l.product_id = p_product and l.spec_id is distinct from v_spec
       and pp.status in ('DRAFT', 'PENDING_APPROVAL', 'APPROVED')
    returning pp.plan_no)
  select string_agg(distinct plan_no, ', ') into v_plans from moved;
  with moved as (
    update mfg.work_orders w set spec_id = v_spec, bom_id = v_bom
     where w.product_id = p_product and w.status = 'DRAFT' and w.spec_id is distinct from v_spec
    returning w.wo_no)
  select string_agg(wo_no, ', ') into v_wos from moved;
  return nullif(concat_ws('; ', 'kế hoạch ' || v_plans, 'lệnh SX nháp ' || v_wos), '');
end $$;
revoke all on function plan.follow_released_spec(uuid) from public, anon, authenticated;

create or replace function master.release_spec(p_spec uuid) returns void
language plpgsql security definer set search_path = master, core, public as $$
declare s master.product_specs; v_issues text[]; v_code text; v_moved text; u text;
begin
  if coalesce(current_setting('bmt.wf_release', true), '') <> 'on' then
    raise exception 'Chỉ phát hành spec qua quy trình duyệt';
  end if;
  select * into s from master.product_specs where id = p_spec for update;
  v_issues := master.check_spec(p_spec);
  if array_length(v_issues, 1) > 0 then
    raise exception 'Không phát hành được spec: %', array_to_string(v_issues, '; ');
  end if;
  if not exists (select 1 from master.bom_headers where spec_id = p_spec) then
    raise exception 'Spec chưa có BOM';
  end if;
  update master.product_specs set status = 'OBSOLETE'
   where product_id = s.product_id and status = 'RELEASED' and id <> p_spec;
  update master.bom_headers set status = 'OBSOLETE'
   where spec_id in (select id from master.product_specs where product_id = s.product_id and id <> p_spec) and status = 'RELEASED';
  perform set_config('bmt.allow_release', 'on', true);
  update master.product_specs set status = 'RELEASED', released_at = now(), released_by = auth.uid() where id = p_spec;
  perform set_config('bmt.allow_release', 'off', true);
  update master.bom_headers set status = 'RELEASED' where spec_id = p_spec;
  update master.products set current_spec_id = p_spec where id = s.product_id;
  -- Kế hoạch, lệnh SX nháp đang dùng bản cũ: chuyển sang bản mới (MRP tự đánh dấu cần chạy lại), báo người liên quan
  v_moved := plan.follow_released_spec(s.product_id);
  if v_moved is not null then
    select code into v_code from master.products where id = s.product_id;
    perform app.kh_log('Spec', v_code, 'phiên bản cũ', 'v' || s.version, 'Phát hành spec mới: ' || v_moved);
    foreach u in array array['BGD', 'SX_TP', 'SX_KH', 'MUA_TP'] loop
      perform app.kh_notify_role(u, 'Spec ' || v_code || ' v' || s.version || ' đã phát hành',
        'Đã chuyển sang bản mới: ' || v_moved || '. Chạy lại MRP và xếp lại lịch nếu định mức thay đổi.', '/ke-hoach');
    end loop;
  end if;
end $$;

-- Dữ liệu hiện có: dòng kế hoạch đang trỏ spec đã ngưng dùng
do $$
declare p uuid;
begin
  for p in select distinct l.product_id from plan.plan_lines l join master.product_specs s on s.id = l.spec_id
            join plan.production_plans pp on pp.id = l.plan_id
           where s.status = 'OBSOLETE' and pp.status in ('DRAFT', 'PENDING_APPROVAL', 'APPROVED') loop
    perform plan.follow_released_spec(p);
  end loop;
end $$;

-- ===========================================================================
-- 6. L7: module máy – không tự duyệt, báo TP Kỹ thuật/QA việc chờ
-- ===========================================================================
-- Tốc độ chuẩn: Kỹ thuật / Quản lý SX đề xuất (quyền machine:create), TP Kỹ thuật/QA duyệt; người nhập không tự duyệt
drop policy if exists p_insert on master.machine_speeds;
create policy p_insert on master.machine_speeds for insert to authenticated
  with check ((core.has_perm('machine', 'config') or core.has_perm('machine', 'create')) and status = 'PENDING' and approved_by is null);

create or replace function app.approve_machine_speed(p_id uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare s master.machine_speeds;
begin
  if not core.has_perm('machine', 'approve') then raise exception 'Bạn chưa có quyền duyệt tốc độ chuẩn'; end if;
  select * into s from master.machine_speeds where id = p_id for update;
  if not found or s.status <> 'PENDING' then raise exception 'Tốc độ này không ở trạng thái chờ duyệt'; end if;
  if s.created_by = auth.uid() then raise exception 'Người nhập tốc độ không tự duyệt: chờ TP Kỹ thuật/QA (hoặc Giám đốc) duyệt'; end if;
  update master.machine_speeds set status = 'OBSOLETE'
   where status = 'APPROVED' and machine_id = s.machine_id and op_code = s.op_code
     and coalesce(product_id::text, '') = coalesce(s.product_id::text, '') and coalesce(group_code, '') = coalesce(s.group_code, '')
     and coalesce(core_code, '') = coalesce(s.core_code, '');
  update master.machine_speeds set status = 'APPROVED', approved_by = auth.uid(), approved_at = now(),
         temp_approval = not core.has_role('KT_TP') and not core.has_role('ADMIN')
   where id = p_id;
end $$;

create or replace function master.notify_speed_pending() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform app.kh_notify_role('KT_TP', 'Tốc độ chuẩn chờ duyệt: ' || (select code from master.machines where id = new.machine_id),
    new.op_code || ' · ' || new.std_mpm || ' m/phút' || coalesce(' · ' || (select code from master.products where id = new.product_id), ''),
    '/may/' || new.machine_id || '?tab=toc-do');
  return new;
end $$;
drop trigger if exists trg_notify_speed on master.machine_speeds;
create trigger trg_notify_speed after insert on master.machine_speeds for each row execute function master.notify_speed_pending();

-- Tay nghề: lưu người giao; TP Kỹ thuật/QA ký, người giao không tự ký
alter table master.operator_skills add column if not exists assigned_by uuid;

create or replace function app.set_operator_skill(p_machine uuid, p_operator text, p_level text, p_reason text default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare m master.machines; k master.operator_skills; v_lbl jsonb := '{"MAIN":"Đứng chính","LEARNING":"Đang học"}';
begin
  if not (core.has_role('SX_TP') or core.has_perm('machine', 'config')) then
    raise exception 'Chỉ Quản lý SX hoặc TP Kỹ thuật/QA giao người đứng máy';
  end if;
  if p_level is null or p_level not in ('MAIN','LEARNING') then raise exception 'Chọn Đứng chính hoặc Đang học'; end if;
  select * into m from master.machines where id = p_machine;
  if not found then raise exception 'Không tìm thấy máy'; end if;
  if m.inline_with is not null then raise exception 'Giao người theo dây chuyền, không theo máy con'; end if;
  if not exists (select 1 from master.operators where code = p_operator and active) then raise exception 'Không có người đứng máy %', p_operator; end if;
  select * into k from master.operator_skills where operator_code = p_operator and machine_code = m.code for update;
  if found and k.level = p_level then raise exception 'Không có thay đổi'; end if;
  insert into master.operator_skills (operator_code, machine_code, level, assigned_by) values (p_operator, m.code, p_level, auth.uid())
  on conflict (operator_code, machine_code) do update set level = excluded.level, assigned_by = excluded.assigned_by, signed_by = null, signed_at = null;
  perform app.kh_log('Người đứng máy', p_operator || ' · ' || m.code, coalesce(v_lbl ->> k.level, 'Chưa giao'), v_lbl ->> p_level,
                     coalesce(nullif(trim(coalesce(p_reason, '')), ''), 'Giao người đứng máy'));
  perform app.kh_notify_role('SX_TP', 'Người đứng máy đã đổi', p_operator || ' · ' || m.code || ': ' || (v_lbl ->> p_level) || '. Bấm Xếp lại lịch để áp dụng.', '/lich-may');
  perform app.kh_notify_role('KT_TP', 'Tay nghề chờ ký: ' || p_operator || ' · ' || m.code, v_lbl ->> p_level, '/may/' || m.id || '?tab=nguoi');
end $$;

create or replace function app.sign_operator_skill(p_machine uuid, p_operator text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare k master.operator_skills;
begin
  if not core.has_role('KT_TP') then raise exception 'Chỉ TP Kỹ thuật/QA xác nhận tay nghề'; end if;
  select k2.* into k from master.operator_skills k2 join master.machines m on m.code = k2.machine_code
   where m.id = p_machine and k2.operator_code = p_operator and k2.signed_at is null for update of k2;
  if not found then raise exception 'Đã xác nhận rồi hoặc người này chưa được giao dây chuyền'; end if;
  if k.assigned_by = auth.uid() then raise exception 'Người giao người đứng máy không tự ký tay nghề: chờ TP Kỹ thuật/QA khác ký'; end if;
  update master.operator_skills set signed_by = auth.uid(), signed_at = now()
   where operator_code = k.operator_code and machine_code = k.machine_code;
end $$;

-- Phiếu bảo dưỡng/sửa chữa: người làm phiếu không tự xác nhận; xong phiếu thì báo TP Kỹ thuật/QA
create or replace function app.confirm_maint_wo(p_id uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare w mfg.maint_work_orders;
begin
  if not core.has_perm('machine', 'approve') then raise exception 'Chỉ TP Kỹ thuật/QA xác nhận phiếu'; end if;
  select * into w from mfg.maint_work_orders where id = p_id for update;
  if not found or w.status <> 'DONE' or w.confirmed_at is not null then raise exception 'Phiếu chưa hoàn thành hoặc đã xác nhận'; end if;
  if w.done_by = auth.uid() then raise exception 'Người làm phiếu không tự xác nhận: chờ TP Kỹ thuật/QA khác xác nhận'; end if;
  update mfg.maint_work_orders set confirmed_by = auth.uid(), confirmed_at = now() where id = p_id;
end $$;

create or replace function mfg.notify_maint_done() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform app.kh_notify_role('KT_TP', 'Phiếu chờ xác nhận: ' || new.wo_no,
    new.title || ' · ' || case new.result when 'OK' then 'Đạt' else 'Chưa đạt' end, '/may/bao-duong/phieu/' || new.id);
  return new;
end $$;
drop trigger if exists trg_notify_maint_done on mfg.maint_work_orders;
create trigger trg_notify_maint_done after update of status on mfg.maint_work_orders
  for each row when (new.status = 'DONE' and old.status is distinct from 'DONE') execute function mfg.notify_maint_done();
