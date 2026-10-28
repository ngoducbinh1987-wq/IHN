-- ============================================================================
-- 20261026005200_po_fg_paper
-- Anh Bình chốt 28/10/2026 (trả lời tài liệu "Rà soát module Kho theo quy trình final" + tin nhắn 11:52):
--  A. Mua hàng: Chủ tịch HĐQT chốt kế hoạch tháng (kèm kết quả MRP · đề nghị mua) thì MES tự sinh đơn mua hàng
--     (PO, nháp, theo nhà cung cấp ưu tiên) → NV mua hàng kiểm tra (chọn NCC, giá, ngày về) và duyệt gửi đi
--     → TP Mua duyệt → Giám đốc duyệt. TP Mua duyệt xong (chuyển Giám đốc) thì Kế toán (Kế toán kho, Kế toán giá thành,
--     Kế toán trưởng) nhận thông báo. Hiệu chỉnh kế hoạch tháng được duyệt: giảm/hủy đơn mua chưa duyệt, sinh đơn mua thêm.
--     Đề xuất mua bổ sung / tích trữ / tối ưu đã duyệt thì NV mua lập đơn mua từ đề xuất. Nhận hàng theo PO đã duyệt.
--  B. Kho thành phẩm: cuộn chỉ dán tem QC PASS, không in, không quét QR; xuất kho chỉ cần số cuộn theo chủng loại
--     (mã, nhãn, quy cách). Lệnh giao lập trực tiếp (không cần đơn bán), Giám đốc duyệt, Kế toán SX nhập "đã giao" từ phiếu
--     giấy người giữ kho TP ký (người giữ kho TP là người được khai báo ở Nhân sự xưởng – "NV3 là biến số").
--     Phiếu nhập kho TP: cuộn QC Đạt chuyển từ khu chờ QC vào khu lưu kho (Kế toán SX nhập từ phiếu giấy).
--  C. Điểm 1: phiếu Kế toán SX nhập từ giấy được xác nhận khi Kế toán SX gửi báo cáo ngày ("Đã đối soát xong – gửi").
--     Điểm 4: phế ghi ở phiếu hoàn thành, báo cáo ca tự nhập kho phế khi TP SX chốt ca / khi gửi báo cáo ngày.
--     Điểm 5: tồn đầu kỳ BTP theo từng bobin (số bobin, công đoạn, mét, kg), thành phẩm theo số cuộn × mét.
--  D. Phiếu hoàn thành đóng gói (CD6): nhập số cuộn × mét mỗi cuộn trên một phiếu.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Cấu trúc dữ liệu
-- ---------------------------------------------------------------------------
alter table purchase.purchase_orders alter column supplier_id drop not null;
alter table purchase.purchase_orders
  add column if not exists source text not null default 'MANUAL',
  add column if not exists plan_id uuid references plan.production_plans(id) on delete set null,
  add column if not exists mrp_run_id uuid references plan.mrp_runs(id) on delete set null,
  add column if not exists adjustment_id uuid references plan.plan_adjustments(id) on delete set null,
  add column if not exists pr_id uuid references purchase.purchase_requests(id) on delete set null,
  add column if not exists cancel_reason text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'purchase_orders_source_check') then
    alter table purchase.purchase_orders add constraint purchase_orders_source_check check (source in ('MRP', 'PR', 'MANUAL'));
  end if;
end $$;
alter table purchase.po_lines
  add column if not exists mrp_line_id uuid references plan.mrp_lines(id) on delete set null,
  add column if not exists mrp_qty numeric(18,4),
  add column if not exists note text;
create index if not exists purchase_orders_plan_idx on purchase.purchase_orders(plan_id);
create index if not exists po_lines_mrp_line_idx on purchase.po_lines(mrp_line_id);
create index if not exists po_lines_pr_line_idx on purchase.po_lines(pr_line_id);
comment on column purchase.purchase_orders.source is 'MRP: MES tự sinh khi Chủ tịch chốt kế hoạch tháng / hiệu chỉnh; PR: lập từ đề xuất mua đã duyệt; MANUAL: lập tay';

-- Thông báo thêm khi một bước duyệt xong (ví dụ PO: TP Mua duyệt → báo Kế toán)
alter table wf.approval_steps add column if not exists notify_roles text[] not null default '{}';

-- Cuộn thành phẩm: quy cách (mét/cuộn, kiểu đóng gói) để đếm và xuất theo số cuộn
alter table inv.handling_units
  add column if not exists pack_m numeric(12,2),
  add column if not exists pack_type text;
comment on column inv.handling_units.pack_m is 'Quy cách mét/cuộn của cuộn thành phẩm (từ lệnh SX hoặc tồn đầu kỳ); trống = đoạn cắt';

-- Lệnh giao trực tiếp (không cần đơn bán): khách, ngày, các dòng chủng loại × số cuộn
alter table sales.deliveries alter column so_id drop not null;
alter table sales.deliveries
  add column if not exists customer_id uuid references core.partners(id),
  add column if not exists customer_name text,
  add column if not exists paper_no text,
  add column if not exists giver_code text,
  add column if not exists shipped_at timestamptz,
  add column if not exists shipped_by uuid references core.profiles(id);
alter table sales.delivery_lines alter column so_line_id drop not null;

create table if not exists sales.delivery_items (
  id            uuid primary key default gen_random_uuid(),
  delivery_id   uuid not null references sales.deliveries(id) on delete cascade,
  line_no       integer not null,
  product_id    uuid not null references master.products(id),
  brand         text not null,
  pack_m        numeric(12,2),             -- trống = cuộn lẻ, đoạn cắt
  coils         integer not null check (coils > 0),
  shipped_coils integer,
  shipped_m     numeric(14,2),
  note          text,
  unique (delivery_id, line_no)
);
alter table sales.delivery_items enable row level security;
drop policy if exists p_select on sales.delivery_items;
create policy p_select on sales.delivery_items for select to authenticated
  using (core.has_perm('sales', 'view') or core.has_perm('inventory', 'view'));
grant select on sales.delivery_items to authenticated;
-- Kế toán SX, Kỹ thuật/QA thấy lệnh giao (trước chỉ người có quyền bán hàng)
drop policy if exists p_select on sales.deliveries;
create policy p_select on sales.deliveries for select to authenticated
  using (core.has_perm('sales', 'view') or core.has_perm('inventory', 'view'));

-- Phiếu hoàn thành đóng gói: số cuộn trên một phiếu
alter table mfg.bobbin_slips add column if not exists coils integer not null default 1;

-- ---------------------------------------------------------------------------
-- 2. Quy trình duyệt, quyền, menu
-- ---------------------------------------------------------------------------
update wf.approval_flows set name = 'Đơn mua hàng (PO)', submit_role = null, submit_user_ids = '{}',
       submit_label = 'NV mua hàng kiểm tra đơn mua, duyệt gửi TP Mua'
 where doc_type = 'PO';
update wf.approval_steps set level_label = 'TP Mua duyệt đơn mua hàng', role_code = 'MUA_TP', enabled = true,
       min_amount = null, when_flags = '{}', fallback_role = 'BGD', notify_roles = array['KT_KHO', 'KT_GT', 'KTT']
 where doc_type = 'PO' and seq = 1;
update wf.approval_steps set level_label = 'Giám đốc duyệt đơn mua hàng', role_code = 'BGD', enabled = true,
       min_amount = null, when_flags = '{}'
 where doc_type = 'PO' and seq = 2;
update wf.approval_steps set enabled = false where doc_type = 'PO' and seq > 2;

-- Lệnh giao: Kinh doanh / Kế toán SX lập → Giám đốc duyệt (bỏ bước TP KT/QA: MES chỉ cho xuất cuộn QC Đạt)
update wf.approval_flows set submit_role = null, submit_user_ids = '{}', submit_label = 'Kinh doanh / Kế toán SX lập lệnh giao'
 where doc_type = 'DELIVERY';
update wf.approval_steps set enabled = false where doc_type = 'DELIVERY' and role_code = 'KT_TP';
update wf.approval_steps set level_label = 'Giám đốc duyệt lệnh giao', enabled = true where doc_type = 'DELIVERY' and role_code = 'BGD';

-- Kế toán (kho, giá thành, trưởng) xem lệnh giao, đơn bán
insert into core.role_permissions (role_code, module, action)
select r, 'sales', 'view' from unnest(array['KT_KHO', 'KT_GT', 'KTT']) r
on conflict do nothing;

-- Menu "Đơn mua hàng" (nhóm Mua hàng): cùng bộ phận với Đề xuất mua hàng
insert into core.pages (key, path, label, grp, sort)
select 'don-mua', '/don-mua', 'Đơn mua hàng', 'Mua hàng', coalesce((select sort from core.pages where key = 'de-xuat'), 0) + 1
where not exists (select 1 from core.pages where key = 'don-mua');
insert into core.role_pages (role_code, page_key)
select role_code, 'don-mua' from core.role_pages where page_key = 'de-xuat'
on conflict do nothing;
insert into core.role_pages (role_code, page_key)
select r, 'don-mua' from unnest(array['THU_KHO']) r
on conflict do nothing;

-- flow_config: thêm danh sách vai trò nhận thông báo khi bước duyệt xong
create or replace function wf.flow_config(p_doc_type text)
returns jsonb language sql stable security definer set search_path = pg_catalog, public as $$
  select jsonb_build_object(
    'submit', jsonb_build_object('label', f.submit_label, 'role', f.submit_role, 'users', to_jsonb(f.submit_user_ids)),
    'steps', coalesce((select jsonb_agg(jsonb_build_object('seq', s.seq, 'label', s.level_label, 'role', s.role_code,
                                                           'users', to_jsonb(s.assignee_ids), 'sla_hours', s.sla_hours,
                                                           'warn_hours', s.warn_hours, 'min_amount', s.min_amount,
                                                           'flags', to_jsonb(s.when_flags), 'fallback', s.fallback_role,
                                                           'notify', to_jsonb(s.notify_roles)) order by s.seq)
                       from wf.approval_steps s where s.doc_type = f.doc_type and s.enabled), '[]'))
  from wf.approval_flows f where f.doc_type = p_doc_type
$$;

-- Ai gửi duyệt: PO – NV mua / TP Mua; lệnh giao – Kinh doanh / Kế toán SX
create or replace function wf.can_submit(p_doc_type text)
returns boolean language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce(case p_doc_type
    when 'PR'          then core.has_perm('purchase', 'create') or core.has_role('BGD') or core.has_perm('plan', 'create')
    when 'PO'          then core.has_role('MUA_NV') or core.has_role('MUA_TP')
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
    when 'DELIVERY'    then core.has_perm('sales', 'create') or core.has_role('KT_KHO')
    when 'STOCK_ADJ'   then core.has_role('KT_KHO') or core.has_role('ADMIN')
    when 'STOCK_OPEN'  then core.has_role('KT_KHO') or core.has_role('ADMIN')
  end, false)
$$;

-- Kiểm chứng từ trước khi gửi duyệt: thêm PO (đủ NCC, giá) và lệnh giao trực tiếp (đủ cuộn trong kho)
create or replace function wf.check_doc(p_doc_type text, p_doc_id uuid)
returns void language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare d inv.stock_docs; rq inv.requisitions; v_status text; v_need text; po purchase.purchase_orders; v_bad text;
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
  elsif p_doc_type = 'PO' then
    select * into po from purchase.purchase_orders where id = p_doc_id;
    if not found then raise exception 'Không tìm thấy đơn mua hàng'; end if;
    if po.supplier_id is null then raise exception 'Đơn mua %: chọn nhà cung cấp trước khi duyệt gửi TP Mua', po.po_no; end if;
    if not exists (select 1 from purchase.po_lines where po_id = p_doc_id) then raise exception 'Đơn mua % chưa có dòng hàng', po.po_no; end if;
    select string_agg(m.code, ', ' order by m.code) into v_bad from purchase.po_lines l join master.materials m on m.id = l.material_id
     where l.po_id = p_doc_id and l.unit_price is null;
    if v_bad is not null then raise exception 'Đơn mua %: % chưa có đơn giá (nhập giá trước khi gửi duyệt)', po.po_no, v_bad; end if;
  elsif p_doc_type = 'DELIVERY' then
    select status into v_status from sales.deliveries where id = p_doc_id;
    if not found then raise exception 'Không tìm thấy lệnh giao'; end if;
    if v_status <> 'DRAFT' then raise exception 'Lệnh giao đang ở trạng thái %', v_status; end if;
    -- lệnh giao trực tiếp: phải có dòng hàng và đủ cuộn QC Đạt trong kho (lệnh giao cũ theo đơn bán đã chọn bobin sẵn)
    if exists (select 1 from sales.deliveries where id = p_doc_id and so_id is null) then
      perform inv.fg_check_delivery(p_doc_id);
    end if;
  end if;
end $$;

-- Duyệt: báo thêm vai trò cấu hình ở bước (notify_roles); PO duyệt xong cập nhật giá, NCC ưu tiên;
-- lệnh giao duyệt xong báo Kế toán SX in phiếu xuất; tồn đầu kỳ ghi sổ xong gắn bobin BTP
create or replace function wf.act(p_request uuid, p_action text, p_comment text default null)
returns text language plpgsql security definer set search_path = wf, core, public as $$
declare r wf.approval_requests; f wf.approval_flows; v_step jsonb; v_next jsonb; v_hash text;
        v_ok boolean; v_behalf uuid; v_fallback boolean; v_comment text := p_comment; v_prev uuid[]; v_others uuid[];
        v_notify text[];
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
  -- Vai trò cần biết khi bước này duyệt xong (ví dụ PO: TP Mua duyệt → Kế toán)
  select coalesce(array_agg(x), '{}') into v_notify from jsonb_array_elements_text(coalesce(v_step -> 'notify', '[]')) x;
  if v_next is not null then
    update wf.approval_requests set current_seq = (v_next ->> 'seq')::smallint where id = p_request;
    perform wf.notify_users(array_remove(wf.step_actor_ids(v_next), r.submitted_by), 'Chờ duyệt: ' || r.doc_no, r.summary, '/duyet/' || p_request);
    if cardinality(v_notify) > 0 then
      perform wf.notify_users(array_remove(inv.role_users(v_notify), auth.uid()),
        format('%s: %s xong, chờ %s', r.doc_no, coalesce(v_step ->> 'label', 'bước duyệt'), coalesce(v_next ->> 'label', 'bước sau')),
        r.summary, '/duyet/' || p_request);
    end if;
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
      elsif r.doc_type = 'STOCK_OPEN' then
        perform inv.opening_carriers(r.doc_id);
      end if;
    elsif r.doc_type = 'EXTRA_ISSUE' then
      perform wf.notify_users(inv.role_users(array['THU_KHO']), 'Phiếu lĩnh bổ sung đã duyệt: ' || r.doc_no, r.summary, '/kho/cap-phat/' || r.doc_id);
    elsif r.doc_type = 'DELIVERY' then
      perform wf.notify_users(inv.role_users(array['KT_KHO', 'SX_TP', 'KHO_NV']), 'Lệnh giao đã duyệt: ' || r.doc_no,
        coalesce(r.summary || '. ', '') || 'In phiếu xuất cho người giữ kho thành phẩm, xuất xong Kế toán SX nhập "đã giao".',
        '/kho/xuat-ban/' || r.doc_id);
    elsif r.doc_type = 'PO' then
      perform purchase.po_approved(r.doc_id);
    end if;
  end if;
  perform set_config('bmt.wf_release', 'off', true);
  if cardinality(v_notify) > 0 then
    perform wf.notify_users(array_remove(inv.role_users(v_notify), auth.uid()), 'Đã duyệt: ' || r.doc_no, r.summary, '/duyet/' || p_request);
  end if;
  insert into wf.notifications (user_id, title, link) values (r.submitted_by, 'Đã duyệt: ' || r.doc_no, '/duyet/' || p_request);
  return 'APPROVED';
end $$;

-- ---------------------------------------------------------------------------
-- 3. Đơn mua hàng tự sinh từ MRP, lập từ đề xuất, sửa, hủy, duyệt xong
-- ---------------------------------------------------------------------------
-- Điều kiện mua của vật tư (NCC ưu tiên, giá, mã hàng NCC): cùng thứ tự chọn với plan.run_mrp
create or replace function purchase.material_terms(p_material uuid)
returns master.material_suppliers language sql stable security definer set search_path = pg_catalog, public as $$
  select ms.* from master.material_suppliers ms where ms.material_id = p_material
  order by ms.is_preferred desc, ms.unit_price is null, ms.supplier_id nulls last limit 1
$$;

-- Sinh đơn mua nháp từ kết quả MRP (một đơn cho mỗi NCC ưu tiên; vật tư chưa có NCC gom vào một đơn "chưa chọn NCC").
-- Gọi lại với cùng lần MRP chỉ lập phần còn thiếu (đã trừ dòng đơn mua chưa hủy của lần MRP đó).
create or replace function purchase.po_from_mrp(p_run uuid, p_adj uuid default null)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public
set "TimeZone" = 'Asia/Ho_Chi_Minh' as $$
declare r plan.mrp_runs; p plan.production_plans; v_adj text; g record; v_po uuid; v_no text; v_ids uuid[] := '{}'; v_nos text[] := '{}';
        v_lines int := 0; v_n int;
begin
  select * into r from plan.mrp_runs where id = p_run;
  if not found then raise exception 'Không tìm thấy lần chạy MRP'; end if;
  select * into p from plan.production_plans where id = r.plan_id;
  select adj_no into v_adj from plan.plan_adjustments where id = p_adj;
  create temp table if not exists _po_need (mrp_line_id uuid, material_id uuid, qty numeric, supplier_id uuid, unit_price numeric,
                                            item_code text, need_date date) on commit drop;
  delete from _po_need where true;
  insert into _po_need
  select ml.id, ml.material_id,
         ml.suggest_qty - coalesce((select sum(pl.qty) from purchase.po_lines pl join purchase.purchase_orders po on po.id = pl.po_id
                                    where pl.mrp_line_id = ml.id and po.status <> 'CANCELLED'), 0),
         t.supplier_id, t.unit_price, t.supplier_item_code, coalesce(ml.need_date, p.material_need_date)
  from plan.mrp_lines ml
  left join lateral (select * from purchase.material_terms(ml.material_id)) t on true
  where ml.run_id = p_run and ml.suggest_qty > 0;
  delete from _po_need where qty <= 0.0001;

  for g in select supplier_id, min(need_date) as need_date from _po_need group by supplier_id order by supplier_id nulls last loop
    v_no := core.next_no('PO');
    insert into purchase.purchase_orders (po_no, supplier_id, status, order_date, expected_date, note, source, plan_id, mrp_run_id, adjustment_id)
    values (v_no, g.supplier_id, 'DRAFT', (now() at time zone 'Asia/Ho_Chi_Minh')::date, g.need_date,
            'Theo kế hoạch ' || p.plan_no || coalesce(' · hiệu chỉnh ' || v_adj, '') || ' (MES tự sinh từ MRP)',
            'MRP', p.id, p_run, p_adj)
    returning id into v_po;
    insert into purchase.po_lines (po_id, line_no, material_id, supplier_item_code, qty, unit_price, expected_date, mrp_line_id, mrp_qty)
    select v_po, row_number() over (order by m.code), n.material_id, n.item_code, round(n.qty, 4), n.unit_price, n.need_date, n.mrp_line_id, round(n.qty, 4)
    from _po_need n join master.materials m on m.id = n.material_id
    where n.supplier_id is not distinct from g.supplier_id;
    get diagnostics v_n = row_count;
    v_lines := v_lines + v_n;
    v_ids := v_ids || v_po; v_nos := v_nos || v_no;
  end loop;

  if cardinality(v_ids) > 0 then
    perform wf.notify_users(inv.role_users(array['MUA_NV', 'MUA_TP']),
      'Đơn mua hàng chờ NV mua kiểm tra: ' || array_to_string(v_nos, ', '),
      format('MES tự lập %s đơn mua (%s dòng vật tư) theo %s%s. NV mua chọn NCC, giá, ngày về rồi bấm "Duyệt, gửi TP Mua".',
             cardinality(v_ids), v_lines, p.plan_no, coalesce(' · hiệu chỉnh ' || v_adj, '')),
      case when cardinality(v_ids) = 1 then '/don-mua/' || v_ids[1] else '/don-mua' end);
  end if;
  return jsonb_build_object('count', cardinality(v_ids), 'lines', v_lines, 'po_ids', to_jsonb(v_ids), 'po_nos', to_jsonb(v_nos));
end $$;

-- Chủ tịch HĐQT chốt kế hoạch tháng → MES tự sinh đơn mua hàng từ lần MRP cuối
create or replace function plan.auto_po_on_approve()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_run uuid;
begin
  if new.mode <> 'OFFICIAL' then return null; end if;
  select id into v_run from plan.mrp_runs where plan_id = new.id order by run_at desc limit 1;
  if v_run is null then return null; end if;
  -- kế hoạch cũ đã sinh đề xuất mua (PR) từ lần MRP này thì giữ cách cũ
  if exists (select 1 from purchase.purchase_requests where mrp_run_id = v_run and status <> 'CANCELLED') then return null; end if;
  perform purchase.po_from_mrp(v_run, null);
  return null;
end $$;
drop trigger if exists trg_auto_po on plan.production_plans;
create trigger trg_auto_po after update of status on plan.production_plans
  for each row when (new.status = 'APPROVED' and old.status is distinct from 'APPROVED')
  execute function plan.auto_po_on_approve();

-- NV mua / TP Mua sinh đơn mua cho phần MRP còn thiếu (ví dụ TP Mua chỉnh MRP sau khi kế hoạch đã duyệt)
create or replace function app.po_from_mrp(p_plan uuid)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare p plan.production_plans; v_run uuid; v jsonb;
begin
  if not (core.has_role('MUA_NV') or core.has_role('MUA_TP') or core.has_perm('plan', 'create')) then
    raise exception 'Chỉ NV mua, TP Mua hoặc TP SX sinh đơn mua từ MRP';
  end if;
  select * into p from plan.production_plans where id = p_plan;
  if not found then raise exception 'Không tìm thấy kế hoạch'; end if;
  if p.status <> 'APPROVED' or p.mode <> 'OFFICIAL' then raise exception 'Chỉ sinh đơn mua từ kế hoạch tháng đã được Chủ tịch HĐQT chốt'; end if;
  if p.mrp_stale then raise exception 'Dòng kế hoạch đã thay đổi sau lần chạy MRP: chạy lại MRP'; end if;
  select id into v_run from plan.mrp_runs where plan_id = p_plan order by run_at desc limit 1;
  if v_run is null then raise exception 'Kế hoạch chưa chạy MRP'; end if;
  if exists (select 1 from purchase.purchase_requests where mrp_run_id = v_run and status <> 'CANCELLED') then
    raise exception 'Lần MRP này đã sinh đề xuất mua (PR): lập đơn mua từ đề xuất đó';
  end if;
  v := purchase.po_from_mrp(v_run, null);
  if (v ->> 'count')::int = 0 then raise exception 'Không còn vật tư nào cần lập đơn mua từ lần MRP này'; end if;
  return v;
end $$;

-- Đề xuất mua đã duyệt (bổ sung, tích trữ, tối ưu…) → NV mua lập đơn mua (mỗi NCC một đơn) cho phần chưa lên đơn
create or replace function app.po_from_pr(p_pr uuid)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public
set "TimeZone" = 'Asia/Ho_Chi_Minh' as $$
declare pr purchase.purchase_requests; v_plan uuid; g record; v_po uuid; v_no text; v_ids uuid[] := '{}'; v_nos text[] := '{}';
begin
  if not (core.has_role('MUA_NV') or core.has_role('MUA_TP')) then raise exception 'Chỉ NV mua / TP Mua lập đơn mua hàng'; end if;
  select * into pr from purchase.purchase_requests where id = p_pr for update;
  if not found then raise exception 'Không tìm thấy đề xuất mua'; end if;
  if pr.status not in ('APPROVED', 'PARTIAL_PO') then raise exception 'Đề xuất % chưa được Giám đốc duyệt hoặc đã lên đơn đủ', pr.pr_no; end if;
  select plan_id into v_plan from plan.mrp_runs where id = pr.mrp_run_id;
  create temp table if not exists _pr_need (pr_line_id uuid, material_id uuid, qty numeric, supplier_id uuid, unit_price numeric,
                                            item_code text, need_date date) on commit drop;
  delete from _pr_need where true;
  insert into _pr_need
  select l.id, l.material_id, l.qty - l.ordered_qty, t.supplier_id, t.unit_price, t.supplier_item_code, coalesce(l.need_date, pr.need_date)
  from purchase.pr_lines l left join lateral (select * from purchase.material_terms(l.material_id)) t on true
  where l.pr_id = p_pr and l.qty - l.ordered_qty > 0.0001;
  if not exists (select 1 from _pr_need) then raise exception 'Đề xuất % đã lên đơn mua đủ số lượng', pr.pr_no; end if;
  for g in select supplier_id, min(need_date) as need_date from _pr_need group by supplier_id order by supplier_id nulls last loop
    v_no := core.next_no('PO');
    insert into purchase.purchase_orders (po_no, supplier_id, status, order_date, expected_date, note, source, pr_id, plan_id)
    values (v_no, g.supplier_id, 'DRAFT', (now() at time zone 'Asia/Ho_Chi_Minh')::date, g.need_date,
            'Theo đề xuất ' || pr.pr_no || coalesce(' · ' || nullif(trim(pr.note), ''), ''), 'PR', p_pr, v_plan)
    returning id into v_po;
    insert into purchase.po_lines (po_id, line_no, material_id, supplier_item_code, qty, unit_price, expected_date, pr_line_id)
    select v_po, row_number() over (order by m.code), n.material_id, n.item_code, round(n.qty, 4), n.unit_price, n.need_date, n.pr_line_id
    from _pr_need n join master.materials m on m.id = n.material_id where n.supplier_id is not distinct from g.supplier_id;
    v_ids := v_ids || v_po; v_nos := v_nos || v_no;
  end loop;
  update purchase.pr_lines l set ordered_qty = l.ordered_qty + n.qty from _pr_need n where n.pr_line_id = l.id;
  update purchase.purchase_requests set status = case when exists (select 1 from purchase.pr_lines x where x.pr_id = p_pr and x.qty - x.ordered_qty > 0.0001)
                                                      then 'PARTIAL_PO' else 'CLOSED' end where id = p_pr;
  return jsonb_build_object('count', cardinality(v_ids), 'po_ids', to_jsonb(v_ids), 'po_nos', to_jsonb(v_nos));
end $$;

-- Ai sửa đơn mua: nháp – NV mua / TP Mua; chờ duyệt – người đang giữ bước duyệt (TP Mua, Giám đốc), ghi lịch sử duyệt
create or replace function purchase.po_edit_request(p_po uuid)
returns wf.approval_requests language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_status text; r wf.approval_requests;
begin
  select status into v_status from purchase.purchase_orders where id = p_po;
  if v_status is null then raise exception 'Không tìm thấy đơn mua hàng'; end if;
  if v_status = 'DRAFT' then
    if not (core.has_role('MUA_NV') or core.has_role('MUA_TP')) then raise exception 'Chỉ NV mua / TP Mua sửa đơn mua nháp'; end if;
    return r;
  elsif v_status = 'PENDING_APPROVAL' then
    return wf.review_request('PO', p_po);
  end if;
  raise exception 'Đơn mua đã duyệt hoặc đã đóng: không sửa được';
end $$;

create or replace function app.po_save_header(p_po uuid, p_supplier uuid, p_expected date, p_terms text, p_note text, p_is_import boolean default false)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
declare r wf.approval_requests; po purchase.purchase_orders; v_old text; v_new text;
begin
  r := purchase.po_edit_request(p_po);
  select * into po from purchase.purchase_orders where id = p_po for update;
  if p_supplier is not null and not exists (select 1 from core.partners where id = p_supplier and is_supplier and active) then
    raise exception 'Nhà cung cấp không hợp lệ';
  end if;
  update purchase.purchase_orders set supplier_id = p_supplier, expected_date = p_expected,
         payment_terms = nullif(trim(coalesce(p_terms, '')), ''), note = nullif(trim(coalesce(p_note, '')), ''), is_import = coalesce(p_is_import, false)
   where id = p_po;
  if r.id is not null then
    select name into v_old from core.partners where id = po.supplier_id;
    select name into v_new from core.partners where id = p_supplier;
    perform wf.log_review_edit(r.id, concat_ws('; ',
      case when po.supplier_id is distinct from p_supplier then format('NCC %s → %s', coalesce(v_old, 'chưa chọn'), coalesce(v_new, 'chưa chọn')) end,
      case when po.expected_date is distinct from p_expected then format('ngày về %s → %s', coalesce(to_char(po.expected_date, 'DD/MM'), '—'), coalesce(to_char(p_expected, 'DD/MM'), '—')) end,
      case when po.payment_terms is distinct from nullif(trim(coalesce(p_terms, '')), '') then 'điều khoản thanh toán' end,
      case when po.note is distinct from nullif(trim(coalesce(p_note, '')), '') then 'ghi chú' end));
  end if;
end $$;

-- Thêm (p_line null) hoặc sửa dòng đơn mua
create or replace function app.po_save_line(p_po uuid, p_line uuid, p_material_code text, p_qty numeric, p_price numeric,
                                            p_date date default null, p_note text default null)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
declare r wf.approval_requests; l purchase.po_lines; m master.materials; v_desc text; v_line int;
begin
  r := purchase.po_edit_request(p_po);
  if coalesce(p_qty, 0) <= 0 then raise exception 'Số lượng phải lớn hơn 0'; end if;
  if p_price is not null and p_price < 0 then raise exception 'Đơn giá không được âm'; end if;
  if p_line is not null then
    select * into l from purchase.po_lines where id = p_line and po_id = p_po for update;
    if not found then raise exception 'Dòng không thuộc đơn mua này'; end if;
    select * into m from master.materials where id = l.material_id;
    update purchase.po_lines set qty = p_qty, unit_price = p_price, expected_date = coalesce(p_date, expected_date),
           note = nullif(trim(coalesce(p_note, '')), '') where id = p_line;
    if l.pr_line_id is not null then
      update purchase.pr_lines set ordered_qty = greatest(ordered_qty + p_qty - l.qty, 0) where id = l.pr_line_id;
    end if;
    v_desc := concat_ws(', ',
      case when l.qty <> p_qty then format('%s: %s → %s %s', m.code, wf.fmt_qty(l.qty), wf.fmt_qty(p_qty), m.uom) end,
      case when l.unit_price is distinct from p_price then format('%s: đơn giá %s → %s', m.code, coalesce(wf.fmt_qty(l.unit_price), '—'), coalesce(wf.fmt_qty(p_price), '—')) end,
      case when p_date is not null and l.expected_date is distinct from p_date then format('%s: ngày về %s', m.code, to_char(p_date, 'DD/MM')) end);
  else
    select * into m from master.materials where code = upper(trim(split_part(coalesce(p_material_code, ''), ' · ', 1))) and not is_scrap;
    if not found then raise exception 'Không có vật tư %', p_material_code; end if;
    if exists (select 1 from purchase.po_lines where po_id = p_po and material_id = m.id) then
      raise exception '% đã có trong đơn: sửa số lượng ở dòng đó', m.code;
    end if;
    select coalesce(max(line_no), 0) + 1 into v_line from purchase.po_lines where po_id = p_po;
    insert into purchase.po_lines (po_id, line_no, material_id, supplier_item_code, qty, unit_price, expected_date, note)
    values (p_po, v_line, m.id, (purchase.material_terms(m.id)).supplier_item_code, p_qty, p_price,
            coalesce(p_date, (select expected_date from purchase.purchase_orders where id = p_po)), nullif(trim(coalesce(p_note, '')), ''));
    v_desc := format('thêm %s: %s %s', m.code, wf.fmt_qty(p_qty), m.uom);
  end if;
  if r.id is not null and coalesce(v_desc, '') <> '' then perform wf.log_review_edit(r.id, v_desc); end if;
end $$;

create or replace function app.po_delete_line(p_line uuid)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
declare l purchase.po_lines; r wf.approval_requests; m master.materials;
begin
  select * into l from purchase.po_lines where id = p_line;
  if not found then raise exception 'Không tìm thấy dòng đơn mua'; end if;
  r := purchase.po_edit_request(l.po_id);
  if not exists (select 1 from purchase.po_lines where po_id = l.po_id and id <> p_line) then
    raise exception 'Đơn mua phải còn ít nhất một dòng: không mua nữa thì hủy đơn';
  end if;
  select * into m from master.materials where id = l.material_id;
  delete from purchase.po_lines where id = p_line;
  if l.pr_line_id is not null then
    update purchase.pr_lines set ordered_qty = greatest(ordered_qty - l.qty, 0) where id = l.pr_line_id;
    update purchase.purchase_requests pr set status = 'PARTIAL_PO' where pr.id = (select pr_id from purchase.pr_lines where id = l.pr_line_id) and pr.status = 'CLOSED';
  end if;
  if r.id is not null then perform wf.log_review_edit(r.id, format('bỏ %s: %s %s', m.code, wf.fmt_qty(l.qty), m.uom)); end if;
end $$;

-- Chuyển các dòng của đơn nháp sang NCC khác (MES gom vào đơn nháp cùng nguồn của NCC đó, chưa có thì lập đơn mới)
create or replace function app.po_move_lines(p_po uuid, p_lines uuid[], p_supplier uuid)
returns uuid language plpgsql security definer set search_path = pg_catalog, public
set "TimeZone" = 'Asia/Ho_Chi_Minh' as $$
declare po purchase.purchase_orders; v_to uuid; v_line int;
begin
  if not (core.has_role('MUA_NV') or core.has_role('MUA_TP')) then raise exception 'Chỉ NV mua / TP Mua chia đơn mua'; end if;
  select * into po from purchase.purchase_orders where id = p_po for update;
  if not found or po.status <> 'DRAFT' then raise exception 'Chỉ chia được đơn mua đang nháp'; end if;
  if p_supplier is null or not exists (select 1 from core.partners where id = p_supplier and is_supplier and active) then
    raise exception 'Chọn nhà cung cấp nhận các dòng';
  end if;
  if coalesce(cardinality(p_lines), 0) = 0 then raise exception 'Chọn dòng cần chuyển'; end if;
  if (select count(*) from purchase.po_lines where po_id = p_po and id = any(p_lines)) <> cardinality(p_lines) then
    raise exception 'Có dòng không thuộc đơn %', po.po_no;
  end if;
  if po.supplier_id is not distinct from p_supplier then raise exception 'Các dòng đã thuộc NCC này'; end if;
  select id into v_to from purchase.purchase_orders x
   where x.status = 'DRAFT' and x.supplier_id = p_supplier and x.id <> p_po and x.source = po.source
     and x.plan_id is not distinct from po.plan_id and x.mrp_run_id is not distinct from po.mrp_run_id
     and x.pr_id is not distinct from po.pr_id and x.adjustment_id is not distinct from po.adjustment_id
   order by x.created_at limit 1;
  if v_to is null then
    insert into purchase.purchase_orders (po_no, supplier_id, status, order_date, expected_date, payment_terms, note, source, plan_id, mrp_run_id, adjustment_id, pr_id)
    values (core.next_no('PO'), p_supplier, 'DRAFT', (now() at time zone 'Asia/Ho_Chi_Minh')::date, po.expected_date, po.payment_terms, po.note,
            po.source, po.plan_id, po.mrp_run_id, po.adjustment_id, po.pr_id)
    returning id into v_to;
  end if;
  select coalesce(max(line_no), 0) into v_line from purchase.po_lines where po_id = v_to;
  update purchase.po_lines l set po_id = v_to, line_no = v_line + x.rn,
         supplier_item_code = coalesce((select ms.supplier_item_code from master.material_suppliers ms
                                         where ms.material_id = l.material_id and ms.supplier_id = p_supplier limit 1), l.supplier_item_code),
         unit_price = coalesce((select ms.unit_price from master.material_suppliers ms
                                 where ms.material_id = l.material_id and ms.supplier_id = p_supplier limit 1), l.unit_price)
    from (select id, row_number() over (order by line_no) as rn from purchase.po_lines where id = any(p_lines)) x
   where x.id = l.id;
  -- đơn cũ hết dòng thì hủy
  if not exists (select 1 from purchase.po_lines where po_id = p_po) then
    update purchase.purchase_orders set status = 'CANCELLED', cancel_reason = 'Đã chuyển hết dòng sang đơn khác' where id = p_po;
  end if;
  return v_to;
end $$;

create or replace function app.po_cancel(p_po uuid, p_reason text)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
declare po purchase.purchase_orders;
begin
  if not (core.has_role('MUA_NV') or core.has_role('MUA_TP')) then raise exception 'Chỉ NV mua / TP Mua hủy đơn mua'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do hủy đơn mua'; end if;
  select * into po from purchase.purchase_orders where id = p_po for update;
  if not found then raise exception 'Không tìm thấy đơn mua hàng'; end if;
  if po.status <> 'DRAFT' then raise exception 'Chỉ hủy được đơn mua nháp (đơn đang chờ duyệt: người duyệt trả lại trước)'; end if;
  update purchase.pr_lines pl set ordered_qty = greatest(pl.ordered_qty - l.qty, 0)
    from purchase.po_lines l where l.po_id = p_po and l.pr_line_id = pl.id;
  update purchase.purchase_requests pr set status = 'APPROVED'
   where pr.id = po.pr_id and pr.status in ('PARTIAL_PO', 'CLOSED')
     and not exists (select 1 from purchase.pr_lines x where x.pr_id = pr.id and x.ordered_qty > 0);
  update purchase.purchase_requests pr set status = 'PARTIAL_PO'
   where pr.id = po.pr_id and pr.status = 'CLOSED';
  update purchase.purchase_orders set status = 'CANCELLED', cancel_reason = trim(p_reason) where id = p_po;
end $$;

-- NV mua thêm nhà cung cấp mới ngay trên đơn mua
create or replace function app.save_supplier(p_name text, p_tax_code text default null, p_contact text default null, p_address text default null)
returns uuid language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid; v_code text; v_n int;
begin
  if not (core.has_role('MUA_NV') or core.has_role('MUA_TP')) then raise exception 'Chỉ NV mua / TP Mua thêm nhà cung cấp'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Nhập tên nhà cung cấp'; end if;
  select id into v_id from core.partners where lower(name) = lower(trim(p_name)) or (nullif(trim(coalesce(p_tax_code, '')), '') is not null and tax_code = trim(p_tax_code)) limit 1;
  if v_id is not null then
    update core.partners set is_supplier = true, active = true,
           tax_code = coalesce(nullif(trim(coalesce(p_tax_code, '')), ''), tax_code),
           contact = coalesce(nullif(trim(coalesce(p_contact, '')), ''), contact),
           address = coalesce(nullif(trim(coalesce(p_address, '')), ''), address)
     where id = v_id;
    return v_id;
  end if;
  select count(*) + 1 into v_n from core.partners where code like 'NCC-%';
  v_code := 'NCC-' || lpad(v_n::text, 3, '0');
  while exists (select 1 from core.partners where code = v_code) loop v_n := v_n + 1; v_code := 'NCC-' || lpad(v_n::text, 3, '0'); end loop;
  insert into core.partners (code, name, tax_code, is_supplier, is_customer, partner_type, contact, address, active)
  values (v_code, trim(p_name), nullif(trim(coalesce(p_tax_code, '')), ''), true, false, 'SUPPLIER',
          nullif(trim(coalesce(p_contact, '')), ''), nullif(trim(coalesce(p_address, '')), ''), true)
  returning id into v_id;
  return v_id;
end $$;

-- Đơn mua được Giám đốc duyệt: ghi giá và NCC vào điều kiện mua của vật tư (MRP lần sau dùng giá này), báo mua hàng và kho
create or replace function purchase.po_approved(p_po uuid)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
declare po purchase.purchase_orders; l record; v_sup text; v_list text;
begin
  select * into po from purchase.purchase_orders where id = p_po;
  select name into v_sup from core.partners where id = po.supplier_id;
  for l in select pl.*, m.code from purchase.po_lines pl join master.materials m on m.id = pl.material_id where pl.po_id = p_po loop
    if po.supplier_id is null or l.unit_price is null then continue; end if;
    update master.material_suppliers set unit_price = l.unit_price, supplier_item_code = coalesce(l.supplier_item_code, supplier_item_code), valid_from = po.order_date
     where material_id = l.material_id and supplier_id = po.supplier_id;
    if not found then
      update master.material_suppliers set supplier_id = po.supplier_id, unit_price = l.unit_price,
             supplier_item_code = coalesce(l.supplier_item_code, supplier_item_code), valid_from = po.order_date
       where id = (select id from master.material_suppliers where material_id = l.material_id and supplier_id is null order by is_preferred desc limit 1);
      if not found then
        insert into master.material_suppliers (material_id, supplier_id, supplier_item_code, unit_price, is_preferred, valid_from)
        values (l.material_id, po.supplier_id, l.supplier_item_code, l.unit_price,
                not exists (select 1 from master.material_suppliers x where x.material_id = l.material_id and x.is_preferred), po.order_date);
      end if;
    end if;
    insert into master.price_history (material_id, supplier_id, price, source, noted_by)
    values (l.material_id, po.supplier_id, l.unit_price, 'PO ' || po.po_no, auth.uid());
  end loop;
  select string_agg(m.code || ' ' || wf.fmt_qty(pl.qty) || ' ' || m.uom, ', ' order by pl.line_no) into v_list
    from purchase.po_lines pl join master.materials m on m.id = pl.material_id where pl.po_id = p_po;
  perform wf.notify_users(inv.role_users(array['MUA_NV', 'MUA_TP']), 'Đơn mua đã duyệt, gửi NCC: ' || po.po_no,
    coalesce(v_sup, '') || ' · ' || left(coalesce(v_list, ''), 400), '/don-mua/' || p_po);
  perform wf.notify_users(inv.role_users(array['THU_KHO', 'KT_KHO']), 'Hàng sắp về theo ' || po.po_no,
    coalesce(v_sup, '') || coalesce(' · dự kiến ' || to_char(po.expected_date, 'DD/MM'), '') || ' · ' || left(coalesce(v_list, ''), 400), '/kho/nhan-hang');
end $$;

-- Kế hoạch cũ: không sinh PR khi đã có đơn mua tự sinh từ lần MRP đó
create or replace function plan.create_pr_from_mrp(p_run uuid)
returns uuid language plpgsql security definer set search_path = plan, purchase, public as $$
declare v_pr uuid; p plan.production_plans;
begin
  if not (core.has_perm('plan', 'create') or core.has_perm('purchase', 'create')) then raise exception 'Không có quyền tạo PR'; end if;
  select pp.* into p from plan.mrp_runs r join plan.production_plans pp on pp.id = r.plan_id where r.id = p_run;
  if p.status <> 'APPROVED' or p.mode <> 'OFFICIAL' then
    raise exception 'Chỉ sinh PR từ kế hoạch chính thức đã được phê duyệt';
  end if;
  if p.mrp_stale then raise exception 'Dòng kế hoạch đã thay đổi sau lần chạy MRP: chạy lại MRP'; end if;
  if exists (select 1 from purchase.purchase_orders po where po.mrp_run_id = p_run and po.status <> 'CANCELLED') then
    raise exception 'MES đã tự sinh đơn mua hàng từ kết quả MRP này (xem Đơn mua hàng)';
  end if;
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

-- MRP: đơn mua nháp / chờ duyệt cũng tính vào "đã đề xuất" (chạy lại MRP không đề xuất trùng)
do $$
declare d text; i int; j int;
begin
  d := replace(pg_get_functiondef('plan.run_mrp(uuid, jsonb)'::regprocedure), E'\r', '');
  i := position('), requested as (' in d);
  j := position('), calc as (' in d);
  if i = 0 or j = 0 or j < i then raise exception 'plan.run_mrp: không tìm thấy đoạn requested để sửa'; end if;
  d := substr(d, 1, i - 1) || $x$), requested as (   -- đề xuất mua chưa lên đơn + đơn mua nháp / chờ duyệt (tránh đề xuất trùng khi chạy lại)
    select q.material_id, sum(q.qty) as qty from (
      select pl.material_id, greatest(pl.qty - pl.ordered_qty, 0) as qty
      from purchase.pr_lines pl join purchase.purchase_requests pr on pr.id = pl.pr_id
      where pr.status in ('DRAFT', 'PENDING_APPROVAL', 'APPROVED', 'PARTIAL_PO')
      union all
      select pol.material_id, pol.qty
      from purchase.po_lines pol join purchase.purchase_orders po on po.id = pol.po_id
      where po.status in ('DRAFT', 'PENDING_APPROVAL')
    ) q group by q.material_id
  $x$ || substr(d, j);
  execute d;
end $$;

-- Hiệu chỉnh kế hoạch tháng: giảm đề xuất mua (PR) và đơn mua (PO) chưa duyệt của kế hoạch khi tồn dự kiến dư.
-- Đơn mua / đề xuất đã duyệt giữ nguyên. Mua thêm do trigger plan.apply_adjustment sinh đơn mua.
create or replace function plan.revise_mrp(p_adj uuid)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public
set "TimeZone" = 'Asia/Ho_Chi_Minh' as $$
declare a plan.plan_adjustments; v_plan uuid; v_old uuid; v_reserve jsonb; v_r1 uuid; v_fin uuid; v_pb jsonb;
        m record; pl record; d record; v_left numeric; v_cut numeric; v_pm numeric; v_red jsonb := '[]'; v_rows jsonb;
        v_note text; v_req uuid; v_hash text; v_buy int; v_table text; v_link text; v_extra uuid[];
begin
  select * into a from plan.plan_adjustments where id = p_adj;
  v_plan := a.plan_id;
  select r.id, coalesce(r.snapshot -> 'reserve', '{}') into v_old, v_reserve
    from plan.mrp_runs r where r.plan_id = v_plan order by r.run_at desc limit 1;

  -- Dòng mua chưa duyệt của kế hoạch: đề xuất mua chưa lên đơn, đơn mua nháp / chờ duyệt chưa nhận hàng
  create temp table if not exists _pend (doc_type text, doc_id uuid, doc_no text, status text, line_id uuid, material_id uuid,
                                         qty numeric, created_at timestamptz, pr_line_id uuid) on commit drop;
  delete from _pend where true;
  insert into _pend
  select 'PR', r.id, r.pr_no, r.status, l.id, l.material_id, l.qty, r.created_at, null
  from purchase.pr_lines l join purchase.purchase_requests r on r.id = l.pr_id join plan.mrp_runs mr on mr.id = r.mrp_run_id and mr.plan_id = v_plan
  where r.status in ('DRAFT', 'PENDING_APPROVAL') and l.ordered_qty = 0
  union all
  select 'PO', po.id, po.po_no, po.status, l.id, l.material_id, l.qty, po.created_at, l.pr_line_id
  from purchase.po_lines l join purchase.purchase_orders po on po.id = l.po_id
  where po.plan_id = v_plan and po.status in ('DRAFT', 'PENDING_APPROVAL') and l.received_qty = 0;
  select coalesce(jsonb_object_agg(material_id::text, q), '{}') into v_pb
    from (select material_id, sum(qty) as q from _pend group by material_id) x;

  perform set_config('bmt.chair_edit', 'on', true);
  v_r1 := plan.run_mrp(v_plan, coalesce(v_reserve, '{}'));
  perform plan.carry_mrp_adjust(v_old, v_r1);

  for m in select x.material_id, mt.code, mt.uom, ml.projected, ml.pack_multiple
           from (select distinct material_id from _pend) x
           join master.materials mt on mt.id = x.material_id
           left join plan.mrp_lines ml on ml.run_id = v_r1 and ml.material_id = x.material_id
           order by mt.code loop
    -- không còn nhu cầu (không có dòng MRP): toàn bộ phần chưa duyệt là thừa
    v_left := coalesce(m.projected, 1e15);
    continue when v_left <= 0;
    v_pm := nullif(m.pack_multiple, 0);
    for pl in select * from _pend where material_id = m.material_id order by created_at desc, qty desc loop
      exit when v_left <= 0;
      if v_left >= pl.qty then v_cut := pl.qty;
      else v_cut := case when v_pm is null then round(v_left, 3) else floor(v_left / v_pm) * v_pm end;
      end if;
      exit when v_cut <= 0;
      if pl.doc_type = 'PR' then
        if v_cut >= pl.qty then delete from purchase.pr_lines where id = pl.line_id;
        else update purchase.pr_lines set qty = qty - v_cut,
                    note = left(coalesce(note || ' · ', '') || 'Giảm ' || wf.fmt_qty(v_cut) || ' theo ' || a.adj_no, 500)
              where id = pl.line_id;
        end if;
      else
        if v_cut >= pl.qty then delete from purchase.po_lines where id = pl.line_id;
        else update purchase.po_lines set qty = qty - v_cut,
                    note = left(coalesce(note || ' · ', '') || 'Giảm ' || wf.fmt_qty(v_cut) || ' theo ' || a.adj_no, 500)
              where id = pl.line_id;
        end if;
        if pl.pr_line_id is not null then
          update purchase.pr_lines set ordered_qty = greatest(ordered_qty - v_cut, 0) where id = pl.pr_line_id;
        end if;
      end if;
      v_left := v_left - v_cut;
      v_red := v_red || jsonb_build_array(jsonb_build_object('doc_type', pl.doc_type, 'pr_id', pl.doc_id, 'pr_no', pl.doc_no, 'status', pl.status,
                 'material_code', m.code, 'uom', m.uom, 'old', pl.qty, 'new', pl.qty - v_cut));
    end loop;
  end loop;

  -- Chứng từ bị giảm: ghi lịch sử duyệt, hủy nếu hết dòng, báo người lập, người đang duyệt (đơn mua: cả NV mua, TP Mua)
  for d in select distinct e ->> 'doc_type' as doc_type, (e ->> 'pr_id')::uuid as doc_id, e ->> 'pr_no' as doc_no
           from jsonb_array_elements(v_red) e loop
    select string_agg(e ->> 'material_code' || ' ' || wf.fmt_qty((e ->> 'old')::numeric) || ' → ' || wf.fmt_qty((e ->> 'new')::numeric)
                      || ' ' || coalesce(e ->> 'uom', ''), '; ')
      into v_note from jsonb_array_elements(v_red) e where (e ->> 'pr_id')::uuid = d.doc_id;
    select id into v_req from wf.approval_requests where doc_type = d.doc_type and doc_id = d.doc_id and status = 'PENDING'
     order by submitted_at desc limit 1;
    v_table := case d.doc_type when 'PR' then 'purchase.purchase_requests' else 'purchase.purchase_orders' end;
    v_link := case d.doc_type when 'PR' then '/de-xuat/' else '/don-mua/' end || d.doc_id;
    if (d.doc_type = 'PR' and not exists (select 1 from purchase.pr_lines where pr_id = d.doc_id))
       or (d.doc_type = 'PO' and not exists (select 1 from purchase.po_lines where po_id = d.doc_id)) then
      if v_req is not null then
        update wf.approval_requests set status = 'CANCELLED', finished_at = now() where id = v_req;
        insert into wf.approval_actions (request_id, seq, action, comment, data_hash)
        select v_req, coalesce(current_seq, 0), 'COMMENT', left('[Hủy theo hiệu chỉnh kế hoạch ' || a.adj_no || '] không còn cần mua: ' || v_note, 2000), data_hash
        from wf.approval_requests where id = v_req;
      end if;
      if d.doc_type = 'PR' then
        update purchase.purchase_requests set status = 'CANCELLED',
               note = left(coalesce(note || ' · ', '') || 'Hủy theo hiệu chỉnh kế hoạch ' || a.adj_no, 500) where id = d.doc_id;
      else
        update purchase.purchase_orders set status = 'CANCELLED', cancel_reason = 'Hủy theo hiệu chỉnh kế hoạch ' || a.adj_no where id = d.doc_id;
      end if;
      v_note := 'Đã hủy (không còn cần mua): ' || v_note;
    else
      if v_req is not null then
        v_hash := wf.doc_hash(v_table, d.doc_id);
        insert into wf.approval_actions (request_id, seq, action, comment, data_hash)
        select v_req, coalesce(current_seq, 0), 'COMMENT', left('[Giảm theo hiệu chỉnh kế hoạch ' || a.adj_no || '] ' || v_note, 2000), v_hash
        from wf.approval_requests where id = v_req;
        update wf.approval_requests set data_hash = v_hash where id = v_req;
      end if;
      v_note := 'Đã giảm: ' || v_note;
    end if;
    v_extra := case when d.doc_type = 'PO' then inv.role_users(array['MUA_NV', 'MUA_TP']) else '{}'::uuid[] end;
    perform wf.notify_users(array_remove(
        array[(case d.doc_type when 'PR' then (select created_by from purchase.purchase_requests where id = d.doc_id)
                               else (select created_by from purchase.purchase_orders where id = d.doc_id) end)]
        || coalesce((select array_agg(distinct u) from wf.approval_requests r
                       cross join lateral jsonb_array_elements(r.flow_snapshot -> 'steps') s
                       cross join lateral unnest(wf.step_actor_ids(s)) u
                      where r.id = v_req and r.status = 'PENDING' and (s ->> 'seq')::int = r.current_seq), '{}')
        || coalesce((select array[submitted_by] from wf.approval_requests where id = v_req), '{}')
        || v_extra, null),
      case d.doc_type when 'PR' then 'Đề xuất mua ' else 'Đơn mua ' end || d.doc_no || ' giảm theo hiệu chỉnh kế hoạch ' || a.adj_no,
      left(v_note, 500), v_link);
  end loop;

  if jsonb_array_length(v_red) > 0 then
    v_fin := plan.run_mrp(v_plan, coalesce(v_reserve, '{}'));
    perform plan.carry_mrp_adjust(v_r1, v_fin);
  else
    v_fin := v_r1;
  end if;
  perform set_config('bmt.chair_edit', 'off', true);

  with o as (select material_id, total_issue + reserve as need from plan.mrp_lines where run_id = v_old),
  n as (select * from plan.mrp_lines where run_id = v_fin),
  prs as (select r.id, r.status from purchase.purchase_requests r join plan.mrp_runs mr on mr.id = r.mrp_run_id and mr.plan_id = v_plan),
  pos as (select po.id, po.status from purchase.purchase_orders po where po.plan_id = v_plan),
  ap as (select material_id, sum(q) as q from (
           select l.material_id, l.qty as q from purchase.pr_lines l join prs on prs.id = l.pr_id
            where prs.status in ('APPROVED', 'PARTIAL_PO', 'CLOSED')
           union all
           select l.material_id, l.qty from purchase.po_lines l join pos on pos.id = l.po_id
            where pos.status in ('APPROVED', 'SENT', 'PARTIAL_RECEIVED', 'RECEIVED', 'CLOSED') and l.pr_line_id is null) x
         group by material_id),
  pa as (select material_id, sum(q) as q from (
           select l.material_id, l.qty as q from purchase.pr_lines l join prs on prs.id = l.pr_id
            where prs.status in ('DRAFT', 'PENDING_APPROVAL') and l.ordered_qty = 0
           union all
           select l.material_id, l.qty from purchase.po_lines l join pos on pos.id = l.po_id
            where pos.status in ('DRAFT', 'PENDING_APPROVAL') and l.received_qty = 0) x
         group by material_id),
  pb as (select key::uuid as material_id, value::numeric as q from jsonb_each_text(v_pb)),
  mats as (select material_id from o union select material_id from n union select material_id from pb),
  rw as (
    select mt.code, mt.name, mt.uom, coalesce(o.need, 0) as old_need, coalesce(n.total_issue + n.reserve, 0) as new_need,
           coalesce(n.available, 0) as available, coalesce(n.incoming, 0) as incoming, coalesce(ap.q, 0) as approved,
           coalesce(pb.q, 0) as pending_before, coalesce(pa.q, 0) as pending_after, coalesce(n.suggest_qty, 0) as buy_more,
           coalesce(n.projected + n.suggest_qty, coalesce(n.available, 0) + coalesce(n.incoming, 0)) as projected_after,
           n.unit_price
    from mats join master.materials mt on mt.id = mats.material_id
    left join o on o.material_id = mats.material_id left join n on n.material_id = mats.material_id
    left join ap on ap.material_id = mats.material_id left join pa on pa.material_id = mats.material_id
    left join pb on pb.material_id = mats.material_id
  )
  select jsonb_agg(jsonb_build_object(
           'code', code, 'name', name, 'uom', uom, 'old_need', round(old_need, 3), 'new_need', round(new_need, 3),
           'delta', round(new_need - old_need, 3), 'available', round(available, 3), 'incoming', round(incoming, 3),
           'approved', round(approved, 3), 'pending_before', round(pending_before, 3), 'pending_after', round(pending_after, 3),
           'buy_more', round(buy_more, 3), 'projected_after', round(projected_after, 3),
           'amount', case when unit_price is not null then round(buy_more * unit_price, 0) end,
           'action', case when buy_more > 0 then 'BUY'
                          when pending_after < pending_before then 'CUT'
                          when new_need < old_need and pending_after > 0 and projected_after > 0 then 'PACK'
                          when new_need < old_need and approved > 0 then 'KEEP'
                          when new_need < old_need then 'LESS'
                          when new_need > old_need then 'ENOUGH'
                          else 'SAME' end)
         order by case when buy_more > 0 then 0 when pending_after < pending_before then 1 when new_need <> old_need then 2 else 3 end, code)
    into v_rows
  from rw
  where round(new_need - old_need, 3) <> 0 or buy_more > 0 or pending_after <> pending_before;

  select count(*) into v_buy from plan.mrp_lines where run_id = v_fin and suggest_qty > 0;
  return jsonb_build_object('run_id', v_fin, 'old_run_id', v_old, 'rows', coalesce(v_rows, '[]'), 'reductions', v_red,
                            'buy_count', v_buy, 'cut_count', jsonb_array_length(v_red), 'at', now());
end $$;

-- Chủ tịch duyệt hiệu chỉnh: áp dòng, MRP hiệu chỉnh, giảm đơn/đề xuất chưa duyệt, tự sinh đơn mua phần mua thêm
create or replace function plan.apply_adjustment()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare pp plan.production_plans; v jsonb; v_po jsonb; v_msg text;
begin
  if new.status <> 'APPROVED' or old.status = 'APPROVED' then return new; end if;
  perform plan.check_adjustment(new.id);
  select * into pp from plan.production_plans where id = new.plan_id;
  perform plan.apply_adjustment_lines(new.id);
  v := plan.revise_mrp(new.id);
  if (v ->> 'buy_count')::int > 0 then
    v_po := purchase.po_from_mrp((v ->> 'run_id')::uuid, new.id);
    v := v || jsonb_build_object('po', v_po);
  end if;
  new.applied_at := now();
  new.mrp_run_id := (v ->> 'run_id')::uuid;
  new.mrp_result := v;
  v_msg := pp.plan_no || ' · ' || new.reason || '. MES đã chạy MRP hiệu chỉnh'
    || case when (v ->> 'cut_count')::int > 0 then ', giảm ' || (v ->> 'cut_count') || ' dòng mua chưa duyệt' else '' end
    || case when coalesce((v_po ->> 'count')::int, 0) > 0
            then ', ' || (v ->> 'buy_count') || ' vật tư cần mua thêm: đã lập đơn mua ' || (select string_agg(x, ', ') from jsonb_array_elements_text(v_po -> 'po_nos') x)
                 || ' chờ NV mua kiểm tra'
            when (v ->> 'buy_count')::int > 0 then ', ' || (v ->> 'buy_count') || ' vật tư cần mua thêm (đã có đơn mua đang chờ)'
            else ', không phải mua thêm' end
    || '. Vật tư Giám đốc đã duyệt mua giữ nguyên. TP SX xếp lại lịch máy.';
  perform app.kh_log('Hiệu chỉnh kế hoạch tháng', new.adj_no, null, pp.plan_no, new.reason);
  perform wf.notify_users(inv.role_users(array['SX_TP', 'SX_KH', 'BGD', 'MUA_TP', 'KT_TP']), 'Kế hoạch tháng đã hiệu chỉnh: ' || new.adj_no,
    left(v_msg, 500), '/ke-hoach/dieu-chinh/' || new.id);
  return new;
end $$;

-- Danh sách đơn mua, dòng đơn mua (giá chỉ hiện với người được xem giá)
create or replace view app.v_pos with (security_invoker = true) as
select po.id, po.po_no, po.status, po.source,
       case po.source when 'MRP' then 'Tự sinh từ MRP' when 'PR' then 'Từ đề xuất mua' else 'Lập tay' end as source_label,
       po.supplier_id, sp.name as supplier_name, sp.tax_code as supplier_tax_code,
       po.order_date, po.expected_date, po.payment_terms, po.note, po.is_import, po.cancel_reason,
       po.plan_id, pp.plan_no, po.pr_id, pr.pr_no, po.adjustment_id, ad.adj_no, po.mrp_run_id,
       (select count(*) from purchase.po_lines l where l.po_id = po.id) as line_count,
       case when core.can_see_price() then (select round(sum(l.qty * l.unit_price), 0) from purchase.po_lines l where l.po_id = po.id) end as amount,
       (select count(*) from purchase.po_lines l where l.po_id = po.id and l.unit_price is null) as missing_price,
       exists (select 1 from purchase.po_lines l where l.po_id = po.id and l.received_qty > 0) as has_receipt,
       po.created_at, po.created_by, app.user_name(po.created_by) as created_by_name,
       (select ar.id from wf.approval_requests ar where ar.doc_type = 'PO' and ar.doc_id = po.id order by ar.submitted_at desc limit 1) as request_id
from purchase.purchase_orders po
left join core.partners sp on sp.id = po.supplier_id
left join plan.production_plans pp on pp.id = po.plan_id
left join purchase.purchase_requests pr on pr.id = po.pr_id
left join plan.plan_adjustments ad on ad.id = po.adjustment_id;

create or replace view app.v_po_lines with (security_invoker = true) as
select l.id, l.po_id, l.line_no, l.material_id, m.code as material_code, m.name as material_name, m.uom,
       l.supplier_item_code, l.qty, l.received_qty, l.expected_date, l.note, l.pr_line_id, l.mrp_line_id, l.mrp_qty,
       case when core.can_see_price() then l.unit_price end as unit_price,
       case when core.can_see_price() then round(l.qty * l.unit_price, 0) end as amount,
       (l.unit_price is not null) as priced,
       ml.total_issue + ml.reserve as need_qty, ml.available, ml.incoming, m.safety_stock as safety_qty,
       t.moq, t.pack_multiple, t.lead_time_days
from purchase.po_lines l
join master.materials m on m.id = l.material_id
left join plan.mrp_lines ml on ml.id = l.mrp_line_id
left join lateral (select * from purchase.material_terms(l.material_id)) t on true;
grant select on app.v_pos, app.v_po_lines to authenticated;

-- Quy trình duyệt: đơn mua mở trang /don-mua/<id>
do $$
declare d text; v_from text := $f$WHEN 'PR'::text THEN ('/de-xuat/'::text || doc_id)$f$;
begin
  d := pg_get_viewdef('app.v_approvals'::regclass);
  if position(v_from in d) = 0 then raise exception 'app.v_approvals: không tìm thấy dòng liên kết PR'; end if;
  if position('/don-mua/' in d) = 0 then
    execute 'create or replace view app.v_approvals with (security_invoker = true) as ' ||
      replace(d, v_from, v_from || $f$ WHEN 'PO'::text THEN ('/don-mua/'::text || doc_id)$f$);
  end if;
end $$;

-- Kế hoạch tháng đã duyệt trước khi có tính năng này mà chưa sinh đề xuất/đơn mua: sinh đơn mua nháp một lần
do $$
declare p record; v_run uuid;
begin
  for p in select * from plan.production_plans where status = 'APPROVED' and mode = 'OFFICIAL' and not coalesce(mrp_stale, false) loop
    select id into v_run from plan.mrp_runs where plan_id = p.id order by run_at desc limit 1;
    continue when v_run is null;
    continue when exists (select 1 from purchase.purchase_requests where mrp_run_id = v_run and status <> 'CANCELLED');
    continue when exists (select 1 from purchase.purchase_orders where mrp_run_id = v_run and status <> 'CANCELLED');
    perform purchase.po_from_mrp(v_run, null);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Kho: chế độ phiếu giấy cho kho thành phẩm, cuộn không QR, phế vào kho, đối soát cuối ngày
-- ---------------------------------------------------------------------------
-- Người giữ kho: Kế toán SX / TP SX nhập thay theo phiếu giấy (cờ bmt.paper do hàm nhập phiếu giấy đặt)
create or replace function inv.require_keeper(p_wh uuid, p_witness uuid default null)
returns boolean language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_mode text := inv.keeper_mode(p_wh); v_code text;
begin
  select w.code into v_code from inv.warehouses w where w.id = p_wh;
  -- Phạm vi kho được giao (Quản trị → Người dùng, migration 2200); không giao kho nào = mọi kho
  if not core.can_use_warehouse(p_wh) then
    raise exception 'Bạn không được giao kho %', v_code;
  end if;
  -- Phiếu giấy có chữ ký người giữ kho: Kế toán SX (hoặc TP SX) nhập vào MES
  if coalesce(current_setting('bmt.paper', true), '') = 'on' and mfg.can_enter_slips() then
    return false;
  end if;
  if v_mode is null then
    raise exception 'Bạn không phải người giữ kho % (kho NVL, BTP, phế – TP SX; kho thành phẩm – người giữ kho TP khai báo ở Nhân sự xưởng, Kế toán SX nhập từ phiếu giấy)', v_code;
  end if;
  if v_mode = 'DELEGATED' then
    if p_witness is null then
      raise exception 'Đang giữ kho % theo ủy quyền: chọn Kế toán SX chứng kiến', v_code;
    end if;
    if p_witness = auth.uid() or not exists (select 1 from core.user_roles ur where ur.user_id = p_witness and ur.role_code = 'KT_KHO') then
      raise exception 'Người chứng kiến phải là Kế toán SX (vai trò Kế toán kho), không phải người xuất';
    end if;
    return true;
  end if;
  return false;
end $$;

-- Người giữ kho thành phẩm ký trên phiếu giấy: người được khai báo "giữ kho TP" ở Nhân sự xưởng
create or replace function inv.fg_keeper(p_code text)
returns master.operators language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare o master.operators;
begin
  select * into o from master.operators where code = upper(trim(coalesce(p_code, ''))) and active;
  if not found then raise exception 'Chọn người giữ kho thành phẩm đã ký trên phiếu'; end if;
  if not o.keeps_fg then
    raise exception '% chưa được khai báo giữ kho thành phẩm (Nhân sự xưởng → Người: tích "Giữ kho TP")', o.code;
  end if;
  return o;
end $$;

-- Cuộn thành phẩm "đủ quy cách": có quy cách, không phải đoạn lẻ, chưa bị cắt; còn lại tính là cuộn lẻ / đoạn cắt
create or replace function inv.fg_pack(p_pack numeric, p_remnant boolean, p_qty numeric, p_init numeric)
returns numeric language sql immutable as $$
  select case when p_pack is not null and not coalesce(p_remnant, false) and p_qty >= coalesce(p_init, p_qty) - 0.01 then p_pack end
$$;

-- Đầu ra công đoạn: thành phẩm (CD6) nhiều cuộn trên một phiếu (cờ bmt.coils), mỗi cuộn một đơn vị chứa có quy cách
create or replace function mfg.record_output(p_wo_op uuid, p_lot_no text, p_qty_m numeric, p_weight_kg numeric, p_inputs jsonb,
  p_color text default null, p_tare_kg numeric default null, p_carrier text default null, p_location text default null)
returns uuid language plpgsql security definer set search_path = pg_catalog, public as $$
declare o mfg.wo_operations; w mfg.work_orders; op master.operations; v_lot uuid; v_last boolean; e jsonb; v_hu uuid;
        v_in uuid; v_iline int := 0; v_need numeric; b record; v_take numeric; v_out uuid; v_wh uuid; v_loc uuid; c inv.carriers;
        v_kind text; v_lotno text; v_inlot inv.lots; v_code text; v_coils int := 1; v_each numeric; v_kg numeric; i int;
begin
  if not (core.has_perm('production', 'create') or current_setting('bmt.slip', true) = 'on') then
    raise exception 'Không có quyền ghi nhận sản xuất';
  end if;
  select * into o from mfg.wo_operations where id = p_wo_op;
  if not found then raise exception 'Không tìm thấy công đoạn'; end if;
  select * into w from mfg.work_orders where id = o.wo_id;
  if w.status not in ('RELEASED', 'IN_PROGRESS') then raise exception 'Lệnh % chưa phát lệnh hoặc đã đóng', w.wo_no; end if;
  if coalesce(p_qty_m, 0) <= 0 then raise exception 'Nhập số mét đầu ra'; end if;
  select * into op from master.operations where code = o.op_code;
  v_last := o.op_code = 'CD6';
  if v_last then v_coils := greatest(coalesce(nullif(current_setting('bmt.coils', true), '')::int, 1), 1); end if;
  if p_carrier is not null then
    select * into c from inv.carriers where code = p_carrier for update;
    if not found then raise exception 'Không có bobin %', p_carrier; end if;
    if c.status <> 'EMPTY' then raise exception 'Bobin % đang chứa hàng hoặc hỏng', p_carrier; end if;
  end if;
  -- Quy trình final: mọi bobin (BTP và thành phẩm) vào Chờ QC, QC kiểm sau mỗi công đoạn
  insert into inv.lots (lot_no, item_kind, product_id, spec_id, wip_stage, brand, color, uom, wo_op_id, qc_status, mfg_date, weight_kg)
  values (p_lot_no, case when v_last then 'FG' else 'WIP' end, w.product_id, w.spec_id,
          case when v_last then null else op.output_prefix end, w.brand, p_color, 'm', p_wo_op,
          'PENDING', (now() at time zone 'Asia/Ho_Chi_Minh')::date, p_weight_kg)
  returning id into v_lot;
  insert into mfg.wo_outputs (wo_op_id, lot_id, qty_m, weight_kg) values (p_wo_op, v_lot, p_qty_m, p_weight_kg) returning id into v_out;

  -- BTP đầu vào: phải có tem QC PASS; lấy ra khỏi kho BTP (phiếu tự sinh, Kế toán SX không cần hậu kiểm)
  for e in select * from jsonb_array_elements(coalesce(p_inputs, '[]')) loop
    select * into v_inlot from inv.lots where id = (e ->> 'lot_id')::uuid;
    if not found then raise exception 'Không tìm thấy lô đầu vào'; end if;
    if v_inlot.item_kind in ('WIP', 'FG') and v_inlot.qc_status <> 'PASSED' then
      raise exception 'Bobin % chưa có tem QC PASS (đang %): không được lắp vào công đoạn sau', v_inlot.lot_no,
        case v_inlot.qc_status when 'PENDING' then 'Chờ QC' when 'QUARANTINE' then 'cách ly' when 'REJECTED' then 'không đạt' else v_inlot.qc_status end;
    end if;
    insert into mfg.lot_genealogy (parent_lot_id, child_lot_id, wo_op_id, qty_used)
    values (v_inlot.id, v_lot, p_wo_op, (e ->> 'qty')::numeric);
    if v_inlot.item_kind = 'WIP' then
      if v_in is null then
        insert into inv.stock_docs (doc_no, doc_type, warehouse_id, ref_type, ref_id, review_status, note)
        values (core.next_no('XBTP'), 'ISSUE_WO', inv.wh('KBTP'), 'WO', w.id, 'NA', 'Tự sinh: ' || o.op_code || ' lệnh ' || w.wo_no)
        returning id into v_in;
      end if;
      v_need := (e ->> 'qty')::numeric;
      for b in select bal.* from inv.stock_balances bal where bal.lot_id = v_inlot.id and bal.warehouse_id = inv.wh('KBTP')
               and bal.qty - bal.reserved_qty > 0
               and (e ->> 'hu_id' is null or bal.hu_key = (e ->> 'hu_id')::uuid)
               order by bal.qty loop
        exit when v_need <= 0;
        v_take := least(v_need, b.qty - b.reserved_qty);
        v_iline := v_iline + 1;
        insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty)
        values (v_in, v_iline, b.lot_id, nullif(b.location_key, '00000000-0000-0000-0000-000000000000'),
                nullif(b.hu_key, '00000000-0000-0000-0000-000000000000'), v_take);
        v_need := v_need - v_take;
      end loop;
      if v_need > 0.005 then
        raise exception 'Lô BTP % không đủ trong kho BTP (thiếu % m)', v_inlot.lot_no, round(v_need, 2);
      end if;
    end if;
  end loop;
  if v_in is not null then perform inv._post(v_in); end if;

  -- Lô đầu ra: BTP một bobin (có tem QR); thành phẩm mỗi cuộn một đơn vị (chỉ dán tem QC PASS, không in QR)
  v_wh := inv.wh(case when v_last then 'KTP' else 'KBTP' end);
  v_loc := coalesce(inv.loc(p_location), inv.loc(case when v_last then 'KTP-QC' else 'KBTP-W' end));
  v_kind := case when v_last and w.pack_type = 'Cuộn PE' then 'COIL' else 'REEL' end;
  insert into inv.stock_docs (doc_no, doc_type, warehouse_id, ref_type, ref_id, review_status, note)
  values (core.next_no(case when v_last then 'NTP' else 'NBTP' end), case when v_last then 'FG_IN' else 'WIP_IN' end, v_wh, 'WO', w.id,
          case when v_last then 'PENDING' else 'NA' end,
          o.op_code || ' lệnh ' || w.wo_no || case when v_coils > 1 then ' · ' || v_coils || ' cuộn' else '' end)
  returning id into v_in;
  for i in 1 .. v_coils loop
    v_each := case when i = v_coils then p_qty_m - round(p_qty_m / v_coils, 2) * (v_coils - 1) else round(p_qty_m / v_coils, 2) end;
    v_kg := case when p_weight_kg is null then null
                 when i = v_coils then p_weight_kg - round(p_weight_kg / v_coils, 3) * (v_coils - 1) else round(p_weight_kg / v_coils, 3) end;
    v_hu := inv.new_hu(v_lot, v_kind, v_each, v_wh, v_loc,
                       case when v_kg is not null then v_kg + coalesce(p_tare_kg, c.tare_kg, 0) end, coalesce(p_tare_kg, c.tare_kg));
    if i = 1 and c.id is not null then
      update inv.handling_units set carrier_id = c.id where id = v_hu;
      update inv.carriers set status = 'IN_USE', current_hu_id = v_hu, location_id = v_loc where id = c.id;
    end if;
    update inv.handling_units set is_remnant = v_last and v_each < least(w.m_per_pack, inv.remnant_min(w.product_id)),
           pack_m = case when v_last then w.m_per_pack end, pack_type = case when v_last then w.pack_type end
     where id = v_hu;
    insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty, weight_kg)
    values (v_in, i, v_lot, v_loc, v_hu, v_each, v_kg);
  end loop;
  perform inv._post(v_in);
  update mfg.wo_outputs set stock_doc_id = v_in where id = v_out;
  update mfg.wo_operations set good_m = good_m + p_qty_m, status = case when status = 'PENDING' then 'RUNNING' else status end where id = p_wo_op;
  update mfg.work_orders set status = 'IN_PROGRESS' where id = w.id and status = 'RELEASED';
  select code into v_code from master.products where id = w.product_id;
  perform wf.notify_users(inv.role_users(array['QC', 'KT_TP']),
    'Bobin chờ QC: ' || p_lot_no, coalesce(op.name, o.op_code) || ' · ' || v_code || ' · ' || p_qty_m || ' m'
      || case when v_coils > 1 then ' (' || v_coils || ' cuộn)' else '' end || ' · lệnh ' || w.wo_no || '. Trả kết quả trong 2 giờ.',
    '/kho/qc');
  return v_lot;
end $$;

-- Phiếu hoàn thành: đóng gói (CD6) nhập số cuộn × mét mỗi cuộn
CREATE OR REPLACE FUNCTION app.record_bobbin(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare w mfg.work_orders; o mfg.wo_operations; op master.operations; m master.machines; c inv.carriers; opr master.operators;
        sr master.spec_results; sp master.product_specs;
        v_gross numeric; v_tare numeric; v_net numeric; v_qty numeric; v_est boolean := false; v_start timestamptz; v_end timestamptz;
        e jsonb; v_code text; v_hu inv.handling_units; v_inlot inv.lots; v_left numeric; v_hu_net numeric; v_used numeric;
        v_inputs jsonb := '[]'; v_rec jsonb := '[]'; v_lotno text; v_base text; v_n int := 1; v_lot uuid; v_slip uuid; v_no text;
        v_scrap uuid; v_scrap_kg numeric; v_reason text; v_out_doc uuid; v_in_doc uuid; v_hu_id uuid; v_per_core numeric;
        v_coils int := 1; v_each numeric;
begin
  if not mfg.can_enter_slips() then
    raise exception 'Chỉ Kế toán SX nhập phiếu hoàn thành (TP SX nhập thay khi Kế toán vắng)';
  end if;
  select * into w from mfg.work_orders where id = nullif(p ->> 'wo_id', '')::uuid;
  if not found then raise exception 'Chọn lệnh sản xuất'; end if;
  if w.status not in ('RELEASED', 'IN_PROGRESS') then raise exception 'Lệnh % chưa phát lệnh hoặc đã đóng', w.wo_no; end if;
  select * into o from mfg.wo_operations where wo_id = w.id and op_code = p ->> 'op_code';
  if not found then raise exception 'Lệnh % không có công đoạn %', w.wo_no, coalesce(p ->> 'op_code', '—'); end if;
  select * into op from master.operations where code = o.op_code;
  select * into sp from master.product_specs where id = w.spec_id;
  select * into sr from master.spec_results where spec_id = w.spec_id;

  -- Máy, người làm
  if coalesce(p ->> 'machine_code', '') <> '' then
    select * into m from master.machines where code = upper(trim(p ->> 'machine_code'));
    if not found then raise exception 'Không có máy %', p ->> 'machine_code'; end if;
  elsif o.op_code <> 'CD6' then
    raise exception 'Chọn máy';
  end if;
  select * into opr from master.operators where code = upper(trim(coalesce(p ->> 'operator_code', '')));
  if not found then raise exception 'Chọn người làm (người đứng máy ghi trên phiếu)'; end if;

  -- Bobin (số cố định) và khối lượng
  if coalesce(trim(p ->> 'carrier'), '') <> '' then
    select * into c from inv.carriers where code = upper(trim(p ->> 'carrier'));
    if not found then raise exception 'Bobin số % chưa khai báo (Kho → Bobin: đánh số, cân bì)', p ->> 'carrier'; end if;
    if c.status <> 'EMPTY' then raise exception 'Bobin số % đang chứa hàng khác: kiểm tra lại số bobin trên phiếu', c.code; end if;
  elsif o.op_code <> 'CD6' then
    raise exception 'Nhập số bobin (số đánh cố định trên bobin)';
  end if;
  v_gross := nullif(p ->> 'gross_kg', '')::numeric;
  if coalesce(v_gross, 0) <= 0 then raise exception 'Nhập khối lượng cân (kg): bắt buộc với mọi bobin'; end if;
  v_tare := coalesce(c.tare_kg, 0);
  v_net := v_gross - v_tare;
  if v_net <= 0 then raise exception 'Khối lượng cân % kg không lớn hơn bì bobin % kg', trim_scale(v_gross), trim_scale(v_tare); end if;

  -- Số mét: bện ước tính từ kg (mét thật lấy ở line đùn khi bọc); công đoạn khác theo đồng hồ mét
  if o.op_code = 'CD1' then
    v_per_core := case when coalesce(sr.metal_kgkm, 0) > 0 and coalesce(sp.cores, 0) > 0 then sr.metal_kgkm / sp.cores end;
    if v_per_core is null then raise exception 'Spec chưa có khối lượng ruột dẫn (kg/km): không ước tính được mét bobin bện'; end if;
    v_qty := round(v_net / v_per_core * 1000, 1);
    v_est := true;
  elsif o.op_code = 'CD6' and nullif(p ->> 'm_each', '') is not null then
    -- Đóng gói: số cuộn × mét mỗi cuộn trên một phiếu (cuộn chỉ dán tem QC PASS, xuất kho theo số cuộn)
    v_coils := coalesce(nullif(p ->> 'coils', '')::int, 1);
    v_each := (p ->> 'm_each')::numeric;
    if v_coils < 1 or v_coils > 500 then raise exception 'Số cuộn phải từ 1 đến 500'; end if;
    if coalesce(v_each, 0) <= 0 then raise exception 'Nhập số mét mỗi cuộn'; end if;
    v_qty := v_coils * v_each;
  elsif nullif(p ->> 'meter_end', '') is not null then
    v_qty := (p ->> 'meter_end')::numeric - coalesce(nullif(p ->> 'meter_start', '')::numeric, 0);
    if v_qty <= 0 then raise exception 'Số đồng hồ mét lúc xong phải lớn hơn lúc bắt đầu'; end if;
  else
    v_qty := nullif(p ->> 'qty_m', '')::numeric;
    if coalesce(v_qty, 0) <= 0 then raise exception 'Nhập số đồng hồ mét lúc bắt đầu và lúc xong'; end if;
  end if;

  v_start := nullif(p ->> 'started_at', '')::timestamp at time zone 'Asia/Ho_Chi_Minh';
  v_end := nullif(p ->> 'ended_at', '')::timestamp at time zone 'Asia/Ho_Chi_Minh';
  if v_end is null then raise exception 'Nhập giờ hoàn thành'; end if;
  if v_start is not null and v_start >= v_end then raise exception 'Giờ bắt đầu phải trước giờ hoàn thành'; end if;
  if v_end > now() + interval '10 minutes' then raise exception 'Giờ hoàn thành ở tương lai: kiểm tra lại ngày giờ'; end if;

  -- Bobin đầu vào: chỉ bobin có tem QC PASS; tháo ra còn dư thì trừ phần còn lại theo kg
  for e in select * from jsonb_array_elements(coalesce(p -> 'inputs', '[]')) loop
    v_code := upper(trim(coalesce(e ->> 'code', '')));
    continue when v_code = '';
    select h.* into v_hu from inv.handling_units h
      where h.status = 'ACTIVE' and (h.hu_no = v_code or h.id = (select ca.current_hu_id from inv.carriers ca where ca.code = v_code))
      limit 1;
    if not found then raise exception 'Không tìm thấy bobin đầu vào % (số bobin hoặc mã tem)', v_code; end if;
    select * into v_inlot from inv.lots where id = v_hu.lot_id;
    if v_inlot.item_kind not in ('WIP') then raise exception 'Bobin % không phải bán thành phẩm', v_code; end if;
    if v_inlot.qc_status <> 'PASSED' then
      raise exception 'Bobin % (lô %) chưa có tem QC PASS: không được lắp vào công đoạn sau', v_code, v_inlot.lot_no;
    end if;
    if v_inlot.product_id <> w.product_id then
      raise exception 'Bobin % thuộc mã sản phẩm khác lệnh %', v_code, w.wo_no;
    end if;
    if (select o2.seq from mfg.wo_operations o2 where o2.id = v_inlot.wo_op_id) >= o.seq then
      raise exception 'Bobin % không phải của công đoạn trước %', v_code, o.op_code;
    end if;
    v_left := nullif(e ->> 'left_kg', '')::numeric;
    v_hu_net := coalesce(v_hu.gross_kg, 0) - coalesce(v_hu.tare_kg, 0);
    if coalesce(v_left, 0) > 0 then
      if v_hu_net <= 0 then raise exception 'Bobin % chưa có khối lượng cân: không trừ được phần còn dư', v_code; end if;
      if v_left >= v_hu_net then raise exception 'Bobin %: kg còn dư (%) không nhỏ hơn kg trên bobin (%)', v_code, v_left, round(v_hu_net, 2); end if;
      v_used := round(v_hu.qty * (1 - v_left / v_hu_net), 2);
    else
      v_used := v_hu.qty;
    end if;
    v_inputs := v_inputs || jsonb_build_object('lot_id', v_inlot.id, 'hu_id', v_hu.id, 'qty', v_used);
    -- used_kg: kg BTP đã dùng (cân lúc làm ra − kg còn dư) để tính kg/km ruột thật và nhựa thực dùng theo công đoạn
    v_rec := v_rec || jsonb_build_object('code', v_code, 'hu_no', v_hu.hu_no, 'lot_no', v_inlot.lot_no, 'stage', v_inlot.wip_stage,
                                         'left_kg', v_left, 'used_m', v_used,
                                         'used_kg', case when v_hu_net > 0 then round(v_hu_net - coalesce(v_left, 0), 3) end);
  end loop;
  if o.seq > 1 and o.op_code <> 'CD0' and jsonb_array_length(v_inputs) = 0 then
    raise exception 'Nhập bobin đầu vào (bobin BTP có tem QC PASS đã lắp)';
  end if;

  -- Số lô: <tiền tố công đoạn>-<yymmdd>-<số bobin>
  v_base := coalesce(op.output_prefix, o.op_code) || '-' || to_char(v_end at time zone 'Asia/Ho_Chi_Minh', 'YYMMDD') || '-'
            || coalesce(c.code, upper(substr(replace(w.wo_no, 'LSX-', ''), 1, 12)));
  v_lotno := v_base;
  while exists (select 1 from inv.lots where lot_no = v_lotno) loop
    v_n := v_n + 1; v_lotno := v_base || '-' || v_n;
  end loop;

  if m.id is not null and o.machine_id is null then update mfg.wo_operations set machine_id = m.id where id = o.id; end if;
  perform set_config('bmt.slip', 'on', true);
  perform set_config('bmt.coils', v_coils::text, true);
  v_lot := mfg.record_output(o.id, v_lotno, v_qty, v_net, v_inputs, coalesce(nullif(p ->> 'color', ''), sp.sheath_color), v_tare, c.code, null);
  perform set_config('bmt.coils', '', true);
  perform set_config('bmt.slip', 'off', true);
  select h.id into v_hu_id from inv.handling_units h where h.lot_id = v_lot order by h.created_at limit 1;
  select d.id into v_out_doc from inv.stock_docs d join inv.stock_doc_lines l on l.doc_id = d.id
    where l.lot_id = v_lot and d.doc_type in ('WIP_IN', 'FG_IN') limit 1;
  select d.id into v_in_doc from inv.stock_docs d
    where d.ref_type = 'WO' and d.ref_id = w.id and d.doc_type = 'ISSUE_WO' and d.created_at = now() order by d.doc_no desc limit 1;
  -- Bobin đầu vào còn dư: ghi lại kg trên bobin để lần lắp sau tính đúng
  for e in select * from jsonb_array_elements(v_rec) loop
    if coalesce((e ->> 'left_kg')::numeric, 0) > 0 then
      update inv.handling_units set gross_kg = coalesce(tare_kg, 0) + (e ->> 'left_kg')::numeric where hu_no = e ->> 'hu_no';
    end if;
  end loop;

  -- Phế của bobin
  v_scrap_kg := nullif(p ->> 'scrap_kg', '')::numeric;
  v_reason := nullif(p ->> 'scrap_reason', '');
  if coalesce(v_scrap_kg, 0) > 0 then
    if v_reason is null then raise exception 'Chọn lý do phế'; end if;
    insert into mfg.scrap_records (wo_op_id, scrap_material_id, reason_code, qty_kg, machine_id, shift_code, operator_id, lot_id)
    values (o.id, (select mt.id from master.materials mt where mt.code = mfg.scrap_material_for(o.op_code, w.spec_id)), v_reason, v_scrap_kg,
            m.id, 'A', opr.profile_id, null)
    returning id into v_scrap;
  end if;

  update mfg.wo_operations set
    started_at = least(coalesce(started_at, v_start, v_end), coalesce(v_start, v_end)),
    ended_at = greatest(coalesce(ended_at, v_end), v_end),
    run_minutes = run_minutes + coalesce(extract(epoch from (v_end - v_start)) / 60, 0)
  where id = o.id;

  v_no := core.next_no('PHT');
  insert into mfg.bobbin_slips (slip_no, paper_no, wo_id, wo_op_id, op_code, machine_id, carrier_id, operator_code, started_at, ended_at,
                                gross_kg, tare_kg, net_kg, meter_start, meter_end, qty_m, qty_estimated, inputs, materials, scrap_kg, scrap_reason,
                                readings, note, lot_id, hu_id, out_doc_id, in_doc_id, scrap_id, coils)
  values (v_no, nullif(trim(coalesce(p ->> 'paper_no', '')), ''), w.id, o.id, o.op_code, m.id, c.id, opr.code, v_start, v_end,
          v_gross, v_tare, v_net, nullif(p ->> 'meter_start', '')::numeric, nullif(p ->> 'meter_end', '')::numeric, v_qty, v_est, v_rec,
          nullif(trim(coalesce(p ->> 'materials', '')), ''), v_scrap_kg, v_reason, coalesce(p -> 'readings', '{}'),
          nullif(trim(coalesce(p ->> 'note', '')), ''), v_lot, v_hu_id, v_out_doc, v_in_doc, v_scrap, v_coils)
  returning id into v_slip;
  return jsonb_build_object('slip_id', v_slip, 'slip_no', v_no, 'lot_no', v_lotno, 'qty_m', v_qty, 'estimated', v_est, 'net_kg', v_net, 'coils', v_coils);
end $function$;

-- Hủy phiếu hoàn thành: không hủy khi phế của phiếu đã vào kho phế
CREATE OR REPLACE FUNCTION app.void_bobbin(p_slip uuid, p_reason text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare s mfg.bobbin_slips; lt inv.lots; v_bal numeric; v_qty numeric;
begin
  if not (core.has_role('KT_KHO') or core.is_admin()) then raise exception 'Chỉ Kế toán SX hủy phiếu hoàn thành nhập sai'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do hủy phiếu'; end if;
  select * into s from mfg.bobbin_slips where id = p_slip for update;
  if not found or s.status <> 'ACTIVE' then raise exception 'Phiếu không còn hiệu lực'; end if;
  select * into lt from inv.lots where id = s.lot_id for update;
  if lt.qc_status not in ('PENDING', 'QUARANTINE') then
    raise exception 'Bobin % đã có kết quả QC: nhờ QC/TP KT/QA xử lý trước khi hủy phiếu', lt.lot_no;
  end if;
  select coalesce(sum(b.qty), 0) into v_bal from inv.stock_balances b where b.lot_id = s.lot_id;
  if v_bal + 0.005 < s.qty_m then raise exception 'Bobin % đã được dùng ở công đoạn sau: không hủy được', lt.lot_no; end if;
  if s.in_doc_id is not null then perform inv.reverse_doc(s.in_doc_id, 'Hủy phiếu hoàn thành ' || s.slip_no || ': ' || trim(p_reason)); end if;
  if s.out_doc_id is not null then perform inv.reverse_doc(s.out_doc_id, 'Hủy phiếu hoàn thành ' || s.slip_no || ': ' || trim(p_reason)); end if;
  delete from mfg.lot_genealogy where child_lot_id = s.lot_id;
  select coalesce(sum(qty_m), 0) into v_qty from mfg.wo_outputs where lot_id = s.lot_id;
  update mfg.wo_operations set good_m = greatest(good_m - v_qty, 0) where id = s.wo_op_id;
  delete from mfg.wo_outputs where lot_id = s.lot_id;
  if s.scrap_id is not null and (select sr.lot_id from mfg.scrap_records sr where sr.id = s.scrap_id) is not null then
    raise exception 'Phế của phiếu % đã nhập kho phế khi chốt ca: không hủy được, lập biên bản điều chỉnh kho phế', s.slip_no;
  end if;
  if s.scrap_id is not null then
    update mfg.bobbin_slips set scrap_id = null where id = s.id;
    delete from mfg.scrap_records where id = s.scrap_id;
  end if;
  update inv.lots set qc_status = 'REJECTED', attrs = attrs || jsonb_build_object('void_slip', s.slip_no) where id = s.lot_id;
  update mfg.bobbin_slips set status = 'VOID', void_reason = trim(p_reason), voided_at = now(), voided_by = auth.uid() where id = s.id;
  return s.slip_no;
end $function$;

-- Gửi báo cáo ngày (tay hoặc tự động 19:30): nhập phế còn lại vào kho phế trước khi tổng hợp
CREATE OR REPLACE FUNCTION mfg.send_daily_report(p_date date, p_auto boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare v jsonb; v_red jsonb; v_c jsonb; v_slips int; v_m numeric; v_body text; v_lines text; v_link text := '/bao-cao/ngay?d=' || p_date;
begin
  -- Phế ghi trên phiếu hoàn thành, báo cáo ca chưa vào kho phế: nhập kho phế (mỗi mã một bao/ngày)
  perform inv.scrap_to_stock(p_date);
  v := mfg.daily_report_data(p_date);
  v_c := v -> 'counts';
  select coalesce(jsonb_agg(jsonb_build_object('wo_id', e ->> 'wo_id', 'wo_no', e ->> 'wo_no', 'stage', e ->> 'stage',
                                               'label', e ->> 'label', 'var_pct', e -> 'var_pct')), '[]')
    into v_red from jsonb_array_elements(v -> 'loss') e where e ->> 'level' = 'RED';
  select coalesce(sum((e ->> 'slips')::int), 0), coalesce(sum((e ->> 'm')::numeric), 0) into v_slips, v_m
    from jsonb_array_elements(v -> 'production') e;
  v_body := format('%s bobin, %s m theo phiếu hoàn thành. QC: %s bobin đang chờ, %s quá hạn. Hao hụt: %s đỏ, %s vàng, %s xanh.',
                   v_slips, core.vn_num(round(v_m)), v -> 'qc' ->> 'pending_now', v -> 'qc' ->> 'late_now',
                   v_c ->> 'RED', v_c ->> 'YELLOW', v_c ->> 'GREEN');
  select string_agg(format('%s · %s: vượt định mức %s %%', e ->> 'wo_no', e ->> 'label', core.vn_num((e ->> 'var_pct')::numeric)), E'\n') into v_lines
    from jsonb_array_elements(v_red) e;
  perform wf.notify_users(inv.role_users(array['SX_TP', 'KT_KHO', 'BGD', 'TO_TRUONG']),
    'Báo cáo sản xuất ngày ' || to_char(p_date, 'DD/MM'), v_body || coalesce(E'\nMục đỏ:\n' || v_lines, ''), v_link);
  if jsonb_array_length(v_red) > 0 then
    perform wf.notify_users(inv.role_users(array['BGD']),
      'Cảnh báo đỏ hao hụt ngày ' || to_char(p_date, 'DD/MM') || ': ' || jsonb_array_length(v_red) || ' mục', v_lines, v_link);
    perform wf.notify_users(inv.role_users(array['SX_TP']),
      'Giải trình hao hụt đỏ ngày ' || to_char(p_date, 'DD/MM') || ' trước 10:00 hôm sau', v_lines, v_link);
  end if;
  insert into mfg.daily_reports (work_date, sent_at, sent_by, auto, summary)
  values (p_date, now(), case when p_auto then null else auth.uid() end, p_auto,
          jsonb_build_object('counts', v_c, 'red', v_red, 'slips', v_slips, 'm', round(v_m, 1)))
  on conflict (work_date) do update set sent_at = excluded.sent_at, sent_by = excluded.sent_by, auto = excluded.auto, summary = excluded.summary;
  return jsonb_build_object('counts', v_c, 'slips', v_slips, 'm', round(v_m, 1));
end $function$;

-- Phế từ phiếu hoàn thành, báo cáo ca → kho phế (giá trị 0, mỗi mã phế một bao/ngày).
-- Gọi khi TP SX chốt ca (phế của máy đó) và khi gửi báo cáo ngày (phần còn lại đến hết ngày).
create or replace function inv.scrap_to_stock(p_date date, p_machine uuid default null, p_report uuid default null)
returns uuid language plpgsql security definer set search_path = pg_catalog, public
set "TimeZone" = 'Asia/Ho_Chi_Minh' as $$
declare g record; s record; v_doc uuid; v_line int := 0;
begin
  create temp table if not exists _sc (id uuid, material_id uuid, kg numeric) on commit drop;
  delete from _sc where true;
  insert into _sc
  select sr.id, sr.scrap_material_id, sr.qty_kg from mfg.scrap_records sr
  where sr.lot_id is null and sr.scrap_material_id is not null and coalesce(sr.qty_kg, 0) > 0
    and coalesce((select (bs.ended_at at time zone 'Asia/Ho_Chi_Minh')::date from mfg.bobbin_slips bs where bs.scrap_id = sr.id limit 1),
                 (sr.recorded_at at time zone 'Asia/Ho_Chi_Minh')::date) <= p_date
    and ((p_machine is null and p_report is null)
         or sr.shift_report_id = p_report
         or (sr.shift_report_id is null and sr.machine_id = p_machine));
  if not exists (select 1 from _sc) then return null; end if;
  insert into inv.stock_docs (doc_no, doc_type, warehouse_id, review_status, note)
  values (core.next_no('NP'), 'SCRAP_IN', inv.wh('KPL'), 'NA',
          'Phế ghi trên phiếu hoàn thành, báo cáo ca đến ngày ' || to_char(p_date, 'DD/MM/YYYY')
          || coalesce(' · máy ' || (select code from master.machines where id = p_machine), ''))
  returning id into v_doc;
  for g in select material_id, sum(kg) as kg from _sc group by material_id order by material_id loop
    select * into s from inv.scrap_lot(g.material_id, p_date);
    v_line := v_line + 1;
    insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty, weight_kg)
    values (v_doc, v_line, s.lot_id, s.loc_id, s.hu_id, round(g.kg, 3), round(g.kg, 3));
    update mfg.scrap_records sr set lot_id = s.lot_id from _sc x where x.id = sr.id and x.material_id = g.material_id;
  end loop;
  perform inv._post(v_doc);
  return v_doc;
end $$;

-- TP SX / tổ trưởng chốt ca: phế cả ca vào sổ hao hụt rồi tự nhập kho phế
create or replace function app.kh_confirm_report(p_id uuid, p_note text)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
declare r mfg.shift_reports; v_dev numeric; sc jsonb; o mfg.wo_operations; w mfg.work_orders; v_mc uuid;
begin
  if not app.kh_has_any(array['TO_TRUONG','SX_TP']) then raise exception 'Chỉ Quản lý SX / tổ trưởng (hoặc tổ phó được ủy quyền) xác nhận ca'; end if;
  select * into r from mfg.shift_reports where id = p_id for update;
  if r.status <> 'SUBMITTED' then raise exception 'Báo cáo chưa gửi hoặc đã xác nhận'; end if;
  select plc_dev_pct into v_dev from master.planning_config where id = 1;
  if r.source = 'BOTH' and exists (select 1 from jsonb_array_elements(r.lines) e
       where coalesce((e->>'plc_m')::numeric, 0) > 0
         and abs((e->>'declared_m')::numeric - (e->>'plc_m')::numeric) / (e->>'plc_m')::numeric * 100 > v_dev)
     and coalesce(trim(p_note), '') = '' then
    raise exception 'Mét khai báo lệch PLC trên % %%: cần ghi giải trình', v_dev;
  end if;
  update mfg.shift_reports set status = 'CONFIRMED', confirmed_by = auth.uid(), confirmed_at = now(),
    note = coalesce(nullif(trim(coalesce(p_note, '')), ''), note) where id = p_id;
  select id into v_mc from master.machines where code = r.machine_code;
  for sc in select * from jsonb_array_elements(r.scraps) loop
    select * into w from mfg.work_orders where wo_no = sc ->> 'wo_no';
    select * into o from mfg.wo_operations where wo_id = w.id and op_code = sc ->> 'op_code';
    continue when o.id is null;
    insert into mfg.scrap_records (wo_op_id, scrap_material_id, reason_code, qty_kg, machine_id, shift_code, shift_report_id, recorded_at)
    values (o.id, (select mt.id from master.materials mt where mt.code = mfg.scrap_material_for(o.op_code, w.spec_id)), sc ->> 'reason',
            (sc ->> 'kg')::numeric, v_mc, r.shift_code, r.id,
            least(now(), ((r.work_date + 1)::timestamp - interval '1 minute') at time zone 'Asia/Ho_Chi_Minh'));
  end loop;
  -- Phế của ca (báo cáo ca + phiếu hoàn thành của máy đến hết ngày) vào kho phế
  perform inv.scrap_to_stock(r.work_date, v_mc, p_id);
  -- M3: dừng máy trong ca vào nhật ký máy (lịch sử, chỉ số hỏng, báo cáo bảo trì tháng)
  perform mfg.shift_downtime_to_log(p_id);
end $$;

-- Phiếu kho do Kế toán SX nhập từ phiếu giấy (Kế toán SX không giữ kho nên mọi phiếu chờ xác nhận do Kế toán SX lập là phiếu giấy)
create or replace function inv.is_recon_doc(p_user uuid)
returns boolean language sql stable security definer set search_path = pg_catalog, public as $$
  select p_user is not null and exists (select 1 from core.user_roles ur where ur.user_id = p_user and ur.role_code = 'KT_KHO')
$$;

-- Kế toán SX bấm "Đã đối soát xong – gửi": xác nhận mọi phiếu mình (và Kế toán SX khác) nhập từ giấy đến hết ngày đó;
-- phiếu người khác nhập trực tiếp (TP SX…) vẫn do Kế toán SX duyệt từng phiếu
create or replace function app.send_daily_report(p_date date)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare v jsonb; v_n int := 0;
begin
  if not (mfg.can_enter_slips() or core.has_role('BGD')) then raise exception 'Chỉ Kế toán SX (sau đối soát) hoặc TP SX gửi báo cáo ngày'; end if;
  if p_date > (now() at time zone 'Asia/Ho_Chi_Minh')::date then raise exception 'Chưa đến ngày %', to_char(p_date, 'DD/MM'); end if;
  v := mfg.send_daily_report(p_date, false);
  if core.has_role('KT_KHO') then
    update inv.stock_docs d set review_status = 'CONFIRMED', reviewed_by = auth.uid(), reviewed_at = now(),
           review_note = left(coalesce(review_note || ' · ', '') || 'Đối soát cuối ngày ' || to_char(p_date, 'DD/MM/YYYY'), 500)
     where d.status = 'POSTED' and d.review_status = 'PENDING' and d.doc_date <= p_date and inv.is_recon_doc(d.created_by);
    get diagnostics v_n = row_count;
  end if;
  return v || jsonb_build_object('confirmed_docs', v_n);
end $$;

-- Cảnh báo kho: phiếu Kế toán SX nhập từ giấy tính theo ngày chưa đối soát
CREATE OR REPLACE FUNCTION inv.daily_alerts()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
 SET "TimeZone" TO 'Asia/Ho_Chi_Minh'
AS $function$
declare r record; v_n int := 0; v_week text := to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'IYYY-IW');
begin
  -- Phiếu đã ghi sổ chưa được Kế toán SX xác nhận quá hạn → Giám đốc + Kế toán SX
  for r in select d.* from inv.stock_docs d
           where d.status = 'POSTED' and d.review_status = 'PENDING'
             and not inv.is_recon_doc(d.created_by)
             and d.posted_at < now() - make_interval(hours => coalesce(inv.setting('review_hours'), 24)::int) loop
    insert into inv.alert_log (kind, ref_id) values ('REVIEW', r.id) on conflict do nothing;
    continue when not found;
    perform wf.notify_users(inv.role_users(array['BGD', 'KT_KHO']), 'Phiếu kho chưa được Kế toán SX duyệt: ' || r.doc_no,
      'Ghi sổ lúc ' || to_char(r.posted_at at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM'), '/kho/phieu/' || r.id);
    v_n := v_n + 1;
  end loop;
  -- Phiếu Kế toán SX nhập từ phiếu giấy: xác nhận khi gửi báo cáo ngày; ngày đã qua mà chưa đối soát → một cảnh báo/ngày
  for r in select d.doc_date, count(*) as n, (array_agg(d.id order by d.doc_no))[1] as first_id
           from inv.stock_docs d
           where d.status = 'POSTED' and d.review_status = 'PENDING' and inv.is_recon_doc(d.created_by)
             and d.doc_date < (now() at time zone 'Asia/Ho_Chi_Minh')::date
           group by d.doc_date loop
    insert into inv.alert_log (kind, ref_id) values ('RECON', r.first_id) on conflict do nothing;
    continue when not found;
    perform wf.notify_users(inv.role_users(array['BGD', 'KT_KHO']), 'Ngày ' || to_char(r.doc_date, 'DD/MM') || ' chưa đối soát kho',
      r.n || ' phiếu Kế toán SX nhập từ phiếu giấy chưa xác nhận: đối soát rồi bấm "Đã đối soát xong – gửi" ở Báo cáo sản xuất ngày',
      '/bao-cao/ngay?d=' || r.doc_date);
    v_n := v_n + 1;
  end loop;
  -- Lô chờ QC quá lâu
  for r in select l.* from inv.lots l
           where l.qc_status = 'PENDING' and l.created_at < now() - make_interval(days => coalesce(inv.setting('qc_wait_days'), 2)::int) loop
    insert into inv.alert_log (kind, ref_id) values ('QCWAIT', r.id) on conflict do nothing;
    continue when not found;
    perform wf.notify_users(inv.role_users(array['KT_TP', 'QC', 'MUA_NV']), 'Lô chờ kiểm tra quá hạn: ' || r.lot_no,
      'Nhận từ ' || to_char(r.created_at at time zone 'Asia/Ho_Chi_Minh', 'DD/MM'), '/kho/qc');
    v_n := v_n + 1;
  end loop;
  -- Hết hạn: tự chuyển Cách ly (BR-KHO-10)
  for r in select l.* from inv.lots l where l.qc_status = 'PASSED' and l.exp_date < current_date
             and exists (select 1 from inv.stock_balances b where b.lot_id = l.id and b.qty > 0) loop
    update inv.lots set qc_status = 'QUARANTINE' where id = r.id;
    insert into inv.alert_log (kind, ref_id) values ('EXPIRED', r.id) on conflict do nothing;
    perform wf.notify_users(inv.role_users(array['THU_KHO', 'KT_TP', 'MUA_NV']), 'Lô hết hạn, đã chuyển cách ly: ' || r.lot_no,
      'HSD ' || to_char(r.exp_date, 'DD/MM/YYYY'), '/kho/qc');
    v_n := v_n + 1;
  end loop;
  -- Sắp hết hạn
  for r in select l.* from inv.lots l where l.qc_status = 'PASSED' and l.exp_date >= current_date
             and l.exp_date <= current_date + coalesce(inv.setting('expiry_warn_days'), 30)::int
             and exists (select 1 from inv.stock_balances b where b.lot_id = l.id and b.qty > 0) loop
    insert into inv.alert_log (kind, ref_id) values ('EXPWARN', r.id) on conflict do nothing;
    continue when not found;
    perform wf.notify_users(inv.role_users(array['THU_KHO', 'MUA_NV']), 'Lô sắp hết hạn: ' || r.lot_no,
      'HSD ' || to_char(r.exp_date, 'DD/MM/YYYY') || ' – ưu tiên cấp trước', '/kho/ton?q=' || r.lot_no);
    v_n := v_n + 1;
  end loop;
  -- Dưới mức đặt hàng (Kế toán SX theo dõi tồn tối thiểu, báo NV mua hàng) — mỗi tuần một lần
  for r in select m.id, m.code, m.name, m.uom, m.reorder_point, coalesce(a.available, 0) + coalesce(a.in_quality, 0) as have
           from master.materials m left join inv.v_material_availability a on a.material_id = m.id
           where m.reorder_point is not null and coalesce(a.available, 0) + coalesce(a.in_quality, 0) <= m.reorder_point loop
    insert into inv.alert_log (kind, ref_id, period_key) values ('REORDER', r.id, v_week) on conflict do nothing;
    continue when not found;
    perform wf.notify_users(inv.role_users(array['KT_KHO', 'MUA_NV']), 'Chạm mức đặt hàng: ' || r.code,
      format('%s: còn %s %s, mức đặt hàng %s', r.name, round(r.have, 1), r.uom, r.reorder_point), '/vat-tu?q=' || r.code);
    v_n := v_n + 1;
  end loop;
  -- Phiếu nháp để lâu
  for r in select d.* from inv.stock_docs d where d.status = 'DRAFT'
             and d.created_at < now() - make_interval(hours => coalesce(inv.setting('draft_hours'), 24)::int) loop
    insert into inv.alert_log (kind, ref_id) values ('DRAFT', r.id) on conflict do nothing;
    continue when not found;
    perform wf.notify_users(array_remove(array[r.created_by], null) ||
                            case when r.price_pending then inv.role_users(array['KT_KHO']) else '{}'::uuid[] end,
      'Phiếu kho còn nháp: ' || r.doc_no, case when r.price_pending then 'Chờ Kế toán SX nhập giá' else 'Hoàn tất hoặc hủy phiếu' end,
      '/kho/phieu/' || r.id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $function$;

-- Tồn đầu kỳ: NVL theo bao/ống (như cũ); BTP từng bobin (số bobin, công đoạn, mét, kg cân); thành phẩm số cuộn × mét/cuộn
create or replace function inv.create_opening(p_warehouse uuid, p_doc_date date, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = pg_catalog, public
set "TimeZone" = 'Asia/Ho_Chi_Minh' as $$
declare w inv.warehouses; v_doc uuid; v_no text; e jsonb; m master.materials; p master.products; v_lot uuid; v_hu uuid;
        v_loc uuid; v_line int := 0; v_units int; v_each numeric; i int; c inv.carriers; v_stage text; v_gross numeric; v_net numeric;
        v_qty numeric; v_pack numeric; v_pack_type text; v_brand text; v_kgkm numeric; v_cores int; v_carriers text[] := '{}';
begin
  if not core.has_role('KT_KHO') then raise exception 'Chỉ Kế toán SX lập tồn đầu kỳ'; end if;
  select * into w from inv.warehouses where id = p_warehouse;
  if not found then raise exception 'Chọn kho'; end if;
  if coalesce(jsonb_array_length(p_lines), 0) = 0 then raise exception 'Nhập ít nhất một dòng'; end if;
  v_no := core.next_no('TDK');
  insert into inv.stock_docs (doc_no, doc_type, warehouse_id, doc_date, note)
  values (v_no, 'OPENING', p_warehouse, coalesce(p_doc_date, current_date), 'Tồn đầu kỳ ' || w.code) returning id into v_doc;
  for e in select * from jsonb_array_elements(p_lines) loop
    v_loc := inv.loc(upper(trim(coalesce(e ->> 'location_code', ''))));
    if v_loc is not null and (select l.warehouse_id from inv.locations l where l.id = v_loc) <> p_warehouse then
      raise exception 'Vị trí % không thuộc kho %', e ->> 'location_code', w.code;
    end if;
    if w.kind in ('MAT', 'SCRAP') then
      if coalesce((e ->> 'qty')::numeric, 0) <= 0 then raise exception 'Số lượng phải > 0 (%)', e ->> 'code'; end if;
      v_loc := coalesce(v_loc, (select l.id from inv.locations l where l.warehouse_id = p_warehouse and l.kind = 'STORE' order by l.sort limit 1));
      v_units := greatest(coalesce(nullif(e ->> 'units', '')::int, 1), 1);
      v_each := round((e ->> 'qty')::numeric / v_units, 4);
      select * into m from master.materials where code = upper(trim(e ->> 'code'));
      if not found then raise exception 'Không có mã vật tư %', e ->> 'code'; end if;
      if w.kind = 'MAT' and (e ->> 'unit_cost') is null then raise exception '% thiếu đơn giá', m.code; end if;
      insert into inv.lots (lot_no, item_kind, material_id, uom, supplier_lot, qc_status, mfg_date, exp_date, attrs)
      values (core.next_no('DK'), case when w.kind = 'SCRAP' then 'SCRAP' else 'MAT' end, m.id, m.uom, nullif(e ->> 'supplier_lot', ''),
              'PASSED', nullif(e ->> 'mfg_date', '')::date, nullif(e ->> 'exp_date', '')::date, '{"opening": true}')
      returning id into v_lot;
      for i in 1 .. v_units loop
        v_hu := inv.new_hu(v_lot, 'OTHER', case when i = v_units then (e ->> 'qty')::numeric - v_each * (v_units - 1) else v_each end, p_warehouse, v_loc);
        v_line := v_line + 1;
        insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty, unit_cost)
        values (v_doc, v_line, v_lot, v_loc, v_hu, (select qty from inv.handling_units where id = v_hu), nullif(e ->> 'unit_cost', '')::numeric);
      end loop;
    else
      select * into p from master.products where code = upper(trim(e ->> 'code'));
      if not found then raise exception 'Không có mã sản phẩm %', e ->> 'code'; end if;
      v_brand := coalesce(nullif(upper(trim(e ->> 'brand')), ''), p.default_brand, 'KAVIX');
      if w.kind = 'WIP' then
        -- BTP: mỗi dòng một bobin có số cố định, công đoạn đã làm xong, kg cân (MES trừ bì bobin), mét
        v_stage := upper(trim(coalesce(e ->> 'stage', '')));
        select coalesce(op.output_prefix, v_stage) into v_stage from master.operations op where op.code = v_stage or op.output_prefix = v_stage limit 1;
        if v_stage is null or v_stage not in ('CB', 'LB', 'BL', 'BS', 'CV') then
          raise exception '%: công đoạn phải là CD1 (bện) … CD5 (bọc vỏ)', p.code;
        end if;
        select * into c from inv.carriers where code = upper(trim(coalesce(e ->> 'carrier', '')));
        if not found then raise exception '%: nhập số bobin đã khai báo ở Kho → Bobin (số cố định, bì)', p.code; end if;
        if c.status <> 'EMPTY' then raise exception 'Bobin số % đang chứa hàng khác', c.code; end if;
        if c.code = any(v_carriers) or exists (select 1 from inv.handling_units h join inv.stock_doc_lines dl on dl.hu_id = h.id
                                               join inv.stock_docs d on d.id = dl.doc_id
                                              where h.carrier_id = c.id and d.doc_type = 'OPENING' and d.status in ('DRAFT', 'PENDING_APPROVAL')) then
          raise exception 'Bobin số % đã có trong phiếu tồn đầu kỳ đang chờ duyệt', c.code;
        end if;
        v_carriers := v_carriers || c.code;
        v_gross := nullif(e ->> 'gross_kg', '')::numeric;
        if coalesce(v_gross, 0) <= 0 then raise exception 'Bobin số %: nhập kg cân', c.code; end if;
        v_net := v_gross - coalesce(c.tare_kg, 0);
        if v_net <= 0 then raise exception 'Bobin số %: kg cân không lớn hơn bì % kg', c.code, trim_scale(coalesce(c.tare_kg, 0)); end if;
        v_qty := nullif(e ->> 'qty', '')::numeric;
        if v_qty is null and v_stage = 'CB' then
          -- ruột bện: ước tính mét từ kg như phiếu hoàn thành (mét thật đo ở line đùn khi bọc)
          select r.metal_kgkm, s.cores into v_kgkm, v_cores from master.product_specs s left join master.spec_results r on r.spec_id = s.id
           where s.id = p.current_spec_id;
          if coalesce(v_kgkm, 0) > 0 and coalesce(v_cores, 0) > 0 then v_qty := round(v_net / (v_kgkm / v_cores) * 1000, 1); end if;
        end if;
        if coalesce(v_qty, 0) <= 0 then raise exception 'Bobin số %: nhập số mét', c.code; end if;
        v_loc := coalesce(v_loc, inv.loc('KBTP-W'));
        insert into inv.lots (lot_no, item_kind, product_id, spec_id, brand, uom, qc_status, mfg_date, wip_stage, weight_kg, attrs)
        values (core.next_no('DK'), 'WIP', p.id, p.current_spec_id, v_brand, 'm', 'PASSED', nullif(e ->> 'mfg_date', '')::date, v_stage, v_net,
                jsonb_build_object('opening', true, 'carrier', c.code))
        returning id into v_lot;
        v_hu := inv.new_hu(v_lot, 'REEL', v_qty, p_warehouse, v_loc, v_gross, coalesce(c.tare_kg, 0));
        update inv.handling_units set carrier_id = c.id where id = v_hu;
        v_line := v_line + 1;
        insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty, weight_kg)
        values (v_doc, v_line, v_lot, v_loc, v_hu, v_qty, v_net);
      else
        -- Thành phẩm: số cuộn × mét mỗi cuộn theo quy cách (cuộn chỉ dán tem QC PASS)
        v_pack := nullif(e ->> 'pack_m', '')::numeric;
        v_units := coalesce(nullif(e ->> 'coils', '')::int, nullif(e ->> 'units', '')::int, 1);
        v_each := coalesce(nullif(e ->> 'm_each', '')::numeric,
                           case when e ? 'coils' then v_pack else round((e ->> 'qty')::numeric / greatest(v_units, 1), 2) end);
        if v_units < 1 then raise exception '%: số cuộn phải ≥ 1', p.code; end if;
        if coalesce(v_each, 0) <= 0 then raise exception '%: nhập quy cách (mét/cuộn) hoặc số mét mỗi cuộn', p.code; end if;
        v_pack := coalesce(v_pack, v_each);
        v_pack_type := coalesce(nullif(trim(e ->> 'pack_type'), ''), p.default_pack, 'Bobin gỗ');
        v_loc := coalesce(v_loc, inv.loc(case when v_brand = 'HEIZKA' then 'KTP-B' else 'KTP-A' end));
        insert into inv.lots (lot_no, item_kind, product_id, spec_id, brand, uom, qc_status, mfg_date, attrs)
        values (core.next_no('DK'), 'FG', p.id, p.current_spec_id, v_brand, 'm', 'PASSED', nullif(e ->> 'mfg_date', '')::date, '{"opening": true}')
        returning id into v_lot;
        for i in 1 .. v_units loop
          v_hu := inv.new_hu(v_lot, case when v_pack_type = 'Cuộn PE' then 'COIL' else 'REEL' end, v_each, p_warehouse, v_loc);
          update inv.handling_units set pack_m = v_pack, pack_type = v_pack_type,
                 is_remnant = v_each < least(v_pack, inv.remnant_min(p.id)) where id = v_hu;
          v_line := v_line + 1;
          insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty)
          values (v_doc, v_line, v_lot, v_loc, v_hu, v_each);
        end loop;
      end if;
    end if;
  end loop;
  perform wf.submit('STOCK_OPEN', v_doc, v_no, format('Tồn đầu kỳ %s: %s dòng', w.code, jsonb_array_length(p_lines)));
  return v_doc;
end $$;

-- Tồn đầu kỳ được Kế toán trưởng duyệt, ghi sổ: bobin BTP chuyển sang "đang chứa hàng"
create or replace function inv.opening_carriers(p_doc uuid)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  update inv.carriers c set status = 'IN_USE', current_hu_id = h.id, location_id = h.location_id
    from inv.stock_doc_lines dl join inv.handling_units h on h.id = dl.hu_id
   where dl.doc_id = p_doc and h.carrier_id = c.id and c.status = 'EMPTY';
end $$;

-- ---------------------------------------------------------------------------
-- 5. Kho thành phẩm theo số cuộn: nhập kho TP, lệnh giao trực tiếp, xuất theo số cuộn
-- ---------------------------------------------------------------------------
-- Cuộn đã hứa giao: lệnh giao trực tiếp đang chờ duyệt / đã duyệt chưa xuất
create or replace function inv.fg_committed(p_product uuid, p_brand text, p_pack numeric, p_exclude uuid default null)
returns integer language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce(sum(i.coils), 0)::int from sales.delivery_items i join sales.deliveries d on d.id = i.delivery_id
   where d.so_id is null and d.status in ('PENDING_APPROVAL', 'APPROVED') and d.id is distinct from p_exclude
     and i.product_id = p_product and i.brand = p_brand and i.pack_m is not distinct from p_pack
$$;

-- Cuộn còn giao được: QC Đạt, đã nhập kho (khu lưu, khu chờ giao), không giữ cho đơn bán, trừ cuộn đã hứa ở lệnh giao khác
create or replace function inv.fg_free_coils(p_product uuid, p_brand text, p_pack numeric, p_exclude uuid default null)
returns integer language sql stable security definer set search_path = pg_catalog, public as $$
  select (select count(*) from inv.handling_units h join inv.lots l on l.id = h.lot_id
            join inv.locations loc on loc.id = h.location_id join inv.warehouses w on w.id = h.warehouse_id
           where w.code = 'KTP' and h.status = 'ACTIVE' and l.item_kind = 'FG' and l.qc_status = 'PASSED' and loc.kind in ('STORE', 'SHIP')
             and l.product_id = p_product and l.brand = p_brand and inv.fg_pack(h.pack_m, h.is_remnant, h.qty, h.init_qty) is not distinct from p_pack
             and coalesce((select sum(b.reserved_qty) from inv.stock_balances b where b.hu_key = h.id), 0) = 0)::int
         - inv.fg_committed(p_product, p_brand, p_pack, p_exclude)
$$;

create or replace function inv.fg_label(p_code text, p_brand text, p_pack numeric)
returns text language sql immutable as $$
  select p_code || ' · ' || coalesce(p_brand, '') || ' · ' || coalesce(core.vn_num(p_pack) || ' m/cuộn', 'cuộn lẻ')
$$;

create or replace function inv.fg_check_delivery(p_delivery uuid)
returns void language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare i record; v_free int;
begin
  if not exists (select 1 from sales.delivery_items where delivery_id = p_delivery) then raise exception 'Lệnh giao chưa có dòng hàng'; end if;
  for i in select di.*, p.code from sales.delivery_items di join master.products p on p.id = di.product_id
           where di.delivery_id = p_delivery order by di.line_no loop
    v_free := inv.fg_free_coils(i.product_id, i.brand, i.pack_m, p_delivery);
    if v_free < i.coils then
      raise exception 'Kho thành phẩm chỉ còn % cuộn % (đã QC Đạt, đã nhập kho, chưa hứa giao): lệnh giao cần %',
        greatest(v_free, 0), inv.fg_label(i.code, i.brand, i.pack_m), i.coils;
    end if;
  end loop;
end $$;

-- Phiếu nhập kho thành phẩm: cuộn QC Đạt ở khu chờ QC chuyển vào khu lưu kho (Kế toán SX nhập từ phiếu giấy người giữ kho TP ký)
create or replace function app.fg_putaway(p jsonb)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public
set "TimeZone" = 'Asia/Ho_Chi_Minh' as $$
declare v_wh uuid := inv.wh('KTP'); k master.operators; e jsonb; pr master.products; v_brand text; v_pack numeric; v_n int; v_to uuid;
        v_doc uuid; v_no text; v_line int := 0; h record; v_got int; v_total int := 0; v_paper boolean;
begin
  v_paper := mfg.can_enter_slips() and inv.keeper_mode(v_wh) is null;
  if not (mfg.can_enter_slips() or inv.keeper_mode(v_wh) is not null) then
    raise exception 'Kế toán SX nhập phiếu nhập kho thành phẩm theo phiếu giấy người giữ kho TP ký';
  end if;
  if v_paper or nullif(trim(coalesce(p ->> 'keeper_code', '')), '') is not null then k := inv.fg_keeper(p ->> 'keeper_code'); end if;
  if coalesce(jsonb_array_length(p -> 'items'), 0) = 0 then raise exception 'Nhập số cuộn nhập kho của ít nhất một mã'; end if;
  v_no := core.next_no('NKTP');
  insert into inv.stock_docs (doc_no, doc_type, warehouse_id, to_warehouse_id, review_status, paper_no, receiver_code, note)
  values (v_no, 'TRANSFER', v_wh, v_wh, 'NA', nullif(trim(coalesce(p ->> 'paper_no', '')), ''), k.code,
          'Nhập kho thành phẩm (cuộn QC Đạt)' || coalesce(' · ' || k.code || ' ký nhận', ''))
  returning id into v_doc;
  for e in select * from jsonb_array_elements(p -> 'items') loop
    v_n := coalesce(nullif(e ->> 'coils', '')::int, 0);
    continue when v_n = 0;
    if v_n < 0 then raise exception 'Số cuộn phải > 0'; end if;
    select * into pr from master.products where code = upper(trim(coalesce(e ->> 'product_code', '')));
    if not found then raise exception 'Không có mã sản phẩm %', e ->> 'product_code'; end if;
    v_brand := upper(trim(coalesce(e ->> 'brand', '')));
    v_pack := nullif(e ->> 'pack_m', '')::numeric;
    v_to := coalesce(inv.loc(upper(trim(coalesce(e ->> 'location_code', '')))), inv.loc(case when v_brand = 'HEIZKA' then 'KTP-B' else 'KTP-A' end));
    if (select l.warehouse_id from inv.locations l where l.id = v_to) <> v_wh or (select l.kind from inv.locations l where l.id = v_to) not in ('STORE', 'SHIP') then
      raise exception 'Vị trí nhập phải là khu lưu kho thành phẩm';
    end if;
    v_got := 0;
    for h in select hu.id, hu.lot_id, hu.location_id, hu.qty from inv.handling_units hu join inv.lots l on l.id = hu.lot_id
             join inv.locations loc on loc.id = hu.location_id
             where hu.warehouse_id = v_wh and hu.status = 'ACTIVE' and l.item_kind = 'FG' and l.qc_status = 'PASSED' and loc.kind = 'QC'
               and l.product_id = pr.id and l.brand = v_brand and inv.fg_pack(hu.pack_m, hu.is_remnant, hu.qty, hu.init_qty) is not distinct from v_pack
             order by l.mfg_date nulls first, l.lot_no, hu.hu_no limit v_n loop
      v_line := v_line + 1; v_got := v_got + 1;
      insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, to_location_id, hu_id, qty)
      values (v_doc, v_line, h.lot_id, h.location_id, v_to, h.id, h.qty);
    end loop;
    if v_got < v_n then
      raise exception 'Khu chờ QC chỉ có % cuộn % đã QC Đạt (phiếu ghi %)', v_got, inv.fg_label(pr.code, v_brand, v_pack), v_n;
    end if;
    v_total := v_total + v_got;
  end loop;
  if v_total = 0 then raise exception 'Nhập số cuộn nhập kho của ít nhất một mã'; end if;
  perform inv._post(v_doc);
  return jsonb_build_object('doc_id', v_doc, 'doc_no', v_no, 'coils', v_total);
end $$;

-- Lệnh giao trực tiếp: khách, ngày giao, các dòng (mã, nhãn, quy cách mét/cuộn hoặc cuộn lẻ, số cuộn).
-- Lập khi nháp: Kinh doanh / Kế toán SX; chờ duyệt: Giám đốc (người duyệt) sửa, ghi lịch sử duyệt
create or replace function app.delivery_save(p_id uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = pg_catalog, public
set "TimeZone" = 'Asia/Ho_Chi_Minh' as $$
declare d sales.deliveries; r wf.approval_requests; e jsonb; pr master.products; v_line int := 0; v_id uuid; v_old text; v_new text;
        v_cust uuid := nullif(p ->> 'customer_id', '')::uuid; v_name text := nullif(trim(coalesce(p ->> 'customer_name', '')), '');
begin
  if p_id is null then
    if not wf.can_submit('DELIVERY') then raise exception 'Chỉ Kinh doanh hoặc Kế toán SX lập lệnh giao'; end if;
  else
    select * into d from sales.deliveries where id = p_id for update;
    if not found then raise exception 'Không tìm thấy lệnh giao'; end if;
    if d.so_id is not null then raise exception 'Lệnh giao theo đơn bán: sửa ở đơn bán'; end if;
    if d.status = 'DRAFT' then
      if not wf.can_submit('DELIVERY') then raise exception 'Chỉ Kinh doanh hoặc Kế toán SX sửa lệnh giao nháp'; end if;
    elsif d.status = 'PENDING_APPROVAL' then
      r := wf.review_request('DELIVERY', p_id);
    else
      raise exception 'Lệnh giao đã duyệt hoặc đã xuất: không sửa được';
    end if;
    select string_agg(inv.fg_label(pp.code, i.brand, i.pack_m) || ' × ' || i.coils, '; ' order by i.line_no) into v_old
      from sales.delivery_items i join master.products pp on pp.id = i.product_id where i.delivery_id = p_id;
  end if;
  if v_cust is not null then select name into v_name from core.partners where id = v_cust; end if;
  if v_name is null then raise exception 'Nhập khách hàng nhận hàng'; end if;
  if coalesce(jsonb_array_length(p -> 'items'), 0) = 0 then raise exception 'Nhập ít nhất một dòng: mã, nhãn, quy cách, số cuộn'; end if;
  if p_id is null then
    insert into sales.deliveries (delivery_no, so_id, ship_date, status, note, customer_id, customer_name)
    values (core.next_no('LG'), null, coalesce(nullif(p ->> 'ship_date', '')::date, current_date), 'DRAFT',
            nullif(trim(coalesce(p ->> 'note', '')), ''), v_cust, v_name)
    returning id into v_id;
  else
    v_id := p_id;
    update sales.deliveries set ship_date = coalesce(nullif(p ->> 'ship_date', '')::date, ship_date), note = nullif(trim(coalesce(p ->> 'note', '')), ''),
           customer_id = v_cust, customer_name = v_name where id = v_id;
    delete from sales.delivery_items where delivery_id = v_id;
  end if;
  for e in select * from jsonb_array_elements(p -> 'items') loop
    continue when nullif(trim(coalesce(e ->> 'product_code', '')), '') is null;
    select * into pr from master.products where code = upper(trim(e ->> 'product_code'));
    if not found then raise exception 'Không có mã sản phẩm %', e ->> 'product_code'; end if;
    if coalesce(nullif(e ->> 'coils', '')::int, 0) <= 0 then raise exception '%: số cuộn phải > 0', pr.code; end if;
    if nullif(e ->> 'pack_m', '')::numeric <= 0 then raise exception '%: quy cách mét/cuộn phải > 0', pr.code; end if;
    if exists (select 1 from sales.delivery_items x where x.delivery_id = v_id and x.product_id = pr.id
                and x.brand = coalesce(nullif(upper(trim(e ->> 'brand')), ''), pr.default_brand, 'KAVIX')
                and x.pack_m is not distinct from nullif(e ->> 'pack_m', '')::numeric) then
      raise exception '% trùng dòng (cùng nhãn, quy cách): gộp số cuộn vào một dòng', pr.code;
    end if;
    v_line := v_line + 1;
    insert into sales.delivery_items (delivery_id, line_no, product_id, brand, pack_m, coils, note)
    values (v_id, v_line, pr.id, coalesce(nullif(upper(trim(e ->> 'brand')), ''), pr.default_brand, 'KAVIX'),
            nullif(e ->> 'pack_m', '')::numeric, (e ->> 'coils')::int, nullif(trim(coalesce(e ->> 'note', '')), ''));
  end loop;
  if v_line = 0 then raise exception 'Nhập ít nhất một dòng: mã, nhãn, quy cách, số cuộn'; end if;
  if r.id is not null then
    perform inv.fg_check_delivery(v_id);
    select string_agg(inv.fg_label(pp.code, i.brand, i.pack_m) || ' × ' || i.coils, '; ' order by i.line_no) into v_new
      from sales.delivery_items i join master.products pp on pp.id = i.product_id where i.delivery_id = v_id;
    perform wf.log_review_edit(r.id, concat_ws('; ',
      case when v_old is distinct from v_new then 'hàng: ' || coalesce(v_new, '') end,
      case when d.ship_date is distinct from coalesce(nullif(p ->> 'ship_date', '')::date, d.ship_date) then 'ngày giao ' || to_char(nullif(p ->> 'ship_date', '')::date, 'DD/MM') end,
      case when d.customer_name is distinct from v_name then 'khách ' || v_name end));
    update wf.approval_requests set summary = left(app.delivery_summary(v_id), 500) where id = r.id;
  end if;
  return v_id;
end $$;

create or replace function app.delivery_summary(p_delivery uuid)
returns text language sql stable security definer set search_path = pg_catalog, public as $$
  select d.customer_name || ' · ' || coalesce(to_char(d.ship_date, 'DD/MM'), '') || ' · '
         || coalesce((select sum(i.coils) from sales.delivery_items i where i.delivery_id = d.id), 0) || ' cuộn: '
         || coalesce((select string_agg(inv.fg_label(p.code, i.brand, i.pack_m) || ' × ' || i.coils, '; ' order by i.line_no)
                        from sales.delivery_items i join master.products p on p.id = i.product_id where i.delivery_id = d.id), '')
  from sales.deliveries d where d.id = p_delivery
$$;

create or replace function app.delivery_submit(p_id uuid)
returns uuid language plpgsql security definer set search_path = pg_catalog, public as $$
declare d sales.deliveries;
begin
  select * into d from sales.deliveries where id = p_id;
  if not found then raise exception 'Không tìm thấy lệnh giao'; end if;
  return wf.submit('DELIVERY', p_id, d.delivery_no, app.delivery_summary(p_id));
end $$;

create or replace function app.delivery_cancel(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
declare d sales.deliveries;
begin
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do hủy lệnh giao'; end if;
  select * into d from sales.deliveries where id = p_id for update;
  if not found then raise exception 'Không tìm thấy lệnh giao'; end if;
  if d.status <> 'DRAFT' then raise exception 'Chỉ hủy được lệnh giao nháp (đang chờ duyệt: Giám đốc trả lại trước)'; end if;
  if not (wf.can_submit('DELIVERY') or d.created_by = auth.uid()) then raise exception 'Không có quyền hủy lệnh giao'; end if;
  update sales.deliveries set status = 'CANCELLED', note = left(coalesce(note || ' · ', '') || 'Hủy: ' || trim(p_reason), 500) where id = p_id;
end $$;

-- Xuất giao theo số cuộn: MES tự chọn cuộn QC Đạt, lô cũ trước; Kế toán SX nhập từ phiếu xuất người giữ kho TP ký
create or replace function app.delivery_ship(p_id uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = pg_catalog, public
set "TimeZone" = 'Asia/Ho_Chi_Minh' as $$
declare d sales.deliveries; v_wh uuid := inv.wh('KTP'); k master.operators; i record; e jsonb; v_n int; v_got int; v_m numeric;
        h record; v_doc uuid; v_line int := 0; v_paper boolean; v_short text; v_total int := 0; v_list text;
begin
  v_paper := mfg.can_enter_slips() and inv.keeper_mode(v_wh) is null;
  if not (mfg.can_enter_slips() or inv.keeper_mode(v_wh) is not null) then
    raise exception 'Kế toán SX nhập xuất giao theo phiếu xuất người giữ kho thành phẩm ký';
  end if;
  select * into d from sales.deliveries where id = p_id for update;
  if not found then raise exception 'Không tìm thấy lệnh giao'; end if;
  if d.so_id is not null then raise exception 'Lệnh giao theo đơn bán: xuất bằng cách quét bobin'; end if;
  if d.status <> 'APPROVED' then raise exception 'Lệnh giao chưa được Giám đốc duyệt hoặc đã xuất'; end if;
  if v_paper or nullif(trim(coalesce(p ->> 'giver_code', '')), '') is not null then k := inv.fg_keeper(p ->> 'giver_code'); end if;
  perform set_config('bmt.paper', 'on', true);
  insert into inv.stock_docs (doc_no, doc_type, warehouse_id, ref_type, ref_id, paper_no, receiver_code, note)
  values (core.next_no('XB'), 'SALE', v_wh, 'DELIVERY', p_id, nullif(trim(coalesce(p ->> 'paper_no', '')), ''), k.code,
          'Lệnh giao ' || d.delivery_no || ' · ' || d.customer_name || coalesce(' · ' || k.code || ' giao', ''))
  returning id into v_doc;
  for i in select di.*, pr.code from sales.delivery_items di join master.products pr on pr.id = di.product_id
           where di.delivery_id = p_id order by di.line_no loop
    select x into e from jsonb_array_elements(coalesce(p -> 'items', '[]')) x where (x ->> 'item_id')::uuid = i.id limit 1;
    v_n := coalesce(nullif(e ->> 'coils', '')::int, i.coils);
    if v_n < 0 or v_n > i.coils then raise exception '%: số cuộn xuất phải từ 0 đến % (theo lệnh giao)', inv.fg_label(i.code, i.brand, i.pack_m), i.coils; end if;
    v_got := 0; v_m := 0;
    for h in select hu.id, hu.lot_id, hu.location_id, hu.qty from inv.handling_units hu join inv.lots l on l.id = hu.lot_id
             join inv.locations loc on loc.id = hu.location_id
             where hu.warehouse_id = v_wh and hu.status = 'ACTIVE' and l.item_kind = 'FG' and l.qc_status = 'PASSED' and loc.kind in ('STORE', 'SHIP')
               and l.product_id = i.product_id and l.brand = i.brand and inv.fg_pack(hu.pack_m, hu.is_remnant, hu.qty, hu.init_qty) is not distinct from i.pack_m
               and coalesce((select sum(b.reserved_qty) from inv.stock_balances b where b.hu_key = hu.id), 0) = 0
             order by l.mfg_date nulls first, l.lot_no, hu.hu_no limit v_n loop
      v_line := v_line + 1; v_got := v_got + 1; v_m := v_m + h.qty;
      insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty) values (v_doc, v_line, h.lot_id, h.location_id, h.id, h.qty);
      insert into sales.delivery_lines (delivery_id, so_line_id, hu_id, lot_id, qty_m) values (p_id, null, h.id, h.lot_id, h.qty);
    end loop;
    if v_got < v_n then
      raise exception 'Kho chỉ còn % cuộn % QC Đạt đã nhập kho (phiếu xuất ghi %)', v_got, inv.fg_label(i.code, i.brand, i.pack_m), v_n;
    end if;
    update sales.delivery_items set shipped_coils = v_got, shipped_m = v_m where id = i.id;
    v_total := v_total + v_got;
    if v_got < i.coils then
      v_short := concat_ws('; ', v_short, inv.fg_label(i.code, i.brand, i.pack_m) || ' giao ' || v_got || '/' || i.coils);
    end if;
  end loop;
  if v_total = 0 then raise exception 'Nhập số cuộn đã xuất'; end if;
  perform inv._post(v_doc);
  perform set_config('bmt.paper', 'off', true);
  update sales.deliveries set status = 'SHIPPED', stock_doc_id = v_doc, shipped_at = now(), shipped_by = auth.uid(),
         paper_no = nullif(trim(coalesce(p ->> 'paper_no', '')), ''), giver_code = k.code
   where id = p_id;
  select string_agg(inv.fg_label(pr.code, di.brand, di.pack_m) || ' × ' || di.shipped_coils, '; ' order by di.line_no) into v_list
    from sales.delivery_items di join master.products pr on pr.id = di.product_id where di.delivery_id = p_id and di.shipped_coils > 0;
  perform wf.notify_users(array_remove(array[d.created_by], auth.uid()) || inv.role_users(array['BGD']),
    'Đã xuất giao ' || d.delivery_no || ' · ' || d.customer_name,
    left(v_total || ' cuộn: ' || coalesce(v_list, '') || coalesce('. Giao thiếu: ' || v_short, ''), 500), '/kho/xuat-ban/' || p_id);
  return v_doc;
end $$;

-- Cắt cuộn, nhận hàng khách trả theo phiếu giấy (Kế toán SX nhập, người giữ kho TP ký)
create or replace function app.fg_split(p jsonb)
returns uuid language plpgsql security definer set search_path = pg_catalog, public as $$
declare k master.operators; v_doc uuid; v_parts numeric[];
begin
  if not (mfg.can_enter_slips() or inv.keeper_mode(inv.wh('KTP')) is not null) then raise exception 'Kế toán SX nhập phiếu cắt cuộn theo phiếu giấy'; end if;
  if mfg.can_enter_slips() and inv.keeper_mode(inv.wh('KTP')) is null or nullif(trim(coalesce(p ->> 'keeper_code', '')), '') is not null then
    k := inv.fg_keeper(p ->> 'keeper_code');
  end if;
  select array_agg(x::numeric) into v_parts from jsonb_array_elements_text(coalesce(p -> 'parts', '[]')) x;
  perform set_config('bmt.paper', 'on', true);
  v_doc := inv.split_hu((p ->> 'hu_id')::uuid, v_parts, coalesce(nullif(p ->> 'scrap_m', '')::numeric, 0), p ->> 'reason');
  perform set_config('bmt.paper', 'off', true);
  update inv.handling_units set pack_m = null where parent_hu_id = (p ->> 'hu_id')::uuid and pack_m is null;
  update inv.stock_docs set paper_no = nullif(trim(coalesce(p ->> 'paper_no', '')), ''), receiver_code = k.code,
         note = note || coalesce(' · ' || k.code || ' cắt', '') where id = v_doc;
  return v_doc;
end $$;

create or replace function app.fg_customer_return(p jsonb)
returns uuid language plpgsql security definer set search_path = pg_catalog, public as $$
declare k master.operators; v_doc uuid;
begin
  if not (mfg.can_enter_slips() or inv.keeper_mode(inv.wh('KTP')) is not null) then raise exception 'Kế toán SX nhập hàng khách trả theo phiếu giấy'; end if;
  if mfg.can_enter_slips() and inv.keeper_mode(inv.wh('KTP')) is null or nullif(trim(coalesce(p ->> 'keeper_code', '')), '') is not null then
    k := inv.fg_keeper(p ->> 'keeper_code');
  end if;
  perform set_config('bmt.paper', 'on', true);
  v_doc := inv.customer_return((p ->> 'product_id')::uuid, p ->> 'brand', (p ->> 'qty_m')::numeric, null, null, p ->> 'note');
  perform set_config('bmt.paper', 'off', true);
  update inv.stock_docs set paper_no = nullif(trim(coalesce(p ->> 'paper_no', '')), ''), receiver_code = k.code,
         note = note || coalesce(' · ' || k.code || ' nhận', '') where id = v_doc;
  return v_doc;
end $$;

-- Xuất bán theo lệnh giao trực tiếp (không có đơn bán): không đụng tới hàng đang giữ cho đơn bán
do $$
declare d text; v_from text := $f$    if d.doc_type = 'SALE' and not v_rev then$f$;
begin
  d := replace(pg_get_functiondef('inv._post(uuid)'::regprocedure), E'\r', '');
  if position('(d.ref_type = ''DELIVERY'' and v_so is null)' in d) > 0 then return; end if;   -- đã sửa
  if position(v_from in d) = 0 then raise exception 'inv._post: không tìm thấy đoạn xuất bán để sửa'; end if;
  execute replace(d, v_from, $f$    if d.doc_type = 'SALE' and not v_rev and not (d.ref_type = 'DELIVERY' and v_so is null) then$f$);
end $$;

-- Cuộn thành phẩm từng chiếc và tồn thành phẩm theo chủng loại (mã, nhãn, quy cách) – đếm số cuộn
create or replace view app.v_fg_coils with (security_invoker = true) as
select h.id, h.hu_no, l.id as lot_id, l.lot_no, l.product_id, p.code as product_code, p.description as product_name, l.brand,
       l.mfg_date, l.qc_status, h.qty, h.init_qty, h.pack_m as nominal_pack_m, h.pack_type, h.is_remnant,
       inv.fg_pack(h.pack_m, h.is_remnant, h.qty, h.init_qty) as pack_m,
       loc.code as location_code, loc.kind as location_kind, h.location_id,
       coalesce((select sum(b.reserved_qty) from inv.stock_balances b where b.hu_key = h.id), 0) as reserved_qty
from inv.handling_units h
join inv.lots l on l.id = h.lot_id
join master.products p on p.id = l.product_id
join inv.warehouses w on w.id = h.warehouse_id
left join inv.locations loc on loc.id = h.location_id
where w.code = 'KTP' and h.status = 'ACTIVE' and l.item_kind = 'FG';

create or replace view app.v_fg_stock with (security_invoker = true) as
select c.product_id, c.product_code, c.product_name, c.brand, c.pack_m, max(c.pack_type) as pack_type,
       count(*) filter (where c.location_kind = 'QC' and c.qc_status = 'PENDING') as qc_wait_coils,
       count(*) filter (where c.location_kind = 'QC' and c.qc_status = 'PASSED') as putaway_coils,
       coalesce(sum(c.qty) filter (where c.location_kind = 'QC' and c.qc_status = 'PASSED'), 0) as putaway_m,
       count(*) filter (where c.location_kind in ('STORE', 'SHIP') and c.qc_status = 'PASSED') as store_coils,
       coalesce(sum(c.qty) filter (where c.location_kind in ('STORE', 'SHIP') and c.qc_status = 'PASSED'), 0) as store_m,
       count(*) filter (where c.qc_status in ('QUARANTINE', 'REJECTED') or c.location_kind = 'RETURN') as hold_coils,
       count(*) as total_coils, coalesce(sum(c.qty), 0) as total_m,
       inv.fg_committed(c.product_id, c.brand, c.pack_m, null) as committed_coils,
       greatest(count(*) filter (where c.location_kind in ('STORE', 'SHIP') and c.qc_status = 'PASSED' and c.reserved_qty = 0)
                - inv.fg_committed(c.product_id, c.brand, c.pack_m, null), 0) as free_coils,
       min(c.mfg_date) as oldest_mfg_date
from app.v_fg_coils c
group by c.product_id, c.product_code, c.product_name, c.brand, c.pack_m;

-- Lệnh giao: cả lệnh theo đơn bán (cũ) và lệnh trực tiếp
create or replace view app.v_deliveries with (security_invoker = true) as
select dv.id, dv.delivery_no, dv.status, dv.ship_date, dv.note, dv.created_at, dv.stock_doc_id,
       so.id as so_id, so.so_no,
       coalesce(so.label_brand, (select string_agg(distinct i.brand, ', ') from sales.delivery_items i where i.delivery_id = dv.id)) as label_brand,
       coalesce(cu.name, cu2.name, dv.customer_name) as customer_name,
       app.user_name(dv.created_by) as created_by_name,
       (select count(*) from sales.delivery_lines x where x.delivery_id = dv.id) as reel_count,
       (select sum(x.qty_m) from sales.delivery_lines x where x.delivery_id = dv.id) as total_m,
       (select ar.id from wf.approval_requests ar where ar.doc_id = dv.id order by ar.submitted_at desc limit 1) as approval_id,
       dv.customer_id, (dv.so_id is null) as direct,
       coalesce((select sum(i.coils) from sales.delivery_items i where i.delivery_id = dv.id), 0) as coil_count,
       coalesce((select sum(i.shipped_coils) from sales.delivery_items i where i.delivery_id = dv.id), 0) as shipped_coils,
       dv.paper_no, dv.giver_code, (select o.full_name from master.operators o where o.code = dv.giver_code) as giver_name,
       dv.shipped_at, app.user_name(dv.shipped_by) as shipped_by_name, dv.created_by
from sales.deliveries dv
left join sales.sales_orders so on so.id = dv.so_id
left join core.partners cu on cu.id = so.customer_id
left join core.partners cu2 on cu2.id = dv.customer_id;

create or replace view app.v_delivery_items with (security_invoker = true) as
select i.id, i.delivery_id, i.line_no, i.product_id, p.code as product_code, p.description as product_name, i.brand, i.pack_m,
       i.coils, i.shipped_coils, i.shipped_m, i.note,
       inv.fg_free_coils(i.product_id, i.brand, i.pack_m, i.delivery_id) as free_coils
from sales.delivery_items i join master.products p on p.id = i.product_id;
grant select on app.v_fg_coils, app.v_fg_stock, app.v_deliveries, app.v_delivery_items to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Quyền gọi hàm
-- ---------------------------------------------------------------------------
revoke execute on function purchase.po_from_mrp(uuid, uuid), purchase.po_approved(uuid), plan.auto_po_on_approve(),
  inv.scrap_to_stock(date, uuid, uuid), inv.opening_carriers(uuid), inv.fg_check_delivery(uuid)
  from public, anon, authenticated;
revoke execute on function app.po_from_mrp(uuid), app.po_from_pr(uuid), app.po_save_header(uuid, uuid, date, text, text, boolean),
  app.po_save_line(uuid, uuid, text, numeric, numeric, date, text), app.po_delete_line(uuid), app.po_move_lines(uuid, uuid[], uuid),
  app.po_cancel(uuid, text), app.save_supplier(text, text, text, text), app.fg_putaway(jsonb), app.delivery_save(uuid, jsonb),
  app.delivery_submit(uuid), app.delivery_cancel(uuid, text), app.delivery_ship(uuid, jsonb), app.fg_split(jsonb),
  app.fg_customer_return(jsonb), app.delivery_summary(uuid), purchase.material_terms(uuid), purchase.po_edit_request(uuid),
  inv.fg_keeper(text), inv.fg_committed(uuid, text, numeric, uuid), inv.fg_free_coils(uuid, text, numeric, uuid), inv.is_recon_doc(uuid)
  from public, anon;
grant execute on function app.po_from_mrp(uuid), app.po_from_pr(uuid), app.po_save_header(uuid, uuid, date, text, text, boolean),
  app.po_save_line(uuid, uuid, text, numeric, numeric, date, text), app.po_delete_line(uuid), app.po_move_lines(uuid, uuid[], uuid),
  app.po_cancel(uuid, text), app.save_supplier(text, text, text, text), app.fg_putaway(jsonb), app.delivery_save(uuid, jsonb),
  app.delivery_submit(uuid), app.delivery_cancel(uuid, text), app.delivery_ship(uuid, jsonb), app.fg_split(jsonb),
  app.fg_customer_return(jsonb), app.delivery_summary(uuid), purchase.material_terms(uuid), purchase.po_edit_request(uuid),
  inv.fg_keeper(text), inv.fg_committed(uuid, text, numeric, uuid), inv.fg_free_coils(uuid, text, numeric, uuid), inv.is_recon_doc(uuid),
  inv.fg_pack(numeric, boolean, numeric, numeric), inv.fg_label(text, text, numeric)
  to authenticated;

-- Đã có đơn mua tự sinh từ kết quả MRP: khóa kết quả MRP (NV mua, người duyệt sửa số mua trên đơn mua)
create or replace function plan.mrp_lock_reason(p_run uuid)
returns text language sql stable security definer set search_path = pg_catalog, public as $$
  select case
    when pp.status not in ('DRAFT', 'PENDING_APPROVAL', 'APPROVED') then 'Kế hoạch đang ở trạng thái ' || pp.status || ': không sửa kết quả MRP'
    when pp.mrp_stale then 'Dòng kế hoạch đã thay đổi: chạy lại MRP trước khi điều chỉnh'
    when r.id <> (select r2.id from plan.mrp_runs r2 where r2.plan_id = pp.id order by r2.run_at desc limit 1)
      then 'Đây không phải lần chạy MRP mới nhất'
    when exists (select 1 from purchase.purchase_requests pr where pr.mrp_run_id = r.id and pr.status <> 'CANCELLED')
      then 'Đã sinh đề xuất mua từ kết quả này'
    when exists (select 1 from purchase.purchase_orders po where po.mrp_run_id = r.id and po.status <> 'CANCELLED')
      then 'Đã sinh đơn mua hàng từ kết quả này: sửa số mua trên đơn mua'
  end
  from plan.mrp_runs r join plan.production_plans pp on pp.id = r.plan_id where r.id = p_run
$$;

-- Nhân sự xưởng: TP SX khai báo người giữ kho thành phẩm (ký phiếu nhập kho TP, phiếu xuất giao; "NV3 là biến số")
create or replace function app.kh_set_fg_keeper(p_code text, p_on boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
declare o master.operators;
begin
  if not plan.can_staff() then raise exception 'Chỉ TP SX / Kế hoạch SX quản lý nhân sự xưởng'; end if;
  select * into o from master.operators where code = upper(trim(coalesce(p_code, ''))) for update;
  if not found then raise exception 'Không tìm thấy người %', p_code; end if;
  if p_on and not o.active then raise exception '% đã ngừng làm: không giao giữ kho', o.code; end if;
  if o.keeps_fg = p_on then return; end if;
  update master.operators set keeps_fg = p_on where code = o.code;
  perform app.kh_log('Nhân sự xưởng', o.code || coalesce(' ' || o.full_name, ''), case when o.keeps_fg then 'Giữ kho TP' else 'Không giữ kho TP' end,
    case when p_on then 'Giữ kho TP' else 'Không giữ kho TP' end, coalesce(nullif(trim(coalesce(p_reason, '')), ''), 'Khai báo người giữ kho thành phẩm'));
  perform wf.notify_users(inv.role_users(array['KT_KHO']), 'Người giữ kho thành phẩm: ' || o.code || case when p_on then ' được giao' else ' thôi giữ' end,
    'Phiếu nhập kho TP, phiếu xuất giao do người giữ kho TP ký; Kế toán SX chọn đúng người khi nhập vào MES.', '/kho/thanh-pham');
end $$;
revoke execute on function app.kh_set_fg_keeper(text, boolean, text) from public, anon;
grant execute on function app.kh_set_fg_keeper(text, boolean, text) to authenticated;

-- Danh sách người giữ kho thành phẩm (để Kế toán SX chọn người ký trên phiếu nhập kho TP, phiếu xuất giao, cắt cuộn)
create or replace function app.fg_keepers()
returns table (code text, full_name text) language sql stable security definer set search_path = pg_catalog, public as $$
  select o.code, o.full_name from master.operators o
   where o.keeps_fg and o.active and (core.has_perm('inventory', 'view') or core.has_perm('sales', 'view'))
   order by o.sort, o.code
$$;
revoke execute on function app.fg_keepers() from public, anon;
grant execute on function app.fg_keepers() to authenticated;

-- Phiếu hoàn thành: thêm số cuộn (đóng gói nhiều cuộn trên một phiếu)
do $$
declare d text; i int;
begin
  d := pg_get_viewdef('app.v_bobbin_slips'::regclass);
  if position('coils' in d) > 0 then return; end if;
  i := position(E'\n   FROM ' in d);
  if i = 0 then raise exception 'app.v_bobbin_slips: không tìm thấy FROM chính'; end if;
  execute 'create or replace view app.v_bobbin_slips with (security_invoker = true) as ' || substr(d, 1, i - 1) || ', s.coils' || substr(d, i);
end $$;
