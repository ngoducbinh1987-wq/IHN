import Link from 'next/link';
import { Empty, Flash, Pill, StatusPill, Tabs, Toolbar } from '@/components/ui';
import { df, nf } from '@/lib/format';
import { KIND_NAMES, LoadErrors, QC_STATUS, fetchAll } from '@/lib/kho';
import { requirePage, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { kindLabel, type FgGroup } from '../xuat-ban/items-fields';

export const metadata = { title: 'Tồn kho' };

type Row = {
  warehouse_code: string; location_code: string | null; lot_id: string; lot_no: string; hu_id: string | null; hu_no: string | null; item_kind: string;
  item_code: string; item_name: string; uom: string; group_code: string | null; qc_status: string; exp_date: string | null; mfg_date: string | null;
  brand: string | null; color: string | null; wip_stage: string | null; qty: number; reserved_qty: number; available: number; is_remnant: boolean; expiring: boolean;
};

const FILTERS: Record<string, string> = { '': 'Tất cả', dat: 'Đạt', qc: 'Chờ QC', 'cach-ly': 'Cách ly', hsd: 'Sắp hết hạn', le: 'Đoạn lẻ', thieu: 'Dưới mức đặt hàng' };

export default async function StockPage({ searchParams }: { searchParams: Promise<{ kho?: string; loc?: string; q?: string; xem?: string; trang?: string }> }) {
  const sp = await searchParams;
  const me = await requirePage('kho-ton');
  await requirePerm('inventory', 'view');
  // Kinh doanh (chỉ giữ vai trò kinh doanh) xem tồn thành phẩm để hẹn giao khách (phân quyền theo bộ phận 28/10/2026)
  const fgOnly = me.roles.length > 0 && me.roles.every((r) => r.startsWith('KD_'));
  const kho = fgOnly ? 'KTP' : ['KNL', 'KBTP', 'KTP', 'KPL'].includes(sp.kho ?? '') ? sp.kho! : '';
  const loc = sp.loc && FILTERS[sp.loc] && !(fgOnly && sp.loc === 'thieu') ? sp.loc : '';
  const detail = sp.xem === 'ct' || !!sp.q;
  const supabase = await createClient();
  const le = new LoadErrors();
  const qs = (patch: Record<string, string | undefined>) => {
    const p = new URLSearchParams(Object.entries({ kho, loc, q: sp.q, xem: sp.xem, ...patch }).filter(([, v]) => v) as [string, string][]);
    return `/kho/ton${p.toString() ? '?' + p.toString() : ''}`;
  };

  if (loc === 'thieu') {
    const [{ data: mats }, { data: avail }] = le.all(await Promise.all([
      supabase.schema('master').from('materials').select('id, code, name, uom, reorder_point, target_months').not('reorder_point', 'is', null).order('code'),
      supabase.schema('app').from('v_materials').select('id, available, in_quality'),
    ]));
    const rows = (mats ?? []).map((m) => {
      const a = (avail ?? []).find((x) => x.id === m.id);
      return { ...m, available: Number(a?.available ?? 0), in_quality: Number(a?.in_quality ?? 0) };
    }).filter((m) => m.available + m.in_quality <= Number(m.reorder_point));
    return (
      <>
        <Toolbar title="Tồn kho" reload={qs({})} />
        <Flash err={le.text} />
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

  const term = (sp.q ?? '').replace(/[,()*%\\]/g, ' ').trim();
  // Đọc hết tồn (nối từng trang 1.000 dòng): bảng theo mã hàng cộng từ mọi dòng, không được thiếu
  const stockPage = (from: number, to: number) => {
    let q = supabase.schema('app').from('v_stock').select('*');
    if (kho) q = q.eq('warehouse_code', kho);
    if (loc === 'dat') q = q.eq('qc_status', 'PASSED');
    if (loc === 'qc') q = q.eq('qc_status', 'PENDING');
    if (loc === 'cach-ly') q = q.in('qc_status', ['QUARANTINE', 'REJECTED']);
    if (loc === 'hsd') q = q.eq('expiring', true);
    if (loc === 'le') q = q.eq('is_remnant', true);
    if (term) q = q.or(`item_code.ilike.*${term}*,item_name.ilike.*${term}*,lot_no.ilike.*${term}*,hu_no.ilike.*${term}*,location_code.ilike.*${term}*`);
    return q.order('item_code').order('lot_no').order('hu_no').order('warehouse_code').order('location_code').order('lot_id').order('hu_id')
      .range(from, to).returns<Row[]>();
  };
  const [stock, { data: fg }] = le.all(await Promise.all([
    fetchAll<Row>(stockPage),
    // Thành phẩm đếm theo cuộn, chủng loại (mã · nhãn · quy cách): cuộn chỉ dán tem QC PASS, xuất theo số cuộn
    kho === 'KTP' && !detail ? supabase.schema('app').from('v_fg_stock').select('*').order('product_code').order('brand').returns<FgGroup[]>() : Promise.resolve({ data: [] as FgGroup[] }),
  ]));
  const rows = stock.data;
  // Bảng chi tiết hiện 500 dòng mỗi trang
  const PER = 500;
  const pages = Math.max(1, Math.ceil(rows.length / PER));
  const pg = Math.min(pages, Math.max(1, Math.floor(Number(sp.trang)) || 1));
  const shown = rows.slice((pg - 1) * PER, pg * PER);

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
      <Flash err={le.text} />
      <FilterBar kho={kho} loc={loc} qs={qs} />
      <div className="mb-3 flex gap-2">
        <Link className={`btn btn-sm ${!detail ? 'btn-pri' : ''}`} href={qs({ xem: undefined })}>Theo mã hàng</Link>
        <Link className={`btn btn-sm ${detail ? 'btn-pri' : ''}`} href={qs({ xem: 'ct' })}>Chi tiết từng ống/bao/bobin</Link>
      </div>
      {(fg ?? []).length > 0 && (
        <section className="card mb-4 overflow-x-auto" id="theo-cuon">
          <div className="card-h"><span>Thành phẩm theo cuộn</span><Link className="btn btn-sm btn-soft" href="/kho/xuat-ban">Lập lệnh giao</Link></div>
          <table className="tbl">
            <thead><tr><th>Chủng loại</th><th className="num">Chờ QC</th><th className="num">Chờ nhập kho</th><th className="num">Trong kho</th><th className="num">Mét</th><th className="num">Đã hứa giao</th><th className="num">Còn giao được</th><th className="num">Giữ lại</th></tr></thead>
            <tbody>{(fg ?? []).map((g) => (
              <tr key={`${g.product_code}|${g.brand}|${g.pack_m}`}>
                <td>{kindLabel(g.product_code, g.brand, g.pack_m)}</td><td className="num">{g.qc_wait_coils || '—'}</td><td className="num">{g.putaway_coils || '—'}</td>
                <td className="num font-medium">{g.store_coils}</td><td className="num">{nf(g.store_m)}</td><td className="num">{g.committed_coils || '—'}</td>
                <td className="num font-medium text-brand">{g.free_coils}</td><td className="num">{g.hold_coils || '—'}</td>
              </tr>
            ))}</tbody>
          </table>
        </section>
      )}
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
            <tbody>{shown.map((r) => (
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
      {detail && pages > 1 && (
        <div className="mt-2 flex flex-wrap items-center gap-2 text-[13px]">
          <span className="text-muted">Dòng {((pg - 1) * PER + 1).toLocaleString('vi-VN')}–{Math.min(pg * PER, rows.length).toLocaleString('vi-VN')} / {rows.length.toLocaleString('vi-VN')}</span>
          {pg > 1 && <Link className="btn btn-sm" href={qs({ trang: String(pg - 1) })}>Trang trước</Link>}
          {pg < pages && <Link className="btn btn-sm" href={qs({ trang: String(pg + 1) })}>Trang sau</Link>}
        </div>
      )}
      {stock.truncated && <p className="mt-2 text-[12.5px] text-warn">Kết quả quá {rows.length.toLocaleString('vi-VN')} dòng nên chỉ tính chừng đó dòng. Chọn kho hoặc dùng ô tìm kiếm để thu hẹp.</p>}
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
