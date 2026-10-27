'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { parseNum } from '@/lib/format';
import { loadKh } from '@/lib/kh/load';
import { minutesOf, sampleTemplate, shiftLines } from '@/lib/kh/shift';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

const back = (form: FormData, kind: 'ok' | 'err', msg: string): never =>
  redirect(`/ghi-nhan-ca?d=${form.get('d')}&m=${form.get('m')}&s=${form.get('s')}&${kind}=${encodeURIComponent(msg)}`);

async function save(form: FormData) {
  const me = await requireMe();
  const db = await createClient();
  const d = String(form.get('d')), m = String(form.get('m')), s = String(form.get('s'));
  const kh = await loadKh(db, { roles: me.roles });
  const plan = shiftLines(kh, d, m, s);
  const lines = plan.map((l, i) => {
    const decl = parseNum(form.get(`decl_${i}`));
    const bob = parseNum(form.get(`bob_${i}`));
    if (decl !== null && (Number.isNaN(decl) || decl < 0)) back(form, 'err', `Dòng ${l.label}: mét khai báo phải là số ≥ 0`);
    return { key: l.key, plan_line_id: l.plan_line_id, label: l.label, product_code: l.product_code, op: l.op, color: l.color, planned_m: l.planned_m, declared_m: decl ?? 0, plc_m: null, bobbins: bob && !Number.isNaN(bob) ? Math.round(bob) : 0 };
  });
  const downtime: { from: string; to: string; min: number; reason: string; src: string }[] = [];
  for (let i = 0; i < 12; i++) {
    const from = String(form.get(`dt_from_${i}`) ?? '').trim(), to = String(form.get(`dt_to_${i}`) ?? '').trim();
    if (!from && !to) continue;
    const min = minutesOf(from, to);
    if (!min) back(form, 'err', `Dừng máy dòng ${i + 1}: nhập giờ dạng HH:MM, giờ chạy lại sau giờ dừng`);
    downtime.push({ from, to, min, reason: String(form.get(`dt_reason_${i}`) ?? ''), src: 'MANUAL' });
  }
  // NVL để lại máy chạy tiếp cùng lô; phế cả ca ngoài phiếu bobin (Kế toán SX nhập từ tờ báo cáo ca giấy)
  const keeps: { material_code: string; kg: number; wo_no: string }[] = [];
  for (let i = 0; i < 12; i++) {
    const mat = String(form.get(`kp_mat_${i}`) ?? '').trim().toUpperCase();
    if (!mat) continue;
    const kg = parseNum(form.get(`kp_kg_${i}`));
    if (kg === null || Number.isNaN(kg) || kg <= 0) back(form, 'err', `NVL để lại máy ${mat}: nhập kg cân`);
    keeps.push({ material_code: mat, kg: kg as number, wo_no: String(form.get(`kp_wo_${i}`) ?? '') });
  }
  const scraps: { wo_no: string; op_code: string; reason: string; kg: number }[] = [];
  for (let i = 0; i < 12; i++) {
    const kg = parseNum(form.get(`sc_kg_${i}`));
    if (kg === null) continue;
    if (Number.isNaN(kg) || kg <= 0) back(form, 'err', `Phế cả ca dòng ${i + 1}: kg phải là số > 0`);
    const [wo_no = '', op_code = ''] = String(form.get(`sc_wo_${i}`) ?? '').split('|');
    scraps.push({ wo_no, op_code, reason: String(form.get(`sc_reason_${i}`) ?? ''), kg });
  }
  const { data, error } = await db.schema('app').rpc('kh_save_report', {
    p_date: d, p_machine: m,
    p: {
      shift_code: s, operator_code: String(form.get('operator') ?? '') || null, plan_id: kh.version?.plan_id ?? null, source: 'MANUAL',
      lines, downtime, samples: sampleTemplate(plan), keeps, scraps, scrap_kg: 0,
      note: String(form.get('note') ?? '').trim() || null,
    },
  });
  if (error) back(form, 'err', error.message);
  return data as string;
}

export async function saveReport(form: FormData) {
  await save(form);
  revalidatePath('/ghi-nhan-ca');
  back(form, 'ok', 'Đã lưu nháp báo cáo ca');
}

export async function submitReport(form: FormData) {
  const id = await save(form);
  const db = await createClient();
  const { error } = await db.schema('app').rpc('kh_submit_report', { p_id: id });
  if (error) back(form, 'err', 'Đã lưu nháp nhưng chưa gửi được: ' + error.message);
  revalidatePath('/ghi-nhan-ca');
  back(form, 'ok', 'Đã gửi báo cáo ca. TP SX chốt ca (vắng thì tổ phó NV1).');
}

export async function confirmReport(form: FormData) {
  const db = await createClient();
  const { error } = await db.schema('app').rpc('kh_confirm_report', { p_id: String(form.get('id')), p_note: String(form.get('note') ?? '') });
  if (error) back(form, 'err', error.message);
  revalidatePath('/ghi-nhan-ca');
  back(form, 'ok', 'Đã chốt ca: số liệu khóa, phế cả ca ghi vào sổ phế của lô, cộng vào Kế hoạch – Thực tế.');
}

export async function reopenReport(form: FormData) {
  const db = await createClient();
  const { error } = await db.schema('app').rpc('kh_reopen_report', { p_id: String(form.get('id')) });
  if (error) back(form, 'err', error.message);
  revalidatePath('/ghi-nhan-ca');
  back(form, 'ok', 'Đã trả lại báo cáo để người vận hành sửa');
}

export async function judgeSample(form: FormData) {
  const me = await requireMe();
  const db = await createClient();
  const d = String(form.get('d')), m = String(form.get('m')), s = String(form.get('s'));
  const kh = await loadKh(db, { roles: me.roles });
  const { error } = await db.schema('app').rpc('kh_sample', {
    p_date: d, p_machine: m, p_shift: s, p_samples: sampleTemplate(shiftLines(kh, d, m, s)),
    p_index: Number(form.get('i')), p_result: form.get('r') === 'NG' ? 'NG' : 'OK',
  });
  if (error) back(form, 'err', error.message);
  revalidatePath('/ghi-nhan-ca');
  back(form, 'ok', form.get('r') === 'NG' ? 'Đã ghi mẫu không đạt: chỉnh máy, lấy mẫu lại' : 'Đã duyệt mẫu đạt: được chạy hàng loạt');
}
