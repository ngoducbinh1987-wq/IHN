-- Kiểm thử migration 20261026006100: màu lõi dây 2 lõi silicone, tạm tính thông số spec (không lưu).
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


-- (1) Màu lõi dây 2 lõi silicone
select pg_temp.ok(not exists (select 1 from master.product_specs where cores = 2 and insulation = 'SIL' and status <> 'OBSOLETE'
                               and core_colors is distinct from array['Trắng','Nâu']),
  'Mọi spec 2 lõi silicone còn hiệu lực: Lõi 1 Trắng, Lõi 2 Nâu');
select pg_temp.ok(not exists (select 1 from master.bom_lines l join master.bom_headers h on h.id = l.bom_id
                               join master.product_specs s on s.id = h.spec_id join master.materials m on m.id = l.material_id
                               where s.cores = 2 and s.insulation = 'SIL' and s.status <> 'OBSOLETE' and m.code = 'SI-C1'),
  'BOM dây 2 lõi silicone không còn màu silicone xanh dương (SI-C1)');

-- (2) Tạm tính: chọn spec 2 lõi đã phát hành và một bản nháp mới của nó
insert into t select 'rel', p.current_spec_id from master.products p join master.product_specs s on s.id = p.current_spec_id
 where s.cores = 2
   and not exists (select 1 from master.product_specs x where x.product_id = p.id and x.id <> s.id and x.status in ('DRAFT','PILOT_PENDING','PILOT','PENDING_APPROVAL'))
 order by (s.status = 'RELEASED') desc, (p.code like 'HOME-%') desc, p.code limit 1;
select set_config('bmt.allow_release', 'on', true);
update master.product_specs set status = 'RELEASED' where id = pg_temp.v('rel') and status <> 'RELEASED';
select set_config('bmt.allow_release', 'off', true);
select pg_temp.as_user('E_KTTP');
do $$ begin
  execute 'set local role authenticated';
  insert into t values ('spec', master.new_spec_version(pg_temp.v('rel'), 'MAJOR'));
  execute 'reset role';
end $$;
create temp table before as select s.wire_count, s.cores, s.core_colors, r.metal_kgkm, r.rdc_calc, (select count(*) from core.audit_log) audits
  from master.product_specs s join master.spec_results r on r.spec_id = s.id where s.id = pg_temp.v('spec');
create temp table pv (j jsonb);
grant all on pv to authenticated;
select pg_temp.as_api($q$insert into pv select app.spec_preview(pg_temp.v('spec'),
  '{"wire_mix":[{"n":16,"d":0.24},{"n":4,"d":0.3}],"cores":"4","core_colors":["Trắng","Nâu","Đen","Xám"]}')$q$);
select pg_temp.ok((select (j->'spec'->>'wire_count')::int = 20 and (j->'spec'->>'cores')::int = 4
  and (j->'res'->>'metal_kgkm')::numeric > b.metal_kgkm and jsonb_array_length(j->'spec'->'core_colors') = 4 from pv, before b),
  'Tạm tính trả thông số mới: 20 sợi, 4 lõi, 4 màu, đồng tăng');
select pg_temp.ok((select s.wire_count = b.wire_count and s.cores = b.cores and s.core_colors is not distinct from b.core_colors
  and r.metal_kgkm = b.metal_kgkm and r.rdc_calc = b.rdc_calc
  from master.product_specs s join master.spec_results r on r.spec_id = s.id, before b where s.id = pg_temp.v('spec')),
  'Tạm tính không lưu gì vào spec, kết quả định mức');
select pg_temp.ok((select count(*) from core.audit_log) = (select audits from before), 'Tạm tính không ghi nhật ký');
select pg_temp.ok(coalesce(current_setting('bmt.admin_spec_edit', true), '') <> 'on', 'Cờ sửa spec đã phát hành không còn bật sau tạm tính');
select pg_temp.blocked($q$select app.spec_preview(pg_temp.v('spec'), '{"wire_mix":[{"n":0,"d":0.24}]}')$q$, 'số nguyên', 'Tạm tính số sợi sai: báo lỗi như khi lưu');
select pg_temp.blocked($q$select app.spec_preview(pg_temp.v('rel'), '{"cores":"3"}')$q$, 'Không có quyền tạm tính', 'Người thường không tạm tính spec đã phát hành');
select pg_temp.as_user('E_ADM');
delete from pv where true;
select pg_temp.as_api($q$insert into pv select app.spec_preview(pg_temp.v('rel'), '{"ins_thickness_mm":"0.8"}')$q$);
select pg_temp.ok((select (j->'res'->>'ins_kgkm')::numeric > r.ins_kgkm and (j->'spec'->>'status') = 'RELEASED' from pv, master.spec_results r where r.spec_id = pg_temp.v('rel'))
  and (select ins_thickness_mm <> 0.8 from master.product_specs where id = pg_temp.v('rel')),
  'Quản trị tạm tính spec đã phát hành: cách điện dày hơn → kg/km tăng, spec không đổi');
select pg_temp.ok(not has_function_privilege('anon', 'app.spec_preview(uuid,jsonb)', 'execute'), 'Khách (anon) không gọi được tạm tính');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
