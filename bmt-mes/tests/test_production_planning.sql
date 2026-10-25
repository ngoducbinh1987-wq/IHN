-- Kiểm thử module Kế hoạch sản xuất (2200). Chạy trong transaction rồi rollback, không để lại dữ liệu.
create temp table t_res (n serial, name text, ok boolean, msg text) on commit drop;
grant all on t_res to authenticated; grant all on sequence t_res_n_seq to authenticated;

create or replace function pg_temp.as_user(p_name text) returns void language plpgsql as $$
declare v uuid;
begin
  reset role;
  select id into v from core.profiles where full_name = p_name;
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
end $$;
create or replace function pg_temp.expect(p_name text, p_sql text, p_should_pass boolean, p_like text default null) returns void language plpgsql as $$
declare m text;
begin
  begin
    execute p_sql;
    insert into t_res (name, ok, msg) values (p_name, p_should_pass, 'chạy được');
  exception when others then
    m := sqlerrm;
    insert into t_res (name, ok, msg) values (p_name, (not p_should_pass) and (p_like is null or m like '%' || p_like || '%'), m);
  end;
end $$;

-- Vai trò thật (26/10/2026): Minh = BGD + SX_KH, Lực = KT_TP + QC, Hương = MUA_TP, Trang = KTT, Bình = đủ vai trò (chạy thử)
-- Hương (Mua hàng): xem được, không sửa được gì
select pg_temp.as_user('Dương Thu Hương');
select pg_temp.expect('Hương xem tham số', 'do $x$ begin if (select count(*) from app.v_kh_config) <> 1 then raise exception ''không thấy''; end if; end $x$', true);
select pg_temp.expect('Hương sửa tham số → chặn', $q$select app.kh_save_config('{"fill_pct":80}', 'thử')$q$, false, 'Chỉ Giám đốc');
select pg_temp.expect('Hương sửa tốc độ → chặn', $q$select app.kh_save_rates('[{"op_code":"CD1","rate_small":90,"rate_large":80}]', 'thử')$q$, false, 'TP Kỹ thuật');
select pg_temp.expect('Hương xếp lịch → chặn', $q$select app.kh_save_schedule((select id from plan.production_plans limit 1), date '2026-11-02', '{}', '[]', '[]', 'x')$q$, false, 'Quản lý SX');

-- Minh (Giám đốc + Quản lý SX kế hoạch)
select pg_temp.as_user('Trần Đức Minh');
select pg_temp.expect('Minh sửa tham số không lý do → chặn', $q$select app.kh_save_config('{"fill_pct":80}', '')$q$, false, 'lý do');
select pg_temp.expect('Minh sửa tham số ngoài khoảng → chặn', $q$select app.kh_save_config('{"fill_pct":99}', 'thử')$q$, false, 'ngoài khoảng');
select pg_temp.expect('Minh sửa tỷ lệ 80%', $q$select app.kh_save_config('{"fill_pct":80,"frozen_days":3}', 'Chạy thử tháng đầu')$q$, true);
select pg_temp.expect('Minh bật ca B', $q$select app.kh_save_shifts('[{"code":"B","start_time":"14:00","end_time":"22:00","break_min":30,"active":true}]', 'Tăng ca')$q$, true);
select pg_temp.expect('Minh tắt ca A → chặn', $q$select app.kh_save_shifts('[{"code":"A","start_time":"06:00","end_time":"14:00","break_min":30,"active":false}]', 'x')$q$, false, 'Ca A');
select pg_temp.expect('Minh sửa tốc độ → chặn (việc của TP KT)', $q$select app.kh_save_rates('[{"op_code":"CD1","rate_small":95,"rate_large":80}]', 'x')$q$, false, 'TP Kỹ thuật');
select pg_temp.expect('Minh chuyển máy sang PLC khi chưa có tag → chặn', $q$select app.kh_set_machine_mode('EXT-SI-01', 'BOTH', 'thử')$q$, false, 'tag PLC');
select pg_temp.expect('Minh đặt hạn giao', $q$select app.kh_set_line((select id from plan.plan_lines limit 1), date '2026-11-20', 0::smallint)$q$, true);
select pg_temp.expect('Minh phát lệnh khi KH chưa duyệt → chặn', $q$select app.kh_release_day((select id from plan.production_plans limit 1), date '2026-11-02', null, '[]', '[]')$q$, false, 'chưa được duyệt');
select pg_temp.expect('Minh lưu lịch máy', $q$select app.kh_save_schedule((select id from plan.production_plans limit 1), date '2026-11-02', '{"S":383}',
  json_build_array(json_build_object('plan_line_id', (select id from plan.plan_lines limit 1), 'label','L1','product_code','x','qty_m',100))::jsonb,
  json_build_array(json_build_object('plan_line_id', (select id from plan.plan_lines limit 1), 'op_code','CD1','machine_code','BUN-01','operator_code','NV2','start_min',0,'run_start_min',0,'end_min',10,'meters',1000,'rate',100,'speed',100))::jsonb,
  'Lịch đầu')$q$, true);
select pg_temp.expect('Đổi ngày bắt đầu khi đã có lịch → chặn', $q$select app.kh_set_sched_start((select id from plan.production_plans limit 1), date '2026-11-03')$q$, false, 'Đã có lịch');
select pg_temp.expect('Minh lập đơn phát sinh mức C', $q$select app.kh_create_change((select id from plan.production_plans limit 1),
  '{"product_code":"PFR-2C-1","qty_m":3000,"due_date":"2026-11-10","priority":"0"}', '{}', 'C',
  '[{"role":"SX_TP","label":"Quản lý SX lập"},{"role":"KT_TP","label":"TP Kỹ thuật/QA cho ý kiến"},{"role":"BGD","label":"Giám đốc duyệt"}]')$q$, true);
select pg_temp.expect('Minh duyệt thay bước KT → chặn', $q$select app.kh_change_step((select id from plan.change_requests limit 1), 'approve')$q$, false, 'chờ TP Kỹ thuật');
select pg_temp.expect('Minh nhập báo cáo ca → chặn', $q$select app.kh_save_report(date '2026-11-02', 'EXT-SI-01', '{}')$q$, false, 'vận hành');

-- Lực (TP Kỹ thuật/QA + QC)
select pg_temp.as_user('Nguyễn Văn Lực');
select pg_temp.expect('Lực sửa tham số chung → chặn', $q$select app.kh_save_config('{"fill_pct":80}', 'x')$q$, false, 'Chỉ Giám đốc');
select pg_temp.expect('Lực sửa tốc độ CD1', $q$select app.kh_save_rates('[{"op_code":"CD1","rate_small":95,"rate_large":80}]', 'Chạy thử đạt 95')$q$, true);
select pg_temp.expect('Lực sửa phút đổi máy', $q$select app.kh_save_changeovers('[{"code":"INS_DOWN","minutes":40}]', 'Purge lâu hơn')$q$, true);
select pg_temp.expect('Lực sửa tốc độ ngoài khoảng → chặn', $q$select app.kh_save_rates('[{"op_code":"CD1","rate_small":500,"rate_large":80}]', 'x')$q$, false, 'từ 5 đến 300');
select pg_temp.expect('Nhật ký có 4 dòng', 'do $x$ begin if (select count(*) from app.v_kh_param_log where at >= now()) <> 4 then raise exception ''sai số dòng %'', (select count(*) from app.v_kh_param_log where at >= now()); end if; end $x$', true);
select pg_temp.expect('Lực cho ý kiến KT', $q$select app.kh_change_step((select id from plan.change_requests limit 1), 'approve', 'Đồng ý, cần purge')$q$, true);
select pg_temp.expect('Lực duyệt mẫu đầu ca: đạt', $q$select app.kh_sample(date '2026-11-02', 'EXT-SI-01', '[{"kind":"Đầu ca","product_code":"PFR-2C-1","status":"PENDING"}]', 0, 'OK')$q$, true);
select pg_temp.expect('Lực phát lệnh → chặn', $q$select app.kh_release_day((select id from plan.production_plans limit 1), date '2026-11-02', null, '[]', '[]')$q$, false, 'Quản lý SX');

-- Minh (người lập) duyệt bước Giám đốc của chính đề nghị mình → chặn
select pg_temp.as_user('Trần Đức Minh');
select pg_temp.expect('Minh tự duyệt đề nghị mình lập → chặn', $q$select app.kh_change_step((select id from plan.change_requests limit 1), 'approve')$q$, false, 'không tự duyệt');

-- Bình (đủ vai trò): duyệt GĐ, thêm dòng, nhập + gửi + xác nhận ca
select pg_temp.as_user('Ngô Đức Bình');
select pg_temp.expect('Bình trả lại không lý do → chặn', $q$select app.kh_change_step((select id from plan.change_requests limit 1), 'return', '')$q$, false, 'lý do trả lại');
select pg_temp.expect('Bình duyệt bước Giám đốc', $q$do $x$ begin if app.kh_change_step((select id from plan.change_requests limit 1), 'approve') <> 'READY' then raise exception 'chưa READY'; end if; end $x$$q$, true);
select pg_temp.expect('Thêm dòng kế hoạch từ đơn phát sinh', $q$do $x$ declare v uuid; begin v := app.kh_change_add_line((select id from plan.change_requests limit 1));
  if not exists (select 1 from plan.plan_lines where id = v and priority = 0 and due_date = '2026-11-10') then raise exception 'dòng sai'; end if; end $x$$q$, true);
select pg_temp.expect('Bình lưu báo cáo ca (dừng chưa lý do)', $q$select app.kh_save_report(date '2026-11-02', 'EXT-SI-01', '{"operator_code":"NV1","lines":[{"label":"x","declared_m":1000}],"downtime":[{"min":12,"reason":""}]}')$q$, true);
select pg_temp.expect('Mẫu đã duyệt vẫn giữ sau khi lưu', $q$do $x$ begin if (select samples->0->>'status' from mfg.shift_reports where machine_code='EXT-SI-01' and work_date='2026-11-02') <> 'OK' then raise exception 'mất mẫu'; end if; end $x$$q$, true);
select pg_temp.expect('Gửi khi dừng máy chưa có lý do → chặn', $q$select app.kh_submit_report((select id from mfg.shift_reports where machine_code='EXT-SI-01' and work_date='2026-11-02'))$q$, false, 'chưa chọn lý do');
select pg_temp.expect('Lưu lại có lý do', $q$select app.kh_save_report(date '2026-11-02', 'EXT-SI-01', '{"operator_code":"NV1","lines":[{"label":"x","declared_m":1000}],"downtime":[{"min":12,"reason":"Đứt dây"}]}')$q$, true);
select pg_temp.expect('Gửi báo cáo', $q$select app.kh_submit_report((select id from mfg.shift_reports where machine_code='EXT-SI-01' and work_date='2026-11-02'))$q$, true);
select pg_temp.expect('Sửa sau khi gửi → chặn', $q$select app.kh_save_report(date '2026-11-02', 'EXT-SI-01', '{}')$q$, false, 'đã gửi');
select pg_temp.expect('Xác nhận ca', $q$select app.kh_confirm_report((select id from mfg.shift_reports where machine_code='EXT-SI-01' and work_date='2026-11-02'), null)$q$, true);

-- Trang (Kế toán trưởng): xem được
select pg_temp.as_user('Trần Thị Thu Trang');
select pg_temp.expect('Trang xem báo cáo ca', $q$do $x$ begin if (select count(*) from app.v_kh_reports) <> 1 then raise exception 'không thấy'; end if; end $x$$q$, true);
select pg_temp.expect('Trang duyệt phiếu lĩnh → chặn (việc của KT kho)', $q$select app.kh_approve_slip(gen_random_uuid())$q$, false, 'Kế toán kho');

reset role;
select pg_temp.expect('Có thông báo đơn phát sinh', $q$do $x$ begin if (select count(*) from wf.notifications where title like 'Đơn phát sinh%' and created_at > now() - interval '1 minute') < 3 then raise exception 'thiếu'; end if; end $x$$q$, true);

-- In kết quả qua thông báo lỗi để chắc chắn rollback toàn bộ
do $x$ begin raise exception E'KET QUA %/% dat\n%', (select count(*) filter (where ok) from t_res), (select count(*) from t_res),
  (select string_agg(n || '. ' || case when ok then 'ĐẠT ' else 'LỖI ' end || name || ' — ' || msg, E'\n' order by n) from t_res); end $x$;
