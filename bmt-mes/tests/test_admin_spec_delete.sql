-- Kiểm thử migration 20261026005900: Quản trị xóa phiên bản spec (nháp, đã phát hành, hiện hành).
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
create function pg_temp.newver(p_from uuid) returns uuid language sql as $$ select master.new_spec_version(p_from, 'MAJOR') $$;
set client_min_messages = notice;

update core.profiles set status = 'INACTIVE' where status = 'ACTIVE';
with u(code) as (values ('D_ADM'),('D_KTTP')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('D_ADM','ADMIN'),('D_KTTP','KT_TP')) u(code, role) on u.code = p.employee_code;

-- Hai mã có BOM, không chứng từ nào dùng; bản hiện hành coi như đã phát hành
insert into t select 'p' || row_number() over (order by p.code), p.id from master.products p
 where exists (select 1 from master.bom_headers h join master.bom_lines l on l.bom_id = h.id where h.spec_id = p.current_spec_id)
   and not exists (select 1 from master.product_specs s where s.product_id = p.id and s.id <> p.current_spec_id)
   and not exists (select 1 from plan.plan_lines l where l.product_id = p.id)
   and not exists (select 1 from mfg.work_orders w where w.product_id = p.id)
   and not exists (select 1 from inv.lots l where l.product_id = p.id)
 order by p.code limit 2;
insert into t select 'v1', current_spec_id from master.products where id = pg_temp.v('p1');
insert into t select 'q1', current_spec_id from master.products where id = pg_temp.v('p2');
select set_config('bmt.allow_release', 'on', true);
update master.product_specs set status = 'RELEASED' where id in (pg_temp.v('v1'), pg_temp.v('q1')) and status <> 'RELEASED';
update master.bom_headers set status = 'RELEASED' where spec_id in (pg_temp.v('v1'), pg_temp.v('q1'));
select set_config('bmt.allow_release', 'off', true);
select pg_temp.as_user('D_ADM');
insert into t select 'v2', pg_temp.newver(pg_temp.v('v1'));

-- ================================================================ Quyền
select pg_temp.as_user('D_KTTP');
select pg_temp.blocked($q$select app.admin_spec_delete(pg_temp.v('v2'), 'thử')$q$, 'Chỉ Quản trị', 'TP KT/QA không xóa được phiên bản spec');
select pg_temp.as_user('D_ADM');
select pg_temp.blocked($q$select app.admin_spec_delete(pg_temp.v('v2'), ' ')$q$, 'lý do', 'Xóa phiên bản bắt buộc ghi lý do');

-- ================================================================ Xóa bản nháp
select pg_temp.as_api($q$select app.admin_spec_delete(pg_temp.v('v2'), 'Tạo nhầm phiên bản')$q$);
select pg_temp.ok(not exists (select 1 from master.product_specs where id = pg_temp.v('v2'))
  and not exists (select 1 from master.bom_headers where spec_id = pg_temp.v('v2'))
  and (select current_spec_id = pg_temp.v('v1') from master.products where id = pg_temp.v('p1')),
  'Quản trị xóa phiên bản nháp v2 (kèm BOM); mã vẫn dùng v1');
select pg_temp.blocked($q$select app.admin_spec_delete(pg_temp.v('v1'), 'thử')$q$, 'duy nhất', 'Không xóa phiên bản duy nhất của mã');

-- ================================================================ Xóa bản hiện hành đã phát hành
insert into t select 'v3', pg_temp.newver(pg_temp.v('v1'));
select pg_temp.as_api($q$select app.admin_spec_delete(pg_temp.v('v1'), 'Bỏ bản cũ')$q$);
select pg_temp.ok(not exists (select 1 from master.product_specs where id = pg_temp.v('v1'))
  and (select current_spec_id = pg_temp.v('v3') from master.products where id = pg_temp.v('p1')),
  'Quản trị xóa bản hiện hành đã phát hành (kèm BOM đã phát hành); mã chuyển sang bản còn lại');

-- Bản cũ (OBSOLETE) được phát hành lại khi xóa bản hiện hành
insert into t select 'q2', pg_temp.newver(pg_temp.v('q1'));
select set_config('bmt.allow_release', 'on', true);
update master.product_specs set status = 'OBSOLETE' where id = pg_temp.v('q1');
update master.product_specs set status = 'RELEASED' where id = pg_temp.v('q2');
update master.bom_headers set status = 'RELEASED' where spec_id = pg_temp.v('q2');
update master.products set current_spec_id = pg_temp.v('q2') where id = pg_temp.v('p2');
select set_config('bmt.allow_release', 'off', true);
select pg_temp.as_api($q$select app.admin_spec_delete(pg_temp.v('q2'), 'Phát hành nhầm')$q$);
select pg_temp.ok((select p.current_spec_id = pg_temp.v('q1') and s.status = 'RELEASED' from master.products p join master.product_specs s on s.id = p.current_spec_id
  where p.id = pg_temp.v('p2')), 'Xóa bản hiện hành: bản cũ trước đó được phát hành lại và thành hiện hành');

-- ================================================================ Đang được dùng
with x as (insert into plan.production_plans (plan_no, period_label) values ('KH-D1', 'Thử') returning id) insert into t select 'plan', id from x;
insert into t select 'q3', pg_temp.newver(pg_temp.v('q1'));
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, m_per_pack, pack_type, brand)
select pg_temp.v('plan'), pg_temp.v('p2'), pg_temp.v('q3'), 1000, 500, s.pack_type, s.brand from master.product_specs s where s.id = pg_temp.v('q3');
select pg_temp.blocked($q$select app.admin_spec_delete(pg_temp.v('q3'), 'thử')$q$, 'đang được dùng', 'Không xóa phiên bản kế hoạch đang dùng');

select pg_temp.ok((select count(*) = 3 from core.audit_log where action = 'ADMIN_DELETE' and new_data ->> 'doc_type' = 'Xóa phiên bản spec'),
  'Nhật ký can thiệp ghi 3 lần xóa phiên bản');
select pg_temp.ok(not has_function_privilege('anon', 'app.admin_spec_delete(uuid,text)', 'execute'), 'Khách (anon) không gọi được');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
