'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { after } from 'next/server';
import { parseNum } from '@/lib/format';
import { errText, withMsg } from '@/lib/kho';
import { flushEmailOutbox } from '@/lib/notify';
import { qcTestsFor } from '@/lib/qc';
import { createClient } from '@/lib/supabase/server';
import { str } from '../util';

export async function passLot(form: FormData) { await releaseLot(form, 'PASS'); }
export async function failLot(form: FormData) { await releaseLot(form, 'FAIL'); }
export async function rejectLot(form: FormData) { await releaseLot(form, 'REJECT'); }

async function releaseLot(form: FormData, result: 'PASS' | 'FAIL' | 'REJECT') {
  const back = str(form, 'back') || '/kho/qc';
  // Chỉ tiêu theo công đoạn của lô (lib/qc.ts): số đo, Đạt/Không đạt, ghi chữ
  const tests: Record<string, unknown>[] = [];
  for (const t of qcTestsFor(str(form, 'item_kind'), str(form, 'wip_stage') || null)) {
    const raw = str(form, `t_${t.code}`);
    if (!raw) continue;
    if (t.kind === 'num') {
      const v = parseNum(raw);
      if (v === null || Number.isNaN(v)) redirect(withMsg(back, 'err', `Giá trị "${t.label}" không hợp lệ`));
      tests.push({ test_code: t.code, value_num: v, unit: t.unit ?? null });
    } else if (t.kind === 'pf') {
      tests.push({ test_code: t.code, value_text: raw === 'PASS' ? 'Đạt' : 'Không đạt', pass: raw === 'PASS' });
    } else {
      tests.push({ test_code: t.code, value_text: raw });
    }
  }
  if (result === 'PASS' && tests.some((t) => t.pass === false)) {
    redirect(withMsg(back, 'err', 'Có chỉ tiêu Không đạt: chọn "Không đạt – cách ly" và ghi lỗi'));
  }
  const supabase = await createClient();
  const { error } = await supabase.schema('qa').rpc('release_lot', {
    p_lot: str(form, 'lot_id'), p_result: result, p_note: str(form, 'note') || null, p_tests: tests,
  });
  if (error) redirect(withMsg(back, 'err', errText(error.message)));
  after(async () => { await flushEmailOutbox(); });
  revalidatePath('/kho/qc');
  redirect(withMsg(back, 'ok', `${str(form, 'lot_no')}: ${result === 'PASS' ? 'Đạt – dán tem QC PASS, được dùng ở công đoạn sau' : result === 'FAIL' ? 'Không đạt – dán tem đỏ, cách ly, đã mở phiếu xử lý (NCR)' : 'Không nhận – chờ trả NCC/hủy'}`));
}
