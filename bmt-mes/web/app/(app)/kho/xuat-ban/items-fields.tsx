import { nf } from '@/lib/format';

export type FgGroup = {
  product_id: string; product_code: string; product_name: string | null; brand: string; pack_m: number | null; pack_type: string | null;
  qc_wait_coils: number; putaway_coils: number; putaway_m: number; store_coils: number; store_m: number; hold_coils: number;
  total_coils: number; total_m: number; committed_coils: number; free_coils: number; oldest_mfg_date: string | null;
};
export type ItemRow = { product_code: string; brand: string; pack_m: number | null; coils: number };

export const kindKey = (code: string, brand: string, pack: number | null) => `${code}|${brand}|${pack ?? ''}`;
export const kindLabel = (code: string, brand: string, pack: number | null) => `${code} · ${brand} · ${pack ? `${nf(pack)} m/cuộn` : 'cuộn lẻ, đoạn cắt'}`;

// Các dòng lệnh giao: chủng loại (mã, nhãn, quy cách) × số cuộn; chỉ cần biết xuất bao nhiêu cuộn, chủng loại nào
export function ItemsFields({ groups, rows, extraRows = 4 }: { groups: FgGroup[]; rows?: ItemRow[]; extraRows?: number }) {
  const initial = rows ?? [];
  const opts = [...groups];
  for (const r of initial) {
    if (!opts.some((g) => kindKey(g.product_code, g.brand, g.pack_m) === kindKey(r.product_code, r.brand, r.pack_m))) {
      opts.push({ product_id: '', product_code: r.product_code, product_name: null, brand: r.brand, pack_m: r.pack_m, pack_type: null, qc_wait_coils: 0,
        putaway_coils: 0, putaway_m: 0, store_coils: 0, store_m: 0, hold_coils: 0, total_coils: 0, total_m: 0, committed_coils: 0, free_coils: 0, oldest_mfg_date: null });
    }
  }
  const n = Math.min(12, initial.length + extraRows);
  return (
    <div className="flex flex-col gap-2">
      {Array.from({ length: n }, (_, i) => {
        const r = initial[i];
        return (
          <div key={i} className="grid gap-2 sm:grid-cols-[minmax(0,1fr)_130px]">
            <select className="inp" name={`kind_${i}`} defaultValue={r ? kindKey(r.product_code, r.brand, r.pack_m) : ''} aria-label={`Chủng loại dòng ${i + 1}`}>
              <option value="">{i === 0 ? 'Chọn chủng loại cáp' : '—'}</option>
              {opts.map((g) => (
                <option key={kindKey(g.product_code, g.brand, g.pack_m)} value={kindKey(g.product_code, g.brand, g.pack_m)}>
                  {kindLabel(g.product_code, g.brand, g.pack_m)} – còn giao được {g.free_coils} cuộn
                </option>
              ))}
            </select>
            <input className="inp text-right" name={`coils_${i}`} inputMode="numeric" defaultValue={r ? String(r.coils) : ''} placeholder="Số cuộn" aria-label={`Số cuộn dòng ${i + 1}`} />
          </div>
        );
      })}
    </div>
  );
}
