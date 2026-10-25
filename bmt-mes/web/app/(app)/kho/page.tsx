import { redirect } from 'next/navigation';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Pill, Tabs, Toolbar } from '@/components/ui';
import { df, nf } from '@/lib/format';
import { can, requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { reviewDocs, saveTolerance } from './actions';

export const metadata = { title: 'Kiểm soát kho' };

type Doc = {
  id: string; doc_no: string; doc_type_name: string; warehouse_name: string; doc_date: string; status: string; note: string | null;
  wo_no: string | null; posted_at: string | null; posted_by_name: string | null; created_by_name: string | null;
  reviewed_at: string | null; reviewed_by_name: string | null; mine: boolean; line_count: number;
};
type Cu = {
  wo_id: string; wo_no: string; product_code: string; wo_status: string; finished: boolean; good_m: number;
  issued_kg: number; product_kg: number; scrap_kg: number; diff_kg: number; diff_pct: number | null; tolerance_pct: number; over_limit: boolean;
};

const WO_STATUS: Record<string, string> = {
  RELEASED: 'Đã phát lệnh', IN_PROGRESS: 'Đang sản xuất', PAUSED: 'Tạm dừng', PRODUCED: 'Đã sản xuất xong', QC_PENDING: 'Chờ QC', CLOSED: 'Đã đóng',
};

export default async function StockControl({ searchParams }: { searchParams: Promise<{ tab?: string; ok?: string; err?: string }> }) {
  const sp = await searchParams;
  const me = await requireMe();
  if (!(can(me, 'inventory', 'view') || can(me, 'production', 'view') || can(me, 'cost', 'view'))) {
    redirect('/?err=' + encodeURIComponent('Bạn chưa được cấp quyền vào trang này'));
  }
  const tab = sp.tab ?? (can(me, 'inventory', 'view') ? 'cho-kiem' : 'dong');
  const reviewer = me.roles.includes('KT_KHO');
  const supabase = await createClient();

  const [{ count: waiting }, docsRes, cuRes, { data: setting }] = await Promise.all([
    supabase.schema('app').from('v_stock_docs').select('id', { count: 'exact', head: true }).eq('status', 'POSTED').is('reviewed_at', null),
    tab === 'dong' ? Promise.resolve({ data: [] as Doc[], error: null })
      : tab === 'da-kiem'
        ? supabase.schema('app').from('v_stock_docs').select('*').not('reviewed_at', 'is', null).order('reviewed_at', { ascending: false }).limit(100).returns<Doc[]>()
        : supabase.schema('app').from('v_stock_docs').select('*').eq('status', 'POSTED').is('reviewed_at', null).order('posted_at', { ascending: true }).limit(300).returns<Doc[]>(),
    tab === 'dong' ? supabase.schema('app').rpc('copper_balance', { p_days: 90 }) : Promise.resolve({ data: [] as Cu[], error: null }),
    supabase.schema('mfg').from('control_settings').select('value, name, owner_role, updated_at').eq('key', 'copper_tolerance_pct').maybeSingle(),
  ]);
  const docs = docsRes.data ?? [];
  const cu = (cuRes.data ?? []) as Cu[];
  const canTol = (setting?.owner_role && me.roles.includes(setting.owner_role)) || can(me, 'admin', 'edit');

  return (
    <>
      <Toolbar title="Kiểm soát kho" reload={`/kho?tab=${tab}`} />
      <Tabs active={tab} items={[
        ...(can(me, 'inventory', 'view') ? [
          { key: 'cho-kiem', label: 'Phiếu chờ kiểm', href: '/kho?tab=cho-kiem', count: waiting ?? 0 },
          { key: 'da-kiem', label: 'Đã kiểm', href: '/kho?tab=da-kiem' },
        ] : []),
        { key: 'dong', label: 'Cân bằng đồng', href: '/kho?tab=dong' },
      ]} />
      <Flash ok={sp.ok} err={sp.err ?? docsRes.error?.message ?? cuRes.error?.message} />

      {tab !== 'dong' && (
        <>
          <p className="mb-3 text-[13.5px] text-muted">
            {tab === 'cho-kiem'
              ? <>Phiếu nhập, xuất đã ghi sổ, chờ Kế toán SX đối chiếu trong ngày (với PO, phiếu lĩnh, phiếu kiểm tra chất lượng). Việc kiểm không chặn ghi sổ. Không tự kiểm phiếu do mình lập hoặc ghi sổ.</>
              : <>100 phiếu kiểm gần nhất.</>}
          </p>
          {docs.length === 0 ? <Empty>{tab === 'cho-kiem' ? 'Không còn phiếu chờ kiểm.' : 'Chưa có phiếu nào được kiểm.'}</Empty> : (
            <form action={reviewDocs} className="card overflow-x-auto">
              <table className="tbl">
                <thead><tr>
                  {tab === 'cho-kiem' && reviewer && <th className="w-8"><span className="sr-only">Chọn</span></th>}
                  <th>Số phiếu</th><th>Loại</th><th>Kho</th><th>Lệnh SX</th><th>Ngày</th><th className="text-right">Dòng</th><th>Ghi sổ</th>
                  {tab === 'da-kiem' && <th>Đã kiểm</th>}<th>Ghi chú</th>
                </tr></thead>
                <tbody>
                  {docs.map((d) => (
                    <tr key={d.id}>
                      {tab === 'cho-kiem' && reviewer && (
                        <td>{d.mine ? <span className="text-[12px] text-muted" title="Phiếu do bạn lập hoặc ghi sổ">—</span>
                          : <input type="checkbox" name="ids" value={d.id} aria-label={`Chọn ${d.doc_no}`} className="accent-[rgb(var(--brand))]" />}</td>
                      )}
                      <td className="mono whitespace-nowrap">{d.doc_no}</td>
                      <td className="whitespace-nowrap">{d.doc_type_name}</td>
                      <td className="whitespace-nowrap">{d.warehouse_name}</td>
                      <td className="mono">{d.wo_no ?? '—'}</td>
                      <td className="whitespace-nowrap">{df(d.doc_date)}</td>
                      <td className="text-right tabular-nums">{d.line_count}</td>
                      <td className="whitespace-nowrap">{df(d.posted_at, true)}<div className="text-[12px] text-muted">{d.posted_by_name ?? ''}</div></td>
                      {tab === 'da-kiem' && <td className="whitespace-nowrap">{df(d.reviewed_at, true)}<div className="text-[12px] text-muted">{d.reviewed_by_name ?? ''}</div></td>}
                      <td className="min-w-[200px] text-[13px]">{d.note ?? ''}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
              {tab === 'cho-kiem' && reviewer && (
                <div className="flex items-center gap-3 border-t border-line p-3">
                  <SubmitButton>Đánh dấu đã kiểm</SubmitButton>
                  <span className="text-[12.5px] text-muted">Chỉ đánh dấu phiếu đã đối chiếu khớp. Phiếu sai: báo Quản lý SX lập phiếu điều chỉnh.</span>
                </div>
              )}
            </form>
          )}
        </>
      )}

      {tab === 'dong' && (
        <>
          <div className="mb-3 flex flex-wrap items-end gap-3">
            <p className="mr-auto max-w-[760px] text-[13.5px] text-muted">
              Đồng xuất cho lệnh (kim loại dẫn, xuất trừ trả lại) phải bằng đồng trong thành phẩm (mét đóng gói × kg/km lõi đồng + drain)
              cộng phế đồng nộp lại. Chỉ đánh giá khi lệnh đã sản xuất xong; lệnh đang chạy còn đồng nằm trong bán thành phẩm.
            </p>
            <form action={saveTolerance} className="flex items-end gap-2">
              <label className="lbl">Lệch cho phép (%)
                <input className="inp w-24 text-right" name="value" inputMode="decimal" defaultValue={nf(setting?.value, 1)} disabled={!canTol} />
              </label>
              {canTol && <SubmitButton className="btn btn-soft">Lưu</SubmitButton>}
            </form>
          </div>
          {cu.length === 0 ? <Empty>Chưa có lệnh sản xuất nào trong 90 ngày qua.</Empty> : (
            <div className="card overflow-x-auto">
              <table className="tbl">
                <thead><tr>
                  <th>Lệnh SX</th><th>Mã cáp</th><th>Trạng thái</th><th className="text-right">Mét thành phẩm</th>
                  <th className="text-right">Đồng xuất (kg)</th><th className="text-right">Trong thành phẩm (kg)</th><th className="text-right">Phế đồng (kg)</th>
                  <th className="text-right">Lệch (kg)</th><th className="text-right">Lệch (%)</th><th>Đánh giá</th>
                </tr></thead>
                <tbody>
                  {cu.map((r) => (
                    <tr key={r.wo_id} className={r.over_limit ? 'bg-bad-soft' : ''}>
                      <td className="mono whitespace-nowrap">{r.wo_no}</td>
                      <td className="mono whitespace-nowrap">{r.product_code}</td>
                      <td className="whitespace-nowrap">{WO_STATUS[r.wo_status] ?? r.wo_status}</td>
                      <td className="text-right tabular-nums">{nf(r.good_m)}</td>
                      <td className="text-right tabular-nums">{nf(r.issued_kg, 2)}</td>
                      <td className="text-right tabular-nums">{nf(r.product_kg, 2)}</td>
                      <td className="text-right tabular-nums">{nf(r.scrap_kg, 2)}</td>
                      <td className="text-right tabular-nums">{nf(r.diff_kg, 2)}</td>
                      <td className="text-right tabular-nums">{r.diff_pct === null ? '—' : nf(r.diff_pct, 2)}</td>
                      <td>{!r.finished ? <Pill tone="mute">Đang chạy</Pill> : r.over_limit ? <Pill tone="bad">Vượt ngưỡng</Pill> : <Pill tone="ok">Đạt</Pill>}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </>
  );
}
