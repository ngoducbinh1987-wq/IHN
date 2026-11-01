-- Anh Bình 01/11/2026: đặt lại toàn bộ tên (Quy cách) sản phẩm theo một quy tắc, ví dụ "2×0.75 mm² SI/vỏ LSZH, không shield".
-- Tên phải có: tiết diện + số lõi (hoặc số cặp), cách điện bên trong, loại vỏ, chống nhiễu hay không.
--   * Số lõi:  "2×0.75 mm²"; cáp xoắn cặp (mã có đoạn -nP-): "2P×2×0.75 mm²"; lõi AWG: "1P×2×AWG18".
--   * Cách điện: SIL → SI; HDPE, PVC giữ nguyên.
--   * Vỏ: "vỏ LSZH", "vỏ FR-PVC", "vỏ PVC"; không có vỏ: "không vỏ".
--   * Chống nhiễu: "không shield" hoặc "shield AL/PET + drain" (có dây drain) / "shield AL/PET".
-- MES tự đặt tên theo spec hiện hành của mã (master.spec_name) mỗi khi spec hiện hành đổi hoặc được sửa; không gõ tay nữa.

create or replace function master.spec_name(p_spec uuid) returns text
language sql stable security definer set search_path = pg_catalog, public as $$
  select concat(
           case when p.code ~ '-[0-9]+P-' and s.pairs > 0 then s.pairs || 'P×2×' else s.cores || '×' end,
           case when s.core_code ~ '^A[0-9]+$' then 'AWG' || substr(s.core_code, 2)
                else coalesce(trim_scale(c.nominal_mm2)::text, s.core_code) || ' mm²' end,
           ' ',
           case s.insulation when 'SIL' then 'SI' else coalesce(nullif(s.insulation, ''), '?') end,
           '/',
           case when coalesce(nullif(trim(s.sheath), ''), 'Không') in ('Không', 'KHONG', 'NONE') then 'không vỏ' else 'vỏ ' || s.sheath end,
           ', ',
           case when not coalesce(s.shield, false) then 'không shield'
                when coalesce(s.drain_wires, 0) > 0 then 'shield AL/PET + drain'
                else 'shield AL/PET' end)
    from master.product_specs s join master.products p on p.id = s.product_id
    left join master.core_types c on c.code = s.core_code and c.set_id = s.param_set_id
   where s.id = p_spec
$$;
revoke all on function master.spec_name(uuid) from public, anon;
grant execute on function master.spec_name(uuid) to authenticated;

-- Mã: đặt tên theo spec hiện hành (ghi đè tên gõ tay)
create or replace function master.products_auto_name() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v text;
begin
  if new.current_spec_id is not null then
    v := master.spec_name(new.current_spec_id);
    if v is not null then new.description := v; end if;
  end if;
  return new;
end $$;
revoke all on function master.products_auto_name() from public, anon, authenticated;
drop trigger if exists products_auto_name on master.products;
create trigger products_auto_name before insert or update on master.products
  for each row execute function master.products_auto_name();

-- Spec hiện hành sửa thông số (số lõi, cách điện, vỏ, shield…) → đổi tên mã
create or replace function master.specs_auto_name() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  update master.products p set description = master.spec_name(new.id)
   where p.current_spec_id = new.id and p.description is distinct from master.spec_name(new.id);
  return null;
end $$;
revoke all on function master.specs_auto_name() from public, anon, authenticated;
drop trigger if exists specs_auto_name on master.product_specs;
create trigger specs_auto_name after insert or update of cores, pairs, core_code, insulation, sheath, shield, drain_wires, param_set_id
  on master.product_specs for each row execute function master.specs_auto_name();

-- Đặt lại tên mọi mã
update master.products set description = master.spec_name(current_spec_id)
 where current_spec_id is not null and description is distinct from master.spec_name(current_spec_id);
