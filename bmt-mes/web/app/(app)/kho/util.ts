import { parseNum } from '@/lib/format';

export type PickItem = { hu_id: string; qty: number | null; reason: string | null };

// Đọc danh sách đã quét (ScanList) từ form; số lượng theo kiểu Việt Nam
export function parseItems(raw: FormDataEntryValue | null): { items: PickItem[]; error?: string } {
  let arr: { hu_id: string; qty_text?: string; reason?: string | null }[] = [];
  try { arr = JSON.parse(String(raw ?? '[]')); } catch { return { items: [], error: 'Danh sách quét không hợp lệ' }; }
  const items: PickItem[] = [];
  for (const a of arr) {
    const q = a.qty_text ? parseNum(a.qty_text) : null;
    if (q !== null && (Number.isNaN(q) || q <= 0)) return { items: [], error: `Số lượng "${a.qty_text}" không hợp lệ` };
    items.push({ hu_id: a.hu_id, qty: q, reason: a.reason ?? null });
  }
  return { items };
}

export const str = (form: FormData, key: string) => String(form.get(key) ?? '').trim();
export const optUuid = (form: FormData, key: string) => str(form, key) || null;
