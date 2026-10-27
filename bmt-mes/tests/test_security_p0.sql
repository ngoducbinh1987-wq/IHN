-- Kiểm thử migration 20261026002800 (vá bảo mật P0): mã kiểm chứng từ, gửi duyệt, hàm nội bộ.
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create temp table t (k text primary key, v uuid);
grant all on r, t to authenticated;
grant usage on sequence r_n_seq to authenticated;

create function pg_temp.as_user(p_code text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', (select id::text from core.profiles where employee_code = p_code), true),
         set_config('request.jwt.claim.role', 'authenticated', true)
$$;
create function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_msg; end if;
  insert into r(msg) values (p_msg);
end $$;
-- Chạy dưới vai trò authenticated (như gọi qua API) và mong đợi bị chặn với thông báo chứa p_pattern
create function pg_temp.blocked(p_sql text, p_pattern text, p_msg text) returns void language plpgsql as $$
begin
  begin
    execute 'set local role authenticated';
    execute p_sql;
    execute 'reset role';
  exception when others then
    execute 'reset role';
    if sqlerrm ilike '%' || p_pattern || '%' then insert into r(msg) values (p_msg || ' → chặn: ' || sqlerrm); return; end if;
    raise exception 'FAIL: % — lỗi khác mong đợi: %', p_msg, sqlerrm;
  end;
  raise exception 'FAIL: % — lẽ ra phải bị chặn', p_msg;
end $$;
create function pg_temp.as_api(p_sql text) returns void language plpgsql as $$
begin
  execute 'set local role authenticated';
  execute p_sql;
  execute 'reset role';
end $$;
grant execute on function pg_temp.ok(boolean, text) to authenticated;
set client_min_messages = notice;

with u(code, role) as (values ('S_VH','VAN_HANH'),('S_MUA','MUA_NV'),('S_BGD','BGD'),('S_MUATP','MUA_TP')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('S_VH','VAN_HANH'),('S_MUA','MUA_NV'),('S_BGD','BGD'),('S_MUATP','MUA_TP')) u(code, role) on u.code = p.employee_code;

insert into purchase.purchase_requests (pr_no, source, status) values ('PR-S1', 'MANUAL', 'APPROVED'), ('PR-S2', 'MANUAL', 'DRAFT');
insert into t select 'pr1', id from purchase.purchase_requests where pr_no = 'PR-S1';
insert into t select 'pr2', id from purchase.purchase_requests where pr_no = 'PR-S2';

-- ================================================================ 1. Mã kiểm chứng từ
select pg_temp.ok(not has_function_privilege('authenticated', 'wf.doc_hash(text,uuid)', 'execute')
  and not has_function_privilege('anon', 'wf.doc_hash(text,uuid)', 'execute'), 'Người dùng không gọi trực tiếp được wf.doc_hash');
do $$ begin
  begin
    perform wf.doc_hash($q$core.profiles t where cast((select string_agg(email, ',') from auth.users) as int) = 1 --$q$, gen_random_uuid());
    raise exception 'FAIL: chuỗi chèn SQL lẽ ra phải bị chặn';
  exception when others then
    if sqlerrm not like '%không thuộc quy trình%' then raise exception 'FAIL: chèn SQL lọt qua hoặc lỗi khác: %', sqlerrm; end if;
    insert into r(msg) values ('Chuỗi chèn SQL bị từ chối, không lộ dữ liệu → ' || sqlerrm);
  end;
end $$;
select pg_temp.ok(wf.doc_hash('purchase.purchase_requests', (select v from t where k = 'pr2')) is not null,
  'Bảng thuộc quy trình vẫn tính được mã kiểm');

-- ================================================================ 2. Gửi duyệt
select pg_temp.as_user('S_VH');
select pg_temp.blocked($q$select wf.submit('PR', (select v from t where k = 'pr2'), 'PR-S2', 'x')$q$, 'không có quyền gửi duyệt',
  'Công nhân vận hành (không có quyền mua hàng) không gửi duyệt PR được');
select pg_temp.as_user('S_MUA');
select pg_temp.blocked($q$select wf.submit('PR', (select v from t where k = 'pr1'), 'PR-S1', 'gửi lại')$q$, 'trạng thái APPROVED',
  'PR đã duyệt không gửi duyệt lại được');
select pg_temp.ok((select status = 'APPROVED' from purchase.purchase_requests where pr_no = 'PR-S1'), 'PR đã duyệt giữ nguyên trạng thái');
select pg_temp.blocked($q$select wf.submit('PR', gen_random_uuid(), 'PR-GIA-MAO', 'Duyệt gấp')$q$, 'Không tìm thấy chứng từ',
  'Mã chứng từ bịa không tạo được yêu cầu duyệt "ma"');
select pg_temp.ok(not exists (select 1 from wf.approval_requests where doc_no = 'PR-GIA-MAO')
  and not exists (select 1 from wf.notifications where title like '%PR-GIA-MAO%'), 'Không có yêu cầu duyệt hay thông báo giả nào được tạo');
select pg_temp.as_api($q$insert into t select 'req', wf.submit('PR', (select v from t where k = 'pr2'), 'TEN-TU-DAT', repeat('x', 900))$q$);
select pg_temp.ok((select doc_no = 'PR-S2' and length(summary) = 500 from wf.approval_requests where id = (select v from t where k = 'req')),
  'Gửi duyệt hợp lệ: số chứng từ lấy từ bảng (PR-S2), nội dung tóm tắt cắt còn 500 ký tự');
select pg_temp.ok((select status = 'PENDING_APPROVAL' from purchase.purchase_requests where pr_no = 'PR-S2'), 'PR nháp chuyển sang Chờ duyệt');
select pg_temp.blocked($q$select wf.submit('PR', (select v from t where k = 'pr2'), 'PR-S2', 'lần 2')$q$, 'trạng thái PENDING_APPROVAL',
  'Không gửi duyệt hai lần cùng một chứng từ');
select pg_temp.as_user('S_MUATP');   -- PR: TP Mua duyệt → Giám đốc duyệt (migration 4500)
select pg_temp.as_api($q$select wf.act((select v from t where k = 'req'), 'APPROVE', 'Đồng ý')$q$);
select pg_temp.as_user('S_BGD');
select pg_temp.as_api($q$select wf.act((select v from t where k = 'req'), 'APPROVE', 'Đồng ý')$q$);
select pg_temp.ok((select status = 'APPROVED' from purchase.purchase_requests where pr_no = 'PR-S2'), 'Giám đốc duyệt bình thường sau khi vá (mã kiểm khớp)');

-- ================================================================ 3. Hàm nội bộ
select pg_temp.ok(not has_function_privilege('authenticated', 'wf.notify_role(text,text,text,text)', 'execute')
  and not has_function_privilege('authenticated', 'app.kh_log(text,text,text,text,text)', 'execute')
  and not has_function_privilege('authenticated', 'wf.doc_number(text,uuid)', 'execute'),
  'Người dùng không gọi trực tiếp được wf.notify_role, app.kh_log, wf.doc_number');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
