-- Anh Bình 02/11/2026 (Tham số xếp lịch): tốc độ theo công đoạn phải lấy từ thông số của máy, không dùng số giả định.
--   1. Xóa toàn bộ tốc độ mặc định theo công đoạn (master.machine_rates – số giả định, chưa ai ban hành).
--      Bảng giữ (trống) để các hàm cũ không lỗi; xếp lịch, kiểm tra năng lực, km/ngày chỉ dùng tốc độ khai báo của máy
--      (Hồ sơ máy → Tốc độ & dải hoạt động) hoặc PLC. Máy chưa khai báo thì không xếp và báo thiếu thông số.
--   2. app.kh_save_rates bỏ (báo khai ở Hồ sơ máy).
--   3. app.machine_param_gaps(): máy xếp lịch còn thiếu thông số tốc độ → cảnh báo Alarm trên menu chính, Tham số xếp lịch, Danh sách máy.
--   Quản trị sửa / xóa / duyệt tốc độ đã khai báo: migration 8100 (app.admin_speed_edit, admin_speed_delete).

-- 1. Xóa tốc độ giả định (ghi nhật ký tham số từng dòng)
insert into master.planning_param_log (section, item, old_value, new_value, reason)
select 'Tốc độ chuẩn', r.label || ' (mặc định công đoạn)', r.rate_small::text || ' / ' || r.rate_large::text, 'đã xóa',
       'Bỏ tốc độ giả định: xếp lịch chỉ dùng tốc độ khai báo của từng máy (anh Bình 02/11/2026)'
  from master.machine_rates r;
delete from master.machine_rates where true;

-- 2. Không còn sửa tốc độ mặc định theo công đoạn
create or replace function app.kh_save_rates(p jsonb, p_reason text) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  raise exception 'Đã bỏ tốc độ mặc định theo công đoạn: khai báo tốc độ ở Hồ sơ máy → Tốc độ & dải hoạt động';
end $$;
revoke all on function app.kh_save_rates(jsonb, text) from public, anon;
grant execute on function app.kh_save_rates(jsonb, text) to authenticated;

-- Lời nhắc trong kiểm tra năng lực: không còn "Tham số xếp lịch" cho tốc độ
do $$
declare v_oid oid; v_def text; v_new text;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'check_capacity';
  v_def := pg_get_functiondef(v_oid);
  v_new := replace(replace(v_def,
    'TP Kỹ thuật/QA khai báo tốc độ trong Hồ sơ máy hoặc Tham số xếp lịch.', 'TP Kỹ thuật/QA khai báo tốc độ ở Hồ sơ máy → Tốc độ & dải hoạt động.'),
    'Máy chưa có tốc độ riêng. TP Kỹ thuật/QA khai báo ở Hồ sơ máy → Tốc độ, hoặc xác nhận tốc độ mặc định ở Tham số xếp lịch.',
    'Máy chưa có tốc độ khai báo. TP Kỹ thuật/QA khai báo ở Hồ sơ máy → Tốc độ & dải hoạt động.');
  if v_new <> v_def then execute v_new; end if;
end $$;

-- 3. Máy thiếu thông số tốc độ
--    Máy xếp lịch (đang dùng, không phải máy con, không Ngừng dùng) × công đoạn của loại máy:
--    * chưa có dòng tốc độ nào (chờ duyệt cũng tính là có) → "Chưa có tốc độ …";
--    * có dòng nhưng không có dòng chung của máy → các mã đã phát hành spec cần công đoạn đó trên máy (trong dải tiết diện)
--      mà không dòng nào phủ (riêng mã / nhóm / cỡ ruột) → "Thiếu tốc độ cỡ …".
create or replace function master.machine_param_gaps() returns table (
  machine_id uuid, machine_code text, machine_name text, machine_type text, op_code text, kind text, cores text[], products int, message text)
language sql stable security definer set search_path = pg_catalog, public as $$
  with ops(machine_type, op_code, op_name) as (values
    ('BUNCHER', 'CD1', 'bện ruột dẫn'), ('EXTRUDER_SI', 'CD2', 'bọc cách điện silicone'), ('EXTRUDER_TP', 'CD2', 'bọc cách điện HDPE/PVC'),
    ('EXTRUDER_TP', 'CD5', 'bọc vỏ'), ('TWISTER', 'CD3', 'xoắn, quấn AL/PET'), ('MIXER', 'CD0', 'trộn silicone (kg/giờ)'), ('PACKER', 'CD6', 'đóng gói')),
  mo as (
    select m.id, m.code::text, m.name::text, m.machine_type::text, o.op_code, o.op_name
      from master.machines m join ops o on o.machine_type = m.machine_type
     where m.active and m.inline_with is null and coalesce(m.status, '') <> 'OFF'),
  sp as (select * from master.machine_speeds where status <> 'OBSOLETE'),
  prod as (
    select p.id, p.group_code, s.core_code, s.insulation, s.sheath, s.cores, s.pairs, c.nominal_mm2
      from master.products p join master.product_specs s on s.id = p.current_spec_id and s.status = 'RELEASED'
      left join master.core_types c on c.code = s.core_code and c.set_id = s.param_set_id),
  need as (
    select mo.id mid, mo.op_code, pr.*
      from mo join prod pr on case mo.op_code
          when 'CD1' then true
          when 'CD2' then (pr.insulation = 'SIL') = (mo.machine_type = 'EXTRUDER_SI')
          when 'CD0' then pr.insulation = 'SIL'
          when 'CD3' then coalesce(pr.cores, 1) > 1 or coalesce(pr.pairs, 0) > 0
          when 'CD5' then coalesce(nullif(trim(pr.sheath), ''), 'Không') not in ('Không', 'KHONG', 'NONE')
          else true end
      left join master.machine_ranges rg on rg.machine_id = mo.id and rg.param = 'SIZE_MM2'
     where mo.op_code in ('CD0', 'CD6') or rg.id is null or pr.nominal_mm2 is null
        or pr.nominal_mm2 between coalesce(rg.min_value, 0) and coalesce(rg.max_value, 1e9)),
  miss as (
    select n.mid, n.op_code, array_agg(distinct coalesce(n.core_code, '?') order by coalesce(n.core_code, '?')) cores, count(*)::int products
      from need n
     where exists (select 1 from sp where sp.machine_id = n.mid and sp.op_code = n.op_code)
       and not exists (select 1 from sp where sp.machine_id = n.mid and sp.op_code = n.op_code
                          and (sp.product_id = n.id
                               or (sp.product_id is null and (sp.group_code is null or sp.group_code = n.group_code)
                                   and (sp.core_code is null or sp.core_code = n.core_code))))
     group by n.mid, n.op_code)
  select mo.id, mo.code, mo.name, mo.machine_type, mo.op_code, 'NONE', null::text[], null::int,
         'Chưa có tốc độ ' || mo.op_name
    from mo where not exists (select 1 from sp where sp.machine_id = mo.id and sp.op_code = mo.op_code)
  union all
  select mo.id, mo.code, mo.name, mo.machine_type, mo.op_code, 'CORE', x.cores, x.products,
         'Thiếu tốc độ ' || mo.op_name || ' cỡ ' || array_to_string(x.cores, ', ') || ' (' || x.products || ' mã)'
    from mo join miss x on x.mid = mo.id and x.op_code = mo.op_code
$$;
revoke all on function master.machine_param_gaps() from public, anon, authenticated;

-- Web: danh sách thiếu thông số (người xem máy hoặc kế hoạch SX)
create or replace function app.machine_param_gaps() returns table (
  machine_id uuid, machine_code text, machine_name text, machine_type text, op_code text, kind text, cores text[], products int, message text)
language sql stable security definer set search_path = pg_catalog, public as $$
  select g.* from master.machine_param_gaps() g
   where core.has_perm('machine', 'view') or app.kh_can_view()
   order by g.machine_code, g.op_code
$$;
revoke all on function app.machine_param_gaps() from public, anon;
grant execute on function app.machine_param_gaps() to authenticated;

-- Menu chính: số máy đang Alarm thiếu thông số
create or replace function app.machine_param_alarm_count() returns integer
language sql stable security definer set search_path = pg_catalog, public as $$
  select case when core.has_perm('machine', 'view') or app.kh_can_view()
              then (select count(distinct machine_id)::int from master.machine_param_gaps()) else 0 end
$$;
revoke all on function app.machine_param_alarm_count() from public, anon;
grant execute on function app.machine_param_alarm_count() to authenticated;
