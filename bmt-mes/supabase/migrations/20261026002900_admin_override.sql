-- BMT MES · 2900 · Quyền can thiệp của Quản trị hệ thống (yêu cầu 26/10/2026)
-- Quản trị hệ thống (vai trò ADMIN gán trực tiếp, không nhận qua ủy quyền) được:
--  1. Hủy bất kỳ quy trình duyệt đang chạy: yêu cầu duyệt → Đã hủy, chứng từ về trạng thái khi bị trả lại (thường là Nháp).
--  2. Mở lại chứng từ (kể cả đã duyệt) về Nháp để sửa, rồi gửi duyệt lại.
--  3. Xóa chứng từ: đề xuất mua (PR), PO, đơn bán (SO), kế hoạch tháng, đề xuất mua tối ưu, spec chưa phát hành, đơn phát sinh.
-- Bắt buộc ghi lý do; toàn bộ nội dung trước khi sửa/xóa lưu vào core.audit_log để truy vết; người lập nhận thông báo.
-- Không mở lại / xóa khi chứng từ đã sinh nghiệp vụ sau (PR đã lên PO, PO đã nhận hàng, SO đã giao, kế hoạch đã có lệnh SX…):
-- phải xử lý chứng từ sau trước. Phiếu kho đã ghi sổ và lệnh SX không xóa ở đây (dùng phiếu đảo / hủy phiếu sẵn có).

create or replace function core.is_admin() returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select exists (select 1 from core.user_roles ur join core.profiles p on p.id = ur.user_id
                 where ur.user_id = auth.uid() and ur.role_code = 'ADMIN' and p.status = 'ACTIVE')
$$;
revoke all on function core.is_admin() from public, anon;
grant execute on function core.is_admin() to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 1. Hủy quy trình duyệt đang chạy
-- ---------------------------------------------------------------------------
create or replace function app.admin_cancel_request(p_request uuid, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r wf.approval_requests; f wf.approval_flows; v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  if not core.is_admin() then raise exception 'Chỉ Quản trị hệ thống được hủy quy trình duyệt'; end if;
  if v_reason is null then raise exception 'Nhập lý do hủy quy trình'; end if;
  select * into r from wf.approval_requests where id = p_request for update;
  if not found then raise exception 'Không tìm thấy quy trình duyệt'; end if;
  if r.status <> 'PENDING' then raise exception 'Quy trình đã kết thúc (%), không hủy được', r.status; end if;
  select * into f from wf.approval_flows where doc_type = r.doc_type;
  update wf.approval_requests set status = 'CANCELLED', finished_at = now() where id = r.id;
  insert into wf.approval_actions (request_id, seq, action, comment, data_hash)
  values (r.id, coalesce(r.current_seq, 0), 'COMMENT', '[Quản trị hủy quy trình] ' || v_reason, r.data_hash);
  execute format('update %s set %I = $1 where id = $2', f.doc_table::regclass, f.status_col) using f.rejected_status, r.doc_id;
  insert into core.audit_log (user_id, table_name, row_id, action, new_data)
  values (auth.uid(), 'wf.approval_requests', r.id::text, 'ADMIN_CANCEL',
          jsonb_build_object('doc_type', r.doc_type, 'doc_id', r.doc_id, 'doc_no', r.doc_no, 'reason', v_reason));
  if r.submitted_by is distinct from auth.uid() then
    insert into wf.notifications (user_id, title, body, link)
    values (r.submitted_by, 'Quản trị đã hủy quy trình duyệt: ' || r.doc_no, v_reason, '/duyet/' || r.id);
  end if;
end $$;
revoke all on function app.admin_cancel_request(uuid, text) from public, anon;
grant execute on function app.admin_cancel_request(uuid, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2 + 3. Mở lại để sửa / xóa chứng từ
-- ---------------------------------------------------------------------------
create or replace function app.admin_doc(p_doc_type text, p_doc_id uuid, p_action text, p_reason text) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_table text; v_rel regclass; v_old jsonb; v_lines jsonb; v_no text; v_creator uuid; v_ref text; q record;
begin
  if not core.is_admin() then raise exception 'Chỉ Quản trị hệ thống được mở lại hoặc xóa chứng từ'; end if;
  if v_reason is null then raise exception 'Nhập lý do'; end if;
  if p_action not in ('reopen', 'delete') then raise exception 'Thao tác không hợp lệ'; end if;
  if p_doc_type not in ('PR', 'PO', 'SO', 'PLAN', 'PROPOSAL', 'SPEC_NEW', 'SPEC_MINOR', 'DPS') then
    raise exception 'Loại chứng từ này không mở lại/xóa ở đây: phiếu kho đã ghi sổ dùng phiếu đảo, lệnh SX và phiếu lĩnh dùng chức năng hủy sẵn có';
  end if;
  if p_doc_type = 'DPS' and p_action = 'reopen' then raise exception 'Đơn phát sinh không mở lại được: xóa rồi lập đơn mới'; end if;
  v_table := case when p_doc_type = 'DPS' then 'plan.change_requests' else (select doc_table from wf.approval_flows where doc_type = p_doc_type) end;
  v_rel := v_table::regclass;
  execute format('select to_jsonb(t) from %s t where id = $1', v_rel) into v_old using p_doc_id;
  if v_old is null then raise exception 'Không tìm thấy chứng từ'; end if;
  v_no := coalesce(wf.doc_number(v_table, p_doc_id), v_old ->> 'req_no', p_doc_type);
  v_creator := nullif(v_old ->> 'created_by', '')::uuid;

  -- Chứng từ đã sinh nghiệp vụ sau: phải xử lý chứng từ sau trước
  if p_doc_type = 'PR' then
    select string_agg(distinct po.po_no, ', ') into v_ref from purchase.pr_lines l
      join purchase.po_lines pl on pl.pr_line_id = l.id join purchase.purchase_orders po on po.id = pl.po_id where l.pr_id = p_doc_id;
    if v_ref is not null then raise exception 'Đề xuất % đã lên PO %: xử lý PO trước', v_no, v_ref; end if;
    v_lines := (select jsonb_agg(to_jsonb(l)) from purchase.pr_lines l where l.pr_id = p_doc_id);
  elsif p_doc_type = 'PO' then
    select string_agg(gr_no, ', ') into v_ref from purchase.goods_receipts where po_id = p_doc_id;
    if v_ref is not null then raise exception 'PO % đã nhận hàng (%): không mở lại/xóa được', v_no, v_ref; end if;
    v_lines := (select jsonb_agg(to_jsonb(l)) from purchase.po_lines l where l.po_id = p_doc_id);
  elsif p_doc_type = 'SO' then
    select string_agg(delivery_no, ', ') into v_ref from sales.deliveries where so_id = p_doc_id and status <> 'CANCELLED';
    if v_ref is not null then raise exception 'Đơn bán % đã có lệnh giao %: xử lý lệnh giao trước', v_no, v_ref; end if;
    select string_agg(distinct p.plan_no, ', ') into v_ref from sales.so_lines l
      join plan.plan_lines pl on pl.so_line_id = l.id join plan.production_plans p on p.id = pl.plan_id where l.so_id = p_doc_id;
    if v_ref is not null then raise exception 'Đơn bán % đã đưa vào kế hoạch %: sửa kế hoạch trước', v_no, v_ref; end if;
    v_lines := (select jsonb_agg(to_jsonb(l)) from sales.so_lines l where l.so_id = p_doc_id);
  elsif p_doc_type = 'PLAN' then
    select string_agg(w.wo_no, ', ') into v_ref from mfg.work_orders w join plan.plan_lines l on l.id = w.plan_line_id where l.plan_id = p_doc_id;
    if v_ref is not null then raise exception 'Kế hoạch % đã có lệnh SX %: không mở lại/xóa được', v_no, v_ref; end if;
    v_lines := (select jsonb_agg(to_jsonb(l)) from plan.plan_lines l where l.plan_id = p_doc_id);
  elsif p_doc_type = 'PROPOSAL' then
    select string_agg(distinct po.po_no, ', ') into v_ref from plan.proposal_lines l
      join purchase.po_lines pl on pl.proposal_line_id = l.id join purchase.purchase_orders po on po.id = pl.po_id where l.proposal_id = p_doc_id;
    if v_ref is not null then raise exception 'Đề xuất mua tối ưu % đã lên PO %: xử lý PO trước', v_no, v_ref; end if;
    v_lines := (select jsonb_agg(to_jsonb(l)) from plan.proposal_lines l where l.proposal_id = p_doc_id);
  elsif p_doc_type like 'SPEC%' then
    if v_old ->> 'status' in ('RELEASED', 'OBSOLETE') then
      raise exception 'Spec % đã phát hành: tạo phiên bản mới thay vì mở lại/xóa', v_no;
    end if;
    v_lines := (select jsonb_agg(to_jsonb(l)) from master.bom_lines l join master.bom_headers h on h.id = l.bom_id where h.spec_id = p_doc_id);
  end if;

  -- Dừng quy trình duyệt đang chạy của chứng từ (nếu có)
  for q in select * from wf.approval_requests where doc_id = p_doc_id and status = 'PENDING' for update loop
    update wf.approval_requests set status = 'CANCELLED', finished_at = now() where id = q.id;
    insert into wf.approval_actions (request_id, seq, action, comment, data_hash)
    values (q.id, coalesce(q.current_seq, 0), 'COMMENT',
            '[Quản trị ' || case p_action when 'delete' then 'xóa chứng từ' else 'mở lại để sửa' end || '] ' || v_reason, q.data_hash);
  end loop;

  if p_action = 'reopen' then
    execute format('update %s set status = ''DRAFT'' where id = $1', v_rel) using p_doc_id;
  else
    if p_doc_type = 'PLAN' then
      select string_agg(pr.pr_no, ', ') into v_ref from purchase.purchase_requests pr
        join plan.mrp_runs m on m.id = pr.mrp_run_id where m.plan_id = p_doc_id;
      if v_ref is not null then raise exception 'Kế hoạch % đã sinh đề xuất mua %: xóa các đề xuất đó trước', v_no, v_ref; end if;
      update plan.production_plans set previous_id = null where previous_id = p_doc_id;
      delete from plan.daily_releases where plan_id = p_doc_id;
      delete from plan.mrp_line_edits where plan_id = p_doc_id;
      delete from plan.mrp_runs where plan_id = p_doc_id;
    elsif p_doc_type = 'SO' then
      delete from sales.deliveries where so_id = p_doc_id and status = 'CANCELLED';
    end if;
    begin
      execute format('delete from %s where id = $1', v_rel) using p_doc_id;
    exception when foreign_key_violation then
      raise exception 'Không xóa được % vì dữ liệu khác đang dùng (%): mở lại để sửa hoặc xử lý chứng từ liên quan trước',
        v_no, coalesce(substring(sqlerrm from 'on table "([^"]+)"'), 'chứng từ liên quan');
    end;
  end if;

  insert into core.audit_log (user_id, table_name, row_id, action, old_data, new_data)
  values (auth.uid(), v_table, p_doc_id::text, case p_action when 'delete' then 'ADMIN_DELETE' else 'ADMIN_REOPEN' end,
          jsonb_build_object('doc', v_old, 'lines', v_lines),
          jsonb_build_object('doc_type', p_doc_type, 'doc_no', v_no, 'reason', v_reason));
  if v_creator is not null and v_creator <> auth.uid() and exists (select 1 from core.profiles where id = v_creator) then
    insert into wf.notifications (user_id, title, body, link)
    values (v_creator, case p_action when 'delete' then 'Quản trị đã xóa ' else 'Quản trị đã mở lại để sửa ' end || v_no, v_reason, null);
  end if;
  return v_no;
end $$;
revoke all on function app.admin_doc(text, uuid, text, text) from public, anon;
grant execute on function app.admin_doc(text, uuid, text, text) to authenticated, service_role;

-- Nhật ký can thiệp của Quản trị (xem ở trang Quản trị)
create or replace function app.admin_overrides(p_limit integer default 50)
returns table (at timestamptz, actor text, action text, doc_type text, doc_no text, reason text)
language sql stable security definer set search_path = pg_catalog, public as $$
  select a.at, app.user_name(a.user_id), a.action, a.new_data ->> 'doc_type', a.new_data ->> 'doc_no', a.new_data ->> 'reason'
  from core.audit_log a
  where a.action in ('ADMIN_CANCEL', 'ADMIN_REOPEN', 'ADMIN_DELETE') and core.has_perm('admin', 'view')
  order by a.at desc limit least(greatest(coalesce(p_limit, 50), 1), 500)
$$;
revoke all on function app.admin_overrides(integer) from public, anon;
grant execute on function app.admin_overrides(integer) to authenticated, service_role;
