-- Kiểm thử migration 20261026010500_bobbin_carriers: 40 bobin 630 + 20 bobin 800 đã khai báo ở Kho → Bobin.
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

do $$ begin
  perform pg_temp.ok((select count(*) from inv.carriers where carrier_type = 'B630' and code ~ '^B630-(0[1-9]|[1-3][0-9]|40)$') = 40,
    '40 bobin 630 số B630-01…B630-40');
  perform pg_temp.ok((select count(*) from inv.carriers where carrier_type = 'B800' and code ~ '^B800-(0[1-9]|1[0-9]|20)$') = 20,
    '20 bobin 800 số B800-01…B800-20');
  perform pg_temp.ok(not exists (select 1 from inv.carriers c left join inv.locations l on l.id = c.location_id
      where c.code ~ '^B(630|800)-' and c.status = 'EMPTY' and coalesce(l.code, '') <> 'KBTP-EMPTY' and c.current_hu_id is null),
    'Bobin trống nằm ở khu bobin trống KBTP-EMPTY');
  perform pg_temp.ok((select prosrc like '%chưa có khối lượng bì%' from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'app' and p.proname = 'record_bobbin'), 'Phiếu hoàn thành chặn bobin chưa cân bì');
end $$;

do $$ begin
  raise exception 'KET_QUA_OK %', (select count(*) from r) || ' kiểm tra đạt: ' || (select string_agg(msg, ' | ' order by n) from r);
end $$;
