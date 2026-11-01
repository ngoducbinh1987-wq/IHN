-- Quyền tối cao của Quản trị hệ thống (anh Bình yêu cầu 01/11/2026):
-- Quản trị (ADMIN gán trực tiếp, core.is_admin) tham gia mọi khâu, duyệt và sửa mọi đề xuất, phê duyệt,
-- số liệu kho, giá trị. Mọi thao tác của Quản trị vẫn ghi lịch sử duyệt / core.audit_log.
--  1. Mọi quyền thao tác (has_perm), xem giá, mọi kho, không cần là người giữ kho.
--  2. Bỏ chặn "người lập không tự duyệt", "đã duyệt bước trước", "người làm không tự xác nhận"… cho Quản trị
--     (ghi rõ "[Quản trị …]" vào lịch sử duyệt); sửa chứng từ đang chờ duyệt kể cả do mình lập.
--  3. Sửa số liệu kho: đặt lại tồn một dòng tồn (phiếu điều chỉnh ghi sổ ngay), sửa đơn giá dòng phiếu kho,
--     sửa giá bình quân vật tư; sửa số lượng / đơn giá / ngày về của đơn mua đã duyệt.

-- 1. Quyền nền ---------------------------------------------------------------------------------------------
create or replace function core.has_perm(p_module text, p_action text)
 returns boolean language sql stable security definer set search_path to 'pg_catalog', 'public'
as $$
  select exists (
    select 1
    from core.user_roles ur
    join core.role_permissions rp on rp.role_code = ur.role_code
    join core.profiles p on p.id = ur.user_id and p.status = 'ACTIVE'
    where ur.user_id = auth.uid() and rp.module = p_module and rp.action = p_action
  ) or exists (
    select 1
    from core.delegations d
    join core.role_permissions rp on rp.role_code = d.role_code
    where d.to_user = auth.uid() and now() between d.valid_from and d.valid_to
      and rp.module = p_module and rp.action = p_action
  ) or core.is_admin()
$$;

create or replace function core.can_see_price()
 returns boolean language sql stable security definer set search_path to 'pg_catalog', 'public'
as $$
  select exists (select 1 from core.user_roles ur join core.roles r on r.code = ur.role_code
                 where ur.user_id = auth.uid() and r.can_see_price)
      or core.is_admin()
$$;

create or replace function core.can_use_warehouse(p_wh uuid)
 returns boolean language sql stable security definer set search_path to 'pg_catalog', 'public'
as $$
  select core.is_admin()
      or not exists (select 1 from core.user_scopes where user_id = auth.uid() and scope_type = 'WAREHOUSE')
      or exists (select 1 from core.user_scopes where user_id = auth.uid() and scope_type = 'WAREHOUSE' and scope_id = p_wh)
$$;

-- 2. Bỏ chặn tự duyệt cho Quản trị: vá đúng câu kiểm tra trong định nghĩa hiện tại ----------------------------
create or replace function pg_temp.patch(p_name text, p_old text, p_new text) returns void language plpgsql as $$
declare v_oid oid; v_n int; v_def text;
begin
  select count(*), min(p.oid) into v_n, v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname || '.' || p.proname = p_name;
  if v_n <> 1 then raise exception 'Vá %: có % hàm cùng tên', p_name, v_n; end if;
  v_def := pg_get_functiondef(v_oid);
  if position(p_old in v_def) = 0 then
    raise exception 'Vá %: không thấy đoạn "%"', p_name, p_old;
  end if;
  execute replace(v_def, p_old, p_new);
end $$;

-- Luồng duyệt chung
select pg_temp.patch('wf.act',
  $o$if auth.uid() = r.submitted_by then raise exception 'Người lập không tự duyệt chứng từ của mình'; end if;$o$,
  $n$if auth.uid() = r.submitted_by and not core.is_admin() then raise exception 'Người lập không tự duyệt chứng từ của mình'; end if;
  if auth.uid() = r.submitted_by and p_action = 'APPROVE' then v_comment := '[Quản trị duyệt chứng từ mình lập] ' || coalesce(v_comment, ''); end if;$n$);
select pg_temp.patch('wf.act',
  $o$if auth.uid() = any(v_prev) then$o$,
  $n$if auth.uid() = any(v_prev) and core.is_admin() then
      v_comment := '[Quản trị duyệt tiếp bước sau] ' || coalesce(v_comment, '');
    elsif auth.uid() = any(v_prev) then$n$);
select pg_temp.patch('wf.review_request',
  $o$if auth.uid() = r.submitted_by then$o$,
  $n$if auth.uid() = r.submitted_by and not core.is_admin() then$n$);

-- Bước duyệt trong module
select pg_temp.patch('app.approve_machine_speed',
  $o$if s.created_by = auth.uid() then$o$, $n$if s.created_by = auth.uid() and not core.is_admin() then$n$);
select pg_temp.patch('app.confirm_maint_wo',
  $o$if w.done_by = auth.uid() then$o$, $n$if w.done_by = auth.uid() and not core.is_admin() then$n$);
select pg_temp.patch('app.kh_approve_lot',
  $o$if l.committed_by = auth.uid() then$o$, $n$if l.committed_by = auth.uid() and not core.is_admin() then$n$);
select pg_temp.patch('app.kh_approve_slip',
  $o$if auth.uid() in (d.released_by, d.proposed_by) then$o$, $n$if auth.uid() in (d.released_by, d.proposed_by) and not core.is_admin() then$n$);
select pg_temp.patch('app.kh_change_step',
  $o$if (c.created_by = auth.uid() or exists$o$, $n$if not core.is_admin() and (c.created_by = auth.uid() or exists$n$);
select pg_temp.patch('app.kh_change_edit',
  $o$if c.created_by = auth.uid() then raise exception 'Người lập không sửa$o$,
  $n$if c.created_by = auth.uid() and not core.is_admin() then raise exception 'Người lập không sửa$n$);
select pg_temp.patch('app.kh_ot_review',
  $o$if o.proposed_by = auth.uid() then$o$, $n$if o.proposed_by = auth.uid() and not core.is_admin() then$n$);
select pg_temp.patch('app.kh_shift_review',
  $o$if o.proposed_by = auth.uid() then$o$, $n$if o.proposed_by = auth.uid() and not core.is_admin() then$n$);
select pg_temp.patch('app.kh_release_review',
  $o$if d.proposed_by = auth.uid() then$o$, $n$if d.proposed_by = auth.uid() and not core.is_admin() then$n$);
select pg_temp.patch('app.kh_schedule_review',
  $o$if v.created_by = auth.uid() then$o$, $n$if v.created_by = auth.uid() and not core.is_admin() then$n$);
select pg_temp.patch('app.maint_confirm',
  $o$if w.sched_by = auth.uid() then$o$, $n$if w.sched_by = auth.uid() and not core.is_admin() then$n$);
select pg_temp.patch('app.roster_review',
  $o$if r.submitted_by = auth.uid() then$o$, $n$if r.submitted_by = auth.uid() and not core.is_admin() then$n$);
select pg_temp.patch('app.sign_operator_skill',
  $o$if k.assigned_by = auth.uid() then$o$, $n$if k.assigned_by = auth.uid() and not core.is_admin() then$n$);
select pg_temp.patch('inv.review_doc',
  $o$if auth.uid() in (d.created_by, d.posted_by) then$o$, $n$if auth.uid() in (d.created_by, d.posted_by) and not core.is_admin() then$n$);
select pg_temp.patch('qa.release_lot',
  $o$and op.profile_id = auth.uid()) then$o$, $n$and op.profile_id = auth.uid()) and not core.is_admin() then$n$);
select pg_temp.patch('app.delivery_cancel',
  $o$if not (wf.can_submit('DELIVERY') or d.created_by = auth.uid()) then$o$,
  $n$if not (wf.can_submit('DELIVERY') or d.created_by = auth.uid() or core.is_admin()) then$n$);
select pg_temp.patch('inv.confirm_issue',
  $o$if d.receiver_id is distinct from auth.uid() then$o$, $n$if d.receiver_id is distinct from auth.uid() and not core.is_admin() then$n$);
select pg_temp.patch('inv.require_keeper',
  $o$if coalesce(current_setting('bmt.paper', true), '') = 'on' and mfg.can_enter_slips() then$o$,
  $n$if core.is_admin() then return false; end if;   -- Quản trị: mọi kho, không cần là người giữ kho
  if coalesce(current_setting('bmt.paper', true), '') = 'on' and mfg.can_enter_slips() then$n$);

select pg_temp.patch('app.roster_save', $o$if r.submitted_by = auth.uid() then$o$, $n$if r.submitted_by = auth.uid() and not core.is_admin() then$n$);

-- "Chờ tôi duyệt": Quản trị thấy cả chứng từ mình lập
do $$
declare v_def text := pg_get_viewdef('app.v_approvals'::regclass);
begin
  if position('(submitted_by <> auth.uid())' in v_def) = 0 then raise exception 'Vá app.v_approvals: không thấy điều kiện người lập'; end if;
  execute 'create or replace view app.v_approvals with (security_invoker = true) as '
       || replace(v_def, '(submitted_by <> auth.uid())', '((submitted_by <> auth.uid()) OR core.is_admin())');
end $$;

-- 3. Quản trị sửa số liệu kho, giá trị ---------------------------------------------------------------------
create or replace function app.admin_log(p_table text, p_id text, p_action text, p_old jsonb, p_new jsonb)
 returns void language sql security definer set search_path to 'pg_catalog', 'public'
as $$
  insert into core.audit_log (user_id, table_name, row_id, action, old_data, new_data)
  values (auth.uid(), p_table, p_id, p_action, p_old, p_new)
$$;

insert into master.reason_codes (code, kind, name) values ('ADJ_ADMIN', 'ADJUST', 'Quản trị sửa số tồn') on conflict (code) do nothing;

-- Đặt lại số tồn của một dòng tồn (kho + vị trí + lô + đơn vị chứa): lập phiếu điều chỉnh ADJ ghi sổ ngay
create or replace function app.admin_stock_set(p_warehouse uuid, p_lot uuid, p_location uuid, p_hu uuid, p_qty numeric, p_reason text)
 returns text language plpgsql security definer set search_path to 'pg_catalog', 'public' set "TimeZone" to 'Asia/Ho_Chi_Minh'
as $$
declare v_zero uuid := '00000000-0000-0000-0000-000000000000'; b inv.stock_balances; lt inv.lots; v_doc uuid; v_no text; v_diff numeric;
        v_res text;
begin
  if not core.is_admin() then raise exception 'Chỉ Quản trị hệ thống sửa số tồn trực tiếp'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Ghi lý do sửa số tồn'; end if;
  if p_qty is null or p_qty < 0 then raise exception 'Số tồn mới phải từ 0 trở lên'; end if;
  select * into b from inv.stock_balances
   where warehouse_id = p_warehouse and lot_id = p_lot and location_key = coalesce(p_location, v_zero) and hu_key = coalesce(p_hu, v_zero)
   for update;
  if not found then raise exception 'Không tìm thấy dòng tồn này'; end if;
  if p_qty < b.reserved_qty then raise exception 'Đang giữ cho đơn hàng % – số tồn mới không được nhỏ hơn', core.vn_num(b.reserved_qty); end if;
  v_diff := p_qty - b.qty;
  if v_diff = 0 then raise exception 'Số tồn mới bằng số hiện tại'; end if;
  select * into lt from inv.lots where id = p_lot;
  v_no := core.next_no('DC');
  insert into inv.stock_docs (doc_no, doc_type, status, warehouse_id, ref_type, reason_code, review_status, note)
  values (v_no, 'ADJ', 'APPROVED', p_warehouse, 'ADMIN', 'ADJ_ADMIN', 'NA', 'Quản trị sửa số tồn: ' || trim(p_reason))
  returning id into v_doc;
  insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty, note)
  values (v_doc, 1, p_lot, p_location, p_hu, v_diff, format('Sổ %s → %s', core.vn_num(b.qty), core.vn_num(p_qty)));
  perform inv._post(v_doc);
  perform app.admin_log('inv.stock_balances', v_doc::text, 'ADMIN_STOCK',
    jsonb_build_object('qty', b.qty),
    jsonb_build_object('doc_type', 'Sửa số tồn', 'doc_no', v_no, 'lot_no', lt.lot_no, 'qty', p_qty, 'diff', v_diff, 'reason', trim(p_reason)));
  return v_no;
end $$;

-- Sửa đơn giá một dòng phiếu kho (nháp hoặc đã ghi sổ). Đã ghi sổ: sửa giá trên sổ cái và cộng chênh lệch vào giá trị tồn vật tư
create or replace function app.admin_line_cost(p_line uuid, p_cost numeric, p_reason text)
 returns void language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare l inv.stock_doc_lines; d inv.stock_docs; lt inv.lots; wh inv.warehouses; v_old numeric; v_q numeric; v_dv numeric;
begin
  if not core.is_admin() then raise exception 'Chỉ Quản trị hệ thống sửa đơn giá phiếu kho'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Ghi lý do sửa đơn giá'; end if;
  if p_cost is null or p_cost < 0 then raise exception 'Đơn giá phải từ 0 trở lên'; end if;
  select * into l from inv.stock_doc_lines where id = p_line for update;
  if not found then raise exception 'Không tìm thấy dòng phiếu kho'; end if;
  select * into d from inv.stock_docs where id = l.doc_id;
  if d.status = 'CANCELLED' then raise exception 'Phiếu % đã hủy', d.doc_no; end if;
  select * into lt from inv.lots where id = l.lot_id;
  select * into wh from inv.warehouses where id = d.warehouse_id;
  if d.status = 'POSTED' and d.doc_type = 'TRANSFER' and d.to_warehouse_id is distinct from d.warehouse_id and lt.item_kind = 'MAT' then
    raise exception 'Phiếu chuyển kho vật tư đi theo giá bình quân: sửa giá bình quân ở từng kho';
  end if;
  v_old := l.unit_cost;
  update inv.stock_doc_lines set unit_cost = p_cost where id = p_line;
  if d.status = 'POSTED' then
    select coalesce(sum(sm.qty), 0), coalesce(max(sm.unit_cost), 0) into v_q, v_old
      from inv.stock_moves sm where sm.doc_line_id = p_line;
    update inv.stock_moves set unit_cost = p_cost where doc_line_id = p_line;
    if lt.item_kind = 'MAT' and wh.kind <> 'SCRAP' and v_q <> 0 then
      -- Nhập vào: chênh lệch giá tính cho phần còn trong kho (phần đã xuất đi theo giá cũ); xuất ra: trả chênh lệch về tồn
      if v_q > 0 then
        select least(v_q, greatest(coalesce(max(v.qty), 0), 0)) into v_q from cost.item_valuation v
         where v.warehouse_id = d.warehouse_id and v.material_id = lt.material_id;
      end if;
      v_dv := round((p_cost - v_old) * v_q, 2);
      update cost.item_valuation set value = value + v_dv,
             avg_cost = case when qty > 0 then (value + v_dv) / qty else avg_cost end, updated_at = now()
       where warehouse_id = d.warehouse_id and material_id = lt.material_id;
    end if;
  end if;
  perform app.admin_log('inv.stock_doc_lines', p_line::text, 'ADMIN_COST',
    jsonb_build_object('unit_cost', v_old),
    jsonb_build_object('doc_type', 'Sửa đơn giá phiếu kho', 'doc_no', d.doc_no, 'line_no', l.line_no, 'lot_no', lt.lot_no,
                       'unit_cost', p_cost, 'reason', trim(p_reason)));
end $$;

-- Sửa giá bình quân của vật tư trong một kho (giá trị tồn = số tồn × giá mới)
create or replace function app.admin_avg_cost(p_warehouse uuid, p_material_code text, p_cost numeric, p_reason text)
 returns void language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare v_mat uuid; v_code text := upper(trim(coalesce(p_material_code, ''))); v cost.item_valuation; v_wh text;
begin
  if not core.is_admin() then raise exception 'Chỉ Quản trị hệ thống sửa giá bình quân'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Ghi lý do sửa giá'; end if;
  if p_cost is null or p_cost < 0 then raise exception 'Giá phải từ 0 trở lên'; end if;
  select id into v_mat from master.materials where code = v_code;
  if v_mat is null then raise exception 'Không có vật tư %', v_code; end if;
  select code into v_wh from inv.warehouses where id = p_warehouse;
  if v_wh is null then raise exception 'Không tìm thấy kho'; end if;
  select * into v from cost.item_valuation where warehouse_id = p_warehouse and material_id = v_mat for update;
  if not found then
    insert into cost.item_valuation (warehouse_id, material_id, qty, avg_cost, value) values (p_warehouse, v_mat, 0, p_cost, 0);
  else
    update cost.item_valuation set avg_cost = p_cost, value = round(qty * p_cost, 2), updated_at = now()
     where warehouse_id = p_warehouse and material_id = v_mat;
  end if;
  perform app.admin_log('cost.item_valuation', v_wh || '/' || v_code, 'ADMIN_COST',
    jsonb_build_object('avg_cost', v.avg_cost, 'value', v.value),
    jsonb_build_object('doc_type', 'Sửa giá bình quân', 'doc_no', v_wh || ' · ' || v_code, 'avg_cost', p_cost, 'reason', trim(p_reason)));
end $$;

-- Sửa dòng đơn mua đã duyệt (nháp / chờ duyệt sửa theo cách thường)
create or replace function app.admin_po_line(p_line uuid, p_qty numeric, p_price numeric, p_date date, p_reason text)
 returns void language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare l purchase.po_lines; o purchase.purchase_orders; v_code text;
begin
  if not core.is_admin() then raise exception 'Chỉ Quản trị hệ thống sửa đơn mua đã duyệt'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Ghi lý do sửa đơn mua'; end if;
  select * into l from purchase.po_lines where id = p_line for update;
  if not found then raise exception 'Không tìm thấy dòng đơn mua'; end if;
  select * into o from purchase.purchase_orders where id = l.po_id;
  if o.status in ('DRAFT', 'PENDING_APPROVAL') then raise exception 'Đơn mua chưa duyệt: sửa ngay trên đơn (Quản trị sửa được khi đang chờ duyệt)'; end if;
  if o.status = 'CANCELLED' then raise exception 'Đơn mua đã hủy'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Số lượng phải lớn hơn 0'; end if;
  if p_qty < coalesce(l.received_qty, 0) then raise exception 'Đã nhận % – số lượng không được nhỏ hơn', core.vn_num(l.received_qty); end if;
  if p_price is null or p_price < 0 then raise exception 'Đơn giá phải từ 0 trở lên'; end if;
  update purchase.po_lines set qty = p_qty, unit_price = p_price, expected_date = coalesce(p_date, expected_date) where id = p_line;
  select m.code into v_code from master.materials m where m.id = l.material_id;
  perform app.admin_log('purchase.po_lines', p_line::text, 'ADMIN_PO',
    jsonb_build_object('qty', l.qty, 'unit_price', l.unit_price, 'expected_date', l.expected_date),
    jsonb_build_object('doc_type', 'Sửa đơn mua đã duyệt', 'doc_no', o.po_no, 'material', v_code, 'qty', p_qty, 'unit_price', p_price,
                       'expected_date', coalesce(p_date, l.expected_date), 'reason', trim(p_reason)));
  if o.created_by is not null and o.created_by <> auth.uid() then
    insert into wf.notifications (user_id, title, body, link)
    values (o.created_by, 'Quản trị sửa đơn mua ' || o.po_no,
            format('%s: %s × %s đ. Lý do: %s', v_code, core.vn_num(p_qty), core.vn_num(p_price), trim(p_reason)), '/don-mua/' || o.id);
  end if;
end $$;

-- Nhật ký can thiệp của Quản trị: thêm sửa tồn, đơn giá, đơn mua
create or replace function app.admin_overrides(p_limit integer default 50)
 returns table(at timestamp with time zone, actor text, action text, doc_type text, doc_no text, reason text)
 language sql stable security definer set search_path to 'pg_catalog', 'public'
as $$
  select a.at, app.user_name(a.user_id), a.action, a.new_data ->> 'doc_type', a.new_data ->> 'doc_no', a.new_data ->> 'reason'
  from core.audit_log a
  where a.action in ('ADMIN_CANCEL', 'ADMIN_REOPEN', 'ADMIN_DELETE', 'ADMIN_STOCK', 'ADMIN_COST', 'ADMIN_PO') and core.has_perm('admin', 'view')
  order by a.at desc limit least(greatest(coalesce(p_limit, 50), 1), 500)
$$;

revoke execute on function app.admin_log(text, text, text, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function app.admin_stock_set(uuid, uuid, uuid, uuid, numeric, text) from public, anon;
revoke execute on function app.admin_line_cost(uuid, numeric, text) from public, anon;
revoke execute on function app.admin_avg_cost(uuid, text, numeric, text) from public, anon;
revoke execute on function app.admin_po_line(uuid, numeric, numeric, date, text) from public, anon;
grant execute on function app.admin_stock_set(uuid, uuid, uuid, uuid, numeric, text) to authenticated;
grant execute on function app.admin_line_cost(uuid, numeric, text) to authenticated;
grant execute on function app.admin_avg_cost(uuid, text, numeric, text) to authenticated;
grant execute on function app.admin_po_line(uuid, numeric, numeric, date, text) to authenticated;
