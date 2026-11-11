-- Sửa lỗi migration 9700: khi bảng MRP hiệu chỉnh chưa tính được (đề xuất nháp chưa có dòng, đề xuất đã hủy, lỗi kiểm tra)
-- app.adj_mrp / plan.adj_preview trả 'rows', 'table' là CHUỖI "[]" (jsonb_build_object('rows', '[]') không ép kiểu)
-- thay vì mảng rỗng → trang /ke-hoach/dieu-chinh/[id] gọi .map trên chuỗi và sập (phát hiện 11/11/2026 khi chạy E2E;
-- trên Supabase lúc đó có 1 đề xuất nháp chưa có dòng). Vá bằng replace trên định nghĩa hàm, báo lỗi nếu không thấy đoạn cần vá.
do $$
declare f text; d text; n int;
begin
  foreach f in array array['plan.adj_preview(uuid)', 'app.adj_mrp(uuid)'] loop
    d := pg_get_functiondef(f::regprocedure);
    n := (length(d) - length(replace(d, '''rows'', ''[]''', ''))) / length('''rows'', ''[]''');
    if n = 0 then raise exception 'Không thấy đoạn cần vá trong %', f; end if;
    d := replace(d, '''rows'', ''[]''', '''rows'', ''[]''::jsonb');
    d := replace(d, '''table'', ''[]''', '''table'', ''[]''::jsonb');
    execute d;
  end loop;
end $$;

-- Kiểm: các nhánh trả mảng rỗng đúng kiểu
do $$ begin
  if pg_get_functiondef('app.adj_mrp(uuid)'::regprocedure) ~ '''(rows|table)'', ''\[\]''(?!::)'
     or pg_get_functiondef('plan.adj_preview(uuid)'::regprocedure) ~ '''(rows|table)'', ''\[\]''(?!::)' then
    raise exception 'Còn nhánh trả chuỗi "[]"';
  end if;
end $$;
