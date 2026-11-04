-- ============================================================================
-- 20261026009500_po_master_contracts
-- Anh Bình 04/11/2026: quy trình mua hàng mới
--  1. Yêu cầu mua được duyệt (kế hoạch tháng Chủ tịch chốt → MRP; đề xuất mua Giám đốc duyệt) → MES lập
--     "Đơn mua hàng tổng" (DMT-…) giao Phòng mua hàng.
--  2. NV mua làm việc với NCC, chốt cho TỪNG DÒNG vật tư: nhà cung cấp, đơn giá, điều khoản thanh toán, ngày giao dự kiến
--     (mỗi chủng loại có NCC khác nhau: NCC ghi theo dòng, không ghi chung cho đơn).
--  3. NV mua gom các dòng thành Hợp đồng/Phiếu (PO-…): mỗi NCC một hợp đồng (tách được thành nhiều hợp đồng), đệ trình
--     TP Mua duyệt → Giám đốc duyệt. Hợp đồng nào chốt xong thì gửi ngay, duyệt riêng từng hợp đồng.
--  4. Hạn: NV mua 5 ngày làm việc từ khi nhận đơn tổng để gửi đủ hợp đồng; TP Mua 1 ngày làm việc; Giám đốc 1 ngày làm việc.
--     Quá hạn: nhắc và cảnh báo lên cấp trên (NV mua → TP Mua + Giám đốc; TP Mua → Giám đốc; Giám đốc → Chủ tịch HĐQT),
--     không ai làm thay (bỏ duyệt thay của bước TP Mua).
--  5. Giám đốc duyệt xong: báo NV mua, Kế toán (Kế toán kho/SX, Kế toán giá thành, Kế toán trưởng); đơn tổng có mọi hợp
--     đồng đã duyệt thì báo hoàn tất.
-- Hợp đồng là đơn mua (PO) như trước: nhận hàng, giá NCC, hiệu chỉnh kế hoạch tháng dùng chung. Đơn tổng không gửi duyệt,
-- không nhận hàng; dòng chuyển từ đơn tổng sang hợp đồng (không nhân đôi số lượng trong MRP).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Cấu trúc
-- ---------------------------------------------------------------------------
alter table purchase.purchase_orders
  add column if not exists kind text not null default 'HD',
  add column if not exists parent_id uuid references purchase.purchase_orders(id) on delete set null,
  add column if not exists due_date date,
  add column if not exists all_submitted_at timestamptz,
  add column if not exists done_at timestamptz;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'purchase_orders_kind_check') then
    alter table purchase.purchase_orders add constraint purchase_orders_kind_check check (kind in ('TONG', 'HD'));
  end if;
end $$;
create index if not exists purchase_orders_parent_idx on purchase.purchase_orders(parent_id);
comment on column purchase.purchase_orders.kind is 'TONG: đơn mua hàng tổng (MES lập từ yêu cầu mua đã duyệt, NV mua chốt từng dòng); HD: hợp đồng/phiếu mua một NCC, gửi duyệt TP Mua → Giám đốc';
comment on column purchase.purchase_orders.parent_id is 'Hợp đồng: đơn mua tổng nguồn';
comment on column purchase.purchase_orders.due_date is 'Đơn tổng: hạn NV mua gửi đủ hợp đồng (5 ngày làm việc từ khi nhận)';

alter table purchase.po_lines
  add column if not exists supplier_id uuid references core.partners(id),
  add column if not exists payment_terms text;
comment on column purchase.po_lines.supplier_id is 'NCC NV mua chốt cho dòng (đơn tổng); hợp đồng: bằng NCC của hợp đồng';
comment on column purchase.po_lines.payment_terms is 'Điều khoản thanh toán chốt cho dòng';

-- Cộng n ngày làm việc (theo ngày làm việc của xưởng ở Tham số xếp lịch)
create or replace function purchase.add_workdays(p_from date, p_n int) returns date
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare d date := p_from; k int := 0;
begin
  while k < p_n and d < p_from + 90 loop
    d := d + 1;
    if plan.is_workday(d) then k := k + 1; end if;
  end loop;
  return d;
end $$;

-- Hạn duyệt hợp đồng: cùng giờ của ngày làm việc thứ n sau lúc nhận (giờ VN)
create or replace function purchase.due_after_workdays(p_at timestamptz, p_n int) returns timestamptz
language sql stable security definer set search_path = pg_catalog, public as $$
  select (purchase.add_workdays((p_at at time zone 'Asia/Ho_Chi_Minh')::date, p_n)
          + (p_at at time zone 'Asia/Ho_Chi_Minh')::time) at time zone 'Asia/Ho_Chi_Minh'
$$;

-- ---------------------------------------------------------------------------
-- 2. Đơn đang nháp của quy trình cũ → đơn mua tổng
--    (đơn nháp tự sinh từ MRP / đề xuất mua chưa gửi duyệt; nhiều đơn nháp cùng nguồn gộp làm một)
-- ---------------------------------------------------------------------------
do $$
declare g record; v_first uuid; v_line int; o record;
begin
  for g in
    select po.source, po.plan_id, po.mrp_run_id, po.adjustment_id, po.pr_id, array_agg(po.id order by po.created_at, po.po_no) as ids
      from purchase.purchase_orders po
     where po.status = 'DRAFT' and po.source in ('MRP', 'PR') and po.kind = 'HD' and po.parent_id is null
       and not exists (select 1 from wf.approval_requests r where r.doc_type = 'PO' and r.doc_id = po.id and r.status = 'PENDING')
     group by po.source, po.plan_id, po.mrp_run_id, po.adjustment_id, po.pr_id
  loop
    v_first := g.ids[1];
    -- dòng: NCC, điều khoản lấy từ đầu đơn cũ (chưa có thì NCC ưu tiên của vật tư)
    update purchase.po_lines l set supplier_id = coalesce(po.supplier_id, (purchase.material_terms(l.material_id)).supplier_id),
           payment_terms = coalesce(l.payment_terms, po.payment_terms)
      from purchase.purchase_orders po where po.id = l.po_id and po.id = any(g.ids);
    for o in select id, po_no from purchase.purchase_orders where id = any(g.ids[2:]) loop
      select coalesce(max(line_no), 0) into v_line from purchase.po_lines where po_id = v_first;
      update purchase.po_lines l set po_id = v_first, line_no = v_line + x.rn
        from (select id, row_number() over (order by line_no) as rn from purchase.po_lines where po_id = o.id) x where x.id = l.id;
      update purchase.purchase_orders set status = 'CANCELLED', cancel_reason = 'Gộp vào đơn mua tổng' where id = o.id;
    end loop;
    update purchase.purchase_orders po set kind = 'TONG', supplier_id = null, payment_terms = null,
           due_date = purchase.add_workdays((po.created_at at time zone 'Asia/Ho_Chi_Minh')::date, 5)
     where po.id = v_first;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Quy trình duyệt hợp đồng: TP Mua (1 ngày làm việc) → Giám đốc (1 ngày làm việc), không duyệt thay;
--    Kế toán nhận thông báo khi Giám đốc duyệt xong (không còn ở bước TP Mua)
-- ---------------------------------------------------------------------------
update wf.approval_flows set name = 'Hợp đồng / phiếu mua hàng (PO)',
       submit_label = 'NV mua gom dòng của đơn mua tổng thành hợp đồng, đệ trình TP Mua'
 where doc_type = 'PO';
update wf.approval_steps set level_label = 'TP Mua duyệt hợp đồng mua hàng', fallback_role = null, notify_roles = '{}', sla_hours = 24
 where doc_type = 'PO' and seq = 1;
update wf.approval_steps set level_label = 'Giám đốc duyệt hợp đồng mua hàng', sla_hours = 24
 where doc_type = 'PO' and seq = 2;

-- Hạn duyệt đơn mua tính theo ngày làm việc ở purchase.po_deadline_alerts (bỏ khỏi job hạn chung theo giờ)
do $$
declare d text; v_from text := $f$where q.status = 'PENDING' loop$f$;
begin
  select pg_get_functiondef('wf.check_sla()'::regprocedure) into d;
  if position(v_from in d) = 0 then raise exception 'wf.check_sla khác bản dự kiến: không vá được'; end if;
  execute replace(d, v_from, $f$where q.status = 'PENDING' and q.doc_type <> 'PO' loop$f$);
end $$;

-- Gửi duyệt: đơn tổng không gửi duyệt; hợp đồng từ đơn tổng phải đủ ngày giao, điều khoản thanh toán từng dòng
do $$
declare d text;
  v_a text := $f$if not found then raise exception 'Không tìm thấy đơn mua hàng'; end if;$f$;
  v_b text := $f$if v_bad is not null then raise exception 'Đơn mua %: % chưa có đơn giá (nhập giá trước khi gửi duyệt)', po.po_no, v_bad; end if;$f$;
begin
  select pg_get_functiondef('wf.check_doc(text, uuid)'::regprocedure) into d;
  if position(v_a in d) = 0 or position(v_b in d) = 0 then raise exception 'wf.check_doc khác bản dự kiến: không vá được'; end if;
  d := replace(d, v_a, v_a || $f$
    if po.kind = 'TONG' then raise exception 'Đơn mua tổng % không gửi duyệt: gom các dòng thành hợp đồng theo NCC rồi đệ trình', po.po_no; end if;$f$);
  d := replace(d, v_b, v_b || $f$
    if po.parent_id is not null then
      select string_agg(m.code, ', ' order by m.code) into v_bad from purchase.po_lines l join master.materials m on m.id = l.material_id
       where l.po_id = p_doc_id and (l.expected_date is null or coalesce(trim(coalesce(l.payment_terms, po.payment_terms)), '') = '');
      if v_bad is not null then raise exception 'Hợp đồng %: % chưa có ngày giao hoặc điều khoản thanh toán', po.po_no, v_bad; end if;
    end if;$f$);
  execute d;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Lập đơn mua tổng
-- ---------------------------------------------------------------------------
-- Từ kết quả MRP (Chủ tịch chốt kế hoạch tháng, hiệu chỉnh được duyệt): một đơn tổng cho phần còn thiếu, NCC/giá gợi ý theo
-- điều kiện mua của vật tư
create or replace function purchase.po_from_mrp(p_run uuid, p_adj uuid default null)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public
set "TimeZone" = 'Asia/Ho_Chi_Minh' as $$
declare r plan.mrp_runs; p plan.production_plans; v_adj text; v_po uuid; v_no text; v_n int; v_today date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
        v_due date;
begin
  select * into r from plan.mrp_runs where id = p_run;
  if not found then raise exception 'Không tìm thấy lần chạy MRP'; end if;
  select * into p from plan.production_plans where id = r.plan_id;
  select adj_no into v_adj from plan.plan_adjustments where id = p_adj;
  create temp table if not exists _po_need (mrp_line_id uuid, material_id uuid, qty numeric, supplier_id uuid, unit_price numeric,
                                            item_code text, need_date date) on commit drop;
  delete from _po_need where true;
  insert into _po_need
  select ml.id, ml.material_id,
         ml.suggest_qty - coalesce((select sum(pl.qty) from purchase.po_lines pl join purchase.purchase_orders po on po.id = pl.po_id
                                    where pl.mrp_line_id = ml.id and po.status <> 'CANCELLED'), 0),
         t.supplier_id, t.unit_price, t.supplier_item_code, coalesce(ml.need_date, p.material_need_date)
  from plan.mrp_lines ml
  left join lateral (select * from purchase.material_terms(ml.material_id)) t on true
  where ml.run_id = p_run and ml.suggest_qty > 0;
  delete from _po_need where qty <= 0.0001;
  if not exists (select 1 from _po_need) then
    return jsonb_build_object('count', 0, 'lines', 0, 'po_ids', '[]'::jsonb, 'po_nos', '[]'::jsonb);
  end if;

  v_no := core.next_no('DMT');
  v_due := purchase.add_workdays(v_today, 5);
  insert into purchase.purchase_orders (po_no, kind, supplier_id, status, order_date, expected_date, due_date, note, source, plan_id, mrp_run_id, adjustment_id)
  values (v_no, 'TONG', null, 'DRAFT', v_today, (select min(need_date) from _po_need), v_due,
          'Theo kế hoạch ' || p.plan_no || coalesce(' · hiệu chỉnh ' || v_adj, '') || ' (MES tự lập từ MRP)', 'MRP', p.id, p_run, p_adj)
  returning id into v_po;
  insert into purchase.po_lines (po_id, line_no, material_id, supplier_id, supplier_item_code, qty, unit_price, expected_date, mrp_line_id, mrp_qty)
  select v_po, row_number() over (order by m.code), n.material_id, n.supplier_id, n.item_code, round(n.qty, 4), n.unit_price, n.need_date,
         n.mrp_line_id, round(n.qty, 4)
  from _po_need n join master.materials m on m.id = n.material_id;
  get diagnostics v_n = row_count;

  perform wf.notify_users(inv.role_users(array['MUA_NV', 'MUA_TP']),
    'Đơn mua hàng tổng ' || v_no || ': hạn gửi đủ hợp đồng ' || to_char(v_due, 'DD/MM'),
    format('%s dòng vật tư theo %s%s. NV mua chốt NCC, giá, điều khoản thanh toán, ngày giao từng dòng, gom thành hợp đồng theo NCC và đệ trình TP Mua trong 5 ngày làm việc (đến hết %s).',
           v_n, p.plan_no, coalesce(' · hiệu chỉnh ' || v_adj, ''), to_char(v_due, 'DD/MM/YYYY')),
    '/don-mua/' || v_po);
  return jsonb_build_object('count', 1, 'lines', v_n, 'po_ids', jsonb_build_array(v_po), 'po_nos', jsonb_build_array(v_no));
end $$;

-- Từ đề xuất mua đã được Giám đốc duyệt (bổ sung, tích trữ, tối ưu…): một đơn tổng cho phần chưa lên đơn
create or replace function purchase.po_from_pr(p_pr uuid)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public
set "TimeZone" = 'Asia/Ho_Chi_Minh' as $$
declare pr purchase.purchase_requests; v_plan uuid; v_po uuid; v_no text; v_n int; v_today date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
        v_due date;
begin
  select * into pr from purchase.purchase_requests where id = p_pr for update;
  if not found then raise exception 'Không tìm thấy đề xuất mua'; end if;
  if pr.status not in ('APPROVED', 'PARTIAL_PO') then raise exception 'Đề xuất % chưa được Giám đốc duyệt hoặc đã lên đơn đủ', pr.pr_no; end if;
  select plan_id into v_plan from plan.mrp_runs where id = pr.mrp_run_id;
  create temp table if not exists _pr_need (pr_line_id uuid, material_id uuid, qty numeric, supplier_id uuid, unit_price numeric,
                                            item_code text, need_date date) on commit drop;
  delete from _pr_need where true;
  insert into _pr_need
  select l.id, l.material_id, l.qty - l.ordered_qty, t.supplier_id, t.unit_price, t.supplier_item_code, coalesce(l.need_date, pr.need_date)
  from purchase.pr_lines l left join lateral (select * from purchase.material_terms(l.material_id)) t on true
  where l.pr_id = p_pr and l.qty - l.ordered_qty > 0.0001;
  if not exists (select 1 from _pr_need) then raise exception 'Đề xuất % đã lên đơn mua đủ số lượng', pr.pr_no; end if;

  v_no := core.next_no('DMT');
  v_due := purchase.add_workdays(v_today, 5);
  insert into purchase.purchase_orders (po_no, kind, supplier_id, status, order_date, expected_date, due_date, note, source, pr_id, plan_id)
  values (v_no, 'TONG', null, 'DRAFT', v_today, (select min(need_date) from _pr_need), v_due,
          'Theo đề xuất ' || pr.pr_no || coalesce(' · ' || nullif(trim(pr.note), ''), ''), 'PR', p_pr, v_plan)
  returning id into v_po;
  insert into purchase.po_lines (po_id, line_no, material_id, supplier_id, supplier_item_code, qty, unit_price, expected_date, pr_line_id)
  select v_po, row_number() over (order by m.code), n.material_id, n.supplier_id, n.item_code, round(n.qty, 4), n.unit_price, n.need_date, n.pr_line_id
  from _pr_need n join master.materials m on m.id = n.material_id;
  get diagnostics v_n = row_count;
  -- đề xuất giữ trạng thái Đã duyệt; số đã lên đơn theo dõi ở ordered_qty
  update purchase.pr_lines l set ordered_qty = l.ordered_qty + n.qty from _pr_need n where n.pr_line_id = l.id;

  perform wf.notify_users(inv.role_users(array['MUA_NV', 'MUA_TP']),
    'Đơn mua hàng tổng ' || v_no || ': hạn gửi đủ hợp đồng ' || to_char(v_due, 'DD/MM'),
    format('%s dòng vật tư theo đề xuất %s. NV mua chốt NCC, giá, điều khoản thanh toán, ngày giao từng dòng, gom thành hợp đồng theo NCC và đệ trình TP Mua trong 5 ngày làm việc (đến hết %s).',
           v_n, pr.pr_no, to_char(v_due, 'DD/MM/YYYY')),
    '/don-mua/' || v_po);
  return jsonb_build_object('count', 1, 'lines', v_n, 'po_ids', jsonb_build_array(v_po), 'po_nos', jsonb_build_array(v_no));
end $$;

-- NV mua / TP Mua lập đơn tổng cho đề xuất đã duyệt mà chưa có đơn (đề xuất duyệt trước khi có quy trình này)
create or replace function app.po_from_pr(p_pr uuid)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if not (core.has_role('MUA_NV') or core.has_role('MUA_TP')) then raise exception 'Chỉ NV mua / TP Mua lập đơn mua hàng'; end if;
  return purchase.po_from_pr(p_pr);
end $$;

-- Giám đốc duyệt đề xuất mua → MES tự lập đơn mua tổng giao Phòng mua hàng
create or replace function purchase.auto_po_on_pr_approve()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if exists (select 1 from purchase.pr_lines l where l.pr_id = new.id and l.qty - l.ordered_qty > 0.0001) then
    perform purchase.po_from_pr(new.id);
  end if;
  return null;
end $$;
drop trigger if exists trg_auto_po_pr on purchase.purchase_requests;
create trigger trg_auto_po_pr after update of status on purchase.purchase_requests
  for each row when (new.status = 'APPROVED' and old.status is distinct from 'APPROVED')
  execute function purchase.auto_po_on_pr_approve();

-- ---------------------------------------------------------------------------
-- 5. Đơn tổng: chốt từng dòng, gom hợp đồng, trả dòng về đơn tổng, theo dõi hoàn tất
-- ---------------------------------------------------------------------------
-- Tình trạng đơn tổng sau mỗi thay đổi: gửi đủ hợp đồng (không còn dòng chưa gom, không còn hợp đồng nháp) → hoàn tất
-- (mọi hợp đồng đã được Giám đốc duyệt) → báo NV mua, Kế toán
create or replace function purchase.tong_refresh(p_tong uuid)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
declare t purchase.purchase_orders; v_left int; v_draft int; v_pending int; v_ok int; v_list text;
begin
  select * into t from purchase.purchase_orders where id = p_tong and kind = 'TONG' for update;
  if not found or t.status = 'CANCELLED' then return; end if;
  select count(*) into v_left from purchase.po_lines where po_id = p_tong;
  select count(*) filter (where status = 'DRAFT'), count(*) filter (where status = 'PENDING_APPROVAL'),
         count(*) filter (where status in ('APPROVED', 'SENT', 'PARTIAL_RECEIVED', 'RECEIVED', 'CLOSED'))
    into v_draft, v_pending, v_ok
    from purchase.purchase_orders where parent_id = p_tong and kind = 'HD';
  if v_left = 0 and v_draft = 0 and (v_pending + v_ok) > 0 then
    if t.all_submitted_at is null then update purchase.purchase_orders set all_submitted_at = now() where id = p_tong; end if;
  elsif t.all_submitted_at is not null then
    update purchase.purchase_orders set all_submitted_at = null where id = p_tong;
  end if;
  if v_left = 0 and v_draft = 0 and v_pending = 0 and v_ok > 0 then
    if t.done_at is null then
      update purchase.purchase_orders set done_at = now(), status = 'CLOSED' where id = p_tong;
      select string_agg(h.po_no || coalesce(' (' || sp.name || ')', ''), ', ' order by h.po_no) into v_list
        from purchase.purchase_orders h left join core.partners sp on sp.id = h.supplier_id
       where h.parent_id = p_tong and h.kind = 'HD' and h.status <> 'CANCELLED';
      perform wf.notify_users(inv.role_users(array['MUA_NV', 'MUA_TP', 'KT_KHO', 'KT_GT', 'KTT']),
        'Hoàn tất đơn mua tổng ' || t.po_no,
        format('Giám đốc đã duyệt đủ %s hợp đồng: %s.', v_ok, left(coalesce(v_list, ''), 400)), '/don-mua/' || p_tong);
    end if;
  elsif t.done_at is not null then
    update purchase.purchase_orders set done_at = null, status = 'DRAFT' where id = p_tong;
  end if;
end $$;

create or replace function purchase.trg_tong_refresh()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if new.parent_id is not null then perform purchase.tong_refresh(new.parent_id); end if;
  if tg_op = 'UPDATE' and old.parent_id is not null and old.parent_id is distinct from new.parent_id then
    perform purchase.tong_refresh(old.parent_id);
  end if;
  return null;
end $$;
drop trigger if exists trg_tong_refresh on purchase.purchase_orders;
create trigger trg_tong_refresh after update of status, parent_id on purchase.purchase_orders
  for each row when (new.kind = 'HD') execute function purchase.trg_tong_refresh();

-- Chốt một dòng: NCC, đơn giá, điều khoản thanh toán, ngày giao, số lượng, ghi chú.
-- Đơn tổng: NV mua / TP Mua. Hợp đồng nháp: NV mua / TP Mua; hợp đồng chờ duyệt: người đang duyệt (ghi lịch sử duyệt).
-- Đổi NCC của dòng đã vào hợp đồng: trả dòng về đơn tổng.
create or replace function app.po_line_set(p_line uuid, p_supplier uuid, p_price numeric, p_terms text, p_date date,
                                           p_qty numeric default null, p_note text default null)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
declare l purchase.po_lines; po purchase.purchase_orders; m master.materials; r wf.approval_requests; v_qty numeric;
        v_terms text := nullif(trim(coalesce(p_terms, '')), ''); v_desc text;
begin
  select * into l from purchase.po_lines where id = p_line for update;
  if not found then raise exception 'Không tìm thấy dòng đơn mua'; end if;
  select * into po from purchase.purchase_orders where id = l.po_id for update;
  select * into m from master.materials where id = l.material_id;
  v_qty := coalesce(p_qty, l.qty);
  -- người không được xem giá (form không có ô giá) thì giữ đơn giá đang có
  if p_price is null and not core.can_see_price() then p_price := l.unit_price; end if;
  if v_qty <= 0 then raise exception 'Số lượng phải lớn hơn 0'; end if;
  if p_price is not null and p_price < 0 then raise exception 'Đơn giá không được âm'; end if;
  if p_supplier is not null and not exists (select 1 from core.partners where id = p_supplier and is_supplier and active) then
    raise exception 'Nhà cung cấp không hợp lệ';
  end if;
  if po.kind = 'TONG' then
    if not (core.has_role('MUA_NV') or core.has_role('MUA_TP')) then raise exception 'Chỉ NV mua / TP Mua chốt dòng đơn mua tổng'; end if;
    if po.status <> 'DRAFT' then raise exception 'Đơn mua tổng % đã hoàn tất hoặc đã hủy', po.po_no; end if;
    update purchase.po_lines set supplier_id = p_supplier, unit_price = p_price, payment_terms = v_terms, expected_date = p_date,
           qty = v_qty, note = nullif(trim(coalesce(p_note, '')), ''),
           supplier_item_code = coalesce((select ms.supplier_item_code from master.material_suppliers ms
                                           where ms.material_id = l.material_id and ms.supplier_id = p_supplier limit 1), supplier_item_code)
     where id = p_line;
  else
    r := purchase.po_edit_request(po.id);
    if p_supplier is not null and p_supplier is distinct from po.supplier_id then
      raise exception '% thuộc hợp đồng % của NCC khác: đổi NCC thì trả dòng về đơn mua tổng', m.code, po.po_no;
    end if;
    update purchase.po_lines set unit_price = p_price, payment_terms = v_terms, expected_date = coalesce(p_date, expected_date),
           qty = v_qty, note = nullif(trim(coalesce(p_note, '')), '')
     where id = p_line;
    if r.id is not null then
      v_desc := concat_ws(', ',
        case when l.qty <> v_qty then format('%s: %s → %s %s', m.code, wf.fmt_qty(l.qty), wf.fmt_qty(v_qty), m.uom) end,
        case when l.unit_price is distinct from p_price then format('%s: đơn giá %s → %s', m.code, coalesce(wf.fmt_qty(l.unit_price), '—'), coalesce(wf.fmt_qty(p_price), '—')) end,
        case when l.payment_terms is distinct from v_terms then format('%s: thanh toán %s', m.code, coalesce(v_terms, '—')) end,
        case when p_date is not null and l.expected_date is distinct from p_date then format('%s: ngày giao %s', m.code, to_char(p_date, 'DD/MM')) end);
      if coalesce(v_desc, '') <> '' then perform wf.log_review_edit(r.id, v_desc); end if;
    end if;
    -- điều khoản đầu hợp đồng theo dòng
    update purchase.purchase_orders h set payment_terms = (select case when count(distinct coalesce(x.payment_terms, '')) = 1 then max(x.payment_terms)
                                                                         else 'Theo từng dòng' end from purchase.po_lines x where x.po_id = h.id),
           expected_date = (select min(x.expected_date) from purchase.po_lines x where x.po_id = h.id)
     where h.id = po.id and h.parent_id is not null;
  end if;
  if l.pr_line_id is not null and v_qty <> l.qty then
    update purchase.pr_lines set ordered_qty = greatest(ordered_qty + v_qty - l.qty, 0) where id = l.pr_line_id;
  end if;
end $$;

-- Gom dòng của đơn tổng thành hợp đồng: mỗi NCC một hợp đồng (dòng chọn, hoặc mọi dòng đã chốt đủ khi không chọn);
-- p_submit: đệ trình TP Mua luôn
create or replace function app.po_make_contracts(p_tong uuid, p_lines uuid[] default null, p_submit boolean default false)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public
set "TimeZone" = 'Asia/Ho_Chi_Minh' as $$
declare t purchase.purchase_orders; v_bad text; g record; v_id uuid; v_no text; v_out jsonb := '[]'; v_sup text; v_n int;
        v_today date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
begin
  if not (core.has_role('MUA_NV') or core.has_role('MUA_TP')) then raise exception 'Chỉ NV mua / TP Mua gom hợp đồng'; end if;
  select * into t from purchase.purchase_orders where id = p_tong for update;
  if not found or t.kind <> 'TONG' then raise exception 'Không tìm thấy đơn mua tổng'; end if;
  if t.status <> 'DRAFT' then raise exception 'Đơn mua tổng % đã hoàn tất hoặc đã hủy', t.po_no; end if;
  create temp table if not exists _hd_lines (id uuid) on commit drop;
  delete from _hd_lines where true;
  if coalesce(cardinality(p_lines), 0) > 0 then
    if (select count(*) from purchase.po_lines where po_id = p_tong and id = any(p_lines)) <> cardinality(p_lines) then
      raise exception 'Có dòng không thuộc đơn mua tổng %', t.po_no;
    end if;
    insert into _hd_lines select unnest(p_lines);
    select string_agg(m.code, ', ' order by m.code) into v_bad
      from purchase.po_lines l join master.materials m on m.id = l.material_id
     where l.id in (select id from _hd_lines)
       and (l.supplier_id is null or l.unit_price is null or l.expected_date is null or coalesce(trim(l.payment_terms), '') = '');
    if v_bad is not null then
      raise exception 'Chưa chốt đủ NCC, đơn giá, điều khoản thanh toán, ngày giao: %', v_bad;
    end if;
  else
    insert into _hd_lines select l.id from purchase.po_lines l
     where l.po_id = p_tong and l.supplier_id is not null and l.unit_price is not null and l.expected_date is not null
       and coalesce(trim(l.payment_terms), '') <> '';
  end if;
  if not exists (select 1 from _hd_lines) then
    raise exception 'Chưa có dòng nào chốt đủ NCC, đơn giá, điều khoản thanh toán, ngày giao';
  end if;

  for g in select l.supplier_id, min(l.expected_date) as eta, count(distinct l.payment_terms) as nterms, max(l.payment_terms) as terms
             from purchase.po_lines l where l.id in (select id from _hd_lines) group by l.supplier_id loop
    v_no := core.next_no('PO');
    insert into purchase.purchase_orders (po_no, kind, parent_id, supplier_id, status, order_date, expected_date, payment_terms, note,
                                          source, plan_id, mrp_run_id, adjustment_id, pr_id, is_import)
    values (v_no, 'HD', p_tong, g.supplier_id, 'DRAFT', v_today, g.eta, case when g.nterms = 1 then g.terms else 'Theo từng dòng' end,
            'Theo đơn mua tổng ' || t.po_no, t.source, t.plan_id, t.mrp_run_id, t.adjustment_id, t.pr_id, false)
    returning id into v_id;
    update purchase.po_lines l set po_id = v_id, line_no = x.rn
      from (select l2.id, row_number() over (order by m.code) as rn from purchase.po_lines l2 join master.materials m on m.id = l2.material_id
             where l2.id in (select id from _hd_lines) and l2.supplier_id = g.supplier_id) x
     where x.id = l.id;
    get diagnostics v_n = row_count;
    select name into v_sup from core.partners where id = g.supplier_id;
    if p_submit then
      perform wf.submit('PO', v_id, v_no, format('%s · %s dòng · theo %s', v_sup, v_n, t.po_no));
    end if;
    v_out := v_out || jsonb_build_object('id', v_id, 'po_no', v_no, 'supplier', v_sup, 'lines', v_n);
  end loop;
  perform purchase.tong_refresh(p_tong);
  return jsonb_build_object('contracts', v_out, 'submitted', p_submit,
                            'left', (select count(*) from purchase.po_lines where po_id = p_tong));
end $$;

-- Trả mọi dòng của hợp đồng nháp (hoặc bị trả lại) về đơn tổng để đổi NCC, gom lại; hợp đồng hủy
create or replace function app.po_return_to_tong(p_po uuid, p_reason text default null)
returns uuid language plpgsql security definer set search_path = pg_catalog, public as $$
declare po purchase.purchase_orders; v_line int;
begin
  if not (core.has_role('MUA_NV') or core.has_role('MUA_TP')) then raise exception 'Chỉ NV mua / TP Mua trả dòng về đơn tổng'; end if;
  select * into po from purchase.purchase_orders where id = p_po for update;
  if not found or po.kind <> 'HD' or po.parent_id is null then raise exception 'Hợp đồng không lập từ đơn mua tổng'; end if;
  if po.status <> 'DRAFT' then raise exception 'Chỉ trả về đơn tổng khi hợp đồng còn nháp (đang chờ duyệt: người duyệt trả lại trước)'; end if;
  perform 1 from purchase.purchase_orders where id = po.parent_id for update;
  update purchase.purchase_orders set status = 'DRAFT', done_at = null where id = po.parent_id and status = 'CLOSED';
  select coalesce(max(line_no), 0) into v_line from purchase.po_lines where po_id = po.parent_id;
  update purchase.po_lines l set po_id = po.parent_id, line_no = v_line + x.rn,
         supplier_id = coalesce(l.supplier_id, po.supplier_id), payment_terms = coalesce(l.payment_terms, nullif(po.payment_terms, 'Theo từng dòng'))
    from (select id, row_number() over (order by line_no) as rn from purchase.po_lines where po_id = p_po) x where x.id = l.id;
  update purchase.purchase_orders set status = 'CANCELLED',
         cancel_reason = 'Trả dòng về đơn mua tổng' || coalesce(': ' || nullif(trim(coalesce(p_reason, '')), ''), '')
   where id = p_po;
  return po.parent_id;
end $$;

-- Hợp đồng: đổi NCC ở đầu hợp đồng thì đổi luôn NCC các dòng
create or replace function purchase.sync_line_supplier()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  update purchase.po_lines set supplier_id = new.supplier_id where po_id = new.id and supplier_id is distinct from new.supplier_id;
  return null;
end $$;
drop trigger if exists trg_sync_line_supplier on purchase.purchase_orders;
create trigger trg_sync_line_supplier after update of supplier_id on purchase.purchase_orders
  for each row when (new.kind = 'HD' and new.supplier_id is not null) execute function purchase.sync_line_supplier();
-- dòng mới / dòng chuyển vào hợp đồng mang NCC của hợp đồng
create or replace function purchase.line_supplier_default()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare h purchase.purchase_orders;
begin
  select * into h from purchase.purchase_orders where id = new.po_id;
  if h.kind = 'HD' and h.supplier_id is not null then new.supplier_id := h.supplier_id; end if;
  return new;
end $$;
drop trigger if exists trg_line_supplier_default on purchase.po_lines;
create trigger trg_line_supplier_default before insert or update of po_id on purchase.po_lines
  for each row execute function purchase.line_supplier_default();

-- Xóa đơn mua (Quản trị xóa chứng từ): trả lại số "đã lên đơn" cho đề xuất mua (đơn đã hủy thì po_cancel đã trả)
create or replace function purchase.po_delete_release_pr()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if old.status <> 'CANCELLED' then
    update purchase.pr_lines pl set ordered_qty = greatest(pl.ordered_qty - x.q, 0)
      from (select pr_line_id, sum(qty) as q from purchase.po_lines where po_id = old.id and pr_line_id is not null group by pr_line_id) x
     where x.pr_line_id = pl.id;
    update purchase.purchase_requests pr set status = 'PARTIAL_PO'
     where pr.status = 'CLOSED' and pr.id in (select l.pr_id from purchase.pr_lines l join purchase.po_lines pl on pl.pr_line_id = l.id where pl.po_id = old.id);
  end if;
  return old;
end $$;
drop trigger if exists trg_po_delete_release_pr on purchase.purchase_orders;
create trigger trg_po_delete_release_pr before delete on purchase.purchase_orders
  for each row execute function purchase.po_delete_release_pr();

-- ---------------------------------------------------------------------------
-- 6. Giám đốc duyệt hợp đồng: giá NCC, báo NV mua, Kế toán, Kho
-- ---------------------------------------------------------------------------
create or replace function purchase.po_approved(p_po uuid)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
declare po purchase.purchase_orders; l record; v_sup text; v_list text; v_amt numeric; v_tong text;
begin
  select * into po from purchase.purchase_orders where id = p_po;
  select name into v_sup from core.partners where id = po.supplier_id;
  select po_no into v_tong from purchase.purchase_orders where id = po.parent_id;
  for l in select pl.*, m.code from purchase.po_lines pl join master.materials m on m.id = pl.material_id where pl.po_id = p_po loop
    if po.supplier_id is null or l.unit_price is null then continue; end if;
    update master.material_suppliers set unit_price = l.unit_price, supplier_item_code = coalesce(l.supplier_item_code, supplier_item_code), valid_from = po.order_date
     where material_id = l.material_id and supplier_id = po.supplier_id;
    if not found then
      update master.material_suppliers set supplier_id = po.supplier_id, unit_price = l.unit_price,
             supplier_item_code = coalesce(l.supplier_item_code, supplier_item_code), valid_from = po.order_date
       where id = (select id from master.material_suppliers where material_id = l.material_id and supplier_id is null order by is_preferred desc limit 1);
      if not found then
        insert into master.material_suppliers (material_id, supplier_id, supplier_item_code, unit_price, is_preferred, valid_from)
        values (l.material_id, po.supplier_id, l.supplier_item_code, l.unit_price,
                not exists (select 1 from master.material_suppliers x where x.material_id = l.material_id and x.is_preferred), po.order_date);
      end if;
    end if;
    insert into master.price_history (material_id, supplier_id, price, source, noted_by)
    values (l.material_id, po.supplier_id, l.unit_price, 'PO ' || po.po_no, auth.uid());
  end loop;
  select string_agg(m.code || ' ' || wf.fmt_qty(pl.qty) || ' ' || m.uom, ', ' order by pl.line_no), sum(pl.qty * pl.unit_price) into v_list, v_amt
    from purchase.po_lines pl join master.materials m on m.id = pl.material_id where pl.po_id = p_po;
  -- NV mua (người lập + NV mua, TP Mua) và Kế toán: hợp đồng đã được Giám đốc duyệt, gửi NCC
  perform wf.notify_users(array(select distinct u from unnest(inv.role_users(array['MUA_NV', 'MUA_TP', 'KT_KHO', 'KT_GT', 'KTT'])
                                                             || coalesce(po.created_by, '00000000-0000-0000-0000-000000000000'::uuid)) u
                                where u <> '00000000-0000-0000-0000-000000000000'::uuid),
    'Giám đốc đã duyệt hợp đồng mua ' || po.po_no,
    concat_ws(' · ', v_sup, coalesce('theo ' || v_tong, null), coalesce('thanh toán: ' || po.payment_terms, null),
              coalesce('giá trị ' || wf.fmt_qty(round(v_amt, 0)) || ' đ', null), left(coalesce(v_list, ''), 300)),
    '/don-mua/' || p_po);
  perform wf.notify_users(inv.role_users(array['THU_KHO']), 'Hàng sắp về theo ' || po.po_no,
    coalesce(v_sup, '') || coalesce(' · dự kiến ' || to_char(po.expected_date, 'DD/MM'), '') || ' · ' || left(coalesce(v_list, ''), 400), '/kho/nhan-hang');
end $$;

-- ---------------------------------------------------------------------------
-- 7. Hạn và cảnh báo theo ngày làm việc
-- ---------------------------------------------------------------------------
create or replace function purchase.po_deadline_alerts()
returns integer language plpgsql security definer set search_path = pg_catalog, public
set "TimeZone" = 'Asia/Ho_Chi_Minh' as $$
declare t record; q record; v_today date := (now() at time zone 'Asia/Ho_Chi_Minh')::date; v_n int := 0; v_users uuid[]; v_up uuid[];
        v_due timestamptz; v_kind text; v_role text; v_left int; v_draft int;
begin
  -- Đơn tổng: NV mua gửi đủ hợp đồng trong 5 ngày làm việc
  for t in select * from purchase.purchase_orders
            where kind = 'TONG' and status = 'DRAFT' and all_submitted_at is null and due_date is not null loop
    select count(*) into v_left from purchase.po_lines where po_id = t.id;
    select count(*) into v_draft from purchase.purchase_orders where parent_id = t.id and kind = 'HD' and status = 'DRAFT';
    continue when v_left = 0 and v_draft = 0;
    v_kind := case when v_today > t.due_date then 'PO_TONG_LATE'
                   when purchase.add_workdays(v_today, 1) >= t.due_date and extract(hour from now()) >= 8 then 'PO_TONG_WARN' end;
    continue when v_kind is null;
    insert into inv.alert_log (kind, ref_id, period_key) values (v_kind, t.id, t.due_date::text) on conflict do nothing;
    continue when not found;
    v_users := inv.role_users(array['MUA_NV', 'MUA_TP']);
    if v_kind = 'PO_TONG_LATE' then v_users := v_users || plan.gd_ids(); end if;
    perform wf.notify_users(array(select distinct u from unnest(v_users) u),
      case v_kind when 'PO_TONG_LATE' then 'Quá hạn gửi hợp đồng: ' else 'Còn 1 ngày làm việc: ' end || t.po_no,
      format('Đơn mua tổng %s hạn gửi đủ hợp đồng hết ngày %s: còn %s dòng chưa gom, %s hợp đồng chưa đệ trình TP Mua.',
             t.po_no, to_char(t.due_date, 'DD/MM/YYYY'), v_left, v_draft),
      '/don-mua/' || t.id);
    v_n := v_n + 1;
  end loop;

  -- Hợp đồng chờ duyệt: TP Mua 1 ngày làm việc, Giám đốc 1 ngày làm việc; quá hạn báo lên cấp trên
  for q in select r.*, wf.snap_step(r, r.current_seq) as st from wf.approval_requests r where r.status = 'PENDING' and r.doc_type = 'PO' loop
    v_due := purchase.due_after_workdays(q.step_started_at, 1);
    v_kind := case when now() >= v_due then 'OVERDUE' when now() >= v_due - interval '4 hours' then 'WARN' end;
    continue when v_kind is null;
    insert into wf.sla_alerts (request_id, seq, step_started_at, kind) values (q.id, q.current_seq, q.step_started_at, v_kind)
    on conflict do nothing;
    continue when not found;
    v_users := array_remove(wf.step_actor_ids(q.st), q.submitted_by);
    v_role := coalesce(q.st ->> 'escalated_from', q.st ->> 'role');
    v_up := case when v_kind = 'OVERDUE' then (case when v_role = 'MUA_TP' then plan.gd_ids() else plan.chair_ids() end) else '{}'::uuid[] end;
    perform wf.notify_users(v_users,
      case v_kind when 'OVERDUE' then 'Quá hạn duyệt hợp đồng mua: ' else 'Sắp đến hạn duyệt hợp đồng mua: ' end || q.doc_no,
      format('Bước "%s" hạn %s (1 ngày làm việc). %s', q.st ->> 'label', to_char(v_due at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM/YYYY'), coalesce(q.summary, '')),
      '/duyet/' || q.id, q.id, q.current_seq);
    v_up := array(select u from unnest(v_up) u where u <> all(v_users));
    if cardinality(v_up) > 0 then
      perform wf.notify_users(v_up, 'Cảnh báo: hợp đồng mua ' || q.doc_no || ' quá hạn duyệt',
        format('Bước "%s" quá hạn từ %s, chưa duyệt. %s', q.st ->> 'label', to_char(v_due at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM/YYYY'),
               coalesce(q.summary, '')),
        '/duyet/' || q.id, q.id, q.current_seq);
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'bmt_po_deadline';
    perform cron.schedule('bmt_po_deadline', '*/30 * * * *', 'select purchase.po_deadline_alerts()');
  end if;
end $$;

-- Hiệu chỉnh kế hoạch tháng chỉ giảm đơn mua chưa duyệt sinh từ MRP; đơn tổng / hợp đồng lập từ đề xuất mua Giám đốc đã duyệt
-- là "đã duyệt mua" (giữ nguyên như đề xuất đó)
do $$
declare d text; v_from text := $f$where po.plan_id = v_plan and po.status in ('DRAFT', 'PENDING_APPROVAL') and l.received_qty = 0;$f$;
begin
  select pg_get_functiondef('plan.revise_mrp(uuid)'::regprocedure) into d;
  if position(v_from in d) = 0 then raise exception 'plan.revise_mrp khác bản dự kiến: không vá được'; end if;
  d := replace(d, v_from, $f$where po.plan_id = v_plan and po.status in ('DRAFT', 'PENDING_APPROVAL') and l.received_qty = 0 and po.pr_id is null;$f$);
  -- bảng MRP hiệu chỉnh: dòng đơn mua lập từ đề xuất đã duyệt đã tính ở cột "đã duyệt mua" (không tính lại vào "chưa duyệt")
  v_from := $f$where pos.status in ('DRAFT', 'PENDING_APPROVAL') and l.received_qty = 0) x$f$;
  if position(v_from in d) = 0 then raise exception 'plan.revise_mrp khác bản dự kiến: không vá được (2)'; end if;
  execute replace(d, v_from, $f$where pos.status in ('DRAFT', 'PENDING_APPROVAL') and l.received_qty = 0 and l.pr_line_id is null) x$f$);
end $$;

-- Tổng quan: việc của NV mua / TP Mua
do $$
declare d text;
  v_from text := $f$if n > 0 then t := t || jsonb_build_object('key', 'safety', 'label', 'Vật tư dưới mức dự phòng', 'n', n, 'href', '/de-xuat/du-phong'); end if;$f$;
begin
  select pg_get_functiondef('app.dashboard()'::regprocedure) into d;
  if position(v_from in d) = 0 then raise exception 'app.dashboard khác bản dự kiến: không vá được'; end if;
  execute replace(d, v_from, v_from || $f$
    select count(*), count(*) filter (where po.due_date < v_today) into n, n2 from purchase.purchase_orders po
     where po.kind = 'TONG' and po.status = 'DRAFT' and po.all_submitted_at is null
       and (exists (select 1 from purchase.po_lines l where l.po_id = po.id)
            or exists (select 1 from purchase.purchase_orders h where h.parent_id = po.id and h.status = 'DRAFT'));
    if n > 0 then t := t || jsonb_build_object('key', 'po_tong', 'label', 'Đơn mua tổng chưa gửi đủ hợp đồng', 'n', n, 'late', n2, 'href', '/don-mua'); end if;$f$);
end $$;

-- ---------------------------------------------------------------------------
-- 8. View
-- ---------------------------------------------------------------------------
create or replace view app.v_pos with (security_invoker = true) as
select po.id, po.po_no, po.status, po.source,
       case po.source when 'MRP' then 'Tự sinh từ MRP' when 'PR' then 'Từ đề xuất mua' else 'Lập tay' end as source_label,
       po.supplier_id, sp.name as supplier_name, sp.tax_code as supplier_tax_code,
       po.order_date, po.expected_date, po.payment_terms, po.note, po.is_import, po.cancel_reason,
       po.plan_id, pp.plan_no, po.pr_id, pr.pr_no, po.adjustment_id, ad.adj_no, po.mrp_run_id,
       (select count(*) from purchase.po_lines l where l.po_id = po.id) as line_count,
       case when core.can_see_price() then (select round(sum(l.qty * l.unit_price), 0) from purchase.po_lines l where l.po_id = po.id) end as amount,
       (select count(*) from purchase.po_lines l where l.po_id = po.id and l.unit_price is null) as missing_price,
       exists (select 1 from purchase.po_lines l where l.po_id = po.id and l.received_qty > 0) as has_receipt,
       po.created_at, po.created_by, app.user_name(po.created_by) as created_by_name,
       (select ar.id from wf.approval_requests ar where ar.doc_type = 'PO' and ar.doc_id = po.id order by ar.submitted_at desc limit 1) as request_id,
       po.kind, po.parent_id, par.po_no as parent_no, po.due_date, po.all_submitted_at, po.done_at,
       (select count(*) from purchase.purchase_orders h where h.parent_id = po.id and h.status <> 'CANCELLED') as contract_count,
       (select count(*) from purchase.purchase_orders h where h.parent_id = po.id and h.status in ('APPROVED', 'SENT', 'PARTIAL_RECEIVED', 'RECEIVED', 'CLOSED')) as contract_approved,
       (select count(*) from purchase.purchase_orders h where h.parent_id = po.id and h.status = 'DRAFT') as contract_draft,
       (select count(*) from purchase.po_lines l where l.po_id = po.id and l.supplier_id is not null and l.unit_price is not null
          and l.expected_date is not null and coalesce(trim(l.payment_terms), '') <> '') as lines_ready,
       (po.kind = 'TONG' and po.status = 'DRAFT' and po.all_submitted_at is null and po.due_date < (now() at time zone 'Asia/Ho_Chi_Minh')::date) as overdue
from purchase.purchase_orders po
left join core.partners sp on sp.id = po.supplier_id
left join plan.production_plans pp on pp.id = po.plan_id
left join purchase.purchase_requests pr on pr.id = po.pr_id
left join plan.plan_adjustments ad on ad.id = po.adjustment_id
left join purchase.purchase_orders par on par.id = po.parent_id;

create or replace view app.v_po_lines with (security_invoker = true) as
select l.id, l.po_id, l.line_no, l.material_id, m.code as material_code, m.name as material_name, m.uom,
       l.supplier_item_code, l.qty, l.received_qty, l.expected_date, l.note, l.pr_line_id, l.mrp_line_id, l.mrp_qty,
       case when core.can_see_price() then l.unit_price end as unit_price,
       case when core.can_see_price() then round(l.qty * l.unit_price, 0) end as amount,
       (l.unit_price is not null) as priced,
       ml.total_issue + ml.reserve as need_qty, ml.available, ml.incoming, m.safety_stock as safety_qty,
       t.moq, t.pack_multiple, t.lead_time_days,
       coalesce(l.supplier_id, po.supplier_id) as supplier_id, sp.name as supplier_name,
       coalesce(l.payment_terms, nullif(po.payment_terms, 'Theo từng dòng')) as payment_terms,
       (coalesce(l.supplier_id, po.supplier_id) is not null and l.unit_price is not null and l.expected_date is not null
          and coalesce(trim(coalesce(l.payment_terms, nullif(po.payment_terms, 'Theo từng dòng'))), '') <> '') as ready
from purchase.po_lines l
join purchase.purchase_orders po on po.id = l.po_id
join master.materials m on m.id = l.material_id
left join core.partners sp on sp.id = coalesce(l.supplier_id, po.supplier_id)
left join plan.mrp_lines ml on ml.id = l.mrp_line_id
left join lateral (select * from purchase.material_terms(l.material_id)) t on true;
grant select on app.v_pos, app.v_po_lines to authenticated;

-- ---------------------------------------------------------------------------
-- 9. Quyền
-- ---------------------------------------------------------------------------
revoke execute on function purchase.add_workdays(date, int), purchase.due_after_workdays(timestamptz, int),
  purchase.po_from_pr(uuid), purchase.auto_po_on_pr_approve(), purchase.tong_refresh(uuid), purchase.trg_tong_refresh(),
  purchase.sync_line_supplier(), purchase.line_supplier_default(), purchase.po_deadline_alerts(), purchase.po_delete_release_pr(),
  purchase.po_from_mrp(uuid, uuid), purchase.po_approved(uuid) from public, anon, authenticated;
revoke execute on function app.po_line_set(uuid, uuid, numeric, text, date, numeric, text), app.po_make_contracts(uuid, uuid[], boolean),
  app.po_return_to_tong(uuid, text), app.po_from_pr(uuid) from public, anon;
grant execute on function app.po_line_set(uuid, uuid, numeric, text, date, numeric, text), app.po_make_contracts(uuid, uuid[], boolean),
  app.po_return_to_tong(uuid, text), app.po_from_pr(uuid) to authenticated;
