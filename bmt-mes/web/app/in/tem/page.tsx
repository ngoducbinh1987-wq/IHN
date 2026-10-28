import QRCode from 'qrcode';
import { PrintButton } from '@/components/print-button';
import { df, nf } from '@/lib/format';
import { KIND_NAMES, LOC_KINDS, QC_STATUS, WH_NAMES } from '@/lib/kho';
import { requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { PrintLabels } from './print-labels';

export const metadata = { title: 'In tem' };

type Hu = {
  id: string; hu_no: string; qr_payload: string | null; hu_type: string; status: string; qty: number; init_qty: number | null; gross_kg: number | null; tare_kg: number | null;
  is_remnant: boolean; print_count: number; lot_no: string; item_kind: string; qc_status: string; mfg_date: string | null; exp_date: string | null; supplier_lot: string | null;
  brand: string | null; color: string | null; uom: string; item_code: string; item_name: string; warehouse_code: string | null; location_code: string | null;
  supplier_name: string | null; wo_no: string | null; op_code: string | null; carrier_code: string | null;
};
type Loc = { id: string; code: string; name: string | null; kind: string; warehouse_code: string; active: boolean };

const UUID = /^[0-9a-f-]{36}$/i;
const qr = (payload: string) => QRCode.toString(payload, { type: 'svg', margin: 0, errorCorrectionLevel: 'M' });

// Tem 100 × 75 mm cho máy in tem nhiệt; mỗi tem một trang
export default async function PrintTags({ searchParams }: { searchParams: Promise<{ doc?: string; hu?: string; loc?: string }> }) {
  const sp = await searchParams;
  await requirePerm('inventory', 'view');
  const supabase = await createClient();

  let hus: Hu[] = [];
  let locs: Loc[] = [];
  let title = 'In tem';
  if (sp.doc && UUID.test(sp.doc)) {
    const [{ data: d }, { data: lines }] = await Promise.all([
      supabase.schema('app').from('v_stock_docs').select('doc_no').eq('id', sp.doc).maybeSingle(),
      supabase.schema('app').from('v_stock_doc_lines').select('hu_id, qty').eq('doc_id', sp.doc).gt('qty', 0).not('hu_id', 'is', null),
    ]);
    const ids = [...new Set((lines ?? []).map((l) => l.hu_id as string))];
    if (ids.length) hus = ((await supabase.schema('app').from('v_hu').select('*').in('id', ids).neq('status', 'VOID').order('hu_no')).data ?? []) as Hu[];
    title = `Tem phiếu ${d?.doc_no ?? ''}`;
  } else if (sp.hu) {
    const ids = sp.hu.split(',').filter((x) => UUID.test(x));
    if (ids.length) hus = ((await supabase.schema('app').from('v_hu').select('*').in('id', ids).order('hu_no')).data ?? []) as Hu[];
    title = 'Tem đơn vị';
  } else if (sp.loc) {
    const code = sp.loc.toUpperCase();
    const q = supabase.schema('app').from('v_locations').select('id, code, name, kind, warehouse_code, active').eq('active', true).order('sort');
    locs = ((await (WH_NAMES[code] ? q.eq('warehouse_code', code) : q.eq('code', code))).data ?? []) as Loc[];
    title = `Tem vị trí ${code}`;
  }

  // Cuộn thành phẩm chỉ dán tem QC PASS, không in tem QR (anh Bình chốt 28/10/2026)
  const fgSkipped = hus.filter((h) => h.item_kind === 'FG').length;
  hus = hus.filter((h) => h.item_kind !== 'FG');
  const huSvgs = await Promise.all(hus.map((h) => qr(h.qr_payload || `BMT|${h.hu_no}`)));
  const locSvgs = await Promise.all(locs.map((l) => qr(`LOC|${l.code}`)));
  const reprint = hus.filter((h) => h.print_count > 0).length;
  const empty = hus.length === 0 && locs.length === 0;

  return (
    <main className="mx-auto max-w-[1100px] bg-white p-6 text-ink print:m-0 print:max-w-none print:p-0">
      <style>{'@page { size: 100mm 75mm; margin: 0 } @media print { html, body { background: #fff } }'}</style>
      <div className="mb-4 flex flex-wrap items-center justify-between gap-3 print:hidden">
        <div>
          <h1 className="text-[20px] font-medium">{title}</h1>
          <p className="text-[13px] text-muted">
            Khổ tem 100 × 75 mm. Trong hộp thoại in chọn máy in tem, khổ giấy 100 × 75, lề 0, tỉ lệ 100%.
            {reprint > 0 && <> <b className="text-warn">{reprint} tem đã in trước đó</b> – in lại phải ghi lý do, hệ thống lưu nhật ký.</>}
          </p>
        </div>
        {hus.length > 0 ? <PrintLabels ids={hus.map((h) => h.id)} reprint={reprint} /> : locs.length > 0 ? <PrintButton /> : null}
      </div>
      {fgSkipped > 0 && <p className="mb-3 text-[13px] text-muted print:hidden">{fgSkipped} cuộn thành phẩm không in tem QR: cuộn thành phẩm chỉ dán tem QC PASS, xuất kho theo số cuộn.</p>}
      {empty && <p className="text-muted">Không có tem nào để in.</p>}

      <div className="flex flex-wrap gap-4 print:block">
        {hus.map((h, i) => {
          const net = h.item_kind === 'MAT' || h.item_kind === 'SCRAP' ? null : h.gross_kg !== null && h.tare_kg !== null ? h.gross_kg - h.tare_kg : null;
          const qc = QC_STATUS[h.qc_status]?.[0] ?? h.qc_status;
          return (
            <section key={h.id} className="flex h-[75mm] w-[100mm] flex-col overflow-hidden border border-ink/40 p-[3mm] text-[9pt] leading-tight print:break-after-page print:border-0">
              <div className="flex items-center justify-between border-b border-ink pb-[1mm]">
                <img src="/logo-bmt.png" alt="BMTcable" className="h-[6mm] w-auto" />
                <span className="font-medium">{KIND_NAMES[h.item_kind] ?? h.item_kind}{h.is_remnant ? ' · ĐOẠN LẺ' : ''} · {h.warehouse_code ?? ''}{h.location_code ? `/${h.location_code}` : ''}</span>
              </div>
              <div className="flex min-h-0 flex-1 gap-[2mm] pt-[1.5mm]">
                <div className="min-w-0 flex-1">
                  <div className="truncate text-[14pt] font-bold">{h.item_code}</div>
                  <div className="line-clamp-2 text-[8.5pt]">{h.item_name}</div>
                  <div className="mt-[1mm] text-[16pt] font-bold">{nf(h.qty, h.uom === 'm' ? 0 : 2)} <span className="text-[10pt]">{h.uom}</span></div>
                  <table className="mt-[1mm] w-full text-[8pt] [&_td]:py-[0.3mm] [&_td:first-child]:pr-[1.5mm] [&_td:first-child]:text-ink/70">
                    <tbody>
                      <tr><td>Lô</td><td className="font-medium">{h.lot_no}</td></tr>
                      {h.supplier_lot && <tr><td>Lô NCC</td><td>{h.supplier_lot}</td></tr>}
                      {h.wo_no && <tr><td>Lệnh SX</td><td>{h.wo_no}{h.op_code ? ` · ${h.op_code}` : ''}</td></tr>}
                      {(h.brand || h.color) && <tr><td>TH / màu</td><td>{[h.brand, h.color].filter(Boolean).join(' · ')}</td></tr>}
                      {h.gross_kg !== null && <tr><td>Cân</td><td>tổng {nf(h.gross_kg, 2)} · bì {nf(h.tare_kg, 2)}{net !== null ? ` · tịnh ${nf(net, 2)}` : ''} kg</td></tr>}
                      <tr><td>Ngày SX/nhập</td><td>{df(h.mfg_date)}{h.exp_date ? <> · <b>HSD {df(h.exp_date)}</b></> : ''}</td></tr>
                      {h.carrier_code && <tr><td>Bobin</td><td>{h.carrier_code}</td></tr>}
                    </tbody>
                  </table>
                </div>
                <div className="flex w-[30mm] shrink-0 flex-col items-center">
                  <div className="w-[30mm] [&_svg]:h-auto [&_svg]:w-full" dangerouslySetInnerHTML={{ __html: huSvgs[i] }} />
                  <div className={`mt-[1.5mm] w-full border px-[1mm] py-[0.5mm] text-center text-[8pt] font-bold ${h.qc_status === 'PASSED' ? 'border-ink' : 'border-ink bg-ink text-white'}`}>{qc}</div>
                </div>
              </div>
              <div className="flex items-end justify-between border-t border-ink pt-[1mm]">
                <span className="font-mono text-[12pt] font-bold">{h.hu_no}</span>
                <span className="text-[7pt] text-ink/70">{h.supplier_name ?? ''}{h.print_count > 0 ? ` · in lại lần ${h.print_count}` : ''}</span>
              </div>
            </section>
          );
        })}

        {locs.map((l, i) => (
          <section key={l.id} className="flex h-[75mm] w-[100mm] items-center gap-[4mm] overflow-hidden border border-ink/40 p-[4mm] print:break-after-page print:border-0">
            <div className="w-[45mm] shrink-0 [&_svg]:h-auto [&_svg]:w-full" dangerouslySetInnerHTML={{ __html: locSvgs[i] }} />
            <div className="min-w-0">
              <div className="text-[9pt]">{WH_NAMES[l.warehouse_code] ?? l.warehouse_code}</div>
              <div className="break-all font-mono text-[20pt] font-bold leading-none">{l.code}</div>
              <div className="mt-[2mm] text-[10pt]">{l.name}</div>
              <div className="mt-[1mm] text-[9pt] text-ink/70">{LOC_KINDS[l.kind] ?? l.kind}</div>
            </div>
          </section>
        ))}
      </div>
    </main>
  );
}
