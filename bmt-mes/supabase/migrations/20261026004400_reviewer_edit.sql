-- Người duyệt được sửa đề xuất trước khi duyệt (yêu cầu anh Bình 27/10/2026 23:13):
--  1. Người lập kế hoạch (TP SX / Kế hoạch SX) sửa được bảng MRP – đề nghị mua khi kế hoạch còn nháp, trước khi gửi Giám đốc.
--  2. Giám đốc (bước 1) và Chủ tịch HĐQT (bước 2) khi duyệt kế hoạch sửa được dòng kế hoạch và đề nghị mua MRP.
--  3. Nguyên tắc chung: người đang giữ bước duyệt được sửa nội dung đề xuất, mọi lần sửa ghi vào lịch sử duyệt.
--     Áp dụng ở bản này cho: kế hoạch tháng (PLAN), đề xuất mua (PR), phiếu điều chỉnh kế hoạch (PLAN_ADJ).
-- Dựa trên migration 20261026004200_plan_chair_review (Chủ tịch sửa ở bước chốt): mở cho mọi bước duyệt.

-- ===========================================================================
-- 1. Hàm chung
-- ===========================================================================
-- Yêu cầu duyệt đang chờ của chứng từ, người gọi đang giữ bước hiện tại (hoặc được ủy quyền, Quản trị) và không phải người lập.
create or replace function wf.review_request(p_doc_type text, p_doc_id uuid) returns wf.approval_requests
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare r wf.approval_requests; v_step jsonb;
begin
  select * into r from wf.approval_requests where doc_type = p_doc_type and doc_id = p_doc_id and status = 'PENDING'
   order by submitted_at desc limit 1;
  if not found then raise exception 'Chứng từ không ở bước chờ duyệt: chỉ người lập sửa khi còn nháp'; end if;
  v_step := wf.snap_step(r, r.current_seq);
  if auth.uid() = r.submitted_by then
    raise exception 'Người lập không sửa chứng từ đang chờ duyệt: người duyệt sửa, hoặc trả lại để người lập sửa';
  end if;
  if not (wf.can_act_step(v_step, r.step_started_at)).ok then
    raise exception 'Chỉ người đang duyệt bước "%" (%) được sửa chứng từ này', v_step ->> 'label',
      coalesce((select string_agg(full_name, ', ') from core.profiles where id = any(wf.step_actor_ids(v_step))), v_step ->> 'role');
  end if;
  return r;
end $$;
revoke all on function wf.review_request(text, uuid) from public, anon, authenticated;

-- Cho web: có được sửa khi duyệt không (không báo lỗi)
create or replace function app.can_review_edit(p_doc_type text, p_doc_id uuid) returns boolean
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform wf.review_request(p_doc_type, p_doc_id);
  return true;
exception when others then
  return false;
end $$;
revoke all on function app.can_review_edit(text, uuid) from public, anon;
grant execute on function app.can_review_edit(text, uuid) to authenticated;

-- Ghi lần sửa vào lịch sử duyệt (Trao đổi) và cập nhật mã kiểm để không chặn bước duyệt.
-- Báo người lập (mỗi người duyệt tối đa một thông báo trong 30 phút).
create or replace function wf.log_review_edit(p_req uuid, p_note text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r wf.approval_requests; f wf.approval_flows; v_hash text; v_recent boolean;
begin
  select * into r from wf.approval_requests where id = p_req for update;
  select * into f from wf.approval_flows where doc_type = r.doc_type;
  v_hash := wf.doc_hash(f.doc_table, r.doc_id);
  select exists (select 1 from wf.approval_actions a where a.request_id = p_req and a.actor_id = auth.uid()
                  and a.comment like '[Sửa khi duyệt]%' and a.acted_at > now() - interval '30 minutes') into v_recent;
  insert into wf.approval_actions (request_id, seq, action, comment, data_hash)
  values (p_req, r.current_seq, 'COMMENT', left('[Sửa khi duyệt] ' || coalesce(nullif(trim(p_note), ''), 'sửa nội dung'), 2000), v_hash);
  update wf.approval_requests set data_hash = v_hash where id = p_req;
  if not v_recent and r.submitted_by is not null and r.submitted_by <> auth.uid() then
    perform wf.notify_users(array[r.submitted_by], 'Người duyệt đã sửa ' || r.doc_no,
      left(coalesce((select full_name from core.profiles where id = auth.uid()), 'Người duyệt') || ': ' || coalesce(p_note, ''), 500),
      '/duyet/' || r.id);
  end if;
end $$;
revoke all on function wf.log_review_edit(uuid, text) from public, anon, authenticated;

create or replace function wf.fmt_num(p numeric) returns text
language sql immutable set search_path = pg_catalog, public as $$
  select replace(replace(replace(to_char(p, 'FM999G999G999G990D099'), ',', '#'), '.', ','), '#', '.')
$$;
create or replace function wf.fmt_qty(p numeric) returns text
language sql immutable set search_path = pg_catalog, public as $$
  select regexp_replace(regexp_replace(wf.fmt_num(p), '(,[0-9]*?)0+$', '\1'), ',$', '')
$$;

-- ===========================================================================
-- 2. Kế hoạch tháng: mọi bước duyệt được sửa dòng (trước chỉ bước Chủ tịch chốt)
-- ===========================================================================
create or replace function plan.chair_request(p_plan uuid) returns wf.approval_requests
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if (select status from plan.production_plans where id = p_plan) is distinct from 'PENDING_APPROVAL' then
    raise exception 'Kế hoạch không ở trạng thái chờ duyệt';
  end if;
  return wf.review_request('PLAN', p_plan);
end $$;
revoke all on function plan.chair_request(uuid) from public, anon, authenticated;

-- Giữ điều chỉnh đề nghị mua của lần MRP trước cho vật tư có nhu cầu không đổi (số MRP tính ra bằng số gốc lần trước)
create or replace function plan.carry_mrp_adjust(p_old uuid, p_new uuid) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare n int; v_today date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
begin
  if p_old is null or p_new is null or p_old = p_new then return 0; end if;
  update plan.mrp_lines nl set
    orig_suggest_qty = nl.suggest_qty,
    suggest_qty = o.suggest_qty,
    amount = case when nl.unit_price is not null then round(o.suggest_qty * nl.unit_price, 2) end,
    need_date = o.need_date, note = o.note, adjusted_by = o.adjusted_by, adjusted_at = o.adjusted_at,
    status = case when o.suggest_qty = 0 then 'Không cần mua'
                  when nl.unit_price is null then 'Cập nhật giá'
                  when coalesce(nl.lead_time_days, 0) = 0 then 'Thiếu lead time'
                  when coalesce(o.need_date, nl.latest_order_date) < v_today then 'Trễ'
                  else 'Đặt hàng' end
  from plan.mrp_lines o
  where o.run_id = p_old and nl.run_id = p_new and o.material_id = nl.material_id
    and o.orig_suggest_qty is not null and nl.suggest_qty = o.orig_suggest_qty
    and (o.suggest_qty <> nl.suggest_qty or o.need_date is not null or o.note is not null);
  get diagnostics n = row_count;
  if n > 0 then
    update plan.mrp_runs r set
      budget_vnd = (select sum(amount) from plan.mrp_lines where run_id = r.id),
      missing_price_count = (select count(*) from plan.mrp_lines where run_id = r.id and suggest_qty > 0 and unit_price is null)
    where r.id = p_new;
  end if;
  return n;
end $$;
revoke all on function plan.carry_mrp_adjust(uuid, uuid) from public, anon, authenticated;

-- Chạy MRP từ web: giữ điều chỉnh của vật tư không đổi nhu cầu. Kế hoạch chờ duyệt: chỉ người đang duyệt (sửa dòng thì MES tự chạy).
create or replace function app.plan_run_mrp(p_plan uuid) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_old uuid; v_new uuid; v_status text;
begin
  select status into v_status from plan.production_plans where id = p_plan;
  if v_status is null then raise exception 'Không tìm thấy kế hoạch'; end if;
  if v_status = 'PENDING_APPROVAL' then
    perform plan.chair_request(p_plan);
    perform set_config('bmt.chair_edit', 'on', true);
  elsif v_status not in ('DRAFT', 'APPROVED') then
    raise exception 'Kế hoạch đã đóng hoặc hủy: không chạy MRP';
  elsif not core.has_perm('plan', 'create') then
    raise exception 'Không có quyền chạy MRP';
  end if;
  select id into v_old from plan.mrp_runs where plan_id = p_plan order by run_at desc limit 1;
  perform plan.run_mrp(p_plan);
  perform set_config('bmt.chair_edit', 'off', true);
  select id into v_new from plan.mrp_runs where plan_id = p_plan order by run_at desc limit 1;
  perform plan.carry_mrp_adjust(v_old, v_new);
  if v_status = 'PENDING_APPROVAL' then
    perform wf.log_review_edit((plan.chair_request(p_plan)).id, 'chạy lại MRP');
  end if;
  return v_new;
end $$;
revoke all on function app.plan_run_mrp(uuid) from public, anon;
grant execute on function app.plan_run_mrp(uuid) to authenticated;

-- Chạy MRP thẳng (không qua app.plan_run_mrp) khi kế hoạch chờ duyệt: chặn, để không mất số người duyệt đã sửa
do $$
declare d text; v_old text := $x$if not (core.has_perm('plan', 'create') or coalesce(current_setting('bmt.chair_edit', true), '') = 'on') then raise exception 'Không có quyền chạy MRP'; end if;$x$;
begin
  d := replace(pg_get_functiondef('plan.run_mrp(uuid, jsonb)'::regprocedure), E'\r', '');
  if position('người duyệt sửa dòng thì MES tự chạy lại MRP' in d) > 0 then return; end if;   -- đã áp
  if position(v_old in d) = 0 then raise exception 'plan.run_mrp: không thấy đoạn kiểm quyền cần sửa'; end if;
  d := replace(d, v_old, v_old || $x$
  if coalesce(current_setting('bmt.chair_edit', true), '') <> 'on'
     and (select status from plan.production_plans where id = p_plan) = 'PENDING_APPROVAL' then
    raise exception 'Kế hoạch đang chờ duyệt: người duyệt sửa dòng thì MES tự chạy lại MRP';
  end if;$x$);
  execute d;
end $$;

-- Sau khi người duyệt sửa dòng: chạy lại MRP (giữ dự phòng và điều chỉnh không đổi), ghi lịch sử duyệt, cập nhật tóm tắt
create or replace function plan.chair_after_edit(p_plan uuid, p_req uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_reserve jsonb; p plan.production_plans; v_n int; v_m numeric; v_old uuid; v_new uuid; e record; v_note text;
begin
  select * into p from plan.production_plans where id = p_plan;
  select r.id, coalesce(r.snapshot -> 'reserve', '{}') into v_old, v_reserve from plan.mrp_runs r where r.plan_id = p_plan order by r.run_at desc limit 1;
  perform set_config('bmt.chair_edit', 'on', true);
  perform plan.run_mrp(p_plan, coalesce(v_reserve, '{}'));
  perform set_config('bmt.chair_edit', 'off', true);
  select id into v_new from plan.mrp_runs where plan_id = p_plan order by run_at desc limit 1;
  perform plan.carry_mrp_adjust(v_old, v_new);
  select count(*), coalesce(sum(qty_m), 0) into v_n, v_m from plan.plan_lines where plan_id = p_plan and qty_m > 0;
  update wf.approval_requests
     set summary = left(format('%s: %s SKU, %s m (đã chỉnh khi duyệt)', p.period_label, v_n,
                               replace(to_char(v_m, 'FM999G999G999G990'), ',', '.')), 500)
   where id = p_req;
  -- lần sửa vừa ghi ở plan_chair_edits → lịch sử duyệt
  select ce.*, pr.code into e from plan.plan_chair_edits ce join master.products pr on pr.id = ce.product_id
   where ce.request_id = p_req and ce.edited_by = auth.uid() order by ce.id desc limit 1;
  if found then
    v_note := e.code || ': ' || case e.action
      when 'ADD' then 'thêm ' || wf.fmt_qty((e.new_data ->> 'qty_m')::numeric) || ' m'
      when 'REMOVE' then 'bỏ (' || wf.fmt_qty((e.old_data ->> 'qty_m')::numeric) || ' m)'
      else 'sản lượng ' || wf.fmt_qty((e.old_data ->> 'qty_m')::numeric) || ' → ' || wf.fmt_qty((e.new_data ->> 'qty_m')::numeric) || ' m' end
      || ' · lý do: ' || e.reason || ' · MES chạy lại MRP';
    perform wf.log_review_edit(p_req, v_note);
  end if;
end $$;
revoke all on function plan.chair_after_edit(uuid, uuid) from public, anon, authenticated;

-- Duyệt xong: báo người lập và người đã duyệt các dòng đã chỉnh khi duyệt
create or replace function plan.notify_chair_edits() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r wf.approval_requests; v_body text; v_users uuid[];
begin
  select * into r from wf.approval_requests where doc_type = 'PLAN' and doc_id = new.id order by submitted_at desc limit 1;
  if not found then return new; end if;
  select string_agg(p.code || ': ' || case e.action
           when 'ADD' then 'thêm ' || wf.fmt_qty((e.new_data ->> 'qty_m')::numeric) || ' m'
           when 'REMOVE' then 'bỏ (' || wf.fmt_qty((e.old_data ->> 'qty_m')::numeric) || ' m)'
           else wf.fmt_qty((e.old_data ->> 'qty_m')::numeric) || ' → ' || wf.fmt_qty((e.new_data ->> 'qty_m')::numeric) || ' m' end
           || ' (' || coalesce(app.user_name(e.edited_by), '') || ')', '; ' order by e.id)
    into v_body
    from plan.plan_chair_edits e join master.products p on p.id = e.product_id where e.request_id = r.id;
  if v_body is null then return new; end if;
  select coalesce(array_agg(distinct a.actor_id), '{}') into v_users
    from wf.approval_actions a where a.request_id = r.id and a.action = 'APPROVE' and a.actor_id <> auth.uid();
  perform wf.notify_users(array(select distinct u from unnest(v_users || r.submitted_by) u where u is not null and u <> auth.uid()),
    'Kế hoạch đã được chỉnh khi duyệt: ' || new.plan_no, left(v_body, 1000), '/ke-hoach/' || new.id);
  return new;
end $$;
revoke all on function plan.notify_chair_edits() from public, anon, authenticated;

-- ===========================================================================
-- 3. Bảng MRP – đề nghị mua
--    Nháp: người lập kế hoạch (plan:create), TP Mua, TP KT/QA. Chờ duyệt: người đang duyệt. Đã duyệt: TP Mua, TP KT/QA (như trước).
-- ===========================================================================
create or replace function plan.mrp_lock_reason(p_run uuid) returns text
language sql stable security definer set search_path = pg_catalog, public as $$
  select case
    when pp.status not in ('DRAFT', 'PENDING_APPROVAL', 'APPROVED') then 'Kế hoạch đang ở trạng thái ' || pp.status || ': không sửa kết quả MRP'
    when pp.mrp_stale then 'Dòng kế hoạch đã thay đổi: chạy lại MRP trước khi điều chỉnh'
    when r.id <> (select r2.id from plan.mrp_runs r2 where r2.plan_id = pp.id order by r2.run_at desc limit 1)
      then 'Đây không phải lần chạy MRP mới nhất'
    when exists (select 1 from purchase.purchase_requests pr where pr.mrp_run_id = r.id and pr.status <> 'CANCELLED')
      then 'Đã sinh đề xuất mua từ kết quả này'
  end
  from plan.mrp_runs r join plan.production_plans pp on pp.id = r.plan_id where r.id = p_run
$$;
revoke all on function plan.mrp_lock_reason(uuid) from public, anon;

create or replace function app.adjust_mrp_line(p_line uuid, p_qty numeric, p_need_date date, p_note text, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare l plan.mrp_lines; v_plan uuid; v_status text; v_lock text; v_date date; v_note text := nullif(trim(coalesce(p_note, '')), '');
        r wf.approval_requests; v_mat text; v_uom text; v_today date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
begin
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do điều chỉnh'; end if;
  if p_qty is null or p_qty < 0 then raise exception 'Số lượng đề nghị mua phải ≥ 0'; end if;
  select * into l from plan.mrp_lines where id = p_line for update;
  if not found then raise exception 'Không tìm thấy dòng MRP'; end if;
  select r2.plan_id, pp.status into v_plan, v_status from plan.mrp_runs r2 join plan.production_plans pp on pp.id = r2.plan_id where r2.id = l.run_id;
  if v_status = 'PENDING_APPROVAL' then
    r := plan.chair_request(v_plan);
  elsif v_status = 'DRAFT' then
    if not (core.has_perm('plan', 'create') or app.can_adjust_mrp()) then
      raise exception 'Kế hoạch nháp: người lập kế hoạch, TP Mua hàng hoặc TP Kỹ thuật/QA sửa kết quả MRP';
    end if;
  elsif not app.can_adjust_mrp() then
    raise exception 'Kế hoạch đã duyệt: chỉ TP Mua hàng hoặc TP Kỹ thuật/QA sửa kết quả MRP';
  end if;
  v_lock := plan.mrp_lock_reason(l.run_id);
  if v_lock is not null then raise exception '%', v_lock; end if;
  v_date := coalesce(p_need_date, l.latest_order_date);
  if p_qty = l.suggest_qty and v_date is not distinct from coalesce(l.need_date, l.latest_order_date)
     and v_note is not distinct from l.note then
    raise exception 'Không có thay đổi';
  end if;

  insert into plan.mrp_line_edits (plan_id, run_id, mrp_line_id, material_id, old_qty, new_qty, old_need_date, new_need_date,
                                   old_note, new_note, reason)
  values (v_plan, l.run_id, l.id, l.material_id, l.suggest_qty, p_qty, coalesce(l.need_date, l.latest_order_date), v_date,
          l.note, v_note, trim(p_reason));

  update plan.mrp_lines set
    orig_suggest_qty = coalesce(orig_suggest_qty, suggest_qty),
    suggest_qty = p_qty,
    amount = case when unit_price is not null then round(p_qty * unit_price, 2) end,
    need_date = case when p_need_date is null or p_need_date = latest_order_date then null else p_need_date end,
    note = v_note, adjusted_by = auth.uid(), adjusted_at = now(),
    status = case when p_qty = 0 then 'Không cần mua'
                  when unit_price is null then 'Cập nhật giá'
                  when coalesce(lead_time_days, 0) = 0 then 'Thiếu lead time'
                  when v_date < v_today then 'Trễ'
                  else 'Đặt hàng' end
  where id = p_line;

  update plan.mrp_runs r2 set
    budget_vnd = (select sum(amount) from plan.mrp_lines where run_id = r2.id),
    missing_price_count = (select count(*) from plan.mrp_lines where run_id = r2.id and suggest_qty > 0 and unit_price is null)
  where r2.id = l.run_id;

  if r.id is not null then
    select code, uom into v_mat, v_uom from master.materials where id = l.material_id;
    perform wf.log_review_edit(r.id, format('Đề nghị mua %s: %s → %s %s%s · lý do: %s', v_mat, wf.fmt_qty(l.suggest_qty), wf.fmt_qty(p_qty), coalesce(v_uom, ''),
      case when v_date is distinct from coalesce(l.need_date, l.latest_order_date) then ', ngày cần ' || to_char(v_date, 'DD/MM') else '' end, trim(p_reason)));
  end if;
end $$;
revoke all on function app.adjust_mrp_line(uuid, numeric, date, text, text) from public, anon;
grant execute on function app.adjust_mrp_line(uuid, numeric, date, text, text) to authenticated;

-- ===========================================================================
-- 4. Đề xuất mua (PR): người lập sửa khi nháp; người đang duyệt sửa khi chờ duyệt
-- ===========================================================================
create or replace function purchase.pr_edit_request(p_pr uuid) returns wf.approval_requests
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_status text; r wf.approval_requests;
begin
  select status into v_status from purchase.purchase_requests where id = p_pr;
  if v_status is null then raise exception 'Không tìm thấy đề xuất mua'; end if;
  if v_status = 'DRAFT' then
    if not core.has_perm('purchase', 'create') then raise exception 'Không có quyền sửa đề xuất mua'; end if;
    return r;   -- rỗng: người lập sửa nháp
  elsif v_status = 'PENDING_APPROVAL' then
    return wf.review_request('PR', p_pr);
  end if;
  raise exception 'Chỉ sửa được đề xuất đang nháp hoặc đang chờ duyệt (người duyệt sửa)';
end $$;
revoke all on function purchase.pr_edit_request(uuid) from public, anon, authenticated;

create or replace function app.save_pr_line(p_pr uuid, p_material_code text, p_qty numeric, p_need_date date default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_mat uuid; r wf.approval_requests; v_old numeric; v_code text; v_uom text;
begin
  r := purchase.pr_edit_request(p_pr);
  select id, code, uom into v_mat, v_code, v_uom from master.materials where code = upper(trim(p_material_code));
  if v_mat is null then raise exception 'Không có vật tư %', p_material_code; end if;
  if coalesce(p_qty, 0) <= 0 then raise exception 'Số lượng phải lớn hơn 0'; end if;
  select qty into v_old from purchase.pr_lines where pr_id = p_pr and material_id = v_mat;
  update purchase.pr_lines set qty = p_qty, need_date = coalesce(p_need_date, need_date) where pr_id = p_pr and material_id = v_mat;
  if not found then
    insert into purchase.pr_lines (pr_id, material_id, qty, need_date)
    values (p_pr, v_mat, p_qty, coalesce(p_need_date, (select need_date from purchase.purchase_requests where id = p_pr)));
  end if;
  if r.id is not null then
    perform wf.log_review_edit(r.id, case when v_old is null then format('thêm %s: %s %s', v_code, wf.fmt_qty(p_qty), v_uom)
                                          else format('%s: %s → %s %s', v_code, wf.fmt_qty(v_old), wf.fmt_qty(p_qty), v_uom) end);
  end if;
end $$;

create or replace function app.delete_pr_line(p_line uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare l purchase.pr_lines; r wf.approval_requests; v_code text;
begin
  select * into l from purchase.pr_lines where id = p_line;
  if not found then raise exception 'Không tìm thấy dòng đề xuất'; end if;
  r := purchase.pr_edit_request(l.pr_id);
  if r.id is not null and not exists (select 1 from purchase.pr_lines where pr_id = l.pr_id and id <> p_line) then
    raise exception 'Đề xuất phải còn ít nhất một dòng: muốn bỏ cả đề xuất thì bấm Trả lại';
  end if;
  delete from purchase.pr_lines where id = p_line;
  if r.id is not null then
    select code into v_code from master.materials where id = l.material_id;
    perform wf.log_review_edit(r.id, format('bỏ %s (%s)', v_code, wf.fmt_qty(l.qty)));
  end if;
end $$;

-- Thông tin chung (nội dung, ngày cần): thay cho ghi thẳng bảng của web
create or replace function app.save_pr_header(p_pr uuid, p_note text, p_need_date date) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r wf.approval_requests; o purchase.purchase_requests;
begin
  r := purchase.pr_edit_request(p_pr);
  if coalesce(trim(p_note), '') = '' then raise exception 'Nhập nội dung đề xuất'; end if;
  select * into o from purchase.purchase_requests where id = p_pr for update;
  if o.note is not distinct from trim(p_note) and o.need_date is not distinct from p_need_date then raise exception 'Không có thay đổi'; end if;
  update purchase.purchase_requests set note = trim(p_note), need_date = p_need_date where id = p_pr;
  if r.id is not null then
    perform wf.log_review_edit(r.id, concat_ws('; ',
      case when o.note is distinct from trim(p_note) then 'nội dung: ' || left(trim(p_note), 200) end,
      case when o.need_date is distinct from p_need_date then 'ngày cần ' || coalesce(to_char(o.need_date, 'DD/MM'), '—') || ' → ' || coalesce(to_char(p_need_date, 'DD/MM'), '—') end));
  end if;
end $$;
revoke all on function app.save_pr_line(uuid, text, numeric, date), app.delete_pr_line(uuid), app.save_pr_header(uuid, text, date) from public, anon;
grant execute on function app.save_pr_line(uuid, text, numeric, date), app.delete_pr_line(uuid), app.save_pr_header(uuid, text, date) to authenticated;

-- ===========================================================================
-- 5. Phiếu điều chỉnh kế hoạch (PLAN_ADJ): Chủ tịch sửa dòng khi duyệt
-- ===========================================================================
do $$
declare d text;
  v_old text := $x$  if a.status <> 'DRAFT' then raise exception 'Phiếu % đã gửi duyệt: không sửa được', a.adj_no; end if;
  if a.created_by is distinct from auth.uid() and not core.is_admin() and not wf.can_submit('PLAN_ADJ') then
    raise exception 'Không có quyền sửa phiếu điều chỉnh';
  end if;$x$;
  v_new text := $x$  if a.status = 'PENDING_APPROVAL' then
    v_req := wf.review_request('PLAN_ADJ', p_adj);
  elsif a.status <> 'DRAFT' then raise exception 'Phiếu % đã gửi duyệt: không sửa được', a.adj_no;
  elsif a.created_by is distinct from auth.uid() and not core.is_admin() and not wf.can_submit('PLAN_ADJ') then
    raise exception 'Không có quyền sửa phiếu điều chỉnh';
  end if;$x$;
begin
  d := replace(pg_get_functiondef('app.adj_save(uuid, text, jsonb)'::regprocedure), E'\r', '');
  if position('wf.log_review_edit' in d) > 0 then return; end if;   -- đã áp
  if position(v_old in d) = 0 then raise exception 'app.adj_save: không thấy đoạn kiểm trạng thái cần sửa'; end if;
  d := replace(d, v_old, v_new);
  d := replace(d, 'declare a plan.plan_adjustments;', 'declare v_req wf.approval_requests; a plan.plan_adjustments;');
  if position('v_req wf.approval_requests' in d) = 0 then raise exception 'app.adj_save: không thêm được biến'; end if;
  -- ghi lịch sử duyệt sau khi lưu dòng
  d := regexp_replace(d, 'end loop;\s*end\s*\$function\$\s*$', $x$end loop;
  if v_req.id is not null then
    perform plan.check_adjustment(p_adj);
    perform wf.log_review_edit(v_req.id, 'sửa nội dung phiếu: ' || i || ' dòng · ' || coalesce(nullif(trim(p_reason), ''), a.reason));
  end if;
end $function$
$x$);
  if position('wf.log_review_edit' in d) = 0 then raise exception 'app.adj_save: không thêm được ghi lịch sử'; end if;
  execute d;
end $$;
