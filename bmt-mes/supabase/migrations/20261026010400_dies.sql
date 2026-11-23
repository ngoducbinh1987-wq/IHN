-- Migration 20261026010400 – Module Khuôn (anh Bình duyệt 19/11/2026, Claude Doc "BMT MES – Danh mục khuôn tối ưu (đùn, bện)"):
--  * Danh mục khuôn (Quản lý máy → Khuôn): khuôn trong (tip), khuôn ngoài (die) đùn cách điện / vỏ, khuôn bện, khuôn xoắn.
--  * Quy tắc kích thước rút từ bảng khuôn nhà máy; TP KT/QA sửa. MES tự tra khuôn cho từng spec × công đoạn, đề xuất kích thước còn thiếu.
--  * Anh Bình chốt: OD trong spec = OD tối ưu, thêm OD thực tế (khuôn vỏ tính theo OD thực tế khi đã đo);
--    khuôn 4,9 / 5,85 là khuôn máy xoắn; KB-1,95 + KB-2,05 gộp thành KB-2,10; dung sai khuôn ngoài cách điện ±0,05, vỏ ±0,08;
--    khuôn vỏ LSZH và PVC dùng chung.
--  * Alarm khi mã trong kế hoạch tháng chưa có khuôn sẵn; lịch máy gom lô theo khuôn, không cho hai máy dùng một bộ khuôn cùng lúc;
--    km chạy của khuôn từ phiếu hoàn thành; NV mua đặt khuôn qua đề xuất mua bổ sung.

-- ===== OD thực tế =====
alter table master.spec_results add column if not exists od_actual_mm numeric(8,3);
alter table master.spec_results add column if not exists od_actual_note text;
alter table master.spec_results add column if not exists od_actual_at timestamptz;
alter table master.spec_results add column if not exists od_actual_by uuid references core.profiles(id);
create index if not exists spec_results_od_actual_by_fkidx on master.spec_results (od_actual_by);

create or replace function app.set_od_actual(p_spec uuid, p_od numeric, p_note text)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_old numeric; v_st text; v_code text;
begin
  if not (core.has_role('KT_TP') or core.has_role('QC') or core.has_role('SX_TP')) then
    raise exception 'Chỉ TP KT/QA, QC, TP SX (hoặc Quản trị) nhập OD thực tế';
  end if;
  select s.status, p.code into v_st, v_code from master.product_specs s join master.products p on p.id = s.product_id where s.id = p_spec;
  if v_st is null then raise exception 'Không tìm thấy spec'; end if;
  if v_st = 'OBSOLETE' then raise exception 'Spec đã hết hiệu lực'; end if;
  if p_od is not null and (p_od <= 0 or p_od > 100) then raise exception 'OD thực tế phải trong khoảng 0–100 mm'; end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'Ghi căn cứ (đo ở lô nào, thiết bị đo…)'; end if;
  select od_actual_mm into v_old from master.spec_results where spec_id = p_spec;
  if not found then raise exception 'Spec chưa có kết quả tính'; end if;
  update master.spec_results set od_actual_mm = p_od, od_actual_note = trim(p_note), od_actual_at = now(), od_actual_by = auth.uid()
   where spec_id = p_spec;
  perform app.admin_log('master.spec_results', p_spec::text, 'OD_ACTUAL',
    jsonb_build_object('product', v_code, 'od_actual_mm', v_old), jsonb_build_object('product', v_code, 'od_actual_mm', p_od, 'note', trim(p_note)));
end $$;
revoke all on function app.set_od_actual(uuid, numeric, text) from public, anon;
grant execute on function app.set_od_actual(uuid, numeric, text) to authenticated;

-- ===== Quy tắc kích thước khuôn =====
create table if not exists master.die_rules (
  kind         text not null,                 -- KB, TS, DS, TC, DC, TX, TV, DV
  mat          text not null default '*',     -- vật liệu vỏ (khuôn ngoài vỏ dùng chung: LSZH / PVC / FR-PVC), '*' = mọi vật liệu
  label        text not null,
  op_code      text not null,
  machine_type text not null,
  part         text not null check (part in ('TIP', 'DIE')),  -- TIP: lỗ ≥ cơ sở + khe hở; DIE: lỗ = cơ sở × hệ số ± dung sai
  basis        text not null check (basis in ('COND', 'CORE', 'LAY', 'UNDER', 'OD')),
  nominal      numeric(6,3),                  -- TIP: khe hở chuẩn
  clr_min      numeric(6,3),                  -- TIP: khe hở nhỏ nhất / lớn nhất được dùng chung
  clr_max      numeric(6,3),
  factor       numeric(8,4),                  -- DIE: lỗ = cơ sở × hệ số
  tol          numeric(6,3),                  -- DIE: dung sai dùng chung (±)
  a_offset     numeric(6,3),                  -- ØA mũi tip = Ød + a_offset
  l_factor     numeric(6,3),                  -- L land die = l_factor × ØD
  head         text not null default 'TT' check (head in ('SI', 'TT', 'BEN', 'XOAN')),
  sort         int not null default 0,
  updated_by   uuid references core.profiles(id),
  updated_at   timestamptz not null default now(),
  primary key (kind, mat)
);
create index if not exists die_rules_updated_by_fkidx on master.die_rules (updated_by);
alter table master.die_rules enable row level security;
revoke all on master.die_rules from anon, authenticated;
grant select on master.die_rules to authenticated;
drop policy if exists die_rules_read on master.die_rules;
create policy die_rules_read on master.die_rules for select to authenticated using (true);

insert into master.die_rules (kind, mat, label, op_code, machine_type, part, basis, nominal, clr_min, clr_max, factor, tol, a_offset, l_factor, head, sort) values
  ('KB', '*',      'Khuôn bện đồng',                       'CD1', 'BUNCHER',     'TIP', 'COND',  0.08, 0.05, 0.15, null,   null, null, null, 'BEN',  1),
  ('TS', '*',      'Khuôn trong cách điện silicone (tip)', 'CD2', 'EXTRUDER_SI', 'TIP', 'COND',  0.05, 0.04, 0.14, null,   null, 0.6,  null, 'SI',   2),
  ('DS', '*',      'Khuôn ngoài cách điện silicone (die)', 'CD2', 'EXTRUDER_SI', 'DIE', 'CORE',  null, null, null, 0.97,   0.05, null, 0.6,  'SI',   3),
  ('TC', '*',      'Khuôn trong cách điện HDPE/PVC (tip)', 'CD2', 'EXTRUDER_TP', 'TIP', 'COND',  0.10, 0.08, 0.20, null,   null, 1.0,  null, 'TT',   4),
  ('DC', '*',      'Khuôn ngoài cách điện HDPE/PVC (die)', 'CD2', 'EXTRUDER_TP', 'DIE', 'CORE',  null, null, null, 1.0085, 0.05, null, 1.5,  'TT',   5),
  ('TX', '*',      'Khuôn máy xoắn',                       'CD3', 'TWISTER',     'TIP', 'LAY',   0.40, 0.20, 0.70, null,   null, null, null, 'XOAN', 6),
  ('TV', '*',      'Khuôn trong vỏ (tip)',                 'CD5', 'EXTRUDER_TP', 'TIP', 'UNDER', 0.40, 0.30, 0.70, null,   null, 1.0,  null, 'TT',   7),
  ('DV', 'LSZH',   'Khuôn ngoài vỏ (die, LSZH/PVC chung)', 'CD5', 'EXTRUDER_TP', 'DIE', 'OD',    null, null, null, 1.0,    0.08, null, 0.5,  'TT',   8),
  ('DV', 'PVC',    'Khuôn ngoài vỏ (die, LSZH/PVC chung)', 'CD5', 'EXTRUDER_TP', 'DIE', 'OD',    null, null, null, 1.01,   0.08, null, 0.6,  'TT',   9),
  ('DV', 'FR-PVC', 'Khuôn ngoài vỏ (die, LSZH/PVC chung)', 'CD5', 'EXTRUDER_TP', 'DIE', 'OD',    null, null, null, 1.01,   0.08, null, 0.6,  'TT',  10)
on conflict (kind, mat) do nothing;

-- Bảng giá (VND/chiếc) theo cấp đường kính lỗ, bảng khuôn nhà máy (1 RMB = 3.850 VND)
create table if not exists master.die_prices (
  head  text not null, part text not null, max_d numeric(6,2) not null, price numeric(14,0) not null,
  primary key (head, part, max_d)
);
alter table master.die_prices enable row level security;
revoke all on master.die_prices from anon, authenticated;
grant select on master.die_prices to authenticated;
drop policy if exists die_prices_read on master.die_prices;
create policy die_prices_read on master.die_prices for select to authenticated using (true);
insert into master.die_prices (head, part, max_d, price) values
  ('TT', 'TIP', 3, 962500), ('TT', 'TIP', 5, 1039500), ('TT', 'TIP', 8, 1155000), ('TT', 'TIP', 9999, 1270500),
  ('TT', 'DIE', 3, 1039500), ('TT', 'DIE', 5, 1116500), ('TT', 'DIE', 8, 1232000), ('TT', 'DIE', 9999, 1347500),
  ('SI', 'TIP', 3, 770000), ('SI', 'TIP', 5, 847000), ('SI', 'TIP', 8, 962500), ('SI', 'TIP', 9999, 1078000),
  ('SI', 'DIE', 3, 847000), ('SI', 'DIE', 5, 924000), ('SI', 'DIE', 8, 1039500), ('SI', 'DIE', 9999, 1155000)
on conflict do nothing;

create or replace function master.die_price(p_kind text, p_size numeric) returns numeric
language sql stable set search_path = pg_catalog, public as $$
  select p.price from master.die_rules r join master.die_prices p on p.head = r.head and p.part = r.part
   where r.kind = p_kind and p.max_d >= p_size order by r.mat, p.max_d limit 1
$$;

-- ===== Danh mục khuôn =====
create table if not exists master.dies (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,                 -- TS-1.25, DV-6.70, KB-2.10, TX-4.90 (bộ thứ hai: thêm "#2")
  kind          text not null,
  size          numeric(6,2) not null check (size > 0),  -- Ød (khuôn trong, bện, xoắn) / ØD (khuôn ngoài)
  a_mm          numeric(6,2),                          -- ØA mũi tip
  l_mm          numeric(6,2),                          -- L land die
  qty           int not null default 1 check (qty >= 0),
  status        text not null default 'NEEDED' check (status in ('NEEDED', 'ORDERED', 'AVAILABLE', 'WORN', 'BROKEN', 'RETIRED')),
  fit_min       numeric(6,3),                          -- TP KT/QA chốt riêng: dùng cho cơ sở (ruột, lõi, OD…) từ … đến …
  fit_max       numeric(6,3),
  price         numeric(14,0),
  life_km       numeric(12,1),                         -- tuổi thọ dự kiến (km) để tính tiền khuôn / km
  km_base       numeric(12,1) not null default 0,      -- km đã chạy trước khi theo dõi trên MES
  in_service_at timestamptz,                           -- bắt đầu tính km từ phiếu hoàn thành
  location      text,
  note          text,
  material_id   uuid references master.materials(id),  -- mã vật tư khi đặt mua
  pr_id         uuid references purchase.purchase_requests(id),
  created_by    uuid references core.profiles(id),
  created_at    timestamptz not null default now(),
  updated_by    uuid references core.profiles(id),
  updated_at    timestamptz not null default now(),
  check (fit_min is null or fit_max is null or fit_min <= fit_max)
);
create index if not exists dies_kind_size on master.dies (kind, size);
create index if not exists dies_material_id_fkidx on master.dies (material_id);
create index if not exists dies_pr_id_fkidx on master.dies (pr_id);
create index if not exists dies_created_by_fkidx on master.dies (created_by);
create index if not exists dies_updated_by_fkidx on master.dies (updated_by);
alter table master.dies enable row level security;
revoke all on master.dies from anon, authenticated;
grant select on master.dies to authenticated;
drop policy if exists dies_read on master.dies;
create policy dies_read on master.dies for select to authenticated
  using ((select core.has_perm('machine', 'view')) or (select core.has_perm('spec', 'view')) or (select core.has_perm('purchase', 'view')));
grant all on master.die_rules, master.die_prices, master.dies to service_role;

create or replace function master.die_can_view() returns boolean language sql stable set search_path = pg_catalog, public as $$
  select core.has_perm('machine', 'view') or core.has_perm('spec', 'view') or core.has_perm('purchase', 'view') or app.kh_can_view()
$$;
create or replace function master.ceil05(x numeric) returns numeric language sql immutable as $$ select ceil(round(x / 0.05, 6)) * 0.05 $$;
create or replace function master.floor05(x numeric) returns numeric language sql immutable as $$ select floor(round(x / 0.05, 6)) * 0.05 $$;

-- Yêu cầu khuôn của một spec: mỗi loại khuôn một dòng (cơ sở, khoảng kích thước dùng được, kích thước đề xuất)
create or replace function master.die_reqs(p_spec uuid)
returns table (spec_id uuid, kind text, label text, op_code text, machine_type text, part text, basis_name text,
               basis numeric, req numeric, lo numeric, hi numeric, suggest numeric, a_mm numeric, l_mm numeric, od_src text, sort int)
language sql stable security definer set search_path = pg_catalog, public as $$
  with s as (
    select s.id, s.cores, coalesce(s.pairs, 0) pairs, s.insulation, s.sheath, coalesce(s.bundle_factor, 1) bf,
           r.bundle_dia_mm cond, r.core_dia_mm core, r.cable_bundle_mm under,
           coalesce(r.od_actual_mm, r.od_mm) od, case when r.od_actual_mm is not null then 'thực tế' else 'tối ưu' end od_src
      from master.product_specs s join master.spec_results r on r.spec_id = s.id where s.id = p_spec
  ), b as (
    select s.id, ru.*, s.od_src,
           case ru.basis when 'COND' then s.cond when 'CORE' then s.core when 'UNDER' then s.under when 'OD' then s.od
                         when 'LAY' then (case when s.pairs > 0 then 2 else s.bf end) * s.core end::numeric bv
      from s join master.die_rules ru on
           (ru.kind = 'KB')
        or (ru.kind in ('TS', 'DS') and s.insulation = 'SIL')
        or (ru.kind in ('TC', 'DC') and coalesce(s.insulation, '') <> 'SIL')
        or (ru.kind = 'TX' and s.cores >= 2)
        or (ru.kind = 'TV' and coalesce(s.sheath, 'Không') not in ('Không', ''))
        or (ru.kind = 'DV' and ru.mat = s.sheath)
  )
  select b.id, b.kind, b.label, b.op_code, b.machine_type, b.part,
         case b.basis when 'COND' then 'Ø ruột dẫn' when 'CORE' then 'Ø lõi cách điện' when 'UNDER' then 'Ø dưới vỏ'
                      when 'OD' then 'OD ' || b.od_src when 'LAY' then 'Ø xoắn' end,
         round(b.bv, 3),
         round(case when b.part = 'TIP' then b.bv + b.nominal else b.bv * b.factor end, 3),
         round(case when b.part = 'TIP' then b.bv + b.clr_min else b.bv * b.factor - b.tol end, 3),
         round(case when b.part = 'TIP' then b.bv + b.clr_max else b.bv * b.factor + b.tol end, 3),
         x.sg,
         case when b.a_offset is not null then x.sg + b.a_offset end,
         case when b.l_factor is not null then round(b.l_factor * x.sg, 1) end,
         case when b.basis = 'OD' then b.od_src end, b.sort
    from b cross join lateral (select case when b.part = 'TIP'
           then least(master.floor05(b.bv + b.clr_max), greatest(master.ceil05(b.bv + b.nominal), master.ceil05(b.bv + b.clr_min)))
           else round(b.bv * b.factor, 2) end sg) x
   where b.bv is not null and b.bv > 0
$$;

-- Khuôn trong danh mục khớp với yêu cầu: TP KT/QA chốt khoảng riêng (fit_min–fit_max theo cơ sở) hoặc kích thước nằm trong khoảng dùng được
create or replace function master.die_fits(d master.dies, k text, basis numeric, lo numeric, hi numeric) returns boolean
language sql immutable as $$
  select d.kind = k and d.status <> 'RETIRED' and
         case when d.fit_min is not null or d.fit_max is not null
              then basis between coalesce(d.fit_min, -1e9) and coalesce(d.fit_max, 1e9)
              else d.size between lo - 1e-6 and hi + 1e-6 end
$$;

create or replace function master.die_status_rank(s text) returns int language sql immutable as $$
  select case s when 'AVAILABLE' then 1 when 'WORN' then 2 when 'ORDERED' then 3 when 'NEEDED' then 4 when 'BROKEN' then 5 else 9 end
$$;

-- Khuôn dùng cho một spec: yêu cầu + khuôn chọn (sẵn có trước, gần kích thước chuẩn nhất)
create or replace function master.die_match(p_spec uuid)
returns table (spec_id uuid, kind text, label text, op_code text, machine_type text, part text, basis_name text, basis numeric,
               req numeric, lo numeric, hi numeric, suggest numeric, a_mm numeric, l_mm numeric, od_src text, sort int,
               die_id uuid, die_code text, die_size numeric, die_status text, die_qty int, ready boolean)
language sql stable security definer set search_path = pg_catalog, public as $$
  select q.*, d.id, d.code, d.size, d.status, d.qty, coalesce(d.status in ('AVAILABLE', 'WORN') and d.qty > 0, false)
    from master.die_reqs(p_spec) q
    left join lateral (
      select d.* from master.dies d where master.die_fits(d, q.kind, q.basis, q.lo, q.hi)
       order by master.die_status_rank(d.status) + case when d.qty > 0 then 0 else 3 end, abs(d.size - q.req), d.code limit 1
    ) d on true
$$;

-- Spec còn dùng: spec hiện hành của mã còn hoạt động + spec trong kế hoạch tháng còn mở
create or replace function master.die_specs()
returns table (spec_id uuid, product_id uuid, product_code text, in_plan boolean, plan_m numeric)
language sql stable security definer set search_path = pg_catalog, public as $$
  with pl as (
    select l.spec_id, sum(l.qty_m) m
      from plan.plan_lines l join plan.production_plans p on p.id = l.plan_id
     where p.status in ('DRAFT', 'PENDING_APPROVAL', 'APPROVED') and l.qty_m > 0
       and (p.period_month is null or p.period_month >= date_trunc('month', (now() at time zone 'Asia/Ho_Chi_Minh'))::date)
     group by l.spec_id
  ), sp as (
    select p.current_spec_id spec_id from master.products p where p.active and p.current_spec_id is not null
    union select spec_id from pl
  )
  select sp.spec_id, s.product_id, p.code, pl.spec_id is not null, coalesce(pl.m, 0)
    from sp join master.product_specs s on s.id = sp.spec_id and s.status <> 'OBSOLETE'
    join master.products p on p.id = s.product_id
    left join pl on pl.spec_id = sp.spec_id
$$;

-- ===== Hàm cho web =====
create or replace function app.spec_dies(p_spec uuid)
returns table (kind text, label text, op_code text, machine_type text, part text, basis_name text, basis numeric, req numeric,
               lo numeric, hi numeric, suggest numeric, a_mm numeric, l_mm numeric, od_src text, sort int,
               die_id uuid, die_code text, die_size numeric, die_status text, die_qty int, ready boolean, price numeric)
language sql stable security definer set search_path = pg_catalog, public as $$
  select m.kind, m.label, m.op_code, m.machine_type, m.part, m.basis_name, m.basis, m.req, m.lo, m.hi, m.suggest, m.a_mm, m.l_mm,
         m.od_src, m.sort, m.die_id, m.die_code, m.die_size, m.die_status, m.die_qty, m.ready,
         case when core.can_see_price() then master.die_price(m.kind, coalesce(m.die_size, m.suggest)) end
    from master.die_match(p_spec) m where master.die_can_view() order by m.sort
$$;

-- Mã chưa có khuôn sẵn (không có khuôn khớp, hoặc khuôn khớp chưa về / hỏng)
create or replace function app.die_gaps()
returns table (product_code text, spec_id uuid, in_plan boolean, plan_m numeric, kind text, label text, op_code text,
               basis_name text, basis numeric, suggest numeric, a_mm numeric, l_mm numeric, die_code text, die_status text, reason text)
language sql stable security definer set search_path = pg_catalog, public as $$
  select x.product_code, x.spec_id, x.in_plan, x.plan_m, m.kind, m.label, m.op_code, m.basis_name, m.basis, m.suggest, m.a_mm, m.l_mm,
         m.die_code, m.die_status,
         case when m.die_id is null then 'Chưa có khuôn'
              when m.die_status = 'NEEDED' then 'Khuôn cần đặt'
              when m.die_status = 'ORDERED' then 'Khuôn đã đặt, chưa về'
              when m.die_status = 'BROKEN' then 'Khuôn hỏng'
              else 'Khuôn chưa có số lượng' end
    from master.die_specs() x cross join lateral master.die_match(x.spec_id) m
   where master.die_can_view() and not m.ready
   order by x.in_plan desc, x.product_code, m.sort
$$;

create or replace function app.die_alarm_count() returns integer
language sql stable security definer set search_path = pg_catalog, public as $$
  select case when master.die_can_view() then (
    select count(distinct x.product_code)::int from master.die_specs() x cross join lateral master.die_match(x.spec_id) m
     where x.in_plan and not m.ready) else 0 end
$$;

-- Danh mục khuôn kèm số mã dùng, km chạy, tiền khuôn/km, OD đo trên chuyền
create or replace function app.die_list()
returns table (id uuid, code text, kind text, label text, size numeric, a_mm numeric, l_mm numeric, qty int, status text,
               fit_min numeric, fit_max numeric, price numeric, life_km numeric, km_run numeric, cost_per_km numeric,
               products int, product_codes text, plan_codes text, location text, note text, pr_no text, in_service_at timestamptz,
               od_note text, updated_at timestamptz)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if not master.die_can_view() then return; end if;
  return query
  with use as (
    select m.die_id, x.product_code, x.product_id, x.in_plan, m.op_code, m.part
      from master.die_specs() x cross join lateral master.die_match(x.spec_id) m where m.die_id is not null
  ), pu as (select distinct u.die_id, u.product_id, u.op_code, u.part from use u
  ), run as (
    -- km chạy: mét phiếu hoàn thành của công đoạn khuôn, mã dùng khuôn, từ ngày đưa khuôn vào dùng
    select d.id die_id, sum(b.qty_m) / 1000 km
      from master.dies d
      join pu u on u.die_id = d.id
      join mfg.work_orders w on w.product_id = u.product_id
      join mfg.bobbin_slips b on b.wo_id = w.id and b.op_code = u.op_code and b.status = 'ACTIVE'
       and (d.in_service_at is null or b.recorded_at >= d.in_service_at)
     group by d.id
  ), od as (
    -- OD đo trên chuyền (10 phiếu gần nhất) so với lỗ khuôn ngoài: lớn hơn quá dung sai → kiểm tra mòn khuôn
    select u.die_id, avg((b.readings->>'od_mm')::numeric) od_avg, count(*) n
      from pu u join mfg.work_orders w on w.product_id = u.product_id
      join lateral (select bs.readings from mfg.bobbin_slips bs where bs.wo_id = w.id and bs.op_code = u.op_code and bs.status = 'ACTIVE'
                      and coalesce(bs.readings->>'od_mm', '') ~ '^[0-9]+(\.[0-9]+)?$' order by bs.recorded_at desc limit 10) b on true
     where u.part = 'DIE'
     group by u.die_id
  )
  select d.id, d.code, d.kind, r.label, d.size, d.a_mm, d.l_mm, d.qty, d.status, d.fit_min, d.fit_max,
         case when core.can_see_price() then d.price end, d.life_km,
         round(d.km_base + coalesce(run.km, 0), 1),
         case when core.can_see_price() and d.life_km > 0 and d.price is not null then round(d.price / d.life_km, 0) end,
         (select count(distinct u.product_code)::int from use u where u.die_id = d.id),
         (select string_agg(distinct u.product_code, ', ') from use u where u.die_id = d.id),
         (select string_agg(distinct u.product_code, ', ') from use u where u.die_id = d.id and u.in_plan),
         d.location, d.note, pr.pr_no, d.in_service_at,
         case when od.n >= 3 and od.od_avg > d.size + coalesce(r.tol, 0.08)
              then format('OD đo trên chuyền %s mm > lỗ khuôn %s mm: kiểm tra mòn khuôn', round(od.od_avg, 2), d.size) end,
         d.updated_at
    from master.dies d
    left join lateral (select ru.label, ru.tol from master.die_rules ru where ru.kind = d.kind order by ru.mat limit 1) r on true
    left join run on run.die_id = d.id
    left join od on od.die_id = d.id
    left join purchase.purchase_requests pr on pr.id = d.pr_id
   order by r.label, d.size, d.code;
end $$;

-- MES đề xuất khuôn cần làm thêm: mọi yêu cầu chưa có khuôn khớp (kể cả khuôn đang đặt) gom theo cách phủ tham lam
-- (khuôn trong: một kích thước phủ mọi cơ sở trong khoảng khe hở; khuôn ngoài: các lỗ chuẩn cách nhau ≤ 2 × dung sai)
create or replace function master.die_propose_raw()
returns table (kind text, label text, size numeric, a_mm numeric, l_mm numeric, price numeric, n_codes int, codes text,
               in_plan boolean, basis_min numeric, basis_max numeric)
language plpgsql security definer set search_path = pg_catalog, public as $$
declare k record; r record; x0 numeric; tmax numeric; v_size numeric; v_l numeric; v_xmax numeric;
begin
  create temp table if not exists _dp (kind text, part text, mat text, code text, in_plan boolean, basis numeric, req numeric) on commit drop;
  delete from _dp where true;
  insert into _dp
  select m.kind, m.part, s.sheath, x.product_code, x.in_plan, m.basis, m.req
    from master.die_specs() x join master.product_specs s on s.id = x.spec_id
    cross join lateral master.die_match(x.spec_id) m where m.die_id is null;
  for k in select distinct d.kind, d.part from _dp d loop
    select * into r from master.die_rules ru where ru.kind = k.kind order by ru.mat limit 1;
    loop
      if k.part = 'TIP' then
        select min(d.basis) into x0 from _dp d where d.kind = k.kind;
        exit when x0 is null;
        tmax := master.floor05(x0 + r.clr_max);
        select max(d.basis) into v_xmax from _dp d where d.kind = k.kind and tmax - d.basis >= r.clr_min - 1e-9;
        v_size := least(tmax, greatest(master.ceil05(v_xmax + r.nominal), master.ceil05(v_xmax + r.clr_min)));
        return query
          select k.kind, r.label, v_size, case when r.a_offset is not null then v_size + r.a_offset end, null::numeric,
                 master.die_price(k.kind, v_size),
                 count(distinct d.code)::int, string_agg(distinct d.code, ', '), bool_or(d.in_plan), min(d.basis), max(d.basis)
            from _dp d where d.kind = k.kind and d.basis <= tmax - r.clr_min + 1e-9 and d.basis >= x0 - 1e-9;
        delete from _dp d where d.kind = k.kind and d.basis <= tmax - r.clr_min + 1e-9 and d.basis >= x0 - 1e-9;
      else
        select min(d.req) into x0 from _dp d where d.kind = k.kind;
        exit when x0 is null;
        select round((min(d.req) + max(d.req)) / 2, 2) into v_size from _dp d where d.kind = k.kind and d.req <= x0 + 2 * r.tol + 1e-9;
        -- L theo vật liệu nhiều mã nhất trong nhóm (khuôn vỏ LSZH / PVC dùng chung)
        select round(ru.l_factor * v_size, 1) into v_l from _dp d join master.die_rules ru on ru.kind = d.kind and ru.mat in (d.mat, '*')
         where d.kind = k.kind and d.req <= x0 + 2 * r.tol + 1e-9 group by ru.l_factor order by count(*) desc, ru.l_factor limit 1;
        return query
          select k.kind, r.label, v_size, null::numeric, v_l,
                 master.die_price(k.kind, v_size),
                 count(distinct d.code)::int, string_agg(distinct d.code, ', '), bool_or(d.in_plan), min(d.basis), max(d.basis)
            from _dp d where d.kind = k.kind and d.req <= x0 + 2 * r.tol + 1e-9;
        delete from _dp d where d.kind = k.kind and d.req <= x0 + 2 * r.tol + 1e-9;
      end if;
    end loop;
  end loop;
end $$;

create or replace function app.die_propose()
returns table (kind text, label text, size numeric, a_mm numeric, l_mm numeric, price numeric, n_codes int, codes text,
               in_plan boolean, basis_min numeric, basis_max numeric)
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if not master.die_can_view() then return; end if;
  return query select p.kind, p.label, p.size, p.a_mm, p.l_mm, case when core.can_see_price() then p.price end,
                      p.n_codes, p.codes, p.in_plan, p.basis_min, p.basis_max
                 from master.die_propose_raw() p order by p.in_plan desc, p.kind, p.size;
end $$;

-- Thêm khuôn MES đề xuất vào danh mục (Cần đặt); p_kinds null = mọi loại
create or replace function master.die_add_proposed(p_kinds text[]) returns int
language plpgsql security definer set search_path = pg_catalog, public as $$
declare p record; n int := 0; v_code text;
begin
  for p in select * from master.die_propose_raw() x where p_kinds is null or x.kind = any(p_kinds) loop
    v_code := p.kind || '-' || to_char(p.size, 'FM990.00');
    while exists (select 1 from master.dies where code = v_code) loop v_code := v_code || '#'; end loop;
    insert into master.dies (code, kind, size, a_mm, l_mm, qty, status, price, note, created_by, updated_by)
    values (v_code, p.kind, p.size, p.a_mm, p.l_mm, 1, 'NEEDED', p.price,
            'MES đề xuất ' || to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'DD/MM/YYYY') || ' cho: ' || left(p.codes, 400), auth.uid(), auth.uid());
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function master.die_can_edit() returns boolean language sql stable set search_path = pg_catalog, public as $$
  select core.has_role('KT_TP')
$$;

-- Thêm toàn bộ khuôn MES đề xuất vào danh mục (trạng thái Cần đặt)
create or replace function app.die_add_proposals() returns int
language plpgsql security definer set search_path = pg_catalog, public as $$
declare n int;
begin
  if not master.die_can_edit() then raise exception 'Chỉ TP KT/QA (hoặc Quản trị) thêm khuôn vào danh mục'; end if;
  n := master.die_add_proposed(null);
  if n > 0 then perform app.admin_log('master.dies', null, 'DIE_PROPOSE', null, jsonb_build_object('added', n)); end if;
  return n;
end $$;

-- Thêm / sửa một khuôn (TP KT/QA): code, kind, size, a_mm, l_mm, qty, fit_min, fit_max, price, life_km, km_base, location, note
create or replace function app.die_save(p_id uuid, p jsonb, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid := p_id; v_old jsonb; v_kind text; v_size numeric; v_code text;
begin
  if not master.die_can_edit() then raise exception 'Chỉ TP KT/QA (hoặc Quản trị) sửa danh mục khuôn'; end if;
  v_kind := upper(trim(p->>'kind'));
  v_size := nullif(p->>'size', '')::numeric;
  if not exists (select 1 from master.die_rules where kind = v_kind) then raise exception 'Loại khuôn không hợp lệ'; end if;
  if coalesce(v_size, 0) <= 0 or v_size > 60 then raise exception 'Kích thước lỗ khuôn phải trong khoảng 0–60 mm'; end if;
  v_code := upper(coalesce(nullif(trim(p->>'code'), ''), v_kind || '-' || to_char(v_size, 'FM990.00')));
  if v_id is not null then
    select to_jsonb(d) into v_old from master.dies d where id = v_id;
    if v_old is null then raise exception 'Không tìm thấy khuôn'; end if;
    if coalesce(trim(p_reason), '') = '' then raise exception 'Ghi lý do sửa'; end if;
  end if;
  if exists (select 1 from master.dies where code = v_code and id is distinct from v_id) then raise exception 'Mã khuôn % đã có', v_code; end if;
  if v_id is null then
    insert into master.dies (code, kind, size, status, created_by) values (v_code, v_kind, v_size, 'NEEDED', auth.uid()) returning id into v_id;
  end if;
  update master.dies set code = v_code, kind = v_kind, size = v_size,
         a_mm = nullif(p->>'a_mm', '')::numeric, l_mm = nullif(p->>'l_mm', '')::numeric,
         qty = coalesce(nullif(p->>'qty', '')::int, qty),
         fit_min = nullif(p->>'fit_min', '')::numeric, fit_max = nullif(p->>'fit_max', '')::numeric,
         price = coalesce(nullif(p->>'price', '')::numeric, master.die_price(v_kind, v_size)),
         life_km = nullif(p->>'life_km', '')::numeric, km_base = coalesce(nullif(p->>'km_base', '')::numeric, 0),
         location = nullif(trim(p->>'location'), ''), note = nullif(trim(p->>'note'), ''),
         updated_by = auth.uid(), updated_at = now()
   where id = v_id;
  perform app.admin_log('master.dies', v_id::text, case when v_old is null then 'DIE_ADD' else 'DIE_EDIT' end,
    v_old, (select to_jsonb(d) || jsonb_build_object('reason', p_reason) from master.dies d where id = v_id));
  return v_id;
end $$;

-- Đổi trạng thái: nhận khuôn (AVAILABLE), mòn, hỏng, loại bỏ, cần đặt lại (TP KT/QA, TP SX)
create or replace function app.die_set_status(p_id uuid, p_status text, p_note text, p_qty int default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare d master.dies;
begin
  if not (core.has_role('KT_TP') or core.has_role('SX_TP')) then raise exception 'Chỉ TP KT/QA, TP SX (hoặc Quản trị) đổi trạng thái khuôn'; end if;
  select * into d from master.dies where id = p_id for update;
  if not found then raise exception 'Không tìm thấy khuôn'; end if;
  if p_status not in ('NEEDED', 'ORDERED', 'AVAILABLE', 'WORN', 'BROKEN', 'RETIRED') then raise exception 'Trạng thái không hợp lệ'; end if;
  if p_status in ('WORN', 'BROKEN', 'RETIRED', 'NEEDED') and coalesce(trim(p_note), '') = '' then raise exception 'Ghi lý do'; end if;
  if p_qty is not null and p_qty < 0 then raise exception 'Số lượng không âm'; end if;
  update master.dies set status = p_status, qty = coalesce(p_qty, qty),
         in_service_at = case when p_status = 'AVAILABLE' and in_service_at is null then now() else in_service_at end,
         note = case when coalesce(trim(p_note), '') = '' then note else trim(p_note) end,
         updated_by = auth.uid(), updated_at = now()
   where id = p_id;
  perform app.admin_log('master.dies', p_id::text, 'DIE_STATUS', jsonb_build_object('code', d.code, 'status', d.status, 'qty', d.qty),
    jsonb_build_object('code', d.code, 'status', p_status, 'qty', coalesce(p_qty, d.qty), 'note', p_note));
  if p_status in ('WORN', 'BROKEN') then
    perform wf.notify_role(r, 'Khuôn ' || d.code || case when p_status = 'WORN' then ' mòn' else ' hỏng' end,
      coalesce(trim(p_note), '') || '. Xem mã dùng khuôn ở Quản lý máy → Khuôn; cần thì đặt khuôn thay.', '/may/khuon')
      from unnest(array['KT_TP', 'SX_TP', 'MUA_TP']) r;
  end if;
end $$;

-- NV mua / TP Mua đặt khuôn: tạo mã vật tư công cụ dụng cụ (nếu chưa có) + đề xuất mua công cụ dụng cụ (CCDC), khuôn chuyển "Đã đặt"
create or replace function app.die_order(p_ids uuid[], p_need date, p_note text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare d record; v_lines jsonb := '[]'; v_mat uuid; v_mcode text; v_pr uuid; n int := 0;
begin
  if not (core.has_role('MUA_NV') or core.has_role('MUA_TP')) then raise exception 'NV mua hoặc TP Mua đặt khuôn'; end if;
  if p_need is null then raise exception 'Chọn ngày cần khuôn'; end if;
  for d in select * from master.dies where id = any(p_ids) for update loop
    if d.status not in ('NEEDED', 'WORN', 'BROKEN') then raise exception 'Khuôn % đang ở trạng thái %, không đặt lại', d.code, d.status; end if;
    v_mcode := 'KH-' || d.code;
    select id into v_mat from master.materials where code = v_mcode;
    if v_mat is null then
      insert into master.materials (code, name, group_code, purchase_spec, uom, loss_rate, has_expiry, requires_coa, is_scrap, safety_stock, active, data_note)
      values (v_mcode, (select label from master.die_rules where kind = d.kind order by mat limit 1) || ' ' || to_char(d.size, 'FM990.00') || ' mm',
              'TOOLING',
              concat_ws(', ', case when d.kind in ('TS', 'TC', 'TV', 'KB', 'TX') then 'Ød ' || to_char(d.size, 'FM990.00') else 'ØD ' || to_char(d.size, 'FM990.00') end,
                        case when d.a_mm is not null then 'ØA ' || to_char(d.a_mm, 'FM990.00') end,
                        case when d.l_mm is not null then 'L ' || to_char(d.l_mm, 'FM990.0') end,
                        case when d.kind in ('TS', 'DS') then 'SUS304, đầu máy silicone' when d.kind in ('TC', 'DC', 'TV', 'DV') then 'SUS304 chèn hợp kim vonfram' end,
                        'mm, các kích thước khác theo bản vẽ gốc'),
              'cái', 0, false, false, false, 0, true, 'Tạo từ danh mục khuôn ' || d.code)
      returning id into v_mat;
    end if;
    update master.dies set material_id = v_mat where id = d.id;
    v_lines := v_lines || jsonb_build_object('material_code', v_mcode, 'qty', greatest(d.qty, 1));
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Chọn khuôn cần đặt'; end if;
  v_pr := app.create_pr(p_need, coalesce(nullif(trim(p_note), ''), 'Đặt khuôn theo danh mục khuôn'), v_lines, 'CCDC');
  update master.dies set status = 'ORDERED', pr_id = v_pr, updated_by = auth.uid(), updated_at = now() where id = any(p_ids);
  perform app.admin_log('master.dies', v_pr::text, 'DIE_ORDER', null, jsonb_build_object('dies', p_ids, 'pr', v_pr));
  return v_pr;
end $$;

-- Sửa quy tắc kích thước (TP KT/QA): danh sách [{kind, mat, nominal, clr_min, clr_max, factor, tol, a_offset, l_factor}]
create or replace function app.die_rules_save(p jsonb, p_reason text) returns int
language plpgsql security definer set search_path = pg_catalog, public as $$
declare x jsonb; n int := 0; v_old jsonb;
begin
  if not master.die_can_edit() then raise exception 'Chỉ TP KT/QA (hoặc Quản trị) sửa quy tắc khuôn'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Ghi lý do sửa quy tắc'; end if;
  select jsonb_agg(to_jsonb(r)) into v_old from master.die_rules r;
  for x in select * from jsonb_array_elements(coalesce(p, '[]')) loop
    update master.die_rules r set
      nominal = coalesce(nullif(x->>'nominal', '')::numeric, r.nominal), clr_min = coalesce(nullif(x->>'clr_min', '')::numeric, r.clr_min),
      clr_max = coalesce(nullif(x->>'clr_max', '')::numeric, r.clr_max), factor = coalesce(nullif(x->>'factor', '')::numeric, r.factor),
      tol = coalesce(nullif(x->>'tol', '')::numeric, r.tol), a_offset = coalesce(nullif(x->>'a_offset', '')::numeric, r.a_offset),
      l_factor = coalesce(nullif(x->>'l_factor', '')::numeric, r.l_factor), updated_by = auth.uid(), updated_at = now()
     where r.kind = x->>'kind' and r.mat = coalesce(x->>'mat', '*');
    if found then n := n + 1; end if;
    if exists (select 1 from master.die_rules r where r.kind = x->>'kind' and r.mat = coalesce(x->>'mat', '*')
               and ((r.part = 'TIP' and (r.clr_min < 0 or r.clr_min > r.nominal or r.nominal > r.clr_max or r.clr_max > 3))
                 or (r.part = 'DIE' and (r.factor <= 0.5 or r.factor > 1.5 or r.tol < 0 or r.tol > 1)))) then
      raise exception 'Quy tắc % không hợp lệ: khe hở nhỏ nhất ≤ chuẩn ≤ lớn nhất; hệ số 0,5–1,5; dung sai 0–1 mm', x->>'kind';
    end if;
  end loop;
  perform app.admin_log('master.die_rules', null, 'DIE_RULES', jsonb_build_object('rules', v_old),
    jsonb_build_object('rules', (select jsonb_agg(to_jsonb(r)) from master.die_rules r), 'reason', p_reason));
  return n;
end $$;

-- Bộ xếp lịch: khuôn từng dòng kế hoạch theo công đoạn + số bộ khuôn sẵn có
create or replace function app.kh_dies(p_plan uuid) returns jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
  select case when app.kh_can_view() or core.has_perm('machine', 'view') then jsonb_build_object(
    'lines', coalesce((
      select jsonb_object_agg(x.id, x.ops) from (
        select l.id, jsonb_object_agg(o.op_code, o.codes) ops
          from plan.plan_lines l
          cross join lateral (select m.op_code, jsonb_agg(m.die_code order by m.sort) codes
                                from master.die_match(l.spec_id) m where m.die_code is not null group by m.op_code) o
         where l.plan_id = p_plan group by l.id) x), '{}'::jsonb),
    'qty', coalesce((select jsonb_object_agg(code, qty) from master.dies where status in ('AVAILABLE', 'WORN') and qty > 0), '{}'::jsonb))
  else '{}'::jsonb end
$$;

-- Lệnh SX ngày: mã có việc trong ngày mà công đoạn đó chưa có khuôn sẵn
create or replace function app.die_day_check(p_plan uuid, p_codes text[])
returns table (product_code text, op_code text, label text, suggest numeric, die_code text, reason text)
language sql stable security definer set search_path = pg_catalog, public as $$
  select p.code, m.op_code, m.label, m.suggest, m.die_code,
         case when m.die_id is null then 'chưa có khuôn' when m.die_status = 'ORDERED' then 'khuôn đã đặt, chưa về'
              when m.die_status = 'NEEDED' then 'khuôn cần đặt' else 'khuôn hỏng / chưa có số lượng' end
    from plan.plan_lines l join master.products p on p.id = l.product_id
    cross join lateral master.die_match(l.spec_id) m
   where (app.kh_can_view() or core.has_perm('machine', 'view')) and l.plan_id = p_plan and p.code = any(p_codes) and not m.ready
   order by p.code, m.sort
$$;

-- Cảnh báo hằng ngày: mã trong kế hoạch tháng chưa có khuôn sẵn → TP KT/QA + TP Mua (mỗi mã một lần / tuần)
create or replace function master.die_alerts() returns int
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r record; n int := 0; v_week text := to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'IYYY-IW');
begin
  for r in
    select x.product_id, x.product_code, string_agg(m.label || ' ' || coalesce(m.die_code, '(MES đề xuất ' || to_char(m.suggest, 'FM990.00') || ' mm)'), '; ' order by m.sort) need
      from master.die_specs() x cross join lateral master.die_match(x.spec_id) m
     where x.in_plan and not m.ready group by x.product_id, x.product_code
  loop
    continue when exists (select 1 from inv.alert_log where kind = 'DIE' and ref_id = r.product_id and period_key = v_week);
    insert into inv.alert_log (kind, ref_id, period_key) values ('DIE', r.product_id, v_week);
    perform wf.notify_role(x, 'Thiếu khuôn: ' || r.product_code, 'Mã trong kế hoạch tháng chưa có khuôn sẵn: ' || left(r.need, 400), '/may/khuon?tab=thieu')
      from unnest(array['KT_TP', 'MUA_TP']) x;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function master.die_alerts() from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'bmt_die_alert';
    perform cron.schedule('bmt_die_alert', '10 1 * * *', 'select master.die_alerts()');  -- 08:10 giờ VN
  end if;
end $$;

-- Quyền gọi
do $$ declare f text; begin
  foreach f in array array[
    'master.die_price(text, numeric)', 'master.die_can_view()', 'master.die_can_edit()', 'master.ceil05(numeric)', 'master.floor05(numeric)',
    'master.die_reqs(uuid)', 'master.die_fits(master.dies, text, numeric, numeric, numeric)', 'master.die_status_rank(text)',
    'master.die_match(uuid)', 'master.die_specs()', 'master.die_propose_raw()', 'master.die_add_proposed(text[])'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array[
    'app.spec_dies(uuid)', 'app.die_gaps()', 'app.die_alarm_count()', 'app.die_list()', 'app.die_propose()', 'app.die_add_proposals()',
    'app.die_save(uuid, jsonb, text)', 'app.die_set_status(uuid, text, text, integer)', 'app.die_order(uuid[], date, text)',
    'app.die_rules_save(jsonb, text)', 'app.kh_dies(uuid)', 'app.die_day_check(uuid, text[])'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
-- hàm nội bộ đọc dữ liệu rộng: chỉ hàm app.* gọi
revoke execute on function master.die_reqs(uuid), master.die_match(uuid), master.die_specs(), master.die_propose_raw(),
  master.die_add_proposed(text[]) from authenticated;

-- Phút đổi máy: đổi mã cùng khuôn vỏ chỉ chỉnh in (lịch máy gom lô dùng chung khuôn vỏ); TP KT/QA chỉnh số phút ở Tham số xếp lịch
insert into master.changeover_rules (code, op_code, label, minutes, sort)
select 'SH_PRINT', 'CD5', 'Đổi mã cùng khuôn vỏ (chỉnh in)', coalesce((select minutes from master.changeover_rules where code = 'SH_COLOR'), 20), 10
where not exists (select 1 from master.changeover_rules where code = 'SH_PRINT');

-- Số đếm menu: thêm Alarm thiếu khuôn
create or replace function app.menu_counts() returns jsonb
language plpgsql stable set search_path = pg_catalog, public as $$
declare
  v_turn bigint; v_unread bigint; v_maint bigint; v_qc bigint; v_safety int; v_po bigint; v_alarm int; v_die int;
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
  -- mã trong kế hoạch tháng chưa có khuôn sẵn (hàm tự kiểm quyền)
  begin v_die := app.die_alarm_count(); exception when others then v_die := null; end;
  return jsonb_build_object('my_turn', v_turn, 'unread', v_unread, 'maint_overdue', v_maint, 'qc_wait', v_qc,
                            'safety_below', v_safety, 'po_draft', v_po, 'param_alarm', v_alarm, 'die_alarm', v_die);
end $$;
revoke all on function app.menu_counts() from public, anon;
grant execute on function app.menu_counts() to authenticated;

-- Mục menu Khuôn (Quản lý máy): vai trò như Tốc độ sản xuất + mua hàng
insert into core.pages (key, path, label, grp, sort)
select 'may-khuon', '/may/khuon', 'Khuôn (đùn, bện, xoắn)', 'Quản lý máy', coalesce((select sort from core.pages where key = 'may'), 60) + 1
where not exists (select 1 from core.pages where key = 'may-khuon');
insert into core.role_pages (role_code, page_key)
select role_code, 'may-khuon' from core.role_pages where page_key = 'may-toc-do'
on conflict do nothing;
insert into core.role_pages (role_code, page_key)
select r, 'may-khuon' from unnest(array['MUA_TP', 'MUA_NV', 'QC']) r where exists (select 1 from core.roles where code = r)
on conflict do nothing;

-- ===== Nạp danh mục ban đầu =====
-- Khuôn đã có ở nhà máy (bảng khuôn nhà máy): khuôn bện 1,35; 1,60; khuôn máy xoắn 4,90; 5,85 – mỗi loại 1 cái
insert into master.dies (code, kind, size, qty, status, in_service_at, note)
select v.code, v.kind, v.size, 1, 'AVAILABLE', now(), 'Có sẵn tại nhà máy (bảng khuôn nhà máy 19/11/2026)'
from (values ('KB-1.35', 'KB', 1.35), ('KB-1.60', 'KB', 1.60), ('TX-4.90', 'TX', 4.90), ('TX-5.85', 'TX', 5.85)) v(code, kind, size)
where not exists (select 1 from master.dies d where d.code = v.code);
-- Anh Bình chốt: gộp KB-1,95 và KB-2,05 thành một khuôn bện 2,10 dùng cho ruột Ø1,80–2,00 mm (AWG14, 2,5 mm²)
insert into master.dies (code, kind, size, qty, status, fit_min, fit_max, note)
select 'KB-2.10', 'KB', 2.10, 1, 'NEEDED', 1.80, 2.00, 'Anh Bình chốt 19/11/2026: gộp KB-1,95 và KB-2,05, dùng cho ruột Ø1,80–2,00 mm'
where not exists (select 1 from master.dies where code = 'KB-2.10');
-- Còn lại: khuôn MES đề xuất theo quy tắc (Cần đặt)
do $$ declare n int; begin
  n := master.die_add_proposed(null);
  raise notice 'Danh mục khuôn: thêm % khuôn MES đề xuất (Cần đặt)', n;
end $$;
