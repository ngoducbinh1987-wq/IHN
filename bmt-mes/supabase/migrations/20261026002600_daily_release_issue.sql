-- BMT MES · 20261026002600 · Lệnh ngày: database tự tính kiểm tra + phiếu lĩnh theo định mức BOM, nối với Kho
--  1. plan.day_work: việc trong ngày lấy từ lịch máy đã lưu (cùng cách chia ca với web/lib/kh/scheduler.ts)
--  2. plan.day_materials: vật tư theo định mức BOM của từng dòng kế hoạch (CD1/CD2 quy mét lõi ra mét cáp)
--  3. app.kh_day_preview: kiểm tra trước khi phát (kế hoạch, việc, spec, BOM, tồn kho, máy không chạy) + phiếu lĩnh dự kiến
--  4. app.kh_release_day: không nhận kiểm tra/phiếu lĩnh do web gửi; tự tính, gắn lệnh SX cho từng dòng có việc
--  5. app.kh_approve_slip: Kế toán kho duyệt → tạo phiếu lĩnh Kho (inv.requisitions) theo lệnh SX để thủ kho quét QR cấp

alter table inv.requisitions add column if not exists slip_id uuid references plan.issue_slips(id);
create index if not exists requisitions_slip on inv.requisitions (slip_id);

-- ---------------------------------------------------------------------------
-- 1. Việc trong ngày
-- ---------------------------------------------------------------------------
-- Ngày làm việc thứ di (tính từ ngày làm việc đầu tiên ≥ base_date) chiếm đoạn phút [di·SPD·S, (di+1)·SPD·S).
-- Mét trong ngày = phần chạy (sau đổi máy) nằm trong đoạn × tốc độ. first_slot: lượt đầu tiên của dòng + công đoạn (tính hao hụt khởi động).
create or replace function plan.day_work(p_version uuid, p_date date)
returns table (plan_line_id uuid, op_code text, machine_code text, meters numeric, first_slot boolean)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v plan.schedule_versions; v_s numeric; v_spd integer; v_wd integer[]; v_base date; v_di integer; d0 numeric; d1 numeric;
begin
  select * into v from plan.schedule_versions where id = p_version;
  if not found or p_date is null then return; end if;
  v_s := (v.params ->> 'S')::numeric;
  v_spd := coalesce((v.params ->> 'SPD')::integer, 1);
  v_wd := coalesce((select array_agg(x::integer) from jsonb_array_elements_text(v.params -> 'workdays') x), array[1, 2, 3, 4, 5, 6]);
  if coalesce(v_s, 0) <= 0 or not (extract(isodow from p_date)::integer = any(v_wd)) then return; end if;
  select min(d)::date into v_base from generate_series(v.base_date::timestamp, v.base_date + 14, interval '1 day') d
   where extract(isodow from d)::integer = any(v_wd);
  if p_date < v_base then return; end if;
  select count(*) into v_di from generate_series(v_base::timestamp, p_date - 1, interval '1 day') d
   where extract(isodow from d)::integer = any(v_wd);
  d0 := v_di * v_spd * v_s;
  d1 := d0 + v_spd * v_s;
  return query
  select s.plan_line_id, s.op_code, s.machine_code,
         round(greatest(0, least(s.end_min, d1) - greatest(s.run_start_min, d0)) * s.rate, 1),
         s.run_start_min >= d0 and s.run_start_min < d1
           and s.run_start_min = (select min(s2.run_start_min) from plan.schedule_slots s2
                                   where s2.version_id = p_version and s2.plan_line_id = s.plan_line_id and s2.op_code = s.op_code)
  from plan.schedule_slots s
  where s.version_id = p_version and s.end_min > d0 and s.start_min < d1;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Vật tư theo định mức BOM
-- ---------------------------------------------------------------------------
-- Công đoạn lịch máy → công đoạn trong BOM: CD2 gồm phối trộn silicone (CD0); CD3 gồm quấn băng chống nhiễu (CD4);
-- CD5 gồm đóng gói (CD6, tính theo kiện). Kiện/pallet tính lúc xuất giao, không lĩnh theo ca.
create or replace function plan.day_materials(p_version uuid, p_date date)
returns table (plan_line_id uuid, material_id uuid, qty numeric, cable_m numeric)
language sql stable security definer set search_path = pg_catalog, public as $$
  with w as (
    select * from plan.day_work(p_version, p_date) where meters > 0
  ), e as (
    select w.*, pl.spec_id, pl.m_per_pack,
           case when w.op_code in ('CD1', 'CD2')
                then w.meters / greatest(1, coalesce(jsonb_array_length(so.meta -> 'cores'), 1)) else w.meters end as em
    from w join plan.plan_lines pl on pl.id = w.plan_line_id
    left join plan.schedule_orders so on so.version_id = p_version and so.plan_line_id = w.plan_line_id
  ), b as (
    select e.plan_line_id, bl.material_id,
           case bl.basis
             when 'KM' then bl.qty_per_basis * e.em / 1000 / (1 - bl.loss_rate) + case when e.first_slot then bl.startup_per_lot else 0 end
             when 'PACK' then bl.qty_per_basis * e.em / e.m_per_pack
             else 0 end as q
    from e join master.bom_headers h on h.spec_id = e.spec_id join master.bom_lines bl on bl.bom_id = h.id
    where bl.operation_code = any (case e.op_code when 'CD1' then array['CD1'] when 'CD2' then array['CD2', 'CD0']
                                                  when 'CD3' then array['CD3', 'CD4'] when 'CD5' then array['CD5', 'CD6']
                                                  else array[e.op_code] end)
  )
  select b.plan_line_id, b.material_id, round(sum(b.q), 3),
         (select round(max(e.em)) from e where e.plan_line_id = b.plan_line_id)
  from b group by b.plan_line_id, b.material_id
  having round(sum(b.q), 3) > 0
$$;

-- ---------------------------------------------------------------------------
-- 3. Kiểm tra + phiếu lĩnh dự kiến (web hiển thị đúng thứ database sẽ kiểm khi phát)
-- ---------------------------------------------------------------------------
create or replace function app.kh_day_preview(p_plan uuid, p_date date) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare pp plan.production_plans; v_ver uuid; v_checks jsonb := '[]'; v_slip jsonb; v_jobs integer; v_mach integer;
        v_txt text; v_txt2 text;
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

-- ---------------------------------------------------------------------------
-- 4. Lệnh SX cho dòng kế hoạch (tạo và phát nếu chưa có; dùng lại lệnh đang chạy)
-- ---------------------------------------------------------------------------
create or replace function plan.ensure_wo(p_line uuid, p_date date) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare l plan.plan_lines; w mfg.work_orders; v_bom uuid; v_spec_status text; pp plan.production_plans;
begin
  select * into l from plan.plan_lines where id = p_line;
  select * into pp from plan.production_plans where id = l.plan_id;
  select * into w from mfg.work_orders where plan_line_id = p_line and status not in ('CANCELLED', 'CLOSED')
   order by created_at desc limit 1;
  if found and w.status <> 'DRAFT' then return w.id; end if;
  select s.status into v_spec_status from master.product_specs s where s.id = l.spec_id;
  select id into v_bom from master.bom_headers where spec_id = l.spec_id;
  if v_spec_status <> 'RELEASED' or v_bom is null then return null; end if;
  if w.id is null then
    insert into mfg.work_orders (wo_no, wo_type, plan_line_id, product_id, spec_id, bom_id, qty_m, run_lots, m_per_pack, pack_type, brand,
                                 planned_start, note)
    values (core.next_no('LSX'), 'PRODUCTION', l.id, l.product_id, l.spec_id, v_bom, l.qty_m, l.run_lots, l.m_per_pack, l.pack_type, l.brand,
            p_date, 'Theo kế hoạch tháng ' || pp.plan_no || ' (tạo khi phát lệnh ngày ' || to_char(p_date, 'DD/MM') || ')')
    returning * into w;
  end if;
  -- Kế hoạch tháng đã được Giám đốc duyệt; Quản lý SX phát lệnh ngày = phát lệnh SX cho dòng có việc
  perform set_config('bmt.wf_release', 'on', true);
  perform mfg.release_wo(w.id);
  perform set_config('bmt.wf_release', '', true);
  return w.id;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Phát lệnh ngày (p_checks, p_slip chỉ giữ để tương thích, không dùng)
-- ---------------------------------------------------------------------------
create or replace function app.kh_release_day(p_plan uuid, p_date date, p_note text, p_checks jsonb, p_slip jsonb) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare pp plan.production_plans; v_ver uuid; v_rev integer; v_id uuid; v_no text; v_warn integer; v_prev jsonb; r record; v_wos text;
begin
  if not app.kh_has_any(array['SX_TP','SX_KH']) then raise exception 'Chỉ Quản lý SX được phát lệnh ngày'; end if;
  select * into pp from plan.production_plans where id = p_plan;
  if pp.status <> 'APPROVED' then raise exception 'Kế hoạch tháng % chưa được duyệt: chưa phát lệnh ngày được', pp.plan_no; end if;
  if p_date < (now() at time zone 'Asia/Ho_Chi_Minh')::date then raise exception 'Không phát lệnh cho ngày đã qua'; end if;
  select id into v_ver from plan.schedule_versions where plan_id = p_plan and is_current;
  if v_ver is null then raise exception 'Chưa có lịch máy: bấm Xếp lại lịch trước'; end if;
  v_prev := app.kh_day_preview(p_plan, p_date);
  if not exists (select 1 from plan.day_work(v_ver, p_date)) then raise exception 'Không có việc nào trong ngày % theo lịch máy', to_char(p_date, 'DD/MM'); end if;
  select count(*) into v_warn from jsonb_array_elements(v_prev -> 'checks') e where not (e ->> 'ok')::boolean;
  if v_warn > 0 and coalesce(trim(p_note), '') = '' then raise exception 'Còn % cảnh báo: ghi cách xử lý vào ô ghi chú', v_warn; end if;

  select coalesce(max(revision), 0) + 1 into v_rev from plan.daily_releases where plan_id = p_plan and work_date = p_date;
  insert into plan.daily_releases (plan_id, work_date, revision, version_id, note, checks)
  values (p_plan, p_date, v_rev, v_ver, nullif(trim(p_note), ''), v_prev -> 'checks') returning id into v_id;
  v_no := 'PL-' || to_char(p_date, 'YYMMDD') || '-' || lpad(v_rev::text, 2, '0');
  insert into plan.issue_slips (release_id, slip_no, work_date, lines) values (v_id, v_no, p_date, v_prev -> 'slip');

  -- Gắn lệnh SX cho từng dòng có việc trong ngày
  for r in select distinct w.plan_line_id from plan.day_work(v_ver, p_date) w loop
    perform plan.ensure_wo(r.plan_line_id, p_date);
  end loop;
  select string_agg(wo.wo_no, ', ' order by wo.wo_no) into v_wos
    from mfg.work_orders wo where wo.plan_line_id in (select distinct w.plan_line_id from plan.day_work(v_ver, p_date) w)
     and wo.status in ('RELEASED', 'IN_PROGRESS');

  perform app.kh_notify_role('KT_KHO', 'Phiếu lĩnh ' || v_no || ' chờ duyệt', 'Lệnh ngày ' || to_char(p_date, 'DD/MM') || case when v_rev > 1 then ' (bản ' || v_rev || ')' else '' end || ' đã phát. Lệnh SX: ' || coalesce(v_wos, '—'), '/lenh-ngay?d=' || p_date);
  perform app.kh_notify_role('BGD', 'Đã phát lệnh ngày ' || to_char(p_date, 'DD/MM') || case when v_rev > 1 then ' bản ' || v_rev else '' end, nullif(trim(p_note), ''), '/lenh-ngay?d=' || p_date);
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Kế toán kho duyệt phiếu lĩnh → phiếu lĩnh Kho theo lệnh SX (thủ kho quét QR cấp ở /kho/cap-phat)
-- ---------------------------------------------------------------------------
create or replace function app.kh_approve_slip(p_slip uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare s plan.issue_slips; d plan.daily_releases; pp plan.production_plans; r record; v_wo uuid; v_req uuid; v_no text; v_list text := '';
        v_cancel integer := 0;
begin
  if not core.has_role('KT_KHO') then raise exception 'Chỉ Kế toán kho được duyệt phiếu lĩnh'; end if;
  select * into s from plan.issue_slips where id = p_slip for update;
  if not found then raise exception 'Không tìm thấy phiếu lĩnh'; end if;
  if s.status = 'APPROVED' then raise exception 'Phiếu đã duyệt'; end if;
  select * into d from plan.daily_releases where id = s.release_id;
  select * into pp from plan.production_plans where id = d.plan_id;
  if d.released_by = auth.uid() then raise exception 'Người phát lệnh ngày không tự duyệt phiếu lĩnh'; end if;
  update plan.issue_slips set status = 'APPROVED', approved_by = auth.uid(), approved_at = now() where id = p_slip;

  -- Bản phát lại trong cùng ngày: hủy phiếu lĩnh Kho của bản trước nếu chưa cấp gì
  update inv.requisitions rq set status = 'CANCELLED', note = concat_ws(' · ', rq.note, 'Hủy: thay bằng ' || s.slip_no)
   where rq.slip_id in (select s2.id from plan.issue_slips s2 join plan.daily_releases d2 on d2.id = s2.release_id
                         where d2.plan_id = d.plan_id and d2.work_date = d.work_date and s2.id <> p_slip)
     and rq.status = 'APPROVED'
     and not exists (select 1 from inv.requisition_lines rl where rl.req_id = rq.id and rl.qty_issued > 0);
  get diagnostics v_cancel = row_count;

  for r in select dm.plan_line_id, max(dm.cable_m) as cable_m, p.code from plan.day_materials(d.version_id, d.work_date) dm
           join plan.plan_lines pl on pl.id = dm.plan_line_id join master.products p on p.id = pl.product_id
           group by dm.plan_line_id, p.code order by p.code loop
    v_wo := plan.ensure_wo(r.plan_line_id, d.work_date);
    continue when v_wo is null;   -- spec chưa phát hành / chưa có BOM: đã cảnh báo lúc phát lệnh
    v_no := core.next_no('PL');
    insert into inv.requisitions (req_no, wo_id, kind, work_date, qty_m, status, note, slip_id)
    values (v_no, v_wo, 'NORM', d.work_date, null, 'APPROVED',
            'Theo lệnh ngày ' || s.slip_no || ' · ' || r.code || ' ≈ ' || core.vn_num(r.cable_m) || ' m cáp', p_slip)
    returning id into v_req;
    insert into inv.requisition_lines (req_id, material_id, qty_norm, qty_req)
    select v_req, dm.material_id, dm.qty, dm.qty from plan.day_materials(d.version_id, d.work_date) dm where dm.plan_line_id = r.plan_line_id;
    v_list := v_list || case when v_list = '' then '' else ', ' end || v_no || ' (' || r.code || ')';
  end loop;

  perform app.kh_notify_role('THU_KHO', 'Phiếu lĩnh ' || s.slip_no || ' đã duyệt',
    'Cấp đầu ca ' || to_char(s.work_date, 'DD/MM') || ' bằng quét QR: ' || coalesce(nullif(v_list, ''), 'không có vật tư cần cấp')
      || case when v_cancel > 0 then '. Đã hủy ' || v_cancel || ' phiếu của bản phát trước' else '' end, '/kho/cap-phat');
end $$;

-- ---------------------------------------------------------------------------
-- View lệnh ngày: kèm phiếu lĩnh Kho đã tạo
-- ---------------------------------------------------------------------------
create or replace view app.v_kh_releases with (security_invoker = true) as
select r.id, r.plan_id, r.work_date, r.revision, r.version_id, r.note, r.checks, r.released_at, r.released_by,
       app.user_name(r.released_by) as released_by_name,
       s.id as slip_id, s.slip_no, s.lines as slip_lines, s.status as slip_status, s.approved_at,
       app.user_name(s.approved_by) as approved_by_name,
       (select coalesce(jsonb_agg(jsonb_build_object('id', rq.id, 'req_no', rq.req_no, 'status', rq.status, 'wo_no', wo.wo_no,
                                                     'product_code', p.code) order by rq.req_no), '[]')
          from inv.requisitions rq join mfg.work_orders wo on wo.id = rq.wo_id join master.products p on p.id = wo.product_id
         where rq.slip_id = s.id) as requisitions
from plan.daily_releases r left join plan.issue_slips s on s.release_id = r.id;

revoke execute on function plan.day_work(uuid, date), plan.day_materials(uuid, date), plan.ensure_wo(uuid, date) from public, anon, authenticated;
revoke execute on function app.kh_day_preview(uuid, date), app.kh_release_day(uuid, date, text, jsonb, jsonb), app.kh_approve_slip(uuid) from public, anon;
grant execute on function app.kh_day_preview(uuid, date), app.kh_release_day(uuid, date, text, jsonb, jsonb), app.kh_approve_slip(uuid) to authenticated, service_role;
grant select on app.v_kh_releases to authenticated, service_role;
