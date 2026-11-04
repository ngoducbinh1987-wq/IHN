-- Anh Bình 04/11/2026: PVC vỏ nhập kho (PVC-S, 50 kg mẫu) là PVC vỏ cáp điều khiển màu xám đã pha màu sẵn, không trộn hạt màu nữa.
--   * Bảng màu vỏ: PVC + Xám → không hạt màu (material_code null = pha sẵn);
--   * master.sync_bom: vỏ pha màu sẵn → bỏ dòng hạt màu vỏ, hạt vỏ = toàn bộ định mức vỏ;
--   * master.bom_issues: vỏ pha màu sẵn mà BOM còn hạt màu vỏ → báo thừa;
--   * vật tư PVC-S đổi tên "PVC vỏ xám (pha màu sẵn)";
--   * đồng bộ BOM mọi spec vỏ PVC còn hiệu lực (CTL, HEW: bỏ PV-GR), kế hoạch dùng các spec này → chạy lại MRP.
update master.pigment_rules set material_code = null, dose = 0 where kind = 'SH' and family = 'PVC' and color = 'xám';
update master.materials set name = 'PVC vỏ xám (pha màu sẵn)' where code = 'PVC-S';

do $$
declare v_def text; v_old text; v_new text;
begin
  -- sync_bom
  v_def := pg_get_functiondef('master.sync_bom(uuid)'::regprocedure);
  v_old := 'if v_rule.color is not null and v_rule.material_code is not null then';
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'master.sync_bom: không thấy đúng một đoạn cần vá';
  end if;
  v_new := $v$if v_rule.color is not null and v_rule.material_code is null then
      -- vỏ pha màu sẵn: không hạt màu, hạt vỏ = định mức vỏ
      delete from master.bom_lines l using master.materials m
       where m.id = l.material_id and l.bom_id = v_bom and m.group_code = 'COLOR' and master.bom_group(m.code, m.group_code, l.operation_code) = 'SH';
      select sum(l.qty_per_basis) into v_comp
        from master.bom_lines l join master.materials m on m.id = l.material_id
       where l.bom_id = v_bom and l.basis = 'KM' and m.group_code = 'COMPOUND' and master.bom_group(m.code, m.group_code, l.operation_code) = 'SH';
      if coalesce(v_comp, 0) > 0 then
        update master.bom_lines l set qty_per_basis = round(l.qty_per_basis * r.sheath_kgkm / v_comp, 6)
          from master.materials m
         where m.id = l.material_id and l.bom_id = v_bom and l.basis = 'KM' and m.group_code = 'COMPOUND'
           and master.bom_group(m.code, m.group_code, l.operation_code) = 'SH';
        v_n := v_n + 1; v_done := array_append(v_done, 'SH');
      end if;
    elsif v_rule.color is not null and v_rule.material_code is not null then$v$;
  execute replace(v_def, v_old, v_new);

  -- bom_issues
  v_def := pg_get_functiondef('master.bom_issues(uuid)'::regprocedure);
  v_old := 'elsif v_rule.material_code is not null and not exists';
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'master.bom_issues: không thấy đúng một đoạn cần vá';
  end if;
  v_new := $v$elsif v_rule.material_code is null and exists (select 1 from master.bom_lines l join master.materials m on m.id = l.material_id
             where l.bom_id = v_bom and m.group_code = 'COLOR' and master.bom_group(m.code, m.group_code, l.operation_code) = 'SH') then
      msgs := msgs || format('Vỏ %s màu %s pha màu sẵn: BOM thừa hạt màu vỏ', s.sheath, s.sheath_color);
    elsif v_rule.material_code is not null and not exists$v$;
  execute replace(v_def, v_old, v_new);
end $$;

-- Đồng bộ BOM spec vỏ PVC còn hiệu lực
select set_config('bmt.admin_spec_edit', 'on', true);
create temp table _synced as
select s.id, master.sync_bom(s.id) n from master.product_specs s where s.status <> 'OBSOLETE' and s.sheath = 'PVC';
update plan.production_plans pp set mrp_stale = true
 where pp.status in ('DRAFT', 'PENDING_APPROVAL', 'APPROVED') and not pp.mrp_stale
   and exists (select 1 from plan.plan_lines pl join _synced x on x.id = pl.spec_id where pl.plan_id = pp.id and x.n > 0);
drop table _synced;
select set_config('bmt.admin_spec_edit', 'off', true);
