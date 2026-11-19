-- Kiểm thử migration 20261026010300_pr_kind_ccdc_dates: loại đề xuất "Mua công cụ dụng cụ, máy, trang thiết bị",
-- nhãn loại NVL, vật tư đúng loại đề xuất, ngày dd/mm/yyyy trong hàm database.
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_msg; end if;
  insert into r(msg) values (p_msg);
end $$;
-- Chạy p_sql dưới tài khoản p_code, trả thông báo lỗi (null khi chạy được)
create function pg_temp.as_user(p_code text, p_sql text) returns text language plpgsql as $$
declare v_id uuid := (select id from core.profiles where employee_code = p_code); v_err text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_id::text, true);
  begin
    execute 'set local role authenticated';
    execute p_sql;
    execute 'reset role';
  exception when others then
    get stacked diagnostics v_err = message_text;
    execute 'reset role';
  end;
  return v_err;
end $$;
set client_min_messages = notice;

with u(code) as (values ('PK_MUA'), ('PK_SX')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('PK_MUA', 'MUA_NV'), ('PK_SX', 'SX_TP')) u(code, role) on u.code = p.employee_code;

insert into master.materials (code, name, group_code, uom, loss_rate, active)
values ('ZZ-MAYHAN', 'Máy hàn thử', 'ASSET', 'cái', 0, true), ('ZZ-NVL', 'Vật tư NVL thử', 'CONDUCTOR', 'kg', 0, true);
insert into master.materials (code, name, group_code, uom, loss_rate, active)
select 'BOB-630', 'Bobin nhựa 630', 'TOOLING', 'cái', 0, true where not exists (select 1 from master.materials where code = 'BOB-630');

create temp table t (k text primary key, v text);
grant all on t to authenticated;

do $$
declare e text; v_pr uuid; v_kind text;
begin
  -- 1. Nhãn loại đề xuất
  perform pg_temp.ok(purchase.pr_kind_label('BO_SUNG') = 'Mua bổ sung nguyên vật liệu'
    and purchase.pr_kind_label('TICH_TRU') = 'Tích trữ nguyên vật liệu'
    and purchase.pr_kind_label('TOI_UU') = 'Tối ưu giá nguyên vật liệu'
    and purchase.pr_kind_label('CCDC') = 'Mua công cụ dụng cụ, máy, trang thiết bị'
    and purchase.pr_kind_label('KE_HOACH') = 'Mua NVL theo kế hoạch tháng', 'Nhãn loại đề xuất ghi rõ nguyên vật liệu / công cụ dụng cụ');
  perform pg_temp.ok((select count(*) from master.material_groups where code in ('TOOLING', 'ASSET')) = 2, 'Có nhóm Công cụ dụng cụ và Máy, trang thiết bị, tài sản');

  -- 2. TP SX lập đề xuất mua công cụ dụng cụ (bobin, máy hàn)
  e := pg_temp.as_user('PK_SX', $q$insert into t values ('ccdc', app.create_pr(null, 'Mua bobin 800 và máy hàn',
        '[{"material_code":"BOB-630","qty":10},{"material_code":"ZZ-MAYHAN","qty":1}]'::jsonb, 'CCDC')::text)$q$);
  perform pg_temp.ok(e is null, 'TP SX lập đề xuất mua công cụ dụng cụ, máy (' || coalesce(e, 'ok') || ')');
  v_pr := (select v from t where k = 'ccdc')::uuid;
  perform pg_temp.ok((select pr_kind from purchase.purchase_requests where id = v_pr) = 'CCDC', 'Đề xuất lưu loại CCDC');
  perform pg_temp.ok((select pr_kind_label from app.v_prs where id = v_pr) = 'Mua công cụ dụng cụ, máy, trang thiết bị', 'Danh sách đề xuất hiện nhãn loại mới');

  -- 3. Đề xuất CCDC không nhận NVL; đề xuất NVL không nhận công cụ dụng cụ
  e := pg_temp.as_user('PK_SX', $q$select app.create_pr(null, 'Sai loại', '[{"material_code":"ZZ-NVL","qty":5}]'::jsonb, 'CCDC')$q$);
  perform pg_temp.ok(e like '%nguyên vật liệu%', 'Đề xuất CCDC chặn vật tư NVL (' || coalesce(e, 'không chặn') || ')');
  e := pg_temp.as_user('PK_SX', $q$select app.create_pr(null, 'Sai loại', '[{"material_code":"BOB-630","qty":5}]'::jsonb, 'BO_SUNG')$q$);
  perform pg_temp.ok(e like '%Mua công cụ dụng cụ, máy, trang thiết bị%', 'Đề xuất mua bổ sung NVL chặn bobin, gợi ý đúng loại (' || coalesce(e, 'không chặn') || ')');
  e := pg_temp.as_user('PK_SX', format($q$select app.save_pr_line(%L, 'ZZ-NVL', 3)$q$, v_pr));
  perform pg_temp.ok(e like '%nguyên vật liệu%', 'Thêm dòng NVL vào đề xuất CCDC bị chặn');

  -- 4. Đổi loại: CCDC có dòng công cụ không đổi sang loại NVL
  e := pg_temp.as_user('PK_SX', format($q$select app.set_pr_kind(%L, 'BO_SUNG')$q$, v_pr));
  perform pg_temp.ok(e like '%Không đổi được sang loại%', 'Đề xuất CCDC không đổi sang mua bổ sung NVL khi còn dòng công cụ');

  -- 5. Loại NVL vẫn chạy như cũ: mua bổ sung NVL, NV mua đổi sang tối ưu giá NVL; TP SX không lập tích trữ
  e := pg_temp.as_user('PK_MUA', $q$insert into t values ('nvl', app.create_pr(null, 'Bù đồng thiếu', '[{"material_code":"ZZ-NVL","qty":5}]'::jsonb, 'BO_SUNG')::text)$q$);
  perform pg_temp.ok(e is null, 'NV mua lập đề xuất mua bổ sung NVL (' || coalesce(e, 'ok') || ')');
  e := pg_temp.as_user('PK_MUA', format($q$select app.set_pr_kind(%L, 'TOI_UU')$q$, (select v from t where k = 'nvl')));
  v_kind := (select pr_kind from purchase.purchase_requests where id = (select v from t where k = 'nvl')::uuid);
  perform pg_temp.ok(e is null and v_kind = 'TOI_UU', 'NV mua đổi sang tối ưu giá NVL');
  e := pg_temp.as_user('PK_MUA', format($q$select app.set_pr_kind(%L, 'CCDC')$q$, (select v from t where k = 'nvl')));
  perform pg_temp.ok(e like '%Không đổi được sang loại%', 'Đề xuất có dòng NVL không đổi sang loại công cụ dụng cụ');
  e := pg_temp.as_user('PK_SX', $q$select app.create_pr(null, 'Tích trữ', '[{"material_code":"ZZ-NVL","qty":5}]'::jsonb, 'TICH_TRU')$q$);
  perform pg_temp.ok(e like '%NV mua hoặc TP Mua%', 'TP SX không lập đề xuất tích trữ NVL (giữ như cũ)');
  e := pg_temp.as_user('PK_SX', $q$select app.create_pr(null, 'X', '[{"material_code":"ZZ-NVL","qty":5}]'::jsonb, 'KE_HOACH')$q$);
  perform pg_temp.ok(e like '%Chọn loại đề xuất%', 'Không lập tay loại theo kế hoạch tháng');

  -- 6. Ngày trong thông báo, câu báo lỗi của database có năm
  perform pg_temp.ok(not exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace
      where s.nspname in ('app', 'plan', 'purchase', 'inv', 'mfg', 'qa', 'wf', 'core', 'master', 'sales', 'cost', 'iot', 'integ')
        and p.prosrc ~ $r$'(HH24:MI )?DD/MM( HH24:MI)?'|'HH24:MI DD/MM/YYYY'$r$), 'Không còn hàm hiện ngày thiếu năm (dd/mm) hoặc giờ trước ngày');
  perform pg_temp.ok((select count(*) from pg_proc where prosrc like $s$%'DD/MM/YYYY%$s$) >= 40, 'Các hàm thông báo dùng dd/mm/yyyy');
  perform pg_temp.ok(to_char(date '2026-11-05', 'DD/MM/YYYY') = '05/11/2026', 'Định dạng dd/mm/yyyy có số 0 đầu');
end $$;

do $$ begin
  raise exception 'KET_QUA_OK %', (select count(*) from r) || ' kiểm tra đạt: ' || (select string_agg(msg, ' | ' order by n) from r);
end $$;
