'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { after } from 'next/server';
import { parseNum } from '@/lib/format';
import { flushEmailOutbox, submitForApproval } from '@/lib/notify';
import { createClient } from '@/lib/supabase/server';

const back = (id: string, kind: 'ok' | 'err', msg: string) => redirect(`/ke-hoach/${id}?${kind}=${encodeURIComponent(msg)}`);

export async function createPlan(form: FormData) {
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc('create_plan', {
    p_year: Number(form.get('year')), p_month: Number(form.get('month')), p_need_date: String(form.get('need_date') ?? '') || null,
  });
  if (error) redirect('/ke-hoach/moi?err=' + encodeURIComponent(error.message));
  redirect(`/ke-hoach/${data}?ok=` + encodeURIComponent('Đã tạo kế hoạch tháng. Thêm các dòng sản phẩm bên dưới.'));
}

export async function saveLine(form: FormData) {
  const planId = String(form.get('plan_id'));
  const productId = String(form.get('product_id'));
  const qty = parseNum(form.get('qty_m'));
  const mpp = parseNum(form.get('m_per_pack'));
  if (qty === null || Number.isNaN(qty) || qty < 0) back(planId, 'err', 'Sản lượng (m) phải là số ≥ 0');
  if (mpp === null || Number.isNaN(mpp) || mpp <= 0) back(planId, 'err', 'Chọn quy cách m/kiện');

  const supabase = await createClient();
  const { data: plan } = await supabase.schema('plan').from('production_plans').select('status').eq('id', planId).single();
  if (plan?.status !== 'DRAFT') back(planId, 'err', 'Kế hoạch không còn ở trạng thái Nháp: không sửa dòng được');
  const { data: prod } = await supabase.schema('master').from('products').select('code, current_spec_id').eq('id', productId).single();
  if (!prod?.current_spec_id) back(planId, 'err', 'Sản phẩm chưa có spec');
  const row = {
    plan_id: planId, product_id: productId, spec_id: prod!.current_spec_id, qty_m: qty, run_lots: 1,
    m_per_pack: mpp, pack_type: String(form.get('pack_type')), brand: String(form.get('brand')),
    single_color: String(form.get('single_color') ?? '').trim() || null, wo_note: String(form.get('wo_note') ?? '').trim() || null,
  };
  const lineId = String(form.get('line_id') ?? '');
  const { data: saved, error } = lineId
    ? await supabase.schema('plan').from('plan_lines').update(row).eq('id', lineId).eq('plan_id', planId).select('id')
    : await supabase.schema('plan').from('plan_lines').insert(row).select('id');
  if (error) back(planId, 'err', error.code === '23505' ? `${prod!.code} đã có trong kế hoạch: sửa dòng có sẵn` : error.message.includes('row-level') ? 'Bạn không có quyền sửa kế hoạch' : error.message);
  if (!saved?.length) back(planId, 'err', 'Không lưu được: bạn không có quyền sửa hoặc kế hoạch đã khóa');
  const { data: fresh } = await supabase.schema('plan').from('production_plans').select('mrp_stale').eq('id', planId).single();
  revalidatePath(`/ke-hoach/${planId}`);
  back(planId, 'ok', `Đã ${lineId ? 'cập nhật' : 'thêm'} dòng ${prod!.code}.${fresh?.mrp_stale ? ' Kết quả MRP cần chạy lại.' : ''}`);
}

export async function deleteLine(form: FormData) {
  const planId = String(form.get('plan_id'));
  const supabase = await createClient();
  const { error } = await supabase.schema('plan').from('plan_lines').delete().eq('id', String(form.get('line_id')));
  if (error) back(planId, 'err', error.message.includes('row-level') ? 'Bạn không có quyền xóa dòng kế hoạch' : error.message);
  revalidatePath(`/ke-hoach/${planId}`);
  back(planId, 'ok', 'Đã xóa dòng');
}

// Người đang duyệt (Giám đốc duyệt, Chủ tịch HĐQT chốt): sửa/thêm/bỏ dòng; database kiểm bước, người duyệt, lý do và tự chạy lại MRP
export async function chairSaveLine(form: FormData) {
  const planId = String(form.get('plan_id'));
  const lineId = String(form.get('line_id') ?? '') || null;
  const qty = parseNum(form.get('qty_m'));
  const mpp = parseNum(form.get('m_per_pack'));
  if (qty === null || Number.isNaN(qty) || qty <= 0) back(planId, 'err', 'Sản lượng (m) phải lớn hơn 0 (bỏ mã thì bấm Bỏ mã)');
  if (mpp === null || Number.isNaN(mpp) || mpp <= 0) back(planId, 'err', 'Chọn quy cách m/kiện');
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('plan_chair_save_line', {
    p_plan: planId, p_line: lineId, p_product: lineId ? null : String(form.get('product_id')), p_qty: qty, p_lots: 1,
    p_pack_type: String(form.get('pack_type')), p_m_per_pack: mpp, p_brand: String(form.get('brand')), p_reason: String(form.get('reason') ?? ''),
  });
  if (error) back(planId, 'err', error.message);
  revalidatePath(`/ke-hoach/${planId}`);
  back(planId, 'ok', `Đã ${lineId ? 'sửa' : 'thêm'} dòng, MRP đã tính lại, ghi vào lịch sử duyệt. Xong thì bấm duyệt / chốt kế hoạch.`);
}

export async function chairRemoveLine(form: FormData) {
  const planId = String(form.get('plan_id'));
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('plan_chair_remove_line', { p_line: String(form.get('line_id')), p_reason: String(form.get('reason') ?? '') });
  if (error) back(planId, 'err', error.message);
  revalidatePath(`/ke-hoach/${planId}`);
  back(planId, 'ok', 'Đã bỏ mã khỏi kế hoạch, MRP đã tính lại.');
}

export async function runMrp(form: FormData) {
  const planId = String(form.get('plan_id'));
  const supabase = await createClient();
  // app.plan_run_mrp: giữ số đã chỉnh của vật tư không đổi nhu cầu; kế hoạch chờ duyệt thì chỉ người đang duyệt chạy
  const { error } = await supabase.schema('app').rpc('plan_run_mrp', { p_plan: planId });
  if (error) back(planId, 'err', error.message);
  revalidatePath(`/ke-hoach/${planId}`);
  back(planId, 'ok', 'Đã chạy MRP');
}

export async function submitPlan(form: FormData) {
  const planId = String(form.get('plan_id'));
  const { error } = await submitForApproval('PLAN', planId, String(form.get('plan_no')), String(form.get('summary')));
  if (error) back(planId, 'err', error.message);
  revalidatePath('/', 'layout');
  back(planId, 'ok', 'Đã gửi duyệt. Giám đốc đã nhận thông báo, duyệt xong chuyển Chủ tịch HĐQT chốt.');
}

// Điều chỉnh kết quả MRP: quyền, khóa chứng từ, giá trị gốc và lịch sử do database kiểm tra/ghi (app.adjust_mrp_line)
export async function adjustMrp(form: FormData) {
  const planId = String(form.get('plan_id'));
  const qty = parseNum(form.get('qty'));
  const reason = String(form.get('reason') ?? '').trim();
  if (qty === null || Number.isNaN(qty) || qty < 0) back(planId, 'err', 'Số lượng đề nghị mua phải là số ≥ 0');
  if (!reason) back(planId, 'err', 'Nhập lý do điều chỉnh');
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('adjust_mrp_line', {
    p_line: String(form.get('line_id')), p_qty: qty, p_need_date: String(form.get('need_date') ?? '') || null,
    p_note: String(form.get('note') ?? ''), p_reason: reason,
  });
  if (error) back(planId, 'err', error.message);
  revalidatePath(`/ke-hoach/${planId}`);
  back(planId, 'ok', 'Đã điều chỉnh kết quả MRP. Đề xuất mua sinh ra sẽ dùng số liệu mới.');
}

// ---------------- Đề xuất hiệu chỉnh kế hoạch tháng (TP SX lập → Giám đốc → Chủ tịch HĐQT duyệt) ----------------
const adjBack = (id: string, kind: 'ok' | 'err', msg: string) => redirect(`/ke-hoach/dieu-chinh/${id}?${kind}=${encodeURIComponent(msg)}`);

export async function createAdj(form: FormData) {
  const planId = String(form.get('plan_id'));
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc('adj_create', { p_plan: planId, p_reason: String(form.get('reason') ?? '') });
  if (error) {
    if (form.get('from') === 'moi') redirect('/ke-hoach/moi?err=' + encodeURIComponent(error.message));
    if (form.get('from') === 'list') redirect('/ke-hoach/dieu-chinh?err=' + encodeURIComponent(error.message));
    back(planId, 'err', error.message);
  }
  redirect(`/ke-hoach/dieu-chinh/${data}?ok=` + encodeURIComponent('Đã lập đề xuất hiệu chỉnh (nháp). Thêm các dòng, xem bảng MRP hiệu chỉnh rồi gửi Giám đốc duyệt.'));
}

// Đọc các dòng của form (tối đa 12): loại, dòng kế hoạch / mã mới, số mét, hạn giao, ưu tiên, ghi chú
function adjLines(form: FormData, id: string) {
  const lines: Record<string, unknown>[] = [];
  for (let i = 0; i < 12; i++) {
    const kind = String(form.get(`kind_${i}`) ?? '');
    if (!kind) continue;
    const raw = String(form.get(`qty_${i}`) ?? '').trim();
    const qty = raw ? parseNum(raw) : null;
    if (raw && (qty === null || Number.isNaN(qty) || qty < 0)) adjBack(id, 'err', `Dòng ${i + 1}: số mét "${raw}" không hợp lệ`);
    lines.push({
      kind, plan_line_id: String(form.get(`line_${i}`) ?? ''), product_code: String(form.get(`code_${i}`) ?? '').trim().toUpperCase(),
      qty_m: qty, due_date: String(form.get(`due_${i}`) ?? '') || null, priority: String(form.get(`prio_${i}`) ?? '') || null,
      note: String(form.get(`note_${i}`) ?? '').trim(),
    });
  }
  return lines;
}

export async function saveAdj(form: FormData) {
  const id = String(form.get('id'));
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('adj_save', { p_adj: id, p_reason: String(form.get('reason') ?? ''), p_lines: adjLines(form, id) });
  if (error) adjBack(id, 'err', error.message);
  revalidatePath(`/ke-hoach/dieu-chinh/${id}`);
  adjBack(id, 'ok', 'Đã lưu đề xuất hiệu chỉnh. Bảng MRP hiệu chỉnh bên dưới đã tính lại.');
}

export async function submitAdj(form: FormData) {
  const id = String(form.get('id'));
  const supabase = await createClient();
  const save = await supabase.schema('app').rpc('adj_save', { p_adj: id, p_reason: String(form.get('reason') ?? ''), p_lines: adjLines(form, id) });
  if (save.error) adjBack(id, 'err', save.error.message);
  const { error } = await supabase.schema('app').rpc('adj_submit', { p_adj: id });
  if (error) adjBack(id, 'err', error.message);
  after(async () => { await flushEmailOutbox(); });
  revalidatePath('/', 'layout');
  adjBack(id, 'ok', 'Đã gửi Giám đốc duyệt, sau đó Chủ tịch HĐQT duyệt. Duyệt xong MES áp vào kế hoạch tháng và chạy MRP hiệu chỉnh.');
}

export async function cancelAdj(form: FormData) {
  const id = String(form.get('id'));
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('adj_cancel', { p_adj: id });
  if (error) adjBack(id, 'err', error.message);
  revalidatePath(`/ke-hoach/dieu-chinh/${id}`);
  adjBack(id, 'ok', 'Đã hủy đề xuất nháp');
}
