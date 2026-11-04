-- Anh Bình 04/11/2026: bổ sung spec sản xuất 2 mã HEIZKA, mô tả theo quy tắc danh mục, cập nhật và phê duyệt luôn.
--   HEW14S2PC  2*41*0.25TC + 3.1 HDPE + 2*filling rope + PET + 7*0.18TCCA + 8.2 PVC   (14AWG, 1 pair, Grey, AL-Shield, Twisted, 305 m)
--   HER14S2LZ  2*40*0.25BC + 3.1 silicone + PET + 7*0.18TCCA + AL + 8.0 LSZH           (Shielded, Twisted pair, Orange, 500 m)
-- Dựng như migration 6700 (mã mẫu Kavix gần nhất: CTL-1P-A14, SFR-1P-2P5): ruột theo spec, chiều dày cách điện suy từ đường kính lõi,
-- vỏ suy từ OD, drain 7×0,18 TCCA, PET + độn PP ước tính; tên (Quy cách) MES tự đặt theo quy tắc.
-- HER14S2LZ: tên tiếng Anh ghi 16AWG nhưng mã "14" và ruột 40×0,25 mm (1,96 mm²) là cỡ 14AWG → lõi A14 (giống HER16 = A16, HER18 = A18).
-- Phê duyệt: phát hành ngay bằng app.admin_spec_release (migration 8400) nhân danh Quản trị, như 8 mã HEIZKA trước;
-- Rdc tính vượt giới hạn thì ghi chấp nhận sai lệch "Đã kiểm tra thực tế, duyệt mẫu này" và web vẫn cảnh báo.

do $$
declare
  h record; src master.product_specs; t master.products; tr master.spec_results; s master.product_specs; r master.spec_results;
  v_product uuid; v_spec uuid; v_bom uuid; v_ins numeric; v_bundle numeric; v_extra numeric; v_sh numeric; v_rho numeric;
  v_inner_t numeric; v_drain_area numeric; v_drain numeric; v_pet numeric; v_pp numeric; v_mat uuid;
begin
  perform set_config('bmt.admin_spec_edit', 'on', true);
  for h in select * from (values
    ('HEW14S2PC', 'CTL-1P-A14',  'A14',  'TC', '[{"n":41,"d":0.25}]', 3.1,  8.2, true,  true,  'TCCA', 0.18, 7,  2, 'PVC',  'Xám (Gray)', 305,
     'HEIZKA Security Control Cable 14AWG, 1 pair, Grey, AL-Shield, Twisted, 305m PVC. Spec.: 2*41*0.25TC+3.1HDPE+2*filling rope+PET+7*0.18TCCA+8.2PVC'),
    ('HER14S2LZ', 'SFR-1P-2P5',  'A14',  'BC', '[{"n":40,"d":0.25}]', 3.1,  8.0, true,  true,  'TCCA', 0.18, 7,  0, 'LSZH', 'RAL 2004',    500,
     'HEIZKA Fire Resistant Instrumentation Cable (16AWG, Shielded, Twisted pair, Orange, 500m/roll, LSZH). Spec.: 2*40*0.25BC+3.1silicone rubber+PET+7*0.18TCCA+AL+8.0LSZH')
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


-- Phát hành ngay (DB không có Quản trị – dựng mới để kiểm thử – thì để Nháp)
do $$
declare v_admin uuid; x record;
begin
  select ur.user_id into v_admin from core.user_roles ur join core.profiles p on p.id = ur.user_id
   where ur.role_code = 'ADMIN' and p.status = 'ACTIVE' order by p.created_at limit 1;
  if v_admin is null then return; end if;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  for x in select s.id from master.product_specs s join master.products p on p.current_spec_id = s.id
            where p.code in ('HEW14S2PC', 'HER14S2LZ') and s.status not in ('RELEASED', 'OBSOLETE') order by p.code loop
    perform app.admin_spec_release(x.id, 'Đã kiểm tra thực tế, duyệt mẫu này');
  end loop;
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
