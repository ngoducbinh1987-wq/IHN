'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { parseNum } from '@/lib/format';
import { createClient } from '@/lib/supabase/server';

const go = (kind: 'ok' | 'err', msg: string, edit?: string): never =>
  redirect(`/tham-so?${edit ? `sua=${edit}&` : ''}${kind}=${encodeURIComponent(msg)}`);
const num = (form: FormData, k: string, label: string, edit: string) => {
  const v = parseNum(form.get(k));
  if (v === null || Number.isNaN(v)) go('err', `${label}: nhập số`, edit);
  return v as number;
};
const done = (n: number, extra = '') => {
  revalidatePath('/tham-so'); revalidatePath('/lich-may');
  go('ok', `Đã lưu ${n} thay đổi${extra}. Quản lý SX đã được báo để xếp lại lịch.`);
};

export async function saveConfig(form: FormData) {
  const e = 'params';
  const cutoff = String(form.get('cutoff_time') ?? '');
  if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(cutoff)) go('err', 'Giờ chốt phát lệnh: nhập dạng HH:MM', e);
  const p = {
    fill_pct: num(form, 'fill_pct', 'Tỷ lệ xếp lịch', e), frozen_days: num(form, 'frozen_days', 'Vùng khóa', e), cutoff_time: cutoff,
    downtime_reason_min: num(form, 'downtime_reason_min', 'Dừng máy bắt buộc lý do', e), plc_dev_pct: num(form, 'plc_dev_pct', 'Ngưỡng lệch PLC', e),
    auto_shifts: num(form, 'auto_shifts', 'Số ca đạt liên tiếp', e), plc_loss_min: num(form, 'plc_loss_min', 'Mất kết nối PLC', e),
    machines_per_operator: num(form, 'machines_per_operator', 'Số máy 1 người đứng', e),
    group_days: num(form, 'group_days', 'Khung gom lô', e),
  };
  const db = await createClient();
  const { data, error } = await db.schema('app').rpc('kh_save_config', { p, p_reason: String(form.get('reason') ?? '') });
  if (error) go('err', error.message, e);
  done(Number(data));
}

export async function saveShifts(form: FormData) {
  const e = 'shifts';
  const rows = ['A', 'B', 'C'].map((c) => {
    const st = String(form.get(`start_${c}`) ?? ''), en = String(form.get(`end_${c}`) ?? '');
    if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(st) || !/^([01]\d|2[0-3]):[0-5]\d$/.test(en)) go('err', `Ca ${c}: giờ nhập dạng HH:MM`, e);
    return { code: c, start_time: st, end_time: en, break_min: num(form, `break_${c}`, `Ca ${c} · phút nghỉ`, e), active: c === 'A' || form.get(`active_${c}`) === '1' };
  });
  const reason = String(form.get('reason') ?? '');
  const wd = form.getAll('workday').map(Number).filter((d) => d >= 1 && d <= 7).sort();
  const wdChanged = wd.join(',') !== String(form.get('wd_old') ?? '');
  if (!wd.length) go('err', 'Chọn ít nhất một ngày làm việc', e);
  const db = await createClient();
  let n = 0;
  const { data, error } = await db.schema('app').rpc('kh_save_shifts', { p: rows, p_reason: reason });
  if (error && !(wdChanged && error.message.includes('Không có thay đổi'))) go('err', error.message, e);
  n += Number(data ?? 0);
  if (wdChanged) {
    // Ngày làm việc lưu ở mfg.machine_setting('shift') qua app.save_work_calendar: giờ ca A chia đôi quanh giờ nghỉ
    // (đúng giá trị vừa lưu nên hàm chỉ đổi ngày làm việc); tỷ lệ xếp lịch, số máy/người giữ nguyên
    const { data: c } = await db.schema('app').from('v_kh_config').select('fill_pct, machines_per_operator').single();
    const a = rows[0], min = (t: string) => Number(t.slice(0, 2)) * 60 + Number(t.slice(3, 5));
    const half = (min(a.end_time) - min(a.start_time) - a.break_min) / 2;
    const hm = (m: number) => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(Math.floor(m % 60)).padStart(2, '0')}:${m % 1 ? '30' : '00'}`;
    const { data: k, error: er2 } = await db.schema('app').rpc('save_work_calendar', {
      p_s1_from: a.start_time, p_s1_to: hm(min(a.start_time) + half), p_s2_from: hm(min(a.start_time) + half + a.break_min), p_s2_to: a.end_time,
      p_workdays: wd, p_fill: Number(c?.fill_pct), p_max_op: Number(c?.machines_per_operator), p_reason: reason,
    });
    if (er2) go('err', (n ? `Đã lưu ca nhưng chưa lưu ngày làm việc: ` : '') + er2.message, e);
    n += Number(k ?? 0);
  }
  done(n);
}

export async function saveRates(form: FormData) {
  const e = 'rates';
  const rows = String(form.get('ops') ?? '').split(',').filter(Boolean).map((op) => ({
    op_code: op, rate_small: num(form, `small_${op}`, `${op} cỡ nhỏ`, e), rate_large: num(form, `large_${op}`, `${op} cỡ lớn`, e),
  }));
  const db = await createClient();
  const { data, error } = await db.schema('app').rpc('kh_save_rates', { p: rows, p_reason: String(form.get('reason') ?? '') });
  if (error) go('err', error.message, e);
  done(Number(data), ' · tốc độ chuyển sang “đã ban hành”');
}

export async function saveChangeovers(form: FormData) {
  const e = 'setup';
  const codes = String(form.get('codes') ?? '').split(',').filter(Boolean);
  const rows = codes.map((c) => ({ code: c, minutes: num(form, `min_${c}`, c, e) }));
  const db = await createClient();
  const { data, error } = await db.schema('app').rpc('kh_save_changeovers', { p: rows, p_reason: String(form.get('reason') ?? '') });
  if (error) go('err', error.message, e);
  done(Number(data));
}

export async function setMode(form: FormData) {
  const db = await createClient();
  const { error } = await db.schema('app').rpc('kh_set_machine_mode', {
    p_machine: String(form.get('machine')), p_mode: String(form.get('mode')), p_reason: String(form.get('reason') ?? ''),
  });
  if (error) go('err', error.message);
  revalidatePath('/tham-so'); revalidatePath('/ghi-nhan-ca');
  go('ok', `Đã đổi cách nhập dữ liệu máy ${String(form.get('machine'))}`);
}

// Thông số dòng chảy (thuật toán xếp lịch theo thông số): TP KT/QA sửa thông số kỹ thuật, Giám đốc sửa tất cả
export async function saveFlow(form: FormData) {
  const e = 'flow';
  const bgd = form.get('bgd') === '1';
  const opt = (k: string, label: string) => {
    const raw = String(form.get(k) ?? '').trim();
    if (raw === '') return null;
    const v = parseNum(raw);
    if (v === null || Number.isNaN(v)) go('err', `${label}: nhập số`, e);
    return v as number;
  };
  const p: Record<string, unknown> = {
    qc_min: num(form, 'qc_min', 'Thời gian QC', e), qc_learn: form.get('qc_learn') === '1',
    pot_life_h: num(form, 'pot_life_h', 'Hạn dùng silicone', e), mix_batch_kg: num(form, 'mix_batch_kg', 'kg một mẻ trộn', e),
    size_large_mm2: num(form, 'size_large_mm2', 'Ngưỡng cỡ lớn', e), plc_min_run: num(form, 'plc_min_run', 'Phút chạy PLC tối thiểu', e),
  };
  const unit: Record<string, number> = {}, safety: Record<string, number> = {};
  for (const op of ['CD1', 'CD2', 'CD3', 'CD5', 'CD6']) {
    unit[op] = num(form, `unit_${op}`, `Mét một bobin ${op}`, e);
    const sv = opt(`safety_${op}`, `Đệm an toàn ${op}`);
    if (sv !== null && sv > 0) safety[op] = sv;
  }
  p.unit_m = unit; p.safety_min = safety;
  if (bgd) {
    p.mix_early_max_h = num(form, 'mix_early_max_h', 'Trộn sớm tối đa', e);
    p.ot_max_min = num(form, 'ot_max_min', 'Tăng ca tối đa mỗi ngày', e);
    p.ot_month_h = num(form, 'ot_month_h', 'Tăng ca tối đa mỗi tháng', e);
    p.pick_window_min = opt('pick_window_min', 'Khung coi như cùng lúc');
  }
  const db = await createClient();
  const { data, error } = await db.schema('app').rpc('kh_save_flow', { p, p_reason: String(form.get('reason') ?? '') });
  if (error) go('err', error.message, e);
  done(Number(data));
}
