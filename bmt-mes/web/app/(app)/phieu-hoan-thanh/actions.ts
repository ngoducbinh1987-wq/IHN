'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { after } from 'next/server';
import { nf, parseNum } from '@/lib/format';
import { errText, withMsg } from '@/lib/kho';
import { flushEmailOutbox } from '@/lib/notify';
import { createClient } from '@/lib/supabase/server';

const str = (form: FormData, key: string) => String(form.get(key) ?? '').trim();

// Số kiểu Việt Nam; trống → null; sai → báo lỗi về trang
function num(form: FormData, key: string, label: string, back: string): number | null {
  const raw = str(form, key);
  if (!raw) return null;
  const v = parseNum(raw);
  if (v === null || Number.isNaN(v) || v < 0) redirect(withMsg(back, 'err', `${label}: "${raw}" không phải số hợp lệ`));
  return v;
}

// Kế toán SX nhập phiếu hoàn thành bobin từ phiếu giấy của công nhân
export async function recordBobbin(form: FormData) {
  const back = `/phieu-hoan-thanh?muc=${encodeURIComponent(str(form, 'wo_op_id'))}`;
  const inputs: { code: string; left_kg: number | null }[] = [];
  for (let i = 0; i < 6; i++) {
    const code = str(form, `in_code_${i}`).toUpperCase();
    if (!code) continue;
    inputs.push({ code, left_kg: num(form, `in_left_${i}`, `Kg còn dư bobin ${code}`, back) });
  }
  const readings: Record<string, number> = {};
  const spark = num(form, 'spark_faults', 'Số lần cao áp báo lỗi', back);
  const od = num(form, 'od_mm', 'OD đọc trên chuyền', back);
  if (spark !== null) readings.spark_faults = spark;
  if (od !== null) readings.od_mm = od;
  const payload = {
    wo_id: str(form, 'wo_id'), op_code: str(form, 'op_code'), machine_code: str(form, 'machine_code'), carrier: str(form, 'carrier').toUpperCase(),
    operator_code: str(form, 'operator_code'), started_at: str(form, 'started_at'), ended_at: str(form, 'ended_at'),
    gross_kg: num(form, 'gross_kg', 'Khối lượng cân', back), meter_start: num(form, 'meter_start', 'Đồng hồ mét lúc bắt đầu', back),
    meter_end: num(form, 'meter_end', 'Đồng hồ mét lúc xong', back), qty_m: num(form, 'qty_m', 'Chiều dài cuộn', back),
    coils: num(form, 'coils', 'Số cuộn', back), m_each: num(form, 'm_each', 'Mét mỗi cuộn', back),
    color: str(form, 'color'), paper_no: str(form, 'paper_no'), inputs, materials: str(form, 'materials'),
    scrap_kg: num(form, 'scrap_kg', 'Kg phế', back), scrap_reason: str(form, 'scrap_reason'), readings, note: str(form, 'note'),
  };
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc('record_bobbin', { p: payload });
  if (error) redirect(withMsg(back, 'err', errText(error.message)));
  const r = data as { slip_no: string; lot_no: string; qty_m: number; estimated: boolean; net_kg: number; coils?: number };
  after(async () => { await flushEmailOutbox(); });
  revalidatePath('/phieu-hoan-thanh');
  revalidatePath('/kho/qc');
  redirect(withMsg(back, 'ok', `${r.slip_no}: ${(r.coils ?? 1) > 1 ? `${r.coils} cuộn` : 'bobin'} ${r.lot_no} · ${nf(r.net_kg, 2)} kg · ${nf(r.qty_m, 1)} m${r.estimated ? ' (ước tính từ kg)' : ''} → Chờ QC, đã báo QC`));
}

// Hủy phiếu nhập sai (Kế toán SX): đảo phiếu kho, trả bobin đầu vào
export async function voidBobbin(form: FormData) {
  const back = str(form, 'back') || '/phieu-hoan-thanh';
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc('void_bobbin', { p_slip: str(form, 'slip_id'), p_reason: str(form, 'reason') });
  if (error) redirect(withMsg(back, 'err', errText(error.message)));
  revalidatePath('/phieu-hoan-thanh');
  revalidatePath('/kho/qc');
  redirect(withMsg(back, 'ok', `Đã hủy phiếu ${data}: bobin đầu vào trả về kho BTP, số bobin trống lại`));
}
