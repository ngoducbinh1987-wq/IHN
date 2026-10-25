-- BMT MES · 2400 · Module Kho (phần 1): danh mục, tồn theo đơn vị chứa (ống/bao/bobin), ghi sổ
-- Theo tài liệu "BMT MES – Phân tích nghiệp vụ Quản lý kho" và "Quy chuẩn vai trò & nhiệm vụ nhân sự nhà máy BMT" (25/10/2026):
--   · Kho NVL, BTP, phế do Quản lý SX giữ (vai trò Thủ kho); kho thành phẩm do NV5 giữ (vai trò NV kho)
--   · Kế toán SX duyệt (hậu kiểm) phiếu nhập/xuất trong ngày; Kế toán trưởng duyệt kiểm kê
--   · Tồn theo từng đơn vị chứa có QR; không xuất phần đã giữ; khóa kỳ giá thành đã chốt; khóa vị trí đang kiểm kê
-- Mọi hàm đặt search_path = pg_catalog, public và ghi rõ schema của bảng.

-- ===========================================================================
-- 1. Cài đặt kho (số cấu hình được, có người phụ trách)
-- ===========================================================================
create table if not exists inv.settings (
  key        text primary key,
  label      text not null,
  num_value  numeric,
  text_value text,
  unit       text,
  owner_role text references core.roles(code),           -- vai trò được sửa (ngoài Quản trị)
  sort       smallint not null default 0,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
insert into inv.settings (key, label, num_value, text_value, unit, owner_role, sort) values
  ('copper_tol_pct',   'Lệch cân bằng đồng cho phép theo lệnh SX', 2, null, '%', 'KT_TP', 1),
  ('material_tol_pct', 'Tiêu hao vượt định mức cho phép trước khi cảnh báo', 3, null, '%', 'KT_TP', 2),
  ('giveaway_tol_pct', 'Vượt dày cho phép (kg/km thực so với lý thuyết)', 2, null, '%', 'KT_TP', 3),
  ('remnant_min_m',    'Chiều dài tối thiểu cuộn thành phẩm (ngắn hơn là đoạn lẻ)', 100, null, 'm', 'KT_TP', 4),
  ('expiry_warn_days', 'Cảnh báo hàng sắp hết hạn trước', 30, null, 'ngày', 'KT_TP', 5),
  ('qc_wait_days',     'Cảnh báo lô chờ kiểm tra chất lượng quá', 2, null, 'ngày', 'KT_TP', 6),
  ('review_hours',     'Hạn Kế toán SX xác nhận phiếu nhập, xuất', 24, null, 'giờ', 'KTT', 7),
  ('draft_hours',      'Cảnh báo phiếu nháp chưa xử lý quá', 24, null, 'giờ', 'KTT', 8),
  ('count_sample_size','Số đơn vị chứa mỗi lần kiểm kê chọn mẫu', 10, null, 'đơn vị', 'KTT', 9),
  ('issue_hours',      'Khung giờ mở kho NVL, ví dụ 06:30-08:00,16:30-17:30 (để trống = không kiểm tra)', null, null, null, 'SX_TP', 10)
on conflict (key) do nothing;

create or replace function inv.setting(p_key text) returns numeric
language sql stable security definer set search_path = pg_catalog, public as $$
  select s.num_value from inv.settings s where s.key = p_key
$$;

-- Người dùng đang hoạt động giữ một trong các vai trò (để gửi thông báo)
create or replace function inv.role_users(p_roles text[]) returns uuid[]
language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce(array_agg(distinct ur.user_id), '{}')
  from core.user_roles ur join core.profiles p on p.id = ur.user_id and p.status = 'ACTIVE'
  where ur.role_code = any(p_roles)
$$;

-- ===========================================================================
-- 2. Danh mục bổ sung
-- ===========================================================================
alter table master.materials
  add column if not exists shelf_life_days integer check (shelf_life_days > 0),
  add column if not exists storage_zone text check (storage_zone in ('THUONG','MAT','HOA_CHAT')),
  add column if not exists abc_class text check (abc_class in ('A','B','C')),
  add column if not exists reorder_point numeric(18,4) check (reorder_point >= 0);

-- Nhóm A (kiểm kê dày nhất): đồng và silicone; hóa chất cất khu riêng
update master.materials set abc_class = case when group_code = 'CONDUCTOR' or code like 'SIL-%' then 'A'
                                              when group_code in ('COMPOUND','ADDITIVE') then 'B' else 'C' end
 where abc_class is null and not is_scrap;
update master.materials set storage_zone = case when code in ('DCBP-50','INK','SOLVENT') then 'HOA_CHAT'
                                                 when code like 'SIL-%' then 'MAT' else 'THUONG' end
 where storage_zone is null and not is_scrap;

alter table master.products add column if not exists min_remnant_m numeric check (min_remnant_m > 0);

-- Bảng bì: ống đồng, thùng, bao của NCC → kg tịnh = cân tổng − bì
create table if not exists master.package_types (
  id         uuid primary key default gen_random_uuid(),
  code       text unique not null,
  name       text not null,
  tare_kg    numeric(10,3) not null check (tare_kg >= 0),
  material_group text references master.material_groups(code),
  note       text,
  active     boolean not null default true
);
select core.add_audit_cols('master.package_types');

-- ===========================================================================
-- 3. Kho: người giữ kho, vị trí
-- ===========================================================================
create table if not exists inv.warehouse_keepers (
  warehouse_id uuid not null references inv.warehouses(id),
  role_code    text not null references core.roles(code),
  primary key (warehouse_id, role_code)
);
insert into inv.warehouse_keepers (warehouse_id, role_code)
select w.id, k.role from inv.warehouses w
join (values ('KNL','THU_KHO'), ('KBTP','THU_KHO'), ('KPL','THU_KHO'), ('KTP','KHO_NV')) k(code, role) on k.code = w.code
on conflict do nothing;

alter table inv.locations
  add column if not exists kind text not null default 'STORE'
    check (kind in ('STORE','QC','HOLD','LINE','SHIP','RETURN','EMPTY')),
  add column if not exists sort smallint not null default 0,
  add column if not exists active boolean not null default true;

-- Vị trí đề xuất theo mặt bằng xưởng (thủ kho đo thực tế rồi sửa/ thêm ở Cài đặt kho)
insert into inv.locations (warehouse_id, code, name, kind, sort)
select w.id, v.code, v.name, v.kind, v.sort from inv.warehouses w
join (values
  ('KNL','KNL-QC','Chờ kiểm (vạch vàng)','QC',1),
  ('KNL','KNL-HOLD','Cách ly (vạch đỏ)','HOLD',2),
  ('KNL','KNL-CU','Đồng sợi, drain','STORE',3),
  ('KNL','KNL-SI','Silicone (khu mát)','STORE',4),
  ('KNL','KNL-HC','Hóa chất: DCBP, mực, dung môi','STORE',5),
  ('KNL','KNL-NH','Compound PVC, LSZH, HDPE','STORE',6),
  ('KNL','KNL-MB','Màu, masterbatch','STORE',7),
  ('KNL','KNL-BG','Băng, sợi độn','STORE',8),
  ('KNL','KNL-BB','Bao bì: bobin gỗ, PE, đai, nhãn, pallet','STORE',9),
  ('KBTP','KBTP-W','Bobin chờ công đoạn sau (cạnh Tây)','STORE',1),
  ('KBTP','KBTP-L','Cạnh máy','LINE',2),
  ('KBTP','KBTP-EMPTY','Bobin trống','EMPTY',3),
  ('KTP','KTP-QC','Chờ FQC','QC',1),
  ('KTP','KTP-A','Thành phẩm KAVIX','STORE',2),
  ('KTP','KTP-B','Thành phẩm HEIZKA','STORE',3),
  ('KTP','KTP-SHIP','Chờ giao','SHIP',4),
  ('KTP','KTP-RET','Hàng khách trả','RETURN',5),
  ('KPL','KPL-CU','Phế đồng','STORE',1),
  ('KPL','KPL-NH','Phế nhựa, silicone, purge','STORE',2),
  ('KPL','KPL-CAP','Cáp lỗi','STORE',3)
) v(wh, code, name, kind, sort) on v.wh = w.code
on conflict (warehouse_id, code) do nothing;

create or replace function inv.loc(p_code text) returns uuid
language sql stable security definer set search_path = pg_catalog, public as $$
  select l.id from inv.locations l where l.code = p_code
$$;
create or replace function inv.wh(p_code text) returns uuid
language sql stable security definer set search_path = pg_catalog, public as $$
  select w.id from inv.warehouses w where w.code = p_code
$$;

-- Cách người hiện tại giữ kho: DIRECT (giữ vai trò), DELEGATED (theo ủy quyền có thời hạn) hoặc null
create or replace function inv.keeper_mode(p_wh uuid) returns text
language sql stable security definer set search_path = pg_catalog, public as $$
  select case
    when exists (select 1 from core.user_scopes s where s.user_id = auth.uid() and s.scope_type = 'WAREHOUSE')
         and not exists (select 1 from core.user_scopes s where s.user_id = auth.uid() and s.scope_type = 'WAREHOUSE' and s.scope_id = p_wh)
      then null
    when exists (select 1 from inv.warehouse_keepers k
                 join core.user_roles ur on ur.role_code = k.role_code
                 join core.profiles p on p.id = ur.user_id and p.status = 'ACTIVE'
                 where k.warehouse_id = p_wh and ur.user_id = auth.uid()) then 'DIRECT'
    when exists (select 1 from inv.warehouse_keepers k
                 join core.delegations d on d.role_code = k.role_code
                 where k.warehouse_id = p_wh and d.to_user = auth.uid() and now() between d.valid_from and d.valid_to) then 'DELEGATED'
  end
$$;

-- Bắt buộc là người giữ kho; giữ theo ủy quyền thì phải có Kế toán SX chứng kiến (Quy chuẩn mục 11)
create or replace function inv.require_keeper(p_wh uuid, p_witness uuid default null) returns boolean
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_mode text := inv.keeper_mode(p_wh); v_code text;
begin
  select w.code into v_code from inv.warehouses w where w.id = p_wh;
  -- Phạm vi kho được giao (Quản trị → Người dùng, migration 2200); không giao kho nào = mọi kho
  if not core.can_use_warehouse(p_wh) then
    raise exception 'Bạn không được giao kho %', v_code;
  end if;
  if v_mode is null then
    raise exception 'Bạn không phải người giữ kho % (Quy chuẩn: kho NVL, BTP, phế – Quản lý SX; kho thành phẩm – NV5)', v_code;
  end if;
  if v_mode = 'DELEGATED' then
    if p_witness is null then
      raise exception 'Đang giữ kho % theo ủy quyền: chọn Kế toán SX chứng kiến', v_code;
    end if;
    if p_witness = auth.uid() or not exists (select 1 from core.user_roles ur where ur.user_id = p_witness and ur.role_code = 'KT_KHO') then
      raise exception 'Người chứng kiến phải là Kế toán SX (vai trò Kế toán kho), không phải người xuất';
    end if;
    return true;
  end if;
  return false;
end $$;

-- ===========================================================================
-- 4. Bobin trung gian (tài sản quay vòng, BR-KHO-15)
-- ===========================================================================
create table if not exists inv.carriers (
  id           uuid primary key default gen_random_uuid(),
  code         text unique not null,
  carrier_type text not null,                        -- B500, B630, ống NCC…
  tare_kg      numeric(10,3) not null default 0 check (tare_kg >= 0),
  owner        text not null default 'BMT' check (owner in ('BMT','NCC','KHACH')),
  status       text not null default 'EMPTY' check (status in ('EMPTY','IN_USE','DAMAGED','RETIRED')),
  location_id  uuid references inv.locations(id),
  current_hu_id uuid,
  note         text
);
select core.add_audit_cols('inv.carriers');

-- ===========================================================================
-- 5. Đơn vị chứa có QR: vị trí, trạng thái, cân, đoạn lẻ, in tem
-- ===========================================================================
alter table inv.handling_units
  add column if not exists status text not null default 'ACTIVE' check (status in ('ACTIVE','EMPTY','VOID')),
  add column if not exists warehouse_id uuid references inv.warehouses(id),
  add column if not exists location_id uuid references inv.locations(id),
  add column if not exists init_qty numeric(18,4),
  add column if not exists gross_kg numeric(18,4),
  add column if not exists tare_kg numeric(18,4),
  add column if not exists package_type_id uuid references master.package_types(id),
  add column if not exists carrier_id uuid references inv.carriers(id),
  add column if not exists parent_hu_id uuid references inv.handling_units(id),
  add column if not exists is_remnant boolean not null default false,
  add column if not exists print_count integer not null default 0,
  add column if not exists last_printed_at timestamptz,
  add column if not exists void_reason text;
create index if not exists handling_units_wh_loc on inv.handling_units (warehouse_id, location_id) where status = 'ACTIVE';
alter table inv.carriers drop constraint if exists carriers_current_hu_fk;
alter table inv.carriers add constraint carriers_current_hu_fk foreign key (current_hu_id) references inv.handling_units(id);

-- Tạo đơn vị chứa mới cho một lô: số = <số lô>-<nn>
create or replace function inv.new_hu(p_lot uuid, p_type text, p_qty numeric, p_wh uuid, p_loc uuid,
                                      p_gross numeric default null, p_tare numeric default null, p_pkg uuid default null,
                                      p_parent uuid default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_lot text; v_n int; v_id uuid;
begin
  select lot_no into v_lot from inv.lots where id = p_lot for update;
  select count(*) + 1 into v_n from inv.handling_units where lot_id = p_lot;
  insert into inv.handling_units (hu_no, lot_id, hu_type, qty, init_qty, warehouse_id, location_id, gross_kg, tare_kg,
                                  package_type_id, parent_hu_id)
  values (v_lot || '-' || lpad(v_n::text, 2, '0'), p_lot, p_type, p_qty, p_qty, p_wh, p_loc, p_gross, p_tare, p_pkg, p_parent)
  returning id into v_id;
  return v_id;
end $$;

-- ===========================================================================
-- 6. Tồn theo đơn vị chứa; không xuất phần đã giữ (BR-KHO-08)
-- ===========================================================================
alter table inv.stock_balances add column if not exists hu_key uuid not null default '00000000-0000-0000-0000-000000000000';
alter table inv.stock_balances drop constraint if exists stock_balances_pkey;
alter table inv.stock_balances add primary key (warehouse_id, location_key, lot_id, hu_key);
alter table inv.stock_balances drop constraint if exists stock_balances_reserved_chk;
alter table inv.stock_balances add constraint stock_balances_reserved_chk check (reserved_qty >= 0 and reserved_qty <= qty);
create index if not exists stock_balances_hu on inv.stock_balances (hu_key);
create index if not exists stock_balances_lot on inv.stock_balances (lot_id);

alter table inv.stock_moves add column if not exists hu_id uuid references inv.handling_units(id);
create index if not exists stock_moves_hu on inv.stock_moves (hu_id);
grant select (hu_id) on inv.stock_moves to authenticated;

drop function if exists inv.bal_add(uuid, uuid, uuid, numeric);
create or replace function inv.bal_add(p_wh uuid, p_loc uuid, p_lot uuid, p_hu uuid, p_delta numeric) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  update inv.stock_balances set qty = qty + p_delta, updated_at = now()
   where warehouse_id = p_wh and location_key = p_loc and lot_id = p_lot and hu_key = p_hu;
  if not found then
    if p_delta < 0 then raise exception using errcode = 'check_violation', message = 'lô/đơn vị chứa chưa có tồn tại kho, vị trí này'; end if;
    insert into inv.stock_balances (warehouse_id, location_key, lot_id, hu_key, qty) values (p_wh, p_loc, p_lot, p_hu, p_delta);
  end if;
  -- Dòng tồn về 0 thì xóa (sổ cái vẫn giữ đủ lịch sử)
  delete from inv.stock_balances
   where warehouse_id = p_wh and location_key = p_loc and lot_id = p_lot and hu_key = p_hu and qty = 0 and reserved_qty = 0;
end $$;

-- Giá bình quân gia quyền di động theo vật tư × kho
--   p_recalc = true: tính lại bình quân (nhập mua, tồn đầu, phiếu đảo theo giá gốc); false: xuất theo bình quân hiện tại
create or replace function inv.val_add(p_wh uuid, p_mat uuid, p_dq numeric, p_cost numeric, p_recalc boolean) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_dv numeric := round(p_dq * p_cost, 2);
begin
  insert into cost.item_valuation (warehouse_id, material_id, qty, avg_cost, value)
  values (p_wh, p_mat, p_dq, p_cost, v_dv)
  on conflict (warehouse_id, material_id) do update set
    avg_cost = case when p_recalc and cost.item_valuation.qty + excluded.qty > 0
                    then (cost.item_valuation.value + excluded.value) / (cost.item_valuation.qty + excluded.qty)
                    else cost.item_valuation.avg_cost end,
    value = case when cost.item_valuation.qty + excluded.qty = 0 then 0 else cost.item_valuation.value + excluded.value end,
    qty = cost.item_valuation.qty + excluded.qty,
    updated_at = now();
end $$;

-- ===========================================================================
-- 7. Chứng từ kho: loại mới, hậu kiểm Kế toán SX, người nhận, chứng kiến
-- ===========================================================================
alter table inv.stock_docs drop constraint if exists stock_docs_doc_type_check;
alter table inv.stock_docs add constraint stock_docs_doc_type_check check (doc_type in (
  'GR','ISSUE_WO','RETURN_WO','WIP_IN','FG_IN','SCRAP_IN','SALE','SCRAP_OUT','TRANSFER','ADJ','RETURN_SUP',
  'OPENING',       -- tồn đầu kỳ
  'SPLIT',         -- cắt, tách bobin
  'RECLASS',       -- đổi mã, hạ cấp
  'CUST_RETURN')); -- hàng khách trả
alter table inv.stock_docs
  add column if not exists requisition_id uuid,
  add column if not exists review_status text not null default 'PENDING' check (review_status in ('PENDING','CONFIRMED','RETURNED','NA')),
  add column if not exists reviewed_by uuid,
  add column if not exists reviewed_at timestamptz,
  add column if not exists review_note text,
  add column if not exists receiver_id uuid references core.profiles(id),
  add column if not exists received_at timestamptz,
  add column if not exists witness_id uuid references core.profiles(id),
  add column if not exists delegated boolean not null default false,
  add column if not exists off_hours_reason text,
  add column if not exists price_pending boolean not null default false,
  add column if not exists reversed_by uuid references inv.stock_docs(id);
create index if not exists stock_docs_review on inv.stock_docs (review_status, posted_at) where status = 'POSTED';
create index if not exists stock_docs_ref on inv.stock_docs (ref_type, ref_id);

alter table inv.stock_doc_lines
  add column if not exists weight_kg numeric(18,4),
  add column if not exists gross_kg numeric(18,4),
  add column if not exists tare_kg numeric(18,4),
  add column if not exists reason text;

-- Kho và sản xuất không thấy giá trên dòng chứng từ (giá xem qua hàm có kiểm tra quyền)
revoke select on inv.stock_doc_lines from authenticated;
grant select (id, doc_id, line_no, lot_id, location_id, to_location_id, hu_id, qty, qty_alt, note, weight_kg, gross_kg, tare_kg, reason)
  on inv.stock_doc_lines to authenticated;

-- ===========================================================================
-- 8. Phiếu lĩnh vật tư theo lệnh SX (MES tự tạo theo định mức; lĩnh thêm phải TP Kỹ thuật/QA duyệt)
-- ===========================================================================
create table if not exists inv.requisitions (
  id          uuid primary key default gen_random_uuid(),
  req_no      text unique not null,
  wo_id       uuid not null references mfg.work_orders(id),
  kind        text not null check (kind in ('NORM','EXTRA')),
  work_date   date not null default (now() at time zone 'Asia/Ho_Chi_Minh')::date,
  qty_m       numeric(18,2) check (qty_m > 0),
  status      text not null default 'DRAFT'
              check (status in ('DRAFT','PENDING_APPROVAL','APPROVED','PARTIAL','DONE','CANCELLED')),
  reason_code text references master.reason_codes(code),
  note        text
);
select core.add_audit_cols('inv.requisitions');
select core.enable_audit('inv.requisitions');
create index if not exists requisitions_wo on inv.requisitions (wo_id);

create table if not exists inv.requisition_lines (
  id           uuid primary key default gen_random_uuid(),
  req_id       uuid not null references inv.requisitions(id) on delete cascade,
  material_id  uuid not null references master.materials(id),
  qty_norm     numeric(18,4) not null default 0,
  qty_req      numeric(18,4) not null check (qty_req > 0),
  qty_issued   numeric(18,4) not null default 0,
  qty_returned numeric(18,4) not null default 0,
  unique (req_id, material_id)
);
alter table inv.stock_docs drop constraint if exists stock_docs_requisition_fk;
alter table inv.stock_docs add constraint stock_docs_requisition_fk foreign key (requisition_id) references inv.requisitions(id);

-- ===========================================================================
-- 9. Kiểm kê: theo đơn vị chứa, chọn mẫu hoặc toàn bộ, khóa trong lúc đếm
-- ===========================================================================
alter table inv.stock_counts
  add column if not exists count_type text not null default 'FULL' check (count_type in ('SAMPLE','FULL')),
  add column if not exists location_ids uuid[],                 -- null = toàn kho (FULL)
  add column if not exists note text,
  add column if not exists closed_at timestamptz,
  add column if not exists closed_by uuid;
drop table if exists inv.stock_count_lines;
create table inv.stock_count_lines (
  id          bigint generated always as identity primary key,
  count_id    uuid not null references inv.stock_counts(id) on delete cascade,
  lot_id      uuid not null references inv.lots(id),
  hu_key      uuid not null default '00000000-0000-0000-0000-000000000000',
  location_id uuid references inv.locations(id),
  system_qty  numeric(18,4) not null,
  counted_qty numeric(18,4) check (counted_qty >= 0),
  counted_by  uuid,
  counted_at  timestamptz,
  note        text,
  unique nulls not distinct (count_id, lot_id, hu_key, location_id)
);
create index if not exists stock_count_lines_count on inv.stock_count_lines (count_id);

-- Vị trí/đơn vị chứa có đang trong phiếu kiểm kê chưa đóng không
create or replace function inv.count_lock(p_wh uuid, p_loc uuid, p_hu uuid) returns text
language sql stable security definer set search_path = pg_catalog, public as $$
  select c.count_no from inv.stock_counts c
  where c.warehouse_id = p_wh and c.status in ('OPEN','COUNTED','PENDING_APPROVAL')
    and (
      (c.count_type = 'FULL' and (c.location_ids is null or p_loc = any(c.location_ids)))
      or (c.count_type = 'SAMPLE' and p_hu is not null
          and exists (select 1 from inv.stock_count_lines l where l.count_id = c.id and l.hu_key = p_hu))
    )
  limit 1
$$;

-- ===========================================================================
-- 10. Giao hàng: dòng giao theo bobin, trạng thái duyệt lệnh giao
-- ===========================================================================
alter table sales.deliveries drop constraint if exists deliveries_status_check;
alter table sales.deliveries add constraint deliveries_status_check
  check (status in ('DRAFT','PENDING_APPROVAL','APPROVED','PICKED','SHIPPED','CANCELLED'));
alter table sales.deliveries add column if not exists note text;
create table if not exists sales.delivery_lines (
  id          uuid primary key default gen_random_uuid(),
  delivery_id uuid not null references sales.deliveries(id) on delete cascade,
  so_line_id  uuid not null references sales.so_lines(id),
  hu_id       uuid not null references inv.handling_units(id),
  lot_id      uuid not null references inv.lots(id),
  qty_m       numeric(18,2) not null check (qty_m > 0),
  unique (delivery_id, hu_id)
);

-- Nhận hàng không theo PO (hàng mẫu, chạy thử): bắt buộc lý do; Kế toán SX nhập giá
alter table purchase.goods_receipts alter column po_id drop not null;
alter table purchase.goods_receipts
  add column if not exists supplier_id uuid references core.partners(id),
  add column if not exists no_po_reason text,
  add column if not exists checked_by uuid,
  add column if not exists checked_at timestamptz,
  add column if not exists check_note text;
alter table purchase.gr_lines alter column po_line_id drop not null;
alter table purchase.gr_lines add column if not exists material_id uuid references master.materials(id);

-- ===========================================================================
-- 11. Ghi sổ (lõi, không kiểm tra người dùng — chỉ gọi từ hàm nghiệp vụ)
-- ===========================================================================
create or replace function inv._post(p_doc uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  d inv.stock_docs; l record; wh inv.warehouses; to_wh inv.warehouses; r record;
  v_sign int; v_cost numeric; v_loc uuid; v_hu uuid; v_zero uuid := '00000000-0000-0000-0000-000000000000';
  v_rev boolean; v_same boolean; v_res numeric; v_need numeric; v_take numeric; v_so uuid; v_lock text; v_to_loc uuid;
begin
  select * into d from inv.stock_docs where id = p_doc for update;
  if not found then raise exception 'Không tìm thấy chứng từ kho'; end if;
  if d.status = 'POSTED' then raise exception 'Chứng từ % đã ghi sổ', d.doc_no; end if;
  if d.status not in ('DRAFT', 'APPROVED') then raise exception 'Chứng từ % đang ở trạng thái %', d.doc_no, d.status; end if;
  if d.doc_type in ('ADJ', 'SCRAP_OUT', 'OPENING') and d.status <> 'APPROVED' then
    raise exception 'Chứng từ % cần được phê duyệt trước khi ghi sổ', d.doc_no;
  end if;
  if exists (select 1 from cost.cost_periods cp where cp.period = to_char(d.doc_date, 'YYYY-MM') and cp.status = 'CLOSED') then
    raise exception 'Kỳ % đã chốt giá thành: không ghi sổ chứng từ ngày % (sửa bằng chứng từ ở kỳ đang mở)',
      to_char(d.doc_date, 'MM/YYYY'), to_char(d.doc_date, 'DD/MM/YYYY');
  end if;
  if not exists (select 1 from inv.stock_doc_lines x where x.doc_id = p_doc) then
    raise exception 'Chứng từ % chưa có dòng nào', d.doc_no;
  end if;
  select * into wh from inv.warehouses where id = d.warehouse_id;
  select * into to_wh from inv.warehouses where id = d.to_warehouse_id;
  if d.doc_type = 'TRANSFER' and to_wh.id is null then raise exception 'Chuyển kho cần kho nhận'; end if;
  v_rev := d.reversal_of is not null;
  v_same := d.doc_type = 'TRANSFER' and d.to_warehouse_id = d.warehouse_id;
  if d.doc_type = 'SALE' and d.ref_type = 'DELIVERY' then
    select dl.so_id into v_so from sales.deliveries dl where dl.id = d.ref_id;
  end if;

  for l in select dl.*, lt.item_kind, lt.material_id, lt.qc_status, lt.lot_no, lt.exp_date
           from inv.stock_doc_lines dl join inv.lots lt on lt.id = dl.lot_id
           where dl.doc_id = p_doc order by dl.line_no loop

    if d.doc_type in ('ADJ', 'SPLIT', 'RECLASS') then
      v_sign := sign(l.qty)::int;
    else
      if l.qty < 0 then raise exception 'Số lượng phải dương (dòng %)', l.line_no; end if;
      v_sign := case when d.doc_type in ('GR','RETURN_WO','WIP_IN','FG_IN','SCRAP_IN','OPENING','CUST_RETURN') then 1 else -1 end;
      if v_rev then v_sign := -v_sign; end if;
    end if;
    if not v_rev and d.doc_type in ('ISSUE_WO', 'SALE') and l.qc_status <> 'PASSED' then
      raise exception 'Lô % chưa đạt QC (%): không được xuất', l.lot_no, l.qc_status;   -- BR-KHO-02
    end if;
    if not v_rev and d.doc_type = 'ISSUE_WO' and l.exp_date is not null and l.exp_date < d.doc_date then
      raise exception 'Lô % đã hết hạn dùng (%): không được cấp cho sản xuất', l.lot_no, to_char(l.exp_date, 'DD/MM/YYYY');
    end if;

    v_loc := coalesce(l.location_id, v_zero);
    v_hu := coalesce(l.hu_id, v_zero);
    if d.doc_type <> 'ADJ' then
      v_lock := inv.count_lock(d.warehouse_id, l.location_id, l.hu_id);
      if v_lock is not null then
        raise exception 'Đang kiểm kê (%): không xuất nhập ở vị trí/đơn vị chứa này cho đến khi đóng kiểm kê', v_lock;
      end if;
    end if;

    -- Giá: kho phế = 0; vật tư: nhập mua/tồn đầu/phiếu đảo theo giá dòng, còn lại theo bình quân; BTP/TP: giá tạm
    v_cost := 0;
    if wh.kind = 'SCRAP' then
      v_cost := 0;
    elsif l.item_kind = 'MAT' then
      if d.doc_type in ('GR', 'OPENING') or v_rev then
        if l.unit_cost is null then raise exception 'Dòng % thiếu đơn giá (Kế toán SX nhập giá)', l.line_no; end if;
        v_cost := l.unit_cost;
        if not v_same then perform inv.val_add(d.warehouse_id, l.material_id, v_sign * abs(l.qty), v_cost, true); end if;
      else
        select v.avg_cost into v_cost from cost.item_valuation v where v.warehouse_id = d.warehouse_id and v.material_id = l.material_id;
        v_cost := coalesce(v_cost, 0);
        if not v_same then perform inv.val_add(d.warehouse_id, l.material_id, v_sign * abs(l.qty), v_cost, false); end if;
      end if;
    else
      v_cost := coalesce(l.unit_cost, 0);
    end if;

    -- Xuất bán: trả lại phần "đã giữ" của SO trước khi trừ tồn (BR-KHO-08)
    if d.doc_type = 'SALE' and not v_rev then
      v_need := abs(l.qty);
      for r in select sr.* from sales.so_reservations sr join sales.so_lines sl on sl.id = sr.so_line_id
               where sr.released_at is null and sr.lot_id = l.lot_id
                 and (l.hu_id is null or sr.hu_id is null or sr.hu_id = l.hu_id)
                 and (v_so is null or sl.so_id = v_so)
               order by sr.created_at for update of sr loop
        exit when v_need <= 0;
        v_take := least(v_need, r.qty_m);
        update inv.stock_balances set reserved_qty = greatest(reserved_qty - v_take, 0)
         where warehouse_id = d.warehouse_id and location_key = v_loc and lot_id = l.lot_id and hu_key = v_hu;
        if v_take >= r.qty_m then
          update sales.so_reservations set released_at = now() where id = r.id;
        else
          update sales.so_reservations set qty_m = qty_m - v_take where id = r.id;
        end if;
        update sales.so_lines set reserved_m = greatest(reserved_m - v_take, 0), delivered_m = delivered_m + v_take
         where id = r.so_line_id;
        v_need := v_need - v_take;
      end loop;
    end if;

    -- Chuyển vị trí: phần đã giữ đi theo bobin
    v_res := 0;
    if d.doc_type = 'TRANSFER' then
      select coalesce(b.reserved_qty, 0) into v_res from inv.stock_balances b
       where b.warehouse_id = d.warehouse_id and b.location_key = v_loc and b.lot_id = l.lot_id and b.hu_key = v_hu for update;
      v_res := least(coalesce(v_res, 0), abs(l.qty));
      if v_res > 0 then
        update inv.stock_balances set reserved_qty = reserved_qty - v_res
         where warehouse_id = d.warehouse_id and location_key = v_loc and lot_id = l.lot_id and hu_key = v_hu;
      end if;
    end if;

    insert into inv.stock_moves (doc_id, doc_line_id, move_type, warehouse_id, location_id, lot_id, hu_id, qty, qty_alt, unit_cost)
    values (p_doc, l.id, d.doc_type, d.warehouse_id, l.location_id, l.lot_id, l.hu_id, v_sign * abs(l.qty), l.qty_alt, v_cost);
    perform inv.bal_add(d.warehouse_id, v_loc, l.lot_id, v_hu, v_sign * abs(l.qty));

    if d.doc_type = 'TRANSFER' then
      v_to_loc := coalesce(l.to_location_id, v_zero);
      v_lock := inv.count_lock(to_wh.id, l.to_location_id, l.hu_id);
      if v_lock is not null then raise exception 'Vị trí nhận đang kiểm kê (%)', v_lock; end if;
      insert into inv.stock_moves (doc_id, doc_line_id, move_type, warehouse_id, location_id, lot_id, hu_id, qty, qty_alt, unit_cost)
      values (p_doc, l.id, 'TRANSFER', to_wh.id, l.to_location_id, l.lot_id, l.hu_id, abs(l.qty), l.qty_alt, v_cost);
      perform inv.bal_add(to_wh.id, v_to_loc, l.lot_id, v_hu, abs(l.qty));
      if v_res > 0 then
        update inv.stock_balances set reserved_qty = reserved_qty + v_res
         where warehouse_id = to_wh.id and location_key = v_to_loc and lot_id = l.lot_id and hu_key = v_hu;
      end if;
      if l.item_kind = 'MAT' and not v_same then
        perform inv.val_add(to_wh.id, l.material_id, abs(l.qty), v_cost, true);
      end if;
    end if;
  end loop;

  -- Đơn vị chứa: số lượng còn, vị trí hiện tại, hết hàng thì "Trống" (BR-KHO-13)
  update inv.handling_units h set
    qty = s.q,
    status = case when s.q > 0 then 'ACTIVE' else 'EMPTY' end,
    warehouse_id = coalesce(s.wh, h.warehouse_id),
    location_id = case when s.wh is not null then nullif(s.loc, v_zero) else h.location_id end
  from (select x.hu_id, coalesce(sum(b.qty), 0) as q,
               (array_agg(b.warehouse_id order by b.qty desc) filter (where b.qty > 0))[1] as wh,
               (array_agg(b.location_key order by b.qty desc) filter (where b.qty > 0))[1] as loc
        from (select distinct dl.hu_id from inv.stock_doc_lines dl where dl.doc_id = p_doc and dl.hu_id is not null) x
        left join inv.stock_balances b on b.hu_key = x.hu_id
        group by x.hu_id) s
  where h.id = s.hu_id and h.status <> 'VOID';
  update inv.carriers c set status = 'EMPTY', current_hu_id = null
   where c.current_hu_id in (select dl.hu_id from inv.stock_doc_lines dl where dl.doc_id = p_doc)
     and exists (select 1 from inv.handling_units h where h.id = c.current_hu_id and h.status = 'EMPTY');

  -- Lô hết tồn ở mọi kho → "Hết"; có tồn trở lại (trả kho, điều chỉnh) → "Đạt"
  update inv.lots lt set qc_status = case when s.q > 0 then 'PASSED' else 'CONSUMED' end
  from (select x.lot_id, coalesce(sum(b.qty), 0) as q
        from (select distinct dl.lot_id from inv.stock_doc_lines dl where dl.doc_id = p_doc) x
        left join inv.stock_balances b on b.lot_id = x.lot_id
        group by x.lot_id) s
  where lt.id = s.lot_id
    and ((lt.qc_status = 'PASSED' and s.q = 0) or (lt.qc_status = 'CONSUMED' and s.q > 0));

  update inv.stock_docs set status = 'POSTED', posted_at = now(), posted_by = auth.uid() where id = p_doc;
  if d.reversal_of is not null then
    update inv.stock_docs set reversed_by = p_doc where id = d.reversal_of;
  end if;

  if d.doc_type in ('GR','ISSUE_WO','RETURN_WO','FG_IN','SALE','SCRAP_OUT','ADJ','TRANSFER','OPENING','CUST_RETURN','RECLASS','RETURN_SUP')
     and not v_same then
    insert into integ.sync_queue (entity, entity_id, direction) values ('STOCK_DOC', p_doc, 'TO_MISA');
  end if;
exception
  when check_violation then
    raise exception 'Không đủ tồn khả dụng để xuất (chứng từ %; đã trừ hàng đang giữ): %', d.doc_no, sqlerrm;
end $$;
revoke execute on function inv._post(uuid) from public, anon, authenticated;

-- Ghi sổ một chứng từ đã lập (người giữ kho của kho xuất và kho nhận)
create or replace function inv.post_doc(p_doc uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare d inv.stock_docs; x record;
begin
  select * into d from inv.stock_docs where id = p_doc;
  if not found then raise exception 'Không tìm thấy chứng từ kho'; end if;
  if not core.has_perm('inventory', 'edit') then raise exception 'Không có quyền ghi sổ kho'; end if;
  perform inv.require_keeper(d.warehouse_id, d.witness_id);
  if d.to_warehouse_id is not null and d.to_warehouse_id <> d.warehouse_id then
    perform inv.require_keeper(d.to_warehouse_id, d.witness_id);
  end if;
  -- Xuất cho sản xuất: phải gắn lệnh SX; ngoài phiếu lĩnh đã duyệt thì không vượt định mức cả lệnh (2200)
  if d.doc_type = 'ISSUE_WO' then
    if d.ref_type is distinct from 'WO' or d.ref_id is null then
      raise exception 'Phiếu xuất sản xuất % phải gắn lệnh sản xuất', d.doc_no;
    end if;
    if d.requisition_id is not null then
      if not exists (select 1 from inv.requisitions rq where rq.id = d.requisition_id and rq.wo_id = d.ref_id and rq.status in ('APPROVED', 'PARTIAL')) then
        raise exception 'Phiếu lĩnh của chứng từ % chưa được duyệt hoặc đã cấp xong', d.doc_no;
      end if;
      select m.code, coalesce(rl.qty_req - rl.qty_issued + rl.qty_returned, 0) as remain, t.qty as this_qty into x
      from (select lt.material_id, sum(dl.qty) as qty from inv.stock_doc_lines dl join inv.lots lt on lt.id = dl.lot_id
            where dl.doc_id = p_doc and lt.item_kind = 'MAT' group by lt.material_id) t
      join master.materials m on m.id = t.material_id
      left join inv.requisition_lines rl on rl.req_id = d.requisition_id and rl.material_id = t.material_id
      where t.qty > coalesce(rl.qty_req - rl.qty_issued + rl.qty_returned, 0) + 0.0001
      order by m.code limit 1;
      if found then
        raise exception 'Vượt phiếu lĩnh (%): còn được cấp %, phiếu này %', x.code, core.vn_num(x.remain), core.vn_num(x.this_qty);
      end if;
    else
      select m.code, coalesce(sm.std_qty, 0) as std, coalesce(i.qty, 0) as issued, t.qty as this_qty into x
      from (select lt.material_id, sum(dl.qty) as qty from inv.stock_doc_lines dl join inv.lots lt on lt.id = dl.lot_id
            where dl.doc_id = p_doc and lt.item_kind = 'MAT' group by lt.material_id) t
      join master.materials m on m.id = t.material_id
      left join mfg.wo_std_materials(d.ref_id) sm on sm.material_id = t.material_id
      left join inv.wo_issued(d.ref_id) i on i.material_id = t.material_id
      where coalesce(i.qty, 0) + t.qty > coalesce(sm.std_qty, 0) + 0.0001
      order by m.code limit 1;
      if found then
        raise exception 'Vượt định mức (%): định mức %, đã xuất %, phiếu này %. Lập phiếu lĩnh bổ sung để TP Kỹ thuật/QA duyệt',
          x.code, core.vn_num(x.std), core.vn_num(x.issued), core.vn_num(x.this_qty);
      end if;
    end if;
  end if;
  perform inv._post(p_doc);
  -- Cấp theo phiếu lĩnh: cộng số đã cấp, đóng phiếu khi đủ
  if d.doc_type = 'ISSUE_WO' and d.requisition_id is not null then
    update inv.requisition_lines rl set qty_issued = rl.qty_issued + t.qty
      from (select lt.material_id, sum(dl.qty) as qty from inv.stock_doc_lines dl join inv.lots lt on lt.id = dl.lot_id
            where dl.doc_id = p_doc and lt.item_kind = 'MAT' group by lt.material_id) t
     where rl.req_id = d.requisition_id and rl.material_id = t.material_id;
    update inv.requisitions rq set status = case when exists (
             select 1 from inv.requisition_lines rl where rl.req_id = rq.id and rl.qty_issued - rl.qty_returned < rl.qty_req) then 'PARTIAL' else 'DONE' end
     where rq.id = d.requisition_id;
  end if;
end $$;
