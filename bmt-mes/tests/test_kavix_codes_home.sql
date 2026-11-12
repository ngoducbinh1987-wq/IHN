-- Kiểm thử migration 20261026010100: mã KAVIX chỉ 3 tiền tố F120/HOME/CTRL, hậu tố LZ/PC/FP/SI, màu vỏ theo tiền tố.
-- Chạy được bằng psql hoặc Supabase (net.http_get + DO). Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_msg; end if;
  insert into r(msg) values (p_msg);
end $$;
set client_min_messages = notice;

create temp view k as
select p.id, p.code, p.group_code, p.sales_name, s.id spec_id, s.cores, s.insulation, s.sheath, s.sheath_color
  from master.products p join master.product_specs s on s.id = p.current_spec_id where p.default_brand = 'KAVIX';

select pg_temp.ok(not exists (select 1 from k where code !~ '^(F120|HOME|CTRL)-KV'), 'Mọi mã KAVIX chỉ dùng tiền tố F120, HOME, CTRL');
select pg_temp.ok(not exists (select 1 from k where code !~ '(LZ|PC|FP|SI)$'), 'Mọi mã KAVIX kết thúc bằng hậu tố LZ, PC, FP hoặc SI');
select pg_temp.ok(not exists (select 1 from k where
      (right(code, 2) = 'LZ' and sheath <> 'LSZH') or (right(code, 2) = 'FP' and sheath <> 'FR-PVC')
   or (right(code, 2) = 'PC' and not (sheath = 'PVC' or (sheath = 'Không' and insulation = 'PVC')))
   or (right(code, 2) = 'SI' and not (sheath = 'Không' and insulation = 'SIL'))),
  'Hậu tố đúng vật liệu ngoài cùng (LZ LSZH, FP FR-PVC, PC PVC, SI silicone không vỏ)');
select pg_temp.ok((select count(*) from k where code ~ '^HOME-KV[0-9]+X[234]FP$' and group_code = 'PFR') = 18
   and (select count(*) from k where code ~ '^HOME-KV[0-9]+X1SI$' and group_code = 'SIF') = 6
   and (select count(*) from k where code ~ '^HOME-KV[0-9]+X1PC$' and group_code = 'PVC') = 6,
  'PFR → HOME…FP (18), SIF-1C → HOME…X1SI (6), PVC-1C → HOME…X1PC (6)');
select pg_temp.ok(exists (select 1 from k where code = 'HOME-KV15X2FP' and cores = 2)
   and exists (select 1 from k where code = 'HOME-KV075X4FP' and cores = 4)
   and exists (select 1 from k where code = 'HOME-KV60X1SI') and exists (select 1 from k where code = 'HOME-KV10X1PC'),
  'Ví dụ: PFR-2C-1P5 → HOME-KV15X2FP, PFR-4C-0P75 → HOME-KV075X4FP, SIF-1C-6 → HOME-KV60X1SI, PVC-1C-1 → HOME-KV10X1PC');
select pg_temp.ok(not exists (select 1 from k where code like 'CTRL-%' and code !~ '^CTRL-KVAWG[0-9]+S[0-9]+PC$'), 'CTRL đổi hậu tố PVC → PC');
select pg_temp.ok((select sales_name = 'Dây điện dân dụng KAVIX HOMESAFE 2 lõi x 1.5mm, FR-PVC' from k where code = 'HOME-KV15X2FP')
   and (select sales_name = 'Dây điện dân dụng KAVIX HOMESAFE 1 lõi x 0.75mm, Silicone' from k where code = 'HOME-KV075X1SI')
   and (select sales_name = 'Dây điện dân dụng KAVIX HOMESAFE 1 lõi x 2.5mm, PVC' from k where code = 'HOME-KV25X1PC')
   and not exists (select 1 from k where coalesce(sales_name, '') = ''),
  'Mô tả sản phẩm đủ cho mọi mã KAVIX (HOMESAFE …, FR-PVC / Silicone / PVC)');

-- Màu vỏ theo tiền tố
select pg_temp.ok(not exists (select 1 from k where code like 'F120-%' and master.norm_color(sheath_color) <> 'ral 2004')
   and not exists (select 1 from k where code like 'HOME-%' and sheath <> 'Không' and master.norm_color(sheath_color) <> 'ral 6037')
   and not exists (select 1 from k where code like 'CTRL-%' and master.norm_color(sheath_color) <> 'xám'),
  'Màu vỏ theo tiền tố: F120 RAL 2004, HOME RAL 6037, CTRL xám');
select pg_temp.ok(not exists (select 1 from k, unnest(master.bom_issues(k.spec_id)) x where x ilike '%vỏ%'),
  'Đối chiếu BOM: không mã KAVIX nào lỗi màu vỏ');
select set_config('bmt.admin_spec_edit', 'on', true);
update master.product_specs set sheath_color = 'RAL 2004' where id = (select spec_id from k where code = 'HOME-KV15X2FP');
select pg_temp.ok(exists (select 1 from unnest(master.bom_issues((select spec_id from k where code = 'HOME-KV15X2FP'))) x
                          where x like 'Vỏ FR-PVC thương hiệu KAVIX% phải màu RAL 6037%'),
  'HOME vỏ FR-PVC đổi RAL 2004: báo phải RAL 6037');
update master.product_specs set sheath_color = 'RAL 2004' where id = (select spec_id from k where code = 'CTRL-KVAWG20S2PC');
select pg_temp.ok(exists (select 1 from unnest(master.bom_issues((select spec_id from k where code = 'CTRL-KVAWG20S2PC'))) x
                          where x like 'Vỏ PVC thương hiệu KAVIX% phải màu Xám%'),
  'CTRL vỏ PVC đổi RAL 2004: báo phải Xám');
select pg_temp.ok(not exists (select 1 from master.product_specs s join master.products p on p.id = s.product_id, unnest(master.bom_issues(s.id)) x
                               where p.default_brand = 'HEIZKA' and s.status <> 'OBSOLETE' and x ilike '%thương hiệu%'),
  'HEIZKA không bị quy tắc màu theo tiền tố KAVIX');
select pg_temp.ok(not exists (select 1 from master.products where code ~ '^(PFR|SIF|PVC)-[0-9]C-' or code ~ '^CTRL-.*PVC$'), 'Không còn mã cũ');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
