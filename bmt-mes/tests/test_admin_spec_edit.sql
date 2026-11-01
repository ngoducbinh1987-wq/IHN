-- Kiểm thử migration 20261026005800: Quản trị sửa spec, BOM ở mọi trạng thái (spec đã phát hành vẫn giữ trạng thái).
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
select p.id, u.role from core.profiles p join (values ('E_ADM','ADMIN'),('E_KTTP','KT_TP'),('E_KTTP','SX_TP')) u(code, role) on u.code = p.employee_code;

-- Một mã có BOM, coi như đã phát hành; một kế hoạch đang dùng mã đó
insert into t select 'spec', p.current_spec_id from master.products p
 where exists (select 1 from master.bom_headers h join master.bom_lines l on l.bom_id = h.id where h.spec_id = p.current_spec_id)
 order by p.code limit 1;
insert into t select 'prod', product_id from master.product_specs where id = pg_temp.v('spec');
select set_config('bmt.allow_release', 'on', true);
update master.product_specs set status = 'RELEASED' where id = pg_temp.v('spec') and status <> 'RELEASED';
update master.bom_headers set status = 'RELEASED' where spec_id = pg_temp.v('spec');
select set_config('bmt.allow_release', 'off', true);
with x as (insert into plan.production_plans (plan_no, period_label) values ('KH-E1', 'Thử') returning id) insert into t select 'plan', id from x;
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, m_per_pack, pack_type, brand)
select pg_temp.v('plan'), pg_temp.v('prod'), pg_temp.v('spec'), 1000, 500, s.pack_type, s.brand from master.product_specs s where s.id = pg_temp.v('spec');
update plan.production_plans set mrp_stale = false where id = pg_temp.v('plan');
insert into t select 'line', l.id from master.bom_lines l join master.bom_headers h on h.id = l.bom_id where h.spec_id = pg_temp.v('spec') order by l.id limit 1;

-- ================================================================ Người thường
select pg_temp.as_user('E_KTTP');
select pg_temp.blocked($q$select app.update_spec_draft(pg_temp.v('spec'), '{"description":"Sửa thử"}')$q$, 'chỉ sửa được spec nháp',
  'TP KT/QA không sửa thẳng spec đã phát hành (phải tạo phiên bản mới)');
select pg_temp.blocked($q$select app.admin_spec_edit(pg_temp.v('spec'), 'spec', '{"description":"Sửa thử"}', 'thử')$q$, 'Chỉ Quản trị',
  'Người không phải Quản trị không dùng được sửa spec của Quản trị');
select pg_temp.blocked($q$select app.save_bom_line(pg_temp.v('spec'), 'CU-024', 'KM', 1, null, 0, 'CD1')$q$, 'Chỉ sửa được BOM của spec nháp',
  'TP KT/QA không sửa BOM đã phát hành');

-- ================================================================ Quản trị
select pg_temp.as_user('E_ADM');
select pg_temp.blocked($q$select app.admin_spec_edit(pg_temp.v('spec'), 'spec', '{"description":"Sửa thử"}', ' ')$q$, 'lý do', 'Quản trị sửa spec bắt buộc ghi lý do');
select pg_temp.as_api($q$select app.admin_spec_edit(pg_temp.v('spec'), 'spec', '{"description":"Quy cách sửa bởi Quản trị","brand":"HEIZKA","od_mm":"7.5"}', 'Sai quy cách in trên catalogue')$q$);
select pg_temp.ok((select p.description = 'Quy cách sửa bởi Quản trị' and p.default_brand = 'HEIZKA' and s.brand = 'HEIZKA' and s.status = 'RELEASED'
  from master.products p join master.product_specs s on s.product_id = p.id where s.id = pg_temp.v('spec')),
  'Quản trị sửa quy cách, thương hiệu spec đã phát hành; spec vẫn Đã phát hành');
select pg_temp.ok((select mrp_stale from plan.production_plans where id = pg_temp.v('plan')),
  'Kế hoạch đang dùng mã này được đánh dấu cần chạy lại MRP');
select pg_temp.as_api($q$select app.admin_spec_edit(pg_temp.v('spec'), 'bom_save',
  jsonb_build_object('material_code', (select m.code from master.bom_lines l join master.materials m on m.id = l.material_id where l.id = pg_temp.v('line')),
    'basis', (select basis from master.bom_lines where id = pg_temp.v('line')), 'qty', 9.876, 'operation', (select operation_code from master.bom_lines where id = pg_temp.v('line'))),
  'Định mức thực tế')$q$);
select pg_temp.ok((select qty_per_basis = 9.876 from master.bom_lines where id = pg_temp.v('line'))
  and (select status = 'RELEASED' from master.bom_headers where spec_id = pg_temp.v('spec')),
  'Quản trị sửa suất dòng BOM đã phát hành; BOM vẫn Đã phát hành');
select pg_temp.as_api($q$select app.admin_spec_edit(pg_temp.v('spec'), 'bom_delete', jsonb_build_object('line_id', pg_temp.v('line')), 'Dòng thừa')$q$);
select pg_temp.ok(not exists (select 1 from master.bom_lines where id = pg_temp.v('line')), 'Quản trị xóa dòng BOM đã phát hành');
select pg_temp.blocked($q$select app.admin_spec_edit(pg_temp.v('spec'), 'bom_delete', jsonb_build_object('line_id', gen_random_uuid()), 'thử')$q$,
  'không thuộc spec', 'Không xóa dòng BOM của spec khác');

-- Khóa vẫn còn khi không qua hàm Quản trị
reset role;
do $$ begin
  begin
    update master.product_specs set config_note = 'ghi thẳng' where id = pg_temp.v('spec');
    raise exception 'FAIL: ghi thẳng spec đã phát hành lẽ ra bị chặn';
  exception when others then
    if sqlerrm not like '%đã phát hành%' then raise; end if;
    insert into r(msg) values ('Ngoài hàm Quản trị, spec đã phát hành vẫn bị khóa → ' || sqlerrm);
  end;
end $$;
select pg_temp.as_user('E_ADM');
select pg_temp.ok((select count(*) = 3 from app.admin_overrides(50) where action = 'ADMIN_SPEC'), 'Nhật ký can thiệp của Quản trị ghi 3 lần sửa spec');
select pg_temp.ok(not has_function_privilege('anon', 'app.admin_spec_edit(uuid,text,jsonb,text)', 'execute'), 'Khách (anon) không gọi được');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
