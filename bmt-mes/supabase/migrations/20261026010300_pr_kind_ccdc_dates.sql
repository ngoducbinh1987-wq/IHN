-- 1) Đề xuất mua: thêm mục đích "Mua công cụ dụng cụ, máy, trang thiết bị" (CCDC);
--    các loại cũ ghi rõ là nguyên vật liệu; vật tư trên dòng phải đúng loại đề xuất.
-- 2) Mọi ngày trong thông báo, câu báo lỗi do database tạo: dd/mm/yyyy (anh Bình 19/11/2026).

-- ---------------------------------------------------------------------------
-- Nhóm vật tư: công cụ dụng cụ (bobin, khuôn, dụng cụ đo…) và máy, thiết bị, tài sản
-- ---------------------------------------------------------------------------
insert into master.material_groups (code, name) values ('TOOLING', 'Công cụ dụng cụ')
on conflict (code) do update set name = excluded.name;
insert into master.material_groups (code, name) values ('ASSET', 'Máy, trang thiết bị, tài sản')
on conflict (code) do nothing;

create or replace function purchase.is_tool_group(p_group text) returns boolean
language sql immutable set search_path = pg_catalog, public as $$
  select coalesce(p_group in ('TOOLING', 'ASSET'), false)
$$;

-- ---------------------------------------------------------------------------
-- Loại đề xuất
-- ---------------------------------------------------------------------------
alter table purchase.purchase_requests drop constraint if exists purchase_requests_pr_kind_check;
alter table purchase.purchase_requests add constraint purchase_requests_pr_kind_check
  check (pr_kind in ('KE_HOACH', 'BO_SUNG', 'TICH_TRU', 'TOI_UU', 'CCDC'));
comment on column purchase.purchase_requests.pr_kind is
  'KE_HOACH: NVL theo kế hoạch tháng (MRP); BO_SUNG: mua bổ sung NVL; TICH_TRU: tích trữ NVL; TOI_UU: tối ưu giá NVL; CCDC: công cụ dụng cụ, máy, trang thiết bị, tài sản phục vụ sản xuất';

create or replace function purchase.pr_kind_label(p text) returns text
language sql immutable set search_path = pg_catalog, public as $$
  select case p when 'KE_HOACH' then 'Mua NVL theo kế hoạch tháng'
                when 'BO_SUNG' then 'Mua bổ sung nguyên vật liệu'
                when 'TICH_TRU' then 'Tích trữ nguyên vật liệu'
                when 'TOI_UU' then 'Tối ưu giá nguyên vật liệu'
                when 'CCDC' then 'Mua công cụ dụng cụ, máy, trang thiết bị'
                else p end
$$;

create or replace function purchase.pr_kind_guard() returns trigger
language plpgsql set search_path = pg_catalog, public as $$
begin
  if new.source = 'MRP' then
    new.pr_kind := 'KE_HOACH';
  elsif new.pr_kind = 'KE_HOACH' then
    raise exception 'Đề xuất lập tay chọn loại: mua bổ sung NVL, tích trữ NVL, tối ưu giá NVL hoặc công cụ dụng cụ, máy, thiết bị (loại "theo kế hoạch tháng" chỉ sinh từ dự trù MRP)';
  end if;
  return new;
end $$;

-- Thêm CCDC vào danh sách loại được lập / đổi (vá đúng đoạn kiểm, báo lỗi nếu định nghĩa khác)
do $$
declare f text; v_old text := $o$if p_kind not in ('BO_SUNG', 'TICH_TRU', 'TOI_UU') then raise exception 'Chọn loại đề xuất: Bổ sung, Tích trữ hoặc Tối ưu'; end if;$o$;
        v_new text := $n$if p_kind not in ('BO_SUNG', 'TICH_TRU', 'TOI_UU', 'CCDC') then raise exception 'Chọn loại đề xuất: mua bổ sung NVL, tích trữ NVL, tối ưu giá NVL hoặc công cụ dụng cụ, máy, thiết bị'; end if;$n$;
        fn regprocedure;
begin
  foreach fn in array array['app.create_pr(date, text, jsonb, text)'::regprocedure, 'app.set_pr_kind(uuid, text)'::regprocedure] loop
    f := replace(pg_get_functiondef(fn), E'\r', '');
    if position(v_old in f) = 0 then raise exception 'Không thấy đoạn kiểm loại đề xuất trong %', fn; end if;
    execute replace(f, v_old, v_new);
  end loop;
end $$;

-- Vật tư trên dòng phải đúng loại: NVL cho các loại mua NVL; nhóm Công cụ dụng cụ / Máy, thiết bị cho CCDC
create or replace function purchase.pr_line_kind_check() returns trigger
language plpgsql set search_path = pg_catalog, public as $$
declare v_kind text; v_src text; v_code text; v_group text;
begin
  select pr_kind, source into v_kind, v_src from purchase.purchase_requests where id = new.pr_id;
  if v_src = 'MRP' then return new; end if;
  select code, group_code into v_code, v_group from master.materials where id = new.material_id;
  if v_kind = 'CCDC' and not purchase.is_tool_group(v_group) then
    raise exception 'Đề xuất mua công cụ dụng cụ, máy, thiết bị chỉ nhận vật tư nhóm "Công cụ dụng cụ" hoặc "Máy, trang thiết bị, tài sản": % là nguyên vật liệu, lập đề xuất mua NVL riêng', v_code;
  elsif v_kind <> 'CCDC' and purchase.is_tool_group(v_group) then
    raise exception '% là công cụ dụng cụ / máy, thiết bị: chọn loại đề xuất "Mua công cụ dụng cụ, máy, trang thiết bị"', v_code;
  end if;
  return new;
end $$;
drop trigger if exists trg_pr_line_kind on purchase.pr_lines;
create trigger trg_pr_line_kind before insert or update of material_id on purchase.pr_lines
  for each row execute function purchase.pr_line_kind_check();

-- Đổi loại đề xuất đã có dòng: dòng phải hợp với loại mới
create or replace function purchase.pr_kind_lines_check() returns trigger
language plpgsql set search_path = pg_catalog, public as $$
declare v_code text;
begin
  if new.source = 'MRP' or new.pr_kind is not distinct from old.pr_kind then return new; end if;
  select m.code into v_code from purchase.pr_lines l join master.materials m on m.id = l.material_id
   where l.pr_id = new.id and purchase.is_tool_group(m.group_code) <> (new.pr_kind = 'CCDC') limit 1;
  if v_code is not null then
    raise exception 'Không đổi được sang loại "%": vật tư % không hợp với loại này (công cụ dụng cụ, máy, thiết bị và nguyên vật liệu lập đề xuất riêng)',
      purchase.pr_kind_label(new.pr_kind), v_code;
  end if;
  return new;
end $$;
drop trigger if exists trg_pr_kind_lines on purchase.purchase_requests;
create trigger trg_pr_kind_lines after update of pr_kind on purchase.purchase_requests
  for each row execute function purchase.pr_kind_lines_check();

revoke execute on function purchase.pr_line_kind_check() from public, anon, authenticated;
revoke execute on function purchase.pr_kind_lines_check() from public, anon, authenticated;
revoke execute on function purchase.is_tool_group(text) from public, anon;

-- ---------------------------------------------------------------------------
-- Ngày trong thông báo / câu báo lỗi: dd/mm/yyyy (giờ đứng sau ngày)
-- ---------------------------------------------------------------------------
do $$
declare r record; f text; g text; n int := 0;
begin
  for r in
    select p.oid from pg_proc p join pg_namespace s on s.oid = p.pronamespace
     where s.nspname in ('app', 'plan', 'purchase', 'inv', 'mfg', 'qa', 'wf', 'core', 'master', 'sales', 'cost', 'iot', 'integ')
       and p.prokind = 'f'
       and p.prosrc ~ $r$'(HH24:MI )?DD/MM( HH24:MI)?'|'HH24:MI DD/MM/YYYY'$r$
  loop
    f := replace(pg_get_functiondef(r.oid), E'\r', '');
    g := replace(f, $s$'HH24:MI DD/MM/YYYY'$s$, $s$'DD/MM/YYYY HH24:MI'$s$);
    g := replace(g, $s$'HH24:MI DD/MM'$s$, $s$'DD/MM/YYYY HH24:MI'$s$);
    g := replace(g, $s$'DD/MM HH24:MI'$s$, $s$'DD/MM/YYYY HH24:MI'$s$);
    g := replace(g, $s$'DD/MM'$s$, $s$'DD/MM/YYYY'$s$);
    if g <> f then execute g; n := n + 1; end if;
  end loop;
  if exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace
              where s.nspname in ('app', 'plan', 'purchase', 'inv', 'mfg', 'qa', 'wf', 'core', 'master', 'sales', 'cost', 'iot', 'integ')
                and p.prosrc ~ $r$'(HH24:MI )?DD/MM( HH24:MI)?'|'HH24:MI DD/MM/YYYY'$r$) then
    raise exception 'Còn hàm dùng định dạng ngày thiếu năm';
  end if;
  raise notice 'Đã đổi định dạng ngày trong % hàm', n;
end $$;
