-- Kiểm thử migration 20261026005600_security_cleanup. Chỉ đọc catalog, kết thúc bằng "lỗi" KET_QUA_OK (rollback).
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql.
do $$
declare n int := 0; bad text;
begin
  -- 1. Hàm nạp dữ liệu tạm đã xóa
  if to_regprocedure('public._mig_import(text,text,text,jsonb)') is not null then
    raise exception 'FAIL: public._mig_import vẫn còn';
  end if;
  n := n + 1;

  -- 2. Không còn hàm SECURITY DEFINER nghiệp vụ nào người chưa đăng nhập (anon) gọi được
  select string_agg(p.oid::regprocedure::text, ', ') into bad
  from pg_proc p join pg_namespace s on s.oid = p.pronamespace
  where p.prosecdef and has_function_privilege('anon', p.oid, 'execute')
    and s.nspname in ('public','app','core','master','plan','purchase','inv','mfg','qa','cost','wf','sales','iot','integ');
  if bad is not null then raise exception 'FAIL: anon còn gọi được: %', bad; end if;
  n := n + 1;

  -- 3. Hàm web gọi vẫn mở cho người đã đăng nhập
  if not (has_function_privilege('authenticated', 'app.kh_delete_op_shift(uuid,text)', 'execute')
      and has_function_privilege('authenticated', 'app.kh_save_op_shift(uuid,text,date,date,integer,text)', 'execute')
      and has_function_privilege('authenticated', 'app.kh_save_shift_rules(numeric,text)', 'execute')
      and has_function_privilege('authenticated', 'mfg.can_enter_slips()', 'execute')
      and has_function_privilege('authenticated', 'inv.fg_pack(numeric,boolean,numeric,numeric)', 'execute')) then
    raise exception 'FAIL: authenticated mất quyền gọi hàm web dùng';
  end if;
  n := n + 1;

  -- 4. Hàm nội bộ không mở cho authenticated
  if has_function_privilege('authenticated', 'mfg.scrap_material_for(text,uuid)', 'execute') then
    raise exception 'FAIL: authenticated gọi được mfg.scrap_material_for';
  end if;
  n := n + 1;

  -- 5. search_path cố định
  select string_agg(p.oid::regprocedure::text, ', ') into bad
  from pg_proc p
  where p.oid in ('inv.fg_pack(numeric,boolean,numeric,numeric)'::regprocedure, 'inv.fg_label(text,text,numeric)'::regprocedure,
                  'mfg.loss_level(numeric,numeric)'::regprocedure)
    and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%');
  if bad is not null then raise exception 'FAIL: chưa cố định search_path: %', bad; end if;
  n := n + 1;

  -- 6. Hàm vẫn chạy đúng
  if inv.fg_pack(500, false, 500, 500) <> 500 or inv.fg_pack(500, true, 500, 500) is not null
     or mfg.loss_level(3, 2) <> 'RED' or inv.fg_label('ABC', 'HEIZKA', null) not like 'ABC · HEIZKA%' then
    raise exception 'FAIL: hàm tính toán trả sai sau khi đổi search_path';
  end if;
  n := n + 1;

  raise exception 'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt', n;
end $$;
