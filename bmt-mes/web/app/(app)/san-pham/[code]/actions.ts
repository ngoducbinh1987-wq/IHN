'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { parseNum } from '@/lib/format';
import { readParams } from '@/lib/spec';
import { submitForApproval } from '@/lib/notify';
import { createClient } from '@/lib/supabase/server';

const back = (code: string, kind: 'ok' | 'err', msg: string, v?: string) =>
  redirect(`/san-pham/${encodeURIComponent(code)}?${v ? `v=${v}&` : ''}${kind}=${encodeURIComponent(msg)}`);

export async function updateSpec(form: FormData) {
  const code = String(form.get('code')); const spec = String(form.get('spec_id'));
  const p = readParams(form);
  if (typeof p === 'string') back(code, 'err', p, spec);
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('update_spec_draft', { p_spec: spec, p });
  if (error) back(code, 'err', error.message, spec);
  revalidatePath(`/san-pham/${code}`);
  back(code, 'ok', 'Đã lưu thông số và tính lại định mức', spec);
}

export async function saveBomLine(form: FormData) {
  const code = String(form.get('code')); const spec = String(form.get('spec_id'));
  const qty = parseNum(form.get('qty')); const loss = parseNum(form.get('loss')); const startup = parseNum(form.get('startup'));
  if (qty === null || Number.isNaN(qty) || qty <= 0) back(code, 'err', 'Định mức phải lớn hơn 0', spec);
  if (loss !== null && (Number.isNaN(loss) || loss < 0 || loss >= 100)) back(code, 'err', 'Hao hụt (%) phải từ 0 đến dưới 100', spec);
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('save_bom_line', {
    p_spec: spec, p_material_code: String(form.get('material_code') ?? '').split(' · ')[0].trim(), p_basis: String(form.get('basis') ?? 'KM'),
    p_qty: qty, p_loss: loss === null ? null : loss / 100, p_startup: startup ?? 0, p_operation: String(form.get('operation') ?? ''),
  });
  if (error) back(code, 'err', error.message, spec);
  revalidatePath(`/san-pham/${code}`);
  back(code, 'ok', 'Đã lưu dòng BOM', spec);
}

export async function deleteBomLine(form: FormData) {
  const code = String(form.get('code')); const spec = String(form.get('spec_id'));
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('delete_bom_line', { p_line: String(form.get('line_id')) });
  if (error) back(code, 'err', error.message, spec);
  revalidatePath(`/san-pham/${code}`);
  back(code, 'ok', 'Đã xóa dòng BOM', spec);
}

export async function submitSpec(form: FormData) {
  const code = String(form.get('code')); const spec = String(form.get('spec_id')); const version = String(form.get('version'));
  const minor = form.get('change_level') === 'MINOR';
  const { error } = await submitForApproval(minor ? 'SPEC_MINOR' : 'SPEC_NEW', spec, `SPEC ${code} v${version}`,
    minor ? 'Thay đổi nhỏ spec + BOM' : 'Phát hành spec + BOM');
  if (error) back(code, 'err', error.message, spec);
  revalidatePath('/', 'layout');
  back(code, 'ok', 'Đã gửi duyệt. Người duyệt bước đầu đã nhận thông báo.', spec);
}

export async function recordPilot(form: FormData) {
  const code = String(form.get('code')); const spec = String(form.get('spec_id'));
  const rdc = parseNum(form.get('rdc')); const kgkm = parseNum(form.get('kgkm')); const od = parseNum(form.get('od'));
  if (rdc === null || [rdc, kgkm, od].some((v) => Number.isNaN(v) || (v !== null && v <= 0))) back(code, 'err', 'Kết quả đo phải là số dương', spec);
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('record_pilot', { p_spec: spec, p_rdc: rdc, p_kgkm: kgkm, p_od: od });
  if (error) back(code, 'err', error.message, spec);
  revalidatePath(`/san-pham/${code}`);
  back(code, 'ok', 'Đã lưu kết quả pilot', spec);
}

export async function saveDeviation(form: FormData) {
  const code = String(form.get('code')); const spec = String(form.get('spec_id'));
  const note = String(form.get('note') ?? '').trim();
  const supabase = await createClient();
  const { error } = await supabase.schema('master').from('product_specs').update({ rdc_deviation_note: note || null }).eq('id', spec);
  if (error) back(code, 'err', error.message, spec);
  revalidatePath(`/san-pham/${code}`);
  back(code, 'ok', note ? 'Đã lưu phiếu chấp nhận sai lệch' : 'Đã xóa phiếu chấp nhận sai lệch', spec);
}

export async function newVersion(form: FormData) {
  const code = String(form.get('code'));
  const supabase = await createClient();
  const { data, error } = await supabase.schema('master').rpc('new_spec_version', {
    p_from: String(form.get('spec_id')), p_change_level: String(form.get('level')),
  });
  if (error) back(code, 'err', error.message);
  // Phiên bản mới là bản nháp; sản phẩm vẫn dùng bản đã phát hành cho tới khi bản mới được duyệt
  back(code, 'ok', 'Đã tạo phiên bản nháp mới. Sửa thông số / BOM rồi gửi duyệt.', data as string);
}
