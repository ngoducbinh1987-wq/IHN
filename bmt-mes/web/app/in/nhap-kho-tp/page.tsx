import { PrintButton } from '@/components/print-button';
import { df, nf } from '@/lib/format';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { kindLabel, type FgGroup } from '../../(app)/kho/xuat-ban/items-fields';

export const metadata = { title: 'In phiếu nhập kho thành phẩm' };

// Phiếu nhập kho thành phẩm: danh sách cuộn QC Đạt đang ở khu chờ QC; người giữ kho TP đếm, ghi số cuộn thực nhập, ký; Kế toán SX nhập vào MES
export default async function PrintPutaway() {
  await requireMe();
  const supabase = await createClient();
  const [{ data: groups }, { data: keepers }] = await Promise.all([
    supabase.schema('app').from('v_fg_stock').select('*').gt('putaway_coils', 0).order('product_code').returns<FgGroup[]>(),
    supabase.schema('app').rpc('fg_keepers'),
  ]);
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Ho_Chi_Minh' });
  const kp = ((keepers ?? []) as { code: string; full_name: string | null }[]).map((k) => `${k.code}${k.full_name ? ` · ${k.full_name}` : ''}`).join(', ');
  return (
    <main className="mx-auto max-w-[900px] bg-white p-8 text-ink print:p-0">
      <style>{'@page { size: A4; margin: 12mm } @media print { html, body { background: #fff } }'}</style>
      <div className="mb-4 flex items-center justify-between print:hidden">
        <p className="text-[13px] text-muted">In phiếu, người giữ kho thành phẩm đếm cuộn có tem QC PASS, ghi số cuộn thực nhập, ký; Kế toán SX nhập ở Kho → Thành phẩm.</p>
        <PrintButton />
      </div>
      <div className="flex items-start justify-between border-b border-ink pb-2">
        <img src="/logo-bmt.png" alt="BMTcable" className="h-8 w-auto" />
        <div className="text-right text-[12px]">Số phiếu giấy: ..................<br />Ngày: {df(today)}</div>
      </div>
      <h1 className="my-4 text-center text-[20px] font-bold">PHIẾU NHẬP KHO THÀNH PHẨM</h1>
      <p className="mb-3 text-[13px]">Cuộn đã QC Đạt (tem QC PASS) chuyển từ khu chờ QC vào khu lưu kho. Người giữ kho thành phẩm: {kp || '..............................'}</p>
      <table className="w-full border-collapse text-[13px] [&_td]:border [&_td]:border-ink [&_td]:px-2 [&_td]:py-1.5 [&_th]:border [&_th]:border-ink [&_th]:px-2 [&_th]:py-1.5">
        <thead><tr><th>#</th><th className="text-left">Chủng loại (mã · nhãn · quy cách)</th><th>Số cuộn QC Đạt (MES)</th><th>Mét (MES)</th><th>Số cuộn thực nhập</th><th>Vị trí cất</th></tr></thead>
        <tbody>
          {(groups ?? []).map((g, i) => (
            <tr key={`${g.product_code}|${g.brand}|${g.pack_m}`}><td className="text-center">{i + 1}</td><td>{kindLabel(g.product_code, g.brand, g.pack_m)}</td>
              <td className="text-center">{g.putaway_coils}</td><td className="text-right">{nf(g.putaway_m)}</td><td /><td /></tr>
          ))}
          {Array.from({ length: Math.max(0, 6 - (groups ?? []).length) }, (_, i) => <tr key={`b${i}`}><td>&nbsp;</td><td /><td /><td /><td /><td /></tr>)}
        </tbody>
      </table>
      <div className="mt-12 grid grid-cols-3 text-center text-[13px]">
        <div><b>Người giữ kho thành phẩm</b><br />(ký, ghi rõ họ tên)</div><div><b>QC</b><br />(ký)</div><div><b>Kế toán SX</b><br />(đã nhập MES)</div>
      </div>
    </main>
  );
}
