'use client';

import { useMemo, useState } from 'react';

type Item = { id: string; code: string; name: string; uom: string };
type Group = { name: string; items: Item[] };

// Tick mặt hàng NCC bán được cho BMT: gom theo nhóm vật tư, có ô lọc và "chọn cả nhóm".
// Gửi form: mỗi vật tư đang tick là một ô ẩn name="material" (ô lọc không làm mất vật tư đã tick).
export function MaterialPicker({ groups, selected }: { groups: Group[]; selected: string[] }) {
  const [picked, setPicked] = useState<Set<string>>(() => new Set(selected));
  const [q, setQ] = useState('');
  const key = q.trim().toLowerCase();
  const shown = useMemo(() => groups
    .map((g) => ({ ...g, items: key ? g.items.filter((m) => `${m.code} ${m.name}`.toLowerCase().includes(key)) : g.items }))
    .filter((g) => g.items.length > 0), [groups, key]);

  const toggle = (ids: string[], on: boolean) => setPicked((prev) => {
    const next = new Set(prev);
    for (const id of ids) { if (on) next.add(id); else next.delete(id); }
    return next;
  });

  return (
    <div className="flex flex-col gap-3">
      {[...picked].map((id) => <input key={id} type="hidden" name="material" value={id} />)}
      <div className="flex flex-wrap items-center gap-3">
        <input className="inp w-full sm:w-72" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Lọc mã hoặc tên vật tư" aria-label="Lọc vật tư" />
        <span className="text-[13.5px] text-muted">Đang chọn <b className="text-ink">{picked.size}</b> mặt hàng</span>
      </div>
      {shown.length === 0 && <div className="text-[14px] text-muted">Không có vật tư nào khớp ô lọc.</div>}
      {shown.map((g) => {
        const ids = g.items.map((m) => m.id);
        const all = ids.every((id) => picked.has(id));
        return (
          <fieldset key={g.name} className="rounded border border-line p-3">
            <legend className="px-1 text-[14px] font-medium">{g.name}</legend>
            <label className="mb-2 flex w-fit items-center gap-2 text-[13.5px] text-brand">
              <input type="checkbox" checked={all} onChange={(e) => toggle(ids, e.target.checked)} />Chọn cả nhóm ({g.items.length})
            </label>
            <div className="grid gap-x-4 gap-y-1.5 sm:grid-cols-2 xl:grid-cols-3">
              {g.items.map((m) => (
                <label key={m.id} className="flex items-start gap-2 text-[14px]">
                  <input className="mt-1" type="checkbox" checked={picked.has(m.id)} onChange={(e) => toggle([m.id], e.target.checked)} />
                  <span><span className="mono font-medium">{m.code}</span> {m.name}</span>
                </label>
              ))}
            </div>
          </fieldset>
        );
      })}
    </div>
  );
}
