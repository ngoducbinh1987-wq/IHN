-- Kiểm thử migration 20261026008600: Quản trị xóa chứng từ Nháp – kế hoạch từng duyệt có đề xuất hiệu chỉnh, đề xuất hiệu chỉnh nháp.
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
with u(code) as (values ('X_ADM'),('X_SXTP')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('X_ADM','ADMIN'),('X_SXTP','SX_TP')) u(code, role) on u.code = p.employee_code;

-- Kế hoạch KH-X1 từng duyệt: có đề xuất hiệu chỉnh đã áp (bỏ một dòng) và một đề xuất nháp; sau đó mở lại về Nháp
insert into t select 'spec', p.current_spec_id from master.products p where p.current_spec_id is not null order by p.code limit 1;
insert into plan.production_plans (plan_no, period_label) values ('KH-X1', 'Thử xóa nháp'), ('KH-X2', 'Có đơn mua');
insert into t select plan_no, id from plan.production_plans where plan_no in ('KH-X1', 'KH-X2');
insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, m_per_pack, pack_type, brand)
select pp.id, s.product_id, s.id, q, 500, 'Bobin gỗ', 'KAVIX' from plan.production_plans pp, master.product_specs s, (values (1000), (2000)) x(q)
 where pp.plan_no in ('KH-X1', 'KH-X2') and s.id = pg_temp.v('spec');
insert into plan.plan_adjustments (adj_no, plan_id, status, reason, applied_at) values
  ('PDC-X1-1', pg_temp.v('KH-X1'), 'APPROVED', 'Bỏ dòng', now()),
  ('PDC-X1-2', pg_temp.v('KH-X1'), 'DRAFT', 'Nháp', null),
  ('PDC-X2-1', pg_temp.v('KH-X2'), 'DRAFT', 'Nháp kế hoạch 2', null),
  ('PDC-X2-2', pg_temp.v('KH-X2'), 'APPROVED', 'Đã áp', now());
insert into t select adj_no, id from plan.plan_adjustments where adj_no like 'PDC-X%';
insert into plan.plan_adjustment_lines (adj_id, line_no, kind, plan_line_id, product_id, qty_m, old_qty_m)
select a.id, 1, 'REMOVE', l.id, l.product_id, 0, l.qty_m
  from plan.plan_adjustments a join plan.plan_lines l on l.plan_id = a.plan_id and l.qty_m = 1000
 where a.adj_no in ('PDC-X1-1', 'PDC-X1-2', 'PDC-X2-1');
insert into purchase.purchase_orders (po_no, supplier_id, plan_id)
select 'PO-X2', id, pg_temp.v('KH-X2') from core.partners order by code limit 1;

-- Trước khi sửa: xóa thẳng kế hoạch bị chặn vì dòng hiệu chỉnh trỏ vào dòng kế hoạch
do $$ begin
  begin
    delete from plan.production_plans where id = pg_temp.v('KH-X1');
    raise exception 'FAIL: lẽ ra khóa ngoại chặn';
  exception when foreign_key_violation then null;
  end;
end $$;
select pg_temp.ok(true, 'Tái hiện lỗi: kế hoạch có dòng hiệu chỉnh trỏ vào thì xóa thẳng bị khóa ngoại chặn');

-- ================================================================ Quyền
select pg_temp.as_user('X_SXTP');
select pg_temp.blocked($q$select app.admin_doc('PLAN', pg_temp.v('KH-X1'), 'delete', 'xóa')$q$, 'Chỉ Quản trị', 'TP SX không dùng được xóa của Quản trị');
select pg_temp.as_user('X_ADM');
select pg_temp.blocked($q$select app.admin_doc('PLAN', pg_temp.v('KH-X1'), 'delete', ' ')$q$, 'lý do', 'Xóa bắt buộc lý do');

-- ================================================================ Đề xuất hiệu chỉnh
select pg_temp.blocked($q$select app.admin_doc('PLAN_ADJ', pg_temp.v('PDC-X2-2'), 'delete', 'xóa')$q$, 'đã áp vào kế hoạch',
  'Đề xuất hiệu chỉnh đã duyệt (đã áp) không xóa được');
select pg_temp.as_api($q$select app.admin_doc('PLAN_ADJ', pg_temp.v('PDC-X2-1'), 'delete', 'Lập nhầm')$q$);
select pg_temp.ok(not exists (select 1 from plan.plan_adjustments where id = pg_temp.v('PDC-X2-1'))
  and not exists (select 1 from plan.plan_adjustment_lines where adj_id = pg_temp.v('PDC-X2-1'))
  and exists (select 1 from core.audit_log where action = 'ADMIN_DELETE' and row_id = pg_temp.v('PDC-X2-1')::text
               and new_data ->> 'doc_no' = 'PDC-X2-1' and jsonb_array_length(old_data -> 'lines') = 1),
  'Quản trị xóa đề xuất hiệu chỉnh nháp kèm dòng, nhật ký giữ bản sao');

-- ================================================================ Kế hoạch
select pg_temp.blocked($q$select app.admin_doc('PLAN', pg_temp.v('KH-X2'), 'delete', 'xóa')$q$, 'đã sinh đơn mua PO-X2',
  'Kế hoạch đã sinh đơn mua chưa hủy: chặn, báo số đơn');
select pg_temp.as_api($q$select app.admin_doc('PLAN', pg_temp.v('KH-X1'), 'delete', 'Lập lại kế hoạch tháng')$q$);
select pg_temp.ok(not exists (select 1 from plan.production_plans where id = pg_temp.v('KH-X1'))
  and not exists (select 1 from plan.plan_adjustments where plan_id = pg_temp.v('KH-X1')),
  'Quản trị xóa kế hoạch Nháp từng có đề xuất hiệu chỉnh: xóa cả đề xuất hiệu chỉnh của kế hoạch');
select pg_temp.ok((select jsonb_array_length(old_data -> 'adjustments') = 2 and jsonb_array_length(old_data -> 'lines') = 2
                     and old_data #>> '{doc,plan_no}' = 'KH-X1'
                   from core.audit_log where action = 'ADMIN_DELETE' and row_id = pg_temp.v('KH-X1')::text),
  'Nhật ký giữ bản sao kế hoạch, 2 dòng và 2 đề xuất hiệu chỉnh');

-- Đơn mua hủy rồi thì xóa được kế hoạch
update purchase.purchase_orders set status = 'CANCELLED' where po_no = 'PO-X2';
select pg_temp.as_api($q$select app.admin_doc('PLAN', pg_temp.v('KH-X2'), 'delete', 'Đơn mua đã hủy')$q$);
select pg_temp.ok(not exists (select 1 from plan.production_plans where id = pg_temp.v('KH-X2'))
  and (select plan_id is null from purchase.purchase_orders where po_no = 'PO-X2'),
  'Đơn mua đã hủy: xóa được kế hoạch, đơn mua giữ lại (bỏ liên kết kế hoạch)');

select pg_temp.ok(not has_function_privilege('anon', 'app.admin_doc(text,uuid,text,text)', 'execute'), 'Khách (anon) không gọi được');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
