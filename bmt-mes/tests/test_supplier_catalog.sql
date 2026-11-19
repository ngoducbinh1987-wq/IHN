-- Kiểm thử migration 20261026010300: Danh mục nhà cung cấp – quyền thêm / sửa / ngừng dùng / xóa, mặt hàng NCC bán được,
-- đơn mua chỉ chọn được NCC đã khai báo bán vật tư của dòng.
-- Chạy được bằng psql hoặc Supabase SQL Editor / MCP execute_sql. Kết thúc bằng "lỗi" KET_QUA_OK để ROLLBACK.
set client_min_messages = warning;
begin;
create temp table r (n serial, msg text);
create temp table t (k text primary key, v uuid);
grant all on r, t to authenticated;
grant usage on sequence r_n_seq to authenticated;

create function pg_temp.as_user(p_code text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', (select id::text from core.profiles where employee_code = p_code), true),
         set_config('request.jwt.claim.role', 'authenticated', true)
$$;
create function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_msg; end if;
  insert into r(msg) values (p_msg);
end $$;
create function pg_temp.blocked(p_sql text, p_pattern text, p_msg text) returns void language plpgsql as $$
begin
  begin
    execute 'set local role authenticated';
    execute p_sql;
    execute 'reset role';
  exception when others then
    execute 'reset role';
    if sqlerrm ilike '%' || p_pattern || '%' then insert into r(msg) values (p_msg || ' → chặn: ' || sqlerrm); return; end if;
    raise exception 'FAIL: % — lỗi khác mong đợi: %', p_msg, sqlerrm;
  end;
  raise exception 'FAIL: % — lẽ ra phải bị chặn', p_msg;
end $$;
-- Lệnh chạy bằng quyền chủ sở hữu (mô phỏng hàm SECURITY DEFINER của đơn mua) phải bị trigger chặn
create function pg_temp.blocked_owner(p_sql text, p_pattern text, p_msg text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm ilike '%' || p_pattern || '%' then insert into r(msg) values (p_msg || ' → chặn: ' || sqlerrm); return; end if;
    raise exception 'FAIL: % — lỗi khác mong đợi: %', p_msg, sqlerrm;
  end;
  raise exception 'FAIL: % — lẽ ra phải bị chặn', p_msg;
end $$;
create function pg_temp.as_api(p_sql text) returns void language plpgsql as $$
begin
  execute 'set local role authenticated';
  execute p_sql;
  execute 'reset role';
end $$;
create function pg_temp.v(p_k text) returns uuid language sql as $$ select v from t where k = p_k $$;
grant execute on function pg_temp.v(text) to authenticated;
set client_min_messages = notice;

update core.profiles set status = 'INACTIVE' where status = 'ACTIVE';
with u(code) as (values ('X_ADM'),('X_MTP'),('X_MNV'),('X_KHO')),
ins as (insert into auth.users (id, email) select gen_random_uuid(), lower(code) || '@bmt.test' from u returning id, email)
insert into core.profiles (id, employee_code, full_name, status)
select id, upper(split_part(email, '@', 1)), 'Test ' || split_part(email, '@', 1), 'ACTIVE' from ins;
insert into core.user_roles (user_id, role_code)
select p.id, u.role from core.profiles p
  join (values ('X_ADM','ADMIN'),('X_MTP','MUA_TP'),('X_MNV','MUA_NV'),('X_KHO','THU_KHO')) u(code, role) on u.code = p.employee_code;

-- Hai vật tư để thử (không phải phế liệu)
insert into t select 'm1', id from master.materials where not is_scrap and active order by code limit 1;
insert into t select 'm2', id from master.materials where not is_scrap and active order by code offset 1 limit 1;

-- ---------------------------------------------------------------------------
-- 1. Thêm mới: chỉ TP Mua
-- ---------------------------------------------------------------------------
select pg_temp.as_user('X_MNV');
select pg_temp.blocked($q$select app.supplier_save(null, 'NCC Thử Một')$q$, 'Chỉ TP Mua được thêm', 'NV mua không thêm mới được NCC');
select pg_temp.blocked($q$select app.save_supplier('NCC Thử Một')$q$, 'Chỉ TP Mua được thêm', 'NV mua không thêm nhanh NCC trên đơn mua được');
select pg_temp.as_user('X_KHO');
select pg_temp.blocked($q$select app.supplier_save(null, 'NCC Thử Một')$q$, 'Chỉ TP Mua được thêm', 'Thủ kho không thêm mới được NCC');

select pg_temp.as_user('X_MTP');
select pg_temp.as_api($q$insert into t select 's1', app.supplier_save(null, '  NCC  Thử Một ', '0101 234 567', 'Anh A', '0912345678', 'a@ncc.vn', 'Hà Nội', '30 ngày sau khi nhận hàng', 'ghi chú')$q$);
select pg_temp.ok((select code ~ '^NCC-\d{3,}$' and name = 'NCC Thử Một' and tax_code = '0101234567' and is_supplier and active
                      and partner_type = 'SUPPLIER' and phone = '0912345678' and email = 'a@ncc.vn' and payment_terms = '30 ngày sau khi nhận hàng'
                   from core.partners where id = pg_temp.v('s1')),
  'TP Mua thêm NCC: tự cấp mã NCC-xxx, gọn tên và mã số thuế, lưu đủ điện thoại, email, điều khoản');
select pg_temp.blocked($q$select app.supplier_save(null, 'ncc thử một')$q$, 'trùng tên hoặc mã số thuế', 'Trùng tên (không phân biệt hoa thường) không tạo NCC mới');
select pg_temp.blocked($q$select app.supplier_save(null, 'Tên Khác', '0101234567')$q$, 'trùng tên hoặc mã số thuế', 'Trùng mã số thuế không tạo NCC mới');
select pg_temp.blocked($q$select app.supplier_save(null, 'Tên Khác 2', null, null, null, 'sai-email')$q$, 'không đúng dạng', 'Email sai dạng bị chặn');
select pg_temp.blocked($q$select app.supplier_save(null, '   ')$q$, 'Nhập tên', 'Tên trống bị chặn');
select pg_temp.as_api($q$insert into t select 's1b', app.save_supplier('NCC THỬ MỘT')$q$);
select pg_temp.ok(pg_temp.v('s1b') = pg_temp.v('s1'), 'Thêm nhanh trùng tên NCC đang dùng: trả về NCC đã có, không tạo trùng');
select pg_temp.as_api($q$insert into t select 's2', app.supplier_save(null, 'NCC Thử Hai')$q$);
select pg_temp.ok((select count(distinct code) = 2 from core.partners where id in (pg_temp.v('s1'), pg_temp.v('s2'))), 'NCC thứ hai có mã khác');

-- ---------------------------------------------------------------------------
-- 2. Sửa: NV mua, TP Mua. Ghi thẳng qua API: chặn
-- ---------------------------------------------------------------------------
select pg_temp.as_user('X_MNV');
select pg_temp.as_api($q$select app.supplier_save(pg_temp.v('s1'), 'NCC Thử Một', '0101234567', 'Chị B', '0988', null, 'Hưng Yên', null, null)$q$);
select pg_temp.ok((select contact = 'Chị B' and phone = '0988' and email is null and address = 'Hưng Yên' and payment_terms is null
                   from core.partners where id = pg_temp.v('s1')), 'NV mua sửa được thông tin NCC (ô để trống thì xóa giá trị cũ)');
select pg_temp.blocked($q$select app.supplier_save(pg_temp.v('s1'), 'NCC Thử Hai')$q$, 'trùng tên hoặc mã số thuế', 'Sửa tên trùng NCC khác bị chặn');
select pg_temp.blocked($q$insert into core.partners (code, name, is_supplier) values ('NCC-X99', 'Chèn thẳng', true)$q$, 'row-level security', 'NV mua chèn thẳng vào bảng qua API bị chặn');
select pg_temp.as_api($q$update core.partners set active = false where id = pg_temp.v('s1')$q$);
select pg_temp.ok((select active from core.partners where id = pg_temp.v('s1')), 'NV mua sửa thẳng bảng qua API không có tác dụng (RLS)');
select pg_temp.as_user('X_KHO');
select pg_temp.blocked($q$select app.supplier_save(pg_temp.v('s1'), 'Đổi tên')$q$, 'Chỉ NV mua / TP Mua', 'Thủ kho không sửa được NCC');

-- ---------------------------------------------------------------------------
-- 3. Mặt hàng NCC bán được: chỉ TP Mua khai báo
-- ---------------------------------------------------------------------------
select pg_temp.as_user('X_MNV');
select pg_temp.blocked($q$select app.supplier_set_materials(pg_temp.v('s1'), array[pg_temp.v('m1')])$q$, 'Chỉ TP Mua', 'NV mua không khai báo mặt hàng của NCC được');
select pg_temp.as_user('X_MTP');
select pg_temp.as_api($q$select app.supplier_set_materials(pg_temp.v('s1'), array[pg_temp.v('m1'), pg_temp.v('m1')])$q$);
select pg_temp.ok((select count(*) = 1 from master.supplier_materials where supplier_id = pg_temp.v('s1') and material_id = pg_temp.v('m1')),
  'TP Mua khai báo NCC 1 bán vật tư 1 (gửi trùng vẫn một dòng)');
select pg_temp.ok((select material_count = 1 from app.v_suppliers where id = pg_temp.v('s1')), 'Danh sách NCC đếm đúng số mặt hàng');
select pg_temp.ok((select count(*) = 1 from app.v_supplier_materials where supplier_id = pg_temp.v('s1') and po_count = 0), 'Trang chi tiết thấy mặt hàng (chưa mua lần nào)');
select pg_temp.blocked($q$insert into master.supplier_materials (supplier_id, material_id) values (pg_temp.v('s2'), pg_temp.v('m1'))$q$, 'permission denied', 'Chèn thẳng bảng mặt hàng qua API bị chặn');
select pg_temp.blocked($q$select app.supplier_set_materials(pg_temp.v('s1'), array[gen_random_uuid()])$q$, 'không hợp lệ', 'Vật tư không có trong danh mục bị chặn');

-- ---------------------------------------------------------------------------
-- 4. Đơn mua: chỉ chọn được NCC đã khai báo bán vật tư của dòng
-- ---------------------------------------------------------------------------
insert into purchase.purchase_orders (po_no, kind, status) values ('PO-XT1', 'TONG', 'DRAFT');
insert into t select 'po', id from purchase.purchase_orders where po_no = 'PO-XT1';
-- MES lập đơn tổng với NCC gợi ý: NCC 1 có bán vật tư 1 → giữ; NCC 1 không bán vật tư 2 → để trống
insert into purchase.po_lines (po_id, line_no, material_id, qty, supplier_id) values
  (pg_temp.v('po'), 1, pg_temp.v('m1'), 10, pg_temp.v('s1')),
  (pg_temp.v('po'), 2, pg_temp.v('m2'), 10, pg_temp.v('s1'));
select pg_temp.ok((select supplier_id = pg_temp.v('s1') from purchase.po_lines where po_id = pg_temp.v('po') and line_no = 1)
              and (select supplier_id is null from purchase.po_lines where po_id = pg_temp.v('po') and line_no = 2),
  'Đơn tổng lập tự động: giữ NCC gợi ý hợp lệ, bỏ trống NCC chưa khai báo vật tư');
select pg_temp.blocked_owner($q$update purchase.po_lines set supplier_id = pg_temp.v('s1') where po_id = pg_temp.v('po') and line_no = 2$q$,
  'chưa khai báo bán vật tư', 'Chọn NCC chưa khai báo vật tư của dòng bị chặn');
select pg_temp.blocked_owner($q$update purchase.po_lines set supplier_id = pg_temp.v('s2') where po_id = pg_temp.v('po') and line_no = 1$q$,
  'chưa khai báo bán vật tư', 'NCC 2 chưa khai báo mặt hàng nào: không chọn được');
select pg_temp.as_api($q$select app.supplier_set_materials(pg_temp.v('s2'), array[pg_temp.v('m1'), pg_temp.v('m2')])$q$);
update purchase.po_lines set supplier_id = pg_temp.v('s2') where po_id = pg_temp.v('po') and line_no = 2;
select pg_temp.ok((select supplier_id = pg_temp.v('s2') from purchase.po_lines where po_id = pg_temp.v('po') and line_no = 2),
  'Sau khi TP Mua khai báo, chọn được NCC 2 cho vật tư 2');
select pg_temp.ok((select open_count = 1 from app.v_suppliers where id = pg_temp.v('s2')), 'Danh sách NCC đếm đơn mua đang mở');
-- Điều khoản thanh toán mặc định của NCC tự điền vào dòng chưa có điều khoản; dòng đã có thì giữ
update core.partners set payment_terms = '45 ngày sau khi nhận hàng' where id = pg_temp.v('s1');
update purchase.po_lines set supplier_id = pg_temp.v('s1'), payment_terms = null where po_id = pg_temp.v('po') and line_no = 1;
select pg_temp.ok((select payment_terms = '45 ngày sau khi nhận hàng' from purchase.po_lines where po_id = pg_temp.v('po') and line_no = 1),
  'Dòng chưa có điều khoản: tự điền điều khoản thanh toán mặc định của NCC');
update purchase.po_lines set supplier_id = pg_temp.v('s1'), payment_terms = 'Trả ngay' where po_id = pg_temp.v('po') and line_no = 1;
select pg_temp.ok((select payment_terms = 'Trả ngay' from purchase.po_lines where po_id = pg_temp.v('po') and line_no = 1),
  'Dòng NV mua đã ghi điều khoản riêng: giữ nguyên');
select pg_temp.blocked($q$select app.supplier_set_materials(pg_temp.v('s2'), array[pg_temp.v('m1')])$q$, 'Chưa bỏ được',
  'Bỏ mặt hàng đang nằm trên đơn mua chưa duyệt bị chặn');

-- ---------------------------------------------------------------------------
-- 5. Ngừng dùng / dùng lại: chỉ TP Mua
-- ---------------------------------------------------------------------------
select pg_temp.as_user('X_MNV');
select pg_temp.blocked($q$select app.supplier_set_active(pg_temp.v('s2'), false, 'thử')$q$, 'Chỉ TP Mua', 'NV mua không ngừng dùng NCC được');
select pg_temp.as_user('X_MTP');
select pg_temp.blocked($q$select app.supplier_set_active(pg_temp.v('s2'), false, '  ')$q$, 'Nhập lý do', 'Ngừng dùng phải có lý do');
select pg_temp.blocked($q$select app.supplier_set_active(pg_temp.v('s2'), false, 'Giao chậm')$q$, 'PO-XT1', 'Còn dòng đơn mua chưa duyệt: không ngừng dùng được, báo đúng số đơn');
update purchase.po_lines set supplier_id = null where po_id = pg_temp.v('po') and line_no = 2;
select pg_temp.as_api($q$select app.supplier_set_active(pg_temp.v('s2'), false, 'Giao chậm')$q$);
select pg_temp.ok((select not active and inactive_reason = 'Giao chậm' and inactive_at is not null and inactive_by is not null
                   from core.partners where id = pg_temp.v('s2')), 'TP Mua ngừng dùng NCC 2: lưu lý do, người, thời điểm');
select pg_temp.blocked_owner($q$update purchase.po_lines set supplier_id = pg_temp.v('s2') where po_id = pg_temp.v('po') and line_no = 2$q$,
  'đã ngừng dùng', 'NCC đã ngừng dùng không chọn được trên đơn mua');
select pg_temp.blocked($q$select app.save_supplier('NCC Thử Hai')$q$, 'đang ngừng dùng', 'Thêm nhanh trùng tên NCC đã ngừng: báo dùng lại, không tạo trùng');
select pg_temp.as_api($q$select app.supplier_set_active(pg_temp.v('s2'), true)$q$);
select pg_temp.ok((select active and inactive_reason is null and inactive_at is null from core.partners where id = pg_temp.v('s2')), 'TP Mua cho dùng lại NCC 2');

-- ---------------------------------------------------------------------------
-- 6. Xóa: chỉ Quản trị, chỉ NCC chưa phát sinh chứng từ
-- ---------------------------------------------------------------------------
select pg_temp.blocked($q$select app.supplier_delete(pg_temp.v('s2'), 'thử')$q$, 'Chỉ Quản trị hệ thống', 'TP Mua không xóa được NCC');
select pg_temp.as_user('X_ADM');
select pg_temp.blocked($q$select app.supplier_delete(pg_temp.v('s2'), '')$q$, 'Nhập lý do', 'Xóa phải có lý do');
select pg_temp.blocked($q$select app.supplier_delete(pg_temp.v('s1'), 'Nhập nhầm')$q$, 'đã phát sinh chứng từ', 'NCC đã có dòng đơn mua: không xóa, báo dùng Ngừng dùng');
select pg_temp.blocked($q$select app.supplier_delete((select id from core.partners where code = 'KAVIX'), 'thử')$q$, 'Không tìm thấy', 'Không xóa được pháp nhân thương hiệu qua hàm này');
select pg_temp.as_api($q$select app.supplier_delete(pg_temp.v('s2'), 'Nhập nhầm')$q$);
select pg_temp.ok(not exists (select 1 from core.partners where id = pg_temp.v('s2'))
              and not exists (select 1 from master.supplier_materials where supplier_id = pg_temp.v('s2')),
  'Quản trị xóa NCC chưa phát sinh chứng từ, xóa kèm danh sách mặt hàng');
select pg_temp.ok((select old_data ->> 'name' = 'NCC Thử Hai' and new_data ->> 'reason' = 'Nhập nhầm' from core.audit_log
                    where action = 'ADMIN_DELETE' and row_id = pg_temp.v('s2')::text), 'Nhật ký giữ bản sao NCC đã xóa và lý do');
-- Quản trị cũng thêm, ngừng dùng được (quyền cao nhất)
select pg_temp.as_api($q$insert into t select 's3', app.supplier_save(null, 'NCC Thử Ba')$q$);
select pg_temp.as_api($q$select app.supplier_set_active(pg_temp.v('s3'), false, 'thử')$q$);
select pg_temp.ok((select not active from core.partners where id = pg_temp.v('s3')), 'Quản trị thêm và ngừng dùng được NCC');

-- ---------------------------------------------------------------------------
-- 7. Lịch sử, menu, quyền gọi
-- ---------------------------------------------------------------------------
select pg_temp.as_user('X_KHO');
select pg_temp.as_api($q$insert into r(msg) select 'Thủ kho xem được lịch sử NCC 1: ' || count(*) || ' dòng (thêm, sửa, mặt hàng)' from app.supplier_history(pg_temp.v('s1')) having count(*) >= 3 and bool_or(action = 'MATERIALS') and bool_or(action = 'INSERT') and bool_or(action = 'UPDATE' and changes ? 'phone')$q$);
select pg_temp.ok((select count(*) = 1 from r where msg like 'Thủ kho xem được lịch sử%'), 'Lịch sử NCC ghi đủ thêm mới, sửa (có trường đổi), khai báo mặt hàng');
-- Người chỉ có quyền xem (thủ kho) đọc được danh sách, mặt hàng qua view (RLS của người gọi)
select pg_temp.as_api($q$insert into r(msg) select 'Thủ kho đọc được view NCC: ' || count(*) || ' NCC thử' from app.v_suppliers
  where id in (pg_temp.v('s1'), pg_temp.v('s3')) and material_count >= 0 and po_count >= 0 having count(*) = 2$q$);
select pg_temp.as_api($q$insert into r(msg) select 'Thủ kho đọc được mặt hàng của NCC 1: ' || count(*) || ' mặt hàng' from app.v_supplier_materials
  where supplier_id = pg_temp.v('s1') having count(*) = 1
     and (select count(*) from master.supplier_materials where supplier_id = pg_temp.v('s1')) = 1$q$);
select pg_temp.ok((select count(*) = 2 from r where msg like 'Thủ kho đọc được view NCC%' or msg like 'Thủ kho đọc được mặt hàng%'),
  'Vai trò chỉ xem đọc được danh sách NCC, mặt hàng (để màn hình Đơn mua lọc NCC theo vật tư)');
select pg_temp.ok(exists (select 1 from core.pages where key = 'nha-cung-cap' and path = '/nha-cung-cap' and grp = 'Mua hàng')
              and (select count(*) from core.role_pages where page_key = 'nha-cung-cap') = (select count(*) from core.role_pages where page_key = 'don-mua'),
  'Mục menu Nhà cung cấp: vai trò vào được giống Đơn mua hàng');
select pg_temp.ok(not has_function_privilege('anon', 'app.supplier_save(uuid,text,text,text,text,text,text,text,text)', 'execute')
              and not has_function_privilege('anon', 'app.supplier_delete(uuid,text)', 'execute')
              and not has_function_privilege('anon', 'app.supplier_set_active(uuid,boolean,text)', 'execute')
              and not has_function_privilege('anon', 'app.supplier_set_materials(uuid,uuid[])', 'execute')
              and not has_function_privilege('anon', 'app.supplier_history(uuid)', 'execute')
              and not has_function_privilege('authenticated', 'purchase.line_check_supplier()', 'execute'),
  'Khách (anon) không gọi được các hàm NCC');

do $$ begin raise exception E'KET_QUA_OK (đã rollback, không để lại dữ liệu) — % kiểm tra đạt:\n%', (select count(*) from r), (select string_agg(n||'. '||msg, E'\n' order by n) from r); end $$;
