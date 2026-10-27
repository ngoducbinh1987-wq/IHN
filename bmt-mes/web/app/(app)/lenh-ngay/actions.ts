'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { ROLE, hasRole } from '@/lib/kh/load';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

const go = (q: string, kind: 'ok' | 'err', msg: string): never => redirect(`/lenh-ngay?${q}&${kind}=${encodeURIComponent(msg)}`);

// TP SX / Kế hoạch SX đề xuất lệnh ngày → Giám đốc duyệt mới phát; Giám đốc tự phát thì phát ngay
export async function releaseDay(form: FormData) {
  const planId = String(form.get('plan_id'));
  const date = String(form.get('d'));
  const q = `plan=${planId}&d=${date}`;
  const me = await requireMe();
  if (!hasRole(me.roles, [...ROLE.release, 'BGD'])) go(q, 'err', 'Chỉ TP SX (Kế hoạch SX) đề xuất lệnh ngày, Giám đốc duyệt phát');
  if (form.get('confirm') !== '1') go(q, 'err', 'Đánh dấu ô xác nhận trước khi gửi');
  const db = await createClient();
  // Kiểm tra trước khi phát và phiếu lĩnh do database tự tính từ lịch máy + định mức BOM
  const { data: id, error } = await db.schema('app').rpc('kh_release_day', {
    p_plan: planId, p_date: date, p_note: String(form.get('note') ?? ''), p_checks: [], p_slip: [],
  });
  if (error) go(q, 'err', error.message);
  const { data: rel } = await db.schema('app').from('v_kh_releases').select('status, revision').eq('id', id as string).limit(1).maybeSingle();
  revalidatePath('/lenh-ngay');
  if (rel?.status === 'PROPOSED') go(q, 'ok', `Đã gửi Giám đốc duyệt lệnh ngày bản ${rel.revision}. Giám đốc duyệt xong MES phát lệnh SX và gửi phiếu lĩnh cho Kế toán SX.`);
  go(q, 'ok', 'Đã phát lệnh ngày và gắn lệnh SX cho từng mã. Phiếu lĩnh đã gửi Kế toán SX duyệt.');
}

// Giám đốc duyệt / trả lại lệnh ngày TP SX đề xuất
export async function reviewRelease(form: FormData) {
  const q = `plan=${String(form.get('plan_id'))}&d=${String(form.get('d'))}`;
  const ok = form.get('approve') === '1';
  const db = await createClient();
  const { error } = await db.schema('app').rpc('kh_release_review', {
    p_release: String(form.get('release_id')), p_approve: ok, p_note: String(form.get('note') ?? '').trim() || null,
  });
  if (error) go(q, 'err', error.message);
  revalidatePath('/lenh-ngay');
  go(q, 'ok', ok ? 'Đã duyệt phát lệnh ngày: lệnh SX đã phát, phiếu lĩnh chờ Kế toán SX duyệt.' : 'Đã trả lại lệnh ngày, TP SX nhận thông báo.');
}

export async function approveSlip(form: FormData) {
  const q = `plan=${String(form.get('plan_id'))}&d=${String(form.get('d'))}`;
  const db = await createClient();
  const { error } = await db.schema('app').rpc('kh_approve_slip', { p_slip: String(form.get('slip_id')) });
  if (error) go(q, 'err', error.message);
  revalidatePath('/lenh-ngay');
  go(q, 'ok', 'Đã duyệt phiếu lĩnh. Đã tạo phiếu lĩnh Kho theo lệnh SX, thủ kho quét QR cấp ở Cấp NVL cho SX.');
}
