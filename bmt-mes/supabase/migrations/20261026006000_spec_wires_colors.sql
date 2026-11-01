-- Thông số spec theo từng lớp (anh Bình yêu cầu 01/11/2026):
--  (2) ruột dẫn bện từ 1–4 loại sợi khác đường kính: master.product_specs.wire_mix = [{"n": số sợi, "d": đường kính mm}, …];
--      wire_count = tổng số sợi, wire_dia_mm = đường kính tương đương sqrt(Σ n·d² / Σ n) để master.calc_spec giữ nguyên công thức
--      (tiết diện = wire_count·π·d²/4 = Σ n·π·d²/4, đúng tuyệt đối).
--  (3) màu cách điện từng lõi: master.product_specs.core_colors text[] (vị trí i = lõi i); insulation_colors = các màu nối " + ".
-- Hàm sửa: app.update_spec_draft nhận thêm p.wire_mix (mảng), p.core_colors (mảng) qua master.set_spec_layers.

alter table master.product_specs add column if not exists wire_mix jsonb;
alter table master.product_specs add column if not exists core_colors text[];

-- Dữ liệu cũ: một loại sợi
update master.product_specs set wire_mix = jsonb_build_array(jsonb_build_object('n', wire_count, 'd', wire_dia_mm))
 where wire_mix is null;

create or replace function master.set_spec_layers(p_spec uuid, p jsonb) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_mix jsonb := '[]'; e jsonb; v_n numeric; v_d numeric; v_sn numeric := 0; v_snd2 numeric := 0;
        v_cores int; v_colors text[]; i int;
begin
  if jsonb_typeof(p->'wire_mix') = 'array' then
    for e in select x from jsonb_array_elements(p->'wire_mix') x loop
      v_n := nullif(e->>'n', '')::numeric; v_d := nullif(e->>'d', '')::numeric;
      if v_n is null and v_d is null then continue; end if;
      if v_n is null or v_n < 1 or v_n <> trunc(v_n) then raise exception 'Số sợi phải là số nguyên ≥ 1'; end if;
      if v_d is null or v_d <= 0 or v_d > 5 then raise exception 'Đường kính sợi phải lớn hơn 0 và không quá 5 mm'; end if;
      v_mix := v_mix || jsonb_build_array(jsonb_build_object('n', v_n::int, 'd', v_d));
      v_sn := v_sn + v_n; v_snd2 := v_snd2 + v_n * v_d * v_d;
    end loop;
    if jsonb_array_length(v_mix) = 0 then raise exception 'Khai ít nhất một loại sợi (số sợi, đường kính)'; end if;
    if jsonb_array_length(v_mix) > 4 then raise exception 'Ruột dẫn tối đa 4 loại sợi'; end if;
    update master.product_specs set wire_mix = v_mix, wire_count = v_sn::int, wire_dia_mm = sqrt(v_snd2 / v_sn)
     where id = p_spec;
  end if;
  if jsonb_typeof(p->'core_colors') = 'array' then
    select cores into v_cores from master.product_specs where id = p_spec;
    v_colors := array(select nullif(trim(x), '') from jsonb_array_elements_text(p->'core_colors') with ordinality t(x, o) order by o);
    if cardinality(v_colors) > v_cores then v_colors := v_colors[1:v_cores]; end if;
    while cardinality(v_colors) < v_cores loop v_colors := v_colors || null::text; end loop;
    if exists (select 1 from unnest(v_colors) c where c is not null) then
      update master.product_specs set core_colors = v_colors,
             insulation_colors = (select string_agg(coalesce(c, '?'), ' + ' order by o) from unnest(v_colors) with ordinality u(c, o))
       where id = p_spec;
    else
      update master.product_specs set core_colors = null where id = p_spec;
    end if;
  end if;
end $$;
revoke all on function master.set_spec_layers(uuid, jsonb) from public, anon, authenticated;

-- Vá app.update_spec_draft: ghi các loại sợi, màu lõi trước khi tính lại định mức
create or replace function pg_temp.patch(p_name text, p_old text, p_new text) returns void language plpgsql as $$
declare v_oid oid; v_n int; v_def text;
begin
  select count(*), min(p.oid) into v_n, v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname || '.' || p.proname = p_name;
  if v_n <> 1 then raise exception 'Vá %: có % hàm cùng tên', p_name, v_n; end if;
  v_def := pg_get_functiondef(v_oid);
  if position(p_old in v_def) = 0 then raise exception 'Vá %: không thấy đoạn "%"', p_name, p_old; end if;
  if position('master.set_spec_layers' in v_def) > 0 then return; end if;   -- đã vá
  execute replace(v_def, p_old, p_new);
end $$;
select pg_temp.patch('app.update_spec_draft',
  $o$perform master.calc_spec(p_spec);$o$,
  $n$perform master.set_spec_layers(p_spec, p);
  perform master.calc_spec(p_spec);$n$);
