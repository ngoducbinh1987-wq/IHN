'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { parseNum } from '@/lib/format';
import { createClient } from '@/lib/supabase/server';

// Quản trị hệ thống sửa số liệu kho, giá trị, đơn mua đã duyệt (database kiểm core.is_admin, ghi nhật ký can thiệp)
const path = (raw: FormDataEntryValue | null, fallback: string) => {
  const p = String(raw ?? '');
  return /^\/(?!\/)/.test(p) ? p : fallback;
};
const go = (to: string, kind: 'ok' | 'err', msg: string): never =>
  redirect(`${to}${to.includes('?') ? '&' : '?'}${kind}=${encodeURIComponent(msg)}`);
const txt = (form: FormData, k: string) => String(form.get(k) ?? '').trim();
const opt = (form: FormData, k: string) => txt(form, k) || null;

async function run(form: FormData, fallback: string, fn: string, args: Record<string, unknown>, ok: (data: unknown) => string) {
  const back = path(form.get('back'), fallback);
  if (!txt(form, 'reason')) go(back, 'err', 'Ghi lý do sửa');
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc(fn, { ...args, p_reason: txt(form, 'reason') });
  if (error) go(back, 'err', error.message);
  revalidatePath('/', 'layout');
  go(back, 'ok', ok(data));
}

export async function adminStockSet(form: FormData) {
  const qty = parseNum(form.get('qty'));
  await run(form, '/kho/ton', 'admin_stock_set', {
    p_warehouse: txt(form, 'warehouse_id'), p_lot: txt(form, 'lot_id'), p_location: opt(form, 'location_id'), p_hu: opt(form, 'hu_id'), p_qty: qty,
  }, (no) => `Đã sửa số tồn (phiếu điều chỉnh ${no} đã ghi sổ)`);
}

export async function adminLineCost(form: FormData) {
  await run(form, '/kho/phieu', 'admin_line_cost', { p_line: txt(form, 'line_id'), p_cost: parseNum(form.get('cost')) },
    () => 'Đã sửa đơn giá dòng phiếu kho (giá trị tồn cập nhật theo)');
}

export async function adminAvgCost(form: FormData) {
  await run(form, '/kho/ton', 'admin_avg_cost', {
    p_warehouse: txt(form, 'warehouse_id'), p_material_code: txt(form, 'material_code').toUpperCase(), p_cost: parseNum(form.get('cost')),
  }, () => 'Đã sửa giá bình quân, giá trị tồn tính lại theo giá mới');
}

export async function adminPoLine(form: FormData) {
  await run(form, '/don-mua', 'admin_po_line', {
    p_line: txt(form, 'line_id'), p_qty: parseNum(form.get('qty')), p_price: parseNum(form.get('price')), p_date: opt(form, 'expected_date'),
  }, () => 'Đã sửa dòng đơn mua, người lập đã nhận thông báo');
}
