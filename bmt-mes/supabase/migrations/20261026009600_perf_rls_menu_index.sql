-- Tối ưu hiệu năng (anh Bình duyệt 05/11/2026, mục 1, 2, 4 của rà soát code):
-- (1) Quy tắc RLS gọi core.has_perm/has_role, app.kh_can_view/can_see_loss, auth.uid() với tham số hằng → bọc thành
--     (select …) để Postgres tính MỘT lần mỗi câu truy vấn (InitPlan) thay vì từng dòng. Kết quả lọc không đổi
--     (các hàm đều STABLE, tham số là hằng, không phụ thuộc dòng).
-- (2) app.menu_counts(): gộp 7 số đếm trên menu thành một lượt gọi (SECURITY INVOKER: đếm theo đúng RLS của người xem
--     như các truy vấn cũ của web; phần nào lỗi thì trả null, không làm hỏng trang).
-- (4) Xóa 3 index trùng; thêm index cho khóa ngoại chưa có index (schema nghiệp vụ).

-- ===== (1) RLS: tính hàm kiểm quyền một lần mỗi câu truy vấn =====
do $$
declare
  r record; q text; w text; n int := 0; left_over int;
  fns constant text := '(?:core\.has_perm|core\.has_role|app\.kh_can_view|app\.can_see_loss|auth\.uid)';
  args constant text := '\((?:''[^'']*''::text(?:, ''[^'']*''::text)*)?\)';
  pat text; unwrap text;
begin
  pat := '(' || fns || args || ')';
  unwrap := '\( SELECT (' || fns || args || ') AS [a-z_]+\)';
  for r in
    select * from pg_policies
    where schemaname in ('core','master','sales','plan','purchase','inv','mfg','qa','cost','wf','iot','integ','app')
  loop
    q := r.qual; w := r.with_check;
    if q is not null then q := regexp_replace(regexp_replace(q, unwrap, '\1', 'g'), pat, '(select \1)', 'g'); end if;
    if w is not null then w := regexp_replace(regexp_replace(w, unwrap, '\1', 'g'), pat, '(select \1)', 'g'); end if;
    if q is distinct from r.qual or w is distinct from r.with_check then
      execute format('alter policy %I on %I.%I%s%s', r.policyname, r.schemaname, r.tablename,
        case when q is not null then ' using (' || q || ')' else '' end,
        case when w is not null then ' with check (' || w || ')' else '' end);
      n := n + 1;
    end if;
  end loop;
  -- kiểm: không còn lời gọi nào chưa bọc
  select count(*) into left_over
  from pg_policies p,
       regexp_matches(coalesce(p.qual, '') || ' ' || coalesce(p.with_check, ''), '(?<!SELECT )' || fns || '\(', 'g')
  where p.schemaname in ('core','master','sales','plan','purchase','inv','mfg','qa','cost','wf','iot','integ','app');
  if left_over > 0 then raise exception 'Còn % lời gọi hàm kiểm quyền chưa bọc trong RLS', left_over; end if;
  raise notice 'RLS: đã viết lại % quy tắc', n;
end $$;

-- ===== (2) Số đếm trên menu: một lượt gọi =====
create or replace function app.menu_counts() returns jsonb
language plpgsql stable set search_path = pg_catalog, public as $$
declare
  v_turn bigint; v_unread bigint; v_maint bigint; v_qc bigint; v_safety int; v_po bigint; v_alarm int;
begin
  begin select count(*) into v_turn from app.v_approvals where my_turn; exception when others then v_turn := null; end;
  begin select count(*) into v_unread from app.v_notifications where read_at is null; exception when others then v_unread := null; end;
  -- việc bảo dưỡng quá hạn chưa có phiếu (RLS: người xem được máy)
  begin select count(*) into v_maint from app.v_maint_plans where active and state = 'OVERDUE' and open_wo is null;
  exception when others then v_maint := null; end;
  -- bobin, lô chờ QC (RLS: người xem được kho)
  begin select count(*) into v_qc from inv.lots where qc_status = 'PENDING'; exception when others then v_qc := null; end;
  -- vật tư dưới mức tồn dự phòng (hàm tự kiểm quyền)
  begin v_safety := app.safety_below_count(); exception when others then v_safety := null; end;
  -- đơn mua nháp chờ NV mua (RLS: người xem được mua hàng)
  begin select count(*) into v_po from purchase.purchase_orders where status = 'DRAFT'; exception when others then v_po := null; end;
  -- máy xếp lịch thiếu thông số tốc độ (hàm tự kiểm quyền)
  begin v_alarm := app.machine_param_alarm_count(); exception when others then v_alarm := null; end;
  return jsonb_build_object('my_turn', v_turn, 'unread', v_unread, 'maint_overdue', v_maint, 'qc_wait', v_qc,
                            'safety_below', v_safety, 'po_draft', v_po, 'param_alarm', v_alarm);
end $$;
revoke all on function app.menu_counts() from public, anon;
grant execute on function app.menu_counts() to authenticated;

-- ===== (4) Index =====
-- index trùng (giữ bản đang được dùng)
drop index if exists inv.stock_balances_lot_id_idx;      -- trùng inv.stock_balances_lot
drop index if exists master.machines_inline_with_idx;    -- trùng master.machines_inline_idx
drop index if exists purchase.po_lines_pr_line_id_idx;   -- trùng purchase.po_lines_pr_line_idx

-- khóa ngoại chưa có index nào bắt đầu bằng đúng các cột của khóa
do $$
declare r record; v_name text; n int := 0;
begin
  for r in
    select c.conrelid, c.conname, n.nspname, t.relname, c.conkey,
           (select string_agg(quote_ident(a.attname), ', ' order by k.ord)
              from unnest(c.conkey) with ordinality k(attnum, ord)
              join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum) cols,
           (select string_agg(a.attname, '_' order by k.ord)
              from unnest(c.conkey) with ordinality k(attnum, ord)
              join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum) colnames
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where c.contype = 'f' and t.relkind = 'r'
      and n.nspname in ('core','master','sales','plan','purchase','inv','mfg','qa','cost','wf','iot','integ','app')
      and not exists (
        select 1 from pg_index i
        where i.indrelid = c.conrelid
          and (string_to_array(i.indkey::text, ' ')::int2[])[1:array_length(c.conkey, 1)] @> c.conkey
          and (string_to_array(i.indkey::text, ' ')::int2[])[1:array_length(c.conkey, 1)] <@ c.conkey)
  loop
    v_name := left(r.relname || '_' || r.colnames, 56) || '_fkidx';
    execute format('create index if not exists %I on %I.%I (%s)', v_name, r.nspname, r.relname, r.cols);
    n := n + 1;
  end loop;
  raise notice 'Index khóa ngoại: thêm %', n;
end $$;
