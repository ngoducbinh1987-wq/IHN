-- Kiểm thử migration 20261026003300: phiếu hoàn thành bobin (Kế toán SX nhập), Chờ QC, chặn lắp bobin chưa QC PASS,
-- không tự ký QC, hủy phiếu nhập sai, cảnh báo quá hạn QC, cấu hình duyệt kế hoạch tháng.
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
-- Phiếu mẫu: giờ VN hôm nay
create function pg_temp.slip(p jsonb) returns jsonb language sql as $$
  select app.record_bobbin(jsonb_build_object(
    'wo_id', (select v from t where k = 'wo'),
    'started_at', to_char((now() at time zone 'Asia/Ho_Chi_Minh') - interval '3 hours', 'YYYY-MM-DD"T"HH24:MI'),
    'ended_at', to_char((now() at time zone 'Asia/Ho_Chi_Minh') - interval '1 hour', 'YYYY-MM-DD"T"HH24:MI'),
    'operator_code', 'NV2') || p)
$$;
set client_min_messages = notice;

-- Người dùng thử
with u(code) as (values ('B_KTKHO'),('B_SXTP'),('B_QC'),('B_QCNV1'),('B_VH'),('B_KTTP')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p join (values ('B_KTKHO','KT_KHO'),('B_SXTP','SX_TP'),('B_QC','QC'),('B_QCNV1','QC'),
  ('B_VH','VAN_HANH'),('B_KTTP','KT_TP')) u(code, role) on u.code = p.employee_code;
update core.profiles set status = 'LOCKED' where (employee_code is null or employee_code !~ '^B_') and status = 'ACTIVE';
-- NV1 (người đứng máy) có tài khoản QC: không được tự ký QC cho bobin mình làm
update master.operators set profile_id = (select id from core.profiles where employee_code = 'B_QCNV1') where code = 'NV1';

-- Bobin đánh số cố định, bì 20 kg
insert into inv.carriers (code, carrier_type, tare_kg, owner, status) values
  ('B901', 'B630', 20, 'BMT', 'EMPTY'), ('B902', 'B630', 20, 'BMT', 'EMPTY'), ('B903', 'B630', 20, 'BMT', 'EMPTY');

-- Lệnh SX đã phát: PFR-2C-1P5 1.000 m, công đoạn bện, bọc cách điện, bọc vỏ, đóng gói
insert into mfg.work_orders (wo_no, product_id, spec_id, bom_id, qty_m, m_per_pack, pack_type, brand, status)
select 'LSX-BS1', p.id, p.current_spec_id, (select h.id from master.bom_headers h where h.spec_id = p.current_spec_id limit 1),
       1000, 500, 'Bobin gỗ', 'KAVIX', 'RELEASED'
from master.products p where p.code = 'PFR-2C-1P5';
insert into t select 'wo', id from mfg.work_orders where wo_no = 'LSX-BS1';
insert into mfg.wo_operations (wo_id, op_code, seq, planned_m)
select (select v from t where k = 'wo'), o.code, o.seq, 2000 from master.operations o where o.code in ('CD1', 'CD2', 'CD5', 'CD6');

-- ================================================================ 0. Cấu hình duyệt kế hoạch tháng
select pg_temp.ok((select enabled and role_code = 'BGD' from wf.approval_steps where doc_type = 'PLAN' and seq = 1)
  and (select enabled from wf.approval_steps where doc_type = 'PLAN' and seq = 2)
  and (select submit_role is null from wf.approval_flows where doc_type = 'PLAN'),
  'Kế hoạch tháng: TP SX lập → Giám đốc duyệt → Chủ tịch HĐQT chốt (từ 28/10/2026)');

-- ================================================================ 1. Quyền nhập phiếu
select pg_temp.as_user('B_VH');
select pg_temp.fails($$select pg_temp.slip('{"op_code":"CD1","machine_code":"BUN-01","carrier":"B901","gross_kg":120}')$$,
  'Kế toán SX', 'Vận hành không tự nhập phiếu hoàn thành vào MES');

-- ================================================================ 2. Bện: chỉ kg, mét ước tính; vào Chờ QC
select pg_temp.as_user('B_KTKHO');
select pg_temp.fails($$select pg_temp.slip('{"op_code":"CD1","machine_code":"BUN-01","carrier":"B999","gross_kg":120}')$$,
  'chưa khai báo', 'Số bobin chưa khai báo thì không nhập được');
select pg_temp.fails($$select pg_temp.slip('{"op_code":"CD1","machine_code":"BUN-01","carrier":"B901"}')$$,
  'khối lượng', 'Thiếu kg cân: không nhập được');
select pg_temp.fails($$select pg_temp.slip('{"op_code":"CD1","machine_code":"BUN-01","carrier":"B901","gross_kg":15}')$$,
  'bì bobin', 'Kg cân không lớn hơn bì bobin: báo lỗi');
create temp table s1 as select pg_temp.slip('{"op_code":"CD1","machine_code":"BUN-01","carrier":"B901","gross_kg":120,"operator_code":"NV1",
  "scrap_kg":1.5,"scrap_reason":"SC_STARTUP","materials":"Sợi đồng lô CU-01","paper_no":"G-001"}') as j;
insert into t select 'lot1', id from inv.lots where lot_no = (select j ->> 'lot_no' from s1);
select pg_temp.ok((select (j ->> 'estimated')::boolean and (j ->> 'net_kg')::numeric = 100
                          and abs((j ->> 'qty_m')::numeric - round(100 / (r.metal_kgkm / s.cores) * 1000, 1)) < 0.01
                   from s1, master.products p join master.spec_results r on r.spec_id = p.current_spec_id
                   join master.product_specs s on s.id = p.current_spec_id where p.code = 'PFR-2C-1P5'),
  'Bện: kg tịnh = cân − bì; mét ước tính từ kg ÷ kg/km ruột một lõi');
select pg_temp.ok((select qc_status = 'PENDING' and item_kind = 'WIP' and wip_stage = 'CB' from inv.lots where id = (select v from t where k = 'lot1')),
  'Bobin BTP vừa nhập ở trạng thái Chờ QC (không còn tự Đạt)');
select pg_temp.ok((select status = 'IN_USE' from inv.carriers where code = 'B901'), 'Bobin số B901 chuyển sang đang chứa hàng');
select pg_temp.ok(exists (select 1 from wf.notifications n join core.profiles p on p.id = n.user_id
                          where p.employee_code = 'B_QC' and n.title like 'Bobin chờ QC%'), 'QC nhận thông báo bobin chờ QC');
select pg_temp.ok((select count(*) = 1 from mfg.scrap_records sr join master.materials m on m.id = sr.scrap_material_id
                   where sr.wo_op_id = (select id from mfg.wo_operations where wo_id = (select v from t where k = 'wo') and op_code = 'CD1')
                     and m.code = 'PL-CU' and sr.qty_kg = 1.5), 'Phế của bobin bện ghi vào phế đồng');
select pg_temp.ok((select count(*) = 1 and bool_and(machine_code = 'BUN-01' and operator_code = 'NV1' and slip_no is not null)
                   from app.v_qc_queue where lot_id = (select v from t where k = 'lot1')), 'Hàng chờ QC hiện máy, người làm, số phiếu');
select pg_temp.fails($$select pg_temp.slip('{"op_code":"CD1","machine_code":"BUN-01","carrier":"B901","gross_kg":110}')$$,
  'đang chứa hàng', 'Số bobin đang chứa hàng khác: nhập trùng bị chặn');

-- ================================================================ 3. Chặn lắp bobin chưa QC PASS
select pg_temp.fails($$select pg_temp.slip('{"op_code":"CD2","machine_code":"EXT-SI-01","carrier":"B902","gross_kg":60,"meter_start":0,"meter_end":1500,
  "inputs":[{"code":"B901"}]}')$$, 'QC PASS', 'Bọc cách điện: bobin bện chưa QC PASS không được lắp');
select pg_temp.fails($$select pg_temp.slip('{"op_code":"CD2","machine_code":"EXT-SI-01","carrier":"B902","gross_kg":60,"meter_start":0,"meter_end":1500}')$$,
  'bobin đầu vào', 'Công đoạn sau bắt buộc ghi bobin đầu vào');

-- ================================================================ 4. QC: không tự ký cho bobin mình làm
select pg_temp.as_user('B_QCNV1');
select pg_temp.fails($$select qa.release_lot((select v from t where k = 'lot1'), 'PASS', null, '[]')$$,
  'Không tự ký', 'Người đứng máy NV1 (có tài khoản QC) không tự ký QC PASS bobin mình làm');
select pg_temp.as_user('B_QC');
select qa.release_lot((select v from t where k = 'lot1'), 'PASS', null, '[{"test_code":"COND_DIA","value_num":1.6,"unit":"mm"},{"test_code":"VISUAL","value_text":"Đạt"}]');
select pg_temp.ok((select qc_status = 'PASSED' from inv.lots where id = (select v from t where k = 'lot1'))
  and exists (select 1 from qa.inspections i join qa.test_results tr on tr.inspection_id = i.id
              where i.lot_id = (select v from t where k = 'lot1') and i.insp_type = 'IPQC' and tr.test_code = 'COND_DIA'),
  'QC khác ký PASS: bobin Đạt, lưu số đo');
select pg_temp.ok(exists (select 1 from wf.notifications n join core.profiles p on p.id = n.user_id
                          where p.employee_code = 'B_SXTP' and n.title like 'QC PASS%'), 'TP SX được báo bobin QC PASS');

-- ================================================================ 5. Bọc cách điện: mét theo đồng hồ, tháo bobin còn dư
select pg_temp.as_user('B_KTKHO');
select pg_temp.fails($$select pg_temp.slip('{"op_code":"CD2","machine_code":"EXT-SI-01","carrier":"B902","gross_kg":60,"meter_start":1500,"meter_end":1500,
  "inputs":[{"code":"B901"}]}')$$, 'lớn hơn lúc bắt đầu', 'Đồng hồ mét lúc xong phải lớn hơn lúc bắt đầu');
create temp table h1 as select h.id, h.qty from inv.handling_units h where h.lot_id = (select v from t where k = 'lot1');
create temp table s2 as select pg_temp.slip('{"op_code":"CD2","machine_code":"EXT-SI-01","carrier":"B902","gross_kg":60,"meter_start":200,"meter_end":1700,
  "inputs":[{"code":"B901","left_kg":10}],"readings":{"spark_faults":0,"od_mm":2.07}}') as j;
insert into t select 'lot2', id from inv.lots where lot_no = (select j ->> 'lot_no' from s2);
insert into t select 'slip2', (j ->> 'slip_id')::uuid from s2;
select pg_temp.ok((select (j ->> 'qty_m')::numeric = 1500 and not (j ->> 'estimated')::boolean from s2), 'Mét lõi = đồng hồ lúc xong − lúc bắt đầu');
select pg_temp.ok((select abs(g.qty_used - round(h1.qty * 0.9, 2)) < 0.01 from mfg.lot_genealogy g, h1
                   where g.child_lot_id = (select v from t where k = 'lot2') and g.parent_lot_id = (select v from t where k = 'lot1')),
  'Bobin bện còn dư 10/100 kg: chỉ trừ 90 % số mét, phả hệ lô ghi đúng');
select pg_temp.ok((select abs(sum(b.qty) - round(h1.qty * 0.1, 2)) < 0.02 from inv.stock_balances b, h1 where b.hu_key = h1.id group by h1.qty)
  and (select gross_kg = 30 from inv.handling_units where id = (select id from h1)),
  'Phần còn lại vẫn trong kho BTP; bobin ghi lại 10 kg + bì để lần lắp sau tính đúng');
select pg_temp.ok((select readings ->> 'od_mm' = '2.07' from app.v_qc_queue where lot_id = (select v from t where k = 'lot2')),
  'QC thấy số đo OD người đứng máy đọc trên chuyền');

-- ================================================================ 6. Hủy phiếu nhập sai
select pg_temp.as_user('B_SXTP');
select pg_temp.fails($$select app.void_bobbin((select v from t where k = 'slip2'), 'Nhập sai')$$, 'Kế toán SX', 'Chỉ Kế toán SX hủy phiếu nhập sai');
select pg_temp.as_user('B_KTKHO');
select pg_temp.fails($$select app.void_bobbin((select v from t where k = 'slip2'), '')$$, 'lý do', 'Hủy phiếu bắt buộc lý do');
select app.void_bobbin((select v from t where k = 'slip2'), 'Nhập sai số đồng hồ');
select pg_temp.ok((select status = 'VOID' from mfg.bobbin_slips where id = (select v from t where k = 'slip2'))
  and (select qc_status = 'REJECTED' from inv.lots where id = (select v from t where k = 'lot2'))
  and (select status = 'EMPTY' from inv.carriers where code = 'B902')
  and (select abs(sum(b.qty) - h1.qty) < 0.02 from inv.stock_balances b, h1 where b.hu_key = h1.id group by h1.qty)
  and not exists (select 1 from mfg.lot_genealogy where child_lot_id = (select v from t where k = 'lot2')),
  'Hủy phiếu: bobin B902 trống lại, bobin bện đầu vào trả đủ số mét về kho BTP, xóa phả hệ');
-- TP SX nhập thay khi Kế toán vắng
update inv.handling_units set gross_kg = 120 where id = (select id from h1);
select pg_temp.as_user('B_SXTP');
create temp table s3 as select pg_temp.slip('{"op_code":"CD2","machine_code":"EXT-SI-01","carrier":"B902","gross_kg":60,"meter_start":200,"meter_end":2000,
  "inputs":[{"code":"B901"}]}') as j;
select pg_temp.ok((select (j ->> 'qty_m')::numeric = 1800 from s3) and (select status = 'EMPTY' from inv.carriers where code = 'B901'),
  'TP SX nhập thay; lắp hết bobin bện thì bobin B901 trống, dùng lại được');
select pg_temp.as_user('B_KTKHO');
select pg_temp.fails($$select app.void_bobbin((select id from mfg.bobbin_slips where lot_id = (select v from t where k = 'lot1')), 'x')$$,
  'đã có kết quả QC', 'Bobin đã QC và đã dùng ở công đoạn sau: không hủy phiếu được');

-- ================================================================ 7. Quá hạn QC 2 giờ
update inv.lots set created_at = now() - interval '3 hours' where lot_no = (select j ->> 'lot_no' from s3);
create temp table qa1 as select qa.qc_wait_alerts() as n1;
create temp table qa2 as select qa.qc_wait_alerts() as n2;
select pg_temp.ok((select n1 >= 1 from qa1) and (select n2 = 0 from qa2)
  and exists (select 1 from wf.notifications n join core.profiles p on p.id = n.user_id where p.employee_code = 'B_KTTP' and n.title like 'Quá hạn QC%'),
  'Chờ QC quá 2 giờ: báo QC và TP KT/QA một lần');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
