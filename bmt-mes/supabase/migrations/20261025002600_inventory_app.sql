-- BMT MES · 2400 · Module Kho (phần 3): luồng duyệt theo Quy chuẩn, cảnh báo hằng ngày, phân quyền,
-- tầng đọc cho web app (schema app) và báo cáo hao hụt

-- ===========================================================================
-- 1. Luồng duyệt theo Quy chuẩn vai trò & nhiệm vụ (mục 9)
-- ===========================================================================
-- Lĩnh vượt định mức: TP Kỹ thuật/QA duyệt (Quản lý SX giữ vai trò TP sản xuất nên không tự duyệt)
update wf.approval_flows set doc_table = 'inv.requisitions', rejected_status = 'CANCELLED', submit_label = 'Quản lý SX lập phiếu lĩnh bổ sung'
 where doc_type = 'EXTRA_ISSUE';
update wf.approval_steps set role_code = 'KT_TP', level_label = 'TP Kỹ thuật/QA duyệt lĩnh vượt định mức'
 where doc_type = 'EXTRA_ISSUE' and seq = 1;
-- Kiểm kê: Kế toán SX lập biên bản, Kế toán trưởng duyệt (A)
update wf.approval_flows set rejected_status = 'CANCELLED', submit_label = 'Kế toán SX lập biên bản kiểm kê', submit_role = 'KT_KHO'
 where doc_type = 'STOCK_ADJ';
delete from wf.approval_steps where doc_type = 'STOCK_ADJ' and seq > 1;
update wf.approval_steps set role_code = 'KTT', level_label = 'Kế toán trưởng duyệt chênh lệch kiểm kê' where doc_type = 'STOCK_ADJ' and seq = 1;
-- Bán phế: Quản lý SX lập, Kế toán SX kiểm tra, Giám đốc duyệt
update wf.approval_flows set rejected_status = 'CANCELLED', submit_label = 'Quản lý SX lập phiếu bán phế' where doc_type = 'SCRAP_OUT';
update wf.approval_steps set level_label = 'Kế toán SX kiểm tra' where doc_type = 'SCRAP_OUT' and seq = 1;
update wf.approval_steps set level_label = 'Giám đốc duyệt' where doc_type = 'SCRAP_OUT' and seq = 2;

insert into wf.approval_flows (doc_type, name, doc_table, status_col, approved_status, rejected_status, pending_status, submit_label, submit_role)
values ('STOCK_OPEN', 'Tồn kho đầu kỳ', 'inv.stock_docs', 'status', 'APPROVED', 'CANCELLED', 'PENDING_APPROVAL', 'Kế toán SX lập tồn đầu kỳ', 'KT_KHO'),
       ('DELIVERY', 'Lệnh giao hàng (xuất xưởng thành phẩm)', 'sales.deliveries', 'status', 'APPROVED', 'CANCELLED', 'PENDING_APPROVAL', 'NV5 lập lệnh giao', 'KHO_NV')
on conflict (doc_type) do nothing;
insert into wf.approval_steps (doc_type, seq, level_label, role_code, enabled, sla_hours) values
  ('STOCK_OPEN', 1, 'Kế toán trưởng duyệt', 'KTT', true, 24),
  ('DELIVERY', 1, 'TP Kỹ thuật/QA xác nhận chất lượng', 'KT_TP', true, 24),
  ('DELIVERY', 2, 'Giám đốc duyệt lệnh giao', 'BGD', true, 24)
on conflict do nothing;

-- ===========================================================================
-- 2. wf.act: hoàn tất duyệt chứng từ kho thì ghi sổ ngay; trả lại thì mở lại kiểm kê / hủy hàng tạo nháp
-- ===========================================================================
-- (thân hàm chép từ 2100, thêm nhánh kho — xem các dòng có ghi "kho:")
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
    -- kho: kiểm kê bị trả lại → mở lại để đếm/đóng lại; tồn đầu kỳ bị trả lại → hủy đơn vị chứa đã tạo
    if r.doc_type = 'STOCK_ADJ' then
      update inv.stock_counts set status = 'COUNTED' where adj_doc_id = r.doc_id and status = 'PENDING_APPROVAL';
    elsif r.doc_type = 'STOCK_OPEN' then
      update inv.handling_units set status = 'VOID', void_reason = 'Tồn đầu kỳ bị trả lại'
       where id in (select dl.hu_id from inv.stock_doc_lines dl where dl.doc_id = r.doc_id);
    end if;
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
  insert into wf.notifications (user_id, title, link) values (r.submitted_by, 'Đã duyệt: ' || r.doc_no, '/duyet/' || p_request);
  return 'APPROVED';
end $$;

-- ===========================================================================
-- 3. Cảnh báo hằng ngày (pg_cron): hậu kiểm quá hạn, lô chờ QC lâu, hàng sắp/đã hết hạn, dưới mức đặt hàng, phiếu nháp
-- ===========================================================================
create table if not exists inv.alert_log (
  kind       text not null,
  ref_id     uuid not null,
  period_key text not null default '',
  created_at timestamptz not null default now(),
  primary key (kind, ref_id, period_key)
);
alter table inv.alert_log enable row level security;
revoke all on inv.alert_log from authenticated, anon;
grant all on inv.alert_log to service_role;

create or replace function inv.daily_alerts() returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r record; v_n int := 0; v_week text := to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'IYYY-IW');
begin
  -- Phiếu đã ghi sổ chưa được Kế toán SX xác nhận quá hạn → Giám đốc + Kế toán SX
  for r in select d.* from inv.stock_docs d
           where d.status = 'POSTED' and d.review_status = 'PENDING'
             and d.posted_at < now() - make_interval(hours => coalesce(inv.setting('review_hours'), 24)::int) loop
    insert into inv.alert_log (kind, ref_id) values ('REVIEW', r.id) on conflict do nothing;
    continue when not found;
    perform wf.notify_users(inv.role_users(array['BGD', 'KT_KHO']), 'Phiếu kho chưa được Kế toán SX duyệt: ' || r.doc_no,
      'Ghi sổ lúc ' || to_char(r.posted_at at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM'), '/kho/phieu/' || r.id);
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
end $$;
revoke execute on function inv.daily_alerts() from public, anon, authenticated;
grant execute on function inv.daily_alerts() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('bmt_inv_daily_alerts', '5 0 * * *', 'select inv.daily_alerts()');   -- 07:05 giờ Việt Nam
  end if;
exception when others then
  raise notice 'Bỏ qua pg_cron: %', sqlerrm;
end $$;

-- ===========================================================================
-- 4. Phân quyền theo Quy chuẩn mục 10
-- ===========================================================================
-- Không gán chung cho 1 người: người giữ kho ≠ người ghi sổ ≠ người mua ≠ người duyệt chi
create or replace function app.admin_upsert_user(p_user uuid, p_full_name text, p_employee_code text,
                                                 p_department text, p_title text, p_roles text[], p_status text default 'ACTIVE')
returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_bad text;
begin
  if not core.has_perm('admin', 'edit') then raise exception 'Không có quyền quản trị người dùng'; end if;
  if p_user = auth.uid() and not ('ADMIN' = any(p_roles)) then
    raise exception 'Không tự gỡ vai trò ADMIN của chính mình';
  end if;
  select string_agg(x.label, '; ') into v_bad
  from (values ('THU_KHO','KT_KHO','Thủ kho + Kế toán kho'), ('KHO_NV','KT_KHO','NV kho + Kế toán kho'),
               ('THU_KHO','MUA_NV','Thủ kho + NV mua hàng'), ('KTT','KT_KHO','Kế toán trưởng + Kế toán kho')) x(a, b, label)
  where x.a = any(p_roles) and x.b = any(p_roles);
  if v_bad is not null then
    raise exception 'Không gán chung cho một người (Quy chuẩn mục 10): %', v_bad;
  end if;
  insert into core.profiles (id, full_name, employee_code, department, title, status)
  values (p_user, p_full_name, nullif(trim(p_employee_code), ''), nullif(p_department, ''), p_title, p_status)
  on conflict (id) do update set full_name = excluded.full_name, employee_code = excluded.employee_code,
    department = excluded.department, title = excluded.title, status = excluded.status;
  delete from core.user_roles where user_id = p_user and role_code <> all(p_roles);
  insert into core.user_roles (user_id, role_code) select p_user, unnest(p_roles) on conflict do nothing;
end $$;

-- Người dùng hiện tại: tính cả vai trò đang được ủy quyền (ví dụ tổ phó giữ kho thay Quản lý SX)
create or replace function app.me() returns jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
  with r as (
    select ur.role_code from core.user_roles ur where ur.user_id = auth.uid()
    union
    select d.role_code from core.delegations d where d.to_user = auth.uid() and now() between d.valid_from and d.valid_to
  )
  select jsonb_build_object(
    'id', p.id, 'full_name', p.full_name, 'employee_code', p.employee_code, 'status', p.status,
    'email', (select email from auth.users where id = p.id),
    'roles', coalesce((select jsonb_agg(r.role_code order by r.role_code) from r), '[]'),
    'delegated_roles', coalesce((select jsonb_agg(d.role_code || ':' || app.user_name(d.from_user)) from core.delegations d
                                 where d.to_user = p.id and now() between d.valid_from and d.valid_to), '[]'),
    'perms', coalesce((select jsonb_agg(distinct rp.module || ':' || rp.action)
                       from r join core.role_permissions rp on rp.role_code = r.role_code), '[]'),
    'can_see_price', core.can_see_price())
  from core.profiles p where p.id = auth.uid()
$$;

-- Cài đặt kho (Quản trị + vai trò phụ trách từng mục)
create or replace function app.save_setting(p_key text, p_num numeric, p_text text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare s inv.settings;
begin
  select * into s from inv.settings where key = p_key for update;
  if not found then raise exception 'Không có mục cài đặt %', p_key; end if;
  if not (core.has_role('ADMIN') or (s.owner_role is not null and core.has_role(s.owner_role))) then
    raise exception 'Mục "%" do % cài đặt', s.label, (select r.name from core.roles r where r.code = s.owner_role);
  end if;
  if p_num is not null and p_num < 0 then raise exception 'Giá trị phải ≥ 0'; end if;
  if p_key = 'issue_hours' and coalesce(trim(p_text), '') <> '' and not exists (
       select 1 where (select bool_and(w ~ '^\d{1,2}:\d{2}-\d{1,2}:\d{2}$') from unnest(string_to_array(replace(p_text, ' ', ''), ',')) w)) then
    raise exception 'Khung giờ dạng 06:30-08:00,16:30-17:30';
  end if;
  update inv.settings set num_value = p_num, text_value = nullif(trim(coalesce(p_text, '')), ''), updated_at = now(), updated_by = auth.uid()
   where key = p_key;
end $$;

create or replace function app.save_location(p_id uuid, p_wh text, p_code text, p_name text, p_kind text, p_active boolean) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_wh uuid := inv.wh(p_wh); v_id uuid := p_id;
begin
  if v_wh is null then raise exception 'Chọn kho'; end if;
  if not (core.has_role('ADMIN') or inv.keeper_mode(v_wh) = 'DIRECT') then raise exception 'Chỉ người giữ kho hoặc Quản trị sửa vị trí'; end if;
  if coalesce(trim(p_code), '') = '' then raise exception 'Nhập mã vị trí'; end if;
  if v_id is null then
    insert into inv.locations (warehouse_id, code, name, kind, active, sort)
    values (v_wh, upper(trim(p_code)), nullif(trim(p_name), ''), coalesce(p_kind, 'STORE'), coalesce(p_active, true),
            coalesce((select max(sort) + 1 from inv.locations where warehouse_id = v_wh), 1))
    returning id into v_id;
  else
    update inv.locations set code = upper(trim(p_code)), name = nullif(trim(p_name), ''), kind = coalesce(p_kind, kind),
           active = coalesce(p_active, active) where id = v_id and warehouse_id = v_wh;
    if not found then raise exception 'Không có vị trí'; end if;
    if not coalesce(p_active, true) and exists (select 1 from inv.stock_balances b where b.location_key = v_id and b.qty > 0) then
      raise exception 'Vị trí còn hàng: chuyển hết hàng trước khi ngưng dùng';
    end if;
  end if;
  return v_id;
exception when unique_violation then raise exception 'Mã vị trí % đã có', upper(trim(p_code));
end $$;

create or replace function app.save_package_type(p_id uuid, p_code text, p_name text, p_tare numeric, p_group text, p_active boolean) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid := p_id;
begin
  if not (core.has_role('ADMIN') or core.has_role('THU_KHO') or core.has_role('MUA_NV') or core.has_role('KT_KHO')) then
    raise exception 'Không có quyền sửa bảng bì';
  end if;
  if coalesce(trim(p_code), '') = '' or coalesce(trim(p_name), '') = '' then raise exception 'Nhập mã và tên loại bao bì'; end if;
  if p_tare is null or p_tare < 0 then raise exception 'Nhập bì (kg) ≥ 0'; end if;
  if v_id is null then
    insert into master.package_types (code, name, tare_kg, material_group, active)
    values (upper(trim(p_code)), trim(p_name), p_tare, nullif(p_group, ''), coalesce(p_active, true)) returning id into v_id;
  else
    update master.package_types set code = upper(trim(p_code)), name = trim(p_name), tare_kg = p_tare,
           material_group = nullif(p_group, ''), active = coalesce(p_active, true) where id = v_id;
  end if;
  return v_id;
exception when unique_violation then raise exception 'Mã % đã có', upper(trim(p_code));
end $$;

create or replace function app.save_carrier(p_id uuid, p_code text, p_type text, p_tare numeric, p_owner text, p_status text, p_note text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid := p_id; c inv.carriers;
begin
  if not (core.has_role('ADMIN') or inv.keeper_mode(inv.wh('KBTP')) = 'DIRECT') then raise exception 'Chỉ Quản lý SX quản lý bobin trung gian'; end if;
  if coalesce(trim(p_code), '') = '' or coalesce(trim(p_type), '') = '' then raise exception 'Nhập mã và loại bobin'; end if;
  if v_id is null then
    insert into inv.carriers (code, carrier_type, tare_kg, owner, status, note, location_id)
    values (upper(trim(p_code)), upper(trim(p_type)), coalesce(p_tare, 0), coalesce(p_owner, 'BMT'), 'EMPTY', nullif(trim(p_note), ''), inv.loc('KBTP-EMPTY'))
    returning id into v_id;
  else
    select * into c from inv.carriers where id = v_id for update;
    if c.status = 'IN_USE' and p_status <> 'IN_USE' then raise exception 'Bobin đang chứa hàng: dùng hết hàng trước'; end if;
    if p_status = 'IN_USE' and c.status <> 'IN_USE' then raise exception 'Trạng thái "Đang chứa" do hệ thống ghi khi ghi đầu ra'; end if;
    update inv.carriers set code = upper(trim(p_code)), carrier_type = upper(trim(p_type)), tare_kg = coalesce(p_tare, 0),
           owner = coalesce(p_owner, owner), status = coalesce(p_status, status), note = nullif(trim(p_note), '') where id = v_id;
  end if;
  return v_id;
exception when unique_violation then raise exception 'Mã bobin % đã có', upper(trim(p_code));
end $$;

-- Mức đặt hàng, hạn dùng, khu cất, nhóm ABC (Kế toán SX theo dõi tồn tối thiểu, NV mua hàng)
create or replace function app.save_material_stock(p_material uuid, p_reorder numeric, p_shelf_life int, p_zone text, p_abc text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if not (core.has_role('ADMIN') or core.has_role('KT_KHO') or core.has_role('MUA_NV') or core.has_role('MUA_TP')) then
    raise exception 'Chỉ Kế toán SX, NV mua hàng sửa mức đặt hàng';
  end if;
  if p_reorder is not null and p_reorder < 0 then raise exception 'Mức đặt hàng phải ≥ 0'; end if;
  update master.materials set reorder_point = p_reorder, shelf_life_days = nullif(p_shelf_life, 0),
         storage_zone = nullif(p_zone, ''), abc_class = nullif(p_abc, '') where id = p_material;
end $$;

-- ===========================================================================
-- 5. RLS + quyền cho bảng mới
-- ===========================================================================
insert into core.table_modules (table_name, module) values
  ('inv.settings','inventory'), ('inv.warehouse_keepers','inventory'), ('inv.carriers','inventory'), ('inv.requisitions','inventory'),
  ('inv.requisition_lines','inventory'), ('master.package_types','master'), ('sales.delivery_lines','sales'),
  ('inv.stock_count_lines','inventory')
on conflict (table_name) do nothing;

do $$
declare t text;
begin
  foreach t in array array['inv.settings','inv.warehouse_keepers','inv.carriers','inv.requisitions','inv.requisition_lines',
                           'master.package_types','sales.delivery_lines','inv.stock_count_lines'] loop
    execute format('alter table %s enable row level security', t);
    execute format('drop policy if exists p_select on %s', t);
    execute format('drop policy if exists p_insert on %s', t);
    execute format('drop policy if exists p_update on %s', t);
    execute format('drop policy if exists p_delete on %s', t);
    execute format('grant select on %s to authenticated', t);
    execute format('grant all on %s to service_role', t);
  end loop;
end $$;
-- Danh mục dùng chung: ai đăng nhập cũng đọc được; ghi qua hàm
create policy p_select on inv.settings for select to authenticated using (true);
create policy p_select on inv.warehouse_keepers for select to authenticated using (true);
create policy p_select on master.package_types for select to authenticated using (true);
create policy p_select on inv.carriers for select to authenticated using (core.has_perm('inventory', 'view') or core.has_perm('production', 'view'));
create policy p_select on inv.requisitions for select to authenticated using (core.has_perm('inventory', 'view') or core.has_perm('production', 'view'));
create policy p_select on inv.requisition_lines for select to authenticated using (core.has_perm('inventory', 'view') or core.has_perm('production', 'view'));
create policy p_select on sales.delivery_lines for select to authenticated using (core.has_perm('inventory', 'view') or core.has_perm('sales', 'view'));
create policy p_select on inv.stock_count_lines for select to authenticated using (core.has_perm('inventory', 'view'));
-- Chứng từ kho, lô, đơn vị chứa: chỉ ghi qua hàm nghiệp vụ (tránh sửa số lượng ngoài quy trình)
revoke insert, update, delete on inv.handling_units, inv.requisitions, inv.requisition_lines, inv.stock_count_lines,
  inv.carriers, inv.settings, inv.warehouse_keepers, master.package_types, sales.delivery_lines from authenticated;
-- Vận hành, đóng gói, QC xem đơn vị chứa/lô để quét
drop policy if exists p_select on inv.handling_units;
create policy p_select on inv.handling_units for select to authenticated using (core.has_perm('inventory', 'view') or core.has_perm('production', 'view'));

-- ===========================================================================
-- 6. Tầng đọc cho màn hình kho (security_invoker: RLS của người đang đăng nhập)
-- ===========================================================================
create or replace view app.v_hu with (security_invoker = true) as
select h.id, h.hu_no, h.qr_payload, h.hu_type, h.status, h.qty, h.init_qty, h.gross_kg, h.tare_kg, h.is_remnant, h.print_count,
       h.last_printed_at, h.parent_hu_id, h.created_at,
       coalesce((select sum(b.reserved_qty) from inv.stock_balances b where b.hu_key = h.id), 0) as reserved_qty,
       l.id as lot_id, l.lot_no, l.item_kind, l.qc_status, l.mfg_date, l.exp_date, l.supplier_lot, l.brand, l.color, l.wip_stage, l.uom,
       coalesce(m.code, p.code) as item_code, coalesce(m.name, p.description) as item_name, m.group_code, m.id as material_id, p.id as product_id,
       w.code as warehouse_code, w.name as warehouse_name, h.warehouse_id, loc.code as location_code, loc.name as location_name, h.location_id,
       sp.name as supplier_name, wo.wo_no, wo.id as wo_id, o.op_code, cr.code as carrier_code,
       (l.exp_date is not null and l.exp_date < current_date) as expired
from inv.handling_units h
join inv.lots l on l.id = h.lot_id
left join master.materials m on m.id = l.material_id
left join master.products p on p.id = l.product_id
left join inv.warehouses w on w.id = h.warehouse_id
left join inv.locations loc on loc.id = h.location_id
left join core.partners sp on sp.id = l.supplier_id
left join mfg.wo_operations o on o.id = l.wo_op_id
left join mfg.work_orders wo on wo.id = o.wo_id
left join inv.carriers cr on cr.id = h.carrier_id;

create or replace view app.v_stock with (security_invoker = true) as
select b.warehouse_id, w.code as warehouse_code, nullif(b.location_key, '00000000-0000-0000-0000-000000000000') as location_id,
       loc.code as location_code, b.lot_id, l.lot_no, nullif(b.hu_key, '00000000-0000-0000-0000-000000000000') as hu_id, h.hu_no,
       l.item_kind, coalesce(m.code, p.code) as item_code, coalesce(m.name, p.description) as item_name, coalesce(m.uom, l.uom) as uom,
       m.group_code, l.qc_status, l.exp_date, l.mfg_date, l.brand, l.color, l.wip_stage, b.qty, b.reserved_qty, b.qty - b.reserved_qty as available,
       coalesce(h.is_remnant, false) as is_remnant, b.updated_at,
       (l.exp_date is not null and l.exp_date < current_date + coalesce(inv.setting('expiry_warn_days'), 30)::int) as expiring
from inv.stock_balances b
join inv.warehouses w on w.id = b.warehouse_id
join inv.lots l on l.id = b.lot_id
left join inv.locations loc on loc.id = nullif(b.location_key, '00000000-0000-0000-0000-000000000000')
left join inv.handling_units h on h.id = nullif(b.hu_key, '00000000-0000-0000-0000-000000000000')
left join master.materials m on m.id = l.material_id
left join master.products p on p.id = l.product_id
where b.qty > 0;

create or replace view app.v_stock_docs with (security_invoker = true) as
select d.id, d.doc_no, d.doc_type, d.status, d.doc_date, d.warehouse_id, w.code as warehouse_code, tw.code as to_warehouse_code,
       d.ref_type, d.ref_id, d.reason_code, rc.name as reason_name, d.note, d.posted_at, d.created_at,
       d.review_status, d.reviewed_at, d.review_note, d.price_pending, d.delegated, d.off_hours_reason,
       d.reversal_of, d.reversed_by, d.requisition_id, d.receiver_id, d.received_at,
       app.user_name(d.created_by) as created_by_name, d.created_by, app.user_name(d.posted_by) as posted_by_name, d.posted_by,
       app.user_name(d.reviewed_by) as reviewed_by_name, app.user_name(d.receiver_id) as receiver_name, app.user_name(d.witness_id) as witness_name,
       (select count(*) from inv.stock_doc_lines x where x.doc_id = d.id) as line_count,
       (select sum(abs(x.qty)) from inv.stock_doc_lines x where x.doc_id = d.id) as total_qty,
       case d.ref_type when 'WO' then (select wo.wo_no from mfg.work_orders wo where wo.id = d.ref_id)
                       when 'GR' then (select coalesce(po.po_no, 'Không theo PO') from purchase.goods_receipts g left join purchase.purchase_orders po on po.id = g.po_id where g.id = d.ref_id)
                       when 'DELIVERY' then (select dv.delivery_no from sales.deliveries dv where dv.id = d.ref_id)
                       when 'COUNT' then (select c.count_no from inv.stock_counts c where c.id = d.ref_id)
                       when 'SO' then (select so.so_no from sales.sales_orders so where so.id = d.ref_id) end as ref_no,
       (select rq.req_no from inv.requisitions rq where rq.id = d.requisition_id) as req_no,
       (select ar.id from wf.approval_requests ar where ar.doc_id = d.id order by ar.submitted_at desc limit 1) as approval_id
from inv.stock_docs d
join inv.warehouses w on w.id = d.warehouse_id
left join inv.warehouses tw on tw.id = d.to_warehouse_id
left join master.reason_codes rc on rc.code = d.reason_code;

create or replace view app.v_stock_doc_lines with (security_invoker = true) as
select dl.id, dl.doc_id, dl.line_no, dl.lot_id, l.lot_no, dl.hu_id, h.hu_no, dl.qty, dl.weight_kg, dl.gross_kg, dl.tare_kg, dl.reason, dl.note,
       coalesce(m.code, p.code) as item_code, coalesce(m.name, p.description) as item_name, coalesce(m.uom, l.uom) as uom, l.item_kind,
       l.qc_status, l.exp_date, l.supplier_lot, loc.code as location_code, tl.code as to_location_code
from inv.stock_doc_lines dl
join inv.lots l on l.id = dl.lot_id
left join inv.handling_units h on h.id = dl.hu_id
left join master.materials m on m.id = l.material_id
left join master.products p on p.id = l.product_id
left join inv.locations loc on loc.id = dl.location_id
left join inv.locations tl on tl.id = dl.to_location_id;

-- Giá trên dòng chứng từ: chỉ người được xem giá
create or replace function app.doc_line_prices(p_doc uuid) returns table (line_id uuid, unit_cost numeric, amount numeric)
language sql stable security definer set search_path = pg_catalog, public as $$
  select dl.id, coalesce(dl.unit_cost, (select sm.unit_cost from inv.stock_moves sm where sm.doc_line_id = dl.id order by sm.id limit 1)),
         round(abs(dl.qty) * coalesce(dl.unit_cost, (select sm.unit_cost from inv.stock_moves sm where sm.doc_line_id = dl.id order by sm.id limit 1)), 0)
  from inv.stock_doc_lines dl where dl.doc_id = p_doc and core.can_see_price()
$$;

create or replace view app.v_requisitions with (security_invoker = true) as
select r.id, r.req_no, r.kind, r.status, r.work_date, r.qty_m, r.reason_code, rc.name as reason_name, r.note, r.created_at,
       app.user_name(r.created_by) as created_by_name, r.wo_id, wo.wo_no, wo.status as wo_status, p.code as product_code, p.description as product_name,
       (select count(*) from inv.requisition_lines x where x.req_id = r.id) as line_count,
       (select count(*) from inv.requisition_lines x where x.req_id = r.id and x.qty_issued - x.qty_returned >= x.qty_req) as line_done,
       (select ar.id from wf.approval_requests ar where ar.doc_id = r.id order by ar.submitted_at desc limit 1) as approval_id
from inv.requisitions r
join mfg.work_orders wo on wo.id = r.wo_id
join master.products p on p.id = wo.product_id
left join master.reason_codes rc on rc.code = r.reason_code;

create or replace view app.v_requisition_lines with (security_invoker = true) as
select rl.id, rl.req_id, rl.material_id, m.code as material_code, m.name as material_name, m.uom, m.has_expiry,
       rl.qty_norm, rl.qty_req, rl.qty_issued, rl.qty_returned, greatest(rl.qty_req - (rl.qty_issued - rl.qty_returned), 0) as remaining,
       coalesce((select sum(b.qty - b.reserved_qty) from inv.stock_balances b join inv.lots l on l.id = b.lot_id
                 where l.material_id = rl.material_id and l.qc_status = 'PASSED' and b.warehouse_id = inv.wh('KNL')
                   and (l.exp_date is null or l.exp_date >= current_date)), 0) as available
from inv.requisition_lines rl join master.materials m on m.id = rl.material_id;

-- Gợi ý đơn vị chứa xuất trước (FEFO/FIFO) cho một vật tư
create or replace view app.v_pick_suggest with (security_invoker = true) as
select h.id as hu_id, h.hu_no, l.material_id, l.lot_no, l.exp_date, l.created_at as received_at, h.qty,
       h.qty - coalesce((select sum(b.reserved_qty) from inv.stock_balances b where b.hu_key = h.id), 0) as available,
       loc.code as location_code,
       row_number() over (partition by l.material_id order by l.exp_date nulls last, l.created_at, h.hu_no) as pick_order
from inv.handling_units h join inv.lots l on l.id = h.lot_id left join inv.locations loc on loc.id = h.location_id
where h.status = 'ACTIVE' and h.warehouse_id = inv.wh('KNL') and l.item_kind = 'MAT' and l.qc_status = 'PASSED'
  and (l.exp_date is null or l.exp_date >= current_date) and h.qty > 0;

create or replace view app.v_qc_queue with (security_invoker = true) as
select l.id as lot_id, l.lot_no, l.item_kind, l.qc_status, l.supplier_lot, l.mfg_date, l.exp_date, l.created_at, l.weight_kg,
       coalesce(m.code, p.code) as item_code, coalesce(m.name, p.description) as item_name, coalesce(m.uom, l.uom) as uom, m.requires_coa,
       sp.name as supplier_name, wo.wo_no, o.op_code,
       coalesce((select sum(b.qty) from inv.stock_balances b where b.lot_id = l.id), 0) as qty,
       (select count(*) from inv.handling_units h where h.lot_id = l.id and h.status = 'ACTIVE') as hu_count,
       (select n.ncr_no from qa.ncrs n where n.lot_id = l.id and n.status = 'OPEN' order by n.created_at desc limit 1) as ncr_no,
       (select n.description from qa.ncrs n where n.lot_id = l.id and n.status = 'OPEN' order by n.created_at desc limit 1) as ncr_text,
       r.total_kgkm, r.rdc_limit, r.od_mm
from inv.lots l
left join master.materials m on m.id = l.material_id
left join master.products p on p.id = l.product_id
left join core.partners sp on sp.id = l.supplier_id
left join mfg.wo_operations o on o.id = l.wo_op_id
left join mfg.work_orders wo on wo.id = o.wo_id
left join master.spec_results r on r.spec_id = l.spec_id
where l.qc_status in ('PENDING', 'QUARANTINE');

create or replace view app.v_counts with (security_invoker = true) as
select c.id, c.count_no, c.warehouse_id, w.code as warehouse_code, c.status, c.count_type, c.count_date, c.note, c.adj_doc_id, c.closed_at,
       app.user_name(c.created_by) as created_by_name,
       (select count(*) from inv.stock_count_lines l where l.count_id = c.id) as line_count,
       (select count(*) from inv.stock_count_lines l where l.count_id = c.id and l.counted_qty is not null) as counted,
       (select count(*) from inv.stock_count_lines l where l.count_id = c.id and l.counted_qty is not null and l.counted_qty <> l.system_qty) as diff_lines,
       (select array_agg(loc.code order by loc.code) from inv.locations loc where loc.id = any(c.location_ids)) as location_codes
from inv.stock_counts c join inv.warehouses w on w.id = c.warehouse_id;

-- Đếm mù: chỉ Kế toán SX (chủ trì) thấy số sổ sách
create or replace view app.v_count_lines with (security_invoker = true) as
select cl.id, cl.count_id, cl.lot_id, l.lot_no, nullif(cl.hu_key, '00000000-0000-0000-0000-000000000000') as hu_id, h.hu_no,
       cl.location_id, loc.code as location_code, coalesce(m.code, p.code) as item_code, coalesce(m.name, p.description) as item_name,
       coalesce(m.uom, l.uom) as uom,
       case when core.has_role('KT_KHO') then cl.system_qty end as system_qty,
       cl.counted_qty, app.user_name(cl.counted_by) as counted_by_name, cl.counted_at, cl.note,
       case when core.has_role('KT_KHO') and cl.counted_qty is not null then cl.counted_qty - cl.system_qty end as diff
from inv.stock_count_lines cl
join inv.lots l on l.id = cl.lot_id
left join inv.handling_units h on h.id = nullif(cl.hu_key, '00000000-0000-0000-0000-000000000000')
left join inv.locations loc on loc.id = cl.location_id
left join master.materials m on m.id = l.material_id
left join master.products p on p.id = l.product_id;

create or replace view app.v_open_wos with (security_invoker = true) as
select wo.id, wo.wo_no, wo.status, wo.qty_m, wo.run_lots, wo.m_per_pack, wo.pack_type, wo.brand, p.code as product_code, p.description as product_name,
       coalesce((select sum(r.qty_m) from inv.requisitions r where r.wo_id = wo.id and r.kind = 'NORM' and r.status <> 'CANCELLED'), 0) as requisitioned_m,
       (select array_agg(o.op_code order by o.seq) from mfg.wo_operations o where o.wo_id = wo.id) as ops
from mfg.work_orders wo join master.products p on p.id = wo.product_id
where wo.status in ('RELEASED', 'IN_PROGRESS');

create or replace view app.v_carriers with (security_invoker = true) as
select c.id, c.code, c.carrier_type, c.tare_kg, c.owner, c.status, c.note, loc.code as location_code, h.hu_no, h.qty, l.lot_no
from inv.carriers c left join inv.locations loc on loc.id = c.location_id
left join inv.handling_units h on h.id = c.current_hu_id left join inv.lots l on l.id = h.lot_id;

create or replace view app.v_deliveries with (security_invoker = true) as
select dv.id, dv.delivery_no, dv.status, dv.ship_date, dv.note, dv.created_at, dv.stock_doc_id, so.id as so_id, so.so_no, so.label_brand,
       cu.name as customer_name, app.user_name(dv.created_by) as created_by_name,
       (select count(*) from sales.delivery_lines x where x.delivery_id = dv.id) as reel_count,
       (select sum(x.qty_m) from sales.delivery_lines x where x.delivery_id = dv.id) as total_m,
       (select ar.id from wf.approval_requests ar where ar.doc_id = dv.id order by ar.submitted_at desc limit 1) as approval_id
from sales.deliveries dv join sales.sales_orders so on so.id = dv.so_id left join core.partners cu on cu.id = so.customer_id;

create or replace view app.v_delivery_lines with (security_invoker = true) as
select dl.id, dl.delivery_id, dl.hu_id, h.hu_no, l.lot_no, dl.qty_m, p.code as product_code, p.description as product_name, loc.code as location_code
from sales.delivery_lines dl join inv.handling_units h on h.id = dl.hu_id join inv.lots l on l.id = dl.lot_id
join master.products p on p.id = l.product_id left join inv.locations loc on loc.id = h.location_id;

-- Bobin đã giữ cho đơn bán đã duyệt, chưa nằm trong lệnh giao đang chạy
create or replace view app.v_so_reserved with (security_invoker = true) as
select so.id as so_id, so.so_no, so.label_brand, cu.name as customer_name, so.required_date, sr.hu_id, h.hu_no, sr.qty_m,
       p.code as product_code, p.description as product_name, loc.code as location_code
from sales.so_reservations sr
join sales.so_lines sl on sl.id = sr.so_line_id
join sales.sales_orders so on so.id = sl.so_id
join master.products p on p.id = sl.product_id
left join core.partners cu on cu.id = so.customer_id
left join inv.handling_units h on h.id = sr.hu_id
left join inv.locations loc on loc.id = h.location_id
where sr.released_at is null and so.status = 'APPROVED' and sr.hu_id is not null
  and not exists (select 1 from sales.delivery_lines dl join sales.deliveries dv on dv.id = dl.delivery_id
                  where dl.hu_id = sr.hu_id and dv.status in ('DRAFT', 'PENDING_APPROVAL', 'APPROVED', 'PICKED'));

-- Thẻ kho (số lượng, không giá)
create or replace view app.v_ledger with (security_invoker = true) as
select sm.id, sm.moved_at, d.doc_date, d.doc_no, d.doc_type, d.id as doc_id, w.code as warehouse_code, loc.code as location_code,
       l.lot_no, h.hu_no, coalesce(m.code, p.code) as item_code, coalesce(m.name, p.description) as item_name, coalesce(m.uom, l.uom) as uom,
       l.material_id, l.product_id, sm.warehouse_id, sm.qty, app.user_name(sm.posted_by) as posted_by_name
from inv.stock_moves sm
join inv.stock_docs d on d.id = sm.doc_id
join inv.warehouses w on w.id = sm.warehouse_id
join inv.lots l on l.id = sm.lot_id
left join inv.locations loc on loc.id = sm.location_id
left join inv.handling_units h on h.id = sm.hu_id
left join master.materials m on m.id = l.material_id
left join master.products p on p.id = l.product_id;

create or replace view app.v_open_po_lines with (security_invoker = true) as
select po.id as po_id, po.po_no, po.status as po_status, sp.name as supplier_name, pl.id as line_id, pl.line_no,
       m.code as material_code, m.name as material_name, m.uom, m.has_expiry, pl.qty, pl.received_qty, pl.expected_date
from purchase.purchase_orders po
join purchase.po_lines pl on pl.po_id = po.id
join master.materials m on m.id = pl.material_id
left join core.partners sp on sp.id = po.supplier_id
where po.status in ('APPROVED', 'SENT', 'PARTIAL_RECEIVED');

create or replace view app.v_locations with (security_invoker = true) as
select l.id, l.code, l.name, l.kind, l.sort, l.active, w.code as warehouse_code, w.id as warehouse_id,
       (select count(*) from inv.stock_balances b where b.location_key = l.id and b.qty > 0) as units
from inv.locations l join inv.warehouses w on w.id = l.warehouse_id;

create or replace view app.v_inv_settings with (security_invoker = true) as
select s.key, s.label, s.num_value, s.text_value, s.unit, s.owner_role, r.name as owner_role_name, s.sort, s.updated_at, app.user_name(s.updated_by) as updated_by_name
from inv.settings s left join core.roles r on r.code = s.owner_role;

-- Nhập – xuất – tồn theo kỳ (số lượng; giá trị chỉ khi được xem giá)
create or replace function app.stock_nxt(p_from date, p_to date, p_wh uuid default null)
returns table (warehouse_code text, item_code text, item_name text, uom text, item_kind text,
               opening numeric, qty_in numeric, qty_out numeric, closing numeric,
               value_opening numeric, value_in numeric, value_out numeric, value_closing numeric)
language sql stable security definer set search_path = pg_catalog, public as $$
  with mv as (
    select sm.warehouse_id, coalesce(l.material_id, l.product_id) as item_id, l.item_kind, sm.qty, sm.qty * sm.unit_cost as val, d.doc_date
    from inv.stock_moves sm join inv.stock_docs d on d.id = sm.doc_id join inv.lots l on l.id = sm.lot_id
    where (p_wh is null or sm.warehouse_id = p_wh) and d.doc_date <= p_to
      and core.has_perm('inventory', 'view')
  ), agg as (
    select warehouse_id, item_id, item_kind,
           sum(qty) filter (where doc_date < p_from) as op,
           sum(qty) filter (where doc_date >= p_from and qty > 0) as qin,
           -sum(qty) filter (where doc_date >= p_from and qty < 0) as qout,
           sum(val) filter (where doc_date < p_from) as vop,
           sum(val) filter (where doc_date >= p_from and qty > 0) as vin,
           -sum(val) filter (where doc_date >= p_from and qty < 0) as vout
    from mv group by warehouse_id, item_id, item_kind
  )
  select w.code, coalesce(m.code, p.code), coalesce(m.name, p.description), coalesce(m.uom, 'm'), a.item_kind,
         coalesce(a.op, 0), coalesce(a.qin, 0), coalesce(a.qout, 0), coalesce(a.op, 0) + coalesce(a.qin, 0) - coalesce(a.qout, 0),
         case when core.can_see_price() then round(coalesce(a.vop, 0)) end, case when core.can_see_price() then round(coalesce(a.vin, 0)) end,
         case when core.can_see_price() then round(coalesce(a.vout, 0)) end,
         case when core.can_see_price() then round(coalesce(a.vop, 0) + coalesce(a.vin, 0) - coalesce(a.vout, 0)) end
  from agg a join inv.warehouses w on w.id = a.warehouse_id
  left join master.materials m on m.id = a.item_id and a.item_kind in ('MAT', 'SCRAP')
  left join master.products p on p.id = a.item_id and a.item_kind in ('WIP', 'FG')
  where coalesce(a.op, 0) <> 0 or coalesce(a.qin, 0) <> 0 or coalesce(a.qout, 0) <> 0
  order by w.code, 2
$$;

-- Số việc cho trang Tổng quan kho
create or replace function app.kho_overview() returns jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
  select case when core.has_perm('inventory', 'view') or core.has_perm('production', 'view') then jsonb_build_object(
    'qc_pending', (select count(*) from inv.lots where qc_status = 'PENDING'),
    'quarantine', (select count(*) from inv.lots l where qc_status = 'QUARANTINE' and exists (select 1 from inv.stock_balances b where b.lot_id = l.id and b.qty > 0)),
    'review_pending', (select count(*) from inv.stock_docs where status = 'POSTED' and review_status = 'PENDING'),
    'review_overdue', (select count(*) from inv.stock_docs where status = 'POSTED' and review_status = 'PENDING'
                         and posted_at < now() - make_interval(hours => coalesce(inv.setting('review_hours'), 24)::int)),
    'returned', (select count(*) from inv.stock_docs where review_status = 'RETURNED' and reversed_by is null),
    'price_pending', (select count(*) from inv.stock_docs where status = 'DRAFT' and price_pending),
    'req_open', (select count(*) from inv.requisitions where status in ('APPROVED', 'PARTIAL')),
    'req_waiting', (select count(*) from inv.requisitions where status = 'PENDING_APPROVAL'),
    'issue_unconfirmed', (select count(*) from inv.stock_docs where doc_type = 'ISSUE_WO' and status = 'POSTED' and receiver_id is not null and received_at is null),
    'my_receipts', (select count(*) from inv.stock_docs where doc_type = 'ISSUE_WO' and status = 'POSTED' and receiver_id = auth.uid() and received_at is null),
    'expiring', (select count(*) from inv.lots l where l.qc_status = 'PASSED' and l.exp_date >= current_date
                   and l.exp_date <= current_date + coalesce(inv.setting('expiry_warn_days'), 30)::int
                   and exists (select 1 from inv.stock_balances b where b.lot_id = l.id and b.qty > 0)),
    'below_reorder', (select count(*) from master.materials m left join inv.v_material_availability a on a.material_id = m.id
                        where m.reorder_point is not null and coalesce(a.available, 0) + coalesce(a.in_quality, 0) <= m.reorder_point),
    'counts_open', (select count(*) from inv.stock_counts where status in ('OPEN', 'COUNTED', 'PENDING_APPROVAL')),
    'deliveries_ready', (select count(*) from sales.deliveries where status = 'APPROVED'),
    'deliveries_waiting', (select count(*) from sales.deliveries where status = 'PENDING_APPROVAL'),
    'remnants', (select count(*) from inv.handling_units where status = 'ACTIVE' and is_remnant),
    'drafts', (select count(*) from inv.stock_docs where status = 'DRAFT' and not price_pending)
  ) end
$$;

-- ===========================================================================
-- 7. Báo cáo hao hụt
-- ===========================================================================
create or replace function inv.scrap_category(p_reason text) returns text
language sql immutable as $$
  select case when p_reason in ('SC_STARTUP','SC_PURGE','SC_COLOR') then 'STARTUP'
              when p_reason in ('SC_OD','SC_SPARK','SC_BREAK','SC_PRINT') then 'QUALITY'
              when p_reason = 'SC_TAIL' then 'LENGTH' else 'OTHER' end
$$;

create or replace function app.can_see_loss() returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select core.has_perm('production', 'view') or core.has_perm('inventory', 'view') or core.has_perm('cost', 'view')
$$;

-- Một dòng cho mỗi lệnh SX có hoạt động trong kỳ: tiêu hao, 5 nhóm hao hụt, cân bằng đồng
create or replace function app.loss_by_wo(p_from date, p_to date)
returns table (
  wo_id uuid, wo_no text, wo_status text, product_code text, product_name text, good_m numeric, qty_m numeric,
  issued_kg numeric, norm_kg numeric, var_kg numeric, var_pct numeric,
  fg_kg numeric, fg_theory_kg numeric, weighed_km numeric, kgkm_theory numeric, kgkm_actual numeric, giveaway_kg numeric, giveaway_pct numeric,
  startup_kg numeric, quality_kg numeric, tail_kg numeric, other_scrap_kg numeric, overlength_m numeric, overlength_kg numeric, wip_kg numeric,
  unexplained_kg numeric,
  cu_issued numeric, cu_fg numeric, cu_scrap numeric, cu_cable numeric, cu_wip numeric, cu_diff numeric, cu_diff_pct numeric, cu_ok boolean,
  last_activity date)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_tol numeric := coalesce(inv.setting('copper_tol_pct'), 1);
begin
  if not app.can_see_loss() then raise exception 'Không có quyền xem báo cáo hao hụt'; end if;
  return query
  with act as (
    select d.ref_id as wid, max(d.doc_date) as dt from inv.stock_docs d
     where d.ref_type = 'WO' and d.status = 'POSTED' and d.doc_date between p_from and p_to group by d.ref_id
    union all
    select o.wo_id, max((s.recorded_at at time zone 'Asia/Ho_Chi_Minh')::date) from mfg.scrap_records s join mfg.wo_operations o on o.id = s.wo_op_id
     where (s.recorded_at at time zone 'Asia/Ho_Chi_Minh')::date between p_from and p_to group by o.wo_id
  ), ws as (
    select a.wid, max(a.dt) as dt from act a group by a.wid
  ), base as (
    select w.id, w.wo_no, w.status, w.qty_m, w.m_per_pack, w.product_id, w.spec_id, ws.dt, s.cores,
           coalesce(r.metal_kgkm, 0) as metal, coalesce(r.drain_kgkm, 0) as drain, coalesce(r.ins_kgkm, 0) as ins,
           coalesce(r.sheath_kgkm, 0) as sheath, nullif(r.total_kgkm, 0) as total,
           coalesce((select sum(op.qty_m) from mfg.wo_outputs op join mfg.wo_operations o on o.id = op.wo_op_id
                     where o.wo_id = w.id and o.op_code = 'CD6'), 0) as good
    from ws join mfg.work_orders w on w.id = ws.wid
    join master.product_specs s on s.id = w.spec_id
    left join master.spec_results r on r.spec_id = w.spec_id
  ), mat as (   -- vật tư nằm trong cáp (bỏ bao bì, mực, dung môi), tính theo kg
    select b.id, sum(-sm.qty) filter (where m.group_code = 'CONDUCTOR') as cu,
           sum(-sm.qty) as kg
    from base b join inv.stock_docs d on d.ref_type = 'WO' and d.ref_id = b.id and d.doc_type in ('ISSUE_WO', 'RETURN_WO') and d.status = 'POSTED'
    join inv.stock_moves sm on sm.doc_id = d.id join inv.lots l on l.id = sm.lot_id and l.item_kind = 'MAT'
    join master.materials m on m.id = l.material_id and m.uom = 'kg' and m.group_code in ('CONDUCTOR','COMPOUND','ADDITIVE','COLOR','TAPE_FILLER')
    group by b.id
  ), nrm as (
    select b.id, sum(n.qty) as kg
    from base b cross join lateral inv.norm_for_wo(b.id, b.good, true) n
    join master.materials m on m.id = n.material_id and m.uom = 'kg' and m.group_code in ('CONDUCTOR','COMPOUND','ADDITIVE','COLOR','TAPE_FILLER')
    where b.good > 0 group by b.id
  ), fg as (
    select b.id, sum(op.weight_kg) as kg, sum(op.qty_m) filter (where op.weight_kg is not null) / 1000 as km_w
    from base b join mfg.wo_operations o on o.wo_id = b.id and o.op_code = 'CD6' join mfg.wo_outputs op on op.wo_op_id = o.id
    group by b.id
  ), scr as (
    select o.wo_id as id,
           sum(s.qty_kg) filter (where inv.scrap_category(s.reason_code) = 'STARTUP') as st,
           sum(s.qty_kg) filter (where inv.scrap_category(s.reason_code) = 'QUALITY') as ql,
           sum(s.qty_kg) filter (where inv.scrap_category(s.reason_code) = 'LENGTH') as tl,
           sum(s.qty_kg) filter (where inv.scrap_category(s.reason_code) = 'OTHER') as ot,
           sum(s.qty_kg) filter (where m.code in ('PL-CU', 'PL-TC')) as cu,
           sum(s.qty_kg) filter (where m.code = 'PL-CABLE') as cable
    from mfg.scrap_records s join mfg.wo_operations o on o.id = s.wo_op_id join master.materials m on m.id = s.scrap_material_id
    where o.wo_id in (select base.id from base) group by o.wo_id
  ), ovl as (
    select b.id, sum(greatest(coalesce(h.init_qty, h.qty) - b.m_per_pack, 0)) as m
    from base b join mfg.wo_operations o on o.wo_id = b.id and o.op_code = 'CD6' join inv.lots l on l.wo_op_id = o.id
    join inv.handling_units h on h.lot_id = l.id and h.parent_hu_id is null
    group by b.id
  ), wip as (   -- BTP còn dở của lệnh (ước tính theo kg/km của spec)
    select b.id,
           sum(bal.qty / 1000 * case l.wip_stage when 'CB' then b.metal / greatest(b.cores, 1)
                                                 when 'LB' then (b.metal + b.ins) / greatest(b.cores, 1)
                                                 when 'MX' then 0
                                                 when 'CV' then coalesce(b.total, 0)
                                                 else coalesce(b.total, 0) - b.sheath end) as kg,
           sum(bal.qty / 1000 * case l.wip_stage when 'CB' then b.metal / greatest(b.cores, 1)
                                                 when 'LB' then b.metal / greatest(b.cores, 1)
                                                 when 'MX' then 0
                                                 when 'BL' then b.metal else b.metal + b.drain end) as cu
    from base b join mfg.wo_operations o on o.wo_id = b.id join inv.lots l on l.wo_op_id = o.id and l.item_kind = 'WIP'
    join inv.stock_balances bal on bal.lot_id = l.id and bal.qty > 0
    group by b.id
  ), calc as (
    select b.*, coalesce(mat.kg, 0) as i_kg, nrm.kg as n_kg, coalesce(mat.cu, 0) as i_cu,
           fg.kg as fg_w, coalesce(fg.km_w, 0) as km_w,
           coalesce(scr.st, 0) as st, coalesce(scr.ql, 0) as ql, coalesce(scr.tl, 0) as tl, coalesce(scr.ot, 0) as ot,
           coalesce(scr.cu, 0) as scu, coalesce(scr.cable, 0) as scable, coalesce(ovl.m, 0) as ov_m,
           coalesce(wip.kg, 0) as w_kg, coalesce(wip.cu, 0) as w_cu
    from base b left join mat on mat.id = b.id left join nrm on nrm.id = b.id left join fg on fg.id = b.id
    left join scr on scr.id = b.id left join ovl on ovl.id = b.id left join wip on wip.id = b.id
  )
  select c.id, c.wo_no, c.status, p.code, p.description, c.good, c.qty_m,
         round(c.i_kg, 2), round(c.n_kg, 2), round(c.i_kg - c.n_kg, 2), round((c.i_kg - c.n_kg) / nullif(c.n_kg, 0) * 100, 2),
         round(coalesce(c.fg_w, 0) + (c.good / 1000 - c.km_w) * coalesce(c.total, 0), 2),
         round(c.good / 1000 * coalesce(c.total, 0), 2),
         round(c.km_w, 3), c.total, round(c.fg_w / nullif(c.km_w, 0), 3),
         round(coalesce(c.fg_w, 0) - c.km_w * coalesce(c.total, 0), 2),
         round((c.fg_w / nullif(c.km_w, 0) / c.total - 1) * 100, 2),
         round(c.st, 2), round(c.ql, 2), round(c.tl, 2), round(c.ot, 2), round(c.ov_m, 1), round(c.ov_m / 1000 * coalesce(c.total, 0), 2),
         round(c.w_kg, 2),
         round(c.i_kg - (coalesce(c.fg_w, 0) + (c.good / 1000 - c.km_w) * coalesce(c.total, 0)) - (c.st + c.ql + c.tl + c.ot) - c.w_kg, 2),
         round(c.i_cu, 3), round(c.good / 1000 * (c.metal + c.drain), 3), round(c.scu, 3),
         round(c.scable * (c.metal + c.drain) / nullif(c.total, 0), 3), round(c.w_cu, 3),
         round(c.i_cu - c.good / 1000 * (c.metal + c.drain) - c.scu - coalesce(c.scable * (c.metal + c.drain) / nullif(c.total, 0), 0) - c.w_cu, 3),
         round((c.i_cu - c.good / 1000 * (c.metal + c.drain) - c.scu - coalesce(c.scable * (c.metal + c.drain) / nullif(c.total, 0), 0) - c.w_cu)
               / nullif(c.i_cu, 0) * 100, 2),
         case when c.i_cu = 0 then null
              else abs((c.i_cu - c.good / 1000 * (c.metal + c.drain) - c.scu - coalesce(c.scable * (c.metal + c.drain) / nullif(c.total, 0), 0) - c.w_cu)
                       / c.i_cu * 100) <= v_tol end,
         c.dt
  from calc c join master.products p on p.id = c.product_id
  order by c.dt desc, c.wo_no;
end $$;

-- Tiêu hao từng vật tư của một lệnh: định mức (theo mét đạt) so với cấp − trả
create or replace function app.loss_wo_materials(p_wo uuid)
returns table (material_code text, material_name text, uom text, group_code text, norm numeric, issued numeric, returned numeric, net numeric,
               var numeric, var_pct numeric, over_tol boolean)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_good numeric; v_tol numeric := coalesce(inv.setting('material_tol_pct'), 3);
begin
  if not app.can_see_loss() then raise exception 'Không có quyền xem báo cáo hao hụt'; end if;
  select coalesce(sum(op.qty_m), 0) into v_good from mfg.wo_outputs op join mfg.wo_operations o on o.id = op.wo_op_id
   where o.wo_id = p_wo and o.op_code = 'CD6';
  return query
  with n as (select x.material_id, x.qty from inv.norm_for_wo(p_wo, v_good, true) x where v_good > 0),
  a as (
    select l.material_id, sum(-sm.qty) filter (where d.doc_type = 'ISSUE_WO') as iss, sum(sm.qty) filter (where d.doc_type = 'RETURN_WO') as ret
    from inv.stock_docs d join inv.stock_moves sm on sm.doc_id = d.id join inv.lots l on l.id = sm.lot_id and l.item_kind = 'MAT'
    where d.ref_type = 'WO' and d.ref_id = p_wo and d.status = 'POSTED' and d.doc_type in ('ISSUE_WO', 'RETURN_WO')
    group by l.material_id
  )
  select m.code, m.name, m.uom, m.group_code, round(coalesce(n.qty, 0), 3), round(coalesce(a.iss, 0), 3), round(coalesce(a.ret, 0), 3),
         round(coalesce(a.iss, 0) - coalesce(a.ret, 0), 3), round(coalesce(a.iss, 0) - coalesce(a.ret, 0) - coalesce(n.qty, 0), 3),
         round((coalesce(a.iss, 0) - coalesce(a.ret, 0) - n.qty) / nullif(n.qty, 0) * 100, 2),
         coalesce((coalesce(a.iss, 0) - coalesce(a.ret, 0) - n.qty) / nullif(n.qty, 0) * 100 > v_tol, false)
  from (select n.material_id from n union select a.material_id from a) ids
  join master.materials m on m.id = ids.material_id
  left join n on n.material_id = ids.material_id left join a on a.material_id = ids.material_id
  order by m.group_code, m.code;
end $$;

-- Pareto phế: theo nguyên nhân, công đoạn, máy
create or replace function app.loss_scrap(p_from date, p_to date)
returns table (reason_code text, reason_name text, category text, op_code text, machine_code text, scrap_code text, kg numeric, times bigint)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if not app.can_see_loss() then raise exception 'Không có quyền xem báo cáo hao hụt'; end if;
  return query
  select s.reason_code, rc.name, inv.scrap_category(s.reason_code), o.op_code, mc.code, m.code, round(sum(s.qty_kg), 2), count(*)
  from mfg.scrap_records s
  join mfg.wo_operations o on o.id = s.wo_op_id
  join master.materials m on m.id = s.scrap_material_id
  left join master.reason_codes rc on rc.code = s.reason_code
  left join master.machines mc on mc.id = coalesce(s.machine_id, o.machine_id)
  where (s.recorded_at at time zone 'Asia/Ho_Chi_Minh')::date between p_from and p_to
  group by s.reason_code, rc.name, o.op_code, mc.code, m.code;
end $$;

-- Danh sách lệnh SX cho ô chọn ở trang phế (gồm cả lệnh vừa đóng trong 7 ngày)
create or replace view app.v_wo_for_scrap with (security_invoker = true) as
select wo.id, wo.wo_no, wo.status, p.code as product_code,
       (select array_agg(o.op_code order by o.seq) from mfg.wo_operations o where o.wo_id = wo.id) as ops
from mfg.work_orders wo join master.products p on p.id = wo.product_id
where wo.status in ('RELEASED', 'IN_PROGRESS', 'PAUSED', 'PRODUCED', 'QC_PENDING')
   or (wo.status = 'CLOSED' and wo.closed_at > now() - interval '7 days');

-- ===========================================================================
-- 8. Hộp duyệt: đường dẫn tới chứng từ kho
-- ===========================================================================
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
                   'approvers', case when b.status = 'PENDING' and (s ->> 'seq')::int >= b.current_seq then app.people(wf.step_actor_ids(s)) end)
          from jsonb_array_elements(b.flow_snapshot -> 'steps') s left join core.roles ro on ro.code = s ->> 'role') q) as steps,
       (select jsonb_agg(jsonb_build_object('seq', a.seq, 'action', a.action, 'comment', a.comment, 'at', a.acted_at,
                                            'actor', app.user_name(a.actor_id),
                                            'label', (select s ->> 'label' from jsonb_array_elements(b.flow_snapshot -> 'steps') s where (s ->> 'seq')::int = a.seq))
                         order by a.acted_at)
          from wf.approval_actions a where a.request_id = b.id) as history
from base b;

grant select on all tables in schema app to authenticated, service_role;
revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;

-- Hàm của schema kho/sản xuất mới tạo: chỉ người đăng nhập; các hàm lõi chỉ gọi nội bộ
do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p
           where p.pronamespace::regnamespace::text in ('inv', 'qa', 'mfg', 'sales', 'purchase') and p.prokind = 'f' loop
    execute format('revoke execute on function %s from public, anon', f);
  end loop;
end $$;
grant execute on function inv.setting(text), inv.loc(text), inv.wh(text), inv.keeper_mode(uuid), inv.hu_available(uuid),
  inv.create_requisition(uuid, numeric, date, text), inv.create_extra_requisition(uuid, jsonb, text, text), inv.cancel_requisition(uuid, text),
  inv.issue_pick(uuid, jsonb, uuid, uuid, text), inv.confirm_issue(uuid), inv.return_hu(uuid, numeric, uuid, uuid),
  inv.receive_goods(uuid, uuid, text, text, jsonb), inv.set_receipt_price(uuid, jsonb), purchase.check_receipt(uuid, text),
  qa.release_lot(uuid, text, text, jsonb), inv.move_hu(uuid, uuid, uuid), inv.split_hu(uuid, numeric[], numeric, text),
  inv.reclass_hu(uuid, boolean, uuid, text, text), inv.customer_return(uuid, text, numeric, uuid, uuid, text),
  inv.create_opening(uuid, date, jsonb), inv.record_scrap(uuid, text, text, numeric, text, uuid, text), inv.create_scrap_sale(jsonb, text, text),
  sales.reserve_so(uuid), sales.create_delivery(uuid, uuid[], date, text), inv.ship_delivery(uuid, uuid[]),
  inv.count_open(uuid, text, uuid[], text), inv.count_scan(uuid, uuid, bigint, numeric, uuid, text), inv.count_close(uuid, boolean),
  inv.count_cancel(uuid, text), inv.review_doc(uuid, boolean, text), inv.reverse_doc(uuid, text), inv.mark_printed(uuid[], text),
  inv.post_doc(uuid), mfg.record_output(uuid, text, numeric, numeric, jsonb, text, numeric, text, text)
  to authenticated;
revoke execute on function inv._post(uuid), inv.receipt_finish(uuid), inv.daily_alerts(), inv.bal_add(uuid, uuid, uuid, uuid, numeric),
  inv.val_add(uuid, uuid, numeric, numeric, boolean), inv.new_hu(uuid, text, numeric, uuid, uuid, numeric, numeric, uuid, uuid),
  inv.scrap_lot(uuid, date) from authenticated;
