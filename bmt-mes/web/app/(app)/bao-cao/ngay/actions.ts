'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { after } from 'next/server';
import { errText, withMsg } from '@/lib/kho';
import { flushEmailOutbox } from '@/lib/notify';
import { createClient } from '@/lib/supabase/server';

const str = (form: FormData, key: string) => String(form.get(key) ?? '').trim();

// Kế toán SX gửi báo cáo ngày sau khi đối soát xuất – dùng – thừa – phế
export async function sendDailyReport(form: FormData) {
  const d = str(form, 'd');
  const back = `/bao-cao/ngay?d=${d}`;
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc('send_daily_report', { p_date: d });
  if (error) redirect(withMsg(back, 'err', errText(error.message)));
  after(async () => { await flushEmailOutbox(); });
  revalidatePath('/bao-cao/ngay');
  const r = data as { counts: Record<string, number>; confirmed_docs?: number };
  const c = r.counts ?? {};
  const conf = r.confirmed_docs ? `; đã xác nhận ${r.confirmed_docs} phiếu kho nhập từ phiếu giấy` : '';
  redirect(withMsg(back, 'ok', `Đã gửi báo cáo ngày cho TP SX, Kế toán SX, Giám đốc, tổ trưởng (${c.RED ?? 0} đỏ, ${c.YELLOW ?? 0} vàng)${conf}. Phế còn lại đã nhập kho phế.`));
}

// TP SX giải trình mục vàng/đỏ (Giám đốc ghi chỉ đạo)
export async function saveLossNote(form: FormData) {
  const d = str(form, 'd');
  const back = `/bao-cao/ngay?d=${d}`;
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('save_loss_note', {
    p_wo: str(form, 'wo_id'), p_stage: str(form, 'stage'), p_date: d, p_note: str(form, 'note'),
  });
  if (error) redirect(withMsg(back, 'err', errText(error.message)));
  after(async () => { await flushEmailOutbox(); });
  revalidatePath('/bao-cao/ngay');
  redirect(withMsg(back, 'ok', 'Đã lưu giải trình'));
}
