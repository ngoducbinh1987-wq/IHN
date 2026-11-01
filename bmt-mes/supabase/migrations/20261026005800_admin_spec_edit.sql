-- Quản trị hệ thống sửa spec, BOM ở mọi trạng thái (anh Bình yêu cầu 01/11/2026: nút sửa ở từng dòng Sản phẩm & Spec,
-- chỉ Quản trị). Người khác vẫn chỉ sửa spec nháp / pilot; spec đã phát hành phải tạo phiên bản mới.
-- Cách làm: hàm app.admin_spec_edit (chỉ core.is_admin, bắt buộc lý do) bật cờ bmt.admin_spec_edit rồi gọi đúng hàm sửa
-- sẵn có (update_spec_draft, save_bom_line, delete_bom_line); cờ cho phép sửa spec/BOM đã phát hành, giữ nguyên trạng thái.

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

-- Khóa spec / BOM đã phát hành: bỏ qua khi Quản trị sửa qua app.admin_spec_edit
select pg_temp.patch('master.guard_released_spec',
  $o$if old.status = 'RELEASED' and not ($o$,
  $n$if coalesce(current_setting('bmt.admin_spec_edit', true), '') = 'on' and new.status = old.status then return new; end if;
  if old.status = 'RELEASED' and not ($n$);
select pg_temp.patch('master.guard_released_bom_line',
  $o$if v_status = 'RELEASED' then$o$,
  $n$if v_status = 'RELEASED' and coalesce(current_setting('bmt.admin_spec_edit', true), '') <> 'on' then$n$);

select pg_temp.patch('app.update_spec_draft',
  $o$if v_status not in ('DRAFT', 'PILOT_PENDING', 'PILOT') then$o$,
  $n$if v_status not in ('DRAFT', 'PILOT_PENDING', 'PILOT') and coalesce(current_setting('bmt.admin_spec_edit', true), '') <> 'on' then$n$);
select pg_temp.patch('app.update_spec_draft',
  $o$status = 'DRAFT'$o$,
  $n$status = case when coalesce(current_setting('bmt.admin_spec_edit', true), '') = 'on' then status else 'DRAFT' end$n$);
select pg_temp.patch('app.save_bom_line',
  $o$where h.spec_id = p_spec and h.status = 'DRAFT' and s.status in ('DRAFT', 'PILOT_PENDING', 'PILOT');$o$,
  $n$where h.spec_id = p_spec and ((h.status = 'DRAFT' and s.status in ('DRAFT', 'PILOT_PENDING', 'PILOT'))
      or coalesce(current_setting('bmt.admin_spec_edit', true), '') = 'on');$n$);
select pg_temp.patch('app.delete_bom_line',
  $o$and h.status = 'DRAFT' and s.status in ('DRAFT', 'PILOT_PENDING', 'PILOT');$o$,
  $n$and ((h.status = 'DRAFT' and s.status in ('DRAFT', 'PILOT_PENDING', 'PILOT'))
        or coalesce(current_setting('bmt.admin_spec_edit', true), '') = 'on');$n$);

-- p_action: 'spec' (p = thông số như update_spec_draft), 'bom_save' (p: material_code, basis, qty, loss, startup, operation),
-- 'bom_delete' (p: line_id)
create or replace function app.admin_spec_edit(p_spec uuid, p_action text, p jsonb, p_reason text)
 returns void language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare s master.product_specs; pr master.products; v_req uuid; v_what text; v_plans int;
begin
  if not core.is_admin() then raise exception 'Chỉ Quản trị hệ thống sửa spec đã phát hành / đang duyệt'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Ghi lý do sửa spec'; end if;
  select * into s from master.product_specs where id = p_spec;
  if not found then raise exception 'Không tìm thấy spec'; end if;
  if s.status = 'OBSOLETE' then raise exception 'Spec v% đã thay bằng bản mới: sửa bản hiện hành', s.version; end if;
  select * into pr from master.products where id = s.product_id;
  if p_action = 'bom_delete' and not exists (
       select 1 from master.bom_lines l join master.bom_headers h on h.id = l.bom_id
        where l.id = (p ->> 'line_id')::uuid and h.spec_id = p_spec) then
    raise exception 'Dòng BOM không thuộc spec này';
  end if;

  perform set_config('bmt.admin_spec_edit', 'on', true);
  if p_action = 'spec' then
    perform app.update_spec_draft(p_spec, p);
    if coalesce(trim(p ->> 'brand'), '') <> '' and s.product_id is not null and pr.default_brand is distinct from trim(p ->> 'brand') then
      update master.products set default_brand = trim(p ->> 'brand') where id = s.product_id;
    end if;
    v_what := 'thông số';
  elsif p_action = 'bom_save' then
    perform app.save_bom_line(p_spec, p ->> 'material_code', p ->> 'basis', (p ->> 'qty')::numeric,
      nullif(p ->> 'loss', '')::numeric, coalesce(nullif(p ->> 'startup', '')::numeric, 0), p ->> 'operation');
    v_what := 'BOM ' || upper(trim(p ->> 'material_code'));
  elsif p_action = 'bom_delete' then
    v_what := 'xóa dòng BOM ' || (select m.code from master.bom_lines l join master.materials m on m.id = l.material_id where l.id = (p ->> 'line_id')::uuid);
    perform app.delete_bom_line((p ->> 'line_id')::uuid);
  else
    raise exception 'Thao tác không hợp lệ';
  end if;
  perform set_config('bmt.admin_spec_edit', 'off', true);

  -- Đang chờ duyệt: ghi lịch sử duyệt, cập nhật mã kiểm để duyệt tiếp được
  select id into v_req from wf.approval_requests where doc_id = p_spec and status = 'PENDING' order by submitted_at desc limit 1;
  if v_req is not null then perform wf.log_review_edit(v_req, '[Quản trị] ' || v_what || '. Lý do: ' || trim(p_reason)); end if;
  -- Spec đã phát hành: kế hoạch đang dùng spec này cần chạy lại MRP
  if s.status = 'RELEASED' then
    update plan.production_plans pp set mrp_stale = true
     where pp.status in ('DRAFT', 'PENDING_APPROVAL', 'APPROVED') and not pp.mrp_stale
       and exists (select 1 from plan.plan_lines l where l.plan_id = pp.id and l.spec_id = p_spec);
    get diagnostics v_plans = row_count;
    if v_plans > 0 then
      perform wf.notify_users(array(select distinct ur.user_id from core.user_roles ur where ur.role_code in ('SX_TP', 'SX_KH', 'MUA_TP')),
        'Quản trị sửa spec ' || pr.code || ' v' || s.version,
        format('%s. Lý do: %s. %s kế hoạch đang dùng mã này cần chạy lại MRP.', v_what, trim(p_reason), v_plans), '/san-pham/' || pr.code);
    end if;
  end if;
  perform app.admin_log('master.product_specs', p_spec::text, 'ADMIN_SPEC', jsonb_build_object('status', s.status),
    jsonb_build_object('doc_type', 'Sửa spec', 'doc_no', pr.code || ' v' || s.version, 'what', v_what, 'detail', p, 'reason', trim(p_reason)));
end $$;
revoke execute on function app.admin_spec_edit(uuid, text, jsonb, text) from public, anon;
grant execute on function app.admin_spec_edit(uuid, text, jsonb, text) to authenticated;

select pg_temp.patch('app.admin_overrides',
  $o$'ADMIN_STOCK', 'ADMIN_COST', 'ADMIN_PO')$o$, $n$'ADMIN_STOCK', 'ADMIN_COST', 'ADMIN_PO', 'ADMIN_SPEC')$n$);
