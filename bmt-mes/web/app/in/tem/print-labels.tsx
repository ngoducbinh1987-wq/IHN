'use client';

import { Printer } from 'lucide-react';
import { useState, useTransition } from 'react';
import { markPrinted } from './actions';

// Nút in tem đơn vị: ghi nhận lần in trước rồi mở hộp thoại in của trình duyệt
export function PrintLabels({ ids, reprint }: { ids: string[]; reprint: number }) {
  const [reason, setReason] = useState('');
  const [err, setErr] = useState('');
  const [pending, start] = useTransition();
  const go = () => {
    setErr('');
    if (reprint > 0 && !reason.trim()) { setErr('Có tem đã in trước đó: nhập lý do in lại (tem rách, mờ, dán nhầm…)'); return; }
    start(async () => {
      const r = await markPrinted(ids, reason);
      if (r.error) setErr(r.error);
      else window.print();
    });
  };
  return (
    <div className="flex flex-wrap items-center gap-2 print:hidden">
      {reprint > 0 && (
        <input className="inp inp-y w-72" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Lý do in lại" aria-label="Lý do in lại" />
      )}
      <button type="button" className="btn btn-pri" onClick={go} disabled={pending}><Printer size={16} />{pending ? 'Đang ghi nhận…' : `In ${ids.length} tem`}</button>
      {err && <span role="alert" className="text-[13px] text-bad">{err}</span>}
    </div>
  );
}
