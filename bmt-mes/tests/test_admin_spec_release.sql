-- Kiểm thử migration 20261026008400: Quản trị phát hành spec trực tiếp, Rdc vượt thì ghi chấp nhận sai lệch và vẫn cảnh báo.
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
create function pg_temp.sp(p_k text) returns master.product_specs language sql as $$ select * from master.product_specs where id = pg_temp.v(p_k) $$;
set client_min_messages = notice;

update core.profiles set status = 'INACTIVE' where status = 'ACTIVE';
with u(code) as (values ('L_ADM'),('L_KTTP')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('L_ADM','ADMIN'),('L_KTTP','KT_TP')) u(code, role) on u.code = p.employee_code;

-- Ba mã có BOM, giới hạn Rdc, chưa chứng từ nào dùng, chưa có phiên bản khác: mở phiên bản nháp mới cho từng mã
insert into t select 'p' || row_number() over (order by (p.code like 'HOME-%') desc, p.code), p.id from master.products p
 join master.spec_results sr on sr.spec_id = p.current_spec_id
 where sr.rdc_limit is not null and sr.rdc_calc <= sr.rdc_limit
   and exists (select 1 from master.bom_headers h join master.bom_lines l on l.bom_id = h.id where h.spec_id = p.current_spec_id)
   and not exists (select 1 from master.product_specs s where s.product_id = p.id and s.id <> p.current_spec_id)
   and not exists (select 1 from plan.plan_lines l where l.product_id = p.id)
   and not exists (select 1 from mfg.work_orders w where w.product_id = p.id)
 order by (p.code like 'HOME-%') desc, p.code limit 3;
insert into t select 'v' || substr(k, 2), (select current_spec_id from master.products where id = t.v) from t where k like 'p%';
update master.product_specs set status = 'DRAFT' where id in (select v from t where k like 'v%') and status not in ('RELEASED', 'DRAFT');
select pg_temp.as_user('L_ADM');
-- Bản hiện hành đã phát hành (dữ liệu thật) thì mở bản nháp mới; còn nháp (DB dựng mới) thì dùng luôn
insert into t select 'd' || substr(k, 2), case when (select status from master.product_specs where id = t.v) = 'RELEASED'
                                               then master.new_spec_version(v, 'MAJOR') else v end from t where k like 'v%';
select pg_temp.ok((select count(*) = 3 from master.product_specs where id in (pg_temp.v('d1'), pg_temp.v('d2'), pg_temp.v('d3')) and status = 'DRAFT')
  and coalesce(array_length(master.check_spec(pg_temp.v('d1')), 1), 0) = 0, 'Chuẩn bị 3 phiên bản nháp, bản d1 đạt kiểm tra');
-- d2: Rdc tính vượt giới hạn; d3: lỗi khác (chưa có giới hạn Rdc)
update master.spec_results set rdc_calc = rdc_limit * 1.2 where spec_id = pg_temp.v('d2');
update master.spec_results set rdc_limit = null where spec_id = pg_temp.v('d3');

-- ================================================================ Quyền
select pg_temp.as_user('L_KTTP');
select pg_temp.blocked($q$select app.admin_spec_release(pg_temp.v('d1'), 'thử')$q$, 'Chỉ Quản trị', 'TP KT/QA không phát hành trực tiếp được');
select pg_temp.as_user('L_ADM');
select pg_temp.blocked($q$select app.admin_spec_release(pg_temp.v('d1'), '  ')$q$, 'lý do', 'Phát hành trực tiếp bắt buộc ghi lý do');

-- Phát hành thường vẫn chặn Rdc vượt
do $$ begin
  perform set_config('bmt.wf_release', 'on', true);
  begin
    perform master.release_spec(pg_temp.v('d2'));
    raise exception 'FAIL: phát hành thường lẽ ra phải chặn Rdc vượt';
  exception when others then
    if sqlerrm not ilike '%Rdc tính%' then raise; end if;
  end;
  perform set_config('bmt.wf_release', 'off', true);
end $$;
select pg_temp.ok(true, 'Phát hành qua quy trình thường vẫn chặn Rdc vượt giới hạn');

-- ================================================================ Phát hành
select pg_temp.as_api($q$select app.admin_spec_release(pg_temp.v('d1'), 'Duyệt phát hành')$q$);
select pg_temp.ok((select status = 'RELEASED' and released_by = (select id from core.profiles where employee_code = 'L_ADM')
                          and coalesce(rdc_deviation_note, '') = '' from pg_temp.sp('d1'))
  and (select current_spec_id = pg_temp.v('d1') from master.products where id = pg_temp.v('p1'))
  and (pg_temp.v('v1') = pg_temp.v('d1') or (select status = 'OBSOLETE' from pg_temp.sp('v1')))
  and (select status = 'RELEASED' from master.bom_headers where spec_id = pg_temp.v('d1') limit 1),
  'Quản trị phát hành bản đạt: Đã phát hành, thành bản hiện hành, bản cũ hết hiệu lực, BOM phát hành, không ghi sai lệch');

select pg_temp.as_api($q$select app.admin_spec_release(pg_temp.v('d2'), 'Đã kiểm tra thực tế, duyệt mẫu này')$q$);
select pg_temp.ok((select status = 'RELEASED' and rdc_deviation_note = 'Đã kiểm tra thực tế, duyệt mẫu này' from pg_temp.sp('d2'))
  and coalesce(array_length(master.check_spec(pg_temp.v('d2')), 1), 0) = 0,
  'Rdc vượt: Quản trị phát hành được, chấp nhận sai lệch ghi đúng lý do "Đã kiểm tra thực tế, duyệt mẫu này"');
select pg_temp.ok((select rdc_over from app.v_products where id = pg_temp.v('p2')),
  'Danh sách sản phẩm vẫn đánh dấu Rdc vượt (web tô đỏ, trang mã hiện cảnh báo)');

select pg_temp.blocked($q$select app.admin_spec_release(pg_temp.v('d3'), 'thử')$q$, 'Không phát hành được spec',
  'Lỗi kiểm tra khác Rdc (chưa có giới hạn Rdc) vẫn chặn phát hành');
select pg_temp.ok((select status = 'DRAFT' and coalesce(rdc_deviation_note, '') = '' from pg_temp.sp('d3')), 'Bản bị chặn giữ nguyên Nháp, không ghi sai lệch');
select pg_temp.blocked($q$select app.admin_spec_release(pg_temp.v('d1'), 'thử')$q$, 'đã phát hành', 'Bản đã phát hành không phát hành lại');

select pg_temp.ok((select count(*) = 2 from core.audit_log where action = 'ADMIN_SPEC' and at >= now() and new_data->>'doc_type' = 'Phát hành spec')
  and (select (new_data->>'rdc_deviation')::boolean and new_data->>'rdc_calc' is not null from core.audit_log where action = 'ADMIN_SPEC' and at >= now() and row_id = pg_temp.v('d2')::text)
  and exists (select 1 from app.admin_overrides(50) where action = 'ADMIN_SPEC' and doc_type = 'Phát hành spec'),
  'Nhật ký can thiệp ghi 2 lần phát hành');
select pg_temp.ok(not has_function_privilege('anon', 'app.admin_spec_release(uuid,text)', 'execute'), 'Khách (anon) không gọi được');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
