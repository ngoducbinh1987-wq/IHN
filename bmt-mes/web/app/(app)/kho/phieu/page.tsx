import Link from 'next/link';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Pill, StatusPill, Tabs, Toolbar } from '@/components/ui';
import { df, nf, overdueText } from '@/lib/format';
import { DOC_TYPES, REVIEW_STATUS, STOCK_DOC_STATUS, hasRole } from '@/lib/kho';
import { requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { confirmDoc } from './actions';

export const metadata = { title: 'Phiếu kho' };

export default async function DocsPage({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string; tab?: string; loai?: string; q?: string }> }) {
  const sp = await searchParams;
  const me = await requirePerm('inventory', 'view');
  const tab = ['duyet', 'gia', 'tra-lai', 'nhap'].includes(sp.tab ?? '') ? sp.tab! : 'tat-ca';
  const kt = hasRole(me, 'KT_KHO');
  const supabase = await createClient();
  let q = supabase.schema('app').from('v_stock_docs').select('*').order('created_at', { ascending: false }).limit(300);
  if (tab === 'duyet') q = q.eq('status', 'POSTED').eq('review_status', 'PENDING');
  if (tab === 'gia') q = q.eq('status', 'DRAFT').eq('price_pending', true);
  if (tab === 'tra-lai') q = q.eq('review_status', 'RETURNED');
  if (tab === 'nhap') q = q.in('status', ['DRAFT', 'PENDING_APPROVAL', 'APPROVED']).eq('price_pending', false);
  if (sp.loai && DOC_TYPES[sp.loai]) q = q.eq('doc_type', sp.loai);
  const term = (sp.q ?? '').replace(/[,()*%\\]/g, ' ').trim();
  if (term) q = q.or(`doc_no.ilike.*${term}*,note.ilike.*${term}*,ref_no.ilike.*${term}*`);
  const [{ data: docs }, { count: nDuyet }, { count: nGia }, { count: nTra }] = await Promise.all([
    q,
    supabase.schema('inv').from('stock_docs').select('id', { count: 'exact', head: true }).eq('status', 'POSTED').eq('review_status', 'PENDING'),
    supabase.schema('inv').from('stock_docs').select('id', { count: 'exact', head: true }).eq('status', 'DRAFT').eq('price_pending', true),
    supabase.schema('inv').from('stock_docs').select('id', { count: 'exact', head: true }).eq('review_status', 'RETURNED').is('reversed_by', null),
  ]);
  const href = (t: string) => `/kho/phieu${t === 'tat-ca' ? '' : `?tab=${t}`}`;
  return (
    <>
      <Toolbar title="Phiếu kho" reload={href(tab)} search={{ placeholder: 'Tìm số phiếu, lệnh, ghi chú', value: sp.q }} hidden={{ tab: tab === 'tat-ca' ? undefined : tab, loai: sp.loai }} />
      <Tabs active={tab} items={[
        { key: 'duyet', label: kt ? 'Chờ tôi duyệt' : 'Chờ Kế toán SX duyệt', href: href('duyet'), count: nDuyet ?? 0 },
        { key: 'gia', label: 'Phiếu nhập chờ giá', href: href('gia'), count: nGia ?? 0 },
        { key: 'tra-lai', label: 'Bị trả lại', href: href('tra-lai'), count: nTra ?? 0 },
        { key: 'nhap', label: 'Nháp / chờ phê duyệt', href: href('nhap') },
        { key: 'tat-ca', label: 'Tất cả', href: href('tat-ca') },
      ]} />
      <Flash ok={sp.ok} err={sp.err} />
      <div className="mb-3 flex flex-wrap items-center gap-2 text-[13px]">
        <span className="text-muted">Loại:</span>
        <Link className={`btn btn-sm ${!sp.loai ? 'btn-pri' : ''}`} href={href(tab)}>Tất cả</Link>
        {['GR', 'ISSUE_WO', 'RETURN_WO', 'FG_IN', 'SALE', 'SCRAP_IN', 'TRANSFER', 'ADJ', 'SPLIT', 'OPENING'].map((t) => (
          <Link key={t} className={`btn btn-sm ${sp.loai === t ? 'btn-pri' : ''}`} href={`${href(tab)}${tab === 'tat-ca' ? '?' : '&'}loai=${t}`}>{DOC_TYPES[t]}</Link>
        ))}
      </div>
      {tab === 'duyet' && kt && <p className="mb-3 text-[13px] text-muted">Kế toán SX duyệt trong ngày (Quy chuẩn mục 5): đối chiếu PO, phiếu lĩnh, phiếu kiểm tra. Mở phiếu để xem dòng, hoặc xác nhận nhanh ở đây.</p>}
      <section className="card overflow-x-auto">
        {docs && docs.length > 0 ? (
          <table className="tbl">
            <thead><tr><th>Số phiếu</th><th>Loại</th><th>Kho</th><th>Tham chiếu</th><th className="num">Số lượng</th><th>Người lập</th><th>Thời điểm</th><th>Trạng thái</th><th>Kế toán SX</th>{tab === 'duyet' && kt && <th />}</tr></thead>
            <tbody>{docs.map((d) => {
              const late = d.review_status === 'PENDING' && d.posted_at ? overdueText(new Date(new Date(d.posted_at).getTime() + 24 * 3600_000).toISOString()) : null;
              return (
                <tr key={d.id}>
                  <td><Link className="link mono font-medium" href={`/kho/phieu/${d.id}`}>{d.doc_no}</Link>{d.reversal_of && <div className="text-[12px] text-warn">phiếu đảo</div>}{d.reversed_by && <div className="text-[12px] text-muted">đã đảo</div>}</td>
                  <td>{DOC_TYPES[d.doc_type] ?? d.doc_type}{d.delegated && <div className="text-[12px] text-warn">theo ủy quyền</div>}</td>
                  <td>{d.warehouse_code}{d.to_warehouse_code && d.to_warehouse_code !== d.warehouse_code ? ` → ${d.to_warehouse_code}` : ''}</td>
                  <td>{d.ref_no ?? '—'}{d.req_no ? <div className="text-[12px] text-muted">{d.req_no}</div> : null}</td>
                  <td className="num">{nf(d.total_qty, 2)}</td><td>{d.created_by_name ?? '—'}</td>
                  <td className="whitespace-nowrap">{df(d.posted_at ?? d.created_at, true)}</td>
                  <td>{d.price_pending ? <Pill tone="warn">Chờ giá</Pill> : <StatusPill map={STOCK_DOC_STATUS} value={d.status} />}</td>
                  <td>{d.status === 'POSTED' ? <><StatusPill map={REVIEW_STATUS} value={d.review_status} />{late && <div className="text-[12px] text-bad">{late}</div>}</> : '—'}</td>
                  {tab === 'duyet' && kt && (
                    <td>{d.created_by !== me.id && d.posted_by !== me.id && (
                      <form action={confirmDoc}><input type="hidden" name="doc_id" value={d.id} /><input type="hidden" name="doc_no" value={d.doc_no} /><input type="hidden" name="next" value="list" />
                        <SubmitButton className="btn btn-sm btn-soft" pendingText="…">Xác nhận</SubmitButton></form>)}</td>
                  )}
                </tr>
              );
            })}</tbody>
          </table>
        ) : <Empty>Không có phiếu nào.</Empty>}
      </section>
    </>
  );
}
