-- Khai báo bobin nhựa đang có ở xưởng vào Kho → Bobin (anh Bình 22/11/2026): 40 bobin 630, 20 bobin 800.
-- Số bobin B630-01…B630-40, B800-01…B800-20 (sơn/dán số này lên bobin). Chưa cân bì: tare 0, ghi chú nhắc cân.
-- Phiếu hoàn thành chặn bobin chưa có bì (tịnh = cân − bì, bì 0 làm sai kg/mét, hao hụt).

insert into inv.carriers (code, carrier_type, tare_kg, owner, status, note, location_id)
select format('B%s-%s', t.kind, lpad(n::text, 2, '0')), 'B' || t.kind, 0, 'BMT', 'EMPTY',
       'Khai báo 22/11/2026 (vật tư BOB-' || t.kind || '). Chưa cân bì: cân bobin rỗng, nhập bì ở Kho → Bobin trước khi dùng.',
       inv.loc('KBTP-EMPTY')
from (values ('630', 40), ('800', 20)) t(kind, cnt), generate_series(1, t.cnt) n
on conflict (code) do nothing;

do $$
declare f text;
  v_old text := 'v_tare := coalesce(c.tare_kg, 0);';
  v_new text := 'if c.id is not null and coalesce(c.tare_kg, 0) <= 0 then
    raise exception ''Bobin % chưa có khối lượng bì: cân bobin rỗng, nhập bì ở Kho → Bobin rồi ghi phiếu'', c.code;
  end if;
  v_tare := coalesce(c.tare_kg, 0);';
begin
  select replace(pg_get_functiondef(p.oid), E'\r', '') into f from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'record_bobbin';
  if f is null or position(v_old in f) = 0 then raise exception 'Không thấy đoạn tính bì trong app.record_bobbin'; end if;
  if position('chưa có khối lượng bì' in f) = 0 then execute replace(f, v_old, v_new); end if;
end $$;
