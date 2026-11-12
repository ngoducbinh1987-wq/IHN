-- Kiểm thử migration 20261026006000: ruột dẫn nhiều loại sợi, màu từng lõi.
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

-- Spec mẫu 2 lõi: tạo phiên bản nháp mới để sửa (dữ liệu thật đã phát hành)
insert into t select 'rel', p.current_spec_id from master.products p join master.product_specs s on s.id = p.current_spec_id
 where s.cores = 2
   and not exists (select 1 from master.product_specs x where x.product_id = p.id and x.id <> s.id and x.status in ('DRAFT','PILOT_PENDING','PILOT','PENDING_APPROVAL'))
 order by (s.status = 'RELEASED') desc, (p.code like 'HOME-%LZ') desc, p.code limit 1;
select set_config('bmt.allow_release', 'on', true);
update master.product_specs set status = 'RELEASED' where id = pg_temp.v('rel') and status <> 'RELEASED';
select set_config('bmt.allow_release', 'off', true);
select pg_temp.ok((select wire_mix = jsonb_build_array(jsonb_build_object('n', wire_count, 'd', wire_dia_mm)) from master.product_specs where id = pg_temp.v('rel')),
  'Dữ liệu cũ: wire_mix = một loại sợi (số sợi × đường kính cũ)');
select pg_temp.as_user('E_KTTP');
do $$ begin
  execute 'set local role authenticated';
  insert into t values ('spec', master.new_spec_version(pg_temp.v('rel'), 'MAJOR'));
  execute 'reset role';
end $$;
select pg_temp.ok((select wire_mix is not null from master.product_specs where id = pg_temp.v('spec')), 'Phiên bản mới chép các loại sợi');

-- Một loại sợi như cũ: định mức không đổi
create temp table m0 as select metal_kgkm, ins_kgkm, rdc_calc from master.spec_results where spec_id = pg_temp.v('spec');
select pg_temp.as_api($q$select app.update_spec_draft(pg_temp.v('spec'),
  jsonb_build_object('wire_mix', (select wire_mix from master.product_specs where id = pg_temp.v('spec'))))$q$);
select pg_temp.ok((select abs(r.metal_kgkm - m0.metal_kgkm) < 1e-6 and abs(r.rdc_calc - m0.rdc_calc) < 1e-6
  from master.spec_results r, m0 where r.spec_id = pg_temp.v('spec')), 'Lưu lại cùng một loại sợi: định mức đồng, Rdc không đổi');

-- Hai loại sợi 16×0,24 + 4×0,30
select pg_temp.as_api($q$select app.update_spec_draft(pg_temp.v('spec'),
  '{"wire_mix":[{"n":16,"d":0.24},{"n":"","d":""},{"n":4,"d":0.3}]}')$q$);
select pg_temp.ok((select jsonb_array_length(wire_mix) = 2 and wire_count = 20
  and abs(wire_dia_mm - sqrt((16*0.24^2 + 4*0.3^2) / 20)) < 1e-6 from master.product_specs where id = pg_temp.v('spec')),
  'Hai loại sợi: bỏ dòng trống, tổng 20 sợi, đường kính tương đương sqrt(Σn·d²/Σn)');
select pg_temp.ok((select abs(a_total_mm2 - (16*pi()*0.24^2/4 + 4*pi()*0.3^2/4)) < 1e-6 from master.spec_results where spec_id = pg_temp.v('spec')),
  'Tiết diện ruột = tổng tiết diện từng loại sợi');
select pg_temp.ok((select r.metal_kgkm > m0.metal_kgkm and r.rdc_calc < m0.rdc_calc from master.spec_results r, m0 where r.spec_id = pg_temp.v('spec')),
  'Thêm sợi: định mức đồng tăng, Rdc giảm');
select pg_temp.blocked($q$select app.update_spec_draft(pg_temp.v('spec'), '{"wire_mix":[{"n":2.5,"d":0.24}]}')$q$, 'số nguyên', 'Số sợi lẻ bị chặn');
select pg_temp.blocked($q$select app.update_spec_draft(pg_temp.v('spec'), '{"wire_mix":[{"n":10,"d":0}]}')$q$, 'Đường kính sợi', 'Đường kính 0 bị chặn');
select pg_temp.blocked($q$select app.update_spec_draft(pg_temp.v('spec'), '{"wire_mix":[{"n":"","d":""}]}')$q$, 'ít nhất một loại sợi', 'Không khai loại sợi nào bị chặn');
select pg_temp.blocked($q$select app.update_spec_draft(pg_temp.v('spec'),
  '{"wire_mix":[{"n":1,"d":0.2},{"n":1,"d":0.2},{"n":1,"d":0.2},{"n":1,"d":0.2},{"n":1,"d":0.2}]}')$q$, 'tối đa 4', 'Quá 4 loại sợi bị chặn');

-- Màu từng lõi
select pg_temp.as_api($q$select app.update_spec_draft(pg_temp.v('spec'), '{"core_colors":["Nâu"," Trắng ","Đen"]}')$q$);
select pg_temp.ok((select core_colors = array['Nâu','Trắng'] and insulation_colors = 'Nâu + Trắng' from master.product_specs where id = pg_temp.v('spec')),
  'Màu lõi: cắt theo số lõi (2), bỏ khoảng trắng, ghi chung "Nâu + Trắng"');
select pg_temp.as_api($q$select app.update_spec_draft(pg_temp.v('spec'), '{"cores":"4","core_colors":["Nâu","","Xám"]}')$q$);
select pg_temp.ok((select core_colors = array['Nâu',null,'Xám',null]::text[] and insulation_colors = 'Nâu + ? + Xám + ?' from master.product_specs where id = pg_temp.v('spec')),
  'Đổi 4 lõi: thiếu màu để trống (?), đủ 4 vị trí');
select pg_temp.as_api($q$select app.update_spec_draft(pg_temp.v('spec'), '{"cores":"2","core_colors":["",""]}')$q$);
select pg_temp.ok((select core_colors is null and insulation_colors = 'Nâu + ? + Xám + ?' from master.product_specs where id = pg_temp.v('spec')),
  'Xóa hết màu lõi: core_colors trống, giữ ghi chú màu cũ');

-- Quản trị sửa spec đã phát hành qua admin_spec_edit cũng nhận các loại sợi, màu lõi
select pg_temp.as_user('E_ADM');
select pg_temp.as_api($q$select app.admin_spec_edit(pg_temp.v('rel'), 'spec', '{"wire_mix":[{"n":30,"d":0.24}],"core_colors":["Đỏ","Đen"]}', 'Thử khai lớp')$q$);
select pg_temp.ok((select status = 'RELEASED' and wire_count = 30 and core_colors = array['Đỏ','Đen'] from master.product_specs where id = pg_temp.v('rel')),
  'Quản trị sửa spec đã phát hành: lưu loại sợi, màu lõi; vẫn Đã phát hành');
select pg_temp.ok(not has_function_privilege('authenticated', 'master.set_spec_layers(uuid,jsonb)', 'execute'), 'Người dùng không gọi thẳng hàm nội bộ set_spec_layers');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
