-- Anh Bình 04/11/2026: mọi dây chống nhiễu (shield) của HEIZKA và KAVIX đều dùng drain TCCA Ø0,20 mm.
-- KAVIX (SFR, CTL) đã dùng TCCA Ø0,20 (TCCA-020). Sửa các spec còn khác (8 mã HEIZKA: 7×0,18 TCCA, 12×0,18 TC):
--   * drain_mat = TCCA, drain_dia_mm = 0,20, giữ số sợi của spec;
--   * định mức drain = số sợi × kg/km một sợi TCCA Ø0,20 lấy từ spec KAVIX đã phát hành (SFR-1P-1: 1,2017 kg/km ÷ 10 sợi);
--   * BOM: dòng drain TCCA-018 / TC-018 (CD3, CD4) đổi sang TCCA-020, MES đồng bộ suất theo định mức;
--   * ghi chú cấu hình: thay "n*0.18TCCA" / "n*0.18TC" bằng "n*0.20TCCA";
-- Sửa nhân danh Quản trị bằng app.admin_spec_edit (giữ trạng thái Đã phát hành, ghi nhật ký can thiệp, kế hoạch dùng mã → chạy lại MRP).
do $$
declare v_admin uuid; v_tcca uuid; v_per numeric; x record; v_note text; n int := 0;
begin
  select ur.user_id into v_admin from core.user_roles ur join core.profiles p on p.id = ur.user_id
   where ur.role_code = 'ADMIN' and p.status = 'ACTIVE' order by p.created_at limit 1;
  select id into v_tcca from master.materials where code = 'TCCA-020';
  if v_tcca is null then raise exception 'Thiếu vật tư TCCA-020'; end if;
  -- kg/km một sợi TCCA Ø0,20: trung bình các spec KAVIX đã phát hành dùng TCCA Ø0,20
  select avg(r.drain_kgkm / s.drain_wires) into v_per
    from master.product_specs s join master.spec_results r on r.spec_id = s.id
   where s.status = 'RELEASED' and s.drain_mat = 'TCCA' and s.drain_dia_mm = 0.2 and s.drain_wires > 0 and r.drain_kgkm > 0;
  v_per := coalesce(v_per, 0.12017);

  if v_admin is not null then perform set_config('request.jwt.claim.sub', v_admin::text, true); end if;

  for x in
    select s.id, s.status, s.drain_wires, s.config_note
      from master.product_specs s
     where s.status in ('DRAFT', 'PILOT_PENDING', 'PILOT', 'PENDING_APPROVAL', 'RELEASED')
       and coalesce(s.drain_wires, 0) > 0
       and (coalesce(s.drain_mat, '') <> 'TCCA' or s.drain_dia_mm is distinct from 0.2)
  loop
    perform set_config('bmt.admin_spec_edit', 'on', true);
    v_note := regexp_replace(coalesce(x.config_note, ''), '([0-9]+)\*0\.18TC(CA)?', '\1*0.20TCCA', 'g');
    update master.product_specs set drain_mat = 'TCCA', drain_dia_mm = 0.2, config_note = nullif(v_note, '') where id = x.id;
    update master.bom_lines l set material_id = v_tcca,
           note = trim(coalesce(l.note, '') || ' Drain chuẩn hóa TCCA Ø0,20 (04/11/2026).')
      from master.bom_headers h, master.materials m
     where h.id = l.bom_id and h.spec_id = x.id and m.id = l.material_id and l.operation_code in ('CD3', 'CD4')
       and m.code in ('TCCA-018', 'TC-018')
       and not exists (select 1 from master.bom_lines l2 where l2.bom_id = l.bom_id and l2.material_id = v_tcca and l2.basis = l.basis);
    if v_admin is not null then
      perform app.admin_spec_edit(x.id, 'spec', jsonb_build_object('drain_mat', 'TCCA', 'drain_kgkm', round(x.drain_wires * v_per, 4)),
        'Chuẩn hóa drain dây chống nhiễu: TCCA Ø0,20 mm (' || x.drain_wires || ' sợi)');
    else
      -- DB chưa có Quản trị (dựng mới để kiểm thử): ghi thẳng rồi tính lại, đồng bộ BOM
      update master.spec_results set drain_kgkm = round(x.drain_wires * v_per, 4) where spec_id = x.id;
      perform master.calc_spec(x.id);
      perform master.sync_bom(x.id);
    end if;
    n := n + 1;
  end loop;
  perform set_config('bmt.admin_spec_edit', 'off', true);
  perform set_config('request.jwt.claim.sub', '', true);
  raise notice 'Chuẩn hóa drain TCCA Ø0,20: % spec', n;
end $$;
