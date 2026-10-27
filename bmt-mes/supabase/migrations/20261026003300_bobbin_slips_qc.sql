-- BMT MES · 3300 · Quy trình final 27/10/2026 – Đợt 0 + 1 + 2
--  0. Cấu hình: kế hoạch tháng TP SX lập → Chủ tịch HĐQT duyệt; anh Bằng = TP SX kiêm thủ kho NVL
--  1. Phiếu hoàn thành bobin: công nhân ghi giấy, Kế toán SX (KT_KHO; vắng thì TP SX) nhập vào MES
--  2. Mọi bobin BTP vừa nhập ở trạng thái Chờ QC; chỉ bobin QC PASS mới được lắp vào công đoạn sau;
--     không ai tự ký QC PASS cho bobin mình làm; QC trả kết quả trong 2 giờ (quá hạn báo QC, TP KT/QA)

-- ===========================================================================
-- 0. Cấu hình duyệt và vai trò theo quy trình final
-- ===========================================================================
-- Kế hoạch tháng: TP SX lập, Chủ tịch HĐQT duyệt (bỏ bước "Quản lý SX xác nhận năng lực" vì người lập chính là TP SX)
update wf.approval_steps set enabled = false where doc_type = 'PLAN' and seq = 1 and role_code = 'SX_TP';
update wf.approval_flows set submit_role = null, submit_label = 'TP SX lập kế hoạch tháng' where doc_type = 'PLAN';

-- Anh Bằng: TP sản xuất (Quản lý SX) kiêm thủ kho NVL, giữ vai trò Kế hoạch SX
insert into core.user_roles (user_id, role_code)
select p.id, r.code
from core.profiles p join auth.users u on u.id = p.id
cross join (values ('SX_TP'), ('THU_KHO'), ('SX_KH')) as r(code)
where lower(u.email) = 'bang.dd@bmtcable.vn'
on conflict do nothing;

-- Kế toán SX (vai trò Kế toán kho) nhập phiếu hoàn thành, báo cáo ca: cần xem lệnh SX, spec, kết quả QC, kế hoạch ngày
insert into core.role_permissions (role_code, module, action)
values ('KT_KHO', 'production', 'view'), ('KT_KHO', 'spec', 'view'), ('KT_KHO', 'quality', 'view'), ('KT_KHO', 'plan', 'view'),
       ('SX_TP', 'spec', 'view'), ('SX_TP', 'quality', 'view')
on conflict do nothing;

-- ===========================================================================
-- 1. Phiếu hoàn thành bobin
-- ===========================================================================
create table if not exists mfg.bobbin_slips (
  id            uuid primary key default gen_random_uuid(),
  slip_no       text unique not null,                     -- PHT-0001 (số MES)
  paper_no      text,                                      -- số phiếu giấy (nếu có)
  wo_id         uuid not null references mfg.work_orders(id),
  wo_op_id      uuid not null references mfg.wo_operations(id),
  op_code       text not null,
  machine_id    uuid references master.machines(id),
  carrier_id    uuid references inv.carriers(id),
  operator_code text not null,
  started_at    timestamptz,
  ended_at      timestamptz,
  gross_kg      numeric(18,3) not null check (gross_kg > 0),
  tare_kg       numeric(18,3) not null default 0,
  net_kg        numeric(18,3) not null check (net_kg > 0),
  meter_start   numeric(18,2),
  meter_end     numeric(18,2),
  qty_m         numeric(18,2) not null check (qty_m > 0),
  qty_estimated boolean not null default false,           -- bện: mét ước tính từ kg, mét thật lấy ở line đùn
  inputs        jsonb not null default '[]',              -- [{hu_no, lot_no, carrier, left_kg, used_m}]
  materials     text,                                      -- loại + số lô NVL đã dùng (ghi trên phiếu)
  scrap_kg      numeric(18,3),
  scrap_reason  text references master.reason_codes(code),
  readings      jsonb not null default '{}',              -- số đọc thiết bị trên chuyền: {spark_faults, od_mm}
  note          text,
  lot_id        uuid references inv.lots(id),
  hu_id         uuid references inv.handling_units(id),
  out_doc_id    uuid references inv.stock_docs(id),
  in_doc_id     uuid references inv.stock_docs(id),
  scrap_id      uuid references mfg.scrap_records(id),
  status        text not null default 'ACTIVE' check (status in ('ACTIVE', 'VOID')),
  void_reason   text,
  recorded_at   timestamptz not null default now(),
  recorded_by   uuid default auth.uid(),
  voided_at     timestamptz,
  voided_by     uuid
);
create index if not exists bobbin_slips_wo on mfg.bobbin_slips (wo_id);
create index if not exists bobbin_slips_lot on mfg.bobbin_slips (lot_id);
create index if not exists bobbin_slips_rec on mfg.bobbin_slips (recorded_at desc);

alter table mfg.bobbin_slips enable row level security;
revoke all on mfg.bobbin_slips from anon, authenticated;
grant select on mfg.bobbin_slips to authenticated;
grant all on mfg.bobbin_slips to service_role;
drop policy if exists p_select on mfg.bobbin_slips;
create policy p_select on mfg.bobbin_slips for select to authenticated
  using (core.has_perm('production', 'view') or core.has_perm('inventory', 'view') or core.has_perm('quality', 'view'));
-- Chỉ ghi qua hàm (authenticated không có quyền insert/update), không cần trigger chốt trạng thái

-- Người được nhập phiếu: Kế toán SX (KT_KHO); TP SX nhập thay khi Kế toán vắng
create or replace function mfg.can_enter_slips() returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select core.has_role('KT_KHO') or core.has_role('SX_TP')
$$;
grant execute on function mfg.can_enter_slips() to authenticated;

-- ===========================================================================
-- 2. Ghi nhận đầu ra: BTP vào Chờ QC, chặn BTP đầu vào chưa QC PASS
--    (viết lại mfg.record_output của 2500; thêm đường vào từ phiếu hoàn thành)
-- ===========================================================================
create or replace function mfg.record_output(p_wo_op uuid, p_lot_no text, p_qty_m numeric, p_weight_kg numeric,
                                             p_inputs jsonb, p_color text default null, p_tare_kg numeric default null,
                                             p_carrier text default null, p_location text default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare o mfg.wo_operations; w mfg.work_orders; op master.operations; v_lot uuid; v_last boolean; e jsonb; v_hu uuid;
        v_in uuid; v_iline int := 0; v_need numeric; b record; v_take numeric; v_out uuid; v_wh uuid; v_loc uuid; c inv.carriers;
        v_kind text; v_lotno text; v_inlot inv.lots; v_code text;
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
  select code into v_code from master.products where id = w.product_id;
  perform wf.notify_users(inv.role_users(array['QC', 'KT_TP']),
    'Bobin chờ QC: ' || p_lot_no, coalesce(op.name, o.op_code) || ' · ' || v_code || ' · ' || p_qty_m || ' m · lệnh ' || w.wo_no || '. Trả kết quả trong 2 giờ.',
    '/kho/qc');
  return v_lot;
end $$;
revoke execute on function mfg.record_output(uuid, text, numeric, numeric, jsonb, text, numeric, text, text) from public, anon;
grant execute on function mfg.record_output(uuid, text, numeric, numeric, jsonb, text, numeric, text, text) to authenticated;

-- Mã phế theo công đoạn và vật liệu của spec
create or replace function mfg.scrap_material_for(p_op text, p_spec uuid) returns text
language sql stable security definer set search_path = pg_catalog, public as $$
  select case
    when p_op = 'CD1' then 'PL-CU'
    when p_op in ('CD0', 'CD2') then case upper(coalesce(s.insulation, ''))
      when 'SIL' then 'PL-SIL' when 'PVC' then 'PL-PVC' when 'LSZH' then 'PL-LSZH' when 'HDPE' then 'PL-PE' else 'PL-CABLE' end
    when p_op = 'CD5' then case when upper(coalesce(s.sheath, '')) like '%LSZH%' then 'PL-LSZH'
      when upper(coalesce(s.sheath, '')) like '%PVC%' then 'PL-PVC' when upper(coalesce(s.sheath, '')) like '%PE%' then 'PL-PE' else 'PL-CABLE' end
    else 'PL-CABLE' end
  from master.product_specs s where s.id = p_spec
$$;

-- Nhập phiếu hoàn thành bobin (Kế toán SX)
-- p: {wo_id, op_code, machine_code, carrier, operator_code, started_at, ended_at (giờ VN 'YYYY-MM-DDTHH:MI'),
--     gross_kg, meter_start, meter_end, qty_m (khi không có đồng hồ: đóng gói), color, paper_no,
--     inputs: [{code (số bobin hoặc mã đơn vị chứa), left_kg}], materials, scrap_kg, scrap_reason, readings: {spark_faults, od_mm}, note}
create or replace function app.record_bobbin(p jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare w mfg.work_orders; o mfg.wo_operations; op master.operations; m master.machines; c inv.carriers; opr master.operators;
        sr master.spec_results; sp master.product_specs;
        v_gross numeric; v_tare numeric; v_net numeric; v_qty numeric; v_est boolean := false; v_start timestamptz; v_end timestamptz;
        e jsonb; v_code text; v_hu inv.handling_units; v_inlot inv.lots; v_left numeric; v_hu_net numeric; v_used numeric;
        v_inputs jsonb := '[]'; v_rec jsonb := '[]'; v_lotno text; v_base text; v_n int := 1; v_lot uuid; v_slip uuid; v_no text;
        v_scrap uuid; v_scrap_kg numeric; v_reason text; v_out_doc uuid; v_in_doc uuid; v_hu_id uuid; v_per_core numeric;
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
    if coalesce(v_left, 0) > 0 then
      v_hu_net := coalesce(v_hu.gross_kg, 0) - coalesce(v_hu.tare_kg, 0);
      if v_hu_net <= 0 then raise exception 'Bobin % chưa có khối lượng cân: không trừ được phần còn dư', v_code; end if;
      if v_left >= v_hu_net then raise exception 'Bobin %: kg còn dư (%) không nhỏ hơn kg trên bobin (%)', v_code, v_left, round(v_hu_net, 2); end if;
      v_used := round(v_hu.qty * (1 - v_left / v_hu_net), 2);
    else
      v_used := v_hu.qty;
    end if;
    v_inputs := v_inputs || jsonb_build_object('lot_id', v_inlot.id, 'hu_id', v_hu.id, 'qty', v_used);
    v_rec := v_rec || jsonb_build_object('code', v_code, 'hu_no', v_hu.hu_no, 'lot_no', v_inlot.lot_no, 'left_kg', v_left, 'used_m', v_used);
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
  v_lot := mfg.record_output(o.id, v_lotno, v_qty, v_net, v_inputs, coalesce(nullif(p ->> 'color', ''), sp.sheath_color), v_tare, c.code, null);
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
                                readings, note, lot_id, hu_id, out_doc_id, in_doc_id, scrap_id)
  values (v_no, nullif(trim(coalesce(p ->> 'paper_no', '')), ''), w.id, o.id, o.op_code, m.id, c.id, opr.code, v_start, v_end,
          v_gross, v_tare, v_net, nullif(p ->> 'meter_start', '')::numeric, nullif(p ->> 'meter_end', '')::numeric, v_qty, v_est, v_rec,
          nullif(trim(coalesce(p ->> 'materials', '')), ''), v_scrap_kg, v_reason, coalesce(p -> 'readings', '{}'),
          nullif(trim(coalesce(p ->> 'note', '')), ''), v_lot, v_hu_id, v_out_doc, v_in_doc, v_scrap)
  returning id into v_slip;
  return jsonb_build_object('slip_id', v_slip, 'slip_no', v_no, 'lot_no', v_lotno, 'qty_m', v_qty, 'estimated', v_est, 'net_kg', v_net);
end $$;
revoke execute on function app.record_bobbin(jsonb) from public, anon;
grant execute on function app.record_bobbin(jsonb) to authenticated;

-- Hủy phiếu nhập sai: đảo phiếu nhập BTP/TP và phiếu xuất BTP đầu vào (bobin chưa được dùng, chưa QC xong)
create or replace function app.void_bobbin(p_slip uuid, p_reason text) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
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
  if s.scrap_id is not null then
    update mfg.bobbin_slips set scrap_id = null where id = s.id;
    delete from mfg.scrap_records where id = s.scrap_id;
  end if;
  update inv.lots set qc_status = 'REJECTED', attrs = attrs || jsonb_build_object('void_slip', s.slip_no) where id = s.lot_id;
  update mfg.bobbin_slips set status = 'VOID', void_reason = trim(p_reason), voided_at = now(), voided_by = auth.uid() where id = s.id;
  return s.slip_no;
end $$;
revoke execute on function app.void_bobbin(uuid, text) from public, anon;
grant execute on function app.void_bobbin(uuid, text) to authenticated;

-- ===========================================================================
-- 3. QC: không tự ký QC PASS cho bobin mình làm (viết lại qa.release_lot của 2500)
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
  if exists (select 1 from mfg.bobbin_slips s join master.operators op on op.code = s.operator_code
             where s.lot_id = p_lot and s.status = 'ACTIVE' and op.profile_id = auth.uid()) then
    raise exception 'Không tự ký QC cho bobin mình làm: nhờ QC khác hoặc người được TP KT/QA ký tay nghề QC';
  end if;
  if p_result <> 'PASS' and coalesce(trim(p_note), '') = '' then raise exception 'Ghi lỗi phát hiện để lập NCR'; end if;
  v_type := case lt.item_kind when 'MAT' then 'IQC' when 'FG' then 'FQC' else 'IPQC' end;
  insert into qa.inspections (insp_no, insp_type, lot_id, wo_op_id, spec_id, result, inspected_at, note)
  values (core.next_no('KT'), v_type, p_lot, lt.wo_op_id, lt.spec_id, case when p_result = 'PASS' then 'PASS' else 'FAIL' end, now(),
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
  if lt.item_kind = 'WIP' then
    -- BTP: báo TP SX (lắp được công đoạn sau / cách ly, phiếu xử lý)
    perform wf.notify_users(inv.role_users(array['SX_TP']),
      case p_result when 'PASS' then 'QC PASS: ' else 'Bobin không đạt: ' end || lt.lot_no,
      v_code || case when p_result = 'PASS' then ' – dán tem QC PASS, được lắp vào công đoạn sau'
                     else ' – dán tem đỏ, đưa vào ô cách ly. ' || trim(p_note) end, '/phieu-hoan-thanh');
  else
    perform wf.notify_users(inv.role_users(case when lt.item_kind = 'FG' then array['KHO_NV'] else array['THU_KHO'] end),
      case p_result when 'PASS' then 'Lô đạt: ' else 'Lô không đạt: ' end || lt.lot_no,
      v_code || case when p_result = 'PASS' then ' – cất vào vị trí lưu kho' else ' – chuyển khu cách ly. ' || trim(p_note) end, '/kho/ton?q=' || lt.lot_no);
  end if;
  if p_result <> 'PASS' and lt.item_kind = 'MAT' then
    perform wf.notify_users(inv.role_users(array['MUA_NV']), 'Lô NVL không đạt: ' || lt.lot_no, v_code || ': ' || trim(p_note), '/kho/qc');
  end if;
  return v_insp;
end $$;

-- QC trả kết quả trong 2 giờ: quá hạn báo QC và TP KT/QA (một lần cho mỗi bobin)
insert into inv.settings (key, label, num_value, unit, owner_role, sort)
values ('qc_result_minutes', 'Thời hạn QC trả kết quả bobin sau khi nhập phiếu', 120, 'phút', 'KT_TP', 20)
on conflict (key) do nothing;

create or replace function qa.qc_wait_alerts() returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r record; v_n int := 0; v_min numeric := coalesce(inv.setting('qc_result_minutes'), 120);
begin
  for r in select l.id, l.lot_no, l.created_at, coalesce(p.code, '') as code
           from inv.lots l left join master.products p on p.id = l.product_id
           where l.qc_status = 'PENDING' and l.item_kind in ('WIP', 'FG')
             and l.created_at < now() - make_interval(mins => v_min::int)
             and not (l.attrs ? 'qc_late_alert') loop
    perform wf.notify_users(inv.role_users(array['QC', 'KT_TP']), 'Quá hạn QC: ' || r.lot_no,
      r.code || ' chờ QC từ ' || to_char(r.created_at at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM') || ' (quá ' || v_min || ' phút)', '/kho/qc');
    update inv.lots set attrs = attrs || jsonb_build_object('qc_late_alert', now()) where id = r.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke execute on function qa.qc_wait_alerts() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('bmt_qc_wait', '*/15 * * * *', 'select qa.qc_wait_alerts()');
  end if;
exception when others then
  raise notice 'Bỏ qua pg_cron: %', sqlerrm;
end $$;

-- ===========================================================================
-- 4. View cho web
-- ===========================================================================
-- Hàng chờ QC: thêm thông tin phiếu hoàn thành (máy, người làm, số đọc trên chuyền, thời gian chờ)
create or replace view app.v_qc_queue with (security_invoker = true) as
select l.id as lot_id, l.lot_no, l.item_kind, l.qc_status, l.supplier_lot, l.mfg_date, l.exp_date, l.created_at, l.weight_kg,
       coalesce(m.code, p.code) as item_code, coalesce(m.name, p.description) as item_name, coalesce(m.uom, l.uom) as uom, m.requires_coa,
       sp.name as supplier_name, wo.wo_no, o.op_code,
       coalesce((select sum(b.qty) from inv.stock_balances b where b.lot_id = l.id), 0) as qty,
       (select count(*) from inv.handling_units h where h.lot_id = l.id and h.status = 'ACTIVE') as hu_count,
       (select n.ncr_no from qa.ncrs n where n.lot_id = l.id and n.status = 'OPEN' order by n.created_at desc limit 1) as ncr_no,
       (select n.description from qa.ncrs n where n.lot_id = l.id and n.status = 'OPEN' order by n.created_at desc limit 1) as ncr_text,
       r.total_kgkm, r.rdc_limit, r.od_mm,
       l.wip_stage, s.slip_no, s.operator_code, mc.code as machine_code, ca.code as carrier_code, s.net_kg, s.qty_estimated, s.readings,
       s.ended_at as made_at, (extract(epoch from (now() - l.created_at)) / 60)::int as wait_min
from inv.lots l
left join master.materials m on m.id = l.material_id
left join master.products p on p.id = l.product_id
left join core.partners sp on sp.id = l.supplier_id
left join mfg.wo_operations o on o.id = l.wo_op_id
left join mfg.work_orders wo on wo.id = o.wo_id
left join master.spec_results r on r.spec_id = l.spec_id
left join mfg.bobbin_slips s on s.lot_id = l.id and s.status = 'ACTIVE'
left join master.machines mc on mc.id = s.machine_id
left join inv.carriers ca on ca.id = s.carrier_id
where l.qc_status in ('PENDING', 'QUARANTINE');
grant select on app.v_qc_queue to authenticated;

-- Lệnh SX đang chạy × công đoạn: chọn khi nhập phiếu / in phiếu trống
create or replace view app.v_slip_targets with (security_invoker = true) as
select wo.id as wo_id, wo.wo_no, wo.status as wo_status, wo.qty_m as wo_qty_m, wo.pack_type, wo.m_per_pack, wo.brand,
       p.code as product_code, p.description as product_name, s.cores, s.sheath_color, s.insulation_colors,
       o.id as wo_op_id, o.op_code, op.name as op_name, o.seq, op.machine_type, op.per_core, o.planned_m, o.good_m, mc.code as machine_code,
       (select count(*) from mfg.bobbin_slips b where b.wo_op_id = o.id and b.status = 'ACTIVE') as slips,
       case when coalesce(r.metal_kgkm, 0) > 0 and coalesce(s.cores, 0) > 0 then round(r.metal_kgkm / s.cores, 4) end as core_cu_kgkm
from mfg.work_orders wo
join master.products p on p.id = wo.product_id
join master.product_specs s on s.id = wo.spec_id
left join master.spec_results r on r.spec_id = wo.spec_id
join mfg.wo_operations o on o.wo_id = wo.id
join master.operations op on op.code = o.op_code
left join master.machines mc on mc.id = o.machine_id
where wo.status in ('RELEASED', 'IN_PROGRESS');
grant select on app.v_slip_targets to authenticated;

-- Phiếu hoàn thành đã nhập
create or replace view app.v_bobbin_slips with (security_invoker = true) as
select s.id, s.slip_no, s.paper_no, s.status, s.void_reason, s.recorded_at, s.op_code, op.name as op_name, wo.wo_no, p.code as product_code,
       mc.code as machine_code, ca.code as carrier_code, s.operator_code, s.started_at, s.ended_at, s.gross_kg, s.tare_kg, s.net_kg,
       s.meter_start, s.meter_end, s.qty_m, s.qty_estimated, s.inputs, s.materials, s.scrap_kg, s.scrap_reason, s.readings, s.note,
       l.lot_no, l.qc_status, h.hu_no, pr.full_name as recorded_by_name,
       ((s.ended_at at time zone 'Asia/Ho_Chi_Minh')::date) as work_date
from mfg.bobbin_slips s
join mfg.work_orders wo on wo.id = s.wo_id
join master.products p on p.id = wo.product_id
join master.operations op on op.code = s.op_code
left join master.machines mc on mc.id = s.machine_id
left join inv.carriers ca on ca.id = s.carrier_id
left join inv.lots l on l.id = s.lot_id
left join inv.handling_units h on h.id = s.hu_id
left join core.profiles pr on pr.id = s.recorded_by;
grant select on app.v_bobbin_slips to authenticated;
