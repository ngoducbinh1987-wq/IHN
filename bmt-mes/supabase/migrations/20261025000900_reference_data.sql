-- BMT MES · 0900 · Dữ liệu tham chiếu: phòng ban, vai trò, quyền, luồng duyệt, kho, công đoạn, lý do, nhóm SP, máy

insert into core.uoms (code, name) values
  ('kg','Kilogram'), ('m','Mét'), ('km','Kilomet'), ('bộ','Bộ'), ('cái','Cái');

insert into core.departments (code, name) values
  ('BGD','Ban giám đốc'), ('KD','Kinh doanh'), ('KT','Kỹ thuật/QA'), ('KHO','Kho'),
  ('MUA','Mua hàng'), ('KTOAN','Kế toán'), ('SX','Sản xuất'), ('IT','Quản trị hệ thống');

insert into core.roles (code, name, department, level, can_see_price) values
  ('BGD','Ban giám đốc','BGD',3,true),
  ('KD_NV','Nhân viên kinh doanh','KD',1,false), ('KD_TP','Trưởng phòng kinh doanh','KD',2,false),
  ('KT_NV','Nhân viên kỹ thuật','KT',1,false), ('KT_TP','Trưởng phòng Kỹ thuật/QA','KT',2,false), ('QC','Kiểm tra chất lượng','KT',1,false),
  ('KHO_NV','Nhân viên kho','KHO',1,false), ('THU_KHO','Thủ kho','KHO',2,false),
  ('MUA_NV','Nhân viên mua hàng','MUA',1,true), ('MUA_TP','Trưởng phòng mua hàng','MUA',2,true),
  ('KT_KHO','Kế toán kho','KTOAN',1,true), ('KT_GT','Kế toán giá thành','KTOAN',1,true), ('KTT','Kế toán trưởng','KTOAN',2,true),
  ('SX_TP','Trưởng phòng sản xuất','SX',2,false), ('SX_KH','Kế hoạch sản xuất','SX',1,false),
  ('TO_TRUONG','Tổ trưởng ca','SX',1,false), ('VAN_HANH','Công nhân vận hành','SX',1,false),
  ('ADMIN','Quản trị hệ thống','IT',3,false);

insert into core.permissions (module, action)
select m, a from unnest(array['admin','master','spec','price','sales','plan','purchase','inventory','production',
                              'quality','cost','approval','iot','integration']) m
cross join unnest(array['view','create','edit','approve','export','config']) a;

-- Ma trận quyền: 'phân hệ:hành động,…'
create temporary table _rp (role_code text, spec text);
insert into _rp values
  ('BGD','admin:view;master:view,export;spec:view,approve,export;price:view,export;sales:view,approve,export;plan:view,approve,export;purchase:view,approve,export;inventory:view,approve,export;production:view,approve,export;quality:view,approve,export;cost:view,approve,export;approval:view;iot:view;integration:view'),
  ('KD_NV','master:view;spec:view;sales:view,create,edit,export;plan:view;inventory:view;production:view;approval:view'),
  ('KD_TP','master:view;spec:view;sales:view,create,edit,approve,export,config;plan:view;inventory:view;production:view;approval:view'),
  ('KT_NV','master:view,create,edit;spec:view,create,edit,export;quality:view,create,edit;production:view;inventory:view;plan:view;approval:view;iot:view'),
  ('KT_TP','master:view,create,edit,config;spec:view,create,edit,approve,export,config;quality:view,create,edit,approve,export;production:view;inventory:view;plan:view;approval:view;iot:view'),
  ('QC','master:view;spec:view;quality:view,create,edit,export;inventory:view,edit;production:view;approval:view;iot:view'),
  ('KHO_NV','master:view;inventory:view,create,edit;purchase:view;production:view;approval:view'),
  ('THU_KHO','master:view;inventory:view,create,edit,export;purchase:view;production:view;sales:view;approval:view'),
  ('MUA_NV','master:view,create,edit;spec:view;price:view,create,edit,export;purchase:view,create,edit,export;plan:view;inventory:view;approval:view'),
  ('MUA_TP','master:view,create,edit;spec:view;price:view,create,edit,approve,export;purchase:view,create,edit,approve,export,config;plan:view,create,edit;inventory:view;approval:view'),
  ('KT_KHO','master:view;price:view;inventory:view,export,approve;purchase:view;cost:view,create,edit;integration:view,create,edit;approval:view'),
  ('KT_GT','master:view;spec:view;price:view;inventory:view;production:view;cost:view,create,edit,export;integration:view;approval:view'),
  ('KTT','master:view;spec:view;price:view,export;inventory:view,approve,export;production:view;purchase:view;plan:view;cost:view,create,edit,approve,export;integration:view,create,edit;approval:view'),
  ('SX_TP','master:view;spec:view;plan:view,create,edit,approve,export;production:view,create,edit,approve,export,config;inventory:view,create,edit;quality:view;purchase:view,create;iot:view;sales:view;approval:view'),
  ('SX_KH','master:view;spec:view;plan:view,create,edit,export;production:view,create,edit;inventory:view;purchase:view,create;iot:view;sales:view;approval:view'),
  ('TO_TRUONG','master:view;spec:view;production:view,create,edit;inventory:view,create,edit;quality:view;iot:view;approval:view'),
  ('VAN_HANH','master:view;spec:view;production:view,create;inventory:view;iot:view');

insert into core.role_permissions (role_code, module, action)
select r.role_code, split_part(ma, ':', 1), act
from _rp r, unnest(string_to_array(r.spec, ';')) ma, unnest(string_to_array(split_part(ma, ':', 2), ',')) act;

insert into core.role_permissions (role_code, module, action)
select 'ADMIN', module, action from core.permissions;
drop table _rp;

-- ---------------------------------------------------------------------------
-- Luồng duyệt theo phân cấp (BA mục 15)
-- ---------------------------------------------------------------------------
insert into wf.approval_flows (doc_type, name, doc_table, approved_status, rejected_status, pending_status) values
  ('SO','Đơn bán hàng','sales.sales_orders','APPROVED','DRAFT','PENDING_APPROVAL'),
  ('SPEC_NEW','Spec + BOM mã mới / thay đổi lớn','master.product_specs','RELEASED','DRAFT','PENDING_APPROVAL'),
  ('SPEC_MINOR','Thay đổi nhỏ spec','master.product_specs','RELEASED','DRAFT','PENDING_APPROVAL'),
  ('PLAN','Kế hoạch SX kỳ + MRP','plan.production_plans','APPROVED','DRAFT','PENDING_APPROVAL'),
  ('PR','Yêu cầu mua (PR)','purchase.purchase_requests','APPROVED','DRAFT','PENDING_APPROVAL'),
  ('PROPOSAL','Đề xuất mua tối ưu','plan.purchase_proposals','APPROVED','DRAFT','PENDING_APPROVAL'),
  ('PO','Đơn mua hàng (PO)','purchase.purchase_orders','APPROVED','DRAFT','PENDING_APPROVAL'),
  ('WO_RELEASE','Phát lệnh sản xuất','mfg.work_orders','RELEASED','DRAFT','DRAFT'),
  ('EXTRA_ISSUE','Cấp NVL bổ sung vượt định mức','inv.stock_docs','APPROVED','DRAFT','PENDING_APPROVAL'),
  ('NCR','NCR / chấp nhận sai lệch','qa.ncrs','APPROVED','OPEN','PENDING_APPROVAL'),
  ('STOCK_ADJ','Điều chỉnh kiểm kê','inv.stock_docs','APPROVED','DRAFT','PENDING_APPROVAL'),
  ('SCRAP_OUT','Xuất bán / hủy phế liệu','inv.stock_docs','APPROVED','DRAFT','PENDING_APPROVAL'),
  ('COST_CLOSE','Chốt giá thành kỳ','cost.cost_periods','CLOSED','CALCULATED','PENDING_APPROVAL');

insert into wf.approval_steps (doc_type, seq, level_label, role_code, enabled) values
  ('SO',1,'Duyệt','KD_TP',true), ('SO',2,'Phê duyệt','BGD',true),               -- ADMIN có thể tắt bước BGĐ
  ('SPEC_NEW',1,'Kiểm tra (kết quả pilot)','QC',true), ('SPEC_NEW',2,'Duyệt','KT_TP',true), ('SPEC_NEW',3,'Phê duyệt phát hành','BGD',true),
  ('SPEC_MINOR',1,'Duyệt','KT_TP',true),
  ('PLAN',1,'Duyệt','SX_TP',true), ('PLAN',2,'Phê duyệt','BGD',true),
  ('PR',1,'Duyệt','SX_TP',true),
  ('PROPOSAL',1,'Kiểm tra dòng tiền','KTT',true), ('PROPOSAL',2,'Phê duyệt','BGD',true),
  ('PO',1,'Duyệt','MUA_TP',true), ('PO',2,'Phê duyệt','BGD',true),
  ('WO_RELEASE',1,'Phát lệnh','SX_TP',true),
  ('EXTRA_ISSUE',1,'Duyệt','SX_TP',true),
  ('NCR',1,'Duyệt','KT_TP',true), ('NCR',2,'Phê duyệt (giao khách)','BGD',false),
  ('STOCK_ADJ',1,'Kiểm tra','KT_KHO',true), ('STOCK_ADJ',2,'Phê duyệt','BGD',true),
  ('SCRAP_OUT',1,'Kiểm tra','KT_KHO',true), ('SCRAP_OUT',2,'Phê duyệt','BGD',true),
  ('COST_CLOSE',1,'Duyệt','KTT',true), ('COST_CLOSE',2,'Phê duyệt','BGD',true);

-- ---------------------------------------------------------------------------
-- Kho, công đoạn, lý do
-- ---------------------------------------------------------------------------
insert into inv.warehouses (code, name, kind) values
  ('KNL','Kho nguyên liệu','MAT'), ('KBTP','Kho bán thành phẩm','WIP'),
  ('KTP','Kho thành phẩm','FG'), ('KPL','Kho phế liệu','SCRAP');

insert into master.operations (code, seq, name, machine_type, output_prefix) values
  ('CD0',0,'Phối trộn silicone','MIXER','MX'),
  ('CD1',1,'Bện ruột dẫn','BUNCHER','CB'),
  ('CD2',2,'Bọc cách điện','EXTRUDER_SI','LB'),
  ('CD3',3,'Xoắn cặp / ghép lõi','TWISTER','BL'),
  ('CD4',4,'Quấn băng chống nhiễu','TAPER','BS'),
  ('CD5',5,'Bọc vỏ + in','EXTRUDER_TP','CV'),
  ('CD6',6,'Kiểm tra + đóng gói','PACKER','BB');

insert into master.product_groups (code, name, allowed_brands, allowed_sheaths, sheath_color, insulation_colors) values
  ('PFR','Cáp điện chống cháy', array['KAVIX'], array['FR-PVC','LSZH'], 'RAL 6037', 'Silicone nâu + trắng'),
  ('SFR','Tín hiệu FR chống nhiễu', array['KAVIX','HEIZKA'], array['LSZH'], 'RAL 2004', 'Silicone nâu + trắng'),
  ('CFR','Điều khiển chống cháy', array['KAVIX','HEIZKA'], null, 'Theo thương hiệu', 'Theo sơ đồ lõi hiện hành'),
  ('CTL','Điều khiển AWG chống nhiễu', array['KAVIX','HEIZKA'], array['PVC'], 'Xám (Gray)', 'HDPE trắng + đen'),
  ('SIF','Dây đơn chống cháy', array['KAVIX','HEIZKA'], array['Không'], null, 'Theo màu chọn'),
  ('PVC','Dây đơn PVC', array['KAVIX','HEIZKA'], array['Không'], null, 'Theo màu chọn');

insert into master.routings (group_code, op_code) values
  ('PFR','CD0'),('PFR','CD1'),('PFR','CD2'),('PFR','CD3'),('PFR','CD5'),('PFR','CD6'),
  ('SFR','CD0'),('SFR','CD1'),('SFR','CD2'),('SFR','CD3'),('SFR','CD4'),('SFR','CD5'),('SFR','CD6'),
  ('CFR','CD0'),('CFR','CD1'),('CFR','CD2'),('CFR','CD3'),('CFR','CD5'),('CFR','CD6'),
  ('CTL','CD1'),('CTL','CD2'),('CTL','CD3'),('CTL','CD4'),('CTL','CD5'),('CTL','CD6'),
  ('SIF','CD0'),('SIF','CD1'),('SIF','CD2'),('SIF','CD6'),
  ('PVC','CD1'),('PVC','CD2'),('PVC','CD6');

-- Màu lõi (CAL-16)
insert into master.color_rules (group_code, cores, core_colors) values
  ('PFR',2,array['Nâu','Trắng']), ('PFR',3,array['Nâu','Nâu','Trắng']), ('PFR',4,array['Nâu','Nâu','Trắng','Trắng']),
  ('SFR',2,array['Nâu','Trắng']), ('SFR',4,array['Nâu','Trắng','Nâu','Trắng']),
  ('SFR',6,array['Nâu','Trắng','Nâu','Trắng','Nâu','Trắng']), ('SFR',8,array['Nâu','Trắng','Nâu','Trắng','Nâu','Trắng','Nâu','Trắng']),
  ('CTL',2,array['Trắng','Đen']), ('CTL',4,array['Trắng','Đen','Trắng','Đen']),
  ('CTL',6,array['Trắng','Đen','Trắng','Đen','Trắng','Đen']), ('CTL',8,array['Trắng','Đen','Trắng','Đen','Trắng','Đen','Trắng','Đen']);

insert into master.reason_codes (code, kind, name, planned) values
  ('SC_STARTUP','SCRAP','Phế khởi động',true),
  ('SC_BREAK','SCRAP','Đứt dây',false),
  ('SC_OD','SCRAP','Sai OD / chiều dày',false),
  ('SC_COLOR','SCRAP','Sai màu / đổi màu',false),
  ('SC_PRINT','SCRAP','Lỗi in',false),
  ('SC_SPARK','SCRAP','Hỏng cao áp / spark',false),
  ('SC_TAIL','SCRAP','Đuôi bobin',true),
  ('SC_PURGE','SCRAP','Purge / vệ sinh máy',true),
  ('DT_MATERIAL','DOWNTIME','Chờ NVL',false),
  ('DT_COLOR','DOWNTIME','Đổi màu',true),
  ('DT_DIE','DOWNTIME','Thay khuôn',true),
  ('DT_BREAKDOWN','DOWNTIME','Hỏng máy',false),
  ('DT_CLEAN','DOWNTIME','Vệ sinh / purge',true),
  ('DT_QC','DOWNTIME','Chờ QC',false),
  ('DT_POWER','DOWNTIME','Mất điện',false),
  ('EX_SCRAP','EXTRA_ISSUE','Bù phế vượt định mức',false),
  ('EX_RERUN','EXTRA_ISSUE','Chạy lại do lỗi',false),
  ('ADJ_COUNT','ADJUST','Chênh lệch kiểm kê',false),
  ('RJ_IQC','REJECT','Không đạt kiểm tra đầu vào',false);

-- Nhóm vật tư (gồm mã phế liệu, giá trị 0)
insert into master.material_groups (code, name) values
  ('CONDUCTOR','Kim loại dẫn'), ('COMPOUND','Compound cách điện / vỏ'), ('ADDITIVE','Phụ gia, lưu hóa'),
  ('COLOR','Màu'), ('TAPE_FILLER','Băng, độn'), ('PRINT_CLEAN','In, vệ sinh'), ('PACK','Đóng gói'), ('SCRAP','Phế liệu');

insert into master.materials (code, name, group_code, uom, is_scrap, check_note) values
  ('PL-CU','Phế đồng (đuôi, đứt dây)','SCRAP','kg',true,'Giá trị 0; bán phế ghi thu nhập khác'),
  ('PL-TC','Phế đồng mạ thiếc','SCRAP','kg',true,'Giá trị 0'),
  ('PL-SIL','Phế silicone','SCRAP','kg',true,'Giá trị 0'),
  ('PL-PVC','Phế PVC / FR-PVC','SCRAP','kg',true,'Giá trị 0'),
  ('PL-LSZH','Phế LSZH','SCRAP','kg',true,'Giá trị 0'),
  ('PL-PE','Phế HDPE','SCRAP','kg',true,'Giá trị 0'),
  ('PL-CABLE','Cáp lỗi / hạ cấp','SCRAP','kg',true,'Giá trị 0'),
  ('PL-PURGE','Purge thải','SCRAP','kg',true,'Giá trị 0');

-- Máy (mã tạm, cần xác nhận số lượng máy thực tế — câu hỏi mở số 3)
insert into master.machines (code, name, machine_type, plc_model, protocol) values
  ('EXT-SI-01','Máy đùn silicone','EXTRUDER_SI','Siemens (chưa xác nhận model)','S7'),
  ('EXT-TP-01','Máy đùn PVC/LSZH/PE','EXTRUDER_TP','Siemens (chưa xác nhận model)','S7'),
  ('BUN-01','Máy bện','BUNCHER','Siemens (chưa xác nhận model)','S7'),
  ('TWS-01','Máy xoắn','TWISTER','Siemens (chưa xác nhận model)','S7'),
  ('PRN-01','Máy in','PRINTER',null,'MODBUS_TCP'),
  ('GAU-01','Máy đo chiều dày / OD','GAUGE',null,'MODBUS_TCP');
update master.machines set inline_with = (select id from master.machines where code = 'EXT-TP-01') where code in ('PRN-01','GAU-01');
