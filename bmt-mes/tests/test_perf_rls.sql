-- Kiểm thử migration 20261026009600_perf_rls_menu_index: RLS tính hàm kiểm quyền một lần mỗi câu truy vấn,
-- app.menu_counts() gộp số đếm menu (đúng bằng từng truy vấn cũ theo RLS từng người), index trùng / khóa ngoại thiếu index.
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_msg; end if;
  insert into r(msg) values (p_msg);
end $$;
set client_min_messages = notice;

-- Người dùng thử
with u(code) as (values ('PF_BGD'),('PF_VH'),('PF_MUATP'),('PF_KTKHO'),('PF_KD'),('PF_NONE')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('PF_BGD','BGD'),('PF_VH','VAN_HANH'),('PF_MUATP','MUA_TP'),
  ('PF_KTKHO','KT_KHO'),('PF_KD','KD_NV')) u(code, role) on u.code = p.employee_code;

-- Một lô chờ QC + một đơn mua nháp để số đếm khác 0 với người có quyền
insert into inv.lots (lot_no, item_kind, material_id, uom, qc_status)
select 'PF-LOT-1', 'MAT', id, uom, 'PENDING' from master.materials where active and not is_scrap order by code limit 1;
insert into purchase.purchase_orders (po_no, status, kind, source, order_date)
values ('PF-PO-1', 'DRAFT', 'TONG', 'MANUAL', (now() at time zone 'Asia/Ho_Chi_Minh')::date);

do $$
declare
  scopes constant text[] := array['core','master','sales','plan','purchase','inv','mfg','qa','cost','wf','iot','integ','app'];
  bad text; n int; u record; mc jsonb; d_turn bigint; d_unread bigint; d_maint bigint; d_qc bigint; d_po bigint;
  d_safety int; d_alarm int; plan text := ''; ln text;
begin
  -- 1. RLS: mọi lời gọi hàm kiểm quyền đã bọc (select …)
  select count(*) into n
  from pg_policies p,
       regexp_matches(coalesce(p.qual, '') || ' ' || coalesce(p.with_check, ''),
                      '(?<!SELECT )(?:core\.has_perm|core\.has_role|app\.kh_can_view|app\.can_see_loss|auth\.uid)\(', 'g')
  where p.schemaname = any(scopes);
  perform pg_temp.ok(n = 0, 'RLS: không còn lời gọi hàm kiểm quyền tính từng dòng (' || n || ')');
  select count(*) into n from pg_policies p
  where p.schemaname = any(scopes) and coalesce(p.qual, '') || coalesce(p.with_check, '') ~ 'SELECT core\.has_perm\(';
  perform pg_temp.ok(n > 200, 'RLS: ' || n || ' quy tắc dùng (select core.has_perm(…))');

  -- 2. Không còn khóa ngoại thiếu index
  select string_agg(c.conrelid::regclass || '.' || c.conname, ', ') into bad
  from pg_constraint c join pg_class t on t.oid = c.conrelid join pg_namespace s on s.oid = t.relnamespace
  where c.contype = 'f' and t.relkind = 'r' and s.nspname = any(scopes)
    and not exists (select 1 from pg_index i where i.indrelid = c.conrelid
      and (string_to_array(i.indkey::text, ' ')::int2[])[1:array_length(c.conkey, 1)] @> c.conkey
      and (string_to_array(i.indkey::text, ' ')::int2[])[1:array_length(c.conkey, 1)] <@ c.conkey);
  perform pg_temp.ok(bad is null, 'Mọi khóa ngoại có index' || coalesce(' – thiếu: ' || bad, ''));

  -- 3. Không còn index trùng (cùng bảng, cột, điều kiện, biểu thức)
  select string_agg(x, '; ') into bad from (
    select string_agg(i.indexrelid::regclass::text, ' = ') x
    from pg_index i join pg_class t on t.oid = i.indrelid join pg_namespace s on s.oid = t.relnamespace
    where s.nspname = any(scopes)
    group by i.indrelid, i.indkey::text, i.indclass::text, coalesce(pg_get_expr(i.indpred, i.indrelid), ''),
             coalesce(pg_get_expr(i.indexprs, i.indrelid), ''), i.indisunique
    having count(*) > 1) q;
  perform pg_temp.ok(bad is null, 'Không còn index trùng' || coalesce(' – ' || bad, ''));

  -- 4. Quyền gọi app.menu_counts
  perform pg_temp.ok(has_function_privilege('authenticated', 'app.menu_counts()', 'execute')
                     and not has_function_privilege('anon', 'app.menu_counts()', 'execute')
                     and not (select prosecdef from pg_proc where oid = 'app.menu_counts()'::regprocedure),
                     'menu_counts: người đăng nhập gọi được, anon không, chạy theo quyền người gọi (RLS)');

  -- 5. menu_counts = từng truy vấn cũ của web, theo RLS của từng người
  for u in select p.id, p.employee_code from core.profiles p where p.employee_code like 'PF\_%' order by 2 loop
    perform set_config('request.jwt.claims', json_build_object('sub', u.id, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', u.id::text, true);
    execute 'set local role authenticated';
    mc := app.menu_counts();
    select count(*) into d_turn from app.v_approvals where my_turn;
    select count(*) into d_unread from app.v_notifications where read_at is null;
    select count(*) into d_maint from app.v_maint_plans where active and state = 'OVERDUE' and open_wo is null;
    select count(*) into d_qc from inv.lots where qc_status = 'PENDING';
    d_safety := app.safety_below_count();
    select count(*) into d_po from purchase.purchase_orders where status = 'DRAFT';
    d_alarm := app.machine_param_alarm_count();
    execute 'reset role';
    perform pg_temp.ok((mc ->> 'my_turn')::bigint = d_turn and (mc ->> 'unread')::bigint = d_unread
                       and (mc ->> 'maint_overdue')::bigint = d_maint and (mc ->> 'qc_wait')::bigint = d_qc
                       and (mc ->> 'safety_below')::int = d_safety and (mc ->> 'po_draft')::bigint = d_po
                       and (mc ->> 'param_alarm')::int = d_alarm,
                       u.employee_code || ': menu_counts khớp từng số đếm ' || mc::text);
    if u.employee_code = 'PF_KTKHO' then
      perform pg_temp.ok(d_qc >= 1, 'PF_KTKHO (Kế toán kho) thấy lô chờ QC: ' || d_qc);
    elsif u.employee_code = 'PF_MUATP' then
      perform pg_temp.ok(d_po >= 1, 'PF_MUATP (TP Mua) thấy đơn mua nháp: ' || d_po);
    elsif u.employee_code = 'PF_NONE' then
      perform pg_temp.ok(d_qc = 0 and d_po = 0 and d_turn = 0, 'PF_NONE (không vai trò): RLS vẫn chặn, mọi số = 0');
    end if;
  end loop;

  -- 6. Kế hoạch truy vấn: kiểm quyền thành InitPlan (một lần), không lọc từng dòng
  perform set_config('request.jwt.claims', json_build_object('sub', (select id from core.profiles where employee_code = 'PF_BGD'), 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  for ln in execute 'explain (costs off) select * from master.materials' loop plan := plan || ln || E'\n'; end loop;
  select count(*) into n from inv.lots;
  execute 'reset role';
  perform pg_temp.ok(plan ~ 'InitPlan' or plan ~ '\(InitPlan', 'master.materials: kiểm quyền chạy một lần (InitPlan)');
  perform pg_temp.ok(n >= 1, 'PF_BGD (Ban giám đốc) vẫn đọc được lô qua RLS: ' || n);
end $$;

do $$ begin
  raise exception 'KET_QUA_OK %', (select count(*) from r) || ' kiểm tra đạt: ' || (select string_agg(msg, ' | ' order by n) from r);
end $$;
rollback;
