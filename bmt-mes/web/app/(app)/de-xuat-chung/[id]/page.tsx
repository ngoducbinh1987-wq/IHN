import Link from 'next/link';
import { notFound } from 'next/navigation';
import { Printer } from 'lucide-react';
import { StageBar } from '@/components/stage-bar';
import { SubmitButton } from '@/components/submit-button';
import { DateInput } from '@/components/date-input';
import { Flash, InfoRow, Pill, StatusPill, Toolbar } from '@/components/ui';
import { df, dmy, nf, numIn } from '@/lib/format';
import { REQ_GROUP_NAME, REQ_STATUS, fmtDays, type Req, type ReqType } from '@/lib/requests';
import { can, requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { cancelRequest, doneRequest, prFromRequest, refuseRequest, repairRequest, submitRequest, withdrawRequest } from '../actions';
import { RequestForm } from '../request-form';

export const metadata = { title: 'Đề xuất' };

type Hist = { seq: number; action: string; comment: string | null; at: string; actor: string | null; label: string | null };
const ACT: Record<string, string> = { APPROVE: 'Duyệt', REJECT: 'Trả lại / từ chối', COMMENT: 'Ghi chú' };

export default async function RequestDetail({ params, searchParams }:
  { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; err?: string; sua?: string }> }) {
  const { id } = await params;
  const sp = await searchParams;
  const me = await requireMe();
  const db = await createClient();
  const { data: r } = await db.schema('app').from('v_requests').select('*').eq('id', id).maybeSingle<Req>();
  if (!r) notFound();
  const { data: t } = await db.schema('app').from('v_request_types').select('*').eq('code', r.type_code).maybeSingle<ReqType>();
  if (!t) notFound();
  const editable = r.mine && ['DRAFT', 'RETURNED'].includes(r.status);
  const reviewing = r.my_turn && r.status === 'PENDING_APPROVAL' && sp.sua === '1';
  const needForm = editable || reviewing;
  const [{ data: machines }, { data: mats }] = await Promise.all([
    needForm && t.form === 'REPAIR' ? db.schema('app').from('v_machines').select('code, name').order('code') : Promise.resolve({ data: [] }),
    (needForm && t.form === 'BUY') || (r.can_handle && t.action === 'PR')
      ? db.schema('app').from('v_materials').select('code, name, uom').order('code') : Promise.resolve({ data: [] }),
  ]);
  const hist = (r.history ?? []) as Hist[];
  const d = r.data ?? {};
  const when = r.date_from ? `${dmy(r.date_from)}${r.date_to && r.date_to !== r.date_from ? ' – ' + dmy(r.date_to) : ''}` : null;

  return (
    <>
      <Toolbar title={`${r.req_no} · ${r.type_name}`} reload={`/de-xuat-chung/${r.id}`}
        actions={<>
          <Link href={`/in/de-xuat?id=${r.id}`} className="btn" target="_blank"><Printer size={15} />In đơn</Link>
          <Link href="/de-xuat-chung" className="btn">Danh sách</Link>
        </>} />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /></div>
      {Array.isArray(r.steps) && <div className="-mx-4 mb-4 md:-mx-5"><StageBar stages={r.steps as never} /></div>}

      <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_360px]">
        <div className="flex min-w-0 flex-col gap-4">
          {editable ? (
            <RequestForm t={t} r={r} back={`/de-xuat-chung/${r.id}`} machines={(machines ?? []) as { code: string; name: string | null }[]}
              mats={(mats ?? []) as { code: string; name: string | null; uom: string | null }[]} />
          ) : reviewing ? (
            <RequestForm t={t} r={r} back={`/de-xuat-chung/${r.id}?sua=1`} review machines={(machines ?? []) as { code: string; name: string | null }[]}
              mats={(mats ?? []) as { code: string; name: string | null; uom: string | null }[]} />
          ) : (
            <section className="card p-4 md:p-5" id="noi-dung-de-xuat">
              <h2 className="text-[19px] font-medium">{r.title}{r.urgent && <> <Pill tone="bad">Gấp</Pill></>}</h2>
              <div className="mt-3 grid gap-x-6 sm:grid-cols-2">
                {when && <InfoRow label={r.form === 'MATERNITY' ? 'Nghỉ từ – đến' : 'Thời gian'}>{when}{r.days !== null && ` (${fmtDays(Number(r.days))}${r.part === 'AM' ? ', nửa đầu ca' : r.part === 'PM' ? ', nửa sau ca' : ''})`}</InfoRow>}
                {(r.time_from || r.time_to) && <InfoRow label="Giờ">{r.time_from?.slice(0, 5) ?? '…'} – {r.time_to?.slice(0, 5) ?? '…'}</InfoRow>}
                {r.paid !== null && <InfoRow label="Hưởng lương">{r.paid ? 'Có lương' : 'Không lương'}</InfoRow>}
                {r.amount !== null && <InfoRow label="Số tiền">{nf(r.amount)} đ</InfoRow>}
                {r.machine_code && <InfoRow label="Máy">{r.machine_code}</InfoRow>}
                {r.target_dept_name && <InfoRow label="Bộ phận nhận">{r.target_dept_name}</InfoRow>}
                {d.place && <InfoRow label="Nơi công tác">{d.place}</InfoRow>}
                {d.transport && <InfoRow label="Phương tiện">{d.transport}</InfoRow>}
                {d.cost_plan && <InfoRow label="Dự trù chi phí">{d.cost_plan}</InfoRow>}
                {d.due_date && <InfoRow label="Ngày dự sinh">{dmy(d.due_date)}</InfoRow>}
                {d.handover && <InfoRow label="Bàn giao việc cho">{d.handover}</InfoRow>}
                {(d.from_shift || d.to_shift) && <InfoRow label="Đổi ca">{d.from_shift} → {d.to_shift}</InfoRow>}
                {d.benefit && <InfoRow label="Lợi ích ước tính">{d.benefit}</InfoRow>}
              </div>
              <div className="mt-3 whitespace-pre-wrap rounded bg-sunk px-3 py-2 text-[14.5px]">{r.content}</div>
              {r.items?.length > 0 && (
                <div className="mt-3 overflow-x-auto rounded border border-line">
                  <table className="tbl">
                    <thead><tr><th>Mã VT</th><th>Tên hàng</th><th>Quy cách</th><th className="num">Số lượng</th><th>ĐVT</th><th className="num">Giá ước tính</th></tr></thead>
                    <tbody>{r.items.map((it, i) => (
                      <tr key={i}><td className="mono">{it.code ?? <Pill tone="warn">Chưa có mã</Pill>}</td><td>{it.name}</td><td>{it.spec}</td>
                        <td className="num">{nf(it.qty ?? 0, 2)}</td><td>{it.unit}</td><td className="num">{it.price ? nf(it.price) : '—'}</td></tr>
                    ))}</tbody>
                  </table>
                </div>
              )}
            </section>
          )}

          {/* Người lập */}
          {r.mine && r.status === 'PENDING_APPROVAL' && (
            <form action={withdrawRequest} className="card flex flex-wrap items-center gap-3 p-4">
              <input type="hidden" name="id" value={r.id} />
              <span className="mr-auto text-[14px]">Đề xuất đang chờ duyệt. Chưa ai duyệt thì bạn rút lại được để sửa.</span>
              <SubmitButton className="btn">Rút lại để sửa</SubmitButton>
            </form>
          )}
          {editable && (
            <div className="flex flex-wrap gap-2">
              <form action={submitRequest}><input type="hidden" name="id" value={r.id} /><SubmitButton className="btn btn-pri">Gửi đề xuất</SubmitButton></form>
              <form action={cancelRequest}><input type="hidden" name="id" value={r.id} /><SubmitButton className="btn btn-bad-o">Hủy đề xuất</SubmitButton></form>
            </div>
          )}

          {/* Người duyệt */}
          {r.my_turn && r.status === 'PENDING_APPROVAL' && (
            <section className="card flex flex-col gap-3 p-4" id="duyet-de-xuat">
              <h2 className="text-[17px] font-medium">Bạn đang giữ bước: {r.current_level}</h2>
              <div className="flex flex-wrap gap-2">
                {r.approval_id && <Link href={`/duyet/${r.approval_id}`} className="btn btn-pri">Duyệt / trả lại ở Quy trình duyệt</Link>}
                {!reviewing && <Link href={`/de-xuat-chung/${r.id}?sua=1`} className="btn btn-soft">Sửa nội dung trước khi duyệt</Link>}
              </div>
              <form action={refuseRequest} className="flex flex-wrap items-end gap-2">
                <input type="hidden" name="id" value={r.id} />
                <label className="lbl min-w-[260px] flex-1">Từ chối (đóng đề xuất, không gửi lại được)<input className="inp" name="reason" required placeholder="Lý do từ chối" /></label>
                <SubmitButton className="btn btn-bad-o">Từ chối</SubmitButton>
              </form>
            </section>
          )}

          {/* Người xử lý sau khi duyệt */}
          {r.can_handle && (
            <section className="card flex flex-col gap-3 p-4" id="xu-ly-de-xuat">
              <h2 className="text-[17px] font-medium">Đề xuất đã duyệt, chờ bạn xử lý</h2>
              {t.action === 'PR' && (
                <form action={prFromRequest} className="flex flex-col gap-2">
                  <input type="hidden" name="id" value={r.id} />
                  <datalist id="pr-mats">{(mats ?? []).map((m: { code: string; name: string | null; uom: string | null }) => <option key={m.code} value={`${m.code} · ${m.name} (${m.uom})`} />)}</datalist>
                  <p className="text-[13px] text-muted">Ghi mã vật tư cho từng dòng (hàng chưa có mã: khai ở Mua hàng → Vật tư trước). MES lập đề xuất mua loại {r.type_code === 'MUA_CCDC' ? 'công cụ dụng cụ' : 'bổ sung NVL'}, đi TP Mua → Giám đốc như thường.</p>
                  <table className="tbl"><thead><tr><th>Hàng đề xuất</th><th>Mã vật tư</th><th className="w-32 text-right">Số mua</th></tr></thead>
                    <tbody>{(r.items ?? []).map((it, i) => (
                      <tr key={i}><td>{it.name}{it.spec ? ` · ${it.spec}` : ''} ({nf(it.qty ?? 0, 2)} {it.unit})</td>
                        <td><input className="inp" name="pr_code" list="pr-mats" defaultValue={it.code ?? ''} aria-label={`Mã vật tư dòng ${i + 1}`} /></td>
                        <td><input className="inp text-right" name="pr_qty" defaultValue={it.qty ? numIn(it.qty) : ''} aria-label={`Số mua dòng ${i + 1}`} /></td></tr>
                    ))}</tbody>
                  </table>
                  <div className="flex flex-wrap items-end gap-2">
                    <label className="lbl">Ngày cần hàng<DateInput name="need_date" defaultValue={r.date_from} /></label>
                    <SubmitButton className="btn btn-pri">Lập đề xuất mua</SubmitButton>
                  </div>
                </form>
              )}
              {t.action === 'REPAIR' && r.machine_code && (
                <form action={repairRequest}><input type="hidden" name="id" value={r.id} />
                  <SubmitButton className="btn btn-pri">Mở phiếu sửa chữa {r.machine_code}</SubmitButton></form>
              )}
              <form action={doneRequest} className="flex flex-wrap items-end gap-2">
                <input type="hidden" name="id" value={r.id} />
                <label className="lbl min-w-[260px] flex-1">{t.action === 'HANDLE' ? 'Việc đã làm' : 'Hoặc ghi đã xử lý cách khác'}
                  <input className="inp" name="note" required placeholder='Ví dụ: "Đã chi 3.000.000 đ ngày 25/11/2026"' /></label>
                <SubmitButton className="btn">Đã xử lý</SubmitButton>
              </form>
            </section>
          )}

          {hist.length > 0 && (
            <section className="card p-4">
              <h2 className="mb-2 text-[17px] font-medium">Lịch sử duyệt</h2>
              <ul className="flex flex-col gap-2 text-[14px]">
                {hist.map((h, i) => (
                  <li key={i}><b>{h.label ?? 'Bước duyệt'}</b> · {h.actor} · {df(h.at, true)} · {ACT[h.action] ?? h.action}
                    {h.comment && <div className="mt-0.5 rounded bg-sunk px-3 py-1.5">{h.comment}</div>}</li>
                ))}
              </ul>
            </section>
          )}
        </div>

        <aside className="card h-fit p-4">
          <InfoRow label="Trạng thái"><StatusPill map={REQ_STATUS} value={r.status} /></InfoRow>
          <InfoRow label="Nhóm">{REQ_GROUP_NAME[r.grp] ?? r.grp}</InfoRow>
          <InfoRow label="Người đề xuất">{r.requester_name}{r.dept_name && <div className="text-[12.5px] text-muted">{r.dept_name}</div>}</InfoRow>
          {r.creator_name !== r.requester_name && <InfoRow label="Người lập">{r.creator_name}</InfoRow>}
          <InfoRow label="Lập lúc">{df(r.created_at, true)}</InfoRow>
          {r.status === 'PENDING_APPROVAL' && <>
            <InfoRow label="Đang ở bước">{r.current_level}</InfoRow>
            <InfoRow label="Người duyệt">{(r.current_approvers ?? []).map((p) => p.name).join(', ') || '—'}</InfoRow>
            <InfoRow label="Hạn">{df(r.step_due_at, true)}{r.overdue && <> <Pill tone="bad">Quá hạn</Pill></>}</InfoRow>
          </>}
          {r.handled_at && <InfoRow label={r.status === 'REFUSED' ? 'Lý do từ chối' : 'Kết quả xử lý'}>{r.handle_note}{r.handler_name && <div className="text-[12.5px] text-muted">{r.handler_name} · {df(r.handled_at, true)}</div>}</InfoRow>}
          {r.pr_no && <InfoRow label="Đề xuất mua"><Link className="text-brand hover:underline" href={`/de-xuat/${r.pr_id}`}>{r.pr_no}</Link></InfoRow>}
          {r.maint_wo_no && <InfoRow label="Phiếu sửa chữa"><Link className="text-brand hover:underline" href={`/may/bao-duong/phieu/${r.maint_wo_id}`}>{r.maint_wo_no}</Link></InfoRow>}
          {r.approval_id && (r.my_turn || can(me, 'approval', 'view')) && <InfoRow label="Quy trình duyệt"><Link className="text-brand hover:underline" href={`/duyet/${r.approval_id}`}>Mở trang duyệt</Link></InfoRow>}
          {me.is_admin && r.anonymous && <p className="mt-2 text-[12.5px] text-muted">Đề xuất ẩn danh: chỉ Quản trị thấy tên người gửi.</p>}
        </aside>
      </div>
    </>
  );
}
