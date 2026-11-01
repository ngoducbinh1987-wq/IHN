-- Anh Bình 01/11/2026 (CFR-4C-0P75: lõi Nâu, Trắng, Đen, Trắng nhưng BOM vẫn màu Nâu + Xanh dương): rà soát lại toàn bộ BOM.
-- Quy luật lấy từ file Excel 3.0 (78 spec): hạt màu cách điện = tỷ lệ pha × khối lượng cách điện của các lõi có màu
--   silicone 1 % (lõi trắng = silicone tự nhiên, không pha màu), HDPE 2 % (trắng dùng HD-W), PVC 2 %; hạt màu vỏ 2 % hạt vỏ.
-- Từ nay:
--  * master.pigment_rules: bảng màu → vật tư màu + tỷ lệ pha (cách điện theo vật liệu cách điện; vỏ theo vật liệu vỏ + màu vỏ).
--  * master.sync_bom: màu cách điện theo đúng màu từng lõi (số lõi mỗi màu), màu vỏ theo màu vỏ, sợi đồng theo từng cỡ sợi
--    (mỗi cỡ một vật tư CU-0dd / TC-0dd, chia theo n·d²), rồi các nhóm còn lại theo định mức MES như trước.
--  * master.bom_issues: báo cả thiếu vật tư sợi đồng theo cỡ, màu lõi chưa khai / chưa có vật tư, màu vỏ, băng AL/PET theo bề rộng.

create table if not exists master.pigment_rules (
  kind      text not null check (kind in ('INS', 'SH')),      -- INS: màu cách điện; SH: màu vỏ
  family    text not null,                                   -- INS: SIL/HDPE/PVC; SH: LSZH/FR-PVC/PVC
  color     text not null,                                   -- tên màu chuẩn hóa (master.norm_color)
  material_code text,                                        -- null = không pha màu (vật liệu tự nhiên)
  dose      numeric not null default 0 check (dose >= 0 and dose < 0.2),  -- tỷ lệ hạt màu / khối lượng vật liệu nền
  primary key (kind, family, color)
);
alter table master.pigment_rules enable row level security;
grant select on master.pigment_rules to authenticated;
drop policy if exists pigment_rules_read on master.pigment_rules;
create policy pigment_rules_read on master.pigment_rules for select to authenticated using (true);

insert into master.pigment_rules (kind, family, color, material_code, dose) values
  ('INS', 'SIL', 'trắng', null, 0.01), ('INS', 'SIL', 'nâu', 'SI-C0', 0.01), ('INS', 'SIL', 'xanh dương', 'SI-C1', 0.01),
  ('INS', 'SIL', 'đen', 'SI-C2', 0.01), ('INS', 'SIL', 'xám', 'SI-C3', 0.01), ('INS', 'SIL', 'vàng-xanh lá', 'SI-C4', 0.01),
  ('INS', 'HDPE', 'trắng', 'HD-W', 0.02), ('INS', 'HDPE', 'đen', 'HD-B', 0.02), ('INS', 'HDPE', 'nâu', 'HD-C0', 0.02),
  ('INS', 'HDPE', 'xanh dương', 'HD-C1', 0.02),
  ('INS', 'PVC', 'nâu', 'PI-C0', 0.02), ('INS', 'PVC', 'xanh dương', 'PI-C1', 0.02), ('INS', 'PVC', 'đen', 'PI-C2', 0.02),
  ('INS', 'PVC', 'xám', 'PI-C3', 0.02), ('INS', 'PVC', 'vàng-xanh lá', 'PI-C4', 0.02),
  ('SH', 'LSZH', 'ral 6037', 'LS-G', 0.02), ('SH', 'LSZH', 'ral 2004', 'LS-O', 0.02),
  ('SH', 'FR-PVC', 'ral 6037', 'PF-G', 0.02), ('SH', 'FR-PVC', 'ral 2004', 'PF-O', 0.02),
  ('SH', 'PVC', 'ral 6037', 'PV-G', 0.02), ('SH', 'PVC', 'ral 2004', 'PV-O', 0.02), ('SH', 'PVC', 'xám', 'PV-GR', 0.02)
on conflict (kind, family, color) do nothing;

-- Chuẩn hóa tên màu: "Vàng xanh", "Vàng-xanh lá" → "vàng-xanh lá"; "RAL 6037" → "ral 6037"; "Xám (Gray)" → "xám"
create or replace function master.norm_color(p text) returns text
language sql immutable set search_path = pg_catalog as $$
  select case
    when p is null or trim(p) = '' then null
    when p ~ '6037' then 'ral 6037'
    when p ~ '2004' then 'ral 2004'
    when lower(p) ~ 'vàng' and lower(p) ~ 'xanh' then 'vàng-xanh lá'
    when lower(p) ~ 'xám|gray|grey' then 'xám'
    when lower(p) ~ 'xanh dương|xanh lam|blue' then 'xanh dương'
    when lower(p) ~ 'nâu|brown' then 'nâu'
    when lower(p) ~ 'đen|black' then 'đen'
    when lower(p) ~ 'trắng|white' then 'trắng'
    else lower(trim(p))
  end
$$;

-- Vật tư sợi đồng theo vật liệu + cỡ sợi: BC Ø0,24 → CU-024, TC Ø0,20 → TC-020
create or replace function master.wire_material(p_mat text, p_d numeric) returns text
language sql immutable set search_path = pg_catalog as $$
  select case when p_mat = 'TC' then 'TC-' else 'CU-' end || lpad(round(p_d * 100)::int::text, 3, '0')
$$;

-- Lượng dự kiến từng vật tư màu cách điện của spec (theo màu từng lõi). Trả rỗng khi chưa khai đủ màu lõi.
-- base_frac = phần khối lượng cách điện các lõi màu đó ÷ tổng (n lõi ÷ số lõi).
create or replace function master.ins_color_plan(p_spec uuid)
returns table (color text, n int, material_code text, dose numeric, ok boolean)
language sql stable security definer set search_path = pg_catalog, public as $$
  with s as (select * from master.product_specs where id = p_spec),
  c as (select master.norm_color(x) col, count(*)::int n from s, unnest(s.core_colors) x group by 1)
  select c.col, c.n, r.material_code, coalesce(r.dose, 0), r.color is not null
    from c cross join s left join master.pigment_rules r on r.kind = 'INS' and r.family = s.insulation and r.color = c.col
   where s.core_colors is not null and not exists (select 1 from s, unnest(s.core_colors) x where x is null or trim(x) = '')
$$;
revoke all on function master.ins_color_plan(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- Đồng bộ BOM theo thông số (viết lại)
create or replace function master.sync_bom(p_spec uuid) returns int
language plpgsql security definer set search_path = pg_catalog, public as $$
declare s master.product_specs; r master.spec_results; v_bom uuid; t record; v_sum numeric; v_n int := 0; v_k int;
  v_label uuid; v_other uuid; v_comp numeric; v_add numeric; v_cs numeric; v_den numeric; v_C numeric; v_op text;
  v_nd2 numeric; v_ok boolean; v_rule master.pigment_rules; v_mat uuid; v_done text[] := '{}';
begin
  select * into s from master.product_specs where id = p_spec;
  select * into r from master.spec_results where spec_id = p_spec;
  select h.id into v_bom from master.bom_headers h where h.spec_id = p_spec;
  if v_bom is null or r.spec_id is null then return 0; end if;

  -- (a) Sợi đồng theo từng cỡ sợi: đủ vật tư cho mọi cỡ thì mỗi cỡ một dòng, lượng = đồng × n·d² ÷ Σ n·d²
  select sum((e->>'n')::numeric * (e->>'d')::numeric ^ 2),
         bool_and(exists (select 1 from master.materials m where m.code = master.wire_material(s.conductor_mat, (e->>'d')::numeric)))
    into v_nd2, v_ok
    from jsonb_array_elements(coalesce(s.wire_mix, jsonb_build_array(jsonb_build_object('n', s.wire_count, 'd', s.wire_dia_mm)))) e;
  if v_ok and v_nd2 > 0 and coalesce(r.metal_kgkm, 0) > 0 then
    create temp table if not exists _wire (material_id uuid primary key, q numeric) on commit drop;
    delete from _wire where true;
    insert into _wire
    select m.id, sum(r.metal_kgkm * (e->>'n')::numeric * (e->>'d')::numeric ^ 2 / v_nd2)
      from jsonb_array_elements(coalesce(s.wire_mix, jsonb_build_array(jsonb_build_object('n', s.wire_count, 'd', s.wire_dia_mm)))) e
      join master.materials m on m.code = master.wire_material(s.conductor_mat, (e->>'d')::numeric)
     group by m.id;
    delete from master.bom_lines l using master.materials m
     where m.id = l.material_id and l.bom_id = v_bom and master.bom_group(m.code, m.group_code, l.operation_code) = 'CU'
       and l.material_id not in (select material_id from _wire);
    insert into master.bom_lines (bom_id, material_id, basis, qty_per_basis, loss_rate, startup_per_lot, operation_code)
    select v_bom, w.material_id, 'KM', round(w.q, 6), m.loss_rate, 0, 'CD1' from _wire w join master.materials m on m.id = w.material_id
    on conflict (bom_id, material_id, basis) do update set qty_per_basis = excluded.qty_per_basis, operation_code = 'CD1';
    v_n := v_n + 1; v_done := array_append(v_done, 'CU');
  end if;

  -- (b) Cách điện theo màu từng lõi: C (vật liệu nền) = cách điện ÷ (1 + phụ gia/C + Σ tỷ lệ pha × n màu ÷ số lõi)
  if exists (select 1 from master.ins_color_plan(p_spec)) and not exists (select 1 from master.ins_color_plan(p_spec) where not ok)
     and coalesce(r.ins_kgkm, 0) > 0 then
    select sum(l.qty_per_basis) filter (where m.group_code = 'COMPOUND'), sum(l.qty_per_basis) filter (where m.group_code = 'ADDITIVE'),
           sum(l.startup_per_lot) filter (where m.group_code = 'COMPOUND'), min(l.operation_code) filter (where m.group_code = 'COMPOUND')
      into v_comp, v_add, v_cs, v_op
      from master.bom_lines l join master.materials m on m.id = l.material_id
     where l.bom_id = v_bom and l.basis = 'KM' and master.bom_group(m.code, m.group_code, l.operation_code) = 'INS';
    if coalesce(v_comp, 0) > 0 then
      v_den := 1 + coalesce(v_add, 0) / v_comp + (select coalesce(sum(p.dose * p.n), 0) from master.ins_color_plan(p_spec) p where p.material_code is not null) / s.cores;
      v_C := r.ins_kgkm / v_den;
      update master.bom_lines l set qty_per_basis = round(l.qty_per_basis * v_C / v_comp, 6)
        from master.materials m
       where m.id = l.material_id and l.bom_id = v_bom and l.basis = 'KM' and m.group_code in ('COMPOUND', 'ADDITIVE')
         and master.bom_group(m.code, m.group_code, l.operation_code) = 'INS';
      delete from master.bom_lines l using master.materials m
       where m.id = l.material_id and l.bom_id = v_bom and m.group_code = 'COLOR' and master.bom_group(m.code, m.group_code, l.operation_code) = 'INS'
         and m.code not in (select p.material_code from master.ins_color_plan(p_spec) p where p.material_code is not null);
      insert into master.bom_lines (bom_id, material_id, basis, qty_per_basis, loss_rate, startup_per_lot, operation_code)
      select v_bom, m.id, 'KM', round(p.dose * p.n * v_C / s.cores, 6), m.loss_rate,
             round(p.dose * p.n * coalesce(v_cs, 0) / s.cores, 6), v_op
        from master.ins_color_plan(p_spec) p join master.materials m on m.code = p.material_code
      on conflict (bom_id, material_id, basis) do update set qty_per_basis = excluded.qty_per_basis,
        startup_per_lot = excluded.startup_per_lot, operation_code = excluded.operation_code;
      v_n := v_n + 1; v_done := array_append(v_done, 'INS');
    end if;
  end if;

  -- (c) Vỏ theo màu vỏ: hạt vỏ = vỏ ÷ (1 + tỷ lệ pha), hạt màu = tỷ lệ pha × hạt vỏ
  if s.sheath <> 'Không' and coalesce(r.sheath_kgkm, 0) > 0 then
    select * into v_rule from master.pigment_rules where kind = 'SH' and family = s.sheath and color = master.norm_color(s.sheath_color);
    if v_rule.color is not null and v_rule.material_code is not null then
      select id into v_mat from master.materials where code = v_rule.material_code;
      select sum(l.qty_per_basis), sum(l.startup_per_lot), min(l.operation_code) into v_comp, v_cs, v_op
        from master.bom_lines l join master.materials m on m.id = l.material_id
       where l.bom_id = v_bom and l.basis = 'KM' and m.group_code = 'COMPOUND' and master.bom_group(m.code, m.group_code, l.operation_code) = 'SH';
      if v_mat is not null and coalesce(v_comp, 0) > 0 then
        v_C := r.sheath_kgkm / (1 + v_rule.dose);
        update master.bom_lines l set qty_per_basis = round(l.qty_per_basis * v_C / v_comp, 6)
          from master.materials m
         where m.id = l.material_id and l.bom_id = v_bom and l.basis = 'KM' and m.group_code = 'COMPOUND'
           and master.bom_group(m.code, m.group_code, l.operation_code) = 'SH';
        delete from master.bom_lines l using master.materials m
         where m.id = l.material_id and l.bom_id = v_bom and m.group_code = 'COLOR' and master.bom_group(m.code, m.group_code, l.operation_code) = 'SH'
           and l.material_id <> v_mat;
        insert into master.bom_lines (bom_id, material_id, basis, qty_per_basis, loss_rate, startup_per_lot, operation_code)
        select v_bom, v_mat, 'KM', round(v_rule.dose * v_C, 6), m.loss_rate, round(v_rule.dose * coalesce(v_cs, 0), 6), v_op
          from master.materials m where m.id = v_mat
        on conflict (bom_id, material_id, basis) do update set qty_per_basis = excluded.qty_per_basis,
          startup_per_lot = excluded.startup_per_lot, operation_code = excluded.operation_code;
        v_n := v_n + 1; v_done := array_append(v_done, 'SH');
      end if;
    end if;
  end if;

  -- (d) Các nhóm còn lại (và nhóm trên khi chưa đủ dữ liệu): giữ tỷ lệ, tổng = định mức MES
  for t in select * from master.bom_targets(p_spec) where not (grp = any(v_done)) loop
    select sum(l.qty_per_basis) into v_sum
      from master.bom_lines l join master.materials m on m.id = l.material_id
     where l.bom_id = v_bom and l.basis = 'KM' and master.bom_group(m.code, m.group_code, l.operation_code) = t.grp;
    if coalesce(v_sum, 0) > 0 and t.target > 0 and abs(v_sum - t.target) > 0.0000005 then
      update master.bom_lines l set qty_per_basis = round(l.qty_per_basis * t.target / v_sum, 6)
        from master.materials m
       where m.id = l.material_id and l.bom_id = v_bom and l.basis = 'KM'
         and master.bom_group(m.code, m.group_code, l.operation_code) = t.grp;
      get diagnostics v_k = row_count; v_n := v_n + v_k;
    end if;
  end loop;

  -- (e) Nhãn theo thương hiệu
  select id into v_label from master.materials where code = case s.brand when 'HEIZKA' then 'LABEL-H' else 'LABEL-K' end;
  select id into v_other from master.materials where code = case s.brand when 'HEIZKA' then 'LABEL-K' else 'LABEL-H' end;
  if v_label is not null and v_other is not null
     and not exists (select 1 from master.bom_lines where bom_id = v_bom and material_id = v_label) then
    update master.bom_lines set material_id = v_label where bom_id = v_bom and material_id = v_other;
    get diagnostics v_k = row_count; v_n := v_n + v_k;
  end if;
  return v_n;
end $$;
revoke all on function master.sync_bom(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- Đối chiếu BOM (viết lại, thêm cỡ sợi, màu lõi theo lượng, màu vỏ, AL/PET)
create or replace function master.bom_issues(p_spec uuid) returns text[]
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare s master.product_specs; r master.spec_results; v_bom uuid; t record; v_sum numeric; v_cnt int; msgs text[] := '{}'; v_list text;
  v_ins_prefix text; v_ins_comp text; v_sh_prefix text; v_sh_comp text; v_rule master.pigment_rules; v_comp numeric; v_add numeric;
  v_den numeric; v_C numeric; pc record; v_q numeric; e jsonb; v_code text;
begin
  select * into s from master.product_specs where id = p_spec;
  select * into r from master.spec_results where spec_id = p_spec;
  select id into v_bom from master.bom_headers where spec_id = p_spec;
  if v_bom is null then return array['Chưa có BOM']; end if;

  -- 1. Tổng từng nhóm so với định mức MES
  for t in select * from master.bom_targets(p_spec) loop
    select sum(l.qty_per_basis), count(*) into v_sum, v_cnt
      from master.bom_lines l join master.materials m on m.id = l.material_id
     where l.bom_id = v_bom and master.bom_group(m.code, m.group_code, l.operation_code) = t.grp;
    if t.target > 0 and v_cnt = 0 then
      msgs := msgs || format('BOM thiếu vật tư %s (%s kg/km)', t.label, round(t.target, 3));
    elsif t.target <= 0 and v_cnt > 0 then
      msgs := msgs || format('BOM thừa vật tư %s: thông số không có lớp này', t.label);
    elsif v_cnt > 0 and abs(coalesce(v_sum, 0) - t.target) > greatest(0.0005, t.target * 0.001) then
      msgs := msgs || format('BOM %s %s kg/km ≠ định mức %s kg/km', t.label, round(v_sum, 3), round(t.target, 3));
    end if;
  end loop;

  -- 2. Sợi đồng: mỗi cỡ sợi một vật tư đúng vật liệu, đúng lượng theo n·d²
  for e in select x from jsonb_array_elements(coalesce(s.wire_mix, jsonb_build_array(jsonb_build_object('n', s.wire_count, 'd', s.wire_dia_mm)))) x loop
    v_code := master.wire_material(s.conductor_mat, (e->>'d')::numeric);
    if not exists (select 1 from master.materials where code = v_code) then
      msgs := msgs || format('Chưa có vật tư sợi đồng %s Ø%s (mã %s): khai ở Vật tư rồi lưu lại thông số',
                             case s.conductor_mat when 'TC' then 'mạ thiếc' else 'trần' end, replace(((e->>'d')::numeric)::text, '.', ','), v_code);
    end if;
  end loop;
  select string_agg(m.code, ', ') into v_list from master.bom_lines l join master.materials m on m.id = l.material_id
   where l.bom_id = v_bom and master.bom_group(m.code, m.group_code, l.operation_code) = 'CU'
     and m.code not in (select master.wire_material(s.conductor_mat, (x->>'d')::numeric)
                          from jsonb_array_elements(coalesce(s.wire_mix, jsonb_build_array(jsonb_build_object('n', s.wire_count, 'd', s.wire_dia_mm)))) x);
  if v_list is not null then msgs := msgs || format('Ruột dẫn %s (%s) nhưng BOM dùng %s', s.conductor_mat,
       (select string_agg(x->>'n' || '×' || replace(x->>'d', '.', ','), ' + ') from jsonb_array_elements(s.wire_mix) x), v_list); end if;

  -- 3. Vật liệu nền cách điện, vỏ
  v_ins_comp := case s.insulation when 'SIL' then 'SIL-' when 'HDPE' then 'HDPE-' else 'PVC-I' end;
  v_ins_prefix := case s.insulation when 'SIL' then 'SI-' when 'HDPE' then 'HD-' else 'PI-' end;
  select string_agg(m.code, ', ') into v_list from master.bom_lines l join master.materials m on m.id = l.material_id
   where l.bom_id = v_bom and master.bom_group(m.code, m.group_code, l.operation_code) = 'INS'
     and ((m.group_code = 'COMPOUND' and m.code not like v_ins_comp || '%') or (m.group_code = 'COLOR' and m.code not like v_ins_prefix || '%'));
  if v_list is not null then msgs := msgs || format('Cách điện %s nhưng BOM dùng %s', s.insulation, v_list); end if;
  if s.sheath <> 'Không' then
    v_sh_comp := case s.sheath when 'LSZH' then 'LSZH-' when 'FR-PVC' then 'PVC-FR' else 'PVC-S' end;
    v_sh_prefix := case s.sheath when 'LSZH' then 'LS-' when 'FR-PVC' then 'PF-' else 'PV-' end;
    select string_agg(m.code, ', ') into v_list from master.bom_lines l join master.materials m on m.id = l.material_id
     where l.bom_id = v_bom and master.bom_group(m.code, m.group_code, l.operation_code) = 'SH'
       and ((m.group_code = 'COMPOUND' and m.code not like v_sh_comp || '%') or (m.group_code = 'COLOR' and m.code not like v_sh_prefix || '%'));
    if v_list is not null then msgs := msgs || format('Vỏ %s nhưng BOM dùng %s', s.sheath, v_list); end if;
  end if;

  -- 4. Màu cách điện theo màu từng lõi
  if s.core_colors is not null then
    select string_agg('lõi ' || o, ', ') into v_list from unnest(s.core_colors) with ordinality u(x, o) where x is null or trim(x) = '';
    if v_list is not null then msgs := msgs || format('Chưa khai màu %s', v_list); end if;
    select string_agg(distinct p.color, ', ') into v_list from master.ins_color_plan(p_spec) p where not p.ok;
    if v_list is not null then msgs := msgs || format('Màu lõi %s chưa có vật tư màu %s trong bảng màu', v_list, s.insulation); end if;
    if exists (select 1 from master.ins_color_plan(p_spec)) and not exists (select 1 from master.ins_color_plan(p_spec) where not ok) then
      select sum(l.qty_per_basis) filter (where m.group_code = 'COMPOUND'), sum(l.qty_per_basis) filter (where m.group_code = 'ADDITIVE')
        into v_comp, v_add
        from master.bom_lines l join master.materials m on m.id = l.material_id
       where l.bom_id = v_bom and l.basis = 'KM' and master.bom_group(m.code, m.group_code, l.operation_code) = 'INS';
      select string_agg(m.name, ', ') into v_list from master.bom_lines l join master.materials m on m.id = l.material_id
       where l.bom_id = v_bom and m.group_code = 'COLOR' and master.bom_group(m.code, m.group_code, l.operation_code) = 'INS'
         and m.code not in (select p.material_code from master.ins_color_plan(p_spec) p where p.material_code is not null);
      if v_list is not null then msgs := msgs || format('BOM có màu không có trên lõi: %s', v_list); end if;
      for pc in select * from master.ins_color_plan(p_spec) where material_code is not null loop
        select sum(l.qty_per_basis) into v_q from master.bom_lines l join master.materials m on m.id = l.material_id
         where l.bom_id = v_bom and m.code = pc.material_code and master.bom_group(m.code, m.group_code, l.operation_code) = 'INS';
        if v_q is null then
          msgs := msgs || format('%s lõi %s chưa có vật tư màu %s trong BOM', pc.n, pc.color, pc.material_code);
        elsif coalesce(v_comp, 0) > 0 and abs(v_q - pc.dose * pc.n * v_comp / s.cores) > greatest(0.0005, v_q * 0.01) then
          msgs := msgs || format('Màu %s (%s lõi) %s kg/km ≠ %s %% × cách điện %s lõi = %s kg/km', pc.color, pc.n, round(v_q, 4),
                                 pc.dose * 100, pc.n, round(pc.dose * pc.n * v_comp / s.cores, 4));
        end if;
      end loop;
    end if;
  end if;

  -- 5. Màu vỏ
  if s.sheath <> 'Không' then
    select * into v_rule from master.pigment_rules where kind = 'SH' and family = s.sheath and color = master.norm_color(s.sheath_color);
    if v_rule.color is null then
      msgs := msgs || format('Màu vỏ "%s" chưa có trong bảng màu vỏ %s', coalesce(s.sheath_color, ''), s.sheath);
    elsif v_rule.material_code is not null and not exists (select 1 from master.bom_lines l join master.materials m on m.id = l.material_id
             where l.bom_id = v_bom and m.code = v_rule.material_code and master.bom_group(m.code, m.group_code, l.operation_code) = 'SH') then
      msgs := msgs || format('Vỏ màu %s cần vật tư %s, BOM chưa có', s.sheath_color, v_rule.material_code);
    end if;
  end if;

  -- 6. Băng AL/PET theo bề rộng
  if coalesce(s.shield, false) and s.alpet_width_mm is not null
     and exists (select 1 from master.bom_lines l join master.materials m on m.id = l.material_id where l.bom_id = v_bom and m.code like 'ALP-%')
     and not exists (select 1 from master.bom_lines l join master.materials m on m.id = l.material_id
                      where l.bom_id = v_bom and m.code = 'ALP-' || round(s.alpet_width_mm)::text) then
    msgs := msgs || format('Băng AL/PET %s mm nhưng BOM dùng loại khác', round(s.alpet_width_mm));
  end if;

  -- 7. Đóng gói, nhãn
  if s.brand is not null and exists (select 1 from master.bom_lines l join master.materials m on m.id = l.material_id
       where l.bom_id = v_bom and m.code like 'LABEL-%' and m.code <> case s.brand when 'HEIZKA' then 'LABEL-H' else 'LABEL-K' end) then
    msgs := msgs || format('Nhãn trong BOM không đúng thương hiệu %s', s.brand);
  end if;
  if s.pack_type = 'Bobin gỗ' and not exists (select 1 from master.bom_lines l join master.materials m on m.id = l.material_id
       where l.bom_id = v_bom and m.code like 'REEL-%') then
    msgs := msgs || 'Đóng gói bobin gỗ nhưng BOM chưa có bobin'::text;
  elsif s.pack_type = 'Cuộn PE' and exists (select 1 from master.bom_lines l join master.materials m on m.id = l.material_id
       where l.bom_id = v_bom and m.code like 'REEL-%') then
    msgs := msgs || 'Đóng gói cuộn PE nhưng BOM có bobin gỗ (thừa)'::text;
  end if;

  -- 8. Dòng không có lượng
  select string_agg(m.code, ', ') into v_list from master.bom_lines l join master.materials m on m.id = l.material_id
   where l.bom_id = v_bom and coalesce(l.qty_per_basis, 0) = 0 and coalesce(l.startup_per_lot, 0) = 0;
  if v_list is not null then msgs := msgs || format('Dòng BOM không có lượng (thừa): %s', v_list); end if;
  return msgs;
end $$;
revoke all on function master.bom_issues(uuid) from public, anon;
grant execute on function master.bom_issues(uuid) to authenticated;

-- Màu từng lõi chưa khai: lấy theo bảng màu lõi chuẩn của file Excel (master.color_rules, CAL-16: PFR, SFR, CTL theo số lõi).
-- CFR, SIF, PVC ghi "Theo sơ đồ lõi hiện hành" (không có bảng chuẩn): để trống, người dùng khai trên thẻ Thông số.
select set_config('bmt.admin_spec_edit', 'on', true);
update master.product_specs s
   set core_colors = cr.core_colors,
       insulation_colors = array_to_string(cr.core_colors, ' + ')
  from master.products p, master.color_rules cr
 where p.id = s.product_id and cr.group_code = p.group_code and cr.cores = s.cores
   and s.core_colors is null and s.status <> 'OBSOLETE';
select set_config('bmt.admin_spec_edit', 'off', true);

-- Áp cho mọi spec còn hiệu lực (CFR-4C-0P75: Nâu + Đen theo lõi, bỏ Xanh dương; dây 2 lõi Trắng + Nâu: lõi trắng silicone tự nhiên)
select set_config('bmt.admin_spec_edit', 'on', true);
create temp table _synced as
select s.id, master.sync_bom(s.id) n from master.product_specs s where s.status <> 'OBSOLETE';
update plan.production_plans pp set mrp_stale = true
 where pp.status in ('DRAFT', 'PENDING_APPROVAL', 'APPROVED') and not pp.mrp_stale
   and exists (select 1 from plan.plan_lines pl join _synced x on x.id = pl.spec_id where pl.plan_id = pp.id and x.n > 0);
drop table _synced;
select set_config('bmt.admin_spec_edit', 'off', true);
