-- Anh Bình 01/11/2026: lõi AWG chưa có giới hạn Rdc. Áp IEC TR 62602:2009 – Bảng 1 và Bảng 2 (Rdc tối đa ở 20 °C, Ω/km)
-- do anh Bình gửi. Lõi AWG của MES là lõi bện (Class 2) nên dùng hai cột "Lõi bện Class 2":
--   AWG  | đồng trần | đồng mạ thiếc
--   20   | 34,6      | 36,7
--   18   | 21,8      | 23,2
--   16   | 13,7      | 14,6
--   14   | 8,62      | 8,96
-- master.core_types: rdc_limit = đồng trần, rdc_limit_tc = đồng mạ thiếc (trống = dùng rdc_limit), rdc_source = căn cứ.
-- master.calc_spec chọn giới hạn theo vật liệu ruột dẫn (TC → rdc_limit_tc).

alter table master.core_types add column if not exists rdc_limit_tc numeric;
alter table master.core_types add column if not exists rdc_source text;

update master.core_types c set rdc_limit = v.bc, rdc_limit_tc = v.tc,
       rdc_source = 'IEC TR 62602:2009 Bảng 1–2, lõi bện Class 2 (đồng trần / mạ thiếc), 20 °C'
  from (values ('A20', 34.6, 36.7), ('A18', 21.8, 23.2), ('A16', 13.7, 14.6), ('A14', 8.62, 8.96)) v(code, bc, tc)
 where c.code = v.code;

create or replace function pg_temp.patch(p_name text, p_old text, p_new text, p_mark text) returns void language plpgsql as $$
declare v_oid oid; v_n int; v_def text;
begin
  select count(*), min(p.oid) into v_n, v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname || '.' || p.proname = p_name;
  if v_n <> 1 then raise exception 'Vá %: có % hàm cùng tên', p_name, v_n; end if;
  v_def := pg_get_functiondef(v_oid);
  if position(p_mark in v_def) > 0 then return; end if;
  if position(p_old in v_def) = 0 then raise exception 'Vá %: không thấy đoạn "%"', p_name, p_old; end if;
  execute replace(v_def, p_old, p_new);
end $$;
select pg_temp.patch('master.calc_spec', 'r.rdc_limit := c.rdc_limit;',
  'r.rdc_limit := case when s.conductor_mat = ''TC'' then coalesce(c.rdc_limit_tc, c.rdc_limit) else c.rdc_limit end;', 'rdc_limit_tc');

-- Tính lại giới hạn (và Rdc) cho mọi spec dùng lõi AWG
select master.calc_spec(s.id) from master.product_specs s
 where s.status <> 'OBSOLETE' and s.core_code in ('A14', 'A16', 'A18', 'A20');
