'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { ROLE, hasRole } from '@/lib/kh/load';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

const go = (q: string, kind: 'ok' | 'err', msg: string): never => redirect(`/lenh-ngay?${q}&${kind}=${encodeURIComponent(msg)}`);

export async function releaseDay(form: FormData) {
  const planId = String(form.get('plan_id'));
  const date = String(form.get('d'));
  const q = `plan=${planId}&d=${date}`;
  const me = await requireMe();
  if (!hasRole(me.roles, ROLE.release)) go(q, 'err', 'Chỉ Quản lý SX được phát lệnh ngày');
  if (form.get('confirm') !== '1') go(q, 'err', 'Đánh dấu ô xác nhận trước khi phát');
  const db = await createClient();
  // Kiểm tra trước khi phát và phiếu lĩnh do database tự tính từ lịch máy + định mức BOM
  const { error } = await db.schema('app').rpc('kh_release_day', {
    p_plan: planId, p_date: date, p_note: String(form.get('note') ?? ''), p_checks: [], p_slip: [],
  });
  if (error) go(q, 'err', error.message);
  revalidatePath('/lenh-ngay');
  go(q, 'ok', 'Đã phát lệnh ngày và gắn lệnh SX cho từng mã. Phiếu lĩnh đã gửi Kế toán kho duyệt, Giám đốc đã được báo.');
}

export async function approveSlip(form: FormData) {
  const q = `plan=${String(form.get('plan_id'))}&d=${String(form.get('d'))}`;
  const db = await createClient();
  const { error } = await db.schema('app').rpc('kh_approve_slip', { p_slip: String(form.get('slip_id')) });
  if (error) go(q, 'err', error.message);
  revalidatePath('/lenh-ngay');
  go(q, 'ok', 'Đã duyệt phiếu lĩnh. Đã tạo phiếu lĩnh Kho theo lệnh SX, thủ kho quét QR cấp ở Cấp NVL cho SX.');
}
