-- Kiểm thử migration 20261026006400: áp quy cách ruột dẫn chuẩn cho mọi mã cùng cỡ lõi.
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

-- Mô phỏng chuẩn của anh Bình: HOME-KV075X2LZ 16×0,24 bước 21,21; HOME-KV10X2LZ 19×0,24 + 2×0,20 bước 25
insert into t select 's075', current_spec_id from master.products where code = 'HOME-KV075X2LZ';
insert into t select 's1', current_spec_id from master.products where code = 'HOME-KV10X2LZ';
select set_config('bmt.admin_spec_edit', 'on', true);
select set_config('bmt.allow_release', 'on', true);
update master.product_specs set status = 'RELEASED' where id in (pg_temp.v('s075'), pg_temp.v('s1')) and status <> 'RELEASED';
select set_config('bmt.allow_release', 'off', true);
update master.product_specs set pitch_mm = 21.2132034356 where id = pg_temp.v('s075');
select master.set_spec_layers(pg_temp.v('s075'), '{"wire_mix":[{"n":16,"d":0.24}]}');
update master.product_specs set pitch_mm = 25 where id = pg_temp.v('s1');
select master.set_spec_layers(pg_temp.v('s1'), '{"wire_mix":[{"n":19,"d":0.24},{"n":2,"d":0.2}]}');
select master.calc_spec(pg_temp.v('s075')); select master.calc_spec(pg_temp.v('s1'));
-- Một mã 1,0 mm² và một mã 0,75 còn quy cách cũ (để chắc chắn có mã cần sửa cả khi chạy lại trên dữ liệu đã chuẩn hóa)
select master.set_spec_layers(s.id, '{"wire_mix":[{"n":20,"d":0.24}]}') from master.product_specs s join master.products p on p.id = s.product_id
 where p.code = 'HOME-KV10X4FP' and s.status <> 'OBSOLETE';
select master.set_spec_layers(s.id, '{"wire_mix":[{"n":15,"d":0.24}]}') from master.product_specs s join master.products p on p.id = s.product_id
 where p.code = 'HOME-KV075X4FP' and s.status <> 'OBSOLETE';
select set_config('bmt.admin_spec_edit', 'off', true);
select pg_temp.ok(exists (select 1 from master.materials where code = 'CU-020' and group_code = 'CONDUCTOR'), 'Có vật tư sợi đồng trần Ø0,20 (CU-020)');
create temp table lay as select id, lay_factor, cores, status from master.product_specs where core_code in ('M0.75', 'M1');
-- Kế hoạch dùng mã 1 mm²
with x as (insert into plan.production_plans (plan_no, period_label) values ('KH-CS1', 'Thử') returning id) insert into t select 'plan', id from x;
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, m_per_pack, pack_type, brand)
select pg_temp.v('plan'), s.product_id, s.id, 1000, 500, s.pack_type, s.brand from master.product_specs s join master.products p on p.id = s.product_id
 where p.code = 'HOME-KV10X4FP' and s.status <> 'OBSOLETE' order by s.version desc limit 1;
update plan.production_plans set mrp_stale = false where id = pg_temp.v('plan');

-- Quyền
select pg_temp.as_user('E_KTTP');
select pg_temp.blocked($q$select app.admin_conductor_apply(pg_temp.v('s1'), 'thử')$q$, 'Chỉ Quản trị', 'Người không phải Quản trị không áp được');
select pg_temp.as_user('E_ADM');
select pg_temp.blocked($q$select app.admin_conductor_apply(pg_temp.v('s1'), ' ')$q$, 'lý do', 'Bắt buộc lý do');

create temp table res (j jsonb);
grant all on res to authenticated;
select pg_temp.as_api($q$insert into res select app.admin_conductor_apply(pg_temp.v('s075'), 'Chuẩn hóa 0,75')$q$);
select pg_temp.as_api($q$insert into res select app.admin_conductor_apply(pg_temp.v('s1'), 'Chuẩn hóa 1,0')$q$);
select pg_temp.ok((select count(*) = 2 and min((j->>'count')::int) > 0 from res), 'Áp chuẩn 0,75 và 1,0 cho các mã khác: có spec được sửa');
select pg_temp.ok(not exists (select 1 from master.product_specs s where s.status <> 'OBSOLETE' and s.core_code = 'M0.75' and s.conductor_mat = 'BC'
                                and (s.wire_mix <> '[{"n":16,"d":0.24}]'::jsonb or s.pitch_mm <> 21.2132034356)),
  'Mọi mã lõi 0,75 BC: 16×0,24, bước 21,21');
select pg_temp.ok(not exists (select 1 from master.product_specs s where s.status <> 'OBSOLETE' and s.core_code = 'M1' and s.conductor_mat = 'BC'
                                and (s.wire_mix <> '[{"n":19,"d":0.24},{"n":2,"d":0.2}]'::jsonb or s.pitch_mm <> 25)),
  'Mọi mã lõi 1,0 BC: 19×0,24 + 2×0,20, bước 25');
select pg_temp.ok(not exists (select 1 from master.product_specs s join lay l on l.id = s.id where s.lay_factor <> l.lay_factor or s.status <> l.status),
  'Hệ số ghép K, trạng thái từng mã giữ nguyên');
select pg_temp.ok((select bool_and(abs(r.metal_kgkm / s.cores / s.lay_factor - r1.metal_kgkm / s1.cores / s1.lay_factor) < 0.00001)
                     from master.product_specs s join master.spec_results r on r.spec_id = s.id,
                          master.product_specs s1 join master.spec_results r1 on r1.spec_id = s1.id
                    where s1.id = pg_temp.v('s1') and s.core_code = 'M1' and s.status <> 'OBSOLETE'),
  'Đồng mỗi lõi (bỏ K) mọi mã 1,0 mm² = mã chuẩn HOME-KV10X2LZ');
select pg_temp.ok((select bool_and(abs(pg_temp.q(s.id, 'CU-020') - r.metal_kgkm * 2 * 0.04 / (19 * 0.0576 + 2 * 0.04)) < 0.00001
                                   and abs(pg_temp.q(s.id, 'CU-024') - r.metal_kgkm * 19 * 0.0576 / (19 * 0.0576 + 2 * 0.04)) < 0.00001)
                     from master.product_specs s join master.spec_results r on r.spec_id = s.id where s.core_code = 'M1' and s.status <> 'OBSOLETE'),
  'BOM mọi mã 1,0 mm² (cả mã chuẩn): CU-024 và CU-020 chia theo n·d²');
select pg_temp.ok(not exists (select 1 from master.product_specs s where s.status <> 'OBSOLETE' and s.core_code in ('M0.75', 'M1')
                               and cardinality(master.bom_issues(s.id)) > 0), 'Mọi mã 0,75 / 1,0: BOM khớp');
select pg_temp.ok((select mrp_stale from plan.production_plans where id = pg_temp.v('plan')), 'Kế hoạch dùng mã 1,0 mm² cần chạy lại MRP');
select pg_temp.ok((select count(*) from core.audit_log where action = 'ADMIN_SPEC' and new_data ->> 'doc_type' like 'Chuẩn hóa ruột dẫn%' and at >= now())
                   = (select sum((j->>'count')::int) from res), 'Nhật ký ghi từng spec được chuẩn hóa');
select pg_temp.ok(not has_function_privilege('anon', 'app.admin_conductor_apply(uuid,text)', 'execute')
  and not has_function_privilege('authenticated', 'master.apply_conductor(uuid)', 'execute'), 'Khách không gọi được; hàm nội bộ không mở cho người dùng');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
