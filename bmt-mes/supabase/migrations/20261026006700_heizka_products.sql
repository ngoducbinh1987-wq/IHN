-- Anh Bình 01/11/2026: lập Sản phẩm & Spec của Heizka (spec sản xuất bên Trung Quốc anh gửi) trong MES.
--   HER15S2LZ  2*30*0.24BC + 2.6 silicone + PET + 7*0.18TCCA + AL + 6.8 LSZH     (2×1.5 mm², Shielded, Orange, 500 m)
--   HER18S2LZ  2*15*0.25BC + 2.2 silicone + PET + 7*0.18TCCA + AL + 5.9 LSZH     (18AWG, Shielded, Orange, 500 m)
--   HER16S2LZ  2*25*0.25BC + 2.6 silicone + PET + 7*0.18TCCA + AL + 6.8 LSZH     (16AWG, Shielded, Orange, 500 m)
--   HEW18S2PC  2*16*0.25TC + 2.15 HDPE + 2*filling rope + PET + 12*0.18TC + 6.0 PVC (18AWG, AL-Shield, Gray, 305 m)
--   HER15U2LZ  2*30*0.24BC + 2.6 silicone + 6.7 LSZH                             (2×1.5 mm², Unshielded, Orange, 500 m)
--   HEW16S2PC  2*26*0.25TC + 2.5 HDPE + 2*filling rope + PET + 12*0.18TC + 6.7 PVC  (16AWG, AL-Shield, Gray, 305 m)
--   HER10S2LZ  2*16*0.24BC + 2.1 silicone + PET + 7*0.18TCCA + AL + 5.7 LSZH     (2×1.0 mm², Shielded, Orange, 500 m)
--   HER25U2LZ  2*49*0.24BC + 3.1 silicone + 7.9 LSZH                             (2×2.5 mm², 14AWG, Unshielded, Orange, 500 m)
-- Cách dựng: sao chép spec Kavix gần nhất (nhóm, công đoạn, BOM), rồi đặt theo spec Heizka:
--   * ruột dẫn (vật liệu, các loại sợi), mã lõi theo cỡ Heizka ghi trên tên (mm² hoặc AWG) → giới hạn Rdc theo đúng tên bán;
--   * "2.6 silicone" = đường kính lõi sau bọc → chiều dày cách điện = (đường kính lõi − đường kính ruột MES tính) ÷ 2;
--   * "6.8 LSZH" = OD cáp → chiều dày vỏ = (OD − 2 × đường kính lõi − khe băng/shield như mã Kavix mẫu) ÷ 2,
--     kg/km vỏ theo khối lượng riêng hiệu dụng của mã mẫu;
--   * drain: số sợi × Ø theo spec (TCCA dây silicone, TC dây HDPE), kg/km theo diện tích (TCCA như mã mẫu, TC theo rhoTC);
--   * băng PET (ước tính 0,025 mm, chồng mí 25 %), 2 sợi độn PP (ước tính) → TP KT/QA chỉnh khi có số thật;
--   * thương hiệu HEIZKA (nhãn LABEL-H), màu vỏ Orange = RAL 2004, Gray = Xám (Gray); đóng gói bobin gỗ 500 / 305 m.
-- Spec để ở trạng thái Nháp (đi luồng duyệt spec như thường). Màu lõi giữ theo mã mẫu (spec Heizka không ghi).
-- Kèm: vật tư sợi CU-025, TC-025, drain TCCA-018, TC-018; master.bom_group nhận drain đồng (TC) ở công đoạn ngoài CD1;
--      master.spec_name ghi kiểu "1P×2×" theo nhóm SFR/CTL (mã Heizka không có đoạn -1P-).

-- ---------------------------------------------------------------- Vật tư
insert into master.materials (code, name, group_code, purchase_spec, uom, loss_rate, density, has_expiry, requires_coa)
select v.code, v.name, m.group_code, m.purchase_spec, m.uom, m.loss_rate, m.density, m.has_expiry, m.requires_coa
  from (values ('CU-025', 'Đồng trần BC Ø0,25', 'CU-024'), ('TC-025', 'Đồng mạ thiếc TC Ø0,25', 'TC-024'),
               ('TCCA-018', 'Drain TCCA Ø0,18', 'TCCA-020'), ('TC-018', 'Đồng mạ thiếc TC Ø0,18', 'TC-020')) v(code, name, src)
  join master.materials m on m.code = v.src
on conflict (code) do nothing;

-- Drain bằng sợi đồng (TC-018…) ở công đoạn xoắn/băng: nhóm DR
create or replace function master.bom_group(p_code text, p_group text, p_op text) returns text
language sql immutable set search_path = pg_catalog as $$
  select case
    when p_group = 'CONDUCTOR' and p_op = 'CD1' then 'CU'
    when p_group in ('COMPOUND', 'COLOR', 'ADDITIVE') and p_op in ('CD0', 'CD2') then 'INS'
    when p_group in ('COMPOUND', 'COLOR') and p_op = 'CD5' then 'SH'
    when p_code = 'PP-FILL' then 'PP'
    when p_code = 'PET-20' then 'PET'
    when p_code like 'ALP-%' then 'ALP'
    when p_code like 'TCCA%' then 'DR'
    when p_group = 'CONDUCTOR' and p_op in ('CD3', 'CD4') then 'DR'
  end
$$;

-- Tên: cáp xoắn cặp chống nhiễu (nhóm SFR, CTL) ghi "nP×2×"
create or replace function master.spec_name(p_spec uuid) returns text
language sql stable security definer set search_path = pg_catalog, public as $$
  select concat(
           case when (p.code ~ '-[0-9]+P-' or p.group_code in ('SFR', 'CTL')) and s.pairs > 0 then s.pairs || 'P×2×' else s.cores || '×' end,
           case when s.core_code ~ '^A[0-9]+$' then 'AWG' || substr(s.core_code, 2)
                else coalesce(trim_scale(c.nominal_mm2)::text, s.core_code) || ' mm²' end,
           ' ',
           case s.insulation when 'SIL' then 'SI' else coalesce(nullif(s.insulation, ''), '?') end,
           '/',
           case when coalesce(nullif(trim(s.sheath), ''), 'Không') in ('Không', 'KHONG', 'NONE') then 'không vỏ' else 'vỏ ' || s.sheath end,
           ', ',
           case when not coalesce(s.shield, false) then 'không shield'
                when coalesce(s.drain_wires, 0) > 0 then 'shield AL/PET + drain'
                else 'shield AL/PET' end)
    from master.product_specs s join master.products p on p.id = s.product_id
    left join master.core_types c on c.code = s.core_code and c.set_id = s.param_set_id
   where s.id = p_spec
$$;

-- Kiểm tra spec: dây silicone không chống nhiễu của Heizka cũng không có drain (trước đây chỉ cho thương hiệu KAVIX)
create or replace function pg_temp.patch(p_name text, p_old text, p_new text, p_mark text) returns void language plpgsql as $$
declare v_oid oid; v_n int; v_def text;
begin
  select count(*), min(p.oid) into v_n, v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname || '.' || p.proname = p_name;
  if v_n <> 1 then raise exception 'Vá %: có % hàm cùng tên', p_name, v_n; end if;
  v_def := pg_get_functiondef(v_oid);
  if position(p_mark in v_def) > 0 then return; end if;
  if position(p_old in v_def) = 0 then raise exception 'Vá %: không thấy đoạn "%"', p_name, p_old; end if;
  execute replace(v_def, p_old, p_new);
end $$;
select pg_temp.patch('master.check_spec', 'not (s.brand = ''KAVIX'' and s.insulation = ''SIL'')',
  'not (s.insulation = ''SIL'' and (s.brand = ''KAVIX'' or not coalesce(s.shield, false)))', 'not coalesce(s.shield, false)))');

-- ---------------------------------------------------------------- Sản phẩm Heizka
do $$
declare
  h record; src master.product_specs; t master.products; tr master.spec_results; s master.product_specs; r master.spec_results;
  v_product uuid; v_spec uuid; v_bom uuid; v_ins numeric; v_bundle numeric; v_extra numeric; v_sh numeric; v_rho numeric;
  v_inner_t numeric; v_drain_area numeric; v_drain numeric; v_pet numeric; v_pp numeric; v_mat uuid;
begin
  perform set_config('bmt.admin_spec_edit', 'on', true);
  for h in select * from (values
    ('HER15S2LZ', 'SFR-1P-1P5',  'M1.5', 'BC', '[{"n":30,"d":0.24}]', 2.6,  6.8, true,  true,  'TCCA', 0.18, 7,  0, 'LSZH', 'RAL 2004',    500,
     'HEIZKA Fire Resistant Instrumentation Cable 2x1.5mm2, 16AWG, Shielded, Twisted pair, Orange, 500m/roll, LSZH. Spec.: 2*30*0.24BC + 2.6silicone rubber + PET + 7*0.18TCCA + AL + 6.8LSZH'),
    ('HER18S2LZ', 'SFR-1P-0P75', 'A18',  'BC', '[{"n":15,"d":0.25}]', 2.2,  5.9, true,  true,  'TCCA', 0.18, 7,  0, 'LSZH', 'RAL 2004',    500,
     'HEIZKA Fire Resistant Cable 18AWG, Shielded, Twisted pair, Orange, 500m LSZH. Spec.: 2*15*0.25BC + 2.2silicone rubber + PET + 7*0.18TCCA + AL + 5.9LSZH'),
    ('HER16S2LZ', 'SFR-1P-1P5',  'A16',  'BC', '[{"n":25,"d":0.25}]', 2.6,  6.8, true,  true,  'TCCA', 0.18, 7,  0, 'LSZH', 'RAL 2004',    500,
     'HEIZKA Fire Resistant Instrumentation Cable (16AWG, Shielded, Twisted pair, Orange, 500m/roll, LSZH). Spec.: 2*25*0.25BC + 2.6silicone rubber + PET + 7*0.18TCCA + AL + 6.8LSZH'),
    ('HEW18S2PC', 'CTL-1P-A18',  'A18',  'TC', '[{"n":16,"d":0.25}]', 2.15, 6.0, true,  true,  'TC',   0.18, 12, 2, 'PVC',  'Xám (Gray)', 305,
     'HEIZKA Security Control Cable 18AWG, 1 pair, Gray, AL-Shield, Twisted, 305m/roll, PVC. 2*16*0.25TC+2.15HDPE+2*filling rope+PET+12*0.18TC+6.0PVC'),
    ('HER15U2LZ', 'CFR-2C-1P5',  'M1.5', 'BC', '[{"n":30,"d":0.24}]', 2.6,  6.7, false, false, 'Không', null, 0, 0, 'LSZH', 'RAL 2004',    500,
     'HEIZKA Fire Resistant Instrumentation Cable 2x1.5mm2 16AWG, Unshielded, Twisted pair, Orange, 500m/roll, LSZH. Spec.: 2*30*0.24BC+2.6silicone rubber+6.7LSZH'),
    ('HEW16S2PC', 'CTL-1P-A16',  'A16',  'TC', '[{"n":26,"d":0.25}]', 2.5,  6.7, true,  true,  'TC',   0.18, 12, 2, 'PVC',  'Xám (Gray)', 305,
     'HEIZKA Security Control Cable 16AWG, 1 pair, Gray, AL-Shield, Twisted, 305m PVC. 2*26*0.25TC+2.5HDPE+2*filling rope+PET+12*0.18TC+6.7PVC'),
    ('HER10S2LZ', 'SFR-1P-1',    'M1',   'BC', '[{"n":16,"d":0.24}]', 2.1,  5.7, true,  true,  'TCCA', 0.18, 7,  0, 'LSZH', 'RAL 2004',    500,
     'HEIZKA Fire Resistant Instrumentation Cable 2x1.0mm2, 16AWG, Shielded, Twisted pair, Orange, 500m/roll, LSZH. Spec.: 2*16*0.24BC + 2.1silicone rubber + PET + 7*0.18TCCA + AL + 5.7LSZH'),
    ('HER25U2LZ', 'CFR-2C-2P5',  'M2.5', 'BC', '[{"n":49,"d":0.24}]', 3.1,  7.9, false, false, 'Không', null, 0, 0, 'LSZH', 'RAL 2004',    500,
     'HEIZKA Fire Resistant Instrumentation Cable 2x2.5mm2, 14AWG, Unshielded, Twisted pair, Orange, 500m/roll, LSZH. Spec.: 2*49*0.24BC+3.1silicone rubber+7.9LSZH')
  ) x(code, tpl, core, mat, wires, core_od, od, shield, pet, dmat, dd, dn, ropes, sheath, color, m_pack, note) loop
    continue when exists (select 1 from master.products where code = h.code);
    select ps.* into src from master.product_specs ps join master.products p on p.current_spec_id = ps.id where p.code = h.tpl;
    if src.id is null then raise exception 'Không có mã mẫu %', h.tpl; end if;
    select * into t from master.products where id = src.product_id;
    select * into tr from master.spec_results where spec_id = src.id;

    insert into master.products (code, group_code, description, default_brand, default_pack, default_m_per_pack)
    values (h.code, t.group_code, h.code, 'HEIZKA', 'Bobin gỗ', h.m_pack) returning id into v_product;

    s := src;
    s.id := gen_random_uuid(); s.product_id := v_product; s.version := 1; s.status := 'DRAFT'; s.change_level := 'NEW';
    s.released_at := null; s.released_by := null; s.rdc_deviation_note := null;
    s.created_at := now(); s.created_by := null; s.updated_at := now(); s.updated_by := null;
    s.core_code := h.core; s.conductor_mat := h.mat; s.shield := h.shield; s.pet_tape := h.pet;
    s.drain_mat := h.dmat; s.drain_dia_mm := h.dd; s.drain_wires := h.dn; s.pp_filler := h.ropes;
    s.sheath := h.sheath; s.sheath_color := h.color; s.brand := 'HEIZKA'; s.pack_type := 'Bobin gỗ'; s.m_per_pack := h.m_pack;
    s.config_note := 'Spec Heizka (TQ) – tạo từ mẫu ' || t.code || ': ' || h.note;
    insert into master.product_specs select s.*;
    v_spec := s.id;
    update master.products set current_spec_id = v_spec where id = v_product;

    insert into master.spec_results (spec_id, cable_bundle_mm, od_mm, sheath_kgkm, pp_kgkm, pet_kgkm, alpet_kgkm, drain_kgkm)
    values (v_spec, tr.cable_bundle_mm, tr.od_mm, tr.sheath_kgkm, 0, 0, case when h.shield then tr.alpet_kgkm else 0 end, 0);
    insert into master.bom_headers (spec_id, status, note) values (v_spec, 'DRAFT', 'Sao chép BOM từ ' || t.code || ' (spec Heizka)')
    returning id into v_bom;
    insert into master.bom_lines (bom_id, material_id, basis, qty_per_basis, loss_rate, startup_per_lot, operation_code, note)
    select v_bom, l.material_id, l.basis, l.qty_per_basis, l.loss_rate, l.startup_per_lot, l.operation_code, l.note
      from master.bom_lines l join master.bom_headers bh on bh.id = l.bom_id where bh.spec_id = src.id;

    -- Ruột dẫn, rồi cách điện theo đường kính lõi Heizka
    perform master.set_spec_layers(v_spec, jsonb_build_object('wire_mix', h.wires::jsonb));
    r := master.calc_spec(v_spec);
    v_ins := round((h.core_od - r.bundle_dia_mm) / 2, 3);
    update master.product_specs set ins_thickness_mm = v_ins where id = v_spec;
    r := master.calc_spec(v_spec);

    -- Vỏ theo OD Heizka
    v_bundle := 2 * r.core_dia_mm;
    v_extra := greatest(tr.od_mm - tr.cable_bundle_mm - 2 * src.sheath_thickness_mm, 0);
    v_sh := round((h.od - v_bundle - v_extra) / 2, 3);
    v_inner_t := tr.od_mm - 2 * src.sheath_thickness_mm;
    v_rho := tr.sheath_kgkm / (pi() / 4 * (tr.od_mm ^ 2 - v_inner_t ^ 2));
    update master.product_specs set sheath_thickness_mm = v_sh where id = v_spec;

    -- Drain, PET, độn
    v_drain_area := coalesce(h.dn, 0) * pi() * coalesce(h.dd, 0) ^ 2 / 4;
    v_drain := case when h.dmat = 'TCCA' then v_drain_area * tr.drain_kgkm / nullif(src.drain_wires * pi() * src.drain_dia_mm ^ 2 / 4, 0)
                    when h.dmat = 'TC' then v_drain_area * master.param(src.param_set_id, 'rhoTC') * 1.05
                    else 0 end;
    v_pet := case when h.pet then pi() * v_bundle * 1.25 * 0.025 * 1.38 else 0 end;
    v_pp := case when h.ropes > 0 then 0.3 * (pi() / 4 * v_bundle ^ 2 - 2 * pi() / 4 * r.core_dia_mm ^ 2) * 0.91 else 0 end;
    update master.spec_results set cable_bundle_mm = round(v_bundle, 4), od_mm = h.od,
           sheath_kgkm = round((v_rho * pi() / 4 * (h.od ^ 2 - (h.od - 2 * v_sh) ^ 2))::numeric, 4),
           drain_kgkm = round(coalesce(v_drain, 0), 4), pet_kgkm = round(v_pet, 4), pp_kgkm = round(v_pp, 4)
     where spec_id = v_spec;

    -- BOM: drain theo vật liệu/cỡ Heizka; thêm băng PET, độn PP
    select id into v_mat from master.materials where code = case h.dmat when 'TCCA' then 'TCCA-018' when 'TC' then 'TC-018' end;
    if v_mat is not null then
      update master.bom_lines l set material_id = v_mat from master.materials m
       where m.id = l.material_id and l.bom_id = v_bom and m.code like 'TCCA%';
    end if;
    if h.pet then
      insert into master.bom_lines (bom_id, material_id, basis, qty_per_basis, loss_rate, startup_per_lot, operation_code, note)
      select v_bom, m.id, 'KM', round(v_pet, 6), 0.03, 0, 'CD4', 'Băng PET bó cặp (spec Heizka, ước tính)' from master.materials m where m.code = 'PET-20'
      on conflict (bom_id, material_id, basis) do nothing;
    end if;
    if h.ropes > 0 then
      insert into master.bom_lines (bom_id, material_id, basis, qty_per_basis, loss_rate, startup_per_lot, operation_code, note)
      select v_bom, m.id, 'KM', round(v_pp, 6), 0.03, 0, 'CD3', h.ropes || ' sợi độn (spec Heizka, ước tính)' from master.materials m where m.code = 'PP-FILL'
      on conflict (bom_id, material_id, basis) do nothing;
    end if;

    perform master.calc_spec(v_spec);
    perform master.sync_bom(v_spec);
    update master.products set description = master.spec_name(v_spec) where id = v_product;
  end loop;
  perform set_config('bmt.admin_spec_edit', 'off', true);
end $$;

-- Tên các mã có sẵn theo quy tắc mới (không đổi gì với SFR/CTL vì đã có đoạn -nP-)
update master.products set description = master.spec_name(current_spec_id)
 where current_spec_id is not null and description is distinct from master.spec_name(current_spec_id);
