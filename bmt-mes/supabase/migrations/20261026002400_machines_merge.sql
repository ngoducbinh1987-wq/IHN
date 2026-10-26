-- BMT MES · 20261026002400 · Quản lý máy: gộp với Kế hoạch sản xuất, vá bảo mật
-- 1. Người đứng máy: dùng chung master.operators + master.operator_skills (NV1–NV5, Chủ tịch chốt 25/10/2026).
--    Quản lý SX / TP Kỹ thuật/QA giao người cho dây chuyền ở Hồ sơ máy; TP Kỹ thuật/QA ký xác nhận tay nghề.
--    Bảng master.machine_operators (chưa có dữ liệu) thôi dùng.
-- 2. Kiểm tra năng lực tính giống Lịch máy:
--    * bọc cách điện silicone chạy line silicone; bọc cách điện PVC/HDPE/LSZH chạy line vỏ;
--    * xoắn + quấn AL/PET tính một lần trên máy xoắn (lấy tốc độ chậm hơn);
--    * máy chưa có tốc độ riêng thì dùng tốc độ mặc định theo công đoạn (master.machine_rates, Tham số xếp lịch);
--    * năng lực tính theo nhóm máy; máy "Ngừng dùng" không tính năng lực;
--    * kiểm tra đủ người: số dây chuyền phải chạy cùng lúc ≤ số người đứng chính × số máy một người.
-- 3. Bảo mật: hàm mfg.* không cho anon gọi; lịch sử vận hành đọc qua hàm app.machine_history (bỏ view SECURITY DEFINER).

-- ===========================================================================
-- 1. Người đứng máy
-- ===========================================================================
-- Người có quyền xem máy xem được danh sách người đứng máy (thêm vào quyền xem của Kế hoạch SX)
drop policy if exists p_select_machine on master.operators;
create policy p_select_machine on master.operators for select to authenticated using (core.has_perm('machine', 'view'));
drop policy if exists p_select_machine on master.operator_skills;
create policy p_select_machine on master.operator_skills for select to authenticated using (core.has_perm('machine', 'view'));

drop view if exists app.v_machine_operators;
create view app.v_machine_operators with (security_invoker = true) as
select m.id as machine_id, m.code as machine_code, k.operator_code, o.job, o.extra, o.is_deputy, o.profile_id,
       app.user_name(o.profile_id) as profile_name, k.level, k.signed_at, k.signed_by, app.user_name(k.signed_by) as signed_by_name, o.sort
from master.operator_skills k
join master.operators o on o.code = k.operator_code
join master.machines m on m.code = k.machine_code;
grant select on app.v_machine_operators to authenticated, service_role;

-- Giao người đứng máy cho dây chuyền (đổi mức tay nghề thì phải ký xác nhận lại)
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
  insert into master.operator_skills (operator_code, machine_code, level) values (p_operator, m.code, p_level)
  on conflict (operator_code, machine_code) do update set level = excluded.level, signed_by = null, signed_at = null;
  perform app.kh_log('Người đứng máy', p_operator || ' · ' || m.code, coalesce(v_lbl ->> k.level, 'Chưa giao'), v_lbl ->> p_level,
                     coalesce(nullif(trim(coalesce(p_reason, '')), ''), 'Giao người đứng máy'));
  perform app.kh_notify_role('SX_TP', 'Người đứng máy đã đổi', p_operator || ' · ' || m.code || ': ' || (v_lbl ->> p_level) || '. Bấm Xếp lại lịch để áp dụng.', '/lich-may');
end $$;

create or replace function app.remove_operator_skill(p_machine uuid, p_operator text, p_reason text default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare m master.machines; k master.operator_skills; v_lbl jsonb := '{"MAIN":"Đứng chính","LEARNING":"Đang học"}';
begin
  if not (core.has_role('SX_TP') or core.has_perm('machine', 'config')) then
    raise exception 'Chỉ Quản lý SX hoặc TP Kỹ thuật/QA giao người đứng máy';
  end if;
  select * into m from master.machines where id = p_machine;
  if not found then raise exception 'Không tìm thấy máy'; end if;
  delete from master.operator_skills where operator_code = p_operator and machine_code = m.code returning * into k;
  if k.operator_code is null then raise exception 'Người này chưa được giao dây chuyền %', m.code; end if;
  perform app.kh_log('Người đứng máy', p_operator || ' · ' || m.code, v_lbl ->> k.level, 'Bỏ giao',
                     coalesce(nullif(trim(coalesce(p_reason, '')), ''), 'Bỏ giao người đứng máy'));
  perform app.kh_notify_role('SX_TP', 'Người đứng máy đã đổi', p_operator || ' thôi đứng ' || m.code || '. Bấm Xếp lại lịch để áp dụng.', '/lich-may');
end $$;

-- TP Kỹ thuật/QA ký xác nhận tay nghề
create or replace function app.sign_operator_skill(p_machine uuid, p_operator text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if not (core.has_role('KT_TP') or core.has_role('ADMIN')) then raise exception 'Chỉ TP Kỹ thuật/QA xác nhận tay nghề'; end if;
  update master.operator_skills k set signed_by = auth.uid(), signed_at = now()
    from master.machines m
   where m.id = p_machine and k.machine_code = m.code and k.operator_code = p_operator and k.signed_at is null;
  if not found then raise exception 'Đã xác nhận rồi hoặc người này chưa được giao dây chuyền'; end if;
end $$;

-- Bảng cũ: không dùng nữa
revoke all on master.machine_operators from authenticated;
comment on table master.machine_operators is 'Không dùng từ 26/10/2026: người đứng máy lưu ở master.operators + master.operator_skills';

-- Danh sách dây chuyền: người đứng chính lấy từ tay nghề
create or replace view app.v_machines with (security_invoker = true) as
select m.id, m.code, m.name, m.machine_type, m.inline_with as line_id, l.code as line_code, l.name as line_name,
       m.op_code, o.name as op_name, m.seq, m.critical, m.unit_kind, m.vendor, m.model, m.serial_no, m.year_made, m.location, m.note,
       m.plc_model, m.protocol, m.rated_kw, m.active, m.status, m.status_since, m.status_note, m.status_eta,
       (select count(*) from master.machines c where c.inline_with = m.id) as unit_count,
       (select count(*) from master.machine_specs s where s.machine_id = m.id or s.machine_id in (select c.id from master.machines c where c.inline_with = m.id)) as spec_total,
       (select count(*) from master.machine_specs s where (s.machine_id = m.id or s.machine_id in (select c.id from master.machines c where c.inline_with = m.id)) and coalesce(s.value, '') <> '') as spec_filled,
       (select string_agg(k.operator_code, ', ' order by k.operator_code) from master.operator_skills k
         where k.machine_code = coalesce(l.code, m.code) and k.level = 'MAIN') as operators,
       (select w.id from mfg.maint_work_orders w where w.machine_id = m.id and w.wo_type = 'CM' and w.status in ('OPEN','IN_PROGRESS') limit 1) as open_repair_id
from master.machines m
left join master.machines l on l.id = m.inline_with
left join master.operations o on o.code = coalesce(m.op_code, l.op_code);

-- ===========================================================================
-- 2. Tốc độ: mặc định theo công đoạn khi máy chưa có tốc độ riêng
-- ===========================================================================
-- Tốc độ mặc định (TP Kỹ thuật/QA sửa ở Tham số xếp lịch) cho người có quyền xem máy
create or replace function app.machine_rate_defaults()
returns table (op_code text, label text, unit text, rate_small numeric, rate_large numeric, confirmed boolean, sort smallint)
language sql stable security definer set search_path = pg_catalog, public as $$
  select r.op_code, r.label, r.unit, r.rate_small, r.rate_large, r.confirmed, r.sort
  from master.machine_rates r where core.has_perm('machine', 'view') or app.kh_can_view() order by r.sort
$$;

-- Km mỗi ngày dự kiến: tốc độ riêng của máy, chưa có thì tốc độ mặc định của công đoạn
create or replace function mfg.machine_daily_rate(p_line uuid, out hours_per_day numeric, out km_per_day numeric)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare u record; d int; s jsonb := mfg.machine_setting('shift'); v_std numeric;
begin
  select * into u from mfg.machine_usage(p_line, now() - interval '30 days');
  d := greatest(1, mfg.workdays(((now() at time zone 'Asia/Ho_Chi_Minh') - interval '30 days')::date, (now() at time zone 'Asia/Ho_Chi_Minh')::date));
  hours_per_day := case when u.hours / d >= 0.5 then u.hours / d
                        else coalesce((s ->> 'minutes')::numeric, 480) * coalesce((s ->> 'fill')::numeric, 0.85) / 60 end;
  if u.km / d > 0.05 then km_per_day := u.km / d;
  else
    select avg(std_mpm) into v_std from master.machine_speeds where machine_id = p_line and status <> 'OBSOLETE';
    if v_std is null then
      select (r.rate_small + r.rate_large) / 2 into v_std
      from master.machines m join master.machine_rates r on r.op_code = m.op_code where m.id = p_line;
    end if;
    km_per_day := case when v_std is null then null else hours_per_day * 60 * v_std / 1000 end;
  end if;
end $$;

-- ===========================================================================
-- 3. Kiểm tra năng lực (thay bản 2300)
--    p_extra: [{"product_id": "...", "qty_m": 10000}] đơn thử, không ghi vào kế hoạch
-- ===========================================================================
create or replace function app.check_capacity(p_plan uuid, p_from date, p_to date, p_shifts int default 1,
  p_ot_hours numeric default 0, p_extra jsonb default '[]') returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  s jsonb := mfg.machine_setting('shift');
  v_min numeric := coalesce((s ->> 'minutes')::numeric, 480);
  v_fill numeric := coalesce((s ->> 'fill')::numeric, 0.85);
  v_maxop int := coalesce((mfg.machine_setting('max_machines_per_operator'))::text::int, 2);
  v_days int; v_from timestamptz;
  v_issues jsonb := '[]'; v_ops jsonb := '[]'; v_lines jsonb := '[]'; v_skipped jsonb := '[]';
  r record; o record; g record; mc record; sp record;
  v_type text; v_codes text[]; v_n int; v_meters numeric; v_line_issues jsonb; v_size_ok boolean;
  v_unapproved boolean := false; v_default_ops text[] := '{}'; v_default_guess boolean := false;
  v_cap numeric; v_req numeric; v_load numeric; v_mach jsonb; v_maint numeric; v_down numeric; v_eta timestamptz; v_note text;
  v_gross numeric; v_need numeric := 0; v_busy text[] := '{}'; v_people int;
begin
  if not core.has_perm('machine', 'view') and not core.has_perm('plan', 'view') then raise exception 'Bạn chưa có quyền xem năng lực máy'; end if;
  if p_to < p_from then raise exception 'Ngày kết thúc phải sau ngày bắt đầu'; end if;
  p_shifts := greatest(1, least(3, coalesce(p_shifts, 1)));
  v_days := mfg.workdays(p_from, p_to);
  v_from := p_from::timestamp at time zone 'Asia/Ho_Chi_Minh';

  -- Nhu cầu: dòng kế hoạch + đơn thử
  drop table if exists _dem; drop table if exists _req;
  create temporary table _dem on commit drop as
  select p.id as product_id, p.code, p.description, p.group_code, sp2.core_code, sp2.cores, ct.nominal_mm2,
         upper(coalesce(sp2.insulation, '')) like 'SIL%' as sil,
         sum(d.qty_m) as qty_m, sum(d.lots) as lots, bool_or(d.trial) as trial
  from (
    select l.product_id, l.qty_m, l.run_lots as lots, false as trial from plan.plan_lines l where l.plan_id = p_plan
    union all
    select (e ->> 'product_id')::uuid, (e ->> 'qty_m')::numeric, 1, true from jsonb_array_elements(coalesce(p_extra, '[]')) e
  ) d
  join master.products p on p.id = d.product_id
  join master.product_specs sp2 on sp2.id = p.current_spec_id
  left join master.core_types ct on ct.code = sp2.core_code and ct.set_id = sp2.param_set_id
  group by 1, 2, 3, 4, 5, 6, 7, 8;

  create temporary table _req (mtype text, minutes numeric) on commit drop;

  for r in select * from _dem loop
    v_line_issues := '[]';
    for o in select op.code, op.name, op.machine_type, op.per_core
             from master.routings rt join master.operations op on op.code = rt.op_code
             where rt.group_code = r.group_code order by op.seq loop
      -- Quấn AL/PET chạy liền trên máy xoắn: tính cùng công đoạn xoắn
      if o.code = 'CD4' and exists (select 1 from master.routings where group_code = r.group_code and op_code = 'CD3') then continue; end if;
      -- Bọc cách điện: silicone chạy line silicone, PVC/HDPE/LSZH chạy line vỏ
      v_type := case when o.code = 'CD2' then case when r.sil then 'EXTRUDER_SI' else 'EXTRUDER_TP' end else o.machine_type end;
      v_codes := case when o.code = 'CD3' and exists (select 1 from master.routings where group_code = r.group_code and op_code = 'CD4')
                      then array['CD3','CD4'] else array[o.code] end;
      select count(*) into v_n from master.machines mm
       where mm.active and mm.inline_with is null and mm.machine_type = v_type and mm.status <> 'OFF';
      if v_n = 0 then
        if not v_skipped @> to_jsonb(array[o.name]) then v_skipped := v_skipped || to_jsonb(array[o.name]); end if;
        continue;
      end if;
      -- Dải hoạt động: tiết diện ruột (ít nhất một máy làm được)
      select bool_or(rg.id is null or r.nominal_mm2 is null
                     or (r.nominal_mm2 >= coalesce(rg.min_value, -1) - 0.0001 and r.nominal_mm2 <= coalesce(rg.max_value, 1e9) + 0.0001)) into v_size_ok
      from master.machines mm left join master.machine_ranges rg on rg.machine_id = mm.id and rg.param = 'SIZE_MM2'
      where mm.active and mm.inline_with is null and mm.machine_type = v_type and mm.status <> 'OFF';
      if not coalesce(v_size_ok, true) then
        v_line_issues := v_line_issues || jsonb_build_object('lvl', 'bad', 'op', o.name, 'text', format('Tiết diện %s mm² ngoài dải của máy', round(r.nominal_mm2, 2)));
        continue;
      end if;
      -- Tốc độ từng máy: tốc độ riêng hợp nhất (mã SP → nhóm + mã lõi → mã lõi → nhóm → mặc định máy),
      -- chưa có thì tốc độ mặc định của công đoạn; xoắn + AL/PET lấy tốc độ chậm hơn; trung bình các máy cùng nhóm
      select avg(x.eff) as eff, avg(x.setup) as setup, bool_or(x.pending) as pending, bool_or(x.dflt) as dflt, bool_or(x.guess) as guess into sp
      from (
        select mm.id, min(coalesce(b.eff, d.rate)) as eff, max(coalesce(b.setup, 0)) as setup,
               bool_or(b.status = 'PENDING') as pending, bool_or(b.eff is null) as dflt, bool_or(b.eff is null and not coalesce(d.confirmed, false)) as guess
        from master.machines mm
        cross join unnest(v_codes) as oc(code)
        left join lateral (
          select s2.status, s2.setup_min as setup,
                 least(s2.std_mpm, coalesce(s2.rated_mpm, s2.std_mpm),
                       coalesce((select rg.max_value from master.machine_ranges rg where rg.machine_id = mm.id and rg.param = 'SPEED_MPM'), s2.std_mpm)) as eff
          from master.machine_speeds s2
          where s2.machine_id = mm.id and s2.op_code = oc.code and s2.status <> 'OBSOLETE'
            and (s2.product_id = r.product_id or s2.product_id is null)
            and (s2.group_code = r.group_code or s2.group_code is null)
            and (s2.core_code = r.core_code or s2.core_code is null)
          order by (s2.product_id is not null) desc, (s2.group_code is not null and s2.core_code is not null) desc,
                   (s2.core_code is not null) desc, (s2.group_code is not null) desc, (s2.status = 'APPROVED') desc, s2.submitted_at desc
          limit 1) b on true
        left join lateral (
          select case when coalesce(r.nominal_mm2, 0) >= 2.5 then mr.rate_large else mr.rate_small end as rate, mr.confirmed
          from master.machine_rates mr where mr.op_code = oc.code) d on true
        where mm.active and mm.inline_with is null and mm.machine_type = v_type and mm.status <> 'OFF'
        group by mm.id
      ) x;
      if sp.eff is null then
        v_line_issues := v_line_issues || jsonb_build_object('lvl', 'bad', 'op', o.name, 'text', 'Chưa có tốc độ chuẩn');
        continue;
      end if;
      if sp.pending then v_unapproved := true; end if;
      if sp.dflt and not v_default_ops @> array[o.name] then v_default_ops := v_default_ops || o.name; end if;
      if sp.guess then v_default_guess := true; end if;
      v_meters := r.qty_m * case when o.per_core then greatest(r.cores, 1) else 1 end;
      insert into _req values (v_type, v_meters / sp.eff + coalesce(sp.setup, 0) * greatest(r.lots, 1));
    end loop;
    v_lines := v_lines || jsonb_build_object('product_id', r.product_id, 'code', r.code, 'description', r.description,
      'qty_m', r.qty_m, 'trial', r.trial, 'issues', v_line_issues);
    if jsonb_array_length(v_line_issues) > 0 then
      v_issues := v_issues || (select jsonb_agg(jsonb_build_object('lvl', 'bad', 'text', r.code || ': ' || (i ->> 'text') || ' (' || (i ->> 'op') || ')',
        'hint', case when i ->> 'text' like 'Chưa có tốc độ%' then 'TP Kỹ thuật/QA khai báo tốc độ trong Hồ sơ máy hoặc Tham số xếp lịch.'
                     else 'Không máy nào trong xưởng làm được. Từ chối đơn hoặc thuê gia công ngoài.' end))
        from jsonb_array_elements(v_line_issues) i);
    end if;
  end loop;

  -- Năng lực từng nhóm máy
  for g in select t.mtype, t.sort,
                  case t.mtype when 'BUNCHER' then 'Bện ruột dẫn (máy bện)'
                               when 'EXTRUDER_SI' then 'Bọc cách điện silicone (line silicone)'
                               when 'TWISTER' then 'Xoắn + quấn AL/PET (máy xoắn)'
                               when 'EXTRUDER_TP' then 'Bọc vỏ, bọc cách điện PVC/HDPE/LSZH (line vỏ)'
                               else t.names end as label
           from (select mm.machine_type as mtype, min(coalesce(op.seq, 99)) as sort, string_agg(distinct op.name, ', ') as names
                 from master.machines mm left join master.operations op on op.code = mm.op_code
                 where mm.active and mm.inline_with is null and mm.op_code is not null
                 group by mm.machine_type) t
           order by t.sort, t.mtype loop
    v_cap := 0; v_mach := '[]'; v_n := 0;
    for mc in select mm.* from master.machines mm
              where mm.active and mm.inline_with is null and mm.op_code is not null and mm.machine_type = g.mtype order by mm.code loop
      v_gross := v_days * (v_min * p_shifts + coalesce(p_ot_hours, 0) * 60) * v_fill;
      v_maint := 0; v_down := 0; v_note := null;
      if mc.status = 'OFF' then
        v_gross := 0; v_note := 'Ngừng dùng, không tính năng lực';
      else
        v_n := v_n + 1;
        -- Bảo dưỡng trong ca đến hạn trong kỳ (kể cả máy con của dây chuyền)
        select coalesce(sum(p.stop_minutes * greatest(1, 1 + floor(greatest(0, (p_to - greatest(st.due_date, p_from))::numeric)
                   / greatest(1, coalesce(p.every_days, 9999))))), 0) into v_maint
        from mfg.maint_plans p join master.machines um on um.id = p.machine_id
        cross join lateral mfg.maint_plan_state(p.id) st
        where p.active and not p.off_shift and p.stop_minutes > 0 and coalesce(um.inline_with, um.id) = mc.id
          and st.open_wo is null and st.due_date <= p_to;
        -- Máy hỏng / bảo dưỡng: trừ ngày làm việc tới giờ dự kiến chạy lại (chưa có giờ dự kiến: trừ 1 ngày)
        if mc.status in ('DOWN','MAINT') then
          v_eta := coalesce(mc.status_eta, now() + interval '1 day');
          if v_eta > v_from then
            v_down := mfg.workdays(greatest(p_from, (now() at time zone 'Asia/Ho_Chi_Minh')::date),
                                   least(p_to, ((v_eta at time zone 'Asia/Ho_Chi_Minh') - interval '1 minute')::date)) * v_min * p_shifts * v_fill;
            v_down := least(v_down, v_days * v_min * p_shifts * v_fill);
          end if;
          v_note := case mc.status when 'DOWN' then 'Hỏng' else 'Bảo dưỡng' end
                    || coalesce(', dự kiến chạy lại ' || to_char(mc.status_eta at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM'), ', chưa có giờ dự kiến');
          v_issues := v_issues || jsonb_build_object('lvl', 'warn', 'text', mc.code || ' ' || lower(v_note),
            'hint', format('Đã trừ %s giờ máy. Sửa lâu hơn thì cập nhật giờ dự kiến trên phiếu để tính lại.', round(v_down / 60, 1)));
        end if;
      end if;
      v_cap := v_cap + greatest(0, v_gross - v_maint - v_down);
      v_mach := v_mach || jsonb_build_object('id', mc.id, 'code', mc.code, 'name', mc.name, 'status', mc.status, 'note', v_note,
        'gross_min', round(v_gross), 'maint_min', round(v_maint), 'down_min', round(v_down),
        'operator', (select string_agg(k.operator_code, ', ' order by k.operator_code) from master.operator_skills k
                      where k.machine_code = mc.code and k.level = 'MAIN'));
    end loop;
    select coalesce(sum(minutes), 0) into v_req from _req where mtype = g.mtype;
    v_load := case when v_cap > 0 then v_req / v_cap when v_req > 0 then 9.99 else 0 end;
    v_ops := v_ops || jsonb_build_object('op_code', g.mtype, 'name', g.label, 'req_min', round(v_req), 'cap_min', round(v_cap),
                                         'load', round(v_load, 4), 'machines', v_mach);
    if v_req > 0 and v_n > 0 then
      -- Số dây chuyền phải chạy cùng lúc của nhóm này
      v_need := v_need + least(v_n, ceil(least(v_load, 1) * v_n));
      v_busy := v_busy || array(select mm.code from master.machines mm
                                 where mm.active and mm.inline_with is null and mm.op_code is not null and mm.machine_type = g.mtype and mm.status <> 'OFF');
    end if;
    if v_load > 1 then
      v_issues := v_issues || jsonb_build_object('lvl', 'bad', 'text', format('%s quá tải %s%%', g.label, round(v_load * 100)),
        'hint', format('Thiếu %s giờ máy. Tăng ca, thêm ca, dời hạn hoặc bớt đơn.', round((v_req - v_cap) / 60)));
    elsif v_load >= 0.85 then
      v_issues := v_issues || jsonb_build_object('lvl', 'warn', 'text', format('%s tải %s%%, còn %s giờ dự phòng', g.label, round(v_load * 100), round((v_cap - v_req) / 60)),
        'hint', 'Một lần hỏng máy dài có thể trễ đơn. Ưu tiên bảo dưỡng ngoài giờ ca.');
    end if;
  end loop;

  -- Bảo dưỡng quá hạn
  v_issues := v_issues || coalesce((select jsonb_agg(jsonb_build_object('lvl', 'warn',
      'text', m.code || ' quá hạn bảo dưỡng: ' || p.name,
      'hint', case when p.off_shift then 'Làm ngoài giờ ca, không trừ năng lực. Làm ngay sau ca.' else format('Đã giữ %s phút dừng máy. Quản lý SX xếp vào kế hoạch ngày.', p.stop_minutes) end))
    from mfg.maint_plans p join master.machines m on m.id = p.machine_id cross join lateral mfg.maint_plan_state(p.id) st
    where p.active and st.state = 'OVERDUE' and st.open_wo is null), '[]');

  -- Người đứng máy
  v_issues := v_issues || coalesce((select jsonb_agg(jsonb_build_object('lvl', 'warn', 'text', m.code || ' chưa có người đứng máy chính',
      'hint', 'Quản lý SX giao người trong Hồ sơ máy → Người đứng máy. Chỉ giao người đã được TP Kỹ thuật/QA xác nhận tay nghề.'))
    from master.machines m where m.active and m.inline_with is null and m.op_code is not null and m.status <> 'OFF'
      and not exists (select 1 from master.operator_skills k where k.machine_code = m.code and k.level = 'MAIN')), '[]');
  if v_need > 0 then
    select count(distinct k.operator_code) into v_people from master.operator_skills k
     join master.operators op on op.code = k.operator_code and op.active
     where k.level = 'MAIN' and k.machine_code = any(v_busy);
    if v_need > v_people * v_maxop then
      v_issues := v_issues || jsonb_build_object('lvl', 'bad',
        'text', format('Thiếu người: cần chạy cùng lúc khoảng %s dây chuyền, có %s người đứng chính × %s máy/người', v_need, v_people, v_maxop),
        'hint', 'Giao thêm người đứng máy, cho người đang học đứng kèm, hoặc giãn kế hoạch để chạy luân phiên.');
    end if;
  end if;

  if v_unapproved then
    v_issues := v_issues || jsonb_build_object('lvl', 'info', 'text', 'Có tốc độ đang dùng là số chờ duyệt',
      'hint', 'Kết quả để tham khảo. TP Kỹ thuật/QA duyệt tốc độ chuẩn; chờ quá 1 ngày làm việc thì Giám đốc duyệt tạm.');
  end if;
  if cardinality(v_default_ops) > 0 then
    v_issues := v_issues || jsonb_build_object('lvl', 'info',
      'text', 'Dùng tốc độ mặc định theo công đoạn cho: ' || array_to_string(v_default_ops, ', ')
              || case when v_default_guess then ' (số giả định, chưa xác nhận)' else '' end,
      'hint', 'Máy chưa có tốc độ riêng. TP Kỹ thuật/QA khai báo ở Hồ sơ máy → Tốc độ, hoặc xác nhận tốc độ mặc định ở Tham số xếp lịch.');
  end if;

  return jsonb_build_object('from', p_from, 'to', p_to, 'workdays', v_days, 'shifts', p_shifts, 'ot_hours', coalesce(p_ot_hours, 0),
    'shift_minutes', v_min, 'fill', v_fill, 'ops', v_ops, 'lines', v_lines, 'skipped_ops', v_skipped,
    'issues', (select coalesce(jsonb_agg(i order by case i ->> 'lvl' when 'bad' then 0 when 'warn' then 1 else 2 end), '[]') from jsonb_array_elements(v_issues) i));
end $$;

-- ===========================================================================
-- 4. Lịch sử vận hành: hàm thay view SECURITY DEFINER (đọc được nhật ký sửa thông số trong core.audit_log)
-- ===========================================================================
create or replace function app.machine_history(p_line uuid default null, p_machine uuid default null,
  p_from timestamptz default null, p_to timestamptz default null, p_limit int default 200)
returns table (machine_id uuid, line_id uuid, at timestamptz, kind text, sub text, detail text, source text, who text)
language sql stable security definer set search_path = pg_catalog, public as $$
  select h.* from (
    select g.machine_id, mfg.line_of(g.machine_id) as line_id, g.started_at as at, 'STATUS'::text as kind, g.status as sub,
           coalesce(r.name, '') || case when g.note is not null then case when r.name is null then '' else ': ' end || g.note else '' end as detail,
           g.source, app.user_name(g.created_by) as who
    from mfg.machine_status_log g left join master.reason_codes r on r.code = g.reason_code
    union all
    select w.machine_id, mfg.line_of(w.machine_id), w.created_at, 'WO_OPEN', w.wo_type, w.wo_no || ' ' || w.title, 'HE_THONG', app.user_name(w.created_by)
    from mfg.maint_work_orders w
    union all
    select w.machine_id, mfg.line_of(w.machine_id), w.finished_at, 'WO_DONE', w.wo_type,
           w.wo_no || ' xong · ' || case w.result when 'OK' then 'đạt' else 'chưa đạt' end || coalesce(' · ' || w.action_taken, ''), 'HE_THONG', app.user_name(w.done_by)
    from mfg.maint_work_orders w where w.status = 'DONE'
    union all
    select c.machine_id, c.machine_id, c.done_at, 'CHECK', case when c.has_issue then 'ISSUE' else 'OK' end,
           'Checklist đầu ca' || case when c.has_issue then ' có vấn đề' || coalesce(': ' || c.note, '') else ' đạt' end, 'TAY', app.user_name(c.done_by)
    from mfg.maint_checks c
    union all
    select (a.new_data ->> 'machine_id')::uuid, mfg.line_of((coalesce(a.new_data, a.old_data) ->> 'machine_id')::uuid), a.at, 'CHANGE',
           case a.table_name when 'master.machine_speeds' then 'SPEED' else 'SPEC' end,
           case a.table_name when 'master.machine_speeds'
             then 'Tốc độ ' || coalesce(a.new_data ->> 'label', a.new_data ->> 'op_code', '') || ': ' || coalesce(a.old_data ->> 'std_mpm', '—') || ' → ' || coalesce(a.new_data ->> 'std_mpm', '—') || ' m/ph (' || coalesce(a.new_data ->> 'status', '') || ')'
             else 'Thông số ' || coalesce(a.new_data ->> 'label', a.old_data ->> 'label', '') || ': ' || coalesce(a.old_data ->> 'value', '—') || ' → ' || coalesce(a.new_data ->> 'value', '—') end,
           'TAY', app.user_name(a.user_id)
    from core.audit_log a
    where a.table_name in ('master.machine_specs','master.machine_speeds') and a.action = 'UPDATE'
      and (a.old_data ->> 'value' is distinct from a.new_data ->> 'value' or a.old_data ->> 'std_mpm' is distinct from a.new_data ->> 'std_mpm'
           or a.old_data ->> 'status' is distinct from a.new_data ->> 'status')
    union all
    select k.m_id, k.m_id, l.at, 'PEOPLE', 'SKILL', 'Người đứng máy ' || l.item || ': ' || coalesce(l.old_value, '—') || ' → ' || coalesce(l.new_value, '—'), 'TAY', app.user_name(l.user_id)
    from master.planning_param_log l
    cross join lateral (select m.id as m_id from master.machines m where m.code = split_part(l.item, ' · ', 2)) k
    where l.section = 'Người đứng máy'
    union all
    select e.machine_id, mfg.line_of(e.machine_id), e.ts, 'ALARM', e.event_type, coalesce(e.code || ': ', '') || coalesce(e.message, ''), 'PLC', null
    from iot.machine_events e
  ) h
  where core.has_perm('machine', 'view')
    and (p_line is null or h.line_id = p_line) and (p_machine is null or h.machine_id = p_machine)
    and (p_from is null or h.at >= p_from) and (p_to is null or h.at <= p_to)
  order by h.at desc
  limit greatest(1, least(coalesce(p_limit, 200), 1000))
$$;
drop view if exists app.v_machine_history;

-- ===========================================================================
-- 5. Quyền gọi hàm
-- ===========================================================================
revoke execute on function mfg.line_of(uuid), mfg.shift_setting(), mfg.machine_setting(text), mfg.workdays(date, date),
  mfg.status_minutes(uuid, text, timestamptz, timestamptz), mfg.machine_usage(uuid, timestamptz), mfg.machine_daily_rate(uuid),
  mfg.maint_plan_state(uuid), mfg.roles_setting(text, text[]) from public, anon;
grant execute on function mfg.line_of(uuid), mfg.shift_setting(), mfg.machine_setting(text), mfg.workdays(date, date),
  mfg.status_minutes(uuid, text, timestamptz, timestamptz), mfg.machine_usage(uuid, timestamptz), mfg.machine_daily_rate(uuid),
  mfg.maint_plan_state(uuid), mfg.roles_setting(text, text[]) to authenticated, service_role;
revoke execute on function app.set_operator_skill(uuid, text, text, text), app.remove_operator_skill(uuid, text, text),
  app.sign_operator_skill(uuid, text), app.machine_rate_defaults(), app.machine_history(uuid, uuid, timestamptz, timestamptz, int),
  app.check_capacity(uuid, date, date, int, numeric, jsonb) from public, anon;
grant execute on function app.set_operator_skill(uuid, text, text, text), app.remove_operator_skill(uuid, text, text),
  app.sign_operator_skill(uuid, text), app.machine_rate_defaults(), app.machine_history(uuid, uuid, timestamptz, timestamptz, int),
  app.check_capacity(uuid, date, date, int, numeric, jsonb) to authenticated, service_role;
