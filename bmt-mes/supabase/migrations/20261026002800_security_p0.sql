-- BMT MES · 2800 · Vá bảo mật nhóm P0 (kiểm thử độc lập 26/10/2026)
--  1. wf.doc_hash: ghép thẳng tên bảng vào câu lệnh động → người đã đăng nhập chèn được SQL, đọc được mọi bảng.
--     Chỉ nhận bảng có trong cấu hình quy trình, đọc qua regclass; thu quyền gọi của người dùng (chỉ wf.submit / wf.act dùng).
--  2. wf.submit: không kiểm chứng từ → ai cũng gửi duyệt lại được chứng từ đã duyệt hoặc tạo yêu cầu duyệt cho chứng từ không tồn tại.
--     Nay kiểm: chứng từ tồn tại, đang ở trạng thái được gửi (Nháp / trả lại / kẹt chờ duyệt mà không còn yêu cầu nào chạy),
--     người gửi có quyền lập; số chứng từ đọc từ bảng.
--  3. Thu quyền gọi trực tiếp wf.notify_role (gửi thông báo tùy ý tới cả một vai trò) và app.kh_log (ghi nhật ký tham số giả).
--     Hai hàm chỉ được gọi bên trong hàm hệ thống (SECURITY DEFINER), không bị ảnh hưởng.

-- ---------------------------------------------------------------------------
-- 1. Mã kiểm chứng từ
-- ---------------------------------------------------------------------------
create or replace function wf.doc_hash(p_table text, p_id uuid) returns text
language plpgsql stable security definer set search_path = pg_catalog, public set timezone = 'UTC' as $$
declare v jsonb; v_rel regclass;
begin
  if not exists (select 1 from wf.approval_flows where doc_table = p_table) then
    raise exception 'Bảng không thuộc quy trình duyệt nào';
  end if;
  v_rel := p_table::regclass;
  execute format('select to_jsonb(t) - array[''status'',''updated_at'',''updated_by'',''current_spec_id'',''mrp_stale'',''sched_start''] from %s t where id = $1', v_rel)
    into v using p_id;
  return md5(v::text);
end $$;
revoke all on function wf.doc_hash(text, uuid) from public, anon, authenticated;
grant execute on function wf.doc_hash(text, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Gửi duyệt
-- ---------------------------------------------------------------------------
-- Quyền lập chứng từ theo loại quy trình (dùng khi quy trình chưa cấu hình riêng người/vai trò được gửi)
create or replace function wf.can_submit(p_doc_type text) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce(case p_doc_type
    when 'PR'          then core.has_perm('purchase', 'create') or core.has_role('BGD')
    when 'PO'          then core.has_perm('purchase', 'create')
    when 'PROPOSAL'    then core.has_perm('purchase', 'create') or core.has_perm('plan', 'create')
    when 'SO'          then core.has_perm('sales', 'create')
    when 'SPEC_NEW'    then core.has_perm('spec', 'create')
    when 'SPEC_MINOR'  then core.has_perm('spec', 'create')
    when 'PLAN'        then core.has_role('BGD') or core.has_perm('plan', 'create')
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
revoke all on function wf.can_submit(text) from public, anon;
grant execute on function wf.can_submit(text) to authenticated, service_role;

-- Số chứng từ đọc từ chính bảng chứng từ (cột *_no đầu tiên); spec ghép "SPEC <mã> v<phiên bản>"
create or replace function wf.doc_number(p_table text, p_id uuid) returns text
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_rel regclass := p_table::regclass; v_col name; v_no text;
begin
  if p_table = 'master.product_specs' then
    select 'SPEC ' || p.code || ' v' || s.version into v_no
      from master.product_specs s join master.products p on p.id = s.product_id where s.id = p_id;
    return v_no;
  end if;
  select a.attname into v_col from pg_attribute a
   where a.attrelid = v_rel and a.attnum > 0 and not a.attisdropped and a.attname like '%\_no'
   order by a.attnum limit 1;
  if v_col is null then return null; end if;
  execute format('select %I::text from %s where id = $1', v_col, v_rel) into v_no using p_id;
  return v_no;
end $$;
revoke all on function wf.doc_number(text, uuid) from public, anon, authenticated;
grant execute on function wf.doc_number(text, uuid) to service_role;

create or replace function wf.submit(p_doc_type text, p_doc_id uuid, p_doc_no text, p_summary text default null) returns uuid
language plpgsql security definer set search_path = wf, core, public as $$
declare f wf.approval_flows; v_req uuid; v_snap jsonb; v_first jsonb; v_issues text[]; v_stale boolean; v_rows int;
        v_status text; v_from text[]; v_no text; v_summary text := left(nullif(trim(coalesce(p_summary, '')), ''), 500);
begin
  select * into f from wf.approval_flows where doc_type = p_doc_type;
  if not found then raise exception 'Chưa cấu hình luồng duyệt cho %', p_doc_type; end if;
  if not f.active then raise exception 'Quy trình "%" đã ngưng sử dụng', f.name; end if;
  if cardinality(f.submit_user_ids) > 0 and not auth.uid() = any(f.submit_user_ids) then
    raise exception 'Bạn không được giao bước "%" của quy trình này', f.submit_label;
  end if;
  if f.submit_role is not null and not core.has_role(f.submit_role) then
    raise exception 'Bước "%" cần vai trò %', f.submit_label, coalesce((select name from core.roles where code = f.submit_role), f.submit_role);
  end if;
  perform wf.check_doc(p_doc_type, p_doc_id);   -- phiếu kho, lệnh giao: đúng loại phiếu, đang Nháp
  -- Quy trình chưa giao riêng người/vai trò lập: người gửi phải có quyền lập chứng từ loại này
  if f.submit_role is null and cardinality(f.submit_user_ids) = 0 and not wf.can_submit(p_doc_type) then
    raise exception 'Bạn không có quyền gửi duyệt "%"', f.name;
  end if;
  -- Chứng từ phải tồn tại và đang ở trạng thái được gửi duyệt (Nháp, hoặc trạng thái sau khi bị trả lại)
  execute format('select %I::text from %s where id = $1', f.status_col, f.doc_table::regclass) into v_status using p_doc_id;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then raise exception 'Không tìm thấy chứng từ cần gửi duyệt'; end if;
  -- Được gửi lại khi chứng từ kẹt ở "chờ duyệt" mà không còn yêu cầu duyệt nào đang chạy (yêu cầu cũ đã bị hủy)
  v_from := array['DRAFT']
         || case when not exists (select 1 from wf.approval_requests q where q.doc_type = p_doc_type and q.doc_id = p_doc_id and q.status = 'PENDING')
                 then array[f.pending_status] else '{}'::text[] end
         || case when f.rejected_status not in ('DRAFT', 'CANCELLED') then array[f.rejected_status] else '{}'::text[] end
         || case when p_doc_type like 'SPEC%' then array['PILOT_PENDING', 'PILOT'] else '{}'::text[] end;
  if v_status is null or not v_status = any(v_from) then
    raise exception 'Chứng từ đang ở trạng thái %, không gửi duyệt được', coalesce(v_status, 'không xác định');
  end if;
  if p_doc_type like 'SPEC%' then
    v_issues := master.check_spec(p_doc_id);
    if array_length(v_issues, 1) > 0 then
      raise exception 'Spec chưa đạt kiểm tra: %', array_to_string(v_issues, '; ');
    end if;
  elsif p_doc_type = 'PLAN' then
    select mrp_stale into v_stale from plan.production_plans where id = p_doc_id;
    if v_stale then raise exception 'Dòng kế hoạch đã thay đổi sau lần chạy MRP: chạy lại MRP rồi gửi duyệt'; end if;
  end if;
  v_no := coalesce(nullif(wf.doc_number(f.doc_table, p_doc_id), ''), left(nullif(trim(coalesce(p_doc_no, '')), ''), 60), p_doc_type);
  v_snap := wf.build_snapshot(p_doc_type, p_doc_id);
  v_first := v_snap -> 'steps' -> 0;
  if v_first is null then raise exception 'Luồng % không có bước nào áp dụng', p_doc_type; end if;
  if cardinality(array_remove(wf.step_actor_ids(v_first), auth.uid())) = 0 then
    raise exception 'Bước "%" chưa có người thực hiện: cấu hình tại Quản trị → Cài đặt quy trình', v_first ->> 'label';
  end if;
  insert into wf.approval_requests (doc_type, doc_id, doc_no, summary, current_seq, data_hash, flow_snapshot)
  values (p_doc_type, p_doc_id, v_no, v_summary, (v_first ->> 'seq')::smallint, wf.doc_hash(f.doc_table, p_doc_id), v_snap)
  returning id into v_req;
  execute format('update %s set %I = $1 where id = $2', f.doc_table::regclass, f.status_col) using f.pending_status, p_doc_id;
  perform wf.notify_users(array_remove(wf.step_actor_ids(v_first), auth.uid()), 'Chờ duyệt: ' || v_no, v_summary, '/duyet/' || v_req);
  return v_req;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Hàm nội bộ: chỉ gọi từ hàm hệ thống
-- ---------------------------------------------------------------------------
revoke all on function wf.notify_role(text, text, text, text) from public, anon, authenticated;
grant execute on function wf.notify_role(text, text, text, text) to service_role;
revoke all on function app.kh_log(text, text, text, text, text) from public, anon, authenticated;
grant execute on function app.kh_log(text, text, text, text, text) to service_role;
