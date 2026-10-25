'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { parseNum } from '@/lib/format';
import { createClient } from '@/lib/supabase/server';

const back = (tab: string, kind: 'ok' | 'err', msg: string) => redirect(`/kho?tab=${tab}&${kind}=${encodeURIComponent(msg)}`);

export async function reviewDocs(form: FormData) {
  const ids = form.getAll('ids').map(String);
  if (ids.length === 0) back('cho-kiem', 'err', 'Chọn ít nhất một phiếu');
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc('review_stock_docs', { p_ids: ids });
  if (error) back('cho-kiem', 'err', error.message);
  revalidatePath('/kho');
  back('cho-kiem', 'ok', `Đã đánh dấu kiểm ${data ?? 0} phiếu`);
}

export async function saveTolerance(form: FormData) {
  const v = parseNum(form.get('value'));
  if (v === null || Number.isNaN(v) || v < 0 || v > 100) back('dong', 'err', 'Lệch cho phép phải từ 0 đến 100 %');
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('set_control_setting', { p_key: 'copper_tolerance_pct', p_value: v });
  if (error) back('dong', 'err', error.message);
  revalidatePath('/kho');
  back('dong', 'ok', 'Đã lưu ngưỡng lệch đồng cho phép');
}
