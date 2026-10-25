-- BMT MES · 2300 · Module Kho (phần 2): nghiệp vụ kho theo Quy chuẩn vai trò nhân sự BMT
--   Phiếu lĩnh theo định mức · cấp/trả bằng quét QR + cân · nhận hàng · QC giải phóng lô · chuyển vị trí · tách bobin ·
--   hạ cấp · hàng trả lại · tồn đầu kỳ · phế · bán phế · lệnh giao hàng · kiểm kê · hậu kiểm Kế toán SX · phiếu đảo ·
--   ghi đầu ra sản xuất tự sinh phiếu kho · cảnh báo hằng ngày

-- ===========================================================================
-- 0. Tiện ích
-- ===========================================================================
-- Ngoài khung giờ mở kho NVL (cài đặt issue_hours, dạng "06:30-08:00,16:30-17:30")
create or replace function inv.outside_hours() returns boolean
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v text; w text; v_now time := (now() at time zone 'Asia/Ho_Chi_Minh')::time;
begin
  select nullif(trim(s.text_value), '') into v from inv.settings s where s.key = 'issue_hours';
  if v is null then return false; end if;
  foreach w in array string_to_array(replace(v, ' ', ''), ',') loop
    if w ~ '^\d{1,2}:\d{2}-\d{1,2}:\d{2}$' and v_now between split_part(w, '-', 1)::time and split_part(w, '-', 2)::time then
      return false;
    end if;
  end loop;
  return true;
end $$;

create or replace function inv.hu_type_for(p_group text) returns text
language sql immutable as $$
  select case p_group when 'CONDUCTOR' then 'REEL' when 'TAPE_FILLER' then 'REEL'
                      when 'COMPOUND' then 'BAG' when 'COLOR' then 'BAG' when 'ADDITIVE' then 'DRUM' else 'OTHER' end
$$;

-- Tồn khả dụng của một đơn vị chứa (đã trừ hàng giữ)
create or replace function inv.hu_available(p_hu uuid) returns numeric
language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce(sum(b.qty - b.reserved_qty), 0) from inv.stock_balances b where b.hu_key = p_hu
$$;

-- Lô phế theo mã phế và ngày (một bao/ngày), vị trí theo loại phế
create or replace function inv.scrap_lot(p_material uuid, p_date date) returns table (lot_id uuid, hu_id uuid, loc_id uuid)
language plpgsql security definer set search_path = pg_catalog, public as $$
declare m master.materials; v_no text; v_loc uuid;
begin
  select * into m from master.materials where id = p_material;
  if not found or not m.is_scrap then raise exception 'Mã % không phải mã phế liệu', coalesce(m.code, '?'); end if;
  v_loc := inv.loc(case when m.code in ('PL-CU','PL-TC') then 'KPL-CU' when m.code = 'PL-CABLE' then 'KPL-CAP' else 'KPL-NH' end);
  v_no := m.code || '-' || to_char(p_date, 'YYMMDD');
  select l.id into lot_id from inv.lots l where l.lot_no = v_no;
  if lot_id is null then
    insert into inv.lots (lot_no, item_kind, material_id, uom, qc_status, mfg_date)
    values (v_no, 'SCRAP', p_material, 'kg', 'PASSED', p_date) returning id into lot_id;
  end if;
  select h.id into hu_id from inv.handling_units h where h.lot_id = scrap_lot.lot_id order by h.hu_no limit 1;
  if hu_id is null then hu_id := inv.new_hu(lot_id, 'BAG', 0, inv.wh('KPL'), v_loc); end if;
  loc_id := v_loc;
  return next;
end $$;

-- ===========================================================================
-- 1. Phiếu lĩnh theo định mức (Quy chuẩn: MES tự tạo từ lệnh sản xuất; Quản lý SX không tự ghi số lượng)
-- ===========================================================================
-- Định mức cho p_qty_m mét của lệnh: BOM × cơ sở tính / (1 − hao hụt) + phế khởi động (chỉ phiếu lĩnh đầu tiên)
create or replace function inv.norm_for_wo(p_wo uuid, p_qty_m numeric, p_first boolean)
returns table (material_id uuid, qty numeric)
language sql stable security definer set search_path = pg_catalog, public as $$
  with w as (
    select wo.*, ceil(p_qty_m / wo.m_per_pack) as packs, s.param_set_id
    from mfg.work_orders wo join master.product_specs s on s.id = wo.spec_id where wo.id = p_wo
  ), b as (
    select bl.material_id,
           bl.qty_per_basis * case bl.basis
             when 'KM' then p_qty_m / 1000
             when 'PACK' then w.packs
             when 'PALLET' then ceil(w.packs / case when w.pack_type = 'Bobin gỗ' then master.param(w.param_set_id, 'palletW')
                                                    else master.param(w.param_set_id, 'palletC') end)
             else case when p_first then w.run_lots else 0 end end / (1 - bl.loss_rate)
           + case when p_first then bl.startup_per_lot * w.run_lots else 0 end as q
    from master.bom_lines bl, w where bl.bom_id = w.bom_id
  )
  select b.material_id, round(sum(b.q), 3) from b group by b.material_id having round(sum(b.q), 3) > 0
$$;

create or replace function inv.can_plan_issue() returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select core.has_role('SX_TP') or core.has_role('TO_TRUONG') or core.has_role('SX_KH')
$$;

create or replace function inv.create_requisition(p_wo uuid, p_qty_m numeric, p_work_date date default null, p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare w mfg.work_orders; v_done numeric; v_first boolean; v_id uuid; v_no text;
begin
  if not inv.can_plan_issue() then raise exception 'Chỉ Quản lý SX / Kế hoạch SX lập phiếu lĩnh'; end if;
  select * into w from mfg.work_orders where id = p_wo for update;
  if not found then raise exception 'Không tìm thấy lệnh sản xuất'; end if;
  if w.status not in ('RELEASED', 'IN_PROGRESS') then raise exception 'Lệnh % chưa phát lệnh hoặc đã đóng (%)', w.wo_no, w.status; end if;
  if coalesce(p_qty_m, 0) <= 0 then raise exception 'Nhập số mét sản xuất của ca/ngày'; end if;
  select coalesce(sum(r.qty_m), 0) into v_done from inv.requisitions r where r.wo_id = p_wo and r.kind = 'NORM' and r.status <> 'CANCELLED';
  if v_done + p_qty_m > w.qty_m then
    raise exception 'Lệnh % chỉ còn % m chưa lĩnh (đã lĩnh % m): phần vượt dùng phiếu lĩnh bổ sung', w.wo_no, w.qty_m - v_done, v_done;
  end if;
  v_first := not exists (select 1 from inv.requisitions r where r.wo_id = p_wo and r.kind = 'NORM' and r.status <> 'CANCELLED');
  v_no := core.next_no('PL');
  insert into inv.requisitions (req_no, wo_id, kind, work_date, qty_m, status, note)
  values (v_no, p_wo, 'NORM', coalesce(p_work_date, (now() at time zone 'Asia/Ho_Chi_Minh')::date), p_qty_m, 'APPROVED', p_note)
  returning id into v_id;
  insert into inv.requisition_lines (req_id, material_id, qty_norm, qty_req)
  select v_id, n.material_id, n.qty, n.qty from inv.norm_for_wo(p_wo, p_qty_m, v_first) n;
  if not exists (select 1 from inv.requisition_lines where req_id = v_id) then raise exception 'Lệnh % chưa có BOM', w.wo_no; end if;
  perform wf.notify_users(inv.role_users(array['THU_KHO']), 'Phiếu lĩnh mới: ' || v_no,
    format('Lệnh %s · %s m · ngày %s', w.wo_no, p_qty_m, to_char(coalesce(p_work_date, current_date), 'DD/MM')), '/kho/cap-phat/' || v_id);
  return v_id;
end $$;

-- Lĩnh bổ sung vượt định mức: TP Kỹ thuật/QA duyệt trên MES (Quy chuẩn mục 2, mục 9)
create or replace function inv.create_extra_requisition(p_wo uuid, p_lines jsonb, p_reason text, p_note text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare w mfg.work_orders; v_id uuid; v_no text; e jsonb; m master.materials; v_qty numeric; v_sum text;
begin
  if not inv.can_plan_issue() then raise exception 'Chỉ Quản lý SX / Kế hoạch SX lập phiếu lĩnh bổ sung'; end if;
  select * into w from mfg.work_orders where id = p_wo;
  if not found or w.status not in ('RELEASED', 'IN_PROGRESS') then raise exception 'Lệnh sản xuất chưa phát lệnh hoặc đã đóng'; end if;
  if not exists (select 1 from master.reason_codes rc where rc.code = p_reason and rc.kind = 'EXTRA_ISSUE') then
    raise exception 'Chọn nguyên nhân lĩnh bổ sung';
  end if;
  if coalesce(jsonb_array_length(p_lines), 0) = 0 then raise exception 'Nhập ít nhất một vật tư'; end if;
  v_no := core.next_no('PLB');
  insert into inv.requisitions (req_no, wo_id, kind, status, reason_code, note)
  values (v_no, p_wo, 'EXTRA', 'DRAFT', p_reason, nullif(trim(coalesce(p_note, '')), '')) returning id into v_id;
  for e in select * from jsonb_array_elements(p_lines) loop
    select * into m from master.materials where code = upper(trim(e ->> 'material_code')) and not is_scrap;
    if not found then raise exception 'Không có mã vật tư %', e ->> 'material_code'; end if;
    v_qty := (e ->> 'qty')::numeric;
    if coalesce(v_qty, 0) <= 0 then raise exception 'Số lượng % phải > 0', m.code; end if;
    insert into inv.requisition_lines (req_id, material_id, qty_norm, qty_req) values (v_id, m.id, 0, v_qty)
    on conflict (req_id, material_id) do update set qty_req = inv.requisition_lines.qty_req + excluded.qty_req;
  end loop;
  select string_agg(m2.code || ' ' || rl.qty_req || ' ' || m2.uom, ', ') into v_sum
    from inv.requisition_lines rl join master.materials m2 on m2.id = rl.material_id where rl.req_id = v_id;
  perform wf.submit('EXTRA_ISSUE', v_id, v_no, format('Lệnh %s – %s – %s', w.wo_no, v_sum,
    (select rc.name from master.reason_codes rc where rc.code = p_reason)));
  return v_id;
end $$;

create or replace function inv.cancel_requisition(p_req uuid, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r inv.requisitions;
begin
  if not inv.can_plan_issue() then raise exception 'Chỉ Quản lý SX / Kế hoạch SX hủy phiếu lĩnh'; end if;
  select * into r from inv.requisitions where id = p_req for update;
  if r.status in ('DONE', 'CANCELLED') then raise exception 'Phiếu lĩnh đã đóng'; end if;
  if exists (select 1 from inv.requisition_lines where req_id = p_req and qty_issued > 0) then
    raise exception 'Phiếu lĩnh đã xuất một phần: trả NVL thừa về kho thay vì hủy';
  end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do hủy'; end if;
  update inv.requisitions set status = 'CANCELLED', note = concat_ws(' · ', note, 'Hủy: ' || trim(p_reason)) where id = p_req;
end $$;

-- ===========================================================================
-- 2. Cấp NVL theo phiếu lĩnh: quét QR, gợi ý FEFO/FIFO, không vượt phiếu lĩnh, NV vận hành nhận tại máy
-- p_items: [{"hu_id": "...", "qty": 12.5 (để trống = cả đơn vị), "weight_kg": 12.5, "reason": "lý do đổi lô"}]
-- ===========================================================================
create or replace function inv.issue_pick(p_req uuid, p_items jsonb, p_receiver uuid, p_witness uuid default null,
                                         p_off_hours_reason text default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  r inv.requisitions; w mfg.work_orders; v_wh uuid := inv.wh('KNL'); v_del boolean; v_doc uuid; v_no text;
  e jsonb; h record; v_qty numeric; v_avail numeric; v_line int := 0; v_first text; c record;
begin
  select * into r from inv.requisitions where id = p_req for update;
  if not found then raise exception 'Không tìm thấy phiếu lĩnh'; end if;
  if r.status not in ('APPROVED', 'PARTIAL') then raise exception 'Phiếu lĩnh % chưa được duyệt hoặc đã đóng (%)', r.req_no, r.status; end if;
  select * into w from mfg.work_orders where id = r.wo_id;
  v_del := inv.require_keeper(v_wh, p_witness);
  if p_receiver is null or p_receiver = auth.uid() then
    raise exception 'Chọn công nhân nhận hàng tại máy (người nhận khác người xuất kho)';
  end if;
  if not exists (select 1 from core.user_roles ur join core.profiles p on p.id = ur.user_id and p.status = 'ACTIVE'
                 where ur.user_id = p_receiver and ur.role_code in ('VAN_HANH', 'TO_TRUONG')) then
    raise exception 'Người nhận phải là công nhân vận hành';
  end if;
  if inv.outside_hours() and coalesce(trim(p_off_hours_reason), '') = '' then
    raise exception 'Ngoài giờ mở kho NVL: nhập lý do xuất';
  end if;
  if coalesce(jsonb_array_length(p_items), 0) = 0 then raise exception 'Quét ít nhất một đơn vị chứa'; end if;

  v_no := core.next_no('XK');
  insert into inv.stock_docs (doc_no, doc_type, warehouse_id, ref_type, ref_id, requisition_id, receiver_id, witness_id,
                              delegated, off_hours_reason, note)
  values (v_no, 'ISSUE_WO', v_wh, 'WO', r.wo_id, p_req, p_receiver, p_witness, v_del, nullif(trim(coalesce(p_off_hours_reason, '')), ''),
          'Theo phiếu lĩnh ' || r.req_no || ' · lệnh ' || w.wo_no)
  returning id into v_doc;

  create temp table if not exists _pick (material_id uuid, qty numeric) on commit drop;
  delete from _pick;
  for e in select * from jsonb_array_elements(p_items) loop
    select hu.*, lt.material_id, lt.qc_status, lt.exp_date, lt.lot_no, lt.item_kind, lt.mfg_date, m.code as mcode
      into h
      from inv.handling_units hu join inv.lots lt on lt.id = hu.lot_id left join master.materials m on m.id = lt.material_id
     where hu.id = (e ->> 'hu_id')::uuid;
    if not found then raise exception 'Không tìm thấy mã QR %', e ->> 'hu_id'; end if;
    if h.status <> 'ACTIVE' or h.warehouse_id is distinct from v_wh then raise exception '% không còn trong kho NVL', h.hu_no; end if;
    if h.item_kind <> 'MAT' then raise exception '% không phải nguyên vật liệu', h.hu_no; end if;
    if not exists (select 1 from inv.requisition_lines rl where rl.req_id = p_req and rl.material_id = h.material_id) then
      raise exception '% là mã %: không có trong phiếu lĩnh %', h.hu_no, h.mcode, r.req_no;
    end if;
    if h.qc_status <> 'PASSED' then raise exception '% (lô %) chưa đạt QC: không được cấp', h.hu_no, h.lot_no; end if;
    if h.exp_date is not null and h.exp_date < current_date then raise exception '% đã hết hạn dùng', h.hu_no; end if;
    if exists (select 1 from inv.stock_doc_lines dl where dl.doc_id = v_doc and dl.hu_id = h.id) then
      raise exception 'Quét trùng %', h.hu_no;
    end if;
    v_avail := inv.hu_available(h.id);
    v_qty := coalesce(nullif(e ->> 'qty', '')::numeric, v_avail);
    if v_qty <= 0 or v_qty > v_avail then raise exception '% chỉ còn % có thể xuất', h.hu_no, v_avail; end if;
    -- FEFO (có hạn dùng) / FIFO (theo ngày nhập): đơn vị khác cùng mã đáng ra xuất trước
    select hu2.hu_no into v_first
      from inv.handling_units hu2 join inv.lots l2 on l2.id = hu2.lot_id
     where l2.material_id = h.material_id and hu2.status = 'ACTIVE' and hu2.warehouse_id = v_wh and hu2.id <> h.id
       and l2.qc_status = 'PASSED' and (l2.exp_date is null or l2.exp_date >= current_date)
       and inv.hu_available(hu2.id) > 0
       and not exists (select 1 from jsonb_array_elements(p_items) x where (x ->> 'hu_id')::uuid = hu2.id)
       and (coalesce(l2.exp_date, 'infinity'::date), l2.created_at) < (coalesce(h.exp_date, 'infinity'::date),
            (select l3.created_at from inv.lots l3 where l3.id = h.lot_id))
     order by l2.exp_date nulls last, l2.created_at limit 1;
    if v_first is not null and coalesce(trim(e ->> 'reason'), '') = '' then
      raise exception '% nên xuất trước % (hạn dùng/ngày nhập sớm hơn): quét đúng hoặc ghi lý do đổi lô', v_first, h.hu_no;
    end if;
    v_line := v_line + 1;
    insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty, weight_kg, reason)
    values (v_doc, v_line, h.lot_id, h.location_id, h.id, v_qty, nullif(e ->> 'weight_kg', '')::numeric,
            nullif(trim(coalesce(e ->> 'reason', '')), ''));
    insert into _pick values (h.material_id, v_qty);
  end loop;

  -- Không xuất vượt phiếu lĩnh: chỉ được dư một đơn vị không chia được (dư trả kho cuối ca)
  for c in select p.material_id, sum(p.qty) as s, min(p.qty) as mn, rl.qty_req, rl.qty_issued - rl.qty_returned as net, m.code, m.uom
           from _pick p join inv.requisition_lines rl on rl.req_id = p_req and rl.material_id = p.material_id
           join master.materials m on m.id = p.material_id
           group by p.material_id, rl.qty_req, rl.qty_issued, rl.qty_returned, m.code, m.uom loop
    if c.net + c.s - c.mn >= c.qty_req then
      raise exception '% xuất vượt phiếu lĩnh (cần %, đã xuất %, lần này %): bỏ bớt đơn vị hoặc lập phiếu lĩnh bổ sung',
        c.code, c.qty_req, c.net, c.s;
    end if;
    update inv.requisition_lines set qty_issued = qty_issued + c.s where req_id = p_req and material_id = c.material_id;
  end loop;

  perform inv._post(v_doc);
  update inv.requisitions rq set status = case when not exists (
           select 1 from inv.requisition_lines rl where rl.req_id = p_req and rl.qty_issued - rl.qty_returned < rl.qty_req) then 'DONE' else 'PARTIAL' end
   where rq.id = p_req;
  update mfg.work_orders set status = 'IN_PROGRESS' where id = r.wo_id and status = 'RELEASED';
  perform wf.notify_users(array[p_receiver], 'Nhận NVL tại máy: ' || v_no, 'Lệnh ' || w.wo_no || ' – kiểm tra và bấm Xác nhận đã nhận', '/kho/nhan-nvl');
  return v_doc;
end $$;

-- Công nhân xác nhận đã nhận NVL tại máy
create or replace function inv.confirm_issue(p_doc uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare d inv.stock_docs;
begin
  select * into d from inv.stock_docs where id = p_doc for update;
  if not found or d.doc_type <> 'ISSUE_WO' or d.status <> 'POSTED' then raise exception 'Không có phiếu xuất này'; end if;
  if d.receiver_id is distinct from auth.uid() then raise exception 'Chỉ người được giao nhận hàng mới xác nhận'; end if;
  if d.received_at is not null then raise exception 'Đã xác nhận lúc %', to_char(d.received_at at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM'); end if;
  update inv.stock_docs set received_at = now() where id = p_doc;
end $$;

-- Trả NVL thừa cuối ca: quét QR đơn vị đã cấp, nhập kg cân lại (về đúng lô cũ)
create or replace function inv.return_hu(p_hu uuid, p_qty numeric, p_location uuid default null, p_witness uuid default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare h record; v_wh uuid := inv.wh('KNL'); v_del boolean; v_last inv.stock_docs; v_out numeric; v_back numeric; v_doc uuid; v_loc uuid;
begin
  select hu.*, lt.item_kind, lt.material_id, lt.lot_no into h from inv.handling_units hu join inv.lots lt on lt.id = hu.lot_id where hu.id = p_hu;
  if not found then raise exception 'Không tìm thấy mã QR'; end if;
  if h.item_kind <> 'MAT' then raise exception '% không phải nguyên vật liệu', h.hu_no; end if;
  v_del := inv.require_keeper(v_wh, p_witness);
  if coalesce(p_qty, 0) <= 0 then raise exception 'Nhập số lượng trả (kg cân lại)'; end if;
  select d.* into v_last from inv.stock_moves sm join inv.stock_docs d on d.id = sm.doc_id
   where sm.hu_id = p_hu and d.doc_type = 'ISSUE_WO' and d.reversal_of is null and d.reversed_by is null
   order by sm.moved_at desc limit 1;
  if v_last.id is null then raise exception '% chưa được cấp cho lệnh sản xuất nào', h.hu_no; end if;
  select coalesce(-sum(sm.qty) filter (where d.doc_type = 'ISSUE_WO'), 0), coalesce(sum(sm.qty) filter (where d.doc_type = 'RETURN_WO'), 0)
    into v_out, v_back
    from inv.stock_moves sm join inv.stock_docs d on d.id = sm.doc_id
   where sm.hu_id = p_hu and d.ref_type = 'WO' and d.ref_id = v_last.ref_id and d.doc_type in ('ISSUE_WO', 'RETURN_WO');
  if p_qty > v_out - v_back then
    raise exception '% chỉ được trả tối đa % (đã cấp %, đã trả %)', h.hu_no, v_out - v_back, v_out, v_back;
  end if;
  v_loc := coalesce(p_location, (select l.location_id from inv.stock_doc_lines l where l.doc_id = v_last.id and l.hu_id = p_hu limit 1));
  if v_loc is not null and (select l.warehouse_id from inv.locations l where l.id = v_loc) <> v_wh then
    raise exception 'Vị trí trả phải thuộc kho NVL';
  end if;
  insert into inv.stock_docs (doc_no, doc_type, warehouse_id, ref_type, ref_id, requisition_id, witness_id, delegated, note)
  values (core.next_no('TK'), 'RETURN_WO', v_wh, 'WO', v_last.ref_id, v_last.requisition_id, p_witness, v_del,
          'Trả thừa từ ' || v_last.doc_no) returning id into v_doc;
  insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty, weight_kg)
  values (v_doc, 1, h.lot_id, v_loc, p_hu, p_qty, p_qty);
  perform inv._post(v_doc);
  if v_last.requisition_id is not null then
    update inv.requisition_lines set qty_returned = qty_returned + p_qty
     where req_id = v_last.requisition_id and material_id = h.material_id;
    update inv.requisitions rq set status = 'PARTIAL'
     where rq.id = v_last.requisition_id and rq.status = 'DONE'
       and exists (select 1 from inv.requisition_lines rl where rl.req_id = rq.id and rl.qty_issued - rl.qty_returned < rl.qty_req);
  end if;
  return v_doc;
end $$;

-- ===========================================================================
-- 3. Nhận hàng mua: Quản lý SX ký nhận, NV4 cân, NV mua hàng đối chiếu PO, TP Kỹ thuật/QA kiểm tra
-- p_lines: [{"po_line_id": "...", "material_code": "CU-024", "supplier_lot": "...", "mfg_date": "2026-10-01",
--            "exp_date": null, "location_id": null, "coa_density": null, "package_type_id": null,
--            "units": [{"gross_kg": 152.4, "tare_kg": 12.4} | {"qty": 25}]}]
-- ===========================================================================
create or replace function inv.receive_goods(p_po uuid, p_supplier uuid, p_no_po_reason text, p_delivery_note text, p_lines jsonb)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  po purchase.purchase_orders; v_wh uuid := inv.wh('KNL'); v_gr uuid; v_doc uuid; v_no text; v_sup uuid;
  e jsonb; u jsonb; m master.materials; pol purchase.po_lines; v_lot uuid; v_grl uuid; v_hu uuid; v_qty numeric; v_tare numeric;
  v_line int := 0; v_total numeric; v_tol numeric; v_pkg master.package_types; v_loc uuid; v_priced boolean := true; v_exp date;
  v_lots text := '';
begin
  perform inv.require_keeper(v_wh, null);
  if p_po is not null then
    select * into po from purchase.purchase_orders where id = p_po for update;
    if not found then raise exception 'Không tìm thấy PO'; end if;
    if po.status not in ('APPROVED', 'SENT', 'PARTIAL_RECEIVED') then raise exception 'PO % chưa duyệt hoặc đã đóng (%)', po.po_no, po.status; end if;
    v_sup := po.supplier_id;
  else
    if p_supplier is null then raise exception 'Chọn nhà cung cấp'; end if;
    if coalesce(trim(p_no_po_reason), '') = '' then raise exception 'Nhận hàng không theo PO: nhập lý do (hàng mẫu, chạy thử…)'; end if;
    v_sup := p_supplier;
  end if;
  if coalesce(jsonb_array_length(p_lines), 0) = 0 then raise exception 'Nhập ít nhất một dòng hàng'; end if;

  v_no := core.next_no('NH');
  insert into purchase.goods_receipts (gr_no, po_id, supplier_id, no_po_reason, delivery_note, status)
  values (v_no, p_po, v_sup, nullif(trim(coalesce(p_no_po_reason, '')), ''), nullif(trim(coalesce(p_delivery_note, '')), ''), 'DRAFT')
  returning id into v_gr;
  insert into inv.stock_docs (doc_no, doc_type, warehouse_id, ref_type, ref_id, note)
  values (v_no, 'GR', v_wh, 'GR', v_gr, case when p_po is null then 'Không theo PO: ' || trim(p_no_po_reason) else 'Theo ' || po.po_no end)
  returning id into v_doc;
  update purchase.goods_receipts set stock_doc_id = v_doc where id = v_gr;

  for e in select * from jsonb_array_elements(p_lines) loop
    pol := null;
    if nullif(e ->> 'po_line_id', '') is not null then
      select * into pol from purchase.po_lines where id = (e ->> 'po_line_id')::uuid and po_id = p_po for update;
      if not found then raise exception 'Dòng PO không thuộc PO đã chọn'; end if;
      select * into m from master.materials where id = pol.material_id;
    else
      if p_po is not null then raise exception 'Hàng theo PO: chọn dòng PO cho từng mã'; end if;
      select * into m from master.materials where code = upper(trim(e ->> 'material_code')) and not is_scrap;
      if not found then raise exception 'Không có mã vật tư %', e ->> 'material_code'; end if;
    end if;
    v_exp := nullif(e ->> 'exp_date', '')::date;
    if m.has_expiry and v_exp is null then raise exception '% có hạn dùng: bắt buộc nhập HSD (BR-MH-04)', m.code; end if;
    if v_exp is not null and v_exp <= current_date then raise exception '% đã hết hạn dùng: không nhận', m.code; end if;
    if coalesce(jsonb_array_length(e -> 'units'), 0) = 0 then raise exception '%: nhập số lượng từng ống/bao', m.code; end if;
    select * into v_pkg from master.package_types where id = nullif(e ->> 'package_type_id', '')::uuid;
    v_loc := coalesce(nullif(e ->> 'location_id', '')::uuid, inv.loc('KNL-QC'));
    if (select l.warehouse_id from inv.locations l where l.id = v_loc) <> v_wh then raise exception 'Vị trí nhận phải thuộc kho NVL'; end if;

    insert into inv.lots (lot_no, item_kind, material_id, uom, supplier_id, supplier_lot, qc_status, mfg_date, exp_date)
    values (core.next_no('NL'), 'MAT', m.id, m.uom, v_sup, nullif(trim(coalesce(e ->> 'supplier_lot', '')), ''), 'PENDING',
            nullif(e ->> 'mfg_date', '')::date, v_exp)
    returning id into v_lot;
    v_total := 0;
    for u in select * from jsonb_array_elements(e -> 'units') loop
      if nullif(u ->> 'gross_kg', '') is not null then
        if m.uom <> 'kg' then raise exception '% tính theo %: nhập số lượng, không nhập cân', m.code, m.uom; end if;
        v_tare := coalesce(nullif(u ->> 'tare_kg', '')::numeric, v_pkg.tare_kg, 0);
        v_qty := (u ->> 'gross_kg')::numeric - v_tare;
      else
        v_tare := null;
        v_qty := nullif(u ->> 'qty', '')::numeric;
      end if;
      if coalesce(v_qty, 0) <= 0 then raise exception '%: số lượng mỗi đơn vị phải > 0 (cân tổng phải lớn hơn bì)', m.code; end if;
      v_hu := inv.new_hu(v_lot, inv.hu_type_for(m.group_code), v_qty, v_wh, v_loc,
                         nullif(u ->> 'gross_kg', '')::numeric, v_tare, v_pkg.id);
      v_line := v_line + 1;
      insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty, gross_kg, tare_kg, weight_kg, unit_cost)
      values (v_doc, v_line, v_lot, v_loc, v_hu, v_qty, nullif(u ->> 'gross_kg', '')::numeric, v_tare,
              case when m.uom = 'kg' then v_qty end, pol.unit_price);
      v_total := v_total + v_qty;
    end loop;
    if pol.id is not null then
      select coalesce(ms.receive_tolerance, 0.05) into v_tol from master.material_suppliers ms
       where ms.material_id = m.id and (ms.supplier_id = v_sup or ms.supplier_id is null)
       order by (ms.supplier_id = v_sup) desc nulls last limit 1;
      if pol.received_qty + v_total > pol.qty * (1 + coalesce(v_tol, 0.05)) then
        raise exception '% nhận vượt PO quá dung sai % %% (PO %, đã nhận %, lần này %): báo NV mua hàng để Giám đốc điều chỉnh PO',
          m.code, round(coalesce(v_tol, 0.05) * 100, 1), pol.qty, pol.received_qty, v_total;
      end if;
      if pol.unit_price is null then v_priced := false; end if;
    else
      v_priced := false;
    end if;
    insert into purchase.gr_lines (gr_id, po_line_id, material_id, qty, supplier_lot, mfg_date, exp_date, coa_density, lot_id)
    values (v_gr, pol.id, m.id, v_total, nullif(trim(coalesce(e ->> 'supplier_lot', '')), ''), nullif(e ->> 'mfg_date', '')::date,
            v_exp, nullif(e ->> 'coa_density', '')::numeric, v_lot)
    returning id into v_grl;
    update inv.lots set gr_line_id = v_grl where id = v_lot;
    v_lots := v_lots || case when v_lots = '' then '' else ', ' end || m.code || ' ' || v_total || ' ' || m.uom;
  end loop;

  if v_priced then
    perform inv.receipt_finish(v_doc);
  else
    update inv.stock_docs set price_pending = true where id = v_doc;
    perform wf.notify_users(inv.role_users(array['KT_KHO']), 'Nhập giá phiếu nhập ' || v_no, v_lots, '/kho/phieu/' || v_doc);
  end if;
  perform wf.notify_users(inv.role_users(array['KT_TP', 'QC']), 'Lô chờ kiểm tra đầu vào: ' || v_no, v_lots, '/kho/qc');
  perform wf.notify_users(inv.role_users(array['MUA_NV']), 'Đối chiếu nhận hàng ' || v_no,
    coalesce(po.po_no || ': ', 'Không theo PO: ') || v_lots, '/kho/phieu/' || v_doc);
  return v_doc;
end $$;

-- Ghi sổ phiếu nhập đã đủ giá + cập nhật số đã nhận của PO
create or replace function inv.receipt_finish(p_doc uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare d inv.stock_docs; v_po uuid;
begin
  select * into d from inv.stock_docs where id = p_doc;
  perform inv._post(p_doc);
  update inv.stock_docs set price_pending = false where id = p_doc;
  update purchase.goods_receipts set status = 'POSTED' where id = d.ref_id returning po_id into v_po;
  if v_po is not null then
    update purchase.po_lines pl set received_qty = pl.received_qty + g.qty
      from purchase.gr_lines g where g.gr_id = d.ref_id and g.po_line_id = pl.id;
    update purchase.purchase_orders po set status = case
        when not exists (select 1 from purchase.po_lines pl where pl.po_id = po.id and pl.received_qty < pl.qty) then 'RECEIVED'
        else 'PARTIAL_RECEIVED' end
     where po.id = v_po;
  end if;
end $$;
revoke execute on function inv.receipt_finish(uuid) from public, anon, authenticated;

-- Kế toán SX nhập giá cho phiếu nhập không theo PO (hoặc PO chưa có giá), rồi ghi sổ. p_prices: {"<line_id>": 268000}
create or replace function inv.set_receipt_price(p_doc uuid, p_prices jsonb) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare d inv.stock_docs; k text;
begin
  if not core.has_role('KT_KHO') then raise exception 'Chỉ Kế toán SX nhập giá phiếu nhập'; end if;
  select * into d from inv.stock_docs where id = p_doc for update;
  if not found or d.doc_type <> 'GR' or d.status <> 'DRAFT' then raise exception 'Phiếu nhập không ở trạng thái chờ giá'; end if;
  for k in select jsonb_object_keys(p_prices) loop
    if (p_prices ->> k)::numeric is null or (p_prices ->> k)::numeric < 0 then raise exception 'Đơn giá không hợp lệ'; end if;
    update inv.stock_doc_lines set unit_cost = (p_prices ->> k)::numeric where id = k::uuid and doc_id = p_doc;
  end loop;
  -- Các đơn vị cùng lô dùng chung giá dòng đầu tiên đã nhập
  update inv.stock_doc_lines x set unit_cost = s.c from (
    select lot_id, max(unit_cost) as c from inv.stock_doc_lines where doc_id = p_doc group by lot_id) s
   where x.doc_id = p_doc and x.lot_id = s.lot_id and x.unit_cost is null and s.c is not null;
  if exists (select 1 from inv.stock_doc_lines where doc_id = p_doc and unit_cost is null) then
    raise exception 'Còn dòng chưa có giá';
  end if;
  perform inv.receipt_finish(p_doc);
  update inv.stock_docs set review_status = 'CONFIRMED', reviewed_by = auth.uid(), reviewed_at = now(),
         review_note = 'Kế toán SX nhập giá và ghi sổ' where id = p_doc;
end $$;

-- NV mua hàng đối chiếu nhận hàng với PO (Quy chuẩn mục 6)
create or replace function purchase.check_receipt(p_doc uuid, p_note text default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare d inv.stock_docs;
begin
  if not (core.has_role('MUA_NV') or core.has_role('MUA_TP')) then raise exception 'Chỉ NV mua hàng đối chiếu nhận hàng'; end if;
  select * into d from inv.stock_docs where id = p_doc and doc_type = 'GR';
  if not found then raise exception 'Không có phiếu nhập'; end if;
  update purchase.goods_receipts set checked_by = auth.uid(), checked_at = now(), check_note = nullif(trim(coalesce(p_note, '')), '')
   where id = d.ref_id;
end $$;

-- ===========================================================================
-- 4. Kiểm tra chất lượng, giải phóng lô (TP Kỹ thuật/QA quyết định nhận hay trả)
-- p_result: PASS | FAIL (cách ly + NCR) | REJECT (không nhận, chờ trả NCC/hủy — chỉ TP Kỹ thuật/QA)
-- ===========================================================================
create or replace function qa.release_lot(p_lot uuid, p_result text, p_note text, p_tests jsonb default '[]') returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare lt inv.lots; v_insp uuid; v_type text; t jsonb; v_new text; v_ncr text; v_code text;
begin
  if not core.has_perm('quality', 'edit') then raise exception 'Không có quyền kiểm tra chất lượng'; end if;
  select * into lt from inv.lots where id = p_lot for update;
  if not found then raise exception 'Không tìm thấy lô'; end if;
  if p_result not in ('PASS', 'FAIL', 'REJECT') then raise exception 'Kết quả không hợp lệ'; end if;
  if lt.qc_status not in ('PENDING', 'QUARANTINE') then raise exception 'Lô % đang ở trạng thái %, không cần kiểm tra', lt.lot_no, lt.qc_status; end if;
  if lt.qc_status = 'QUARANTINE' and not core.has_role('KT_TP') then
    raise exception 'Lô đang cách ly: chỉ TP Kỹ thuật/QA quyết định nhận hoặc trả';
  end if;
  if p_result = 'REJECT' and not core.has_role('KT_TP') then raise exception 'Chỉ TP Kỹ thuật/QA quyết định không nhận lô'; end if;
  if p_result <> 'PASS' and coalesce(trim(p_note), '') = '' then raise exception 'Ghi lỗi phát hiện để lập NCR'; end if;
  v_type := case lt.item_kind when 'MAT' then 'IQC' when 'FG' then 'FQC' else 'IPQC' end;
  insert into qa.inspections (insp_no, insp_type, lot_id, spec_id, result, inspected_at, note)
  values (core.next_no('KT'), v_type, p_lot, lt.spec_id, case when p_result = 'PASS' then 'PASS' else 'FAIL' end, now(),
          nullif(trim(coalesce(p_note, '')), ''))
  returning id into v_insp;
  for t in select * from jsonb_array_elements(coalesce(p_tests, '[]')) loop
    continue when coalesce(t ->> 'test_code', '') = '';
    insert into qa.test_results (inspection_id, test_code, value_num, value_text, unit, limit_min, limit_max, pass)
    values (v_insp, t ->> 'test_code', nullif(t ->> 'value_num', '')::numeric, nullif(t ->> 'value_text', ''), nullif(t ->> 'unit', ''),
            nullif(t ->> 'limit_min', '')::numeric, nullif(t ->> 'limit_max', '')::numeric, (t ->> 'pass')::boolean);
  end loop;
  v_new := case p_result when 'PASS' then 'PASSED' when 'FAIL' then 'QUARANTINE' else 'REJECTED' end;
  -- Lô đã cấp hết trước khi đánh giá lại: trạng thái theo tồn
  if v_new = 'PASSED' and exists (select 1 from inv.stock_moves sm where sm.lot_id = p_lot)
     and not exists (select 1 from inv.stock_balances b where b.lot_id = p_lot and b.qty > 0) then v_new := 'CONSUMED'; end if;
  update inv.lots set qc_status = v_new where id = p_lot;
  if p_result <> 'PASS' and not exists (select 1 from qa.ncrs n where n.lot_id = p_lot and n.status in ('OPEN', 'PENDING_APPROVAL')) then
    v_ncr := core.next_no('NCR');
    insert into qa.ncrs (ncr_no, lot_id, inspection_id, description, status) values (v_ncr, p_lot, v_insp, trim(p_note), 'OPEN');
  end if;
  if p_result = 'PASS' then
    update qa.ncrs set status = 'CLOSED', disposition = coalesce(disposition, 'USE_AS_IS') where lot_id = p_lot and status = 'OPEN';
  end if;
  select coalesce(m.code, p.code) into v_code from inv.lots l left join master.materials m on m.id = l.material_id
    left join master.products p on p.id = l.product_id where l.id = p_lot;
  perform wf.notify_users(inv.role_users(case when lt.item_kind = 'FG' then array['KHO_NV'] else array['THU_KHO'] end),
    case p_result when 'PASS' then 'Lô đạt: ' else 'Lô không đạt: ' end || lt.lot_no,
    v_code || case when p_result = 'PASS' then ' – cất vào vị trí lưu kho' else ' – chuyển khu cách ly. ' || trim(p_note) end, '/kho/ton?q=' || lt.lot_no);
  if p_result <> 'PASS' and lt.item_kind = 'MAT' then
    perform wf.notify_users(inv.role_users(array['MUA_NV']), 'Lô NVL không đạt: ' || lt.lot_no, v_code || ': ' || trim(p_note), '/kho/qc');
  end if;
  return v_insp;
end $$;

-- ===========================================================================
-- 5. Chuyển vị trí / chuyển kho bằng quét (BR-KHO: quét hàng + quét vị trí mới)
-- ===========================================================================
create or replace function inv.move_hu(p_hu uuid, p_to_location uuid, p_witness uuid default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare h inv.handling_units; v_to inv.locations; v_doc uuid; v_del boolean; v_qty numeric;
begin
  select * into h from inv.handling_units where id = p_hu;
  if not found or h.status <> 'ACTIVE' then raise exception 'Đơn vị chứa không còn hàng'; end if;
  select * into v_to from inv.locations where id = p_to_location and active;
  if not found then raise exception 'Không tìm thấy vị trí nhận'; end if;
  if h.location_id = v_to.id then raise exception '% đã ở vị trí %', h.hu_no, v_to.code; end if;
  v_del := inv.require_keeper(h.warehouse_id, p_witness);
  if v_to.warehouse_id <> h.warehouse_id then perform inv.require_keeper(v_to.warehouse_id, p_witness); end if;
  select coalesce(sum(b.qty), 0) into v_qty from inv.stock_balances b where b.hu_key = p_hu and b.warehouse_id = h.warehouse_id;
  insert into inv.stock_docs (doc_no, doc_type, warehouse_id, to_warehouse_id, witness_id, delegated, review_status, note)
  values (core.next_no('CK'), 'TRANSFER', h.warehouse_id, v_to.warehouse_id, p_witness, v_del,
          case when v_to.warehouse_id = h.warehouse_id then 'NA' else 'PENDING' end, h.hu_no || ' → ' || v_to.code)
  returning id into v_doc;
  insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, to_location_id, hu_id, qty)
  select v_doc, row_number() over (), b.lot_id, nullif(b.location_key, '00000000-0000-0000-0000-000000000000'), v_to.id, p_hu, b.qty
  from inv.stock_balances b where b.hu_key = p_hu and b.warehouse_id = h.warehouse_id and b.qty > 0;
  perform inv._post(v_doc);
  return v_doc;
end $$;

-- ===========================================================================
-- 6. Thành phẩm: cắt/tách bobin, đoạn lẻ, đổi mã/hạ cấp, hàng khách trả
-- ===========================================================================
create or replace function inv.remnant_min(p_product uuid) returns numeric
language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce((select p.min_remnant_m from master.products p where p.id = p_product), inv.setting('remnant_min_m'), 100)
$$;

-- Cắt bobin thành các đoạn (m); phần còn lại ở bobin cũ; phế cắt (m) nhập kho phế dạng cáp lỗi (kg)
create or replace function inv.split_hu(p_hu uuid, p_parts numeric[], p_scrap_m numeric default 0, p_reason text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare h record; v_doc uuid; v_sum numeric; v_rest numeric; v_i int := 0; v_new uuid; v_min numeric; v_kgkm numeric; s record; v_sdoc uuid;
begin
  select hu.*, lt.item_kind, lt.product_id, lt.spec_id, lt.lot_no into h from inv.handling_units hu join inv.lots lt on lt.id = hu.lot_id where hu.id = p_hu;
  if not found or h.status <> 'ACTIVE' then raise exception 'Đơn vị chứa không còn hàng'; end if;
  if h.item_kind <> 'FG' then raise exception 'Chỉ cắt/tách bobin thành phẩm'; end if;
  perform inv.require_keeper(h.warehouse_id, null);
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do cắt (đơn hàng, khách yêu cầu…)'; end if;
  if coalesce(array_length(p_parts, 1), 0) = 0 or exists (select 1 from unnest(p_parts) x where x is null or x <= 0) then
    raise exception 'Nhập độ dài các đoạn cắt (m), mỗi đoạn > 0';
  end if;
  if inv.hu_available(p_hu) < h.qty then raise exception '% đang được giữ cho đơn hàng: bỏ giữ trước khi cắt', h.hu_no; end if;
  select sum(x) into v_sum from unnest(p_parts) x;
  v_rest := h.qty - v_sum - coalesce(p_scrap_m, 0);
  if v_rest < 0 then raise exception '% chỉ có % m', h.hu_no, h.qty; end if;
  v_min := inv.remnant_min(h.product_id);
  insert into inv.stock_docs (doc_no, doc_type, warehouse_id, note) values (core.next_no('CB'), 'SPLIT', h.warehouse_id,
    h.hu_no || ': ' || array_to_string(p_parts, ' + ') || ' m' || case when p_scrap_m > 0 then ', phế cắt ' || p_scrap_m || ' m' else '' end || ' · ' || trim(p_reason))
  returning id into v_doc;
  insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty)
  values (v_doc, 1, h.lot_id, h.location_id, p_hu, -(v_sum + coalesce(p_scrap_m, 0)));
  foreach v_sum in array p_parts loop
    v_i := v_i + 1;
    v_new := inv.new_hu(h.lot_id, h.hu_type, v_sum, h.warehouse_id, h.location_id, null, null, null, p_hu);
    update inv.handling_units set is_remnant = v_sum < v_min where id = v_new;
    insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty) values (v_doc, v_i + 1, h.lot_id, h.location_id, v_new, v_sum);
  end loop;
  perform inv._post(v_doc);
  update inv.handling_units set is_remnant = v_rest > 0 and v_rest < v_min where id = p_hu;
  if coalesce(p_scrap_m, 0) > 0 then
    select r.total_kgkm into v_kgkm from master.spec_results r where r.spec_id = h.spec_id;
    select * into s from inv.scrap_lot((select id from master.materials where code = 'PL-CABLE'), current_date);
    insert into inv.stock_docs (doc_no, doc_type, warehouse_id, note)
    values (core.next_no('NP'), 'SCRAP_IN', inv.wh('KPL'), 'Phế cắt ' || p_scrap_m || ' m từ ' || h.hu_no) returning id into v_sdoc;
    insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty)
    values (v_sdoc, 1, s.lot_id, s.loc_id, s.hu_id, round(p_scrap_m * coalesce(v_kgkm, 0) / 1000, 3));
    if p_scrap_m * coalesce(v_kgkm, 0) > 0 then perform inv._post(v_sdoc); else delete from inv.stock_docs where id = v_sdoc; end if;
  end if;
  return v_doc;
end $$;

-- Đổi mã / hạ cấp / hủy theo NCR (TP Kỹ thuật/QA quyết định)
create or replace function inv.reclass_hu(p_hu uuid, p_to_scrap boolean, p_product uuid, p_brand text, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare h record; v_doc uuid; v_lot uuid; v_new uuid; v_spec uuid; v_kgkm numeric; s record; v_qty numeric;
begin
  if not core.has_role('KT_TP') then raise exception 'Chỉ TP Kỹ thuật/QA quyết định đổi mã, hạ cấp hoặc hủy'; end if;
  select hu.*, lt.item_kind, lt.product_id, lt.spec_id, lt.lot_no, lt.brand, lt.color, lt.wo_op_id into h
    from inv.handling_units hu join inv.lots lt on lt.id = hu.lot_id where hu.id = p_hu;
  if not found or h.status <> 'ACTIVE' then raise exception 'Đơn vị chứa không còn hàng'; end if;
  if h.item_kind not in ('FG', 'WIP') then raise exception 'Chỉ áp dụng cho cáp (BTP/TP)'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do (số NCR, lỗi)'; end if;
  if inv.hu_available(p_hu) < h.qty then raise exception '% đang được giữ cho đơn hàng', h.hu_no; end if;
  v_qty := h.qty;
  insert into inv.stock_docs (doc_no, doc_type, warehouse_id, note)
  values (core.next_no('DM'), 'RECLASS', h.warehouse_id, h.hu_no || case when p_to_scrap then ' → phế' else ' → mã khác' end || ' · ' || trim(p_reason))
  returning id into v_doc;
  insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty) values (v_doc, 1, h.lot_id, h.location_id, p_hu, -v_qty);
  if p_to_scrap then
    perform inv._post(v_doc);
    select r.total_kgkm into v_kgkm from master.spec_results r where r.spec_id = h.spec_id;
    select * into s from inv.scrap_lot((select id from master.materials where code = 'PL-CABLE'), current_date);
    v_doc := null;
    insert into inv.stock_docs (doc_no, doc_type, warehouse_id, note)
    values (core.next_no('NP'), 'SCRAP_IN', inv.wh('KPL'), 'Hủy ' || h.hu_no || ' (' || v_qty || ' m) · ' || trim(p_reason)) returning id into v_doc;
    insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty, note)
    values (v_doc, 1, s.lot_id, s.loc_id, s.hu_id, greatest(round(v_qty * coalesce(v_kgkm, 0) / 1000, 3), 0.001), h.hu_no);
    perform inv._post(v_doc);
  else
    select p.current_spec_id into v_spec from master.products p join master.product_specs s2 on s2.id = p.current_spec_id
     where p.id = p_product and s2.status = 'RELEASED';
    if v_spec is null then raise exception 'Mã đích chưa có spec đã phát hành'; end if;
    insert into inv.lots (lot_no, item_kind, product_id, spec_id, brand, color, uom, wo_op_id, qc_status, mfg_date, attrs)
    values (h.lot_no || '-R' || (select count(*) + 1 from inv.lots x where x.lot_no like h.lot_no || '-R%'), 'FG', p_product, v_spec,
            coalesce(p_brand, h.brand), h.color, 'm', h.wo_op_id, 'PASSED', current_date,
            jsonb_build_object('reclass_from', h.lot_no, 'reason', trim(p_reason)))
    returning id into v_lot;
    v_new := inv.new_hu(v_lot, h.hu_type, v_qty, h.warehouse_id, h.location_id, null, null, null, p_hu);
    insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty) values (v_doc, 2, v_lot, h.location_id, v_new, v_qty);
    perform inv._post(v_doc);
  end if;
  update qa.ncrs set status = 'CLOSED', disposition = case when p_to_scrap then 'SCRAP' else 'DOWNGRADE' end
   where lot_id = h.lot_id and status = 'OPEN';
  return v_doc;
end $$;

-- Hàng khách trả: nhập khu hàng trả về, trạng thái Cách ly chờ TP Kỹ thuật/QA đánh giá
create or replace function inv.customer_return(p_product uuid, p_brand text, p_qty_m numeric, p_so uuid, p_orig_hu uuid, p_note text)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_wh uuid := inv.wh('KTP'); v_lot uuid; v_hu uuid; v_doc uuid; v_spec uuid; v_code text;
begin
  perform inv.require_keeper(v_wh, null);
  if coalesce(p_qty_m, 0) <= 0 then raise exception 'Nhập số mét khách trả'; end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'Ghi lý do khách trả'; end if;
  select p.current_spec_id, p.code into v_spec, v_code from master.products p where p.id = p_product;
  if v_code is null then raise exception 'Chọn mã sản phẩm'; end if;
  if p_orig_hu is not null then
    select l.spec_id into v_spec from inv.handling_units h join inv.lots l on l.id = h.lot_id where h.id = p_orig_hu;
  end if;
  insert into inv.lots (lot_no, item_kind, product_id, spec_id, brand, uom, qc_status, mfg_date, attrs)
  values (core.next_no('TL'), 'FG', p_product, v_spec, coalesce(p_brand, 'KAVIX'), 'm', 'QUARANTINE', current_date,
          jsonb_build_object('customer_return', true, 'so_id', p_so, 'orig_hu', p_orig_hu, 'note', trim(p_note)))
  returning id into v_lot;
  v_hu := inv.new_hu(v_lot, 'REEL', p_qty_m, v_wh, inv.loc('KTP-RET'));
  insert into inv.stock_docs (doc_no, doc_type, warehouse_id, ref_type, ref_id, note)
  values (core.next_no('NTL'), 'CUST_RETURN', v_wh, case when p_so is not null then 'SO' end, p_so, trim(p_note)) returning id into v_doc;
  insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty) values (v_doc, 1, v_lot, inv.loc('KTP-RET'), v_hu, p_qty_m);
  perform inv._post(v_doc);
  insert into qa.ncrs (ncr_no, lot_id, description, status) values (core.next_no('NCR'), v_lot, 'Khách trả: ' || trim(p_note), 'OPEN');
  perform wf.notify_users(inv.role_users(array['KT_TP']), 'Hàng khách trả: ' || v_code, p_qty_m || ' m – ' || trim(p_note), '/kho/qc');
  return v_doc;
end $$;

-- ===========================================================================
-- 7. Tồn đầu kỳ (Kế toán SX lập, Kế toán trưởng duyệt)
-- p_lines: [{"code": "CU-024" | mã sản phẩm, "brand": "KAVIX", "qty": 150.5, "unit_cost": 268000, "location_code": "KNL-CU",
--            "supplier_lot": "...", "mfg_date": "...", "exp_date": "...", "units": 3}]
-- ===========================================================================
create or replace function inv.create_opening(p_warehouse uuid, p_doc_date date, p_lines jsonb) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare w inv.warehouses; v_doc uuid; v_no text; e jsonb; m master.materials; p master.products; v_lot uuid; v_hu uuid;
        v_loc uuid; v_line int := 0; v_units int; v_each numeric; i int;
begin
  if not core.has_role('KT_KHO') then raise exception 'Chỉ Kế toán SX lập tồn đầu kỳ'; end if;
  select * into w from inv.warehouses where id = p_warehouse;
  if not found then raise exception 'Chọn kho'; end if;
  if coalesce(jsonb_array_length(p_lines), 0) = 0 then raise exception 'Nhập ít nhất một dòng'; end if;
  v_no := core.next_no('TDK');
  insert into inv.stock_docs (doc_no, doc_type, warehouse_id, doc_date, note)
  values (v_no, 'OPENING', p_warehouse, coalesce(p_doc_date, current_date), 'Tồn đầu kỳ ' || w.code) returning id into v_doc;
  for e in select * from jsonb_array_elements(p_lines) loop
    v_loc := coalesce(inv.loc(upper(trim(coalesce(e ->> 'location_code', '')))), (select l.id from inv.locations l where l.warehouse_id = p_warehouse and l.kind = 'STORE' order by l.sort limit 1));
    if (select l.warehouse_id from inv.locations l where l.id = v_loc) <> p_warehouse then raise exception 'Vị trí % không thuộc kho %', e ->> 'location_code', w.code; end if;
    if coalesce((e ->> 'qty')::numeric, 0) <= 0 then raise exception 'Số lượng phải > 0 (%)', e ->> 'code'; end if;
    v_units := greatest(coalesce(nullif(e ->> 'units', '')::int, 1), 1);
    v_each := round((e ->> 'qty')::numeric / v_units, 4);
    if w.kind in ('MAT', 'SCRAP') then
      select * into m from master.materials where code = upper(trim(e ->> 'code'));
      if not found then raise exception 'Không có mã vật tư %', e ->> 'code'; end if;
      if w.kind = 'MAT' and (e ->> 'unit_cost') is null then raise exception '% thiếu đơn giá', m.code; end if;
      insert into inv.lots (lot_no, item_kind, material_id, uom, supplier_lot, qc_status, mfg_date, exp_date, attrs)
      values (core.next_no('DK'), case when w.kind = 'SCRAP' then 'SCRAP' else 'MAT' end, m.id, m.uom, nullif(e ->> 'supplier_lot', ''),
              'PASSED', nullif(e ->> 'mfg_date', '')::date, nullif(e ->> 'exp_date', '')::date, '{"opening": true}')
      returning id into v_lot;
    else
      select * into p from master.products where code = upper(trim(e ->> 'code'));
      if not found then raise exception 'Không có mã sản phẩm %', e ->> 'code'; end if;
      insert into inv.lots (lot_no, item_kind, product_id, spec_id, brand, uom, qc_status, mfg_date, wip_stage, attrs)
      values (core.next_no('DK'), case when w.kind = 'WIP' then 'WIP' else 'FG' end, p.id, p.current_spec_id,
              coalesce(nullif(e ->> 'brand', ''), p.default_brand, 'KAVIX'), 'm', 'PASSED', nullif(e ->> 'mfg_date', '')::date,
              nullif(e ->> 'stage', ''), '{"opening": true}')
      returning id into v_lot;
    end if;
    for i in 1 .. v_units loop
      v_hu := inv.new_hu(v_lot, case when w.kind in ('FG', 'WIP') then 'REEL' else 'OTHER' end,
                         case when i = v_units then (e ->> 'qty')::numeric - v_each * (v_units - 1) else v_each end, p_warehouse, v_loc);
      v_line := v_line + 1;
      insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty, unit_cost)
      values (v_doc, v_line, v_lot, v_loc, v_hu, (select qty from inv.handling_units where id = v_hu), nullif(e ->> 'unit_cost', '')::numeric);
    end loop;
  end loop;
  perform wf.submit('STOCK_OPEN', v_doc, v_no, format('Tồn đầu kỳ %s: %s dòng', w.code, jsonb_array_length(p_lines)));
  return v_doc;
end $$;

-- ===========================================================================
-- 8. Phế liệu theo lệnh SX (NV4 gom, cân; giá trị 0) và bán phế (Kế toán SX kiểm tra, Giám đốc duyệt)
-- ===========================================================================
create or replace function inv.record_scrap(p_wo uuid, p_op_code text, p_material_code text, p_qty_kg numeric, p_reason text,
                                            p_machine uuid default null, p_note text default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_op mfg.wo_operations; w mfg.work_orders; m master.materials; s record; v_rec uuid; v_doc uuid;
begin
  if not core.has_perm('production', 'create') then raise exception 'Không có quyền ghi phế'; end if;
  select * into w from mfg.work_orders where id = p_wo;
  if not found then raise exception 'Chọn lệnh sản xuất'; end if;
  select * into v_op from mfg.wo_operations where wo_id = p_wo and op_code = p_op_code;
  if not found then raise exception 'Lệnh % không có công đoạn %', w.wo_no, p_op_code; end if;
  select * into m from master.materials where code = p_material_code and is_scrap;
  if not found then raise exception 'Chọn mã phế liệu'; end if;
  if not exists (select 1 from master.reason_codes rc where rc.code = p_reason and rc.kind = 'SCRAP') then raise exception 'Chọn nguyên nhân phế'; end if;
  if coalesce(p_qty_kg, 0) <= 0 then raise exception 'Nhập số kg phế (cân)'; end if;
  insert into mfg.scrap_records (wo_op_id, scrap_material_id, reason_code, qty_kg, machine_id, operator_id)
  values (v_op.id, m.id, p_reason, p_qty_kg, coalesce(p_machine, v_op.machine_id), auth.uid()) returning id into v_rec;
  select * into s from inv.scrap_lot(m.id, current_date);
  insert into inv.stock_docs (doc_no, doc_type, warehouse_id, ref_type, ref_id, note)
  values (core.next_no('NP'), 'SCRAP_IN', inv.wh('KPL'), 'WO', p_wo,
          'Lệnh ' || w.wo_no || ' · ' || p_op_code || coalesce(' · ' || nullif(trim(p_note), ''), '')) returning id into v_doc;
  insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty, weight_kg, reason)
  values (v_doc, 1, s.lot_id, s.loc_id, s.hu_id, p_qty_kg, p_qty_kg, p_reason);
  perform inv._post(v_doc);
  update mfg.scrap_records set lot_id = s.lot_id where id = v_rec;
  return v_rec;
end $$;

-- p_items: [{"hu_id": "...", "qty": 120.5}]
create or replace function inv.create_scrap_sale(p_items jsonb, p_buyer text, p_note text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_wh uuid := inv.wh('KPL'); v_doc uuid; v_no text; e jsonb; h inv.handling_units; v_i int := 0; v_q numeric; v_sum numeric := 0;
begin
  perform inv.require_keeper(v_wh, null);
  if coalesce(trim(p_buyer), '') = '' then raise exception 'Nhập tên người mua phế'; end if;
  if coalesce(jsonb_array_length(p_items), 0) = 0 then raise exception 'Chọn bao phế cần bán'; end if;
  v_no := core.next_no('BP');
  insert into inv.stock_docs (doc_no, doc_type, warehouse_id, note)
  values (v_no, 'SCRAP_OUT', v_wh, 'Bán phế cho ' || trim(p_buyer) || coalesce(' · ' || nullif(trim(p_note), ''), '')) returning id into v_doc;
  for e in select * from jsonb_array_elements(p_items) loop
    select * into h from inv.handling_units where id = (e ->> 'hu_id')::uuid and warehouse_id = v_wh and status = 'ACTIVE';
    if not found then raise exception 'Bao phế không còn trong kho phế'; end if;
    v_q := coalesce(nullif(e ->> 'qty', '')::numeric, h.qty);
    if v_q <= 0 or v_q > h.qty then raise exception '% chỉ có % kg', h.hu_no, h.qty; end if;
    v_i := v_i + 1; v_sum := v_sum + v_q;
    insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty, weight_kg) values (v_doc, v_i, h.lot_id, h.location_id, h.id, v_q, v_q);
  end loop;
  perform wf.submit('SCRAP_OUT', v_doc, v_no, format('Bán %s kg phế cho %s', v_sum, trim(p_buyer)));
  return v_doc;
end $$;

-- ===========================================================================
-- 9. Giữ hàng theo bobin; lệnh giao hàng (NV5 lập → TP Kỹ thuật/QA xác nhận chất lượng → Giám đốc duyệt) → xuất
-- ===========================================================================
create or replace function sales.reserve_so(p_so uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare so sales.sales_orders; ln record; b record; v_need numeric; v_take numeric;
begin
  if not core.has_perm('sales', 'edit') then raise exception 'Không có quyền giữ hàng'; end if;
  select * into so from sales.sales_orders where id = p_so;
  if so.status <> 'APPROVED' then raise exception 'SO % chưa được duyệt', so.so_no; end if;
  for ln in select l.*, s.status as spec_status from sales.so_lines l left join master.product_specs s on s.id = l.spec_id
            where l.so_id = p_so and l.line_status in ('OPEN', 'PLANNED', 'WAITING_SPEC') order by l.line_no loop
    v_need := ln.qty_m - ln.reserved_m - ln.delivered_m;
    for b in select bal.*, l.lot_no from inv.stock_balances bal join inv.lots l on l.id = bal.lot_id
             join inv.warehouses w on w.id = bal.warehouse_id
             left join inv.handling_units hu on hu.id = bal.hu_key
             where w.kind = 'FG' and l.product_id = ln.product_id and l.brand = so.label_brand and l.qc_status = 'PASSED'
               and bal.qty - bal.reserved_qty > 0 and not coalesce(hu.is_remnant, false)
             order by l.mfg_date nulls last, l.lot_no, hu.hu_no for update of bal loop
      exit when v_need <= 0;
      v_take := least(v_need, b.qty - b.reserved_qty);
      update inv.stock_balances set reserved_qty = reserved_qty + v_take
       where warehouse_id = b.warehouse_id and location_key = b.location_key and lot_id = b.lot_id and hu_key = b.hu_key;
      insert into sales.so_reservations (so_line_id, lot_id, hu_id, qty_m)
      values (ln.id, b.lot_id, nullif(b.hu_key, '00000000-0000-0000-0000-000000000000'), v_take);
      v_need := v_need - v_take;
    end loop;
    update sales.so_lines set
      reserved_m = qty_m - delivered_m - v_need,
      to_produce_m = v_need,
      line_status = case when v_need = 0 then 'RESERVED'
                         when coalesce(ln.spec_status, '') <> 'RELEASED' then 'WAITING_SPEC'
                         else 'PLANNED' end
    where id = ln.id;
  end loop;
end $$;

create or replace function sales.create_delivery(p_so uuid, p_hus uuid[], p_ship_date date, p_note text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare so sales.sales_orders; v_id uuid; v_no text; h uuid; r record; v_sum numeric := 0;
begin
  perform inv.require_keeper(inv.wh('KTP'), null);
  select * into so from sales.sales_orders where id = p_so;
  if not found or so.status <> 'APPROVED' then raise exception 'Đơn bán chưa được duyệt'; end if;
  if coalesce(array_length(p_hus, 1), 0) = 0 then raise exception 'Chọn bobin giao'; end if;
  v_no := core.next_no('LG');
  insert into sales.deliveries (delivery_no, so_id, ship_date, status, note)
  values (v_no, p_so, coalesce(p_ship_date, current_date), 'DRAFT', nullif(trim(coalesce(p_note, '')), '')) returning id into v_id;
  foreach h in array p_hus loop
    select sr.so_line_id, sr.lot_id, sum(sr.qty_m) as q into r from sales.so_reservations sr join sales.so_lines sl on sl.id = sr.so_line_id
     where sr.hu_id = h and sr.released_at is null and sl.so_id = p_so group by sr.so_line_id, sr.lot_id limit 1;
    if r.q is null then raise exception 'Bobin % chưa được giữ cho đơn %', (select hu_no from inv.handling_units where id = h), so.so_no; end if;
    if exists (select 1 from sales.delivery_lines dl join sales.deliveries d on d.id = dl.delivery_id
               where dl.hu_id = h and d.status in ('DRAFT', 'PENDING_APPROVAL', 'APPROVED', 'PICKED') and d.id <> v_id) then
      raise exception 'Bobin % đã nằm trong lệnh giao khác', (select hu_no from inv.handling_units where id = h);
    end if;
    insert into sales.delivery_lines (delivery_id, so_line_id, hu_id, lot_id, qty_m) values (v_id, r.so_line_id, h, r.lot_id, r.q);
    v_sum := v_sum + r.q;
  end loop;
  perform wf.submit('DELIVERY', v_id, v_no, format('%s – %s bobin, %s m', so.so_no, array_length(p_hus, 1), v_sum));
  return v_id;
end $$;

-- Xuất giao: quét đủ đúng các bobin của lệnh giao đã duyệt
create or replace function inv.ship_delivery(p_delivery uuid, p_scanned uuid[]) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare dv sales.deliveries; v_doc uuid; v_missing text; v_extra text; v_wh uuid := inv.wh('KTP');
begin
  perform inv.require_keeper(v_wh, null);
  select * into dv from sales.deliveries where id = p_delivery for update;
  if not found or dv.status <> 'APPROVED' then raise exception 'Lệnh giao chưa được Giám đốc duyệt hoặc đã xuất'; end if;
  select string_agg(h.hu_no, ', ') into v_missing from sales.delivery_lines dl join inv.handling_units h on h.id = dl.hu_id
   where dl.delivery_id = p_delivery and not dl.hu_id = any(coalesce(p_scanned, '{}'));
  select string_agg(coalesce(h.hu_no, x::text), ', ') into v_extra from unnest(coalesce(p_scanned, '{}')) x left join inv.handling_units h on h.id = x
   where not exists (select 1 from sales.delivery_lines dl where dl.delivery_id = p_delivery and dl.hu_id = x);
  if v_missing is not null or v_extra is not null then
    raise exception 'Quét chưa khớp lệnh giao. Thiếu: %. Thừa: %', coalesce(v_missing, 'không'), coalesce(v_extra, 'không');
  end if;
  insert into inv.stock_docs (doc_no, doc_type, warehouse_id, ref_type, ref_id, note)
  values (core.next_no('XB'), 'SALE', v_wh, 'DELIVERY', p_delivery, 'Lệnh giao ' || dv.delivery_no) returning id into v_doc;
  insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty)
  select v_doc, row_number() over (order by h.hu_no), dl.lot_id, h.location_id, dl.hu_id, dl.qty_m
  from sales.delivery_lines dl join inv.handling_units h on h.id = dl.hu_id where dl.delivery_id = p_delivery;
  perform inv._post(v_doc);
  update sales.deliveries set status = 'SHIPPED', stock_doc_id = v_doc where id = p_delivery;
  update sales.so_lines sl set line_status = 'DELIVERED' where sl.so_id = dv.so_id and sl.delivered_m >= sl.qty_m;
  return v_doc;
end $$;

-- ===========================================================================
-- 10. Kiểm kê: Kế toán SX chủ trì, Quản lý SX + NV5 đếm mù, Kế toán trưởng duyệt chênh lệch
-- ===========================================================================
create or replace function inv.count_open(p_warehouse uuid, p_type text, p_locations uuid[], p_note text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid; v_no text; w inv.warehouses; v_n int;
begin
  if not core.has_role('KT_KHO') then raise exception 'Kế toán SX chủ trì mở phiếu kiểm kê'; end if;
  select * into w from inv.warehouses where id = p_warehouse;
  if not found then raise exception 'Chọn kho'; end if;
  if p_type not in ('SAMPLE', 'FULL') then raise exception 'Chọn loại kiểm kê'; end if;
  if exists (select 1 from inv.stock_counts c where c.warehouse_id = p_warehouse and c.status in ('OPEN', 'COUNTED', 'PENDING_APPROVAL')) then
    raise exception 'Kho % đang có phiếu kiểm kê chưa đóng', w.code;
  end if;
  v_no := core.next_no('KK');
  insert into inv.stock_counts (count_no, warehouse_id, status, count_date, count_type, location_ids, note)
  values (v_no, p_warehouse, 'OPEN', current_date, p_type, case when coalesce(array_length(p_locations, 1), 0) = 0 then null else p_locations end,
          nullif(trim(coalesce(p_note, '')), ''))
  returning id into v_id;
  if p_type = 'FULL' then
    insert into inv.stock_count_lines (count_id, lot_id, hu_key, location_id, system_qty)
    select v_id, b.lot_id, b.hu_key, nullif(b.location_key, '00000000-0000-0000-0000-000000000000'), b.qty
    from inv.stock_balances b where b.warehouse_id = p_warehouse and b.qty > 0
      and (coalesce(array_length(p_locations, 1), 0) = 0 or b.location_key = any(p_locations));
  else
    v_n := coalesce(inv.setting('count_sample_size'), 10)::int;
    insert into inv.stock_count_lines (count_id, lot_id, hu_key, location_id, system_qty)
    select v_id, b.lot_id, b.hu_key, nullif(b.location_key, '00000000-0000-0000-0000-000000000000'), b.qty
    from inv.stock_balances b join inv.lots l on l.id = b.lot_id left join master.materials m on m.id = l.material_id
    where b.warehouse_id = p_warehouse and b.qty > 0
      and (coalesce(array_length(p_locations, 1), 0) = 0 or b.location_key = any(p_locations))
    order by case coalesce(m.abc_class, 'B') when 'A' then 0 when 'B' then 1 else 2 end, random()
    limit v_n;
  end if;
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'Kho/vị trí đã chọn không có hàng để kiểm kê'; end if;
  return v_id;
end $$;

create or replace function inv.can_count(p_wh uuid) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select core.has_role('KT_KHO') or inv.keeper_mode(p_wh) is not null
$$;

-- Quét đếm: theo mã QR (p_hu) hoặc theo dòng (p_line) với hàng không có QR
create or replace function inv.count_scan(p_count uuid, p_hu uuid, p_line bigint, p_counted numeric, p_location uuid default null, p_note text default null)
returns bigint
language plpgsql security definer set search_path = pg_catalog, public as $$
declare c inv.stock_counts; v_id bigint; h inv.handling_units; v_loc uuid;
begin
  select * into c from inv.stock_counts where id = p_count for update;
  if not found or c.status not in ('OPEN', 'COUNTED') then raise exception 'Phiếu kiểm kê không ở trạng thái đang đếm'; end if;
  if not inv.can_count(c.warehouse_id) then raise exception 'Bạn không trong tổ kiểm kê kho này'; end if;
  if p_counted is null or p_counted < 0 then raise exception 'Nhập số đếm (≥ 0)'; end if;
  if p_line is not null then
    update inv.stock_count_lines set counted_qty = p_counted, counted_by = auth.uid(), counted_at = now(), note = nullif(trim(coalesce(p_note, '')), '')
     where id = p_line and count_id = p_count returning id into v_id;
    if v_id is null then raise exception 'Không có dòng kiểm kê'; end if;
    return v_id;
  end if;
  select * into h from inv.handling_units where id = p_hu;
  if not found then raise exception 'Không tìm thấy mã QR'; end if;
  v_loc := coalesce(p_location, h.location_id);
  if v_loc is not null and (select l.warehouse_id from inv.locations l where l.id = v_loc) <> c.warehouse_id then
    raise exception 'Vị trí không thuộc kho đang kiểm kê';
  end if;
  update inv.stock_count_lines set counted_qty = p_counted, counted_by = auth.uid(), counted_at = now(), note = nullif(trim(coalesce(p_note, '')), '')
   where count_id = p_count and hu_key = p_hu and location_id is not distinct from v_loc returning id into v_id;
  if v_id is null then
    if c.count_type = 'SAMPLE' and not exists (select 1 from inv.stock_count_lines where count_id = p_count and hu_key = p_hu) then
      raise exception '% không nằm trong danh sách chọn mẫu', h.hu_no;
    end if;
    -- Hàng thấy thực tế nhưng sổ ghi ở vị trí khác / không có: thêm dòng hệ thống = 0
    insert into inv.stock_count_lines (count_id, lot_id, hu_key, location_id, system_qty, counted_qty, counted_by, counted_at, note)
    values (p_count, h.lot_id, p_hu, v_loc, 0, p_counted, auth.uid(), now(), coalesce(nullif(trim(p_note), ''), 'Thấy ngoài danh sách'))
    returning id into v_id;
  end if;
  return v_id;
end $$;

-- Đóng phiếu: chênh lệch → phiếu điều chỉnh ADJ gửi Kế toán trưởng duyệt; không chênh → đóng luôn
create or replace function inv.count_close(p_count uuid, p_missing_as_zero boolean default false) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare c inv.stock_counts; v_left int; v_doc uuid; v_no text; v_diff int; v_val numeric;
begin
  if not core.has_role('KT_KHO') then raise exception 'Kế toán SX đóng phiếu kiểm kê'; end if;
  select * into c from inv.stock_counts where id = p_count for update;
  if not found or c.status not in ('OPEN', 'COUNTED') then raise exception 'Phiếu kiểm kê không ở trạng thái đang đếm'; end if;
  select count(*) into v_left from inv.stock_count_lines where count_id = p_count and counted_qty is null;
  if v_left > 0 and not p_missing_as_zero then
    raise exception 'Còn % dòng chưa đếm: đếm tiếp hoặc chọn "Dòng chưa đếm tính là 0"', v_left;
  end if;
  update inv.stock_count_lines set counted_qty = 0, note = coalesce(note, 'Không tìm thấy khi đếm') where count_id = p_count and counted_qty is null;
  update inv.stock_docs set status = 'CANCELLED' where id = c.adj_doc_id and status = 'DRAFT';
  select count(*) into v_diff from inv.stock_count_lines where count_id = p_count and counted_qty <> system_qty;
  update inv.stock_counts set closed_at = now(), closed_by = auth.uid() where id = p_count;
  if v_diff = 0 then
    update inv.stock_counts set status = 'POSTED', adj_doc_id = null where id = p_count;
    return null;
  end if;
  v_no := core.next_no('DC');
  insert into inv.stock_docs (doc_no, doc_type, warehouse_id, ref_type, ref_id, reason_code, review_status, note)
  values (v_no, 'ADJ', c.warehouse_id, 'COUNT', p_count, 'ADJ_COUNT', 'NA', 'Chênh lệch kiểm kê ' || c.count_no) returning id into v_doc;
  insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty, note)
  select v_doc, row_number() over (order by l.id), l.lot_id, l.location_id,
         nullif(l.hu_key, '00000000-0000-0000-0000-000000000000'), l.counted_qty - l.system_qty,
         'Sổ ' || l.system_qty || ' · đếm ' || l.counted_qty
  from inv.stock_count_lines l where l.count_id = p_count and l.counted_qty <> l.system_qty;
  select sum(abs(l.counted_qty - l.system_qty) * coalesce(v.avg_cost, 0)) into v_val
    from inv.stock_count_lines l join inv.lots lt on lt.id = l.lot_id
    left join cost.item_valuation v on v.warehouse_id = c.warehouse_id and v.material_id = lt.material_id
   where l.count_id = p_count;
  update inv.stock_counts set status = 'PENDING_APPROVAL', adj_doc_id = v_doc where id = p_count;
  perform wf.submit('STOCK_ADJ', v_doc, v_no, format('Kiểm kê %s: %s dòng chênh lệch, giá trị ±%s đ', c.count_no, v_diff, round(coalesce(v_val, 0))));
  return v_doc;
end $$;

create or replace function inv.count_cancel(p_count uuid, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare c inv.stock_counts;
begin
  if not core.has_role('KT_KHO') then raise exception 'Kế toán SX hủy phiếu kiểm kê'; end if;
  select * into c from inv.stock_counts where id = p_count for update;
  if c.status not in ('OPEN', 'COUNTED') then raise exception 'Chỉ hủy phiếu đang đếm'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do hủy'; end if;
  update inv.stock_counts set status = 'CANCELLED', note = concat_ws(' · ', note, 'Hủy: ' || trim(p_reason)) where id = p_count;
  update inv.stock_docs set status = 'CANCELLED' where id = c.adj_doc_id and status = 'DRAFT';
end $$;

-- ===========================================================================
-- 11. Hậu kiểm của Kế toán SX (duyệt trong ngày) và phiếu đảo (BR-KHO-12)
-- ===========================================================================
create or replace function inv.review_doc(p_doc uuid, p_ok boolean, p_note text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare d inv.stock_docs;
begin
  if not core.has_role('KT_KHO') then raise exception 'Chỉ Kế toán SX duyệt phiếu nhập, xuất'; end if;
  select * into d from inv.stock_docs where id = p_doc for update;
  if not found or d.status <> 'POSTED' then raise exception 'Chỉ duyệt phiếu đã ghi sổ'; end if;
  if d.review_status <> 'PENDING' then raise exception 'Phiếu % đã được xử lý (%)', d.doc_no, d.review_status; end if;
  if auth.uid() in (d.created_by, d.posted_by) then raise exception 'Người lập/ghi sổ không tự duyệt phiếu của mình'; end if;
  if not p_ok and coalesce(trim(p_note), '') = '' then raise exception 'Ghi lý do trả lại để người lập sửa'; end if;
  update inv.stock_docs set review_status = case when p_ok then 'CONFIRMED' else 'RETURNED' end, reviewed_by = auth.uid(),
         reviewed_at = now(), review_note = nullif(trim(coalesce(p_note, '')), '') where id = p_doc;
  if not p_ok then
    perform wf.notify_users(array_remove(array[d.created_by, d.posted_by], null) || inv.role_users(array['BGD']),
      'Phiếu kho bị trả lại: ' || d.doc_no, trim(p_note), '/kho/phieu/' || p_doc);
  end if;
end $$;

create or replace function inv.reverse_doc(p_doc uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare d inv.stock_docs; v_new uuid;
begin
  if not core.has_role('KT_KHO') then raise exception 'Chỉ Kế toán SX lập phiếu đảo'; end if;
  select * into d from inv.stock_docs where id = p_doc for update;
  if not found or d.status <> 'POSTED' then raise exception 'Chỉ đảo phiếu đã ghi sổ'; end if;
  if d.reversal_of is not null or d.reversed_by is not null then raise exception 'Phiếu đã được đảo hoặc chính là phiếu đảo'; end if;
  if d.doc_type not in ('GR', 'ISSUE_WO', 'RETURN_WO', 'SCRAP_IN', 'FG_IN', 'WIP_IN', 'CUST_RETURN', 'RETURN_SUP') then
    raise exception 'Loại phiếu % không đảo được: dùng điều chỉnh kiểm kê hoặc phiếu ngược chiều', d.doc_type;
  end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do đảo phiếu'; end if;
  insert into inv.stock_docs (doc_no, doc_type, warehouse_id, to_warehouse_id, ref_type, ref_id, requisition_id, reversal_of,
                              review_status, reviewed_by, reviewed_at, reason_code, note)
  values (core.next_no('DP'), d.doc_type, d.warehouse_id, d.to_warehouse_id, d.ref_type, d.ref_id, d.requisition_id, p_doc,
          'CONFIRMED', auth.uid(), now(), d.reason_code, 'Đảo ' || d.doc_no || ': ' || trim(p_reason))
  returning id into v_new;
  insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, to_location_id, hu_id, qty, qty_alt, unit_cost, note)
  select v_new, dl.line_no, dl.lot_id, dl.location_id, dl.to_location_id, dl.hu_id, abs(dl.qty), dl.qty_alt,
         (select sm.unit_cost from inv.stock_moves sm where sm.doc_line_id = dl.id order by sm.id limit 1), 'Đảo dòng ' || dl.line_no
  from inv.stock_doc_lines dl where dl.doc_id = p_doc;
  perform inv._post(v_new);
  if d.doc_type = 'ISSUE_WO' and d.requisition_id is not null then
    update inv.requisition_lines rl set qty_issued = rl.qty_issued - s.q
      from (select lt.material_id, sum(dl.qty) as q from inv.stock_doc_lines dl join inv.lots lt on lt.id = dl.lot_id where dl.doc_id = p_doc group by lt.material_id) s
     where rl.req_id = d.requisition_id and rl.material_id = s.material_id;
    update inv.requisitions set status = 'PARTIAL' where id = d.requisition_id and status = 'DONE';
  elsif d.doc_type = 'RETURN_WO' and d.requisition_id is not null then
    update inv.requisition_lines rl set qty_returned = rl.qty_returned - s.q
      from (select lt.material_id, sum(dl.qty) as q from inv.stock_doc_lines dl join inv.lots lt on lt.id = dl.lot_id where dl.doc_id = p_doc group by lt.material_id) s
     where rl.req_id = d.requisition_id and rl.material_id = s.material_id;
  elsif d.doc_type = 'GR' and d.ref_type = 'GR' then
    update purchase.po_lines pl set received_qty = pl.received_qty - g.qty
      from purchase.gr_lines g where g.gr_id = d.ref_id and g.po_line_id = pl.id;
    update purchase.goods_receipts set status = 'CANCELLED' where id = d.ref_id;
    update purchase.purchase_orders po set status = case when exists (select 1 from purchase.po_lines pl where pl.po_id = po.id and pl.received_qty > 0)
                                                         then 'PARTIAL_RECEIVED' else 'APPROVED' end
     where po.id = (select g.po_id from purchase.goods_receipts g where g.id = d.ref_id);
  end if;
  update inv.stock_docs set review_status = 'CONFIRMED', reviewed_by = coalesce(reviewed_by, auth.uid()), reviewed_at = coalesce(reviewed_at, now())
   where id = p_doc and review_status in ('PENDING', 'RETURNED');
  return v_new;
end $$;

-- ===========================================================================
-- 12. In tem QR (in lại phải ghi lý do — BR-KHO-16)
-- ===========================================================================
create or replace function inv.mark_printed(p_hus uuid[], p_reason text default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if not core.has_perm('inventory', 'view') then raise exception 'Không có quyền in tem'; end if;
  if exists (select 1 from inv.handling_units where id = any(p_hus) and print_count > 0) and coalesce(trim(p_reason), '') = '' then
    raise exception 'Có tem đã in trước đó: nhập lý do in lại';
  end if;
  update inv.handling_units set print_count = print_count + 1, last_printed_at = now() where id = any(p_hus);
  if coalesce(trim(p_reason), '') <> '' then
    insert into core.audit_log (user_id, table_name, row_id, action, new_data)
    select auth.uid(), 'inv.handling_units', h.id::text, 'REPRINT', jsonb_build_object('reason', trim(p_reason), 'hu_no', h.hu_no)
    from inv.handling_units h where h.id = any(p_hus);
  end if;
end $$;

-- ===========================================================================
-- 13. Ghi đầu ra công đoạn: tự trừ BTP đầu vào, nhập lô đầu ra (BTP vào KBTP, thành phẩm vào KTP chờ FQC)
-- ===========================================================================
drop function if exists mfg.record_output(uuid, text, numeric, numeric, jsonb, text);
create or replace function mfg.record_output(p_wo_op uuid, p_lot_no text, p_qty_m numeric, p_weight_kg numeric,
                                             p_inputs jsonb, p_color text default null, p_tare_kg numeric default null,
                                             p_carrier text default null, p_location text default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare o mfg.wo_operations; w mfg.work_orders; op master.operations; v_lot uuid; v_last boolean; e jsonb; v_hu uuid;
        v_in uuid; v_iline int := 0; v_need numeric; b record; v_take numeric; v_out uuid; v_wh uuid; v_loc uuid; c inv.carriers;
        v_kind text; v_lotno text;
begin
  if not core.has_perm('production', 'create') then raise exception 'Không có quyền ghi nhận sản xuất'; end if;
  select * into o from mfg.wo_operations where id = p_wo_op;
  if not found then raise exception 'Không tìm thấy công đoạn'; end if;
  select * into w from mfg.work_orders where id = o.wo_id;
  if w.status not in ('RELEASED', 'IN_PROGRESS') then raise exception 'Lệnh % chưa phát lệnh hoặc đã đóng', w.wo_no; end if;
  if coalesce(p_qty_m, 0) <= 0 then raise exception 'Nhập số mét đầu ra'; end if;
  select * into op from master.operations where code = o.op_code;
  v_last := o.op_code = 'CD6';
  if p_carrier is not null then
    select * into c from inv.carriers where code = p_carrier for update;
    if not found then raise exception 'Không có bobin %', p_carrier; end if;
    if c.status <> 'EMPTY' then raise exception 'Bobin % đang chứa hàng hoặc hỏng', p_carrier; end if;
  end if;
  insert into inv.lots (lot_no, item_kind, product_id, spec_id, wip_stage, brand, color, uom, wo_op_id, qc_status, mfg_date, weight_kg)
  values (p_lot_no, case when v_last then 'FG' else 'WIP' end, w.product_id, w.spec_id,
          case when v_last then null else op.output_prefix end, w.brand, p_color, 'm', p_wo_op,
          case when v_last then 'PENDING' else 'PASSED' end, current_date, p_weight_kg)
  returning id into v_lot;
  insert into mfg.wo_outputs (wo_op_id, lot_id, qty_m, weight_kg) values (p_wo_op, v_lot, p_qty_m, p_weight_kg) returning id into v_out;

  -- BTP đầu vào lấy ra khỏi kho BTP (phiếu tự sinh, Kế toán SX không cần hậu kiểm)
  for e in select * from jsonb_array_elements(coalesce(p_inputs, '[]')) loop
    insert into mfg.lot_genealogy (parent_lot_id, child_lot_id, wo_op_id, qty_used)
    values ((e ->> 'lot_id')::uuid, v_lot, p_wo_op, (e ->> 'qty')::numeric);
    if (select lt.item_kind from inv.lots lt where lt.id = (e ->> 'lot_id')::uuid) = 'WIP' then
      if v_in is null then
        insert into inv.stock_docs (doc_no, doc_type, warehouse_id, ref_type, ref_id, review_status, note)
        values (core.next_no('XBTP'), 'ISSUE_WO', inv.wh('KBTP'), 'WO', w.id, 'NA', 'Tự sinh: ' || o.op_code || ' lệnh ' || w.wo_no)
        returning id into v_in;
      end if;
      v_need := (e ->> 'qty')::numeric;
      for b in select bal.* from inv.stock_balances bal where bal.lot_id = (e ->> 'lot_id')::uuid and bal.warehouse_id = inv.wh('KBTP')
               and bal.qty - bal.reserved_qty > 0 order by bal.qty loop
        exit when v_need <= 0;
        v_take := least(v_need, b.qty - b.reserved_qty);
        v_iline := v_iline + 1;
        insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty)
        values (v_in, v_iline, b.lot_id, nullif(b.location_key, '00000000-0000-0000-0000-000000000000'),
                nullif(b.hu_key, '00000000-0000-0000-0000-000000000000'), v_take);
        v_need := v_need - v_take;
      end loop;
      if v_need > 0 then
        select lot_no into v_lotno from inv.lots where id = (e ->> 'lot_id')::uuid;
        raise exception 'Lô BTP % không đủ trong kho BTP (thiếu % m)', v_lotno, v_need;
      end if;
    end if;
  end loop;
  if v_in is not null then perform inv._post(v_in); end if;

  -- Lô đầu ra: một đơn vị chứa (bobin/cuộn) có QR
  v_wh := inv.wh(case when v_last then 'KTP' else 'KBTP' end);
  v_loc := coalesce(inv.loc(p_location), inv.loc(case when v_last then 'KTP-QC' else 'KBTP-W' end));
  v_kind := case when v_last and w.pack_type = 'Cuộn PE' then 'COIL' else 'REEL' end;
  v_hu := inv.new_hu(v_lot, v_kind, p_qty_m, v_wh, v_loc,
                     case when p_weight_kg is not null then p_weight_kg + coalesce(p_tare_kg, c.tare_kg, 0) end, coalesce(p_tare_kg, c.tare_kg));
  if c.id is not null then
    update inv.handling_units set carrier_id = c.id where id = v_hu;
    update inv.carriers set status = 'IN_USE', current_hu_id = v_hu, location_id = v_loc where id = c.id;
  end if;
  update inv.handling_units set is_remnant = v_last and p_qty_m < least(w.m_per_pack, inv.remnant_min(w.product_id)) where id = v_hu;
  insert into inv.stock_docs (doc_no, doc_type, warehouse_id, ref_type, ref_id, review_status, note)
  values (core.next_no(case when v_last then 'NTP' else 'NBTP' end), case when v_last then 'FG_IN' else 'WIP_IN' end, v_wh, 'WO', w.id,
          case when v_last then 'PENDING' else 'NA' end, o.op_code || ' lệnh ' || w.wo_no)
  returning id into v_in;
  insert into inv.stock_doc_lines (doc_id, line_no, lot_id, location_id, hu_id, qty, weight_kg)
  values (v_in, 1, v_lot, v_loc, v_hu, p_qty_m, p_weight_kg);
  perform inv._post(v_in);
  update mfg.wo_outputs set stock_doc_id = v_in where id = v_out;
  update mfg.wo_operations set good_m = good_m + p_qty_m, status = case when status = 'PENDING' then 'RUNNING' else status end where id = p_wo_op;
  update mfg.work_orders set status = 'IN_PROGRESS' where id = w.id and status = 'RELEASED';
  if v_last then
    perform wf.notify_users(inv.role_users(array['KT_TP', 'QC']), 'Bobin chờ FQC: ' || p_lot_no, p_qty_m || ' m · lệnh ' || w.wo_no, '/kho/qc');
  end if;
  return v_lot;
end $$;
