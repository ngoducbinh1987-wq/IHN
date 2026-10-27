import { notFound } from 'next/navigation';
import { PrintButton } from '@/components/print-button';
import { df, nf } from '@/lib/format';
import { requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'In kế hoạch' };

// Bản in kế hoạch sản xuất: quy cách đóng gói, số kiện chẵn + kiện lẻ
export default async function PrintPlan({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  await requirePerm('plan', 'view');
  const supabase = await createClient();
  const { data: plan } = await supabase.schema('app').from('v_plans').select('*').eq('id', id).maybeSingle();
  if (!plan) notFound();
  const { data: lines } = await supabase.schema('app').from('v_plan_lines').select('*').eq('plan_id', id).order('product_code');
  return (
    <main className="mx-auto max-w-[1100px] bg-white p-6 text-[13px] text-ink print:p-0">
      <div className="mb-4 flex items-start justify-between gap-4">
        <div>
          <img src="/logo-bmt.png" alt="BMTcable" className="mb-2 h-10 w-auto" />
          <h1 className="text-[20px] font-medium">KẾ HOẠCH SẢN XUẤT {plan.plan_no}</h1>
          <div>{plan.period_label} · Ngày cần vật tư: {df(plan.material_need_date)}{plan.mrp_stale ? ' · MRP cần tính lại' : ''}</div>
        </div>
        <PrintButton />
      </div>
      <table className="w-full border-collapse [&_td]:border [&_td]:border-ink/40 [&_td]:px-2 [&_td]:py-1 [&_th]:border [&_th]:border-ink/40 [&_th]:bg-sunk [&_th]:px-2 [&_th]:py-1">
        <thead><tr><th>STT</th><th>SKU</th><th>Quy cách</th><th>Sản lượng (m)</th><th>Số lô</th><th>Đóng gói</th><th>m/kiện</th><th>Kiện chẵn</th><th>Kiện lẻ</th><th>Tổng kiện</th><th>kg/kiện</th><th>TH</th></tr></thead>
        <tbody>
          {(lines ?? []).map((l, i) => (
            <tr key={l.id}>
              <td className="text-center">{i + 1}</td><td className="font-medium">{l.product_code}</td><td>{l.description}</td>
              <td className="text-right">{nf(l.qty_m)}</td><td className="text-right">{l.run_lots}</td><td>{l.pack_type}</td>
              <td className="text-right">{nf(l.m_per_pack)}</td><td className="text-right">{nf(l.full_packs)}</td>
              <td className="text-right">{Number(l.odd_m) > 0 ? `1 × ${nf(l.odd_m)} m` : '—'}</td>
              <td className="text-right font-medium">{nf(l.packs)}</td><td className="text-right">{nf(l.kg_per_pack, 1)}</td><td>{l.brand}</td>
            </tr>
          ))}
          <tr className="font-medium"><td colSpan={3} className="text-right">Tổng</td><td className="text-right">{nf(plan.total_m)}</td><td colSpan={5} /><td className="text-right">{nf(plan.total_packs)}</td><td colSpan={2} /></tr>
        </tbody>
      </table>
      <div className="mt-10 grid grid-cols-3 text-center">
        <div><b>Người lập</b><div className="text-muted">(ký, ghi rõ họ tên)</div></div>
        <div><b>Duyệt</b></div><div><b>Phê duyệt</b></div>
      </div>
      <div className="mt-6 text-[11px] text-muted">In lúc {df(new Date().toISOString(), true)} từ BMT MES</div>
    </main>
  );
}
