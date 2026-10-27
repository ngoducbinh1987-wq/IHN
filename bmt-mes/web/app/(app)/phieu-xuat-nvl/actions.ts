'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { parseNum } from '@/lib/format';
import { errText, withMsg } from '@/lib/kho';
import { createClient } from '@/lib/supabase/server';

const str = (form: FormData, key: string) => String(form.get(key) ?? '').trim();

// Dòng mã tem + số lượng; số lượng trống = cả ống/bao (phiếu xuất), bắt buộc với NVL thừa
function rows(form: FormData, prefix: string, back: string, needQty: boolean) {
  const items: { code: string; qty: number | null }[] = [];
  for (let i = 0; i < 40; i++) {
    const code = str(form, `${prefix}_code_${i}`).toUpperCase();
    if (!code) continue;
    const raw = str(form, `${prefix}_qty_${i}`);
    const qty = raw ? parseNum(raw) : null;
    if (raw && (qty === null || Number.isNaN(qty) || qty <= 0)) redirect(withMsg(back, 'err', `${code}: "${raw}" không phải số hợp lệ`));
    if (needQty && qty === null) redirect(withMsg(back, 'err', `${code}: nhập kg cân lại`));
    items.push({ code, qty });
  }
  return items;
}

// Kế toán SX nhập phiếu xuất NVL đã có chữ ký thủ kho và NV lấy NVL
export async function paperIssue(form: FormData) {
  const back = str(form, 'back') || '/phieu-xuat-nvl';
  const items = rows(form, 'is', back, false);
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc('paper_issue', {
    p_req: str(form, 'req_id'),
    p: { receiver_code: str(form, 'receiver_code'), paper_no: str(form, 'paper_no'), reason: str(form, 'reason'), items },
  });
  if (error) redirect(withMsg(back, 'err', errText(error.message)));
  revalidatePath('/phieu-xuat-nvl');
  redirect(withMsg(back, 'ok', `Đã ghi sổ phiếu xuất ${(data as { doc_no: string }).doc_no} (${items.length} ống/bao)`));
}

// Kế toán SX nhập phiếu nhập NVL thừa cuối ngày
export async function paperReturn(form: FormData) {
  const back = str(form, 'back') || '/phieu-xuat-nvl';
  const items = rows(form, 'rt', back, true);
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc('paper_return', {
    p: { giver_code: str(form, 'giver_code'), paper_no: str(form, 'paper_no'), items },
  });
  if (error) redirect(withMsg(back, 'err', errText(error.message)));
  revalidatePath('/phieu-xuat-nvl');
  redirect(withMsg(back, 'ok', `Đã nhập lại kho NVL thừa: ${(data as string[]).join(', ')}`));
}
