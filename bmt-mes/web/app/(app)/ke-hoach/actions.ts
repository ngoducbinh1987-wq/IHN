'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { parseNum } from '@/lib/format';
import { submitForApproval } from '@/lib/notify';
import { createClient } from '@/lib/supabase/server';

const back = (id: string, kind: 'ok' | 'err', msg: string) => redirect(`/ke-hoach/${id}?${kind}=${encodeURIComponent(msg)}`);

export async function createPlan(form: FormData) {
  const supabase = await createClient();
  const { data: no, error: e1 } = await supabase.schema('core').rpc('next_no', { p_prefix: 'KH', p_width: 2 });
  if (e1) redirect('/ke-hoach/moi?err=' + encodeURIComponent(e1.message));
  const { data, error } = await supabase.schema('plan').from('production_plans').insert({
    plan_no: no as string,
    period_label: String(form.get('period_label')).trim(),
    material_need_date: String(form.get('need_date')),
    mode: form.get('mode') === 'PRELIMINARY' ? 'PRELIMINARY' : 'OFFICIAL',
  }).select('id').single();
  if (error) redirect('/ke-hoach/moi?err=' + encodeURIComponent(error.message));
  redirect(`/ke-hoach/${data.id}?ok=` + encodeURIComponent(`Đã tạo kế hoạch ${no}. Thêm các dòng sản phẩm bên dưới.`));
}

export async function saveLine(form: FormData) {
  const planId = String(form.get('plan_id'));
  const productId = String(form.get('product_id'));
  const qty = parseNum(form.get('qty_m'));
  const lots = parseNum(form.get('run_lots'));
  const mpp = parseNum(form.get('m_per_pack'));
  if (qty === null || Number.isNaN(qty) || qty < 0) back(planId, 'err', 'Sản lượng (m) phải là số ≥ 0');
  if (lots === null || Number.isNaN(lots) || lots < 1) back(planId, 'err', 'Số lô chạy phải ≥ 1');
  if (mpp === null || Number.isNaN(mpp) || mpp <= 0) back(planId, 'err', 'Chọn quy cách m/kiện');

  const supabase = await createClient();
  const { data: plan } = await supabase.schema('plan').from('production_plans').select('status').eq('id', planId).single();
  if (plan?.status !== 'DRAFT') back(planId, 'err', 'Kế hoạch không còn ở trạng thái Nháp: không sửa dòng được');
  const { data: prod } = await supabase.schema('master').from('products').select('code, current_spec_id').eq('id', productId).single();
  if (!prod?.current_spec_id) back(planId, 'err', 'Sản phẩm chưa có spec');
  const row = {
    plan_id: planId, product_id: productId, spec_id: prod!.current_spec_id, qty_m: qty, run_lots: Math.round(lots!),
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

export async function runMrp(form: FormData) {
  const planId = String(form.get('plan_id'));
  const supabase = await createClient();
  const { error } = await supabase.schema('plan').rpc('run_mrp', { p_plan: planId });
  if (error) back(planId, 'err', error.message);
  revalidatePath(`/ke-hoach/${planId}`);
  back(planId, 'ok', 'Đã chạy MRP');
}

export async function submitPlan(form: FormData) {
  const planId = String(form.get('plan_id'));
  const { error } = await submitForApproval('PLAN', planId, String(form.get('plan_no')), String(form.get('summary')));
  if (error) back(planId, 'err', error.message);
  revalidatePath('/', 'layout');
  back(planId, 'ok', 'Đã gửi duyệt. TP Sản xuất đã nhận thông báo.');
}

export async function createPr(form: FormData) {
  const planId = String(form.get('plan_id'));
  const supabase = await createClient();
  const { data, error } = await supabase.schema('plan').rpc('create_pr_from_mrp', { p_run: String(form.get('run_id')) });
  if (error) back(planId, 'err', error.message);
  const { data: pr } = await supabase.schema('purchase').from('purchase_requests').select('pr_no').eq('id', data as string).single();
  redirect(`/de-xuat/${data}?ok=` + encodeURIComponent(`Đã sinh ${pr?.pr_no ?? 'PR'} từ kết quả MRP. Kiểm tra rồi gửi duyệt.`));
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
