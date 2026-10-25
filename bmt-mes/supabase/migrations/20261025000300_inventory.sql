-- BMT MES · 0300 · Kho, vị trí, lô, đơn vị chứa (bobin/bao có QR), chứng từ kho, sổ cái, tồn

create table inv.warehouses (
  id     uuid primary key default gen_random_uuid(),
  code   text unique not null,                      -- KNL, KBTP, KTP, KPL
  name   text not null,
  kind   text not null check (kind in ('MAT','WIP','FG','SCRAP')),
  misa_code text
);

create table inv.locations (
  id           uuid primary key default gen_random_uuid(),
  warehouse_id uuid not null references inv.warehouses(id),
  code         text not null,                        -- A1-03, F1-07 …
  name         text,
  unique (warehouse_id, code)
);

-- Lô: dùng chung cho NVL, BTP, TP, phế
create table inv.lots (
  id           uuid primary key default gen_random_uuid(),
  lot_no       text unique not null,
  item_kind    text not null check (item_kind in ('MAT','WIP','FG','SCRAP')),
  material_id  uuid references master.materials(id),   -- MAT, SCRAP
  product_id   uuid references master.products(id),    -- WIP, FG
  spec_id      uuid references master.product_specs(id),
  wip_stage    text,                                    -- MX, CB, LB, BL, BS
  brand        text references core.brands(code),       -- thương hiệu in nhãn (FG)
  color        text,
  uom          text not null references core.uoms(code),
  supplier_id  uuid references core.partners(id),
  supplier_lot text,
  gr_line_id   uuid,                                    -- dòng nhận hàng tạo lô (FK sau)
  wo_op_id     uuid,                                    -- công đoạn tạo lô (FK sau)
  qc_status    text not null default 'PENDING'
               check (qc_status in ('PENDING','PASSED','QUARANTINE','REJECTED','CONSUMED')),
  mfg_date     date,
  exp_date     date,
  coa_file_id  uuid references core.attachments(id),
  weight_kg    numeric(18,4),                           -- cân thực khi nhập (BTP/TP) để hiệu chỉnh định mức
  attrs        jsonb not null default '{}',
  check ((item_kind in ('MAT','SCRAP') and material_id is not null)
      or (item_kind in ('WIP','FG') and product_id is not null))
);
select core.add_audit_cols('inv.lots');
select core.enable_audit('inv.lots');
create index on inv.lots (material_id);
create index on inv.lots (product_id);
create index on inv.lots (qc_status);

-- Đơn vị chứa có tem QR: bobin, cuộn, bao
create table inv.handling_units (
  id        uuid primary key default gen_random_uuid(),
  hu_no     text unique not null,                        -- BB-PFR2C15-261025-007
  lot_id    uuid not null references inv.lots(id),
  hu_type   text not null check (hu_type in ('REEL','COIL','BAG','DRUM','PALLET','OTHER')),
  qty       numeric(18,4) not null,
  qr_payload text generated always as ('BMT|' || hu_no) stored
);
select core.add_audit_cols('inv.handling_units');

-- Chứng từ kho
create table inv.stock_docs (
  id            uuid primary key default gen_random_uuid(),
  doc_no        text unique not null,
  doc_type      text not null check (doc_type in (
                  'GR',          -- nhập mua
                  'ISSUE_WO',    -- xuất NVL/BTP cho LSX
                  'RETURN_WO',   -- trả NVL thừa
                  'WIP_IN',      -- nhập BTP từ công đoạn
                  'FG_IN',       -- nhập TP
                  'SCRAP_IN',    -- nhập phế
                  'SALE',        -- xuất bán
                  'SCRAP_OUT',   -- xuất bán/hủy phế
                  'TRANSFER',    -- chuyển kho
                  'ADJ',         -- điều chỉnh kiểm kê
                  'RETURN_SUP')),-- trả NCC
  status        text not null default 'DRAFT' check (status in ('DRAFT','PENDING_APPROVAL','APPROVED','POSTED','CANCELLED')),
  warehouse_id  uuid not null references inv.warehouses(id),
  to_warehouse_id uuid references inv.warehouses(id),
  doc_date      date not null default (now() at time zone 'Asia/Ho_Chi_Minh')::date,
  ref_type      text,                 -- PO, WO, SO, DELIVERY, COUNT
  ref_id        uuid,
  reason_code   text references master.reason_codes(code),
  note          text,
  posted_at     timestamptz,
  posted_by     uuid,
  reversal_of   uuid references inv.stock_docs(id)
);
select core.add_audit_cols('inv.stock_docs');
select core.enable_audit('inv.stock_docs');

create table inv.stock_doc_lines (
  id          uuid primary key default gen_random_uuid(),
  doc_id      uuid not null references inv.stock_docs(id) on delete cascade,
  line_no     integer not null,
  lot_id      uuid not null references inv.lots(id),
  location_id uuid references inv.locations(id),
  to_location_id uuid references inv.locations(id),
  hu_id       uuid references inv.handling_units(id),
  qty         numeric(18,4) not null check (qty <> 0),   -- luôn dương, riêng ADJ cho phép âm
  qty_alt     numeric(18,4),                              -- quy đổi kg ↔ m
  unit_cost   numeric(18,4),                              -- chỉ nhập mua: đơn giá; còn lại hệ thống tự tính
  note        text,
  unique (doc_id, line_no)
);

-- Sổ cái kho bất biến (BR-KHO-01)
create table inv.stock_moves (
  id           bigint generated always as identity primary key,
  moved_at     timestamptz not null default now(),
  doc_id       uuid not null references inv.stock_docs(id),
  doc_line_id  uuid not null references inv.stock_doc_lines(id),
  move_type    text not null,
  warehouse_id uuid not null references inv.warehouses(id),
  location_id  uuid references inv.locations(id),
  lot_id       uuid not null references inv.lots(id),
  qty          numeric(18,4) not null,          -- + nhập, − xuất
  qty_alt      numeric(18,4),
  unit_cost    numeric(18,4) not null default 0,-- giá bình quân tại thời điểm ghi sổ
  amount       numeric(18,2) generated always as (round(qty * unit_cost, 2)) stored,
  posted_by    uuid default auth.uid()
);
create index on inv.stock_moves (lot_id);
create index on inv.stock_moves (warehouse_id, moved_at);

-- Tồn theo kho / vị trí / lô (bảng tổng hợp, chỉ ghi qua inv.post_doc)
create table inv.stock_balances (
  warehouse_id uuid not null references inv.warehouses(id),
  location_key uuid not null default '00000000-0000-0000-0000-000000000000',
  lot_id       uuid not null references inv.lots(id),
  qty          numeric(18,4) not null default 0,
  reserved_qty numeric(18,4) not null default 0,   -- đã giữ cho SO / cấp phát LSX
  updated_at   timestamptz not null default now(),
  primary key (warehouse_id, location_key, lot_id),
  check (qty >= 0)
);

-- Kiểm kê
create table inv.stock_counts (
  id           uuid primary key default gen_random_uuid(),
  count_no     text unique not null,
  warehouse_id uuid not null references inv.warehouses(id),
  status       text not null default 'OPEN' check (status in ('OPEN','COUNTED','PENDING_APPROVAL','APPROVED','POSTED','CANCELLED')),
  count_date   date not null,
  adj_doc_id   uuid references inv.stock_docs(id)
);
select core.add_audit_cols('inv.stock_counts');

create table inv.stock_count_lines (
  count_id    uuid not null references inv.stock_counts(id) on delete cascade,
  lot_id      uuid not null references inv.lots(id),
  location_id uuid references inv.locations(id),
  system_qty  numeric(18,4) not null,
  counted_qty numeric(18,4),
  scanned_by  uuid,
  scanned_at  timestamptz,
  primary key (count_id, lot_id)
);
