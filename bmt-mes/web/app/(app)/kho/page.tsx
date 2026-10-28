import Link from 'next/link';
import {
  ArrowLeftRight, BarChart3, BookOpen, ClipboardCheck, ClipboardList, Disc3, FlaskConical, PackagePlus, Recycle,
  Scissors, Settings, Truck, Warehouse,
} from 'lucide-react';
import { Empty, Flash, Kpi, StatusPill, Toolbar } from '@/components/ui';
import { df } from '@/lib/format';
import { DOC_TYPES, REVIEW_STATUS, hasRole, keeps } from '@/lib/kho';
import { can, requireMe, requirePage } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Kho' };

type Ov = Record<string, number>;

export default async function KhoHome({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string }> }) {
  const sp = await searchParams;
  await requirePage('kho');
  const me = await requireMe();
  const supabase = await createClient();
  const [{ data: ov }, { data: docs }] = await Promise.all([
    supabase.schema('app').rpc('kho_overview'),
    supabase.schema('app').from('v_stock_docs').select('id, doc_no, doc_type, warehouse_code, posted_at, created_at, review_status, status, created_by_name, ref_no')
      .order('created_at', { ascending: false }).limit(12),
  ]);
  const o = (ov ?? {}) as Ov;
  const kt = hasRole(me, 'KT_KHO');
  const qc = can(me, 'quality', 'edit');
  const tiles: { href: string; label: string; icon: typeof Warehouse; show: boolean; hint?: string }[] = [
    { href: '/kho/nhan-hang', label: 'Nhận hàng', icon: PackagePlus, show: keeps(me, 'KNL'), hint: 'Theo đơn mua đã duyệt, in tem QR' },
    { href: '/kho/qc', label: 'Kiểm tra chất lượng', icon: FlaskConical, show: can(me, 'quality', 'view'), hint: 'Giải phóng lô chờ QC' },
    { href: '/phieu-xuat-nvl', label: 'Phiếu xuất NVL, NVL thừa', icon: ClipboardList, show: can(me, 'inventory', 'view') || can(me, 'production', 'view'), hint: 'Theo lô, phiếu giấy' },
    { href: '/kho/chuyen', label: 'Chuyển vị trí', icon: ArrowLeftRight, show: keeps(me, 'KNL') || keeps(me, 'KTP') },
    { href: '/kho/ton', label: 'Tồn kho', icon: Warehouse, show: can(me, 'inventory', 'view') },
    { href: '/kho/phieu', label: 'Phiếu kho', icon: BookOpen, show: can(me, 'inventory', 'view'), hint: kt ? 'Duyệt trong ngày' : undefined },
    { href: '/kho/kiem-ke', label: 'Kiểm kê', icon: ClipboardCheck, show: can(me, 'inventory', 'view') },
    { href: '/kho/phe', label: 'Phế liệu', icon: Recycle, show: can(me, 'production', 'create') || keeps(me, 'KPL') || kt, hint: 'Phế tự vào kho khi chốt ca; bán phế' },
    { href: '/kho/xuat-ban', label: 'Xuất giao hàng', icon: Truck, show: keeps(me, 'KTP') || hasRole(me, 'BGD', 'KT_TP', 'KT_KHO') || can(me, 'sales', 'view'), hint: 'Theo số cuộn, chủng loại' },
    { href: '/kho/thanh-pham', label: 'Thành phẩm: nhập kho, cắt cuộn', icon: Scissors, show: keeps(me, 'KTP') || hasRole(me, 'KT_TP', 'KT_KHO', 'SX_TP', 'ADMIN'), hint: 'Phiếu giấy người giữ kho TP ký' },
    { href: '/kho/bobin', label: 'Bobin trung gian', icon: Disc3, show: can(me, 'production', 'view') || can(me, 'inventory', 'view') },
    { href: '/kho/so-cai', label: 'Nhập – xuất – tồn', icon: BookOpen, show: can(me, 'inventory', 'view') },
    { href: '/bao-cao/hao-hut', label: 'Báo cáo hao hụt', icon: BarChart3, show: can(me, 'production', 'view') || can(me, 'inventory', 'view') || can(me, 'cost', 'view') },
    { href: '/kho/cai-dat', label: 'Cài đặt kho', icon: Settings, show: hasRole(me, 'ADMIN', 'KT_TP', 'THU_KHO', 'KHO_NV', 'KT_KHO', 'KTT', 'MUA_NV', 'SX_TP') },
  ];
  return (
    <>
      <Toolbar title="Kho" reload="/kho" />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /></div>
      <div className="mb-4 grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">
        {qc && <Kpi label="Lô chờ QC" value={o.qc_pending ?? 0} tone={o.qc_pending ? 'warn' : undefined} href="/kho/qc" />}
        <Kpi label={kt ? 'Phiếu chờ tôi duyệt' : 'Phiếu chờ Kế toán SX'} value={o.review_pending ?? 0}
          hint={o.review_overdue ? `${o.review_overdue} phiếu quá hạn` : 'Hạn: trong ngày'} tone={o.review_overdue ? 'bad' : o.review_pending ? 'warn' : undefined} href="/kho/phieu?tab=duyet" />
        {(kt || o.price_pending > 0) && <Kpi label="Phiếu nhập chờ giá" value={o.price_pending ?? 0} tone={o.price_pending ? 'warn' : undefined} href="/kho/phieu?tab=gia" />}
        <Kpi label="Phiếu lĩnh chờ cấp" value={o.req_open ?? 0} hint={o.req_waiting ? `${o.req_waiting} chờ TP KT/QA duyệt` : undefined} href="/phieu-xuat-nvl" />
        <Kpi label="Lô sắp hết hạn" value={o.expiring ?? 0} tone={o.expiring ? 'warn' : undefined} href="/kho/ton?loc=hsd" />
        <Kpi label="Dưới mức đặt hàng" value={o.below_reorder ?? 0} tone={o.below_reorder ? 'bad' : undefined} href="/kho/ton?loc=thieu" />
        <Kpi label="Lô cách ly còn hàng" value={o.quarantine ?? 0} tone={o.quarantine ? 'bad' : undefined} href="/kho/qc?tab=cach-ly" />
        <Kpi label="Lệnh giao chờ xuất" value={o.deliveries_ready ?? 0} hint={o.deliveries_waiting ? `${o.deliveries_waiting} chờ duyệt` : undefined} href="/kho/xuat-ban" />
        <Kpi label="Đoạn lẻ thành phẩm" value={o.remnants ?? 0} href="/kho/ton?loc=le" />
        <Kpi label="Kiểm kê đang mở" value={o.counts_open ?? 0} href="/kho/kiem-ke" />
        {o.returned > 0 && <Kpi label="Phiếu bị trả lại" value={o.returned} tone="bad" href="/kho/phieu?tab=tra-lai" />}
      </div>

      <section className="card mb-4">
        <div className="card-h">Thao tác</div>
        <div className="grid grid-cols-2 gap-2 p-3 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-6">
          {tiles.filter((t) => t.show).map((t) => (
            <Link key={t.href} href={t.href} className="flex min-h-[72px] items-center gap-3 rounded border border-line px-3 py-2.5 hover:border-brand hover:bg-brand-soft/50">
              <t.icon size={24} className="shrink-0 text-brand" />
              <span className="leading-tight"><span className="block text-[14.5px] font-medium">{t.label}</span>{t.hint && <span className="text-[12px] text-muted">{t.hint}</span>}</span>
            </Link>
          ))}
        </div>
      </section>

      <section className="card overflow-x-auto">
        <div className="card-h">Phiếu kho gần đây<Link className="link text-[13px] font-normal" href="/kho/phieu">Xem tất cả</Link></div>
        {docs && docs.length > 0 ? (
          <table className="tbl">
            <thead><tr><th>Số phiếu</th><th>Loại</th><th>Kho</th><th>Tham chiếu</th><th>Người lập</th><th>Thời điểm</th><th>Kế toán SX</th></tr></thead>
            <tbody>
              {docs.map((d) => (
                <tr key={d.id}>
                  <td><Link className="link mono font-medium" href={`/kho/phieu/${d.id}`}>{d.doc_no}</Link></td>
                  <td>{DOC_TYPES[d.doc_type] ?? d.doc_type}</td><td>{d.warehouse_code}</td><td>{d.ref_no ?? '—'}</td>
                  <td>{d.created_by_name ?? '—'}</td><td className="whitespace-nowrap">{df(d.posted_at ?? d.created_at, true)}</td>
                  <td>{d.status === 'POSTED' ? <StatusPill map={REVIEW_STATUS} value={d.review_status} /> : <span className="text-muted">{d.status === 'DRAFT' ? 'Nháp' : d.status}</span>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : <Empty>Chưa có phiếu kho nào. Bắt đầu bằng Nhận hàng hoặc Tồn đầu kỳ (Kế toán SX, ở Cài đặt kho).</Empty>}
      </section>
    </>
  );
}
