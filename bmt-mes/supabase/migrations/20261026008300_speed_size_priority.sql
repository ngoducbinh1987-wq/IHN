-- Anh Bình 02/11/2026: máy khai cả tốc độ chung và tốc độ theo cỡ → cỡ có khai dùng tốc độ theo cỡ, cỡ không khai dùng tốc độ chung;
-- áp cho mọi máy. Bộ xếp lịch (web/lib/kh/scheduler.ts machineSpeed) và app.check_capacity đã chọn theo thứ tự
-- riêng mã SP → nhóm + cỡ → cỡ → nhóm → chung của máy. Migration này chỉ sửa phần báo của kiểm tra năng lực:
--   * cáp chống nhiễu: máy xoắn chưa khai riêng bước quấn AL/PET (CD4) thì chạy theo tốc độ xoắn (CD3), không báo thiếu
--     (trước đây báo nhầm "Dùng tốc độ mặc định theo công đoạn … số giả định" dù đã bỏ tốc độ giả định ở migration 8200);
--   * câu báo đổi thành "Máy chưa khai tốc độ cho: …" (không còn tốc độ mặc định).
do $$
declare v_oid oid; v_def text; v_new text;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'check_capacity';
  v_def := pg_get_functiondef(v_oid);
  v_new := replace(v_def,
    'bool_or(b.eff is null) as dflt, bool_or(b.eff is null and not coalesce(d.confirmed, false)) as guess',
    'bool_or(b.eff is null and not (oc.code = ''CD4'' and ''CD3'' = any (v_codes))) as dflt, false as guess');
  if v_new = v_def then raise exception 'Vá check_capacity: không thấy đoạn dflt/guess'; end if;
  v_def := v_new;
  v_new := replace(v_def, '''Dùng tốc độ mặc định theo công đoạn cho: ''', '''Máy chưa khai tốc độ cho: ''');
  if v_new = v_def then raise exception 'Vá check_capacity: không thấy câu báo tốc độ mặc định'; end if;
  v_new := regexp_replace(v_new, '''lvl'', ''info'',(\s+)''text'', ''Máy chưa khai tốc độ cho: ''', '''lvl'', ''warn'',\1''text'', ''Máy chưa khai tốc độ cho: ''');
  execute v_new;
end $$;
