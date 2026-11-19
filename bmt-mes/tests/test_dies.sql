-- Kiểm thử migration 20261026010300: module Khuôn (danh mục, quy tắc, tra khuôn theo spec, OD thực tế, đề xuất, đặt khuôn, Alarm).
-- Chạy được bằng psql hoặc Supabase (net.http_get + DO). Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
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
create function pg_temp.spec(p_code text) returns uuid language sql as $$ select current_spec_id from master.products where code = p_code $$;
grant execute on function pg_temp.spec(text) to authenticated;
-- khuôn chọn cho spec × loại (đọc dưới quyền chủ sở hữu)
create function pg_temp.die(p_code text, p_kind text) returns text language sql as $$
  select die_code from master.die_match(pg_temp.spec(p_code)) where kind = p_kind $$;
create function pg_temp.req(p_code text, p_kind text) returns numeric language sql as $$
  select req from master.die_reqs(pg_temp.spec(p_code)) where kind = p_kind $$;
set client_min_messages = notice;

update core.profiles set status = 'INACTIVE' where status = 'ACTIVE';
with u(code) as (values ('D_ADM'),('D_KTTP'),('D_SXTP'),('D_MUANV'),('D_SXKH'),('D_NONE')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('D_ADM','ADMIN'),('D_KTTP','KT_TP'),('D_SXTP','SX_TP'),('D_MUANV','MUA_NV'),('D_SXKH','SX_KH')) u(code, role)
  on u.code = p.employee_code;

-- 1. Quy tắc theo anh Bình chốt
select pg_temp.ok((select count(*) from master.die_rules where kind = 'DV' and tol = 0.08 and mat in ('LSZH','PVC','FR-PVC')) = 3
   and (select bool_and(tol = 0.05) from master.die_rules where kind in ('DS','DC')),
  'Dung sai: khuôn ngoài cách điện ±0,05 mm, khuôn ngoài vỏ ±0,08 mm; vỏ LSZH, PVC, FR-PVC cùng một loại khuôn (DV)');
select pg_temp.ok((select string_agg(code || ':' || status, ',' order by code) from master.dies where code in ('KB-1.35','KB-1.60','TX-4.90','TX-5.85'))
                   = 'KB-1.35:AVAILABLE,KB-1.60:AVAILABLE,TX-4.90:AVAILABLE,TX-5.85:AVAILABLE',
  'Khuôn có sẵn: bện 1,35; 1,60; máy xoắn 4,90; 5,85');
select pg_temp.ok(exists (select 1 from master.dies where code = 'KB-2.10' and fit_min = 1.80 and fit_max = 2.00)
   and not exists (select 1 from master.dies where code in ('KB-1.95','KB-2.05')),
  'KB-1,95 + KB-2,05 gộp thành KB-2,10 (ruột Ø1,80–2,00 mm)');

-- 2. Tra khuôn theo spec
select pg_temp.ok((select string_agg(kind, ',' order by sort) from master.die_reqs(pg_temp.spec('HER15U2LZ'))) = 'KB,TS,DS,TX,TV,DV',
  'HER15U2LZ (silicone, 2 lõi, vỏ LSZH): khuôn bện, tip + die silicone, khuôn xoắn, tip + die vỏ');
select pg_temp.ok((select string_agg(kind, ',' order by sort) from master.die_reqs(pg_temp.spec('HEW16S2PC'))) = 'KB,TC,DC,TX,TV,DV',
  'HEW16S2PC (HDPE, vỏ PVC): tip + die đầu máy truyền thống');
select pg_temp.ok((select string_agg(kind, ',' order by sort) from master.die_reqs(pg_temp.spec('HOME-KV15X1SI'))) = 'KB,TS,DS',
  'Dây đơn silicone không vỏ: chỉ khuôn bện + tip/die silicone');
select pg_temp.ok(pg_temp.die('CTRL-KVAWG14S2PC', 'KB') = 'KB-2.10' and pg_temp.die('F120-KV25U2LZ', 'KB') = 'KB-2.10',
  'KB-2,10 dùng cho cả ruột AWG14 (1,85) và 2,5 mm² (1,96)');
select pg_temp.ok(pg_temp.die('HER15U2LZ', 'TX') = 'TX-5.85', 'HER15U2LZ xoắn bằng khuôn có sẵn TX-5,85');
select pg_temp.ok(not exists (select 1 from master.die_specs() x cross join lateral master.die_match(x.spec_id) m where m.die_id is null),
  'Sau khi nạp: mọi spec đang dùng đều có khuôn trong danh mục (có sẵn hoặc cần đặt)');
select pg_temp.ok((select count(*) from master.die_propose_raw()) = 0, 'Không còn khuôn MES phải đề xuất thêm');
-- khuôn vỏ dùng chung: một khuôn DV phủ được cả vỏ LSZH lẫn PVC khi OD gần nhau
select pg_temp.ok(exists (
  select 1 from master.dies d
   where d.kind = 'DV'
     and exists (select 1 from master.die_specs() x join master.product_specs s on s.id = x.spec_id
                 cross join lateral master.die_match(x.spec_id) m where m.die_id = d.id and s.sheath = 'LSZH')
     and exists (select 1 from master.die_specs() x join master.product_specs s on s.id = x.spec_id
                 cross join lateral master.die_match(x.spec_id) m where m.die_id = d.id and s.sheath in ('PVC', 'FR-PVC'))),
  'Có khuôn ngoài vỏ dùng chung cho mã vỏ LSZH và mã vỏ PVC/FR-PVC');

-- 3. OD tối ưu / OD thực tế
insert into t select 'her', pg_temp.spec('HER15U2LZ');
select pg_temp.ok((select od_src from master.die_reqs(pg_temp.v('her')) where kind = 'DV') = 'tối ưu', 'Chưa đo: khuôn vỏ theo OD tối ưu');
insert into t values ('odv0', (select die_id from master.die_match(pg_temp.v('her')) where kind = 'DV'));
select pg_temp.as_user('D_MUANV');
select pg_temp.blocked($$select app.set_od_actual(pg_temp.v('her'), 7.0, 'đo lô 1')$$, 'TP KT/QA', 'NV mua không nhập OD thực tế');
select pg_temp.as_user('D_KTTP');
select pg_temp.blocked($$select app.set_od_actual(pg_temp.v('her'), 7.0, '')$$, 'căn cứ', 'OD thực tế phải ghi căn cứ');
select pg_temp.as_api($$select app.set_od_actual(pg_temp.v('her'), 7.08, 'Đo lô LSX-2611-0001, thước laser')$$);
select pg_temp.ok((select od_src from master.die_reqs(pg_temp.v('her')) where kind = 'DV') = 'thực tế'
   and (select req from master.die_reqs(pg_temp.v('her')) where kind = 'DV') = 7.08
   and (select od_mm from master.spec_results where spec_id = pg_temp.v('her')) = 6.7,
  'Đã đo: khuôn vỏ theo OD thực tế 7,08; OD tối ưu 6,70 giữ nguyên');
select pg_temp.ok((select die_id from master.die_match(pg_temp.v('her')) where kind = 'DV') is distinct from pg_temp.v('odv0')
   or (select size from master.dies where id = pg_temp.v('odv0')) between 7.0 and 7.16,
  'OD thực tế đổi thì khuôn vỏ được chọn lại theo OD thực tế');
select pg_temp.ok(exists (select 1 from core.audit_log where action = 'OD_ACTUAL' and row_id = pg_temp.v('her')::text), 'Nhật ký OD thực tế');

-- 4. Quyền xem
select pg_temp.as_user('D_NONE');
select pg_temp.as_api($$insert into t select 'n_none', null where (select count(*) from app.spec_dies(pg_temp.v('her'))) = 0 and (select count(*) from app.die_list()) = 0$$);
select pg_temp.ok(exists (select 1 from t where k = 'n_none'), 'Người không có vai trò không xem được khuôn');
select pg_temp.as_user('D_SXKH');
select pg_temp.as_api($$insert into t select 'n_sxkh', null where (select count(*) from app.spec_dies(pg_temp.v('her'))) = 6 and (select count(*) from app.die_list()) > 100$$);
select pg_temp.ok(exists (select 1 from t where k = 'n_sxkh'), 'Kế hoạch SX xem được khuôn của spec và danh mục');

-- 5. Alarm theo kế hoạch tháng (trả OD thực tế về trống: khuôn vỏ theo OD tối ưu)
update master.spec_results set od_actual_mm = null where spec_id = pg_temp.v('her');
reset role;
select pg_temp.as_user('D_SXKH');
select pg_temp.as_api($$insert into t select 'alarm0', null from (select app.die_alarm_count() n) x where n >= 0$$);
create temp table a0 as select app.die_alarm_count() n;  -- dưới quyền chủ sở hữu: 0 (không có vai trò)
select pg_temp.ok((select n from a0) = 0, 'Alarm khuôn = 0 với người không có quyền xem');
insert into plan.production_plans (plan_no, period_label, status) values ('KH-THU-KHUON', 'Thử khuôn', 'DRAFT');
insert into t select 'plan', id from plan.production_plans where plan_no = 'KH-THU-KHUON';
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, m_per_pack, pack_type, brand)
select pg_temp.v('plan'), p.id, s.id, 2000, coalesce(s.m_per_pack, 500), coalesce(s.pack_type, 'REEL_W'), coalesce(s.brand, p.default_brand)
  from master.products p join master.product_specs s on s.id = p.current_spec_id where p.code = 'HER15U2LZ';
insert into t select 'line', id from plan.plan_lines where plan_id = pg_temp.v('plan');
create temp table cnt (k text primary key, n int);
grant all on cnt to authenticated;
select pg_temp.as_user('D_SXKH');
select pg_temp.as_api($$insert into cnt values ('a1', app.die_alarm_count())$$);
select pg_temp.as_api($$insert into cnt select 'gap', count(*) from app.die_gaps() where product_code = 'HER15U2LZ' and in_plan$$);
select pg_temp.ok((select n from cnt where k = 'gap') >= 1 and (select n from cnt where k = 'a1') >= 1,
  'Mã HER15U2LZ trong kế hoạch tháng, khuôn còn Cần đặt → Alarm thiếu khuôn');
select pg_temp.as_api($$insert into cnt select 'menu', (app.menu_counts()->>'die_alarm')::int$$);
select pg_temp.ok((select n from cnt where k = 'menu') = (select n from cnt where k = 'a1'), 'Số Alarm khuôn có trong số đếm menu');
select pg_temp.as_api($$insert into cnt select 'day', count(*) from app.die_day_check(pg_temp.v('plan'), array['HER15U2LZ'])$$);
select pg_temp.ok((select n from cnt where k = 'day') = (select n from cnt where k = 'gap'), 'Lệnh SX ngày: báo đủ các khuôn chưa có của mã chạy trong ngày');
select pg_temp.as_api($$insert into t select 'khd', null where app.kh_dies(pg_temp.v('plan'))->'lines'->(pg_temp.v('line')::text)->'CD5' is not null
                                                         and (app.kh_dies(pg_temp.v('plan'))->'qty'->>'TX-5.85')::int = 1$$);
select pg_temp.ok(exists (select 1 from t where k = 'khd'), 'Lịch máy nhận khuôn từng dòng theo công đoạn + số bộ khuôn sẵn có');

-- 6. Đổi trạng thái: nhận khuôn
insert into t select 'd' || m.kind, m.die_id from master.die_match(pg_temp.v('her')) m where not m.ready;
select pg_temp.as_user('D_MUANV');
select pg_temp.blocked($$select app.die_set_status(pg_temp.v('dTS'), 'AVAILABLE', null)$$, 'TP KT/QA', 'NV mua không đổi trạng thái khuôn');
-- 7. Đặt khuôn
select pg_temp.as_user('D_KTTP');
select pg_temp.blocked($$select app.die_order(array[pg_temp.v('dTS')], current_date + 10, 'Đặt khuôn')$$, 'NV mua', 'TP KT/QA không tự lập đề xuất mua khuôn');
select pg_temp.as_user('D_MUANV');
select pg_temp.blocked($$select app.die_order(array[(select id from master.dies where code = 'KB-1.35')], current_date + 10, 'x')$$, 'không đặt lại', 'Khuôn có sẵn không đặt lại');
select pg_temp.as_api($$insert into t select 'pr', app.die_order(array[pg_temp.v('dTS'), pg_temp.v('dDS')], current_date + 10, 'Đặt khuôn silicone HER15')$$);
select pg_temp.ok((select count(*) from purchase.pr_lines l join master.materials m on m.id = l.material_id
                    where l.pr_id = pg_temp.v('pr') and m.group_code = 'TOOLING' and m.code like 'KH-%') = 2
   and (select pr_kind from purchase.purchase_requests where id = pg_temp.v('pr')) = 'BO_SUNG'
   and (select bool_and(status = 'ORDERED' and pr_id = pg_temp.v('pr')) from master.dies where id in (pg_temp.v('dTS'), pg_temp.v('dDS'))),
  'NV mua đặt khuôn: đề xuất mua bổ sung 2 dòng vật tư dụng cụ KH-…, khuôn chuyển Đã đặt');
select pg_temp.as_user('D_KTTP');
select pg_temp.blocked($$select app.die_set_status(pg_temp.v('dTS'), 'WORN', '')$$, 'lý do', 'Báo khuôn mòn phải ghi lý do');
select pg_temp.as_api($$select app.die_set_status(id, 'AVAILABLE', 'Đã nhận khuôn') from master.dies where id in (select v from t where k like 'd%' and v is not null)$$);
select pg_temp.ok((select bool_and(status = 'AVAILABLE' and in_service_at is not null) from master.dies where id in (select v from t where k like 'd%' and v is not null)),
  'TP KT/QA nhận khuôn: Có sẵn, bắt đầu tính km');
select pg_temp.ok(not exists (select 1 from master.die_match(pg_temp.v('her')) where not ready), 'HER15U2LZ đủ khuôn sẵn');
select pg_temp.as_user('D_SXKH');
select pg_temp.as_api($$insert into cnt values ('a2', app.die_alarm_count())$$);
select pg_temp.ok((select n from cnt where k = 'a2') = (select n from cnt where k = 'a1') - 1, 'Đủ khuôn thì mã hết Alarm');
select pg_temp.as_user('D_SXTP');
select pg_temp.as_api($$select app.die_set_status(pg_temp.v('dTS'), 'WORN', 'Lỗ khuôn mòn, OD lõi lệch')$$);
select pg_temp.ok(exists (select 1 from wf.notifications n join core.profiles p on p.id = n.user_id
                           where p.employee_code = 'D_KTTP' and n.title like 'Khuôn % mòn'),
  'TP SX báo khuôn mòn: báo TP KT/QA (khuôn mòn vẫn dùng được, chờ thay)');

-- 8. Thêm / sửa khuôn, quy tắc
select pg_temp.as_user('D_SXTP');
select pg_temp.blocked($$select app.die_save(null, '{"kind":"DV","size":"9.99"}', null)$$, 'TP KT/QA', 'TP SX không sửa danh mục khuôn');
select pg_temp.as_user('D_KTTP');
select pg_temp.as_api($$insert into t select 'new', app.die_save(null, '{"kind":"DV","size":"9.99","l_mm":"5.0","location":"Tủ khuôn A"}', null)$$);
select pg_temp.ok((select code = 'DV-9.99' and status = 'NEEDED' and price is not null from master.dies where id = pg_temp.v('new')), 'TP KT/QA thêm khuôn, MES tự đặt mã + giá theo bảng giá');
select pg_temp.blocked($$select app.die_save(null, '{"kind":"DV","size":"9.99"}', null)$$, 'đã có', 'Trùng mã khuôn bị chặn');
select pg_temp.blocked($$select app.die_save(pg_temp.v('new'), '{"kind":"DV","size":"9.98"}', '')$$, 'lý do', 'Sửa khuôn phải ghi lý do');
select pg_temp.blocked($$select app.die_rules_save('[{"kind":"TS","clr_min":"0.3"}]', 'thử')$$, 'không hợp lệ', 'Quy tắc sai (khe hở nhỏ nhất > chuẩn) bị chặn');
select pg_temp.as_api($$select app.die_rules_save('[{"kind":"DV","mat":"LSZH","tol":"0.10"}]', 'Thử nới dung sai')$$);
select pg_temp.ok((select tol from master.die_rules where kind = 'DV' and mat = 'LSZH') = 0.10, 'TP KT/QA sửa dung sai khuôn vỏ');

-- 9. Đề xuất cho mã mới chưa có khuôn
update master.spec_results set od_actual_mm = 30, od_actual_note = 'thử' where spec_id = pg_temp.v('her');
select pg_temp.as_api($$insert into cnt select 'prop', count(*) from app.die_propose() where codes like '%HER15U2LZ%' and kind = 'DV'$$);
select pg_temp.ok((select n from cnt where k = 'prop') = 1, 'OD thực tế 30 mm: MES đề xuất khuôn vỏ mới');
select pg_temp.as_user('D_SXKH');
select pg_temp.blocked($$select app.die_add_proposals()$$, 'TP KT/QA', 'Kế hoạch SX không thêm khuôn đề xuất');
select pg_temp.as_user('D_KTTP');
select pg_temp.as_api($$insert into cnt select 'added', app.die_add_proposals()$$);
select pg_temp.ok((select n from cnt where k = 'added') = 1 and exists (select 1 from master.dies where code = 'DV-30.00' and status = 'NEEDED'),
  'TP KT/QA thêm khuôn MES đề xuất vào danh mục (Cần đặt)');

-- 10. Danh mục, km, phút đổi máy, quyền anon
select pg_temp.as_api($$insert into cnt select 'list', count(*) from app.die_list() where products > 0$$);
select pg_temp.ok((select n from cnt where k = 'list') > 50, 'Danh mục khuôn: số mã dùng từng khuôn');
select pg_temp.ok(exists (select 1 from master.changeover_rules where code = 'SH_PRINT' and op_code = 'CD5'), 'Phút đổi máy "đổi mã cùng khuôn vỏ"');
select pg_temp.ok(not has_function_privilege('anon', 'app.die_list()', 'execute') and not has_function_privilege('anon', 'app.die_order(uuid[], date, text)', 'execute')
   and not has_function_privilege('authenticated', 'master.die_match(uuid)', 'execute')
   and not has_function_privilege('authenticated', 'master.die_alerts()', 'execute'),
  'anon không gọi được hàm khuôn; hàm nội bộ không mở cho authenticated');
select pg_temp.ok(exists (select 1 from core.pages where key = 'may-khuon') and exists (select 1 from core.role_pages where page_key = 'may-khuon' and role_code = 'MUA_NV'),
  'Mục menu Khuôn (Quản lý máy), NV mua vào được');
reset role;
select set_config('request.jwt.claim.sub', '', true);
insert into cnt select 'alert', master.die_alerts();
select pg_temp.ok((select n from cnt where k = 'alert') >= 1 and exists (select 1 from inv.alert_log where kind = 'DIE')
   and exists (select 1 from wf.notifications n join core.profiles p on p.id = n.user_id where p.employee_code = 'D_KTTP' and n.title like 'Thiếu khuôn%'),
  'Cảnh báo hằng ngày mã thiếu khuôn: báo TP KT/QA');
select pg_temp.ok(master.die_alerts() = 0, 'Cảnh báo thiếu khuôn không lặp trong tuần');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
