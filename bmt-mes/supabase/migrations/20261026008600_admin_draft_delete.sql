-- Quản trị hệ thống xóa được chứng từ ở trạng thái Nháp (anh Bình yêu cầu 04/11/2026, ảnh danh sách Kế hoạch: KH-2611-01 Nháp).
-- Lỗi gốc: KH-2611-01 từng được duyệt, có đề xuất hiệu chỉnh PDC-2611-002 (đã áp) trỏ vào dòng kế hoạch; sau khi mở lại về Nháp
-- thì xóa bị chặn "dữ liệu khác đang dùng (plan_lines)" vì plan_adjustment_lines.plan_line_id không xóa theo.
-- Sửa app.admin_doc:
--  1. Xóa kế hoạch: xóa kèm các đề xuất hiệu chỉnh của chính kế hoạch đó (dừng quy trình đang chạy, lưu bản sao vào nhật ký);
--     chặn khi kế hoạch đã sinh đơn mua chưa hủy (như đề xuất mua).
--  2. Thêm loại PLAN_ADJ (Đề xuất hiệu chỉnh kế hoạch tháng): mở lại / xóa khi chưa áp (nháp, chờ duyệt, bị trả lại);
--     đã duyệt (đã áp vào kế hoạch) thì chặn.
--  3. Bị chặn vì khóa ngoại: báo đúng bảng đang dùng chứng từ (trước báo nhầm tên bảng của chính chứng từ).

create or replace function app.admin_doc(p_doc_type text, p_doc_id uuid, p_action text, p_reason text)
 returns text language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $function$
declare
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_table text; v_rel regclass; v_old jsonb; v_lines jsonb; v_extra jsonb; v_no text; v_creator uuid; v_ref text; q record;
  v_fk_table text;
begin
  if not core.is_admin() then raise exception 'Chỉ Quản trị hệ thống được mở lại hoặc xóa chứng từ'; end if;
  if v_reason is null then raise exception 'Nhập lý do'; end if;
  if p_action not in ('reopen', 'delete') then raise exception 'Thao tác không hợp lệ'; end if;
  if p_doc_type not in ('PR', 'PO', 'SO', 'PLAN', 'PROPOSAL', 'SPEC_NEW', 'SPEC_MINOR', 'DPS', 'PLAN_ADJ') then
    raise exception 'Loại chứng từ này không mở lại/xóa ở đây: phiếu kho đã ghi sổ dùng phiếu đảo, lệnh SX và phiếu lĩnh dùng chức năng hủy sẵn có';
  end if;
  if p_doc_type = 'DPS' and p_action = 'reopen' then raise exception 'Đơn phát sinh không mở lại được: xóa rồi lập đơn mới'; end if;
  v_table := case when p_doc_type = 'DPS' then 'plan.change_requests'
                  when p_doc_type = 'PLAN_ADJ' then 'plan.plan_adjustments'
                  else (select doc_table from wf.approval_flows where doc_type = p_doc_type) end;
  v_rel := v_table::regclass;
  execute format('select to_jsonb(t) from %s t where id = $1', v_rel) into v_old using p_doc_id;
  if v_old is null then raise exception 'Không tìm thấy chứng từ'; end if;
  v_no := coalesce(wf.doc_number(v_table, p_doc_id), v_old ->> 'adj_no', v_old ->> 'req_no', p_doc_type);
  v_creator := nullif(v_old ->> 'created_by', '')::uuid;

  -- Chứng từ đã sinh nghiệp vụ sau: phải xử lý chứng từ sau trước
  if p_doc_type = 'PR' then
    select string_agg(distinct po.po_no, ', ') into v_ref from purchase.pr_lines l
      join purchase.po_lines pl on pl.pr_line_id = l.id join purchase.purchase_orders po on po.id = pl.po_id where l.pr_id = p_doc_id;
    if v_ref is not null then raise exception 'Đề xuất % đã lên PO %: xử lý PO trước', v_no, v_ref; end if;
    v_lines := (select jsonb_agg(to_jsonb(l)) from purchase.pr_lines l where l.pr_id = p_doc_id);
  elsif p_doc_type = 'PO' then
    select string_agg(gr_no, ', ') into v_ref from purchase.goods_receipts where po_id = p_doc_id;
    if v_ref is not null then raise exception 'PO % đã nhận hàng (%): không mở lại/xóa được', v_no, v_ref; end if;
    v_lines := (select jsonb_agg(to_jsonb(l)) from purchase.po_lines l where l.po_id = p_doc_id);
  elsif p_doc_type = 'SO' then
    select string_agg(delivery_no, ', ') into v_ref from sales.deliveries where so_id = p_doc_id and status <> 'CANCELLED';
    if v_ref is not null then raise exception 'Đơn bán % đã có lệnh giao %: xử lý lệnh giao trước', v_no, v_ref; end if;
    select string_agg(distinct p.plan_no, ', ') into v_ref from sales.so_lines l
      join plan.plan_lines pl on pl.so_line_id = l.id join plan.production_plans p on p.id = pl.plan_id where l.so_id = p_doc_id;
    if v_ref is not null then raise exception 'Đơn bán % đã đưa vào kế hoạch %: sửa kế hoạch trước', v_no, v_ref; end if;
    v_lines := (select jsonb_agg(to_jsonb(l)) from sales.so_lines l where l.so_id = p_doc_id);
  elsif p_doc_type = 'PLAN' then
    select string_agg(w.wo_no, ', ') into v_ref from mfg.work_orders w join plan.plan_lines l on l.id = w.plan_line_id where l.plan_id = p_doc_id;
    if v_ref is not null then raise exception 'Kế hoạch % đã có lệnh SX %: không mở lại/xóa được', v_no, v_ref; end if;
    v_lines := (select jsonb_agg(to_jsonb(l)) from plan.plan_lines l where l.plan_id = p_doc_id);
  elsif p_doc_type = 'PLAN_ADJ' then
    if v_old ->> 'status' = 'APPROVED' then
      raise exception 'Đề xuất hiệu chỉnh % đã duyệt và đã áp vào kế hoạch: không mở lại/xóa được (lập đề xuất hiệu chỉnh mới)', v_no;
    end if;
    v_lines := (select jsonb_agg(to_jsonb(l)) from plan.plan_adjustment_lines l where l.adj_id = p_doc_id);
  elsif p_doc_type = 'PROPOSAL' then
    select string_agg(distinct po.po_no, ', ') into v_ref from plan.proposal_lines l
      join purchase.po_lines pl on pl.proposal_line_id = l.id join purchase.purchase_orders po on po.id = pl.po_id where l.proposal_id = p_doc_id;
    if v_ref is not null then raise exception 'Đề xuất mua tối ưu % đã lên PO %: xử lý PO trước', v_no, v_ref; end if;
    v_lines := (select jsonb_agg(to_jsonb(l)) from plan.proposal_lines l where l.proposal_id = p_doc_id);
  elsif p_doc_type like 'SPEC%' then
    if v_old ->> 'status' in ('RELEASED', 'OBSOLETE') then
      raise exception 'Spec % đã phát hành: tạo phiên bản mới thay vì mở lại/xóa', v_no;
    end if;
    v_lines := (select jsonb_agg(to_jsonb(l)) from master.bom_lines l join master.bom_headers h on h.id = l.bom_id where h.spec_id = p_doc_id);
  end if;

  -- Dừng quy trình duyệt đang chạy của chứng từ (nếu có)
  for q in select * from wf.approval_requests where doc_id = p_doc_id and status = 'PENDING' for update loop
    update wf.approval_requests set status = 'CANCELLED', finished_at = now() where id = q.id;
    insert into wf.approval_actions (request_id, seq, action, comment, data_hash)
    values (q.id, coalesce(q.current_seq, 0), 'COMMENT',
            '[Quản trị ' || case p_action when 'delete' then 'xóa chứng từ' else 'mở lại để sửa' end || '] ' || v_reason, q.data_hash);
  end loop;

  if p_action = 'reopen' then
    execute format('update %s set status = ''DRAFT'' where id = $1', v_rel) using p_doc_id;
  else
    if p_doc_type = 'PLAN' then
      select string_agg(pr.pr_no, ', ') into v_ref from purchase.purchase_requests pr
        join plan.mrp_runs m on m.id = pr.mrp_run_id where m.plan_id = p_doc_id;
      if v_ref is not null then raise exception 'Kế hoạch % đã sinh đề xuất mua %: xóa các đề xuất đó trước', v_no, v_ref; end if;
      select string_agg(distinct po.po_no, ', ') into v_ref from purchase.purchase_orders po
       where po.status <> 'CANCELLED'
         and (po.plan_id = p_doc_id or po.mrp_run_id in (select id from plan.mrp_runs where plan_id = p_doc_id));
      if v_ref is not null then raise exception 'Kế hoạch % đã sinh đơn mua %: xóa hoặc hủy các đơn mua đó trước', v_no, v_ref; end if;
      -- Đề xuất hiệu chỉnh của chính kế hoạch: dừng quy trình, lưu bản sao, xóa cùng kế hoạch
      v_extra := (select jsonb_agg(to_jsonb(a) || jsonb_build_object('lines',
                    (select jsonb_agg(to_jsonb(l)) from plan.plan_adjustment_lines l where l.adj_id = a.id)))
                    from plan.plan_adjustments a where a.plan_id = p_doc_id);
      for q in select r.* from wf.approval_requests r join plan.plan_adjustments a on a.id = r.doc_id
                where a.plan_id = p_doc_id and r.status = 'PENDING' for update of r loop
        update wf.approval_requests set status = 'CANCELLED', finished_at = now() where id = q.id;
        insert into wf.approval_actions (request_id, seq, action, comment, data_hash)
        values (q.id, coalesce(q.current_seq, 0), 'COMMENT', '[Quản trị xóa kế hoạch ' || v_no || '] ' || v_reason, q.data_hash);
      end loop;
      delete from plan.plan_adjustment_lines l
       where l.adj_id in (select id from plan.plan_adjustments where plan_id = p_doc_id)
          or l.plan_line_id in (select id from plan.plan_lines where plan_id = p_doc_id)
          or l.new_line_id in (select id from plan.plan_lines where plan_id = p_doc_id);
      delete from plan.plan_adjustments where plan_id = p_doc_id;
      update plan.production_plans set previous_id = null where previous_id = p_doc_id;
      delete from plan.daily_releases where plan_id = p_doc_id;
      delete from plan.mrp_line_edits where plan_id = p_doc_id;
      delete from plan.mrp_runs where plan_id = p_doc_id;
    elsif p_doc_type = 'PLAN_ADJ' then
      delete from plan.plan_adjustment_lines where adj_id = p_doc_id;
    elsif p_doc_type = 'SO' then
      delete from sales.deliveries where so_id = p_doc_id and status = 'CANCELLED';
    end if;
    begin
      execute format('delete from %s where id = $1', v_rel) using p_doc_id;
    exception when foreign_key_violation then
      get stacked diagnostics v_fk_table = table_name;
      raise exception 'Không xóa được % vì dữ liệu khác đang dùng (%): mở lại để sửa hoặc xử lý chứng từ liên quan trước',
        v_no, coalesce(nullif(v_fk_table, ''), substring(sqlerrm from 'on table "([^"]+)"$'), 'chứng từ liên quan');
    end;
  end if;

  insert into core.audit_log (user_id, table_name, row_id, action, old_data, new_data)
  values (auth.uid(), v_table, p_doc_id::text, case p_action when 'delete' then 'ADMIN_DELETE' else 'ADMIN_REOPEN' end,
          jsonb_strip_nulls(jsonb_build_object('doc', v_old, 'lines', v_lines, 'adjustments', v_extra)),
          jsonb_build_object('doc_type', p_doc_type, 'doc_no', v_no, 'reason', v_reason));
  if v_creator is not null and v_creator <> auth.uid() and exists (select 1 from core.profiles where id = v_creator) then
    insert into wf.notifications (user_id, title, body, link)
    values (v_creator, case p_action when 'delete' then 'Quản trị đã xóa ' else 'Quản trị đã mở lại để sửa ' end || v_no, v_reason, null);
  end if;
  return v_no;
end $function$;
revoke execute on function app.admin_doc(text, uuid, text, text) from public, anon;
grant execute on function app.admin_doc(text, uuid, text, text) to authenticated;
