// Đơn phát sinh: mô phỏng ảnh hưởng, tự xác định mức A/B/C và các bước duyệt
import { parseNum } from '@/lib/format';
import { type Kh, orderFrom, rebuild } from './load';
import type { Order } from './scheduler';

export type ProductRow = {
  id: string; product_code: string; product_name: string; group_code: string; cores: number; insulation: string | null; shield: boolean | null;
  sheath_color: string | null; core_colors: string[] | null; route: string[] | null; size_mm2: number; spec_status: string;
  core_code?: string | null;
};
export type ChangeInput = { product_code: string; qty: number; due: string; so: string; prio: 0 | 1; br: boolean };
export type Step = { role: string; label: string; done_by?: string; done_name?: string; done_at?: string; result?: string; comment?: string; user_ids?: string[] };

export const LEVEL: Record<string, { tone: 'ok' | 'warn' | 'bad'; label: string }> = {
  A: { tone: 'ok', label: 'Mức A · Giám đốc duyệt lô phát sinh' },
  B: { tone: 'warn', label: 'Mức B · Giám đốc duyệt, chốt ngày giao' },
  C: { tone: 'bad', label: 'Mức C · chen vào vùng khóa (TP KT/QA → Giám đốc)' },
};

export function stepsFor(level: 'A' | 'B' | 'C'): Step[] {
  // Quy trình 28/10/2026: lô phát sinh TP SX đệ trình, Giám đốc duyệt (Chủ tịch HĐQT không duyệt lô); database tự lập bước
  const first = { role: 'SX_TP', label: 'TP SX lập đề nghị, chạy mô phỏng' };
  if (level === 'A') return [first, { role: 'BGD', label: 'Giám đốc duyệt lô phát sinh' }];
  if (level === 'B') return [first, { role: 'BGD', label: 'Giám đốc duyệt, chốt ngày giao với kinh doanh' }];
  return [first, { role: 'KT_TP', label: 'TP Kỹ thuật/QA cho ý kiến: đổi mã, mẫu đầu mã, thông số' }, { role: 'BGD', label: 'Giám đốc duyệt chen vào vùng khóa' }];
}

export function simulate(kh: Kh, product: ProductRow, input: ChangeInput) {
  const order: Order = {
    ...orderFrom({ ...product, product_id: product.id, core_code: product.core_code ?? null, single_color: null, qty_m: input.qty, due_date: input.due, priority: input.prio, so_no: input.so || null, change_request_id: 'new' }, 'MỚI'),
    id: 'new', source: input.so || 'Đơn phát sinh',
  };
  const br = input.prio === 0 && input.br;
  const r = rebuild(kh, [...kh.orders, order], { split: br });
  const rows = kh.orders.map((o) => ({ o, b: kh.fin.get(o.id), a: r.fin.get(o.id) }))
    .filter((x) => x.a && x.b && x.a.finDate !== x.b.finDate);
  const newly = rows.filter((x) => x.a!.slack !== null && x.a!.slack < 0 && (x.b!.slack === null || x.a!.slack < x.b!.slack));
  const soLate = newly.filter((x) => /^SO/i.test(x.o.source));
  const n = r.fin.get('new')!;
  const level: 'A' | 'B' | 'C' = br ? 'C' : (newly.length || !n.placed || (n.slack !== null && n.slack < 0)) ? 'B' : 'A';
  const notify: string[] = [];
  if (level === 'A') notify.push('Giám đốc');
  if (level === 'B') notify.push('Giám đốc', ...(soLate.length || (n.slack ?? 0) < 0 ? ['Kinh doanh (SO bị lùi)'] : []));
  if (level === 'C') notify.push('TP Kỹ thuật/QA', 'Giám đốc', 'Kế toán (phiếu lĩnh bổ sung)', 'TP mua hàng (kiểm vật tư)', ...(soLate.length ? ['Kinh doanh (SO bị lùi)'] : []));
  const B = (kh.todayIdx + kh.cfg.frozen_days) * r.cal.SPD * r.cal.S;
  const touched = br ? [...new Set(r.sch.slots.filter((s) => s.lineId === 'new' && s.start < B).map((s) => s.machine))] : [];
  return {
    order, br, level, notify, touched, n,
    rows: rows.map((x) => ({ id: x.o.id, label: x.o.label, product_code: x.o.product_code, source: x.o.source, due: x.o.due, before: x.b!.finDate, after: x.a!.finDate, slackAfter: x.a!.slack, placedAfter: x.a!.placed })),
    newly: newly.map((x) => x.o.label),
  };
}
export type Sim = ReturnType<typeof simulate>;

// Đọc ô nhập đơn phát sinh (dùng cho cả mô phỏng và gửi đề nghị)
export function readChange(sp: Record<string, string | undefined>): ChangeInput | string {
  const qty = parseNum(sp.qty ?? null);
  if (!sp.sp) return 'Chọn mã sản phẩm';
  if (qty === null || Number.isNaN(qty) || qty < 100) return 'Số mét phải từ 100 trở lên';
  if (!/^\d{4}-\d{2}-\d{2}$/.test(sp.due ?? '')) return 'Chọn hạn giao khách cần';
  return { product_code: sp.sp, qty, due: sp.due!, so: (sp.so ?? '').trim(), prio: sp.prio === '0' ? 0 : 1, br: sp.prio === '0' && sp.br === '1' };
}

