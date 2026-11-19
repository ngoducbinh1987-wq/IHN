'use client';
import { useEffect, useState } from 'react';
import { PR_KINDS } from '@/lib/purchase';

// Ô chọn loại đề xuất mua + dòng định nghĩa ngắn của loại đang chọn.
// listIds: đổi danh sách gợi ý vật tư của các ô name="material_code" theo loại (NVL / công cụ dụng cụ).
export function PrKindField({ defaultValue = 'BO_SUNG', buyer, name = 'kind', label = true, listIds, className = 'inp' }: {
  defaultValue?: string; buyer: boolean; name?: string; label?: boolean; listIds?: { nvl: string; tool: string }; className?: string;
}) {
  const [kind, setKind] = useState(defaultValue);
  const kinds = PR_KINDS.filter((k) => k.manual && (buyer || !k.buyerOnly || k.code === defaultValue));
  const cur = PR_KINDS.find((k) => k.code === kind);
  useEffect(() => {
    if (!listIds) return;
    const id = kind === 'CCDC' ? listIds.tool : listIds.nvl;
    document.querySelectorAll<HTMLInputElement>('input[name="material_code"]').forEach((i) => i.setAttribute('list', id));
  }, [kind, listIds]);
  const select = (
    <select className={className} name={name} value={kind} onChange={(e) => setKind(e.target.value)} aria-label="Loại đề xuất">
      {kinds.map((k) => <option key={k.code} value={k.code}>{k.label}</option>)}
    </select>
  );
  const def = cur && <span className="mt-1 line-clamp-2 text-[12.5px] font-normal leading-snug text-muted" id={`${name}-def`}>{cur.def}</span>;
  return label ? (
    <label className="lbl"><span className="req">Loại đề xuất</span>{select}{def}</label>
  ) : (
    <span className="flex min-w-0 flex-col">{select}{def}</span>
  );
}
