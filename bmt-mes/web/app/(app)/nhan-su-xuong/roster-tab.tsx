// Nhân sự xưởng → Bảng ca tuần (anh Bình duyệt 28/10/2026): máy nào chạy ca 1, ca 2; ai làm ca 2 cả tuần (đổi ca vào Chủ nhật);
// MES lập → TP SX sửa, gửi → Giám đốc duyệt (được sửa) → MES gửi lịch ca cho công nhân trước 12:00 thứ 7.
// Nhân sự xưởng → Sổ giờ: giờ đứng máy theo lịch máy (luân phiên, lệch quá ngưỡng thì cảnh báo TP SX).
import Link from 'next/link';
import { Alert, LockNote, dd, wd } from '@/components/kh';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Kpi, Pill } from '@/components/ui';
import { df, nf } from '@/lib/format';
import type { Kh } from '@/lib/kh/load';
import { type RMachine, type RPerson, type RosterSummary, mondayOf, weekDays } from '@/lib/kh/roster';
import { addDays, nightHours, peopleOf, toMin } from '@/lib/kh/scheduler';
import { cancelWeek, reviewWeek, saveWeek, submitWeek, suggestWeek } from './actions';

export type RosterRow = {
  id: string; roster_no: string; week_start: string; week_end: string; plan_id: string | null; plan_no: string | null; status: string;
  machines: RMachine[]; people: RPerson[]; qc: { mode?: 'QC' | 'LEAD'; who?: string | null }; summary: Partial<RosterSummary>; note: string | null;
  edits: { by_name?: string; at?: string; before?: string; note?: string | null }[];
  created_by: string | null; created_by_name: string | null; created_at: string; submitted_by: string | null; submitted_by_name: string | null; submitted_at: string | null;
  reviewed_by_name: string | null; reviewed_at: string | null; review_note: string | null; sent_at: string | null; sent_late: boolean | null; deadline: string; req_no: string | null;
};
export type HoursRow = { operator_code: string; work_date: string; attend_min: number; night_min: number; shift_no: number };
type OpLite = { code: string; full_name: string | null; is_deputy: boolean };
type OpShiftRow = { operator_code: string; date_from: string; date_to: string; shift_no: number };

export const ST: Record<string, [string, 'warn' | 'ok' | 'bad' | 'mute' | 'info']> = {
  DRAFT: ['Nháp, TP SX đang sửa', 'info'], PROPOSED: ['Chờ Giám đốc duyệt', 'warn'], APPROVED: ['Đã duyệt, đã gửi công nhân', 'ok'],
  RETURNED: ['Giám đốc trả lại', 'bad'], CANCELLED: ['Đã hủy', 'mute'], REPLACED: ['Đã thay bằng bảng mới', 'mute'],
};
const h1 = (v: number) => nf(Math.round(v * 10) / 10, Number.isInteger(Math.round(v * 10) / 10) ? 0 : 1);
const hm = (t: string) => t.slice(0, 5);
const TYPE: Record<string, string> = { MIXER: 'Máy trộn', BUNCHER: 'Bện', EXTRUDER_SI: 'Line silicone', TWISTER: 'Xoắn', EXTRUDER_TP: 'Line vỏ', PACKER: 'Đóng gói' };

// Giờ ca theo số ca (1 = A, 2 = B, 3 = C) và giờ làm đêm của ca
export function shiftInfo(kh: Kh, no: number) {
  const s = kh.cfg.shifts.find((x) => x.code === (no === 2 ? 'B' : no === 3 ? 'C' : 'A'));
  if (!s) return { label: `ca ${no}`, night: 0 };
  const a = toMin(s.start_time), b0 = toMin(s.end_time), b = b0 <= a ? b0 + 1440 : b0;
  return { label: `ca ${no} (${hm(s.start_time)}–${hm(s.end_time)})`, night: nightHours(a / 60, b / 60) };
}

export function RosterTab({ kh, rosters, sp, roles, userId, ops, opShifts, canEdit }: {
  kh: Kh; rosters: RosterRow[]; sp: Record<string, string | undefined>; roles: string[]; userId: string; ops: OpLite[]; opShifts: OpShiftRow[]; canEdit: boolean;
}) {
  const today = kh.now.date;
  const thisMon = mondayOf(today), nextMon = addDays(thisMon, 7);
  const week = /^\d{4}-\d{2}-\d{2}$/.test(sp.w ?? '') ? mondayOf(sp.w!) : nextMon;
  const days = weekDays(week, kh.cal.wd);
  const tomorrow = addDays(today, 1);
  const from = week < tomorrow ? tomorrow : week; // bảng ca áp từ ngày mai
  const r = rosters.find((x) => x.week_start === week && ['DRAFT', 'PROPOSED', 'RETURNED'].includes(x.status))
    ?? rosters.find((x) => x.week_start === week && x.status === 'APPROVED') ?? null;
  const isTp = roles.includes('SX_TP') || roles.includes('ADMIN');
  const isGd = roles.includes('BGD') || roles.includes('ADMIN');
  const editable = Boolean(r && ((['DRAFT', 'RETURNED'].includes(r.status) && canEdit) || (r.status === 'PROPOSED' && isGd && r.submitted_by !== userId)));
  const s = r?.summary ?? {};
  const deadline = r?.deadline ?? null;
  const lateNow = !r || r.status !== 'APPROVED' ? new Date() > new Date(deadline ?? `${addDays(week, -2)}T05:00:00Z`) : false;
  const name = (c: string) => ops.find((o) => o.code === c)?.full_name ?? '';
  const shOf = (c: string) => r?.people.find((p) => p.code === c)?.shift ?? 1;
  const nOf = (m: string, d: string) => r?.machines.find((x) => x.machine === m && x.date === d)?.shifts ?? 1;
  const hasEntries = (m: string) => Boolean(r?.machines.some((x) => x.machine === m));
  const hid = (k: string, v: string | null | undefined) => <input type="hidden" name={k} value={v ?? ''} />;
  const base = <>{hid('w', week)}{hid('plan_id', r?.plan_id ?? kh.planId)}</>;
  const P = peopleOf(kh.cfg);
  const absentAll = (c: string) => days.filter((d) => d >= from).every((d) => P.absences.some((a) => a.code === c && a.part === 'FULL' && a.from <= d && d <= a.to));
  const extraUsed = [2, 3].filter((no) => r?.machines.some((x) => x.shifts >= no));
  const orderLabel = new Map(kh.orders.map((o) => [o.id, `${o.label} ${o.product_code}`]));
  const finIds = Object.keys(s.plan?.finish ?? {});

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center gap-2">
        {[[thisMon, 'Tuần này'], [nextMon, 'Tuần sau'], [addDays(nextMon, 7), 'Tuần sau nữa']].map(([w, t]) => (
          <Link key={w} className={`btn btn-sm ${w === week ? 'btn-pri' : ''}`} href={`/nhan-su-xuong?tab=ca&w=${w}`}>{t} {dd(w)}–{dd(addDays(w, 6))}</Link>
        ))}
        <span className="text-[13px] text-muted">Hạn Giám đốc duyệt, MES gửi công nhân: <b className={lateNow ? 'text-bad' : ''}>12:00 thứ 7 {dd(addDays(week, -2))}</b></span>
      </div>

      <section className="card" id="bang-ca">
        <div className="card-h"><h2>Bảng ca tuần {dd(week)}–{dd(addDays(week, 6))}{r ? ` · ${r.roster_no}` : ''}</h2>
          {r ? <Pill tone={ST[r.status]?.[1] ?? 'mute'}>{ST[r.status]?.[0] ?? r.status}{r.status === 'APPROVED' && r.sent_late ? ' (sau 12:00 thứ 7)' : ''}</Pill> : <Pill>Chưa lập</Pill>}</div>
        {!r ? (
          <div className="flex flex-col gap-3 px-4 py-4 text-[14px]">
            <div>Chưa có bảng ca tuần này: mọi máy chạy ca 1 ({shiftInfo(kh, 1).label.slice(5)}), mọi người làm ca 1.</div>
            {canEdit ? (
              <form action={suggestWeek} className="flex flex-wrap items-center gap-2">
                {base}{hid('tab', 'ca')}
                <SubmitButton className="btn btn-pri" pendingText="MES đang tính…">MES lập bảng ca tuần này</SubmitButton>
                <span className="text-[12.5px] text-muted">MES thử thêm ca 2 cho từng nhóm máy với người thật, chọn người rảnh làm ca 2 (xoay vòng theo số tuần đã làm ca 2, giờ đứng máy 4 tuần).</span>
              </form>
            ) : <LockNote>TP SX / Kế hoạch SX lập bảng ca</LockNote>}
          </div>
        ) : (
          <div className="flex flex-col gap-3 px-4 py-3 text-[14px]">
            {s.reason && <div><b>MES:</b> {s.reason}</div>}
            {s.plan && s.base && (
              <div className="grid gap-3 sm:grid-cols-3">
                <Kpi label="Kế hoạch xong sau (ngày làm việc)" value={`${h1(s.plan.makespan)}`} hint={`chỉ ca 1: ${h1(s.base.makespan)} ngày`} tone={s.plan.makespan < s.base.makespan - 0.05 ? 'ok' : undefined} />
                <Kpi label="Trễ ngày chốt / hạn giao" value={`${s.plan.late} ngày`} hint={`chỉ ca 1: ${s.base.late} ngày`} tone={s.plan.late > 0 ? 'bad' : 'ok'} />
                <Kpi label="Ngày-người không có việc đứng máy" value={s.plan.idle} hint={`chỉ ca 1: ${s.base.idle}`} tone={s.plan.idle ? 'warn' : 'ok'} />
              </div>
            )}
            {r.status === 'RETURNED' && r.review_note && <Alert tone="bad" title="Giám đốc trả lại">{r.review_note}</Alert>}
            {(s.warnings ?? []).length > 0 && <Alert tone="warn" title="Cần xem">{(s.warnings ?? []).map((w) => <div key={w}>{w}</div>)}</Alert>}
          </div>
        )}
        {r && (
          <>
            <div className="overflow-x-auto border-t border-line"><table className="tbl">
              <thead><tr><th>Máy chạy ca nào</th>{days.map((d) => <th key={d} className={`text-center ${d < from ? 'text-muted' : ''}`}>{wd(d)} {dd(d)}</th>)}</tr></thead>
              <tbody>{kh.machines.map((m) => (
                <tr key={m.code}><td className="whitespace-nowrap"><b>{m.code}</b> <span className="text-[12px] text-muted">{TYPE[m.machine_type] ?? m.machine_type}</span></td>
                  {days.map((d) => { const n = nOf(m.code, d); return (
                    <td key={d} className={`text-center text-[13px] ${n > 1 ? 'bg-info/10 font-semibold' : 'text-muted'}`}>{n === 3 ? 'Ca 1 + 2 + 3' : n === 2 ? 'Ca 1 + 2' : 'Ca 1'}</td>); })}
                </tr>
              ))}</tbody>
            </table></div>
            <div className="overflow-x-auto border-t border-line"><table className="tbl">
              <thead><tr><th>Người</th><th>Ca cả tuần</th><th className="text-right">Đứng máy tuần này (giờ, theo lịch)</th><th className="text-right">Giờ đêm</th>
                <th className="text-right">4 tuần trước (giờ)</th><th className="text-right">Đã làm ca 2 (tuần, 12 tuần qua)</th><th className="text-right">Ngày không có việc</th></tr></thead>
              <tbody>{ops.map((o) => {
                const x = s.hours?.find((h) => h.code === o.code);
                const p = r.people.find((y) => y.code === o.code);
                return (
                  <tr key={o.code}>
                    <td className="whitespace-nowrap"><b>{o.code}</b>{name(o.code) ? ` · ${name(o.code)}` : ''}{absentAll(o.code) && <span className="text-warn"> · vắng cả tuần</span>}</td>
                    <td>{shiftInfo(kh, p?.shift ?? 1).label}{p?.lead && <> <Pill tone="info">Phụ trách ca</Pill></>}</td>
                    <td className="text-right">{x ? h1(x.week_h) : '—'}</td><td className="text-right">{x && x.night_h > 0 ? h1(x.night_h) : '—'}</td>
                    <td className="text-right">{x ? h1(x.prev4_h) : '—'}</td><td className="text-right">{x ? x.ca2_weeks : '—'}</td>
                    <td className={`text-right ${x?.idle_days ? 'text-warn' : ''}`}>{x ? x.idle_days : '—'}</td>
                  </tr>
                );
              })}</tbody>
            </table></div>
            <div className="border-t border-line px-4 py-3 text-[13.5px]">
              {extraUsed.length ? <>Đo mẫu QC ca 2: <b>{r.qc.mode === 'QC' ? `QC làm ca 2 (${r.qc.who ?? ''})` : `ủy quyền người phụ trách ca (${r.people.filter((p) => p.lead).map((p) => p.code).join(', ')})`}</b> · </> : null}
              Đổi ca vào Chủ nhật (nghỉ ít nhất 12 giờ). Ca 2 tối thiểu 2 người, không ai làm ca một mình.{shiftInfo(kh, 2).night > 0 ? ` Ca 2 có ${h1(shiftInfo(kh, 2).night)} giờ làm đêm (trả thêm ít nhất 30 %, nghỉ giữa ca ít nhất 45 phút).` : ''}
              {r.note && <div className="mt-1 text-muted">Ghi chú: {r.note}</div>}
              <div className="mt-1 text-[12.5px] text-muted">{r.created_by_name ? `MES lập theo yêu cầu ${r.created_by_name} ${df(r.created_at, true)}` : ''}{r.submitted_by_name ? ` · TP SX gửi: ${r.submitted_by_name} ${df(r.submitted_at, true)}` : ''}{r.reviewed_by_name ? ` · Giám đốc: ${r.reviewed_by_name} ${df(r.reviewed_at, true)}` : ''}{r.sent_at ? ` · gửi công nhân ${df(r.sent_at, true)}` : ''}{r.req_no ? ` · ca máy ${r.req_no}` : ''}</div>
              {r.edits.length > 0 && <div className="mt-1 text-[12.5px] text-muted">Giám đốc sửa khi duyệt: {r.edits.map((e) => `${e.by_name ?? ''} ${e.at ? df(e.at, true) : ''}${e.note ? ` (${e.note})` : ''}; trước đó: ${e.before ?? ''}`).join(' · ')}</div>}
            </div>
            {finIds.length > 0 && (
              <div className="overflow-x-auto border-t border-line"><table className="tbl">
                <thead><tr><th>Lô</th><th>Xong nếu chỉ ca 1</th><th>Xong theo bảng ca</th></tr></thead>
                <tbody>{finIds.map((id) => (
                  <tr key={id}><td>{orderLabel.get(id) ?? id.slice(0, 8)}</td><td>{dd(s.base?.finish?.[id])}</td>
                    <td className={(s.plan?.finish?.[id] ?? '') < (s.base?.finish?.[id] ?? '') ? 'font-semibold text-ok' : ''}>{dd(s.plan?.finish?.[id])}</td></tr>
                ))}</tbody>
              </table></div>
            )}
            <div className="flex flex-wrap items-center gap-2 border-t border-line px-4 py-3">
              <Link className="btn btn-sm" href={`/in/bang-ca?id=${r.id}`} target="_blank">In bảng ca</Link>
              {['DRAFT', 'RETURNED'].includes(r.status) && canEdit && (
                <form action={suggestWeek} className="flex">{base}{hid('id', r.id)}<SubmitButton className="btn btn-sm" pendingText="MES đang tính…">MES lập lại</SubmitButton></form>
              )}
              {['DRAFT', 'RETURNED'].includes(r.status) && isTp && (
                <form action={submitWeek} className="flex flex-wrap items-center gap-2" id="gui-giam-doc">{base}{hid('id', r.id)}
                  <input name="note" className="inp w-[240px] py-1" placeholder="Ghi chú gửi Giám đốc" aria-label="Ghi chú gửi Giám đốc" defaultValue={r.note ?? ''} />
                  <SubmitButton className="btn btn-sm btn-pri">Duyệt và gửi Giám đốc</SubmitButton></form>
              )}
              {r.status === 'PROPOSED' && isGd && r.submitted_by !== userId && (
                <form action={reviewWeek} className="flex flex-wrap items-center gap-2" id="giam-doc-duyet">{base}{hid('id', r.id)}
                  <input name="note" className="inp w-[240px] py-1" placeholder="Ý kiến (bắt buộc khi trả lại)" aria-label="Ý kiến duyệt bảng ca" />
                  <SubmitButton className="btn btn-sm btn-pri" formAction={async (f: FormData) => { 'use server'; f.set('approve', '1'); await reviewWeek(f); }}>Duyệt và gửi công nhân</SubmitButton>
                  <SubmitButton className="btn btn-sm btn-bad-o" formAction={async (f: FormData) => { 'use server'; f.set('approve', '0'); await reviewWeek(f); }}>Trả lại</SubmitButton>
                </form>
              )}
              {['DRAFT', 'PROPOSED', 'RETURNED'].includes(r.status) && (canEdit || isGd) && (
                <form action={cancelWeek} className="flex flex-wrap items-center gap-1.5">{base}{hid('id', r.id)}
                  <input name="reason" className="inp w-[160px] py-1" placeholder="Lý do hủy" aria-label="Lý do hủy bảng ca" required />
                  <SubmitButton className="btn btn-sm">Hủy bảng ca</SubmitButton></form>
              )}
              {r.status === 'APPROVED' && canEdit && (
                <form action={suggestWeek} className="flex items-center gap-2">{base}
                  <SubmitButton className="btn btn-sm" pendingText="MES đang tính…">Lập bảng mới thay bảng này</SubmitButton>
                  <span className="text-[12.5px] text-muted">bảng mới cũng phải Giám đốc duyệt</span></form>
              )}
            </div>
          </>
        )}
      </section>

      {r && editable && (
        <details className="card" open={r.status !== 'APPROVED'} id="sua-bang-ca">
          <summary className="card-h cursor-pointer"><h2>{r.status === 'PROPOSED' ? 'Giám đốc sửa bảng ca trước khi duyệt' : 'Sửa bảng ca'}</h2><span className="text-[12.5px] text-muted">lưu thì MES tính lại ngày xong, giờ mỗi người</span></summary>
          <form action={saveWeek} className="flex flex-col gap-3 border-t border-line px-4 py-3">
            {base}{hid('id', r.id)}{hid('reason_txt', s.reason ?? '')}
            <div className="overflow-x-auto"><table className="tbl">
              <thead><tr><th>Máy</th><th>Số ca</th>{days.map((d) => <th key={d} className="text-center">{wd(d)} {dd(d)}</th>)}</tr></thead>
              <tbody>{kh.machines.map((m) => {
                const top = Math.max(1, ...days.map((d) => nOf(m.code, d)));
                return (
                  <tr key={m.code}><td className="whitespace-nowrap"><b>{m.code}</b> <span className="text-[12px] text-muted">{TYPE[m.machine_type] ?? m.machine_type}</span></td>
                    <td><select name={`ms_${m.code}`} defaultValue={String(top)} className="inp w-[90px] py-1" aria-label={`Số ca ${m.code}`}>
                      <option value="1">1 ca</option><option value="2">2 ca</option><option value="3">3 ca</option></select></td>
                    {days.map((d) => (
                      <td key={d} className="text-center"><input type="checkbox" name={`md_${m.code}`} value={d} disabled={d < from}
                        defaultChecked={d < from ? nOf(m.code, d) > 1 : (hasEntries(m.code) ? nOf(m.code, d) > 1 : true)} aria-label={`${m.code} chạy thêm ca ${d}`} />
                        {d < from && nOf(m.code, d) > 1 && <input type="hidden" name={`mp_${m.code}`} value={`${d}:${nOf(m.code, d)}`} />}</td>
                    ))}
                  </tr>
                );
              })}</tbody>
            </table></div>
            <p className="text-[12.5px] text-muted">Số ca 2 / 3: máy chạy thêm ca những ngày được tích. Line silicone chạy thêm ca thì máy trộn cũng chạy cùng ca (silicone đã pha chỉ dùng trong hạn).</p>
            <div className="overflow-x-auto"><table className="tbl">
              <thead><tr><th>Người</th><th>Ca cả tuần</th><th>Phụ trách ca 2</th><th>Phụ trách ca 3</th></tr></thead>
              <tbody>{ops.map((o) => (
                <tr key={o.code}><td className="whitespace-nowrap"><b>{o.code}</b>{name(o.code) ? ` · ${name(o.code)}` : ''}{o.is_deputy ? ' · tổ phó' : ''}</td>
                  <td><select name={`ps_${o.code}`} defaultValue={String(shOf(o.code))} className="inp w-auto py-1" aria-label={`Ca của ${o.code}`}>
                    {[1, 2, 3].map((n) => <option key={n} value={n}>{shiftInfo(kh, n).label}</option>)}</select></td>
                  <td><input type="radio" name="lead2" value={o.code} defaultChecked={Boolean(r.people.find((p) => p.code === o.code && p.lead && p.shift === 2))} aria-label={`${o.code} phụ trách ca 2`} /></td>
                  <td><input type="radio" name="lead3" value={o.code} defaultChecked={Boolean(r.people.find((p) => p.code === o.code && p.lead && p.shift === 3))} aria-label={`${o.code} phụ trách ca 3`} /></td>
                </tr>
              ))}</tbody>
            </table></div>
            <div className="flex flex-wrap items-center gap-3 text-[13.5px]">
              <span className="text-muted">Đo mẫu QC ca 2:</span>
              <label className="inline-flex items-center gap-1.5"><input type="radio" name="qc_mode" value="LEAD" defaultChecked={r.qc.mode !== 'QC'} />Ủy quyền người phụ trách ca</label>
              <label className="inline-flex items-center gap-1.5"><input type="radio" name="qc_mode" value="QC" defaultChecked={r.qc.mode === 'QC'} />QC làm ca 2:</label>
              <input name="qc_who" className="inp w-[200px] py-1" defaultValue={r.qc.who ?? ''} placeholder="Tên người QC" aria-label="Người QC làm ca 2" />
            </div>
            <label className="lbl">{r.status === 'PROPOSED' ? 'Giám đốc sửa gì (ghi vào lịch sử, báo TP SX)' : 'Ghi chú'}
              <input name={r.status === 'PROPOSED' ? 'edit_note' : 'note'} className="inp" defaultValue={r.status === 'PROPOSED' ? '' : r.note ?? ''} /></label>
            <div className="flex flex-wrap items-center gap-2"><SubmitButton className="btn btn-pri" pendingText="MES đang tính…">Lưu và tính lại</SubmitButton>
              <span className="text-[12.5px] text-muted">Mỗi người làm ca 2 trọn tuần · ca 2 ít nhất 2 người, 1 người phụ trách · ca 2 phải có người đo mẫu QC.</span></div>
          </form>
        </details>
      )}

      <section className="card overflow-x-auto">
        <div className="card-h"><h2>Các bảng ca</h2><span className="text-[12.5px] text-muted">12 tuần gần nhất</span></div>
        {!rosters.length ? <Empty>Chưa có bảng ca nào.</Empty> : (
          <table className="tbl">
            <thead><tr><th>Tuần</th><th>Số</th><th>Nội dung</th><th>Trạng thái</th></tr></thead>
            <tbody>{rosters.map((x) => (
              <tr key={x.id}><td className="whitespace-nowrap"><Link className="link" href={`/nhan-su-xuong?tab=ca&w=${x.week_start}`}>{dd(x.week_start)}–{dd(x.week_end)}</Link></td><td>{x.roster_no}</td>
                <td className="text-[12.5px]">{[...new Set(x.machines.map((m) => m.machine))].join(', ') || 'Mọi máy ca 1'}{x.people.some((p) => p.shift > 1) ? ` · ca 2: ${x.people.filter((p) => p.shift === 2).map((p) => p.code + (p.lead ? ' (phụ trách)' : '')).join(', ')}` : ''}</td>
                <td><Pill tone={ST[x.status]?.[1] ?? 'mute'}>{ST[x.status]?.[0] ?? x.status}</Pill>{x.status === 'APPROVED' && x.sent_late ? <span className="text-[12px] text-warn"> · gửi sau hạn</span> : null}</td></tr>
            ))}</tbody>
          </table>
        )}
      </section>

      {opShifts.length > 0 && (
        <section className="card overflow-x-auto">
          <div className="card-h"><h2>Ca của người</h2><span className="text-[12.5px] text-muted">ngoài các khoảng này người đó làm ca 1</span></div>
          <table className="tbl">
            <thead><tr><th>Người</th><th>Ca</th><th>Ngày</th></tr></thead>
            <tbody>{opShifts.map((x) => (
              <tr key={x.operator_code + x.date_from} className={x.date_to < today ? 'opacity-60' : ''}><td><b>{x.operator_code}</b>{name(x.operator_code) ? ` · ${name(x.operator_code)}` : ''}</td>
                <td>{shiftInfo(kh, x.shift_no).label}</td><td className="whitespace-nowrap">{dd(x.date_from)}–{dd(x.date_to)}</td></tr>
            ))}</tbody>
          </table>
        </section>
      )}
    </div>
  );
}

// Sổ giờ đứng máy: theo lịch máy đang dùng (khởi động, thay bobin, đứng máy trộn / đóng gói), giờ thật
export function HoursTab({ kh, hours, ops, opShifts }: { kh: Kh; hours: HoursRow[]; ops: OpLite[]; opShifts: OpShiftRow[] }) {
  const today = kh.now.date, P = peopleOf(kh.cfg);
  const mon = mondayOf(today), from4 = addDays(today, -27);
  const sum = (c: string, a: string, b: string, k: 'attend_min' | 'night_min' = 'attend_min') =>
    hours.filter((h) => h.operator_code === c && h.work_date >= a && h.work_date <= b).reduce((x, h) => x + Number(h[k]), 0) / 60;
  const ca2w = (c: string) => {
    const s = new Set<string>();
    for (const x of opShifts) if (x.operator_code === c && x.shift_no >= 2)
      for (let d = x.date_from < addDays(today, -84) ? addDays(today, -84) : x.date_from; d <= x.date_to && d <= today; d = addDays(d, 1)) s.add(mondayOf(d));
    return s.size;
  };
  const rows = ops.map((o) => ({ o, d: sum(o.code, today, today), w: sum(o.code, mon, addDays(mon, 6)), nw: sum(o.code, addDays(mon, 7), addDays(mon, 13)),
    f4: sum(o.code, from4, today), n4: sum(o.code, from4, today, 'night_min'), c2: ca2w(o.code) }));
  const avg = rows.length ? rows.reduce((a, x) => a + x.f4, 0) / rows.length : 0;
  const grid: string[] = [];
  for (let d = addDays(today, -20); d <= addDays(today, 7); d = addDays(d, 1)) if (kh.cal.wd.includes(((new Date(d + 'T00:00:00Z').getUTCDay() + 6) % 7) + 1)) grid.push(d);
  const cell = (c: string, d: string) => { const v = sum(c, d, d); return v > 0.05 ? h1(v) : ''; };
  return (
    <div className="flex flex-col gap-4">
      <Alert tone="info" title={`Luân phiên đứng máy: lệch quá ${nf(P.balance_pct)} % so với bình quân 4 tuần thì MES cảnh báo TP SX`}>
        Giờ đứng máy = giờ người có mặt tại máy theo lịch máy đang dùng (khởi động, thay bobin, đứng máy trộn, đóng gói); MES xếp người ít giờ cộng dồn 4 tuần trước, máy trộn / đóng gói đổi người đầu ngày khi lệch quá ngưỡng. Ngày đã qua giữ như lịch lúc đó. Giám đốc sửa ngưỡng ở <Link className="link" href="/tham-so">Tham số xếp lịch</Link>.
      </Alert>
      <section className="card overflow-x-auto">
        <div className="card-h"><h2>Sổ giờ đứng máy</h2><span className="text-[12.5px] text-muted">giờ, theo lịch máy · bình quân 4 tuần qua {h1(avg)} giờ/người</span></div>
        <table className="tbl">
          <thead><tr><th>Người</th><th className="text-right">Hôm nay</th><th className="text-right">Tuần này</th><th className="text-right">Tuần sau (kế hoạch)</th>
            <th className="text-right">4 tuần qua</th><th className="text-right">So với bình quân</th><th className="text-right">Giờ đêm 4 tuần</th><th className="text-right">Tuần làm ca 2 (12 tuần)</th></tr></thead>
          <tbody>{rows.map((x) => {
            const dev = avg > 0.5 ? (x.f4 - avg) / avg * 100 : 0;
            return (
              <tr key={x.o.code}><td className="whitespace-nowrap"><b>{x.o.code}</b>{x.o.full_name ? ` · ${x.o.full_name}` : ''}</td>
                <td className="text-right">{h1(x.d)}</td><td className="text-right">{h1(x.w)}</td><td className="text-right">{h1(x.nw)}</td><td className="text-right font-semibold">{h1(x.f4)}</td>
                <td className={`text-right ${Math.abs(dev) > P.balance_pct ? 'font-semibold text-bad' : 'text-muted'}`}>{avg > 0.5 ? `${dev >= 0 ? '+' : '−'}${nf(Math.abs(Math.round(dev)))} %` : '—'}</td>
                <td className="text-right">{x.n4 > 0.05 ? h1(x.n4) : '—'}</td><td className="text-right">{x.c2}</td></tr>
            );
          })}</tbody>
        </table>
      </section>
      <section className="card overflow-x-auto">
        <div className="card-h"><h2>Từng ngày</h2><span className="text-[12.5px] text-muted">3 tuần qua và tuần tới (giờ đứng máy)</span></div>
        <table className="tbl text-[12px]">
          <thead><tr><th>Người</th>{grid.map((d) => <th key={d} className={`px-1 text-center ${d === today ? 'text-brand' : ''}`}>{Number(d.slice(8))}<div className="font-normal text-muted">{wd(d)}</div></th>)}</tr></thead>
          <tbody>{ops.map((o) => (
            <tr key={o.code}><td className="whitespace-nowrap"><b>{o.code}</b></td>{grid.map((d) => <td key={d} className={`px-1 text-center ${d > today ? 'text-muted' : ''}`}>{cell(o.code, d)}</td>)}</tr>
          ))}</tbody>
        </table>
      </section>
    </div>
  );
}
