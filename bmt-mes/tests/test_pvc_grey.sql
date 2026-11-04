-- Kiểm thử migration 20261026009100: PVC vỏ xám pha màu sẵn → BOM không hạt màu vỏ, hạt vỏ = định mức vỏ.
-- Chạy được bằng psql hoặc Supabase MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
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
select s.id, p.code, r.sheath_kgkm,
       (select coalesce(sum(l.qty_per_basis), 0) from master.bom_lines l join master.bom_headers h on h.id = l.bom_id join master.materials m on m.id = l.material_id
         where h.spec_id = s.id and l.basis = 'KM' and m.group_code = 'COMPOUND' and master.bom_group(m.code, m.group_code, l.operation_code) = 'SH') comp,
       (select count(*) from master.bom_lines l join master.bom_headers h on h.id = l.bom_id join master.materials m on m.id = l.material_id
         where h.spec_id = s.id and m.group_code = 'COLOR' and master.bom_group(m.code, m.group_code, l.operation_code) = 'SH') colors
  from master.product_specs s join master.products p on p.id = s.product_id join master.spec_results r on r.spec_id = s.id
 where s.status <> 'OBSOLETE' and s.sheath = 'PVC' and master.norm_color(s.sheath_color) = 'xám' and r.sheath_kgkm > 0;

select pg_temp.ok((select material_code is null from master.pigment_rules where kind = 'SH' and family = 'PVC' and color = 'xám'),
  'Bảng màu vỏ: PVC xám không cần hạt màu (pha sẵn)');
select pg_temp.ok((select name = 'PVC vỏ xám (pha màu sẵn)' from master.materials where code = 'PVC-S'), 'Vật tư PVC-S: PVC vỏ xám pha màu sẵn');
select pg_temp.ok((select count(*) = 0 from v where colors > 0), 'Spec vỏ PVC xám: BOM không còn hạt màu vỏ (PV-GR)');
select pg_temp.ok((select bool_and(abs(comp - sheath_kgkm) < 0.001) from v), 'Hạt PVC vỏ = toàn bộ định mức vỏ');
select pg_temp.ok((select bool_and(coalesce(array_length(master.bom_issues(id), 1), 0) = 0
                     or not exists (select 1 from unnest(master.bom_issues(id)) x where x like '%màu%vỏ%')) from v),
  'Đối chiếu BOM: không báo lỗi màu vỏ');

-- BOM có lại hạt màu → báo thừa; đồng bộ lại thì bỏ
select set_config('bmt.admin_spec_edit', 'on', true);
insert into master.bom_lines (bom_id, material_id, basis, qty_per_basis, operation_code)
select h.id, (select id from master.materials where code = 'PV-GR'), 'KM', 0.5, 'CD5'
  from master.bom_headers h where h.spec_id = (select id from v order by code limit 1);
select pg_temp.ok(exists (select 1 from unnest(master.bom_issues((select id from v order by code limit 1))) x where x like '%pha màu sẵn%'),
  'Còn hạt màu vỏ → đối chiếu BOM báo thừa');
select master.sync_bom((select id from v order by code limit 1));
select pg_temp.ok((select colors = 0 and abs(comp - sheath_kgkm) < 0.001 from v order by code limit 1), 'Đồng bộ BOM: bỏ hạt màu, hạt vỏ = định mức vỏ');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
