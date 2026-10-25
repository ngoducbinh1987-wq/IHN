-- BMT MES · 0400 · Đơn bán, kế hoạch kỳ, MRP, đề xuất mua tối ưu, PR, PO, nhận hàng

-- ---------------------------------------------------------------------------
-- Bán hàng
-- ---------------------------------------------------------------------------
create table sales.sales_orders (
  id            uuid primary key default gen_random_uuid(),
  so_no         text unique not null,
  revision      integer not null default 0,           -- BR-SO-05: phiên bản điều chỉnh
  customer_id   uuid not null references core.partners(id),
  brand_entity_id uuid references core.partners(id),  -- pháp nhân thương hiệu (nếu đại lý đặt qua KAVIX/HEIZKA)
  label_brand   text not null references core.brands(code),
  order_date    date not null default (now() at time zone 'Asia/Ho_Chi_Minh')::date,
  required_date date not null,
  delivery_terms text,
  owner_id      uuid default auth.uid(),
  status        text not null default 'DRAFT' check (status in
                ('DRAFT','PENDING_APPROVAL','APPROVED','IN_PRODUCTION','READY','PARTIAL_DELIVERED','DELIVERED','CANCELLED')),
  note          text
);
select core.add_audit_cols('sales.sales_orders');
select core.enable_audit('sales.sales_orders');

create table sales.so_lines (
  id          uuid primary key default gen_random_uuid(),
  so_id       uuid not null references sales.sales_orders(id) on delete cascade,
  line_no     integer not null,
  product_id  uuid not null references master.products(id),
  spec_id     uuid references master.product_specs(id),
  qty_m       numeric(18,2) not null check (qty_m > 0),
  pack_type   text check (pack_type in ('Bobin gỗ','Cuộn PE')),
  m_per_pack  numeric,
  single_color text,
  unit_price  numeric(18,2),
  line_status text not null default 'OPEN' check (line_status in
              ('OPEN','WAITING_SPEC','RESERVED','PLANNED','IN_PRODUCTION','READY','DELIVERED','CANCELLED')),
  reserved_m  numeric(18,2) not null default 0,
  to_produce_m numeric(18,2) not null default 0,
  delivered_m numeric(18,2) not null default 0,
  tech_note   text,
  unique (so_id, line_no)
);

create table sales.so_reservations (
  id          uuid primary key default gen_random_uuid(),
  so_line_id  uuid not null references sales.so_lines(id) on delete cascade,
  lot_id      uuid not null references inv.lots(id),
  hu_id       uuid references inv.handling_units(id),
  qty_m       numeric(18,2) not null check (qty_m > 0),
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid(),
  released_at timestamptz
);

create table sales.deliveries (
  id          uuid primary key default gen_random_uuid(),
  delivery_no text unique not null,
  so_id       uuid not null references sales.sales_orders(id),
  ship_date   date,
  status      text not null default 'DRAFT' check (status in ('DRAFT','PICKED','SHIPPED','CANCELLED')),
  stock_doc_id uuid references inv.stock_docs(id)
);
select core.add_audit_cols('sales.deliveries');

-- ---------------------------------------------------------------------------
-- Kế hoạch kỳ và MRP
-- ---------------------------------------------------------------------------
create table plan.production_plans (
  id          uuid primary key default gen_random_uuid(),
  plan_no     text unique not null,                -- KH-2611-01
  version     integer not null default 1,
  period_label text not null,                      -- Tháng 11/2026
  material_need_date date,                         -- ngày cần vật tư (Chon_san_luong F4)
  status      text not null default 'DRAFT' check (status in ('DRAFT','PENDING_APPROVAL','APPROVED','CLOSED','CANCELLED')),
  mode        text not null default 'OFFICIAL' check (mode in ('OFFICIAL','PRELIMINARY')),  -- sơ bộ khi còn spec chờ duyệt
  previous_id uuid references plan.production_plans(id),
  note        text
);
select core.add_audit_cols('plan.production_plans');
select core.enable_audit('plan.production_plans');

create table plan.plan_lines (
  id          uuid primary key default gen_random_uuid(),
  plan_id     uuid not null references plan.production_plans(id) on delete cascade,
  product_id  uuid not null references master.products(id),
  spec_id     uuid not null references master.product_specs(id),
  qty_m       numeric(18,2) not null check (qty_m >= 0),
  run_lots    integer not null default 1 check (run_lots >= 1),
  m_per_pack  numeric not null check (m_per_pack > 0),
  pack_type   text not null check (pack_type in ('Bobin gỗ','Cuộn PE')),
  brand       text not null references core.brands(code),
  sheath      text,
  single_color text,
  so_line_id  uuid references sales.so_lines(id),   -- null = SX tồn kho
  wo_note     text,
  check_msg   text,                                 -- "Cần xác nhận" (tự tính)
  unique (plan_id, product_id, so_line_id)
);

create table plan.mrp_runs (
  id          uuid primary key default gen_random_uuid(),
  plan_id     uuid not null references plan.production_plans(id),
  run_at      timestamptz not null default now(),
  run_by      uuid default auth.uid(),
  need_date   date,
  total_m     numeric,
  budget_vnd  numeric,
  missing_price_count integer,
  snapshot    jsonb                                  -- phiên bản BOM/tham số đã dùng (BR-KH-06)
);

create table plan.mrp_lines (
  id            uuid primary key default gen_random_uuid(),
  run_id        uuid not null references plan.mrp_runs(id) on delete cascade,
  material_id   uuid not null references master.materials(id),
  theoretical   numeric(18,4) not null,
  after_loss    numeric(18,4) not null,
  startup       numeric(18,4) not null,
  total_issue   numeric(18,4) not null,             -- tổng cấp SX
  available     numeric(18,4) not null,             -- tồn khả dụng
  in_quality    numeric(18,4) not null,             -- đang chờ QC (chỉ hiển thị)
  incoming      numeric(18,4) not null,             -- hàng về kịp
  reserve       numeric(18,4) not null default 0,   -- dự phòng cuối
  net_short     numeric(18,4) not null,
  moq           numeric(18,4),
  pack_multiple numeric(18,4),
  suggest_qty   numeric(18,4) not null,
  unit_price    numeric(18,4),
  amount        numeric(18,2),
  lead_time_days integer,
  latest_order_date date,
  status        text not null,                       -- Không cần mua / Cập nhật giá / Trễ / Đặt hàng
  unique (run_id, material_id)
);

-- Đề xuất mua tối ưu (TP Mua lập)
create table plan.purchase_proposals (
  id          uuid primary key default gen_random_uuid(),
  proposal_no text unique not null,                  -- ĐXM-2610-003 (lưu dạng DXM-…)
  status      text not null default 'DRAFT' check (status in ('DRAFT','PENDING_APPROVAL','APPROVED','REJECTED','CONVERTED','CANCELLED')),
  reason      text,
  note        text
);
select core.add_audit_cols('plan.purchase_proposals');
select core.enable_audit('plan.purchase_proposals');

create table plan.proposal_lines (
  id            uuid primary key default gen_random_uuid(),
  proposal_id   uuid not null references plan.purchase_proposals(id) on delete cascade,
  material_id   uuid not null references master.materials(id),
  avg_monthly_use numeric(18,4),
  target_stock  numeric(18,4),
  suggested_qty numeric(18,4) not null,
  proposed_qty  numeric(18,4) not null,
  deviation_reason text,                               -- bắt buộc khi lệch > 20% (BR-DXM-03)
  reason_kind   text check (reason_kind in ('PRICE','MOQ','SUPPLY_RISK','OTHER')),
  ref_price     numeric(18,4),
  ref_price_source text,
  supplier_id   uuid references core.partners(id),
  check (suggested_qty = 0 or abs(proposed_qty - suggested_qty) / suggested_qty <= 0.2 or deviation_reason is not null)
);

-- ---------------------------------------------------------------------------
-- Mua hàng
-- ---------------------------------------------------------------------------
create table purchase.purchase_requests (
  id          uuid primary key default gen_random_uuid(),
  pr_no       text unique not null,
  source      text not null check (source in ('MRP','MANUAL','PILOT')),
  mrp_run_id  uuid references plan.mrp_runs(id),
  status      text not null default 'DRAFT' check (status in ('DRAFT','PENDING_APPROVAL','APPROVED','PARTIAL_PO','CLOSED','CANCELLED')),
  need_date   date,
  note        text
);
select core.add_audit_cols('purchase.purchase_requests');
select core.enable_audit('purchase.purchase_requests');

create table purchase.pr_lines (
  id          uuid primary key default gen_random_uuid(),
  pr_id       uuid not null references purchase.purchase_requests(id) on delete cascade,
  material_id uuid not null references master.materials(id),
  qty         numeric(18,4) not null check (qty > 0),
  need_date   date,
  mrp_line_id uuid references plan.mrp_lines(id),
  ordered_qty numeric(18,4) not null default 0
);

create table purchase.purchase_orders (
  id          uuid primary key default gen_random_uuid(),
  po_no       text unique not null,
  supplier_id uuid not null references core.partners(id),
  status      text not null default 'DRAFT' check (status in
              ('DRAFT','PENDING_APPROVAL','APPROVED','SENT','PARTIAL_RECEIVED','RECEIVED','CLOSED','CANCELLED')),
  order_date  date,
  expected_date date,
  payment_terms text,
  note        text
);
select core.add_audit_cols('purchase.purchase_orders');
select core.enable_audit('purchase.purchase_orders');

create table purchase.po_lines (
  id          uuid primary key default gen_random_uuid(),
  po_id       uuid not null references purchase.purchase_orders(id) on delete cascade,
  line_no     integer not null,
  material_id uuid not null references master.materials(id),
  supplier_item_code text,
  qty         numeric(18,4) not null check (qty > 0),
  unit_price  numeric(18,4),
  expected_date date,
  pr_line_id  uuid references purchase.pr_lines(id),
  proposal_line_id uuid references plan.proposal_lines(id),
  received_qty numeric(18,4) not null default 0,
  unique (po_id, line_no)
);

create table purchase.goods_receipts (
  id          uuid primary key default gen_random_uuid(),
  gr_no       text unique not null,
  po_id       uuid not null references purchase.purchase_orders(id),
  receipt_date date not null default (now() at time zone 'Asia/Ho_Chi_Minh')::date,
  status      text not null default 'DRAFT' check (status in ('DRAFT','POSTED','CANCELLED')),
  stock_doc_id uuid references inv.stock_docs(id),
  delivery_note text
);
select core.add_audit_cols('purchase.goods_receipts');

create table purchase.gr_lines (
  id          uuid primary key default gen_random_uuid(),
  gr_id       uuid not null references purchase.goods_receipts(id) on delete cascade,
  po_line_id  uuid not null references purchase.po_lines(id),
  qty         numeric(18,4) not null check (qty > 0),
  supplier_lot text,
  mfg_date    date,
  exp_date    date,
  coa_file_id uuid references core.attachments(id),
  coa_density numeric,                                -- tỷ trọng thực trên COA (BR-MH-05)
  lot_id      uuid references inv.lots(id)
);
alter table inv.lots add constraint lots_gr_line_fk foreign key (gr_line_id) references purchase.gr_lines(id);
