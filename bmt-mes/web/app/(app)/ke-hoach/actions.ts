'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { parseNum } from '@/lib/format';
import { createClient } from '@/lib/supabase/server';

const back = (id: string, kind: 'ok' | 'err', msg: string) => redirect(`/ke-hoach/${id}?${kind}=${encodeURIComponent(msg)}`);

export async function createPlan(form: FormData) {
  const supabase = await createClient();
  const { data: no, error: e1 } = await supabase.schema('core').rpc('next_no', { p_prefix: 'KH', p_width: 2 });
  if (e1) redirect('/ke-hoach?err=' + encodeURIComponent(e1.message));
  const { data, error } = await supabase.schema('plan').from('production_plans').insert({
    plan_no: no as string,
    period_label: String(form.get('period_label')).trim(),
    material_need_date: String(form.get('need_date')),
    mode: form.get('mode') === 'PRELIMINARY' ? 'PRELIMINARY' : 'OFFICIAL',
  }).select('id').single();
  if (error) redirect('/ke-hoach?err=' + encodeURIComponent(error.message));
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
  if (mpp === null || Number.isNaN(mpp) || mpp <= 0) back(planId, 'err', 'm/kiện phải > 0');

  const supabase = await createClient();
  const { data: prod } = await supabase.schema('master').from('products').select('code, current_spec_id').eq('id', productId).single();
  if (!prod?.current_spec_id) back(planId, 'err', 'Sản phẩm chưa có spec');
  const row = {
    plan_id: planId, product_id: productId, spec_id: prod!.current_spec_id, qty_m: qty, run_lots: Math.round(lots!),
    m_per_pack: mpp, pack_type: String(form.get('pack_type')), brand: String(form.get('brand')),
    single_color: String(form.get('single_color') ?? '').trim() || null, wo_note: String(form.get('wo_note') ?? '').trim() || null,
  };
  const lineId = String(form.get('line_id') ?? '');
  const { error } = lineId
    ? await supabase.schema('plan').from('plan_lines').update(row).eq('id', lineId)
    : await supabase.schema('plan').from('plan_lines').insert(row);
  if (error) back(planId, 'err', error.message);
  revalidatePath(`/ke-hoach/${planId}`);
  back(planId, 'ok', `Đã lưu dòng ${prod!.code}. Chạy lại MRP để cập nhật nhu cầu vật tư.`);
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
  const supabase = await createClient();
  const { error } = await supabase.schema('wf').rpc('submit', {
    p_doc_type: 'PLAN', p_doc_id: planId, p_doc_no: String(form.get('plan_no')), p_summary: String(form.get('summary')),
  });
  if (error) back(planId, 'err', error.message);
  revalidatePath(`/ke-hoach/${planId}`);
  back(planId, 'ok', 'Đã gửi TP Sản xuất duyệt');
}

export async function createPr(form: FormData) {
  const planId = String(form.get('plan_id'));
  const supabase = await createClient();
  const { data, error } = await supabase.schema('plan').rpc('create_pr_from_mrp', { p_run: String(form.get('run_id')) });
  if (error) back(planId, 'err', error.message);
  const { data: pr } = await supabase.schema('purchase').from('purchase_requests').select('pr_no').eq('id', data as string).single();
  back(planId, 'ok', `Đã sinh ${pr?.pr_no ?? 'PR'} từ kết quả MRP`);
}
