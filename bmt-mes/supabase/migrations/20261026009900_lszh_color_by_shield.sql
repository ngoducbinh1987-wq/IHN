-- Anh Bình 11/11/2026 (đính chính migration 9800): KAVIX cáp chống cháy chống nhiễu (SFR) vỏ vẫn cam RAL 2004;
-- RAL 6037 chỉ cho cáp điện dân dụng KAVIX (không chống nhiễu, CFR). HEIZKA giữ RAL 2004.
--   * master.brand_sheath_colors thêm cột shield (null = mọi loại): KAVIX + chống nhiễu → RAL 2004, KAVIX + không chống nhiễu → RAL 6037.
--   * master.bom_issues: so màu vỏ theo thương hiệu + chống nhiễu.
--   * 16 spec SFR KAVIX trả về RAL 2004 (LSZH-O), đồng bộ BOM, kế hoạch dùng các spec này chạy lại MRP.

alter table master.brand_sheath_colors add column if not exists shield boolean;
comment on column master.brand_sheath_colors.shield is 'true = cáp chống nhiễu, false = không chống nhiễu, null = mọi loại';
alter table master.brand_sheath_colors drop constraint if exists brand_sheath_colors_pkey;
create unique index if not exists brand_sheath_colors_key on master.brand_sheath_colors (brand, family, shield) nulls not distinct;
delete from master.brand_sheath_colors where brand = 'KAVIX' and family = 'LSZH';
insert into master.brand_sheath_colors (brand, family, shield, color, note) values
  ('KAVIX', 'LSZH', true, 'RAL 2004', 'Cáp chống cháy chống nhiễu: LSZH cam (anh Bình 11/11/2026)'),
  ('KAVIX', 'LSZH', false, 'RAL 6037', 'Cáp điện dân dụng không chống nhiễu: LSZH xanh (anh Bình 11/11/2026)')
on conflict do nothing;
update master.brand_sheath_colors set note = 'Mọi loại cáp HEIZKA: LSZH cam (anh Bình 11/11/2026)' where brand = 'HEIZKA' and family = 'LSZH';

-- bom_issues: thêm điều kiện chống nhiễu
do $$
declare d text;
  v_from text := 'where b.brand = s.brand and b.family = s.sheath and master.norm_color(b.color) <> coalesce(master.norm_color(s.sheath_color), '''');';
  v_from2 text := 'msgs := msgs || format(''Vỏ %s thương hiệu %s phải màu %s (đang %s)'', s.sheath, s.brand, v_list, coalesce(s.sheath_color, ''chưa khai''));';
begin
  d := replace(pg_get_functiondef('master.bom_issues(uuid)'::regprocedure), E'\r', '');
  if (length(d) - length(replace(d, v_from, ''))) / length(v_from) <> 1
     or (length(d) - length(replace(d, v_from2, ''))) / length(v_from2) <> 1 then
    raise exception 'master.bom_issues: không thấy đúng đoạn cần vá (migration 9800)';
  end if;
  d := replace(d, v_from, 'where b.brand = s.brand and b.family = s.sheath and (b.shield is null or b.shield = coalesce(s.shield, false))
       and master.norm_color(b.color) <> coalesce(master.norm_color(s.sheath_color), '''');');
  d := replace(d, v_from2, 'msgs := msgs || format(''Vỏ %s thương hiệu %s%s phải màu %s (đang %s)'', s.sheath, s.brand,
        case when coalesce(s.shield, false) then '' (cáp chống nhiễu)'' else '' (cáp không chống nhiễu)'' end, v_list, coalesce(s.sheath_color, ''chưa khai''));');
  execute d;
end $$;

-- Spec còn hiệu lực sai màu theo quy tắc mới → sửa màu (nhân danh Quản trị, ghi nhật ký can thiệp)
do $$
declare v_admin uuid; r record;
begin
  select ur.user_id into v_admin from core.user_roles ur join core.profiles p on p.id = ur.user_id
   where ur.role_code = 'ADMIN' and p.status = 'ACTIVE' order by p.created_at limit 1;
  if v_admin is not null then perform set_config('request.jwt.claim.sub', v_admin::text, true); end if;
  perform set_config('bmt.admin_spec_edit', 'on', true);
  create temp table _recolor (id uuid) on commit drop;
  for r in select s.id, p.code, s.version, s.sheath_color old_color, b.color new_color
             from master.product_specs s join master.products p on p.id = s.product_id
             join master.brand_sheath_colors b on b.brand = s.brand and b.family = s.sheath
                  and (b.shield is null or b.shield = coalesce(s.shield, false))
            where s.status <> 'OBSOLETE' and master.norm_color(s.sheath_color) is distinct from master.norm_color(b.color) loop
    update master.product_specs set sheath_color = r.new_color where id = r.id;
    insert into _recolor values (r.id);
    if v_admin is not null then
      perform app.admin_log('master.product_specs', r.id::text, 'ADMIN_SPEC',
        jsonb_build_object('doc_type', 'Sửa spec', 'doc_no', r.code || ' v' || r.version, 'sheath_color', r.old_color),
        jsonb_build_object('sheath_color', r.new_color,
          'reason', 'KAVIX chống nhiễu vỏ RAL 2004, không chống nhiễu RAL 6037; HEIZKA RAL 2004 (anh Bình 11/11/2026)'));
    end if;
  end loop;
  perform master.sync_bom(id) from _recolor;
  update plan.production_plans pp set mrp_stale = true
   where pp.status in ('DRAFT', 'PENDING_APPROVAL', 'APPROVED') and not pp.mrp_stale
     and exists (select 1 from plan.plan_lines pl join _recolor x on x.id = pl.spec_id where pl.plan_id = pp.id);
  perform set_config('bmt.admin_spec_edit', 'off', true);

  -- Kế hoạch có spec vừa đổi màu: chạy lại MRP
  for r in select id, plan_no from plan.production_plans
            where status in ('DRAFT', 'APPROVED') and mrp_stale
              and exists (select 1 from plan.mrp_runs m where m.plan_id = production_plans.id)
              and exists (select 1 from plan.plan_lines pl join _recolor x on x.id = pl.spec_id where pl.plan_id = production_plans.id) loop
    begin
      perform app.plan_run_mrp(r.id);
    exception when others then
      raise notice 'Không chạy lại được MRP % (%): TP SX bấm Chạy MRP', r.plan_no, sqlerrm;
    end;
  end loop;
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
