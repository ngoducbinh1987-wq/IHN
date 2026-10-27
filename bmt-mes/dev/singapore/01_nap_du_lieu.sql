-- CHỈ CHẠY TRÊN DỰ ÁN "BMT MES Singapore" (awjbtcvpzjjxdczepwyr) – Supabase → SQL Editor → dán toàn bộ → Run.
-- Nạp dữ liệu đã chép từ dự án Mumbai (đang nằm ở bảng tạm _mig.payload) vào các bảng.
-- Xóa dữ liệu mẫu của dự án MỚI trước khi nạp; không đụng tới dự án đang chạy.
create or replace function _mig.load(p_batch text) returns text language plpgsql set search_path = '' as $$
declare
  v_schemas text[] := array['core','master','sales','plan','purchase','inv','mfg','qa','cost','wf','iot','integ'];
  r record; v_list text; v_pending text[]; v_progress boolean;
  v_cols text; v_rows jsonb; v_n bigint; v_total bigint := 0; v_tables int := 0; v_seq jsonb; k text;
begin
  if current_database() <> 'postgres' or not exists (select 1 from _mig.files) then raise exception 'Sai dự án'; end if;
  for r in select c.oid::regclass t from pg_class c join pg_namespace n on n.oid=c.relnamespace
           where c.relkind in ('r','p') and not c.relispartition and n.nspname = any(v_schemas) loop
    execute format('alter table %s disable trigger user', r.t);
  end loop;
  select string_agg(c.oid::regclass::text, ', ') into v_list from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where c.relkind in ('r','p') and not c.relispartition and n.nspname = any(v_schemas);
  execute 'truncate ' || v_list || ' cascade';
  delete from auth.identities; delete from auth.users;
  for k in select unnest(array['auth.users','auth.identities']) loop
    select jsonb_agg(e) into v_rows from _mig.payload p, jsonb_array_elements(p.body) e where p.batch=p_batch and p.tbl=k;
    continue when v_rows is null;
    select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into v_cols from pg_attribute a
      where a.attrelid = k::regclass and a.attnum>0 and not a.attisdropped and a.attgenerated='';
    execute format('insert into %s (%s) overriding system value select %s from jsonb_populate_recordset(null::%s, $1)', k, v_cols, v_cols, k) using v_rows;
    get diagnostics v_n = row_count; v_total := v_total + v_n; v_tables := v_tables + 1;
  end loop;
  select array_agg(distinct tbl) into v_pending from _mig.payload where batch=p_batch and tbl not in ('auth.users','auth.identities','__sequences');
  loop
    exit when coalesce(array_length(v_pending,1),0) = 0;
    v_progress := false;
    foreach k in array v_pending loop
      if exists (select 1 from pg_constraint co where co.contype='f' and co.conrelid = k::regclass and co.confrelid <> co.conrelid
                   and co.confrelid::regclass::text = any(v_pending)) then
        continue;
      end if;
      select jsonb_agg(e) into v_rows from _mig.payload p, jsonb_array_elements(p.body) e where p.batch=p_batch and p.tbl=k;
      select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into v_cols from pg_attribute a
        where a.attrelid = k::regclass and a.attnum>0 and not a.attisdropped and a.attgenerated='';
      begin
        execute format('insert into %s (%s) overriding system value select %s from jsonb_populate_recordset(null::%s, $1)', k::regclass, v_cols, v_cols, k::regclass) using v_rows;
      exception when others then raise exception 'Nạp % lỗi: % [%]', k, sqlerrm, sqlstate;
      end;
      get diagnostics v_n = row_count; v_total := v_total + v_n; v_tables := v_tables + 1;
      v_pending := array_remove(v_pending, k); v_progress := true;
    end loop;
    if not v_progress then raise exception 'Vòng khóa ngoại: %', v_pending; end if;
  end loop;
  for r in select c.oid::regclass t from pg_class c join pg_namespace n on n.oid=c.relnamespace
           where c.relkind in ('r','p') and not c.relispartition and n.nspname = any(v_schemas) loop
    execute format('alter table %s enable trigger user', r.t);
  end loop;
  select body into v_seq from _mig.payload where batch=p_batch and tbl='__sequences';
  for k in select jsonb_object_keys(v_seq) loop
    if (v_seq->k->>'last_value') is not null and to_regclass(k) is not null then
      perform setval(k::regclass, (v_seq->k->>'last_value')::bigint, true);
    end if;
  end loop;
  return format('%s bảng, %s dòng', v_tables, v_total);
end $$;
revoke all on function _mig.load(text) from public, anon, authenticated;
select _mig.load('trial1') as ket_qua;
