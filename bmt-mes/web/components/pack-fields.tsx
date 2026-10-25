'use client';

import { useState } from 'react';

export type PackOption = { pack_type: string; m_per_pack: number };

// Đóng gói + m/kiện theo danh mục (Bobin gỗ 500/305, Cuộn PE 100/200). Giá trị cũ ngoài danh mục vẫn hiện để giữ nguyên.
export function PackFields({ options, packType, mPerPack, className = 'inp inp-y' }:
  { options: PackOption[]; packType?: string | null; mPerPack?: number | string | null; className?: string }) {
  const types = Array.from(new Set(options.map((o) => o.pack_type)));
  const [type, setType] = useState(packType || types[0] || 'Bobin gỗ');
  const list = options.filter((o) => o.pack_type === type).map((o) => Number(o.m_per_pack));
  const cur = mPerPack !== null && mPerPack !== undefined && mPerPack !== '' ? Number(mPerPack) : null;
  const keepOld = type === (packType || '') && cur !== null && !list.includes(cur);
  const values = keepOld ? [...list, cur!] : list;
  const [m, setM] = useState(String(cur !== null && values.includes(cur) ? cur : values[0] ?? ''));
  return (
    <>
      <label className="lbl">Đóng gói
        <select className={className} name="pack_type" value={type}
          onChange={(e) => { setType(e.target.value); setM(String(options.find((o) => o.pack_type === e.target.value)?.m_per_pack ?? '')); }}>
          {types.map((t) => <option key={t}>{t}</option>)}
        </select>
      </label>
      <label className="lbl">m/kiện
        <select className={`${className} text-right`} name="m_per_pack" value={m} onChange={(e) => setM(e.target.value)}>
          {values.map((v) => <option key={v} value={v}>{v.toLocaleString('vi-VN')}{keepOld && v === cur ? ' (cũ)' : ''}</option>)}
        </select>
      </label>
    </>
  );
}
