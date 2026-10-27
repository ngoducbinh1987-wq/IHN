import Link from 'next/link';
import { notFound } from 'next/navigation';
import { Send, Trash2 } from 'lucide-react';
import { AdminTools } from '@/components/admin-tools';
import { StageBar, type Stage } from '@/components/stage-bar';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Pill, StatusPill, Toolbar } from '@/components/ui';
import type { Approval } from '@/lib/approvals';
import { DOC_STATUS, df, nf, numIn } from '@/lib/format';
import { can, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { deletePrLine, savePrHeader, savePrLine, setPrKind, submitPr } from '../actions';

export const metadata = { title: 'Đề xuất mua hàng' };

export default async function PrDetail({ params, searchParams }:
  { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; err?: string }> }) {
  const { id } = await params;
  const sp = await searchParams;
  const me = await requirePerm('purchase', 'view');
  const supabase = await createClient();
  const { data: pr } = await supabase.schema('app').from('v_prs').select('*').eq('id', id).maybeSingle();
  if (!pr) notFound();
  const [{ data: lines }, { data: req }, { data: mats }, { data: flow }] = await Promise.all([
    supabase.schema('app').from('v_pr_lines').select('*').eq('pr_id', id).order('material_code'),
    pr.request_id ? supabase.schema('app').from('v_approvals').select('*').eq('id', pr.request_id).maybeSingle<Approval>() : Promise.resolve({ data: null }),
    supabase.schema('app').from('v_materials').select('code, name, uom').order('code'),
    supabase.schema('wf').from('approval_steps').select('seq, level_label, role_code, enabled').eq('doc_type', 'PR').eq('enabled', true).order('seq'),
  ]);
  const draft = pr.status === 'DRAFT';
  // Người lập sửa khi nháp; người đang giữ bước duyệt sửa khi chờ duyệt (database kiểm lại, ghi lịch sử duyệt)
  const { data: reviewEdit } = pr.status === 'PENDING_APPROVAL'
    ? await supabase.schema('app').rpc('can_review_edit', { p_doc_type: 'PR', p_doc_id: id })
    : { data: false };
  const reviewer = reviewEdit === true;
  const editable = (draft && can(me, 'purchase', 'create')) || reviewer;
  // Đề xuất từ dự trù: cột nhu cầu, tồn đạt QC, đang về, tồn dự kiến (quy trình final: TP SX lập, Giám đốc duyệt)
  const fromMrp = (lines ?? []).some((l) => l.need_qty !== null);
  const showPrice = me.can_see_price;
  const total = (lines ?? []).reduce((s, l) => s + (l.unit_price === null ? 0 : Number(l.qty) * Number(l.unit_price)), 0);
  // Chưa gửi duyệt: vẫn hiện trước các bước sẽ đi qua để người lập biết ai duyệt
  const stages: Stage[] = req?.steps ?? [
    { seq: 0, label: 'Lập phiếu', state: 'current', approvers: [{ id: '', name: pr.created_by_name ?? '' }] },
    ...(flow ?? []).map((s) => ({ seq: s.seq, label: s.level_label, role: s.role_code, state: 'todo' as const })),
  ];

  return (
    <>
      <Toolbar title={<span>{pr.pr_no} – {pr.note}</span>}
        actions={<>
          {req && <Link className="btn btn-soft" href={`/duyet/${req.id}`}>Xem quy trình duyệt</Link>}
          {draft && editable && (lines?.length ?? 0) > 0 && (
            <form action={submitPr}>
              <input type="hidden" name="pr_id" value={id} /><input type="hidden" name="pr_no" value={pr.pr_no} /><input type="hidden" name="note" value={pr.note ?? ''} />
              <SubmitButton className="btn btn-pri"><Send size={15} />Gửi duyệt</SubmitButton>
            </form>
          )}
          <Link className="btn" href="/de-xuat">Đóng</Link>
        </>} />
      <div className="-mx-4 mb-4 md:-mx-5"><StageBar stages={stages} /></div>
      <Flash ok={sp.ok} err={sp.err} />
      {reviewer && (
        <div role="note" id="review-edit" className="mb-4 rounded border-l-4 border-brand bg-brand-soft px-4 py-2.5 text-[14px]">
          <b>Bạn đang duyệt đề xuất này</b> nên được sửa số mua, thêm hoặc bỏ dòng, ngày cần trước khi duyệt. Mỗi lần sửa ghi vào lịch sử duyệt và báo người lập.
          {req && <> Sửa xong bấm duyệt ở <Link className="link" href={`/duyet/${req.id}`}>trang quy trình duyệt</Link>.</>}
        </div>
      )}
      {me.roles.includes('ADMIN') && (
        <AdminTools docType="PR" docId={id} docNo={pr.pr_no} requestId={req?.id} pending={req?.status === 'PENDING'} canReopen={!draft}
          back={`/de-xuat/${id}`} after="/de-xuat" />
      )}

      <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_340px]">
        <section className="card overflow-x-auto">
          <div className="card-h"><h2>Danh sách vật tư đề xuất</h2><span className="text-[13px] text-muted">{lines?.length ?? 0} dòng</span></div>
          <table className="tbl">
            <thead><tr><th>Mã VT</th><th>Vật tư</th>{fromMrp && <><th className="num">Nhu cầu SX</th><th className="num">Tồn đạt QC</th><th className="num">Đang về, đã đề xuất</th></>}<th className="num">Số mua</th><th>ĐVT</th>{fromMrp ? <th className="num" title="Tồn sau sản xuất, sau khi giữ đủ mức dự phòng (âm = thấp hơn mức)">Tồn dự kiến sau SX</th> : <th className="num">Tồn khả dụng</th>}<th className="num" title="Mức tồn dự phòng Giám đốc đã duyệt">Dự phòng</th><th>Ngày cần</th>{showPrice && <th className="num">Đơn giá</th>}{showPrice && <th className="num">Thành tiền</th>}{editable && <th />}</tr></thead>
            <tbody>
              {(lines ?? []).map((l) => (
                <tr key={l.id}>
                  <td className="mono font-medium">{l.material_code}</td><td>{l.material_name}</td>
                  {fromMrp && <><td className="num">{nf(l.need_qty, 2)}</td><td className="num">{nf(l.available_qty, 2)}</td><td className="num">{nf(l.incoming_qty, 2)}</td></>}
                  <td className="num font-medium">{editable ? (
                    <form action={savePrLine} className="flex items-center justify-end gap-1">
                      <input type="hidden" name="pr_id" value={id} /><input type="hidden" name="material_code" value={l.material_code} />
                      <input className="inp w-[110px] py-1 text-right" name="qty" defaultValue={numIn(l.qty)} inputMode="decimal" aria-label={`Số mua ${l.material_code}`} />
                      <SubmitButton className="btn btn-sm" pendingText="…">Lưu</SubmitButton>
                    </form>
                  ) : nf(l.qty, 2)}{l.mrp_qty !== null && Number(l.mrp_qty) !== Number(l.qty) && <div className="text-[12px] font-normal text-warn">MES đề nghị {nf(l.mrp_qty, 2)}</div>}</td>
                  <td>{l.uom}</td>
                  {fromMrp ? <td className={`num ${l.projected_qty !== null && Number(l.projected_qty) < 0 ? 'text-bad' : ''}`}
                    title={l.projected_qty !== null && Number(l.projected_qty) < 0 ? 'Sau sản xuất thấp hơn mức dự phòng' : undefined}>{nf(l.projected_qty, 2)}</td>
                    : <td className="num">{nf(l.available, 1)}</td>}
                  <td className="num">{Number(l.safety_qty ?? 0) > 0 ? nf(l.safety_qty, 2) : '—'}</td>
                  <td>{df(l.need_date)}</td>
                  {showPrice && <td className="num">{l.unit_price === null ? <Pill tone="warn">Chưa có giá</Pill> : nf(l.unit_price)}</td>}
                  {showPrice && <td className="num">{l.unit_price === null ? '—' : nf(Number(l.qty) * Number(l.unit_price))}</td>}
                  {editable && (
                    <td><form action={deletePrLine}><input type="hidden" name="pr_id" value={id} /><input type="hidden" name="line_id" value={l.id} />
                      <SubmitButton className="btn btn-sm btn-bad-o" pendingText="…"><Trash2 size={14} />Xóa</SubmitButton></form></td>
                  )}
                </tr>
              ))}
              {(lines ?? []).length === 0 && <tr><td colSpan={13}><Empty>Chưa có dòng vật tư.</Empty></td></tr>}
            </tbody>
            {showPrice && (lines?.length ?? 0) > 0 && <tfoot><tr><td colSpan={fromMrp ? 11 : 8} className="px-3 py-2 text-right font-medium">Tổng (dòng có giá)</td><td className="num px-3 font-medium">{nf(total)} đ</td>{editable && <td />}</tr></tfoot>}
          </table>
          {editable && (
            <form action={savePrLine} className="grid gap-3 border-t border-line bg-sunk/50 p-4 md:grid-cols-[2fr_1fr_1fr_auto] md:items-end">
              <input type="hidden" name="pr_id" value={id} />
              <datalist id="mats">{(mats ?? []).map((m) => <option key={m.code} value={`${m.code} · ${m.name} (${m.uom})`} />)}</datalist>
              <label className="lbl"><span className="req">Vật tư</span><input className="inp" name="material_code" list="mats" required /></label>
              <label className="lbl"><span className="req">Số lượng</span><input className="inp text-right" name="qty" inputMode="decimal" required /></label>
              <label className="lbl">Ngày cần<input className="inp" type="date" name="need_date" /></label>
              <SubmitButton className="btn btn-pri">+ Thêm dòng</SubmitButton>
            </form>
          )}
        </section>

        <aside className="card p-4">
          <h2 className="mb-2 text-[16px] font-medium">Thông tin đề xuất</h2>
          {editable ? (
            <form action={savePrHeader} className="flex flex-col gap-3">
              <input type="hidden" name="pr_id" value={id} />
              <label className="lbl"><span className="req">Nội dung</span><textarea className="inp" name="note" rows={3} defaultValue={pr.note ?? ''} required /></label>
              <label className="lbl">Ngày cần hàng<input className="inp" type="date" name="need_date" defaultValue={pr.need_date ?? ''} /></label>
              <div><SubmitButton className="btn">Lưu thông tin</SubmitButton></div>
            </form>
          ) : (
            <dl className="text-[14px]">
              <dt className="text-muted">Nội dung</dt><dd className="mb-2">{pr.note}</dd>
              <dt className="text-muted">Ngày cần hàng</dt><dd className="mb-2">{df(pr.need_date)}</dd>
            </dl>
          )}
          <dl className="mt-3 border-t border-line pt-3 text-[14px]">
            <dt className="text-muted">Trạng thái</dt><dd className="mb-2"><StatusPill map={DOC_STATUS} value={pr.status} /></dd>
            <dt className="text-muted">Loại đề xuất</dt><dd className="mb-2">
              {editable && pr.source !== 'MRP' ? (
                <form action={setPrKind} className="flex items-center gap-2">
                  <input type="hidden" name="pr_id" value={id} />
                  <select className="inp py-1" name="kind" defaultValue={pr.pr_kind} aria-label="Loại đề xuất">
                    <option value="BO_SUNG">Mua bổ sung</option><option value="TICH_TRU">Mua tích trữ</option><option value="TOI_UU">Mua tối ưu</option>
                  </select>
                  <SubmitButton className="btn btn-sm" pendingText="…">Đổi</SubmitButton>
                </form>
              ) : pr.pr_kind_label}
            </dd>
            <dt className="text-muted">Nguồn</dt><dd className="mb-2">{pr.source === 'MRP' ? 'Sinh từ MRP' : 'Lập thủ công'}</dd>
            <dt className="text-muted">Người lập</dt><dd className="mb-2 uppercase">{pr.created_by_name}</dd>
            <dt className="text-muted">Thời gian tạo</dt><dd>{df(pr.created_at, true)}</dd>
          </dl>
        </aside>
      </div>
    </>
  );
}
