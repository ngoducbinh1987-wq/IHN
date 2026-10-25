-- BMT MES · 2100 · Sửa dòng kế hoạch, quy cách đóng gói, điều chỉnh MRP, cài đặt quy trình + cảnh báo quá hạn
--  1. Dòng kế hoạch chỉ thêm/sửa khi kế hoạch Nháp; sửa sau khi đã chạy MRP thì đánh dấu "cần tính lại"
--  2. Quy cách đóng gói (m/kiện theo loại): Bobin gỗ 305/500, Cuộn PE 100/200; số kiện chẵn + kiện lẻ
--  3. Điều chỉnh kết quả MRP: chỉ TP Mua hàng, TP Kỹ thuật/QA; bắt buộc lý do; giữ giá trị gốc + lịch sử
--  4. Cài đặt quy trình: người thực hiện từng bước, thời hạn, nhắc trước hạn; hồ sơ đang chạy giữ cấu hình lúc gửi
--  5. Job máy chủ (pg_cron) tạo cảnh báo sắp đến hạn/quá hạn, chống trùng; email đẩy qua /api/cron/notify

-- ---------------------------------------------------------------------------
-- 1. Dòng kế hoạch
-- ---------------------------------------------------------------------------
alter table plan.production_plans add column if not exists mrp_stale boolean not null default false;
alter table plan.mrp_runs alter column run_at set default clock_timestamp();   -- phân biệt lần chạy mới nhất

-- Hash chứng từ không tính cờ "cần tính lại MRP" (cờ do hệ thống bật/tắt)
create or replace function wf.doc_hash(p_table text, p_id uuid) returns text
language plpgsql stable security definer as $$
declare v jsonb;
begin
  execute format('select to_jsonb(t) - array[''status'',''updated_at'',''updated_by'',''current_spec_id'',''mrp_stale''] from %s t where id = $1', p_table)
    into v using p_id;
  return md5(v::text);
end $$;

drop policy if exists p_insert on plan.plan_lines;
create policy p_insert on plan.plan_lines for insert to authenticated
  with check (core.has_perm('plan', 'create')
              and exists (select 1 from plan.production_plans pp where pp.id = plan_id and pp.status = 'DRAFT'));
drop policy if exists p_update on plan.plan_lines;
create policy p_update on plan.plan_lines for update to authenticated
  using (core.has_perm('plan', 'edit') and exists (select 1 from plan.production_plans pp where pp.id = plan_id and pp.status = 'DRAFT'))
  with check (core.has_perm('plan', 'edit') and exists (select 1 from plan.production_plans pp where pp.id = plan_id and pp.status = 'DRAFT'));

create or replace function plan.mark_mrp_stale() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_plan uuid := coalesce(new.plan_id, old.plan_id);
begin
  update plan.production_plans set mrp_stale = true
   where id = v_plan and not mrp_stale and exists (select 1 from plan.mrp_runs r where r.plan_id = v_plan);
  return null;
end $$;
drop trigger if exists trg_mrp_stale on plan.plan_lines;
create trigger trg_mrp_stale after insert or update or delete on plan.plan_lines
  for each row execute function plan.mark_mrp_stale();

create or replace function plan.clear_mrp_stale() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  update plan.production_plans set mrp_stale = false where id = new.plan_id and mrp_stale;
  return null;
end $$;
drop trigger if exists trg_mrp_fresh on plan.mrp_runs;
create trigger trg_mrp_fresh after insert on plan.mrp_runs for each row execute function plan.clear_mrp_stale();

-- ---------------------------------------------------------------------------
-- 2. Quy cách đóng gói
-- ---------------------------------------------------------------------------
create table if not exists master.pack_options (
  pack_type  text not null check (pack_type in ('Bobin gỗ','Cuộn PE')),
  m_per_pack numeric not null check (m_per_pack > 0),
  sort       smallint not null default 0,
  primary key (pack_type, m_per_pack)
);
insert into master.pack_options (pack_type, m_per_pack, sort) values
  ('Bobin gỗ', 500, 1), ('Bobin gỗ', 305, 2), ('Cuộn PE', 100, 1), ('Cuộn PE', 200, 2)
on conflict do nothing;
alter table master.pack_options enable row level security;
drop policy if exists p_select on master.pack_options;
create policy p_select on master.pack_options for select to authenticated using (true);
grant select on master.pack_options to authenticated;
grant all on master.pack_options to service_role;

-- Dòng mới hoặc đổi quy cách phải đúng danh mục; dòng cũ không đổi quy cách vẫn giữ nguyên
create or replace function plan.check_pack() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if tg_op = 'UPDATE' and new.pack_type = old.pack_type and new.m_per_pack = old.m_per_pack then return new; end if;
  if not exists (select 1 from master.pack_options o where o.pack_type = new.pack_type and o.m_per_pack = new.m_per_pack) then
    raise exception 'Quy cách đóng gói không hợp lệ: % % m/kiện', new.pack_type, new.m_per_pack;
  end if;
  return new;
end $$;
drop trigger if exists trg_check_pack on plan.plan_lines;
create trigger trg_check_pack before insert or update on plan.plan_lines for each row execute function plan.check_pack();

-- ---------------------------------------------------------------------------
-- 3. Điều chỉnh kết quả MRP
-- ---------------------------------------------------------------------------
alter table plan.mrp_lines
  add column if not exists orig_suggest_qty numeric(18,4),
  add column if not exists need_date date,            -- ngày cần sau điều chỉnh (null = theo MRP)
  add column if not exists note text,
  add column if not exists adjusted_by uuid,
  add column if not exists adjusted_at timestamptz;
alter table purchase.pr_lines add column if not exists note text;

create table if not exists plan.mrp_line_edits (
  id            bigint generated always as identity primary key,
  plan_id       uuid not null references plan.production_plans(id),
  run_id        uuid not null references plan.mrp_runs(id),
  mrp_line_id   uuid references plan.mrp_lines(id) on delete set null,
  material_id   uuid not null references master.materials(id),
  old_qty       numeric(18,4), new_qty numeric(18,4),
  old_need_date date, new_need_date date,
  old_note      text, new_note text,
  reason        text not null check (length(trim(reason)) > 0),
  edited_by     uuid not null default auth.uid(),
  edited_at     timestamptz not null default now()
);
create index if not exists mrp_line_edits_plan on plan.mrp_line_edits (plan_id, edited_at desc);
alter table plan.mrp_line_edits enable row level security;
drop policy if exists p_select on plan.mrp_line_edits;
create policy p_select on plan.mrp_line_edits for select to authenticated using (core.has_perm('plan', 'view'));
grant select on plan.mrp_line_edits to authenticated;
grant all on plan.mrp_line_edits to service_role;

-- Khóa: kế hoạch đang chờ duyệt/đóng/hủy, không phải lần chạy mới nhất, hoặc đã sinh PR
create or replace function plan.mrp_lock_reason(p_run uuid) returns text
language sql stable security definer set search_path = pg_catalog, public as $$
  select case
    when pp.status not in ('DRAFT', 'APPROVED') then 'Kế hoạch đang ở trạng thái ' || pp.status || ': không sửa kết quả MRP'
    when pp.mrp_stale then 'Dòng kế hoạch đã thay đổi: chạy lại MRP trước khi điều chỉnh'
    when r.id <> (select r2.id from plan.mrp_runs r2 where r2.plan_id = pp.id order by r2.run_at desc limit 1)
      then 'Đây không phải lần chạy MRP mới nhất'
    when exists (select 1 from purchase.purchase_requests pr where pr.mrp_run_id = r.id and pr.status <> 'CANCELLED')
      then 'Đã sinh đề xuất mua từ kết quả này'
  end
  from plan.mrp_runs r join plan.production_plans pp on pp.id = r.plan_id where r.id = p_run
$$;

create or replace function app.can_adjust_mrp() returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select core.has_role('MUA_TP') or core.has_role('KT_TP')
$$;

create or replace function app.adjust_mrp_line(p_line uuid, p_qty numeric, p_need_date date, p_note text, p_reason text)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
declare l plan.mrp_lines; v_plan uuid; v_lock text; v_date date; v_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  if not app.can_adjust_mrp() then raise exception 'Chỉ TP Mua hàng hoặc TP Kỹ thuật/QA được sửa kết quả MRP'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do điều chỉnh'; end if;
  if p_qty is null or p_qty < 0 then raise exception 'Số lượng đề nghị mua phải ≥ 0'; end if;
  select * into l from plan.mrp_lines where id = p_line for update;
  if not found then raise exception 'Không tìm thấy dòng MRP'; end if;
  select plan_id into v_plan from plan.mrp_runs where id = l.run_id;
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
                  when v_date < current_date then 'Trễ'
                  else 'Đặt hàng' end
  where id = p_line;

  update plan.mrp_runs r set
    budget_vnd = (select sum(amount) from plan.mrp_lines where run_id = r.id),
    missing_price_count = (select count(*) from plan.mrp_lines where run_id = r.id and suggest_qty > 0 and unit_price is null)
  where r.id = l.run_id;
end $$;

-- Sinh PR dùng số lượng/ngày cần/ghi chú đã điều chỉnh
create or replace function plan.create_pr_from_mrp(p_run uuid) returns uuid
language plpgsql security definer set search_path = plan, purchase, public as $$
declare v_pr uuid; p plan.production_plans;
begin
  if not core.has_perm('plan', 'create') then raise exception 'Không có quyền tạo PR'; end if;
  select pp.* into p from plan.mrp_runs r join plan.production_plans pp on pp.id = r.plan_id where r.id = p_run;
  if p.status <> 'APPROVED' or p.mode <> 'OFFICIAL' then
    raise exception 'Chỉ sinh PR từ kế hoạch chính thức đã BGĐ duyệt';
  end if;
  if p.mrp_stale then raise exception 'Dòng kế hoạch đã thay đổi sau lần chạy MRP: chạy lại MRP'; end if;
  if exists (select 1 from purchase.purchase_requests pr where pr.mrp_run_id = p_run and pr.status <> 'CANCELLED') then
    raise exception 'Đã sinh đề xuất mua từ kết quả MRP này';
  end if;
  insert into purchase.purchase_requests (pr_no, source, mrp_run_id, need_date, note)
  values (core.next_no('PR'), 'MRP', p_run, p.material_need_date, 'Từ ' || p.plan_no) returning id into v_pr;
  insert into purchase.pr_lines (pr_id, material_id, qty, need_date, mrp_line_id, note)
  select v_pr, material_id, suggest_qty, coalesce(need_date, latest_order_date), id, note
  from plan.mrp_lines where run_id = p_run and suggest_qty > 0;
  return v_pr;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Cài đặt quy trình
-- ---------------------------------------------------------------------------
alter table wf.approval_flows
  add column if not exists submit_label text not null default 'Lập phiếu',
  add column if not exists submit_role text references core.roles(code),     -- null = ai có quyền tạo chứng từ
  add column if not exists submit_user_ids uuid[] not null default '{}';
alter table wf.approval_steps
  add column if not exists assignee_ids uuid[] not null default '{}',        -- rỗng = mọi người giữ vai trò
  add column if not exists warn_hours integer not null default 0 check (warn_hours >= 0);
alter table wf.approval_requests add column if not exists flow_snapshot jsonb;
alter table wf.notifications
  add column if not exists request_id uuid,
  add column if not exists step_seq smallint,
  add column if not exists email_claimed_at timestamptz;

update wf.approval_flows set submit_label = 'Lập kế hoạch' where doc_type = 'PLAN' and submit_label = 'Lập phiếu';
update wf.approval_flows set submit_label = 'Lập đề xuất' where doc_type = 'PR' and submit_label = 'Lập phiếu';
update wf.approval_flows set submit_label = 'Lập spec' where doc_type like 'SPEC%' and submit_label = 'Lập phiếu';

-- Cấu hình hiện hành của một luồng (đóng băng vào hồ sơ lúc gửi duyệt)
create or replace function wf.flow_config(p_doc_type text) returns jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
  select jsonb_build_object(
    'submit', jsonb_build_object('label', f.submit_label, 'role', f.submit_role, 'users', to_jsonb(f.submit_user_ids)),
    'steps', coalesce((select jsonb_agg(jsonb_build_object('seq', s.seq, 'label', s.level_label, 'role', s.role_code,
                                                           'users', to_jsonb(s.assignee_ids), 'sla_hours', s.sla_hours,
                                                           'warn_hours', s.warn_hours) order by s.seq)
                       from wf.approval_steps s where s.doc_type = f.doc_type and s.enabled), '[]'))
  from wf.approval_flows f where f.doc_type = p_doc_type
$$;

update wf.approval_requests r set flow_snapshot = wf.flow_config(r.doc_type) where flow_snapshot is null;

create or replace function wf.snap_step(r wf.approval_requests, p_seq smallint) returns jsonb
language sql immutable as $$
  select s from jsonb_array_elements(r.flow_snapshot -> 'steps') s where (s ->> 'seq')::int = p_seq
$$;

-- Người được xử lý một bước: danh sách được giao (vẫn phải giữ vai trò) hoặc mọi người giữ vai trò
create or replace function wf.step_actor_ids(p_step jsonb) returns uuid[]
language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce(array_agg(distinct ur.user_id), '{}')
  from core.user_roles ur join core.profiles p on p.id = ur.user_id and p.status = 'ACTIVE'
  where ur.role_code = p_step ->> 'role'
    and (jsonb_array_length(coalesce(p_step -> 'users', '[]')) = 0
         or (p_step -> 'users') ? ur.user_id::text)
$$;

-- Người hiện tại có được xử lý bước không (trả người được duyệt thay nếu qua ủy quyền)
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
end $$;

create or replace function wf.notify_users(p_users uuid[], p_title text, p_body text, p_link text,
                                           p_request uuid default null, p_seq smallint default null) returns void
language sql security definer set search_path = pg_catalog, public as $$
  insert into wf.notifications (user_id, title, body, link, request_id, step_seq)
  select u, p_title, p_body, p_link, p_request, p_seq from unnest(p_users) u
$$;

create or replace function wf.submit(p_doc_type text, p_doc_id uuid, p_doc_no text, p_summary text default null) returns uuid
language plpgsql security definer set search_path = wf, core, public as $$
declare f wf.approval_flows; v_req uuid; v_snap jsonb; v_first jsonb; v_issues text[]; v_stale boolean;
begin
  select * into f from wf.approval_flows where doc_type = p_doc_type;
  if not found then raise exception 'Chưa cấu hình luồng duyệt cho %', p_doc_type; end if;
  if cardinality(f.submit_user_ids) > 0 and not auth.uid() = any(f.submit_user_ids) then
    raise exception 'Bạn không được giao bước "%" của quy trình này', f.submit_label;
  end if;
  if f.submit_role is not null and not core.has_role(f.submit_role) then
    raise exception 'Bước "%" cần vai trò %', f.submit_label, f.submit_role;
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
  v_snap := wf.flow_config(p_doc_type);
  v_first := v_snap -> 'steps' -> 0;
  if v_first is null then raise exception 'Luồng % không có bước nào đang bật', p_doc_type; end if;
  if cardinality(wf.step_actor_ids(v_first)) = 0 then
    raise exception 'Bước "%" chưa có người thực hiện: cấu hình tại Quản trị → Cài đặt quy trình', v_first ->> 'label';
  end if;
  insert into wf.approval_requests (doc_type, doc_id, doc_no, summary, current_seq, data_hash, flow_snapshot)
  values (p_doc_type, p_doc_id, p_doc_no, p_summary, (v_first ->> 'seq')::smallint, wf.doc_hash(f.doc_table, p_doc_id), v_snap)
  returning id into v_req;
  execute format('update %s set %I = $1 where id = $2', f.doc_table, f.status_col) using f.pending_status, p_doc_id;
  perform wf.notify_users(wf.step_actor_ids(v_first), 'Chờ duyệt: ' || p_doc_no, p_summary, '/duyet/' || v_req);
  return v_req;
end $$;

create or replace function wf.act(p_request uuid, p_action text, p_comment text default null) returns text
language plpgsql security definer set search_path = wf, core, public as $$
declare r wf.approval_requests; f wf.approval_flows; v_step jsonb; v_next jsonb; v_hash text; v_ok boolean; v_behalf uuid;
begin
  select * into r from wf.approval_requests where id = p_request for update;
  if r.status <> 'PENDING' then raise exception 'Yêu cầu đã kết thúc (%)', r.status; end if;
  select * into f from wf.approval_flows where doc_type = r.doc_type;
  v_step := wf.snap_step(r, r.current_seq);

  select ok, on_behalf into v_ok, v_behalf from wf.can_act_step(v_step);
  if not v_ok then
    raise exception 'Bước "%" cần vai trò % – người được giao: %', v_step ->> 'label', v_step ->> 'role',
      coalesce((select string_agg(full_name, ', ') from core.profiles where id = any(wf.step_actor_ids(v_step))), 'chưa có');
  end if;
  if auth.uid() = r.submitted_by then raise exception 'Người lập không tự duyệt chứng từ của mình'; end if;
  if p_action = 'REJECT' and coalesce(trim(p_comment), '') = '' then
    raise exception 'Nhập lý do trả lại để người lập biết cần sửa gì';
  end if;
  v_hash := wf.doc_hash(f.doc_table, r.doc_id);
  if v_hash <> r.data_hash then raise exception 'Chứng từ đã bị sửa sau khi gửi duyệt: gửi duyệt lại'; end if;

  insert into wf.approval_actions (request_id, seq, on_behalf_of, action, comment, data_hash)
  values (p_request, r.current_seq, v_behalf, p_action, p_comment, v_hash);

  if p_action = 'COMMENT' then return 'PENDING'; end if;

  if p_action = 'REJECT' then
    update wf.approval_requests set status = 'REJECTED', finished_at = now() where id = p_request;
    execute format('update %s set %I = $1 where id = $2', f.doc_table, f.status_col) using f.rejected_status, r.doc_id;
    insert into wf.notifications (user_id, title, body, link) values (r.submitted_by, 'Bị trả lại: ' || r.doc_no, p_comment, '/duyet/' || p_request);
    return 'REJECTED';
  end if;

  select s into v_next from jsonb_array_elements(r.flow_snapshot -> 'steps') s
   where (s ->> 'seq')::int > r.current_seq order by (s ->> 'seq')::int limit 1;
  if v_next is not null then
    update wf.approval_requests set current_seq = (v_next ->> 'seq')::smallint where id = p_request;
    perform wf.notify_users(wf.step_actor_ids(v_next), 'Chờ duyệt: ' || r.doc_no, r.summary, '/duyet/' || p_request);
    return 'PENDING';
  end if;

  update wf.approval_requests set status = 'APPROVED', finished_at = now() where id = p_request;
  if r.doc_type like 'SPEC%' then
    perform master.release_spec(r.doc_id);
  elsif r.doc_type = 'WO_RELEASE' then
    perform mfg.release_wo(r.doc_id);
  else
    execute format('update %s set %I = $1 where id = $2', f.doc_table, f.status_col) using f.approved_status, r.doc_id;
  end if;
  insert into wf.notifications (user_id, title, link) values (r.submitted_by, 'Đã duyệt: ' || r.doc_no, '/duyet/' || p_request);
  return 'APPROVED';
end $$;

-- Lưu cấu hình (chỉ quản trị). Chỉ ảnh hưởng hồ sơ gửi sau thời điểm lưu.
create or replace function app.save_flow_submit(p_doc_type text, p_label text, p_role text, p_users uuid[]) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if not core.has_perm('admin', 'edit') then raise exception 'Chỉ quản trị hệ thống được cài đặt quy trình'; end if;
  if coalesce(trim(p_label), '') = '' then raise exception 'Nhập tên bước'; end if;
  if p_role is not null and exists (select 1 from unnest(coalesce(p_users, '{}')) u
                                    where not exists (select 1 from core.user_roles ur where ur.user_id = u and ur.role_code = p_role)) then
    raise exception 'Người được giao phải có vai trò %', p_role;
  end if;
  update wf.approval_flows set submit_label = trim(p_label), submit_role = p_role, submit_user_ids = coalesce(p_users, '{}')
   where doc_type = p_doc_type;
  if not found then raise exception 'Không có quy trình %', p_doc_type; end if;
end $$;

create or replace function app.save_flow_step(p_doc_type text, p_seq smallint, p_label text, p_role text, p_users uuid[],
                                              p_sla_hours int, p_warn_hours int, p_enabled boolean) returns smallint
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_seq smallint := p_seq;
begin
  if not core.has_perm('admin', 'edit') then raise exception 'Chỉ quản trị hệ thống được cài đặt quy trình'; end if;
  if coalesce(trim(p_label), '') = '' then raise exception 'Nhập tên bước'; end if;
  if p_role is null or not exists (select 1 from core.roles where code = p_role) then raise exception 'Chọn vai trò thực hiện'; end if;
  if coalesce(p_sla_hours, 0) <= 0 then raise exception 'Thời hạn phải > 0 giờ'; end if;
  if coalesce(p_warn_hours, 0) < 0 or coalesce(p_warn_hours, 0) >= p_sla_hours then raise exception 'Nhắc trước hạn phải từ 0 đến nhỏ hơn thời hạn'; end if;
  if exists (select 1 from unnest(coalesce(p_users, '{}')) u
             where not exists (select 1 from core.user_roles ur where ur.user_id = u and ur.role_code = p_role)) then
    raise exception 'Người được giao phải có vai trò % (gán vai trò ở Người dùng & quyền)', p_role;
  end if;
  if v_seq is null then
    select coalesce(max(seq), 0) + 1 into v_seq from wf.approval_steps where doc_type = p_doc_type;
    insert into wf.approval_steps (doc_type, seq, level_label, role_code, enabled, sla_hours, warn_hours, assignee_ids)
    values (p_doc_type, v_seq, trim(p_label), p_role, coalesce(p_enabled, true), p_sla_hours, coalesce(p_warn_hours, 0), coalesce(p_users, '{}'));
  else
    update wf.approval_steps set level_label = trim(p_label), role_code = p_role, enabled = coalesce(p_enabled, true),
           sla_hours = p_sla_hours, warn_hours = coalesce(p_warn_hours, 0), assignee_ids = coalesce(p_users, '{}')
     where doc_type = p_doc_type and seq = v_seq;
    if not found then raise exception 'Không có bước % của %', v_seq, p_doc_type; end if;
  end if;
  if not exists (select 1 from wf.approval_steps where doc_type = p_doc_type and enabled) then
    raise exception 'Quy trình phải còn ít nhất một bước đang bật';
  end if;
  return v_seq;
end $$;

-- Hộp duyệt theo cấu hình đóng băng của từng hồ sơ
create or replace function app.people(p_ids uuid[]) returns jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.full_name, 'title', p.title) order by p.full_name), '[]')
  from core.profiles p where p.id = any(p_ids) and auth.uid() is not null
$$;

drop view if exists app.v_approvals;
create view app.v_approvals with (security_invoker = true) as
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
       case when b.status = 'PENDING' then app.people(wf.step_actor_ids(b.cur_step)) else '[]'::jsonb end as current_approvers,
       b.submitted_by, app.user_name(b.submitted_by) as submitted_by_name, b.submitted_at, b.finished_at,
       b.step_started_at, b.step_started_at + make_interval(hours => b.sla_hours) as step_due_at,
       (b.status = 'PENDING' and now() > b.step_started_at + make_interval(hours => b.sla_hours)) as overdue,
       b.step_index, b.step_total,
       (b.status = 'PENDING' and b.submitted_by <> auth.uid() and (wf.can_act_step(b.cur_step)).ok) as my_turn,
       (b.submitted_by = auth.uid()) as i_submitted,
       exists (select 1 from wf.approval_actions a where a.request_id = b.id and a.actor_id = auth.uid()) as i_acted,
       case b.doc_type
         when 'SPEC_NEW' then '/san-pham/' || (select p.code from master.product_specs s join master.products p on p.id = s.product_id where s.id = b.doc_id) || '?v=' || b.doc_id
         when 'SPEC_MINOR' then '/san-pham/' || (select p.code from master.product_specs s join master.products p on p.id = s.product_id where s.id = b.doc_id) || '?v=' || b.doc_id
         when 'PLAN' then '/ke-hoach/' || b.doc_id
         when 'PR' then '/de-xuat/' || b.doc_id
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
                   'approvers', case when b.status = 'PENDING' and (s ->> 'seq')::int >= b.current_seq then app.people(wf.step_actor_ids(s)) end)
          from jsonb_array_elements(b.flow_snapshot -> 'steps') s left join core.roles ro on ro.code = s ->> 'role') q) as steps,
       (select jsonb_agg(jsonb_build_object('seq', a.seq, 'action', a.action, 'comment', a.comment, 'at', a.acted_at,
                                            'actor', app.user_name(a.actor_id),
                                            'label', (select s ->> 'label' from jsonb_array_elements(b.flow_snapshot -> 'steps') s where (s ->> 'seq')::int = a.seq))
                         order by a.acted_at)
          from wf.approval_actions a where a.request_id = b.id) as history
from base b;

-- Cấu hình cho màn hình quản trị
create or replace view app.v_flow_config with (security_invoker = true) as
select f.doc_type, f.name, f.submit_label, f.submit_role, f.submit_user_ids,
       coalesce((select jsonb_agg(jsonb_build_object('seq', s.seq, 'label', s.level_label, 'role', s.role_code, 'users', s.assignee_ids,
                                                      'sla_hours', s.sla_hours, 'warn_hours', s.warn_hours, 'enabled', s.enabled) order by s.seq)
                 from wf.approval_steps s where s.doc_type = f.doc_type), '[]') as steps,
       (select count(*) from wf.approval_requests r where r.doc_type = f.doc_type and r.status = 'PENDING') as running
from wf.approval_flows f;

-- ---------------------------------------------------------------------------
-- 5. Cảnh báo sắp đến hạn / quá hạn (chạy bằng pg_cron trên máy chủ, không cần trình duyệt)
-- ---------------------------------------------------------------------------
create table if not exists wf.sla_alerts (
  request_id      uuid not null references wf.approval_requests(id) on delete cascade,
  seq             smallint not null,
  step_started_at timestamptz not null,
  kind            text not null check (kind in ('WARN', 'OVERDUE')),
  created_at      timestamptz not null default now(),
  primary key (request_id, seq, step_started_at, kind)      -- mỗi lượt của một bước chỉ cảnh báo một lần mỗi loại
);
alter table wf.sla_alerts enable row level security;
revoke all on wf.sla_alerts from authenticated;
grant all on wf.sla_alerts to service_role;

create or replace function wf.check_sla() returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r record; v_kind text; v_n int := 0; v_due timestamptz; v_users uuid[];
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
    v_users := wf.step_actor_ids(r.st);
    perform wf.notify_users(v_users,
      case v_kind when 'OVERDUE' then 'Quá hạn duyệt: ' else 'Sắp đến hạn duyệt: ' end || r.doc_no,
      format('Bước "%s" hạn %s. %s', r.st ->> 'label', to_char(v_due at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM/YYYY'), coalesce(r.summary, '')),
      '/duyet/' || r.id, r.id, r.current_seq);
    v_n := v_n + cardinality(v_users);
  end loop;
  return v_n;
end $$;
revoke execute on function wf.check_sla() from authenticated, anon, public;
grant execute on function wf.check_sla() to service_role;   -- /api/cron/notify gọi dự phòng khi không có pg_cron

-- Hàng đợi email: nhận (claim) theo lô để hai lần gửi đồng thời không gửi trùng;
-- bỏ qua cảnh báo của bước đã hoàn tất/hủy
drop function if exists app.notification_outbox(int);
create or replace function app.notification_outbox(p_limit int default 50)
returns table (id bigint, email text, full_name text, title text, body text, link text)
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Chỉ máy chủ được đọc hàng đợi email'; end if;
  update wf.notifications n set emailed_at = now()
   where n.emailed_at is null and n.request_id is not null
     and not exists (select 1 from wf.approval_requests r where r.id = n.request_id and r.status = 'PENDING' and r.current_seq = n.step_seq);
  return query
  with c as (
    select n.id from wf.notifications n
    where n.emailed_at is null and n.created_at > now() - interval '2 days'
      and (n.email_claimed_at is null or n.email_claimed_at < now() - interval '10 minutes')
    order by n.id limit p_limit for update skip locked
  ), u as (
    update wf.notifications n set email_claimed_at = now() from c where n.id = c.id returning n.*
  )
  select u.id, au.email::text, p.full_name, u.title, u.body, u.link
  from u join core.profiles p on p.id = u.user_id join auth.users au on au.id = u.user_id
  order by u.id;
end $$;
revoke execute on function app.notification_outbox(int) from authenticated, anon, public;

-- Lịch chạy (chỉ khi máy chủ có pg_cron). Email: pg_net gọi /api/cron/notify nếu Vault có mes_app_url + mes_cron_secret.
create or replace function wf.push_email_job() returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_url text; v_secret text;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'mes_app_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'mes_cron_secret';
  if v_url is null or v_secret is null then return; end if;
  perform net.http_post(url := rtrim(v_url, '/') || '/api/cron/notify',
                        headers := jsonb_build_object('Authorization', 'Bearer ' || v_secret, 'Content-Type', 'application/json'),
                        body := '{}'::jsonb, timeout_milliseconds := 30000);
end $$;
revoke execute on function wf.push_email_job() from authenticated, anon, public;

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net;
  end if;
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('bmt-mes-sla', '*/10 * * * *', 'select wf.check_sla()');
    if exists (select 1 from pg_extension where extname = 'pg_net') and exists (select 1 from pg_namespace where nspname = 'vault') then
      perform cron.schedule('bmt-mes-email', '2-59/10 * * * *', 'select wf.push_email_job()');
    end if;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- View màn hình
-- ---------------------------------------------------------------------------
drop view if exists app.v_plans;
create view app.v_plans with (security_invoker = true) as
select pp.*, (select count(*) from plan.plan_lines l where l.plan_id = pp.id) as line_count,
       (select sum(qty_m) from plan.plan_lines l where l.plan_id = pp.id) as total_m,
       (select sum(ceil(qty_m / m_per_pack)) from plan.plan_lines l where l.plan_id = pp.id) as total_packs,
       (select id from plan.mrp_runs r where r.plan_id = pp.id order by run_at desc limit 1) as last_run_id
from plan.production_plans pp;

drop view if exists app.v_plan_lines;
create view app.v_plan_lines with (security_invoker = true) as
select l.*, p.code as product_code, p.description, s.status as spec_status, s.version as spec_version,
       r.total_kgkm, ceil(l.qty_m / l.m_per_pack) as packs,
       floor(l.qty_m / l.m_per_pack) as full_packs,
       l.qty_m - floor(l.qty_m / l.m_per_pack) * l.m_per_pack as odd_m,
       round(r.total_kgkm * l.m_per_pack / 1000, 2) as kg_per_pack
from plan.plan_lines l join master.products p on p.id = l.product_id
join master.product_specs s on s.id = l.spec_id left join master.spec_results r on r.spec_id = s.id;

drop view if exists app.v_mrp_lines;
create view app.v_mrp_lines with (security_invoker = true) as
select l.*, m.code as material_code, m.name as material_name, m.uom,
       coalesce(l.need_date, l.latest_order_date) as eff_need_date, app.user_name(l.adjusted_by) as adjusted_by_name
from plan.mrp_lines l join master.materials m on m.id = l.material_id;

create or replace view app.v_mrp_edits with (security_invoker = true) as
select e.*, m.code as material_code, m.name as material_name, app.user_name(e.edited_by) as edited_by_name
from plan.mrp_line_edits e join master.materials m on m.id = e.material_id;

create or replace view app.v_pack_options with (security_invoker = true) as
select pack_type, m_per_pack, sort from master.pack_options;

grant select on all tables in schema app to authenticated, service_role;
revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;
revoke execute on function app.notification_outbox(int) from authenticated;
revoke execute on function wf.notify_users(uuid[], text, text, text, uuid, smallint), wf.flow_config(text),
  plan.mark_mrp_stale(), plan.clear_mrp_stale(), plan.check_pack() from public, anon, authenticated;
