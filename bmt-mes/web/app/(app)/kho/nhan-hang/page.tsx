import { Flash, Toolbar } from '@/components/ui';
import { keeps } from '@/lib/kho';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { redirect } from 'next/navigation';
import { ReceiveForm, type MatOpt, type PoOpt } from './receive-form';

export const metadata = { title: 'Nhận hàng' };

type PoLine = { po_id: string; po_no: string; supplier_name: string | null; line_id: string; material_code: string; material_name: string;
  uom: string; has_expiry: boolean; qty: number; received_qty: number };

export default async function ReceivePage({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string }> }) {
  const sp = await searchParams;
  const me = await requireMe();
  if (!keeps(me, 'KNL')) redirect('/kho?err=' + encodeURIComponent('Nhận hàng do Quản lý SX (thủ kho NVL) thực hiện'));
  const supabase = await createClient();
  const [{ data: pos }, { data: mats }, { data: sups }, { data: locs }, { data: pkgs }] = await Promise.all([
    supabase.schema('app').from('v_open_po_lines').select('*').order('po_no', { ascending: false }).order('line_no').returns<PoLine[]>(),
    supabase.schema('master').from('materials').select('code, name, uom, has_expiry').eq('is_scrap', false).eq('active', true).order('code').returns<MatOpt[]>(),
    supabase.schema('core').from('partners').select('id, name').eq('is_supplier', true).eq('active', true).order('name'),
    supabase.schema('app').from('v_locations').select('id, code, name').eq('warehouse_code', 'KNL').eq('active', true).order('sort'),
    supabase.schema('master').from('package_types').select('id, code, name, tare_kg').eq('active', true).order('code'),
  ]);
  const poOpts: PoOpt[] = [];
  for (const l of pos ?? []) {
    let p = poOpts.find((x) => x.id === l.po_id);
    if (!p) { p = { id: l.po_id, po_no: l.po_no, supplier_name: l.supplier_name ?? '', lines: [] }; poOpts.push(p); }
    p.lines.push({ id: l.line_id, material_code: l.material_code, material_name: l.material_name, uom: l.uom, qty: Number(l.qty),
      received_qty: Number(l.received_qty), has_expiry: l.has_expiry });
  }
  return (
    <>
      <Toolbar title="Nhận hàng vào kho nguyên liệu" reload="/kho/nhan-hang" />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /></div>
      <p className="mb-3 text-[13px] text-muted">
        Quản lý SX ký nhận và lập phiếu, NV4 bốc xếp và cân, NV mua hàng đối chiếu PO trên MES, TP Kỹ thuật/QA kiểm tra chất lượng (Quy chuẩn mục 9).
        Hàng mới nhận ở trạng thái Chờ QC, chưa cấp được cho sản xuất.
      </p>
      <ReceiveForm pos={poOpts} mats={mats ?? []} suppliers={sups ?? []}
        locations={(locs ?? []).map((l) => ({ id: l.id, code: l.code, name: l.name }))}
        packages={(pkgs ?? []).map((p) => ({ ...p, tare_kg: Number(p.tare_kg) }))} />
    </>
  );
}
