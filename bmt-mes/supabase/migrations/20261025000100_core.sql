-- BMT MES · 0100 · Schema, hàm tiện ích, tài khoản, vai trò, phân quyền, nhật ký
-- Chạy trên Supabase (PostgreSQL 15+). Không đụng tới các bảng có sẵn trong schema public.

create extension if not exists pgcrypto;

create schema if not exists core;     -- tài khoản, vai trò, đối tác, nhật ký
create schema if not exists master;   -- danh mục: vật tư, sản phẩm, spec, BOM, máy
create schema if not exists sales;    -- đơn bán, giữ hàng, giao hàng
create schema if not exists plan;     -- kế hoạch kỳ, MRP, đề xuất mua tối ưu
create schema if not exists purchase; -- PR, PO, nhận hàng
create schema if not exists inv;      -- kho, lô, sổ cái kho
create schema if not exists mfg;      -- lệnh SX, công đoạn, phả hệ lô, phế, dừng máy
create schema if not exists qa;       -- kiểm tra chất lượng, NCR
create schema if not exists cost;     -- giá thành, bình quân di động
create schema if not exists wf;       -- luồng duyệt
create schema if not exists iot;      -- dữ liệu máy
create schema if not exists integ;    -- đồng bộ MISA

-- ---------------------------------------------------------------------------
-- Hàm tiện ích
-- ---------------------------------------------------------------------------
create or replace function core.set_updated() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end $$;

-- Gắn cột created/updated + trigger cho một bảng
create or replace function core.add_audit_cols(p_table regclass) returns void
language plpgsql as $$
begin
  execute format('alter table %s
    add column if not exists created_at timestamptz not null default now(),
    add column if not exists created_by uuid default auth.uid(),
    add column if not exists updated_at timestamptz not null default now(),
    add column if not exists updated_by uuid', p_table);
  execute format('drop trigger if exists trg_set_updated on %s', p_table);
  execute format('create trigger trg_set_updated before update on %s
    for each row execute function core.set_updated()', p_table);
end $$;

-- Số chứng từ tự sinh: PREFIX-YYMM-#### (đếm lại theo tháng)
create table core.number_sequences (
  prefix  text not null,
  period  text not null,
  last_no integer not null default 0,
  primary key (prefix, period)
);

create or replace function core.next_no(p_prefix text, p_width int default 4) returns text
language plpgsql as $$
declare v_period text := to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'YYMM'); v_no int;
begin
  insert into core.number_sequences(prefix, period, last_no) values (p_prefix, v_period, 1)
  on conflict (prefix, period) do update set last_no = core.number_sequences.last_no + 1
  returning last_no into v_no;
  return p_prefix || '-' || v_period || '-' || lpad(v_no::text, p_width, '0');
end $$;

-- ---------------------------------------------------------------------------
-- Tổ chức, người dùng, vai trò
-- ---------------------------------------------------------------------------
create table core.departments (
  code text primary key,
  name text not null
);

create table core.profiles (
  id            uuid primary key references auth.users(id) on delete restrict,
  employee_code text unique,
  full_name     text not null,
  department    text references core.departments(code),
  title         text,
  phone         text,
  pin_hash      text,                       -- PIN đăng nhập tablet (bcrypt)
  status        text not null default 'ACTIVE' check (status in ('INVITED','ACTIVE','LOCKED','INACTIVE')),
  failed_pin    smallint not null default 0
);
select core.add_audit_cols('core.profiles');

create table core.roles (
  code        text primary key,
  name        text not null,
  department  text references core.departments(code),
  level       smallint not null default 1,  -- 1 nhân viên, 2 trưởng phòng, 3 BGĐ
  can_see_price boolean not null default false
);

-- Phân hệ × hành động
create table core.permissions (
  module text not null,
  action text not null check (action in ('view','create','edit','approve','export','config')),
  primary key (module, action)
);

create table core.role_permissions (
  role_code text references core.roles(code) on delete cascade,
  module    text,
  action    text,
  primary key (role_code, module, action),
  foreign key (module, action) references core.permissions(module, action) on delete cascade
);

create table core.user_roles (
  user_id   uuid references core.profiles(id) on delete cascade,
  role_code text references core.roles(code) on delete cascade,
  primary key (user_id, role_code)
);

-- Phạm vi dữ liệu: kho / máy / khách hàng được giao (trống = toàn nhà máy)
create table core.user_scopes (
  user_id    uuid references core.profiles(id) on delete cascade,
  scope_type text not null check (scope_type in ('WAREHOUSE','MACHINE','PARTNER')),
  scope_id   uuid not null,
  primary key (user_id, scope_type, scope_id)
);

-- Ủy quyền duyệt có thời hạn
create table core.delegations (
  id         uuid primary key default gen_random_uuid(),
  from_user  uuid not null references core.profiles(id),
  to_user    uuid not null references core.profiles(id),
  role_code  text not null references core.roles(code),
  valid_from timestamptz not null,
  valid_to   timestamptz not null,
  reason     text,
  check (valid_to > valid_from and from_user <> to_user)
);
select core.add_audit_cols('core.delegations');

-- Kiểm tra quyền của người đang đăng nhập (dùng trong RLS)
create or replace function core.has_perm(p_module text, p_action text) returns boolean
language sql stable security definer set search_path = core, public as $$
  select exists (
    select 1
    from core.user_roles ur
    join core.role_permissions rp on rp.role_code = ur.role_code
    join core.profiles p on p.id = ur.user_id and p.status = 'ACTIVE'
    where ur.user_id = auth.uid() and rp.module = p_module and rp.action = p_action
  ) or exists (
    select 1
    from core.delegations d
    join core.role_permissions rp on rp.role_code = d.role_code
    where d.to_user = auth.uid() and now() between d.valid_from and d.valid_to
      and rp.module = p_module and rp.action = p_action
  )
$$;

create or replace function core.has_role(p_role text) returns boolean
language sql stable security definer set search_path = core, public as $$
  select exists (select 1 from core.user_roles where user_id = auth.uid() and role_code = p_role)
      or exists (select 1 from core.delegations where to_user = auth.uid() and role_code = p_role
                 and now() between valid_from and valid_to)
$$;

create or replace function core.can_see_price() returns boolean
language sql stable security definer set search_path = core, public as $$
  select exists (select 1 from core.user_roles ur join core.roles r on r.code = ur.role_code
                 where ur.user_id = auth.uid() and r.can_see_price)
$$;

-- ---------------------------------------------------------------------------
-- Đối tác, thương hiệu, đơn vị tính, file đính kèm
-- ---------------------------------------------------------------------------
create table core.partners (
  id          uuid primary key default gen_random_uuid(),
  code        text unique not null,
  name        text not null,
  tax_code    text,
  is_customer boolean not null default false,
  is_supplier boolean not null default false,
  is_brand_entity boolean not null default false,   -- pháp nhân thương hiệu (KAVIX, HEIZKA)
  partner_type text check (partner_type in ('BRAND_ENTITY','DEALER','END_CUSTOMER','SUPPLIER')),
  address     text,
  contact     text,
  misa_code   text,
  active      boolean not null default true
);
select core.add_audit_cols('core.partners');

create table core.brands (
  code            text primary key,              -- KAVIX, HEIZKA
  name            text not null,
  owner_partner_id uuid references core.partners(id),
  label_material  text                           -- LABEL-K / LABEL-H (gắn FK sau khi có master.materials)
);

create table core.uoms (
  code text primary key,  -- kg, m, km, bộ, cái
  name text not null
);

create table core.attachments (
  id          uuid primary key default gen_random_uuid(),
  bucket      text not null default 'documents',
  path        text not null,                     -- đường dẫn trong Supabase Storage
  file_name   text not null,
  mime_type   text,
  ref_table   text,
  ref_id      uuid,
  kind        text                               -- COA, TDS, PO, ảnh lỗi, biên bản…
);
select core.add_audit_cols('core.attachments');

-- ---------------------------------------------------------------------------
-- Nhật ký thao tác
-- ---------------------------------------------------------------------------
create table core.audit_log (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  user_id    uuid,
  table_name text not null,
  row_id     text,
  action     text not null,
  old_data   jsonb,
  new_data   jsonb
);
create index on core.audit_log (table_name, row_id);
create index on core.audit_log (at desc);

create or replace function core.audit() returns trigger
language plpgsql security definer set search_path = core, public as $$
declare v_id text;
begin
  v_id := coalesce(to_jsonb(new)->>'id', to_jsonb(old)->>'id');
  insert into core.audit_log(user_id, table_name, row_id, action, old_data, new_data)
  values (auth.uid(), tg_table_schema || '.' || tg_table_name, v_id, tg_op,
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return coalesce(new, old);
end $$;

create or replace function core.enable_audit(p_table regclass) returns void
language plpgsql as $$
begin
  execute format('drop trigger if exists trg_audit on %s', p_table);
  execute format('create trigger trg_audit after insert or update or delete on %s
    for each row execute function core.audit()', p_table);
end $$;

select core.enable_audit('core.profiles');
select core.enable_audit('core.user_roles');
select core.enable_audit('core.role_permissions');
select core.enable_audit('core.delegations');
