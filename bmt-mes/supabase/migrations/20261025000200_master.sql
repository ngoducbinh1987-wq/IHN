-- BMT MES · 0200 · Danh mục: vật tư, NCC, lõi, tham số công nghệ, sản phẩm, spec, BOM, máy, công đoạn

-- ---------------------------------------------------------------------------
-- Vật tư
-- ---------------------------------------------------------------------------
create table master.material_groups (
  code text primary key,
  name text not null
);

create table master.materials (
  id            uuid primary key default gen_random_uuid(),
  code          text unique not null,            -- CU-024, SIL-9710G, … (mã cố định theo bản 3.0)
  name          text not null,
  group_code    text references master.material_groups(code),
  purchase_spec text,                            -- quy cách mua
  uom           text not null references core.uoms(code),
  loss_rate     numeric(6,4) not null default 0 check (loss_rate >= 0 and loss_rate < 1),  -- hao hụt chạy
  density       numeric(10,4),                   -- g/cm³ (nếu có)
  has_expiry    boolean not null default false,
  requires_coa  boolean not null default false,
  is_scrap      boolean not null default false,  -- mã phế liệu (kho KPL, giá trị 0)
  check_note    text,                            -- căn cứ / kiểm tra
  data_note     text,
  target_months numeric(4,2) not null default 2.5,  -- tồn mục tiêu (tháng)
  safety_stock  numeric(18,4) not null default 0,
  misa_code     text,
  active        boolean not null default true
);
select core.add_audit_cols('master.materials');
select core.enable_audit('master.materials');

alter table core.brands add constraint brands_label_fk foreign key (label_material) references master.materials(code);

-- Thông tin mua theo NCC (Mua hàng quản lý)
create table master.material_suppliers (
  id            uuid primary key default gen_random_uuid(),
  material_id   uuid not null references master.materials(id) on delete cascade,
  supplier_id   uuid references core.partners(id),   -- null = điều kiện mua mặc định từ file Excel
  supplier_item_code text,                           -- mã hàng NCC (bắt buộc trước khi đặt PO, BR-MH-03)
  moq           numeric(18,4) not null default 0,
  pack_multiple numeric(18,4) not null default 1 check (pack_multiple > 0),
  lead_time_days integer not null default 0,
  unit_price    numeric(18,4),                       -- VND/ĐVT chưa VAT; null = chưa có giá (không phải 0)
  currency      text not null default 'VND',
  receive_tolerance numeric(5,4) not null default 0.05,
  is_preferred  boolean not null default false,
  valid_from    date,
  unique (material_id, supplier_id)
);
select core.add_audit_cols('master.material_suppliers');
select core.enable_audit('master.material_suppliers');

create table master.price_history (
  id          bigint generated always as identity primary key,
  material_id uuid not null references master.materials(id),
  supplier_id uuid references core.partners(id),
  price       numeric(18,4) not null,
  source      text,             -- báo giá, PO, LME tham chiếu
  noted_at    timestamptz not null default now(),
  noted_by    uuid default auth.uid()
);

-- ---------------------------------------------------------------------------
-- Tham số công nghệ (có phiên bản)
-- ---------------------------------------------------------------------------
create table master.tech_param_sets (
  id          uuid primary key default gen_random_uuid(),
  version     integer not null unique,
  status      text not null default 'DRAFT' check (status in ('DRAFT','RELEASED','OBSOLETE')),
  note        text,
  released_at timestamptz,
  released_by uuid
);
select core.add_audit_cols('master.tech_param_sets');

create table master.tech_params (
  set_id      uuid not null references master.tech_param_sets(id) on delete cascade,
  code        text not null,          -- rhoCu, rhoSi, dcPhr, startSi, maxPack, …
  name        text not null,
  value       numeric not null,
  unit        text,
  basis       text,                   -- căn cứ / việc cần xác nhận
  confirmed   boolean not null default false,   -- false = Tạm tính
  confirmed_by uuid,
  confirmed_at timestamptz,
  primary key (set_id, code)
);
select core.enable_audit('master.tech_params');

-- Bảng lõi M0.75…M6, A20…A14 (Tham_so H:Z)
create table master.core_types (
  set_id        uuid not null references master.tech_param_sets(id) on delete cascade,
  code          text not null,
  nominal_mm2   numeric not null,
  wire_count    integer not null,
  wire_dia_mm   numeric not null,
  fill_factor   numeric not null,
  silicone_mm   numeric,
  sheath_mm     numeric,
  rdc_limit     numeric,              -- Ω/km; null = chưa có giới hạn (AWG)
  hdpe_mm       numeric,
  pvc_single_mm numeric,
  pitch_override_mm numeric,          -- R: ghi đè bước bện
  pitch_mm      numeric,              -- S: bước bện dùng
  tc020_wires   integer,
  tc024_wires   integer,
  drain_wires   integer,
  drain_pitch_mm numeric,
  primary key (set_id, code)
);

-- ---------------------------------------------------------------------------
-- Sản phẩm, spec (phiên bản), kết quả định mức, BOM
-- ---------------------------------------------------------------------------
create table master.product_groups (
  code  text primary key,     -- PFR, SFR, CFR, CTL, SIF, PVC
  name  text not null,
  allowed_brands text[],      -- PFR chỉ KAVIX …
  allowed_sheaths text[],
  sheath_color text,
  insulation_colors text
);

create table master.products (
  id          uuid primary key default gen_random_uuid(),
  code        text unique not null,        -- PFR-2C-0p75 …
  group_code  text not null references master.product_groups(code),
  description text not null,               -- quy cách
  default_brand text references core.brands(code),
  default_pack  text check (default_pack in ('Bobin gỗ','Cuộn PE')),
  default_m_per_pack numeric not null default 500,
  current_spec_id uuid,                    -- spec đang phát hành (FK thêm sau)
  misa_code   text,
  active      boolean not null default true
);
select core.add_audit_cols('master.products');
select core.enable_audit('master.products');

create table master.product_specs (
  id            uuid primary key default gen_random_uuid(),
  product_id    uuid not null references master.products(id),
  version       integer not null,
  status        text not null default 'DRAFT'
                check (status in ('DRAFT','PILOT_PENDING','PILOT','PENDING_APPROVAL','RELEASED','OBSOLETE')),
  change_level  text check (change_level in ('NEW','MAJOR','MINOR')),
  param_set_id  uuid not null references master.tech_param_sets(id),
  core_code     text not null,
  cores         integer not null check (cores >= 1),
  pairs         integer not null default 0,
  insulation    text not null check (insulation in ('SIL','HDPE','PVC')),
  sheath        text not null,               -- FR-PVC, LSZH, PVC, Không
  ins_thickness_mm numeric not null,
  sheath_thickness_mm numeric not null default 0,
  bundle_factor numeric,                     -- hệ số bó lõi
  lay_factor    numeric not null default 1,  -- K ghép
  pp_filler     numeric not null default 0,
  pet_tape      boolean not null default false,
  shield        boolean not null default false,
  alpet_width_mm numeric,
  conductor_mat text not null check (conductor_mat in ('BC','TC')),
  wire_dia_mm   numeric not null,
  wire_count    integer not null,
  pitch_mm      numeric not null,
  drain_mat     text,                        -- TCCA, TC, Không
  drain_dia_mm  numeric,
  drain_wires   integer,
  drain_pitch_mm numeric,
  sheath_color  text,
  insulation_colors text,
  brand         text references core.brands(code),
  pack_type     text check (pack_type in ('Bobin gỗ','Cuộn PE')),
  m_per_pack    numeric,
  source_basis  text,                        -- S1/S2 catalog …
  config_note   text,
  rdc_deviation_note text,                   -- chấp nhận sai lệch Rdc (BR-SP-03)
  released_at   timestamptz,
  released_by   uuid,
  unique (product_id, version)
);
select core.add_audit_cols('master.product_specs');
select core.enable_audit('master.product_specs');
alter table master.products add constraint products_current_spec_fk
  foreign key (current_spec_id) references master.product_specs(id);

-- Kết quả tính định mức của một spec (Dinh_muc)
create table master.spec_results (
  spec_id         uuid primary key references master.product_specs(id) on delete cascade,
  a_total_mm2     numeric, bundle_dia_mm numeric, k_strand numeric, core_dia_mm numeric,
  cable_bundle_mm numeric, od_mm numeric,
  metal_kgkm      numeric, ins_kgkm numeric, sheath_kgkm numeric, pp_kgkm numeric,
  pet_kgkm        numeric, alpet_kgkm numeric, drain_kgkm numeric, total_kgkm numeric,
  rdc_calc        numeric, rdc_limit numeric,
  tech_check      text,                      -- Kiểm tra kỹ thuật (file)
  pilot_kgkm      numeric, pilot_rdc numeric, pilot_od_mm numeric,  -- QA nhập sau pilot
  calculated_at   timestamptz not null default now()
);

create table master.bom_headers (
  id          uuid primary key default gen_random_uuid(),
  spec_id     uuid not null unique references master.product_specs(id) on delete cascade,
  status      text not null default 'DRAFT' check (status in ('DRAFT','RELEASED','OBSOLETE')),
  note        text
);
select core.add_audit_cols('master.bom_headers');

create table master.bom_lines (
  id            uuid primary key default gen_random_uuid(),
  bom_id        uuid not null references master.bom_headers(id) on delete cascade,
  material_id   uuid not null references master.materials(id),
  basis         text not null check (basis in ('KM','PACK','PALLET','LOT')),  -- suất theo km / kiện / pallet / lô
  qty_per_basis numeric(18,6) not null default 0,     -- suất lý thuyết
  loss_rate     numeric(6,4) not null default 0,      -- hao hụt (mặc định lấy từ vật tư)
  startup_per_lot numeric(18,6) not null default 0,   -- phế khởi động mỗi lô chạy
  operation_code text,                                -- công đoạn tiêu thụ
  note          text,
  unique (bom_id, material_id, basis)
);
select core.enable_audit('master.bom_lines');

-- Quy tắc màu theo nhóm (CAL-16)
create table master.color_rules (
  group_code text references master.product_groups(code),
  cores      integer,
  core_colors text[] not null,               -- ví dụ {'Nâu','Nâu','Trắng'}
  primary key (group_code, cores)
);

-- ---------------------------------------------------------------------------
-- Máy, công đoạn, mã lý do
-- ---------------------------------------------------------------------------
create table master.machines (
  id          uuid primary key default gen_random_uuid(),
  code        text unique not null,           -- EXT-SI-01 …
  name        text not null,
  machine_type text not null check (machine_type in ('MIXER','BUNCHER','EXTRUDER_SI','EXTRUDER_TP','TWISTER','TAPER','PRINTER','GAUGE','TESTER','PACKER')),
  plc_model   text,
  protocol    text check (protocol in ('S7','OPCUA','MODBUS_TCP','NONE')),
  ip_address  inet,
  rated_kw    numeric,                        -- công suất định mức (phân bổ điện GĐ1)
  depreciation_per_hour numeric,
  inline_with uuid references master.machines(id),   -- máy in/máy đo chạy cùng dây máy đùn
  active      boolean not null default true
);
select core.add_audit_cols('master.machines');

create table master.operations (
  code       text primary key,       -- CD0..CD6
  seq        smallint not null,
  name       text not null,
  machine_type text,
  output_prefix text                 -- MX, CB, LB, BL, BS, (cáp), BB
);

create table master.routings (
  group_code text references master.product_groups(code),
  op_code    text references master.operations(code),
  primary key (group_code, op_code)
);

create table master.reason_codes (
  code     text primary key,
  kind     text not null check (kind in ('SCRAP','DOWNTIME','EXTRA_ISSUE','ADJUST','REJECT')),
  name     text not null,
  planned  boolean not null default false     -- phế/dừng trong định mức (khởi động, đổi màu…)
);
