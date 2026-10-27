-- Kế hoạch tháng: chọn đúng tháng/năm, một tháng một kế hoạch, bỏ chế độ sơ bộ; đề xuất hiệu chỉnh kế hoạch tháng
-- (TP SX lập → Giám đốc duyệt → Chủ tịch HĐQT duyệt) kèm bảng MRP hiệu chỉnh.
-- Yêu cầu anh Bình 27/10/2026 23:45:
--   * Kỳ kế hoạch là tháng + năm (12 tháng của năm nay, năm sau); một tháng chỉ một kế hoạch; mọi kế hoạch là chính thức.
--   * Đề xuất hiệu chỉnh (thêm mã, đổi sản lượng tăng/giảm, đổi hạn, bỏ mã) cho kế hoạch đã duyệt.
--   * Khối lượng giảm: vật tư Giám đốc đã duyệt mua theo kế hoạch trước giữ nguyên; đề xuất mua chưa duyệt (nháp, chờ duyệt)
--     của kế hoạch này MES tự giảm theo bảng MRP hiệu chỉnh. Khối lượng tăng: MRP hiệu chỉnh ra số mua thêm.
-- Bảng MRP hiệu chỉnh xem trước được khi lập/duyệt (chạy thử trong giao dịch con rồi hủy), áp thật khi Chủ tịch duyệt.

-- ===========================================================================
-- 1. Kỳ kế hoạch theo tháng, một tháng một kế hoạch
-- ===========================================================================
alter table plan.production_plans add column if not exists period_month date;
alter table plan.production_plans alter column mode set default 'OFFICIAL';

-- Điền tháng cho kế hoạch có sẵn từ nhãn "Tháng 11" / "Tháng 11/2026" (năm lấy theo ngày lập; mỗi tháng chỉ lấy kế hoạch đầu tiên)
with p as (
  select id, created_at, (regexp_match(period_label, '(?i)th[áa]ng\s*0?([0-9]{1,2})(?:\s*[/.-]\s*([0-9]{4}))?')) as m
  from plan.production_plans where period_month is null and status <> 'CANCELLED'
), d as (
  select id, created_at,
         case when m is null or m[1]::int not between 1 and 12 then null
              else make_date(coalesce(m[2]::int,
                                      extract(year from created_at at time zone 'Asia/Ho_Chi_Minh')::int
                                      + case when m[1]::int < extract(month from created_at at time zone 'Asia/Ho_Chi_Minh')::int - 6 then 1 else 0 end),
                             m[1]::int, 1) end as pm
  from p
), u as (
  select id, pm, row_number() over (partition by pm order by created_at) as rn from d where pm is not null
)
update plan.production_plans x set period_month = u.pm from u where u.id = x.id and u.rn = 1;

create unique index if not exists production_plans_one_per_month on plan.production_plans (period_month)
  where status <> 'CANCELLED' and period_month is not null;

-- TP SX / Kế hoạch SX lập kế hoạch tháng: chọn tháng + năm, MES đặt nhãn "Tháng MM/YYYY", chế độ chính thức
create or replace function app.create_plan(p_year int, p_month int, p_need_date date) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_today date := (now() at time zone 'Asia/Ho_Chi_Minh')::date; v_y int; v_month date; v_dup text; v_no text; v_id uuid;
begin
  if not core.has_perm('plan', 'create') then raise exception 'Không có quyền lập kế hoạch sản xuất'; end if;
  v_y := extract(year from v_today)::int;
  if p_month is null or p_month not between 1 and 12 then raise exception 'Chọn tháng của kế hoạch (1–12)'; end if;
  if p_year is null or p_year not between v_y and v_y + 1 then raise exception 'Chọn năm % hoặc %', v_y, v_y + 1; end if;
  if p_need_date is null then raise exception 'Nhập ngày cần vật tư'; end if;
  v_month := make_date(p_year, p_month, 1);
  select plan_no into v_dup from plan.production_plans where period_month = v_month and status <> 'CANCELLED' limit 1;
  if v_dup is not null then
    raise exception 'Tháng %/% đã có kế hoạch %: muốn tăng, giảm sản lượng thì lập Đề xuất hiệu chỉnh kế hoạch tháng',
      lpad(p_month::text, 2, '0'), p_year, v_dup;
  end if;
  v_no := core.next_no('KH', 2);
  insert into plan.production_plans (plan_no, period_label, period_month, material_need_date, mode)
  values (v_no, 'Tháng ' || lpad(p_month::text, 2, '0') || '/' || p_year, v_month, p_need_date, 'OFFICIAL')
  returning id into v_id;
  return v_id;
end $$;
revoke all on function app.create_plan(int, int, date) from public, anon;
grant execute on function app.create_plan(int, int, date) to authenticated;

-- ===========================================================================
-- 2. Quy trình đề xuất hiệu chỉnh: TP SX lập → Giám đốc duyệt → Chủ tịch HĐQT duyệt
-- ===========================================================================
update wf.approval_flows set name = 'Đề xuất hiệu chỉnh kế hoạch tháng', submit_label = 'TP SX lập đề xuất hiệu chỉnh kế hoạch tháng'
 where doc_type = 'PLAN_ADJ';
do $$ begin
  if not exists (select 1 from wf.approval_steps where doc_type = 'PLAN_ADJ' and level_label like 'Giám đốc%') then
    update wf.approval_steps set seq = seq + 100 where doc_type = 'PLAN_ADJ';
    update wf.approval_steps set seq = seq - 99 where doc_type = 'PLAN_ADJ';
    insert into wf.approval_steps (doc_type, seq, level_label, role_code, enabled, sla_hours, assignee_ids)
    select 'PLAN_ADJ', 1, 'Giám đốc duyệt đề xuất hiệu chỉnh kế hoạch tháng', 'BGD', true, 24,
           coalesce((select assignee_ids from wf.approval_steps where doc_type = 'PLAN' and seq = 1), '{}');
    update wf.approval_steps set level_label = 'Chủ tịch HĐQT duyệt hiệu chỉnh kế hoạch tháng'
     where doc_type = 'PLAN_ADJ' and seq = 2;
  end if;
end $$;

-- ===========================================================================
-- 3. MRP: đề xuất mua nháp cũng tính là "đã đề xuất" (không đề xuất trùng khi chạy lại); bỏ nhắc chế độ sơ bộ
-- ===========================================================================
do $$
declare v_def text; v_new text;
begin
  v_def := replace(pg_get_functiondef('plan.run_mrp(uuid, jsonb)'::regprocedure), chr(13), '');
  v_new := replace(v_def, $q$where pr.status in ('PENDING_APPROVAL', 'APPROVED', 'PARTIAL_PO')$q$,
                          $q$where pr.status in ('DRAFT', 'PENDING_APPROVAL', 'APPROVED', 'PARTIAL_PO')$q$);
  v_new := replace(v_new, 'Chuyển kế hoạch sang chế độ sơ bộ hoặc chờ KT/QA duyệt (BR-SP-01)', 'Chờ TP KT/QA phát hành spec (BR-SP-01)');
  if v_new = v_def and position($q$'DRAFT', 'PENDING_APPROVAL', 'APPROVED', 'PARTIAL_PO'$q$ in v_def) = 0 then
    raise exception 'Không tìm thấy đoạn requested trong plan.run_mrp';
  end if;
  if v_new <> v_def then execute v_new; end if;
end $$;

-- ===========================================================================
-- 4. Áp đề xuất hiệu chỉnh + MRP hiệu chỉnh
-- ===========================================================================
alter table plan.plan_adjustments add column if not exists mrp_run_id uuid references plan.mrp_runs(id) on delete set null;
alter table plan.plan_adjustments add column if not exists mrp_result jsonb;

-- Áp các dòng vào kế hoạch tháng (tách khỏi trigger để xem trước dùng lại)
create or replace function plan.apply_adjustment_lines(p_adj uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare a plan.plan_adjustments; l record; v_line uuid; p master.products;
begin
  select * into a from plan.plan_adjustments where id = p_adj;
  for l in select * from plan.plan_adjustment_lines where adj_id = p_adj order by line_no loop
    if l.kind = 'ADD' then
      select * into p from master.products where id = l.product_id;
      insert into plan.plan_lines (plan_id, product_id, spec_id, qty_m, run_lots, m_per_pack, pack_type, brand, wo_note, due_date, priority, adjustment_id)
      values (a.plan_id, p.id, p.current_spec_id, l.qty_m, 1, coalesce(p.default_m_per_pack, 500), coalesce(p.default_pack, 'Bobin gỗ'),
              coalesce(p.default_brand, 'KAVIX'), 'Hiệu chỉnh ' || a.adj_no || coalesce(' · ' || l.note, ''), l.due_date, coalesce(l.priority, 1), a.id)
      returning id into v_line;
      update plan.plan_adjustment_lines set new_line_id = v_line where id = l.id;
    elsif l.kind = 'QTY' then
      update plan.plan_lines set qty_m = l.qty_m, lot_approved_at = null, lot_approved_by = null, lot_version_id = null where id = l.plan_line_id;
      update mfg.work_orders set qty_m = l.qty_m where plan_line_id = l.plan_line_id and status in ('DRAFT', 'RELEASED', 'IN_PROGRESS') and l.qty_m > 0;
    elsif l.kind = 'DUE' then
      update plan.plan_lines set due_date = coalesce(l.due_date, due_date), priority = coalesce(l.priority, priority),
             lot_approved_at = null, lot_approved_by = null, lot_version_id = null where id = l.plan_line_id;
    else
      update plan.plan_lines set qty_m = 0, lot_approved_at = null, lot_approved_by = null, lot_version_id = null where id = l.plan_line_id;
      update mfg.work_orders set status = 'CANCELLED' where plan_line_id = l.plan_line_id and status = 'DRAFT';
    end if;
  end loop;
end $$;
revoke all on function plan.apply_adjustment_lines(uuid) from public, anon, authenticated;

-- Chạy MRP hiệu chỉnh sau khi đã áp dòng:
--   1. chạy lại MRP (giữ dự phòng, giữ số TP Mua đã sửa nếu nhu cầu không đổi);
--   2. vật tư thừa (tồn dự kiến > 0) mà kế hoạch này còn đề xuất mua chưa duyệt (nháp, chờ Giám đốc duyệt): giảm các dòng đó,
--      đề xuất mới nhất trước, làm tròn theo bội số đóng gói; đề xuất hết dòng thì hủy (dừng quy trình duyệt nếu đang chờ);
--      đề xuất Giám đốc đã duyệt, đã lên PO giữ nguyên; phần dư chưa đủ một bội số đóng gói thì giữ (PACK);
--   3. có giảm thì chạy lại MRP lần nữa để bảng MRP đúng số "đã đề xuất".
-- Trả về bảng MRP hiệu chỉnh (rows), các dòng đề xuất mua đã giảm (reductions), số vật tư cần mua thêm.
create or replace function plan.revise_mrp(p_adj uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public set timezone = 'Asia/Ho_Chi_Minh' as $$
declare a plan.plan_adjustments; v_plan uuid; v_old uuid; v_reserve jsonb; v_r1 uuid; v_fin uuid; v_pb jsonb;
        m record; pl record; pr record; v_left numeric; v_cut numeric; v_pm numeric; v_red jsonb := '[]'; v_rows jsonb;
        v_prs uuid[] := '{}'; v_note text; v_req uuid; v_hash text; v_buy int;
begin
  select * into a from plan.plan_adjustments where id = p_adj;
  v_plan := a.plan_id;
  select r.id, coalesce(r.snapshot -> 'reserve', '{}') into v_old, v_reserve
    from plan.mrp_runs r where r.plan_id = v_plan order by r.run_at desc limit 1;
  -- Đề xuất mua chưa duyệt của kế hoạch này trước khi hiệu chỉnh
  select coalesce(jsonb_object_agg(material_id::text, q), '{}') into v_pb from (
    select l.material_id, sum(l.qty) as q from purchase.pr_lines l
    join purchase.purchase_requests r on r.id = l.pr_id join plan.mrp_runs mr on mr.id = r.mrp_run_id and mr.plan_id = v_plan
    where r.status in ('DRAFT', 'PENDING_APPROVAL') group by l.material_id) x;

  perform set_config('bmt.chair_edit', 'on', true);
  v_r1 := plan.run_mrp(v_plan, coalesce(v_reserve, '{}'));
  perform plan.carry_mrp_adjust(v_old, v_r1);

  for m in select x.material_id, mt.code, mt.uom, ml.projected, ml.pack_multiple
           from (select distinct l.material_id from purchase.pr_lines l
                 join purchase.purchase_requests r on r.id = l.pr_id join plan.mrp_runs mr on mr.id = r.mrp_run_id and mr.plan_id = v_plan
                 where r.status in ('DRAFT', 'PENDING_APPROVAL') and l.ordered_qty = 0) x
           join master.materials mt on mt.id = x.material_id
           left join plan.mrp_lines ml on ml.run_id = v_r1 and ml.material_id = x.material_id
           order by mt.code loop
    -- không còn nhu cầu (không có dòng MRP): toàn bộ đề xuất chưa duyệt là thừa
    v_left := coalesce(m.projected, 1e15);
    continue when v_left <= 0;
    v_pm := nullif(m.pack_multiple, 0);
    for pl in select l.id, l.qty, r.id as pr_id, r.pr_no, r.status from purchase.pr_lines l
              join purchase.purchase_requests r on r.id = l.pr_id join plan.mrp_runs mr on mr.id = r.mrp_run_id and mr.plan_id = v_plan
              where r.status in ('DRAFT', 'PENDING_APPROVAL') and l.material_id = m.material_id and l.ordered_qty = 0
              order by r.created_at desc, l.qty desc loop
      exit when v_left <= 0;
      if v_left >= pl.qty then v_cut := pl.qty;
      else v_cut := case when v_pm is null then round(v_left, 3) else floor(v_left / v_pm) * v_pm end;
      end if;
      exit when v_cut <= 0;
      if v_cut >= pl.qty then
        delete from purchase.pr_lines where id = pl.id;
      else
        update purchase.pr_lines set qty = qty - v_cut,
               note = left(coalesce(note || ' · ', '') || 'Giảm ' || wf.fmt_qty(v_cut) || ' theo ' || a.adj_no, 500)
         where id = pl.id;
      end if;
      v_left := v_left - v_cut;
      v_red := v_red || jsonb_build_array(jsonb_build_object('pr_id', pl.pr_id, 'pr_no', pl.pr_no, 'status', pl.status,
                 'material_code', m.code, 'uom', m.uom, 'old', pl.qty, 'new', pl.qty - v_cut));
      if not (pl.pr_id = any(v_prs)) then v_prs := v_prs || pl.pr_id; end if;
    end loop;
  end loop;

  -- Đề xuất mua bị giảm: ghi lịch sử duyệt, hủy nếu hết dòng, báo người lập và người duyệt
  for pr in select * from purchase.purchase_requests where id = any(v_prs) loop
    select string_agg(e ->> 'material_code' || ' ' || wf.fmt_qty((e ->> 'old')::numeric) || ' → ' || wf.fmt_qty((e ->> 'new')::numeric)
                      || ' ' || coalesce(e ->> 'uom', ''), '; ')
      into v_note from jsonb_array_elements(v_red) e where (e ->> 'pr_id')::uuid = pr.id;
    select id into v_req from wf.approval_requests where doc_type = 'PR' and doc_id = pr.id and status = 'PENDING'
     order by submitted_at desc limit 1;
    if not exists (select 1 from purchase.pr_lines where pr_id = pr.id) then
      if v_req is not null then
        update wf.approval_requests set status = 'CANCELLED', finished_at = now() where id = v_req;
        insert into wf.approval_actions (request_id, seq, action, comment, data_hash)
        select v_req, coalesce(current_seq, 0), 'COMMENT', left('[Hủy theo hiệu chỉnh kế hoạch ' || a.adj_no || '] không còn cần mua: ' || v_note, 2000), data_hash
        from wf.approval_requests where id = v_req;
      end if;
      update purchase.purchase_requests set status = 'CANCELLED',
             note = left(coalesce(note || ' · ', '') || 'Hủy theo hiệu chỉnh kế hoạch ' || a.adj_no, 500) where id = pr.id;
      v_note := 'Đã hủy (không còn cần mua): ' || v_note;
    else
      if v_req is not null then
        v_hash := wf.doc_hash('purchase.purchase_requests', pr.id);
        insert into wf.approval_actions (request_id, seq, action, comment, data_hash)
        select v_req, coalesce(current_seq, 0), 'COMMENT', left('[Giảm theo hiệu chỉnh kế hoạch ' || a.adj_no || '] ' || v_note, 2000), v_hash
        from wf.approval_requests where id = v_req;
        update wf.approval_requests set data_hash = v_hash where id = v_req;
      end if;
      v_note := 'Đã giảm: ' || v_note;
    end if;
    perform wf.notify_users(array_remove(array[pr.created_by] || coalesce(
        (select array_agg(distinct u) from wf.approval_requests r
           cross join lateral jsonb_array_elements(r.flow_snapshot -> 'steps') s
           cross join lateral unnest(wf.step_actor_ids(s)) u
          where r.id = v_req and r.status = 'PENDING' and (s ->> 'seq')::int = r.current_seq), '{}'), null),
      'Đề xuất mua ' || pr.pr_no || ' giảm theo hiệu chỉnh kế hoạch ' || a.adj_no, left(v_note, 500), '/de-xuat/' || pr.id);
  end loop;

  if jsonb_array_length(v_red) > 0 then
    v_fin := plan.run_mrp(v_plan, coalesce(v_reserve, '{}'));
    perform plan.carry_mrp_adjust(v_r1, v_fin);
  else
    v_fin := v_r1;
  end if;
  perform set_config('bmt.chair_edit', 'off', true);

  with o as (select material_id, total_issue + reserve as need from plan.mrp_lines where run_id = v_old),
  n as (select * from plan.mrp_lines where run_id = v_fin),
  prs as (select r.id, r.status from purchase.purchase_requests r join plan.mrp_runs mr on mr.id = r.mrp_run_id and mr.plan_id = v_plan),
  ap as (select l.material_id, sum(l.qty) as q from purchase.pr_lines l join prs on prs.id = l.pr_id
         where prs.status in ('APPROVED', 'PARTIAL_PO', 'CLOSED') group by l.material_id),
  pa as (select l.material_id, sum(l.qty) as q from purchase.pr_lines l join prs on prs.id = l.pr_id
         where prs.status in ('DRAFT', 'PENDING_APPROVAL') group by l.material_id),
  pb as (select key::uuid as material_id, value::numeric as q from jsonb_each_text(v_pb)),
  mats as (select material_id from o union select material_id from n union select material_id from pb),
  rw as (
    select mt.code, mt.name, mt.uom, coalesce(o.need, 0) as old_need, coalesce(n.total_issue + n.reserve, 0) as new_need,
           coalesce(n.available, 0) as available, coalesce(n.incoming, 0) as incoming, coalesce(ap.q, 0) as approved,
           coalesce(pb.q, 0) as pending_before, coalesce(pa.q, 0) as pending_after, coalesce(n.suggest_qty, 0) as buy_more,
           coalesce(n.projected + n.suggest_qty, coalesce(n.available, 0) + coalesce(n.incoming, 0)) as projected_after,
           n.unit_price
    from mats join master.materials mt on mt.id = mats.material_id
    left join o on o.material_id = mats.material_id left join n on n.material_id = mats.material_id
    left join ap on ap.material_id = mats.material_id left join pa on pa.material_id = mats.material_id
    left join pb on pb.material_id = mats.material_id
  )
  select jsonb_agg(jsonb_build_object(
           'code', code, 'name', name, 'uom', uom, 'old_need', round(old_need, 3), 'new_need', round(new_need, 3),
           'delta', round(new_need - old_need, 3), 'available', round(available, 3), 'incoming', round(incoming, 3),
           'approved', round(approved, 3), 'pending_before', round(pending_before, 3), 'pending_after', round(pending_after, 3),
           'buy_more', round(buy_more, 3), 'projected_after', round(projected_after, 3),
           'amount', case when unit_price is not null then round(buy_more * unit_price, 0) end,
           'action', case when buy_more > 0 then 'BUY'
                          when pending_after < pending_before then 'CUT'
                          when new_need < old_need and pending_after > 0 and projected_after > 0 then 'PACK'
                          when new_need < old_need and approved > 0 then 'KEEP'
                          when new_need < old_need then 'LESS'
                          when new_need > old_need then 'ENOUGH'
                          else 'SAME' end)
         order by case when buy_more > 0 then 0 when pending_after < pending_before then 1 when new_need <> old_need then 2 else 3 end, code)
    into v_rows
  from rw
  where round(new_need - old_need, 3) <> 0 or buy_more > 0 or pending_after <> pending_before;

  select count(*) into v_buy from plan.mrp_lines where run_id = v_fin and suggest_qty > 0;
  return jsonb_build_object('run_id', v_fin, 'old_run_id', v_old, 'rows', coalesce(v_rows, '[]'), 'reductions', v_red,
                            'buy_count', v_buy, 'cut_count', jsonb_array_length(v_red), 'at', now());
end $$;
revoke all on function plan.revise_mrp(uuid) from public, anon, authenticated;

-- Chủ tịch duyệt xong (bước cuối): áp vào kế hoạch tháng, chạy MRP hiệu chỉnh, giảm đề xuất mua chưa duyệt
create or replace function plan.apply_adjustment() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare pp plan.production_plans; v jsonb; v_msg text;
begin
  if new.status <> 'APPROVED' or old.status = 'APPROVED' then return new; end if;
  perform plan.check_adjustment(new.id);
  select * into pp from plan.production_plans where id = new.plan_id;
  perform plan.apply_adjustment_lines(new.id);
  v := plan.revise_mrp(new.id);
  new.applied_at := now();
  new.mrp_run_id := (v ->> 'run_id')::uuid;
  new.mrp_result := v;
  v_msg := pp.plan_no || ' · ' || new.reason || '. MES đã chạy MRP hiệu chỉnh'
    || case when (v ->> 'cut_count')::int > 0 then ', giảm ' || (v ->> 'cut_count') || ' dòng đề xuất mua chưa duyệt' else '' end
    || case when (v ->> 'buy_count')::int > 0 then ', ' || (v ->> 'buy_count') || ' vật tư cần mua thêm: TP SX lập đề xuất mua bổ sung ở trang kế hoạch'
            else ', không phải mua thêm' end
    || '. Vật tư Giám đốc đã duyệt mua giữ nguyên. TP SX xếp lại lịch máy.';
  perform app.kh_log('Hiệu chỉnh kế hoạch tháng', new.adj_no, null, pp.plan_no, new.reason);
  perform wf.notify_users(inv.role_users(array['SX_TP', 'SX_KH', 'BGD', 'MUA_TP', 'KT_TP']), 'Kế hoạch tháng đã hiệu chỉnh: ' || new.adj_no,
    left(v_msg, 500), '/ke-hoach/dieu-chinh/' || new.id);
  return new;
end $$;

-- Bảng MRP hiệu chỉnh: phiếu nháp / chờ duyệt thì chạy thử (áp dòng + MRP + giảm đề xuất) trong giao dịch con rồi hủy;
-- phiếu đã duyệt trả kết quả đã lưu khi áp.
create or replace function app.adj_mrp(p_adj uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare a plan.plan_adjustments; v jsonb;
begin
  if not core.has_perm('plan', 'view') then raise exception 'Không có quyền xem kế hoạch'; end if;
  select * into a from plan.plan_adjustments where id = p_adj;
  if not found then raise exception 'Không tìm thấy đề xuất hiệu chỉnh'; end if;
  if a.status = 'APPROVED' then return coalesce(a.mrp_result, jsonb_build_object('rows', '[]')) || jsonb_build_object('applied', true); end if;
  if a.status = 'CANCELLED' then return jsonb_build_object('rows', '[]', 'error', 'Đề xuất đã hủy'); end if;
  begin
    perform plan.check_adjustment(p_adj);
    perform plan.apply_adjustment_lines(p_adj);
    v := plan.revise_mrp(p_adj);
    raise exception 'BMT_PREVIEW_ROLLBACK';
  exception when others then
    if sqlerrm <> 'BMT_PREVIEW_ROLLBACK' then return jsonb_build_object('rows', '[]', 'error', sqlerrm); end if;
  end;
  return v - 'run_id' - 'old_run_id' || jsonb_build_object('preview', true);
end $$;
revoke all on function app.adj_mrp(uuid) from public, anon;
grant execute on function app.adj_mrp(uuid) to authenticated;

-- Hủy nháp: lời nhắc theo quy trình mới
create or replace function app.adj_cancel(p_adj uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare a plan.plan_adjustments;
begin
  select * into a from plan.plan_adjustments where id = p_adj for update;
  if not found then raise exception 'Không tìm thấy đề xuất hiệu chỉnh'; end if;
  if a.status <> 'DRAFT' then raise exception 'Chỉ hủy được đề xuất nháp (đang chờ duyệt thì nhờ Giám đốc / Chủ tịch trả lại)'; end if;
  if a.created_by is distinct from auth.uid() and not core.is_admin() then raise exception 'Chỉ người lập hủy đề xuất'; end if;
  update plan.plan_adjustments set status = 'CANCELLED' where id = p_adj;
end $$;

create or replace view app.v_plan_adjustments with (security_invoker = true) as
select a.id, a.adj_no, a.plan_id, pp.plan_no, a.status, a.reason, a.applied_at, a.created_at, a.created_by, app.user_name(a.created_by) as created_by_name,
       (select count(*) from plan.plan_adjustment_lines l where l.adj_id = a.id) as line_count,
       (select r.id from wf.approval_requests r where r.doc_type = 'PLAN_ADJ' and r.doc_id = a.id order by r.submitted_at desc limit 1) as approval_id,
       a.mrp_run_id, pp.period_label
from plan.plan_adjustments a join plan.production_plans pp on pp.id = a.plan_id;
grant select on app.v_plan_adjustments to authenticated;
