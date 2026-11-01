-- Anh Bình 01/11/2026: đã chuẩn hóa ruột dẫn ở CFR-2C-0P75 (0,75 mm²) và CFR-2C-1 (1,0 mm²); lấy quy cách ruột dẫn này
-- áp cho mọi sản phẩm cùng cỡ lõi. Quy cách ruột dẫn = vật liệu (BC/TC), các loại sợi (wire_mix), bước bện; hệ số ghép K
-- là của cáp (số lõi xoắn) nên giữ nguyên từng mã.
--  * Vật tư sợi đồng trần Ø0,20 (CU-020) chưa có: tạo theo CU-024 (cùng nhóm, đơn vị, hao hụt) để BOM tách đúng cỡ sợi.
--  * master.apply_conductor(nguồn): áp cho mọi spec còn hiệu lực cùng mã lõi + vật liệu ruột dẫn, tính lại định mức, đồng bộ BOM,
--    kế hoạch dùng các spec đó cần chạy lại MRP. Spec giữ nguyên trạng thái (như Quản trị sửa spec).
--  * app.admin_conductor_apply(nguồn, lý do): nút "Áp ruột dẫn cho mọi mã cùng cỡ lõi" (chỉ Quản trị), ghi nhật ký từng spec.

insert into master.materials (code, name, group_code, purchase_spec, uom, loss_rate, density, has_expiry, requires_coa)
select 'CU-020', 'Đồng trần BC Ø0,20', m.group_code, m.purchase_spec, m.uom, m.loss_rate, m.density, m.has_expiry, m.requires_coa
  from master.materials m where m.code = 'CU-024'
on conflict (code) do nothing;

create or replace function master.apply_conductor(p_src uuid)
returns table (spec_id uuid, code text, version int, old_wires text, new_wires text)
language plpgsql security definer set search_path = pg_catalog, public as $$
declare src master.product_specs; t record; v_old text;
begin
  select * into src from master.product_specs where id = p_src;
  if src.id is null then raise exception 'Không tìm thấy spec nguồn'; end if;
  if src.wire_mix is null then raise exception 'Spec nguồn chưa khai các loại sợi'; end if;
  perform set_config('bmt.admin_spec_edit', 'on', true);
  for t in select s.id, p.code, s.version, s.wire_mix, s.pitch_mm
             from master.product_specs s join master.products p on p.id = s.product_id
            where s.status <> 'OBSOLETE' and s.id <> src.id and s.core_code = src.core_code and s.conductor_mat = src.conductor_mat
              and (s.wire_mix is distinct from src.wire_mix or s.pitch_mm is distinct from src.pitch_mm)
            order by p.code, s.version loop
    v_old := (select string_agg((x->>'n') || '×' || replace(x->>'d', '.', ','), ' + ') from jsonb_array_elements(t.wire_mix) x)
             || ' mm, bước ' || replace(round(t.pitch_mm, 2)::text, '.', ',');
    update master.product_specs set pitch_mm = src.pitch_mm where id = t.id;
    perform master.set_spec_layers(t.id, jsonb_build_object('wire_mix', src.wire_mix));
    perform master.calc_spec(t.id);
    perform master.sync_bom(t.id);
    spec_id := t.id; code := t.code; version := t.version; old_wires := v_old;
    new_wires := (select string_agg((x->>'n') || '×' || replace(x->>'d', '.', ','), ' + ') from jsonb_array_elements(src.wire_mix) x)
                 || ' mm, bước ' || replace(round(src.pitch_mm, 2)::text, '.', ',');
    return next;
  end loop;
  perform master.sync_bom(src.id);   -- nguồn: BOM tách đúng cỡ sợi khi vừa có vật tư mới
  update plan.production_plans pp set mrp_stale = true
   where pp.status in ('DRAFT', 'PENDING_APPROVAL', 'APPROVED') and not pp.mrp_stale
     and exists (select 1 from plan.plan_lines pl join master.product_specs s on s.id = pl.spec_id
                  where pl.plan_id = pp.id and s.core_code = src.core_code and s.conductor_mat = src.conductor_mat);
  perform set_config('bmt.admin_spec_edit', 'off', true);
end $$;
revoke all on function master.apply_conductor(uuid) from public, anon, authenticated;

create or replace function app.admin_conductor_apply(p_src uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_src text; v_list text; v_n int := 0; t record;
begin
  if not core.is_admin() then raise exception 'Chỉ Quản trị hệ thống được áp ruột dẫn cho các mã khác'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Ghi lý do'; end if;
  select p.code || ' v' || s.version into v_src from master.product_specs s join master.products p on p.id = s.product_id where s.id = p_src;
  if v_src is null then raise exception 'Không tìm thấy spec nguồn'; end if;
  for t in select * from master.apply_conductor(p_src) loop
    v_n := v_n + 1;
    v_list := concat_ws(', ', v_list, t.code || ' v' || t.version);
    perform app.admin_log('master.product_specs', t.spec_id::text, 'ADMIN_SPEC', jsonb_build_object('conductor', t.old_wires),
      jsonb_build_object('conductor', t.new_wires, 'doc_type', 'Chuẩn hóa ruột dẫn theo ' || v_src, 'doc_no', t.code || ' v' || t.version,
                         'reason', trim(p_reason)));
  end loop;
  if v_n > 0 then
    perform wf.notify_role(x, 'Chuẩn hóa ruột dẫn theo ' || v_src, v_n || ' spec: ' || left(v_list, 400) || '. Kế hoạch dùng các mã này cần chạy lại MRP.', '/san-pham')
      from unnest(array['SX_TP', 'SX_KH', 'MUA_TP', 'KT_TP']) x;
  end if;
  return jsonb_build_object('count', v_n, 'specs', coalesce(v_list, ''));
end $$;
revoke all on function app.admin_conductor_apply(uuid, text) from public, anon;
grant execute on function app.admin_conductor_apply(uuid, text) to authenticated;

-- Áp ngay theo hai mã anh Bình đã chuẩn hóa (bản hiện hành)
do $$ declare v_src uuid; t record; v_cnt int;
begin
  for v_src in select p.current_spec_id from master.products p where p.code in ('CFR-2C-0P75', 'CFR-2C-1') and p.current_spec_id is not null loop
    v_cnt := 0;
    for t in select * from master.apply_conductor(v_src) loop
      v_cnt := v_cnt + 1;
      perform app.admin_log('master.product_specs', t.spec_id::text, 'ADMIN_SPEC', jsonb_build_object('conductor', t.old_wires),
        jsonb_build_object('conductor', t.new_wires, 'doc_type', 'Chuẩn hóa ruột dẫn', 'doc_no', t.code || ' v' || t.version,
                           'reason', 'Anh Bình chuẩn hóa ruột dẫn 0,75 / 1,0 mm² theo CFR-2C-0P75, CFR-2C-1 (01/11/2026)'));
    end loop;
    raise notice 'Nguồn %: % spec', v_src, v_cnt;
  end loop;
end $$;
