-- Kiểm thử migration 20261026006600: tên (Quy cách) sản phẩm theo quy tắc, MES tự đặt. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
begin;
create temp table r (n serial, msg text);
create temp table t (k text primary key, v uuid);
create function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_msg; end if;
  insert into r(msg) values (p_msg);
end $$;
create function pg_temp.name_of(p_code text) returns text language sql as $$ select description from master.products where code = p_code $$;

select pg_temp.ok(pg_temp.name_of('CFR-2C-0P75') = '2×0.75 mm² SI/vỏ LSZH, không shield', 'CFR-2C-0P75: 2×0.75 mm² SI/vỏ LSZH, không shield');
select pg_temp.ok(pg_temp.name_of('SFR-2P-1') = '2P×2×1 mm² SI/vỏ LSZH, shield AL/PET + drain', 'SFR-2P-1: 2P×2×1 mm² SI/vỏ LSZH, shield AL/PET + drain');
select pg_temp.ok(pg_temp.name_of('CTL-1P-A14') = '1P×2×AWG14 HDPE/vỏ PVC, shield AL/PET + drain', 'CTL-1P-A14: 1P×2×AWG14 HDPE/vỏ PVC, shield AL/PET + drain');
select pg_temp.ok(pg_temp.name_of('PVC-1C-1') = '1×1 mm² PVC/không vỏ, không shield', 'PVC-1C-1: 1×1 mm² PVC/không vỏ, không shield');
select pg_temp.ok(not exists (select 1 from master.products where current_spec_id is not null and description is distinct from master.spec_name(current_spec_id)),
  'Mọi mã có spec hiện hành: tên đúng quy tắc');
select pg_temp.ok(not exists (select 1 from master.products where current_spec_id is not null
                               and description !~ '^[0-9]+(P×2)?×(AWG[0-9]+|[0-9.]+ mm²) (SI|HDPE|PVC)/(vỏ [A-Z-]+|không vỏ), (không shield|shield AL/PET( \+ drain)?)$'),
  'Mọi tên có tiết diện, số lõi/cặp, cách điện, vỏ, chống nhiễu');
-- Gõ tay tên khác: MES đặt lại theo spec
update master.products set description = 'Tên gõ tay' where code = 'PFR-2C-1';
select pg_temp.ok(pg_temp.name_of('PFR-2C-1') = '2×1 mm² SI/vỏ FR-PVC, không shield', 'Gõ tay tên khác: MES đặt lại theo quy tắc');
-- Sửa thông số spec hiện hành (bật shield): tên đổi theo
select set_config('bmt.admin_spec_edit', 'on', true);
update master.product_specs s set shield = true, drain_wires = 7 from master.products p where p.current_spec_id = s.id and p.code = 'PFR-2C-1';
select pg_temp.ok(pg_temp.name_of('PFR-2C-1') = '2×1 mm² SI/vỏ FR-PVC, shield AL/PET + drain', 'Sửa spec hiện hành (thêm shield): tên tự đổi');
select pg_temp.ok(not has_function_privilege('anon', 'master.spec_name(uuid)', 'execute'), 'anon không gọi master.spec_name');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
rollback;
