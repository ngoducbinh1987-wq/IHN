-- BMT MES · 0700 · Nghiệp vụ: định mức, phát hành spec, ghi sổ kho (bình quân di động), MRP, ATP, truy xuất, duyệt, giá thành

-- ===========================================================================
-- 1. Định mức (CAL-01…06) — khớp file Excel bản 3.0 cho 78/78 SKU
-- ===========================================================================
create or replace function master.param(p_set uuid, p_code text) returns numeric
language sql stable as $$
  select value from master.tech_params where set_id = p_set and code = p_code
$$;

create or replace function master.calc_spec(p_spec uuid) returns master.spec_results
language plpgsql security definer set search_path = master, public as $$
declare
  s master.product_specs; c master.core_types; r master.spec_results;
  v_a numeric; v_d numeric; v_k numeric; v_p numeric; v_rho_ins numeric; v_rho_cu numeric; v_rho_r numeric;
begin
  select * into s from master.product_specs where id = p_spec;
  if not found then raise exception 'Không tìm thấy spec %', p_spec; end if;
  select * into c from master.core_types where set_id = s.param_set_id and code = s.core_code;
  if not found then raise exception 'Thiếu mã lõi % trong bộ tham số', s.core_code; end if;

  v_a := s.wire_count * pi() * s.wire_dia_mm ^ 2 / 4;                               -- CAL-01
  v_d := sqrt(4 * v_a / pi() / c.fill_factor);                                     -- CAL-02
  v_k := sqrt(1 + (2 * pi() * ((v_d - s.wire_dia_mm) / 2 * master.param(s.param_set_id, 'rFactor')) / s.pitch_mm) ^ 2);  -- CAL-03
  v_p := v_d + 2 * s.ins_thickness_mm;
  v_rho_cu := case s.conductor_mat when 'TC' then master.param(s.param_set_id, 'rhoTC') else master.param(s.param_set_id, 'rhoCu') end;
  v_rho_r  := case s.conductor_mat when 'TC' then master.param(s.param_set_id, 'rhoRTC') else master.param(s.param_set_id, 'rhoR') end;
  v_rho_ins := case s.insulation when 'SIL' then master.param(s.param_set_id, 'rhoSi')
                                 when 'HDPE' then master.param(s.param_set_id, 'rhoHD')
                                 else master.param(s.param_set_id, 'rhoPI') end;

  select * into r from master.spec_results where spec_id = p_spec;
  r.spec_id := p_spec;
  r.a_total_mm2 := v_a; r.bundle_dia_mm := v_d; r.k_strand := v_k; r.core_dia_mm := v_p;
  r.metal_kgkm := v_a * v_rho_cu * v_k * s.cores * s.lay_factor;                               -- CAL-04
  r.ins_kgkm := (pi() / 4 * (v_p ^ 2 - v_d ^ 2)
                 + master.param(s.param_set_id, 'fillCu') * (pi() / 4 * v_d ^ 2 - v_a)) * v_rho_ins * s.cores * s.lay_factor;  -- CAL-05
  r.rdc_calc := v_rho_r * 1000 * v_k * s.lay_factor / v_a;                                       -- CAL-06
  r.rdc_limit := c.rdc_limit;
  -- Các lớp vỏ/độn/băng/drain (CAL-07, 08, 10) giữ giá trị đã nhập từ Excel hoặc do KT nhập
  r.total_kgkm := coalesce(r.metal_kgkm,0) + coalesce(r.ins_kgkm,0) + coalesce(r.sheath_kgkm,0) + coalesce(r.pp_kgkm,0)
                + coalesce(r.pet_kgkm,0) + coalesce(r.alpet_kgkm,0) + coalesce(r.drain_kgkm,0);
  r.calculated_at := now();

  insert into master.spec_results values (r.*)
  on conflict (spec_id) do update set
    a_total_mm2 = excluded.a_total_mm2, bundle_dia_mm = excluded.bundle_dia_mm, k_strand = excluded.k_strand,
    core_dia_mm = excluded.core_dia_mm, metal_kgkm = excluded.metal_kgkm, ins_kgkm = excluded.ins_kgkm,
    rdc_calc = excluded.rdc_calc, rdc_limit = excluded.rdc_limit, total_kgkm = excluded.total_kgkm,
    calculated_at = excluded.calculated_at;
  return r;
end $$;

-- Kiểm tra trước khi gửi duyệt / phát hành (BR-SP-02, BR-SP-03, BR-SO-02)
create or replace function master.check_spec(p_spec uuid) returns text[]
language plpgsql stable security definer set search_path = master, core, public as $$
declare s master.product_specs; r master.spec_results; g master.product_groups; msgs text[] := '{}';
begin
  select * into s from master.product_specs where id = p_spec;
  select * into r from master.spec_results where spec_id = p_spec;
  select pg.* into g from master.products p join master.product_groups pg on pg.code = p.group_code where p.id = s.product_id;
  if r.spec_id is null then return array['Chưa tính định mức']; end if;
  if r.rdc_limit is not null and r.rdc_calc > r.rdc_limit
     and not (r.pilot_rdc is not null and r.pilot_rdc <= r.rdc_limit)
     and coalesce(s.rdc_deviation_note, '') = '' then
    msgs := msgs || format('Rdc tính %s > giới hạn %s Ω/km: cần kết quả pilot đạt hoặc phiếu chấp nhận sai lệch', round(r.rdc_calc, 3), r.rdc_limit);
  end if;
  if r.rdc_limit is null then msgs := msgs || 'Chưa có giới hạn Rdc (AWG): QA nhập giới hạn hoặc kết quả đo'; end if;
  if r.total_kgkm * coalesce(s.m_per_pack, 0) / 1000 > master.param(s.param_set_id, 'maxPack') then
    msgs := msgs || 'Kiện quá tải: giảm m/kiện';
  end if;
  if s.wire_count > 50 then msgs := msgs || 'Xác nhận quy trình bện nhiều cấp'; end if;
  if s.drain_mat = 'Không' and not (s.brand = 'KAVIX' and s.insulation = 'SIL') then
    msgs := msgs || 'Drain Không chỉ cho FR KAVIX';
  end if;
  if s.cores = 1 and s.sheath <> 'Không' then msgs := msgs || 'Dây 1 lõi không có vỏ'; end if;
  if s.cores > 1 and s.sheath = 'Không' then msgs := msgs || 'Cáp nhiều lõi phải có vỏ'; end if;
  if g.allowed_brands is not null and not (s.brand = any(g.allowed_brands)) then
    msgs := msgs || format('Nhóm %s chỉ cho thương hiệu %s', g.code, array_to_string(g.allowed_brands, ', '));
  end if;
  if g.allowed_sheaths is not null and not (s.sheath = any(g.allowed_sheaths)) then
    msgs := msgs || format('Nhóm %s chỉ cho vỏ %s', g.code, array_to_string(g.allowed_sheaths, ', '));
  end if;
  return msgs;
end $$;

-- Phát hành spec + BOM (gọi khi bước duyệt cuối hoàn tất)
create or replace function master.release_spec(p_spec uuid) returns void
language plpgsql security definer set search_path = master, core, public as $$
declare s master.product_specs; v_issues text[];
begin
  select * into s from master.product_specs where id = p_spec for update;
  v_issues := master.check_spec(p_spec);
  if array_length(v_issues, 1) > 0 then
    raise exception 'Không phát hành được spec: %', array_to_string(v_issues, '; ');
  end if;
  if not exists (select 1 from master.bom_headers where spec_id = p_spec) then
    raise exception 'Spec chưa có BOM';
  end if;
  update master.product_specs set status = 'OBSOLETE'
   where product_id = s.product_id and status = 'RELEASED' and id <> p_spec;
  update master.bom_headers set status = 'OBSOLETE'
   where spec_id in (select id from master.product_specs where product_id = s.product_id and id <> p_spec) and status = 'RELEASED';
  perform set_config('bmt.allow_release', 'on', true);
  update master.product_specs set status = 'RELEASED', released_at = now(), released_by = auth.uid() where id = p_spec;
  perform set_config('bmt.allow_release', 'off', true);
  update master.bom_headers set status = 'RELEASED' where spec_id = p_spec;
  update master.products set current_spec_id = p_spec where id = s.product_id;
end $$;

-- Spec/BOM đã phát hành không sửa trực tiếp được (chỉ chuyển sang OBSOLETE)
create or replace function master.guard_released_spec() returns trigger
language plpgsql as $$
begin
  if old.status = 'RELEASED' and not (new.status = 'OBSOLETE'
      and (to_jsonb(new) - array['status','updated_at','updated_by']) = (to_jsonb(old) - array['status','updated_at','updated_by'])) then
    raise exception 'Spec % đã phát hành: tạo phiên bản mới để thay đổi', old.id;
  end if;
  if new.status = 'RELEASED' and old.status <> 'RELEASED' and coalesce(current_setting('bmt.allow_release', true), '') <> 'on' then
    raise exception 'Chỉ phát hành spec qua luồng duyệt';
  end if;
  return new;
end $$;
create trigger trg_guard_released_spec before update on master.product_specs
  for each row execute function master.guard_released_spec();

create or replace function master.guard_released_bom_line() returns trigger
language plpgsql as $$
declare v_status text;
begin
  select status into v_status from master.bom_headers where id = coalesce(new.bom_id, old.bom_id);
  if v_status = 'RELEASED' then raise exception 'BOM đã phát hành: tạo phiên bản spec mới để thay đổi'; end if;
  return coalesce(new, old);
end $$;
create trigger trg_guard_bom_line before insert or update or delete on master.bom_lines
  for each row execute function master.guard_released_bom_line();

-- Spec mới: phiên bản tiếp theo, sao chép từ phiên bản hiện hành
create or replace function master.new_spec_version(p_from uuid, p_change_level text) returns uuid
language plpgsql security definer set search_path = master, public as $$
declare v_new uuid; v_ver int; s master.product_specs;
begin
  if not core.has_perm('spec', 'create') then raise exception 'Không có quyền tạo spec'; end if;
  select * into s from master.product_specs where id = p_from;
  select coalesce(max(version), 0) + 1 into v_ver from master.product_specs where product_id = s.product_id;
  s.id := gen_random_uuid(); s.version := v_ver; s.status := 'DRAFT'; s.change_level := p_change_level;
  s.released_at := null; s.released_by := null; s.rdc_deviation_note := null;
  s.created_at := now(); s.created_by := auth.uid(); s.updated_at := now(); s.updated_by := null;
  insert into master.product_specs select s.*;
  v_new := s.id;
  -- Giữ các lớp chưa tính tự động (vỏ, độn, băng, drain); kết quả pilot để trống cho phiên bản mới
  insert into master.spec_results (spec_id, cable_bundle_mm, od_mm, sheath_kgkm, pp_kgkm, pet_kgkm, alpet_kgkm, drain_kgkm, tech_check)
  select v_new, cable_bundle_mm, od_mm, sheath_kgkm, pp_kgkm, pet_kgkm, alpet_kgkm, drain_kgkm, tech_check
  from master.spec_results where spec_id = p_from;
  insert into master.bom_headers (spec_id, status, note) values (v_new, 'DRAFT', 'Sao chép từ v' || (v_ver - 1));
  insert into master.bom_lines (bom_id, material_id, basis, qty_per_basis, loss_rate, startup_per_lot, operation_code, note)
  select (select id from master.bom_headers where spec_id = v_new), l.material_id, l.basis, l.qty_per_basis, l.loss_rate,
         l.startup_per_lot, l.operation_code, l.note
  from master.bom_lines l join master.bom_headers h on h.id = l.bom_id where h.spec_id = p_from;
  perform master.calc_spec(v_new);
  return v_new;
end $$;

-- ===========================================================================
-- 2. Ghi sổ kho + giá bình quân gia quyền di động
-- ===========================================================================
-- Cộng/trừ tồn một lô tại kho + vị trí (không cho âm)
create or replace function inv.bal_add(p_wh uuid, p_loc uuid, p_lot uuid, p_delta numeric) returns void
language plpgsql as $$
begin
  update inv.stock_balances set qty = qty + p_delta, updated_at = now()
   where warehouse_id = p_wh and location_key = p_loc and lot_id = p_lot;
  if not found then
    if p_delta < 0 then raise exception using errcode = 'check_violation', message = 'lô chưa có tồn tại kho/vị trí này'; end if;
    insert into inv.stock_balances (warehouse_id, location_key, lot_id, qty) values (p_wh, p_loc, p_lot, p_delta);
  end if;
end $$;

create or replace function inv.post_doc(p_doc uuid) returns void
language plpgsql security definer set search_path = inv, cost, core, public as $$
declare
  d inv.stock_docs; l record; wh inv.warehouses; to_wh inv.warehouses;
  v_sign int; v_cost numeric; v_val cost.item_valuation; v_loc uuid; v_zero uuid := '00000000-0000-0000-0000-000000000000';
begin
  if not core.has_perm('inventory', 'edit') then raise exception 'Không có quyền ghi sổ kho'; end if;
  select * into d from inv.stock_docs where id = p_doc for update;
  if d.status = 'POSTED' then raise exception 'Chứng từ % đã ghi sổ', d.doc_no; end if;
  if d.status not in ('DRAFT', 'APPROVED') then raise exception 'Chứng từ % đang ở trạng thái %', d.doc_no, d.status; end if;
  if d.doc_type in ('ADJ', 'SCRAP_OUT') and d.status <> 'APPROVED' then
    raise exception 'Chứng từ % cần BGĐ phê duyệt trước khi ghi sổ', d.doc_no;
  end if;
  select * into wh from inv.warehouses where id = d.warehouse_id;
  select * into to_wh from inv.warehouses where id = d.to_warehouse_id;

  for l in select dl.*, lt.item_kind, lt.material_id, lt.qc_status, lt.lot_no
           from inv.stock_doc_lines dl join inv.lots lt on lt.id = dl.lot_id
           where dl.doc_id = p_doc order by dl.line_no loop

    v_sign := case when d.doc_type in ('GR','RETURN_WO','WIP_IN','FG_IN','SCRAP_IN') then 1
                   when d.doc_type in ('ISSUE_WO','SALE','SCRAP_OUT','RETURN_SUP','TRANSFER') then -1
                   when d.doc_type = 'ADJ' then sign(l.qty)::int end;
    if d.doc_type <> 'ADJ' and l.qty < 0 then raise exception 'Số lượng phải dương (dòng %)', l.line_no; end if;
    if d.doc_type in ('ISSUE_WO', 'SALE') and l.qc_status <> 'PASSED' then
      raise exception 'Lô % chưa đạt QC (%): không được xuất', l.lot_no, l.qc_status;   -- BR-KHO-02
    end if;

    -- Giá: kho phế = 0; nhập mua = đơn giá dòng; còn lại = bình quân hiện tại
    v_cost := 0;
    if wh.kind = 'SCRAP' then
      v_cost := 0;
    elsif l.item_kind = 'MAT' then
      select * into v_val from cost.item_valuation where warehouse_id = d.warehouse_id and material_id = l.material_id for update;
      if d.doc_type = 'GR' then
        if l.unit_cost is null then raise exception 'Dòng % thiếu đơn giá nhập', l.line_no; end if;
        v_cost := l.unit_cost;
        insert into cost.item_valuation (warehouse_id, material_id, qty, avg_cost, value)
        values (d.warehouse_id, l.material_id, l.qty, l.unit_cost, round(l.qty * l.unit_cost, 2))
        on conflict (warehouse_id, material_id) do update set
          avg_cost = case when cost.item_valuation.qty + excluded.qty > 0
                          then (cost.item_valuation.value + excluded.value) / (cost.item_valuation.qty + excluded.qty)
                          else excluded.avg_cost end,
          qty = cost.item_valuation.qty + excluded.qty,
          value = cost.item_valuation.value + excluded.value,
          updated_at = now();
      else
        v_cost := coalesce(v_val.avg_cost, 0);
        insert into cost.item_valuation (warehouse_id, material_id, qty, avg_cost, value)
        values (d.warehouse_id, l.material_id, v_sign * abs(l.qty), v_cost, round(v_sign * abs(l.qty) * v_cost, 2))
        on conflict (warehouse_id, material_id) do update set
          qty = cost.item_valuation.qty + excluded.qty,
          value = case when cost.item_valuation.qty + excluded.qty = 0 then 0 else cost.item_valuation.value + excluded.value end,
          updated_at = now();
      end if;
    else
      v_cost := coalesce(l.unit_cost, 0);   -- BTP/TP: giá tạm, cập nhật khi chốt giá thành
    end if;

    v_loc := coalesce(l.location_id, v_zero);
    insert into inv.stock_moves (doc_id, doc_line_id, move_type, warehouse_id, location_id, lot_id, qty, qty_alt, unit_cost)
    values (p_doc, l.id, d.doc_type, d.warehouse_id, l.location_id, l.lot_id, v_sign * abs(l.qty), l.qty_alt, v_cost);
    perform inv.bal_add(d.warehouse_id, v_loc, l.lot_id, v_sign * abs(l.qty));

    if d.doc_type = 'TRANSFER' then
      if to_wh.id is null then raise exception 'Chuyển kho cần kho nhận'; end if;
      insert into inv.stock_moves (doc_id, doc_line_id, move_type, warehouse_id, location_id, lot_id, qty, qty_alt, unit_cost)
      values (p_doc, l.id, 'TRANSFER', to_wh.id, l.to_location_id, l.lot_id, abs(l.qty), l.qty_alt, v_cost);
      perform inv.bal_add(to_wh.id, coalesce(l.to_location_id, v_zero), l.lot_id, abs(l.qty));
      if l.item_kind = 'MAT' then
        insert into cost.item_valuation (warehouse_id, material_id, qty, avg_cost, value)
        values (to_wh.id, l.material_id, abs(l.qty), v_cost, round(abs(l.qty) * v_cost, 2))
        on conflict (warehouse_id, material_id) do update set
          avg_cost = (cost.item_valuation.value + excluded.value) / nullif(cost.item_valuation.qty + excluded.qty, 0),
          qty = cost.item_valuation.qty + excluded.qty, value = cost.item_valuation.value + excluded.value, updated_at = now();
      end if;
    end if;
  end loop;

  update inv.stock_docs set status = 'POSTED', posted_at = now(), posted_by = auth.uid() where id = p_doc;

  if d.doc_type in ('GR','ISSUE_WO','RETURN_WO','FG_IN','SALE','SCRAP_OUT','ADJ','TRANSFER') then
    insert into integ.sync_queue (entity, entity_id, direction) values ('STOCK_DOC', p_doc, 'TO_MISA');
  end if;
exception
  when check_violation then
    raise exception 'Không đủ tồn để xuất (chứng từ %): %', d.doc_no, sqlerrm;
end $$;

-- Tồn khả dụng NVL theo vật tư (BR-KH-01)
create or replace view inv.v_material_availability with (security_invoker = true) as
select m.id as material_id, m.code,
       coalesce(sum(b.qty - b.reserved_qty) filter (where b.qc_status = 'PASSED'), 0) as available,
       coalesce(sum(b.qty) filter (where b.qc_status = 'PENDING'), 0) as in_quality,
       coalesce(sum(b.qty) filter (where b.qc_status = 'QUARANTINE'), 0) as quarantined
from master.materials m
left join (
  select l.material_id, l.qc_status, b.qty, b.reserved_qty
  from inv.stock_balances b
  join inv.lots l on l.id = b.lot_id and l.item_kind = 'MAT'
  join inv.warehouses w on w.id = b.warehouse_id and w.kind = 'MAT'
) b on b.material_id = m.id
group by m.id, m.code;

-- ===========================================================================
-- 3. MRP (CAL-11…15)
-- ===========================================================================
create or replace function plan.run_mrp(p_plan uuid, p_reserve jsonb default '{}') returns uuid
language plpgsql security definer set search_path = plan, master, inv, purchase, public as $$
declare p plan.production_plans; v_run uuid; v_set uuid; v_bad text;
begin
  if not core.has_perm('plan', 'create') then raise exception 'Không có quyền chạy MRP'; end if;
  select * into p from plan.production_plans where id = p_plan;
  if p.mode = 'OFFICIAL' then
    select string_agg(pr.code, ', ') into v_bad from plan.plan_lines pl
      join master.product_specs s on s.id = pl.spec_id join master.products pr on pr.id = pl.product_id
     where pl.plan_id = p_plan and pl.qty_m > 0 and s.status <> 'RELEASED';
    if v_bad is not null then
      raise exception 'Spec chưa phát hành: %. Chuyển kế hoạch sang chế độ sơ bộ hoặc chờ KT/QA duyệt (BR-SP-01)', v_bad;
    end if;
  end if;
  select param_set_id into v_set from master.product_specs s join plan.plan_lines pl on pl.spec_id = s.id
   where pl.plan_id = p_plan limit 1;

  insert into plan.mrp_runs (plan_id, need_date, total_m, snapshot)
  select p_plan, p.material_need_date, sum(qty_m),
         jsonb_build_object('specs', jsonb_agg(jsonb_build_object('product', product_id, 'spec', spec_id, 'm', qty_m, 'lots', run_lots)),
                            'param_set', v_set, 'reserve', p_reserve)
  from plan.plan_lines where plan_id = p_plan
  returning id into v_run;

  with base as (
    select pl.*, ceil(pl.qty_m / pl.m_per_pack) as packs,
           ceil(ceil(pl.qty_m / pl.m_per_pack)
                / case when pl.pack_type = 'Bobin gỗ' then master.param(s.param_set_id, 'palletW')
                       else master.param(s.param_set_id, 'palletC') end) as pallets
    from plan.plan_lines pl join master.product_specs s on s.id = pl.spec_id
    where pl.plan_id = p_plan and pl.qty_m > 0
  ), need as (
    select bl.material_id,
           sum(bl.qty_per_basis * case bl.basis when 'KM' then b.qty_m / 1000 when 'PACK' then b.packs
                                               when 'PALLET' then b.pallets else b.run_lots end) as theo,
           sum(bl.qty_per_basis * case bl.basis when 'KM' then b.qty_m / 1000 when 'PACK' then b.packs
                                               when 'PALLET' then b.pallets else b.run_lots end / (1 - bl.loss_rate)) as after_loss,
           sum(bl.startup_per_lot * b.run_lots) as startup
    from base b
    join master.bom_headers h on h.spec_id = b.spec_id
    join master.bom_lines bl on bl.bom_id = h.id
    group by bl.material_id
  ), terms as (
    select distinct on (ms.material_id) ms.* from master.material_suppliers ms
    order by ms.material_id, ms.is_preferred desc, ms.unit_price is null, ms.supplier_id nulls last
  ), incoming as (
    select pol.material_id, sum(pol.qty - pol.received_qty) as qty
    from purchase.po_lines pol join purchase.purchase_orders po on po.id = pol.po_id
    where po.status in ('APPROVED','SENT','PARTIAL_RECEIVED')
      and coalesce(pol.expected_date, po.expected_date) <= coalesce(p.material_need_date, 'infinity'::date)
    group by pol.material_id
  ), calc as (
    select n.material_id, n.theo, n.after_loss, n.startup, n.after_loss + n.startup as total,
           coalesce(a.available, 0) as available, coalesce(a.in_quality, 0) as in_quality,
           coalesce(i.qty, 0) as incoming, coalesce((p_reserve ->> m.code)::numeric, 0) as reserve,
           t.moq, t.pack_multiple, t.unit_price, t.lead_time_days
    from need n
    join master.materials m on m.id = n.material_id
    left join inv.v_material_availability a on a.material_id = n.material_id
    left join incoming i on i.material_id = n.material_id
    left join terms t on t.material_id = n.material_id
  ), res as (
    select c.*, greatest(0, c.total + c.reserve - c.available - c.incoming) as net from calc c
  ), sug as (
    select r.*, case when r.net = 0 then 0
                     else ceil(greatest(r.net, coalesce(r.moq, 0)) / coalesce(nullif(r.pack_multiple, 0), 1)) * coalesce(nullif(r.pack_multiple, 0), 1) end as suggest
    from res r
  )
  insert into plan.mrp_lines (run_id, material_id, theoretical, after_loss, startup, total_issue, available, in_quality,
                              incoming, reserve, net_short, moq, pack_multiple, suggest_qty, unit_price, amount,
                              lead_time_days, latest_order_date, status)
  select v_run, material_id, round(theo, 4), round(after_loss, 4), round(startup, 4), round(total, 4), available, in_quality,
         incoming, reserve, round(net, 4), moq, pack_multiple, suggest, unit_price,
         case when unit_price is not null then round(suggest * unit_price, 2) end,                -- giá trống ≠ 0 (BR-KH-03)
         lead_time_days,
         case when suggest > 0 and p.material_need_date is not null and coalesce(lead_time_days, 0) > 0
              then p.material_need_date - lead_time_days end,
         case when suggest = 0 then 'Không cần mua'
              when unit_price is null then 'Cập nhật giá'
              when coalesce(lead_time_days, 0) = 0 then 'Thiếu lead time'
              when p.material_need_date - lead_time_days < current_date then 'Trễ'
              else 'Đặt hàng' end
  from sug;

  update plan.mrp_runs r set
    budget_vnd = (select sum(amount) from plan.mrp_lines where run_id = v_run),
    missing_price_count = (select count(*) from plan.mrp_lines where run_id = v_run and suggest_qty > 0 and unit_price is null)
  where r.id = v_run;
  return v_run;
end $$;

-- Sinh PR từ kết quả MRP của kế hoạch đã duyệt
create or replace function plan.create_pr_from_mrp(p_run uuid) returns uuid
language plpgsql security definer set search_path = plan, purchase, public as $$
declare v_pr uuid; p plan.production_plans;
begin
  if not core.has_perm('plan', 'create') then raise exception 'Không có quyền tạo PR'; end if;
  select pp.* into p from plan.mrp_runs r join plan.production_plans pp on pp.id = r.plan_id where r.id = p_run;
  if p.status <> 'APPROVED' or p.mode <> 'OFFICIAL' then
    raise exception 'Chỉ sinh PR từ kế hoạch chính thức đã BGĐ duyệt';
  end if;
  insert into purchase.purchase_requests (pr_no, source, mrp_run_id, need_date, note)
  values (core.next_no('PR'), 'MRP', p_run, p.material_need_date, 'Từ ' || p.plan_no) returning id into v_pr;
  insert into purchase.pr_lines (pr_id, material_id, qty, need_date, mrp_line_id)
  select v_pr, material_id, suggest_qty, latest_order_date, id from plan.mrp_lines where run_id = p_run and suggest_qty > 0;
  return v_pr;
end $$;

-- ===========================================================================
-- 4. Bán hàng: ATP và giữ hàng (BR-SO-03)
-- ===========================================================================
create or replace function sales.atp(p_product uuid, p_brand text) returns numeric
language sql stable security definer set search_path = inv, public as $$
  select coalesce(sum(b.qty - b.reserved_qty), 0)
  from inv.stock_balances b join inv.lots l on l.id = b.lot_id join inv.warehouses w on w.id = b.warehouse_id
  where w.kind = 'FG' and l.product_id = p_product and l.brand = p_brand and l.qc_status = 'PASSED'
$$;

create or replace function sales.reserve_so(p_so uuid) returns void
language plpgsql security definer set search_path = sales, inv, public as $$
declare so sales.sales_orders; ln record; b record; v_need numeric; v_take numeric;
begin
  if not core.has_perm('sales', 'edit') then raise exception 'Không có quyền giữ hàng'; end if;
  select * into so from sales.sales_orders where id = p_so;
  if so.status <> 'APPROVED' then raise exception 'SO % chưa được duyệt', so.so_no; end if;
  for ln in select l.*, s.status as spec_status from sales.so_lines l left join master.product_specs s on s.id = l.spec_id
            where l.so_id = p_so and l.line_status = 'OPEN' order by l.line_no loop
    v_need := ln.qty_m - ln.reserved_m;
    for b in select bal.*, l.lot_no from inv.stock_balances bal join inv.lots l on l.id = bal.lot_id
             join inv.warehouses w on w.id = bal.warehouse_id
             where w.kind = 'FG' and l.product_id = ln.product_id and l.brand = so.label_brand and l.qc_status = 'PASSED'
               and bal.qty - bal.reserved_qty > 0
             order by l.mfg_date nulls last, l.lot_no for update of bal loop
      exit when v_need <= 0;
      v_take := least(v_need, b.qty - b.reserved_qty);
      update inv.stock_balances set reserved_qty = reserved_qty + v_take
       where warehouse_id = b.warehouse_id and location_key = b.location_key and lot_id = b.lot_id;
      insert into sales.so_reservations (so_line_id, lot_id, qty_m) values (ln.id, b.lot_id, v_take);
      v_need := v_need - v_take;
    end loop;
    update sales.so_lines set
      reserved_m = qty_m - v_need,
      to_produce_m = v_need,
      line_status = case when v_need = 0 then 'RESERVED'
                         when coalesce(ln.spec_status, '') <> 'RELEASED' then 'WAITING_SPEC'
                         else 'PLANNED' end
    where id = ln.id;
  end loop;
end $$;

-- ===========================================================================
-- 5. Sản xuất: phát lệnh, ghi nhận đầu ra, truy xuất
-- ===========================================================================
create or replace function mfg.release_wo(p_wo uuid) returns void
language plpgsql security definer set search_path = mfg, master, public as $$
declare w mfg.work_orders; v_spec_status text; v_group text;
begin
  select * into w from mfg.work_orders where id = p_wo for update;
  select s.status, p.group_code into v_spec_status, v_group
    from master.product_specs s join master.products p on p.id = s.product_id where s.id = w.spec_id;
  if w.wo_type = 'PRODUCTION' and v_spec_status <> 'RELEASED' then
    raise exception 'LSX %: spec chưa phát hành, chuyển Kỹ thuật/QA (BR-SP-01)', w.wo_no;
  end if;
  if w.wo_type = 'PILOT' and (w.pilot_max_m is null or w.qty_m > w.pilot_max_m) then
    raise exception 'Lệnh pilot vượt giới hạn mét do KT đặt';
  end if;
  insert into mfg.wo_operations (wo_id, op_code, seq, planned_m)
  select p_wo, o.code, o.seq, w.qty_m from master.routings r join master.operations o on o.code = r.op_code
  where r.group_code = v_group
  on conflict (wo_id, op_code) do nothing;
  update mfg.work_orders set status = 'RELEASED', released_at = now(), released_by = auth.uid() where id = p_wo;
end $$;

-- Ghi nhận lô đầu ra của công đoạn + phả hệ lô từ các lô đầu vào đã quét
-- p_inputs: [{"lot_id": "...", "qty": 123.4}, …]
create or replace function mfg.record_output(p_wo_op uuid, p_lot_no text, p_qty_m numeric, p_weight_kg numeric,
                                             p_inputs jsonb, p_color text default null) returns uuid
language plpgsql security definer set search_path = mfg, inv, master, public as $$
declare o mfg.wo_operations; w mfg.work_orders; op master.operations; v_lot uuid; v_last boolean; e jsonb;
begin
  if not core.has_perm('production', 'create') then raise exception 'Không có quyền ghi nhận sản xuất'; end if;
  select * into o from mfg.wo_operations where id = p_wo_op;
  select * into w from mfg.work_orders where id = o.wo_id;
  select * into op from master.operations where code = o.op_code;
  v_last := o.op_code = 'CD6';
  insert into inv.lots (lot_no, item_kind, product_id, spec_id, wip_stage, brand, color, uom, wo_op_id, qc_status, mfg_date, weight_kg)
  values (p_lot_no, case when v_last then 'FG' else 'WIP' end, w.product_id, w.spec_id,
          case when v_last then null else op.output_prefix end, w.brand, p_color, 'm', p_wo_op,
          case when v_last then 'PENDING' else 'PASSED' end, current_date, p_weight_kg)
  returning id into v_lot;
  insert into mfg.wo_outputs (wo_op_id, lot_id, qty_m, weight_kg) values (p_wo_op, v_lot, p_qty_m, p_weight_kg);
  for e in select * from jsonb_array_elements(coalesce(p_inputs, '[]')) loop
    insert into mfg.lot_genealogy (parent_lot_id, child_lot_id, wo_op_id, qty_used)
    values ((e->>'lot_id')::uuid, v_lot, p_wo_op, (e->>'qty')::numeric);
  end loop;
  update mfg.wo_operations set good_m = good_m + p_qty_m where id = p_wo_op;
  return v_lot;
end $$;

-- Truy xuất ngược: từ lô (bobin) về lô NVL
create or replace function mfg.trace_back(p_lot uuid)
returns table (depth int, lot_id uuid, lot_no text, item_kind text, item_code text, parent_of uuid, qty_used numeric,
               op_code text, machine_code text, supplier text, supplier_lot text)
language sql stable security definer set search_path = mfg, inv, master, public as $$
  with recursive t(depth, lot_id, parent_of, qty_used, wo_op_id) as (
    select 0, p_lot, null::uuid, null::numeric, null::uuid
    union all
    select t.depth + 1, g.parent_lot_id, g.child_lot_id, g.qty_used, g.wo_op_id
    from t join mfg.lot_genealogy g on g.child_lot_id = t.lot_id
    where t.depth < 20
  )
  select t.depth, l.id, l.lot_no, l.item_kind, coalesce(m.code, pr.code), t.parent_of, t.qty_used,
         o.op_code, mc.code, sp.name, l.supplier_lot
  from t join inv.lots l on l.id = t.lot_id
  left join master.materials m on m.id = l.material_id
  left join master.products pr on pr.id = l.product_id
  left join mfg.wo_operations o on o.id = l.wo_op_id
  left join master.machines mc on mc.id = o.machine_id
  left join core.partners sp on sp.id = l.supplier_id
  order by t.depth, l.lot_no
$$;

-- Truy xuất xuôi: từ lô NVL ra bobin TP và SO bị ảnh hưởng (thu hồi)
create or replace function mfg.trace_forward(p_lot uuid)
returns table (depth int, lot_id uuid, lot_no text, item_kind text, product_code text, so_no text, customer text)
language sql stable security definer set search_path = mfg, inv, master, sales, public as $$
  with recursive t(depth, lot_id) as (
    select 0, p_lot
    union
    select t.depth + 1, g.child_lot_id from t join mfg.lot_genealogy g on g.parent_lot_id = t.lot_id where t.depth < 20
  )
  select distinct t.depth, l.id, l.lot_no, l.item_kind, pr.code, so.so_no, c.name
  from t join inv.lots l on l.id = t.lot_id
  left join master.products pr on pr.id = l.product_id
  left join sales.so_reservations r on r.lot_id = l.id and r.released_at is null
  left join sales.so_lines sl on sl.id = r.so_line_id
  left join sales.sales_orders so on so.id = sl.so_id
  left join core.partners c on c.id = so.customer_id
  order by t.depth, l.lot_no
$$;

-- ===========================================================================
-- 6. Luồng duyệt
-- ===========================================================================
create or replace function wf.doc_hash(p_table text, p_id uuid) returns text
language plpgsql stable security definer as $$
declare v jsonb;
begin
  execute format('select to_jsonb(t) - array[''status'',''updated_at'',''updated_by'',''current_spec_id''] from %s t where id = $1', p_table)
    into v using p_id;
  return md5(v::text);
end $$;

create or replace function wf.notify_role(p_role text, p_title text, p_body text, p_link text) returns void
language sql security definer set search_path = wf, core, public as $$
  insert into wf.notifications (user_id, title, body, link)
  select ur.user_id, p_title, p_body, p_link from core.user_roles ur
  join core.profiles p on p.id = ur.user_id and p.status = 'ACTIVE' where ur.role_code = p_role
$$;

create or replace function wf.next_seq(p_doc_type text, p_after smallint) returns smallint
language sql stable as $$
  select min(seq) from wf.approval_steps where doc_type = p_doc_type and enabled and seq > coalesce(p_after, 0)
$$;

create or replace function wf.submit(p_doc_type text, p_doc_id uuid, p_doc_no text, p_summary text default null) returns uuid
language plpgsql security definer set search_path = wf, core, public as $$
declare f wf.approval_flows; v_req uuid; v_seq smallint; v_role text; v_issues text[];
begin
  select * into f from wf.approval_flows where doc_type = p_doc_type;
  if not found then raise exception 'Chưa cấu hình luồng duyệt cho %', p_doc_type; end if;
  if p_doc_type like 'SPEC%' then
    v_issues := master.check_spec(p_doc_id);
    if array_length(v_issues, 1) > 0 then
      raise exception 'Spec chưa đạt kiểm tra: %', array_to_string(v_issues, '; ');
    end if;
  end if;
  v_seq := wf.next_seq(p_doc_type, 0::smallint);
  if v_seq is null then raise exception 'Luồng % không có bước nào đang bật', p_doc_type; end if;
  insert into wf.approval_requests (doc_type, doc_id, doc_no, summary, current_seq, data_hash)
  values (p_doc_type, p_doc_id, p_doc_no, p_summary, v_seq, wf.doc_hash(f.doc_table, p_doc_id))
  returning id into v_req;
  execute format('update %s set %I = $1 where id = $2', f.doc_table, f.status_col) using f.pending_status, p_doc_id;
  select role_code into v_role from wf.approval_steps where doc_type = p_doc_type and seq = v_seq;
  perform wf.notify_role(v_role, 'Chờ duyệt: ' || p_doc_no, p_summary, '/duyet/' || v_req);
  return v_req;
end $$;

create or replace function wf.act(p_request uuid, p_action text, p_comment text default null) returns text
language plpgsql security definer set search_path = wf, core, public as $$
declare r wf.approval_requests; f wf.approval_flows; st wf.approval_steps; v_next smallint; v_hash text; v_behalf uuid;
begin
  select * into r from wf.approval_requests where id = p_request for update;
  if r.status <> 'PENDING' then raise exception 'Yêu cầu đã kết thúc (%)', r.status; end if;
  select * into f from wf.approval_flows where doc_type = r.doc_type;
  select * into st from wf.approval_steps where doc_type = r.doc_type and seq = r.current_seq;

  if not exists (select 1 from core.user_roles where user_id = auth.uid() and role_code = st.role_code) then
    select from_user into v_behalf from core.delegations
     where to_user = auth.uid() and role_code = st.role_code and now() between valid_from and valid_to limit 1;
    if v_behalf is null then raise exception 'Bước này cần vai trò %', st.role_code; end if;
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
    insert into wf.notifications (user_id, title, body) values (r.submitted_by, 'Bị trả lại: ' || r.doc_no, p_comment);
    return 'REJECTED';
  end if;

  v_next := wf.next_seq(r.doc_type, r.current_seq);
  if v_next is not null then
    update wf.approval_requests set current_seq = v_next where id = p_request;
    perform wf.notify_role((select role_code from wf.approval_steps where doc_type = r.doc_type and seq = v_next),
                           'Chờ duyệt: ' || r.doc_no, r.summary, '/duyet/' || p_request);
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
  insert into wf.notifications (user_id, title) values (r.submitted_by, 'Đã duyệt: ' || r.doc_no);
  return 'APPROVED';
end $$;

-- ===========================================================================
-- 7. Giá thành LSX (định mức vs thực tế; phế giá trị 0)
-- ===========================================================================
create or replace function cost.calc_wo(p_wo uuid, p_period uuid) returns cost.wo_costs
language plpgsql security definer set search_path = cost, mfg, inv, master, public as $$
declare w mfg.work_orders; c cost.wo_costs; v_total_min numeric; v_min numeric; v_pallet numeric; v_packs numeric;
begin
  if not core.has_perm('cost', 'create') then raise exception 'Không có quyền tính giá thành'; end if;
  select * into w from mfg.work_orders where id = p_wo;
  v_packs := ceil(w.qty_m / w.m_per_pack);
  select ceil(v_packs / case when w.pack_type = 'Bobin gỗ' then master.param(s.param_set_id, 'palletW') else master.param(s.param_set_id, 'palletC') end)
    into v_pallet from master.product_specs s where s.id = w.spec_id;

  delete from cost.wo_material_variances where wo_id = p_wo;
  with std as (
    select bl.material_id,
           round(sum(bl.qty_per_basis * case bl.basis when 'KM' then w.qty_m / 1000 when 'PACK' then v_packs
                                               when 'PALLET' then v_pallet else w.run_lots end / (1 - bl.loss_rate)
               + bl.startup_per_lot * w.run_lots), 4) as std_qty
    from master.bom_lines bl where bl.bom_id = w.bom_id group by bl.material_id
  ), act as (
    select l.material_id, -sum(sm.qty) as act_qty, -sum(sm.amount) as act_amount
    from inv.stock_moves sm join inv.stock_docs d on d.id = sm.doc_id join inv.lots l on l.id = sm.lot_id
    where d.ref_type = 'WO' and d.ref_id = p_wo and d.doc_type in ('ISSUE_WO','RETURN_WO') and l.item_kind = 'MAT'
    group by l.material_id
  )
  insert into cost.wo_material_variances (wo_id, material_id, std_qty, act_qty, std_price, act_amount, qty_variance, price_variance)
  select p_wo, coalesce(s.material_id, a.material_id), coalesce(s.std_qty, 0), coalesce(a.act_qty, 0), sp.std_price, a.act_amount,
         round((coalesce(a.act_qty, 0) - coalesce(s.std_qty, 0)) * sp.std_price, 2),
         round(coalesce(a.act_amount, 0) - coalesce(a.act_qty, 0) * sp.std_price, 2)
  from std s full join act a on a.material_id = s.material_id
  left join cost.standard_prices sp on sp.period_id = p_period and sp.material_id = coalesce(s.material_id, a.material_id);

  select coalesce(sum(run_minutes), 0) into v_min from mfg.wo_operations where wo_id = p_wo;
  select coalesce(sum(o.run_minutes), 0) into v_total_min
    from mfg.wo_operations o join mfg.work_orders x on x.id = o.wo_id
   where to_char(coalesce(o.ended_at, o.started_at), 'YYYY-MM') = (select period from cost.cost_periods where id = p_period);

  c.wo_id := p_wo; c.period_id := p_period;
  select coalesce(sum(op.qty_m), 0) into c.good_m from mfg.wo_outputs op join mfg.wo_operations o on o.id = op.wo_op_id
   where o.wo_id = p_wo and o.op_code = 'CD6';
  select sum(round(v.std_qty * v.std_price, 2)) filter (where m.group_code <> 'PACK'),
         sum(v.act_amount) filter (where m.group_code <> 'PACK'),
         sum(round(v.std_qty * v.std_price, 2)) filter (where m.group_code = 'PACK'),
         sum(v.act_amount) filter (where m.group_code = 'PACK')
    into c.std_material, c.act_material, c.std_packing, c.act_packing
    from cost.wo_material_variances v join master.materials m on m.id = v.material_id where v.wo_id = p_wo;
  select round(amount * v_min / nullif(v_total_min, 0), 2) into c.act_labor from cost.cost_pools where period_id = p_period and pool_code = 'LABOR';
  select round(amount * v_min / nullif(v_total_min, 0), 2) into c.act_power from cost.cost_pools where period_id = p_period and pool_code = 'POWER';
  select round(amount * v_min / nullif(v_total_min, 0), 2) into c.act_depr from cost.cost_pools where period_id = p_period and pool_code = 'DEPRECIATION';
  select round(amount * v_min / nullif(v_total_min, 0), 2) into c.act_overhead from cost.cost_pools where period_id = p_period and pool_code = 'OVERHEAD';
  select coalesce(sum(qty_kg), 0) into c.scrap_kg from mfg.scrap_records s join mfg.wo_operations o on o.id = s.wo_op_id where o.wo_id = p_wo;
  c.status := 'DRAFT'; c.calculated_at := now();

  insert into cost.wo_costs (wo_id, period_id, good_m, std_material, act_material, std_packing, act_packing,
                             act_labor, act_power, act_depr, act_overhead, scrap_kg, status, calculated_at)
  values (c.wo_id, c.period_id, c.good_m, c.std_material, c.act_material, c.std_packing, c.act_packing,
          c.act_labor, c.act_power, c.act_depr, c.act_overhead, c.scrap_kg, c.status, c.calculated_at)
  on conflict (wo_id) do update set period_id = excluded.period_id, good_m = excluded.good_m,
    std_material = excluded.std_material, act_material = excluded.act_material, std_packing = excluded.std_packing,
    act_packing = excluded.act_packing, act_labor = excluded.act_labor, act_power = excluded.act_power,
    act_depr = excluded.act_depr, act_overhead = excluded.act_overhead, scrap_kg = excluded.scrap_kg,
    status = 'DRAFT', calculated_at = excluded.calculated_at
  returning * into c;
  return c;
end $$;
