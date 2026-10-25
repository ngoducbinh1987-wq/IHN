-- BMT MES · 0500 · Lệnh SX, công đoạn, phả hệ lô, phế, dừng máy, QA, giá thành

-- ---------------------------------------------------------------------------
-- Sản xuất
-- ---------------------------------------------------------------------------
create table mfg.work_orders (
  id          uuid primary key default gen_random_uuid(),
  wo_no       text unique not null,                    -- LSX-2610-031
  wo_type     text not null default 'PRODUCTION' check (wo_type in ('PRODUCTION','PILOT')),
  plan_line_id uuid references plan.plan_lines(id),
  product_id  uuid not null references master.products(id),
  spec_id     uuid not null references master.product_specs(id),
  bom_id      uuid not null references master.bom_headers(id),
  qty_m       numeric(18,2) not null check (qty_m > 0),
  run_lots    integer not null default 1,
  m_per_pack  numeric not null,
  pack_type   text not null,
  brand       text not null references core.brands(code),
  pilot_max_m numeric,                                  -- giới hạn mét cho lệnh pilot (BR-SP-01)
  status      text not null default 'DRAFT' check (status in
              ('DRAFT','RELEASED','IN_PROGRESS','PAUSED','PRODUCED','QC_PENDING','CLOSED','CANCELLED')),
  planned_start date,
  planned_end date,
  released_at timestamptz,
  released_by uuid,
  closed_at   timestamptz,
  note        text
);
select core.add_audit_cols('mfg.work_orders');
select core.enable_audit('mfg.work_orders');

create table mfg.wo_operations (
  id          uuid primary key default gen_random_uuid(),
  wo_id       uuid not null references mfg.work_orders(id) on delete cascade,
  op_code     text not null references master.operations(code),
  seq         smallint not null,
  machine_id  uuid references master.machines(id),
  status      text not null default 'PENDING' check (status in ('PENDING','RUNNING','PAUSED','DONE','SKIPPED')),
  planned_m   numeric(18,2),
  good_m      numeric(18,2) not null default 0,
  plc_m       numeric(18,2),                            -- mét theo PLC (GĐ4)
  started_at  timestamptz,
  ended_at    timestamptz,
  run_minutes numeric(10,2) not null default 0,         -- giờ máy (phân bổ nhân công/điện/khấu hao)
  kwh         numeric(12,3),
  unique (wo_id, op_code)
);
select core.add_audit_cols('mfg.wo_operations');

alter table inv.lots add constraint lots_wo_op_fk foreign key (wo_op_id) references mfg.wo_operations(id);

-- Phiên vận hành tại máy (tablet): người, máy, ca
create table mfg.operator_sessions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references core.profiles(id),
  machine_id  uuid not null references master.machines(id),
  wo_op_id    uuid references mfg.wo_operations(id),
  shift_code  text not null,                             -- A, B, C
  started_at  timestamptz not null default now(),
  ended_at    timestamptz
);

-- Tiêu thụ lô đầu vào tại công đoạn (quét QR)
create table mfg.wo_material_issues (
  id          uuid primary key default gen_random_uuid(),
  wo_op_id    uuid not null references mfg.wo_operations(id),
  lot_id      uuid not null references inv.lots(id),
  qty         numeric(18,4) not null check (qty > 0),
  is_extra    boolean not null default false,             -- cấp bổ sung vượt định mức (BR-SX-01)
  reason_code text references master.reason_codes(code),
  approved_by uuid,
  stock_doc_id uuid references inv.stock_docs(id),
  scanned_at  timestamptz not null default now(),
  scanned_by  uuid default auth.uid()
);

-- Lô đầu ra của công đoạn
create table mfg.wo_outputs (
  id          uuid primary key default gen_random_uuid(),
  wo_op_id    uuid not null references mfg.wo_operations(id),
  lot_id      uuid not null references inv.lots(id),
  qty_m       numeric(18,2) not null check (qty_m > 0),
  weight_kg   numeric(18,4),
  stock_doc_id uuid references inv.stock_docs(id),
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid()
);

-- Phả hệ lô (truy xuất)
create table mfg.lot_genealogy (
  parent_lot_id uuid not null references inv.lots(id),
  child_lot_id  uuid not null references inv.lots(id),
  wo_op_id      uuid not null references mfg.wo_operations(id),
  qty_used      numeric(18,4) not null,
  primary key (parent_lot_id, child_lot_id, wo_op_id),
  check (parent_lot_id <> child_lot_id)
);
create index on mfg.lot_genealogy (child_lot_id);

create table mfg.scrap_records (
  id          uuid primary key default gen_random_uuid(),
  wo_op_id    uuid not null references mfg.wo_operations(id),
  scrap_material_id uuid not null references master.materials(id),   -- mã phế (PL-CU, PL-SIL…)
  reason_code text not null references master.reason_codes(code),
  qty_kg      numeric(18,4) not null check (qty_kg > 0),
  machine_id  uuid references master.machines(id),
  shift_code  text,
  operator_id uuid references core.profiles(id),
  lot_id      uuid references inv.lots(id),                  -- lô phế trong KPL
  recorded_at timestamptz not null default now(),
  recorded_by uuid default auth.uid()
);

create table mfg.downtime_events (
  id          uuid primary key default gen_random_uuid(),
  machine_id  uuid not null references master.machines(id),
  wo_op_id    uuid references mfg.wo_operations(id),
  started_at  timestamptz not null,
  ended_at    timestamptz,
  minutes     numeric(10,2) generated always as (extract(epoch from (ended_at - started_at)) / 60) stored,
  reason_code text references master.reason_codes(code),   -- bắt buộc khi > 5 phút (BR-SX-04)
  source      text not null default 'MANUAL' check (source in ('MANUAL','PLC')),
  note        text
);

-- ---------------------------------------------------------------------------
-- Chất lượng
-- ---------------------------------------------------------------------------
create table qa.inspections (
  id          uuid primary key default gen_random_uuid(),
  insp_no     text unique not null,
  insp_type   text not null check (insp_type in ('IQC','IPQC','FQC','PILOT')),
  lot_id      uuid references inv.lots(id),
  wo_op_id    uuid references mfg.wo_operations(id),
  spec_id     uuid references master.product_specs(id),
  result      text check (result in ('PASS','FAIL','CONDITIONAL')),
  inspector_id uuid default auth.uid(),
  inspected_at timestamptz,
  note        text
);
select core.add_audit_cols('qa.inspections');
select core.enable_audit('qa.inspections');

create table qa.test_results (
  id            uuid primary key default gen_random_uuid(),
  inspection_id uuid not null references qa.inspections(id) on delete cascade,
  test_code     text not null,          -- RDC, HV, OD, INS_THK, SHEATH_THK, KGKM, DENSITY, WIRE_DIA, VISUAL
  value_num     numeric,
  value_text    text,
  unit          text,
  limit_min     numeric,
  limit_max     numeric,
  pass          boolean
);

create table qa.ncrs (
  id          uuid primary key default gen_random_uuid(),
  ncr_no      text unique not null,
  lot_id      uuid references inv.lots(id),
  inspection_id uuid references qa.inspections(id),
  description text not null,
  disposition text check (disposition in ('REWORK','DOWNGRADE','SCRAP','USE_AS_IS','RETURN_SUPPLIER')),
  status      text not null default 'OPEN' check (status in ('OPEN','PENDING_APPROVAL','APPROVED','CLOSED','CANCELLED')),
  root_cause  text
);
select core.add_audit_cols('qa.ncrs');

-- ---------------------------------------------------------------------------
-- Giá thành
-- ---------------------------------------------------------------------------
create table cost.cost_periods (
  id         uuid primary key default gen_random_uuid(),
  period     text unique not null,                    -- 2026-10
  status     text not null default 'OPEN' check (status in ('OPEN','CALCULATED','PENDING_APPROVAL','CLOSED')),
  closed_at  timestamptz
);
select core.add_audit_cols('cost.cost_periods');

-- Giá bình quân gia quyền di động theo mã vật tư × kho (phương án đã duyệt 25/10/2026)
create table cost.item_valuation (
  warehouse_id uuid not null references inv.warehouses(id),
  material_id  uuid not null references master.materials(id),
  qty          numeric(18,4) not null default 0,
  avg_cost     numeric(18,4) not null default 0,
  value        numeric(18,2) not null default 0,
  updated_at   timestamptz not null default now(),
  primary key (warehouse_id, material_id)
);

-- Giá chuẩn kỳ (Kế toán giá thành cập nhật)
create table cost.standard_prices (
  period_id   uuid not null references cost.cost_periods(id),
  material_id uuid not null references master.materials(id),
  std_price   numeric(18,4) not null,
  primary key (period_id, material_id)
);

-- Tập hợp chi phí kỳ: nhân công, điện, khấu hao, SXC (từ MISA)
create table cost.cost_pools (
  period_id   uuid not null references cost.cost_periods(id),
  pool_code   text not null check (pool_code in ('LABOR','POWER','DEPRECIATION','OVERHEAD')),
  amount      numeric(18,2) not null,
  basis       text not null check (basis in ('MACHINE_HOURS','LABOR_HOURS','KWH','CU_KG')),
  source      text default 'MISA',
  primary key (period_id, pool_code)
);

create table cost.wo_costs (
  wo_id        uuid primary key references mfg.work_orders(id),
  period_id    uuid references cost.cost_periods(id),
  good_m       numeric(18,2),
  std_material numeric(18,2), act_material numeric(18,2),
  std_packing  numeric(18,2), act_packing  numeric(18,2),
  std_labor    numeric(18,2), act_labor    numeric(18,2),
  std_power    numeric(18,2), act_power    numeric(18,2),
  std_depr     numeric(18,2), act_depr     numeric(18,2),
  std_overhead numeric(18,2), act_overhead numeric(18,2),
  scrap_kg     numeric(18,4),                     -- phế ghi giá trị 0, chỉ theo dõi kg
  std_total    numeric(18,2) generated always as (coalesce(std_material,0)+coalesce(std_packing,0)+coalesce(std_labor,0)+coalesce(std_power,0)+coalesce(std_depr,0)+coalesce(std_overhead,0)) stored,
  act_total    numeric(18,2) generated always as (coalesce(act_material,0)+coalesce(act_packing,0)+coalesce(act_labor,0)+coalesce(act_power,0)+coalesce(act_depr,0)+coalesce(act_overhead,0)) stored,
  status       text not null default 'DRAFT' check (status in ('DRAFT','PENDING_APPROVAL','APPROVED')),
  calculated_at timestamptz
);

-- Chênh lệch NVL theo từng vật tư (BR-GT-02)
create table cost.wo_material_variances (
  wo_id       uuid not null references mfg.work_orders(id),
  material_id uuid not null references master.materials(id),
  std_qty     numeric(18,4) not null,
  act_qty     numeric(18,4) not null,
  std_price   numeric(18,4),
  act_amount  numeric(18,2),
  qty_variance   numeric(18,2),        -- (thực − ĐM) × giá chuẩn
  price_variance numeric(18,2),        -- (giá thực − giá chuẩn) × lượng thực
  primary key (wo_id, material_id)
);
