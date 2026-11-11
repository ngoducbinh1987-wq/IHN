-- Anh Bình 11/11/2026: LSZH vỏ có 2 loại màu (hạt LSZH pha màu sẵn): RAL 2004 (cam) cho HEIZKA, RAL 6037 (xanh) cho KAVIX.
--   * Vật tư: LSZH-S (hàng đang có, "LSZH cam pha màu sẵn") đổi mã LSZH-O "LSZH vỏ cam RAL 2004 (pha màu sẵn)";
--     thêm LSZH-G "LSZH vỏ xanh RAL 6037 (pha màu sẵn)". Hạt màu LS-O, LS-G không dùng nữa (ngừng, dự phòng 0).
--   * Bảng màu vỏ: LSZH RAL 2004 / RAL 6037 → không hạt màu, hạt vỏ pha sẵn tương ứng (cột mới pigment_rules.compound_code;
--     PVC xám → PVC-S cho đồng bộ). master.sync_bom đổi hạt vỏ theo màu; master.bom_issues báo sai hạt vỏ.
--   * Màu vỏ LSZH theo thương hiệu (bảng mới master.brand_sheath_colors): spec KAVIX vỏ LSZH đang RAL 2004 (SFR) → RAL 6037;
--     bom_issues báo khi màu vỏ khác màu của thương hiệu.
--   * Đồng bộ: BOM mọi spec vỏ LSZH còn hiệu lực; đơn mua tổng nháp: dòng hạt màu LS-O gộp vào dòng hạt LSZH cam;
--     kế hoạch đang dùng các spec này chạy lại MRP.

-- 1. Vật tư
update master.materials set code = 'LSZH-O' where code = 'LSZH-S'
   and not exists (select 1 from master.materials where code = 'LSZH-O');
update master.materials set name = 'LSZH vỏ cam RAL 2004 (pha màu sẵn)',
       purchase_spec = 'Compound vỏ LSZH pha màu sẵn RAL 2004 (cam) – dùng cho HEIZKA'
 where code = 'LSZH-O';
insert into master.materials (code, name, group_code, purchase_spec, uom, loss_rate, density, has_expiry, requires_coa, storage_zone, abc_class, shelf_life_days)
select 'LSZH-G', 'LSZH vỏ xanh RAL 6037 (pha màu sẵn)', group_code, 'Compound vỏ LSZH pha màu sẵn RAL 6037 (xanh) – dùng cho KAVIX',
       uom, loss_rate, density, has_expiry, requires_coa, storage_zone, abc_class, shelf_life_days
  from master.materials where code = 'LSZH-O'
on conflict (code) do nothing;
update master.materials set active = false, safety_stock = 0,
       data_note = left(coalesce(data_note || ' · ', '') || 'Ngừng dùng 11/11/2026: LSZH mua pha màu sẵn (LSZH-O cam, LSZH-G xanh)', 500)
 where code in ('LS-O', 'LS-G') and (active or safety_stock <> 0);

-- 2. Bảng màu vỏ: hạt vỏ pha sẵn theo màu
alter table master.pigment_rules add column if not exists compound_code text;
comment on column master.pigment_rules.compound_code is 'Vỏ pha màu sẵn: mã hạt vỏ của màu này (material_code null)';
update master.pigment_rules set material_code = null, dose = 0, compound_code = 'LSZH-O' where kind = 'SH' and family = 'LSZH' and color = 'ral 2004';
update master.pigment_rules set material_code = null, dose = 0, compound_code = 'LSZH-G' where kind = 'SH' and family = 'LSZH' and color = 'ral 6037';
update master.pigment_rules set compound_code = 'PVC-S' where kind = 'SH' and family = 'PVC' and color = 'xám' and material_code is null;

-- 3. Màu vỏ theo thương hiệu
create table if not exists master.brand_sheath_colors (
  brand text not null,
  family text not null,
  color text not null,
  note text,
  primary key (brand, family)
);
alter table master.brand_sheath_colors enable row level security;
revoke all on master.brand_sheath_colors from public, anon;
grant select on master.brand_sheath_colors to authenticated;
drop policy if exists brand_sheath_colors_read on master.brand_sheath_colors;
create policy brand_sheath_colors_read on master.brand_sheath_colors for select to authenticated using (true);
insert into master.brand_sheath_colors (brand, family, color, note) values
  ('HEIZKA', 'LSZH', 'RAL 2004', 'LSZH cam (anh Bình 11/11/2026)'),
  ('KAVIX', 'LSZH', 'RAL 6037', 'LSZH xanh (anh Bình 11/11/2026)')
on conflict (brand, family) do update set color = excluded.color, note = excluded.note;

-- 4. sync_bom: vỏ pha màu sẵn có hạt vỏ riêng theo màu → đổi dòng hạt vỏ sang đúng mã
do $$
declare d text; v_from text := '-- vỏ pha màu sẵn: không hạt màu, hạt vỏ = định mức vỏ';
begin
  d := replace(pg_get_functiondef('master.sync_bom(uuid)'::regprocedure), E'\r', '');
  if (length(d) - length(replace(d, v_from, ''))) / length(v_from) <> 1 then
    raise exception 'master.sync_bom: không thấy đúng một đoạn cần vá';
  end if;
  execute replace(d, v_from, $v$-- hạt vỏ pha sẵn theo màu (LSZH cam/xanh, PVC xám): mọi dòng hạt vỏ gộp về đúng mã
      if v_rule.compound_code is not null then
        select id into v_mat from master.materials where code = v_rule.compound_code;
        select sum(l.qty_per_basis), sum(l.startup_per_lot), min(l.operation_code) into v_comp, v_cs, v_op
          from master.bom_lines l join master.materials m on m.id = l.material_id
         where l.bom_id = v_bom and l.basis = 'KM' and m.group_code = 'COMPOUND' and master.bom_group(m.code, m.group_code, l.operation_code) = 'SH';
        if v_mat is not null and coalesce(v_comp, 0) > 0
           and exists (select 1 from master.bom_lines l join master.materials m on m.id = l.material_id
                        where l.bom_id = v_bom and l.basis = 'KM' and m.group_code = 'COMPOUND'
                          and master.bom_group(m.code, m.group_code, l.operation_code) = 'SH' and l.material_id <> v_mat) then
          delete from master.bom_lines l using master.materials m
           where m.id = l.material_id and l.bom_id = v_bom and l.basis = 'KM' and m.group_code = 'COMPOUND'
             and master.bom_group(m.code, m.group_code, l.operation_code) = 'SH';
          insert into master.bom_lines (bom_id, material_id, basis, qty_per_basis, loss_rate, startup_per_lot, operation_code)
          select v_bom, m.id, 'KM', round(v_comp, 6), m.loss_rate, round(coalesce(v_cs, 0), 6), coalesce(v_op, 'CD5')
            from master.materials m where m.id = v_mat;
          v_n := v_n + 1;
        end if;
      end if
      $v$ || ';' || E'\n      ' || v_from);
end $$;

-- 5. bom_issues: sai hạt vỏ pha sẵn; màu vỏ khác màu của thương hiệu
do $$
declare d text; v_from text := 'elsif v_rule.material_code is not null and not exists';
  v_from2 text := '  -- 6. Băng AL/PET theo bề rộng';
begin
  d := replace(pg_get_functiondef('master.bom_issues(uuid)'::regprocedure), E'\r', '');
  if (length(d) - length(replace(d, v_from, ''))) / length(v_from) <> 1
     or (length(d) - length(replace(d, v_from2, ''))) / length(v_from2) <> 1 then
    raise exception 'master.bom_issues: không thấy đúng một đoạn cần vá';
  end if;
  d := replace(d, v_from, $v$elsif v_rule.material_code is null and v_rule.compound_code is not null
       and (not exists (select 1 from master.bom_lines l join master.materials m on m.id = l.material_id
                         where l.bom_id = v_bom and m.code = v_rule.compound_code and master.bom_group(m.code, m.group_code, l.operation_code) = 'SH')
            or exists (select 1 from master.bom_lines l join master.materials m on m.id = l.material_id
                        where l.bom_id = v_bom and m.group_code = 'COMPOUND' and m.code <> v_rule.compound_code
                          and master.bom_group(m.code, m.group_code, l.operation_code) = 'SH')) then
      msgs := msgs || format('Vỏ %s màu %s dùng hạt vỏ pha sẵn %s: BOM dùng %s', s.sheath, s.sheath_color, v_rule.compound_code,
        coalesce((select string_agg(m.code, ', ') from master.bom_lines l join master.materials m on m.id = l.material_id
                   where l.bom_id = v_bom and m.group_code = 'COMPOUND' and master.bom_group(m.code, m.group_code, l.operation_code) = 'SH'), 'chưa có'));
    $v$ || v_from);
  d := replace(d, v_from2, $v$  -- 5b. Màu vỏ theo thương hiệu (master.brand_sheath_colors)
  if s.sheath <> 'Không' then
    select string_agg(b.color, ', ') into v_list from master.brand_sheath_colors b
     where b.brand = s.brand and b.family = s.sheath and master.norm_color(b.color) <> coalesce(master.norm_color(s.sheath_color), '');
    if v_list is not null then
      msgs := msgs || format('Vỏ %s thương hiệu %s phải màu %s (đang %s)', s.sheath, s.brand, v_list, coalesce(s.sheath_color, 'chưa khai'));
    end if;
  end if;

$v$ || v_from2);
  execute d;
end $$;

-- 6. Spec KAVIX vỏ LSZH → RAL 6037; HEIZKA → RAL 2004 (nhân danh Quản trị, ghi nhật ký can thiệp)
do $$
declare v_admin uuid; r record;
begin
  select ur.user_id into v_admin from core.user_roles ur join core.profiles p on p.id = ur.user_id
   where ur.role_code = 'ADMIN' and p.status = 'ACTIVE' order by p.created_at limit 1;
  if v_admin is not null then perform set_config('request.jwt.claim.sub', v_admin::text, true); end if;
  perform set_config('bmt.admin_spec_edit', 'on', true);
  for r in select s.id, p.code, s.version, s.status, s.sheath_color old_color, b.color new_color
             from master.product_specs s join master.products p on p.id = s.product_id
             join master.brand_sheath_colors b on b.brand = s.brand and b.family = s.sheath
            where s.status <> 'OBSOLETE' and master.norm_color(s.sheath_color) is distinct from master.norm_color(b.color) loop
    update master.product_specs set sheath_color = r.new_color where id = r.id;
    if v_admin is not null then
      perform app.admin_log('master.product_specs', r.id::text, 'ADMIN_SPEC',
        jsonb_build_object('doc_type', 'Sửa spec', 'doc_no', r.code || ' v' || r.version, 'sheath_color', r.old_color),
        jsonb_build_object('sheath_color', r.new_color,
          'reason', 'LSZH 2 màu theo thương hiệu: RAL 2004 HEIZKA, RAL 6037 KAVIX (anh Bình 11/11/2026)'));
    end if;
  end loop;
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

-- 7. Đồng bộ BOM spec vỏ LSZH, PVC còn hiệu lực
select set_config('bmt.admin_spec_edit', 'on', true);
create temp table _synced as
select s.id, master.sync_bom(s.id) n from master.product_specs s where s.status <> 'OBSOLETE' and s.sheath in ('LSZH', 'PVC');
update plan.production_plans pp set mrp_stale = true
 where pp.status in ('DRAFT', 'PENDING_APPROVAL', 'APPROVED') and not pp.mrp_stale
   and exists (select 1 from plan.plan_lines pl join _synced x on x.id = pl.spec_id where pl.plan_id = pp.id and x.n > 0);
drop table _synced;
select set_config('bmt.admin_spec_edit', 'off', true);

-- 8. Đơn mua tổng / hợp đồng chưa duyệt: dòng hạt màu LSZH (LS-O, LS-G) gộp vào dòng hạt LSZH pha sẵn cùng màu
do $$
declare r record; v_target uuid; v_comp uuid; v_note text;
begin
  for r in select l.id, l.po_id, l.qty, po.po_no, m.code
             from purchase.po_lines l join purchase.purchase_orders po on po.id = l.po_id join master.materials m on m.id = l.material_id
            where m.code in ('LS-O', 'LS-G') and po.status in ('DRAFT', 'PENDING_APPROVAL') and l.received_qty = 0 loop
    select id into v_comp from master.materials where code = case r.code when 'LS-O' then 'LSZH-O' else 'LSZH-G' end;
    v_note := 'Gộp ' || wf.fmt_qty(r.qty) || ' kg hạt màu ' || r.code || ': LSZH mua pha màu sẵn (11/11/2026)';
    select id into v_target from purchase.po_lines where po_id = r.po_id and material_id = v_comp and received_qty = 0 order by line_no limit 1;
    if v_target is not null then
      update purchase.po_lines set qty = qty + r.qty, note = left(coalesce(note || ' · ', '') || v_note, 500) where id = v_target;
      delete from purchase.po_lines where id = r.id;
    else
      update purchase.po_lines set material_id = v_comp, note = left(coalesce(note || ' · ', '') || v_note, 500) where id = r.id;
    end if;
    raise notice '%: %', r.po_no, v_note;
  end loop;
end $$;

-- 9. Kế hoạch đã duyệt / nháp dùng spec vừa đồng bộ: chạy lại MRP (giữ dự phòng, điều chỉnh MRP không đổi nhu cầu)
do $$
declare v_admin uuid; r record;
begin
  select ur.user_id into v_admin from core.user_roles ur join core.profiles p on p.id = ur.user_id
   where ur.role_code = 'ADMIN' and p.status = 'ACTIVE' order by p.created_at limit 1;
  if v_admin is null then return; end if;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  for r in select id, plan_no from plan.production_plans
            where status in ('DRAFT', 'APPROVED') and mrp_stale
              and exists (select 1 from plan.mrp_runs m where m.plan_id = production_plans.id) loop
    begin
      perform app.plan_run_mrp(r.id);
      raise notice 'Đã chạy lại MRP %', r.plan_no;
    exception when others then
      raise notice 'Không chạy lại được MRP % (%): TP SX bấm Chạy MRP', r.plan_no, sqlerrm;
    end;
  end loop;
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
