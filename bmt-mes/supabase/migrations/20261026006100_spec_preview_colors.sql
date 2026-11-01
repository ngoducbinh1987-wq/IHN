-- Anh Bình 01/11/2026: (1) dây 2 lõi bọc silicone: màu lõi Trắng + Nâu (BOM dùng màu silicone trắng SI-W thay màu xanh dương SI-C1);
-- (2) nút Tạm tính: tính thông số, định mức theo số đang nhập mà chưa lưu (app.spec_preview).

-- ---------------------------------------------------------------- (1) Màu lõi dây 2 lõi silicone
select set_config('bmt.admin_spec_edit', 'on', true);   -- cho qua khóa spec / BOM đã phát hành, trạng thái giữ nguyên

update master.product_specs set core_colors = array['Trắng', 'Nâu'], insulation_colors = 'Trắng + Nâu'
 where cores = 2 and insulation = 'SIL' and status <> 'OBSOLETE';

-- BOM: màu silicone xanh dương → màu silicone trắng (cùng suất), chỉ khi BOM chưa có SI-W cùng cách tính
update master.bom_lines l set material_id = (select id from master.materials where code = 'SI-W'),
       note = concat_ws('; ', nullif(l.note, ''), 'Đổi SI-C1 → SI-W 01/11/2026: lõi Trắng + Nâu')
  from master.bom_headers h, master.product_specs s
 where h.id = l.bom_id and s.id = h.spec_id and s.cores = 2 and s.insulation = 'SIL' and s.status <> 'OBSOLETE'
   and l.material_id = (select id from master.materials where code = 'SI-C1')
   and exists (select 1 from master.materials where code = 'SI-W')
   and not exists (select 1 from master.bom_lines x where x.bom_id = l.bom_id and x.basis = l.basis
                     and x.material_id = (select id from master.materials where code = 'SI-W'));

-- Kế hoạch còn hiệu lực dùng các spec này: chạy lại MRP
update plan.production_plans pp set mrp_stale = true
 where pp.status in ('DRAFT', 'PENDING_APPROVAL', 'APPROVED') and not pp.mrp_stale
   and exists (select 1 from plan.plan_lines pl join master.product_specs s on s.id = pl.spec_id
               where pl.plan_id = pp.id and s.cores = 2 and s.insulation = 'SIL');

select set_config('bmt.admin_spec_edit', 'off', true);

-- ---------------------------------------------------------------- (2) Tạm tính thông số spec, không lưu
-- Chạy app.update_spec_draft trong giao dịch con rồi hủy: kết quả đúng như khi bấm Lưu, nhưng không đổi gì.
-- Quyền: như người được sửa spec đó (spec nháp/pilot: spec:edit/create; spec đã phát hành/đang duyệt: chỉ Quản trị).
create or replace function app.spec_preview(p_spec uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_status text; v_out jsonb;
begin
  select status into v_status from master.product_specs where id = p_spec;
  if not found then raise exception 'Không tìm thấy spec'; end if;
  if not (core.is_admin()
          or ((core.has_perm('spec', 'edit') or core.has_perm('spec', 'create')) and v_status in ('DRAFT', 'PILOT_PENDING', 'PILOT'))) then
    raise exception 'Không có quyền tạm tính spec này';
  end if;
  begin
    perform set_config('bmt.admin_spec_edit', 'on', true);
    perform app.update_spec_draft(p_spec, coalesce(p, '{}'::jsonb));
    select jsonb_build_object('spec', to_jsonb(s), 'res', to_jsonb(r), 'issues', to_jsonb(master.check_spec(p_spec)))
      into v_out
      from master.product_specs s left join master.spec_results r on r.spec_id = s.id where s.id = p_spec;
    raise exception 'BMT_PREVIEW_ROLLBACK';
  exception when others then
    if sqlerrm <> 'BMT_PREVIEW_ROLLBACK' then raise; end if;
  end;
  return v_out;
end $$;
revoke all on function app.spec_preview(uuid, jsonb) from public, anon;
grant execute on function app.spec_preview(uuid, jsonb) to authenticated;
