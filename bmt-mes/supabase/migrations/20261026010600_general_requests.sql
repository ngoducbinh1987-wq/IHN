-- Mục Đề xuất chung (anh Bình duyệt phương án 22/11/2026, 11 điểm theo đề xuất):
-- mọi nhân viên gửi đề xuất bất cứ việc gì (nghỉ, thai sản, mua hàng, trang thiết bị, tạm ứng, sửa chữa, cải tiến, khác).
--  * Loại đề xuất: wf.request_types (15 loại, 5 nhóm); đề xuất: wf.requests (DX-yymm-nnn).
--  * Duyệt qua khung wf (doc_type REQUEST): người duyệt MES tự gán theo bộ phận người gửi + cài đặt của loại:
--      Trưởng bộ phận (vai trò cấp 2 của bộ phận) → chuyên môn (Kế toán trưởng / trưởng bộ phận nơi nhận) → Giám đốc.
--    Người gửi (hoặc người lập thay) là trưởng bộ phận → bỏ bước đó; không còn bước nào → Giám đốc; Giám đốc gửi → Chủ tịch HĐQT.
--  * Đề xuất hiện ở Điều hành → Quy trình duyệt ("Chờ tôi duyệt"), chuông, Việc của tôi (qua wf.approval_requests).
--  * Duyệt xong MES tự chuyển: nghỉ của công nhân → lịch vắng; mua → Phòng Mua lập đề xuất mua; sửa chữa → phiếu SC;
--    loại khác → người xử lý bấm "Đã xử lý".
--  * Riêng tư: đề xuất nhân sự, tài chính chỉ người gửi, người lập, người duyệt, nhân sự / kế toán, Ban giám đốc, Quản trị xem;
--    tóm tắt trên Quy trình duyệt không ghi lý do. Góp ý cải tiến được gửi ẩn danh (chỉ Quản trị thấy tên).
--  * Vai trò mới HCNS (Hành chính – Nhân sự); chưa có người giữ thì Kế toán trưởng nhận việc nhân sự.

-- 1. Bộ phận, vai trò Hành chính – Nhân sự --------------------------------------------------------------------
insert into core.departments (code, name) values ('HCNS', 'Hành chính – Nhân sự') on conflict (code) do nothing;
insert into core.roles (code, name, department, level, can_see_price)
values ('HCNS', 'Hành chính – Nhân sự', 'HCNS', 2, false) on conflict (code) do nothing;
insert into core.role_permissions (role_code, module, action)
select 'HCNS', m, a from (values ('master','view'), ('production','view'), ('plan','view'), ('approval','view')) v(m, a)
on conflict do nothing;
-- Quyền vào mục mặc định giống Kế toán trưởng ở các mục chung (Quản trị tick lại ở Phân quyền)
insert into core.role_pages (role_code, page_key)
select 'HCNS', k from unnest(array['kh-chung', 'may', 'may-bao-duong', 'nhan-su-xuong']) k
where exists (select 1 from core.pages p where p.key = k)
on conflict do nothing;

-- Bộ phận của người dùng phải là bộ phận của một vai trò người đó giữ (ví dụ TP KT/QA ghi nhầm Sản xuất)
update core.profiles p set department = d.dept
  from (select ur.user_id, (array_agg(r.department order by r.level desc,
               array_position(array['BGD','SX','KT','MUA','KTOAN','KHO','KD','HCNS','IT'], r.department)))[1] dept
          from core.user_roles ur join core.roles r on r.code = ur.role_code group by ur.user_id) d
 where d.user_id = p.id and p.deleted_at is null
   and (p.department is null or not exists (select 1 from core.user_roles ur join core.roles r on r.code = ur.role_code
                                             where ur.user_id = p.id and r.department = p.department));

-- 2. Loại đề xuất -----------------------------------------------------------------------------------------------
create table if not exists wf.request_types (
  code           text primary key,
  grp            text not null check (grp in ('NS','MUA','TC','KT','GY','KHAC')),
  name           text not null,
  hint           text,
  form           text not null check (form in ('LEAVE','MATERNITY','LATE','SHIFT','TRIP','BUY','MONEY','REPAIR','IDEA','OTHER')),
  gd_rule        text not null default 'NEVER' check (gd_rule in ('NEVER','ALWAYS','DAYS','AMOUNT')),
  gd_threshold   numeric,
  expert_role    text references core.roles(code),
  handler_roles  text[] not null default '{}',   -- 'HR' = người phụ trách nhân sự, 'TARGET' = trưởng bộ phận nơi nhận
  action         text not null default 'HANDLE' check (action in ('ABSENCE','NOTICE','PR','REPAIR','HANDLE')),
  private        boolean not null default false,
  sla_hours      integer not null default 24 check (sla_hours between 1 and 240),
  allow_anonymous boolean not null default false,
  active         boolean not null default true,
  sort           integer not null default 0
);
alter table wf.request_types enable row level security;
drop policy if exists p_select on wf.request_types;
create policy p_select on wf.request_types for select to authenticated using (true);
grant select on wf.request_types to authenticated;

insert into wf.request_types (code, grp, name, hint, form, gd_rule, gd_threshold, expert_role, handler_roles, action, private, sla_hours, allow_anonymous, sort) values
 ('PHEP_NAM',  'NS',  'Nghỉ phép năm', 'Nghỉ có lương theo phép năm (12 ngày/năm, thêm 1 ngày mỗi 5 năm làm việc). Trên 3 ngày Giám đốc duyệt.', 'LEAVE', 'DAYS', 3, null, '{}', 'ABSENCE', true, 24, false, 10),
 ('OM',        'NS',  'Nghỉ ốm, khám bệnh', 'Nghỉ do ốm, đi khám, điều trị. Ốm đột xuất lập sau, trong 2 ngày làm việc; nộp giấy nghỉ ốm cho nhân sự.', 'LEAVE', 'NEVER', null, null, '{}', 'ABSENCE', true, 4, false, 20),
 ('THAI_SAN',  'NS',  'Thai sản, nghỉ sinh con', 'Nghỉ sinh con (lao động nữ 6 tháng), khám thai, vợ sinh con. Ghi người nhận bàn giao việc.', 'MATERNITY', 'ALWAYS', null, null, '{}', 'ABSENCE', true, 24, false, 30),
 ('VIEC_RIENG','NS',  'Nghỉ việc riêng', 'Có lương: kết hôn, con kết hôn, tang người thân. Không lương hoặc trên 3 ngày: Giám đốc duyệt.', 'LEAVE', 'DAYS', 3, null, '{}', 'ABSENCE', true, 24, false, 40),
 ('DI_MUON',   'NS',  'Đi muộn, về sớm, ra ngoài', 'Vắng một phần ca: ghi giờ đi, giờ về.', 'LATE', 'NEVER', null, null, '{}', 'NOTICE', false, 4, false, 50),
 ('DOI_CA',    'NS',  'Đổi ca, làm thêm giờ cá nhân', 'Xin đổi sang ca khác hoặc làm thêm giờ; TP SX sửa Bảng ca tuần sau khi duyệt.', 'SHIFT', 'NEVER', null, null, '{}', 'NOTICE', false, 24, false, 60),
 ('CONG_TAC',  'NS',  'Công tác', 'Đi công tác ngoài nhà máy: nơi đến, thời gian, phương tiện, dự trù chi phí. Giám đốc duyệt.', 'TRIP', 'ALWAYS', null, null, '{}', 'ABSENCE', false, 24, false, 70),
 ('MUA_NVL',   'MUA', 'Mua nguyên vật liệu', 'Nhu cầu NVL ngoài kế hoạch tháng. Duyệt xong Phòng Mua lập đề xuất mua bổ sung NVL.', 'BUY', 'NEVER', null, null, '{MUA_NV,MUA_TP}', 'PR', false, 24, false, 80),
 ('MUA_CCDC',  'MUA', 'Mua công cụ dụng cụ, máy, trang thiết bị', 'Dụng cụ, máy, thiết bị phục vụ sản xuất. Duyệt xong Phòng Mua lập đề xuất mua công cụ dụng cụ.', 'BUY', 'NEVER', null, null, '{MUA_NV,MUA_TP}', 'PR', false, 24, false, 90),
 ('VPP_BHLD',  'MUA', 'Văn phòng phẩm, bảo hộ lao động', 'Giấy, mực, dụng cụ văn phòng, quần áo, găng tay, giày bảo hộ. Nhân sự gom và cấp.', 'BUY', 'NEVER', null, null, '{HR}', 'HANDLE', false, 24, false, 100),
 ('TAM_UNG',   'TC',  'Tạm ứng', 'Tạm ứng tiền cho công việc: số tiền, mục đích, ngày hoàn ứng. Từ 5.000.000 đ Giám đốc duyệt.', 'MONEY', 'AMOUNT', 5000000, 'KTT', '{KTT,KT_KHO}', 'HANDLE', true, 24, false, 110),
 ('THANH_TOAN','TC',  'Thanh toán, hoàn tiền', 'Đề nghị thanh toán khoản đã chi: số tiền, nội dung, hóa đơn. Từ 5.000.000 đ Giám đốc duyệt.', 'MONEY', 'AMOUNT', 5000000, 'KTT', '{KTT,KT_KHO}', 'HANDLE', true, 24, false, 120),
 ('SUA_CHUA',  'KT',  'Sửa chữa máy, nhà xưởng', 'Hư hỏng cần sửa (máy, điện, nước, nhà xưởng). Máy đang hỏng thì vẫn báo hỏng ở Hồ sơ máy.', 'REPAIR', 'NEVER', null, null, '{KT_TP}', 'REPAIR', false, 4, false, 130),
 ('CAI_TIEN',  'GY',  'Cải tiến, sáng kiến', 'Ý tưởng làm nhanh hơn, tiết kiệm hơn, an toàn hơn. Được gửi ẩn danh. Giám đốc quyết định.', 'IDEA', 'ALWAYS', null, null, '{}', 'HANDLE', false, 24, true, 140),
 ('KHAC',      'KHAC','Việc khác', 'Việc không thuộc loại nào ở trên: chọn bộ phận nhận để trưởng bộ phận đó xử lý.', 'OTHER', 'NEVER', null, null, '{TARGET}', 'HANDLE', false, 24, false, 150)
on conflict (code) do nothing;

-- 3. Đề xuất -----------------------------------------------------------------------------------------------------
create table if not exists wf.requests (
  id            uuid primary key default gen_random_uuid(),
  req_no        text not null unique,
  type_code     text not null references wf.request_types(code),
  title         text not null,
  content       text,
  reason        text,
  urgent        boolean not null default false,
  requester_id  uuid references core.profiles(id),               -- người đề xuất có tài khoản
  operator_code text references master.operators(code) on update cascade, -- công nhân chưa có tài khoản (lập thay)
  dept          text references core.departments(code),         -- bộ phận người đề xuất lúc lập
  date_from     date,
  date_to       date,
  part          text not null default 'FULL' check (part in ('FULL','AM','PM')),
  time_from     time,
  time_to       time,
  days          numeric(6,1),
  amount        numeric(18,0),
  paid          boolean,
  machine_id    uuid references master.machines(id),
  target_dept   text references core.departments(code),
  items         jsonb not null default '[]',
  data          jsonb not null default '{}',
  anonymous     boolean not null default false,
  status        text not null default 'DRAFT'
                check (status in ('DRAFT','PENDING_APPROVAL','RETURNED','APPROVED','DONE','REFUSED','CANCELLED')),
  handled_by    uuid references core.profiles(id),
  handled_at    timestamptz,
  handle_note   text,
  pr_id         uuid references purchase.purchase_requests(id) on delete set null,
  maint_wo_id   uuid references mfg.maint_work_orders(id) on delete set null,
  absence_ids   uuid[] not null default '{}',
  created_at    timestamptz not null default now(),
  created_by    uuid default auth.uid() references core.profiles(id),
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  check (requester_id is not null or operator_code is not null),
  check (date_to is null or date_from is null or date_to >= date_from)
);
create index if not exists requests_type_code_fkidx on wf.requests (type_code);
create index if not exists requests_requester_id_fkidx on wf.requests (requester_id);
create index if not exists requests_operator_code_fkidx on wf.requests (operator_code);
create index if not exists requests_dept_fkidx on wf.requests (dept);
create index if not exists requests_machine_id_fkidx on wf.requests (machine_id);
create index if not exists requests_target_dept_fkidx on wf.requests (target_dept);
create index if not exists requests_handled_by_fkidx on wf.requests (handled_by);
create index if not exists requests_pr_id_fkidx on wf.requests (pr_id);
create index if not exists requests_maint_wo_id_fkidx on wf.requests (maint_wo_id);
create index if not exists requests_created_by_fkidx on wf.requests (created_by);
create index if not exists requests_status_idx on wf.requests (status);
create index if not exists request_types_expert_role_fkidx on wf.request_types (expert_role);

insert into wf.approval_flows (doc_type, name, doc_table, status_col, approved_status, rejected_status, pending_status, submit_label, active)
values ('REQUEST', 'Đề xuất chung', 'wf.requests', 'status', 'APPROVED', 'RETURNED', 'PENDING_APPROVAL', 'Người lập đề xuất', true)
on conflict (doc_type) do nothing;

-- 4. Hàm nền: bộ phận, trưởng bộ phận, người phụ trách nhân sự --------------------------------------------------
create or replace function wf.user_has_role(p_user uuid, p_role text) returns boolean
 language sql stable security definer set search_path to 'pg_catalog', 'public'
as $$
  select p_user is not null and p_role is not null
     and exists (select 1 from core.user_roles ur join core.profiles p on p.id = ur.user_id and p.status = 'ACTIVE'
                  where ur.user_id = p_user and ur.role_code = p_role)
$$;

create or replace function wf.user_dept(p_user uuid) returns text
 language sql stable security definer set search_path to 'pg_catalog', 'public'
as $$
  select coalesce(
    (select p.department from core.profiles p where p.id = p_user and p.department is not null),
    (select r.department from core.user_roles ur join core.roles r on r.code = ur.role_code
      where ur.user_id = p_user order by r.level desc,
            array_position(array['BGD','SX','KT','MUA','KTOAN','KHO','KD','HCNS','IT'], r.department) limit 1))
$$;

create or replace function wf.dept_head_role(p_dept text) returns text
 language sql stable security definer set search_path to 'pg_catalog', 'public'
as $$
  select code from core.roles where department = p_dept and level = 2 and p_dept not in ('BGD', 'IT') order by code limit 1
$$;

create or replace function wf.hr_ids() returns uuid[]
 language sql stable security definer set search_path to 'pg_catalog', 'public'
as $$
  select case when cardinality(inv.role_users(array['HCNS'])) > 0 then inv.role_users(array['HCNS'])
              else inv.role_users(array['KTT']) end
$$;

-- Người xử lý sau khi duyệt (vai trò; 'HR' = nhân sự, 'TARGET' = trưởng bộ phận nơi nhận)
create or replace function wf.req_handler_ids(p_req uuid) returns uuid[]
 language plpgsql stable security definer set search_path to 'pg_catalog', 'public'
as $$
declare r wf.requests; t wf.request_types; v uuid[] := '{}'; x text;
begin
  select * into r from wf.requests where id = p_req;
  if not found then return '{}'; end if;
  select * into t from wf.request_types where code = r.type_code;
  foreach x in array t.handler_roles loop
    if x = 'HR' then v := v || wf.hr_ids();
    elsif x = 'TARGET' then v := v || inv.role_users(array[coalesce(wf.dept_head_role(r.target_dept), 'BGD')]);
    else v := v || inv.role_users(array[x]);
    end if;
  end loop;
  return coalesce((select array_agg(distinct u) from unnest(v) u), '{}');
end $$;

create or replace function wf.req_can_handle(p_req uuid) returns boolean
 language sql stable security definer set search_path to 'pg_catalog', 'public'
as $$
  select core.is_admin() or auth.uid() = any(wf.req_handler_ids(p_req))
      or exists (select 1 from wf.requests r join wf.request_types t on t.code = r.type_code
                  where r.id = p_req and exists (select 1 from unnest(t.handler_roles) x
                                                  where x not in ('HR','TARGET') and core.has_role(x)))
$$;

-- Ai xem được đề xuất (dùng cho RLS và màn hình)
create or replace function wf.req_can_view(p_req uuid) returns boolean
 language plpgsql stable security definer set search_path to 'pg_catalog', 'public'
as $$
declare r wf.requests; t wf.request_types; v_me uuid := auth.uid(); q wf.approval_requests;
begin
  if v_me is null then return false; end if;
  if core.is_admin() then return true; end if;
  select * into r from wf.requests where id = p_req;
  if not found then return false; end if;
  if v_me in (r.created_by, r.requester_id) then return true; end if;
  if r.operator_code is not null and exists (select 1 from master.operators o where o.code = r.operator_code and o.profile_id = v_me) then
    return true;
  end if;
  if wf.user_has_role(v_me, 'BGD') then return true; end if;
  select * into t from wf.request_types where code = r.type_code;
  if t.grp = 'NS' and v_me = any(wf.hr_ids()) then return true; end if;
  if r.status in ('APPROVED','DONE') and v_me = any(wf.req_handler_ids(p_req)) then return true; end if;
  -- người duyệt các bước (kể cả bước đã qua) của lần gửi duyệt gần nhất
  for q in select * from wf.approval_requests where doc_type = 'REQUEST' and doc_id = p_req loop
    if exists (select 1 from wf.approval_actions a where a.request_id = q.id and a.actor_id = v_me) then return true; end if;
    if q.status = 'PENDING' and exists (select 1 from jsonb_array_elements(q.flow_snapshot -> 'steps') s
                                         where (s ->> 'seq')::int >= q.current_seq and v_me = any(wf.step_actor_ids(s))) then
      return true;
    end if;
    if exists (select 1 from jsonb_array_elements(q.flow_snapshot -> 'steps') s
                where (s ->> 'seq')::int = q.current_seq and (wf.can_act_step(s, q.step_started_at)).ok) and q.status = 'PENDING' then
      return true;
    end if;
  end loop;
  -- không riêng tư: trưởng bộ phận của người đề xuất, người xử lý
  if not t.private then
    if wf.user_has_role(v_me, wf.dept_head_role(r.dept)) then return true; end if;
    if v_me = any(wf.req_handler_ids(p_req)) then return true; end if;
  end if;
  return false;
end $$;

alter table wf.requests enable row level security;
drop policy if exists p_select on wf.requests;
create policy p_select on wf.requests for select to authenticated using (wf.req_can_view(id));
grant select on wf.requests to authenticated;

-- Số ngày nghỉ: ngày làm việc của xưởng (thai sản tính ngày lịch), nửa ca = 0,5
create or replace function wf.req_days(p_form text, p_from date, p_to date, p_part text) returns numeric
 language sql stable security definer set search_path to 'pg_catalog', 'public'
as $$
  select case
    when p_from is null then null
    when coalesce(p_part, 'FULL') <> 'FULL' then 0.5
    when p_form = 'MATERNITY' then (coalesce(p_to, p_from) - p_from + 1)::numeric
    else (select count(*)::numeric from generate_series(p_from, coalesce(p_to, p_from), interval '1 day') d where plan.is_workday(d::date))
  end
$$;

-- 5. Các bước duyệt của một đề xuất (MES tự gán) --------------------------------------------------------------
create or replace function wf.req_steps(p_req uuid) returns jsonb
 language plpgsql stable security definer set search_path to 'pg_catalog', 'public'
as $$
declare r wf.requests; t wf.request_types; v_out jsonb := '[]'; v_seq int := 0; v_head text; v_exp text; v_gd boolean;
        v_sender uuid; v_creator uuid; v_dn text; v_sla int; v_is_gd boolean;
begin
  select * into r from wf.requests where id = p_req;
  if not found then raise exception 'Không tìm thấy đề xuất'; end if;
  select * into t from wf.request_types where code = r.type_code;
  v_sla := case when r.urgent then least(t.sla_hours, 4) else t.sla_hours end;
  v_sender := coalesce(r.requester_id, (select profile_id from master.operators where code = r.operator_code));
  v_creator := r.created_by;
  -- 1. Trưởng bộ phận của người đề xuất
  v_head := wf.dept_head_role(r.dept);
  -- bỏ bước khi người gửi / người lập giữ vai trò đó, hoặc bộ phận chưa có ai khác giữ vai trò đó (lên Giám đốc)
  if v_head is not null and not wf.user_has_role(v_sender, v_head) and not wf.user_has_role(v_creator, v_head)
     and cardinality(array_remove(array_remove(wf.step_actor_ids(jsonb_build_object('role', v_head)), v_sender), v_creator)) > 0 then
    select name into v_dn from core.departments where code = r.dept;
    v_seq := v_seq + 1;
    v_out := v_out || jsonb_build_array(jsonb_build_object('seq', v_seq, 'label', 'Trưởng bộ phận ' || coalesce(v_dn, r.dept) || ' duyệt',
      'role', v_head, 'users', '[]'::jsonb, 'sla_hours', v_sla, 'warn_hours', 2, 'min_amount', null, 'flags', '[]'::jsonb,
      'fallback', null, 'notify', '[]'::jsonb));
  end if;
  -- 2. Chuyên môn: Kế toán trưởng (tài chính), trưởng bộ phận nơi nhận (việc khác)
  v_exp := case when t.form = 'OTHER' then wf.dept_head_role(r.target_dept) else t.expert_role end;
  if v_exp is not null and v_exp is distinct from v_head
     and not wf.user_has_role(v_sender, v_exp) and not wf.user_has_role(v_creator, v_exp)
     and cardinality(array_remove(array_remove(wf.step_actor_ids(jsonb_build_object('role', v_exp)), v_sender), v_creator)) > 0 then
    v_seq := v_seq + 1;
    v_out := v_out || jsonb_build_array(jsonb_build_object('seq', v_seq,
      'label', case when t.form = 'OTHER' then 'Trưởng bộ phận ' || coalesce((select name from core.departments where code = r.target_dept), r.target_dept) || ' xem xét'
                    else coalesce((select name from core.roles where code = v_exp), v_exp) || ' kiểm' end,
      'role', v_exp, 'users', '[]'::jsonb, 'sla_hours', v_sla, 'warn_hours', 2, 'min_amount', null, 'flags', '[]'::jsonb,
      'fallback', null, 'notify', '[]'::jsonb));
  end if;
  -- 3. Giám đốc theo loại; không còn bước nào cũng lên Giám đốc
  v_gd := case t.gd_rule when 'ALWAYS' then true
                         when 'DAYS' then coalesce(r.days, 0) > coalesce(t.gd_threshold, 0)
                         when 'AMOUNT' then coalesce(r.amount, 0) >= coalesce(t.gd_threshold, 0)
                         else false end
          or (t.code = 'VIEC_RIENG' and r.paid is false)
          or v_seq = 0;
  if v_gd then
    -- người gửi là Giám đốc (Ban giám đốc, không phải Chủ tịch) → Chủ tịch HĐQT duyệt
    v_is_gd := (wf.user_has_role(v_sender, 'BGD') and not v_sender = any(plan.chair_ids()))
            or (wf.user_has_role(v_creator, 'BGD') and not v_creator = any(plan.chair_ids()));
    v_seq := v_seq + 1;
    if v_is_gd and cardinality(plan.chair_ids()) > 0 then
      v_out := v_out || jsonb_build_array(jsonb_build_object('seq', v_seq, 'label', 'Chủ tịch HĐQT duyệt', 'role', 'BGD',
        'users', to_jsonb(plan.chair_ids()), 'all_bgd', true, 'sla_hours', v_sla, 'warn_hours', 2, 'min_amount', null,
        'flags', '[]'::jsonb, 'fallback', null, 'notify', '[]'::jsonb));
    else
      v_out := v_out || jsonb_build_array(jsonb_build_object('seq', v_seq, 'label', 'Giám đốc duyệt', 'role', 'BGD',
        'users', '[]'::jsonb, 'sla_hours', v_sla, 'warn_hours', 2, 'min_amount', null, 'flags', '[]'::jsonb,
        'fallback', null, 'notify', '[]'::jsonb));
    end if;
  end if;
  return v_out;
end $$;

-- wf.build_snapshot: đề xuất chung lấy bước theo từng đề xuất
create or replace function pg_temp.patch(p_fn text, p_old text, p_new text) returns void language plpgsql as $$
declare d text := pg_get_functiondef(p_fn::regprocedure);
begin
  if position(p_old in d) = 0 then raise exception 'Vá %: không thấy đoạn cần vá', p_fn; end if;
  execute replace(d, p_old, p_new);
end $$;

select pg_temp.patch('wf.build_snapshot(text,uuid)', $o$v_cfg := wf.flow_config(p_doc_type);$o$,
  $n$v_cfg := wf.flow_config(p_doc_type);
  if p_doc_type = 'REQUEST' then v_cfg := jsonb_set(v_cfg, '{steps}', wf.req_steps(p_doc_id)); end if;$n$);

select pg_temp.patch('wf.can_submit(text)', $o$when 'STOCK_OPEN'  then$o$,
  $n$when 'REQUEST'     then true
    when 'STOCK_OPEN'  then$n$);

-- Chỉ người lập gửi duyệt đề xuất của mình (app.req_submit), không gửi hộ qua wf.submit
select pg_temp.patch('wf.check_doc(text,uuid)', $o$  elsif p_doc_type = 'PLAN_ADJ' then$o$,
  $n$  elsif p_doc_type = 'REQUEST' then
    if not exists (select 1 from wf.requests where id = p_doc_id and created_by = auth.uid()) then
      raise exception 'Chỉ người lập gửi duyệt đề xuất của mình';
    end if;
  elsif p_doc_type = 'PLAN_ADJ' then$n$);

-- Quá hạn duyệt đề xuất: báo cấp trên (bước thường → Giám đốc, bước Giám đốc → Chủ tịch), không ai duyệt thay
select pg_temp.patch('wf.check_sla()', $o$    if v_kind = 'OVERDUE' and cardinality(v_users) = 0 then$o$,
  $n$    if v_kind = 'OVERDUE' and r.doc_type = 'REQUEST' then
      select coalesce(array_agg(u), '{}') into v_backup
        from unnest(case when r.st ->> 'role' = 'BGD' then plan.chair_ids() else plan.gd_ids() end) u
       where u <> r.submitted_by and u <> all(v_users);
      perform wf.notify_users(v_backup, 'Đề xuất quá hạn duyệt: ' || r.doc_no,
        format('Bước "%s" hạn %s, người giữ bước chưa duyệt. %s', r.st ->> 'label',
               to_char(v_due at time zone 'Asia/Ho_Chi_Minh', 'DD/MM/YYYY HH24:MI'), coalesce(r.summary, '')),
        '/duyet/' || r.id, r.id, r.current_seq);
      v_n := v_n + cardinality(v_backup);
    end if;
    if v_kind = 'OVERDUE' and cardinality(v_users) = 0 then$n$);

-- Góp ý ẩn danh: chỉ người lập và Quản trị thấy tên
create or replace function wf.req_hide_name(p_req uuid) returns boolean
 language sql stable security definer set search_path to 'pg_catalog', 'public'
as $$
  select exists (select 1 from wf.requests r where r.id = p_req and r.anonymous
                  and r.created_by is distinct from auth.uid()) and not core.is_admin()
$$;

-- Quy trình duyệt: đường dẫn đề xuất, ẩn tên người gửi ẩn danh
do $$
declare d text := pg_get_viewdef('app.v_approvals'::regclass);
begin
  if position($o$WHEN 'DELIVERY'::text THEN$o$ in d) = 0 or position('app.user_name(submitted_by) AS submitted_by_name' in d) = 0
     or position($o$'actor', app.user_name(b.submitted_by)$o$ in d) = 0 then
    raise exception 'Vá app.v_approvals: không thấy đoạn cần vá';
  end if;
  d := replace(d, $o$WHEN 'DELIVERY'::text THEN$o$, $n$WHEN 'REQUEST'::text THEN ('/de-xuat-chung/'::text || doc_id)
            WHEN 'DELIVERY'::text THEN$n$);
  d := replace(d, 'app.user_name(submitted_by) AS submitted_by_name',
               $n$CASE WHEN doc_type = 'REQUEST'::text AND wf.req_hide_name(doc_id) THEN 'Ẩn danh'::text ELSE app.user_name(submitted_by) END AS submitted_by_name$n$);
  d := replace(d, $o$'actor', app.user_name(b.submitted_by)$o$,
               $n$'actor', CASE WHEN b.doc_type = 'REQUEST'::text AND wf.req_hide_name(b.doc_id) THEN 'Ẩn danh'::text ELSE app.user_name(b.submitted_by) END$n$);
  execute 'create or replace view app.v_approvals with (security_invoker = true) as ' || d;
end $$;

-- 6. Tóm tắt (hiện ở Quy trình duyệt, thông báo): không ghi lý do của đề xuất riêng tư ---------------------------
create or replace function wf.req_who(p_req uuid) returns text
 language sql stable security definer set search_path to 'pg_catalog', 'public'
as $$
  select coalesce(p.full_name, o.code || coalesce(' ' || o.full_name, ''), '?')
    from wf.requests r left join core.profiles p on p.id = r.requester_id
    left join master.operators o on o.code = r.operator_code where r.id = p_req
$$;

create or replace function wf.req_summary(p_req uuid) returns text
 language sql stable security definer set search_path to 'pg_catalog', 'public'
as $$
  select left(t.name || ' · ' || case when r.anonymous then 'Ẩn danh' else wf.req_who(r.id) end
    || case when r.date_from is not null then ' · ' || to_char(r.date_from, 'DD/MM/YYYY')
              || case when r.date_to is not null and r.date_to > r.date_from then '–' || to_char(r.date_to, 'DD/MM/YYYY') else '' end
              || case when r.days is not null and t.form in ('LEAVE','MATERNITY','TRIP')
                      then ' (' || replace(trim(to_char(r.days, 'FM999990.0')), '.0', '') || ' ngày'
                           || case r.part when 'AM' then ', nửa đầu ca' when 'PM' then ', nửa sau ca' else '' end || ')' else '' end
            else '' end
    || case when r.amount is not null then ' · ' || replace(to_char(r.amount, 'FM999,999,999,990'), ',', '.') || ' đ' else '' end
    || case when not t.private then ' · ' || r.title else '' end
    || case when r.urgent then ' · GẤP' else '' end, 500)
  from wf.requests r join wf.request_types t on t.code = r.type_code where r.id = p_req
$$;

-- 7. Lập, sửa, gửi, rút lại, hủy, từ chối ----------------------------------------------------------------------
create or replace function wf.req_can_create_for_worker() returns boolean
 language sql stable security definer set search_path to 'pg_catalog', 'public'
as $$
  select core.has_role('TO_TRUONG') or core.has_role('SX_TP') or core.has_role('SX_KH') or core.has_role('HCNS')
$$;

create or replace function app.req_save(p jsonb) returns uuid
 language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare v_id uuid := nullif(p ->> 'id', '')::uuid; r wf.requests; t wf.request_types; v_q wf.approval_requests; v_review boolean := false;
        v_type text := nullif(trim(coalesce(p ->> 'type', '')), ''); v_op text := nullif(upper(trim(coalesce(p ->> 'operator_code', ''))), '');
        v_req uuid; v_dept text; v_from date := nullif(p ->> 'date_from', '')::date; v_to date := nullif(p ->> 'date_to', '')::date;
        v_part text := coalesce(nullif(p ->> 'part', ''), 'FULL'); v_days numeric; v_amount numeric := nullif(p ->> 'amount', '')::numeric;
        v_items jsonb := '[]'; it jsonb; v_code text; v_qty numeric; v_machine uuid; v_target text := nullif(p ->> 'target_dept', '');
        v_content text := nullif(trim(coalesce(p ->> 'content', '')), ''); v_title text := nullif(trim(coalesce(p ->> 'title', '')), '');
        v_anon boolean := coalesce((p ->> 'anonymous')::boolean, false); v_data jsonb := coalesce(p -> 'data', '{}');
        v_changes text[] := '{}';
begin
  if auth.uid() is null then raise exception 'Chưa đăng nhập'; end if;
  if v_id is not null then
    select * into r from wf.requests where id = v_id for update;
    if not found then raise exception 'Không tìm thấy đề xuất'; end if;
    if r.status = 'PENDING_APPROVAL' then
      v_q := wf.review_request('REQUEST', v_id);   -- người đang giữ bước duyệt (kể cả ủy quyền, Quản trị) sửa trước khi duyệt
      v_review := true;
      v_type := r.type_code;
      v_op := r.operator_code;
      v_anon := r.anonymous;
    elsif r.status in ('DRAFT', 'RETURNED') then
      if r.created_by is distinct from auth.uid() and not core.is_admin() then
        raise exception 'Chỉ người lập sửa đề xuất khi còn nháp hoặc bị trả lại';
      end if;
    else
      raise exception 'Đề xuất % đang ở trạng thái không sửa được', r.req_no;
    end if;
  end if;
  select * into t from wf.request_types where code = v_type;
  if not found or not t.active then raise exception 'Chọn loại đề xuất'; end if;
  -- người đề xuất
  if v_review then
    v_req := r.requester_id; v_dept := r.dept;
  elsif v_op is not null then
    if not wf.req_can_create_for_worker() then raise exception 'Chỉ Tổ trưởng, TP SX, Kế hoạch SX, Nhân sự lập đề xuất thay công nhân'; end if;
    if not exists (select 1 from master.operators where code = v_op and active) then raise exception 'Không có công nhân %', v_op; end if;
    v_req := (select profile_id from master.operators where code = v_op);
    v_dept := coalesce(wf.user_dept(v_req), 'SX');
    if v_anon then raise exception 'Đề xuất lập thay không gửi ẩn danh'; end if;
  else
    v_req := case when v_id is null then auth.uid() else coalesce(r.requester_id, auth.uid()) end;
    v_dept := wf.user_dept(v_req);
    if v_dept is null then raise exception 'Tài khoản chưa có bộ phận: báo Quản trị gán bộ phận ở Quản trị → Người dùng'; end if;
  end if;
  if v_anon and not t.allow_anonymous then raise exception 'Loại "%" không gửi ẩn danh', t.name; end if;
  -- nội dung theo mẫu của loại
  if v_content is null then raise exception 'Nhập nội dung / lý do đề xuất'; end if;
  if t.form in ('LEAVE','MATERNITY','LATE','SHIFT','TRIP') and v_from is null then raise exception 'Chọn ngày'; end if;
  if t.form in ('LATE','SHIFT') then v_to := v_from; v_part := 'FULL'; end if;
  if t.form in ('MATERNITY','TRIP') and v_to is null then raise exception 'Chọn đến ngày'; end if;
  v_to := case when v_from is null then null else coalesce(v_to, v_from) end;
  if v_to < v_from then raise exception 'Đến ngày phải sau từ ngày'; end if;
  if v_part not in ('FULL','AM','PM') then raise exception 'Chọn cả ngày hoặc nửa ca'; end if;
  if v_part <> 'FULL' and (t.form <> 'LEAVE' or v_to <> v_from) then raise exception 'Nghỉ nửa ca chỉ chọn cho một ngày'; end if;
  if v_to - v_from > 366 then raise exception 'Mỗi đề xuất tối đa một năm'; end if;
  if t.form = 'LATE' and nullif(p ->> 'time_from', '') is null and nullif(p ->> 'time_to', '') is null then
    raise exception 'Nhập giờ đi hoặc giờ về';
  end if;
  if t.form = 'SHIFT' and coalesce(trim(v_data ->> 'to_shift'), '') = '' then raise exception 'Chọn ca muốn đổi sang'; end if;
  if t.form = 'TRIP' and coalesce(trim(v_data ->> 'place'), '') = '' then raise exception 'Nhập nơi công tác'; end if;
  if t.form = 'MONEY' and coalesce(v_amount, 0) <= 0 then raise exception 'Nhập số tiền'; end if;
  if t.form = 'OTHER' then
    if v_target is null or not exists (select 1 from core.departments where code = v_target) then raise exception 'Chọn bộ phận nhận'; end if;
  else
    v_target := null;
  end if;
  if t.form = 'BUY' then
    for it in select * from jsonb_array_elements(coalesce(p -> 'items', '[]')) loop
      v_code := nullif(upper(trim(coalesce(it ->> 'code', ''))), '');
      continue when v_code is null and coalesce(trim(it ->> 'name'), '') = '';
      if v_code is not null and not exists (select 1 from master.materials where code = v_code) then
        raise exception 'Không có mã vật tư %: bỏ mã, ghi tên hàng để Phòng Mua khai báo', v_code;
      end if;
      v_qty := nullif(it ->> 'qty', '')::numeric;
      if coalesce(v_qty, 0) <= 0 then raise exception 'Số lượng % phải lớn hơn 0', coalesce(v_code, it ->> 'name'); end if;
      v_items := v_items || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
        'code', v_code, 'name', coalesce(nullif(trim(it ->> 'name'), ''), (select name from master.materials where code = v_code)),
        'spec', nullif(trim(coalesce(it ->> 'spec', '')), ''), 'qty', v_qty,
        'unit', coalesce(nullif(trim(coalesce(it ->> 'unit', '')), ''), (select uom from master.materials where code = v_code)),
        'price', nullif(it ->> 'price', '')::numeric)));
    end loop;
    if jsonb_array_length(v_items) = 0 then raise exception 'Nhập ít nhất một mặt hàng'; end if;
    v_amount := nullif((select sum((x ->> 'qty')::numeric * (x ->> 'price')::numeric) from jsonb_array_elements(v_items) x
                         where x ? 'price'), 0);
  end if;
  if nullif(p ->> 'machine_code', '') is not null then
    select id into v_machine from master.machines where code = upper(trim(p ->> 'machine_code'));
    if v_machine is null then raise exception 'Không có máy %', p ->> 'machine_code'; end if;
  end if;
  v_days := case when t.form in ('LEAVE','MATERNITY','TRIP') then wf.req_days(t.form, v_from, v_to, v_part) end;
  if t.form = 'LEAVE' and coalesce(v_days, 0) = 0 then raise exception 'Khoảng ngày đã chọn không có ngày làm việc'; end if;
  v_title := coalesce(v_title, t.name);

  if v_id is null then
    insert into wf.requests (req_no, type_code, title, content, reason, urgent, requester_id, operator_code, dept, date_from, date_to, part,
                             time_from, time_to, days, amount, paid, machine_id, target_dept, items, data, anonymous)
    values (core.next_no('DX', 3), t.code, left(v_title, 200), v_content, nullif(trim(coalesce(p ->> 'reason', '')), ''),
            coalesce((p ->> 'urgent')::boolean, false), v_req, v_op, v_dept, v_from, v_to, v_part,
            nullif(p ->> 'time_from', '')::time, nullif(p ->> 'time_to', '')::time, v_days, v_amount,
            case when t.code = 'VIEC_RIENG' then coalesce((p ->> 'paid')::boolean, true) end,
            v_machine, v_target, v_items, v_data, v_anon)
    returning id into v_id;
    return v_id;
  end if;

  if v_review then
    if r.date_from is distinct from v_from or r.date_to is distinct from v_to or r.part is distinct from v_part then
      v_changes := v_changes || format('ngày %s → %s', coalesce(to_char(r.date_from, 'DD/MM/YYYY') || '–' || to_char(r.date_to, 'DD/MM/YYYY'), '—'),
                                       coalesce(to_char(v_from, 'DD/MM/YYYY') || '–' || to_char(v_to, 'DD/MM/YYYY'), '—'));
    end if;
    if r.amount is distinct from v_amount then
      v_changes := v_changes || format('số tiền %s → %s', coalesce(wf.fmt_qty(r.amount), '—'), coalesce(wf.fmt_qty(v_amount), '—'));
    end if;
    if r.items is distinct from v_items then v_changes := v_changes || 'danh sách hàng'::text; end if;
    if r.content is distinct from v_content or r.title is distinct from left(v_title, 200) then v_changes := v_changes || 'nội dung'::text; end if;
  end if;
  update wf.requests set type_code = t.code, title = left(v_title, 200), content = v_content,
         reason = nullif(trim(coalesce(p ->> 'reason', '')), ''), urgent = coalesce((p ->> 'urgent')::boolean, urgent),
         requester_id = v_req, operator_code = v_op, dept = v_dept, date_from = v_from, date_to = v_to, part = v_part,
         time_from = nullif(p ->> 'time_from', '')::time, time_to = nullif(p ->> 'time_to', '')::time, days = v_days, amount = v_amount,
         paid = case when t.code = 'VIEC_RIENG' then coalesce((p ->> 'paid')::boolean, true) end,
         machine_id = v_machine, target_dept = v_target, items = v_items, data = v_data, anonymous = v_anon,
         updated_at = now(), updated_by = auth.uid()
   where id = v_id;
  if v_review then
    update wf.approval_requests set summary = wf.req_summary(v_id) where id = v_q.id;
    perform wf.log_review_edit(v_q.id, 'Sửa ' || coalesce(nullif(array_to_string(v_changes, '; '), ''), 'nội dung đề xuất'));
  end if;
  return v_id;
end $$;

create or replace function app.req_submit(p_id uuid) returns uuid
 language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare r wf.requests;
begin
  select * into r from wf.requests where id = p_id;
  if not found then raise exception 'Không tìm thấy đề xuất'; end if;
  if r.created_by is distinct from auth.uid() then raise exception 'Chỉ người lập gửi đề xuất'; end if;
  if r.status not in ('DRAFT', 'RETURNED') then raise exception 'Đề xuất % đã gửi', r.req_no; end if;
  return wf.submit('REQUEST', p_id, r.req_no, wf.req_summary(p_id));
end $$;

-- Người lập rút lại khi chưa ai duyệt (về Nháp để sửa)
create or replace function app.req_withdraw(p_id uuid) returns void
 language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare r wf.requests; q wf.approval_requests;
begin
  select * into r from wf.requests where id = p_id for update;
  if not found then raise exception 'Không tìm thấy đề xuất'; end if;
  if r.created_by is distinct from auth.uid() and not core.is_admin() then raise exception 'Chỉ người lập rút lại đề xuất'; end if;
  if r.status <> 'PENDING_APPROVAL' then raise exception 'Đề xuất % không ở bước chờ duyệt', r.req_no; end if;
  select * into q from wf.approval_requests where doc_type = 'REQUEST' and doc_id = p_id and status = 'PENDING' for update;
  if found then
    if exists (select 1 from wf.approval_actions where request_id = q.id and action = 'APPROVE') then
      raise exception 'Đã có người duyệt một bước: không rút lại được, nhờ người đang duyệt trả lại';
    end if;
    insert into wf.approval_actions (request_id, seq, action, comment) values (q.id, q.current_seq, 'COMMENT', '[Người lập rút lại đề xuất]');
    update wf.approval_requests set status = 'CANCELLED', finished_at = now() where id = q.id;
  end if;
  update wf.requests set status = 'DRAFT', updated_at = now(), updated_by = auth.uid() where id = p_id;
end $$;

create or replace function app.req_cancel(p_id uuid) returns void
 language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare r wf.requests;
begin
  select * into r from wf.requests where id = p_id for update;
  if not found then raise exception 'Không tìm thấy đề xuất'; end if;
  if r.created_by is distinct from auth.uid() and not core.is_admin() then raise exception 'Chỉ người lập hủy đề xuất'; end if;
  if r.status not in ('DRAFT', 'RETURNED') then raise exception 'Chỉ hủy đề xuất còn nháp hoặc bị trả lại (đang chờ duyệt thì rút lại trước)'; end if;
  update wf.requests set status = 'CANCELLED', updated_at = now(), updated_by = auth.uid() where id = p_id;
end $$;

-- Người đang duyệt từ chối: đóng hồ sơ (khác Trả lại: không gửi lại được)
create or replace function app.req_refuse(p_id uuid, p_reason text) returns void
 language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare r wf.requests; q wf.approval_requests; v_step jsonb; v_ok boolean; v_behalf uuid;
begin
  if coalesce(trim(p_reason), '') = '' then raise exception 'Nhập lý do từ chối'; end if;
  select * into r from wf.requests where id = p_id for update;
  if not found then raise exception 'Không tìm thấy đề xuất'; end if;
  select * into q from wf.approval_requests where doc_type = 'REQUEST' and doc_id = p_id and status = 'PENDING' for update;
  if not found then raise exception 'Đề xuất % không ở bước chờ duyệt', r.req_no; end if;
  v_step := wf.snap_step(q, q.current_seq);
  select c.ok, c.on_behalf into v_ok, v_behalf from wf.can_act_step(v_step, q.step_started_at) c;
  if not v_ok then raise exception 'Chỉ người đang duyệt bước "%" từ chối được', v_step ->> 'label'; end if;
  if auth.uid() = q.submitted_by and not core.is_admin() then raise exception 'Người lập không tự từ chối: dùng Rút lại hoặc Hủy'; end if;
  insert into wf.approval_actions (request_id, seq, on_behalf_of, action, comment, data_hash)
  values (q.id, q.current_seq, v_behalf, 'REJECT', '[Từ chối] ' || trim(p_reason), q.data_hash);
  update wf.approval_requests set status = 'REJECTED', finished_at = now() where id = q.id;
  update wf.requests set status = 'REFUSED', handle_note = trim(p_reason), handled_by = auth.uid(), handled_at = now() where id = p_id;
  perform wf.notify_users(array_remove(array[r.created_by, r.requester_id], null), 'Đề xuất bị từ chối: ' || r.req_no,
                          trim(p_reason), '/de-xuat-chung/' || p_id);
end $$;

-- 8. Duyệt xong: MES tự chuyển tiếp ------------------------------------------------------------------------------
create or replace function wf.req_after_approve() returns trigger
 language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare t wf.request_types; v_op text; v_abs uuid; v_note text; v_handlers uuid[]; v_when text;
        k jsonb := '{"PHEP_NAM":"PHEP","OM":"OM","VIEC_RIENG":"RIENG","CONG_TAC":"CONG_TAC","THAI_SAN":"KHAC"}';
begin
  select * into t from wf.request_types where code = new.type_code;
  v_when := to_char(new.date_from, 'DD/MM/YYYY') || case when new.date_to > new.date_from then '–' || to_char(new.date_to, 'DD/MM/YYYY') else '' end;
  -- người đề xuất có tài khoản mà không phải người lập: cũng nhận tin đã duyệt
  if new.requester_id is not null and new.requester_id is distinct from new.created_by then
    perform wf.notify_users(array[new.requester_id], 'Đề xuất đã duyệt: ' || new.req_no, wf.req_summary(new.id), '/de-xuat-chung/' || new.id);
  end if;
  if t.action = 'ABSENCE' then
    v_op := coalesce(new.operator_code, (select code from master.operators where profile_id = new.requester_id and active limit 1));
    if v_op is not null and new.date_from is not null then
      insert into plan.operator_absences (operator_code, date_from, date_to, part, kind, note)
      values (v_op, new.date_from, new.date_to, new.part, k ->> t.code, 'Theo đề xuất ' || new.req_no)
      returning id into v_abs;
      perform app.kh_log('Lịch vắng', v_op || coalesce(' ' || (select full_name from master.operators where code = v_op), ''), '—',
        v_when || case new.part when 'AM' then ' nửa đầu ca' when 'PM' then ' nửa sau ca' else '' end || ', ' || lower(t.name),
        'Theo đề xuất ' || new.req_no);
      perform wf.notify_users(inv.role_users(array['SX_TP', 'SX_KH']), 'Công nhân vắng: ' || v_op || ' ' || v_when,
        lower(t.name) || ' theo đề xuất ' || new.req_no || ' đã duyệt. Lịch vắng đã ghi: bấm Xếp lại lịch, kiểm Bảng ca tuần.',
        '/nhan-su-xuong');
      v_note := 'Đã ghi lịch vắng ' || v_op || ' ' || v_when;
    else
      v_note := 'Đã ghi nghỉ ' || coalesce(v_when, '');
    end if;
    if t.grp = 'NS' then
      perform wf.notify_users(wf.hr_ids(), 'Nhân sự: ' || new.req_no || ' đã duyệt', wf.req_summary(new.id), '/de-xuat-chung/' || new.id);
    end if;
    update wf.requests set status = 'DONE', handled_at = now(), handle_note = v_note,
           absence_ids = case when v_abs is null then absence_ids else absence_ids || v_abs end
     where id = new.id;
    return new;
  end if;
  if t.action = 'NOTICE' then
    if t.code = 'DOI_CA' then
      perform wf.notify_users(inv.role_users(array['SX_TP', 'SX_KH']), 'Đổi ca đã duyệt: ' || wf.req_who(new.id) || ' ' || v_when,
        coalesce(new.data ->> 'from_shift', '') || ' → ' || coalesce(new.data ->> 'to_shift', '') || '. Sửa Bảng ca tuần nếu cần.',
        '/nhan-su-xuong?tab=bang-ca');
    end if;
    if t.grp = 'NS' then
      perform wf.notify_users(wf.hr_ids(), 'Nhân sự: ' || new.req_no || ' đã duyệt', wf.req_summary(new.id), '/de-xuat-chung/' || new.id);
    end if;
    update wf.requests set status = 'DONE', handled_at = now(), handle_note = 'Đã duyệt, đã báo bộ phận liên quan' where id = new.id;
    return new;
  end if;
  v_handlers := wf.req_handler_ids(new.id);
  if cardinality(v_handlers) = 0 then
    update wf.requests set status = 'DONE', handled_at = now(), handle_note = 'Đã duyệt' where id = new.id;
    return new;
  end if;
  perform wf.notify_users(v_handlers, 'Đề xuất cần xử lý: ' || new.req_no, wf.req_summary(new.id)
    || case t.action when 'PR' then '. Lập đề xuất mua từ đề xuất này.' when 'REPAIR' then '. Mở phiếu sửa chữa hoặc ghi việc đã làm.' else '' end,
    '/de-xuat-chung/' || new.id);
  return new;
end $$;

drop trigger if exists trg_req_after_approve on wf.requests;
create trigger trg_req_after_approve after update of status on wf.requests
  for each row when (new.status = 'APPROVED' and old.status is distinct from 'APPROVED')
  execute function wf.req_after_approve();

-- 9. Xử lý sau khi duyệt ---------------------------------------------------------------------------------------
create or replace function wf.req_for_handle(p_id uuid) returns wf.requests
 language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare r wf.requests;
begin
  select * into r from wf.requests where id = p_id for update;
  if not found then raise exception 'Không tìm thấy đề xuất'; end if;
  if r.status <> 'APPROVED' then raise exception 'Đề xuất % không ở bước chờ xử lý', r.req_no; end if;
  if not wf.req_can_handle(p_id) then raise exception 'Bạn không phải người xử lý đề xuất này'; end if;
  return r;
end $$;

create or replace function wf.req_finish(r wf.requests, p_note text) returns void
 language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
begin
  update wf.requests set status = 'DONE', handled_by = auth.uid(), handled_at = now(), handle_note = p_note where id = r.id;
  perform wf.notify_users(array_remove(array_remove(array[r.created_by, r.requester_id], null), auth.uid()),
                          'Đề xuất đã xử lý: ' || r.req_no, p_note, '/de-xuat-chung/' || r.id);
end $$;

create or replace function app.req_done(p_id uuid, p_note text) returns void
 language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare r wf.requests;
begin
  if coalesce(trim(p_note), '') = '' then raise exception 'Ghi việc đã làm (ví dụ "đã chi 3.000.000 đ ngày 25/11/2026")'; end if;
  r := wf.req_for_handle(p_id);
  perform wf.req_finish(r, trim(p_note));
end $$;

-- Phòng Mua lập đề xuất mua từ đề xuất chung (dòng có mã vật tư; hàng chưa có mã khai vật tư mới trước)
create or replace function app.req_make_pr(p_id uuid, p_lines jsonb default null, p_need date default null) returns uuid
 language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare r wf.requests; t wf.request_types; v_lines jsonb; v_pr uuid; v_no text; v_missing text;
begin
  r := wf.req_for_handle(p_id);
  select * into t from wf.request_types where code = r.type_code;
  if t.action <> 'PR' then raise exception 'Loại "%" không lập đề xuất mua', t.name; end if;
  v_lines := coalesce(p_lines, (select coalesce(jsonb_agg(jsonb_build_object('material_code', x ->> 'code', 'qty', x ->> 'qty')), '[]')
                                  from jsonb_array_elements(r.items) x where x ? 'code'));
  if jsonb_array_length(v_lines) = 0 then
    raise exception 'Các mặt hàng chưa có mã vật tư: khai vật tư mới ở Mua hàng → Vật tư rồi ghi mã từng dòng';
  end if;
  select string_agg(x ->> 'name', ', ') into v_missing from jsonb_array_elements(r.items) x where not x ? 'code';
  v_pr := app.create_pr(coalesce(p_need, r.date_from, plan.vn_today() + 7),
    'Theo đề xuất ' || r.req_no || ' (' || wf.req_who(r.id) || '): ' || r.title || '. ' || r.content
      || coalesce('. Hàng chưa có mã: ' || v_missing, ''),
    v_lines, case r.type_code when 'MUA_CCDC' then 'CCDC' else 'BO_SUNG' end);
  select pr_no into v_no from purchase.purchase_requests where id = v_pr;
  update wf.requests set pr_id = v_pr where id = p_id;
  perform wf.req_finish(r, 'Đã lập đề xuất mua ' || v_no || ', theo dõi ở Mua hàng → Đề xuất mua');
  return v_pr;
end $$;

-- TP KT/QA mở phiếu sửa chữa cho máy đã chọn
create or replace function app.req_make_repair(p_id uuid) returns uuid
 language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare r wf.requests; m master.machines; v_wo uuid; v_no text;
begin
  r := wf.req_for_handle(p_id);
  if r.type_code <> 'SUA_CHUA' then raise exception 'Chỉ đề xuất sửa chữa mở phiếu sửa chữa'; end if;
  select * into m from master.machines where id = r.machine_id;
  if not found then raise exception 'Đề xuất không chọn máy: sửa xong bấm "Đã xử lý" và ghi việc đã làm'; end if;
  v_no := core.next_no('SC');
  insert into mfg.maint_work_orders (wo_no, wo_type, machine_id, title, cause, assignee_role, note)
  values (v_no, 'CM', m.id, left('Sửa chữa ' || m.code || ': ' || r.title, 200), r.content, 'KT_TP', 'Theo đề xuất ' || r.req_no)
  returning id into v_wo;
  update wf.requests set maint_wo_id = v_wo where id = p_id;
  perform wf.req_finish(r, 'Đã mở phiếu sửa chữa ' || v_no);
  return v_wo;
end $$;

-- 10. View cho web ---------------------------------------------------------------------------------------------
create or replace view app.v_request_types with (security_invoker = true) as
  select code, grp, name, hint, form, gd_rule, gd_threshold, expert_role, handler_roles, action, private, sla_hours, allow_anonymous, sort
    from wf.request_types where active;

-- Tiến độ duyệt của đề xuất cho người xem được đề xuất (công nhân không có quyền xem cấu hình quy trình)
create or replace function wf.req_approval(p_req uuid) returns jsonb
 language plpgsql stable security definer set search_path to 'pg_catalog', 'public'
as $$
declare v jsonb;
begin
  if not wf.req_can_view(p_req) then return null; end if;
  select to_jsonb(a) into v from app.v_approvals a where a.doc_type = 'REQUEST' and a.doc_id = p_req order by a.submitted_at desc limit 1;
  return v;
end $$;

create or replace view app.v_requests with (security_invoker = true) as
  select r.id, r.req_no, r.type_code, t.name as type_name, t.grp, t.form, t.private, t.action, r.title, r.content, r.reason, r.urgent,
         case when wf.req_hide_name(r.id) then null else r.requester_id end as requester_id,
         case when wf.req_hide_name(r.id) then null else r.operator_code end as operator_code,
         case when wf.req_hide_name(r.id) then 'Ẩn danh' else wf.req_who(r.id) end as requester_name,
         r.dept, d.name as dept_name, r.date_from, r.date_to, r.part, r.time_from, r.time_to, r.days, r.amount, r.paid,
         r.machine_id, m.code as machine_code, r.target_dept, td.name as target_dept_name, r.items, r.data, r.anonymous,
         r.status,
         case r.status when 'DRAFT' then 'Nháp' when 'PENDING_APPROVAL' then 'Chờ duyệt' when 'RETURNED' then 'Bị trả lại'
                       when 'APPROVED' then 'Đã duyệt, chờ xử lý' when 'DONE' then 'Hoàn tất' when 'REFUSED' then 'Bị từ chối'
                       else 'Đã hủy' end as status_label,
         case when wf.req_hide_name(r.id) then null else r.created_by end as created_by,
         case when wf.req_hide_name(r.id) then 'Ẩn danh' else app.user_name(r.created_by) end as creator_name,
         r.created_at, r.handled_by, app.user_name(r.handled_by) as handler_name, r.handled_at, r.handle_note,
         r.pr_id, pr.pr_no, r.maint_wo_id, wo.wo_no as maint_wo_no,
         (a.j ->> 'id')::uuid as approval_id, a.j ->> 'current_level' as current_level, a.j -> 'current_approvers' as current_approvers,
         (a.j ->> 'step_due_at')::timestamptz as step_due_at, (a.j ->> 'overdue')::boolean as overdue, a.j -> 'steps' as steps,
         a.j -> 'history' as history, coalesce((a.j ->> 'my_turn')::boolean, false) as my_turn,
         (r.status = 'APPROVED' and wf.req_can_handle(r.id)) as can_handle,
         (r.created_by = (select auth.uid())) as mine
    from wf.requests r
    join wf.request_types t on t.code = r.type_code
    left join core.departments d on d.code = r.dept
    left join core.departments td on td.code = r.target_dept
    left join master.machines m on m.id = r.machine_id
    left join purchase.purchase_requests pr on pr.id = r.pr_id
    left join mfg.maint_work_orders wo on wo.id = r.maint_wo_id
    left join lateral (select wf.req_approval(r.id) as j) a on true;
grant select on app.v_request_types, app.v_requests to authenticated;

-- 11. Số đếm menu: đề xuất chờ tôi xử lý ------------------------------------------------------------------------
select pg_temp.patch('app.menu_counts()', $o$v_alarm int;$o$, $n$v_alarm int; v_req bigint;$n$);
select pg_temp.patch('app.menu_counts()', $o$  return jsonb_build_object('my_turn', v_turn,$o$,
  $n$  -- đề xuất chung đã duyệt chờ tôi xử lý (lập đề xuất mua, mở phiếu sửa chữa, chi tiền…)
  begin select count(*) into v_req from app.v_requests where can_handle; exception when others then v_req := null; end;
  return jsonb_build_object('req_todo', v_req, 'my_turn', v_turn,$n$);

-- 12. Quyền gọi hàm ----------------------------------------------------------------------------------------------
revoke execute on function wf.user_has_role(uuid, text), wf.user_dept(uuid), wf.dept_head_role(text), wf.hr_ids(),
  wf.req_handler_ids(uuid), wf.req_days(text, date, date, text), wf.req_steps(uuid), wf.req_summary(uuid),
  wf.req_can_create_for_worker(), wf.req_after_approve(), wf.req_for_handle(uuid), wf.req_finish(wf.requests, text)
  from public, anon, authenticated;
revoke execute on function wf.req_can_view(uuid), wf.req_can_handle(uuid), wf.req_hide_name(uuid), wf.req_who(uuid), wf.req_approval(uuid) from public, anon;
grant execute on function wf.req_can_view(uuid), wf.req_can_handle(uuid), wf.req_hide_name(uuid), wf.req_who(uuid), wf.req_approval(uuid) to authenticated;
revoke execute on function app.req_save(jsonb), app.req_submit(uuid), app.req_withdraw(uuid), app.req_cancel(uuid),
  app.req_refuse(uuid, text), app.req_done(uuid, text), app.req_make_pr(uuid, jsonb, date), app.req_make_repair(uuid) from public, anon;
grant execute on function app.req_save(jsonb), app.req_submit(uuid), app.req_withdraw(uuid), app.req_cancel(uuid),
  app.req_refuse(uuid, text), app.req_done(uuid, text), app.req_make_pr(uuid, jsonb, date), app.req_make_repair(uuid) to authenticated;
