-- Vị trí máy đóng gói PACK-01 theo khoanh đỏ của anh Bình (28/10/2026): cạnh máy xoắn TW800-02, ngay trên TW630-03
-- (thay "ô 17–18, trục D–E" ghi ở migration 3900). Mô hình 3D Trung tâm điều hành R04 đặt cùng vị trí.
update master.machines
   set location = 'Cạnh máy xoắn TW800-02, ngay trên dãy máy xoắn 630 (TW630-03), trục D'
 where code = 'PACK-01';
update master.machine_specs s
   set value = 'Cạnh máy xoắn TW800-02, ngay trên dãy máy xoắn 630 (TW630-03), trục D'
  from master.machines m
 where m.id = s.machine_id and m.code = 'PACK-01' and s.grp = 'Công nghệ' and s.label = 'Vị trí';
update master.machine_specs s
   set value = 'Trong phòng lạnh, phía trục A, trục cán vuông góc chiều dài phòng, cách đều 3 tường'
  from master.machines m
 where m.id = s.machine_id and m.code = 'SIL-MIX' and s.grp = 'Công nghệ' and s.label = 'Vị trí';
