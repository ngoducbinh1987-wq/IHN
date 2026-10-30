import Link from 'next/link';
import { Empty, Flash, Tabs, Toolbar } from '@/components/ui';
import { df, nf } from '@/lib/format';
import { DOC_TYPES, KIND_NAMES, LoadErrors, fetchAll } from '@/lib/kho';
import { requirePage, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Nhập – xuất – tồn' };

type Nxt = {
  warehouse_code: string; item_code: string; item_name: string; uom: string; item_kind: string; opening: number; qty_in: number; qty_out: number; closing: number;
  value_opening: number | null; value_in: number | null; value_out: number | null; value_closing: number | null;
};

const isDate = (s?: string) => !!s && /^\d{4}-\d{2}-\d{2}$/.test(s);
function monthRange() {
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Ho_Chi_Minh' });
  return { from: `${today.slice(0, 8)}01`, to: today };
}

export default async function LedgerPage({ searchParams }: { searchParams: Promise<{ tu?: string; den?: string; kho?: string; ma?: string; tab?: string }> }) {
  const sp = await searchParams;
  await requirePage('kho-so-cai');
  await requirePerm('inventory', 'view');
  const def = monthRange();
  const from = isDate(sp.tu) ? sp.tu! : def.from;
  const to = isDate(sp.den) ? sp.den! : def.to;
  const tab = sp.tab === 'the-kho' || sp.ma ? 'the-kho' : 'nxt';
  const supabase = await createClient();
  const le = new LoadErrors();
  const { data: whs } = le.one(await supabase.schema('inv').from('warehouses').select('id, code, name').order('code'));
  const wh = (whs ?? []).find((w) => w.code === sp.kho);
  // Đọc hết (nối từng trang 1.000 dòng)
  const nxtRes = le.one(await fetchAll<Nxt>((a, b) => supabase.schema('app').rpc('stock_nxt', { p_from: from, p_to: to, p_wh: wh?.id ?? null })
    .order('warehouse_code').order('item_code').range(a, b)));
  const nxt = nxtRes.data;
  const money = nxt.some((r) => r.value_closing !== null);
  const qs = (extra: Record<string, string | undefined>) => {
    const p = new URLSearchParams({ tu: from, den: to, ...(sp.kho ? { kho: sp.kho } : {}) });
    for (const [k, v] of Object.entries(extra)) if (v) p.set(k, v); else p.delete(k);
    return `/kho/so-cai?${p.toString()}`;
  };

  // Thẻ kho một mã: tồn đầu từ NXT, cộng dồn từng dòng
  let card: { rows: Record<string, unknown>[]; opening: number; uom: string; name: string; truncated: boolean } | null = null;
  if (tab === 'the-kho' && sp.ma) {
    const ma = sp.ma;
    const ledger = le.one(await fetchAll<Record<string, unknown>>((a, b) => {
      let q = supabase.schema('app').from('v_ledger').select('*').eq('item_code', ma).gte('doc_date', from).lte('doc_date', to);
      if (wh) q = q.eq('warehouse_id', wh.id);
      return q.order('doc_date').order('moved_at').order('id').range(a, b);
    }));
    const rows = ledger.data;
    const items = nxt.filter((r) => r.item_code === sp.ma);
    card = {
      truncated: ledger.truncated || nxtRes.truncated,
      rows, opening: items.reduce((s, r) => s + Number(r.opening), 0),
      uom: items[0]?.uom ?? (rows?.[0]?.uom as string) ?? '', name: items[0]?.item_name ?? (rows?.[0]?.item_name as string) ?? '',
    };
  }

  const filter = (
    <form className="card mb-4 flex flex-wrap items-end gap-3 p-3" action="/kho/so-cai">
      {tab === 'the-kho' && <input type="hidden" name="tab" value="the-kho" />}
      <label className="lbl">Từ ngày<input className="inp" type="date" name="tu" defaultValue={from} /></label>
      <label className="lbl">Đến ngày<input className="inp" type="date" name="den" defaultValue={to} /></label>
      <label className="lbl">Kho<select className="inp" name="kho" defaultValue={sp.kho ?? ''}><option value="">Tất cả</option>{(whs ?? []).map((w) => <option key={w.id} value={w.code}>{w.code} · {w.name}</option>)}</select></label>
      {tab === 'the-kho' && (
        <label className="lbl">Mã hàng<select className="inp min-w-[220px]" name="ma" defaultValue={sp.ma ?? ''} required>
          <option value="" disabled>Chọn mã</option>
          {[...new Map(nxt.map((r) => [r.item_code, r])).values()].map((r) => <option key={r.item_code} value={r.item_code}>{r.item_code} · {r.item_name}</option>)}
        </select></label>
      )}
      <button className="btn btn-pri" type="submit">Xem</button>
    </form>
  );

  return (
    <>
      <Toolbar title="Nhập – xuất – tồn" reload={qs({ tab: tab === 'the-kho' ? 'the-kho' : undefined, ma: sp.ma })} />
      <Tabs active={tab} items={[
        { key: 'nxt', label: 'Tổng hợp nhập – xuất – tồn', href: qs({}) },
        { key: 'the-kho', label: 'Thẻ kho từng mã', href: qs({ tab: 'the-kho' }) },
      ]} />
      {filter}
      <Flash err={le.text} />
      {nxtRes.truncated && <p className="mb-3 text-[12.5px] text-warn">Kết quả quá {nxt.length.toLocaleString('vi-VN')} dòng nên chỉ hiện chừng đó dòng. Chọn kho để thu hẹp.</p>}

      {tab === 'nxt' && (
        <section className="card overflow-x-auto">
          {nxt.length ? (
            <table className="tbl">
              <thead>
                <tr><th>Kho</th><th>Mã</th><th>Tên hàng</th><th>Loại</th><th>ĐVT</th><th className="num">Tồn đầu</th><th className="num">Nhập</th><th className="num">Xuất</th><th className="num">Tồn cuối</th>
                  {money && <><th className="num">Giá trị đầu</th><th className="num">Giá trị nhập</th><th className="num">Giá trị xuất</th><th className="num">Giá trị cuối</th></>}</tr>
              </thead>
              <tbody>
                {nxt.map((r) => (
                  <tr key={`${r.warehouse_code}-${r.item_code}`}>
                    <td>{r.warehouse_code}</td>
                    <td><Link className="link mono" href={qs({ tab: 'the-kho', ma: r.item_code, kho: sp.kho ?? r.warehouse_code })}>{r.item_code}</Link></td>
                    <td className="min-w-[180px]">{r.item_name}</td><td>{KIND_NAMES[r.item_kind] ?? r.item_kind}</td><td>{r.uom}</td>
                    <td className="num">{nf(r.opening, 2)}</td><td className="num">{nf(r.qty_in, 2)}</td><td className="num">{nf(r.qty_out, 2)}</td><td className="num font-medium">{nf(r.closing, 2)}</td>
                    {money && <><td className="num">{nf(r.value_opening)}</td><td className="num">{nf(r.value_in)}</td><td className="num">{nf(r.value_out)}</td><td className="num font-medium">{nf(r.value_closing)}</td></>}
                  </tr>
                ))}
                {money && (
                  <tr className="font-medium">
                    <td colSpan={9} className="text-right">Tổng giá trị</td>
                    {(['value_opening', 'value_in', 'value_out', 'value_closing'] as const).map((k) => <td key={k} className="num">{nf(nxt.reduce((s, r) => s + Number(r[k] ?? 0), 0))}</td>)}
                  </tr>
                )}
              </tbody>
            </table>
          ) : <Empty>Không có phát sinh trong kỳ này.</Empty>}
          <p className="border-t border-line px-4 py-2 text-[12.5px] text-muted">Số lượng theo đơn vị kho (đồng, nhựa: kg; thành phẩm: m). Giá trị theo giá bình quân, chỉ hiện với người được xem giá. Bấm mã để xem thẻ kho.</p>
        </section>
      )}

      {tab === 'the-kho' && (
        card ? (
          <section className="card overflow-x-auto">
            <div className="card-h"><span><span className="mono">{sp.ma}</span> · {card.name}</span><span className="text-[13px] font-normal text-muted">Tồn đầu kỳ: <b>{nf(card.opening, 2)} {card.uom}</b></span></div>
            {card.rows.length ? (
              <table className="tbl">
                <thead><tr><th>Ngày</th><th>Số phiếu</th><th>Loại</th><th>Kho / vị trí</th><th>Lô</th><th>Đơn vị (QR)</th><th className="num">Nhập</th><th className="num">Xuất</th><th className="num">Tồn</th><th>Người ghi</th></tr></thead>
                <tbody>{(() => {
                  let run = card.opening;
                  return card.rows.map((r) => {
                    const q = Number(r.qty);
                    run += q;
                    return (
                      <tr key={r.id as string}>
                        <td>{df(r.doc_date as string)}</td>
                        <td><Link className="link mono" href={`/kho/phieu/${r.doc_id}`}>{r.doc_no as string}</Link></td>
                        <td>{DOC_TYPES[r.doc_type as string] ?? (r.doc_type as string)}</td>
                        <td>{r.warehouse_code as string}{r.location_code ? ` · ${r.location_code}` : ''}</td>
                        <td className="mono">{r.lot_no as string}</td>
                        <td className="mono">{r.hu_no ? <Link className="link" href={`/kho/quet?ma=${r.hu_no}`}>{r.hu_no as string}</Link> : '—'}</td>
                        <td className="num">{q > 0 ? nf(q, 2) : ''}</td><td className="num">{q < 0 ? nf(-q, 2) : ''}</td><td className="num font-medium">{nf(run, 2)}</td>
                        <td className="text-[13px]">{r.posted_by_name as string}</td>
                      </tr>
                    );
                  });
                })()}</tbody>
              </table>
            ) : <Empty>Mã này không có phát sinh trong kỳ.</Empty>}
            {card.truncated && <p className="border-t border-line px-4 py-2 text-[12.5px] text-warn">Quá nhiều dòng nên chỉ hiện {card.rows.length.toLocaleString('vi-VN')} dòng đầu, số tồn cộng dồn có thể thiếu: thu hẹp khoảng ngày hoặc chọn kho.</p>}
          </section>
        ) : <div className="card"><Empty>Chọn mã hàng để xem thẻ kho.</Empty></div>
      )}
    </>
  );
}
