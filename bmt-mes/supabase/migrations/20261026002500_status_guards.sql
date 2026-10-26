-- BMT MES · 20261026002500 · Rà soát 26/10/2026: chốt trạng thái chứng từ, đơn phát sinh, mã kiểm, cảnh báo bảo mật
--  1. Không đổi trạng thái chứng từ bằng cách ghi thẳng vào bảng qua API (chỉ qua hàm duyệt/xử lý của hệ thống)
--  2. Đơn phát sinh: database tự lập các bước duyệt theo mức; không nhận mức thấp hơn kết quả mô phỏng; bỏ ngoại lệ tự duyệt
--  3. Mã kiểm chứng từ bỏ cột ngày bắt đầu xếp lịch (sched_start) → gỡ kẹt KH-2610-01
--  4. Cảnh báo bảo mật: thu quyền anon, cố định search_path, pg_net sang schema extensions
--  5. MRP tính "Trễ" theo ngày giờ Việt Nam

-- ---------------------------------------------------------------------------
-- 1. Chốt trạng thái
-- ---------------------------------------------------------------------------
-- Hàm nghiệp vụ (SECURITY DEFINER) chạy dưới quyền chủ sở hữu nên được đổi trạng thái;
-- người dùng ghi trực tiếp (vai trò authenticated/anon) thì chỉ được tạo ở trạng thái đầu và các bước chuyển liệt kê.
-- Tham số trigger: cột trạng thái, giá trị khi tạo ('' = trống), các bước chuyển cho phép dạng 'TỪ>SANG'.
create or replace function core.guard_status() returns trigger
language plpgsql set search_path = pg_catalog, public as $$
declare v_col text := tg_argv[0]; v_init text := nullif(tg_argv[1], ''); v_old text; v_new text; i integer;
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  v_new := to_jsonb(new) ->> v_col;
  if tg_op = 'INSERT' then
    if v_new is distinct from v_init then
      raise exception 'Tạo mới phải ở trạng thái % (đổi trạng thái qua chức năng duyệt của BMT MES)', coalesce(v_init, 'trống');
    end if;
    return new;
  end if;
  v_old := to_jsonb(old) ->> v_col;
  if v_new is not distinct from v_old then return new; end if;
  for i in 2 .. tg_nargs - 1 loop
    if tg_argv[i] = coalesce(v_old, '') || '>' || coalesce(v_new, '') then return new; end if;
  end loop;
  raise exception 'Không đổi trực tiếp trạng thái % từ % sang %: dùng chức năng duyệt/xử lý của BMT MES',
    tg_table_schema || '.' || tg_table_name, coalesce(v_old, 'trống'), coalesce(v_new, 'trống');
end $$;
revoke execute on function core.guard_status() from public, anon, authenticated;

do $$
declare r record;
begin
  for r in select * from (values
    ('purchase.purchase_requests', 'status', 'DRAFT', ''),
    ('purchase.purchase_orders',   'status', 'DRAFT', ''),
    ('purchase.goods_receipts',    'status', 'DRAFT', ''),
    ('plan.production_plans',      'status', 'DRAFT', ''),
    ('plan.purchase_proposals',    'status', 'DRAFT', ''),
    ('sales.sales_orders',         'status', 'DRAFT', ''),
    ('sales.so_lines',             'line_status', 'OPEN', ''),
    ('sales.deliveries',           'status', 'DRAFT', ''),
    ('inv.lots',                   'qc_status', 'PENDING', ''),
    ('inv.stock_docs',             'status', 'DRAFT', ''),
    ('inv.stock_docs',             'review_status', 'PENDING', ''),
    ('inv.stock_counts',           'status', 'OPEN', ''),
    ('mfg.work_orders',            'status', 'DRAFT', ''),
    ('mfg.wo_operations',          'status', 'PENDING', ''),
    ('mfg.maint_work_orders',      'status', 'OPEN', 'OPEN>CANCELLED'),
    ('master.machines',            'status', 'IDLE', ''),
    ('master.product_specs',       'status', 'DRAFT', ''),
    ('master.bom_headers',         'status', 'DRAFT', ''),
    ('master.tech_param_sets',     'status', 'DRAFT', ''),
    ('cost.cost_periods',          'status', 'OPEN', ''),
    ('cost.wo_costs',              'status', 'DRAFT', ''),
    ('qa.inspections',             'result', '', ''),
    ('qa.ncrs',                    'status', 'OPEN', '')
  ) t(tbl, col, init, moves) loop
    execute format('drop trigger if exists %I on %s', 'trg_guard_' || r.col, r.tbl);
    execute format('create trigger %I before insert or update of %I on %s for each row execute function core.guard_status(%L, %L%s)',
                   'trg_guard_' || r.col, r.col, r.tbl, r.col, r.init,
                   (select coalesce(string_agg(format(', %L', m), ''), '') from unnest(string_to_array(nullif(r.moves, ''), ',')) m));
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Đơn phát sinh
-- ---------------------------------------------------------------------------
-- Các bước duyệt do database lập theo mức (giống web/lib/kh/change.ts stepsFor); p_steps chỉ giữ để tương thích, không dùng.
-- Mức không được thấp hơn mức suy ra từ kết quả mô phỏng: chen vùng khóa → C; làm trễ đơn khác/không xếp được/trễ hạn → tối thiểu B.
create or replace function app.kh_create_change(p_plan uuid, p_payload jsonb, p_result jsonb, p_level text, p_steps jsonb) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid; v_no text; v_steps jsonb; v_min text;
begin
  if not app.kh_has_any(array['SX_TP','SX_KH']) then raise exception 'Chỉ Quản lý SX lập đề nghị đơn phát sinh'; end if;
  if p_level not in ('A','B','C') then raise exception 'Mức không hợp lệ'; end if;
  if not exists (select 1 from plan.production_plans where id = p_plan) then raise exception 'Không tìm thấy kế hoạch'; end if;
  v_min := case
    when coalesce(p_payload ->> 'priority', '1') = '0' and coalesce((p_payload ->> 'br')::boolean, false) then 'C'
    when jsonb_array_length(coalesce(p_result -> 'newly', '[]')) > 0
      or not coalesce((p_result ->> 'placed')::boolean, false)
      or coalesce((p_result ->> 'slack')::numeric, 0) < 0 then 'B'
    else 'A' end;
  if p_level < v_min then raise exception 'Kết quả mô phỏng cần tối thiểu mức %', v_min; end if;
  v_steps := jsonb_build_array(jsonb_build_object('role', 'SX_TP', 'label', 'Quản lý SX lập đề nghị, chạy mô phỏng',
                                                  'done_by', auth.uid(), 'done_name', app.user_name(auth.uid()), 'done_at', now()));
  if p_level = 'B' then
    v_steps := v_steps || jsonb_build_array(jsonb_build_object('role', 'BGD', 'label', 'Giám đốc duyệt, chốt ngày giao với kinh doanh'));
  elsif p_level = 'C' then
    v_steps := v_steps || jsonb_build_array(
      jsonb_build_object('role', 'KT_TP', 'label', 'TP Kỹ thuật/QA cho ý kiến: đổi mã, mẫu đầu mã, thông số'),
      jsonb_build_object('role', 'BGD', 'label', 'Giám đốc duyệt chen vào vùng khóa'));
  end if;
  select core.next_no('DPS', 3) into v_no;
  insert into plan.change_requests (plan_id, req_no, payload, result, level, steps, status)
  values (p_plan, v_no, p_payload, p_result, p_level, v_steps, case when jsonb_array_length(v_steps) = 1 then 'READY' else 'PENDING' end)
  returning id into v_id;
  if jsonb_array_length(v_steps) > 1 then
    perform app.kh_notify_role(v_steps->1->>'role', 'Đơn phát sinh ' || v_no || ' chờ bạn', v_steps->1->>'label', '/lich-may?tab=phatsinh');
  end if;
  return v_id;
end $$;

-- Duyệt một bước: không ai duyệt đề nghị mình lập hoặc bước mình đã làm (bỏ ngoại lệ cho Quản lý SX)
create or replace function app.kh_change_step(p_req uuid, p_action text, p_comment text default null) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare c plan.change_requests; i integer; n integer; st jsonb; v_role text;
begin
  select * into c from plan.change_requests where id = p_req for update;
  if not found then raise exception 'Không tìm thấy đề nghị'; end if;
  if c.status <> 'PENDING' then raise exception 'Đề nghị không còn chờ duyệt'; end if;
  n := jsonb_array_length(c.steps);
  select min(ord - 1) into i from jsonb_array_elements(c.steps) with ordinality a(e, ord) where e->>'done_at' is null;
  if i is null then raise exception 'Đề nghị đã đủ bước'; end if;
  st := c.steps->i; v_role := st->>'role';
  if not core.has_role(v_role) then raise exception 'Bước này chờ %', st->>'label'; end if;
  if (c.created_by = auth.uid() or exists (select 1 from jsonb_array_elements(c.steps) e where e->>'done_by' = auth.uid()::text)) then
    raise exception 'Bạn đã lập hoặc đã làm bước trước của đề nghị này: không tự duyệt được';
  end if;
  if p_action = 'return' then
    if coalesce(trim(p_comment), '') = '' then raise exception 'Nhập lý do trả lại'; end if;
    update plan.change_requests set status = 'RETURNED', note = trim(p_comment), finished_at = now(),
      steps = jsonb_set(steps, array[i::text], st || jsonb_build_object('done_by', auth.uid(), 'done_name', app.user_name(auth.uid()), 'done_at', now(), 'result', 'Trả lại'))
    where id = p_req;
    insert into wf.notifications (user_id, title, body, link) values (c.created_by, 'Đơn phát sinh ' || c.req_no || ' bị trả lại', trim(p_comment), '/lich-may?tab=phatsinh');
    return 'RETURNED';
  end if;
  update plan.change_requests set
    steps = jsonb_set(steps, array[i::text], st || jsonb_build_object('done_by', auth.uid(), 'done_name', app.user_name(auth.uid()), 'done_at', now(), 'result', 'Đồng ý', 'comment', nullif(trim(coalesce(p_comment, '')), ''))),
    status = case when i = n - 1 then 'READY' else 'PENDING' end
  where id = p_req;
  if i < n - 1 then
    perform app.kh_notify_role(c.steps->(i + 1)->>'role', 'Đơn phát sinh ' || c.req_no || ' chờ bạn', c.steps->(i + 1)->>'label', '/lich-may?tab=phatsinh');
    return 'PENDING';
  end if;
  return 'READY';
end $$;

-- ---------------------------------------------------------------------------
-- 3. Mã kiểm chứng từ: bỏ các cột hệ thống/xếp lịch (cờ MRP, ngày bắt đầu xếp lịch) khỏi nội dung cần duyệt
-- ---------------------------------------------------------------------------
create or replace function wf.doc_hash(p_table text, p_id uuid) returns text
language plpgsql stable security definer set search_path = pg_catalog, public set timezone = 'UTC' as $$
declare v jsonb;
begin
  execute format('select to_jsonb(t) - array[''status'',''updated_at'',''updated_by'',''current_spec_id'',''mrp_stale'',''sched_start''] from %s t where id = $1', p_table)
    into v using p_id;
  return md5(v::text);
end $$;

-- ---------------------------------------------------------------------------
-- 4. Cảnh báo bảo mật
-- ---------------------------------------------------------------------------
revoke execute on function wf.can_act_step(jsonb), wf.step_actor_ids(jsonb), plan.mrp_lock_reason(uuid) from public, anon;
grant execute on function wf.can_act_step(jsonb), wf.step_actor_ids(jsonb), plan.mrp_lock_reason(uuid) to authenticated, service_role;
do $$
begin
  if exists (select 1 from pg_proc where proname = 'can_act_step' and pronargs = 2 and pronamespace = 'wf'::regnamespace) then
    revoke execute on function wf.can_act_step(jsonb, timestamptz) from public, anon;
    grant execute on function wf.can_act_step(jsonb, timestamptz) to authenticated, service_role;
  end if;
end $$;
alter function wf.touch_step() set search_path = pg_catalog, public;
alter function wf.snap_step(wf.approval_requests, smallint) set search_path = pg_catalog, public;
alter function wf.step_applies(jsonb, jsonb) set search_path = pg_catalog, public;
alter function core.vn_num(numeric) set search_path = pg_catalog, public;

-- pg_net không đổi schema được: cài lại vào schema extensions (hàm vẫn ở schema net, job email không đổi)
do $$
begin
  if exists (select 1 from pg_extension e join pg_namespace n on n.oid = e.extnamespace where e.extname = 'pg_net' and n.nspname = 'public')
     and exists (select 1 from pg_namespace where nspname = 'extensions') then
    drop extension pg_net;
    create extension pg_net with schema extensions;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. MRP: ngày theo giờ Việt Nam (Supabase chạy UTC)
-- ---------------------------------------------------------------------------
alter function plan.run_mrp(uuid, jsonb) set timezone = 'Asia/Ho_Chi_Minh';
alter function app.adjust_mrp_line(uuid, numeric, date, text, text) set timezone = 'Asia/Ho_Chi_Minh';
