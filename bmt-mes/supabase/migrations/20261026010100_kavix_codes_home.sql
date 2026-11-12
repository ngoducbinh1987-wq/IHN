-- Anh Bình 12/11/2026: bộ quy tắc mã KAVIX chỉ dùng 3 tiền tố F120, HOME, CTRL; khác nhau ở hậu tố (vật liệu ngoài cùng).
--   Cấu trúc: [DÒNG]-KV[TIẾT DIỆN][LOẠI][SỐ LÕI][HẬU TỐ]
--   Hậu tố: LZ = vỏ LSZH; PC = vỏ PVC hoặc cách điện PVC (dây đơn không vỏ); FP = vỏ FR-PVC; SI = cách điện silicone, dây đơn không vỏ.
--   Màu vỏ theo tiền tố: F120 cam RAL 2004, HOME xanh RAL 6037, CTRL xám. Dây đơn không vỏ: màu cách điện theo màu lõi.
--   Dây đơn giữ 1 mã cho mỗi tiết diện.
-- Đổi mã (47): PFR-nC-x → HOME-KVxXnFP (18), SIF-1C-x → HOME-KVxX1SI (6), PVC-1C-x → HOME-KVxX1PC (6),
--              CTRL-KVAWGyS(2n)PVC → CTRL-KVAWGyS(2n)PC (17).
-- Mô tả sản phẩm (sales_name) cho 30 mã mới đổi; tên nhóm PFR/SIF/PVC theo dòng HOMESAFE (group_code giữ).
-- Màu vỏ theo tiền tố đưa vào đối chiếu BOM (master.brand_sheath_colors): KAVIX FR-PVC HOME- RAL 6037, KAVIX PVC CTRL- Xám.

update master.product_groups set name = 'Dây dân dụng HOMESAFE vỏ FR-PVC' where code = 'PFR';
update master.product_groups set name = 'Dây đơn HOMESAFE silicone' where code = 'SIF';
update master.product_groups set name = 'Dây đơn HOMESAFE PVC' where code = 'PVC';

insert into master.brand_sheath_colors (brand, family, shield, code_prefix, color, note) values
  ('KAVIX', 'FR-PVC', null, 'HOME-', 'RAL 6037', 'Dây dân dụng HOMESAFE vỏ FR-PVC: xanh (anh Bình 12/11/2026, màu theo tiền tố)'),
  ('KAVIX', 'PVC', null, 'CTRL-', 'Xám (Gray)', 'Cáp điều khiển CTRL: vỏ PVC xám (anh Bình 12/11/2026, màu theo tiền tố)')
on conflict do nothing;

create or replace function pg_temp.sz(p text) returns text language sql immutable as $$
  select case p when '0P75' then '075' when '1' then '10' when '1P5' then '15' when '2P5' then '25' when '4' then '40' when '6' then '60' end
$$;
create or replace function pg_temp.szt(p text) returns text language sql immutable as $$
  select case p when '0P75' then '0.75' when '1' then '1' when '1P5' then '1.5' when '2P5' then '2.5' when '4' then '4' when '6' then '6' end
$$;

do $$
declare v_admin uuid; r record; t record; m text[]; v_new text; v_sales text; v_n int; v_cnt int := 0;
begin
  select ur.user_id into v_admin from core.user_roles ur join core.profiles p on p.id = ur.user_id
   where ur.role_code = 'ADMIN' and p.status = 'ACTIVE' order by p.created_at limit 1;
  if v_admin is not null then perform set_config('request.jwt.claim.sub', v_admin::text, true); end if;

  for r in select p.id, p.code from master.products p
            where p.code ~ '^(PFR-[0-9]C-|SIF-1C-|PVC-1C-)' or p.code ~ '^CTRL-KVAWG[0-9]+S[0-9]+PVC$' order by p.code loop
    v_sales := null;
    if r.code ~ '^PFR-' then
      m := regexp_match(r.code, '^PFR-([0-9])C-([0-9P]+)$');
      v_new := 'HOME-KV' || pg_temp.sz(m[2]) || 'X' || m[1] || 'FP';
      v_sales := 'Dây điện dân dụng KAVIX HOMESAFE ' || m[1] || ' lõi x ' || pg_temp.szt(m[2]) || 'mm, FR-PVC';
    elsif r.code ~ '^SIF-' then
      m := regexp_match(r.code, '^SIF-1C-([0-9P]+)$');
      v_new := 'HOME-KV' || pg_temp.sz(m[1]) || 'X1SI';
      v_sales := 'Dây điện dân dụng KAVIX HOMESAFE 1 lõi x ' || pg_temp.szt(m[1]) || 'mm, Silicone';
    elsif r.code ~ '^PVC-' then
      m := regexp_match(r.code, '^PVC-1C-([0-9P]+)$');
      v_new := 'HOME-KV' || pg_temp.sz(m[1]) || 'X1PC';
      v_sales := 'Dây điện dân dụng KAVIX HOMESAFE 1 lõi x ' || pg_temp.szt(m[1]) || 'mm, PVC';
    else
      m := regexp_match(r.code, '^(CTRL-KVAWG[0-9]+S[0-9]+)PVC$');
      v_new := m[1] || 'PC';
    end if;
    if m is null or v_new is null or v_new !~ '^[A-Z0-9][A-Z0-9.-]*$' then raise exception 'Không đặt được mã mới cho %', r.code; end if;
    if exists (select 1 from master.products where code = v_new) then raise exception 'Mã % đã có', v_new; end if;

    update master.products set code = v_new, sales_name = coalesce(v_sales, sales_name) where id = r.id;
    for t in select c.table_schema, c.table_name from information_schema.columns c
               join information_schema.tables x on x.table_schema = c.table_schema and x.table_name = c.table_name and x.table_type = 'BASE TABLE'
              where c.column_name = 'product_code' and c.table_schema in ('plan', 'mfg', 'inv', 'sales', 'qa', 'master', 'purchase', 'cost') loop
      execute format('update %I.%I set product_code = $1 where product_code = $2', t.table_schema, t.table_name) using v_new, r.code;
      get diagnostics v_n = row_count;
    end loop;
    update wf.approval_requests
       set doc_no = regexp_replace(doc_no, '(^|[^A-Z0-9.-])' || r.code || '($|[^A-Z0-9.-])', '\1' || v_new || '\2', 'g'),
           summary = regexp_replace(coalesce(summary, ''), '(^|[^A-Z0-9.-])' || r.code || '($|[^A-Z0-9.-])', '\1' || v_new || '\2', 'g')
     where doc_id in (select id from master.product_specs where product_id = r.id);
    if v_admin is not null then
      perform app.admin_log('master.products', r.id::text, 'ADMIN_RENAME', jsonb_build_object('code', r.code),
              jsonb_build_object('code', v_new, 'doc_no', r.code || ' → ' || v_new, 'doc_type', 'Đổi mã sản phẩm',
                                 'reason', 'Quy tắc mã KAVIX: chỉ tiền tố F120/HOME/CTRL, hậu tố LZ/PC/FP/SI (anh Bình 12/11/2026)'));
    end if;
    v_cnt := v_cnt + 1;
  end loop;

  if v_cnt > 0 then
    perform wf.notify_role(x, 'Mã sản phẩm KAVIX: đổi thêm ' || v_cnt || ' mã theo quy tắc F120/HOME/CTRL',
      'PFR → HOME-KV…X…FP (vỏ FR-PVC), SIF-1C → HOME-KV…X1SI, PVC-1C → HOME-KV…X1PC, CTRL-…PVC → CTRL-…PC. '
      || 'Màu vỏ theo tiền tố: F120 cam RAL 2004, HOME xanh RAL 6037, CTRL xám.', '/san-pham?th=KAVIX')
      from unnest(array['SX_TP', 'SX_KH', 'MUA_TP', 'KT_TP']) x;
  end if;
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
