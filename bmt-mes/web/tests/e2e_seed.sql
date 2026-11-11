-- Dữ liệu nền cho E2E (chạy sau khi dựng database thử, trước khi chạy e2e.mjs).
-- Từ migration 8200 lịch máy chỉ dùng tốc độ khai báo của từng máy (không còn tốc độ giả định), mà database thử
-- không có tốc độ máy nào → bước xếp lịch báo "Chưa có tốc độ …". Nạp một dòng tốc độ chung đã duyệt cho mọi
-- máy × công đoạn còn thiếu (đúng danh sách Alarm của master.machine_param_gaps). Số liệu chỉ để thử.
insert into master.machine_speeds (machine_id, op_code, std_mpm, setup_min, status, approved_at, source, note)
select g.machine_id, g.op_code,
       case g.op_code when 'CD0' then 50 when 'CD1' then 60 when 'CD2' then 150 when 'CD3' then 40 when 'CD5' then 80 else 120 end,
       case g.op_code when 'CD0' then 15 when 'CD6' then 10 else 30 end,
       'APPROVED', now(), 'BMT', 'E2E: tốc độ thử'
from master.machine_param_gaps() g
where g.kind = 'NONE';

do $$ begin
  if exists (select 1 from master.machine_param_gaps()) then
    raise exception 'E2E seed: còn máy thiếu tốc độ: %', (select string_agg(machine_code || ' ' || op_code, ', ') from master.machine_param_gaps());
  end if;
end $$;
