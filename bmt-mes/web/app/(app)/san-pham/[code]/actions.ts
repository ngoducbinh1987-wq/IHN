'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { parseNum } from '@/lib/format';
import { createClient } from '@/lib/supabase/server';

const back = (code: string, kind: 'ok' | 'err', msg: string) =>
  redirect(`/san-pham/${encodeURIComponent(code)}?${kind}=${encodeURIComponent(msg)}`);

export async function submitSpec(form: FormData) {
  const code = String(form.get('code'));
  const supabase = await createClient();
  const { error } = await supabase.schema('wf').rpc('submit', {
    p_doc_type: 'SPEC_NEW',
    p_doc_id: String(form.get('spec_id')),
    p_doc_no: `SPEC ${code} v${form.get('version')}`,
    p_summary: `Phát hành spec + BOM ${code} v${form.get('version')}`,
  });
  if (error) back(code, 'err', error.message);
  revalidatePath(`/san-pham/${code}`);
  back(code, 'ok', 'Đã gửi duyệt. Bước tiếp theo: QC kiểm tra kết quả pilot.');
}

export async function recordPilot(form: FormData) {
  const code = String(form.get('code'));
  const rdc = parseNum(form.get('rdc'));
  const kgkm = parseNum(form.get('kgkm'));
  const od = parseNum(form.get('od'));
  if (rdc === null || [rdc, kgkm, od].some((v) => Number.isNaN(v) || (v !== null && v <= 0))) back(code, 'err', 'Kết quả đo phải là số dương');
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('record_pilot', { p_spec: String(form.get('spec_id')), p_rdc: rdc, p_kgkm: kgkm, p_od: od });
  if (error) back(code, 'err', error.message);
  revalidatePath(`/san-pham/${code}`);
  back(code, 'ok', 'Đã lưu kết quả pilot');
}

export async function saveDeviation(form: FormData) {
  const code = String(form.get('code'));
  const note = String(form.get('note') ?? '').trim();
  const supabase = await createClient();
  const { error } = await supabase.schema('master').from('product_specs')
    .update({ rdc_deviation_note: note || null }).eq('id', String(form.get('spec_id')));
  if (error) back(code, 'err', error.message);
  revalidatePath(`/san-pham/${code}`);
  back(code, 'ok', note ? 'Đã lưu phiếu chấp nhận sai lệch' : 'Đã xóa phiếu chấp nhận sai lệch');
}

export async function newVersion(form: FormData) {
  const code = String(form.get('code'));
  const supabase = await createClient();
  const { data, error } = await supabase.schema('master').rpc('new_spec_version', {
    p_from: String(form.get('spec_id')), p_change_level: String(form.get('level')),
  });
  if (error) back(code, 'err', error.message);
  // Phiên bản mới là bản nháp; sản phẩm vẫn trỏ về bản đã phát hành cho tới khi bản mới được duyệt
  back(code, 'ok', `Đã tạo phiên bản nháp mới (${data}). Sửa và gửi duyệt để thay bản hiện hành.`);
}
