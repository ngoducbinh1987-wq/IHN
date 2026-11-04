-- Anh Bình 04/11/2026: máy bện BUN-01 đã bện xong 25.350 m ruột 1,5 mm² đồng trần (BTP) hôm nay, cần nhập phiếu hoàn thành.
-- Chưa có lệnh SX nào (chưa xếp lịch, chưa phát lệnh ngày) → anh Bình đồng ý để Claude phát lệnh SX trực tiếp:
--   * lệnh SX cho dòng HER15U2LZ (ruột M1.5, 30 × Ø0,24 đồng trần) của kế hoạch đã duyệt KH-2611-02, phát lệnh ngày 04/11/2026
--     (plan.ensure_wo, như khi phát lệnh ngày; nhân danh Quản trị);
--   * phiếu lĩnh NVL ngày 04/11/2026 chỉ phần công đoạn bện (đồng), tính cho 25.350 m ruột = 12.675 m cáp 2 lõi,
--     để Kế toán SX ghi số đồng thực xuất ở Phiếu xuất NVL.
-- Chạy lại không tạo trùng. DB dựng mới (không có kế hoạch KH-2611-02 / Quản trị) thì bỏ qua.
do $$
declare v_admin uuid; v_line uuid; v_wo uuid; v_req uuid; v_no text;
  v_day constant date := date '2026-11-04';
begin
  select ur.user_id into v_admin from core.user_roles ur join core.profiles p on p.id = ur.user_id
   where ur.role_code = 'ADMIN' and p.status = 'ACTIVE' order by p.created_at limit 1;
  select pl.id into v_line from plan.plan_lines pl
    join plan.production_plans pp on pp.id = pl.plan_id and pp.plan_no = 'KH-2611-02' and pp.status = 'APPROVED'
    join master.products p on p.id = pl.product_id and p.code = 'HER15U2LZ'
   where pl.qty_m > 0 order by pl.id limit 1;
  if v_admin is null or v_line is null then raise notice 'Không có KH-2611-02 / HER15U2LZ hoặc Quản trị: bỏ qua'; return; end if;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  v_wo := plan.ensure_wo(v_line, v_day);
  if v_wo is null then raise exception 'HER15U2LZ: spec chưa phát hành hoặc chưa có BOM, không phát lệnh được'; end if;
  update mfg.work_orders set note = coalesce(note, '') || ' Phát lệnh trực tiếp 04/11/2026 (anh Bình duyệt): nhập phiếu hoàn thành bện BUN-01.'
   where id = v_wo and coalesce(note, '') not like '%Phát lệnh trực tiếp 04/11/2026%';

  -- Phiếu lĩnh đồng cho phần bện hôm nay
  if not exists (select 1 from inv.requisitions where wo_id = v_wo and kind = 'NORM' and status <> 'CANCELLED' and work_date = v_day) then
    v_req := inv.create_requisition(v_wo, 12675, v_day,
      'Bện BUN-01 ngày 04/11/2026: 25.350 m ruột 1,5 mm² (= 12.675 m cáp 2 lõi), chỉ vật tư công đoạn bện');
    delete from inv.requisition_lines rl
     where rl.req_id = v_req
       and not exists (select 1 from master.bom_lines bl join mfg.work_orders w on w.bom_id = bl.bom_id
                        where w.id = v_wo and bl.material_id = rl.material_id and bl.operation_code = 'CD1');
    if not exists (select 1 from inv.requisition_lines where req_id = v_req) then
      raise exception 'BOM HER15U2LZ không có vật tư công đoạn bện (CD1)';
    end if;
  end if;
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
