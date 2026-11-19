-- BMT MES · 10300 · Danh mục nhà cung cấp (anh Bình duyệt 19/11/2026)
--  1. Màn hình Mua hàng → Nhà cung cấp (/nha-cung-cap): xem, thêm, sửa, ngừng dùng, trang chi tiết.
--  2. Quyền (anh Bình chốt): thêm mới = chỉ TP Mua; sửa thông tin = NV mua, TP Mua; ngừng dùng / dùng lại = chỉ TP Mua (ghi lý do);
--     xóa = chỉ Quản trị hệ thống, và chỉ khi NCC chưa phát sinh chứng từ (đã có đơn mua, lô hàng… thì dùng Ngừng dùng).
--  3. Thêm nhanh NCC trên đơn mua (app.save_supplier): từ nay chỉ TP Mua (trước: NV mua và TP Mua).
--  4. Ghi thẳng vào core.partners qua API: chỉ Quản trị; mọi người khác ghi qua các hàm dưới đây. Bật nhật ký thay đổi cho bảng.
--  5. Bổ sung 19/11/2026 18:08: mỗi NCC khai báo các mặt hàng bán được cho BMT (master.supplier_materials, TP Mua khai báo).
--     Đơn mua: chọn NCC cho dòng nào thì chỉ được chọn NCC đã khai báo bán vật tư của dòng đó (màn hình lọc, database chặn).
--     Dữ liệu đầu: lấy từ các dòng đơn mua đã có NCC (HZK, Nhật Huy). NCC khác: TP Mua khai báo mặt hàng trước khi chọn được.

-- ===========================================================================
-- 1. Cột mới
-- ===========================================================================
alter table core.partners
  add column if not exists phone           text,
  add column if not exists email           text,
  add column if not exists payment_terms   text,
  add column if not exists note            text,
  add column if not exists inactive_reason text,
  add column if not exists inactive_at     timestamptz,
  add column if not exists inactive_by     uuid;
comment on column core.partners.contact is 'Người liên hệ';
comment on column core.partners.payment_terms is 'Điều khoản thanh toán mặc định của NCC (gợi ý khi chốt dòng đơn mua)';
comment on column core.partners.inactive_reason is 'Lý do ngừng dùng (TP Mua ghi)';

select core.enable_audit('core.partners');

-- Ghi thẳng qua API: chỉ Quản trị hệ thống. Thêm / sửa / ngừng dùng / xóa đi qua hàm app.supplier_*.
drop policy if exists p_insert on core.partners;
drop policy if exists p_update on core.partners;
drop policy if exists p_delete on core.partners;
create policy p_insert on core.partners for insert to authenticated with check ((select core.is_admin()));
create policy p_update on core.partners for update to authenticated using ((select core.is_admin())) with check ((select core.is_admin()));
create policy p_delete on core.partners for delete to authenticated using ((select core.is_admin()));

-- ===========================================================================
-- 2. Thêm mới / sửa
-- ===========================================================================
create or replace function app.supplier_save(p_id uuid, p_name text, p_tax_code text default null, p_contact text default null,
  p_phone text default null, p_email text default null, p_address text default null, p_payment_terms text default null, p_note text default null)
returns uuid language plpgsql security definer set search_path to 'pg_catalog', 'public' as $$
declare
  v_name  text := nullif(trim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g')), '');
  v_tax   text := nullif(regexp_replace(coalesce(p_tax_code, ''), '\s', '', 'g'), '');
  v_email text := nullif(trim(coalesce(p_email, '')), '');
  v_id uuid; v_code text; v_n int; d core.partners; s core.partners;
begin
  if p_id is null then
    if not core.has_role('MUA_TP') then
      raise exception 'Chỉ TP Mua được thêm nhà cung cấp mới. Cần thêm thì báo TP Mua (Mua hàng → Nhà cung cấp)';
    end if;
  elsif not (core.has_role('MUA_NV') or core.has_role('MUA_TP')) then
    raise exception 'Chỉ NV mua / TP Mua được sửa thông tin nhà cung cấp';
  end if;
  if v_name is null then raise exception 'Nhập tên nhà cung cấp'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Email "%" không đúng dạng ten@congty.vn', v_email; end if;

  -- Một lúc chỉ một người thêm / sửa: tránh trùng mã, trùng tên
  perform pg_advisory_xact_lock(hashtext('core.partners.supplier'));

  if p_id is not null then
    select * into s from core.partners where id = p_id and is_supplier for update;
    if not found then raise exception 'Không tìm thấy nhà cung cấp'; end if;
  end if;

  select * into d from core.partners x
   where x.id is distinct from p_id and (lower(x.name) = lower(v_name) or (v_tax is not null and x.tax_code = v_tax))
   order by x.is_supplier desc limit 1;
  if found then
    if d.is_supplier or p_id is not null then
      raise exception 'Đã có % – % trùng tên hoặc mã số thuế%. Mở dòng đó để sửa, không tạo trùng', d.code, d.name,
        case when d.is_supplier and not d.active then ' (đang ngừng dùng)' else '' end;
    end if;
    -- Đối tác đã có (khách hàng) nay cũng bán hàng cho BMT: dùng lại dòng cũ, đánh dấu là nhà cung cấp
    update core.partners set is_supplier = true,
           tax_code = coalesce(v_tax, tax_code),
           contact = coalesce(nullif(trim(coalesce(p_contact, '')), ''), contact),
           phone = coalesce(nullif(trim(coalesce(p_phone, '')), ''), phone),
           email = coalesce(v_email, email),
           address = coalesce(nullif(trim(coalesce(p_address, '')), ''), address),
           payment_terms = coalesce(nullif(trim(coalesce(p_payment_terms, '')), ''), payment_terms),
           note = coalesce(nullif(trim(coalesce(p_note, '')), ''), note)
     where id = d.id;
    return d.id;
  end if;

  if p_id is not null then
    update core.partners set name = v_name, tax_code = v_tax,
           contact = nullif(trim(coalesce(p_contact, '')), ''),
           phone = nullif(trim(coalesce(p_phone, '')), ''),
           email = v_email,
           address = nullif(trim(coalesce(p_address, '')), ''),
           payment_terms = nullif(trim(coalesce(p_payment_terms, '')), ''),
           note = nullif(trim(coalesce(p_note, '')), '')
     where id = p_id;
    return p_id;
  end if;

  select coalesce(max(substring(code from '^NCC-(\d+)$')::int), 0) + 1 into v_n from core.partners where code ~ '^NCC-\d+$';
  v_code := 'NCC-' || lpad(v_n::text, 3, '0');
  insert into core.partners (code, name, tax_code, is_supplier, is_customer, partner_type, contact, phone, email, address, payment_terms, note, active, created_by)
  values (v_code, v_name, v_tax, true, false, 'SUPPLIER',
          nullif(trim(coalesce(p_contact, '')), ''), nullif(trim(coalesce(p_phone, '')), ''), v_email,
          nullif(trim(coalesce(p_address, '')), ''), nullif(trim(coalesce(p_payment_terms, '')), ''), nullif(trim(coalesce(p_note, '')), ''),
          true, auth.uid())
  returning id into v_id;
  return v_id;
end $$;

-- Thêm nhanh NCC trên đơn mua (giữ tên và tham số cũ để màn hình Đơn mua không đổi). Từ nay chỉ TP Mua.
-- Trùng tên / mã số thuế với NCC đang dùng: trả về NCC đó (không sửa thông tin); NCC đã ngừng dùng: báo lỗi.
create or replace function app.save_supplier(p_name text, p_tax_code text default null, p_contact text default null, p_address text default null)
returns uuid language plpgsql security definer set search_path to 'pg_catalog', 'public' as $$
declare
  v_name text := nullif(trim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g')), '');
  v_tax  text := nullif(regexp_replace(coalesce(p_tax_code, ''), '\s', '', 'g'), '');
  d core.partners;
begin
  if not core.has_role('MUA_TP') then
    raise exception 'Chỉ TP Mua được thêm nhà cung cấp mới. Cần thêm thì báo TP Mua (Mua hàng → Nhà cung cấp)';
  end if;
  if v_name is null then raise exception 'Nhập tên nhà cung cấp'; end if;
  select * into d from core.partners x
   where x.is_supplier and (lower(x.name) = lower(v_name) or (v_tax is not null and x.tax_code = v_tax)) limit 1;
  if found then
    if not d.active then
      raise exception 'Nhà cung cấp % – % đang ngừng dùng. TP Mua bấm "Dùng lại" ở Mua hàng → Nhà cung cấp', d.code, d.name;
    end if;
    return d.id;
  end if;
  return app.supplier_save(null, v_name, v_tax, p_contact, null, null, p_address, null, null);
end $$;

-- ===========================================================================
-- 3. Ngừng dùng / dùng lại (chỉ TP Mua)
-- ===========================================================================
create or replace function app.supplier_set_active(p_id uuid, p_active boolean, p_reason text default null)
returns void language plpgsql security definer set search_path to 'pg_catalog', 'public' as $$
declare s core.partners; v_reason text := nullif(trim(coalesce(p_reason, '')), ''); v_ref text;
begin
  if not core.has_role('MUA_TP') then raise exception 'Chỉ TP Mua được ngừng dùng hoặc dùng lại nhà cung cấp'; end if;
  if p_active is null then raise exception 'Thao tác không hợp lệ'; end if;
  select * into s from core.partners where id = p_id and is_supplier for update;
  if not found then raise exception 'Không tìm thấy nhà cung cấp'; end if;
  if s.active = p_active then return; end if;

  if p_active then
    update core.partners set active = true, inactive_reason = null, inactive_at = null, inactive_by = null where id = p_id;
    return;
  end if;

  if v_reason is null then raise exception 'Nhập lý do ngừng dùng'; end if;
  if s.is_customer or s.is_brand_entity then
    raise exception '% – % cũng là khách hàng / pháp nhân thương hiệu: không ngừng dùng ở đây', s.code, s.name;
  end if;
  -- Còn đơn mua tổng đang chốt hoặc hợp đồng chưa duyệt xong của NCC này: xử lý trước
  select string_agg(po_no, ', ' order by po_no) into v_ref from (
    select po.po_no from purchase.purchase_orders po
     where po.supplier_id = p_id and po.status in ('DRAFT', 'PENDING_APPROVAL')
    union
    select po.po_no from purchase.po_lines l join purchase.purchase_orders po on po.id = l.po_id
     where l.supplier_id = p_id and po.status in ('DRAFT', 'PENDING_APPROVAL')) x;
  if v_ref is not null then
    raise exception '% – % còn trong đơn mua chưa duyệt xong (%): đổi NCC ở các dòng đó hoặc chờ duyệt xong rồi mới ngừng dùng', s.code, s.name, v_ref;
  end if;
  update core.partners set active = false, inactive_reason = v_reason, inactive_at = now(), inactive_by = auth.uid() where id = p_id;
end $$;

-- ===========================================================================
-- 4. Xóa (chỉ Quản trị hệ thống; chỉ NCC chưa phát sinh chứng từ)
-- ===========================================================================
create or replace function app.supplier_delete(p_id uuid, p_reason text)
returns text language plpgsql security definer set search_path to 'pg_catalog', 'public' as $$
declare s core.partners; v_reason text := nullif(trim(coalesce(p_reason, '')), ''); v_used text[] := '{}'; v_ref text; v_n int;
begin
  if not core.is_admin() then raise exception 'Chỉ Quản trị hệ thống được xóa nhà cung cấp'; end if;
  if v_reason is null then raise exception 'Nhập lý do xóa'; end if;
  select * into s from core.partners where id = p_id and is_supplier for update;
  if not found then raise exception 'Không tìm thấy nhà cung cấp'; end if;
  if s.is_customer or s.is_brand_entity then
    raise exception '% – % cũng là khách hàng / pháp nhân thương hiệu: không xóa ở đây', s.code, s.name;
  end if;

  select string_agg(po_no, ', ' order by po_no) into v_ref from (
    select po.po_no from purchase.purchase_orders po where po.supplier_id = p_id
    union
    select po.po_no from purchase.po_lines l join purchase.purchase_orders po on po.id = l.po_id where l.supplier_id = p_id) x;
  if v_ref is not null then v_used := v_used || ('đơn mua ' || v_ref); end if;
  select count(*) into v_n from purchase.goods_receipts where supplier_id = p_id;
  if v_n > 0 then v_used := v_used || (v_n || ' phiếu nhận hàng'); end if;
  select count(*) into v_n from inv.lots where supplier_id = p_id;
  if v_n > 0 then v_used := v_used || (v_n || ' lô hàng'); end if;
  select count(*) into v_n from plan.proposal_lines where supplier_id = p_id;
  if v_n > 0 then v_used := v_used || (v_n || ' dòng đề xuất mua'); end if;
  select count(*) into v_n from master.material_suppliers where supplier_id = p_id;
  if v_n > 0 then v_used := v_used || (v_n || ' điều kiện mua vật tư'); end if;
  select count(*) into v_n from master.price_history where supplier_id = p_id;
  if v_n > 0 then v_used := v_used || (v_n || ' dòng lịch sử giá'); end if;
  if cardinality(v_used) > 0 then
    raise exception '% – % đã phát sinh chứng từ (%): không xóa được để giữ lịch sử. Dùng "Ngừng dùng" thay cho xóa',
      s.code, s.name, array_to_string(v_used, '; ');
  end if;

  insert into core.audit_log (user_id, table_name, row_id, action, old_data, new_data)
  values (auth.uid(), 'core.partners', p_id::text, 'ADMIN_DELETE', to_jsonb(s), jsonb_build_object('reason', v_reason));
  begin
    delete from core.partners where id = p_id;
  exception when foreign_key_violation then
    raise exception '% – % đang được dữ liệu khác dùng: không xóa được. Dùng "Ngừng dùng" thay cho xóa', s.code, s.name;
  end;
  return s.code || ' – ' || s.name;
end $$;

-- ===========================================================================
-- 5. Mặt hàng NCC bán được cho BMT
-- ===========================================================================
create table if not exists master.supplier_materials (
  id          uuid primary key default gen_random_uuid(),
  supplier_id uuid not null references core.partners(id) on delete cascade,
  material_id uuid not null references master.materials(id) on delete cascade,
  unique (supplier_id, material_id)
);
select core.add_audit_cols('master.supplier_materials');
create index if not exists supplier_materials_material_idx on master.supplier_materials (material_id);
comment on table master.supplier_materials is 'Mặt hàng NCC bán được cho BMT (TP Mua khai báo). Đơn mua chỉ cho chọn NCC có khai báo vật tư của dòng';
insert into core.table_modules (table_name, module) values ('master.supplier_materials', 'master') on conflict (table_name) do nothing;
alter table master.supplier_materials enable row level security;
drop policy if exists p_select on master.supplier_materials;
create policy p_select on master.supplier_materials for select to authenticated using ((select core.has_perm('master', 'view')));
-- Không có policy ghi: chỉ ghi qua app.supplier_set_materials
revoke all on master.supplier_materials from anon, authenticated;
grant select on master.supplier_materials to authenticated;

-- Dữ liệu đầu: NCC đã được chọn trên dòng đơn mua (chưa hủy) coi như bán được vật tư đó
insert into master.supplier_materials (supplier_id, material_id)
select distinct coalesce(l.supplier_id, po.supplier_id), l.material_id
  from purchase.po_lines l join purchase.purchase_orders po on po.id = l.po_id
 where po.status <> 'CANCELLED' and coalesce(l.supplier_id, po.supplier_id) is not null
on conflict do nothing;

-- TP Mua khai báo lại toàn bộ danh sách mặt hàng của một NCC (gửi cả danh sách đang tick)
create or replace function app.supplier_set_materials(p_id uuid, p_materials uuid[])
returns jsonb language plpgsql security definer set search_path to 'pg_catalog', 'public' as $$
declare
  s core.partners; v_new uuid[]; v_add uuid[]; v_del uuid[]; v_ref text; v_bad int;
begin
  if not core.has_role('MUA_TP') then raise exception 'Chỉ TP Mua được khai báo mặt hàng của nhà cung cấp'; end if;
  select * into s from core.partners where id = p_id and is_supplier for update;
  if not found then raise exception 'Không tìm thấy nhà cung cấp'; end if;
  select coalesce(array_agg(distinct x), '{}') into v_new from unnest(coalesce(p_materials, '{}')) x where x is not null;
  select count(*) into v_bad from unnest(v_new) x where not exists (select 1 from master.materials m where m.id = x and not m.is_scrap);
  if v_bad > 0 then raise exception 'Có % vật tư không hợp lệ (không có trong danh mục hoặc là phế liệu)', v_bad; end if;

  select coalesce(array_agg(sm.material_id), '{}') into v_del from master.supplier_materials sm
   where sm.supplier_id = p_id and sm.material_id <> all (v_new);
  select coalesce(array_agg(x), '{}') into v_add from unnest(v_new) x
   where not exists (select 1 from master.supplier_materials sm where sm.supplier_id = p_id and sm.material_id = x);

  -- Bỏ mặt hàng đang nằm trên đơn mua chưa duyệt xong của NCC này: xử lý đơn trước
  select string_agg(distinct m.code || ' (' || po.po_no || ')', ', ') into v_ref
    from purchase.po_lines l join purchase.purchase_orders po on po.id = l.po_id join master.materials m on m.id = l.material_id
   where coalesce(l.supplier_id, po.supplier_id) = p_id and l.material_id = any (v_del) and po.status in ('DRAFT', 'PENDING_APPROVAL');
  if v_ref is not null then
    raise exception 'Chưa bỏ được vì % đang mua vật tư này trên đơn chưa duyệt xong: %. Đổi NCC ở dòng đó trước', s.name, v_ref;
  end if;

  delete from master.supplier_materials where supplier_id = p_id and material_id = any (v_del);
  insert into master.supplier_materials (supplier_id, material_id, created_by) select p_id, x, auth.uid() from unnest(v_add) x;

  if cardinality(v_add) + cardinality(v_del) > 0 then
    insert into core.audit_log (user_id, table_name, row_id, action, old_data, new_data)
    values (auth.uid(), 'core.partners', p_id::text, 'MATERIALS',
      jsonb_build_object('removed', (select coalesce(jsonb_agg(m.code order by m.code), '[]') from master.materials m where m.id = any (v_del))),
      jsonb_build_object('added',   (select coalesce(jsonb_agg(m.code order by m.code), '[]') from master.materials m where m.id = any (v_add))));
  end if;
  return jsonb_build_object('added', cardinality(v_add), 'removed', cardinality(v_del), 'total', cardinality(v_new));
end $$;

-- Dòng đơn mua: NCC phải đang dùng và đã khai báo bán vật tư của dòng.
--  - Người dùng đổi NCC (UPDATE): sai thì báo lỗi.
--  - Đơn mua tổng MES lập tự động (INSERT, NCC gợi ý theo lần mua trước): NCC không hợp lệ thì để trống cho NV mua chọn.
--  - Dòng có NCC mà chưa có điều khoản thanh toán: tự điền điều khoản mặc định của NCC.
create or replace function purchase.line_check_supplier()
returns trigger language plpgsql security definer set search_path to 'pg_catalog', 'public' as $$
declare v_ok boolean; v_sup text; v_mat text;
begin
  if new.supplier_id is null then return new; end if;
  -- Dòng chưa có điều khoản thanh toán: lấy điều khoản mặc định của NCC (NV mua sửa lại được)
  if coalesce(trim(new.payment_terms), '') = '' then
    select nullif(trim(p.payment_terms), '') into new.payment_terms from core.partners p where p.id = new.supplier_id;
  end if;
  if tg_op = 'UPDATE' and new.supplier_id is not distinct from old.supplier_id and new.material_id = old.material_id then return new; end if;
  v_ok := exists (select 1 from core.partners p where p.id = new.supplier_id and p.is_supplier and p.active)
      and exists (select 1 from master.supplier_materials sm where sm.supplier_id = new.supplier_id and sm.material_id = new.material_id);
  if v_ok then return new; end if;
  if tg_op = 'INSERT' then
    if exists (select 1 from purchase.purchase_orders po where po.id = new.po_id and po.kind = 'TONG') then new.supplier_id := null; end if;
    return new;
  end if;
  select code || ' – ' || name into v_sup from core.partners where id = new.supplier_id;
  select code || ' – ' || name into v_mat from master.materials where id = new.material_id;
  if exists (select 1 from core.partners p where p.id = new.supplier_id and not p.active) then
    raise exception 'Nhà cung cấp % đã ngừng dùng: chọn NCC khác', coalesce(v_sup, '?');
  end if;
  raise exception 'Nhà cung cấp % chưa khai báo bán vật tư %. TP Mua bổ sung mặt hàng ở Mua hàng → Nhà cung cấp, hoặc chọn NCC khác',
    coalesce(v_sup, '?'), coalesce(v_mat, '?');
end $$;
drop trigger if exists trg_line_check_supplier on purchase.po_lines;
create trigger trg_line_check_supplier before insert or update of supplier_id, material_id on purchase.po_lines
  for each row execute function purchase.line_check_supplier();

-- ===========================================================================
-- 6. View cho giao diện
-- ===========================================================================
create or replace view app.v_suppliers with (security_invoker = true) as
select p.id, p.code, p.name, p.tax_code, p.contact, p.phone, p.email, p.address, p.payment_terms, p.note, p.active,
       p.inactive_reason, p.inactive_at, app.user_name(p.inactive_by) as inactive_by_name,
       p.created_at, app.user_name(p.created_by) as created_by_name, p.updated_at,
       (p.is_customer or p.is_brand_entity) as shared,
       (select count(*) from master.supplier_materials sm where sm.supplier_id = p.id)::int as material_count,
       (select count(*) from purchase.purchase_orders po
         where po.supplier_id = p.id and po.kind = 'HD' and po.status <> 'CANCELLED')::int as po_count,
       (select count(*) from purchase.purchase_orders po where po.status in ('DRAFT', 'PENDING_APPROVAL')
           and (po.supplier_id = p.id or exists (select 1 from purchase.po_lines l where l.po_id = po.id and l.supplier_id = p.id)))::int as open_count,
       (select max(po.order_date) from purchase.purchase_orders po
         where po.supplier_id = p.id and po.kind = 'HD' and po.status <> 'CANCELLED') as last_order_date
from core.partners p
where p.is_supplier;

-- Mặt hàng NCC bán được cho BMT, kèm số liệu đã mua (hợp đồng đã duyệt). Giá ẩn với người không được xem giá.
create or replace view app.v_supplier_materials with (security_invoker = true) as
select sm.supplier_id, sm.material_id, m.code as material_code, m.name as material_name, m.uom, m.group_code, g.name as group_name,
       coalesce(b.po_count, 0) as po_count, b.qty, b.received_qty, b.last_order_date, b.last_po_no, b.last_po_id, b.supplier_item_code,
       case when core.can_see_price() then b.last_price end as last_price
from master.supplier_materials sm
join master.materials m on m.id = sm.material_id
left join master.material_groups g on g.code = m.group_code
left join lateral (
  select count(distinct po.id)::int as po_count, sum(l.qty) as qty, sum(l.received_qty) as received_qty, max(po.order_date) as last_order_date,
         (array_agg(po.po_no order by po.order_date desc nulls last, po.created_at desc))[1] as last_po_no,
         (array_agg(po.id order by po.order_date desc nulls last, po.created_at desc))[1] as last_po_id,
         (array_agg(l.supplier_item_code order by po.order_date desc nulls last, po.created_at desc))[1] as supplier_item_code,
         (array_agg(l.unit_price order by po.order_date desc nulls last, po.created_at desc))[1] as last_price
    from purchase.purchase_orders po join purchase.po_lines l on l.po_id = po.id
   where po.supplier_id = sm.supplier_id and l.material_id = sm.material_id and po.kind = 'HD'
     and po.status in ('APPROVED', 'SENT', 'PARTIAL_RECEIVED', 'RECEIVED', 'CLOSED')
) b on true;

-- Lịch sử thay đổi của một NCC (nhật ký chỉ Quản trị đọc thẳng được; hàm này cho người xem được danh mục)
create or replace function app.supplier_history(p_id uuid)
returns table (at timestamptz, user_name text, action text, changes jsonb)
language sql stable security definer set search_path to 'pg_catalog', 'public' as $$
  select a.at, app.user_name(a.user_id), a.action,
         case when a.action = 'UPDATE' then
           (select coalesce(jsonb_object_agg(n.key, jsonb_build_array(o.value, n.value)), '{}'::jsonb)
              from jsonb_each(a.new_data) n join jsonb_each(a.old_data) o on o.key = n.key
             where n.value is distinct from o.value and n.key not in ('updated_at', 'updated_by'))
              when a.action = 'MATERIALS' then coalesce(a.old_data, '{}'::jsonb) || coalesce(a.new_data, '{}'::jsonb)
              when a.action = 'ADMIN_DELETE' then a.new_data
         end
    from core.audit_log a
   where a.table_name = 'core.partners' and a.row_id = p_id::text
     and core.has_perm('master', 'view')
   order by a.at desc, a.id desc
   limit 100
$$;

-- ===========================================================================
-- 7. Mục menu: Mua hàng → Nhà cung cấp (ai vào được Đơn mua hàng thì vào được)
-- ===========================================================================
insert into core.pages (key, path, label, grp, sort) values ('nha-cung-cap', '/nha-cung-cap', 'Nhà cung cấp', 'Mua hàng', 13)
on conflict (key) do update set path = excluded.path, label = excluded.label, grp = excluded.grp, sort = excluded.sort;
insert into core.role_pages (role_code, page_key)
select role_code, 'nha-cung-cap' from core.role_pages where page_key = 'don-mua'
on conflict do nothing;

-- ===========================================================================
-- 8. Quyền
-- ===========================================================================
grant select on app.v_suppliers, app.v_supplier_materials to authenticated;
revoke execute on function purchase.line_check_supplier() from public, anon, authenticated;
revoke execute on function app.supplier_save(uuid, text, text, text, text, text, text, text, text), app.save_supplier(text, text, text, text),
  app.supplier_set_active(uuid, boolean, text), app.supplier_delete(uuid, text), app.supplier_history(uuid),
  app.supplier_set_materials(uuid, uuid[]) from public, anon;
grant execute on function app.supplier_save(uuid, text, text, text, text, text, text, text, text), app.save_supplier(text, text, text, text),
  app.supplier_set_active(uuid, boolean, text), app.supplier_delete(uuid, text), app.supplier_history(uuid),
  app.supplier_set_materials(uuid, uuid[]) to authenticated;
