import Link from 'next/link';
import { redirect } from 'next/navigation';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Pill, Tabs, Toolbar } from '@/components/ui';
import { df, nf, numIn } from '@/lib/format';
import { SS_STATUS } from '@/lib/safety';
import { can, requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { createSafety, prFromSafety } from '../actions';

export const metadata = { title: 'Tồn dự phòng' };

type SafetyRow = { material_id: string; code: string; name: string; group_code: string | null; uom: string; safety_stock: number; safety_days: number | null;
  safety_set_at: string | null; safety_set_by_name: string | null; available: number; in_quality: number; on_hand: number; incoming: number; requested: number;
  plan_month: number; plan_no: string | null; issued_90d: number; per_day: number; suggest_qty: number; below: boolean; to_buy: number;
  pending_no: string | null; pending_id: string | null };
type Change = { id: string; change_no: string; status: string; reason: string; applied_at: string | null; created_at: string; created_by_name: string | null;
  line_count: number; approval_id: string | null };

const TABS = [
  { key: 'duoi-muc', label: 'Dưới mức dự phòng' },
  { key: 'tat-ca', label: 'Tất cả vật tư' },
  { key: 'phieu', label: 'Phiếu điều chỉnh mức' },
];

// Tồn dự phòng từng vật tư (thường 1 tháng sản xuất): TP Mua lập phiếu điều chỉnh mức → Giám đốc duyệt; dưới mức thì cảnh báo,
// NV mua / TP Mua đề xuất mua bổ sung; dự trù MRP tự mua bù đủ mức.
export default async function SafetyStock({ searchParams }: { searchParams: Promise<{ tab?: string; ok?: string; err?: string }> }) {
  const sp = await searchParams;
  const me = await requireMe();
  if (!(can(me, 'purchase', 'view') || can(me, 'inventory', 'view') || me.roles.includes('BGD'))) redirect('/?err=' + encodeURIComponent('Không có quyền xem tồn dự phòng'));
  const tab = TABS.find((t) => t.key === sp.tab) ?? TABS[0];
  const supabase = await createClient();
  const [{ data: rowsRaw, error }, { data: changes }] = await Promise.all([
    supabase.schema('app').rpc('safety_stock_list'),
    supabase.schema('app').from('v_safety_changes').select('*').order('created_at', { ascending: false }).limit(100).returns<Change[]>(),
  ]);
  const rows = (rowsRaw ?? []) as SafetyRow[];
  const below = rows.filter((r) => r.below);
  const shown = tab.key === 'duoi-muc' ? below : rows;
  const isTpMua = me.roles.includes('MUA_TP') || me.roles.includes('ADMIN');
  const isBuyer = isTpMua || me.roles.includes('MUA_NV');
  const toBuy = rows.filter((r) => Number(r.to_buy) > 0).length;
  // Gợi ý lập phiếu: vật tư MES tính được tiêu hao mà mức đang khác gợi ý (1 tháng sản xuất)
  const proposals = rows.filter((r) => Number(r.suggest_qty) > 0 && Math.abs(Number(r.suggest_qty) - Number(r.safety_stock)) > 0.005 && !r.pending_no).slice(0, 40);
  const blank = Math.max(5, 12 - proposals.length);

  return (
    <>
      <Toolbar title="Tồn dự phòng" reload={`/de-xuat/du-phong?tab=${tab.key}`} actions={<Link className="btn" href="/de-xuat">Đề xuất mua hàng</Link>} />
      <Tabs active={tab.key} items={TABS.map((t) => ({ key: t.key, label: t.label, href: `/de-xuat/du-phong?tab=${t.key}`,
        count: t.key === 'duoi-muc' ? below.length : undefined }))} />
      <Flash ok={sp.ok} err={sp.err ?? error?.message} />
      <p className="mb-3 text-[13.5px] text-muted">
        Mỗi vật tư giữ một mức tồn dự phòng (thường bằng 1 tháng sản xuất). <b>TP Mua</b> lập phiếu điều chỉnh mức theo tình hình thực tế, <b>Giám đốc duyệt</b> (được sửa khi duyệt).
        Tồn (đạt QC + chờ QC) thấp hơn mức thì MES báo TP Mua, NV mua, Kế toán SX, Giám đốc; dự trù MRP tự cộng phần thiếu so với mức dự phòng vào đề nghị mua.
        Tiêu hao/ngày: theo kế hoạch tháng đã duyệt gần nhất (cấp SX ÷ 30), chưa có thì theo thực xuất 90 ngày.
      </p>

      {tab.key !== 'phieu' && (
        <>
          {isBuyer && toBuy > 0 && (
            <form action={prFromSafety} className="card mb-4 flex flex-wrap items-center gap-3 px-4 py-3" id="pr-from-safety">
              <span className="text-[14px]"><b>{toBuy}</b> vật tư còn thiếu so với mức dự phòng (đã trừ tồn, hàng đang về, đề xuất đang có).</span>
              <SubmitButton className="btn btn-pri">Lập đề xuất mua bổ sung</SubmitButton>
            </form>
          )}
          <div className="card mb-4 overflow-x-auto">
            {shown.length > 0 ? (
              <table className="tbl">
                <thead><tr><th>Mã VT</th><th>Vật tư</th><th className="num">Tồn (đạt QC + chờ QC)</th><th className="num">Mức dự phòng</th><th className="num">Đang về</th>
                  <th className="num">Đã đề xuất</th><th className="num">Còn phải mua</th><th className="num">Tiêu hao/ngày</th><th className="num">MES gợi ý</th><th>Duyệt lần cuối</th></tr></thead>
                <tbody>{shown.map((r) => (
                  <tr key={r.material_id} className={r.below ? 'bg-bad/5' : ''}>
                    <td className="mono font-medium">{r.code}</td><td>{r.name}<div className="text-[12px] text-muted">{r.uom}</div></td>
                    <td className={`num ${r.below ? 'font-medium text-bad' : ''}`}>{nf(r.on_hand, 2)}{Number(r.in_quality) > 0 && <div className="text-[12px] text-muted">chờ QC {nf(r.in_quality, 2)}</div>}</td>
                    <td className="num">{Number(r.safety_stock) > 0 ? nf(r.safety_stock, 2) : '—'}{r.safety_days !== null && <div className="text-[12px] text-muted">{nf(r.safety_days, 1)} ngày</div>}
                      {r.pending_no && <div><Link className="text-[12px] text-brand hover:underline" href={`/de-xuat/du-phong/${r.pending_id}`}>{r.pending_no} đang sửa</Link></div>}</td>
                    <td className="num">{nf(r.incoming, 2)}</td><td className="num">{nf(r.requested, 2)}</td>
                    <td className={`num ${Number(r.to_buy) > 0 ? 'font-medium text-warn' : ''}`}>{Number(r.to_buy) > 0 ? nf(r.to_buy, 2) : '—'}</td>
                    <td className="num">{Number(r.per_day) > 0 ? nf(r.per_day, 2) : '—'}<div className="text-[12px] text-muted">{Number(r.plan_month) > 0 ? `KH ${r.plan_no}` : Number(r.issued_90d) > 0 ? 'thực xuất 90 ngày' : ''}</div></td>
                    <td className="num">{Number(r.suggest_qty) > 0 ? nf(r.suggest_qty, 2) : '—'}</td>
                    <td className="text-[13px]">{r.safety_set_at ? <>{r.safety_set_by_name}<div className="text-[12px] text-muted">{df(r.safety_set_at, true)}</div></> : '—'}</td>
                  </tr>
                ))}</tbody>
              </table>
            ) : <Empty>{tab.key === 'duoi-muc' ? 'Không vật tư nào dưới mức dự phòng.' : 'Chưa có vật tư.'}</Empty>}
          </div>
        </>
      )}

      {tab.key === 'phieu' && (
        <div className="card mb-4 overflow-x-auto">
          {(changes ?? []).length > 0 ? (
            <table className="tbl">
              <thead><tr><th>Phiếu</th><th>Lý do</th><th className="num">Vật tư</th><th>Người lập</th><th>Trạng thái</th><th /></tr></thead>
              <tbody>{(changes ?? []).map((c) => (
                <tr key={c.id}>
                  <td className="mono"><Link className="link font-medium" href={`/de-xuat/du-phong/${c.id}`}>{c.change_no}</Link></td>
                  <td className="min-w-[240px]">{c.reason}</td><td className="num">{c.line_count}</td>
                  <td>{c.created_by_name}<div className="text-[12px] text-muted">{df(c.created_at, true)}</div></td>
                  <td><Pill tone={SS_STATUS[c.status]?.[1] ?? 'mute'}>{SS_STATUS[c.status]?.[0] ?? c.status}</Pill>{c.applied_at && <div className="text-[12px] text-muted">áp {df(c.applied_at, true)}</div>}</td>
                  <td>{c.approval_id && <Link className="btn btn-sm btn-soft" href={`/duyet/${c.approval_id}`}>Quy trình duyệt</Link>}</td>
                </tr>
              ))}</tbody>
            </table>
          ) : <Empty>Chưa có phiếu điều chỉnh mức dự phòng.</Empty>}
        </div>
      )}

      {isTpMua && (
        <section className="card" id="lap-phieu">
          <div className="card-h"><h2>Lập phiếu điều chỉnh mức dự phòng (TP Mua)</h2><span className="text-[12.5px] font-normal text-muted">Giám đốc duyệt</span></div>
          <form action={createSafety} className="flex flex-col gap-3 p-4">
            <datalist id="ss-mats">{rows.map((r) => <option key={r.code} value={`${r.code} · ${r.name} (${r.uom})`} />)}</datalist>
            <label className="lbl"><span className="req">Lý do điều chỉnh</span>
              <input className="inp" name="reason" required placeholder="VD: dự phòng 1 tháng sản xuất theo kế hoạch tháng 11; NCC đồng giao chậm" /></label>
            <div className="overflow-x-auto rounded border border-line">
              <table className="tbl">
                <thead><tr><th>Vật tư</th><th className="num">Mức hiện tại</th><th className="w-28">Số ngày SX</th><th className="w-36">Mức dự phòng mới</th><th>Ghi chú</th></tr></thead>
                <tbody>
                  {proposals.map((r, i) => (
                    <tr key={r.material_id}>
                      <td><input className="inp" name={`code_${i}`} list="ss-mats" defaultValue={r.code} aria-label={`Vật tư dòng ${i + 1}`} /></td>
                      <td className="num">{nf(r.safety_stock, 2)} {r.uom}</td>
                      <td><input className="inp text-right" name={`days_${i}`} defaultValue={numIn(r.safety_days ?? 30)} inputMode="decimal" aria-label={`Số ngày dòng ${i + 1}`} /></td>
                      <td><input className="inp text-right" name={`qty_${i}`} defaultValue={numIn(r.suggest_qty)} inputMode="decimal" aria-label={`Mức mới dòng ${i + 1}`} /></td>
                      <td><input className="inp" name={`note_${i}`} placeholder={`MES gợi ý ${nf(r.suggest_qty, 2)}`} aria-label={`Ghi chú dòng ${i + 1}`} /></td>
                    </tr>
                  ))}
                  {Array.from({ length: blank }, (_, j) => {
                    const i = proposals.length + j;
                    return (
                      <tr key={`b${i}`}>
                        <td><input className="inp" name={`code_${i}`} list="ss-mats" aria-label={`Vật tư dòng ${i + 1}`} /></td><td />
                        <td><input className="inp text-right" name={`days_${i}`} inputMode="decimal" aria-label={`Số ngày dòng ${i + 1}`} /></td>
                        <td><input className="inp text-right" name={`qty_${i}`} inputMode="decimal" aria-label={`Mức mới dòng ${i + 1}`} /></td>
                        <td><input className="inp" name={`note_${i}`} aria-label={`Ghi chú dòng ${i + 1}`} /></td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
            <p className="text-[12.5px] text-muted">Để trống ô “Mức dự phòng mới” thì MES tính = tiêu hao/ngày × số ngày. Dòng gợi ý sẵn: vật tư có tiêu hao mà mức đang khác 1 tháng sản xuất; xóa mã vật tư để bỏ dòng.</p>
            <div><SubmitButton className="btn btn-pri">Lập phiếu (nháp)</SubmitButton></div>
          </form>
        </section>
      )}
    </>
  );
}
