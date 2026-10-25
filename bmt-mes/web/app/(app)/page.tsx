import Link from 'next/link';
import { Flash, Kpi, PageHeader, Pill, StatusPill } from '@/components/ui';
import { DOC_STATUS, df } from '@/lib/format';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Tổng quan' };

type Dash = {
  products: number; specs_released: number; specs_rdc_over: number; materials_no_price: number;
  materials_no_leadtime: number; approvals_pending: number; plans_open: number;
};

export default async function Dashboard({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string }> }) {
  const sp = await searchParams;
  const me = await requireMe();
  const supabase = await createClient();
  const [{ data: dash }, { data: mine }] = await Promise.all([
    supabase.schema('app').from('v_dashboard').select('*').maybeSingle<Dash>(),
    supabase.schema('app').from('v_approvals').select('id, doc_no, doc_type_name, current_level, submitted_by_name, submitted_at, status')
      .eq('my_turn', true).order('submitted_at').limit(8),
  ]);
  const d = dash ?? ({} as Partial<Dash>);
  return (
    <>
      <PageHeader title={`Chào ${me.full_name}`} sub="Tình trạng dữ liệu và việc cần làm hôm nay" />
      <Flash ok={sp.ok} err={sp.err} />
      <div className="mb-5 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Kpi label="Spec đã phát hành" value={`${d.specs_released ?? 0}/${d.products ?? 0}`}
             hint="Mã chưa phát hành không được ra lệnh SX" tone={(d.specs_released ?? 0) === 0 ? 'warn' : undefined} />
        <Kpi label="SKU Rdc vượt tham chiếu" value={d.specs_rdc_over ?? 0} hint="Cần pilot hoặc chấp nhận sai lệch" tone={(d.specs_rdc_over ?? 0) > 0 ? 'bad' : 'ok'} />
        <Kpi label="Vật tư thiếu giá / lead time" value={`${d.materials_no_price ?? 0} / ${d.materials_no_leadtime ?? 0}`}
             hint="MRP chưa tính được ngân sách và ngày đặt" tone={(d.materials_no_price ?? 0) > 0 ? 'warn' : 'ok'} />
        <Kpi label="Việc chờ bạn duyệt" value={mine?.length ?? 0} hint={`${d.approvals_pending ?? 0} yêu cầu đang chờ toàn hệ thống`} tone="cu" />
      </div>

      <div className="grid gap-4 lg:grid-cols-[2fr_1fr]">
        <section className="card overflow-x-auto">
          <div className="flex items-center justify-between border-b border-line px-4 py-2.5">
            <h2 className="font-semibold">Chờ bạn duyệt</h2>
            <Link className="text-[13px] text-copper" href="/duyet">Mở hộp duyệt</Link>
          </div>
          {mine && mine.length > 0 ? (
            <table className="tbl">
              <thead><tr><th>Chứng từ</th><th>Loại</th><th>Bước</th><th>Người lập</th><th>Gửi lúc</th><th>TT</th></tr></thead>
              <tbody>
                {mine.map((a) => (
                  <tr key={a.id}>
                    <td><Link className="mono font-semibold text-copper" href={`/duyet/${a.id}`}>{a.doc_no}</Link></td>
                    <td>{a.doc_type_name}</td><td>{a.current_level}</td><td>{a.submitted_by_name}</td>
                    <td className="whitespace-nowrap">{df(a.submitted_at, true)}</td><td><StatusPill map={DOC_STATUS} value={a.status} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : <div className="px-4 py-8 text-center text-[13px] text-muted">Không có chứng từ nào chờ bạn duyệt.</div>}
        </section>

        <section className="card p-4">
          <h2 className="mb-2 font-semibold">Việc cần làm trước go-live</h2>
          <ol className="flex list-decimal flex-col gap-2 pl-5 text-[13px]">
            <li>Kỹ thuật/QA rà soát và <Link className="text-copper" href="/san-pham">phát hành spec v1</Link> cho mã đang sản xuất. <Pill tone="warn">{(d.products ?? 0) - (d.specs_released ?? 0)} mã chờ</Pill></li>
            <li>Mua hàng nhập <Link className="text-copper" href="/vat-tu">MOQ, bội số, lead time, giá</Link> cho vật tư. <Pill tone="warn">{d.materials_no_price ?? 0} thiếu giá</Pill></li>
            <li>Quản trị tạo tài khoản cho các phòng ban và gán vai trò.</li>
            <li>Kế hoạch lập <Link className="text-copper" href="/ke-hoach">kế hoạch kỳ đầu</Link> và chạy MRP.</li>
          </ol>
        </section>
      </div>
    </>
  );
}
