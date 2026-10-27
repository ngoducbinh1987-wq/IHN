-- Sửa lỗi "DELETE requires a WHERE clause" (28/10/2026, anh Bình bấm Chạy MRP trên kế hoạch KH-2610-03).
-- Dự án Supabase Singapore nạp sẵn pg-safeupdate cho role authenticator (session_preload_libraries = supautils, safeupdate):
-- mọi lệnh DELETE/UPDATE không có WHERE trong phiên gọi qua API bị chặn, kể cả lệnh nằm trong hàm SECURITY DEFINER.
-- Kiểm thử chạy bằng postgres nên không thấy lỗi. Ba lệnh xóa bảng tạm bị ảnh hưởng:
--   plan.run_mrp: delete from _pool; delete from _need;   (Chạy MRP)
--   inv.issue_pick: delete from _pick;                    (cấp NVL, phiếu xuất NVL theo lô)
-- Sửa tại chỗ trên bản đang chạy (không chép lại thân hàm cũ): thêm "where true".
-- Quy tắc từ nay: không viết DELETE/UPDATE thiếu WHERE trong hàm (bảng tạm cũng vậy). tests/test_safeupdate.sql kiểm toàn bộ.
do $m$
declare r record; def text; n int; total int := 0;
begin
  for r in select p.oid, p.oid::regprocedure::text as fn
           from pg_proc p join pg_namespace s on s.oid = p.pronamespace
           where (s.nspname, p.proname) in (('plan', 'run_mrp'), ('inv', 'issue_pick')) loop
    def := pg_get_functiondef(r.oid);
    n := (select count(*) from regexp_matches(def, 'delete\s+from\s+(_pool|_need|_pick)\s*;', 'gi'));
    if n = 0 then continue; end if;
    def := regexp_replace(def, 'delete\s+from\s+(_pool|_need|_pick)\s*;', 'delete from \1 where true;', 'gi');
    execute def;
    total := total + n;
    raise notice '% : sửa % lệnh xóa', r.fn, n;
  end loop;
  if total = 0 then raise exception 'Không tìm thấy lệnh xóa cần sửa trong plan.run_mrp, inv.issue_pick'; end if;
end $m$;
