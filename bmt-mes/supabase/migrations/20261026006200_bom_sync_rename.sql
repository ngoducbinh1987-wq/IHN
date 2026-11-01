-- Anh Bình 01/11/2026:
--  (1) Nút "Đổi mã sản phẩm" (chỉ Quản trị): app.admin_product_rename.
--  (2) BOM phải khớp sản phẩm, không tính sai, không thừa:
--      - master.sync_bom(spec): đưa suất BOM về đúng định mức MES tính (đồng, cách điện + màu + phụ gia, vỏ + màu, độn PP,
--        băng PET, băng AL/PET, drain) theo tỷ lệ các dòng đang có; đổi nhãn theo thương hiệu. Gọi sau mỗi lần lưu thông số.
--      - master.bom_issues(spec): đối chiếu BOM với thông số (số lượng, vật liệu, màu lõi, nhãn, bobin, dòng thừa); đưa vào
--        master.check_spec nên còn lỗi thì không phát hành được.

create or replace function pg_temp.patch(p_name text, p_old text, p_new text, p_mark text) returns void language plpgsql as $$
declare v_oid oid; v_n int; v_def text;
begin
  select count(*), min(p.oid) into v_n, v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname || '.' || p.proname = p_name;
  if v_n <> 1 then raise exception 'Vá %: có % hàm cùng tên', p_name, v_n; end if;
  v_def := pg_get_functiondef(v_oid);
  if position(p_mark in v_def) > 0 then return; end if;   -- đã vá
  if position(p_old in v_def) = 0 then raise exception 'Vá %: không thấy đoạn "%"', p_name, p_old; end if;
  execute replace(v_def, p_old, p_new);
end $$;

-- ---------------------------------------------------------------- Nhóm vật tư BOM ứng với từng định mức MES tính
-- Trả mã nhóm cho một dòng BOM: CU (đồng ruột), INS (cách điện + màu + phụ gia), SH (vỏ + màu), PP, PET, ALP, DR; null = không đối chiếu
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
  end
$$;

create or replace function master.bom_targets(p_spec uuid) returns table (grp text, label text, target numeric)
language sql stable security definer set search_path = pg_catalog, public as $$
  select x.grp, x.label, coalesce(x.target, 0)
    from master.spec_results r,
         lateral (values ('CU', 'Đồng ruột dẫn', r.metal_kgkm), ('INS', 'Cách điện (gồm màu, phụ gia)', r.ins_kgkm),
                         ('SH', 'Vỏ (gồm màu)', r.sheath_kgkm), ('PP', 'Độn PP', r.pp_kgkm), ('PET', 'Băng PET', r.pet_kgkm),
                         ('ALP', 'Băng AL/PET', r.alpet_kgkm), ('DR', 'Drain', r.drain_kgkm)) x(grp, label, target)
   where r.spec_id = p_spec
$$;
revoke all on function master.bom_targets(uuid) from public, anon, authenticated;

-- Đưa suất BOM (/km) của từng nhóm về đúng định mức, giữ tỷ lệ giữa các dòng trong nhóm; đổi nhãn theo thương hiệu.
-- Không thêm/xóa dòng (thiếu/thừa do master.bom_issues báo). Trả số dòng đã đổi.
create or replace function master.sync_bom(p_spec uuid) returns int
language plpgsql security definer set search_path = pg_catalog, public as $$
declare t record; v_sum numeric; v_n int := 0; v_k int; v_bom uuid; v_brand text; v_label uuid; v_other uuid;
begin
  select h.id into v_bom from master.bom_headers h where h.spec_id = p_spec;
  if v_bom is null then return 0; end if;
  for t in select * from master.bom_targets(p_spec) loop
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
  -- Nhãn theo thương hiệu
  select brand into v_brand from master.product_specs where id = p_spec;
  select id into v_label from master.materials where code = case v_brand when 'HEIZKA' then 'LABEL-H' else 'LABEL-K' end;
  select id into v_other from master.materials where code = case v_brand when 'HEIZKA' then 'LABEL-K' else 'LABEL-H' end;
  if v_label is not null and v_other is not null
     and not exists (select 1 from master.bom_lines where bom_id = v_bom and material_id = v_label) then
    update master.bom_lines set material_id = v_label where bom_id = v_bom and material_id = v_other;
    get diagnostics v_k = row_count; v_n := v_n + v_k;
  end if;
  return v_n;
end $$;
revoke all on function master.sync_bom(uuid) from public, anon, authenticated;

-- Màu ghi trên tên vật tư màu (Màu silicone Nâu, Masterbatch HDPE trắng…) → tên màu lõi chuẩn
create or replace function master.color_of(p_name text) returns text
language sql immutable set search_path = pg_catalog as $$
  select case
    when lower(p_name) like '%vàng xanh%' or lower(p_name) like '%vàng-xanh%' then 'vàng-xanh lá'
    when lower(p_name) like '%nâu%' then 'nâu'
    when lower(p_name) like '%xanh dương%' then 'xanh dương'
    when lower(p_name) like '%đen%' then 'đen'
    when lower(p_name) like '%xám%' then 'xám'
    when lower(p_name) like '%trắng%' then 'trắng'
    when lower(p_name) like '%đỏ%' then 'đỏ'
  end
$$;

-- Đối chiếu BOM với thông số spec. Trả danh sách lỗi (rỗng = khớp).
create or replace function master.bom_issues(p_spec uuid) returns text[]
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare s master.product_specs; v_bom uuid; t record; v_sum numeric; v_cnt int; msgs text[] := '{}'; c text; v_list text;
  v_ins_prefix text; v_ins_comp text; v_sh_prefix text; v_sh_comp text; v_cu text;
begin
  select * into s from master.product_specs where id = p_spec;
  select id into v_bom from master.bom_headers where spec_id = p_spec;
  if v_bom is null then return array['Chưa có BOM']; end if;

  -- 1. Số lượng từng nhóm so với định mức MES tính
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

  -- 2. Vật liệu đúng loại
  v_cu := case s.conductor_mat when 'TC' then 'TC-' else 'CU-' end;
  select string_agg(m.code, ', ') into v_list from master.bom_lines l join master.materials m on m.id = l.material_id
   where l.bom_id = v_bom and master.bom_group(m.code, m.group_code, l.operation_code) = 'CU' and m.code not like v_cu || '%';
  if v_list is not null then msgs := msgs || format('Ruột dẫn %s nhưng BOM dùng %s', s.conductor_mat, v_list); end if;

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

  -- 3. Màu lõi: màu trong BOM phải có trên lõi; lõi màu (trừ Trắng tự nhiên) phải có vật tư màu
  if s.core_colors is not null then
    select string_agg(m.name, ', ') into v_list from master.bom_lines l join master.materials m on m.id = l.material_id
     where l.bom_id = v_bom and m.group_code = 'COLOR' and master.bom_group(m.code, m.group_code, l.operation_code) = 'INS'
       and master.color_of(m.name) is not null
       and not exists (select 1 from unnest(s.core_colors) cc where lower(cc) = master.color_of(m.name));
    if v_list is not null then msgs := msgs || format('BOM có màu không có trên lõi: %s', v_list); end if;
    for c in select distinct lower(cc) from unnest(s.core_colors) cc where cc is not null and lower(cc) <> 'trắng' loop
      if not exists (select 1 from master.bom_lines l join master.materials m on m.id = l.material_id
                      where l.bom_id = v_bom and m.group_code = 'COLOR' and master.bom_group(m.code, m.group_code, l.operation_code) = 'INS'
                        and master.color_of(m.name) = c) then
        msgs := msgs || format('Lõi màu %s chưa có vật tư màu cách điện trong BOM', c);
      end if;
    end loop;
  end if;

  -- 4. Đóng gói, nhãn
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

  -- 5. Dòng không có lượng (suất 0, không có lượng khởi động)
  select string_agg(m.code, ', ') into v_list from master.bom_lines l join master.materials m on m.id = l.material_id
   where l.bom_id = v_bom and coalesce(l.qty_per_basis, 0) = 0 and coalesce(l.startup_per_lot, 0) = 0;
  if v_list is not null then msgs := msgs || format('Dòng BOM không có lượng (thừa): %s', v_list); end if;
  return msgs;
end $$;
revoke all on function master.bom_issues(uuid) from public, anon;
grant execute on function master.bom_issues(uuid) to authenticated;

-- check_spec: thêm đối chiếu BOM (còn lỗi thì không phát hành được)
select pg_temp.patch('master.check_spec', 'return msgs;',
  'msgs := msgs || master.bom_issues(p_spec);' || chr(10) || '  return msgs;', 'master.bom_issues');

-- update_spec_draft: lưu thông số xong thì BOM theo định mức mới
select pg_temp.patch('app.update_spec_draft', 'perform master.calc_spec(p_spec);',
  'perform master.calc_spec(p_spec);' || chr(10) || '  perform master.sync_bom(p_spec);', 'master.sync_bom');

-- Đồng bộ BOM của mọi spec còn hiệu lực (dữ liệu thật: CFR-2C-0P75 v1, CFR-2C-1 v1 đã sửa thông số mà BOM chưa theo)
select set_config('bmt.admin_spec_edit', 'on', true);
create temp table _synced as
select s.id, p.code, s.version, master.sync_bom(s.id) n
  from master.product_specs s join master.products p on p.id = s.product_id where s.status <> 'OBSOLETE';
update plan.production_plans pp set mrp_stale = true
 where pp.status in ('DRAFT', 'PENDING_APPROVAL', 'APPROVED') and not pp.mrp_stale
   and exists (select 1 from plan.plan_lines pl join _synced x on x.id = pl.spec_id where pl.plan_id = pp.id and x.n > 0);
drop table _synced;
select set_config('bmt.admin_spec_edit', 'off', true);

-- ---------------------------------------------------------------- (1) Đổi mã sản phẩm
-- Mọi chứng từ nối theo products.id nên tự hiện mã mới; MES sửa thêm các chỗ lưu sẵn chữ mã (cột product_code của bảng
-- nghiệp vụ như lịch máy đã xếp, số hồ sơ duyệt spec "SPEC <mã> v<n>"). Số lô, số phiếu, thông báo, nhật ký cũ giữ nguyên.
create or replace function app.admin_product_rename(p_product uuid, p_new_code text, p_reason text) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_old text; v_new text := upper(trim(coalesce(p_new_code, ''))); r record; v_n int; v_total int := 0;
begin
  if not core.is_admin() then raise exception 'Chỉ Quản trị hệ thống được đổi mã sản phẩm'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Ghi lý do đổi mã'; end if;
  select code into v_old from master.products where id = p_product for update;
  if v_old is null then raise exception 'Không tìm thấy sản phẩm'; end if;
  if v_new = '' then raise exception 'Nhập mã mới'; end if;
  if v_new !~ '^[A-Z0-9][A-Z0-9.-]*$' then raise exception 'Mã sản phẩm chỉ gồm chữ IN HOA, số, dấu chấm, gạch ngang: %', v_new; end if;
  if v_new = v_old then raise exception 'Mã mới trùng mã hiện tại'; end if;
  if exists (select 1 from master.products where code = v_new) then raise exception 'Mã % đã có sản phẩm khác dùng', v_new; end if;

  update master.products set code = v_new where id = p_product;
  -- Cột product_code lưu sẵn chữ mã trong bảng nghiệp vụ (không phải view)
  for r in select c.table_schema, c.table_name from information_schema.columns c
             join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
            where c.column_name = 'product_code' and c.table_schema in ('plan', 'mfg', 'inv', 'sales', 'qa', 'master', 'purchase', 'cost') loop
    execute format('update %I.%I set product_code = $1 where product_code = $2', r.table_schema, r.table_name) using v_new, v_old;
    get diagnostics v_n = row_count; v_total := v_total + v_n;
  end loop;
  -- Số hồ sơ duyệt spec của mã này
  update wf.approval_requests
     set doc_no = regexp_replace(doc_no, '(^|[^A-Z0-9.-])' || replace(v_old, '.', '\.') || '($|[^A-Z0-9.-])', '\1' || v_new || '\2', 'g'),
         summary = regexp_replace(coalesce(summary, ''), '(^|[^A-Z0-9.-])' || replace(v_old, '.', '\.') || '($|[^A-Z0-9.-])', '\1' || v_new || '\2', 'g')
   where doc_id in (select id from master.product_specs where product_id = p_product);
  get diagnostics v_n = row_count; v_total := v_total + v_n;

  perform app.admin_log('master.products', p_product::text, 'ADMIN_RENAME', jsonb_build_object('code', v_old),
          jsonb_build_object('code', v_new, 'doc_no', v_old || ' → ' || v_new, 'reason', trim(p_reason), 'doc_type', 'Đổi mã sản phẩm', 'rows', v_total));
  perform wf.notify_role(x, 'Đổi mã sản phẩm ' || v_old || ' → ' || v_new,
                         'Quản trị hệ thống đổi mã. Lý do: ' || trim(p_reason), '/san-pham/' || v_new)
    from unnest(array['SX_TP', 'SX_KH', 'MUA_TP', 'KT_TP']) x;
  return v_new;
end $$;
revoke all on function app.admin_product_rename(uuid, text, text) from public, anon;
grant execute on function app.admin_product_rename(uuid, text, text) to authenticated;

select pg_temp.patch('app.admin_overrides', $o$'ADMIN_PO', 'ADMIN_SPEC')$o$, $n$'ADMIN_PO', 'ADMIN_SPEC', 'ADMIN_RENAME')$n$, 'ADMIN_RENAME');

-- Tạm tính trả thêm BOM sau khi đồng bộ (để xem định mức vật tư mới trước khi lưu)
create or replace function app.spec_preview(p_spec uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_status text; v_out jsonb;
begin
  select status into v_status from master.product_specs where id = p_spec;
  if not found then raise exception 'Không tìm thấy spec'; end if;
  if not (core.is_admin()
          or ((core.has_perm('spec', 'edit') or core.has_perm('spec', 'create')) and v_status in ('DRAFT', 'PILOT_PENDING', 'PILOT'))) then
    raise exception 'Không có quyền tạm tính spec này';
  end if;
  begin
    perform set_config('bmt.admin_spec_edit', 'on', true);
    perform app.update_spec_draft(p_spec, coalesce(p, '{}'::jsonb));
    select jsonb_build_object('spec', to_jsonb(s), 'res', to_jsonb(r), 'issues', to_jsonb(master.check_spec(p_spec)),
             'bom', (select coalesce(jsonb_agg(to_jsonb(b) order by b.operation_code, b.material_code), '[]') from app.v_bom_lines b where b.spec_id = p_spec))
      into v_out
      from master.product_specs s left join master.spec_results r on r.spec_id = s.id where s.id = p_spec;
    raise exception 'BMT_PREVIEW_ROLLBACK';
  exception when others then
    if sqlerrm <> 'BMT_PREVIEW_ROLLBACK' then raise; end if;
  end;
  return v_out;
end $$;
revoke all on function app.spec_preview(uuid, jsonb) from public, anon;
grant execute on function app.spec_preview(uuid, jsonb) to authenticated;
