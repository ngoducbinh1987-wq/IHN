'use client';

import { Plus, Trash2 } from 'lucide-react';
import { useMemo, useState } from 'react';
import { SubmitButton } from '@/components/submit-button';
import { parseNum } from '@/lib/format';
import { receiveGoods } from './actions';

export type PoOpt = { id: string; po_no: string; supplier_name: string; lines: { id: string; material_code: string; material_name: string; uom: string; qty: number; received_qty: number; has_expiry: boolean }[] };
export type MatOpt = { code: string; name: string; uom: string; has_expiry: boolean };
type Unit = { gross: string; tare: string; qty: string };
type Line = { key: number; po_line_id: string; material_code: string; supplier_lot: string; mfg_date: string; exp_date: string; location_id: string;
  package_type_id: string; coa_density: string; units: Unit[] };

const blankUnit = (): Unit => ({ gross: '', tare: '', qty: '' });
let seq = 1;

export function ReceiveForm({ pos, mats, suppliers, locations, packages }: {
  pos: PoOpt[]; mats: MatOpt[]; suppliers: { id: string; name: string }[]; locations: { id: string; code: string; name: string | null }[];
  packages: { id: string; code: string; name: string; tare_kg: number }[];
}) {
  const [poId, setPoId] = useState(pos[0]?.id ?? '');
  const [lines, setLines] = useState<Line[]>([]);
  const po = pos.find((p) => p.id === poId);
  const newLine = (): Line => ({ key: seq++, po_line_id: po?.lines[0]?.id ?? '', material_code: '', supplier_lot: '', mfg_date: '', exp_date: '',
    location_id: '', package_type_id: '', coa_density: '', units: [blankUnit()] });
  const set = (k: number, patch: Partial<Line>) => setLines((x) => x.map((l) => (l.key === k ? { ...l, ...patch } : l)));
  const matOf = (l: Line) => (po ? (() => { const pl = po.lines.find((x) => x.id === l.po_line_id); return pl ? { code: pl.material_code, name: pl.material_name, uom: pl.uom, has_expiry: pl.has_expiry } : undefined; })()
    : mats.find((m) => m.code === l.material_code));
  const net = (l: Line, u: Unit) => {
    const m = matOf(l);
    if (m?.uom === 'kg' && u.gross.trim()) {
      const g = parseNum(u.gross); const t = u.tare.trim() ? parseNum(u.tare) : packages.find((p) => p.id === l.package_type_id)?.tare_kg ?? 0;
      return g !== null && t !== null && !Number.isNaN(g) && !Number.isNaN(t) ? g - t : NaN;
    }
    const q = parseNum(u.qty); return q === null ? NaN : q;
  };
  const payload = useMemo(() => JSON.stringify(lines.map((l) => ({
    po_line_id: po ? l.po_line_id : null, material_code: po ? null : l.material_code, supplier_lot: l.supplier_lot, mfg_date: l.mfg_date || null,
    exp_date: l.exp_date || null, location_id: l.location_id || null, package_type_id: l.package_type_id || null,
    coa_density: l.coa_density ? parseNum(l.coa_density) : null,
    units: l.units.map((u) => (u.gross.trim() ? { gross_kg: parseNum(u.gross), tare_kg: u.tare.trim() ? parseNum(u.tare) : null } : { qty: parseNum(u.qty) })),
  }))), [lines, po]);

  return (
    <form action={receiveGoods} className="flex flex-col gap-4">
      <section className="card p-4">
        <div className="grid gap-3 md:grid-cols-[1.4fr_1fr_1fr]">
          <label className="lbl">Nhận theo PO
            <select className="inp inp-y" name="po_id" value={poId} onChange={(e) => { setPoId(e.target.value); setLines([]); }}>
              {pos.map((p) => <option key={p.id} value={p.id}>{p.po_no} · {p.supplier_name}</option>)}
              <option value="">Không theo PO (hàng mẫu, chạy thử…)</option>
            </select>
          </label>
          {!poId && <label className="lbl"><span className="req">Nhà cung cấp</span>
            <select className="inp inp-y" name="supplier_id" required defaultValue="">
              <option value="" disabled>Chọn nhà cung cấp</option>
              {suppliers.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
            </select></label>}
          {!poId && <label className="lbl"><span className="req">Lý do không theo PO</span><input className="inp inp-y" name="no_po_reason" required /></label>}
          <label className="lbl">Số phiếu giao hàng của NCC<input className="inp" name="delivery_note" /></label>
        </div>
        {!poId && <p className="mt-2 text-[12.5px] text-warn">Không theo PO: phiếu chờ Kế toán SX nhập giá rồi mới ghi sổ. Hàng vẫn được QC kiểm tra ngay.</p>}
        {po && <p className="mt-2 text-[12.5px] text-muted">PO {po.po_no}: {po.lines.map((l) => `${l.material_code} ${l.received_qty.toLocaleString('vi-VN')}/${l.qty.toLocaleString('vi-VN')} ${l.uom}`).join(' · ')}</p>}
      </section>

      {lines.map((l, i) => {
        const m = matOf(l);
        const isKg = m?.uom === 'kg';
        const total = l.units.reduce((s, u) => s + (Number.isNaN(net(l, u)) ? 0 : net(l, u)), 0);
        return (
          <section key={l.key} className="card">
            <div className="card-h">
              <span>Dòng {i + 1}{m ? <> · <span className="mono">{m.code}</span> {m.name}</> : ''}</span>
              <button type="button" className="btn btn-sm btn-bad-o" onClick={() => setLines((x) => x.filter((y) => y.key !== l.key))}><Trash2 size={14} />Bỏ dòng</button>
            </div>
            <div className="grid gap-3 p-4 md:grid-cols-3 lg:grid-cols-6">
              {po ? (
                <label className="lbl lg:col-span-2"><span className="req">Hàng theo PO</span>
                  <select className="inp inp-y" value={l.po_line_id} onChange={(e) => set(l.key, { po_line_id: e.target.value })}>
                    {po.lines.map((pl) => <option key={pl.id} value={pl.id}>{pl.material_code} · {pl.material_name} (còn {(pl.qty - pl.received_qty).toLocaleString('vi-VN')} {pl.uom})</option>)}
                  </select></label>
              ) : (
                <label className="lbl lg:col-span-2"><span className="req">Vật tư</span>
                  <select className="inp inp-y" value={l.material_code} onChange={(e) => set(l.key, { material_code: e.target.value })}>
                    <option value="">Chọn vật tư</option>
                    {mats.map((x) => <option key={x.code} value={x.code}>{x.code} · {x.name}</option>)}
                  </select></label>
              )}
              <label className="lbl">Lô NCC<input className="inp" value={l.supplier_lot} onChange={(e) => set(l.key, { supplier_lot: e.target.value })} /></label>
              <label className="lbl">Ngày sản xuất<input className="inp" type="date" value={l.mfg_date} onChange={(e) => set(l.key, { mfg_date: e.target.value })} /></label>
              <label className="lbl"><span className={m?.has_expiry ? 'req' : ''}>Hạn dùng</span>
                <input className={`inp ${m?.has_expiry ? 'inp-y' : ''}`} type="date" value={l.exp_date} required={m?.has_expiry} onChange={(e) => set(l.key, { exp_date: e.target.value })} /></label>
              <label className="lbl">Cất vào
                <select className="inp" value={l.location_id} onChange={(e) => set(l.key, { location_id: e.target.value })}>
                  <option value="">Chờ kiểm (KNL-QC)</option>
                  {locations.map((x) => <option key={x.id} value={x.id}>{x.code} · {x.name}</option>)}
                </select></label>
              {isKg && <label className="lbl lg:col-span-2">Loại ống/bao (để trừ bì)
                <select className="inp" value={l.package_type_id} onChange={(e) => set(l.key, { package_type_id: e.target.value })}>
                  <option value="">Không trừ bì / nhập bì từng đơn vị</option>
                  {packages.map((p) => <option key={p.id} value={p.id}>{p.code} · {p.name} – bì {p.tare_kg.toLocaleString('vi-VN')} kg</option>)}
                </select></label>}
              <label className="lbl">Tỷ trọng trên COA<input className="inp" inputMode="decimal" value={l.coa_density} onChange={(e) => set(l.key, { coa_density: e.target.value })} /></label>
            </div>
            <div className="border-t border-line px-4 py-3">
              <div className="mb-2 text-[13px] text-muted">Từng {isKg ? 'ống/bao/cuộn: cân tổng (kg) và bì, hoặc nhập thẳng kg tịnh' : `đơn vị: số lượng (${m?.uom ?? ''})`} – mỗi dòng in một tem QR</div>
              <div className="flex flex-col gap-2">
                {l.units.map((u, j) => (
                  <div key={j} className="flex flex-wrap items-end gap-2">
                    <span className="w-8 text-[13px] text-muted">#{j + 1}</span>
                    {isKg && <label className="lbl">Cân tổng (kg)<input className="inp inp-y w-28 text-right" inputMode="decimal" value={u.gross}
                      onChange={(e) => set(l.key, { units: l.units.map((x, k) => (k === j ? { ...x, gross: e.target.value } : x)) })} /></label>}
                    {isKg && <label className="lbl">Bì (kg)<input className="inp w-24 text-right" inputMode="decimal" value={u.tare} placeholder="theo loại"
                      onChange={(e) => set(l.key, { units: l.units.map((x, k) => (k === j ? { ...x, tare: e.target.value } : x)) })} /></label>}
                    {(!isKg || !u.gross.trim()) && <label className="lbl">{isKg ? 'hoặc kg tịnh' : 'Số lượng'}<input className="inp inp-y w-28 text-right" inputMode="decimal" value={u.qty}
                      onChange={(e) => set(l.key, { units: l.units.map((x, k) => (k === j ? { ...x, qty: e.target.value } : x)) })} /></label>}
                    <span className="pb-2 text-[13.5px]">= <b>{Number.isNaN(net(l, u)) ? '—' : net(l, u).toLocaleString('vi-VN', { maximumFractionDigits: 3 })}</b> {m?.uom}</span>
                    {l.units.length > 1 && <button type="button" className="btn btn-sm mb-1" aria-label="Bỏ đơn vị" onClick={() => set(l.key, { units: l.units.filter((_, k) => k !== j) })}><Trash2 size={14} /></button>}
                  </div>
                ))}
              </div>
              <div className="mt-2 flex flex-wrap items-center gap-3">
                <button type="button" className="btn btn-sm" onClick={() => set(l.key, { units: [...l.units, { ...blankUnit(), tare: l.units.at(-1)?.tare ?? '' }] })}><Plus size={14} />Thêm ống/bao</button>
                <span className="text-[14px]">Tổng dòng: <b>{total.toLocaleString('vi-VN', { maximumFractionDigits: 3 })} {m?.uom}</b> · {l.units.length} đơn vị</span>
              </div>
            </div>
          </section>
        );
      })}
      <input type="hidden" name="lines" value={payload} />
      <div className="flex flex-wrap gap-2">
        <button type="button" className="btn" onClick={() => setLines((x) => [...x, newLine()])}><Plus size={16} />Thêm dòng hàng</button>
        {lines.length > 0 && <SubmitButton>Ghi phiếu nhập và in tem</SubmitButton>}
      </div>
    </form>
  );
}
