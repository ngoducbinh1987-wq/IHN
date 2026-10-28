-- Trang tổng quan theo phân quyền (anh Bình duyệt 28/10/2026): một hàm database trả số liệu giám sát cho mọi vai trò.
-- Mỗi khối chỉ có khi người xem có quyền xem dữ liệu đó (Quản trị tick ở Hệ thống → Phân quyền → Quyền thao tác):
--   output   sản lượng (production:view hoặc plan:view)
--   lots     lô kế hoạch tháng (plan:view)
--   tasks    việc của tôi (mọi người: quy trình duyệt + các bước duyệt trong module mà người xem làm được)
--   safety   tồn dự phòng (purchase:view hoặc inventory:view)
--   qc       QC bobin, lô hàng (quality:view hoặc production:view)
--   loss     hao hụt (production / inventory / cost:view – app.can_see_loss)
--   oee      hiệu suất máy từ báo cáo ca 7 ngày (production:view hoặc machine:view)
--   stock    giá trị tồn kho (vai trò được xem giá + inventory:view hoặc cost:view)
--   cost     giá thành sản xuất (vai trò được xem giá + cost:view)
-- Khối gắn với mục menu còn cần quyền vào mục đó (bảng tick "Quyền vào mục", migration 4700): dự phòng → Tồn dự phòng,
-- QC → QC bobin, hao hụt → báo cáo ngày/hao hụt, hiệu suất máy → Ghi nhận ca/báo cáo, giá trị tồn kho → Tồn kho/Nhập – xuất – tồn.
-- Thông tin chung (kế hoạch tháng, máy hôm nay, bảo dưỡng) vẫn ở app.shared_overview (mọi người, không có giá).

create or replace function app.dashboard() returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_uid    uuid := auth.uid();
  v_today  date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  v_m0     date := date_trunc('month', (now() at time zone 'Asia/Ho_Chi_Minh'))::date;
  v_start  timestamptz := (v_today::timestamp) at time zone 'Asia/Ho_Chi_Minh';
  v_mstart timestamptz := (date_trunc('month', (now() at time zone 'Asia/Ho_Chi_Minh'))::date::timestamp) at time zone 'Asia/Ho_Chi_Minh';
  v_dim    int := extract(day from (date_trunc('month', (now() at time zone 'Asia/Ho_Chi_Minh')) + interval '1 month - 1 day'))::int;
  v_price  boolean := core.can_see_price();
  v_qcmin  numeric := coalesce(inv.setting('qc_result_minutes'), 120);
  v_gd     boolean := plan.is_gd();
  v_pages  text[];
  r        jsonb := jsonb_build_object('today', v_today, 'month', v_m0, 'month_elapsed', round(extract(day from v_today)::numeric / v_dim, 4));
  x        jsonb; y jsonb; z jsonb; t jsonb := '[]';
  n int; n2 int; v_q numeric; v_fg numeric;
begin
  if not exists (select 1 from core.profiles where id = v_uid and status = 'ACTIVE') then
    raise exception 'Chưa đăng nhập';
  end if;
  -- Mục menu người xem được vào (như app.me: vai trò trực tiếp + ủy quyền; Quản trị vào mọi mục)
  if core.is_admin() then
    select array_agg(key) into v_pages from core.pages;
  else
    select array_agg(distinct rp.page_key) into v_pages from core.role_pages rp
     where rp.role_code in (select ur.role_code from core.user_roles ur where ur.user_id = v_uid
                            union select d.role_code from core.delegations d where d.to_user = v_uid and now() between d.valid_from and d.valid_to);
  end if;
  v_pages := coalesce(v_pages, '{}');

  -- ======================================================================= Sản lượng
  if core.has_perm('production', 'view') or core.has_perm('plan', 'view') then
    with fg as (
      select o.qty_m, l.qc_status, (o.created_at at time zone 'Asia/Ho_Chi_Minh')::date as d
      from mfg.wo_outputs o join inv.lots l on l.id = o.lot_id
      where l.item_kind = 'FG' and not (l.attrs ? 'void_slip') and l.qc_status <> 'REJECTED' and o.created_at >= v_start - interval '40 days'
    )
    select jsonb_build_object(
      'today_m',         coalesce(sum(qty_m) filter (where d = v_today), 0),
      'today_passed_m',  coalesce(sum(qty_m) filter (where d = v_today and qc_status in ('PASSED', 'CONSUMED')), 0),
      'month_m',         coalesce(sum(qty_m) filter (where d >= v_m0), 0),
      'month_passed_m',  coalesce(sum(qty_m) filter (where d >= v_m0 and qc_status in ('PASSED', 'CONSUMED')), 0),
      'days', (select coalesce(jsonb_agg(jsonb_build_object('date', g::date,
                        'm', coalesce((select sum(f.qty_m) from fg f where f.d = g::date), 0),
                        'passed_m', coalesce((select sum(f.qty_m) from fg f where f.d = g::date and f.qc_status in ('PASSED', 'CONSUMED')), 0))
                      order by g), '[]')
               from generate_series(v_today - 13, v_today, interval '1 day') g))
    into x from fg;
    -- Kế hoạch của tháng này (đã duyệt): mục tiêu mét, dự báo cuối tháng theo nhịp hiện tại
    select coalesce(sum(l.qty_m), 0) into v_q
      from plan.plan_lines l join plan.production_plans p on p.id = l.plan_id
     where p.period_month = v_m0 and p.status in ('APPROVED', 'CLOSED');
    x := x || jsonb_build_object('month_target_m', v_q,
      'forecast_m', round((x ->> 'month_m')::numeric * v_dim / extract(day from v_today)::numeric, 0));
    -- Bán thành phẩm và thành phẩm hôm nay theo công đoạn (phiếu hoàn thành bobin)
    select coalesce(jsonb_agg(to_jsonb(s) order by s.op_code), '[]') into y from (
      select bs.op_code, op.name as op_name, count(*) as bobbins, round(sum(bs.qty_m), 1) as m, round(sum(bs.net_kg), 1) as kg
      from mfg.bobbin_slips bs left join master.operations op on op.code = bs.op_code
      where bs.status = 'ACTIVE' and bs.ended_at >= v_start
      group by bs.op_code, op.name) s;
    -- Kế hoạch tháng đang thực hiện (đã duyệt): tiến độ thành phẩm
    select coalesce(jsonb_agg(to_jsonb(p) order by p.period_month nulls last, p.plan_no), '[]') into z from (
      select pp.id as plan_id, pp.plan_no, pp.period_label, pp.period_month,
             coalesce(sum(l.qty_m), 0) as total_m, coalesce(sum(dn.done_m), 0) as done_m, count(l.id) as lines
      from plan.production_plans pp
      join plan.plan_lines l on l.plan_id = pp.id and l.qty_m > 0
      left join lateral (
        select sum(o.qty_m) as done_m from mfg.work_orders w join mfg.wo_operations op on op.wo_id = w.id
        join mfg.wo_outputs o on o.wo_op_id = op.id join inv.lots lt on lt.id = o.lot_id and lt.item_kind = 'FG'
        where w.plan_line_id = l.id and not (lt.attrs ? 'void_slip') and lt.qc_status <> 'REJECTED') dn on true
      where pp.status = 'APPROVED'
      group by pp.id, pp.plan_no, pp.period_label, pp.period_month) p;
    r := r || jsonb_build_object('output', x || jsonb_build_object('stages_today', y, 'plans', z));
  end if;

  -- ======================================================================= Lô kế hoạch tháng (kế hoạch đã duyệt)
  if core.has_perm('plan', 'view') then
    with l as (
      select l.id, pp.plan_no, p.code as product_code, l.qty_m, l.due_date, l.committed_date, l.committed_by, l.lot_approved_at,
             plan.lot_eta(l.id) as eta,
             coalesce((select sum(o.qty_m) from mfg.work_orders w join mfg.wo_operations op on op.wo_id = w.id
                       join mfg.wo_outputs o on o.wo_op_id = op.id join inv.lots lt on lt.id = o.lot_id and lt.item_kind = 'FG'
                       where w.plan_line_id = l.id and not (lt.attrs ? 'void_slip') and lt.qc_status <> 'REJECTED'), 0) as done_m
      from plan.plan_lines l join plan.production_plans pp on pp.id = l.plan_id and pp.status = 'APPROVED'
      join master.products p on p.id = l.product_id
      where l.qty_m > 0
    ), s as (
      select l.*, case
        when done_m >= qty_m then 'DONE'
        when due_date is not null and due_date < v_today then 'LATE'
        when due_date is not null and eta is not null and eta > coalesce(committed_date, due_date) then 'RISK'
        when due_date is not null and eta is null and due_date <= v_today + 7 then 'RISK'
        else 'OK' end as state
      from l
    )
    select jsonb_build_object(
      'total', count(*), 'done', count(*) filter (where state = 'DONE'), 'late', count(*) filter (where state = 'LATE'),
      'risk', count(*) filter (where state = 'RISK'), 'ok', count(*) filter (where state = 'OK'),
      'no_due', count(*) filter (where state <> 'DONE' and due_date is null),
      'not_submitted', count(*) filter (where state <> 'DONE' and committed_date is null),
      'wait_approve', count(*) filter (where state <> 'DONE' and committed_date is not null and lot_approved_at is null),
      'items', coalesce((select jsonb_agg(to_jsonb(q) order by q.ord, q.due_date nulls last) from (
                 select s2.id, s2.plan_no, s2.product_code, s2.qty_m, s2.done_m, s2.due_date, s2.committed_date, s2.eta, s2.state,
                        s2.lot_approved_at is not null as approved,
                        case s2.state when 'LATE' then 1 when 'RISK' then 2 else 3 end as ord
                 from s s2 where s2.state in ('LATE', 'RISK')
                 order by case s2.state when 'LATE' then 1 else 2 end, s2.due_date nulls last limit 8) q), '[]'))
    into x from s;
    r := r || jsonb_build_object('lots', x);
  end if;

  -- ======================================================================= Việc của tôi
  select count(*), count(*) filter (where overdue) into n, n2 from app.v_approvals where my_turn;
  if n > 0 then
    t := t || jsonb_build_object('key', 'wf', 'label', 'Quy trình chờ tôi duyệt', 'n', n, 'late', n2, 'href', '/duyet');
  end if;
  if v_gd then
    select count(*) into n from plan.schedule_versions where status = 'PROPOSED' and coalesce(created_by, '00000000-0000-0000-0000-000000000000') <> v_uid;
    if n > 0 then t := t || jsonb_build_object('key', 'schedule', 'label', 'Lịch máy chờ Giám đốc duyệt', 'n', n, 'href', '/lich-may#schedule-review'); end if;
    select count(*) into n from plan.daily_releases where status = 'PROPOSED' and coalesce(proposed_by, '00000000-0000-0000-0000-000000000000') <> v_uid;
    if n > 0 then t := t || jsonb_build_object('key', 'release', 'label', 'Lệnh SX ngày chờ Giám đốc duyệt', 'n', n, 'href', '/lenh-ngay#release-review'); end if;
    select count(*) into n from plan.plan_lines l join plan.production_plans p on p.id = l.plan_id and p.status = 'APPROVED'
     where l.committed_date is not null and l.lot_approved_at is null and l.qty_m > 0
       and coalesce(l.committed_by, '00000000-0000-0000-0000-000000000000') <> v_uid;
    if n > 0 then t := t || jsonb_build_object('key', 'lot', 'label', 'Lịch lô TP SX đệ trình chờ duyệt', 'n', n, 'href', '/lich-may?tab=thang'); end if;
    select count(*) into n from plan.overtime_requests where status = 'PROPOSED' and proposed_by is distinct from v_uid;
    if n > 0 then t := t || jsonb_build_object('key', 'overtime', 'label', 'Đề xuất tăng ca, trộn sớm chờ Giám đốc duyệt', 'n', n, 'href', '/lich-may?tab=toiuu'); end if;
  end if;
  -- Đơn phát sinh đang ở bước tôi làm được (cùng điều kiện với app.kh_change_step)
  select count(*) into n from plan.change_requests c
   cross join lateral (select e as st from jsonb_array_elements(c.steps) with ordinality a(e, ord) where e ->> 'done_at' is null order by ord limit 1) cur
   where c.status = 'PENDING' and c.created_by is distinct from v_uid
     and not exists (select 1 from jsonb_array_elements(c.steps) e where e ->> 'done_by' = v_uid::text)
     and core.has_role(cur.st ->> 'role')
     and (jsonb_array_length(coalesce(cur.st -> 'user_ids', '[]')) = 0 or core.is_admin() or (cur.st -> 'user_ids') ? v_uid::text)
     and (cur.st ->> 'role' <> 'BGD' or jsonb_array_length(coalesce(cur.st -> 'user_ids', '[]')) > 0 or v_gd);
  if n > 0 then t := t || jsonb_build_object('key', 'dps', 'label', 'Lô phát sinh chờ tôi duyệt', 'n', n, 'href', '/lich-may?tab=phatsinh'); end if;
  if core.has_role('KT_KHO') then
    select count(*) into n from plan.issue_slips s join plan.daily_releases d on d.id = s.release_id
     where s.status = 'PENDING' and d.status = 'RELEASED'
       and coalesce(d.released_by, '00000000-0000-0000-0000-000000000000') <> v_uid
       and coalesce(d.proposed_by, '00000000-0000-0000-0000-000000000000') <> v_uid;
    if n > 0 then t := t || jsonb_build_object('key', 'slip', 'label', 'Phiếu lĩnh lệnh ngày chờ Kế toán SX duyệt', 'n', n, 'href', '/lenh-ngay'); end if;
  end if;
  if core.has_role('TO_TRUONG') or core.has_role('SX_TP') then
    select count(*) into n from mfg.shift_reports where status = 'SUBMITTED' and submitted_by is distinct from v_uid;
    if n > 0 then t := t || jsonb_build_object('key', 'shift', 'label', 'Báo cáo ca chờ chốt', 'n', n, 'href', '/ghi-nhan-ca'); end if;
  end if;
  if core.has_role('SX_TP') then
    select count(*) into n from mfg.maint_work_orders where status = 'DONE' and confirmed_at is null and done_by is distinct from v_uid;
    if n > 0 then t := t || jsonb_build_object('key', 'maint_ok', 'label', 'Máy sửa xong chờ xác nhận chạy lại', 'n', n, 'href', '/may/bao-duong'); end if;
  end if;
  if core.has_role('SX_TP') or core.has_role('SX_KH') or v_gd then
    select count(*) into n from mfg.maint_work_orders
     where sched_status = 'PROPOSED' and status in ('OPEN', 'IN_PROGRESS') and sched_by is distinct from v_uid;
    if n > 0 then t := t || jsonb_build_object('key', 'maint_sched', 'label', 'Lịch bảo dưỡng chờ chốt', 'n', n, 'href', '/lich-may?tab=baoduong'); end if;
  end if;
  if core.has_role('KT_TP') then
    select count(*) into n from master.machine_speeds where status = 'PENDING' and created_by is distinct from v_uid;
    if n > 0 then t := t || jsonb_build_object('key', 'speed', 'label', 'Tốc độ máy chờ TP KT/QA duyệt', 'n', n, 'href', '/may/toc-do'); end if;
    select count(*) into n from master.operator_skills where signed_at is null and assigned_by is distinct from v_uid;
    if n > 0 then t := t || jsonb_build_object('key', 'skill', 'label', 'Tay nghề người đứng máy chờ ký', 'n', n, 'href', '/may'); end if;
  end if;
  if core.has_role('QC') or core.has_role('KT_TP') then
    select count(*), count(*) filter (where l.created_at < now() - make_interval(mins => v_qcmin::int)) into n, n2
      from inv.lots l where l.item_kind in ('WIP', 'FG') and l.qc_status = 'PENDING' and not (l.attrs ? 'void_slip');
    if n > 0 then t := t || jsonb_build_object('key', 'qc', 'label', 'Bobin, lô chờ QC', 'n', n, 'late', n2, 'href', '/kho/qc'); end if;
  end if;
  if core.has_role('SX_TP') or v_gd then
    select count(*) into n from mfg.daily_reports dr cross join jsonb_array_elements(coalesce(dr.summary -> 'red', '[]')) e
     where dr.work_date >= v_today - 7
       and not exists (select 1 from mfg.loss_notes ln where ln.wo_id::text = e ->> 'wo_id' and ln.stage = e ->> 'stage' and ln.work_date = dr.work_date);
    if n > 0 then t := t || jsonb_build_object('key', 'loss_note', 'label', 'Hao hụt đỏ chưa giải trình', 'n', n, 'href', '/bao-cao/ngay'); end if;
  end if;
  if core.has_role('MUA_TP') or core.has_role('MUA_NV') then
    select count(*) into n from app.safety_stock_list() where below;
    if n > 0 then t := t || jsonb_build_object('key', 'safety', 'label', 'Vật tư dưới mức dự phòng', 'n', n, 'href', '/de-xuat/du-phong'); end if;
  end if;
  x := jsonb_build_object('items', t);
  -- Toàn hệ thống: Ban giám đốc, Quản trị (core.has_role nhận Quản trị)
  if core.has_role('BGD') then
    select count(*), count(*) filter (where overdue) into n, n2 from app.v_approvals where status = 'PENDING';
    x := x || jsonb_build_object('all_pending', n, 'all_overdue', n2);
  end if;
  r := r || jsonb_build_object('tasks', x);

  -- ======================================================================= Tồn dự phòng
  if (core.has_perm('purchase', 'view') or core.has_perm('inventory', 'view')) and 'du-phong' = any(v_pages) then
    select jsonb_build_object(
      'set', count(*) filter (where safety_stock > 0), 'below', count(*) filter (where below),
      'items', coalesce((select jsonb_agg(to_jsonb(q)) from (
                 select s2.code, s2.name, s2.uom, s2.safety_stock, s2.available, s2.incoming, s2.to_buy, s2.pending_no,
                        case when s2.per_day > 0 then round(s2.available / s2.per_day, 1) end as days_left
                 from app.safety_stock_list() s2 where s2.below
                 order by case when s2.per_day > 0 then s2.available / s2.per_day end nulls last, s2.code limit 6) q), '[]'))
    into x from app.safety_stock_list();
    r := r || jsonb_build_object('safety', x);
  end if;

  -- ======================================================================= QC
  if (core.has_perm('quality', 'view') or core.has_perm('production', 'view')) and 'kho-qc' = any(v_pages) then
    select jsonb_build_object(
      'pending', count(*) filter (where qc_status = 'PENDING'),
      'late', count(*) filter (where qc_status = 'PENDING' and created_at < now() - make_interval(mins => v_qcmin::int)),
      'oldest_min', round(extract(epoch from now() - min(created_at) filter (where qc_status = 'PENDING')) / 60),
      'quarantine', count(*) filter (where qc_status = 'QUARANTINE'),
      'passed_7d', count(*) filter (where created_at >= v_start - interval '6 days' and qc_status in ('PASSED', 'CONSUMED')),
      'failed_7d', count(*) filter (where created_at >= v_start - interval '6 days' and qc_status in ('REJECTED', 'QUARANTINE')),
      'limit_min', v_qcmin)
    into x from inv.lots
    where item_kind in ('WIP', 'FG') and wo_op_id is not null and not (attrs ? 'void_slip')
      and (qc_status in ('PENDING', 'QUARANTINE') or created_at >= v_start - interval '6 days');
    r := r || jsonb_build_object('qc', x);
  end if;

  -- ======================================================================= Hao hụt (tính đến hết hôm nay cho các lô có hoạt động hôm nay)
  if app.can_see_loss() and v_pages && array['bc-ngay', 'bc-hao-hut'] then
    y := mfg.daily_report_data(v_today);
    select jsonb_build_object('date', v_today, 'counts', y -> 'counts',
      'items', coalesce((select jsonb_agg(jsonb_build_object('wo_id', e ->> 'wo_id', 'wo_no', e ->> 'wo_no', 'product_code', e ->> 'product_code',
                                  'stage', e ->> 'stage', 'label', e ->> 'label', 'level', e ->> 'level', 'var_pct', e -> 'var_pct', 'noted', e ->> 'note' is not null)
                                order by (e ->> 'level' = 'RED') desc, (e ->> 'var_pct')::numeric desc nulls last)
                         from (select e from jsonb_array_elements(coalesce(y -> 'loss', '[]')) e where e ->> 'level' in ('RED', 'YELLOW') limit 8) s), '[]'),
      'red_open_7d', (select count(*) from mfg.daily_reports dr cross join jsonb_array_elements(coalesce(dr.summary -> 'red', '[]')) e
                       where dr.work_date >= v_today - 7
                         and not exists (select 1 from mfg.loss_notes ln where ln.wo_id::text = e ->> 'wo_id' and ln.stage = e ->> 'stage' and ln.work_date = dr.work_date)),
      'scrap_month_kg', (select coalesce(round(sum(qty_kg), 1), 0) from mfg.scrap_records where recorded_at >= v_mstart))
    into x;
    r := r || jsonb_build_object('loss', x);
  end if;

  -- ======================================================================= Hiệu suất máy (báo cáo ca đã gửi/chốt, 7 ngày gần nhất)
  -- Sẵn sàng = (giờ ca − giờ dừng) / giờ ca; Đạt kế hoạch = mét khai báo / mét kế hoạch của ca; Chất lượng = tỷ lệ bobin QC đạt 7 ngày;
  -- Hiệu suất tổng (gần đúng OEE) = Sẵn sàng × Tốc độ × Chất lượng = mét khai báo / mét kế hoạch × Chất lượng.
  if (core.has_perm('production', 'view') or core.has_perm('machine', 'view')) and v_pages && array['ghi-nhan-ca', 'bc-ngay', 'may-bao-cao', 'may-lich-su'] then
    with rp as (
      select sr.machine_code, sr.work_date,
             greatest(0, (extract(epoch from (sh.end_time - sh.start_time)) / 60 + case when sh.end_time <= sh.start_time then 1440 else 0 end) - sh.break_min) as shift_min,
             (select coalesce(sum((e ->> 'min')::numeric), 0) from jsonb_array_elements(coalesce(sr.downtime, '[]')) e) as down_min,
             (select coalesce(sum((e ->> 'planned_m')::numeric), 0) from jsonb_array_elements(coalesce(sr.lines, '[]')) e where e ->> 'planned_m' ~ '^[0-9.]+$') as planned_m,
             (select coalesce(sum((e ->> 'declared_m')::numeric), 0) from jsonb_array_elements(coalesce(sr.lines, '[]')) e where e ->> 'declared_m' ~ '^[0-9.]+$') as declared_m
      from mfg.shift_reports sr join master.shifts sh on sh.code = sr.shift_code
      where sr.work_date between v_today - 6 and v_today and sr.status in ('SUBMITTED', 'CONFIRMED')
    ), m as (
      select rp.machine_code, mc.name as machine_name, count(*) as reports, sum(shift_min) as shift_min, sum(down_min) as down_min,
             sum(planned_m) as planned_m, sum(declared_m) as declared_m
      from rp left join master.machines mc on mc.code = rp.machine_code group by rp.machine_code, mc.name
    )
    select jsonb_build_object(
      'from', v_today - 6, 'to', v_today, 'reports', coalesce(sum(reports), 0),
      'shift_min', coalesce(sum(shift_min), 0), 'down_min', coalesce(sum(down_min), 0),
      'planned_m', coalesce(sum(planned_m), 0), 'declared_m', coalesce(sum(declared_m), 0),
      'machines', coalesce(jsonb_agg(jsonb_build_object('code', machine_code, 'name', machine_name, 'reports', reports,
                     'availability', round((shift_min - least(down_min, shift_min)) / nullif(shift_min, 0), 4),
                     'attainment', round(declared_m / nullif(planned_m, 0), 4), 'down_min', down_min,
                     'planned_m', planned_m, 'declared_m', declared_m) order by machine_code), '[]'))
    into x from m;
    -- Dừng máy theo lý do (7 ngày), phút
    select coalesce(jsonb_agg(jsonb_build_object('reason', q.reason, 'name', coalesce(rc.name, q.reason), 'planned', coalesce(rc.planned, false), 'min', q.min)
                              order by q.min desc), '[]') into y
    from (select coalesce(e ->> 'reason', 'KHAC') as reason, sum((e ->> 'min')::numeric) as min
          from mfg.shift_reports sr cross join jsonb_array_elements(coalesce(sr.downtime, '[]')) e
          where sr.work_date between v_today - 6 and v_today and sr.status in ('SUBMITTED', 'CONFIRMED') and e ->> 'min' ~ '^[0-9.]+$'
          group by 1) q left join master.reason_codes rc on rc.code = q.reason;
    -- Ngày có phiếu hoàn thành của máy mà chưa có báo cáo ca
    select count(*) into n from (
      select distinct mc.code, (bs.ended_at at time zone 'Asia/Ho_Chi_Minh')::date as d
      from mfg.bobbin_slips bs join master.machines mc on mc.id = bs.machine_id
      where bs.status = 'ACTIVE' and bs.ended_at >= v_start - interval '6 days') s
     where not exists (select 1 from mfg.shift_reports sr where sr.machine_code = s.code and sr.work_date = s.d and sr.status in ('SUBMITTED', 'CONFIRMED'));
    x := x || jsonb_build_object('reasons', y, 'missing', n,
      'availability', round(((x ->> 'shift_min')::numeric - least((x ->> 'down_min')::numeric, (x ->> 'shift_min')::numeric)) / nullif((x ->> 'shift_min')::numeric, 0), 4),
      'attainment', round((x ->> 'declared_m')::numeric / nullif((x ->> 'planned_m')::numeric, 0), 4));
    r := r || jsonb_build_object('oee', x);
  end if;

  -- ======================================================================= Giá trị tồn kho (chỉ vai trò được xem giá)
  if v_price and (core.has_perm('inventory', 'view') or core.has_perm('cost', 'view')) and v_pages && array['kho', 'kho-ton', 'kho-so-cai'] then
    with lotcost as (   -- giá BTP/TP: bình quân các lần nhập kho của lô (tạm tính đến khi chốt giá thành)
      select sm.lot_id, sum(sm.amount) / nullif(sum(sm.qty), 0) as unit_cost
      from inv.stock_moves sm where sm.qty > 0 and sm.unit_cost > 0 group by sm.lot_id
    ), v as (
      select w.code, w.name, w.kind,
             coalesce(sum(iv.value), 0) as value, count(*) filter (where iv.qty > 0 and iv.avg_cost = 0) as no_price, count(*) filter (where iv.qty > 0) as items
      from inv.warehouses w join cost.item_valuation iv on iv.warehouse_id = w.id
      where w.kind = 'MAT' and iv.qty <> 0 group by w.code, w.name, w.kind
      union all
      select w.code, w.name, w.kind,
             round(coalesce(sum(b.qty * lc.unit_cost), 0), 0), count(*) filter (where lc.unit_cost is null), count(*)
      from inv.warehouses w join inv.stock_balances b on b.warehouse_id = w.id and b.qty > 0
      left join lotcost lc on lc.lot_id = b.lot_id
      where w.kind in ('WIP', 'FG') group by w.code, w.name, w.kind
    )
    select jsonb_build_object('total', coalesce(sum(value), 0), 'no_price', coalesce(sum(no_price), 0),
      'by_kind', jsonb_build_object('MAT', coalesce(sum(value) filter (where kind = 'MAT'), 0), 'WIP', coalesce(sum(value) filter (where kind = 'WIP'), 0),
                                    'FG', coalesce(sum(value) filter (where kind = 'FG'), 0)),
      'warehouses', coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'kind', kind, 'value', value, 'items', items, 'no_price', no_price) order by kind, code), '[]'))
    into x from v;
    -- NVL đã xuất cho sản xuất trong tháng (giá bình quân lúc xuất, trừ phần trả lại)
    select coalesce(round(-sum(sm.amount), 0), 0) into v_q
      from inv.stock_moves sm join inv.lots l on l.id = sm.lot_id and l.item_kind = 'MAT'
     where sm.move_type in ('ISSUE_WO', 'RETURN_WO') and sm.moved_at >= v_mstart;
    r := r || jsonb_build_object('stock', x || jsonb_build_object('issued_month', v_q));
  end if;

  -- ======================================================================= Giá thành sản xuất (chỉ vai trò được xem giá)
  if v_price and core.has_perm('cost', 'view') then
    select coalesce(jsonb_agg(jsonb_build_object('period', cp.period, 'status', cp.status, 'wos', s.wos, 'good_m', s.good_m,
                               'std_total', s.std_total, 'act_total', s.act_total, 'act_material', s.act_material,
                               'per_m', round(s.act_total / nullif(s.good_m, 0), 0), 'std_per_m', round(s.std_total / nullif(s.good_m, 0), 0),
                               'var_pct', round((s.act_total - s.std_total) / nullif(s.std_total, 0) * 100, 2))
                             order by cp.period desc), '[]')
      into x
      from cost.cost_periods cp
      cross join lateral (select count(*) as wos, coalesce(sum(c.good_m), 0) as good_m, coalesce(sum(c.std_total), 0) as std_total,
                                 coalesce(sum(c.act_total), 0) as act_total, coalesce(sum(c.act_material), 0) as act_material
                          from cost.wo_costs c where c.period_id = cp.id) s
     where cp.period >= to_char(v_m0 - interval '2 months', 'YYYY-MM');
    -- Tạm tính tháng này khi chưa chốt giá thành: chi phí NVL đã xuất ÷ mét thành phẩm đã làm
    select coalesce(round(-sum(sm.amount), 0), 0) into v_q
      from inv.stock_moves sm join inv.lots l on l.id = sm.lot_id and l.item_kind = 'MAT'
     where sm.move_type in ('ISSUE_WO', 'RETURN_WO') and sm.moved_at >= v_mstart;
    select coalesce(sum(o.qty_m), 0) into v_fg
      from mfg.wo_outputs o join inv.lots l on l.id = o.lot_id and l.item_kind = 'FG'
     where o.created_at >= v_mstart and not (l.attrs ? 'void_slip') and l.qc_status <> 'REJECTED';
    r := r || jsonb_build_object('cost', jsonb_build_object('periods', x, 'month_material', v_q, 'month_fg_m', v_fg,
      'est_material_per_m', round(v_q / nullif(v_fg, 0), 0)));
  end if;

  return r;
end $$;
revoke all on function app.dashboard() from public, anon;
grant execute on function app.dashboard() to authenticated;
