'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { after } from 'next/server';
import { parseNum } from '@/lib/format';
import { errText, withMsg } from '@/lib/kho';
import { flushEmailOutbox } from '@/lib/notify';
import { createClient } from '@/lib/supabase/server';
import { str } from '../util';

const go = (kind: 'ok' | 'err', msg: string, tab = '') => redirect(withMsg(`/kho/cai-dat${tab ? `?tab=${tab}` : ''}`, kind, msg));

export async function saveSetting(form: FormData) {
  const raw = str(form, 'num_value');
  const num = raw ? parseNum(raw) : null;
  if (num !== null && Number.isNaN(num)) go('err', 'Giá trị không hợp lệ');
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('save_setting', { p_key: str(form, 'key'), p_num: num, p_text: str(form, 'text_value') || null });
  if (error) go('err', errText(error.message));
  revalidatePath('/kho/cai-dat');
  go('ok', 'Đã lưu cài đặt');
}

export async function saveLocation(form: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('save_location', {
    p_id: str(form, 'id') || null, p_wh: str(form, 'wh'), p_code: str(form, 'code'), p_name: str(form, 'name'), p_kind: str(form, 'kind') || 'STORE',
    p_active: form.get('active') !== 'off',
  });
  if (error) go('err', errText(error.message), 'vi-tri');
  revalidatePath('/kho/cai-dat');
  go('ok', 'Đã lưu vị trí', 'vi-tri');
}

export async function savePackage(form: FormData) {
  const tare = parseNum(form.get('tare_kg'));
  if (tare === null || Number.isNaN(tare) || tare < 0) go('err', 'Bì (kg) không hợp lệ', 'bi');
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('save_package_type', {
    p_id: str(form, 'id') || null, p_code: str(form, 'code'), p_name: str(form, 'name'), p_tare: tare, p_group: str(form, 'group') || null, p_active: form.get('active') !== 'off',
  });
  if (error) go('err', errText(error.message), 'bi');
  revalidatePath('/kho/cai-dat');
  go('ok', 'Đã lưu loại bao bì', 'bi');
}

export async function saveMaterialStock(form: FormData) {
  const rp = str(form, 'reorder_point') ? parseNum(str(form, 'reorder_point')) : null;
  const sl = str(form, 'shelf_life_days') ? parseNum(str(form, 'shelf_life_days')) : null;
  if ((rp !== null && Number.isNaN(rp)) || (sl !== null && Number.isNaN(sl))) go('err', 'Số không hợp lệ', 'vat-tu');
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('save_material_stock', {
    p_material: str(form, 'material_id'), p_reorder: rp, p_shelf_life: sl === null ? null : Math.round(sl), p_zone: str(form, 'zone') || null, p_abc: str(form, 'abc') || null,
  });
  if (error) go('err', errText(error.message), 'vat-tu');
  revalidatePath('/kho/cai-dat');
  go('ok', `Đã lưu ${str(form, 'code')}`, 'vat-tu');
}

// Tồn đầu kỳ theo kho: NVL/phế "MÃ; số lượng; đơn giá; vị trí; số đơn vị; HSD"; BTP "MÃ; công đoạn; số bobin; mét; kg cân; vị trí";
// thành phẩm "MÃ; nhãn; quy cách m/cuộn; số cuộn; mét mỗi cuộn; kiểu đóng gói; vị trí"
export async function createOpening(form: FormData) {
  const [whId, whCode] = str(form, 'warehouse').split('|');
  const lines: Record<string, unknown>[] = [];
  const num = (v: string | undefined, row: string, what: string) => {
    if (!v) return null;
    const n = parseNum(v);
    if (n === null || Number.isNaN(n)) go('err', `Dòng "${row}": ${what} "${v}" không hợp lệ`, 'dau-ky');
    return n;
  };
  for (const row of str(form, 'lines').split(/\r?\n/)) {
    if (!row.trim()) continue;
    const c = row.replace(/^\s*(KNL|KPL|KBTP|KTP)\s*:/i, '').split(/[;\t]/).map((x) => x.trim());
    if (!c[0]) go('err', `Dòng "${row}" thiếu mã`, 'dau-ky');
    if (whCode === 'KBTP') {
      lines.push({ code: c[0].toUpperCase(), stage: (c[1] ?? '').toUpperCase(), carrier: (c[2] ?? '').toUpperCase(), qty: num(c[3], row, 'số mét'),
        gross_kg: num(c[4], row, 'kg cân'), location_code: c[5] || null });
    } else if (whCode === 'KTP') {
      const coils = c[3] ? Number(c[3]) : 1;
      if (!Number.isInteger(coils) || coils <= 0) go('err', `Dòng "${row}": số cuộn phải là số nguyên > 0`, 'dau-ky');
      lines.push({ code: c[0].toUpperCase(), brand: (c[1] ?? '').toUpperCase() || null, pack_m: num(c[2], row, 'quy cách'), coils,
        m_each: num(c[4], row, 'mét mỗi cuộn'), pack_type: c[5] || null, location_code: c[6] || null });
    } else {
      const qty = parseNum(c[1] ?? '');
      const cost = c[2] ? parseNum(c[2]) : null;
      if (qty === null || Number.isNaN(qty) || qty <= 0 || (cost !== null && Number.isNaN(cost))) go('err', `Dòng "${row}" chưa đúng dạng`, 'dau-ky');
      let exp: string | null = null;
      if (c[5]) {
        const m = c[5].match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
        if (!m) go('err', `HSD "${c[5]}" phải dạng dd/mm/yyyy`, 'dau-ky');
        exp = `${m![3]}-${m![2].padStart(2, '0')}-${m![1].padStart(2, '0')}`;
      }
      lines.push({ code: c[0].toUpperCase(), qty, unit_cost: cost, location_code: c[3] || null, units: c[4] ? Number(c[4]) : 1, exp_date: exp });
    }
  }
  if (!lines.length) go('err', 'Nhập ít nhất một dòng', 'dau-ky');
  const supabase = await createClient();
  const { data, error } = await supabase.schema('inv').rpc('create_opening', { p_warehouse: whId, p_doc_date: str(form, 'doc_date') || null, p_lines: lines });
  if (error) go('err', errText(error.message), 'dau-ky');
  after(async () => { await flushEmailOutbox(); });
  redirect(withMsg(`/kho/phieu/${data}`, 'ok', 'Đã lập tồn đầu kỳ, gửi Kế toán trưởng duyệt. Duyệt xong hệ thống tự ghi sổ.'))
}
