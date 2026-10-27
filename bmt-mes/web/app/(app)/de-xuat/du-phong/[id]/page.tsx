import Link from 'next/link';
import { notFound, redirect } from 'next/navigation';
import { Send } from 'lucide-react';
import { SubmitButton } from '@/components/submit-button';
import { Flash, Pill, Toolbar } from '@/components/ui';
import { df, nf, numIn } from '@/lib/format';
import { SS_STATUS } from '@/lib/safety';
import { can, requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { cancelSafety, saveSafety, submitSafety } from '../../actions';

export const metadata = { title: 'Phiếu điều chỉnh tồn dự phòng' };

type Change = { id: string; change_no: string; status: string; reason: string; applied_at: string | null; created_at: string; created_by: string;
  created_by_name: string | null; approval_id: string | null };
type Line = { id: string; line_no: number; material_code: string; material_name: string; uom: string; old_qty: number; old_days: number | null;
  per_day: number; new_days: number | null; new_qty: number; note: string | null };

export default async function SafetyChange({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; err?: string }> }) {
  const { id } = await params;
  const sp = await searchParams;
  const me = await requireMe();
  if (!(can(me, 'purchase', 'view') || can(me, 'inventory', 'view') || me.roles.includes('BGD'))) redirect('/?err=' + encodeURIComponent('Không có quyền xem tồn dự phòng'));
  const supabase = await createClient();
  const { data: c } = await supabase.schema('app').from('v_safety_changes').select('*').eq('id', id).maybeSingle<Change>();
  if (!c) notFound();
  const { data: lines } = await supabase.schema('app').from('v_safety_change_lines').select('*').eq('change_id', id).order('line_no').returns<Line[]>();
  const draft = c.status === 'DRAFT';
  // Người lập (TP Mua) sửa khi nháp; Giám đốc (người đang duyệt) sửa khi chờ duyệt, ghi lịch sử duyệt và báo người lập
  const { data: reviewEdit } = c.status === 'PENDING_APPROVAL'
    ? await supabase.schema('app').rpc('can_review_edit', { p_doc_type: 'SAFETY_STOCK', p_doc_id: id })
    : { data: false };
  const reviewer = reviewEdit === true;
  const canEdit = (draft && (c.created_by === me.id || me.roles.includes('MUA_TP') || me.roles.includes('ADMIN'))) || reviewer;
  const rows: Partial<Line>[] = [...(lines ?? []), ...Array.from({ length: canEdit ? 5 : 0 }, () => ({}))];

  return (
    <>
      <Toolbar title={<span>{c.change_no} · điều chỉnh mức tồn dự phòng</span>} actions={<>
        {c.approval_id && <Link className="btn btn-soft" href={`/duyet/${c.approval_id}`}>Xem quy trình duyệt</Link>}
        <Link className="btn" href="/de-xuat/du-phong?tab=phieu">Đóng</Link>
      </>} />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /></div>
      <section className="card mb-4 flex flex-wrap items-center gap-3 px-4 py-3">
        <Pill tone={SS_STATUS[c.status]?.[1] ?? 'mute'}>{SS_STATUS[c.status]?.[0] ?? c.status}</Pill>
        <span className="text-[13.5px]">Lập bởi {c.created_by_name} · {df(c.created_at, true)}{c.applied_at ? ` · áp ${df(c.applied_at, true)}` : ''}</span>
        <span className="text-[12.5px] text-muted">TP Mua lập → Giám đốc duyệt. Duyệt xong MES áp mức mới, cảnh báo khi tồn thấp hơn mức và mua bù trong dự trù MRP.</span>
      </section>
      {reviewer && (
        <div role="note" id="review-edit" className="mb-4 rounded border-l-4 border-brand bg-brand-soft px-4 py-2.5 text-[14px]">
          <b>Bạn đang duyệt phiếu này</b> nên được sửa mức dự phòng trước khi duyệt. Mỗi lần sửa ghi vào lịch sử duyệt và báo TP Mua.
          {c.approval_id && <> Sửa xong bấm duyệt ở <Link className="link" href={`/duyet/${c.approval_id}`}>trang quy trình duyệt</Link>.</>}
        </div>
      )}

      <form className="card">
        <input type="hidden" name="id" value={id} />
        <div className="p-4">
          {canEdit
            ? <label className="lbl"><span className="req">Lý do điều chỉnh</span><input className="inp" name="reason" defaultValue={c.reason} required /></label>
            : <p className="text-[14px]"><span className="text-muted">Lý do:</span> {c.reason}</p>}
        </div>
        <div className="overflow-x-auto">
          <table className="tbl">
            <thead><tr><th>Vật tư</th><th className="num">Mức cũ</th><th className="num">Tiêu hao/ngày</th><th className="num">Số ngày SX</th><th className="num">Mức mới</th><th>Ghi chú</th></tr></thead>
            <tbody>{rows.map((l, i) => (
              <tr key={l.id ?? `n${i}`}>
                <td>{canEdit ? <input className="inp" name={`code_${i}`} defaultValue={l.material_code ?? ''} aria-label={`Vật tư dòng ${i + 1}`} />
                  : <><span className="mono font-medium">{l.material_code}</span> {l.material_name}</>}</td>
                <td className="num">{l.id ? `${nf(l.old_qty, 2)} ${l.uom}` : ''}{l.old_days != null && <div className="text-[12px] text-muted">{nf(l.old_days, 1)} ngày</div>}</td>
                <td className="num">{l.id && Number(l.per_day) > 0 ? nf(l.per_day, 2) : ''}</td>
                <td className="num">{canEdit ? <input className="inp w-24 text-right" name={`days_${i}`} defaultValue={l.new_days != null ? numIn(l.new_days) : ''} inputMode="decimal" aria-label={`Số ngày dòng ${i + 1}`} />
                  : l.new_days != null ? nf(l.new_days, 1) : '—'}</td>
                <td className="num font-medium">{canEdit ? <input className="inp w-32 text-right" name={`qty_${i}`} defaultValue={l.id ? numIn(l.new_qty) : ''} inputMode="decimal" aria-label={`Mức mới dòng ${i + 1}`} />
                  : <>{nf(l.new_qty, 2)} {l.uom}</>}</td>
                <td>{canEdit ? <input className="inp" name={`note_${i}`} defaultValue={l.note ?? ''} aria-label={`Ghi chú dòng ${i + 1}`} /> : l.note}</td>
              </tr>
            ))}</tbody>
          </table>
        </div>
        {canEdit && (
          <div className="flex flex-wrap items-center gap-2 border-t border-line px-4 py-3">
            <SubmitButton className="btn" formAction={saveSafety}>Lưu</SubmitButton>
            {draft && <SubmitButton className="btn btn-pri" formAction={submitSafety}><Send size={15} />Gửi Giám đốc duyệt</SubmitButton>}
            {draft && <SubmitButton className="btn btn-bad-o" formAction={cancelSafety}>Hủy phiếu</SubmitButton>}
            <span className="text-[12.5px] text-muted">Để trống “Mức mới” thì MES tính = tiêu hao/ngày × số ngày. Xóa mã vật tư để bỏ dòng.</span>
          </div>
        )}
      </form>
    </>
  );
}
