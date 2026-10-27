-- Kiểm tra mọi hàm nghiệp vụ không có DELETE/UPDATE thiếu WHERE (Supabase nạp pg-safeupdate cho authenticator:
-- lệnh thiếu WHERE gọi qua API báo "DELETE requires a WHERE clause"). Kết thúc bằng "lỗi" KET_QUA_OK.
do $$
declare bad text; n int;
begin
  select string_agg(fn || ' :: ' || left(stmt, 120), E'\n'), count(*) into bad, n
  from (
    select p.oid::regprocedure::text as fn, btrim(regexp_replace(st, '\s+', ' ', 'g')) as stmt
    from pg_proc p join pg_namespace s on s.oid = p.pronamespace,
         regexp_split_to_table(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), ';') st
    where s.nspname in ('app','core','master','plan','purchase','inv','mfg','qa','cost','wf','sales','iot','integ')
      and p.prolang in (select oid from pg_language where lanname in ('plpgsql', 'sql'))
  ) x
  where stmt ~* '(^|\s)(delete\s+from\s+[\w\.]+|update\s+[\w\.]+(\s+\w+)?\s+set)\M'
    and substring(stmt from '(?i)((delete\s+from|update)\s.*)$') !~* '\mwhere\M';
  if n > 0 then raise exception E'FAIL: % lệnh DELETE/UPDATE thiếu WHERE:\n%', n, bad; end if;
  raise exception 'KET_QUA_OK — 1 kiểm tra đạt: không hàm nào có DELETE/UPDATE thiếu WHERE';
end $$;
