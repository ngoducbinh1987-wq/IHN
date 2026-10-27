-- BMT MES · 3400 · Quy trình final 27/10/2026 – Đợt 3
--  1. Phiếu xuất NVL theo lô: Kế toán SX in phiếu (MES gợi ý ống/bao theo FEFO), thủ kho xuất, NV lấy NVL ký nhận trên giấy,
--     Kế toán SX nhập số thực xuất vào MES (app.paper_issue); NVL thừa cuối ngày nhập lại kho theo phiếu (app.paper_return)
--  2. Báo cáo ca do Kế toán SX nhập từ tờ báo cáo ca giấy: sản lượng MES tự cộng từ phiếu hoàn thành, NVL để lại máy chạy tiếp
--     cùng lô (đồng trên giá xả, nhựa trong phễu), phế cả ca theo lý do (ghi vào phế khi TP SX chốt ca)
--  3. Mét thật của bobin bện lấy từ đồng hồ line đùn: phiếu hoàn thành ghi kg bobin đầu vào đã dùng → kg/km ruột thật
--  4. Hao hụt theo từng công đoạn, từng lô so với định mức (xanh / vàng / đỏ); báo cáo ngày + cảnh báo, TP SX giải trình mục đỏ

-- ===========================================================================
-- 0. Cột, bảng, tham số
-- ===========================================================================
alter table inv.stock_docs
  add column if not exists paper_no text,          -- số phiếu giấy (phiếu xuất NVL, phiếu nhập NVL thừa)
  add column if not exists receiver_code text;     -- NV nhận (phiếu xuất) / NV trả (NVL thừa): mã người đứng máy NV1–NV5

alter table mfg.shift_reports
  add column if not exists keeps jsonb not null default '[]',    -- NVL để lại máy chạy tiếp cùng lô: [{material_code, kg, wo_no}]
  add column if not exists scraps jsonb not null default '[]';   -- phế cả ca ngoài phiếu bobin: [{wo_no, op_code, reason, kg}]

alter table mfg.scrap_records add column if not exists shift_report_id uuid references mfg.shift_reports(id);

insert into inv.settings (key, label, num_value, unit, owner_role, sort) values
  ('plastic_tol_pct', 'Nhựa dùng vượt định mức (theo công đoạn, theo lô) trước khi báo đỏ', 10, '%', 'KT_TP', 21),
  ('m_loss_pct', 'Định mức hao hụt mét mỗi công đoạn (xoắn, quấn băng, bọc vỏ, đóng gói)', 1, '%', 'KT_TP', 22),
  ('m_tol_pct', 'Hao hụt mét vượt định mức trước khi báo đỏ', 2, '%', 'KT_TP', 23),
  ('twist_factor', 'Hệ số xoắn: mét lõi cho 1 m cáp xoắn (mỗi lõi)', 1.02, 'lần', 'KT_TP', 24)
on conflict (key) do nothing;

-- Giải trình hao hụt (TP SX ghi cho mục vàng/đỏ của báo cáo ngày)
create table if not exists mfg.loss_notes (
  wo_id     uuid not null references mfg.work_orders(id),
  stage     text not null,
  work_date date not null,
  level     text,
  note      text not null,
  noted_by  uuid default auth.uid(),
  noted_at  timestamptz not null default now(),
  primary key (wo_id, stage, work_date)
);
-- Báo cáo ngày đã gửi (Kế toán SX bấm gửi sau đối soát; 19:30 MES tự gửi nếu chưa ai gửi)
create table if not exists mfg.daily_reports (
  work_date date primary key,
  sent_at   timestamptz not null default now(),
  sent_by   uuid,
  auto      boolean not null default false,
  summary   jsonb not null default '{}'
);
do $$
declare t text;
begin
  foreach t in array array['mfg.loss_notes', 'mfg.daily_reports'] loop
    execute format('alter table %s enable row level security', t);
    execute format('revoke all on %s from anon, authenticated', t);
    execute format('grant select on %s to authenticated', t);
    execute format('grant all on %s to service_role', t);
    execute format('drop policy if exists p_select on %s', t);
    execute format('create policy p_select on %s for select to authenticated using (app.can_see_loss())', t);
  end loop;
end $$;

-- ===========================================================================
-- 1. Cấp NVL theo phiếu giấy: viết lại inv.issue_pick, inv.return_hu (2500) — thêm đường Kế toán SX nhập phiếu đã ký
-- ===========================================================================
create or replace function inv.issue_pick(p_req uuid, p_items jsonb, p_receiver uuid, p_witness uuid default null,
                                         p_off_hours_reason text default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  r inv.requisitions; w mfg.work_orders; v_wh uuid := inv.wh('KNL'); v_del boolean; v_doc uuid; v_no text;
  e jsonb; h record; v_qty numeric; v_avail numeric; v_line int := 0; v_first text; c record;
  v_paper boolean := coalesce(current_setting('bmt.paper', true) = 'on', false);
begin
  select * into r from inv.requisitions where id = p_req for update;
  if not found then raise exception 'Không tìm thấy phiếu lĩnh'; end if;
  if r.status not in ('APPROVED', 'PARTIAL') then raise exception 'Phiếu lĩnh % chưa được duyệt hoặc đã đóng (%)', r.req_no, r.status; end if;
  select * into w from mfg.work_orders where id = r.wo_id;
  -- Phiếu giấy (quy trình final): thủ kho xuất, NV lấy NVL ký nhận trên phiếu; Kế toán SX nhập lại vào MES (app.paper_issue)
  if v_paper then
    v_del := false;
  else
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
  if not v_paper then
    perform wf.notify_users(array[p_receiver], 'Nhận NVL tại máy: ' || v_no, 'Lệnh ' || w.wo_no || ' – kiểm tra và bấm Xác nhận đã nhận', '/kho/nhan-nvl');
  end if;
  return v_doc;
end $$;

create or replace function inv.return_hu(p_hu uuid, p_qty numeric, p_location uuid default null, p_witness uuid default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare h record; v_wh uuid := inv.wh('KNL'); v_del boolean; v_last inv.stock_docs; v_out numeric; v_back numeric; v_doc uuid; v_loc uuid;
        v_paper boolean := coalesce(current_setting('bmt.paper', true) = 'on', false);
begin
  select hu.*, lt.item_kind, lt.material_id, lt.lot_no into h from inv.handling_units hu join inv.lots lt on lt.id = hu.lot_id where hu.id = p_hu;
  if not found then raise exception 'Không tìm thấy mã QR'; end if;
  if h.item_kind <> 'MAT' then raise exception '% không phải nguyên vật liệu', h.hu_no; end if;
  v_del := case when v_paper then false else inv.require_keeper(v_wh, p_witness) end;   -- phiếu giấy: Kế toán SX nhập (app.paper_return)
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

-- Kế toán SX nhập phiếu xuất NVL đã ký (thủ kho xuất, NV lấy NVL nhận)
-- p: {paper_no, receiver_code (NV1–NV5), reason (lý do không theo gợi ý lô, nếu có), items: [{code (mã tem ống/bao), qty}]}
create or replace function app.paper_issue(p_req uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r inv.requisitions; opr master.operators; e jsonb; v_code text; h inv.handling_units; v_items jsonb := '[]'; v_doc uuid; v_qty numeric;
        v_no text;
begin
  if not mfg.can_enter_slips() then raise exception 'Chỉ Kế toán SX nhập phiếu xuất NVL (TP SX nhập thay khi Kế toán vắng)'; end if;
  select * into r from inv.requisitions where id = p_req;
  if not found then raise exception 'Không tìm thấy phiếu lĩnh'; end if;
  select * into opr from master.operators where code = upper(trim(coalesce(p ->> 'receiver_code', '')));
  if not found then raise exception 'Chọn NV lấy NVL đã ký nhận trên phiếu'; end if;
  for e in select * from jsonb_array_elements(coalesce(p -> 'items', '[]')) loop
    v_code := upper(trim(coalesce(e ->> 'code', '')));
    continue when v_code = '';
    select * into h from inv.handling_units where hu_no = v_code;
    if not found then raise exception 'Không có mã tem %', v_code; end if;
    v_qty := nullif(e ->> 'qty', '')::numeric;
    if v_qty is not null and v_qty <= 0 then raise exception '%: số lượng thực xuất phải > 0', v_code; end if;
    v_items := v_items || jsonb_build_object('hu_id', h.id, 'qty', v_qty,
                                             'reason', nullif(trim(coalesce(p ->> 'reason', '')), ''));
  end loop;
  if jsonb_array_length(v_items) = 0 then raise exception 'Nhập ít nhất một mã tem đã xuất'; end if;
  perform set_config('bmt.paper', 'on', true);
  v_doc := inv.issue_pick(p_req, v_items, null, null, null);
  perform set_config('bmt.paper', 'off', true);
  update inv.stock_docs set paper_no = nullif(trim(coalesce(p ->> 'paper_no', '')), ''), receiver_code = opr.code, received_at = now(),
         note = note || ' · phiếu giấy, ' || opr.code || ' ký nhận'
   where id = v_doc returning doc_no into v_no;
  return jsonb_build_object('doc_id', v_doc, 'doc_no', v_no);
end $$;

-- Kế toán SX nhập phiếu nhập NVL thừa cuối ngày (TP SX nhận về kho, hai bên ký)
-- p: {paper_no, giver_code (NV trả), items: [{code (mã tem), qty (kg cân lại)}]}
create or replace function app.paper_return(p jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare opr master.operators; e jsonb; v_code text; h inv.handling_units; v_doc uuid; v_docs text[] := '{}'; v_no text; v_qty numeric;
begin
  if not mfg.can_enter_slips() then raise exception 'Chỉ Kế toán SX nhập phiếu NVL thừa (TP SX nhập thay khi Kế toán vắng)'; end if;
  select * into opr from master.operators where code = upper(trim(coalesce(p ->> 'giver_code', '')));
  if not found then raise exception 'Chọn người trả NVL thừa (ghi trên phiếu)'; end if;
  for e in select * from jsonb_array_elements(coalesce(p -> 'items', '[]')) loop
    v_code := upper(trim(coalesce(e ->> 'code', '')));
    continue when v_code = '';
    select * into h from inv.handling_units where hu_no = v_code;
    if not found then raise exception 'Không có mã tem %', v_code; end if;
    v_qty := nullif(e ->> 'qty', '')::numeric;
    if coalesce(v_qty, 0) <= 0 then raise exception '%: nhập số cân lại', v_code; end if;
    perform set_config('bmt.paper', 'on', true);
    v_doc := inv.return_hu(h.id, v_qty, null, null);
    perform set_config('bmt.paper', 'off', true);
    update inv.stock_docs set paper_no = nullif(trim(coalesce(p ->> 'paper_no', '')), ''), receiver_code = opr.code,
           note = note || ' · NVL thừa, ' || opr.code || ' trả'
     where id = v_doc returning doc_no into v_no;
    v_docs := v_docs || v_no;
  end loop;
  if cardinality(v_docs) = 0 then raise exception 'Nhập ít nhất một mã tem trả kho'; end if;
  return to_jsonb(v_docs);
end $$;

revoke execute on function app.paper_issue(uuid, jsonb), app.paper_return(jsonb) from public, anon;
grant execute on function app.paper_issue(uuid, jsonb), app.paper_return(jsonb) to authenticated;

-- ===========================================================================
-- 2. Phiếu hoàn thành bobin: ghi kg bobin đầu vào đã dùng (viết lại app.record_bobbin của 3300)
-- ===========================================================================
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
    v_hu_net := coalesce(v_hu.gross_kg, 0) - coalesce(v_hu.tare_kg, 0);
    if coalesce(v_left, 0) > 0 then
      if v_hu_net <= 0 then raise exception 'Bobin % chưa có khối lượng cân: không trừ được phần còn dư', v_code; end if;
      if v_left >= v_hu_net then raise exception 'Bobin %: kg còn dư (%) không nhỏ hơn kg trên bobin (%)', v_code, v_left, round(v_hu_net, 2); end if;
      v_used := round(v_hu.qty * (1 - v_left / v_hu_net), 2);
    else
      v_used := v_hu.qty;
    end if;
    v_inputs := v_inputs || jsonb_build_object('lot_id', v_inlot.id, 'hu_id', v_hu.id, 'qty', v_used);
    -- used_kg: kg BTP đã dùng (cân lúc làm ra − kg còn dư) để tính kg/km ruột thật và nhựa thực dùng theo công đoạn
    v_rec := v_rec || jsonb_build_object('code', v_code, 'hu_no', v_hu.hu_no, 'lot_no', v_inlot.lot_no, 'stage', v_inlot.wip_stage,
                                         'left_kg', v_left, 'used_m', v_used,
                                         'used_kg', case when v_hu_net > 0 then round(v_hu_net - coalesce(v_left, 0), 3) end);
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

-- ===========================================================================
-- 3. Báo cáo ca: Kế toán SX nhập từ tờ báo cáo ca giấy (viết lại hàm của 2200)
-- ===========================================================================
create or replace function mfg.check_shift_extras(p jsonb) returns void
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare e jsonb;
begin
  for e in select * from jsonb_array_elements(coalesce(p -> 'keeps', '[]')) loop
    if not exists (select 1 from master.materials m where m.code = e ->> 'material_code') then
      raise exception 'NVL để lại máy: không có mã vật tư %', e ->> 'material_code';
    end if;
    if coalesce((e ->> 'kg')::numeric, 0) <= 0 then raise exception 'NVL để lại máy %: nhập kg cân', e ->> 'material_code'; end if;
    if not exists (select 1 from mfg.work_orders w where w.wo_no = e ->> 'wo_no') then
      raise exception 'NVL để lại máy %: chọn lô (lệnh SX) chạy tiếp', e ->> 'material_code';
    end if;
  end loop;
  for e in select * from jsonb_array_elements(coalesce(p -> 'scraps', '[]')) loop
    if coalesce((e ->> 'kg')::numeric, 0) <= 0 then raise exception 'Phế cả ca: nhập kg'; end if;
    if not exists (select 1 from master.reason_codes rc where rc.code = e ->> 'reason' and rc.kind = 'SCRAP') then
      raise exception 'Phế cả ca: chọn lý do';
    end if;
    if not exists (select 1 from mfg.work_orders w join mfg.wo_operations o on o.wo_id = w.id
                   where w.wo_no = e ->> 'wo_no' and o.op_code = e ->> 'op_code') then
      raise exception 'Phế cả ca: chọn lô và công đoạn';
    end if;
  end loop;
end $$;
revoke execute on function mfg.check_shift_extras(jsonb) from public, anon, authenticated;

-- Lưu nháp: người vận hành, tổ trưởng, Quản lý SX; Kế toán SX nhập từ phiếu giấy
create or replace function app.kh_save_report(p_date date, p_machine text, p jsonb) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r mfg.shift_reports; v_id uuid; v_scrap numeric;
begin
  if not app.kh_has_any(array['VAN_HANH','TO_TRUONG','SX_TP','KT_KHO']) then
    raise exception 'Chỉ Kế toán SX (nhập từ báo cáo ca giấy), người vận hành, tổ trưởng, Quản lý SX nhập báo cáo ca';
  end if;
  select * into r from mfg.shift_reports where work_date = p_date and shift_code = coalesce(p->>'shift_code', 'A') and machine_code = p_machine for update;
  if found and r.status <> 'DRAFT' then raise exception 'Báo cáo ca đã gửi hoặc đã xác nhận: không sửa được'; end if;
  perform mfg.check_shift_extras(p);
  select sum((e ->> 'kg')::numeric) into v_scrap from jsonb_array_elements(coalesce(p -> 'scraps', '[]')) e;
  insert into mfg.shift_reports as t (work_date, shift_code, machine_code, operator_code, plan_id, source, lines, downtime, samples,
                                      scrap_kg, scrap_reason, note, keeps, scraps, saved_by, saved_at)
  values (p_date, coalesce(p->>'shift_code', 'A'), p_machine, p->>'operator_code', nullif(p->>'plan_id', '')::uuid,
          coalesce(p->>'source', 'MANUAL'), coalesce(p->'lines', '[]'), coalesce(p->'downtime', '[]'),
          coalesce(p->'samples', '[]'),
          coalesce(v_scrap, (p->>'scrap_kg')::numeric, 0), coalesce(p->'scraps'->0->>'reason', p->>'scrap_reason'), p->>'note',
          coalesce(p->'keeps', '[]'), coalesce(p->'scraps', '[]'), auth.uid(), now())
  on conflict (work_date, shift_code, machine_code) do update set
    operator_code = excluded.operator_code, plan_id = excluded.plan_id, source = excluded.source, lines = excluded.lines,
    downtime = excluded.downtime, scrap_kg = excluded.scrap_kg, scrap_reason = excluded.scrap_reason, note = excluded.note,
    keeps = excluded.keeps, scraps = excluded.scraps,
    samples = case when jsonb_array_length(t.samples) = 0 then excluded.samples else t.samples end,
    saved_by = auth.uid(), saved_at = now()
  returning id into v_id;
  return v_id;
end $$;

-- Gửi chốt ca. Quy trình final: QC kiểm từng bobin sau mỗi công đoạn nên chỉ chặn khi có mẫu đã bị đánh Không đạt
create or replace function app.kh_submit_report(p_id uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r mfg.shift_reports; v_min integer;
begin
  if not app.kh_has_any(array['VAN_HANH','TO_TRUONG','SX_TP','KT_KHO']) then raise exception 'Không có quyền gửi báo cáo ca'; end if;
  select * into r from mfg.shift_reports where id = p_id for update;
  if r.status <> 'DRAFT' then raise exception 'Báo cáo đã gửi'; end if;
  select downtime_reason_min into v_min from master.planning_config where id = 1;
  if exists (select 1 from jsonb_array_elements(r.downtime) e where coalesce(e->>'reason', '') = '' and (e->>'min')::numeric > v_min) then
    raise exception 'Còn lần dừng máy trên % phút chưa chọn lý do', v_min;
  end if;
  if exists (select 1 from jsonb_array_elements(r.samples) e where e->>'status' = 'NG') then
    raise exception 'Mẫu đầu ca/đầu mã không đạt: chưa gửi được báo cáo ca';
  end if;
  update mfg.shift_reports set status = 'SUBMITTED', submitted_by = auth.uid(), submitted_at = now() where id = p_id;
  perform wf.notify_users(array_remove(inv.role_users(array['SX_TP', 'TO_TRUONG']), auth.uid()), 'Báo cáo ca ' || r.machine_code || ' chờ chốt',
    to_char(r.work_date, 'DD/MM') || ' · ca ' || r.shift_code, '/ghi-nhan-ca?d=' || r.work_date || '&m=' || r.machine_code);
end $$;

-- Chốt ca (TP SX; vắng thì tổ phó NV1): ghi phế cả ca vào sổ phế của lô
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
end $$;

-- ===========================================================================
-- 4. Hao hụt theo công đoạn, theo lô (tính đến hết ngày p_date, giờ VN)
-- ===========================================================================
-- Vật tư của lô: cấp − trả theo ngày làm việc của phiếu lĩnh; NVL để lại máy lấy ở báo cáo ca gần nhất của từng máy
create or replace function mfg.wo_mat_use(p_wo uuid, p_date date)
returns table (material_id uuid, grp text, op text, uom text, q numeric, lr numeric, su numeric, net numeric, keep numeric)
language sql stable security definer set search_path = pg_catalog, public as $$
  with w as (select * from mfg.work_orders where id = p_wo),
  bom as (select bl.material_id, max(coalesce(bl.operation_code, '')) as op, sum(bl.qty_per_basis) as q,
                 sum(bl.qty_per_basis * bl.loss_rate) / nullif(sum(bl.qty_per_basis), 0) as lr,
                 sum(bl.startup_per_lot) * max(coalesce(w.run_lots, 1)) as su
          from master.bom_lines bl, w where bl.bom_id = w.bom_id and bl.basis = 'KM' group by bl.material_id),
  mv as (select l.material_id, sum(-sm.qty) as net
         from inv.stock_docs d join inv.stock_moves sm on sm.doc_id = d.id
         join inv.lots l on l.id = sm.lot_id and l.item_kind = 'MAT'
         left join inv.requisitions rq on rq.id = d.requisition_id
         where d.ref_type = 'WO' and d.ref_id = p_wo and d.status = 'POSTED' and d.doc_type in ('ISSUE_WO', 'RETURN_WO')
           and coalesce(rq.work_date, d.doc_date) <= p_date
         group by l.material_id),
  lastrep as (select distinct on (r.machine_code) r.keeps from mfg.shift_reports r where r.work_date <= p_date
              order by r.machine_code, r.work_date desc, r.shift_code desc),
  kp as (select m.id as material_id, sum((k ->> 'kg')::numeric) as kg
         from lastrep cross join jsonb_array_elements(lastrep.keeps) k
         join master.materials m on m.code = k ->> 'material_code'
         where k ->> 'wo_no' = (select w.wo_no from w) group by m.id)
  select m.id, m.group_code, bom.op, m.uom, coalesce(bom.q, 0), coalesce(bom.lr, 0), coalesce(bom.su, 0),
         coalesce(mv.net, 0), coalesce(kp.kg, 0)
  from (select bom.material_id from bom union select mv.material_id from mv union select kp.material_id from kp) ids
  join master.materials m on m.id = ids.material_id
  left join bom on bom.material_id = ids.material_id
  left join mv on mv.material_id = ids.material_id
  left join kp on kp.material_id = ids.material_id
$$;

-- Mức cảnh báo: trong định mức → xanh; vượt nhưng trong ngưỡng → vàng; vượt ngưỡng → đỏ; chưa có đầu ra → chưa tính
create or replace function mfg.loss_level(p_var numeric, p_tol numeric) returns text
language sql immutable as $$
  select case when p_var is null then 'NA' when p_var <= 0 then 'GREEN' when p_var <= p_tol then 'YELLOW' else 'RED' end
$$;

create or replace function mfg.loss_stages(p_wo uuid, p_date date)
returns table (stage text, label text, uom text, in_qty numeric, out_qty numeric, loss_qty numeric, loss_pct numeric,
               norm_in numeric, var_pct numeric, tol_pct numeric, level text, detail text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  w mfg.work_orders; sp master.product_specs; sr master.spec_results;
  v_end timestamptz := ((p_date + 1)::timestamp) at time zone 'Asia/Ho_Chi_Minh';
  v_tw numeric := coalesce(inv.setting('twist_factor'), 1);
  v_mloss numeric := coalesce(inv.setting('m_loss_pct'), 1);
  v_mtol numeric := coalesce(inv.setting('m_tol_pct'), 2);
  v_cutol numeric := coalesce(inv.setting('copper_tol_pct'), 3);
  v_pltol numeric := coalesce(inv.setting('plastic_tol_pct'), 10);
  v_gtol numeric := coalesce(inv.setting('giveaway_tol_pct'), 2);
  v_in numeric; v_keep numeric; v_lr numeric; v_su numeric; v_out numeric; v_scrap numeric; v_norm numeric;
  v_cond numeric; v_core_m numeric; v_core_kg numeric; v_design numeric; v_act numeric; x record;
begin
  select * into w from mfg.work_orders where id = p_wo;
  if not found then return; end if;
  select * into sp from master.product_specs where id = w.spec_id;
  select * into sr from master.spec_results where spec_id = w.spec_id;

  -- Bện: kg đồng cấp ròng (trừ đồng còn trên giá xả) → kg ruột bện cân được
  select coalesce(sum(u.net - u.keep), 0), coalesce(sum(u.keep), 0),
         coalesce(sum(u.q * u.lr) / nullif(sum(u.q), 0), 0), coalesce(sum(u.su), 0)
    into v_in, v_keep, v_lr, v_su
    from mfg.wo_mat_use(p_wo, p_date) u where u.grp = 'CONDUCTOR' and coalesce(u.op, 'CD1') = 'CD1';
  select coalesce(sum(s.net_kg), 0) into v_out from mfg.bobbin_slips s
   where s.wo_id = p_wo and s.op_code = 'CD1' and s.status = 'ACTIVE' and s.ended_at < v_end;
  select coalesce(sum(r.qty_kg), 0) into v_scrap from mfg.scrap_records r join mfg.wo_operations o on o.id = r.wo_op_id
   where o.wo_id = p_wo and o.op_code = 'CD1' and r.recorded_at < v_end;
  if v_in > 0 or v_out > 0 then
    v_norm := case when v_out > 0 then v_out / (1 - v_lr) + v_su end;
    stage := 'CD1_CU'; label := 'Bện – đồng'; uom := 'kg';
    in_qty := round(v_in, 2); out_qty := round(v_out, 2); loss_qty := round(v_in - v_out, 2);
    loss_pct := round((v_in - v_out) / nullif(v_in, 0) * 100, 2); norm_in := round(v_norm, 2);
    var_pct := round((v_in - v_norm) / nullif(v_norm, 0) * 100, 2); tol_pct := v_cutol;
    level := case when v_out > 0 and v_in > 0 then mfg.loss_level(var_pct, v_cutol) else 'NA' end;
    detail := format('Đã ghi phế đồng %s kg · còn trên giá xả %s kg · định mức hao hụt %s %%', core.vn_num(round(v_scrap, 2)), core.vn_num(round(v_keep, 2)), core.vn_num(round(v_lr * 100, 2)));
    return next;
  end if;

  -- Bọc cách điện: kg ruột đã dùng (bobin bện) ÷ km lõi theo đồng hồ line đùn = kg/km ruột thật
  select coalesce(sum(c.cond), 0), coalesce(sum(c.qty_m), 0), coalesce(sum(c.net_kg), 0) into v_cond, v_core_m, v_core_kg
    from (select s.qty_m, s.net_kg,
                 (select sum((i ->> 'used_kg')::numeric) from jsonb_array_elements(s.inputs) i where i ->> 'stage' = 'CB') as cond
          from mfg.bobbin_slips s where s.wo_id = p_wo and s.op_code = 'CD2' and s.status = 'ACTIVE' and s.ended_at < v_end) c
   where c.cond > 0;
  if v_core_m > 0 then
    v_design := case when coalesce(sr.metal_kgkm, 0) > 0 and coalesce(sp.cores, 0) > 0 then sr.metal_kgkm / sp.cores end;
    v_act := v_cond / (v_core_m / 1000);
    stage := 'CD2_CU'; label := 'Bọc cách điện – ruột thật (đồng hồ line đùn)'; uom := 'kg/km';
    in_qty := round(v_cond, 2); out_qty := round(v_core_m, 1); loss_qty := null; loss_pct := null;
    norm_in := round(v_design, 3); var_pct := round((v_act / nullif(v_design, 0) - 1) * 100, 2); tol_pct := v_gtol;
    level := mfg.loss_level(var_pct, v_gtol);
    detail := format('%s kg ruột qua %s m lõi: %s kg/km thật, thiết kế %s kg/km (cho thừa vật liệu khi nặng hơn)',
                     core.vn_num(round(v_cond, 2)), core.vn_num(round(v_core_m, 1)), core.vn_num(round(v_act, 3)), core.vn_num(round(v_design, 3)));
    return next;
  end if;

  -- Bọc cách điện: nhựa cấp ròng (phối trộn + bọc) → nhựa trên lõi = kg lõi − kg ruột
  select coalesce(sum(u.net - u.keep), 0), coalesce(sum(u.keep), 0),
         coalesce(sum(u.q * u.lr) / nullif(sum(u.q), 0), 0), coalesce(sum(u.su), 0)
    into v_in, v_keep, v_lr, v_su
    from mfg.wo_mat_use(p_wo, p_date) u where u.grp in ('COMPOUND', 'ADDITIVE', 'COLOR') and u.op in ('CD0', 'CD2');
  v_out := greatest(v_core_kg - v_cond, 0);
  if v_in > 0 or v_out > 0 then
    v_norm := case when v_out > 0 then v_out / (1 - v_lr) + v_su end;
    stage := 'CD2_PL'; label := 'Bọc cách điện – nhựa'; uom := 'kg';
    in_qty := round(v_in, 2); out_qty := round(v_out, 2); loss_qty := round(v_in - v_out, 2);
    loss_pct := round((v_in - v_out) / nullif(v_in, 0) * 100, 2); norm_in := round(v_norm, 2);
    var_pct := round((v_in - v_norm) / nullif(v_norm, 0) * 100, 2); tol_pct := v_pltol;
    level := case when v_out > 0 and v_in > 0 then mfg.loss_level(var_pct, v_pltol) else 'NA' end;
    detail := format('Nhựa trên lõi %s kg/km (thiết kế %s) · còn trong phễu %s kg',
                     coalesce(core.vn_num(round(v_out / nullif(v_core_m / 1000, 0), 3)), '—'),
                     coalesce(core.vn_num(round(sr.ins_kgkm / nullif(sp.cores, 0), 3)), '—'), core.vn_num(round(v_keep, 2)));
    return next;
  end if;

  -- Xoắn, quấn băng, bọc vỏ, đóng gói: mét vào (bobin đầu vào đã dùng) so với mét ra
  for x in select c.op_code, sum(c.in_m) as in_m, sum(c.qty_m * c.f) as out_eq, sum(c.qty_m) as out_m, max(c.f) as f
           from (select s.op_code, s.qty_m,
                        (select sum((i ->> 'used_m')::numeric) from jsonb_array_elements(s.inputs) i) as in_m,
                        case when exists (select 1 from jsonb_array_elements(s.inputs) i where i ->> 'stage' = 'LB')
                             then greatest(coalesce(sp.cores, 1), 1) * v_tw else 1 end as f
                 from mfg.bobbin_slips s
                 where s.wo_id = p_wo and s.status = 'ACTIVE' and s.ended_at < v_end and s.op_code in ('CD3', 'CD4', 'CD5', 'CD6')) c
           where c.in_m > 0
           group by c.op_code order by c.op_code loop
    v_norm := x.out_eq * (1 + v_mloss / 100);
    stage := x.op_code || '_M';
    label := case x.op_code when 'CD3' then 'Xoắn – mét lõi' when 'CD4' then 'Quấn băng – mét' when 'CD5' then 'Bọc vỏ – mét' else 'Đóng gói – mét' end;
    uom := 'm'; in_qty := round(x.in_m, 1); out_qty := round(x.out_eq, 1); loss_qty := round(x.in_m - x.out_eq, 1);
    loss_pct := round((x.in_m - x.out_eq) / x.in_m * 100, 2); norm_in := round(v_norm, 1);
    var_pct := round((x.in_m - v_norm) / nullif(v_norm, 0) * 100, 2); tol_pct := v_mtol;
    level := mfg.loss_level(var_pct, v_mtol);
    detail := case when x.f > 1 then format('%s m cáp × %s lõi × hệ số xoắn %s · định mức hao hụt %s %%', core.vn_num(round(x.out_m, 1)), sp.cores, core.vn_num(v_tw), core.vn_num(v_mloss))
                   else format('Định mức hao hụt %s %%', core.vn_num(v_mloss)) end;
    return next;
  end loop;

  -- Bọc vỏ: nhựa vỏ cấp ròng → nhựa trên cáp = kg ra − kg bobin đầu vào đã dùng
  select coalesce(sum(c.out_kg - c.in_kg), 0), coalesce(sum(c.qty_m), 0) into v_out, v_core_m
    from (select s.net_kg as out_kg, s.qty_m,
                 (select sum((i ->> 'used_kg')::numeric) from jsonb_array_elements(s.inputs) i) as in_kg
          from mfg.bobbin_slips s where s.wo_id = p_wo and s.op_code = 'CD5' and s.status = 'ACTIVE' and s.ended_at < v_end) c
   where c.in_kg > 0;
  v_out := greatest(v_out, 0);
  select coalesce(sum(u.net - u.keep), 0), coalesce(sum(u.keep), 0),
         coalesce(sum(u.q * u.lr) / nullif(sum(u.q), 0), 0), coalesce(sum(u.su), 0)
    into v_in, v_keep, v_lr, v_su
    from mfg.wo_mat_use(p_wo, p_date) u where u.grp in ('COMPOUND', 'ADDITIVE', 'COLOR') and u.op = 'CD5';
  if v_in > 0 or v_out > 0 then
    v_norm := case when v_out > 0 then v_out / (1 - v_lr) + v_su end;
    stage := 'CD5_PL'; label := 'Bọc vỏ – nhựa vỏ'; uom := 'kg';
    in_qty := round(v_in, 2); out_qty := round(v_out, 2); loss_qty := round(v_in - v_out, 2);
    loss_pct := round((v_in - v_out) / nullif(v_in, 0) * 100, 2); norm_in := round(v_norm, 2);
    var_pct := round((v_in - v_norm) / nullif(v_norm, 0) * 100, 2); tol_pct := v_pltol;
    level := case when v_out > 0 and v_in > 0 then mfg.loss_level(var_pct, v_pltol) else 'NA' end;
    detail := format('Nhựa vỏ %s kg/km (thiết kế %s) · còn trong phễu %s kg',
                     coalesce(core.vn_num(round(v_out / nullif(v_core_m / 1000, 0), 3)), '—'), coalesce(core.vn_num(round(sr.sheath_kgkm, 3)), '—'), core.vn_num(round(v_keep, 2)));
    return next;
  end if;
end $$;
revoke execute on function mfg.wo_mat_use(uuid, date), mfg.loss_stages(uuid, date) from public, anon, authenticated;

create or replace function app.loss_stages(p_wo uuid, p_date date default null)
returns table (stage text, label text, uom text, in_qty numeric, out_qty numeric, loss_qty numeric, loss_pct numeric,
               norm_in numeric, var_pct numeric, tol_pct numeric, level text, detail text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if not app.can_see_loss() then raise exception 'Không có quyền xem báo cáo hao hụt'; end if;
  return query select * from mfg.loss_stages(p_wo, coalesce(p_date, (now() at time zone 'Asia/Ho_Chi_Minh')::date));
end $$;
revoke execute on function app.loss_stages(uuid, date) from public, anon;
grant execute on function app.loss_stages(uuid, date) to authenticated;

-- ===========================================================================
-- 5. Báo cáo ngày: sản lượng theo máy, QC, NVL xuất – thừa – để lại máy, báo cáo ca, hao hụt từng lô (xanh / vàng / đỏ)
-- ===========================================================================
create or replace function mfg.daily_report_data(p_date date) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_start timestamptz := (p_date::timestamp) at time zone 'Asia/Ho_Chi_Minh';
        v_end timestamptz := ((p_date + 1)::timestamp) at time zone 'Asia/Ho_Chi_Minh';
        v_qcmin numeric := coalesce(inv.setting('qc_result_minutes'), 120);
        v_prod jsonb; v_qc jsonb; v_mat jsonb; v_keeps jsonb; v_shift jsonb; v_loss jsonb; v_wos uuid[];
begin
  select coalesce(jsonb_agg(to_jsonb(x) order by x.machine_code, x.op_code), '[]') into v_prod from (
    select coalesce(mc.code, '—') as machine_code, s.op_code, op.name as op_name, count(*) as slips, round(sum(s.qty_m), 1) as m,
           round(sum(s.net_kg), 2) as kg, bool_or(s.qty_estimated) as est, round(sum(coalesce(s.scrap_kg, 0)), 2) as scrap_kg
    from mfg.bobbin_slips s
    left join master.machines mc on mc.id = s.machine_id
    left join master.operations op on op.code = s.op_code
    where s.status = 'ACTIVE' and s.ended_at >= v_start and s.ended_at < v_end
    group by mc.code, s.op_code, op.name) x;

  select jsonb_build_object(
           'made', count(*) filter (where l.created_at >= v_start and l.created_at < v_end),
           'passed', count(*) filter (where l.created_at >= v_start and l.created_at < v_end and l.qc_status in ('PASSED', 'CONSUMED')),
           'failed', count(*) filter (where l.created_at >= v_start and l.created_at < v_end and l.qc_status in ('REJECTED', 'QUARANTINE')),
           'pending_now', count(*) filter (where l.qc_status = 'PENDING'),
           'late_now', count(*) filter (where l.qc_status = 'PENDING' and l.created_at < now() - make_interval(mins => v_qcmin::int)))
    into v_qc
    from inv.lots l
   where l.item_kind in ('WIP', 'FG') and l.wo_op_id is not null and not (l.attrs ? 'void_slip')
     and (l.qc_status = 'PENDING' or (l.created_at >= v_start and l.created_at < v_end));

  select array_agg(distinct t.wid) into v_wos from (
    select s.wo_id as wid from mfg.bobbin_slips s where s.status = 'ACTIVE' and s.ended_at >= v_start and s.ended_at < v_end
    union
    select d.ref_id from inv.stock_docs d left join inv.requisitions rq on rq.id = d.requisition_id
     where d.ref_type = 'WO' and d.status = 'POSTED' and d.doc_type in ('ISSUE_WO', 'RETURN_WO')
       and coalesce(rq.work_date, d.doc_date) = p_date
       and exists (select 1 from inv.stock_doc_lines dl join inv.lots l on l.id = dl.lot_id where dl.doc_id = d.id and l.item_kind = 'MAT')
  ) t;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.wo_no, x.material_code), '[]') into v_mat from (
    select w.wo_no, m.code as material_code, m.name as material_name, m.uom,
           round(coalesce(sum(-sm.qty) filter (where d.doc_type = 'ISSUE_WO'), 0), 3) as issued,
           round(coalesce(sum(sm.qty) filter (where d.doc_type = 'RETURN_WO'), 0), 3) as returned
    from inv.stock_docs d
    join inv.stock_moves sm on sm.doc_id = d.id
    join inv.lots l on l.id = sm.lot_id and l.item_kind = 'MAT'
    join master.materials m on m.id = l.material_id
    join mfg.work_orders w on w.id = d.ref_id
    left join inv.requisitions rq on rq.id = d.requisition_id
    where d.ref_type = 'WO' and d.status = 'POSTED' and d.doc_type in ('ISSUE_WO', 'RETURN_WO') and coalesce(rq.work_date, d.doc_date) = p_date
    group by w.wo_no, m.code, m.name, m.uom) x;

  select coalesce(jsonb_agg(jsonb_build_object('machine_code', r.machine_code, 'shift_code', r.shift_code) || k order by r.machine_code), '[]')
    into v_keeps
    from mfg.shift_reports r cross join jsonb_array_elements(r.keeps) k where r.work_date = p_date;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.machine_code, x.shift_code), '[]') into v_shift from (
    select mc.code as machine_code, mc.name as machine_name, r.shift_code, coalesce(r.status, 'MISSING') as status,
           (select coalesce(sum((e ->> 'min')::numeric), 0) from jsonb_array_elements(coalesce(r.downtime, '[]')) e) as downtime_min,
           coalesce(r.scrap_kg, 0) as shift_scrap_kg,
           (select count(*) from mfg.bobbin_slips s where s.machine_id = mc.id and s.status = 'ACTIVE' and s.ended_at >= v_start and s.ended_at < v_end) as slips
    from master.machines mc
    left join mfg.shift_reports r on r.machine_code = mc.code and r.work_date = p_date
    where r.id is not null
       or exists (select 1 from mfg.bobbin_slips s where s.machine_id = mc.id and s.status = 'ACTIVE' and s.ended_at >= v_start and s.ended_at < v_end)) x;

  select coalesce(jsonb_agg(jsonb_build_object('wo_id', w.id, 'wo_no', w.wo_no, 'product_code', p.code, 'wo_status', w.status) || to_jsonb(ls)
                            || jsonb_build_object('note', n.note, 'noted_by', app.user_name(n.noted_by), 'noted_at', n.noted_at)
                            order by w.wo_no, ls.stage), '[]')
    into v_loss
    from unnest(coalesce(v_wos, '{}'::uuid[])) wid
    join mfg.work_orders w on w.id = wid
    join master.products p on p.id = w.product_id
    cross join lateral mfg.loss_stages(w.id, p_date) ls
    left join mfg.loss_notes n on n.wo_id = w.id and n.stage = ls.stage and n.work_date = p_date;

  return jsonb_build_object(
    'date', p_date, 'production', v_prod, 'qc', v_qc, 'materials', v_mat, 'keeps', v_keeps, 'shifts', v_shift, 'loss', v_loss,
    'counts', (select jsonb_build_object(
                 'GREEN', count(*) filter (where e ->> 'level' = 'GREEN'), 'YELLOW', count(*) filter (where e ->> 'level' = 'YELLOW'),
                 'RED', count(*) filter (where e ->> 'level' = 'RED'), 'NA', count(*) filter (where e ->> 'level' = 'NA'))
               from jsonb_array_elements(v_loss) e),
    'sent', (select jsonb_build_object('sent_at', dr.sent_at, 'auto', dr.auto, 'by', app.user_name(dr.sent_by))
             from mfg.daily_reports dr where dr.work_date = p_date));
end $$;
revoke execute on function mfg.daily_report_data(date) from public, anon, authenticated;

create or replace function app.daily_report(p_date date) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if not app.can_see_loss() then raise exception 'Không có quyền xem báo cáo sản xuất ngày'; end if;
  return mfg.daily_report_data(p_date);
end $$;

-- Gửi báo cáo ngày + cảnh báo: TP SX, Kế toán SX, Giám đốc, tổ trưởng; mục đỏ báo riêng Giám đốc (email ngay) và TP SX giải trình
create or replace function mfg.send_daily_report(p_date date, p_auto boolean) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v jsonb; v_red jsonb; v_c jsonb; v_slips int; v_m numeric; v_body text; v_lines text; v_link text := '/bao-cao/ngay?d=' || p_date;
begin
  v := mfg.daily_report_data(p_date);
  v_c := v -> 'counts';
  select coalesce(jsonb_agg(jsonb_build_object('wo_id', e ->> 'wo_id', 'wo_no', e ->> 'wo_no', 'stage', e ->> 'stage',
                                               'label', e ->> 'label', 'var_pct', e -> 'var_pct')), '[]')
    into v_red from jsonb_array_elements(v -> 'loss') e where e ->> 'level' = 'RED';
  select coalesce(sum((e ->> 'slips')::int), 0), coalesce(sum((e ->> 'm')::numeric), 0) into v_slips, v_m
    from jsonb_array_elements(v -> 'production') e;
  v_body := format('%s bobin, %s m theo phiếu hoàn thành. QC: %s bobin đang chờ, %s quá hạn. Hao hụt: %s đỏ, %s vàng, %s xanh.',
                   v_slips, core.vn_num(round(v_m)), v -> 'qc' ->> 'pending_now', v -> 'qc' ->> 'late_now',
                   v_c ->> 'RED', v_c ->> 'YELLOW', v_c ->> 'GREEN');
  select string_agg(format('%s · %s: vượt định mức %s %%', e ->> 'wo_no', e ->> 'label', core.vn_num((e ->> 'var_pct')::numeric)), E'\n') into v_lines
    from jsonb_array_elements(v_red) e;
  perform wf.notify_users(inv.role_users(array['SX_TP', 'KT_KHO', 'BGD', 'TO_TRUONG']),
    'Báo cáo sản xuất ngày ' || to_char(p_date, 'DD/MM'), v_body || coalesce(E'\nMục đỏ:\n' || v_lines, ''), v_link);
  if jsonb_array_length(v_red) > 0 then
    perform wf.notify_users(inv.role_users(array['BGD']),
      'Cảnh báo đỏ hao hụt ngày ' || to_char(p_date, 'DD/MM') || ': ' || jsonb_array_length(v_red) || ' mục', v_lines, v_link);
    perform wf.notify_users(inv.role_users(array['SX_TP']),
      'Giải trình hao hụt đỏ ngày ' || to_char(p_date, 'DD/MM') || ' trước 10:00 hôm sau', v_lines, v_link);
  end if;
  insert into mfg.daily_reports (work_date, sent_at, sent_by, auto, summary)
  values (p_date, now(), case when p_auto then null else auth.uid() end, p_auto,
          jsonb_build_object('counts', v_c, 'red', v_red, 'slips', v_slips, 'm', round(v_m, 1)))
  on conflict (work_date) do update set sent_at = excluded.sent_at, sent_by = excluded.sent_by, auto = excluded.auto, summary = excluded.summary;
  return jsonb_build_object('counts', v_c, 'slips', v_slips, 'm', round(v_m, 1));
end $$;
revoke execute on function mfg.send_daily_report(date, boolean) from public, anon, authenticated;

-- Kế toán SX bấm gửi sau khi đối soát xong (gửi lại được khi sửa số liệu)
create or replace function app.send_daily_report(p_date date) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if not (mfg.can_enter_slips() or core.has_role('BGD')) then raise exception 'Chỉ Kế toán SX (sau đối soát) hoặc TP SX gửi báo cáo ngày'; end if;
  if p_date > (now() at time zone 'Asia/Ho_Chi_Minh')::date then raise exception 'Chưa đến ngày %', to_char(p_date, 'DD/MM'); end if;
  return mfg.send_daily_report(p_date, false);
end $$;

-- 19:30: chưa ai gửi mà trong ngày có phiếu hoàn thành hoặc phiếu xuất/nhập NVL → MES tự gửi
create or replace function mfg.daily_report_auto() returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare d date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
begin
  if exists (select 1 from mfg.daily_reports where work_date = d) then return 0; end if;
  if not exists (select 1 from mfg.bobbin_slips s where s.status = 'ACTIVE' and (s.ended_at at time zone 'Asia/Ho_Chi_Minh')::date = d)
     and not exists (select 1 from inv.stock_docs x left join inv.requisitions rq on rq.id = x.requisition_id
                     where x.ref_type = 'WO' and x.status = 'POSTED' and x.doc_type in ('ISSUE_WO', 'RETURN_WO')
                       and coalesce(rq.work_date, x.doc_date) = d) then
    return 0;
  end if;
  perform mfg.send_daily_report(d, true);
  return 1;
end $$;

-- 10:00: mục đỏ chưa giải trình → báo Giám đốc và TP SX (mỗi mục một lần)
create or replace function mfg.loss_note_check() returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r record; v_n int := 0; d date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
begin
  for r in select dr.work_date, (e ->> 'wo_id')::uuid as wo_id, e ->> 'wo_no' as wo_no, e ->> 'stage' as stage, e ->> 'label' as label
           from mfg.daily_reports dr cross join jsonb_array_elements(dr.summary -> 'red') e
           where dr.work_date >= d - 7 and dr.work_date < d
             and not exists (select 1 from mfg.loss_notes n where n.wo_id = (e ->> 'wo_id')::uuid and n.stage = e ->> 'stage'
                                                              and n.work_date = dr.work_date) loop
    insert into inv.alert_log (kind, ref_id, period_key) values ('LOSSNOTE', r.wo_id, r.work_date || ' ' || r.stage) on conflict do nothing;
    continue when not found;
    perform wf.notify_users(inv.role_users(array['BGD', 'SX_TP']), 'Chưa giải trình hao hụt đỏ: ' || r.wo_no,
      r.label || ' ngày ' || to_char(r.work_date, 'DD/MM') || ' (hạn 10:00 hôm sau)', '/bao-cao/ngay?d=' || r.work_date);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke execute on function mfg.daily_report_auto(), mfg.loss_note_check() from public, anon, authenticated;

-- TP SX giải trình (bắt buộc với mục đỏ), Giám đốc ghi chỉ đạo
create or replace function app.save_loss_note(p_wo uuid, p_stage text, p_date date, p_note text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_level text; v_wo text;
begin
  if not app.kh_has_any(array['SX_TP', 'BGD']) then raise exception 'Chỉ TP SX (giải trình) hoặc Giám đốc ghi chú hao hụt'; end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'Nhập nội dung giải trình'; end if;
  select ls.level into v_level from mfg.loss_stages(p_wo, p_date) ls where ls.stage = p_stage;
  if v_level is null then raise exception 'Không có mục hao hụt này trong ngày %', to_char(p_date, 'DD/MM'); end if;
  insert into mfg.loss_notes (wo_id, stage, work_date, level, note) values (p_wo, p_stage, p_date, v_level, trim(p_note))
  on conflict (wo_id, stage, work_date) do update set note = excluded.note, level = excluded.level, noted_by = auth.uid(), noted_at = now();
  if v_level = 'RED' then
    select wo_no into v_wo from mfg.work_orders where id = p_wo;
    perform wf.notify_users(array_remove(inv.role_users(array['BGD']), auth.uid()), 'Đã giải trình hao hụt đỏ: ' || v_wo,
      to_char(p_date, 'DD/MM') || ' · ' || trim(p_note), '/bao-cao/ngay?d=' || p_date);
  end if;
end $$;

revoke execute on function app.daily_report(date), app.send_daily_report(date), app.save_loss_note(uuid, text, date, text) from public, anon;
grant execute on function app.daily_report(date), app.send_daily_report(date), app.save_loss_note(uuid, text, date, text) to authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('bmt_daily_report', '30 12 * * *', 'select mfg.daily_report_auto()');   -- 19:30 giờ Việt Nam
    perform cron.schedule('bmt_loss_note', '0 3 * * *', 'select mfg.loss_note_check()');          -- 10:00 giờ Việt Nam
  end if;
exception when others then
  raise notice 'Bỏ qua pg_cron: %', sqlerrm;
end $$;

-- ===========================================================================
-- 6. View cho web
-- ===========================================================================
-- Báo cáo ca: thêm NVL để lại máy, phế cả ca (tạo lại vì r.* đổi cột)
drop view if exists app.v_kh_reports;
create view app.v_kh_reports with (security_invoker = true) as
select r.*, app.user_name(r.submitted_by) as submitted_by_name, app.user_name(r.confirmed_by) as confirmed_by_name
from mfg.shift_reports r;
grant select on app.v_kh_reports to authenticated, service_role;

-- Phiếu hoàn thành: bobin bện thêm mét thật đo ở line đùn khi bọc (kg đã dùng ÷ kg/km thật)
create or replace view app.v_bobbin_slips with (security_invoker = true) as
select s.id, s.slip_no, s.paper_no, s.status, s.void_reason, s.recorded_at, s.op_code, op.name as op_name, wo.wo_no, p.code as product_code,
       mc.code as machine_code, ca.code as carrier_code, s.operator_code, s.started_at, s.ended_at, s.gross_kg, s.tare_kg, s.net_kg,
       s.meter_start, s.meter_end, s.qty_m, s.qty_estimated, s.inputs, s.materials, s.scrap_kg, s.scrap_reason, s.readings, s.note,
       l.lot_no, l.qc_status, h.hu_no, pr.full_name as recorded_by_name,
       ((s.ended_at at time zone 'Asia/Ho_Chi_Minh')::date) as work_date,
       t.used_kg as true_used_kg, t.true_m
from mfg.bobbin_slips s
join mfg.work_orders wo on wo.id = s.wo_id
join master.products p on p.id = wo.product_id
join master.operations op on op.code = s.op_code
left join master.machines mc on mc.id = s.machine_id
left join inv.carriers ca on ca.id = s.carrier_id
left join inv.lots l on l.id = s.lot_id
left join inv.handling_units h on h.id = s.hu_id
left join core.profiles pr on pr.id = s.recorded_by
left join lateral (
  select round(sum((i ->> 'used_kg')::numeric), 2) as used_kg,
         round(sum(s2.qty_m * (i ->> 'used_kg')::numeric
                   / nullif((select sum((j ->> 'used_kg')::numeric) from jsonb_array_elements(s2.inputs) j where j ->> 'stage' = 'CB'), 0)), 1) as true_m
  from mfg.bobbin_slips s2 cross join jsonb_array_elements(s2.inputs) i
  where s.op_code = 'CD1' and s2.wo_id = s.wo_id and s2.op_code = 'CD2' and s2.status = 'ACTIVE' and i ->> 'lot_no' = l.lot_no
) t on true;
grant select on app.v_bobbin_slips to authenticated;

-- Phiếu xuất NVL / nhập NVL thừa theo lô (Kế toán SX đối soát)
create or replace view app.v_wo_mat_docs with (security_invoker = true) as
select d.id, d.doc_no, d.doc_type, d.status, d.doc_date, coalesce(rq.work_date, d.doc_date) as work_date, d.paper_no, d.receiver_code,
       d.posted_at, d.reversed_by, d.reversal_of, app.user_name(d.created_by) as created_by_name, rq.req_no, rq.id as req_id,
       w.id as wo_id, w.wo_no, p.code as product_code,
       (select string_agg(m.code || ' ' || trim_scale(dl.qty) || ' ' || m.uom || ' (' || h.hu_no || ')', ', ' order by dl.line_no)
          from inv.stock_doc_lines dl join inv.lots l on l.id = dl.lot_id join master.materials m on m.id = l.material_id
          left join inv.handling_units h on h.id = dl.hu_id where dl.doc_id = d.id) as lines
from inv.stock_docs d
join mfg.work_orders w on w.id = d.ref_id
join master.products p on p.id = w.product_id
left join inv.requisitions rq on rq.id = d.requisition_id
where d.ref_type = 'WO' and d.doc_type in ('ISSUE_WO', 'RETURN_WO')
  and exists (select 1 from inv.stock_doc_lines dl join inv.lots l on l.id = dl.lot_id where dl.doc_id = d.id and l.item_kind = 'MAT');
grant select on app.v_wo_mat_docs to authenticated;
