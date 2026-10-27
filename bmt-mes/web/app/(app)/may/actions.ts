'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { parseNum } from '@/lib/format';
import { vnDateTime } from '@/lib/machine';
import { createClient } from '@/lib/supabase/server';

// Quay lại trang đang thao tác kèm thông báo ?ok= / ?err=
function back(form: FormData, kind: 'ok' | 'err', msg: string): never {
  const path = String(form.get('back') ?? '/may') || '/may';
  const [base, hash] = path.split('#');
  const sep = base.includes('?') ? '&' : '?';
  const clean = base.replace(/([?&])(ok|err)=[^&]*/g, '$1').replace(/[?&]$/, '');
  redirect(`${clean}${clean.includes('?') ? '&' : sep}${kind}=${encodeURIComponent(msg)}${hash ? '#' + hash : ''}`);
}
const txt = (form: FormData, k: string) => String(form.get(k) ?? '').trim();
const opt = (form: FormData, k: string) => txt(form, k) || null;
const num = (form: FormData, k: string) => { const n = parseNum(form.get(k)); return n === null || Number.isNaN(n) ? null : n; };
const friendly = (m: string) => m.includes('row-level') ? 'Bạn chưa có quyền thực hiện thao tác này' : m;
function done(form: FormData, msg: string): never {
  revalidatePath('/may', 'layout');
  back(form, 'ok', msg);
}

// ---------------------------------------------------------------- Máy
export async function createMachine(form: FormData) {
  const supabase = await createClient();
  const parent = opt(form, 'parent_id');
  const { data, error } = await supabase.schema('app').rpc('create_machine', {
    p_parent: parent, p_code: txt(form, 'code'), p_name: txt(form, 'name'), p_unit_kind: opt(form, 'unit_kind'),
    p_op_code: opt(form, 'op_code'), p_critical: form.get('critical') === 'on', p_seq: num(form, 'seq') ?? 0,
    p_template: form.get('template') === 'on',
  });
  if (error) back(form, 'err', friendly(error.message));
  revalidatePath('/may', 'layout');
  redirect(`/may/${data}?ok=` + encodeURIComponent(parent ? 'Đã thêm máy con. Điền thông số bên dưới.' : 'Đã thêm dây chuyền. Thêm máy con và thông số.'));
}

export async function updateMachine(form: FormData) {
  const supabase = await createClient();
  const year = num(form, 'year_made');
  const kw = num(form, 'rated_kw');
  const { error, data } = await supabase.schema('master').from('machines').update({
    name: txt(form, 'name'), unit_kind: opt(form, 'unit_kind'), critical: form.get('critical') === 'on',
    seq: num(form, 'seq') ?? 0, vendor: opt(form, 'vendor'), model: opt(form, 'model'), serial_no: opt(form, 'serial_no'),
    year_made: year === null ? null : Math.round(year), location: opt(form, 'location'), note: opt(form, 'note'),
    rated_kw: kw, plc_model: opt(form, 'plc_model'), active: form.get('active') === 'on',
  }).eq('id', txt(form, 'id')).select('id');
  if (error) back(form, 'err', friendly(error.message));
  if (!data?.length) back(form, 'err', 'Bạn chưa có quyền sửa thông tin máy');
  done(form, 'Đã lưu thông tin máy');
}

export async function setStatus(form: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('set_machine_status', {
    p_machine: txt(form, 'machine_id'), p_status: txt(form, 'status'), p_reason: opt(form, 'reason'),
    p_note: opt(form, 'note'), p_eta: vnDateTime(form.get('eta')),
  });
  if (error) back(form, 'err', friendly(error.message));
  done(form, txt(form, 'status') === 'DOWN' ? 'Đã báo hỏng: mở phiếu sửa chữa, báo TP Kỹ thuật/QA; TP SX được báo xếp lại lịch máy' : 'Đã cập nhật trạng thái máy');
}

// ---------------------------------------------------------------- Thông số, linh kiện, dải, tốc độ, người, tài liệu
export async function saveSpecs(form: FormData) {
  const supabase = await createClient();
  const machineId = txt(form, 'machine_id');
  const ids = form.getAll('spec_id').map(String);
  let changed = 0;
  for (const id of ids) {
    if (form.get(`del_${id}`) === 'on') {
      const { error } = await supabase.schema('master').from('machine_specs').delete().eq('id', id);
      if (error) back(form, 'err', friendly(error.message));
      changed++;
      continue;
    }
    const value = opt(form, `v_${id}`), uom = opt(form, `u_${id}`), source = opt(form, `s_${id}`);
    const before = { value: opt(form, `ov_${id}`), uom: opt(form, `ou_${id}`), source: opt(form, `os_${id}`) };
    if (before.value === value && before.uom === uom && before.source === source) continue;
    const { error } = await supabase.schema('master').from('machine_specs').update({ value, uom, source: value ? (source ?? 'BMT') : source }).eq('id', id);
    if (error) back(form, 'err', friendly(error.message));
    changed++;
  }
  const label = txt(form, 'new_label');
  if (label) {
    const { error } = await supabase.schema('master').from('machine_specs').insert({
      machine_id: machineId, grp: txt(form, 'new_grp') || 'Chung', label, value: opt(form, 'new_value'), uom: opt(form, 'new_uom'),
      source: opt(form, 'new_source') ?? (opt(form, 'new_value') ? 'BMT' : null), sort: 1000,
    });
    if (error) back(form, 'err', error.code === '23505' ? `Đã có thông số "${label}" trong nhóm này` : friendly(error.message));
    changed++;
  }
  done(form, changed ? `Đã lưu ${changed} thay đổi thông số` : 'Không có gì thay đổi');
}

export async function addComponent(form: FormData) {
  const supabase = await createClient();
  if (!txt(form, 'name')) back(form, 'err', 'Nhập tên linh kiện');
  const { error } = await supabase.schema('master').from('machine_components').insert({
    machine_id: txt(form, 'machine_id'), kind: txt(form, 'kind') || 'OTHER', name: txt(form, 'name'), spec: opt(form, 'spec'),
    qty: num(form, 'qty'), position: opt(form, 'position'), material_id: opt(form, 'material_id'), min_stock: num(form, 'min_stock'), note: opt(form, 'note'),
  });
  if (error) back(form, 'err', friendly(error.message));
  done(form, 'Đã thêm linh kiện');
}

export async function deleteRow(form: FormData) {
  const table = txt(form, 'table');
  const allowed: Record<string, [string, string]> = {
    component: ['master', 'machine_components'], range: ['master', 'machine_ranges'], speed: ['master', 'machine_speeds'],
    doc: ['master', 'machine_docs'], part: ['mfg', 'maint_wo_parts'],
    check_item: ['mfg', 'maint_check_items'], plan: ['mfg', 'maint_plans'],
  };
  const t = allowed[table];
  if (!t) back(form, 'err', 'Thao tác không hợp lệ');
  const supabase = await createClient();
  const { data, error } = await supabase.schema(t[0]).from(t[1]).delete().eq('id', txt(form, 'id')).select('id');
  if (error) back(form, 'err', error.code === '23503' ? 'Không xóa được: đang có phiếu dùng mục này' : friendly(error.message));
  if (!data?.length) back(form, 'err', 'Không xóa được: bạn chưa có quyền hoặc mục đã được duyệt');
  done(form, 'Đã xóa');
}

// Dải hoạt động: một khoảng tiết diện ruột dẫn (mm²) cho mỗi dây chuyền; để trống cả hai thì bỏ dải
export async function saveRange(form: FormData) {
  const supabase = await createClient();
  const machineId = txt(form, 'machine_id');
  const min = num(form, 'min_value'), max = num(form, 'max_value');
  if ((min !== null && min <= 0) || (max !== null && max <= 0)) back(form, 'err', 'Tiết diện phải lớn hơn 0');
  if (min !== null && max !== null && min > max) back(form, 'err', 'Tiết diện "từ" lớn hơn "đến"');
  const { data: cur, error: e0 } = await supabase.schema('master').from('machine_ranges').select('id').eq('machine_id', machineId).eq('param', 'SIZE_MM2');
  if (e0) back(form, 'err', friendly(e0.message));
  const id = cur?.[0]?.id as string | undefined;
  if (min === null && max === null) {
    if (id) {
      const { data, error } = await supabase.schema('master').from('machine_ranges').delete().eq('id', id).select('id');
      if (error) back(form, 'err', friendly(error.message));
      if (!data?.length) back(form, 'err', 'Bạn chưa có quyền sửa dải hoạt động');
    }
    done(form, 'Đã bỏ dải hoạt động');
  }
  const row = { min_value: min, max_value: max, uom: 'mm²' };
  const res = id
    ? await supabase.schema('master').from('machine_ranges').update(row).eq('id', id).select('id')
    : await supabase.schema('master').from('machine_ranges').insert({ ...row, machine_id: machineId, param: 'SIZE_MM2', label: 'Tiết diện ruột' }).select('id');
  if (res.error) back(form, 'err', friendly(res.error.message));
  if (!res.data?.length) back(form, 'err', 'Bạn chưa có quyền sửa dải hoạt động');
  done(form, 'Đã lưu dải hoạt động');
}

export async function addSpeed(form: FormData) {
  const supabase = await createClient();
  const std = num(form, 'std_mpm');
  if (!std || std <= 0) back(form, 'err', 'Nhập tốc độ chuẩn lớn hơn 0');
  const rated = num(form, 'rated_mpm');
  if (rated && std! > rated) back(form, 'err', 'Tốc độ chuẩn không được cao hơn tốc độ danh định của nhà sản xuất');
  const { error } = await supabase.schema('master').from('machine_speeds').insert({
    machine_id: txt(form, 'machine_id'), op_code: txt(form, 'op_code'), product_id: opt(form, 'product_id'),
    group_code: opt(form, 'group_code'), core_code: opt(form, 'core_code'), label: opt(form, 'label'),
    rated_mpm: rated, std_mpm: std, setup_min: num(form, 'setup_min') ?? 0, source: opt(form, 'source'), note: opt(form, 'note'),
  });
  if (error) back(form, 'err', friendly(error.message));
  done(form, 'Đã thêm tốc độ, chờ TP Kỹ thuật/QA duyệt');
}

export async function approveSpeed(form: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('approve_machine_speed', { p_id: txt(form, 'id') });
  if (error) back(form, 'err', friendly(error.message));
  done(form, 'Đã duyệt tốc độ chuẩn');
}

// Người đứng máy: dùng chung NV1–NV5 với Lịch máy (master.operator_skills)
export async function setOperatorSkill(form: FormData) {
  const supabase = await createClient();
  if (!txt(form, 'operator')) back(form, 'err', 'Chọn người đứng máy');
  const { error } = await supabase.schema('app').rpc('set_operator_skill', {
    p_machine: txt(form, 'machine_id'), p_operator: txt(form, 'operator'), p_level: txt(form, 'level') || 'MAIN', p_reason: opt(form, 'reason'),
  });
  if (error) back(form, 'err', friendly(error.message));
  done(form, 'Đã giao người đứng máy. Lịch máy dùng ngay khi xếp lại lịch.');
}

export async function removeOperatorSkill(form: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('remove_operator_skill', {
    p_machine: txt(form, 'machine_id'), p_operator: txt(form, 'operator'), p_reason: opt(form, 'reason'),
  });
  if (error) back(form, 'err', friendly(error.message));
  done(form, 'Đã bỏ giao người đứng máy');
}

export async function signOperatorSkill(form: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('sign_operator_skill', { p_machine: txt(form, 'machine_id'), p_operator: txt(form, 'operator') });
  if (error) back(form, 'err', friendly(error.message));
  done(form, 'Đã xác nhận tay nghề');
}

export async function addDoc(form: FormData) {
  const supabase = await createClient();
  if (!txt(form, 'title')) back(form, 'err', 'Nhập tên tài liệu');
  const url = opt(form, 'url');
  if (url && !/^https?:\/\//i.test(url)) back(form, 'err', 'Đường dẫn tài liệu phải bắt đầu bằng http:// hoặc https://');
  const { error } = await supabase.schema('master').from('machine_docs').insert({
    machine_id: txt(form, 'machine_id'), title: txt(form, 'title'), url, kind: txt(form, 'kind') || 'OTHER',
    status: txt(form, 'status') || 'ISSUED', note: opt(form, 'note'),
  });
  if (error) back(form, 'err', friendly(error.message));
  done(form, 'Đã thêm tài liệu');
}

// ---------------------------------------------------------------- Bảo dưỡng
export async function savePlan(form: FormData) {
  const supabase = await createClient();
  const id = opt(form, 'id');
  const days = num(form, 'every_days'), hours = num(form, 'every_hours'), km = num(form, 'every_km');
  if (!txt(form, 'name')) back(form, 'err', 'Nhập tên công việc bảo dưỡng');
  if (!txt(form, 'machine_id')) back(form, 'err', 'Chọn máy');
  if (!days && !hours && !km) back(form, 'err', 'Đặt ít nhất một chu kỳ: theo ngày, giờ chạy hoặc km');
  if ([days, hours, km].some((v) => v !== null && v <= 0)) back(form, 'err', 'Chu kỳ phải lớn hơn 0');
  const remind = num(form, 'remind_days');
  const level = txt(form, 'level') === 'MAJOR' ? 'MAJOR' : 'MINOR';
  const row: Record<string, unknown> = {
    machine_id: txt(form, 'machine_id'), name: txt(form, 'name'), kind: txt(form, 'kind') || 'INSPECT', level,
    every_days: days === null ? null : Math.round(days), every_hours: hours, every_km: km,
    remind_days: remind === null ? (level === 'MAJOR' ? 30 : 7) : Math.max(0, Math.round(remind)),
    stop_minutes: Math.max(0, Math.round(num(form, 'stop_minutes') ?? 0)), off_shift: form.get('off_shift') === 'on',
    assignee_role: txt(form, 'assignee_role') || 'KT_TP',
    steps: txt(form, 'steps').split('\n').map((s) => s.trim()).filter(Boolean), parts: opt(form, 'parts'), note: opt(form, 'note'),
    active: id ? form.get('active') === 'on' : true,
  };
  const last = txt(form, 'last_done');
  if (last && last !== txt(form, 'last_done_orig')) row.last_done_at = `${last}T17:00:00+07:00`;  // chỉ đổi mốc khi người dùng sửa ngày
  const baseH = num(form, 'base_hours'), baseKm = num(form, 'base_km');
  if (baseH !== null) row.base_hours = baseH;
  if (baseKm !== null) row.base_km = baseKm;
  const res = id
    ? await supabase.schema('mfg').from('maint_plans').update(row).eq('id', id).select('id')
    : await supabase.schema('mfg').from('maint_plans').insert(row).select('id');
  if (res.error) back(form, 'err', friendly(res.error.message));
  if (!res.data?.length) back(form, 'err', 'Bạn chưa có quyền lưu kế hoạch bảo dưỡng');
  revalidatePath('/may', 'layout');
  redirect('/may/bao-duong?ok=' + encodeURIComponent(id ? 'Đã lưu kế hoạch bảo dưỡng' : `Đã thêm kế hoạch "${row.name}". Hệ thống tự nhắc trước ${row.remind_days} ngày.`));
}

export async function createWo(form: FormData) {
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc('create_maint_wo', { p_plan: txt(form, 'plan_id'), p_date: opt(form, 'planned_date') });
  if (error) back(form, 'err', friendly(error.message));
  revalidatePath('/may', 'layout');
  redirect(`/may/bao-duong/phieu/${data}?ok=` + encodeURIComponent('Đã tạo phiếu bảo dưỡng'));
}

export async function startWo(form: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('start_maint_wo', { p_id: txt(form, 'id') });
  if (error) back(form, 'err', friendly(error.message));
  done(form, 'Đã bắt đầu làm phiếu');
}

export async function saveWoProgress(form: FormData) {
  const supabase = await createClient();
  const labels = form.getAll('step_label').map(String);
  const steps = labels.map((label, i) => ({ label, done: form.get(`step_${i}`) === 'on' }));
  const { error, data } = await supabase.schema('mfg').from('maint_work_orders').update({
    steps, cause: opt(form, 'cause'), note: opt(form, 'note'), eta: vnDateTime(form.get('eta')) ?? undefined,
  }).eq('id', txt(form, 'id')).in('status', ['OPEN', 'IN_PROGRESS']).select('id');
  if (error) back(form, 'err', friendly(error.message));
  if (!data?.length) back(form, 'err', 'Không lưu được: phiếu đã đóng hoặc bạn chưa có quyền');
  if (vnDateTime(form.get('eta'))) {
    const { data: w } = await supabase.schema('mfg').from('maint_work_orders').select('machine_id, wo_type').eq('id', txt(form, 'id')).single();
    if (w?.wo_type === 'CM') await supabase.schema('master').from('machines').update({ status_eta: vnDateTime(form.get('eta')) }).eq('id', w.machine_id).eq('status', 'DOWN');
  }
  done(form, 'Đã lưu phiếu');
}

export async function finishWo(form: FormData) {
  const supabase = await createClient();
  const labels = form.getAll('step_label').map(String);
  const steps = labels.map((label, i) => ({ label, done: form.get(`step_${i}`) === 'on' }));
  if (txt(form, 'result') === 'OK' && steps.some((s) => !s.done)) back(form, 'err', 'Còn bước chưa làm. Đánh dấu đủ các bước hoặc chọn kết quả "Chưa đạt".');
  const { error } = await supabase.schema('app').rpc('finish_maint_wo', {
    p_id: txt(form, 'id'), p_result: txt(form, 'result'), p_action: txt(form, 'action_taken'), p_steps: steps, p_cause: opt(form, 'cause'),
  });
  if (error) back(form, 'err', friendly(error.message));
  done(form, 'Đã hoàn thành phiếu. TP Kỹ thuật/QA xác nhận phiếu.');
}

export async function confirmWo(form: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('confirm_maint_wo', { p_id: txt(form, 'id') });
  if (error) back(form, 'err', friendly(error.message));
  done(form, 'Đã xác nhận máy chạy lại đạt');
}

export async function cancelWo(form: FormData) {
  const supabase = await createClient();
  const { error, data } = await supabase.schema('mfg').from('maint_work_orders').update({ status: 'CANCELLED', note: opt(form, 'note') })
    .eq('id', txt(form, 'id')).eq('status', 'OPEN').select('id');
  if (error) back(form, 'err', friendly(error.message));
  if (!data?.length) back(form, 'err', 'Chỉ hủy được phiếu chưa bắt đầu');
  done(form, 'Đã hủy phiếu');
}

export async function addPart(form: FormData) {
  const supabase = await createClient();
  const qty = num(form, 'qty');
  if (!txt(form, 'item')) back(form, 'err', 'Nhập tên phụ tùng');
  if (!qty || qty <= 0) back(form, 'err', 'Số lượng phải lớn hơn 0');
  const { error } = await supabase.schema('mfg').from('maint_wo_parts').insert({
    wo_id: txt(form, 'wo_id'), item: txt(form, 'item'), qty, uom: opt(form, 'uom'), material_id: opt(form, 'material_id'), note: opt(form, 'note'),
  });
  if (error) back(form, 'err', friendly(error.message));
  done(form, 'Đã ghi phụ tùng');
}

// ---------------------------------------------------------------- Checklist đầu ca
export async function saveCheck(form: FormData) {
  const supabase = await createClient();
  const labels = form.getAll('item').map(String);
  const results = labels.map((label, i) => ({ label, ok: form.get(`ok_${i}`) === 'ok', note: txt(form, `note_${i}`) || null }));
  const missing = labels.filter((_, i) => !form.get(`ok_${i}`));
  if (missing.length) back(form, 'err', `Chọn Đạt / Không đạt cho: ${missing.join(', ')}`);
  const { error } = await supabase.schema('app').rpc('save_daily_check', { p_machine: txt(form, 'machine_id'), p_results: results, p_note: opt(form, 'note') });
  if (error) back(form, 'err', friendly(error.message));
  done(form, results.every((r) => r.ok) ? `Đã ghi checklist ${txt(form, 'machine_code')}: đạt` : `Đã ghi checklist ${txt(form, 'machine_code')}, đã báo TP Kỹ thuật/QA và Quản lý SX mục không đạt`);
}

export async function reviewCheck(form: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('review_daily_check', { p_id: txt(form, 'id') });
  if (error) back(form, 'err', friendly(error.message));
  done(form, 'Đã kiểm tra checklist');
}

// ---------------------------------------------------------------- Cài đặt
// Ngày nhắc bảo dưỡng (TP Kỹ thuật/QA)
export async function saveSettings(form: FormData) {
  const supabase = await createClient();
  const minor = num(form, 'remind_minor'), major = num(form, 'remind_major');
  if (minor === null || major === null || minor < 0 || major < 0) back(form, 'err', 'Nhập số ngày nhắc từ 0 trở lên');
  const { error, data } = await supabase.schema('master').from('machine_settings')
    .update({ value: { MINOR: Math.round(minor!), MAJOR: Math.round(major!) } }).eq('key', 'remind_days').select('key');
  if (error) back(form, 'err', friendly(error.message));
  if (!data?.length) back(form, 'err', 'Bạn chưa có quyền sửa cài đặt');
  done(form, 'Đã lưu ngày nhắc bảo dưỡng.');
}

// Lịch làm việc (Giám đốc): dùng chung với Kế hoạch sản xuất
export async function addCheckItem(form: FormData) {
  const supabase = await createClient();
  if (!txt(form, 'label')) back(form, 'err', 'Nhập nội dung mục kiểm tra');
  const { error } = await supabase.schema('mfg').from('maint_check_items').insert({
    label: txt(form, 'label'), machine_id: opt(form, 'machine_id'), sort: num(form, 'sort') ?? 10,
  });
  if (error) back(form, 'err', friendly(error.message));
  done(form, 'Đã thêm mục kiểm tra đầu ca');
}
