-- Kiểm thử migration 20261026006200: BOM tự theo thông số, đối chiếu BOM, đổi mã sản phẩm.
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


-- (A) Dữ liệu sau migration: mọi spec còn hiệu lực có BOM khớp
select pg_temp.ok(not exists (select 1 from master.product_specs s where s.status <> 'OBSOLETE' and cardinality(master.bom_issues(s.id)) > 0
                               and not exists (select 1 from unnest(master.bom_issues(s.id)) x where x like 'Chưa có vật tư sợi đồng%')),
  'Mọi spec còn hiệu lực: BOM khớp thông số (số lượng, vật liệu, màu lõi, nhãn, bobin, không dòng thừa)');

-- Spec 2 lõi silicone (HOME-KV10X2LZ nếu có) – lập phiên bản nháp để sửa
insert into t select 'rel', p.current_spec_id from master.products p join master.product_specs s on s.id = p.current_spec_id
 where s.cores = 2 and s.insulation = 'SIL' and s.sheath <> 'Không' and not coalesce(s.shield, false)
   and not exists (select 1 from master.product_specs x where x.product_id = p.id and x.id <> s.id and x.status in ('DRAFT','PILOT_PENDING','PILOT','PENDING_APPROVAL'))
 order by (p.code = 'HOME-KV10X2LZ') desc, (p.code like 'HOME-%LZ') desc, p.code limit 1;
insert into t select 'prod', product_id from master.product_specs where id = pg_temp.v('rel');
select set_config('bmt.allow_release', 'on', true);
update master.product_specs set status = 'RELEASED' where id = pg_temp.v('rel') and status <> 'RELEASED';
select set_config('bmt.allow_release', 'off', true);
select pg_temp.as_user('E_KTTP');
do $$ begin
  execute 'set local role authenticated';
  insert into t values ('spec', master.new_spec_version(pg_temp.v('rel'), 'MAJOR'));
  execute 'reset role';
end $$;
create temp table ratio as
select (select sum(l.qty_per_basis) from master.bom_lines l join master.bom_headers h on h.id = l.bom_id join master.materials m on m.id = l.material_id
         where h.spec_id = pg_temp.v('spec') and m.code like 'SIL-%') / nullif((select sum(l.qty_per_basis) from master.bom_lines l join master.bom_headers h on h.id = l.bom_id join master.materials m on m.id = l.material_id
         where h.spec_id = pg_temp.v('spec') and m.code = 'DCBP-50'), 0) r;

-- (B) Lưu thông số mới → BOM tự theo định mức
select pg_temp.as_api($q$select app.update_spec_draft(pg_temp.v('spec'), '{"wire_mix":[{"n":22,"d":0.24}],"ins_thickness_mm":"0.7","sheath_kgkm":"25.5"}')$q$);
create temp table g as
select master.bom_group(m.code, m.group_code, l.operation_code) grp, sum(l.qty_per_basis) q
  from master.bom_lines l join master.bom_headers h on h.id = l.bom_id join master.materials m on m.id = l.material_id
 where h.spec_id = pg_temp.v('spec') group by 1;
select pg_temp.ok((select abs(g.q - r.metal_kgkm) < 0.00001 from g, master.spec_results r where g.grp = 'CU' and r.spec_id = pg_temp.v('spec')),
  'Đổi loại sợi: BOM đồng = định mức đồng MES tính');
select pg_temp.ok((select abs(g.q - r.ins_kgkm) < 0.00001 from g, master.spec_results r where g.grp = 'INS' and r.spec_id = pg_temp.v('spec')),
  'Đổi chiều dày cách điện: BOM cách điện + màu + phụ gia = định mức cách điện');
select pg_temp.ok((select abs(g.q - 25.5) < 0.00001 from g where g.grp = 'SH'), 'Sửa định mức vỏ 25,5 kg/km: BOM vỏ + màu = 25,5');
select pg_temp.ok((select abs((select sum(l.qty_per_basis) from master.bom_lines l join master.bom_headers h on h.id = l.bom_id join master.materials m on m.id = l.material_id
         where h.spec_id = pg_temp.v('spec') and m.code like 'SIL-%') / nullif((select sum(l.qty_per_basis) from master.bom_lines l join master.bom_headers h on h.id = l.bom_id join master.materials m on m.id = l.material_id
         where h.spec_id = pg_temp.v('spec') and m.code = 'DCBP-50'), 0) - r) < 0.01 or r is null from ratio),
  'Giữ tỷ lệ silicone : phụ gia khi đồng bộ');
select pg_temp.ok(cardinality(master.bom_issues(pg_temp.v('spec'))) = 0, 'Sau khi lưu: BOM khớp, không còn lỗi đối chiếu');

-- (C) Đối chiếu phát hiện sai, thiếu, thừa
select pg_temp.as_api($q$select app.save_bom_line(pg_temp.v('spec'), (select m.code from master.bom_lines l join master.bom_headers h on h.id = l.bom_id join master.materials m on m.id = l.material_id where h.spec_id = pg_temp.v('spec') and m.group_code = 'CONDUCTOR' limit 1), 'KM', 1, null, 0, 'CD1')$q$);
select pg_temp.ok(exists (select 1 from unnest(master.bom_issues(pg_temp.v('spec'))) x where x like 'BOM Đồng ruột dẫn % ≠ định mức%'),
  'Sửa tay suất đồng sai: báo BOM đồng ≠ định mức');
select pg_temp.ok(exists (select 1 from unnest(master.check_spec(pg_temp.v('spec'))) x where x like 'BOM Đồng ruột dẫn%'),
  'Lỗi BOM nằm trong kiểm tra phát hành (không phát hành được)');
select pg_temp.as_api($q$select app.update_spec_draft(pg_temp.v('spec'), '{}')$q$);
select pg_temp.ok(cardinality(master.bom_issues(pg_temp.v('spec'))) = 0, 'Lưu lại thông số: BOM đồng về đúng định mức');
select pg_temp.as_api($q$select app.save_bom_line(pg_temp.v('spec'), 'TCCA-020', 'KM', 1.2, null, 0, 'CD4')$q$);
select pg_temp.ok(exists (select 1 from unnest(master.bom_issues(pg_temp.v('spec'))) x where x like 'BOM thừa vật tư Drain%'),
  'Thêm drain khi thông số không có drain: báo thừa');
select pg_temp.as_api($q$select app.delete_bom_line((select l.id from master.bom_lines l join master.bom_headers h on h.id = l.bom_id join master.materials m on m.id = l.material_id where h.spec_id = pg_temp.v('spec') and m.code = 'TCCA-020'))$q$);
select pg_temp.as_api($q$select app.update_spec_draft(pg_temp.v('spec'), '{"core_colors":["Trắng","Nâu"]}')$q$);
select pg_temp.as_api($q$select app.save_bom_line(pg_temp.v('spec'), 'SI-C2', 'KM', 0.05, null, 0, 'CD0')$q$);
select pg_temp.ok(exists (select 1 from unnest(master.bom_issues(pg_temp.v('spec'))) x where x like 'BOM có màu không có trên lõi%Đen%'),
  'Thêm tay màu silicone Đen khi lõi Trắng + Nâu: báo thừa màu');
select pg_temp.as_api($q$select app.update_spec_draft(pg_temp.v('spec'), '{"core_colors":["Đỏ","Nâu"]}')$q$);
select pg_temp.ok(exists (select 1 from unnest(master.bom_issues(pg_temp.v('spec'))) x where x like 'Màu lõi đỏ chưa có vật tư màu SIL%'),
  'Lõi màu Đỏ chưa có vật tư màu silicone: báo thiếu');
select pg_temp.as_api($q$select app.update_spec_draft(pg_temp.v('spec'), '{"core_colors":["Trắng","Nâu"],"brand":"HEIZKA"}')$q$);
select pg_temp.ok((select count(*) = 0 from master.bom_lines l join master.bom_headers h on h.id = l.bom_id join master.materials m on m.id = l.material_id
                    where h.spec_id = pg_temp.v('spec') and m.code = 'LABEL-K')
  and not exists (select 1 from unnest(master.bom_issues(pg_temp.v('spec'))) x where x like 'Nhãn%'),
  'Đổi thương hiệu HEIZKA: nhãn KAVIX trong BOM tự đổi sang nhãn HEIZKA');
select pg_temp.as_api($q$select app.update_spec_draft(pg_temp.v('spec'), '{"pack_type":"Cuộn PE","brand":"KAVIX"}')$q$);
select pg_temp.ok(exists (select 1 from unnest(master.bom_issues(pg_temp.v('spec'))) x where x like '%cuộn PE nhưng BOM có bobin gỗ%'),
  'Đóng gói cuộn PE mà BOM còn bobin gỗ: báo thừa');

-- (D) Tạm tính trả BOM theo thông số mới, không lưu
create temp table pv (j jsonb);
grant all on pv to authenticated;
select pg_temp.as_api($q$insert into pv select app.spec_preview(pg_temp.v('spec'), '{"pack_type":"Bobin gỗ","ins_thickness_mm":"0.9"}')$q$);
select pg_temp.ok((select jsonb_array_length(j->'bom') > 0 and abs((select sum((b->>'qty_per_basis')::numeric) from jsonb_array_elements(j->'bom') b where b->>'operation_code' in ('CD0','CD2')) - (j->'res'->>'ins_kgkm')::numeric) < 0.0001 from pv)
  and (select ins_thickness_mm = 0.7 from master.product_specs where id = pg_temp.v('spec')),
  'Tạm tính: BOM cách điện theo chiều dày mới; thông số đang lưu không đổi');

-- (E) Đổi mã sản phẩm
create temp table so_before as select count(*) n from plan.schedule_orders where product_code = (select code from master.products where id = pg_temp.v('prod'));
select pg_temp.blocked($q$select app.admin_product_rename(pg_temp.v('prod'), 'ZZ-MOI-1', 'thử')$q$, 'Chỉ Quản trị', 'Người không phải Quản trị không đổi được mã');
select pg_temp.as_user('E_ADM');
select pg_temp.blocked($q$select app.admin_product_rename(pg_temp.v('prod'), 'ZZ-MOI-1', ' ')$q$, 'lý do', 'Đổi mã bắt buộc lý do');
select pg_temp.blocked($q$select app.admin_product_rename(pg_temp.v('prod'), (select code from master.products where id <> pg_temp.v('prod') limit 1), 'thử')$q$, 'đã có sản phẩm', 'Không đổi sang mã đã có');
select pg_temp.blocked($q$select app.admin_product_rename(pg_temp.v('prod'), 'ZZ MOI', 'thử')$q$, 'chỉ gồm', 'Mã có khoảng trắng bị chặn');
create temp table oldc as select code from master.products where id = pg_temp.v('prod');
insert into wf.approval_requests (doc_type, doc_id, doc_no, summary, status, submitted_by, flow_snapshot)
select 'SPEC_NEW', pg_temp.v('spec'), 'SPEC ' || o.code || ' v9', 'Phát hành ' || o.code || ' (khác ' || o.code || 'P5)', 'CANCELLED', (select id from core.profiles where employee_code = 'E_ADM'), '[]'
  from oldc o;
select pg_temp.as_api($q$select app.admin_product_rename(pg_temp.v('prod'), 'zz-moi-1', 'Đổi theo chuẩn mã mới')$q$);
select pg_temp.ok((select code = 'ZZ-MOI-1' from master.products where id = pg_temp.v('prod')), 'Đổi mã: chữ thường đổi IN HOA, sản phẩm mang mã mới');
select pg_temp.ok((select count(*) from plan.schedule_orders where product_code = 'ZZ-MOI-1') = (select n from so_before)
  and not exists (select 1 from plan.schedule_orders s, oldc o where s.product_code = o.code), 'Lịch máy đã xếp đổi theo mã mới');
select pg_temp.ok((select doc_no = 'SPEC ZZ-MOI-1 v9' and summary like 'Phát hành ZZ-MOI-1 (khác %P5)' and summary not like '%ZZ-MOI-1P5%' from wf.approval_requests where doc_id = pg_temp.v('spec') and doc_no like '%v9'),
  'Số hồ sơ duyệt spec đổi theo; mã khác có chung tiền tố không bị đổi');
select pg_temp.ok(exists (select 1 from app.admin_overrides(20) where action = 'ADMIN_RENAME'), 'Nhật ký can thiệp của Quản trị ghi lần đổi mã');
select pg_temp.ok(not has_function_privilege('anon', 'app.admin_product_rename(uuid,text,text)', 'execute')
  and not has_function_privilege('authenticated', 'master.sync_bom(uuid)', 'execute'), 'Khách không gọi đổi mã; người dùng không gọi thẳng đồng bộ BOM');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
