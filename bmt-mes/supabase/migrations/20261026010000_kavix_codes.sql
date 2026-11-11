-- Anh Bình 11/11/2026: mã + mô tả sản phẩm KAVIX đã chốt (file "Kavix - Marketing & Sales Plan 15/11 Ra mắt sản phẩm").
-- Công thức mã: DÒNG SẢN PHẨM + KV + TIẾT DIỆN + S/U (có/không chống nhiễu; dây dân dụng ghi X) + SỐ LÕI + VỎ (LZ/PVC).
-- Anh chốt khi hỏi lại:
--   * CFR-2C (silicone, vỏ LSZH xanh, không chống nhiễu) = dây dân dụng HOMESAFE (HOME-KV…X2LZ);
--     cáp tín hiệu F120 không chống nhiễu (F120-KV…U2LZ) là mã mới;
--   * "2mm" trong file là 2,5 mm² → mã F120-KV25S2LZ / F120-KV25U2LZ;
--   * mọi mã KAVIX khác đặt lại theo công thức (PFR vỏ FR-PVC, dây đơn PVC/silicone: chờ anh chốt tiền tố dòng sản phẩm);
--   * cáp điều khiển đuôi PVC (CTRL-KVAWG20S2PVC), không phải PE.
-- Đổi mã (48): SFR-nP-x → F120-KVxS(2n)LZ; CFR-nC-x → HOME-KVxXnLZ; CTL-nP-Ay → CTRL-KVAWGyS(2n)PVC.
-- Mã mới (7, spec Nháp chép từ mã cùng kết cấu, TP KT/QA kiểm rồi gửi duyệt phát hành):
--   F120-KV075U2LZ, F120-KV10U2LZ, F120-KV15U2LZ, F120-KV25U2LZ (chép HOME-KV…X2LZ, vỏ cam RAL 2004),
--   HOME-KV40X2LZ, HOME-KV60X2LZ (chép kết cấu PFR-2C-4 / PFR-2C-6, vỏ LSZH xanh RAL 6037),
--   CTRL-KVAWG22S2PVC (chép CTRL-KVAWG20S2PVC, mã lõi mới A22: ruột 11 × 0,20 TC ước tính, chưa có giới hạn Rdc).
-- Mô tả đã chốt lưu ở cột mới master.products.sales_name ("Mô tả sản phẩm"); cột description vẫn là quy cách MES tự đặt.
-- Màu vỏ LSZH theo dòng sản phẩm: F120 (chống nhiễu và không) cam RAL 2004, HOME xanh RAL 6037
--   (master.brand_sheath_colors thêm cột code_prefix; quy tắc theo dòng ưu tiên hơn quy tắc theo chống nhiễu).

-- 1. Mô tả sản phẩm
alter table master.products add column if not exists sales_name text;
comment on column master.products.sales_name is 'Mô tả sản phẩm (tên thương mại đã chốt)';
create or replace view app.v_products with (security_invoker = true) as
 SELECT p.id, p.code, p.group_code, g.name AS group_name, p.description, p.default_brand, p.default_pack, p.default_m_per_pack,
    s.id AS spec_id, s.version, s.status AS spec_status, s.core_code, s.cores, s.insulation, s.sheath, s.brand,
    r.metal_kgkm, r.ins_kgkm, r.total_kgkm, r.od_mm, r.rdc_calc, r.rdc_limit, r.pilot_rdc, r.pilot_kgkm, r.tech_check,
    ((r.rdc_limit IS NOT NULL) AND (r.rdc_calc > r.rdc_limit)) AS rdc_over,
    ( SELECT ar.status FROM wf.approval_requests ar WHERE (ar.doc_id = s.id) ORDER BY ar.submitted_at DESC LIMIT 1) AS last_request_status,
    p.sales_name
   FROM master.products p
     JOIN master.product_groups g ON g.code = p.group_code
     LEFT JOIN master.product_specs s ON s.id = p.current_spec_id
     LEFT JOIN master.spec_results r ON r.spec_id = s.id;
grant select on app.v_products to authenticated;

update master.product_groups set name = 'Cáp tín hiệu F120 chống nhiễu' where code = 'SFR';
update master.product_groups set name = 'Dây dân dụng HOMESAFE, tín hiệu F120 không chống nhiễu' where code = 'CFR';
update master.product_groups set name = 'Cáp điều khiển CTRL (AWG, chống nhiễu)' where code = 'CTL';

-- 2. Màu vỏ LSZH theo dòng sản phẩm
alter table master.brand_sheath_colors add column if not exists code_prefix text;
comment on column master.brand_sheath_colors.code_prefix is 'Áp cho mã sản phẩm bắt đầu bằng chuỗi này (null = mọi mã); quy tắc có tiền tố ưu tiên';
drop index if exists master.brand_sheath_colors_key;
create unique index if not exists brand_sheath_colors_key on master.brand_sheath_colors (brand, family, shield, code_prefix) nulls not distinct;
insert into master.brand_sheath_colors (brand, family, shield, code_prefix, color, note) values
  ('KAVIX', 'LSZH', null, 'F120-', 'RAL 2004', 'Cáp tín hiệu F120 (chống nhiễu và không): LSZH cam (anh Bình 11/11/2026)'),
  ('KAVIX', 'LSZH', null, 'HOME-', 'RAL 6037', 'Dây dân dụng HOMESAFE: LSZH xanh (anh Bình 11/11/2026)')
on conflict do nothing;

do $$
declare d text; i int; j int;
  a1 text := 'select string_agg(b.color, '', '') into v_list from master.brand_sheath_colors b';
  a2 text := 'coalesce(master.norm_color(s.sheath_color), '''');';
begin
  d := replace(pg_get_functiondef('master.bom_issues(uuid)'::regprocedure), E'\r', '');
  i := position(a1 in d);
  if i = 0 or position(a1 in substr(d, i + 1)) > 0 then raise exception 'master.bom_issues: không thấy đúng đoạn quy tắc màu vỏ'; end if;
  j := position(a2 in substr(d, i));
  if j = 0 then raise exception 'master.bom_issues: không thấy cuối đoạn quy tắc màu vỏ'; end if;
  d := substr(d, 1, i - 1) || $v$select b.color into v_list from master.brand_sheath_colors b
     where b.brand = s.brand and b.family = s.sheath and (b.shield is null or b.shield = coalesce(s.shield, false))
       and (b.code_prefix is null or (select p.code from master.products p where p.id = s.product_id) like b.code_prefix || '%')
     order by (b.code_prefix is not null) desc, (b.shield is not null) desc limit 1;
    if master.norm_color(v_list) = coalesce(master.norm_color(s.sheath_color), '') then v_list := null; end if;$v$
       || substr(d, i + j - 1 + length(a2));
  execute d;
end $$;

-- 3. Mã lõi AWG22 (chưa có giới hạn Rdc: TP KT/QA nhập)
insert into master.core_types (set_id, code, nominal_mm2, wire_count, wire_dia_mm, fill_factor, silicone_mm, sheath_mm, rdc_limit, hdpe_mm,
                               pvc_single_mm, pitch_override_mm, pitch_mm, tc020_wires, tc024_wires, drain_wires, drain_pitch_mm, rdc_limit_tc, rdc_source)
select set_id, 'A22', 0.3255, 11, 0.2, fill_factor, silicone_mm, sheath_mm, null, hdpe_mm,
       pvc_single_mm, pitch_override_mm, pitch_mm, tc020_wires, tc024_wires, drain_wires, drain_pitch_mm, null,
       'AWG22 (0,3255 mm²): chưa nhập giới hạn Rdc – TP KT/QA nhập theo IEC TR 62602'
  from master.core_types c where c.code = 'A20'
   and not exists (select 1 from master.core_types x where x.set_id = c.set_id and x.code = 'A22');

-- 4. Đổi mã + mô tả, mã mới
create or replace function pg_temp.sz(p text) returns text language sql immutable as $$
  select case p when '0P75' then '075' when '1' then '10' when '1P5' then '15' when '2P5' then '25' when '4' then '40' when '6' then '60' end
$$;
create or replace function pg_temp.szt(p text) returns text language sql immutable as $$
  select case p when '0P75' then '0.75' when '1' then '1' when '1P5' then '1.5' when '2P5' then '2.5' when '4' then '4' when '6' then '6' end
$$;

do $$
declare v_admin uuid; r record; t record; m text[]; v_new text; v_n int; v_total int := 0; v_cnt int := 0;
  src master.product_specs; sp master.products; tr master.spec_results; s master.product_specs; v_product uuid; v_spec uuid; v_bom uuid;
  r0 master.spec_results; r1 master.spec_results; v_od numeric; v_t numeric; v_new_codes text[] := '{}';
begin
  select ur.user_id into v_admin from core.user_roles ur join core.profiles p on p.id = ur.user_id
   where ur.role_code = 'ADMIN' and p.status = 'ACTIVE' order by p.created_at limit 1;
  if v_admin is not null then perform set_config('request.jwt.claim.sub', v_admin::text, true); end if;

  -- 4a. Đổi mã theo công thức
  for r in select p.id, p.code from master.products p where p.code ~ '^(SFR-[0-9]P|CFR-[0-9]C|CTL-[0-9]P)-' order by p.code loop
    if r.code ~ '^SFR-' then
      m := regexp_match(r.code, '^SFR-([0-9])P-([0-9P]+)$');
      v_new := 'F120-KV' || pg_temp.sz(m[2]) || 'S' || (2 * m[1]::int) || 'LZ';
      update master.products set sales_name = 'Cáp tín hiệu KAVIX F120 ' || (2 * m[1]::int) || ' lõi x ' || pg_temp.szt(m[2])
             || 'mm, có chống nhiễu (S), vỏ LSZH' where id = r.id;
    elsif r.code ~ '^CFR-' then
      m := regexp_match(r.code, '^CFR-([0-9])C-([0-9P]+)$');
      v_new := 'HOME-KV' || pg_temp.sz(m[2]) || 'X' || m[1] || 'LZ';
      update master.products set sales_name = 'Dây điện dân dụng KAVIX HOMESAFE ' || m[1] || ' lõi x ' || pg_temp.szt(m[2]) || 'mm, LSZH' where id = r.id;
    else
      m := regexp_match(r.code, '^CTL-([0-9])P-A([0-9]+)$');
      v_new := 'CTRL-KVAWG' || m[2] || 'S' || (2 * m[1]::int) || 'PVC';
      update master.products set sales_name = 'Cáp điều khiển CTRL ' || (2 * m[1]::int) || ' lõi AWG' || m[2] || ', có chống nhiễu (S), Vỏ PVC' where id = r.id;
    end if;
    if m is null or v_new is null or v_new !~ '^[A-Z0-9][A-Z0-9.-]*$' then raise exception 'Không đặt được mã mới cho %', r.code; end if;
    if exists (select 1 from master.products where code = v_new) then raise exception 'Mã % đã có', v_new; end if;

    update master.products set code = v_new where id = r.id;
    for t in select c.table_schema, c.table_name from information_schema.columns c
               join information_schema.tables x on x.table_schema = c.table_schema and x.table_name = c.table_name and x.table_type = 'BASE TABLE'
              where c.column_name = 'product_code' and c.table_schema in ('plan', 'mfg', 'inv', 'sales', 'qa', 'master', 'purchase', 'cost') loop
      execute format('update %I.%I set product_code = $1 where product_code = $2', t.table_schema, t.table_name) using v_new, r.code;
      get diagnostics v_n = row_count; v_total := v_total + v_n;
    end loop;
    update wf.approval_requests
       set doc_no = regexp_replace(doc_no, '(^|[^A-Z0-9.-])' || r.code || '($|[^A-Z0-9.-])', '\1' || v_new || '\2', 'g'),
           summary = regexp_replace(coalesce(summary, ''), '(^|[^A-Z0-9.-])' || r.code || '($|[^A-Z0-9.-])', '\1' || v_new || '\2', 'g')
     where doc_id in (select id from master.product_specs where product_id = r.id);
    if v_admin is not null then
      perform app.admin_log('master.products', r.id::text, 'ADMIN_RENAME', jsonb_build_object('code', r.code),
              jsonb_build_object('code', v_new, 'doc_no', r.code || ' → ' || v_new, 'doc_type', 'Đổi mã sản phẩm',
                                 'reason', 'Mã sản phẩm KAVIX đã chốt (Marketing & Sales Plan 15/11), anh Bình 11/11/2026'));
    end if;
    v_cnt := v_cnt + 1;
  end loop;

  -- 4b. Mã mới (spec Nháp)
  perform set_config('bmt.admin_spec_edit', 'on', true);
  for t in select * from (values
      ('F120-KV075U2LZ', 'HOME-KV075X2LZ', null::text, 'RAL 2004', 'Cáp tín hiệu KAVIX F120 2 lõi x 0.75mm, không chống nhiễu (U), vỏ LSZH'),
      ('F120-KV10U2LZ',  'HOME-KV10X2LZ',  null, 'RAL 2004', 'Cáp tín hiệu KAVIX F120 2 lõi x 1mm, không chống nhiễu (U), vỏ LSZH'),
      ('F120-KV15U2LZ',  'HOME-KV15X2LZ',  null, 'RAL 2004', 'Cáp tín hiệu KAVIX F120 2 lõi x 1.5mm, không chống nhiễu (U), vỏ LSZH'),
      ('F120-KV25U2LZ',  'HOME-KV25X2LZ',  null, 'RAL 2004', 'Cáp tín hiệu KAVIX F120 2 lõi x 2.5mm, không chống nhiễu (U), vỏ LSZH'),
      ('HOME-KV40X2LZ',  'PFR-2C-4',       null, 'RAL 6037', 'Dây điện dân dụng KAVIX HOMESAFE 2 lõi x 4mm, LSZH'),
      ('HOME-KV60X2LZ',  'PFR-2C-6',       null, 'RAL 6037', 'Dây điện dân dụng KAVIX HOMESAFE 2 lõi x 6mm, LSZH'),
      ('CTRL-KVAWG22S2PVC', 'CTRL-KVAWG20S2PVC', 'A22', null, 'Cáp điều khiển CTRL 2 lõi AWG22, có chống nhiễu (S), Vỏ PVC')
    ) x(code, tpl, core, color, sales) loop
    continue when exists (select 1 from master.products where code = t.code);
    select ps.* into src from master.product_specs ps join master.products p on p.current_spec_id = ps.id where p.code = t.tpl;
    if src.id is null then raise notice 'Không có mã mẫu %: bỏ qua %', t.tpl, t.code; continue; end if;
    select * into sp from master.products where id = src.product_id;
    select * into tr from master.spec_results where spec_id = src.id;

    insert into master.products (code, group_code, description, default_brand, default_pack, default_m_per_pack, sales_name)
    values (t.code, case when t.code like 'CTRL-%' then 'CTL' else 'CFR' end, t.code, 'KAVIX', sp.default_pack, sp.default_m_per_pack, t.sales)
    returning id into v_product;

    s := src;
    s.id := gen_random_uuid(); s.product_id := v_product; s.version := 1; s.status := 'DRAFT'; s.change_level := 'NEW';
    s.released_at := null; s.released_by := null; s.rdc_deviation_note := null;
    s.created_at := now(); s.created_by := v_admin; s.updated_at := now(); s.updated_by := null;
    s.brand := 'KAVIX';
    if t.color is not null then s.sheath := 'LSZH'; s.sheath_color := t.color; end if;
    if t.code like 'HOME-%' then s.pairs := 1; end if;
    if t.core is not null then s.core_code := t.core; end if;
    s.config_note := 'Mã mới theo bảng mã KAVIX 15/11 – tạo từ mẫu ' || t.tpl
      || case when t.code like 'HOME-%' then ' (kết cấu PFR, đổi vỏ FR-PVC → LSZH xanh)'
              when t.core = 'A22' then ' (ruột AWG22 11 × 0,20 TC ước tính, OD và vỏ quy đổi theo đường kính lõi)'
              else ' (cùng kết cấu dây HOMESAFE, vỏ LSZH cam)' end
      || '. TP KT/QA kiểm thông số trước khi gửi duyệt phát hành.';
    insert into master.product_specs select s.*;
    v_spec := s.id;
    update master.products set current_spec_id = v_spec where id = v_product;

    insert into master.spec_results select (jsonb_populate_record(null::master.spec_results, to_jsonb(tr) || jsonb_build_object('spec_id', v_spec))).*;
    insert into master.bom_headers (spec_id, status, note) values (v_spec, 'DRAFT', 'Sao chép BOM từ ' || t.tpl || ' (bảng mã KAVIX 15/11)')
    returning id into v_bom;
    insert into master.bom_lines (bom_id, material_id, basis, qty_per_basis, loss_rate, startup_per_lot, operation_code, note)
    select v_bom, l.material_id, l.basis, l.qty_per_basis, l.loss_rate, l.startup_per_lot, l.operation_code, l.note
      from master.bom_lines l join master.bom_headers bh on bh.id = l.bom_id where bh.spec_id = src.id;

    if t.core = 'A22' then
      r0 := tr;
      perform master.set_spec_layers(v_spec, jsonb_build_object('wire_mix', '[{"n":11,"d":0.2}]'::jsonb));
      r1 := master.calc_spec(v_spec);
      -- OD giảm theo đường kính lõi (cặp xoắn: 2 lõi), vỏ giữ chiều dày, khối lượng vỏ theo t·(OD − t)
      v_t := s.sheath_thickness_mm;
      v_od := round(r0.od_mm - 2 * (r0.core_dia_mm - r1.core_dia_mm), 3);
      update master.spec_results set od_mm = v_od,
             cable_bundle_mm = round(r0.cable_bundle_mm - 2 * (r0.core_dia_mm - r1.core_dia_mm), 4),
             sheath_kgkm = case when coalesce(v_t, 0) > 0 and r0.od_mm > v_t then round(r0.sheath_kgkm * (v_od - v_t) / (r0.od_mm - v_t), 4) else r0.sheath_kgkm end
       where spec_id = v_spec;
    end if;
    perform master.calc_spec(v_spec);
    perform master.sync_bom(v_spec);
    update master.products set description = master.spec_name(v_spec) where id = v_product;
    v_new_codes := v_new_codes || t.code;
  end loop;
  perform set_config('bmt.admin_spec_edit', 'off', true);

  if v_cnt > 0 or cardinality(v_new_codes) > 0 then
    perform wf.notify_role(x, 'Mã sản phẩm KAVIX đã chốt: đổi ' || v_cnt || ' mã, thêm ' || cardinality(v_new_codes) || ' mã',
      'SFR → F120-KV…S…LZ, CFR → HOME-KV…X…LZ, CTL → CTRL-KVAWG…S…PVC. Mã mới (spec Nháp, TP KT/QA kiểm): '
      || coalesce(array_to_string(v_new_codes, ', '), ''), '/san-pham?th=KAVIX')
      from unnest(array['SX_TP', 'SX_KH', 'MUA_TP', 'KT_TP']) x;
  end if;
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
