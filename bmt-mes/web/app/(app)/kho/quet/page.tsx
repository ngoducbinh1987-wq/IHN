import Link from 'next/link';
import { Printer } from 'lucide-react';
import { ScanInput } from '@/components/scan';
import { Empty, Flash, InfoRow, Pill, StatusPill, Toolbar } from '@/components/ui';
import { df, nf } from '@/lib/format';
import { DOC_TYPES, HU_STATUS, KIND_NAMES, LoadErrors, QC_STATUS, keeps, scanCode } from '@/lib/kho';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Quét mã' };

export default async function ScanPage({ searchParams }: { searchParams: Promise<{ ma?: string }> }) {
  const sp = await searchParams;
  const me = await requireMe();
  const code = sp.ma ? scanCode(sp.ma) : '';
  const supabase = await createClient();
  const le = new LoadErrors();
  const { data: h } = code
    ? le.one(await supabase.schema('app').from('v_hu').select('*').eq('hu_no', code).maybeSingle())
    : { data: null };
  const { data: lotHus } = !h && code
    ? le.one(await supabase.schema('app').from('v_hu').select('id, hu_no, qty, uom, status, location_code, warehouse_code').eq('lot_no', code).order('hu_no'))
    : { data: null };
  const { data: moves } = h
    ? le.one(await supabase.schema('app').from('v_ledger').select('id, moved_at, doc_no, doc_id, doc_type, warehouse_code, location_code, qty, posted_by_name')
      .eq('hu_no', h.hu_no).order('moved_at', { ascending: false }).limit(30))
    : { data: null };
  return (
    <>
      <Toolbar title="Quét mã" />
      <div className="mt-4"><Flash err={le.text} /></div>
      <form className="mx-auto mt-4 max-w-[720px]" action="/kho/quet">
        <ScanInput name="ma" submitOnScan defaultValue={code} placeholder="Quét tem QR ống / bao / bobin, hoặc gõ số rồi Enter" />
      </form>
      {code && !h && !lotHus?.length && !le.has && <div className="mx-auto mt-4 max-w-[720px] card"><Empty>Không tìm thấy mã <b className="mono">{code}</b>.</Empty></div>}
      {lotHus && lotHus.length > 0 && (
        <section className="card mx-auto mt-4 max-w-[720px] overflow-x-auto">
          <div className="card-h">Lô {code}: {lotHus.length} đơn vị chứa</div>
          <table className="tbl"><tbody>{lotHus.map((x) => (
            <tr key={x.id}><td><Link className="link mono" href={`/kho/quet?ma=${x.hu_no}`}>{x.hu_no}</Link></td><td className="num">{nf(x.qty, 2)} {x.uom}</td>
              <td>{x.warehouse_code}/{x.location_code ?? '—'}</td><td><StatusPill map={HU_STATUS} value={x.status} /></td></tr>
          ))}</tbody></table>
        </section>
      )}
      {h && (
        <div className="mx-auto mt-4 grid max-w-[1100px] gap-4 lg:grid-cols-[1fr_1.3fr]">
          <section className="card">
            <div className="card-h"><span className="mono">{h.hu_no}</span><StatusPill map={HU_STATUS} value={h.status} /></div>
            <div className="px-4 py-2">
              <div className="mb-2 text-[16px] font-medium"><span className="mono">{h.item_code}</span> · {h.item_name}</div>
              <InfoRow label="Còn">{nf(h.qty, 3)} {h.uom}{Number(h.reserved_qty) > 0 && <> · <Pill tone="info">giữ {nf(h.reserved_qty)}</Pill></>}{h.is_remnant && <> · <Pill tone="warn">Đoạn lẻ</Pill></>}</InfoRow>
              <InfoRow label="Vị trí">{h.warehouse_code ?? '—'} / {h.location_code ?? '—'}</InfoRow>
              <InfoRow label="Lô">{h.lot_no} · {KIND_NAMES[h.item_kind] ?? h.item_kind} · <StatusPill map={QC_STATUS} value={h.qc_status} /></InfoRow>
              {h.supplier_name && <InfoRow label="Nhà cung cấp">{h.supplier_name}{h.supplier_lot ? ` · lô NCC ${h.supplier_lot}` : ''}</InfoRow>}
              {h.exp_date && <InfoRow label="Hạn dùng"><span className={h.expired ? 'text-bad' : ''}>{df(h.exp_date)}</span></InfoRow>}
              {h.wo_no && <InfoRow label="Lệnh SX">{h.wo_no} · {h.op_code}{h.color ? ` · màu ${h.color}` : ''}{h.brand ? ` · ${h.brand}` : ''}</InfoRow>}
              {h.gross_kg && <InfoRow label="Cân">tổng {nf(h.gross_kg, 2)} kg · bì {nf(h.tare_kg, 2)} kg</InfoRow>}
              {h.carrier_code && <InfoRow label="Bobin">{h.carrier_code}</InfoRow>}
              <InfoRow label="Tem">{h.print_count ? `đã in ${h.print_count} lần` : 'chưa in'}</InfoRow>
            </div>
            <div className="flex flex-wrap gap-2 border-t border-line p-3">
              <Link className="btn btn-soft" href={`/in/tem?hu=${h.id}`} target="_blank"><Printer size={16} />In tem</Link>
              {h.status === 'ACTIVE' && (keeps(me, 'KNL') || keeps(me, 'KTP')) && <Link className="btn" href={`/kho/chuyen?ma=${h.hu_no}`}>Chuyển vị trí</Link>}
              {h.item_kind === 'MAT' && keeps(me, 'KNL') && <Link className="btn" href={`/kho/tra?ma=${h.hu_no}`}>Trả NVL thừa</Link>}
              {h.item_kind === 'FG' && h.status === 'ACTIVE' && keeps(me, 'KTP') && <Link className="btn" href={`/kho/thanh-pham?ma=${h.hu_no}`}>Cắt bobin</Link>}
            </div>
          </section>
          <section className="card overflow-x-auto">
            <div className="card-h">Lịch sử xuất nhập</div>
            {moves && moves.length > 0 ? (
              <table className="tbl">
                <thead><tr><th>Thời điểm</th><th>Phiếu</th><th>Kho/vị trí</th><th className="num">SL</th><th>Người ghi</th></tr></thead>
                <tbody>{moves.map((m) => (
                  <tr key={m.id}>
                    <td className="whitespace-nowrap">{df(m.moved_at, true)}</td>
                    <td><Link className="link mono" href={`/kho/phieu/${m.doc_id}`}>{m.doc_no}</Link><div className="text-[12px] text-muted">{DOC_TYPES[m.doc_type] ?? m.doc_type}</div></td>
                    <td>{m.warehouse_code}/{m.location_code ?? '—'}</td>
                    <td className={`num ${Number(m.qty) < 0 ? 'text-bad' : 'text-brand'}`}>{Number(m.qty) > 0 ? '+' : ''}{nf(m.qty, 3)}</td>
                    <td>{m.posted_by_name ?? '—'}</td>
                  </tr>
                ))}</tbody>
              </table>
            ) : <Empty>Chưa có xuất nhập.</Empty>}
          </section>
        </div>
      )}
    </>
  );
}
