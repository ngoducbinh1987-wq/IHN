import Link from 'next/link';
import { notFound } from 'next/navigation';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Pill, Toolbar } from '@/components/ui';
import { df, nf, numIn } from '@/lib/format';
import { can, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { cancelAdj, saveAdj, submitAdj } from '../../actions';

export const metadata = { title: 'Đề xuất hiệu chỉnh kế hoạch tháng' };

type Adj = { id: string; adj_no: string; plan_id: string; plan_no: string; status: string; reason: string; applied_at: string | null; created_at: string; created_by: string; created_by_name: string | null; approval_id: string | null };
type Line = { id: string; line_no: number; kind: string; plan_line_id: string | null; product_code: string | null; product_name: string | null; qty_m: number | null; due_date: string | null; priority: number | null; old_qty_m: number | null; old_due_date: string | null; note: string | null; new_line_id: string | null };
type PlanLine = { id: string; product_code: string; qty_m: number; due_date: string | null };
type MrpRow = { code: string; name: string; uom: string; old_need: number; new_need: number; delta: number; available: number; incoming: number; approved: number;
  pending_before: number; pending_after: number; buy_more: number; projected_after: number; amount: number | null; action: string };
type Cut = { pr_id: string; pr_no: string; status: string; material_code: string; uom: string; old: number; new: number };
type Revise = { rows?: MrpRow[]; reductions?: Cut[]; buy_count?: number; cut_count?: number; preview?: boolean; applied?: boolean; error?: string; at?: string };

const KIND: Record<string, string> = { ADD: 'Thêm mã / lô ngoài kế hoạch', QTY: 'Đổi sản lượng', DUE: 'Đổi hạn giao, ưu tiên', REMOVE: 'Bỏ mã' };
const STATUS: Record<string, [string, 'ok' | 'warn' | 'info' | 'mute']> = {
  DRAFT: ['Nháp', 'warn'], PENDING_APPROVAL: ['Chờ duyệt (Giám đốc → Chủ tịch HĐQT)', 'info'], APPROVED: ['Đã duyệt, đã áp vào kế hoạch', 'ok'], CANCELLED: ['Đã hủy', 'mute'],
};
const ACTION: Record<string, [string, 'ok' | 'warn' | 'bad' | 'info' | 'mute']> = {
  BUY: ['Mua thêm', 'bad'], CUT: ['Giảm đề xuất chưa duyệt', 'warn'], PACK: ['Giữ (dư chưa đủ một bội số đóng gói)', 'mute'],
  KEEP: ['Giữ nguyên: đã duyệt mua', 'info'], LESS: ['Giảm nhu cầu', 'mute'], ENOUGH: ['Đủ, không mua thêm', 'ok'], SAME: ['Không đổi', 'mute'],
};
const PR_ST: Record<string, string> = { DRAFT: 'nháp', PENDING_APPROVAL: 'chờ Giám đốc duyệt' };
const dmy = (d: string | null) => (d ? `${d.slice(8, 10)}/${d.slice(5, 7)}` : '—');

export default async function AdjustmentPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; err?: string }> }) {
  const { id } = await params;
  const sp = await searchParams;
  const me = await requirePerm('plan', 'view');
  const supabase = await createClient();
  const { data: a } = await supabase.schema('app').from('v_plan_adjustments').select('*').eq('id', id).maybeSingle<Adj>();
  if (!a) notFound();
  const [{ data: lines }, { data: planLines }, { data: products }, { data: impactRows }] = await Promise.all([
    supabase.schema('app').from('v_plan_adjustment_lines').select('*').eq('adj_id', id).order('line_no').returns<Line[]>(),
    supabase.schema('app').from('v_kh_plan_lines').select('id, product_code, qty_m, due_date').eq('plan_id', a.plan_id).gt('qty_m', 0).order('product_code').returns<PlanLine[]>(),
    supabase.schema('app').from('v_products').select('code, description').eq('spec_status', 'RELEASED').order('code'),
    supabase.schema('app').rpc('adj_mrp', { p_adj: id }),
  ]);
  const rv = (impactRows ?? {}) as Revise;
  const mrpRows = rv.rows ?? [];
  const cuts = rv.reductions ?? [];
  const draft = a.status === 'DRAFT';
  // Người lập sửa khi nháp; Chủ tịch (người đang duyệt) sửa khi chờ duyệt, ghi lịch sử duyệt
  const { data: reviewEdit } = a.status === 'PENDING_APPROVAL'
    ? await supabase.schema('app').rpc('can_review_edit', { p_doc_type: 'PLAN_ADJ', p_doc_id: id })
    : { data: false };
  const reviewer = reviewEdit === true;
  const canEdit = (draft && (can(me, 'plan', 'create') || me.roles.includes('SX_TP'))) || reviewer;
  const rows: Partial<Line>[] = [...(lines ?? []), ...Array.from({ length: canEdit ? Math.max(3, 6 - (lines?.length ?? 0)) : 0 }, () => ({}))];

  return (
    <>
      <Toolbar title={<span>{a.adj_no} · hiệu chỉnh {a.plan_no}</span>} actions={<>
        {a.approval_id && <Link className="btn btn-soft" href={`/duyet/${a.approval_id}`}>Xem quy trình duyệt</Link>}
        <Link className="btn" href={`/ke-hoach/${a.plan_id}#dieu-chinh`}>Về kế hoạch</Link>
      </>} />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /></div>
      <section className="card mb-4 flex flex-wrap items-center gap-3 px-4 py-3">
        <Pill tone={STATUS[a.status]?.[1] ?? 'mute'}>{STATUS[a.status]?.[0] ?? a.status}</Pill>
        <span className="text-[13.5px]">Lập bởi {a.created_by_name} · {df(a.created_at, true)}{a.applied_at ? ` · áp vào kế hoạch ${df(a.applied_at, true)}` : ''}</span>
        <span className="text-[12.5px] text-muted">TP SX lập → Giám đốc duyệt → Chủ tịch HĐQT duyệt. Duyệt xong MES áp vào kế hoạch tháng, chạy MRP hiệu chỉnh: giảm đề xuất mua chưa duyệt của kế hoạch, giữ nguyên vật tư Giám đốc đã duyệt mua; thiếu thì TP SX lập đề xuất mua bổ sung; xếp lại lịch máy.</span>
      </section>

      {canEdit ? (
        <form className="card mb-4">
          <input type="hidden" name="id" value={id} />
          <div className="px-4 pt-3"><label className="lbl"><span className="req">Lý do</span><input className="inp" name="reason" defaultValue={a.reason} required /></label></div>
          <div className="overflow-x-auto p-4"><table className="tbl">
            <thead><tr><th>Loại</th><th>Dòng kế hoạch (đổi, bỏ)</th><th>Mã mới (thêm)</th><th className="num">Số mét mới</th><th>Hạn giao mới</th><th>Ưu tiên</th><th>Ghi chú (đơn hàng…)</th></tr></thead>
            <tbody>{rows.map((r, i) => (
              <tr key={i}>
                <td><select className="inp min-w-[170px]" name={`kind_${i}`} defaultValue={r.kind ?? ''} aria-label={`Loại dòng ${i + 1}`}>
                  <option value="">—</option>{Object.entries(KIND).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></td>
                <td><select className="inp min-w-[200px]" name={`line_${i}`} defaultValue={r.plan_line_id ?? ''} aria-label={`Dòng kế hoạch ${i + 1}`}>
                  <option value="">—</option>{(planLines ?? []).map((p) => <option key={p.id} value={p.id}>{p.product_code} · {nf(p.qty_m)} m · hạn {dmy(p.due_date)}</option>)}</select></td>
                <td><input className="inp mono w-[150px] uppercase" name={`code_${i}`} list="released" defaultValue={r.kind === 'ADD' ? r.product_code ?? '' : ''} aria-label={`Mã mới ${i + 1}`} /></td>
                <td><input className="inp w-[110px] text-right" name={`qty_${i}`} inputMode="decimal" defaultValue={r.qty_m !== null && r.qty_m !== undefined ? numIn(r.qty_m) : ''} aria-label={`Số mét ${i + 1}`} /></td>
                <td><input className="inp w-[150px]" type="date" name={`due_${i}`} defaultValue={r.due_date ?? ''} aria-label={`Hạn giao ${i + 1}`} /></td>
                <td><select className="inp w-auto" name={`prio_${i}`} defaultValue={r.priority === null || r.priority === undefined ? '' : String(r.priority)} aria-label={`Ưu tiên ${i + 1}`}>
                  <option value="">—</option><option value="1">Thường</option><option value="0">Gấp</option></select></td>
                <td><input className="inp min-w-[160px]" name={`note_${i}`} defaultValue={r.note ?? ''} aria-label={`Ghi chú ${i + 1}`} /></td>
              </tr>
            ))}</tbody>
          </table>
          <datalist id="released">{(products ?? []).map((p) => <option key={p.code} value={p.code}>{p.description}</option>)}</datalist>
          <p className="mt-2 text-[12.5px] text-muted">Thêm mã: chọn "Thêm mã", nhập mã (spec đã phát hành), số mét, hạn giao. Đổi sản lượng: chọn dòng, nhập số mét mới. Đổi hạn: chọn dòng, nhập hạn mới hoặc đánh dấu gấp. Bỏ mã: chỉ khi lô chưa phát lệnh sản xuất (đang chạy thì giảm số mét).</p></div>
          {reviewer ? (
            <div className="flex flex-wrap items-center gap-2 border-t border-line px-4 py-3">
              <SubmitButton formAction={saveAdj}>Lưu thay đổi</SubmitButton>
              <span className="text-[12.5px] text-muted">Bạn đang duyệt đề xuất này: sửa xong ghi vào lịch sử duyệt, báo người lập; duyệt ở {a.approval_id ? <Link className="link" href={`/duyet/${a.approval_id}`}>trang quy trình duyệt</Link> : 'trang quy trình duyệt'}.</span>
            </div>
          ) : (
            <div className="flex flex-wrap gap-2 border-t border-line px-4 py-3">
              <SubmitButton className="btn" formAction={saveAdj}>Lưu nháp</SubmitButton>
              <SubmitButton formAction={submitAdj}>Lưu và gửi Giám đốc duyệt</SubmitButton>
              <SubmitButton className="btn btn-bad-o ml-auto" formAction={cancelAdj}>Hủy đề xuất</SubmitButton>
            </div>
          )}
        </form>
      ) : (
        <section className="card mb-4 overflow-x-auto">
          <div className="card-h">Nội dung điều chỉnh · {a.reason}</div>
          {(lines ?? []).length === 0 ? <Empty>Đề xuất chưa có dòng.</Empty> : (
            <table className="tbl">
              <thead><tr><th>#</th><th>Loại</th><th>Mã</th><th className="num">Số mét</th><th>Hạn giao</th><th>Ghi chú</th></tr></thead>
              <tbody>{(lines ?? []).map((l) => (
                <tr key={l.id}><td>{l.line_no}</td><td>{KIND[l.kind]}</td><td><b>{l.product_code}</b></td>
                  <td className="num">{l.kind === 'ADD' ? nf(l.qty_m) : l.kind === 'QTY' ? <>{nf(l.old_qty_m)} → <b>{nf(l.qty_m)}</b></> : l.kind === 'REMOVE' ? <>{nf(l.old_qty_m)} → <b>0</b></> : nf(l.old_qty_m)}</td>
                  <td>{l.kind === 'DUE' ? <>{dmy(l.old_due_date)} → <b>{l.due_date ? dmy(l.due_date) : 'giữ'}</b>{l.priority === 0 ? ' · gấp' : ''}</> : l.kind === 'ADD' ? dmy(l.due_date) : dmy(l.old_due_date)}</td>
                  <td>{l.note ?? ''}</td></tr>
              ))}</tbody>
            </table>
          )}
        </section>
      )}

      <section className="card overflow-x-auto" id="mrp-hieu-chinh">
        <div className="card-h"><span>Bảng MRP hiệu chỉnh</span><span className="text-[12.5px] font-normal text-muted">{rv.applied
          ? `đã áp khi duyệt${rv.at ? ` ${df(rv.at, true)}` : ''}`
          : 'xem trước: MES chạy thử với các dòng đề xuất (chưa đổi gì), so với lần chạy MRP gần nhất của kế hoạch'}</span></div>
        {rv.error ? <p className="px-4 py-3 text-[13.5px] text-muted">Chưa tính được: {rv.error}</p> : mrpRows.length === 0 ? <Empty>Không đổi nhu cầu vật tư (đổi hạn giao, hoặc chưa có dòng).</Empty> : (
          <table className="tbl">
            <thead><tr><th>Vật tư</th><th className="num">Nhu cầu cũ</th><th className="num">Nhu cầu mới</th><th className="num">Tăng/giảm</th>
              <th className="num">Tồn + đang về</th><th className="num">Đã duyệt mua</th><th className="num">Đề xuất chưa duyệt</th><th className="num">Mua thêm</th><th className="num">Tồn dự kiến</th><th>MES xử lý</th></tr></thead>
            <tbody>{mrpRows.map((x) => (
              <tr key={x.code}><td><b>{x.code}</b><div className="text-[12px] text-muted">{x.name}</div></td>
                <td className="num">{nf(x.old_need, 2)}</td><td className="num">{nf(x.new_need, 2)}</td>
                <td className={`num ${x.delta > 0 ? 'text-bad' : ''}`}>{x.delta > 0 ? '+' : ''}{nf(x.delta, 2)}</td>
                <td className="num">{nf(x.available + x.incoming, 2)}</td><td className="num">{nf(x.approved, 2)}</td>
                <td className="num">{x.pending_after !== x.pending_before ? <><s className="text-muted">{nf(x.pending_before, 2)}</s> → <b>{nf(x.pending_after, 2)}</b></> : nf(x.pending_after, 2)}</td>
                <td className={`num ${x.buy_more > 0 ? 'font-semibold text-bad' : ''}`}>{nf(x.buy_more, 2)} {x.uom}</td>
                <td className="num">{nf(x.projected_after, 2)}</td>
                <td><Pill tone={ACTION[x.action]?.[1] ?? 'mute'}>{ACTION[x.action]?.[0] ?? x.action}</Pill></td></tr>
            ))}</tbody>
          </table>
        )}
        {cuts.length > 0 && (
          <div className="border-t border-line px-4 py-3 text-[13.5px]">
            <b>{rv.applied ? 'Đề xuất mua đã giảm' : 'Đề xuất mua sẽ giảm khi duyệt'}:</b>{' '}
            {cuts.map((c, i) => <span key={i}>{i > 0 && '; '}<Link className="link" href={`/de-xuat/${c.pr_id}`}>{c.pr_no}</Link> ({PR_ST[c.status] ?? c.status}) {c.material_code} {nf(c.old, 2)} → <b>{nf(c.new, 2)}</b> {c.uom}</span>)}
          </div>
        )}
        <p className="border-t border-line px-4 py-3 text-[12.5px] text-muted">
          Đã duyệt mua: đề xuất mua của kế hoạch này Giám đốc đã duyệt (giữ nguyên, không giảm). Đề xuất chưa duyệt: nháp hoặc đang chờ Giám đốc duyệt, MES giảm phần thừa (làm tròn theo bội số đóng gói, hết thì hủy đề xuất).
          {(rv.buy_count ?? 0) > 0 && <> Mua thêm: sau khi duyệt, TP SX bấm “Sinh đề xuất mua (PR)” ở trang kế hoạch.</>}
        </p>
      </section>
    </>
  );
}
