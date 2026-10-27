-- Quản lý máy đợt A (phương án gộp Quản lý máy với quy trình final, anh Bình duyệt 28/10/2026):
--  M1. Báo hỏng: TP KT/QA bấm Hỏng, TP KT/QA vắng thì TP SX bấm; bắt buộc giờ dự kiến chạy lại. Công nhân, tổ trưởng không đổi
--      trạng thái máy trên MES nữa (quy trình final: công nhân làm trên giấy). Máy hỏng / chạy lại: báo TP SX "Xếp lại lịch".
--  M3. Báo cáo ca đã chốt: dừng máy (giờ từ–đến, lý do) ghi vào nhật ký trạng thái máy + downtime_events (lịch sử máy,
--      chỉ số hỏng, báo cáo bảo trì tháng). Lý do "Hỏng máy" mà chưa có phiếu sửa chữa thì mở phiếu để TP KT/QA ghi nguyên nhân.
--  M4. Lịch máy tránh máy hỏng (web lib/kh/scheduler.ts đọc trạng thái + giờ dự kiến chạy lại qua app.v_kh_machines);
--      lệnh ngày cảnh báo máy hỏng còn việc trong ngày.
--  M5. Giữ chỗ bảo dưỡng trên lịch máy: TP KT/QA đề xuất ngày + cách làm (trong ca / gộp lần đổi máy lớn / ngoài giờ ca),
--      TP SX chốt; ngày rơi vào vùng khóa lịch thì Giám đốc chốt. Phiếu đã chốt "trong ca" thành khối giữ chỗ trên lịch máy.
--  Điểm 4: TP SX xác nhận phiếu bảo dưỡng / sửa chữa (máy chạy lại đạt) thay TP KT/QA; người làm phiếu không tự xác nhận.

-- ===========================================================================
-- 1. Cột mới
-- ===========================================================================
alter table mfg.maint_work_orders
  add column if not exists sched_mode   text check (sched_mode in ('IN_SHIFT','CHANGEOVER','OFF_SHIFT')),
  add column if not exists sched_status text check (sched_status in ('PROPOSED','CONFIRMED')),
  add column if not exists sched_note   text,
  add column if not exists sched_by     uuid references core.profiles(id),
  add column if not exists sched_at     timestamptz,
  add column if not exists sched_ok_by  uuid references core.profiles(id),
  add column if not exists sched_ok_at  timestamptz;

alter table mfg.machine_status_log add column if not exists shift_report_id uuid references mfg.shift_reports(id) on delete cascade;
alter table mfg.downtime_events add column if not exists shift_report_id uuid references mfg.shift_reports(id) on delete cascade;

-- ===========================================================================
-- 2. M1: đổi trạng thái máy
-- ===========================================================================
-- Đổi tay: TP KT/QA, TP SX (Quản trị qua has_role). Hàm hệ thống (bắt đầu / xong phiếu bảo dưỡng) đặt cờ bmt.machine_sys.
create or replace function app.set_machine_status(p_machine uuid, p_status text, p_reason text default null,
  p_note text default null, p_eta timestamptz default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare m master.machines; v_now timestamptz := now(); v_wo uuid; v_no text; v_line master.machines;
        v_sys boolean := coalesce(current_setting('bmt.machine_sys', true) = 'on', false); v_msg text;
begin
  if not v_sys and not (core.has_role('KT_TP') or core.has_role('SX_TP')) then
    raise exception 'Chỉ TP Kỹ thuật/QA (vắng thì TP SX) đổi trạng thái máy, báo hỏng. Công nhân báo TP SX.';
  end if;
  select * into m from master.machines where id = p_machine for update;
  if not found then raise exception 'Không tìm thấy máy'; end if;
  if p_status not in ('RUN','IDLE','STOP','MAINT','DOWN','OFF') then raise exception 'Trạng thái không hợp lệ'; end if;
  if p_status in ('STOP','DOWN') and p_reason is null then raise exception 'Chọn lý do dừng máy (BR-SX-04)'; end if;
  if p_status = 'DOWN' and not v_sys and p_eta is null and m.inline_with is null then
    raise exception 'Báo hỏng: nhập giờ dự kiến chạy lại để lịch máy tính lại (ước lượng, sửa lại được)';
  end if;
  if p_eta is not null and p_eta <= v_now and p_status in ('DOWN','MAINT') then raise exception 'Giờ dự kiến chạy lại phải sau bây giờ'; end if;
  if p_status = m.status and p_status not in ('STOP','DOWN','MAINT') then return; end if;

  update mfg.machine_status_log set ended_at = v_now where machine_id = p_machine and ended_at is null;
  update mfg.downtime_events set ended_at = v_now
   where machine_id = p_machine and ended_at is null and source = 'MANUAL';
  insert into mfg.machine_status_log (machine_id, status, started_at, reason_code, note, source)
  values (p_machine, p_status, v_now, p_reason, nullif(trim(coalesce(p_note, '')), ''), case when v_sys then 'HE_THONG' else 'TAY' end);
  if p_status in ('STOP','DOWN','MAINT') then
    insert into mfg.downtime_events (machine_id, started_at, reason_code, source, note)
    values (p_machine, v_now, coalesce(p_reason, case when p_status = 'MAINT' then 'DT_PM' end), 'MANUAL', p_note);
  end if;
  update master.machines set status = p_status, status_since = v_now, status_note = nullif(trim(coalesce(p_note, '')), ''),
         status_eta = case when p_status in ('DOWN','MAINT') then p_eta end
   where id = p_machine;

  if p_status = 'DOWN' then
    select id into v_wo from mfg.maint_work_orders where machine_id = p_machine and wo_type = 'CM' and status in ('OPEN','IN_PROGRESS') limit 1;
    if v_wo is null then
      v_no := core.next_no('SC');
      insert into mfg.maint_work_orders (wo_no, wo_type, machine_id, title, eta, cause, assignee_role)
      values (v_no, 'CM', p_machine, 'Sửa chữa ' || m.code || coalesce(': ' || nullif(trim(coalesce(p_note, '')), ''), ''), p_eta, p_note, 'KT_TP')
      returning id into v_wo;
      perform mfg.notify_roles(mfg.roles_setting('overdue_roles', array['KT_TP','SX_TP','BGD']),
        'Máy hỏng: ' || m.code, coalesce(p_note, m.name) || '. Phiếu sửa chữa ' || v_no || coalesce(', dự kiến chạy lại ' || to_char(p_eta at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM'), ''),
        '/may/bao-duong/phieu/' || v_wo);
    elsif p_eta is not null then
      update mfg.maint_work_orders set eta = p_eta where id = v_wo;
    end if;
    -- Máy con quan trọng hỏng: cả dây chuyền chuyển sang Hỏng
    if m.critical and m.inline_with is not null then
      select * into v_line from master.machines where id = m.inline_with;
      if v_line.status <> 'DOWN' then
        perform set_config('bmt.machine_sys', 'on', true);
        perform app.set_machine_status(m.inline_with, 'DOWN', p_reason, 'Máy con ' || m.code || ' hỏng' || coalesce(': ' || p_note, ''), p_eta);
        perform set_config('bmt.machine_sys', case when v_sys then 'on' else 'off' end, true);
      end if;
    end if;
  end if;

  -- Dây chuyền xếp lịch đổi trạng thái liên quan lịch: báo TP SX, Kế hoạch SX bấm Xếp lại lịch
  if m.inline_with is null and m.machine_type in ('BUNCHER','EXTRUDER_SI','TWISTER','EXTRUDER_TP')
     and (p_status in ('DOWN','OFF','MAINT') or m.status in ('DOWN','OFF','MAINT')) and p_status is distinct from m.status
     and not (p_status = 'MAINT' and v_sys) and not (m.status = 'MAINT' and v_sys and p_status in ('IDLE','RUN')) then
    v_msg := case
      when p_status = 'DOWN' then m.code || ' hỏng' || coalesce(', dự kiến chạy lại ' || to_char(p_eta at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM'), '')
           || '. Bấm Xếp lại lịch: MES chuyển việc sang máy cùng loại và chỉ ra lô bị lùi.'
      when p_status = 'OFF' then m.code || ' ngừng dùng. Bấm Xếp lại lịch để chuyển việc sang máy khác.'
      when p_status = 'MAINT' then m.code || ' đang bảo dưỡng' || coalesce(', dự kiến chạy lại ' || to_char(p_eta at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM'), '') || '. Bấm Xếp lại lịch.'
      else m.code || ' đã chạy lại. Bấm Xếp lại lịch để dùng lại máy.' end;
    perform app.kh_notify_role('SX_TP', case when p_status in ('DOWN','OFF','MAINT') then 'Máy không chạy được: ' else 'Máy chạy lại: ' end || m.code, v_msg, '/lich-may?tab=baoduong');
    perform app.kh_notify_role('SX_KH', case when p_status in ('DOWN','OFF','MAINT') then 'Máy không chạy được: ' else 'Máy chạy lại: ' end || m.code, v_msg, '/lich-may?tab=baoduong');
  end if;
end $$;

-- Bắt đầu làm phiếu: bảo dưỡng trong ca thì máy chuyển "Bảo dưỡng" (hàm hệ thống: người làm phiếu không cần quyền đổi trạng thái)
create or replace function app.start_maint_wo(p_id uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare w mfg.maint_work_orders;
begin
  if not core.has_perm('machine', 'edit') then raise exception 'Bạn chưa có quyền làm phiếu'; end if;
  select * into w from mfg.maint_work_orders where id = p_id for update;
  if w.status <> 'OPEN' then raise exception 'Phiếu không ở trạng thái Mới'; end if;
  update mfg.maint_work_orders set status = 'IN_PROGRESS', started_at = now() where id = p_id;
  if w.wo_type = 'PM' and not w.off_shift then
    perform set_config('bmt.machine_sys', 'on', true);
    perform app.set_machine_status(w.machine_id, 'MAINT', 'DT_PM', w.wo_no || ' ' || w.title,
      case when coalesce(w.est_minutes, 0) > 0 then now() + make_interval(mins => w.est_minutes) end);
    perform set_config('bmt.machine_sys', 'off', true);
    update mfg.machine_status_log set maint_wo_id = p_id where machine_id = w.machine_id and ended_at is null;
  end if;
end $$;

-- Hoàn thành phiếu: ghi kết quả; phiếu bảo dưỡng đặt lại mốc chu kỳ; máy đang Bảo dưỡng / Hỏng trở về Chờ việc
create or replace function app.finish_maint_wo(p_id uuid, p_result text, p_action text, p_steps jsonb, p_cause text default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare w mfg.maint_work_orders; m master.machines; v_now timestamptz := now();
begin
  if not core.has_perm('machine', 'edit') then raise exception 'Bạn chưa có quyền làm phiếu'; end if;
  select * into w from mfg.maint_work_orders where id = p_id for update;
  if w.status not in ('OPEN','IN_PROGRESS') then raise exception 'Phiếu đã đóng'; end if;
  if p_result not in ('OK','NOT_OK') then raise exception 'Chọn kết quả Đạt / Chưa đạt'; end if;
  if coalesce(trim(p_action), '') = '' then raise exception 'Ghi việc đã làm'; end if;
  update mfg.maint_work_orders set status = 'DONE', result = p_result, action_taken = trim(p_action),
         steps = coalesce(p_steps, steps), cause = coalesce(nullif(trim(coalesce(p_cause, '')), ''), cause),
         started_at = coalesce(started_at, v_now), finished_at = v_now, done_by = auth.uid()
   where id = p_id;
  if w.wo_type = 'PM' and w.plan_id is not null and p_result = 'OK' then
    update mfg.maint_plans set last_done_at = v_now, base_hours = 0, base_km = 0 where id = w.plan_id;
  end if;
  select * into m from master.machines where id = w.machine_id;
  if p_result = 'OK' and m.status in ('MAINT','DOWN') then
    perform set_config('bmt.machine_sys', 'on', true);
    perform app.set_machine_status(w.machine_id, 'IDLE', null, 'Xong phiếu ' || w.wo_no, null);
    if m.critical and m.inline_with is not null
       and (select status from master.machines where id = m.inline_with) = 'DOWN'
       and not exists (select 1 from master.machines c where c.inline_with = m.inline_with and c.critical and c.status = 'DOWN') then
      perform app.set_machine_status(m.inline_with, 'IDLE', null, 'Máy con ' || m.code || ' đã sửa xong', null);
    end if;
    perform set_config('bmt.machine_sys', 'off', true);
  end if;
end $$;

-- Điểm 4: TP SX xác nhận máy chạy lại đạt (TP KT/QA thường là người sửa); người làm phiếu không tự xác nhận
create or replace function app.confirm_maint_wo(p_id uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare w mfg.maint_work_orders;
begin
  if not core.has_role('SX_TP') then raise exception 'Chỉ TP SX xác nhận máy chạy lại đạt'; end if;
  select * into w from mfg.maint_work_orders where id = p_id for update;
  if not found or w.status <> 'DONE' or w.confirmed_at is not null then raise exception 'Phiếu chưa hoàn thành hoặc đã xác nhận'; end if;
  if w.done_by = auth.uid() then raise exception 'Người làm phiếu không tự xác nhận: chờ TP SX khác xác nhận'; end if;
  update mfg.maint_work_orders set confirmed_by = auth.uid(), confirmed_at = now() where id = p_id;
end $$;

create or replace function mfg.notify_maint_done() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform app.kh_notify_role('SX_TP', 'Xác nhận máy chạy lại: ' || new.wo_no,
    new.title || ' · ' || case new.result when 'OK' then 'Đạt' else 'Chưa đạt' end, '/may/bao-duong/phieu/' || new.id);
  return new;
end $$;

-- ===========================================================================
-- 3. M5: giữ chỗ bảo dưỡng trên lịch máy
-- ===========================================================================
-- Ngày có nằm trong vùng khóa lịch (hôm nay + frozen_days ngày làm việc) không
create or replace function mfg.in_frozen(p_date date) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select p_date < (now() at time zone 'Asia/Ho_Chi_Minh')::date
      or mfg.workdays((now() at time zone 'Asia/Ho_Chi_Minh')::date, p_date) <= (select frozen_days from master.planning_config where id = 1)
$$;

-- TP KT/QA đề xuất ngày bảo dưỡng (tạo phiếu từ kế hoạch nếu chưa có). Cách làm: IN_SHIFT trong ca (giữ chỗ trên lịch máy),
-- CHANGEOVER gộp vào lần đổi máy lớn (không mất thêm giờ máy), OFF_SHIFT ngoài giờ ca / Chủ nhật (không trừ năng lực)
create or replace function app.maint_propose(p_plan uuid, p_wo uuid, p_date date, p_mode text, p_note text default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_wo uuid := p_wo; w mfg.maint_work_orders; m master.machines; v_frozen boolean;
begin
  if not core.has_role('KT_TP') then raise exception 'Chỉ TP Kỹ thuật/QA đề xuất ngày bảo dưỡng'; end if;
  if p_date is null or p_date < (now() at time zone 'Asia/Ho_Chi_Minh')::date then raise exception 'Chọn ngày bảo dưỡng từ hôm nay trở đi'; end if;
  if p_mode not in ('IN_SHIFT','CHANGEOVER','OFF_SHIFT') then raise exception 'Chọn cách làm: trong ca, gộp lần đổi máy, ngoài giờ ca'; end if;
  if v_wo is null then
    if p_plan is null then raise exception 'Chọn kế hoạch bảo dưỡng'; end if;
    v_wo := app.create_maint_wo(p_plan, p_date);
  end if;
  select * into w from mfg.maint_work_orders where id = v_wo for update;
  if not found or w.wo_type <> 'PM' then raise exception 'Chỉ phiếu bảo dưỡng định kỳ được giữ chỗ trên lịch máy'; end if;
  if w.status <> 'OPEN' then raise exception 'Phiếu % đã bắt đầu hoặc đã đóng', w.wo_no; end if;
  update mfg.maint_work_orders set planned_date = p_date, sched_mode = p_mode, off_shift = (p_mode = 'OFF_SHIFT'),
         sched_status = 'PROPOSED', sched_note = nullif(trim(coalesce(p_note, '')), ''), sched_by = auth.uid(), sched_at = now(),
         sched_ok_by = null, sched_ok_at = null
   where id = v_wo;
  select * into m from master.machines where id = mfg.line_of(w.machine_id);
  v_frozen := mfg.in_frozen(p_date);
  perform app.kh_notify_role(case when v_frozen then 'BGD' else 'SX_TP' end,
    'Chốt ngày bảo dưỡng ' || m.code || ': ' || to_char(p_date, 'DD/MM'),
    w.wo_no || ' ' || w.title || ' · ' || case p_mode when 'IN_SHIFT' then 'trong ca, ' || coalesce(w.est_minutes, 0) || ' phút' when 'CHANGEOVER' then 'gộp vào lần đổi máy lớn' else 'ngoài giờ ca' end
      || case when v_frozen then ' · trong vùng khóa lịch: Giám đốc chốt' else '' end,
    '/lich-may?tab=baoduong');
  return v_wo;
end $$;

-- TP SX chốt (trong vùng khóa lịch: Giám đốc) hoặc trả lại TP KT/QA chọn ngày khác. Người đề xuất không tự chốt.
create or replace function app.maint_confirm(p_wo uuid, p_ok boolean, p_note text default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare w mfg.maint_work_orders; m master.machines; v_frozen boolean;
begin
  select * into w from mfg.maint_work_orders where id = p_wo for update;
  if not found or w.sched_status is null then raise exception 'Phiếu chưa có đề xuất ngày bảo dưỡng'; end if;
  if w.status not in ('OPEN') then raise exception 'Phiếu % đã bắt đầu hoặc đã đóng', w.wo_no; end if;
  v_frozen := mfg.in_frozen(w.planned_date);
  if v_frozen and not core.has_role('BGD') then raise exception 'Ngày % trong vùng khóa lịch: Giám đốc chốt', to_char(w.planned_date, 'DD/MM'); end if;
  if not v_frozen and not (core.has_role('SX_TP') or core.has_role('SX_KH') or core.has_role('BGD')) then
    raise exception 'Chỉ TP SX chốt ngày bảo dưỡng';
  end if;
  if w.sched_by = auth.uid() then raise exception 'Người đề xuất không tự chốt ngày bảo dưỡng'; end if;
  select * into m from master.machines where id = mfg.line_of(w.machine_id);
  if p_ok then
    update mfg.maint_work_orders set sched_status = 'CONFIRMED', sched_ok_by = auth.uid(), sched_ok_at = now() where id = p_wo;
    insert into wf.notifications (user_id, title, body, link)
    select w.sched_by, 'Đã chốt ngày bảo dưỡng ' || m.code || ': ' || to_char(w.planned_date, 'DD/MM'), w.wo_no || ' ' || w.title, '/may/bao-duong/phieu/' || w.id
    where w.sched_by is not null and w.sched_by <> auth.uid();
    if w.sched_mode = 'IN_SHIFT' then
      perform app.kh_notify_role('SX_TP', 'Bảo dưỡng giữ chỗ trên lịch máy: ' || m.code,
        to_char(w.planned_date, 'DD/MM') || ' · ' || coalesce(w.est_minutes, 0) || ' phút. Bấm Xếp lại lịch để lịch tránh khối bảo dưỡng.', '/lich-may?tab=baoduong');
    end if;
  else
    if coalesce(trim(p_note), '') = '' then raise exception 'Ghi lý do trả lại (ví dụ: ngày đó chạy lô gấp)'; end if;
    update mfg.maint_work_orders set sched_status = null, sched_note = concat_ws(' · ', sched_note, 'Trả lại: ' || trim(p_note)),
           sched_ok_by = null, sched_ok_at = null where id = p_wo;
    insert into wf.notifications (user_id, title, body, link)
    select w.sched_by, 'Chọn lại ngày bảo dưỡng ' || m.code, w.wo_no || ': ' || trim(p_note), '/lich-may?tab=baoduong'
    where w.sched_by is not null and w.sched_by <> auth.uid();
  end if;
end $$;

revoke execute on function mfg.in_frozen(date) from public, anon;
revoke execute on function app.maint_propose(uuid, uuid, date, text, text), app.maint_confirm(uuid, boolean, text) from public, anon;
grant execute on function app.maint_propose(uuid, uuid, date, text, text), app.maint_confirm(uuid, boolean, text) to authenticated;

-- Phiếu bảo dưỡng (đang mở) theo dây chuyền xếp lịch, kèm đề xuất / chốt ngày
create or replace view app.v_kh_maint with (security_invoker = true) as
select w.id, w.wo_no, w.title, w.status, w.plan_id, w.planned_date, w.est_minutes, w.off_shift,
       w.sched_mode, w.sched_status, w.sched_note, w.sched_at, w.sched_ok_at,
       app.user_name(w.sched_by) as sched_by_name, app.user_name(w.sched_ok_by) as sched_ok_by_name, w.sched_by,
       m.code as unit_code, l.code as machine_code, p.name as plan_name, p.level, p.kind, p.stop_minutes,
       mfg.in_frozen(w.planned_date) as in_frozen
from mfg.maint_work_orders w
join master.machines m on m.id = w.machine_id
join master.machines l on l.id = coalesce(m.inline_with, m.id)
left join mfg.maint_plans p on p.id = w.plan_id
where w.wo_type = 'PM' and w.status in ('OPEN','IN_PROGRESS');
grant select on app.v_kh_maint to authenticated;

-- Dây chuyền xếp lịch: thêm trạng thái, giờ dự kiến chạy lại (bộ xếp lịch tránh máy hỏng, ngừng dùng)
create or replace view app.v_kh_machines with (security_invoker = true) as
select m.id, m.code, m.name, m.machine_type, m.protocol, m.data_mode, m.active,
       (select count(*) from iot.machine_tags t where t.machine_id = m.id) as tag_count,
       (select max(s.ts) from iot.machine_state s where s.machine_id = m.id) as last_seen,
       coalesce((select array_agg(k.operator_code order by k.operator_code) from master.operator_skills k
                 where k.machine_code = m.code and k.level = 'MAIN'), '{}') as operators,
       m.status, m.status_since, m.status_eta, m.status_note
from master.machines m
where m.machine_type in ('BUNCHER','EXTRUDER_SI','TWISTER','EXTRUDER_TP') and m.active and m.inline_with is null;

-- ===========================================================================
-- 4. M3: báo cáo ca đã chốt ghi dừng máy vào nhật ký máy
-- ===========================================================================
create or replace function mfg.shift_downtime_to_log(p_report uuid) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r mfg.shift_reports; m master.machines; e jsonb; v_from timestamptz; v_to timestamptz; v_status text; v_n int := 0;
        v_reason text; v_wo uuid; v_no text; v_note text;
begin
  select * into r from mfg.shift_reports where id = p_report;
  select * into m from master.machines where code = r.machine_code;
  if not found then return 0; end if;
  delete from mfg.machine_status_log where shift_report_id = r.id;
  delete from mfg.downtime_events where shift_report_id = r.id;
  for e in select * from jsonb_array_elements(r.downtime) loop
    continue when coalesce(e ->> 'from', '') !~ '^\d{1,2}:\d{2}' or coalesce(e ->> 'to', '') !~ '^\d{1,2}:\d{2}';
    v_from := (r.work_date + (e ->> 'from')::time) at time zone 'Asia/Ho_Chi_Minh';
    v_to := (r.work_date + (e ->> 'to')::time) at time zone 'Asia/Ho_Chi_Minh';
    if v_to <= v_from then v_to := v_to + interval '1 day'; end if;
    v_reason := nullif(e ->> 'reason', '');
    if v_reason is not null and not exists (select 1 from master.reason_codes where code = v_reason) then v_reason := 'DT_OTHER'; end if;
    v_status := case v_reason when 'DT_BREAKDOWN' then 'DOWN' when 'DT_PM' then 'MAINT' else 'STOP' end;
    v_note := 'Báo cáo ca ' || r.shift_code || ' ' || to_char(r.work_date, 'DD/MM') || ' (' || (e ->> 'from') || '–' || (e ->> 'to') || ')';
    -- Đã báo hỏng / bảo dưỡng tay trên MES trùng giờ thì không ghi lại
    continue when v_status in ('DOWN','MAINT') and exists (
      select 1 from mfg.machine_status_log g where g.machine_id = m.id and g.status = v_status and g.shift_report_id is null
         and g.started_at < v_to and coalesce(g.ended_at, now()) > v_from);
    insert into mfg.machine_status_log (machine_id, status, started_at, ended_at, reason_code, note, source, created_by, shift_report_id)
    values (m.id, v_status, v_from, v_to, v_reason, v_note, 'HE_THONG', r.confirmed_by, r.id);
    insert into mfg.downtime_events (machine_id, started_at, ended_at, reason_code, source, note, shift_report_id)
    values (m.id, v_from, v_to, v_reason, 'MANUAL', v_note, r.id);
    v_n := v_n + 1;
    -- Hỏng máy trong ca mà chưa có phiếu sửa chữa: mở phiếu để TP KT/QA ghi nguyên nhân, cách sửa
    if v_status = 'DOWN' and not exists (
         select 1 from mfg.maint_work_orders w where w.machine_id = m.id and w.wo_type = 'CM'
            and (w.status in ('OPEN','IN_PROGRESS') or (w.created_at at time zone 'Asia/Ho_Chi_Minh')::date = r.work_date)) then
      v_no := core.next_no('SC');
      insert into mfg.maint_work_orders (wo_no, wo_type, machine_id, title, cause, assignee_role, started_at, note)
      values (v_no, 'CM', m.id, 'Sửa chữa ' || m.code || ': hỏng máy trong ' || lower(v_note), null, 'KT_TP', v_from,
              'Mở từ báo cáo ca đã chốt: máy đã chạy lại, TP KT/QA ghi nguyên nhân và việc đã làm')
      returning id into v_wo;
      perform mfg.notify_roles(array['KT_TP'], 'Hỏng máy trong ca: ' || m.code,
        v_note || ' · ' || round(extract(epoch from v_to - v_from) / 60) || ' phút. Phiếu ' || v_no || ': ghi nguyên nhân, việc đã làm.',
        '/may/bao-duong/phieu/' || v_wo);
    end if;
  end loop;
  return v_n;
end $$;
revoke execute on function mfg.shift_downtime_to_log(uuid) from public, anon, authenticated;

create or replace function app.kh_confirm_report(p_id uuid, p_note text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
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
  -- M3: dừng máy trong ca vào nhật ký máy (lịch sử, chỉ số hỏng, báo cáo bảo trì tháng)
  perform mfg.shift_downtime_to_log(p_id);
end $$;

-- ===========================================================================
-- 5. M4: lệnh ngày cảnh báo máy hỏng còn việc trong ngày, bảo dưỡng giữ chỗ
-- ===========================================================================
create or replace function app.kh_day_preview(p_plan uuid, p_date date) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare pp plan.production_plans; v_ver uuid; v_checks jsonb := '[]'; v_slip jsonb; v_jobs integer; v_mach integer;
        v_txt text; v_txt2 text;
        v_day0 timestamptz := p_date::timestamp at time zone 'Asia/Ho_Chi_Minh'; v_day1 timestamptz := (p_date + 1)::timestamp at time zone 'Asia/Ho_Chi_Minh';
begin
  if not app.kh_can_view() then raise exception 'Không có quyền xem lệnh ngày'; end if;
  select * into pp from plan.production_plans where id = p_plan;
  if not found then raise exception 'Không tìm thấy kế hoạch'; end if;
  select id into v_ver from plan.schedule_versions where plan_id = p_plan and is_current;

  v_checks := v_checks || jsonb_build_object('ok', pp.status = 'APPROVED',
    't', case when pp.status = 'APPROVED' then 'Kế hoạch tháng ' || pp.plan_no || ' đã duyệt' else 'Kế hoạch tháng ' || pp.plan_no || ' chưa duyệt' end,
    'd', case when pp.status = 'APPROVED' then '' else 'Chưa phát lệnh ngày được' end);

  select count(*), count(distinct machine_code) into v_jobs, v_mach from plan.day_work(v_ver, p_date);
  v_checks := v_checks || jsonb_build_object('ok', v_jobs > 0,
    't', case when v_ver is null then 'Chưa có lịch máy' when v_jobs > 0 then v_jobs || ' việc trên ' || v_mach || ' máy' else 'Không có việc nào trong ngày' end);

  -- Máy hỏng / bảo dưỡng / ngừng dùng mà lịch còn giao việc trong ngày
  select string_agg(distinct m.code || ' ' || case m.status when 'DOWN' then 'hỏng' when 'MAINT' then 'đang bảo dưỡng' else 'ngừng dùng' end
           || coalesce(', dự kiến chạy lại ' || to_char(m.status_eta at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM'), case when m.status = 'OFF' then '' else ', chưa có giờ chạy lại' end), '; ')
    into v_txt
    from master.machines m
   where m.status in ('DOWN','MAINT','OFF') and (m.status = 'OFF' or m.status_eta is null or m.status_eta > v_day0)
     and exists (select 1 from plan.day_work(v_ver, p_date) w where w.machine_code = m.code);
  if v_txt is not null then
    v_checks := v_checks || jsonb_build_object('ok', false, 't', 'Máy không chạy được còn việc trong ngày: ' || v_txt,
      'd', 'TP SX bấm Xếp lại lịch ở Lịch máy để chuyển việc sang máy cùng loại trước khi phát lệnh');
  end if;
  -- Bảo dưỡng trong ngày
  select string_agg(l.code || ' ' || w.wo_no || ' (' || case w.sched_mode when 'IN_SHIFT' then 'trong ca ' || coalesce(w.est_minutes, 0) || ' phút'
                     when 'CHANGEOVER' then 'gộp lần đổi máy' else 'ngoài giờ ca' end || ')', '; ' order by l.code)
           filter (where w.sched_status = 'CONFIRMED'),
         string_agg(l.code || ' ' || w.wo_no, '; ' order by l.code) filter (where w.sched_status = 'PROPOSED')
    into v_txt, v_txt2
    from mfg.maint_work_orders w join master.machines u on u.id = w.machine_id join master.machines l on l.id = coalesce(u.inline_with, u.id)
   where w.wo_type = 'PM' and w.status = 'OPEN' and w.planned_date = p_date;
  if v_txt is not null then
    v_checks := v_checks || jsonb_build_object('ok', true, 't', 'Bảo dưỡng đã chốt trong ngày: ' || v_txt, 'd', 'Đã giữ chỗ trên lịch máy khi xếp lại lịch');
  end if;
  if v_txt2 is not null then
    v_checks := v_checks || jsonb_build_object('ok', false, 't', 'Bảo dưỡng chưa chốt ngày: ' || v_txt2, 'd', 'TP SX (vùng khóa: Giám đốc) chốt hoặc trả lại ở Lịch máy → Bảo dưỡng & máy hỏng');
  end if;

  select string_agg(distinct p.code, ', ') filter (where s.status <> 'RELEASED'),
         string_agg(distinct p.code, ', ') filter (where not exists (select 1 from master.bom_headers h join master.bom_lines bl on bl.bom_id = h.id where h.spec_id = pl.spec_id))
    into v_txt, v_txt2
    from (select distinct w.plan_line_id from plan.day_work(v_ver, p_date) w) x
    join plan.plan_lines pl on pl.id = x.plan_line_id
    join master.products p on p.id = pl.product_id join master.product_specs s on s.id = pl.spec_id;
  v_checks := v_checks || jsonb_build_object('ok', v_txt is null,
    't', coalesce('Spec chưa phát hành: ' || v_txt, 'Spec đã phát hành cho mọi mã trong ngày'),
    'd', case when v_txt is not null then 'Mã chưa phát hành spec không được gắn lệnh SX, không lĩnh vật tư' else '' end);
  if v_txt2 is not null then
    v_checks := v_checks || jsonb_build_object('ok', false, 't', 'Chưa có BOM: ' || v_txt2, 'd', 'Không tính được vật tư cần lĩnh cho các mã này');
  end if;

  -- Phiếu lĩnh: gộp theo vật tư, kèm phần của từng dòng kế hoạch
  with m as (
    select dm.*, mt.code, mt.name, mt.uom, p.code as product_code
    from plan.day_materials(v_ver, p_date) dm
    join master.materials mt on mt.id = dm.material_id
    join plan.plan_lines pl on pl.id = dm.plan_line_id join master.products p on p.id = pl.product_id
  ), g as (
    select m.material_id, m.code, m.name, m.uom, sum(m.qty) as qty,
           string_agg(m.product_code || ' ' || core.vn_num(m.qty), ' · ' order by m.product_code) as note
    from m group by m.material_id, m.code, m.name, m.uom
  )
  select coalesce(jsonb_agg(jsonb_build_object('material_code', g.code, 'item', g.code || ' · ' || g.name, 'qty', round(g.qty, 3),
                                               'unit', g.uom, 'available', coalesce(a.available, 0),
                                               'note', 'Định mức BOM: ' || g.note) order by g.code), '[]')
    into v_slip
    from g left join inv.v_material_availability a on a.material_id = g.material_id;

  select string_agg((e ->> 'material_code') || ' thiếu ' || core.vn_num((e ->> 'qty')::numeric - (e ->> 'available')::numeric) || ' ' || (e ->> 'unit'), ', ')
    into v_txt
    from jsonb_array_elements(v_slip) e where (e ->> 'available')::numeric < (e ->> 'qty')::numeric;
  v_checks := v_checks || jsonb_build_object('ok', v_txt is null,
    't', case when jsonb_array_length(v_slip) = 0 then 'Không có vật tư cần lĩnh' when v_txt is null then 'Đủ tồn kho NVL (đã đạt QC) cho phiếu lĩnh'
              else 'Thiếu vật tư: ' || v_txt end,
    'd', case when v_txt is null then '' else 'Báo Mua hàng hoặc đổi lịch; kho chỉ cấp phần đang có' end);

  select string_agg(m.code, ', ' order by m.code) into v_txt
    from master.machines m
   where m.machine_type in ('BUNCHER', 'EXTRUDER_SI', 'TWISTER', 'EXTRUDER_TP') and m.active and m.inline_with is null
     and v_jobs > 0 and not exists (select 1 from plan.day_work(v_ver, p_date) w where w.machine_code = m.code);
  if v_txt is not null then
    v_checks := v_checks || jsonb_build_object('ok', false, 't', 'Máy không chạy cả ngày: ' || v_txt,
      'd', 'Ghi cách xử lý: bảo trì, vệ sinh, hoặc lý do không xếp người');
  end if;

  return jsonb_build_object('version_id', v_ver, 'checks', v_checks, 'slip', v_slip,
    'lines', coalesce((select jsonb_agg(jsonb_build_object('plan_line_id', x.plan_line_id, 'product_code', p.code, 'cable_m', x.cable_m))
                         from (select distinct dm.plan_line_id, dm.cable_m from plan.day_materials(v_ver, p_date) dm) x
                         join plan.plan_lines pl on pl.id = x.plan_line_id join master.products p on p.id = pl.product_id), '[]'));
end $$;

-- Xếp lại lịch làm lô trễ hạn giao (máy hỏng, bảo dưỡng…): cảnh báo đỏ Giám đốc
create or replace function app.kh_late_alert(p_plan uuid, p_reason text, p_lines text[]) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare pp plan.production_plans;
begin
  if not app.kh_has_any(array['SX_TP','SX_KH','BGD']) then raise exception 'Chỉ Quản lý SX hoặc Giám đốc'; end if;
  if coalesce(array_length(p_lines, 1), 0) = 0 then return; end if;
  select * into pp from plan.production_plans where id = p_plan;
  perform app.kh_notify_role('BGD', 'Cảnh báo đỏ: ' || array_length(p_lines, 1) || ' lô trễ hạn giao (' || pp.plan_no || ')',
    left(coalesce(p_reason || ': ', '') || array_to_string(p_lines, '; '), 900), '/lich-may?plan=' || p_plan || '&tab=thang');
end $$;
revoke execute on function app.kh_late_alert(uuid, text, text[]) from public, anon;
grant execute on function app.kh_late_alert(uuid, text, text[]) to authenticated;
