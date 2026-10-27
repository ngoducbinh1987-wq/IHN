import { PrintButton } from '@/components/print-button';
import { df, nf } from '@/lib/format';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'In phiếu xuất NVL theo lô' };

type Req = { id: string; req_no: string; status: string; work_date: string; note: string | null; wo_no: string; product_code: string; product_name: string };
type Line = { req_id: string; material_id: string; material_code: string; material_name: string; uom: string; qty_req: number; remaining: number };
type Pick = { hu_no: string; material_id: string; lot_no: string; available: number; location_code: string | null; pick_order: number };

// Phiếu xuất NVL theo lô (mỗi lô một phiếu) + phiếu nhập NVL thừa cuối ngày; Kế toán SX in 16:00–17:00 hôm trước
export default async function PrintIssue({ searchParams }: { searchParams: Promise<{ d?: string; req?: string }> }) {
  const sp = await searchParams;
  await requireMe();
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Ho_Chi_Minh' });
  const day = /^\d{4}-\d{2}-\d{2}$/.test(sp.d ?? '') ? sp.d! : today;
  const supabase = await createClient();
  let q = supabase.schema('app').from('v_requisitions').select('id, req_no, status, work_date, note, wo_no, product_code, product_name')
    .eq('work_date', day).in('status', ['APPROVED', 'PARTIAL']).order('wo_no');
  if (sp.req) q = q.eq('id', sp.req);
  const { data: reqs } = await q.returns<Req[]>();
  const ids = (reqs ?? []).map((r) => r.id);
  const { data: lines } = ids.length
    ? await supabase.schema('app').from('v_requisition_lines').select('req_id, material_id, material_code, material_name, uom, qty_req, remaining')
        .in('req_id', ids).gt('remaining', 0).order('material_code').returns<Line[]>()
    : { data: [] as Line[] };
  const mats = [...new Set((lines ?? []).map((l) => l.material_id))];
  const { data: picks } = mats.length
    ? await supabase.schema('app').from('v_pick_suggest').select('hu_no, material_id, lot_no, available, location_code, pick_order')
        .in('material_id', mats).lte('pick_order', 8).order('pick_order').returns<Pick[]>()
    : { data: [] as Pick[] };
  // Gợi ý theo thứ tự xuất trước đến khi đủ số cần
  const suggest = (l: Line) => {
    let need = l.remaining;
    const out: Pick[] = [];
    for (const p of (picks ?? []).filter((x) => x.material_id === l.material_id)) {
      if (need <= 0) break;
      out.push(p);
      need -= p.available;
    }
    return out;
  };
  const cell = '[&_td]:border [&_td]:border-ink/50 [&_td]:px-2 [&_td]:py-1.5 [&_th]:border [&_th]:border-ink/50 [&_th]:bg-sunk [&_th]:px-2 [&_th]:py-1 [&_th]:text-left [&_th]:font-medium';
  const sign = (a: string, b: string, c?: string) => (
    <div className={`mt-3 grid ${c ? 'grid-cols-3' : 'grid-cols-2'} gap-4 text-center text-[12px]`}>
      {[a, b, c].filter(Boolean).map((x) => <div key={x}><b>{x}</b><div className="text-muted">(ký, ghi rõ họ tên)</div><div className="h-12" /></div>)}
    </div>
  );

  return (
    <main className="mx-auto max-w-[820px] bg-white p-4 text-[12.5px] text-ink print:p-0">
      <div className="mb-3 flex items-center justify-between gap-3 print:hidden">
        <div>Ngày sản xuất {df(day)} · {(reqs ?? []).length} lô · mỗi lô một phiếu xuất và một phiếu nhập NVL thừa</div>
        <PrintButton />
      </div>
      {(reqs ?? []).length === 0 && <p>Ngày {df(day)} không có phiếu lĩnh cần xuất.</p>}
      {(reqs ?? []).map((r) => {
        const ls = (lines ?? []).filter((l) => l.req_id === r.id);
        return (
          <div key={r.id}>
            <section className="mb-4 border border-ink/60 p-3">
              <div className="mb-2 flex items-start justify-between">
                <div>
                  <div className="text-[15px] font-medium">PHIẾU XUẤT NGUYÊN VẬT LIỆU THEO LÔ</div>
                  <div>Lô (lệnh SX) <b className="mono">{r.wo_no}</b> · Mã <b>{r.product_code}</b> · Ngày sản xuất <b>{df(r.work_date)}</b></div>
                  {r.note && <div className="text-[11.5px] text-muted">{r.note}</div>}
                </div>
                <div className="text-right text-[11px] text-muted">BMT MES<br />Phiếu lĩnh {r.req_no}<br />Số phiếu ……</div>
              </div>
              <table className={`w-full border-collapse ${cell}`}>
                <thead><tr><th>Vật tư</th><th>ĐVT</th><th className="text-right">Cần xuất</th><th>Ống/bao xuất trước (mã tem · còn)</th><th className="w-[16%]">Thực xuất (mã tem · số lượng)</th></tr></thead>
                <tbody>{ls.map((l) => (
                  <tr key={l.material_id}>
                    <td><b>{l.material_code}</b><div className="text-[11px]">{l.material_name}</div></td>
                    <td>{l.uom}</td><td className="text-right">{nf(l.remaining, 2)}</td>
                    <td className="text-[11.5px]">{suggest(l).map((p) => `${p.hu_no}${p.location_code ? ' @' + p.location_code : ''} · ${nf(p.available, 1)}`).join('; ') || 'Hết hàng đạt QC'}</td>
                    <td />
                  </tr>
                ))}</tbody>
              </table>
              <p className="mt-1 text-[11px] text-muted">Xuất ống/bao theo gợi ý (hạn dùng, ngày nhập sớm trước); lấy ống khác thì ghi lý do. Chỉ xuất NVL có tem QC đạt.</p>
              {sign('Kế toán SX lập phiếu', 'Thủ kho (TP SX) xuất', 'NV lấy NVL nhận')}
            </section>
            <section className="mb-4 break-after-page border border-ink/60 p-3">
              <div className="mb-2 flex items-start justify-between">
                <div>
                  <div className="text-[15px] font-medium">PHIẾU NHẬP NVL THỪA CUỐI NGÀY</div>
                  <div>Lô <b className="mono">{r.wo_no}</b> · Mã <b>{r.product_code}</b> · Ngày {df(r.work_date)}</div>
                </div>
                <div className="text-right text-[11px] text-muted">BMT MES<br />Số phiếu ……</div>
              </div>
              <table className={`w-full border-collapse ${cell}`}>
                <thead><tr><th>Vật tư</th><th>Mã tem ống/bao</th><th className="w-[16%]">Trả kho (kg cân)</th><th className="w-[22%]">Để lại máy chạy tiếp cùng lô (kg)</th></tr></thead>
                <tbody>{ls.map((l) => (
                  <tr key={l.material_id}><td><b>{l.material_code}</b></td><td /><td /><td /></tr>
                ))}</tbody>
              </table>
              <p className="mt-1 text-[11px] text-muted">Chỉ để lại máy: cuộn đồng trên giá xả, nhựa còn trong phễu khi ngày mai chạy tiếp cùng lô (ghi cả trên báo cáo ca). Phế đồng để thùng riêng.</p>
              {sign('Người trả (công nhân)', 'Thủ kho (TP SX) nhận')}
            </section>
          </div>
        );
      })}
      <div className="text-[11px] text-muted print:hidden">In lúc {df(new Date().toISOString(), true)} từ BMT MES</div>
    </main>
  );
}
