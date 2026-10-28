import Link from 'next/link';
import { notFound } from 'next/navigation';
import { Empty, Flash, InfoRow, Pill, StatusPill, Toolbar } from '@/components/ui';
import { SubmitButton } from '@/components/submit-button';
import { ASSIGNEE, WO_STATUS, WO_TYPE } from '@/lib/machine';
import { df, nf } from '@/lib/format';
import { can, requirePage, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { addPart, cancelWo, confirmWo, deleteRow, finishWo, saveWoProgress, startWo } from '../../../actions';

export const metadata = { title: 'Phiếu bảo dưỡng' };

type Step = { label: string; done: boolean };

export default async function WoPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; err?: string }> }) {
  const { id } = await params;
  const sp = await searchParams;
  await requirePage('may-bao-duong');
  const me = await requirePerm('machine', 'view');
  const supabase = await createClient();
  const { data: w } = await supabase.schema('app').from('v_maint_wos').select('*').eq('id', id).maybeSingle();
  if (!w) notFound();
  const [{ data: parts }, { data: mats }] = await Promise.all([
    supabase.schema('mfg').from('maint_wo_parts').select('*').eq('wo_id', id).order('created_at'),
    supabase.schema('master').from('materials').select('id, code, name, uom').eq('active', true).order('code'),
  ]);
  const back = `/may/bao-duong/phieu/${id}`;
  const open = w.status === 'OPEN' || w.status === 'IN_PROGRESS';
  const canEdit = can(me, 'machine', 'edit') && open;
  const steps: Step[] = Array.isArray(w.steps) ? w.steps : [];
  const etaLocal = w.eta ? new Date(new Date(w.eta).getTime() + 7 * 3_600_000).toISOString().slice(0, 16) : '';
  return (
    <>
      <Toolbar title={<span>{w.wo_no} · {w.title}</span>} actions={<>
        {w.status === 'OPEN' && can(me, 'machine', 'edit') && (
          <form action={startWo}><input type="hidden" name="id" value={id} /><input type="hidden" name="back" value={back} /><SubmitButton>Bắt đầu làm</SubmitButton></form>
        )}
        {w.status === 'DONE' && !w.confirmed_at && ['SX_TP', 'ADMIN'].some((r) => me.roles.includes(r)) && w.done_by !== me.id && (
          <form action={confirmWo}><input type="hidden" name="id" value={id} /><input type="hidden" name="back" value={back} /><SubmitButton>Xác nhận máy chạy lại đạt</SubmitButton></form>
        )}
        {w.plan_id && <Link className="btn btn-soft" href={`/may/bao-duong/ke-hoach/${w.plan_id}`}>Kế hoạch</Link>}
        <Link className="btn" href="/may/bao-duong?loc=phieu">Đóng</Link>
      </>} />
      <div className="mt-4" />
      <Flash ok={sp.ok} err={sp.err} />
      <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="flex min-w-0 flex-col gap-4">
          {canEdit ? (
            <form className="card">
              <input type="hidden" name="id" value={id} /><input type="hidden" name="back" value={back} />
              <div className="card-h">{w.wo_type === 'CM' ? 'Sửa chữa' : 'Các bước bảo dưỡng'}</div>
              <div className="flex flex-col gap-3 p-4">
                {steps.length > 0 && (
                  <ul className="flex flex-col gap-2">
                    {steps.map((s, i) => (
                      <li key={i}><label className="flex items-start gap-2.5 text-[14.5px]">
                        <input type="hidden" name="step_label" value={s.label} />
                        <input type="checkbox" name={`step_${i}`} defaultChecked={s.done} className="mt-1 h-4 w-4" />{s.label}
                      </label></li>
                    ))}
                  </ul>
                )}
                {w.wo_type === 'CM' && (
                  <>
                    <label className="lbl">Nguyên nhân<textarea name="cause" className="inp" rows={2} defaultValue={w.cause ?? ''} placeholder="Quạt làm mát biến tần hỏng, biến tần quá nhiệt" /></label>
                    <label className="lbl">Dự kiến chạy lại<input name="eta" type="datetime-local" className="inp max-w-xs" defaultValue={etaLocal} /></label>
                  </>
                )}
                <label className="lbl">Ghi chú<input name="note" className="inp" defaultValue={w.note ?? ''} /></label>
                <div><SubmitButton className="btn btn-soft" formAction={saveWoProgress}>Lưu tiến độ</SubmitButton></div>
              </div>
              <div className="border-t border-line bg-sunk/50 p-4">
                <div className="mb-2 text-[14px] font-medium">Hoàn thành phiếu</div>
                <div className="grid gap-3 md:grid-cols-[minmax(0,1fr)_200px]">
                  <label className="lbl"><span className="req">Việc đã làm</span><textarea name="action_taken" className="inp" rows={2} placeholder={w.wo_type === 'CM' ? 'Thay quạt làm mát biến tần, chạy thử 30 phút' : 'Đã vệ sinh 12 module, điện trở thanh gia nhiệt đạt'} /></label>
                  <label className="lbl">Kết quả<select name="result" className="inp"><option value="OK">Đạt, máy chạy lại được</option><option value="NOT_OK">Chưa đạt</option></select></label>
                </div>
                <div className="mt-3"><SubmitButton formAction={finishWo}>Hoàn thành</SubmitButton></div>
              </div>
            </form>
          ) : (
            <section className="card">
              <div className="card-h">{w.wo_type === 'CM' ? 'Sửa chữa' : 'Các bước bảo dưỡng'}</div>
              <div className="p-4 text-[14px]">
                {steps.length > 0 && <ul className="mb-3 flex flex-col gap-1">{steps.map((s, i) => <li key={i}>{s.done ? '✓' : '○'} {s.label}</li>)}</ul>}
                {w.cause && <p><span className="text-muted">Nguyên nhân:</span> {w.cause}</p>}
                {w.action_taken && <p><span className="text-muted">Việc đã làm:</span> {w.action_taken}</p>}
                {w.note && <p><span className="text-muted">Ghi chú:</span> {w.note}</p>}
                {!steps.length && !w.cause && !w.action_taken && <span className="text-muted">Chưa có nội dung.</span>}
              </div>
            </section>
          )}

          <section className="card overflow-x-auto">
            <div className="card-h">Phụ tùng, vật tư dùng</div>
            {(parts ?? []).length ? (
              <table className="tbl">
                <thead><tr><th>Phụ tùng</th><th className="num">Số lượng</th><th>ĐVT</th><th>Phiếu xuất kho</th>{canEdit && <th />}</tr></thead>
                <tbody>
                  {(parts ?? []).map((p) => (
                    <tr key={p.id}>
                      <td>{p.item}{p.note && <div className="text-[12.5px] text-muted">{p.note}</div>}</td><td className="num">{nf(p.qty, 2)}</td><td>{p.uom ?? ''}</td>
                      <td>{p.issued ? <Pill tone="ok">Đã xuất</Pill> : <Pill>Chờ Kế toán SX duyệt xuất</Pill>}</td>
                      {canEdit && <td>{!p.issued && <form action={deleteRow}><input type="hidden" name="table" value="part" /><input type="hidden" name="id" value={p.id} /><input type="hidden" name="back" value={back} /><SubmitButton className="btn btn-sm btn-bad-o" pendingText="…">Xóa</SubmitButton></form>}</td>}
                    </tr>
                  ))}
                </tbody>
              </table>
            ) : <Empty>Chưa ghi phụ tùng.</Empty>}
            {canEdit && (
              <form action={addPart} className="grid gap-3 border-t border-line p-4 sm:grid-cols-2 lg:grid-cols-[1fr_1fr_100px_90px_auto] lg:items-end">
                <input type="hidden" name="wo_id" value={id} /><input type="hidden" name="back" value={back} />
                <label className="lbl"><span className="req">Phụ tùng</span><input name="item" className="inp" required placeholder="Quạt làm mát biến tần" /></label>
                <label className="lbl">Mã kho<select name="material_id" className="inp" defaultValue=""><option value="">Chưa có mã</option>{(mats ?? []).map((m) => <option key={m.id} value={m.id}>{m.code} · {m.name}</option>)}</select></label>
                <label className="lbl"><span className="req">SL</span><input name="qty" className="inp" inputMode="decimal" required /></label>
                <label className="lbl">ĐVT<input name="uom" className="inp" placeholder="cái" /></label>
                <SubmitButton>Thêm</SubmitButton>
              </form>
            )}
            <p className="px-4 pb-3 text-[12.5px] text-muted">Phiếu xuất phụ tùng chỉ tạo từ phiếu bảo dưỡng, sửa chữa: Quản lý SX (thủ kho) xuất, Kế toán SX duyệt.</p>
          </section>
        </div>

        <section className="card h-fit px-4 py-2">
          <InfoRow label="Loại">{w.wo_type === 'CM' ? <Pill tone="bad">{WO_TYPE.CM}</Pill> : WO_TYPE.PM}{w.plan_level === 'MAJOR' && <> <Pill tone="warn">Bảo dưỡng lớn</Pill></>}</InfoRow>
          <InfoRow label="Trạng thái"><StatusPill map={WO_STATUS} value={w.status} /></InfoRow>
          <InfoRow label="Máy"><Link className="link" href={`/may/${w.machine_id}`}>{w.machine_code} · {w.machine_name}</Link></InfoRow>
          {w.line_code !== w.machine_code && <InfoRow label="Dây chuyền"><Link className="link" href={`/may/${w.line_id}`}>{w.line_code}</Link></InfoRow>}
          <InfoRow label="Người làm">{ASSIGNEE[w.assignee_role] ?? w.assignee_role ?? '—'}</InfoRow>
          {w.planned_date && <InfoRow label="Ngày dự kiến">{df(w.planned_date)}</InfoRow>}
          {w.est_minutes ? <InfoRow label="Dừng máy">{w.est_minutes} phút · {w.off_shift ? 'ngoài giờ ca' : 'trong ca'}</InfoRow> : null}
          {w.eta && <InfoRow label="Dự kiến chạy lại">{df(w.eta, true)}</InfoRow>}
          <InfoRow label="Tạo">{df(w.created_at, true)}{w.created_by_name ? ` · ${w.created_by_name}` : ''}</InfoRow>
          {w.started_at && <InfoRow label="Bắt đầu">{df(w.started_at, true)}</InfoRow>}
          {w.finished_at && <InfoRow label="Xong">{df(w.finished_at, true)}{w.done_by_name ? ` · ${w.done_by_name}` : ''}</InfoRow>}
          {w.result && <InfoRow label="Kết quả">{w.result === 'OK' ? <Pill tone="ok">Đạt</Pill> : <Pill tone="bad">Chưa đạt</Pill>}</InfoRow>}
          <InfoRow label="TP SX xác nhận">{w.confirmed_at ? `Máy chạy lại đạt · ${df(w.confirmed_at, true)} · ${w.confirmed_by_name ?? ''}` : w.status === 'DONE' ? 'Chờ TP SX xác nhận máy chạy lại đạt' : '—'}</InfoRow>
          {w.status === 'OPEN' && can(me, 'machine', 'edit') && (
            <form action={cancelWo} className="py-3"><input type="hidden" name="id" value={id} /><input type="hidden" name="back" value={back} />
              <SubmitButton className="btn btn-sm btn-bad-o" pendingText="…">Hủy phiếu</SubmitButton></form>
          )}
        </section>
      </div>
    </>
  );
}
