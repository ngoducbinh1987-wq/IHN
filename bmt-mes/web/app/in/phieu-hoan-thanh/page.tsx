import { Fragment } from 'react';
import { notFound } from 'next/navigation';
import { PrintButton } from '@/components/print-button';
import { df } from '@/lib/format';
import { qcTestsFor } from '@/lib/qc';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'In phiếu hoàn thành bobin' };

const OUT_STAGE: Record<string, string> = { CD0: 'MX', CD1: 'CB', CD2: 'LB', CD3: 'BL', CD4: 'BS', CD5: 'CV' };

// Phiếu hoàn thành bobin in sẵn phần đầu (lô, mã, công đoạn, máy, ngày): mỗi bobin một phiếu, 2 phiếu một trang A4
export default async function PrintSlips({ searchParams }: { searchParams: Promise<{ muc?: string; n?: string; ngay?: string }> }) {
  const sp = await searchParams;
  await requireMe();
  const supabase = await createClient();
  const { data: t } = await supabase.schema('app').from('v_slip_targets').select('*').eq('wo_op_id', sp.muc ?? '').maybeSingle();
  if (!t) notFound();
  const n = Math.min(Math.max(Number(sp.n) || 6, 1), 40);
  const day = /^\d{4}-\d{2}-\d{2}$/.test(sp.ngay ?? '') ? sp.ngay! : new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Ho_Chi_Minh' });
  const isCd1 = t.op_code === 'CD1';
  const isCd6 = t.op_code === 'CD6';
  const tests = qcTestsFor(isCd6 ? 'FG' : 'WIP', OUT_STAGE[t.op_code] ?? null);
  const cell = '[&_td]:border [&_td]:border-ink/50 [&_td]:px-2 [&_td]:py-1.5 [&_th]:border [&_th]:border-ink/50 [&_th]:bg-sunk [&_th]:px-2 [&_th]:py-1 [&_th]:text-left [&_th]:font-medium';
  return (
    <main className="mx-auto max-w-[820px] bg-white p-4 text-[12.5px] text-ink print:p-0">
      <div className="mb-3 flex items-center justify-between gap-3 print:hidden">
        <div>Phiếu trống cho {t.wo_no} · {t.op_code} {t.op_name} · {n} phiếu (đổi số phiếu: thêm <span className="mono">&amp;n=10</span> vào địa chỉ)</div>
        <PrintButton />
      </div>
      {Array.from({ length: n }, (_, i) => (
        <section key={i} className={`mb-4 border border-ink/60 p-3 ${i % 2 === 1 ? 'break-after-page' : ''}`}>
          <div className="mb-2 flex items-start justify-between">
            <div>
              <div className="text-[15px] font-medium">PHIẾU HOÀN THÀNH BOBIN</div>
              <div>Lô (lệnh SX) <b className="mono">{t.wo_no}</b> · Mã <b>{t.product_code}</b> · {t.op_code} {t.op_name}</div>
              <div>Máy: <b>{t.machine_code ?? '…………'}</b> · Ngày {df(day)}{t.op_code === 'CD2' ? ` · Màu lõi: ${t.insulation_colors ?? '……'}` : ['CD5', 'CD6'].includes(t.op_code) ? ` · Màu vỏ: ${t.sheath_color ?? '……'}` : ''}</div>
            </div>
            <div className="text-right text-[11px] text-muted">BMT MES<br />Số phiếu ……</div>
          </div>
          <table className={`w-full border-collapse ${cell}`}>
            <tbody>
              <tr><td className="w-[32%]">Số bobin (số cố định)</td><td className="w-[18%]" /><td className="w-[22%]">Người làm (họ tên, ký)</td><td /></tr>
              <tr><td>Giờ bắt đầu</td><td /><td>Giờ hoàn thành</td><td /></tr>
              <tr><td>Khối lượng cân (kg)</td><td /><td>{isCd6 ? 'Chiều dài cuộn (m)' : isCd1 ? 'Số mét' : 'Đồng hồ mét: đầu → cuối'}</td>
                <td className={isCd1 ? 'text-muted' : ''}>{isCd1 ? 'Không cần: lấy ở line đùn' : isCd6 ? '' : '………… → …………'}</td></tr>
              {!isCd1 && <tr><td>Bobin đầu vào (chỉ bobin có tem QC PASS)</td><td colSpan={3}>Số bobin: …………… dư …… kg · …………… dư …… kg · …………… dư …… kg</td></tr>}
              <tr><td>Chủng loại, số lô NVL đã dùng</td><td colSpan={3} /></tr>
              <tr><td>Phế của bobin (kg, lý do)</td><td colSpan={3}>…… kg · lý do: khởi động / đứt / sai kích thước / ……</td></tr>
              {(t.op_code === 'CD2' || t.op_code === 'CD5') && <tr><td>Số đọc trên chuyền</td><td colSpan={3}>Cao áp báo lỗi …… lần · OD …… mm</td></tr>}
            </tbody>
          </table>
          <table className={`mt-2 w-full border-collapse ${cell}`}>
            <thead><tr><th colSpan={4}>Phần QC (kiểm mỗi bobin; dòng có * kiểm theo tần suất)</th></tr></thead>
            <tbody>
              {Array.from({ length: Math.ceil(tests.length / 2) }, (_, r) => (
                <tr key={r}>
                  {[tests[r * 2], tests[r * 2 + 1]].map((q, k) => (
                    <Fragment key={k}>
                      <td className="w-[30%]">{q ? `${q.label}${q.unit ? ` (${q.unit})` : ''}${q.periodic ? ' *' : ''}` : ''}</td>
                      <td className="w-[20%]">{q?.kind === 'pf' ? '☐ Đạt ☐ Không' : ''}</td>
                    </Fragment>
                  ))}
                </tr>
              ))}
              <tr><td>Kết luận</td><td>☐ Đạt (tem xanh) ☐ Không đạt (tem đỏ)</td><td>QC ký, giờ</td><td /></tr>
            </tbody>
          </table>
        </section>
      ))}
      <div className="text-[11px] text-muted print:hidden">In lúc {df(new Date().toISOString(), true)} từ BMT MES</div>
    </main>
  );
}
