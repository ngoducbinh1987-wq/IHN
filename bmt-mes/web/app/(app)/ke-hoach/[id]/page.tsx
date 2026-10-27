import Link from 'next/link';
import { Pencil, Printer } from 'lucide-react';
import { notFound } from 'next/navigation';
import { PackFields, type PackOption } from '@/components/pack-fields';
import { SubmitButton } from '@/components/submit-button';
import { AdminTools } from '@/components/admin-tools';
import { StageBar, type Stage } from '@/components/stage-bar';
import { Empty, Flash, Pill, StatusPill, Toolbar } from '@/components/ui';
import type { Approval } from '@/lib/approvals';
import { DOC_STATUS, SPEC_STATUS, df, nf } from '@/lib/format';
import { can, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { approve } from '../../duyet/[id]/actions';
import { adjustMrp, chairRemoveLine, chairSaveLine, createAdj, createPr, deleteLine, runMrp, saveLine, submitPlan } from '../actions';

const ADJ_STATUS: Record<string, [string, 'ok' | 'warn' | 'bad' | 'mute' | 'info']> = {
  DRAFT: ['Nháp', 'warn'], PENDING_APPROVAL: ['Chờ Chủ tịch duyệt', 'info'], APPROVED: ['Đã duyệt, đã áp', 'ok'], CANCELLED: ['Đã hủy', 'mute'],
};
const MRP_TONE: Record<string, 'ok' | 'warn' | 'bad' | 'mute' | 'info'> = {
  'Không cần mua': 'mute', 'Cập nhật giá': 'warn', 'Thiếu lead time': 'warn', 'Trễ': 'bad', 'Đặt hàng': 'info',
};

export default async function PlanDetail({ params, searchParams }:
  { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; err?: string; sua?: string; mrp?: string }> }) {
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
  const [{ data: req }, { data: flow }, { data: flowHead }, { data: packOpts }, { data: edits }, { data: prs }] = await Promise.all([
    supabase.schema('app').from('v_approvals').select('*').eq('doc_id', id).order('submitted_at', { ascending: false }).limit(1).maybeSingle<Approval>(),
    supabase.schema('wf').from('approval_steps').select('seq, level_label').eq('doc_type', 'PLAN').eq('enabled', true).order('seq'),
    supabase.schema('wf').from('approval_flows').select('submit_label, submit_role, submit_user_ids').eq('doc_type', 'PLAN').maybeSingle(),
    supabase.schema('app').from('v_pack_options').select('pack_type, m_per_pack').order('pack_type').order('sort').returns<PackOption[]>(),
    supabase.schema('app').from('v_mrp_edits').select('*').eq('plan_id', id).order('edited_at', { ascending: false }).limit(50),
    plan.last_run_id
      ? supabase.schema('purchase').from('purchase_requests').select('id, pr_no').eq('mrp_run_id', plan.last_run_id).neq('status', 'CANCELLED')
      : Promise.resolve({ data: [] as { id: string; pr_no: string }[] }),
  ]);
  const [{ data: levels }, { data: adjs }] = await Promise.all([
    plan.last_run_id
      ? supabase.schema('app').from('v_mrp_products').select('*').eq('run_id', plan.last_run_id).order('id')
      : Promise.resolve({ data: [] as Record<string, never>[] }),
    supabase.schema('app').from('v_plan_adjustments').select('*').eq('plan_id', id).neq('status', 'CANCELLED').order('created_at', { ascending: false }),
  ]);
  const { data: chairEdits } = await supabase.schema('app').from('v_plan_chair_edits').select('*').eq('plan_id', id).order('edited_at', { ascending: false });
  const canAdj = plan.status === 'APPROVED' && (can(me, 'plan', 'create') || me.roles.includes('SX_TP'));
  const stages: Stage[] = req?.steps ?? [{ seq: 0, label: flowHead?.submit_label ?? 'Lập kế hoạch', state: 'current' }, ...(flow ?? []).map((s) => ({ seq: s.seq, label: s.level_label, state: 'todo' as const }))];
  const draft = plan.status === 'DRAFT';
  // Gửi duyệt: đúng người/vai trò được cấu hình ở bước lập; không cấu hình thì người có quyền lập kế hoạch
  // (quy trình 28/10/2026: TP SX lập, chạy MRP → Giám đốc duyệt → Chủ tịch HĐQT chốt; database kiểm lại bằng wf.can_submit)
  const canSubmit = (flowHead?.submit_role ? me.roles.includes(flowHead.submit_role) : can(me, 'plan', 'create') || me.roles.includes('BGD'))
    && (!(flowHead?.submit_user_ids?.length) || flowHead.submit_user_ids.includes(me.id));
  const canMakePr = can(me, 'plan', 'create') || can(me, 'purchase', 'create');
  const editable = draft && can(me, 'plan', 'edit');
  // Bước cuối (Chủ tịch HĐQT chốt): người giữ bước được sửa sản lượng, thêm, bỏ mã rồi chốt (database kiểm lại)
  const chairTurn = plan.status === 'PENDING_APPROVAL' && req?.status === 'PENDING' && req.my_turn && req.step_index === req.step_total;
  const lineEdit = editable || chairTurn;
  const stale = Boolean(plan.mrp_stale);
  const pr = prs?.[0];
  // Điều chỉnh MRP: chỉ TP Mua hàng / TP Kỹ thuật-QA; khóa khi chờ duyệt, đã đóng, MRP cũ hoặc đã sinh PR (database kiểm tra lại)
  const canAdjust = me.roles.includes('MUA_TP') || me.roles.includes('KT_TP');
  const mrpLock = !['DRAFT', 'APPROVED'].includes(plan.status) ? 'kế hoạch đang chờ duyệt hoặc đã đóng'
    : stale ? 'dòng kế hoạch đã thay đổi, cần chạy lại MRP' : pr ? `đã sinh ${pr.pr_no}` : null;
  const adjustable = canAdjust && !mrpLock;
  const packs = packOpts ?? [];
  const showPrice = me.can_see_price;
  const toBuy = (mrp ?? []).filter((m) => Number(m.suggest_qty) > 0).length;

  return (
    <>
      <Toolbar title={<span>{plan.plan_no} – {plan.period_label}</span>}
        actions={<>
          {req && <Link className="btn btn-soft" href={`/duyet/${req.id}`}>Xem quy trình duyệt</Link>}
          {can(me, 'plan', 'create') && (lines?.length ?? 0) > 0 && plan.status !== 'CLOSED' && (
            <form action={runMrp}><input type="hidden" name="plan_id" value={id} /><SubmitButton className="btn btn-soft">Chạy MRP</SubmitButton></form>
          )}
          <Link className="btn btn-soft" href={`/in/ke-hoach/${id}`} target="_blank"><Printer size={16} />In</Link>
          {draft && plan.last_run_id && !stale && canSubmit && (
            <form action={submitPlan}>
              <input type="hidden" name="plan_id" value={id} /><input type="hidden" name="plan_no" value={plan.plan_no} />
              <input type="hidden" name="summary" value={`${plan.period_label}: ${plan.line_count} SKU, ${nf(plan.total_m)} m, ${toBuy} vật tư cần mua`} />
              <SubmitButton>Gửi duyệt kế hoạch</SubmitButton>
            </form>
          )}
          {plan.status === 'APPROVED' && plan.mode === 'OFFICIAL' && plan.last_run_id && !stale && !pr && canMakePr && (
            <form action={createPr}><input type="hidden" name="plan_id" value={id} /><input type="hidden" name="run_id" value={plan.last_run_id} /><SubmitButton>Sinh đề xuất mua (PR)</SubmitButton></form>
          )}
          <Link className="btn" href="/ke-hoach">Đóng</Link>
        </>} />
      <div className="-mx-4 mb-4 md:-mx-5"><StageBar stages={stages} /></div>
      <Flash ok={sp.ok} err={sp.err} />
      {me.roles.includes('ADMIN') && (
        <AdminTools docType="PLAN" docId={id} docNo={plan.plan_no} requestId={req?.id} pending={req?.status === 'PENDING'} canReopen={plan.status !== 'DRAFT'}
          back={`/ke-hoach/${id}`} after="/ke-hoach" />
      )}
      {stale && (
        <div role="alert" id="mrp-stale" className="mb-4 rounded border-l-4 border-warn bg-warn-soft px-4 py-2.5 text-[14px]">
          Dòng kế hoạch đã thay đổi sau lần chạy MRP gần nhất. <b>Bấm “Chạy MRP”</b> để tính lại nhu cầu vật tư trước khi gửi duyệt hoặc sinh đề xuất mua.
        </div>
      )}
      {chairTurn && req && (
        <div id="chair-turn" aria-label="Bước chốt kế hoạch" className="mb-4 flex flex-wrap items-center gap-3 rounded border-l-4 border-brand bg-brand-soft px-4 py-3 text-[14px]">
          <div className="mr-auto min-w-0">
            <b>Bạn đang ở bước chốt kế hoạch.</b> Sửa sản lượng, số lô, đóng gói bằng nút bút; thêm mã ở form dưới bảng; bỏ mã trong form sửa dòng.
            Mỗi lần sửa phải ghi lý do, MES tự chạy lại MRP. Xong bấm <b>Chốt kế hoạch</b>; muốn TP SX làm lại thì Trả lại ở Quy trình duyệt.
          </div>
          <form action={approve}><input type="hidden" name="id" value={req.id} /><SubmitButton pendingText="Đang chốt…">Chốt kế hoạch</SubmitButton></form>
          <Link className="btn" href={`/duyet/${req.id}`}>Trả lại / ý kiến</Link>
        </div>
      )}
      <div className="mb-3 flex flex-wrap gap-x-6 gap-y-1 text-[14px]">
        <span><span className="text-muted">Ngày cần vật tư:</span> {df(plan.material_need_date)}</span>
        <span><span className="text-muted">Chế độ:</span> {plan.mode === 'OFFICIAL' ? 'Chính thức' : 'Sơ bộ'}</span>
        <span><span className="text-muted">Trạng thái:</span> <StatusPill map={DOC_STATUS} value={plan.status} /></span>
      </div>

      <section className="card mb-4 overflow-x-auto">
        <div className="card-h">Dòng kế hoạch · {nf(plan.total_m)} m · {nf(plan.total_packs)} kiện</div>
        <table className="tbl">
          <thead><tr><th>SKU</th><th>Quy cách</th><th>Spec</th><th className="num">Sản lượng (m)</th><th className="num">Số lô</th><th>Đóng gói</th><th className="num">m/kiện</th><th className="num">Số kiện</th><th className="num">kg/kiện</th><th>TH</th>{lineEdit && <th />}</tr></thead>
          <tbody>
            {(lines ?? []).map((l) => lineEdit && sp.sua === l.id ? (
              <tr key={l.id} className="bg-brand-soft/40">
                <td colSpan={11} className="p-0">
                  <LineForm planId={id} line={l} products={products ?? []} packs={packs} chair={chairTurn} />
                </td>
              </tr>
            ) : (
              <tr key={l.id}>
                <td className="mono font-medium">{l.product_code}</td><td className="min-w-[200px]">{l.description}</td>
                <td><StatusPill map={SPEC_STATUS} value={l.spec_status} /></td>
                <td className="num">{nf(l.qty_m)}</td><td className="num">{l.run_lots}</td><td>{l.pack_type}</td>
                <td className="num">{nf(l.m_per_pack)}</td>
                <td className="num whitespace-nowrap">{nf(l.packs)}
                  {Number(l.odd_m) > 0 && <div className="text-[12px] text-muted">{nf(l.full_packs)} chẵn + 1 lẻ {nf(l.odd_m)} m</div>}</td>
                <td className={`num ${Number(l.kg_per_pack) > 100 ? 'font-medium text-bad' : ''}`}>{nf(l.kg_per_pack, 1)}</td>
                <td>{l.brand}</td>
                {lineEdit && (
                  <td><div className="flex gap-1.5">
                    <Link className="btn btn-soft px-2.5" href={`/ke-hoach/${id}?sua=${l.id}`} title="Sửa dòng" aria-label={`Sửa dòng ${l.product_code}`}><Pencil size={16} /></Link>
                    {editable && <form action={deleteLine}><input type="hidden" name="plan_id" value={id} /><input type="hidden" name="line_id" value={l.id} /><SubmitButton className="btn btn-bad" pendingText="…">Xóa</SubmitButton></form>}
                  </div></td>
                )}
              </tr>
            ))}
            {(lines ?? []).length === 0 && <tr><td colSpan={11}><Empty>Chưa có dòng nào.</Empty></td></tr>}
          </tbody>
        </table>
        {lineEdit && !sp.sua && <LineForm planId={id} products={products ?? []} packs={packs} chair={chairTurn} />}
        {editable && plan.mode === 'OFFICIAL' && <p className="px-4 pb-3 text-[12px] text-muted">Kế hoạch chính thức chỉ chạy MRP khi mọi mã đã phát hành spec. Mã dây đơn (SIF/PVC) thường dùng Cuộn PE 100/200 m/kiện; cáp dùng Bobin gỗ 500 hoặc 305 m/kiện.</p>}
      </section>

      {(chairEdits ?? []).length > 0 && (
        <section className="card mb-4 overflow-x-auto" id="chair-edits">
          <div className="card-h">Chủ tịch HĐQT chỉnh khi chốt</div>
          <table className="tbl">
            <thead><tr><th>Lúc</th><th>Người</th><th>SKU</th><th>Thay đổi</th><th>Lý do</th></tr></thead>
            <tbody>
              {(chairEdits ?? []).map((e) => (
                <tr key={e.id}>
                  <td className="whitespace-nowrap">{df(e.edited_at, true)}</td><td>{e.edited_by_name}</td>
                  <td><span className="mono">{e.product_code}</span></td>
                  <td className="whitespace-nowrap">{e.action === 'ADD' ? <>Thêm <b>{nf(e.new_data?.qty_m)} m</b></>
                    : e.action === 'REMOVE' ? <>Bỏ mã ({nf(e.old_data?.qty_m)} m)</>
                    : <>{nf(e.old_data?.qty_m)} → <b>{nf(e.new_data?.qty_m)} m</b>{e.old_data?.run_lots !== e.new_data?.run_lots && <> · lô {e.old_data?.run_lots} → {e.new_data?.run_lots}</>}
                      {(e.old_data?.pack_type !== e.new_data?.pack_type || Number(e.old_data?.m_per_pack) !== Number(e.new_data?.m_per_pack)) && <> · {e.new_data?.pack_type} {nf(e.new_data?.m_per_pack)}</>}
                      {e.old_data?.brand !== e.new_data?.brand && <> · {e.new_data?.brand}</>}</>}</td>
                  <td className="min-w-[180px]">{e.reason}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}

      <section className="card overflow-x-auto" id="mrp">
        <div className="card-h flex-wrap">
          <div>Kết quả MRP · đề nghị mua</div>
          {run && <div className="text-[12px] text-muted">Chạy lúc {df(run.run_at, true)} · {toBuy} vật tư cần mua{showPrice && <> · ngân sách {nf(run.budget_vnd)} đ</>}{run.missing_price_count ? <> · <Pill tone="warn">{run.missing_price_count} mã thiếu giá</Pill></> : null}</div>}
        </div>
        {canAdjust && mrp && mrp.length > 0 && (
          <p className="px-4 pt-2 text-[12.5px] text-muted">
            {mrpLock ? <>Kết quả MRP đang khóa: {mrpLock}.</> : <>Bấm <Pencil size={13} className="inline" /> để điều chỉnh số lượng đề nghị mua, ngày cần, ghi chú (bắt buộc ghi lý do; hệ thống giữ số gốc và lịch sử).</>}
          </p>
        )}
        {mrp && mrp.length > 0 ? (
          <table className="tbl">
            <thead><tr><th>Mã VT</th><th>Vật tư</th><th>ĐVT</th><th className="num">Lý thuyết</th><th className="num">Tổng cấp SX</th><th className="num">Tồn KD</th><th className="num">Chờ QC</th><th className="num">Hàng về</th><th className="num">Đã đề xuất</th><th className="num">Thiếu ròng</th><th className="num">Bội số</th><th className="num">Đề nghị mua</th><th className="num">Tồn dự kiến sau SX</th>{showPrice && <th className="num">Thành tiền</th>}<th>Ngày cần</th><th>Ghi chú</th><th>TT</th>{adjustable && <th />}</tr></thead>
            <tbody>
              {mrp.map((m) => adjustable && sp.mrp === m.id ? (
                <tr key={m.id} className="bg-brand-soft/40">
                  <td colSpan={showPrice ? 18 : 17} className="p-0"><MrpForm planId={id} m={m} /></td>
                </tr>
              ) : (
                <tr key={m.id}>
                  <td className="mono font-medium">{m.material_code}</td><td className="min-w-[160px]">{m.material_name}</td><td>{m.uom}</td>
                  <td className="num">{nf(m.theoretical, 2)}</td><td className="num font-medium">{nf(m.total_issue, 2)}</td>
                  <td className="num">{nf(m.available, 1)}</td><td className="num text-muted">{nf(m.in_quality, 1)}</td><td className="num">{nf(m.incoming, 1)}</td><td className="num">{nf(m.requested, 1)}</td>
                  <td className={`num ${Number(m.net_short) > 0 ? 'text-bad' : 'text-muted'}`}>{nf(m.net_short, 2)}</td>
                  <td className="num">{nf(m.pack_multiple)}</td>
                  <td className="num font-medium">{nf(m.suggest_qty)}
                    {m.orig_suggest_qty !== null && <div className="text-[12px] font-normal text-warn" title={`Sửa bởi ${m.adjusted_by_name ?? ''} lúc ${df(m.adjusted_at, true)}`}>đã sửa · gốc {nf(m.orig_suggest_qty)}</div>}</td>
                  <td className={`num ${m.projected_after !== null && Number(m.projected_after) < 0 ? 'text-bad' : ''}`}>{nf(m.projected_after, 1)}</td>
                  {showPrice && <td className="num">{m.amount === null ? '—' : nf(m.amount)}</td>}
                  <td className="whitespace-nowrap">{df(m.eff_need_date)}
                    {m.need_date && <div className="text-[12px] text-warn">gốc {df(m.latest_order_date)}</div>}</td>
                  <td className="min-w-[120px] text-[13px]">{m.note ?? ''}</td>
                  <td><Pill tone={MRP_TONE[m.status] ?? 'mute'}>{m.status}</Pill></td>
                  {adjustable && <td><Link className="btn btn-soft px-2.5" href={`/ke-hoach/${id}?mrp=${m.id}#mrp`} title="Điều chỉnh" aria-label={`Điều chỉnh ${m.material_code}`}><Pencil size={16} /></Link></td>}
                </tr>
              ))}
            </tbody>
          </table>
        ) : <Empty>Chưa chạy MRP. Thêm dòng kế hoạch rồi bấm “Chạy MRP”.</Empty>}
      </section>

      {levels && levels.length > 0 && (
        <section className="card mt-4 overflow-x-auto">
          <div className="card-h"><span>Dự trù nhiều tầng: thành phẩm → bán thành phẩm → NVL</span><span className="text-[12.5px] font-normal text-muted">mét cáp còn phải làm ở từng công đoạn sau khi trừ tồn</span></div>
          <table className="tbl">
            <thead><tr><th>Mã</th><th className="num">Kế hoạch</th><th className="num">TP sẵn có</th><th className="num">Đóng gói</th><th className="num">Cáp CV có</th><th className="num">Bọc vỏ</th><th className="num">Cáp xoắn có</th><th className="num">Xoắn, băng</th><th className="num">Lõi có (quy cáp)</th><th className="num">Bọc cách điện</th><th className="num">Ruột có (quy cáp)</th><th className="num">Bện</th></tr></thead>
            <tbody>{levels.map((x) => (
              <tr key={x.id}><td><b>{x.product_code}</b>{x.cores ? <span className="text-[12px] text-muted"> · {x.cores} lõi</span> : null}</td><td className="num">{nf(x.qty_m)}</td>
                <td className="num text-brand">{Number(x.fg_m) ? `−${nf(x.fg_m)}` : '—'}</td><td className="num font-medium">{nf(x.q6)}</td>
                <td className="num text-brand">{Number(x.cv_m) ? `−${nf(x.cv_m)}` : '—'}</td><td className="num font-medium">{nf(x.q5)}</td>
                <td className="num text-brand">{Number(x.bl_m) ? `−${nf(x.bl_m)}` : '—'}</td><td className="num font-medium">{nf(x.q34)}</td>
                <td className="num text-brand">{Number(x.lb_m) ? `−${nf(x.lb_m)}` : '—'}</td><td className="num font-medium">{nf(x.q2)}</td>
                <td className="num text-brand">{Number(x.cb_m) ? `−${nf(x.cb_m)}` : '—'}</td><td className="num font-medium">{nf(x.q1)}</td></tr>
            ))}</tbody>
          </table>
          <p className="px-4 py-3 text-[12.5px] text-muted">TP sẵn có: đạt QC, chưa giữ cho đơn, cùng nhãn. BTP: đạt hoặc đang chờ QC trong kho BTP; lõi, ruột quy ra mét cáp ÷ số lõi. Vật tư BOM tính theo mét của công đoạn tiêu thụ; thiếu ròng đã trừ tồn đạt QC, hàng đang về kịp và đề xuất mua chưa lên PO.</p>
        </section>
      )}

      {(plan.status === 'APPROVED' || (adjs ?? []).length > 0) && (
        <section className="card mt-4" id="dieu-chinh">
          <div className="card-h"><span>Phiếu điều chỉnh kế hoạch tháng</span><span className="text-[12.5px] font-normal text-muted">thêm, bớt mã, đổi sản lượng, đổi hạn giao, lô ngoài kế hoạch: TP SX lập, Chủ tịch HĐQT duyệt</span></div>
          {(adjs ?? []).length > 0 && (
            <div className="overflow-x-auto"><table className="tbl">
              <thead><tr><th>Phiếu</th><th>Lý do</th><th className="num">Dòng</th><th>Người lập</th><th>Trạng thái</th></tr></thead>
              <tbody>{(adjs ?? []).map((a) => (
                <tr key={a.id}><td className="mono"><Link className="link" href={`/ke-hoach/dieu-chinh/${a.id}`}>{a.adj_no}</Link></td><td>{a.reason}</td><td className="num">{a.line_count}</td>
                  <td>{a.created_by_name}<div className="text-[12px] text-muted">{df(a.created_at, true)}</div></td>
                  <td><Pill tone={ADJ_STATUS[a.status]?.[1] ?? 'mute'}>{ADJ_STATUS[a.status]?.[0] ?? a.status}</Pill>{a.applied_at && <div className="text-[12px] text-muted">áp {df(a.applied_at, true)}</div>}</td></tr>
              ))}</tbody>
            </table></div>
          )}
          {canAdj && (
            <form action={createAdj} className="flex flex-wrap items-end gap-3 px-4 py-3">
              <input type="hidden" name="plan_id" value={id} />
              <label className="lbl min-w-[280px] flex-1"><span className="req">Lý do điều chỉnh</span><input className="inp" name="reason" required placeholder="VD: khách ABC đặt thêm 3.000 m, khách XYZ lùi hạn" /></label>
              <SubmitButton className="btn">Lập phiếu điều chỉnh</SubmitButton>
            </form>
          )}
        </section>
      )}

      {edits && edits.length > 0 && (
        <section className="card mt-4 overflow-x-auto">
          <div className="card-h">Lịch sử điều chỉnh MRP</div>
          <table className="tbl">
            <thead><tr><th>Thời điểm</th><th>Người sửa</th><th>Vật tư</th><th className="num">Số lượng</th><th>Ngày cần</th><th>Ghi chú</th><th>Lý do</th></tr></thead>
            <tbody>
              {edits.map((e) => (
                <tr key={e.id}>
                  <td className="whitespace-nowrap">{df(e.edited_at, true)}{e.run_id !== plan.last_run_id && <div className="text-[12px] text-muted">lần chạy MRP trước</div>}</td>
                  <td>{e.edited_by_name}</td>
                  <td><span className="mono">{e.material_code}</span> · {e.material_name}</td>
                  <td className="num whitespace-nowrap">{nf(e.old_qty)} → <b>{nf(e.new_qty)}</b></td>
                  <td className="whitespace-nowrap">{df(e.old_need_date)}{e.old_need_date !== e.new_need_date && <> → <b>{df(e.new_need_date)}</b></>}</td>
                  <td className="text-[13px]">{e.old_note !== e.new_note ? <>{e.old_note ?? '—'} → <b>{e.new_note ?? '—'}</b></> : e.new_note ?? ''}</td>
                  <td className="min-w-[160px]">{e.reason}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}
    </>
  );
}

type Prod = { id: string; code: string; description: string | null; spec_status: string | null };
type Line = { id: string; product_id: string; qty_m: number; run_lots: number; pack_type: string; m_per_pack: number; brand: string };

// Form thêm dòng và sửa dòng dùng chung (cùng danh mục đóng gói)
// chair: Chủ tịch ở bước chốt (bắt buộc lý do, không đổi mã của dòng có sẵn, bỏ mã trong form sửa)
function LineForm({ planId, line, products, packs, chair = false }: { planId: string; line?: Line; products: Prod[]; packs: PackOption[]; chair?: boolean }) {
  return (
    <form action={chair ? chairSaveLine : saveLine} className="grid gap-3 border-t border-line bg-sunk/40 p-4 md:grid-cols-[2fr_1fr_0.7fr_1fr_0.8fr_0.8fr_auto] md:items-end">
      <input type="hidden" name="plan_id" value={planId} />
      {line && <input type="hidden" name="line_id" value={line.id} />}
      <label className="lbl">Sản phẩm
        <select className="inp inp-y" name="product_id" required defaultValue={line?.product_id} disabled={chair && Boolean(line)}>
          {products.map((p) => (
            <option key={p.id} value={p.id}>{p.code} · {p.description}{p.spec_status !== 'RELEASED' ? ' (spec chưa phát hành)' : ''}</option>
          ))}
        </select>
      </label>
      <label className="lbl">Sản lượng (m)<input className="inp inp-y text-right" name="qty_m" inputMode="decimal" required defaultValue={line ? String(line.qty_m).replace('.', ',') : undefined} autoFocus={Boolean(line)} /></label>
      <label className="lbl">Số lô<input className="inp inp-y text-right" name="run_lots" defaultValue={line?.run_lots ?? 1} inputMode="numeric" required /></label>
      <PackFields options={packs} packType={line?.pack_type} mPerPack={line?.m_per_pack} />
      <label className="lbl">Thương hiệu<select className="inp inp-y" name="brand" defaultValue={line?.brand}><option>KAVIX</option><option>HEIZKA</option></select></label>
      {chair && (
        <label className="lbl md:col-span-6">Lý do chỉnh <span className="text-bad">*</span>
          <input className="inp inp-y" name="reason" required placeholder="Bắt buộc, ví dụ: khách tăng đơn, chuyển sang tháng sau" />
        </label>
      )}
      {line ? (
        <div className="flex gap-2"><SubmitButton>Lưu</SubmitButton>
          {chair && <SubmitButton className="btn btn-bad" formAction={chairRemoveLine}>Bỏ mã</SubmitButton>}
          <Link className="btn" href={`/ke-hoach/${planId}`}>Hủy</Link></div>
      ) : <SubmitButton>Thêm dòng</SubmitButton>}
    </form>
  );
}

type MrpRow = { id: string; material_code: string; material_name: string; uom: string; suggest_qty: number; orig_suggest_qty: number | null;
  eff_need_date: string | null; latest_order_date: string | null; note: string | null };

function MrpForm({ planId, m }: { planId: string; m: MrpRow }) {
  return (
    <form action={adjustMrp} className="grid gap-3 p-4 md:grid-cols-[1.6fr_0.8fr_0.9fr_1.2fr_1.6fr_auto] md:items-end">
      <input type="hidden" name="plan_id" value={planId} /><input type="hidden" name="line_id" value={m.id} />
      <div className="text-[14px]"><div className="mono font-medium">{m.material_code}</div>{m.material_name}
        <div className="text-[12px] text-muted">MRP tính: {nf(m.orig_suggest_qty ?? m.suggest_qty)} {m.uom} · đặt chậm nhất {df(m.latest_order_date)}</div></div>
      <label className="lbl">Đề nghị mua ({m.uom})<input className="inp inp-y text-right" name="qty" inputMode="decimal" required defaultValue={String(m.suggest_qty).replace('.', ',')} autoFocus /></label>
      <label className="lbl">Ngày cần<input className="inp inp-y" type="date" name="need_date" defaultValue={m.eff_need_date ?? ''} /></label>
      <label className="lbl">Ghi chú<input className="inp" name="note" defaultValue={m.note ?? ''} /></label>
      <label className="lbl">Lý do điều chỉnh <span className="text-bad">*</span><input className="inp inp-y" name="reason" required placeholder="Bắt buộc" /></label>
      <div className="flex gap-2"><SubmitButton>Lưu</SubmitButton><Link className="btn" href={`/ke-hoach/${planId}`}>Hủy</Link></div>
    </form>
  );
}
