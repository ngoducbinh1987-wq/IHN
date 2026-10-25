import Link from 'next/link';
import { Empty, Pill, StatusPill, Tabs, Toolbar } from '@/components/ui';
import { df, nf } from '@/lib/format';
import { KIND_NAMES, QC_STATUS } from '@/lib/kho';
import { requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Tồn kho' };

type Row = {
  warehouse_code: string; location_code: string | null; lot_id: string; lot_no: string; hu_id: string | null; hu_no: string | null; item_kind: string;
  item_code: string; item_name: string; uom: string; group_code: string | null; qc_status: string; exp_date: string | null; mfg_date: string | null;
  brand: string | null; color: string | null; wip_stage: string | null; qty: number; reserved_qty: number; available: number; is_remnant: boolean; expiring: boolean;
};

const FILTERS: Record<string, string> = { '': 'Tất cả', dat: 'Đạt', qc: 'Chờ QC', 'cach-ly': 'Cách ly', hsd: 'Sắp hết hạn', le: 'Đoạn lẻ', thieu: 'Dưới mức đặt hàng' };

export default async function StockPage({ searchParams }: { searchParams: Promise<{ kho?: string; loc?: string; q?: string; xem?: string }> }) {
  const sp = await searchParams;
  await requirePerm('inventory', 'view');
  const kho = ['KNL', 'KBTP', 'KTP', 'KPL'].includes(sp.kho ?? '') ? sp.kho! : '';
  const loc = sp.loc && FILTERS[sp.loc] ? sp.loc : '';
  const detail = sp.xem === 'ct' || !!sp.q;
  const supabase = await createClient();
  const qs = (patch: Record<string, string | undefined>) => {
    const p = new URLSearchParams(Object.entries({ kho, loc, q: sp.q, xem: sp.xem, ...patch }).filter(([, v]) => v) as [string, string][]);
    return `/kho/ton${p.toString() ? '?' + p.toString() : ''}`;
  };

  if (loc === 'thieu') {
    const [{ data: mats }, { data: avail }] = await Promise.all([
      supabase.schema('master').from('materials').select('id, code, name, uom, reorder_point, target_months').not('reorder_point', 'is', null).order('code'),
      supabase.schema('app').from('v_materials').select('id, available, in_quality'),
    ]);
    const rows = (mats ?? []).map((m) => {
      const a = (avail ?? []).find((x) => x.id === m.id);
      return { ...m, available: Number(a?.available ?? 0), in_quality: Number(a?.in_quality ?? 0) };
    }).filter((m) => m.available + m.in_quality <= Number(m.reorder_point));
    return (
      <>
        <Toolbar title="Tồn kho" reload={qs({})} />
        <FilterBar kho={kho} loc={loc} qs={qs} />
        <section className="card overflow-x-auto">
          <div className="card-h">Vật tư chạm mức đặt hàng · Kế toán SX báo NV mua hàng</div>
          {rows.length ? (
            <table className="tbl"><thead><tr><th>Mã</th><th>Vật tư</th><th className="num">Khả dụng</th><th className="num">Chờ QC</th><th className="num">Mức đặt hàng</th></tr></thead>
              <tbody>{rows.map((m) => (
                <tr key={m.id}><td className="mono font-medium">{m.code}</td><td>{m.name}</td><td className="num text-bad">{nf(m.available, 2)} {m.uom}</td>
                  <td className="num">{nf(m.in_quality, 2)}</td><td className="num">{nf(m.reorder_point, 2)}</td></tr>
              ))}</tbody></table>
          ) : <Empty>Không có vật tư nào dưới mức đặt hàng. Mức đặt hàng cài ở Cài đặt kho → Vật tư.</Empty>}
        </section>
      </>
    );
  }

  let q = supabase.schema('app').from('v_stock').select('*').order('item_code').order('lot_no').order('hu_no').limit(2000);
  if (kho) q = q.eq('warehouse_code', kho);
  if (loc === 'dat') q = q.eq('qc_status', 'PASSED');
  if (loc === 'qc') q = q.eq('qc_status', 'PENDING');
  if (loc === 'cach-ly') q = q.in('qc_status', ['QUARANTINE', 'REJECTED']);
  if (loc === 'hsd') q = q.eq('expiring', true);
  if (loc === 'le') q = q.eq('is_remnant', true);
  const term = (sp.q ?? '').replace(/[,()*%\\]/g, ' ').trim();
  if (term) q = q.or(`item_code.ilike.*${term}*,item_name.ilike.*${term}*,lot_no.ilike.*${term}*,hu_no.ilike.*${term}*,location_code.ilike.*${term}*`);
  const { data } = await q.returns<Row[]>();
  const rows = data ?? [];

  // Gộp theo mã hàng + kho
  const sum = new Map<string, { wh: string; kind: string; code: string; name: string; uom: string; qty: number; avail: number; res: number; pending: number; held: number; units: number; exp: string | null }>();
  for (const r of rows) {
    const k = `${r.warehouse_code}|${r.item_code}`;
    const s = sum.get(k) ?? { wh: r.warehouse_code, kind: r.item_kind, code: r.item_code, name: r.item_name, uom: r.uom, qty: 0, avail: 0, res: 0, pending: 0, held: 0, units: 0, exp: null };
    s.qty += Number(r.qty); s.res += Number(r.reserved_qty); s.units += 1;
    if (r.qc_status === 'PASSED') s.avail += Number(r.available);
    if (r.qc_status === 'PENDING') s.pending += Number(r.qty);
    if (['QUARANTINE', 'REJECTED'].includes(r.qc_status)) s.held += Number(r.qty);
    if (r.exp_date && (!s.exp || r.exp_date < s.exp)) s.exp = r.exp_date;
    sum.set(k, s);
  }

  return (
    <>
      <Toolbar title="Tồn kho" reload={qs({})} search={{ placeholder: 'Tìm mã hàng, lô, mã QR, vị trí', value: sp.q }} hidden={{ kho, loc, xem: sp.xem }} />
      <FilterBar kho={kho} loc={loc} qs={qs} />
      <div className="mb-3 flex gap-2">
        <Link className={`btn btn-sm ${!detail ? 'btn-pri' : ''}`} href={qs({ xem: undefined })}>Theo mã hàng</Link>
        <Link className={`btn btn-sm ${detail ? 'btn-pri' : ''}`} href={qs({ xem: 'ct' })}>Chi tiết từng ống/bao/bobin</Link>
      </div>
      <section className="card overflow-x-auto">
        {rows.length === 0 ? <Empty>Không có hàng phù hợp.</Empty> : !detail ? (
          <table className="tbl">
            <thead><tr><th>Kho</th><th>Mã</th><th>Tên</th><th>Loại</th><th className="num">Tổng tồn</th><th className="num">Khả dụng</th><th className="num">Đang giữ</th><th className="num">Chờ QC</th><th className="num">Cách ly</th><th className="num">Số đơn vị</th><th>HSD gần nhất</th></tr></thead>
            <tbody>{[...sum.values()].map((s) => (
              <tr key={s.wh + s.code}>
                <td>{s.wh}</td><td><Link className="link mono font-medium" href={qs({ q: s.code, xem: 'ct' })}>{s.code}</Link></td><td className="min-w-[160px]">{s.name}</td>
                <td>{KIND_NAMES[s.kind] ?? s.kind}</td><td className="num font-medium">{nf(s.qty, 2)} {s.uom}</td><td className="num">{nf(s.avail, 2)}</td>
                <td className="num">{s.res ? nf(s.res, 2) : '—'}</td><td className="num text-warn">{s.pending ? nf(s.pending, 2) : '—'}</td>
                <td className="num text-bad">{s.held ? nf(s.held, 2) : '—'}</td><td className="num">{s.units}</td><td>{s.exp ? df(s.exp) : '—'}</td>
              </tr>
            ))}</tbody>
          </table>
        ) : (
          <table className="tbl">
            <thead><tr><th>Mã QR</th><th>Mã hàng</th><th>Lô</th><th>Kho / vị trí</th><th className="num">Tồn</th><th className="num">Đang giữ</th><th>QC</th><th>HSD / ngày SX</th><th>Ghi chú</th></tr></thead>
            <tbody>{rows.map((r) => (
              <tr key={`${r.warehouse_code}${r.location_code}${r.lot_id}${r.hu_id}`}>
                <td>{r.hu_no ? <Link className="link mono" href={`/kho/quet?ma=${r.hu_no}`}>{r.hu_no}</Link> : '—'}</td>
                <td className="min-w-[160px]"><span className="mono">{r.item_code}</span> · {r.item_name}</td>
                <td className="mono">{r.lot_no}</td><td>{r.warehouse_code} / {r.location_code ?? '—'}</td>
                <td className="num font-medium">{nf(r.qty, 3)} {r.uom}</td><td className="num">{Number(r.reserved_qty) ? nf(r.reserved_qty, 2) : '—'}</td>
                <td><StatusPill map={QC_STATUS} value={r.qc_status} /></td>
                <td className={`whitespace-nowrap ${r.expiring ? 'text-warn' : ''}`}>{r.exp_date ? `HSD ${df(r.exp_date)}` : r.mfg_date ? df(r.mfg_date) : '—'}</td>
                <td className="whitespace-nowrap">{r.is_remnant && <Pill tone="warn">Đoạn lẻ</Pill>} {r.brand ?? ''} {r.color ?? ''} {r.wip_stage ?? ''}</td>
              </tr>
            ))}</tbody>
          </table>
        )}
      </section>
      {rows.length >= 2000 && <p className="mt-2 text-[12.5px] text-muted">Hiện 2.000 dòng đầu. Dùng ô tìm kiếm để thu hẹp.</p>}
    </>
  );
}

function FilterBar({ kho, loc, qs }: { kho: string; loc: string; qs: (p: Record<string, string | undefined>) => string }) {
  return (
    <>
      <Tabs active={kho || 'all'} items={[
        { key: 'all', label: 'Tất cả kho', href: qs({ kho: undefined }) },
        { key: 'KNL', label: 'Nguyên liệu', href: qs({ kho: 'KNL' }) }, { key: 'KBTP', label: 'Bán thành phẩm', href: qs({ kho: 'KBTP' }) },
        { key: 'KTP', label: 'Thành phẩm', href: qs({ kho: 'KTP' }) }, { key: 'KPL', label: 'Phế liệu', href: qs({ kho: 'KPL' }) },
      ]} />
      <div className="mb-3 flex flex-wrap gap-2">
        {Object.entries(FILTERS).map(([k, v]) => (
          <Link key={k} className={`btn btn-sm ${loc === k ? 'btn-pri' : ''}`} href={qs({ loc: k || undefined })}>{v}</Link>
        ))}
      </div>
    </>
  );
}
