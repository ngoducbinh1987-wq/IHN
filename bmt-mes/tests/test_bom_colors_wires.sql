-- Kiểm thử migration 20261026006300: màu cách điện theo màu từng lõi, màu vỏ, sợi đồng theo cỡ.
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create temp table t (k text primary key, v uuid);
grant all on r, t to authenticated;
grant usage on sequence r_n_seq to authenticated;

create function pg_temp.as_user(p_code text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', (select id::text from core.profiles where employee_code = p_code), true),
         set_config('request.jwt.claim.role', 'authenticated', true)
$$;
create function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_msg; end if;
  insert into r(msg) values (p_msg);
end $$;
create function pg_temp.blocked(p_sql text, p_pattern text, p_msg text) returns void language plpgsql as $$
begin
  begin
    execute 'set local role authenticated';
    execute p_sql;
    execute 'reset role';
  exception when others then
    execute 'reset role';
    if sqlerrm ilike '%' || p_pattern || '%' then insert into r(msg) values (p_msg || ' → chặn: ' || sqlerrm); return; end if;
    raise exception 'FAIL: % — lỗi khác mong đợi: %', p_msg, sqlerrm;
  end;
  raise exception 'FAIL: % — lẽ ra phải bị chặn', p_msg;
end $$;
create function pg_temp.as_api(p_sql text) returns void language plpgsql as $$
begin
  execute 'set local role authenticated';
  execute p_sql;
  execute 'reset role';
end $$;
create function pg_temp.v(p_k text) returns uuid language sql as $$ select v from t where k = p_k $$;
grant execute on function pg_temp.v(text) to authenticated;
set client_min_messages = notice;


update core.profiles set status = 'INACTIVE' where status = 'ACTIVE';
with u(code) as (values ('E_ADM'),('E_KTTP')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('E_ADM','ADMIN'),('E_KTTP','KT_TP')) u(code, role) on u.code = p.employee_code;


create function pg_temp.q(p_spec uuid, p_code text) returns numeric language sql as $$
  select sum(l.qty_per_basis) from master.bom_lines l join master.bom_headers h on h.id = l.bom_id join master.materials m on m.id = l.material_id
   where h.spec_id = p_spec and m.code = p_code $$;
create function pg_temp.grp(p_spec uuid, p_grp text, p_group text default null) returns numeric language sql as $$
  select sum(l.qty_per_basis) from master.bom_lines l join master.bom_headers h on h.id = l.bom_id join master.materials m on m.id = l.material_id
   where h.spec_id = p_spec and master.bom_group(m.code, m.group_code, l.operation_code) = p_grp and (p_group is null or m.group_code = p_group) $$;
create function pg_temp.draft(p_code text) returns uuid language plpgsql as $$
declare v uuid; v_rel uuid;
begin
  select s.id into v from master.product_specs s join master.products p on p.id = s.product_id
   where p.code = p_code and s.status in ('DRAFT','PILOT_PENDING','PILOT') order by s.version desc limit 1;
  if v is not null then return v; end if;
  select p.current_spec_id into v_rel from master.products p where p.code = p_code;
  perform set_config('bmt.allow_release', 'on', true);
  update master.product_specs set status = 'RELEASED' where id = v_rel and status <> 'RELEASED';
  perform set_config('bmt.allow_release', 'off', true);
  execute 'set local role authenticated';
  v := master.new_spec_version(v_rel, 'MAJOR');
  execute 'reset role';
  return v;
end $$;

-- (A) Dữ liệu sau migration
select pg_temp.ok(not exists (select 1 from master.product_specs s where s.status <> 'OBSOLETE' and cardinality(master.bom_issues(s.id)) > 0
                               and not exists (select 1 from unnest(master.bom_issues(s.id)) x where x like 'Chưa có vật tư sợi đồng%')),
  'Mọi spec còn hiệu lực: BOM khớp (trừ spec thiếu vật tư sợi đồng theo cỡ)');
select pg_temp.ok((select bool_and(s.core_colors = cr.core_colors or s.core_colors is not null)
                     from master.product_specs s join master.products p on p.id = s.product_id
                     join master.color_rules cr on cr.group_code = p.group_code and cr.cores = s.cores where s.status <> 'OBSOLETE'),
  'PFR, SFR, CTL: màu từng lõi đã điền theo bảng màu lõi chuẩn (Excel CAL-16)');
select pg_temp.ok(not exists (select 1 from master.product_specs s join master.bom_headers h on h.spec_id = s.id join master.bom_lines l on l.bom_id = h.id
                                join master.materials m on m.id = l.material_id
                               where s.status <> 'OBSOLETE' and s.insulation = 'SIL' and m.code = 'SI-W'),
  'Lõi trắng silicone dùng silicone tự nhiên: không còn hạt màu trắng SI-W');

select pg_temp.as_user('E_KTTP');
-- (B) CFR-4C-0P75: lõi Nâu, Trắng, Đen, Trắng → Nâu 1 lõi, Đen 1 lõi, không Xanh dương
insert into t values ('c4', pg_temp.draft('CFR-4C-0P75'));
select pg_temp.as_api($q$select app.update_spec_draft(pg_temp.v('c4'), '{"core_colors":["Nâu","Trắng","Đen","Trắng"]}')$q$);
select pg_temp.ok(pg_temp.q(pg_temp.v('c4'), 'SI-C1') is null and pg_temp.q(pg_temp.v('c4'), 'SI-W') is null,
  'CFR-4C-0P75 Nâu-Trắng-Đen-Trắng: bỏ màu Xanh dương, không pha màu lõi trắng');
select pg_temp.ok(abs(pg_temp.q(pg_temp.v('c4'), 'SI-C0') - 0.01 * pg_temp.q(pg_temp.v('c4'), 'SIL-9710G') / 4) < 0.00001
  and abs(pg_temp.q(pg_temp.v('c4'), 'SI-C2') - 0.01 * pg_temp.q(pg_temp.v('c4'), 'SIL-9710G') / 4) < 0.00001,
  'Màu Nâu, Đen mỗi màu = 1 % silicone của 1 lõi');
select pg_temp.ok(abs(pg_temp.grp(pg_temp.v('c4'), 'INS') - (select ins_kgkm from master.spec_results where spec_id = pg_temp.v('c4'))) < 0.00001
  and abs(pg_temp.q(pg_temp.v('c4'), 'DCBP-50') / pg_temp.q(pg_temp.v('c4'), 'SIL-9710G') - 0.015) < 0.0001,
  'Tổng silicone + DCBP + màu = định mức cách điện; DCBP giữ 1,5 % silicone');
select pg_temp.ok(cardinality(master.bom_issues(pg_temp.v('c4'))) = 0, 'CFR-4C-0P75 sau khi lưu: BOM khớp');
select pg_temp.ok((select abs(l.startup_per_lot - 0.01 * (select l2.startup_per_lot from master.bom_lines l2 join master.materials m2 on m2.id = l2.material_id where l2.bom_id = l.bom_id and m2.code = 'SIL-9710G') / 4) < 0.0001
                     from master.bom_lines l join master.bom_headers h on h.id = l.bom_id join master.materials m on m.id = l.material_id
                    where h.spec_id = pg_temp.v('c4') and m.code = 'SI-C2'),
  'Khởi động/lô của màu = 1 % silicone khởi động × phần lõi');
-- Đổi 6 lõi: 3 Nâu + 3 Xanh dương
select pg_temp.as_api($q$select app.update_spec_draft(pg_temp.v('c4'), '{"cores":"6","pairs":"0","core_colors":["Nâu","Xanh dương","Nâu","Xanh dương","Nâu","Xanh dương"]}')$q$);
select pg_temp.ok(abs(pg_temp.q(pg_temp.v('c4'), 'SI-C0') - 0.01 * 3 * pg_temp.q(pg_temp.v('c4'), 'SIL-9710G') / 6) < 0.00001
  and pg_temp.q(pg_temp.v('c4'), 'SI-C2') is null, '6 lõi 3 Nâu + 3 Xanh dương: Nâu = 1 % × 3/6 silicone, bỏ màu Đen');
-- Thêm tay màu không có trên lõi → báo
select pg_temp.as_api($q$select app.save_bom_line(pg_temp.v('c4'), 'SI-C3', 'KM', 0.05, null, 0, 'CD0')$q$);
select pg_temp.ok(exists (select 1 from unnest(master.bom_issues(pg_temp.v('c4'))) x where x like 'BOM có màu không có trên lõi%Xám%'), 'Thêm tay màu Xám: báo thừa');
select pg_temp.as_api($q$select app.save_bom_line(pg_temp.v('c4'), 'SI-C0', 'KM', 0.5, null, 0, 'CD0')$q$);
select pg_temp.ok(exists (select 1 from unnest(master.bom_issues(pg_temp.v('c4'))) x where x like 'Màu nâu (3 lõi)%≠%'), 'Sửa tay lượng màu Nâu sai: báo lệch');
select pg_temp.as_api($q$select app.update_spec_draft(pg_temp.v('c4'), '{}')$q$);
select pg_temp.ok(cardinality(master.bom_issues(pg_temp.v('c4'))) = 0, 'Lưu lại: MES sửa đúng màu, bỏ màu thừa');
select pg_temp.as_api($q$select app.update_spec_draft(pg_temp.v('c4'), '{"core_colors":["Nâu","","Nâu","Xanh dương","Nâu","Xanh dương"]}')$q$);
select pg_temp.ok(exists (select 1 from unnest(master.bom_issues(pg_temp.v('c4'))) x where x like 'Chưa khai màu lõi 2%'), 'Thiếu màu một lõi: báo chưa khai');

-- (C) Màu vỏ (migration 9800: LSZH pha màu sẵn): RAL 6037 → RAL 2004 đổi hạt vỏ LSZH-G → LSZH-O, không hạt màu;
--     KAVIX phải RAL 6037 → đối chiếu BOM báo sai màu theo thương hiệu
select pg_temp.as_api($q$select app.update_spec_draft(pg_temp.v('c4'), '{"core_colors":["Nâu","Xanh dương","Nâu","Xanh dương","Nâu","Xanh dương"],"sheath_color":"RAL 2004"}')$q$);
select pg_temp.ok(pg_temp.q(pg_temp.v('c4'), 'LS-G') is null and pg_temp.q(pg_temp.v('c4'), 'LS-O') is null and pg_temp.q(pg_temp.v('c4'), 'LSZH-G') is null
  and abs(pg_temp.q(pg_temp.v('c4'), 'LSZH-O') - (select sheath_kgkm from master.spec_results where spec_id = pg_temp.v('c4'))) < 0.00001
  and abs(pg_temp.grp(pg_temp.v('c4'), 'SH') - (select sheath_kgkm from master.spec_results where spec_id = pg_temp.v('c4'))) < 0.00001,
  'Vỏ đổi RAL 2004: hạt vỏ LSZH-G → LSZH-O (pha màu sẵn) = định mức vỏ, không hạt màu');
select pg_temp.ok(exists (select 1 from unnest(master.bom_issues(pg_temp.v('c4'))) x where x like 'Vỏ LSZH thương hiệu KAVIX phải màu RAL 6037%'),
  'KAVIX vỏ LSZH RAL 2004: đối chiếu BOM báo sai màu theo thương hiệu');
select pg_temp.as_api($q$select app.update_spec_draft(pg_temp.v('c4'), '{"sheath_color":"Tím"}')$q$);
select pg_temp.ok(exists (select 1 from unnest(master.bom_issues(pg_temp.v('c4'))) x where x like 'Màu vỏ "Tím" chưa có trong bảng màu vỏ%'), 'Màu vỏ chưa có trong bảng: báo');

-- (D) Sợi đồng theo cỡ
select pg_temp.as_api($q$select app.update_spec_draft(pg_temp.v('c4'), '{"sheath_color":"RAL 6037","wire_mix":[{"n":14,"d":0.24},{"n":3,"d":0.3}]}')$q$);
select pg_temp.ok(exists (select 1 from unnest(master.bom_issues(pg_temp.v('c4'))) x where x like 'Chưa có vật tư sợi đồng trần Ø0,3% (mã CU-030)%'),
  'Ruột trộn sợi Ø0,30 chưa có vật tư CU-030: báo thiếu vật tư');
insert into master.materials (code, name, group_code, uom, loss_rate) values ('CU-030', 'Đồng trần BC Ø0,30', 'CONDUCTOR', 'kg', 0.015);
select pg_temp.as_api($q$select app.update_spec_draft(pg_temp.v('c4'), '{}')$q$);
select pg_temp.ok(abs(pg_temp.q(pg_temp.v('c4'), 'CU-024') - (select metal_kgkm from master.spec_results where spec_id = pg_temp.v('c4')) * 14 * 0.0576 / (14 * 0.0576 + 3 * 0.09)) < 0.00001
  and abs(pg_temp.q(pg_temp.v('c4'), 'CU-030') - (select metal_kgkm from master.spec_results where spec_id = pg_temp.v('c4')) * 3 * 0.09 / (14 * 0.0576 + 3 * 0.09)) < 0.00001
  and cardinality(master.bom_issues(pg_temp.v('c4'))) = 0,
  'Có CU-030: BOM tách 2 dòng đồng theo n·d² (14×0,24 và 3×0,30), khớp');
select pg_temp.as_api($q$select app.update_spec_draft(pg_temp.v('c4'), '{"wire_mix":[{"n":16,"d":0.24}]}')$q$);
select pg_temp.ok(pg_temp.q(pg_temp.v('c4'), 'CU-030') is null, 'Bỏ cỡ sợi Ø0,30: dòng CU-030 bị bỏ');

-- (E) HDPE: CTL 2 cặp Trắng + Đen → HD-W, HD-B mỗi màu 2 % × 2/4 HDPE
insert into t values ('ctl', pg_temp.draft('CTL-2P-A18'));
select pg_temp.as_api($q$select app.update_spec_draft(pg_temp.v('ctl'), '{}')$q$);
select pg_temp.ok(abs(pg_temp.q(pg_temp.v('ctl'), 'HD-W') - 0.02 * 2 * pg_temp.q(pg_temp.v('ctl'), 'HDPE-I') / 4) < 0.00001
  and abs(pg_temp.q(pg_temp.v('ctl'), 'HD-B') - 0.02 * 2 * pg_temp.q(pg_temp.v('ctl'), 'HDPE-I') / 4) < 0.00001
  and cardinality(master.bom_issues(pg_temp.v('ctl'))) = 0, 'CTL Trắng-Đen: HD-W, HD-B mỗi màu 2 % HDPE của 2 lõi, khớp');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
