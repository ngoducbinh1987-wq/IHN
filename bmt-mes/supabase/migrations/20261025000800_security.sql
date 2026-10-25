-- BMT MES · 0800 · Quyền truy cập: GRANT, Row Level Security, cột giá, Realtime, lịch chạy nền

-- ---------------------------------------------------------------------------
-- Phân hệ của từng bảng (dùng cho chính sách RLS chung)
-- ---------------------------------------------------------------------------
create table core.table_modules (
  table_name text primary key,   -- schema.table
  module     text not null
);

insert into core.table_modules (table_name, module)
select n.nspname || '.' || c.relname,
       case
         when n.nspname = 'core' and c.relname in ('partners','brands','uoms','attachments') then 'master'
         when n.nspname = 'core' then 'admin'
         when n.nspname = 'master' and c.relname in ('product_specs','spec_results','bom_headers','bom_lines',
                                                    'tech_param_sets','tech_params','core_types','color_rules') then 'spec'
         when n.nspname = 'master' and c.relname in ('material_suppliers','price_history') then 'price'
         when n.nspname = 'master' then 'master'
         when n.nspname = 'inv' then 'inventory'
         when n.nspname = 'mfg' then 'production'
         when n.nspname = 'qa' then 'quality'
         when n.nspname = 'wf' then 'approval'
         when n.nspname = 'integ' then 'integration'
         else n.nspname
       end
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname in ('core','master','sales','plan','purchase','inv','mfg','qa','cost','wf','iot','integ')
  and c.relkind in ('r','p') and not c.relispartition
  and (n.nspname, c.relname) <> ('core', 'table_modules');

-- ---------------------------------------------------------------------------
-- GRANT: chỉ người đăng nhập (authenticated) và service_role; anon không có quyền
-- ---------------------------------------------------------------------------
do $$
declare s text;
begin
  foreach s in array array['core','master','sales','plan','purchase','inv','mfg','qa','cost','wf','iot','integ'] loop
    execute format('grant usage on schema %I to authenticated, service_role', s);
    execute format('grant select, insert, update, delete on all tables in schema %I to authenticated', s);
    execute format('grant all on all tables in schema %I to service_role', s);
    execute format('grant usage, select on all sequences in schema %I to authenticated, service_role', s);
    execute format('revoke all on all functions in schema %I from public, anon', s);
    execute format('grant execute on all functions in schema %I to authenticated, service_role', s);
  end loop;
end $$;

-- Bảng chỉ ghi qua hàm nghiệp vụ hoặc trigger
revoke insert, update, delete on inv.stock_moves, inv.stock_balances, cost.item_valuation,
  core.audit_log, core.number_sequences, wf.approval_requests, wf.approval_actions,
  iot.telemetry, iot.telemetry_1m, iot.machine_events, plan.mrp_runs, plan.mrp_lines,
  mfg.lot_genealogy, core.table_modules
  from authenticated;
revoke execute on function iot.ingest_batch(jsonb), iot.ensure_partitions(int), iot.drop_old_partitions(int),
  iot.rollup_1m(timestamptz) from authenticated;

-- Giá trên sổ cái kho: Sản xuất/Kho chỉ thấy số lượng
revoke select on inv.stock_moves from authenticated;
grant select (id, moved_at, doc_id, doc_line_id, move_type, warehouse_id, location_id, lot_id, qty, qty_alt, posted_by)
  on inv.stock_moves to authenticated;

create or replace view cost.v_stock_moves_valued as
select sm.* from inv.stock_moves sm where core.can_see_price();
grant select on cost.v_stock_moves_valued to authenticated;

-- ---------------------------------------------------------------------------
-- RLS chung: xem = view, thêm = create, sửa = edit, xóa = config
-- ---------------------------------------------------------------------------
do $$
declare r record; v_schema text; v_table text;
begin
  for r in select * from core.table_modules loop
    v_schema := split_part(r.table_name, '.', 1);
    v_table := split_part(r.table_name, '.', 2);
    execute format('alter table %I.%I enable row level security', v_schema, v_table);
    execute format('create policy p_select on %I.%I for select to authenticated using (core.has_perm(%L, ''view''))', v_schema, v_table, r.module);
    execute format('create policy p_insert on %I.%I for insert to authenticated with check (core.has_perm(%L, ''create''))', v_schema, v_table, r.module);
    execute format('create policy p_update on %I.%I for update to authenticated using (core.has_perm(%L, ''edit'')) with check (core.has_perm(%L, ''edit''))', v_schema, v_table, r.module, r.module);
    execute format('create policy p_delete on %I.%I for delete to authenticated using (core.has_perm(%L, ''config''))', v_schema, v_table, r.module);
  end loop;
end $$;

alter table core.table_modules enable row level security;
create policy p_select on core.table_modules for select to authenticated using (true);

-- Danh mục tham chiếu: mọi người đăng nhập đều đọc được
do $$
declare t text;
begin
  foreach t in array array['core.departments','core.roles','core.permissions','core.uoms','core.brands',
                           'master.reason_codes','master.operations','master.product_groups','master.routings',
                           'inv.warehouses','inv.locations','master.machines'] loop
    execute format('drop policy p_select on %s', t);
    execute format('create policy p_select on %s for select to authenticated using (true)', t);
  end loop;
end $$;

-- Hồ sơ: mỗi người xem được hồ sơ của mình
drop policy p_select on core.profiles;
create policy p_select on core.profiles for select to authenticated
  using (id = auth.uid() or core.has_perm('admin', 'view') or core.has_perm('approval', 'view'));
drop policy p_select on core.user_roles;
create policy p_select on core.user_roles for select to authenticated
  using (user_id = auth.uid() or core.has_perm('admin', 'view'));

-- Thông báo: chỉ của mình
drop policy p_select on wf.notifications;
drop policy p_update on wf.notifications;
create policy p_select on wf.notifications for select to authenticated using (user_id = auth.uid());
create policy p_update on wf.notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Yêu cầu duyệt: người lập luôn xem được yêu cầu của mình
drop policy p_select on wf.approval_requests;
create policy p_select on wf.approval_requests for select to authenticated
  using (submitted_by = auth.uid() or core.has_perm('approval', 'view'));

-- Phạm vi kho: người có phạm vi WAREHOUSE chỉ thấy tồn của kho được giao
drop policy p_select on inv.stock_balances;
create policy p_select on inv.stock_balances for select to authenticated
  using (core.has_perm('inventory', 'view')
         and (not exists (select 1 from core.user_scopes where user_id = auth.uid() and scope_type = 'WAREHOUSE')
              or exists (select 1 from core.user_scopes where user_id = auth.uid() and scope_type = 'WAREHOUSE' and scope_id = warehouse_id)));

-- ---------------------------------------------------------------------------
-- Realtime cho dashboard máy và thông báo (nếu có publication của Supabase)
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table iot.machine_state, wf.notifications, wf.approval_requests;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Lịch chạy nền (pg_cron): tạo phân vùng dữ liệu máy, tổng hợp 1 phút, xóa dữ liệu thô > 90 ngày
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('bmt_iot_partitions', '10 0 * * *', 'select iot.ensure_partitions(7)');
    perform cron.schedule('bmt_iot_rollup', '* * * * *', 'select iot.rollup_1m()');
    perform cron.schedule('bmt_iot_retention', '30 1 * * *', 'select iot.drop_old_partitions(90)');
  end if;
exception when others then
  raise notice 'Bỏ qua pg_cron: %', sqlerrm;
end $$;
