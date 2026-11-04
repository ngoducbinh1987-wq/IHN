-- Anh Bình 04/11/2026: đổi chiều dày vỏ mà khối lượng cáp không đổi.
-- Nguyên nhân: định mức vỏ (spec_results.sheath_kgkm) và OD là số nhập tay (từ Excel), master.calc_spec giữ nguyên,
-- không tính lại theo chiều dày.
-- Sửa app.update_spec_draft (dùng chung cho lưu nháp, Quản trị sửa spec đã phát hành, Tạm tính):
--   * đổi chiều dày vỏ mà không đổi OD → OD = OD cũ + 2 × (chiều dày mới − cũ) (đường kính dưới vỏ giữ nguyên);
--   * đổi chiều dày vỏ hoặc OD mà không tự sửa ô định mức vỏ → định mức vỏ tính lại theo tỷ lệ diện tích vành vỏ
--     t × (OD − t), giữ khối lượng riêng hiệu dụng của chính mã đó (đã gồm phần nhựa lấp khe);
--   * chưa có định mức vỏ cũ → π × t × (OD − t) × khối lượng riêng vật liệu (rhoLS / rhoPF / rhoPV);
--   * người dùng tự sửa ô định mức vỏ (khác số đang lưu) → giữ số người dùng nhập.
-- Sau đó calc_spec cộng lại tổng, sync_bom đưa BOM vỏ về định mức mới.
create or replace function app.update_spec_draft(p_spec uuid, p jsonb)
 returns void
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public'
as $function$
declare v_status text;
  v_t0 numeric; v_od0 numeric; v_kg0 numeric; v_set uuid; v_mat text;
  v_t1 numeric; v_od_in numeric; v_kg_in numeric; v_od1 numeric; v_kg1 numeric; v_rho numeric;
begin
  if not (core.has_perm('spec', 'edit') or core.has_perm('spec', 'create')) then raise exception 'Không có quyền sửa spec'; end if;
  select status, sheath_thickness_mm into v_status, v_t0 from master.product_specs where id = p_spec;
  if v_status not in ('DRAFT', 'PILOT_PENDING', 'PILOT') and coalesce(current_setting('bmt.admin_spec_edit', true), '') <> 'on' then
    raise exception 'Spec đang ở trạng thái %: chỉ sửa được spec nháp', v_status;
  end if;
  select od_mm, sheath_kgkm into v_od0, v_kg0 from master.spec_results where spec_id = p_spec;
  update master.product_specs set
    core_code   = coalesce(nullif(p->>'core_code', ''), core_code),
    cores       = coalesce((nullif(p->>'cores', ''))::int, cores),
    pairs       = coalesce((nullif(p->>'pairs', ''))::int, pairs),
    insulation  = coalesce(nullif(p->>'insulation', ''), insulation),
    sheath      = coalesce(nullif(p->>'sheath', ''), sheath),
    ins_thickness_mm    = coalesce((nullif(p->>'ins_thickness_mm', ''))::numeric, ins_thickness_mm),
    sheath_thickness_mm = coalesce((nullif(p->>'sheath_thickness_mm', ''))::numeric, sheath_thickness_mm),
    lay_factor  = coalesce((nullif(p->>'lay_factor', ''))::numeric, lay_factor),
    conductor_mat = coalesce(nullif(p->>'conductor_mat', ''), conductor_mat),
    wire_dia_mm = coalesce((nullif(p->>'wire_dia_mm', ''))::numeric, wire_dia_mm),
    wire_count  = coalesce((nullif(p->>'wire_count', ''))::int, wire_count),
    pitch_mm    = coalesce((nullif(p->>'pitch_mm', ''))::numeric, pitch_mm),
    drain_mat   = coalesce(nullif(p->>'drain_mat', ''), drain_mat),
    brand       = coalesce(nullif(p->>'brand', ''), brand),
    pack_type   = coalesce(nullif(p->>'pack_type', ''), pack_type),
    m_per_pack  = coalesce((nullif(p->>'m_per_pack', ''))::numeric, m_per_pack),
    sheath_color = coalesce(nullif(p->>'sheath_color', ''), sheath_color),
    insulation_colors = coalesce(nullif(p->>'insulation_colors', ''), insulation_colors),
    config_note = coalesce(nullif(p->>'config_note', ''), config_note),
    status = case when coalesce(current_setting('bmt.admin_spec_edit', true), '') = 'on' then status else 'DRAFT' end
  where id = p_spec
  returning sheath_thickness_mm, param_set_id, sheath into v_t1, v_set, v_mat;

  -- OD và định mức vỏ theo chiều dày vỏ
  v_od_in := (nullif(p->>'od_mm', ''))::numeric;
  v_kg_in := (nullif(p->>'sheath_kgkm', ''))::numeric;
  if v_od_in is not null and v_od_in is distinct from v_od0 then
    v_od1 := v_od_in;                                         -- người dùng sửa OD
  elsif v_t1 is distinct from v_t0 and v_od0 > 0 and v_t0 > 0 and v_t1 > 0 then
    v_od1 := v_od0 + 2 * (v_t1 - v_t0);            -- giữ đường kính dưới vỏ
  else
    v_od1 := coalesce(v_od_in, v_od0);
  end if;
  if v_kg_in is not null and v_kg_in is distinct from v_kg0 then
    v_kg1 := v_kg_in;                                         -- người dùng sửa định mức vỏ
  elsif coalesce(v_mat, 'Không') = 'Không' then
    v_kg1 := coalesce(v_kg_in, v_kg0);
  elsif (v_t1 is distinct from v_t0 or v_od1 is distinct from v_od0) and v_t1 > 0 and v_od1 > v_t1 then
    if v_kg0 > 0 and v_t0 > 0 and v_od0 > v_t0 then
      v_kg1 := round(v_kg0 * (v_t1 * (v_od1 - v_t1)) / (v_t0 * (v_od0 - v_t0)), 4);
    else
      v_rho := master.param(v_set, case v_mat when 'LSZH' then 'rhoLS' when 'FR-PVC' then 'rhoPF' else 'rhoPV' end);
      v_kg1 := case when v_rho > 0 then round((pi() * v_t1 * (v_od1 - v_t1) * v_rho)::numeric, 4) else coalesce(v_kg_in, v_kg0) end;
    end if;
  else
    v_kg1 := coalesce(v_kg_in, v_kg0);
  end if;

  update master.spec_results set
    sheath_kgkm = v_kg1,
    pp_kgkm     = coalesce((nullif(p->>'pp_kgkm', ''))::numeric, pp_kgkm),
    pet_kgkm    = coalesce((nullif(p->>'pet_kgkm', ''))::numeric, pet_kgkm),
    alpet_kgkm  = coalesce((nullif(p->>'alpet_kgkm', ''))::numeric, alpet_kgkm),
    drain_kgkm  = coalesce((nullif(p->>'drain_kgkm', ''))::numeric, drain_kgkm),
    od_mm       = v_od1
  where spec_id = p_spec;
  if p ? 'description' and coalesce(trim(p->>'description'), '') <> '' then
    update master.products set description = trim(p->>'description')
    where id = (select product_id from master.product_specs where id = p_spec);
  end if;
  perform master.set_spec_layers(p_spec, p);
  perform master.calc_spec(p_spec);
  perform master.sync_bom(p_spec);
end $function$;
revoke execute on function app.update_spec_draft(uuid, jsonb) from public, anon;
grant execute on function app.update_spec_draft(uuid, jsonb) to authenticated;
