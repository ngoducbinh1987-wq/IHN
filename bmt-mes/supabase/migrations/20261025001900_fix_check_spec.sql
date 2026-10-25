-- Sửa master.check_spec: nối chuỗi hằng vào mảng text[] phải ép kiểu ::text,
-- nếu không Postgres hiểu chuỗi là literal mảng và báo lỗi "malformed array literal".

create or replace function master.check_spec(p_spec uuid) returns text[]
language plpgsql stable security definer set search_path = master, core, public as $$
declare s master.product_specs; r master.spec_results; g master.product_groups; msgs text[] := '{}';
begin
  select * into s from master.product_specs where id = p_spec;
  select * into r from master.spec_results where spec_id = p_spec;
  select pg.* into g from master.products p join master.product_groups pg on pg.code = p.group_code where p.id = s.product_id;
  if r.spec_id is null then return array['Chưa tính định mức']; end if;
  if r.rdc_limit is not null and r.rdc_calc > r.rdc_limit
     and not (r.pilot_rdc is not null and r.pilot_rdc <= r.rdc_limit)
     and coalesce(s.rdc_deviation_note, '') = '' then
    msgs := msgs || format('Rdc tính %s > giới hạn %s Ω/km: cần kết quả pilot đạt hoặc phiếu chấp nhận sai lệch', round(r.rdc_calc, 3), r.rdc_limit);
  end if;
  if r.rdc_limit is null then msgs := msgs || 'Chưa có giới hạn Rdc (AWG): QA nhập giới hạn hoặc kết quả đo'::text; end if;
  if r.total_kgkm * coalesce(s.m_per_pack, 0) / 1000 > master.param(s.param_set_id, 'maxPack') then
    msgs := msgs || 'Kiện quá tải: giảm m/kiện'::text;
  end if;
  if s.wire_count > 50 then msgs := msgs || 'Xác nhận quy trình bện nhiều cấp'::text; end if;
  if s.drain_mat = 'Không' and not (s.brand = 'KAVIX' and s.insulation = 'SIL') then
    msgs := msgs || 'Drain Không chỉ cho FR KAVIX'::text;
  end if;
  if s.cores = 1 and s.sheath <> 'Không' then msgs := msgs || 'Dây 1 lõi không có vỏ'::text; end if;
  if s.cores > 1 and s.sheath = 'Không' then msgs := msgs || 'Cáp nhiều lõi phải có vỏ'::text; end if;
  if g.allowed_brands is not null and not (s.brand = any(g.allowed_brands)) then
    msgs := msgs || format('Nhóm %s chỉ cho thương hiệu %s', g.code, array_to_string(g.allowed_brands, ', '));
  end if;
  if g.allowed_sheaths is not null and not (s.sheath = any(g.allowed_sheaths)) then
    msgs := msgs || format('Nhóm %s chỉ cho vỏ %s', g.code, array_to_string(g.allowed_sheaths, ', '));
  end if;
  return msgs;
end $$;

