import Link from 'next/link';
import { notFound } from 'next/navigation';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, PageHeader, Pill, StatusPill } from '@/components/ui';
import { DOC_STATUS, SPEC_STATUS, df, nf } from '@/lib/format';
import { can, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { createPr, deleteLine, runMrp, saveLine, submitPlan } from '../actions';

const MRP_TONE: Record<string, 'ok' | 'warn' | 'bad' | 'mute' | 'info'> = {
  'Không cần mua': 'mute', 'Cập nhật giá': 'warn', 'Thiếu lead time': 'warn', 'Trễ': 'bad', 'Đặt hàng': 'info',
};

export default async function PlanDetail({ params, searchParams }:
  { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; err?: string }> }) {
  const { id } = await params;
  const sp = await searchParams;
  const me = await requirePerm('plan', 'view');
  const supabase = await createClient();
  const { data: plan } = await supabase.schema('app').from('v_plans').select('*').eq('id', id).maybeSingle();
  if (!plan) notFound();
  const [{ data: lines }, { data: products }, { data: mrp }, { data: run }] = await Promise.all([
    supabase.schema('app').from('v_plan_lines').select('*').eq('plan_id', id).order('product_code'),
    supabase.schema('app').from('v_products').select('id, code, description, spec_status, default_pack, default_m_per_pack, default_brand').order('code'),
    plan.last_run_id
      ? supabase.schema('app').from('v_mrp_lines').select('*').eq('run_id', plan.last_run_id).order('suggest_qty', { ascending: false }).order('material_code')
      : Promise.resolve({ data: [] as never[] }),
    plan.last_run_id
      ? supabase.schema('plan').from('mrp_runs').select('run_at, budget_vnd, missing_price_count').eq('id', plan.last_run_id).single()
      : Promise.resolve({ data: null }),
  ]);
  const draft = plan.status === 'DRAFT';
  const editable = draft && can(me, 'plan', 'edit');
  const showPrice = me.can_see_price;
  const toBuy = (mrp ?? []).filter((m) => Number(m.suggest_qty) > 0).length;

  return (
    <>
      <PageHeader title={`${plan.plan_no} · ${plan.period_label}`}
        sub={<>Ngày cần vật tư {df(plan.material_need_date)} · {plan.mode === 'OFFICIAL' ? 'Chính thức' : 'Sơ bộ'} · <StatusPill map={DOC_STATUS} value={plan.status} /></>}
        actions={<>
          <Link className="btn" href="/ke-hoach">← Danh sách</Link>
          {can(me, 'plan', 'create') && (lines?.length ?? 0) > 0 && plan.status !== 'CLOSED' && (
            <form action={runMrp}><input type="hidden" name="plan_id" value={id} /><SubmitButton className="btn">Chạy MRP</SubmitButton></form>
          )}
          {draft && plan.last_run_id && can(me, 'plan', 'create') && (
            <form action={submitPlan}>
              <input type="hidden" name="plan_id" value={id} /><input type="hidden" name="plan_no" value={plan.plan_no} />
              <input type="hidden" name="summary" value={`${plan.period_label}: ${plan.line_count} SKU, ${nf(plan.total_m)} m, ${toBuy} vật tư cần mua`} />
              <SubmitButton>Gửi duyệt kế hoạch</SubmitButton>
            </form>
          )}
          {plan.status === 'APPROVED' && plan.mode === 'OFFICIAL' && plan.last_run_id && can(me, 'plan', 'create') && (
            <form action={createPr}><input type="hidden" name="plan_id" value={id} /><input type="hidden" name="run_id" value={plan.last_run_id} /><SubmitButton>Sinh PR</SubmitButton></form>
          )}
        </>} />
      <Flash ok={sp.ok} err={sp.err} />

      <section className="card mb-4 overflow-x-auto">
        <div className="border-b border-line px-4 py-2.5 font-semibold">Dòng kế hoạch · {nf(plan.total_m)} m</div>
        <table className="tbl">
          <thead><tr><th>SKU</th><th>Quy cách</th><th>Spec</th><th className="num">Sản lượng (m)</th><th className="num">Số lô</th><th>Đóng gói</th><th className="num">m/kiện</th><th className="num">Số kiện</th><th className="num">kg/kiện</th><th>TH</th>{editable && <th />}</tr></thead>
          <tbody>
            {(lines ?? []).map((l) => (
              <tr key={l.id}>
                <td className="mono font-semibold">{l.product_code}</td><td className="min-w-[200px]">{l.description}</td>
                <td><StatusPill map={SPEC_STATUS} value={l.spec_status} /></td>
                <td className="num">{nf(l.qty_m)}</td><td className="num">{l.run_lots}</td><td>{l.pack_type}</td>
                <td className="num">{nf(l.m_per_pack)}</td><td className="num">{nf(l.packs)}</td>
                <td className={`num ${Number(l.kg_per_pack) > 100 ? 'font-semibold text-bad' : ''}`}>{nf(l.kg_per_pack, 1)}</td>
                <td>{l.brand}</td>
                {editable && (
                  <td><form action={deleteLine}><input type="hidden" name="plan_id" value={id} /><input type="hidden" name="line_id" value={l.id} /><SubmitButton className="btn btn-bad" pendingText="…">Xóa</SubmitButton></form></td>
                )}
              </tr>
            ))}
            {(lines ?? []).length === 0 && <tr><td colSpan={11}><Empty>Chưa có dòng nào.</Empty></td></tr>}
          </tbody>
        </table>
        {editable && (
          <form action={saveLine} className="grid gap-3 border-t border-line bg-sunk/40 p-4 md:grid-cols-[2fr_1fr_0.7fr_1fr_0.8fr_0.8fr_auto] md:items-end">
            <input type="hidden" name="plan_id" value={id} />
            <label className="lbl">Sản phẩm
              <select className="inp inp-y" name="product_id" required>
                {(products ?? []).map((p) => (
                  <option key={p.id} value={p.id}>{p.code} · {p.description}{p.spec_status !== 'RELEASED' ? ' (spec chưa phát hành)' : ''}</option>
                ))}
              </select>
            </label>
            <label className="lbl">Sản lượng (m)<input className="inp inp-y text-right" name="qty_m" inputMode="decimal" required /></label>
            <label className="lbl">Số lô<input className="inp inp-y text-right" name="run_lots" defaultValue={1} inputMode="numeric" required /></label>
            <label className="lbl">Đóng gói<select className="inp inp-y" name="pack_type"><option>Bobin gỗ</option><option>Cuộn PE</option></select></label>
            <label className="lbl">m/kiện<input className="inp inp-y text-right" name="m_per_pack" defaultValue={500} inputMode="decimal" required /></label>
            <label className="lbl">Thương hiệu<select className="inp inp-y" name="brand"><option>KAVIX</option><option>HEIZKA</option></select></label>
            <SubmitButton>Thêm dòng</SubmitButton>
          </form>
        )}
        {editable && plan.mode === 'OFFICIAL' && <p className="px-4 pb-3 text-[12px] text-muted">Kế hoạch chính thức chỉ chạy MRP khi mọi mã đã phát hành spec. Mã dây đơn (SIF/PVC) thường dùng Cuộn PE 100 m/kiện.</p>}
      </section>

      <section className="card overflow-x-auto">
        <div className="flex flex-wrap items-center justify-between gap-2 border-b border-line px-4 py-2.5">
          <div className="font-semibold">Kết quả MRP · đề nghị mua</div>
          {run && <div className="text-[12px] text-muted">Chạy lúc {df(run.run_at, true)} · {toBuy} vật tư cần mua{showPrice && <> · ngân sách {nf(run.budget_vnd)} đ</>}{run.missing_price_count ? <> · <Pill tone="warn">{run.missing_price_count} mã thiếu giá</Pill></> : null}</div>}
        </div>
        {mrp && mrp.length > 0 ? (
          <table className="tbl">
            <thead><tr><th>Mã VT</th><th>Vật tư</th><th>ĐVT</th><th className="num">Lý thuyết</th><th className="num">Tổng cấp SX</th><th className="num">Tồn KD</th><th className="num">Chờ QC</th><th className="num">Hàng về</th><th className="num">Thiếu ròng</th><th className="num">Bội số</th><th className="num">Đề nghị mua</th>{showPrice && <th className="num">Thành tiền</th>}<th>Đặt chậm nhất</th><th>TT</th></tr></thead>
            <tbody>
              {mrp.map((m) => (
                <tr key={m.id}>
                  <td className="mono font-semibold">{m.material_code}</td><td className="min-w-[160px]">{m.material_name}</td><td>{m.uom}</td>
                  <td className="num">{nf(m.theoretical, 2)}</td><td className="num font-semibold">{nf(m.total_issue, 2)}</td>
                  <td className="num">{nf(m.available, 1)}</td><td className="num text-muted">{nf(m.in_quality, 1)}</td><td className="num">{nf(m.incoming, 1)}</td>
                  <td className={`num ${Number(m.net_short) > 0 ? 'text-bad' : 'text-muted'}`}>{nf(m.net_short, 2)}</td>
                  <td className="num">{nf(m.pack_multiple)}</td><td className="num font-semibold">{nf(m.suggest_qty)}</td>
                  {showPrice && <td className="num">{m.amount === null ? '—' : nf(m.amount)}</td>}
                  <td className="whitespace-nowrap">{df(m.latest_order_date)}</td>
                  <td><Pill tone={MRP_TONE[m.status] ?? 'mute'}>{m.status}</Pill></td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : <Empty>Chưa chạy MRP. Thêm dòng kế hoạch rồi bấm “Chạy MRP”.</Empty>}
      </section>
    </>
  );
}
