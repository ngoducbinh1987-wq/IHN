-- Kiểm thử migration 20261026006500: giới hạn Rdc lõi AWG theo IEC TR 62602.
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


-- Bảng IEC TR 62602:2009 Bảng 1–2, lõi bện Class 2
select pg_temp.ok((select bool_and((c.code, c.rdc_limit, c.rdc_limit_tc) in (('A20', 34.6, 36.7), ('A18', 21.8, 23.2), ('A16', 13.7, 14.6), ('A14', 8.62, 8.96)))
                     from master.core_types c where c.code in ('A14', 'A16', 'A18', 'A20')) and (select count(*) = 4 from master.core_types where code like 'A%' and rdc_source like 'IEC TR 62602%'),
  'Lõi AWG 14–20: giới hạn đồng trần / mạ thiếc theo IEC TR 62602, có ghi căn cứ');
select pg_temp.ok(not exists (select 1 from master.product_specs s join master.spec_results r on r.spec_id = s.id join master.core_types c on c.code = s.core_code and c.set_id = s.param_set_id
                               where s.status <> 'OBSOLETE' and s.core_code like 'A%' and s.core_code <> 'A22' and r.rdc_limit is distinct from case when s.conductor_mat = 'TC' then c.rdc_limit_tc else c.rdc_limit end),
  'Mọi spec lõi AWG: giới hạn Rdc theo vật liệu ruột dẫn (TC → cột mạ thiếc)');
select pg_temp.ok(not exists (select 1 from master.product_specs s, unnest(master.check_spec(s.id)) x where s.status <> 'OBSOLETE' and s.core_code like 'A%' and s.core_code <> 'A22' and x like 'Chưa có giới hạn Rdc%'),
  'Không còn cảnh báo "Chưa có giới hạn Rdc (AWG)"');
-- Đổi một mã CTL sang đồng trần: giới hạn chuyển sang cột đồng trần
insert into t select 'ctl', s.id from master.product_specs s join master.products p on p.id = s.product_id where p.code = 'CTRL-KVAWG16S4PVC' and s.status <> 'OBSOLETE' order by s.version desc limit 1;
select set_config('bmt.admin_spec_edit', 'on', true);
update master.product_specs set conductor_mat = 'BC' where id = pg_temp.v('ctl');
select master.calc_spec(pg_temp.v('ctl'));
select pg_temp.ok((select rdc_limit = 13.7 from master.spec_results where spec_id = pg_temp.v('ctl')), 'Lõi AWG16 đồng trần: giới hạn 13,7 Ω/km');
update master.product_specs set conductor_mat = 'TC' where id = pg_temp.v('ctl');
select master.calc_spec(pg_temp.v('ctl'));
select pg_temp.ok((select rdc_limit = 14.6 from master.spec_results where spec_id = pg_temp.v('ctl')), 'Lõi AWG16 mạ thiếc: giới hạn 14,6 Ω/km');
select pg_temp.ok((select rdc_limit = 19.5 from master.spec_results r join master.product_specs s on s.id = r.spec_id join master.products p on p.id = s.product_id
                    where p.code = 'PFR-2C-1' and s.status <> 'OBSOLETE' order by s.version desc limit 1), 'Lõi mét (M1) giữ giới hạn cũ 19,5 Ω/km');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
