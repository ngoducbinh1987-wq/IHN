-- Kiểm thử migration 20261026006700: 8 mã Heizka theo spec TQ. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
begin;
create temp table r (n serial, msg text);
create function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_msg; end if;
  insert into r(msg) values (p_msg);
end $$;
create temp view hz as
select p.code, p.group_code, p.default_brand, p.description, s.status, s.brand, s.core_code, s.conductor_mat, s.wire_mix, s.shield, s.pet_tape,
       s.drain_mat, s.drain_dia_mm, s.drain_wires, s.sheath, s.sheath_color, s.m_per_pack, res.*
  from master.products p join master.product_specs s on s.id = p.current_spec_id join master.spec_results res on res.spec_id = s.id
 where p.code in ('HER15S2LZ','HER18S2LZ','HER16S2LZ','HEW18S2PC','HER15U2LZ','HEW16S2PC','HER10S2LZ','HER25U2LZ');

select pg_temp.ok((select count(*) = 8 and bool_and(default_brand = 'HEIZKA' and brand = 'HEIZKA' and status in ('DRAFT', 'RELEASED')) from hz), '8 mã Heizka, thương hiệu HEIZKA, spec Nháp (từ 04/11/2026 đã phát hành, migration 8400)');
-- Số gốc lúc tạo (migration 6700): chỉ so với bản Nháp; bản đã phát hành anh Bình chỉnh tay thông số từ 04/11/2026
select pg_temp.ok((select coalesce(bool_and(abs(core_dia_mm - v.core) < 0.002 and od_mm = v.od and abs(a_total_mm2 - v.a) < 0.001) filter (where status = 'DRAFT'), true)
                     from hz join (values ('HER15S2LZ', 2.6, 6.8, 1.357), ('HER18S2LZ', 2.2, 5.9, 0.736), ('HER16S2LZ', 2.6, 6.8, 1.227),
                                          ('HEW18S2PC', 2.15, 6.0, 0.785), ('HER15U2LZ', 2.6, 6.7, 1.357), ('HEW16S2PC', 2.5, 6.7, 1.276),
                                          ('HER10S2LZ', 2.1, 5.7, 0.724), ('HER25U2LZ', 3.1, 7.9, 2.217)) v(code, core, od, a) using (code)),
  'Đường kính lõi, OD, tiết diện ruột đúng spec Heizka');
select pg_temp.ok((select bool_and(case when code like 'HEW%' then conductor_mat = 'TC' and drain_mat = 'TCCA' and drain_dia_mm = 0.2 and drain_wires in (7, 12) and sheath = 'PVC' and m_per_pack = 305
                                        when shield then conductor_mat = 'BC' and drain_mat = 'TCCA' and drain_wires = 7 and drain_dia_mm = 0.2 and sheath = 'LSZH' and m_per_pack = 500
                                        else conductor_mat = 'BC' and not pet_tape and drain_wires = 0 and sheath = 'LSZH' end) from hz),
  'Vật liệu ruột, drain (TCCA Ø0,20 – chuẩn 04/11/2026), vỏ, đóng gói theo spec');
select pg_temp.ok((select description from hz where code = 'HER15S2LZ') = '1P×2×1.5 mm² SI/vỏ LSZH, shield AL/PET + drain'
              and (select description from hz where code = 'HER25U2LZ') = '2×2.5 mm² SI/vỏ LSZH, không shield'
              and (select description from hz where code = 'HEW16S2PC') = '1P×2×AWG16 HDPE/vỏ PVC, shield AL/PET + drain', 'Tên theo quy tắc');
select pg_temp.ok(not exists (select 1 from hz, unnest(master.bom_issues(spec_id)) x), 'BOM khớp thông số (đồng CU-025/TC-025, drain TCCA-020, PET, độn, màu vỏ, nhãn)');
select pg_temp.ok((select count(*) = 4 from hz where rdc_calc > rdc_limit)
              and (select bool_and(code in ('HER10S2LZ', 'HER16S2LZ', 'HER18S2LZ', 'HEW18S2PC')) from hz where rdc_calc > rdc_limit),
  'Rdc vượt giới hạn theo tên bán: HER10, HER16, HER18, HEW18');
select pg_temp.ok(not exists (select 1 from hz, unnest(master.check_spec(spec_id)) x where x like 'Drain Không%'), 'Dây Heizka không shield được không có drain');
select pg_temp.ok(not exists (select 1 from master.products p join master.product_specs s on s.id = p.current_spec_id
                               where p.default_brand = 'KAVIX' and p.description is distinct from master.spec_name(s.id)), 'Tên mã Kavix giữ quy tắc');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
rollback;
