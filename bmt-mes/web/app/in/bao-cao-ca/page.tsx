import { PrintButton } from '@/components/print-button';
import { df, nf } from '@/lib/format';
import { loadKh } from '@/lib/kh/load';
import { DT_REASONS, shiftLines } from '@/lib/kh/shift';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'In báo cáo ca' };

// Tờ báo cáo ca (mỗi máy mỗi ca một tờ) in sẵn máy, ngày, việc theo lịch máy; công nhân ghi, Kế toán SX nhập vào MES
export default async function PrintShift({ searchParams }: { searchParams: Promise<{ d?: string; m?: string; s?: string }> }) {
  const sp = await searchParams;
  const me = await requireMe();
  const db = await createClient();
  const kh = await loadKh(db, { roles: me.roles });
  const date = /^\d{4}-\d{2}-\d{2}$/.test(sp.d ?? '') ? sp.d! : kh.now.date;
  const shift = kh.cal.shifts.find((x) => x.code === sp.s)?.code ?? kh.cal.shifts[0]?.code ?? 'A';
  const machines = kh.machines.filter((m) => !sp.m || m.code === sp.m);
  const cell = '[&_td]:border [&_td]:border-ink/50 [&_td]:px-2 [&_td]:py-1.5 [&_th]:border [&_th]:border-ink/50 [&_th]:bg-sunk [&_th]:px-2 [&_th]:py-1 [&_th]:text-left [&_th]:font-medium';
  const blank = (n: number, cols: number) => Array.from({ length: n }, (_, i) => <tr key={i}>{Array.from({ length: cols }, (_, j) => <td key={j}>&nbsp;</td>)}</tr>);

  return (
    <main className="mx-auto max-w-[820px] bg-white p-4 text-[12.5px] text-ink print:p-0">
      <div className="mb-3 flex items-center justify-between gap-3 print:hidden">
        <div>Báo cáo ca ngày {df(date)} · ca {shift} · {machines.length} máy (một máy: thêm <span className="mono">&amp;m=BUN-01</span>)</div>
        <PrintButton />
      </div>
      {machines.map((m) => {
        const plan = shiftLines(kh, date, m.code, shift);
        return (
          <section key={m.code} className="mb-4 break-after-page border border-ink/60 p-3">
            <div className="mb-2 flex items-start justify-between">
              <div>
                <div className="text-[15px] font-medium">BÁO CÁO CA</div>
                <div>Máy <b>{m.code}</b> · {m.name} · Ngày <b>{df(date)}</b> · Ca {shift}</div>
                <div className="text-[11.5px]">Việc theo lịch máy: {plan.length ? plan.map((l) => `${l.label} ${l.product_code}${l.color ? ' ' + l.color : ''} ${nf(l.planned_m)} m`).join(' · ') : 'không có'}</div>
              </div>
              <div className="text-right text-[11px] text-muted">BMT MES<br />Người đứng máy ……</div>
            </div>
            <table className={`w-full border-collapse ${cell}`}>
              <thead><tr><th colSpan={6}>Các bobin đã làm (số bobin; MES tự cộng sản lượng từ phiếu hoàn thành)</th></tr></thead>
              <tbody>{blank(2, 6)}</tbody>
            </table>
            <table className={`mt-2 w-full border-collapse ${cell}`}>
              <thead><tr><th className="w-[16%]">Dừng lúc</th><th className="w-[16%]">Chạy lại lúc</th><th>Lý do ({Object.values(DT_REASONS).join(', ')}…)</th></tr></thead>
              <tbody>{blank(4, 3)}</tbody>
            </table>
            <table className={`mt-2 w-full border-collapse ${cell}`}>
              <thead><tr><th>NVL thừa: vật tư (mã tem)</th><th className="w-[14%]">kg cân</th><th className="w-[30%]">☐ Trả kho / ☐ Để lại máy chạy tiếp cùng lô</th></tr></thead>
              <tbody>{blank(3, 3)}</tbody>
            </table>
            <table className={`mt-2 w-full border-collapse ${cell}`}>
              <thead><tr><th>Phế cả ca chưa ghi trên phiếu bobin: lý do (khởi động, xả nhựa, đổi màu…)</th><th className="w-[14%]">kg</th><th className="w-[30%]">Lô (lệnh SX)</th></tr></thead>
              <tbody>{blank(3, 3)}</tbody>
            </table>
            <p className="mt-1 text-[11px] text-muted">Phế đồng để thùng riêng. Cuộn đồng trên giá xả, nhựa trong phễu chỉ để lại khi ngày mai chạy tiếp cùng lô.</p>
            <div className="mt-3 grid grid-cols-2 gap-4 text-center text-[12px]">
              {['Công nhân', 'TP SX chốt ca'].map((x) => <div key={x}><b>{x}</b><div className="text-muted">(ký, ghi rõ họ tên)</div><div className="h-12" /></div>)}
            </div>
          </section>
        );
      })}
    </main>
  );
}
