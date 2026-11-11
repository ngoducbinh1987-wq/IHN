-- Kiểm thử migration 20261026009800 + 9900: LSZH 2 màu pha sẵn: RAL 2004 (LSZH-O) cho HEIZKA và KAVIX chống nhiễu,
-- RAL 6037 (LSZH-G) cho KAVIX không chống nhiễu (cáp điện dân dụng).
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

create temp view v as
select s.id, p.code, s.brand, (s.brand = 'KAVIX' and p.code like 'HOME-%') green, coalesce(s.shield, false) shield, s.sheath_color, r.sheath_kgkm,
       (select string_agg(m.code, ',' order by m.code) from master.bom_lines l join master.bom_headers h on h.id = l.bom_id join master.materials m on m.id = l.material_id
         where h.spec_id = s.id and master.bom_group(m.code, m.group_code, l.operation_code) = 'SH') sh_codes,
       (select coalesce(sum(l.qty_per_basis), 0) from master.bom_lines l join master.bom_headers h on h.id = l.bom_id join master.materials m on m.id = l.material_id
         where h.spec_id = s.id and l.basis = 'KM' and master.bom_group(m.code, m.group_code, l.operation_code) = 'SH') sh_qty
  from master.product_specs s join master.products p on p.id = s.product_id join master.spec_results r on r.spec_id = s.id
 where s.status <> 'OBSOLETE' and s.sheath = 'LSZH' and r.sheath_kgkm > 0;

select pg_temp.ok((select count(*) = 1 from master.materials where code = 'LSZH-O' and name like 'LSZH vỏ cam RAL 2004%')
   and (select count(*) = 1 from master.materials where code = 'LSZH-G' and name like 'LSZH vỏ xanh RAL 6037%' and group_code = 'COMPOUND')
   and not exists (select 1 from master.materials where code = 'LSZH-S'),
  'Vật tư: LSZH-O cam RAL 2004, LSZH-G xanh RAL 6037 (LSZH-S đổi mã LSZH-O)');
select pg_temp.ok(not exists (select 1 from master.materials where code in ('LS-O', 'LS-G') and (active or safety_stock <> 0)),
  'Hạt màu LS-O, LS-G ngừng dùng, dự phòng 0');
select pg_temp.ok((select compound_code = 'LSZH-O' and material_code is null from master.pigment_rules where kind = 'SH' and family = 'LSZH' and color = 'ral 2004')
   and (select compound_code = 'LSZH-G' and material_code is null from master.pigment_rules where kind = 'SH' and family = 'LSZH' and color = 'ral 6037'),
  'Bảng màu vỏ: LSZH RAL 2004 → LSZH-O, RAL 6037 → LSZH-G, không hạt màu');
select pg_temp.ok(not exists (select 1 from v where master.norm_color(sheath_color) <> case when green then 'ral 6037' else 'ral 2004' end)
   and exists (select 1 from v where brand = 'KAVIX' and shield) and exists (select 1 from v where brand = 'KAVIX' and not shield),
  'Spec vỏ LSZH: HEIZKA, KAVIX F120 (chống nhiễu và không) RAL 2004; KAVIX HOMESAFE RAL 6037');
select pg_temp.ok(not exists (select 1 from v where sh_codes is distinct from case when green then 'LSZH-G' else 'LSZH-O' end),
  'BOM vỏ LSZH: chỉ một hạt vỏ pha sẵn đúng màu (cam LSZH-O / xanh LSZH-G), không hạt màu');
select pg_temp.ok(not exists (select 1 from v where abs(sh_qty - sheath_kgkm) > 0.0005), 'Hạt vỏ = định mức vỏ');
select pg_temp.ok(not exists (select 1 from v, unnest(master.bom_issues(v.id)) x where x like '%vỏ%' or x like '%Vỏ%'),
  'Đối chiếu BOM: không còn lỗi vỏ');

-- Đổi màu một spec KAVIX sang RAL 2004 → BOM đổi LSZH-O, báo sai màu thương hiệu; đổi lại thì hết
select set_config('bmt.admin_spec_edit', 'on', true);
create temp table k as select id from v where green order by code limit 1;
update master.product_specs set sheath_color = 'RAL 2004' where id = (select id from k);
select master.sync_bom((select id from k));
select pg_temp.ok((select sh_codes = 'LSZH-O' and abs(sh_qty - sheath_kgkm) < 0.0005 from v where id = (select id from k)),
  'KAVIX HOMESAFE đổi RAL 2004: BOM đổi sang LSZH-O, đủ định mức vỏ');
select pg_temp.ok(exists (select 1 from unnest(master.bom_issues((select id from k))) x where x like 'Vỏ LSZH thương hiệu KAVIX (cáp không chống nhiễu) phải màu RAL 6037%'),
  'KAVIX HOMESAFE vỏ RAL 2004: báo sai màu');
update master.product_specs set sheath_color = 'RAL 6037' where id = (select id from k);
select master.sync_bom((select id from k));
select pg_temp.ok((select sh_codes = 'LSZH-G' from v where id = (select id from k))
   and not exists (select 1 from unnest(master.bom_issues((select id from k))) x where x like '%Vỏ%'),
  'Đổi lại RAL 6037: LSZH-G, hết báo');
-- KAVIX chống nhiễu đổi RAL 6037 → báo phải RAL 2004
create temp table ks as select id from v where brand = 'KAVIX' and shield order by code limit 1;
select pg_temp.ok(exists (select 1 from v where brand = 'KAVIX' and code like 'F120-%' and not shield and master.norm_color(sheath_color) = 'ral 2004'
                           and sh_codes = 'LSZH-O' and not exists (select 1 from unnest(master.bom_issues(v.id)) x where x like '%Vỏ%')),
  'F120 không chống nhiễu (mã mới): vỏ cam RAL 2004, LSZH-O, không báo lỗi');
update master.product_specs set sheath_color = 'RAL 6037' where id = (select id from ks);
select pg_temp.ok(exists (select 1 from unnest(master.bom_issues((select id from ks))) x where x like 'Vỏ LSZH thương hiệu KAVIX (cáp chống nhiễu) phải màu RAL 2004%'),
  'KAVIX chống nhiễu vỏ RAL 6037: báo phải RAL 2004');
-- BOM còn hạt màu cũ → báo
insert into master.bom_lines (bom_id, material_id, basis, qty_per_basis, operation_code)
select h.id, (select id from master.materials where code = 'LS-G'), 'KM', 0.5, 'CD5' from master.bom_headers h where h.spec_id = (select id from k);
select pg_temp.ok(exists (select 1 from unnest(master.bom_issues((select id from k))) x where x like '%pha màu sẵn: BOM thừa hạt màu vỏ%'),
  'BOM còn hạt màu LS-G: báo thừa');

-- Đơn mua chưa duyệt không còn dòng hạt màu LSZH
select pg_temp.ok(not exists (select 1 from purchase.po_lines l join purchase.purchase_orders po on po.id = l.po_id join master.materials m on m.id = l.material_id
                               where m.code in ('LS-O', 'LS-G') and po.status in ('DRAFT', 'PENDING_APPROVAL')),
  'Đơn mua chưa duyệt: không còn dòng hạt màu LS-O, LS-G');
select pg_temp.ok(has_table_privilege('authenticated', 'master.brand_sheath_colors', 'select')
   and not has_table_privilege('anon', 'master.brand_sheath_colors', 'select'), 'Bảng màu theo thương hiệu: người dùng đọc được, anon không');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
