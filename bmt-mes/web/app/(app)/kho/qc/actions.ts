'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { after } from 'next/server';
import { parseNum } from '@/lib/format';
import { errText, withMsg } from '@/lib/kho';
import { flushEmailOutbox } from '@/lib/notify';
import { createClient } from '@/lib/supabase/server';
import { str } from '../util';

const TESTS: Record<string, string> = { WIRE_DIA: 'mm', DENSITY: 'g/cm³', RDC: 'Ω/km', OD: 'mm', INS_THK: 'mm', SHEATH_THK: 'mm', KGKM: 'kg/km' };

export async function passLot(form: FormData) { await releaseLot(form, 'PASS'); }
export async function failLot(form: FormData) { await releaseLot(form, 'FAIL'); }
export async function rejectLot(form: FormData) { await releaseLot(form, 'REJECT'); }

async function releaseLot(form: FormData, result: 'PASS' | 'FAIL' | 'REJECT') {
  const back = str(form, 'back') || '/kho/qc';
  const tests: Record<string, unknown>[] = [];
  for (const [code, unit] of Object.entries(TESTS)) {
    const raw = str(form, `t_${code}`);
    if (!raw) continue;
    const v = parseNum(raw);
    if (v === null || Number.isNaN(v)) redirect(withMsg(back, 'err', `Giá trị đo ${code} không hợp lệ`));
    tests.push({ test_code: code, value_num: v, unit });
  }
  const hv = str(form, 't_HV');
  if (hv) tests.push({ test_code: 'HV', value_text: hv === 'PASS' ? 'Đạt' : 'Không đạt', pass: hv === 'PASS' });
  const visual = str(form, 't_VISUAL');
  if (visual) tests.push({ test_code: 'VISUAL', value_text: visual });
  const supabase = await createClient();
  const { error } = await supabase.schema('qa').rpc('release_lot', {
    p_lot: str(form, 'lot_id'), p_result: result, p_note: str(form, 'note') || null, p_tests: tests,
  });
  if (error) redirect(withMsg(back, 'err', errText(error.message)));
  after(async () => { await flushEmailOutbox(); });
  revalidatePath('/kho/qc');
  redirect(withMsg(back, 'ok', `${str(form, 'lot_no')}: ${result === 'PASS' ? 'Đạt – lô được dùng' : result === 'FAIL' ? 'Không đạt – đã cách ly, mở NCR' : 'Không nhận – chờ trả NCC/hủy'}`));
}
