import Link from 'next/link';
import { notFound } from 'next/navigation';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Pill, Toolbar } from '@/components/ui';
import { df, nf, numIn } from '@/lib/format';
import { can, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { cancelAdj, saveAdj, submitAdj } from '../../actions';

export const metadata = { title: 'Phiếu điều chỉnh kế hoạch tháng' };

type Adj = { id: string; adj_no: string; plan_id: string; plan_no: string; status: string; reason: string; applied_at: string | null; created_at: string; created_by: string; created_by_name: string | null; approval_id: string | null };
type Line = { id: string; line_no: number; kind: string; plan_line_id: string | null; product_code: string | null; product_name: string | null; qty_m: number | null; due_date: string | null; priority: number | null; old_qty_m: number | null; old_due_date: string | null; note: string | null; new_line_id: string | null };
type PlanLine = { id: string; product_code: string; qty_m: number; due_date: string | null };
type Impact = { material_code: string; material_name: string; uom: string; extra_need: number; projected_before: number | null; projected_after: number };

const KIND: Record<string, string> = { ADD: 'Thêm mã / lô ngoài kế hoạch', QTY: 'Đổi sản lượng', DUE: 'Đổi hạn giao, ưu tiên', REMOVE: 'Bỏ mã' };
const STATUS: Record<string, [string, 'ok' | 'warn' | 'info' | 'mute']> = {
  DRAFT: ['Nháp', 'warn'], PENDING_APPROVAL: ['Chờ Chủ tịch HĐQT duyệt', 'info'], APPROVED: ['Đã duyệt, đã áp vào kế hoạch', 'ok'], CANCELLED: ['Đã hủy', 'mute'],
};
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
    supabase.schema('app').rpc('adj_impact', { p_adj: id }),
  ]);
  const impact = (impactRows ?? []) as Impact[];
  const draft = a.status === 'DRAFT';
  const canEdit = draft && (can(me, 'plan', 'create') || me.roles.includes('SX_TP'));
  const rows: Partial<Line>[] = [...(lines ?? []), ...Array.from({ length: canEdit ? Math.max(3, 6 - (lines?.length ?? 0)) : 0 }, () => ({}))];

  return (
    <>
      <Toolbar title={<span>{a.adj_no} · điều chỉnh {a.plan_no}</span>} actions={<>
        {a.approval_id && <Link className="btn btn-soft" href={`/duyet/${a.approval_id}`}>Xem quy trình duyệt</Link>}
        <Link className="btn" href={`/ke-hoach/${a.plan_id}#dieu-chinh`}>Về kế hoạch</Link>
      </>} />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /></div>
      <section className="card mb-4 flex flex-wrap items-center gap-3 px-4 py-3">
        <Pill tone={STATUS[a.status]?.[1] ?? 'mute'}>{STATUS[a.status]?.[0] ?? a.status}</Pill>
        <span className="text-[13.5px]">Lập bởi {a.created_by_name} · {df(a.created_at, true)}{a.applied_at ? ` · áp vào kế hoạch ${df(a.applied_at, true)}` : ''}</span>
        <span className="text-[12.5px] text-muted">Chủ tịch HĐQT duyệt. Duyệt xong MES áp vào kế hoạch tháng; TP SX chạy lại dự trù (thiếu vật tư thì đề xuất mua bổ sung) và xếp lại lịch máy.</span>
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
          <div className="flex flex-wrap gap-2 border-t border-line px-4 py-3">
            <SubmitButton className="btn" formAction={saveAdj}>Lưu nháp</SubmitButton>
            <SubmitButton formAction={submitAdj}>Lưu và gửi Chủ tịch HĐQT duyệt</SubmitButton>
            <SubmitButton className="btn btn-bad-o ml-auto" formAction={cancelAdj}>Hủy phiếu</SubmitButton>
          </div>
        </form>
      ) : (
        <section className="card mb-4 overflow-x-auto">
          <div className="card-h">Nội dung điều chỉnh · {a.reason}</div>
          {(lines ?? []).length === 0 ? <Empty>Phiếu chưa có dòng.</Empty> : (
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

      <section className="card overflow-x-auto">
        <div className="card-h"><span>Ảnh hưởng vật tư (xem trước)</span><span className="text-[12.5px] font-normal text-muted">nhu cầu thêm theo BOM so với tồn dự kiến của lần dự trù gần nhất</span></div>
        {impact.length === 0 ? <Empty>Không đổi nhu cầu vật tư (đổi hạn giao, hoặc chưa có dòng).</Empty> : (
          <table className="tbl">
            <thead><tr><th>Vật tư</th><th className="num">Nhu cầu thêm</th><th className="num">Tồn dự kiến trước</th><th className="num">Tồn dự kiến sau</th><th /></tr></thead>
            <tbody>{impact.map((x) => (
              <tr key={x.material_code}><td><b>{x.material_code}</b><div className="text-[12px] text-muted">{x.material_name}</div></td>
                <td className="num">{nf(x.extra_need, 2)} {x.uom}</td><td className="num">{nf(x.projected_before, 2)}</td>
                <td className={`num ${x.projected_after < 0 ? 'text-bad' : ''}`}>{nf(x.projected_after, 2)}</td>
                <td>{x.projected_after < 0 ? <Pill tone="bad">Thiếu: đề xuất mua bổ sung sau khi duyệt</Pill> : null}</td></tr>
            ))}</tbody>
          </table>
        )}
      </section>
    </>
  );
}
