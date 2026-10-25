'use client';

import { Camera, ScanLine, Trash2, X } from 'lucide-react';
import { useEffect, useRef, useState } from 'react';
import { lookupHu, lookupLocation, type HuInfo, type LocInfo } from '@/app/(app)/kho/lookup';

type Detector = { detect: (src: CanvasImageSource) => Promise<{ rawValue: string }[]> };
declare global {
  interface Window { BarcodeDetector?: new (opts: { formats: string[] }) => Detector }
}

// Quét QR bằng camera điện thoại/tablet (Chrome Android có sẵn BarcodeDetector)
function CameraScan({ onCode, onClose }: { onCode: (code: string) => void; onClose: () => void }) {
  const video = useRef<HTMLVideoElement>(null);
  const [msg, setMsg] = useState('Đưa tem QR vào khung hình');
  useEffect(() => {
    let stream: MediaStream | null = null;
    let timer: ReturnType<typeof setInterval> | null = null;
    let done = false;
    (async () => {
      if (!window.BarcodeDetector) { setMsg('Trình duyệt chưa hỗ trợ quét bằng camera. Dùng máy quét cầm tay hoặc gõ mã.'); return; }
      try {
        stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' }, audio: false });
        if (!video.current) return;
        video.current.srcObject = stream;
        await video.current.play();
        const det = new window.BarcodeDetector({ formats: ['qr_code'] });
        timer = setInterval(async () => {
          if (done || !video.current || video.current.readyState < 2) return;
          try {
            const r = await det.detect(video.current);
            if (r[0]?.rawValue && !done) { done = true; onCode(r[0].rawValue); }
          } catch { /* khung hình chưa sẵn sàng */ }
        }, 250);
      } catch {
        setMsg('Không mở được camera. Cho phép quyền camera hoặc dùng máy quét.');
      }
    })();
    return () => { done = true; if (timer) clearInterval(timer); stream?.getTracks().forEach((t) => t.stop()); };
  }, [onCode]);
  return (
    <div className="fixed inset-0 z-50 flex flex-col bg-black/90 p-4" role="dialog" aria-label="Quét mã QR">
      <div className="mb-3 flex items-center justify-between text-white">
        <span className="text-[15px]">{msg}</span>
        <button type="button" className="btn btn-sm" onClick={onClose}><X size={16} />Đóng</button>
      </div>
      <video ref={video} className="mx-auto max-h-[70vh] w-full max-w-[640px] rounded bg-black object-contain" playsInline muted />
    </div>
  );
}

// Ô quét: máy quét cầm tay (gõ chuỗi + Enter), gõ tay, hoặc camera
export function ScanInput({ onCode, placeholder = 'Quét hoặc gõ mã QR rồi Enter', name, autoFocus = true, defaultValue, submitOnScan }:
  { onCode?: (code: string) => void; placeholder?: string; name?: string; autoFocus?: boolean; defaultValue?: string; submitOnScan?: boolean }) {
  const ref = useRef<HTMLInputElement>(null);
  const [cam, setCam] = useState(false);
  const fire = (code: string) => {
    if (!code.trim()) return;
    if (onCode) { onCode(code.trim()); if (ref.current) ref.current.value = ''; }
    else if (ref.current) { ref.current.value = code.trim(); if (submitOnScan) ref.current.form?.requestSubmit(); }
  };
  return (
    <div className="flex gap-2">
      <div className="relative flex-1">
        <ScanLine size={18} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-muted" />
        <input ref={ref} name={name} defaultValue={defaultValue} className="inp h-11 pl-10 font-mono text-[15px]" placeholder={placeholder} autoFocus={autoFocus}
          autoComplete="off" autoCapitalize="characters" spellCheck={false} aria-label={placeholder}
          onKeyDown={(e) => { if (e.key === 'Enter' && onCode) { e.preventDefault(); fire(e.currentTarget.value); } }} />
      </div>
      <button type="button" className="btn h-11" onClick={() => setCam(true)} aria-label="Quét bằng camera"><Camera size={18} /><span className="hidden sm:inline">Camera</span></button>
      {cam && <CameraScan onClose={() => setCam(false)} onCode={(c) => { setCam(false); fire(c); }} />}
    </div>
  );
}

export type Picked = HuInfo & { pickQty: string; reason: string };

// Danh sách đơn vị chứa đã quét (cấp NVL, xuất giao, bán phế…) → trường ẩn JSON cho server action
export function ScanList({ name, warehouse, kinds, withQty = false, withReason = false, qtyLabel = 'Số lượng xuất', allowed, onlyActive = true, hint }:
  { name: string; warehouse?: string; kinds?: string[]; withQty?: boolean; withReason?: boolean; qtyLabel?: string;
    allowed?: string[]; onlyActive?: boolean; hint?: string }) {
  const [items, setItems] = useState<Picked[]>([]);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const add = async (code: string) => {
    setErr(null); setBusy(true);
    const r = await lookupHu(code);
    setBusy(false);
    if (!r.hu) { setErr(r.error ?? 'Không tìm thấy'); return; }
    const h = r.hu;
    if (items.some((x) => x.id === h.id)) { setErr(`${h.hu_no} đã quét rồi`); return; }
    if (onlyActive && h.status !== 'ACTIVE') { setErr(`${h.hu_no} không còn hàng`); return; }
    if (warehouse && h.warehouse_code !== warehouse) { setErr(`${h.hu_no} đang ở ${h.warehouse_code ?? 'ngoài kho'}, không thuộc ${warehouse}`); return; }
    if (kinds && !kinds.includes(h.item_kind)) { setErr(`${h.hu_no} (${h.item_code}) không đúng loại hàng`); return; }
    if (allowed && !allowed.includes(h.item_code)) { setErr(`${h.hu_no} là ${h.item_code}: không có trong danh sách cần xuất`); return; }
    setItems((x) => [...x, { ...h, pickQty: '', reason: '' }]);
  };
  const set = (id: string, patch: Partial<Picked>) => setItems((x) => x.map((i) => (i.id === id ? { ...i, ...patch } : i)));
  // Số lượng gửi dạng chữ; server đọc theo kiểu Việt Nam (parseNum) và báo lỗi nếu sai
  const payload = JSON.stringify(items.map((i) => ({ hu_id: i.id, qty_text: i.pickQty.trim(), reason: i.reason.trim() || null })));
  return (
    <div className="flex flex-col gap-2">
      <ScanInput onCode={add} />
      {hint && <p className="text-[12.5px] text-muted">{hint}</p>}
      {busy && <p className="text-[13px] text-muted">Đang tra mã…</p>}
      {err && <p role="alert" className="rounded border-l-4 border-bad bg-bad-soft px-3 py-2 text-[13.5px] text-bad">{err}</p>}
      <input type="hidden" name={name} value={payload} />
      {items.length > 0 && (
        <div className="overflow-x-auto rounded border border-line">
          <table className="tbl">
            <thead><tr><th>Mã QR</th><th>Hàng</th><th>Lô</th><th className="num">Còn</th>{withQty && <th>{qtyLabel}</th>}{withReason && <th>Lý do đổi lô (nếu có)</th>}<th /></tr></thead>
            <tbody>
              {items.map((i) => (
                <tr key={i.id}>
                  <td className="mono font-medium">{i.hu_no}</td>
                  <td className="min-w-[140px]"><span className="mono">{i.item_code}</span> · {i.item_name}</td>
                  <td className="mono">{i.lot_no}</td>
                  <td className="num">{(i.qty - i.reserved_qty).toLocaleString('vi-VN')} {i.uom}</td>
                  {withQty && <td><input className="inp inp-y w-28 text-right" inputMode="decimal" placeholder="Cả đơn vị" value={i.pickQty}
                    onChange={(e) => set(i.id, { pickQty: e.target.value })} aria-label={`${qtyLabel} ${i.hu_no}`} /></td>}
                  {withReason && <td><input className="inp w-48" value={i.reason} onChange={(e) => set(i.id, { reason: e.target.value })} aria-label={`Lý do ${i.hu_no}`} /></td>}
                  <td><button type="button" className="btn btn-sm btn-bad-o" onClick={() => setItems((x) => x.filter((y) => y.id !== i.id))} aria-label={`Bỏ ${i.hu_no}`}><Trash2 size={14} /></button></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <p className="text-[12.5px] text-muted">Đã quét {items.length} đơn vị.</p>
    </div>
  );
}

// Một mã QR + một vị trí (chuyển vị trí, kiểm kê)
export function ScanOne({ name, label = 'Mã QR', onFound, initial, autoFocus = true }: { name: string; label?: string; onFound?: (h: HuInfo) => void; initial?: string; autoFocus?: boolean }) {
  const [hu, setHu] = useState<HuInfo | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const find = async (c: string) => { setErr(null); const r = await lookupHu(c); if (r.hu) { setHu(r.hu); onFound?.(r.hu); } else { setHu(null); setErr(r.error ?? 'Không tìm thấy'); } };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { if (initial) void find(initial); }, [initial]);
  return (
    <div className="flex flex-col gap-1.5">
      <span className="text-[13px] text-muted">{label}</span>
      <ScanInput autoFocus={autoFocus && !initial} onCode={find} />
      <input type="hidden" name={name} value={hu?.id ?? ''} />
      {err && <p role="alert" className="text-[13px] text-bad">{err}</p>}
      {hu && (
        <div className="rounded border border-line bg-sunk/50 px-3 py-2 text-[13.5px]">
          <b className="mono">{hu.hu_no}</b> · <span className="mono">{hu.item_code}</span> {hu.item_name}<br />
          Còn {hu.qty.toLocaleString('vi-VN')} {hu.uom} · {hu.warehouse_code ?? '—'} / {hu.location_code ?? '—'} · lô {hu.lot_no}
        </div>
      )}
    </div>
  );
}

export function ScanLocation({ name, warehouse }: { name: string; warehouse?: string }) {
  const [loc, setLoc] = useState<LocInfo | null>(null);
  const [err, setErr] = useState<string | null>(null);
  return (
    <div className="flex flex-col gap-1.5">
      <span className="text-[13px] text-muted">Vị trí mới (quét tem vị trí hoặc gõ mã, ví dụ KNL-CU)</span>
      <ScanInput autoFocus={false} placeholder="Quét tem vị trí" onCode={async (c) => {
        setErr(null); const r = await lookupLocation(c);
        if (r.loc && warehouse && r.loc.warehouse_code !== warehouse) { setLoc(null); setErr(`${r.loc.code} thuộc ${r.loc.warehouse_code}, không thuộc ${warehouse}`); return; }
        if (r.loc) setLoc(r.loc); else { setLoc(null); setErr(r.error ?? 'Không có vị trí'); }
      }} />
      <input type="hidden" name={name} value={loc?.id ?? ''} />
      {err && <p role="alert" className="text-[13px] text-bad">{err}</p>}
      {loc && <div className="rounded border border-line bg-brand-soft px-3 py-2 text-[13.5px]"><b className="mono">{loc.code}</b> · {loc.name} ({loc.warehouse_code})</div>}
    </div>
  );
}
