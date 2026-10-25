-- BMT MES · 0600 · Luồng duyệt, dữ liệu máy (chỉ đọc từ PLC), đồng bộ MISA

-- ---------------------------------------------------------------------------
-- Luồng duyệt theo phân cấp chức danh (không theo hạn mức tiền)
-- ---------------------------------------------------------------------------
create table wf.approval_flows (
  doc_type    text primary key,    -- SO, SPEC_NEW, SPEC_MINOR, PLAN, PR, PROPOSAL, PO, WO_RELEASE, EXTRA_ISSUE, NCR, STOCK_ADJ, SCRAP_OUT, COST_CLOSE
  name        text not null,
  doc_table   text not null,       -- bảng chứng từ, ví dụ sales.sales_orders
  status_col  text not null default 'status',
  approved_status text not null default 'APPROVED',
  rejected_status text not null default 'DRAFT',
  pending_status  text not null default 'PENDING_APPROVAL'
);

create table wf.approval_steps (
  doc_type  text not null references wf.approval_flows(doc_type) on delete cascade,
  seq       smallint not null,
  level_label text not null,       -- Kiểm tra / Duyệt / Phê duyệt
  role_code text not null references core.roles(code),
  enabled   boolean not null default true,   -- ADMIN bật/tắt bước (ví dụ BGĐ duyệt SO)
  primary key (doc_type, seq)
);

create table wf.approval_requests (
  id          uuid primary key default gen_random_uuid(),
  doc_type    text not null references wf.approval_flows(doc_type),
  doc_id      uuid not null,
  doc_no      text not null,
  summary     text,
  status      text not null default 'PENDING' check (status in ('PENDING','APPROVED','REJECTED','CANCELLED')),
  current_seq smallint,
  data_hash   text,                -- hash dữ liệu chứng từ lúc gửi duyệt
  submitted_by uuid not null default auth.uid(),
  submitted_at timestamptz not null default now(),
  finished_at timestamptz
);
create index on wf.approval_requests (status, doc_type);
create unique index approval_one_pending on wf.approval_requests (doc_type, doc_id) where status = 'PENDING';

create table wf.approval_actions (
  id          bigint generated always as identity primary key,
  request_id  uuid not null references wf.approval_requests(id) on delete cascade,
  seq         smallint not null,
  actor_id    uuid not null default auth.uid(),
  on_behalf_of uuid,               -- duyệt thay theo ủy quyền
  action      text not null check (action in ('APPROVE','REJECT','COMMENT')),
  comment     text,
  data_hash   text,
  acted_at    timestamptz not null default now()
);

create table wf.notifications (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references core.profiles(id),
  title      text not null,
  body       text,
  link       text,
  read_at    timestamptz,
  created_at timestamptz not null default now()
);
create index on wf.notifications (user_id, read_at);

-- ---------------------------------------------------------------------------
-- Dữ liệu máy (gateway tại xưởng chỉ đọc PLC, không ghi xuống PLC)
-- ---------------------------------------------------------------------------
create table iot.machine_tags (
  machine_id uuid not null references master.machines(id) on delete cascade,
  tag_code   text not null,              -- speed_mpm, length_m, od_mm, temp_z1 …
  address    text,                       -- DB10.DBD4 (S7) hoặc 40001 (Modbus)
  data_type  text,
  unit       text,
  scale      numeric default 1,
  primary key (machine_id, tag_code)
);

-- Bản ghi 1 giây/máy, phân vùng theo ngày (không dùng TimescaleDB)
create table iot.telemetry (
  machine_id uuid not null,
  ts         timestamptz not null,
  wo_op_id   uuid,
  state      smallint,                   -- 0 dừng, 1 chạy, 2 chờ, 3 lỗi
  speed_mpm  real,
  length_m   double precision,           -- bộ đếm mét PLC
  od_mm      real,
  od_dev_mm  real,
  temps      real[],
  current_a  real,
  kwh        double precision,
  extra      jsonb,
  primary key (machine_id, ts)
) partition by range (ts);

create table iot.telemetry_default partition of iot.telemetry default;

-- Tạo trước phân vùng theo ngày
create or replace function iot.ensure_partitions(p_days_ahead int default 7) returns void
language plpgsql as $$
declare d date; tbl text;
begin
  for d in select generate_series(current_date - 1, current_date + p_days_ahead, interval '1 day')::date loop
    tbl := 'telemetry_' || to_char(d, 'YYYYMMDD');
    if to_regclass('iot.' || tbl) is null then
      execute format('create table iot.%I partition of iot.telemetry for values from (%L) to (%L)', tbl, d, d + 1);
    end if;
  end loop;
end $$;

-- Xóa phân vùng thô quá hạn (mặc định giữ 90 ngày)
create or replace function iot.drop_old_partitions(p_keep_days int default 90) returns void
language plpgsql as $$
declare r record;
begin
  for r in select c.relname from pg_inherits i join pg_class c on c.oid = i.inhrelid
           join pg_class p on p.oid = i.inhparent join pg_namespace n on n.oid = p.relnamespace
           where n.nspname = 'iot' and p.relname = 'telemetry' and c.relname ~ '^telemetry_\d{8}$'
             and to_date(substring(c.relname from 11), 'YYYYMMDD') < current_date - p_keep_days loop
    execute format('drop table iot.%I', r.relname);
  end loop;
end $$;

select iot.ensure_partitions(7);

-- Tổng hợp 1 phút, giữ lâu dài
create table iot.telemetry_1m (
  machine_id uuid not null,
  bucket     timestamptz not null,
  wo_op_id   uuid,
  run_seconds integer,
  avg_speed  real,
  meters     double precision,
  od_avg     real, od_min real, od_max real,
  kwh        double precision,
  primary key (machine_id, bucket)
);

create or replace function iot.rollup_1m(p_from timestamptz default now() - interval '10 minutes') returns void
language sql as $$
  insert into iot.telemetry_1m as t (machine_id, bucket, wo_op_id, run_seconds, avg_speed, meters, od_avg, od_min, od_max, kwh)
  select machine_id, date_trunc('minute', ts), max(wo_op_id::text)::uuid,
         count(*) filter (where state = 1), avg(speed_mpm),
         max(length_m) - min(length_m), avg(od_mm), min(od_mm), max(od_mm), max(kwh) - min(kwh)
  from iot.telemetry
  where ts >= date_trunc('minute', p_from) and ts < date_trunc('minute', now())
  group by 1, 2
  on conflict (machine_id, bucket) do update set
    wo_op_id = excluded.wo_op_id, run_seconds = excluded.run_seconds, avg_speed = excluded.avg_speed,
    meters = excluded.meters, od_avg = excluded.od_avg, od_min = excluded.od_min, od_max = excluded.od_max, kwh = excluded.kwh
$$;

-- Trạng thái mới nhất của từng máy (web app nghe Realtime bảng này)
create table iot.machine_state (
  machine_id uuid primary key references master.machines(id),
  ts         timestamptz,
  state      smallint,
  speed_mpm  real,
  length_m   double precision,
  od_mm      real,
  temps      real[],
  wo_op_id   uuid references mfg.wo_operations(id),   -- tablet gắn lệnh đang chạy
  alarm      text
);

create table iot.machine_events (
  id         bigint generated always as identity primary key,
  machine_id uuid not null references master.machines(id),
  ts         timestamptz not null,
  event_type text not null,             -- START, STOP, ALARM, ALARM_CLEAR
  code       text,
  message    text
);

-- Hàm nhận dữ liệu từ gateway (chỉ service_role gọi được)
-- payload: [{"machine":"EXT-SI-01","ts":"…","state":1,"speed_mpm":62,"length_m":1234.5,"od_mm":2.72,"temps":[48,352]}, …]
create or replace function iot.ingest_batch(p_payload jsonb) returns integer
language plpgsql security definer set search_path = iot, master, public as $$
declare n int;
begin
  with rows as (
    select m.id as machine_id, (e->>'ts')::timestamptz as ts, (e->>'state')::smallint as state,
           (e->>'speed_mpm')::real as speed_mpm, (e->>'length_m')::float8 as length_m,
           (e->>'od_mm')::real as od_mm, (e->>'od_dev_mm')::real as od_dev_mm,
           case when e ? 'temps' then array(select jsonb_array_elements_text(e->'temps')::real) end as temps,
           (e->>'current_a')::real as current_a, (e->>'kwh')::float8 as kwh, e->'extra' as extra
    from jsonb_array_elements(p_payload) e
    join master.machines m on m.code = e->>'machine'
  ), ins as (
    insert into iot.telemetry (machine_id, ts, wo_op_id, state, speed_mpm, length_m, od_mm, od_dev_mm, temps, current_a, kwh, extra)
    select r.machine_id, r.ts, s.wo_op_id, r.state, r.speed_mpm, r.length_m, r.od_mm, r.od_dev_mm, r.temps, r.current_a, r.kwh, r.extra
    from rows r left join iot.machine_state s on s.machine_id = r.machine_id
    on conflict do nothing
    returning machine_id, ts, state, speed_mpm, length_m, od_mm, temps
  ), latest as (
    select distinct on (machine_id) * from ins order by machine_id, ts desc
  ), up as (
    insert into iot.machine_state (machine_id, ts, state, speed_mpm, length_m, od_mm, temps)
    select machine_id, ts, state, speed_mpm, length_m, od_mm, temps from latest
    on conflict (machine_id) do update set ts = excluded.ts, state = excluded.state, speed_mpm = excluded.speed_mpm,
      length_m = excluded.length_m, od_mm = excluded.od_mm, temps = excluded.temps
    where iot.machine_state.ts is null or excluded.ts > iot.machine_state.ts
    returning 1
  )
  select count(*) into n from ins;
  return n;
end $$;
revoke all on function iot.ingest_batch(jsonb) from public;

-- ---------------------------------------------------------------------------
-- Đồng bộ MISA
-- ---------------------------------------------------------------------------
create table integ.misa_mappings (
  entity     text not null,          -- MATERIAL, PRODUCT, WAREHOUSE, PARTNER, ACCOUNT
  local_id   uuid not null,
  misa_code  text not null,
  primary key (entity, local_id)
);

create table integ.sync_queue (
  id          bigint generated always as identity primary key,
  entity      text not null,          -- STOCK_DOC, PARTNER, MATERIAL, COST
  entity_id   uuid not null,
  direction   text not null check (direction in ('TO_MISA','FROM_MISA')),
  status      text not null default 'QUEUED' check (status in ('QUEUED','SENT','FAILED','SKIPPED')),
  attempts    integer not null default 0,
  payload     jsonb,
  last_error  text,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);
create index on integ.sync_queue (status, created_at);

create table integ.sync_logs (
  id        bigint generated always as identity primary key,
  queue_id  bigint references integ.sync_queue(id),
  at        timestamptz not null default now(),
  ok        boolean not null,
  response  text
);
