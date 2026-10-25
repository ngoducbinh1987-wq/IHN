'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { after } from 'next/server';
import { parseNum } from '@/lib/format';
import { errText, withMsg } from '@/lib/kho';
import { flushEmailOutbox } from '@/lib/notify';
import { createClient } from '@/lib/supabase/server';
import { str } from '../util';

export async function openCount(form: FormData) {
  const supabase = await createClient();
  const locs = form.getAll('locations').map(String).filter(Boolean);
  const { data, error } = await supabase.schema('inv').rpc('count_open', {
    p_warehouse: str(form, 'warehouse_id'), p_type: str(form, 'count_type'), p_locations: locs.length ? locs : null, p_note: str(form, 'note') || null,
  });
  if (error) redirect(withMsg('/kho/kiem-ke', 'err', errText(error.message)));
  revalidatePath('/kho/kiem-ke');
  redirect(withMsg(`/kho/kiem-ke/${data}`, 'ok', 'Đã mở phiếu kiểm kê. Vị trí trong phiếu bị khóa xuất nhập cho đến khi đóng.'));
}

export async function scanCount(form: FormData) {
  const id = str(form, 'count_id');
  const qty = parseNum(form.get('counted'));
  if (qty === null || Number.isNaN(qty) || qty < 0) redirect(withMsg(`/kho/kiem-ke/${id}`, 'err', 'Nhập số đếm (≥ 0)'));
  const hu = str(form, 'hu_id');
  const line = str(form, 'line_id');
  if (!hu && !line) redirect(withMsg(`/kho/kiem-ke/${id}`, 'err', 'Quét mã QR hàng đang đếm'));
  const supabase = await createClient();
  const { error } = await supabase.schema('inv').rpc('count_scan', {
    p_count: id, p_hu: hu || null, p_line: line ? Number(line) : null, p_counted: qty, p_location: str(form, 'location_id') || null, p_note: str(form, 'note') || null,
  });
  if (error) redirect(withMsg(`/kho/kiem-ke/${id}`, 'err', errText(error.message)));
  revalidatePath(`/kho/kiem-ke/${id}`);
  redirect(withMsg(`/kho/kiem-ke/${id}`, 'ok', 'Đã ghi số đếm. Quét đơn vị tiếp theo.'));
}

export async function closeCount(form: FormData) {
  const id = str(form, 'count_id');
  const supabase = await createClient();
  const { data, error } = await supabase.schema('inv').rpc('count_close', { p_count: id, p_missing_as_zero: form.get('missing_zero') === 'on' });
  if (error) redirect(withMsg(`/kho/kiem-ke/${id}`, 'err', errText(error.message)));
  after(async () => { await flushEmailOutbox(); });
  revalidatePath('/kho/kiem-ke');
  redirect(withMsg(`/kho/kiem-ke/${id}`, 'ok', data ? 'Có chênh lệch: biên bản đã gửi Kế toán trưởng duyệt. Duyệt xong hệ thống tự điều chỉnh và mở khóa.' : 'Không chênh lệch: đã đóng phiếu, mở khóa vị trí.'));
}

export async function cancelCount(form: FormData) {
  const id = str(form, 'count_id');
  const supabase = await createClient();
  const { error } = await supabase.schema('inv').rpc('count_cancel', { p_count: id, p_reason: str(form, 'reason') });
  if (error) redirect(withMsg(`/kho/kiem-ke/${id}`, 'err', errText(error.message)));
  revalidatePath('/kho/kiem-ke');
  redirect(withMsg('/kho/kiem-ke', 'ok', 'Đã hủy phiếu kiểm kê'));
}
