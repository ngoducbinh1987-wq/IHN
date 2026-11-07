-- Anh Bình 07/11/2026: Đề xuất hiệu chỉnh kế hoạch tháng
--   * mở ra thấy danh mục sản xuất của tháng cần hiệu chỉnh (web: bảng dòng kế hoạch, cột sau hiệu chỉnh);
--   * nút "Chạy MRP hiệu chỉnh": bảng đủ cột MRP ban đầu (cấp SX theo lần MRP gần nhất của kế hoạch), MRP hiện tại (sau hiệu chỉnh),
--     chênh lệch, tồn kho, hàng về, đã đề xuất, dự phòng tồn kho, thiếu, đề xuất mua, tồn sau SX.
-- Kết quả chạy thử lưu ở bảng riêng plan.adj_mrp_previews (không lưu vào plan_adjustments: mã kiểm duyệt băm cả dòng),
-- mở lại trang dùng kết quả đã lưu; sửa dòng đề xuất hoặc kế hoạch chạy MRP lại thì MES tự chạy lại.

create table if not exists plan.adj_mrp_previews (
  adj_id uuid primary key references plan.plan_adjustments(id) on delete cascade,
  result jsonb not null,
  old_run_id uuid,
  lines_hash text,
  run_at timestamptz not null default now(),
  run_by uuid
);
alter table plan.adj_mrp_previews enable row level security;
revoke all on plan.adj_mrp_previews from public, anon, authenticated;

-- Bảng MRP hiệu chỉnh đủ vật tư: so lần MRP trước (p_old) với lần MRP sau hiệu chỉnh (p_new)
create or replace function plan.adj_mrp_table(p_old uuid, p_new uuid) returns jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
  with o as (select material_id, total_issue from plan.mrp_lines where run_id = p_old),
  n as (select * from plan.mrp_lines where run_id = p_new),
  mats as (select material_id from o union select material_id from n),
  rw as (
    select mt.code, mt.name, mt.uom, coalesce(o.total_issue, 0) as mrp_old, coalesce(n.total_issue, 0) as mrp_new,
           n.available, n.incoming, n.requested, n.reserve, n.net_short, coalesce(n.suggest_qty, 0) as suggest,
           n.projected + n.suggest_qty as projected_after, n.material_id is not null as has_new
    from mats join master.materials mt on mt.id = mats.material_id
    left join o on o.material_id = mats.material_id left join n on n.material_id = mats.material_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', code, 'name', name, 'uom', uom, 'mrp_old', round(mrp_old, 3), 'mrp_new', round(mrp_new, 3),
           'diff', round(mrp_new - mrp_old, 3), 'available', round(available, 3), 'incoming', round(incoming, 3),
           'requested', round(requested, 3), 'reserve', round(reserve, 3), 'shortage', round(net_short, 3),
           'suggest', round(suggest, 3), 'projected_after', round(projected_after, 3))
         order by case when suggest > 0 then 0 when round(mrp_new - mrp_old, 3) <> 0 then 1 else 2 end, code), '[]')
  from rw
$$;
revoke all on function plan.adj_mrp_table(uuid, uuid) from public, anon, authenticated;

create or replace function plan.adj_lines_hash(p_adj uuid) returns text
language sql stable security definer set search_path = pg_catalog, public as $$
  select md5(coalesce(jsonb_agg(to_jsonb(l) - 'id' - 'new_line_id' order by l.line_no), '[]')::text)
  from plan.plan_adjustment_lines l where l.adj_id = p_adj
$$;
revoke all on function plan.adj_lines_hash(uuid) from public, anon, authenticated;

-- Chạy thử: áp dòng + MRP hiệu chỉnh trong giao dịch con rồi hủy, lưu kết quả
create or replace function plan.adj_preview(p_adj uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v jsonb; v_old uuid;
begin
  begin
    perform plan.check_adjustment(p_adj);
    perform plan.apply_adjustment_lines(p_adj);
    v := plan.revise_mrp(p_adj);
    v := v || jsonb_build_object('table', plan.adj_mrp_table((v ->> 'old_run_id')::uuid, (v ->> 'run_id')::uuid));
    raise exception 'BMT_PREVIEW_ROLLBACK';
  exception when others then
    if sqlerrm <> 'BMT_PREVIEW_ROLLBACK' then return jsonb_build_object('rows', '[]', 'table', '[]', 'error', sqlerrm); end if;
  end;
  v_old := (v ->> 'old_run_id')::uuid;
  v := v - 'run_id' - 'old_run_id' || jsonb_build_object('preview', true, 'at', now(), 'by_name', app.user_name(auth.uid()));
  insert into plan.adj_mrp_previews (adj_id, result, old_run_id, lines_hash, run_at, run_by)
  values (p_adj, v, v_old, plan.adj_lines_hash(p_adj), now(), auth.uid())
  on conflict (adj_id) do update set result = excluded.result, old_run_id = excluded.old_run_id, lines_hash = excluded.lines_hash,
                                     run_at = excluded.run_at, run_by = excluded.run_by;
  return v;
end $$;
revoke all on function plan.adj_preview(uuid) from public, anon, authenticated;

-- Bảng MRP hiệu chỉnh: đã duyệt → kết quả lúc áp; nháp / chờ duyệt → kết quả lần chạy gần nhất nếu còn đúng
-- (cùng dòng đề xuất, kế hoạch chưa chạy MRP lại), không thì chạy thử lại
create or replace function app.adj_mrp(p_adj uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare a plan.plan_adjustments; v jsonb; p plan.adj_mrp_previews; v_last uuid;
begin
  if not core.has_perm('plan', 'view') then raise exception 'Không có quyền xem kế hoạch'; end if;
  select * into a from plan.plan_adjustments where id = p_adj;
  if not found then raise exception 'Không tìm thấy đề xuất hiệu chỉnh'; end if;
  if a.status = 'APPROVED' then
    v := coalesce(a.mrp_result, jsonb_build_object('rows', '[]'));
    if not v ? 'table' and v ? 'run_id' then
      v := v || jsonb_build_object('table', plan.adj_mrp_table((v ->> 'old_run_id')::uuid, (v ->> 'run_id')::uuid));
    end if;
    return v - 'run_id' - 'old_run_id' || jsonb_build_object('applied', true);
  end if;
  if a.status = 'CANCELLED' then return jsonb_build_object('rows', '[]', 'table', '[]', 'error', 'Đề xuất đã hủy'); end if;
  select r.id into v_last from plan.mrp_runs r where r.plan_id = a.plan_id order by r.run_at desc limit 1;
  select * into p from plan.adj_mrp_previews where adj_id = p_adj;
  if found and p.old_run_id is not distinct from v_last and p.lines_hash = plan.adj_lines_hash(p_adj) then
    return p.result || jsonb_build_object('cached', true);
  end if;
  return plan.adj_preview(p_adj);
end $$;
revoke all on function app.adj_mrp(uuid) from public, anon;
grant execute on function app.adj_mrp(uuid) to authenticated;

-- Nút "Chạy MRP hiệu chỉnh": chạy lại theo tồn kho, hàng về, đơn mua hiện tại
create or replace function app.adj_run_mrp(p_adj uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare a plan.plan_adjustments;
begin
  if not core.has_perm('plan', 'view') then raise exception 'Không có quyền xem kế hoạch'; end if;
  select * into a from plan.plan_adjustments where id = p_adj;
  if not found then raise exception 'Không tìm thấy đề xuất hiệu chỉnh'; end if;
  if a.status not in ('DRAFT', 'PENDING_APPROVAL') then
    raise exception 'Đề xuất đã duyệt hoặc đã hủy: MRP hiệu chỉnh đã chốt lúc duyệt';
  end if;
  if not exists (select 1 from plan.plan_adjustment_lines where adj_id = p_adj) then
    raise exception 'Đề xuất chưa có dòng: thêm dòng hiệu chỉnh, Lưu nháp rồi chạy MRP';
  end if;
  return plan.adj_preview(p_adj);
end $$;
revoke all on function app.adj_run_mrp(uuid) from public, anon;
grant execute on function app.adj_run_mrp(uuid) to authenticated;
