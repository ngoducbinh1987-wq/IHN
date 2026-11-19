-- Mã vật tư bobin nhựa quay vòng 630, 800 (anh Bình yêu cầu 19/11/2026)
-- Bobin nhựa dùng chứa bán thành phẩm giữa các công đoạn, quay vòng (không tiêu hao theo km, không đưa vào BOM/MRP).
-- Nhóm vật tư mới TOOLING "Dụng cụ sản xuất quay vòng" để không lẫn với vật tư đóng gói (bobin gỗ REEL-W).
-- Từng bobin thật vẫn khai báo ở Kho → Bobin (inv.carriers, loại B630 / B800) để ghi phiếu hoàn thành.

insert into master.material_groups (code, name)
values ('TOOLING', 'Dụng cụ sản xuất quay vòng')
on conflict (code) do nothing;

insert into master.materials (code, name, group_code, purchase_spec, uom, loss_rate, has_expiry, requires_coa, is_scrap,
                              check_note, data_note, storage_zone, abc_class, safety_stock, active)
select v.code, v.name, 'TOOLING', v.spec, 'cái', 0, false, false, false, v.chk,
       'Tạo 19/11/2026 theo yêu cầu anh Bình. Hiện có ' || v.have || ' cái tại xưởng (chưa nhập tồn kho MES). Loại bobin ở Kho → Bobin: ' || v.ctype || '.',
       'THUONG', 'C', 0, true
from (values
  ('BOB-630', 'Bobin nhựa 630 (quay vòng BTP)',
   'Bobin nhựa mặt bích Ø630 mm, dùng cho máy bện BUN-01 và line bọc cách điện (ruột bện, lõi cách điện)',
   'Xác nhận đường kính lõi, bề rộng lòng, khối lượng bì và tải trọng tối đa khi mua.', 40, 'B630'),
  ('BOB-800', 'Bobin nhựa 800 (quay vòng BTP)',
   'Bobin nhựa mặt bích Ø800 mm, dùng cho máy xoắn TWS-01 và line bọc vỏ (cặp xoắn, cáp chờ đóng gói)',
   'Xác nhận đường kính lõi, bề rộng lòng, khối lượng bì và tải trọng tối đa khi mua.', 20, 'B800')
) v(code, name, spec, chk, have, ctype)
where not exists (select 1 from master.materials m where m.code = v.code);
