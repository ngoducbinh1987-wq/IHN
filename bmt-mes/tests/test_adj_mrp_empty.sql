-- Kiểm thử migration 20261026009910_adj_mrp_empty_fix: nhánh "chưa tính được" của bảng MRP hiệu chỉnh trả MẢNG rỗng.
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
begin;
do $$
declare v jsonb; n int := 0;
begin
  -- 1. Đề xuất không chạy thử được (ở đây: không tồn tại) → error kèm rows/table là mảng
  v := plan.adj_preview(gen_random_uuid());
  if v ->> 'error' is null then raise exception 'FAIL: phải trả error, nhận %', v; end if;
  if jsonb_typeof(v -> 'rows') <> 'array' or jsonb_typeof(v -> 'table') <> 'array' then
    raise exception 'FAIL: rows/table phải là mảng, nhận %', v;
  end if;
  n := n + 1;
  -- 2. Không còn nhánh nào trả chuỗi "[]" trong hai hàm
  if pg_get_functiondef('app.adj_mrp(uuid)'::regprocedure) ~ '''(rows|table)'', ''\[\]''(?!::)'
     or pg_get_functiondef('plan.adj_preview(uuid)'::regprocedure) ~ '''(rows|table)'', ''\[\]''(?!::)' then
    raise exception 'FAIL: còn nhánh trả chuỗi "[]"';
  end if;
  n := n + 1;
  raise exception 'KET_QUA_OK % kiểm tra đạt: nhánh lỗi trả mảng rỗng; không còn chuỗi "[]"', n;
end $$;
rollback;
