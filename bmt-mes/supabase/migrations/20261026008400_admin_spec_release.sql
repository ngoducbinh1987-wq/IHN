-- Quản trị hệ thống phát hành spec ngay (anh Bình yêu cầu 04/11/2026: duyệt phát hành hết thông số HEIZKA,
-- mã Rdc không đạt vẫn hiện cảnh báo).
-- Rdc tính vượt giới hạn mà chưa có pilot đạt / chấp nhận sai lệch: ghi lý do của Quản trị vào chấp nhận sai lệch
-- (rdc_deviation_note, anh Bình chốt nội dung "Đã kiểm tra thực tế, duyệt mẫu này") rồi phát hành; các lỗi kiểm tra khác (BOM, kết cấu…) vẫn chặn như phát hành thường.
-- Web vẫn tô đỏ Rdc và hiện cảnh báo "Rdc vượt giới hạn" trên trang mã.

create or replace function app.admin_spec_release(p_spec uuid, p_reason text)
 returns text language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare s master.product_specs; r master.spec_results; v_code text; v_no text; v_note text; v_rdc boolean := false; q record;
begin
  if not core.is_admin() then raise exception 'Chỉ Quản trị hệ thống phát hành spec trực tiếp'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Ghi lý do phát hành'; end if;
  select * into s from master.product_specs where id = p_spec for update;
  if not found then raise exception 'Không tìm thấy phiên bản spec'; end if;
  select code into v_code from master.products where id = s.product_id;
  v_no := v_code || ' v' || s.version;
  if s.status in ('RELEASED', 'OBSOLETE') then raise exception '% đã phát hành hoặc đã cũ', v_no; end if;

  select * into r from master.spec_results where spec_id = p_spec;
  if r.rdc_limit is not null and r.rdc_calc > r.rdc_limit
     and not (r.pilot_rdc is not null and r.pilot_rdc <= r.rdc_limit)
     and coalesce(s.rdc_deviation_note, '') = '' then
    v_rdc := true;
    v_note := trim(p_reason);   -- nội dung ghi vào chấp nhận sai lệch = lý do Quản trị nhập; số Rdc ghi ở nhật ký
    update master.product_specs set rdc_deviation_note = v_note where id = p_spec;
  end if;

  -- Quy trình duyệt đang chạy của phiên bản: dừng, ghi lịch sử
  for q in select * from wf.approval_requests where doc_id = p_spec and status = 'PENDING' for update loop
    update wf.approval_requests set status = 'CANCELLED', finished_at = now() where id = q.id;
    insert into wf.approval_actions (request_id, seq, action, comment, data_hash)
    values (q.id, coalesce(q.current_seq, 0), 'COMMENT', '[Quản trị phát hành trực tiếp] ' || trim(p_reason), q.data_hash);
  end loop;

  perform set_config('bmt.wf_release', 'on', true);
  perform master.release_spec(p_spec);
  perform set_config('bmt.wf_release', 'off', true);

  perform app.admin_log('master.product_specs', p_spec::text, 'ADMIN_SPEC', to_jsonb(s),
    jsonb_build_object('doc_type', 'Phát hành spec', 'doc_no', v_no, 'reason', trim(p_reason),
                       'rdc_deviation', v_rdc, 'rdc_calc', r.rdc_calc, 'rdc_limit', r.rdc_limit));
  return v_no;
end $$;
revoke execute on function app.admin_spec_release(uuid, text) from public, anon;
grant execute on function app.admin_spec_release(uuid, text) to authenticated;

-- Phát hành ngay mọi spec HEIZKA chưa phát hành, nhân danh Quản trị (dữ liệu thật: Ngô Đức Bình).
-- DB không có Quản trị (dựng mới để kiểm thử) thì bỏ qua.
do $$
declare v_admin uuid; x record; n int := 0;
begin
  select ur.user_id into v_admin from core.user_roles ur join core.profiles p on p.id = ur.user_id
   where ur.role_code = 'ADMIN' and p.status = 'ACTIVE' order by p.created_at limit 1;
  if v_admin is null then return; end if;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  for x in select s.id from master.product_specs s join master.products p on p.id = s.product_id
            where s.brand = 'HEIZKA' and s.status not in ('RELEASED', 'OBSOLETE') and p.current_spec_id = s.id
            order by p.code loop
    perform app.admin_spec_release(x.id, 'Đã kiểm tra thực tế, duyệt mẫu này');
    n := n + 1;
  end loop;
  perform set_config('request.jwt.claim.sub', '', true);
  raise notice 'Đã phát hành % spec HEIZKA', n;
end $$;
