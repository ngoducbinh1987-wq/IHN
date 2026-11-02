-- Quản trị hệ thống sửa, duyệt, xóa tốc độ chuẩn của mọi máy (anh Bình yêu cầu 02/11/2026, ảnh Hồ sơ máy bện → Tốc độ).
-- Người thường giữ nguyên: nhập tốc độ (chờ duyệt), TP KT/QA duyệt, người nhập không tự duyệt, chỉ sửa/xóa dòng chờ duyệt.
-- Quản trị: sửa tốc độ chuẩn + phút đổi máy ở dòng chờ duyệt hoặc đã duyệt (duyệt luôn khi sửa), xóa mọi dòng, duyệt tất cả.

create or replace function pg_temp.patch(p_name text, p_old text, p_new text) returns void language plpgsql as $$
declare v_oid oid; v_n int; v_def text;
begin
  select count(*), min(p.oid) into v_n, v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname || '.' || p.proname = p_name;
  if v_n <> 1 then raise exception 'Vá %: có % hàm cùng tên', p_name, v_n; end if;
  v_def := pg_get_functiondef(v_oid);
  if position(p_old in v_def) = 0 then raise exception 'Vá %: không thấy đoạn "%"', p_name, p_old; end if;
  execute replace(v_def, p_old, p_new);
end $$;

-- Nhãn một dòng tốc độ để ghi nhật ký: "BUN-01 · cỡ M0.75" / "… · mã PFR-2C-1P5" / "… · mặc định"
create or replace function master.speed_label(s master.machine_speeds) returns text
 language sql stable security definer set search_path to 'pg_catalog', 'public'
as $$
  select coalesce((select code from master.machines where id = s.machine_id), '?') || ' ' || s.op_code || ' · '
      || coalesce('mã ' || (select code from master.products where id = s.product_id), 'cỡ ' || s.core_code, 'nhóm ' || s.group_code, 'mặc định')
$$;
revoke execute on function master.speed_label(master.machine_speeds) from public, anon, authenticated;

create or replace function app.admin_speed_edit(p_id uuid, p_std numeric, p_setup numeric, p_approve boolean, p_reason text)
 returns text language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare s master.machine_speeds; v_new master.machine_speeds;
begin
  if not core.is_admin() then raise exception 'Chỉ Quản trị hệ thống sửa tốc độ đã duyệt'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Ghi lý do sửa tốc độ'; end if;
  select * into s from master.machine_speeds where id = p_id for update;
  if not found then raise exception 'Không tìm thấy dòng tốc độ'; end if;
  if s.status = 'OBSOLETE' then raise exception 'Dòng tốc độ này đã được thay bằng bản mới'; end if;
  if p_std is null or p_std <= 0 then raise exception 'Tốc độ chuẩn phải lớn hơn 0'; end if;
  if p_setup is not null and p_setup < 0 then raise exception 'Phút đổi máy không được âm'; end if;
  if s.rated_mpm is not null and p_std > s.rated_mpm then
    raise exception 'Tốc độ chuẩn không được cao hơn tốc độ danh định của nhà sản xuất (%)', s.rated_mpm;
  end if;

  update master.machine_speeds set std_mpm = p_std, setup_min = coalesce(p_setup, setup_min) where id = p_id;
  if s.status = 'PENDING' and coalesce(p_approve, false) then
    perform app.approve_machine_speed(p_id);
  elsif s.status = 'APPROVED' then
    update master.machine_speeds set approved_by = auth.uid(), approved_at = now(), temp_approval = false where id = p_id;
  end if;
  select * into v_new from master.machine_speeds where id = p_id;

  perform app.admin_log('master.machine_speeds', p_id::text, 'ADMIN_SPEED', to_jsonb(s),
    jsonb_build_object('doc_type', 'Sửa tốc độ máy', 'doc_no', master.speed_label(s), 'reason', trim(p_reason),
      'std_mpm', jsonb_build_array(s.std_mpm, v_new.std_mpm), 'setup_min', jsonb_build_array(s.setup_min, v_new.setup_min),
      'status', v_new.status));
  return v_new.status;
end $$;
revoke execute on function app.admin_speed_edit(uuid, numeric, numeric, boolean, text) from public, anon;
grant execute on function app.admin_speed_edit(uuid, numeric, numeric, boolean, text) to authenticated;

create or replace function app.admin_speed_delete(p_id uuid, p_reason text)
 returns void language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare s master.machine_speeds;
begin
  if not core.is_admin() then raise exception 'Chỉ Quản trị hệ thống xóa tốc độ đã duyệt'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Ghi lý do xóa tốc độ'; end if;
  select * into s from master.machine_speeds where id = p_id for update;
  if not found then raise exception 'Không tìm thấy dòng tốc độ'; end if;
  delete from master.machine_speeds where id = p_id;
  perform app.admin_log('master.machine_speeds', p_id::text, 'ADMIN_SPEED', to_jsonb(s),
    jsonb_build_object('doc_type', 'Xóa tốc độ máy', 'doc_no', master.speed_label(s), 'reason', trim(p_reason), 'status', s.status));
end $$;
revoke execute on function app.admin_speed_delete(uuid, text) from public, anon;
grant execute on function app.admin_speed_delete(uuid, text) to authenticated;

-- Duyệt mọi dòng chờ duyệt của một máy (p_machine null = mọi máy); bỏ qua dòng người gọi tự nhập (trừ Quản trị).
-- Nhiều dòng chờ cùng phạm vi áp dụng: duyệt theo thứ tự gửi, dòng gửi sau cùng là bản dùng.
create or replace function app.approve_machine_speeds(p_machine uuid) returns integer
 language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare r record; n integer := 0;
begin
  if not core.has_perm('machine', 'approve') then raise exception 'Bạn chưa có quyền duyệt tốc độ chuẩn'; end if;
  for r in select id from master.machine_speeds
            where status = 'PENDING' and (p_machine is null or machine_id = p_machine)
              and (created_by is distinct from auth.uid() or core.is_admin())
            order by submitted_at, created_at loop
    perform app.approve_machine_speed(r.id);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function app.approve_machine_speeds(uuid) from public, anon;
grant execute on function app.approve_machine_speeds(uuid) to authenticated;

select pg_temp.patch('app.admin_overrides', $o$'ADMIN_USER_DELETE'$o$, $n$'ADMIN_USER_DELETE', 'ADMIN_SPEED'$n$);
