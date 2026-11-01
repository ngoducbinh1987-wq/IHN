-- Quản trị hệ thống xóa phiên bản spec (anh Bình yêu cầu 01/11/2026), mọi trạng thái: nháp, đang duyệt, đã phát hành, cũ.
-- Không xóa được khi phiên bản đang được dùng (dòng kế hoạch, lệnh SX, lô, đơn bán, phiếu QC) hoặc là phiên bản duy nhất của mã.
-- Xóa phiên bản hiện hành: mã chuyển sang phiên bản mới nhất còn lại (ưu tiên bản đã phát hành / cũ – bản cũ được phát hành lại).
create or replace function app.admin_spec_delete(p_spec uuid, p_reason text)
 returns text language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare s master.product_specs; pr master.products; v_no text; v_next master.product_specs; v_lines jsonb; v_used text; q record;
begin
  if not core.is_admin() then raise exception 'Chỉ Quản trị hệ thống xóa phiên bản spec'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Ghi lý do xóa phiên bản'; end if;
  select * into s from master.product_specs where id = p_spec for update;
  if not found then raise exception 'Không tìm thấy phiên bản spec'; end if;
  select * into pr from master.products where id = s.product_id for update;
  v_no := pr.code || ' v' || s.version;

  select string_agg(x, ', ') into v_used from (
    select 'kế hoạch ' || string_agg(distinct pp.plan_no, ', ') x from plan.plan_lines l join plan.production_plans pp on pp.id = l.plan_id
     where l.spec_id = p_spec having count(*) > 0
    union all select 'lệnh SX ' || string_agg(distinct w.wo_no, ', ') from mfg.work_orders w where w.spec_id = p_spec having count(*) > 0
    union all select count(*) || ' lô hàng' from inv.lots l where l.spec_id = p_spec having count(*) > 0
    union all select count(*) || ' dòng đơn bán' from sales.so_lines l where l.spec_id = p_spec having count(*) > 0
    union all select count(*) || ' phiếu QC' from qa.inspections i where i.spec_id = p_spec having count(*) > 0) t;
  if v_used is not null then
    raise exception 'Không xóa được % vì đang được dùng (%): xóa / sửa các chứng từ đó trước', v_no, v_used;
  end if;

  if pr.current_spec_id = p_spec then
    select * into v_next from master.product_specs x where x.product_id = s.product_id and x.id <> p_spec
     order by (x.status in ('RELEASED', 'OBSOLETE')) desc, x.version desc limit 1;
    if not found then raise exception '% là phiên bản duy nhất của mã: không xóa được', v_no; end if;
    if v_next.status = 'OBSOLETE' then
      perform set_config('bmt.allow_release', 'on', true);
      update master.product_specs set status = 'RELEASED' where id = v_next.id;
      update master.bom_headers set status = 'RELEASED' where spec_id = v_next.id;
      perform set_config('bmt.allow_release', 'off', true);
    end if;
    update master.products set current_spec_id = v_next.id where id = s.product_id;
  end if;

  -- Dừng quy trình duyệt đang chạy của phiên bản
  for q in select * from wf.approval_requests where doc_id = p_spec and status = 'PENDING' for update loop
    update wf.approval_requests set status = 'CANCELLED', finished_at = now() where id = q.id;
    insert into wf.approval_actions (request_id, seq, action, comment, data_hash)
    values (q.id, coalesce(q.current_seq, 0), 'COMMENT', '[Quản trị xóa phiên bản spec] ' || trim(p_reason), q.data_hash);
  end loop;

  v_lines := (select jsonb_agg(to_jsonb(l)) from master.bom_lines l join master.bom_headers h on h.id = l.bom_id where h.spec_id = p_spec);
  perform set_config('bmt.admin_spec_edit', 'on', true);   -- dòng BOM đã phát hành
  delete from master.bom_lines l using master.bom_headers h where h.id = l.bom_id and h.spec_id = p_spec;
  perform set_config('bmt.admin_spec_edit', 'off', true);
  begin
    delete from master.product_specs where id = p_spec;
  exception when foreign_key_violation then
    raise exception 'Không xóa được % vì dữ liệu khác đang dùng (%)', v_no, coalesce(substring(sqlerrm from 'on table "([^"]+)"'), 'chứng từ liên quan');
  end;

  perform app.admin_log('master.product_specs', p_spec::text, 'ADMIN_DELETE',
    jsonb_build_object('doc', to_jsonb(s), 'lines', v_lines),
    jsonb_build_object('doc_type', 'Xóa phiên bản spec', 'doc_no', v_no, 'reason', trim(p_reason),
                       'current_now', case when v_next.id is not null then pr.code || ' v' || v_next.version end));
  return v_no;
end $$;
revoke execute on function app.admin_spec_delete(uuid, text) from public, anon;
grant execute on function app.admin_spec_delete(uuid, text) to authenticated;
