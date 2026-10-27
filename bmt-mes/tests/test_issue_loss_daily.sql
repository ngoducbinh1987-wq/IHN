-- Kiểm thử migration 20261026003500 (quy trình final – Đợt 3): phiếu xuất NVL theo lô và NVL thừa do Kế toán SX nhập từ phiếu giấy,
-- báo cáo ca do Kế toán SX nhập (NVL để lại máy, phế cả ca), kg/km ruột thật từ đồng hồ line đùn, hao hụt theo công đoạn,
-- báo cáo ngày + cảnh báo đỏ + giải trình.
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create temp table t (k text primary key, v uuid);

create function pg_temp.as_user(p_code text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', (select id::text from core.profiles where employee_code = p_code), true),
         set_config('request.jwt.claim.role', 'authenticated', true)
$$;
create function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_msg; end if;
  insert into r(msg) values (p_msg);
end $$;
create function pg_temp.fails(p_sql text, p_pattern text, p_msg text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm ilike '%' || p_pattern || '%' then insert into r(msg) values (p_msg || ' → chặn: ' || sqlerrm); return; end if;
    raise exception 'FAIL: % — lỗi khác mong đợi: %', p_msg, sqlerrm;
  end;
  raise exception 'FAIL: % — lẽ ra phải báo lỗi', p_msg;
end $$;
create function pg_temp.today() returns date language sql as $$ select (now() at time zone 'Asia/Ho_Chi_Minh')::date $$;
create function pg_temp.slip(p jsonb) returns jsonb language sql as $$
  select app.record_bobbin(jsonb_build_object(
    'wo_id', (select v from t where k = 'wo'),
    'started_at', to_char((now() at time zone 'Asia/Ho_Chi_Minh') - interval '3 minutes', 'YYYY-MM-DD"T"HH24:MI'),
    'ended_at', to_char((now() at time zone 'Asia/Ho_Chi_Minh') - interval '1 minute', 'YYYY-MM-DD"T"HH24:MI'),
    'operator_code', 'NV2') || p)
$$;
create function pg_temp.hu(p_mat text, p_n int) returns text language sql as $$
  select h.hu_no from inv.handling_units h join inv.lots l on l.id = h.lot_id join master.materials m on m.id = l.material_id
  where m.code = p_mat and l.attrs ? 'dl_test' order by h.hu_no offset p_n - 1 limit 1
$$;
set client_min_messages = notice;

-- Người dùng thử
with u(code) as (values ('D_KTKHO'),('D_SXTP'),('D_BGD'),('D_VH'),('D_QC'),('D_NONE'),('D_KTT')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('D_KTKHO','KT_KHO'),('D_SXTP','SX_TP'),('D_BGD','BGD'),('D_VH','VAN_HANH'),('D_QC','QC'),('D_KTT','KTT'))
  u(code, role) on u.code = p.employee_code;
update core.profiles set status = 'LOCKED' where (employee_code is null or employee_code !~ '^D_') and status = 'ACTIVE';
update master.operators set profile_id = null where profile_id is not null;

insert into inv.carriers (code, carrier_type, tare_kg, owner, status) values
  ('D901', 'B630', 20, 'BMT', 'EMPTY'), ('D902', 'B630', 20, 'BMT', 'EMPTY'), ('D903', 'B630', 20, 'BMT', 'EMPTY');

-- Lệnh SX PFR-2C-1P5 (2 lõi): bện, bọc cách điện silicone, bọc vỏ, đóng gói
insert into mfg.work_orders (wo_no, product_id, spec_id, bom_id, qty_m, m_per_pack, pack_type, brand, status)
select 'LSX-DL1', p.id, p.current_spec_id, (select h.id from master.bom_headers h where h.spec_id = p.current_spec_id limit 1),
       3000, 500, 'Bobin gỗ', 'KAVIX', 'RELEASED'
from master.products p where p.code = 'PFR-2C-1P5';
insert into t select 'wo', id from mfg.work_orders where wo_no = 'LSX-DL1';
insert into mfg.wo_operations (wo_id, op_code, seq, planned_m)
select (select v from t where k = 'wo'), o.code, o.seq, 6000 from master.operations o where o.code in ('CD1', 'CD2', 'CD5', 'CD6');

-- Tồn kho NVL: 2 ống đồng × 100 kg, 1 bao silicone 50 kg, 1 bao PVC 80 kg
select pg_temp.as_user('D_KTKHO');
insert into t select 'op', inv.create_opening(inv.wh('KNL'), pg_temp.today(),
  '[{"code":"CU-024","qty":200,"unit_cost":250000,"units":2},{"code":"SIL-9710G","qty":50,"unit_cost":90000},{"code":"PVC-FR","qty":80,"unit_cost":40000}]');
select pg_temp.as_user('D_KTT');
select wf.act((select id from wf.approval_requests where doc_id = (select v from t where k = 'op')), 'APPROVE');
select pg_temp.as_user('D_KTKHO');
update inv.lots set attrs = attrs || '{"dl_test": true}' where id in (select lot_id from inv.stock_doc_lines where doc_id = (select v from t where k = 'op'));
-- Phiếu lĩnh theo lệnh ngày (đã duyệt)
insert into inv.requisitions (req_no, wo_id, kind, work_date, status, note)
values ('PL-DL1', (select v from t where k = 'wo'), 'NORM', pg_temp.today(), 'APPROVED', 'thử');
insert into t select 'req', id from inv.requisitions where req_no = 'PL-DL1';
insert into inv.requisition_lines (req_id, material_id, qty_norm, qty_req)
select (select v from t where k = 'req'), m.id, q, q from (values ('CU-024', 150), ('SIL-9710G', 50), ('PVC-FR', 70)) v(code, q)
join master.materials m on m.code = v.code;

-- ================================================================ 1. Phiếu xuất NVL theo lô: Kế toán SX nhập phiếu đã ký
select pg_temp.as_user('D_VH');
select pg_temp.fails($$select app.paper_issue((select v from t where k = 'req'), '{"receiver_code":"NV1","items":[]}')$$,
  'Kế toán SX', 'Công nhân không tự nhập phiếu xuất NVL vào MES');
select pg_temp.as_user('D_KTKHO');
select pg_temp.fails($$select app.paper_issue((select v from t where k = 'req'), jsonb_build_object('items', jsonb_build_array(jsonb_build_object('code', pg_temp.hu('CU-024', 1)))))$$,
  'NV lấy NVL', 'Phiếu xuất phải ghi NV lấy NVL đã ký nhận');
create temp table is1 as select app.paper_issue((select v from t where k = 'req'), jsonb_build_object('receiver_code', 'nv1', 'paper_no', 'PX-001',
  'items', jsonb_build_array(jsonb_build_object('code', pg_temp.hu('CU-024', 1)), jsonb_build_object('code', pg_temp.hu('CU-024', 2), 'qty', 30),
                             jsonb_build_object('code', pg_temp.hu('SIL-9710G', 1)), jsonb_build_object('code', pg_temp.hu('PVC-FR', 1), 'qty', 70)))) as j;
select pg_temp.ok((select d.doc_type = 'ISSUE_WO' and d.status = 'POSTED' and d.paper_no = 'PX-001' and d.receiver_code = 'NV1'
                          and d.receiver_id is null and d.received_at is not null
                   from inv.stock_docs d where d.id = (select (j ->> 'doc_id')::uuid from is1)),
  'Phiếu xuất ghi sổ: số phiếu giấy, NV1 ký nhận (không cần tài khoản), người nhập là Kế toán SX');
select pg_temp.ok((select qty_issued = 130 from inv.requisition_lines rl join master.materials m on m.id = rl.material_id
                   where rl.req_id = (select v from t where k = 'req') and m.code = 'CU-024')
  and (select status = 'PARTIAL' from inv.requisitions where id = (select v from t where k = 'req'))
  and (select status = 'EMPTY' from inv.handling_units where hu_no = pg_temp.hu('CU-024', 1))
  and (select qty = 70 from inv.handling_units where hu_no = pg_temp.hu('CU-024', 2)),
  'Xuất 1 ống nguyên + 30 kg ống thứ hai: trừ đúng tồn từng ống, phiếu lĩnh còn thiếu → Đang cấp');
select pg_temp.ok(exists (select 1 from app.v_wo_mat_docs where wo_no = 'LSX-DL1' and doc_type = 'ISSUE_WO' and paper_no = 'PX-001' and lines like '%CU-024%'),
  'Danh sách phiếu xuất NVL theo lô cho Kế toán SX đối soát');

-- ================================================================ 2. NVL thừa cuối ngày nhập lại kho
select pg_temp.fails($$select app.paper_return(jsonb_build_object('giver_code', 'NV1', 'items', jsonb_build_array(jsonb_build_object('code', pg_temp.hu('CU-024', 2), 'qty', 40))))$$,
  'tối đa', 'Không nhận lại nhiều hơn số đã xuất từ ống đó');
create temp table rt1 as select app.paper_return(jsonb_build_object('giver_code', 'NV1', 'paper_no', 'PN-001',
  'items', jsonb_build_array(jsonb_build_object('code', pg_temp.hu('CU-024', 2), 'qty', 10), jsonb_build_object('code', pg_temp.hu('SIL-9710G', 1), 'qty', 3)))) as j;
select pg_temp.ok((select jsonb_array_length(j) = 2 from rt1)
  and (select qty = 80 from inv.handling_units where hu_no = pg_temp.hu('CU-024', 2))
  and (select status = 'ACTIVE' and qty = 3 from inv.handling_units where hu_no = pg_temp.hu('SIL-9710G', 1))
  and (select count(*) = 2 from inv.stock_docs where doc_type = 'RETURN_WO' and paper_no = 'PN-001' and receiver_code = 'NV1'),
  'Phiếu nhập NVL thừa: đồng 10 kg, silicone 3 kg về đúng ống/bao cũ, ghi số phiếu và người trả');

-- ================================================================ 3. Phiếu hoàn thành: kg bobin đầu vào đã dùng → kg/km ruột thật
-- Bện: 125 kg cân − 20 bì = 105 kg ruột
create temp table s1 as select pg_temp.slip('{"op_code":"CD1","machine_code":"BUN-01","carrier":"D901","gross_kg":125}') as j;
insert into t select 'lot1', id from inv.lots where lot_no = (select j ->> 'lot_no' from s1);
select pg_temp.as_user('D_QC');
select qa.release_lot((select v from t where k = 'lot1'), 'PASS', null, '[]');
-- Bọc cách điện: tháo bobin bện còn 25 kg (dùng 80 kg); đồng hồ line đùn 6.400 m; lõi cân 142 kg (122 kg tịnh)
select pg_temp.as_user('D_KTKHO');
create temp table s2 as select pg_temp.slip('{"op_code":"CD2","machine_code":"EXT-SI-01","carrier":"D902","gross_kg":142,"meter_start":0,"meter_end":6400,
  "inputs":[{"code":"D901","left_kg":25}]}') as j;
insert into t select 'lot2', id from inv.lots where lot_no = (select j ->> 'lot_no' from s2);
select pg_temp.ok((select (inputs -> 0 ->> 'used_kg')::numeric = 80 and inputs -> 0 ->> 'stage' = 'CB' from mfg.bobbin_slips where lot_id = (select v from t where k = 'lot2')),
  'Phiếu bọc ghi kg ruột đã dùng = 105 − 25 kg còn dư');
select pg_temp.ok((select true_used_kg = 80 and true_m = 6400 from app.v_bobbin_slips where lot_no = (select j ->> 'lot_no' from s1)),
  'Bobin bện hiện mét thật theo đồng hồ line đùn (80 kg → 6.400 m)');
select pg_temp.as_user('D_QC');
select qa.release_lot((select v from t where k = 'lot2'), 'PASS', null, '[]');
-- Bọc vỏ: 3.100 m cáp, 202 kg cân (182 kg tịnh), lắp hết bobin lõi
select pg_temp.as_user('D_KTKHO');
create temp table s3 as select pg_temp.slip('{"op_code":"CD5","machine_code":"EXT-TP-01","carrier":"D903","gross_kg":202,"meter_start":1000,"meter_end":4100,
  "inputs":[{"code":"D902"}]}') as j;
select pg_temp.ok((select (inputs -> 0 ->> 'used_kg')::numeric = 122 and (inputs -> 0 ->> 'used_m')::numeric = 6400 from mfg.bobbin_slips
                   where slip_no = (select j ->> 'slip_no' from s3)), 'Phiếu bọc vỏ ghi mét và kg lõi đã dùng');

-- ================================================================ 4. Báo cáo ca do Kế toán SX nhập từ tờ giấy
select pg_temp.fails($$select app.kh_save_report(pg_temp.today(), 'BUN-01', '{"operator_code":"NV2","keeps":[{"material_code":"XX-9","kg":8,"wo_no":"LSX-DL1"}]}')$$,
  'không có mã vật tư', 'NVL để lại máy: mã vật tư sai bị chặn');
select pg_temp.fails($$select app.kh_save_report(pg_temp.today(), 'BUN-01', '{"operator_code":"NV2","scraps":[{"wo_no":"LSX-DL1","op_code":"CD1","kg":2}]}')$$,
  'chọn lý do', 'Phế cả ca phải có lý do');
insert into t select 'rep1', app.kh_save_report(pg_temp.today(), 'BUN-01', '{"operator_code":"NV2",
  "lines":[{"key":"x","declared_m":0}],"samples":[{"kind":"Mẫu đầu ca","status":"PENDING"}],
  "keeps":[{"material_code":"CU-024","kg":8,"wo_no":"LSX-DL1"}],
  "scraps":[{"wo_no":"LSX-DL1","op_code":"CD1","reason":"SC_STARTUP","kg":2}],
  "downtime":[{"from":"09:00","to":"09:20","min":20,"reason":"DT_COLOR"}]}');
select pg_temp.ok((select scrap_kg = 2 and scrap_reason = 'SC_STARTUP' and jsonb_array_length(keeps) = 1 from mfg.shift_reports where id = (select v from t where k = 'rep1')),
  'Kế toán SX lưu báo cáo ca: đồng 8 kg còn trên giá xả chạy tiếp, phế khởi động 2 kg');
select app.kh_submit_report((select v from t where k = 'rep1'));
select pg_temp.ok((select status = 'SUBMITTED' from mfg.shift_reports where id = (select v from t where k = 'rep1'))
  and exists (select 1 from wf.notifications n join core.profiles p on p.id = n.user_id where p.employee_code = 'D_SXTP' and n.title like 'Báo cáo ca BUN-01 chờ chốt%'),
  'Gửi chốt ca (mẫu chưa đánh giá không chặn: QC kiểm từng bobin); TP SX được báo');
insert into t select 'rep2', app.kh_save_report(pg_temp.today(), 'EXT-TP-01', '{"operator_code":"NV1","samples":[{"kind":"Mẫu đầu ca","status":"NG"}],
  "keeps":[{"material_code":"PVC-FR","kg":2,"wo_no":"LSX-DL1"}]}');
select pg_temp.fails($$select app.kh_submit_report((select v from t where k = 'rep2'))$$, 'không đạt', 'Mẫu bị đánh Không đạt thì chưa gửi được');
select pg_temp.fails($$select app.kh_confirm_report((select v from t where k = 'rep1'), null)$$, 'xác nhận ca', 'Kế toán SX không chốt ca');
select pg_temp.as_user('D_SXTP');
select app.kh_confirm_report((select v from t where k = 'rep1'), null);
select pg_temp.ok((select count(*) = 1 and sum(sr.qty_kg) = 2 and bool_and(m.code = 'PL-CU') from mfg.scrap_records sr join master.materials m on m.id = sr.scrap_material_id
                   where sr.shift_report_id = (select v from t where k = 'rep1')),
  'TP SX chốt ca: phế cả ca ghi vào sổ phế đồng của lô');

-- ================================================================ 5. Hao hụt theo công đoạn (tính đến hết hôm nay)
select pg_temp.as_user('D_BGD');
create temp table ls as select * from app.loss_stages((select v from t where k = 'wo'), null);
-- Bện: vào = 130 − 10 trả − 8 trên giá xả = 112 kg; ra 105 kg; định mức 105 / (1 − 1,5 %) = 106,6 kg → vượt 5,1 % > 2 % → đỏ
select pg_temp.ok((select in_qty = 112 and out_qty = 105 and loss_qty = 7 and level = 'RED' and abs(var_pct - round((112 - 105 / 0.985) / (105 / 0.985) * 100, 2)) < 0.01
                   from ls where stage = 'CD1_CU'),
  'Bện – đồng: cấp ròng 112 kg (trừ trả kho, trừ đồng trên giá xả), ruột 105 kg, vượt định mức 5,1 % → Đỏ');
select pg_temp.ok((select in_qty = 80 and out_qty = 6400 and level = 'YELLOW' from ls where stage = 'CD2_CU'),
  'Bọc – ruột thật 80 kg / 6,4 km = 12,5 kg/km so với thiết kế 12,36: cho thừa 1,1 % → Vàng');
select pg_temp.ok((select in_qty = 47 and out_qty = 42 and level = 'GREEN' from ls where stage = 'CD2_PL'),
  'Bọc – nhựa: cấp 50 − trả 3 = 47 kg, nhựa trên lõi 122 − 80 = 42 kg, trong định mức (gồm phế khởi động) → Xanh');
select pg_temp.ok((select in_qty = 6400 and out_qty = round(3100 * 2 * 1.02, 1) and level = 'YELLOW' from ls where stage = 'CD5_M'),
  'Bọc vỏ – mét: 6.400 m lõi vào, 3.100 m cáp × 2 lõi × hệ số xoắn 1,02 ra → vượt định mức 1 %, trong ngưỡng → Vàng');
select pg_temp.ok((select in_qty = 68 and out_qty = 60 and level = 'YELLOW' from ls where stage = 'CD5_PL'),
  'Bọc vỏ – nhựa: cấp 70 − 2 kg còn trong phễu = 68 kg, nhựa trên cáp 182 − 122 = 60 kg → Vàng');
select pg_temp.as_user('D_NONE');
select pg_temp.fails($$select app.loss_stages((select v from t where k = 'wo'), null)$$, 'Không có quyền', 'Người không có quyền không xem hao hụt');
select pg_temp.fails($$select app.daily_report(pg_temp.today())$$, 'Không có quyền', 'Người không có quyền không xem báo cáo ngày');

-- ================================================================ 6. Báo cáo ngày, gửi cảnh báo, giải trình
select pg_temp.as_user('D_BGD');
create temp table dr as select app.daily_report(pg_temp.today()) as j;
select pg_temp.ok((select jsonb_array_length(j -> 'production') = 3 and (j -> 'counts' ->> 'RED')::int = 1
                          and (select count(*) from jsonb_array_elements(j -> 'loss')) = 5
                          and exists (select 1 from jsonb_array_elements(j -> 'materials') e where e ->> 'material_code' = 'CU-024' and (e ->> 'issued')::numeric = 130 and (e ->> 'returned')::numeric = 10)
                          and exists (select 1 from jsonb_array_elements(j -> 'shifts') e where e ->> 'machine_code' = 'BUN-01' and e ->> 'status' = 'CONFIRMED' and (e ->> 'downtime_min')::numeric = 20)
                          and exists (select 1 from jsonb_array_elements(j -> 'shifts') e where e ->> 'machine_code' = 'EXT-SI-01' and e ->> 'status' = 'MISSING')
                   from dr),
  'Báo cáo ngày: sản lượng 3 máy, NVL xuất/trả theo lô, báo cáo ca (máy chưa có báo cáo ca hiện Thiếu), 5 mục hao hụt, 1 đỏ');
select pg_temp.as_user('D_VH');
select pg_temp.fails($$select app.send_daily_report(pg_temp.today())$$, 'Kế toán SX', 'Công nhân không gửi báo cáo ngày');
select pg_temp.as_user('D_KTKHO');
select app.send_daily_report(pg_temp.today());
select pg_temp.ok((select not auto and jsonb_array_length(summary -> 'red') = 1 from mfg.daily_reports where work_date = pg_temp.today())
  and exists (select 1 from wf.notifications n join core.profiles p on p.id = n.user_id where p.employee_code = 'D_BGD' and n.title like 'Cảnh báo đỏ hao hụt%' and n.body like '%LSX-DL1%')
  and exists (select 1 from wf.notifications n join core.profiles p on p.id = n.user_id where p.employee_code = 'D_SXTP' and n.title like 'Giải trình hao hụt đỏ%')
  and exists (select 1 from wf.notifications n join core.profiles p on p.id = n.user_id where p.employee_code = 'D_KTKHO' and n.title like 'Báo cáo sản xuất ngày%'),
  'Kế toán SX gửi báo cáo ngày sau đối soát: mọi bộ phận nhận báo cáo, Giám đốc nhận cảnh báo đỏ, TP SX nhận việc giải trình');
select pg_temp.ok(mfg.daily_report_auto() = 0, '19:30 MES không gửi lại khi Kế toán SX đã gửi');
select pg_temp.fails($$select app.save_loss_note((select v from t where k = 'wo'), 'CD1_CU', pg_temp.today(), 'x')$$, 'TP SX', 'Kế toán SX không giải trình thay TP SX');
select pg_temp.as_user('D_SXTP');
select pg_temp.fails($$select app.save_loss_note((select v from t where k = 'wo'), 'CD1_CU', pg_temp.today(), ' ')$$, 'nội dung', 'Giải trình bắt buộc có nội dung');
select app.save_loss_note((select v from t where k = 'wo'), 'CD1_CU', pg_temp.today(), 'Đứt sợi nhiều lần khi đổi ống, đã chỉnh căng sợi');
select pg_temp.ok((select level = 'RED' from mfg.loss_notes where wo_id = (select v from t where k = 'wo') and stage = 'CD1_CU')
  and exists (select 1 from wf.notifications n join core.profiles p on p.id = n.user_id where p.employee_code = 'D_BGD' and n.title like 'Đã giải trình hao hụt đỏ%')
  and (select count(*) = 1 from jsonb_array_elements(app.daily_report(pg_temp.today()) -> 'loss') e where e ->> 'note' like 'Đứt sợi%'),
  'TP SX giải trình mục đỏ: Giám đốc được báo, báo cáo ngày hiện giải trình');
-- 10:00 hôm sau: mục đỏ ngày trước chưa giải trình → báo Giám đốc + TP SX một lần
reset role;
insert into mfg.daily_reports (work_date, auto, summary) values (pg_temp.today() - 1, true,
  jsonb_build_object('red', jsonb_build_array(jsonb_build_object('wo_id', (select v from t where k = 'wo'), 'wo_no', 'LSX-DL1', 'stage', 'CD5_PL', 'label', 'Bọc vỏ – nhựa vỏ'))));
create temp table ln as select mfg.loss_note_check() as a, mfg.loss_note_check() as b;
select pg_temp.ok((select a = 1 and b = 0 from ln)
  and exists (select 1 from wf.notifications n join core.profiles p on p.id = n.user_id where p.employee_code = 'D_BGD' and n.title like 'Chưa giải trình hao hụt đỏ%'),
  'Quá 10:00 chưa giải trình mục đỏ: báo Giám đốc và TP SX một lần');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
