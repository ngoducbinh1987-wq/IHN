'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';

const back = (flow: string, kind: 'ok' | 'err', msg: string) =>
  redirect(`/quan-tri/quy-trinh?f=${encodeURIComponent(flow)}&${kind}=${encodeURIComponent(msg)}`);

// Chỉ giữ người được giao còn giữ vai trò của bước (đổi vai trò thì danh sách cũ tự bỏ)
async function holders(role: string | null, ids: string[]) {
  if (!role || !ids.length) return ids;
  const supabase = await createClient();
  const { data } = await supabase.schema('core').from('user_roles').select('user_id').eq('role_code', role).in('user_id', ids);
  return (data ?? []).map((r) => r.user_id as string);
}

export async function saveSubmit(form: FormData) {
  const flow = String(form.get('flow'));
  const role = String(form.get('role') ?? '') || null;
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('save_flow_submit', {
    p_doc_type: flow, p_label: String(form.get('label') ?? ''), p_role: role,
    p_users: await holders(role, form.getAll('users').map(String)),
  });
  if (error) back(flow, 'err', error.message);
  revalidatePath('/quan-tri/quy-trinh');
  back(flow, 'ok', 'Đã lưu bước lập. Áp dụng cho hồ sơ gửi từ bây giờ.');
}

export async function saveStep(form: FormData) {
  const flow = String(form.get('flow'));
  const seq = String(form.get('seq') ?? '');
  const role = String(form.get('role') ?? '');
  const sla = Number(form.get('sla_hours'));
  const warn = Number(form.get('warn_hours') || 0);
  if (!Number.isInteger(sla) || sla <= 0) back(flow, 'err', 'Thời hạn (giờ) phải là số nguyên > 0');
  if (!Number.isInteger(warn) || warn < 0 || warn >= sla) back(flow, 'err', 'Nhắc trước hạn phải từ 0 đến nhỏ hơn thời hạn');
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('save_flow_step', {
    p_doc_type: flow, p_seq: seq ? Number(seq) : null, p_label: String(form.get('label') ?? ''), p_role: role,
    p_users: await holders(role, form.getAll('users').map(String)), p_sla_hours: sla, p_warn_hours: warn,
    p_enabled: seq ? form.get('enabled') === 'on' : true,
  });
  if (error) back(flow, 'err', error.message);
  revalidatePath('/quan-tri/quy-trinh');
  back(flow, 'ok', seq ? 'Đã lưu bước. Hồ sơ đang chạy giữ cấu hình cũ; hồ sơ gửi mới dùng cấu hình này.' : 'Đã thêm bước mới.');
}
