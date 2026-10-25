import Link from 'next/link';
import { Empty, Flash, Pill, Toolbar } from '@/components/ui';
import { MStatus } from '@/components/machine-ui';
import { SubmitButton } from '@/components/submit-button';
import { hhmm, vnToday } from '@/lib/machine';
import { df } from '@/lib/format';
import { can, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { reviewCheck, saveCheck } from '../actions';

export const metadata = { title: 'Checklist đầu ca' };

type Res = { label: string; ok: boolean; note: string | null };

export default async function ChecklistPage({ searchParams }: { searchParams: Promise<{ ngay?: string; ok?: string; err?: string }> }) {
  const sp = await searchParams;
  const me = await requirePerm('machine', 'view');
  const today = vnToday();
  const day = /^\d{4}-\d{2}-\d{2}$/.test(sp.ngay ?? '') && sp.ngay! <= today ? sp.ngay! : today;
  const isToday = day === today;
  const supabase = await createClient();
  const [{ data: lines }, { data: items }, { data: checks }] = await Promise.all([
    supabase.schema('app').from('v_machines').select('id, code, name, status, status_since, status_eta, operators').is('line_id', null).eq('active', true).neq('status', 'OFF').order('code'),
    supabase.schema('app').from('v_maint_check_items').select('*').eq('active', true).order('sort'),
    supabase.schema('app').from('v_maint_checks').select('*').eq('check_date', day),
  ]);
  const itemsFor = (id: string) => (items ?? []).filter((i) => !i.machine_id || i.machine_id === id).map((i) => i.label);
  const canWrite = can(me, 'machine', 'create') && isToday;
  const canReview = can(me, 'machine', 'approve');
  const back = `/may/checklist${isToday ? '' : `?ngay=${day}`}`;
  const done = (lines ?? []).filter((l) => (checks ?? []).some((c) => c.machine_id === l.id)).length;
  return (
    <>
      <Toolbar title="Checklist bảo dưỡng đầu ca" reload={back}
        actions={<form className="flex items-center gap-2"><input type="date" name="ngay" defaultValue={day} max={today} className="inp w-auto" aria-label="Ngày" /><button className="btn" type="submit">Xem</button></form>} />
      <div className="mt-4" />
      <Flash ok={sp.ok} err={sp.err} />
      <p className="mb-4 text-[13.5px] text-muted">
        {isToday ? 'Hôm nay' : df(day)}: {done}/{(lines ?? []).length} dây chuyền đã làm. NV vận hành làm trước khi chạy máy. Mục không đạt thì ghi rõ vấn đề, hệ thống báo TP Kỹ thuật/QA và Quản lý SX.
        {can(me, 'machine', 'config') && <> Sửa danh sách mục kiểm tra trong <Link className="link" href="/may/cai-dat">Cài đặt máy</Link>.</>}
      </p>
      {(lines ?? []).length === 0 && <div className="card"><Empty>Chưa có dây chuyền nào đang dùng.</Empty></div>}
      <div className="grid gap-4 xl:grid-cols-2">
        {(lines ?? []).map((l) => {
          const c = (checks ?? []).find((x) => x.machine_id === l.id);
          const res: Res[] = c?.results ?? [];
          const labels = c && !canWrite ? res.map((r) => r.label) : itemsFor(l.id);
          const editable = canWrite && !c?.checked_at;
          return (
            <section key={l.id} className="card">
              <div className="card-h flex-wrap">
                <span><Link className="text-brand hover:underline" href={`/may/${l.id}`}>{l.code}</Link> <span className="font-normal text-muted">· {l.name}</span></span>
                <span className="flex items-center gap-2">
                  {c ? (c.has_issue ? <Pill tone="warn">Có vấn đề</Pill> : <Pill tone="ok">Đạt</Pill>) : <Pill>{isToday ? 'Chưa làm' : 'Không làm'}</Pill>}
                  {c?.checked_at && <Pill tone="info">TP Kỹ thuật/QA đã kiểm tra</Pill>}
                </span>
              </div>
              <div className="flex flex-wrap items-center gap-x-6 gap-y-1 border-b border-line px-4 py-2 text-[13px] text-muted">
                <MStatus value={l.status} />
                <span>Người đứng máy: {l.operators ?? '—'}</span>
                {c && <span>Ghi lúc {hhmm(c.done_at)} · {c.done_by_name ?? ''}</span>}
              </div>
              {editable ? (
                <form action={saveCheck} className="p-4">
                  <input type="hidden" name="machine_id" value={l.id} /><input type="hidden" name="machine_code" value={l.code} /><input type="hidden" name="back" value={back} />
                  <ul className="flex flex-col divide-y divide-line">
                    {labels.map((label, i) => {
                      const prev = res.find((r) => r.label === label);
                      return (
                        <li key={label} className="grid gap-2 py-2.5 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center">
                          <input type="hidden" name="item" value={label} />
                          <span className="text-[14.5px]">{label}</span>
                          <span className="flex gap-1.5" role="radiogroup" aria-label={label}>
                            <label className="btn btn-sm has-[:checked]:border-brand has-[:checked]:bg-brand has-[:checked]:text-white"><input type="radio" name={`ok_${i}`} value="ok" className="sr-only" defaultChecked={prev?.ok === true} />Đạt</label>
                            <label className="btn btn-sm has-[:checked]:border-bad has-[:checked]:bg-bad has-[:checked]:text-white"><input type="radio" name={`ok_${i}`} value="ng" className="sr-only" defaultChecked={prev?.ok === false} />Không đạt</label>
                          </span>
                          <input name={`note_${i}`} className="inp sm:col-span-2" placeholder="Ghi vấn đề nếu không đạt (ví dụ: áp khí 0,45 MPa)" defaultValue={prev?.note ?? ''} aria-label={`Ghi chú ${label}`} />
                        </li>
                      );
                    })}
                  </ul>
                  <label className="lbl mt-2">Ghi chú chung<input name="note" className="inp" defaultValue={c?.note ?? ''} /></label>
                  <div className="mt-3"><SubmitButton>{c ? 'Cập nhật checklist' : 'Ghi checklist'}</SubmitButton></div>
                </form>
              ) : c ? (
                <div className="p-4">
                  <ul className="flex flex-col gap-1 text-[14px]">
                    {res.map((r) => (
                      <li key={r.label} className="flex flex-wrap gap-2"><span className={r.ok ? 'text-brand' : 'font-medium text-bad'}>{r.ok ? '✓' : '✗'}</span><span>{r.label}</span>{r.note && <span className="text-muted">· {r.note}</span>}</li>
                    ))}
                  </ul>
                  {c.note && <p className="mt-2 text-[13.5px]"><span className="text-muted">Ghi chú:</span> {c.note}</p>}
                  {c.checked_at && <p className="mt-2 text-[12.5px] text-muted">Kiểm tra lúc {df(c.checked_at, true)} · {c.checked_by_name}</p>}
                </div>
              ) : <Empty>{isToday ? 'Chưa làm checklist.' : 'Ngày này không có checklist.'}</Empty>}
              {c && !c.checked_at && canReview && (
                <form action={reviewCheck} className="border-t border-line px-4 py-3"><input type="hidden" name="id" value={c.id} /><input type="hidden" name="back" value={back} />
                  <SubmitButton className="btn btn-sm btn-soft">Đã kiểm tra</SubmitButton></form>
              )}
            </section>
          );
        })}
      </div>
    </>
  );
}
