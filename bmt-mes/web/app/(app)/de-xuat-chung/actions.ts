'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { after } from 'next/server';
import { parseNum } from '@/lib/format';
import { flushEmailOutbox } from '@/lib/notify';
import { createClient } from '@/lib/supabase/server';

const s = (f: FormData, k: string) => String(f.get(k) ?? '').trim();
const back = (url: string, key: 'ok' | 'err', msg: string) => redirect(`${url}${url.includes('?') ? '&' : '?'}${key}=${encodeURIComponent(msg)}`);

// Gom dữ liệu form theo mẫu của loại đề xuất
function payload(f: FormData) {
  const data: Record<string, string> = {};
  for (const k of ['place', 'transport', 'cost_plan', 'from_shift', 'to_shift', 'due_date', 'handover', 'benefit']) {
    const v = s(f, 'data_' + k);
    if (v) data[k] = v;
  }
  const codes = f.getAll('item_code').map(String), names = f.getAll('item_name').map(String), specs = f.getAll('item_spec').map(String);
  const qtys = f.getAll('item_qty'), units = f.getAll('item_unit').map(String), prices = f.getAll('item_price');
  const items = names.map((n, i) => ({
    code: (codes[i] ?? '').split('·')[0].trim().toUpperCase() || undefined, name: n.trim() || undefined, spec: (specs[i] ?? '').trim() || undefined,
    qty: parseNum(qtys[i] ?? null) ?? undefined, unit: (units[i] ?? '').trim() || undefined, price: parseNum(prices[i] ?? null) ?? undefined,
  })).filter((x) => x.code || x.name);
  return {
    id: s(f, 'id') || undefined, type: s(f, 'type'), title: s(f, 'title'), content: s(f, 'content'),
    urgent: f.get('urgent') === 'on', operator_code: s(f, 'operator_code') || undefined,
    date_from: s(f, 'date_from') || undefined, date_to: s(f, 'date_to') || undefined, part: s(f, 'part') || 'FULL',
    time_from: s(f, 'time_from') || undefined, time_to: s(f, 'time_to') || undefined,
    amount: parseNum(f.get('amount')) ?? undefined, paid: f.has('paid') ? f.get('paid') === '1' : undefined,
    machine_code: s(f, 'machine_code') || undefined, target_dept: s(f, 'target_dept') || undefined,
    anonymous: f.get('anonymous') === 'on', items, data,
  };
}

export async function saveRequest(f: FormData) {
  const supabase = await createClient();
  const from = s(f, 'back') || '/de-xuat-chung';
  const send = f.get('send') === '1';
  const p = payload(f);
  const { data: id, error } = await supabase.schema('app').rpc('req_save', { p });
  if (error) back(from, 'err', error.message);
  if (send && !p.id) {
    const { error: e2 } = await supabase.schema('app').rpc('req_submit', { p_id: id });
    if (e2) back(`/de-xuat-chung/${id}`, 'err', 'Đã lưu nháp nhưng chưa gửi được: ' + e2.message);
    after(flushEmailOutbox);
  } else if (send) {
    const { data: st } = await supabase.schema('app').from('v_requests').select('status').eq('id', id as string).maybeSingle();
    if (st && ['DRAFT', 'RETURNED'].includes(st.status)) {
      const { error: e2 } = await supabase.schema('app').rpc('req_submit', { p_id: id });
      if (e2) back(`/de-xuat-chung/${id}`, 'err', 'Đã lưu nhưng chưa gửi được: ' + e2.message);
      after(flushEmailOutbox);
    }
  }
  revalidatePath('/', 'layout');
  back(`/de-xuat-chung/${id}`, 'ok', send ? 'Đã gửi đề xuất. Người duyệt đã nhận thông báo ở Quy trình duyệt.' : 'Đã lưu');
}

async function call(f: FormData, fn: string, args: Record<string, unknown>, ok: string) {
  const id = s(f, 'id');
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc(fn, args);
  if (error) back(`/de-xuat-chung/${id}`, 'err', error.message);
  after(flushEmailOutbox);
  revalidatePath('/', 'layout');
  back(`/de-xuat-chung/${id}`, 'ok', ok);
}

export async function submitRequest(f: FormData) { await call(f, 'req_submit', { p_id: s(f, 'id') }, 'Đã gửi đề xuất. Người duyệt đã nhận thông báo.'); }
export async function withdrawRequest(f: FormData) { await call(f, 'req_withdraw', { p_id: s(f, 'id') }, 'Đã rút lại, đề xuất về Nháp.'); }
export async function cancelRequest(f: FormData) { await call(f, 'req_cancel', { p_id: s(f, 'id') }, 'Đã hủy đề xuất.'); }
export async function refuseRequest(f: FormData) { await call(f, 'req_refuse', { p_id: s(f, 'id'), p_reason: s(f, 'reason') }, 'Đã từ chối, người gửi đã nhận thông báo.'); }
export async function doneRequest(f: FormData) { await call(f, 'req_done', { p_id: s(f, 'id'), p_note: s(f, 'note') }, 'Đã ghi xử lý xong, người gửi đã nhận thông báo.'); }
export async function repairRequest(f: FormData) { await call(f, 'req_make_repair', { p_id: s(f, 'id') }, 'Đã mở phiếu sửa chữa.'); }

export async function prFromRequest(f: FormData) {
  const codes = f.getAll('pr_code').map(String), qtys = f.getAll('pr_qty');
  const lines = codes.map((c, i) => ({ material_code: c.split('·')[0].trim().toUpperCase(), qty: parseNum(qtys[i] ?? null) }))
    .filter((l) => l.material_code && l.qty);
  await call(f, 'req_make_pr', { p_id: s(f, 'id'), p_lines: lines.length ? lines : null, p_need: s(f, 'need_date') || null },
    'Đã lập đề xuất mua, theo dõi ở Mua hàng → Đề xuất mua.');
}
