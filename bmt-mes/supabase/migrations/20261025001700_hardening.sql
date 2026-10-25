-- BMT MES · 1700 · Gia cố sau kiểm tra trên Supabase (25/10/2026)
-- 1. Phân vùng dữ liệu máy: chặn đọc trực tiếp (trước đây vượt qua RLS của bảng cha)
-- 2. Thay view security definer bằng hàm có kiểm tra quyền xem giá
-- 3. Cố định search_path cho mọi hàm của hệ thống
-- 4. RLS gọi auth.uid() một lần cho mỗi truy vấn
-- 5. Index cho mọi khóa ngoại chưa có index

-- ---------------------------------------------------------------------------
-- 1. Phân vùng iot.telemetry
-- ---------------------------------------------------------------------------
create or replace function iot.lock_partition(p_table text) returns void
language plpgsql as $$
begin
  execute format('alter table iot.%I enable row level security', p_table);
  execute format('revoke all on iot.%I from anon, authenticated', p_table);
end $$;

create or replace function iot.ensure_partitions(p_days_ahead int default 7) returns void
language plpgsql as $$
declare d date; tbl text;
begin
  for d in select generate_series(current_date - 1, current_date + p_days_ahead, interval '1 day')::date loop
    tbl := 'telemetry_' || to_char(d, 'YYYYMMDD');
    if to_regclass('iot.' || tbl) is null then
      execute format('create table iot.%I partition of iot.telemetry for values from (%L) to (%L)', tbl, d, d + 1);
      perform iot.lock_partition(tbl);
    end if;
  end loop;
end $$;

select iot.lock_partition(c.relname)
from pg_inherits i join pg_class c on c.oid = i.inhrelid
where i.inhparent = 'iot.telemetry'::regclass;

-- ---------------------------------------------------------------------------
-- 2. Giá trị kho: hàm thay cho view security definer
-- ---------------------------------------------------------------------------
drop view if exists cost.v_stock_moves_valued;

create or replace function cost.stock_moves_valued(p_from timestamptz default null, p_to timestamptz default null)
returns setof inv.stock_moves
language sql stable security definer set search_path = pg_catalog, public as $$
  select sm.* from inv.stock_moves sm
  where core.can_see_price()
    and (p_from is null or sm.moved_at >= p_from)
    and (p_to is null or sm.moved_at < p_to)
$$;
revoke all on function cost.stock_moves_valued(timestamptz, timestamptz) from public, anon;
grant execute on function cost.stock_moves_valued(timestamptz, timestamptz) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. search_path cố định cho mọi hàm (mọi tham chiếu bảng trong hàm đã ghi rõ schema)
-- ---------------------------------------------------------------------------
do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p
           where p.pronamespace::regnamespace::text in ('core','master','sales','plan','purchase','inv','mfg','qa','cost','wf','iot','integ')
             and p.prokind = 'f' loop
    execute format('alter function %s set search_path = pg_catalog, public', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 4. RLS: (select auth.uid()) để Postgres tính một lần mỗi truy vấn
-- ---------------------------------------------------------------------------
drop policy p_select on core.profiles;
create policy p_select on core.profiles for select to authenticated
  using (id = (select auth.uid()) or core.has_perm('admin', 'view') or core.has_perm('approval', 'view'));

drop policy p_select on core.user_roles;
create policy p_select on core.user_roles for select to authenticated
  using (user_id = (select auth.uid()) or core.has_perm('admin', 'view'));

drop policy p_select on wf.notifications;
drop policy p_update on wf.notifications;
create policy p_select on wf.notifications for select to authenticated using (user_id = (select auth.uid()));
create policy p_update on wf.notifications for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

drop policy p_select on wf.approval_requests;
create policy p_select on wf.approval_requests for select to authenticated
  using (submitted_by = (select auth.uid()) or core.has_perm('approval', 'view'));

drop policy p_select on inv.stock_balances;
create policy p_select on inv.stock_balances for select to authenticated
  using (core.has_perm('inventory', 'view')
         and (not exists (select 1 from core.user_scopes where user_id = (select auth.uid()) and scope_type = 'WAREHOUSE')
              or exists (select 1 from core.user_scopes where user_id = (select auth.uid()) and scope_type = 'WAREHOUSE' and scope_id = warehouse_id)));

-- ---------------------------------------------------------------------------
-- 5. Index cho khóa ngoại chưa có index phủ cột đầu
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select c.conrelid::regclass as tbl,
           string_agg(quote_ident(a.attname), ', ' order by k.ord) as cols
    from pg_constraint c
    cross join lateral unnest(c.conkey) with ordinality k(attnum, ord)
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
    join pg_class t on t.oid = c.conrelid
    where c.contype = 'f'
      and c.connamespace::regnamespace::text in ('core','master','sales','plan','purchase','inv','mfg','qa','cost','wf','iot','integ')
      and not t.relispartition
      and not exists (
        select 1 from pg_index i
        where i.indrelid = c.conrelid
          and (i.indkey::int2[])[0:array_length(c.conkey, 1) - 1] = c.conkey)
    group by c.oid, c.conrelid
  loop
    execute format('create index on %s (%s)', r.tbl, r.cols);
  end loop;
end $$;
