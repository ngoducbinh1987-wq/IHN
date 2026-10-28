// Thẻ "Tối ưu & thêm ca" của Lịch máy: máy cổ chai, nếu thêm ca / thêm người thì sao, thứ tự lô MES chọn,
// đề xuất máy chạy 2 ca, 3 ca để kịp ngày chốt (anh Bình duyệt 28/10/2026): TP SX / Kế hoạch SX đề xuất → Giám đốc duyệt.
// Mọi con số tính từ thông số (Tham số xếp lịch, Hồ sơ máy → Tốc độ, Nhân sự xưởng); không có số cố định.
import Link from 'next/link';
import { Alert, FinishPill, dd } from '@/components/kh';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Pill } from '@/components/ui';
import { df, nf } from '@/lib/format';
import { type Kh, QC_LEARN_MIN_SAMPLES, analyze } from '@/lib/kh/load';
import { SHIFT_GROUPS, groupName } from '@/lib/kh/optimize';
import { finishInfo, flowOf, mixerKgh, peopleOf, shiftRun } from '@/lib/kh/scheduler';
import { endOvertime, endShifts, proposeShifts, reviewShifts } from './actions';

export type OtRow = {
  id: string; req_no: string; plan_no: string | null; extra_min: Record<string, number>; mix_early_h: number; date_from: string; date_to: string;
  summary: { lines?: string[]; gain?: string } | null; reason: string; status: string; proposed_by: string | null; proposed_by_name: string | null; proposed_at: string;
  reviewed_by_name: string | null; reviewed_at: string | null; review_note: string | null;
};
export type ShiftReqRow = {
  id: string; req_no: string; plan_no: string | null; items: { machines: string[]; shifts: number; from: string; to: string; group?: string }[];
  summary: { gain?: string; persons?: string; short?: string[] } | null; reason: string; status: string; proposed_by: string | null; proposed_by_name: string | null;
  proposed_at: string; reviewed_by_name: string | null; reviewed_at: string | null; review_note: string | null;
};
const ST: Record<string, [string, 'warn' | 'ok' | 'bad' | 'mute']> = {
  PROPOSED: ['Chờ Giám đốc duyệt', 'warn'], APPROVED: ['Đang áp dụng', 'ok'], RETURNED: ['Bị trả lại', 'bad'], CANCELLED: ['Đã hủy', 'mute'], ENDED: ['Đã kết thúc', 'mute'],
};
const h1 = (v: number) => { const x = Math.round(v * 10) / 10; return nf(x, Number.isInteger(x) ? 0 : 1); };
const hm = (t: string) => t.slice(0, 5);

export function OptimizeTab({ kh, sp, roles, userId, ots, reqs }: { kh: Kh; sp: Record<string, string | undefined>; roles: string[]; userId: string; ots: OtRow[]; reqs: ShiftReqRow[] }) {
  if (!kh.orders.length) return <div className="card"><Empty>Kế hoạch chưa có dòng nào xếp được.</Empty></div>;
  const mode = sp.mode === 'fastest' ? 'fastest' : 'due';
  const t0 = Date.now();
  const r = analyze(kh, mode);
  const ms = Date.now() - t0;
  const best = r.best!;
  const F = flowOf(kh.cfg);
  const P = peopleOf(kh.cfg);
  const meta = kh.flowMeta;
  const canPropose = ['SX_TP', 'SX_KH', 'BGD', 'ADMIN'].some((x) => roles.includes(x));
  const isGd = roles.includes('BGD') || roles.includes('ADMIN');
  const base = best.ordered.score, fin = r.fin;
  const finS = best.staffed ? finishInfo(best.staffed.sch, best.staffed.cal, best.staffed.ords) : null;
  const finR = best.realPlan ? finishInfo(best.realPlan.sch, best.realPlan.cal, best.realPlan.ords) : null;
  const late = r.orders.filter((o) => (fin.get(o.id)?.slack ?? 0) < 0);
  const lateS = finS ? r.orders.filter((o) => (finS.get(o.id)?.slack ?? 0) < 0) : late;
  const mixers = kh.machines.filter((m) => m.machine_type === 'MIXER');
  const today = kh.now.date;
  const seqTxt = [...r.orders].sort((a, b) => (a.seq ?? 0) - (b.seq ?? 0)).map((o) => o.label).join(' → ');
  const plan = best.shiftPlan;
  const gainTxt = best.staffed ? `${h1(base.makespan)} → ${h1(best.staffed.score.makespan)} ngày làm việc (đủ người), trễ hạn ${base.late} → ${best.staffed.score.late} ngày` : '';
  const shB = kh.cfg.shifts.find((s) => s.code === 'B'), shC = kh.cfg.shifts.find((s) => s.code === 'C'), shA = kh.cfg.shifts.find((s) => s.code === 'A');
  const overlapB = Boolean(shA && shB && hm(shB.start_time) < hm(shA.end_time) && hm(shB.start_time) > hm(shA.start_time));
  const shortW = (best.realPlan?.sch.warnings ?? []).filter((w) => w.startsWith('Thiếu người ca') || w.includes('làm ca dài'));
  const ext = best.realPlan?.sch.roster?.ext ?? [];
  const extBy = new Map<string, number>();
  for (const e of ext) extBy.set(e.code, (extBy.get(e.code) ?? 0) + e.hours);
  // Nhóm máy cho form: mọi nhóm có máy, điền sẵn theo MES
  const groups = Object.keys(SHIFT_GROUPS).map((g) => ({ g, machines: kh.machines.filter((m) => SHIFT_GROUPS[g].includes(m.machine_type) && m.status !== 'OFF').map((m) => m.code) }))
    .filter((x) => x.machines.length);
  const lastFin = [...fin.values()].map((f) => f.finDate).filter(Boolean).sort().at(-1) ?? today;
  const pre = (g: string) => plan.find((p) => p.group === g);
  const approved = (kh.cfg.machine_shifts ?? []).filter((x) => x.to >= today);
  const summary = JSON.stringify({ gain: gainTxt, persons: plan.map((p) => `${groupName(p.group)}: ${p.persons} người mỗi ca thêm`).join('; '), short: shortW.slice(0, 6) });
  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center gap-2 text-[13px]">
        <span className="text-muted">Mục tiêu:</span>
        <Link className={`btn btn-sm ${mode === 'due' ? 'btn-pri' : ''}`} href={`?plan=${kh.planId}&tab=toiuu`}>Kịp ngày chốt / hạn giao</Link>
        <Link className={`btn btn-sm ${mode === 'fastest' ? 'btn-pri' : ''}`} href={`?plan=${kh.planId}&tab=toiuu&mode=fastest`}>Xong sớm nhất có thể</Link>
        <span className="text-muted">MES chạy thử {nf(best.evals)} phương án trong {ms < 100 ? 'dưới 0,1' : nf(ms / 1000, 1)} giây</span>
      </div>
      {(r.sch.warnings ?? []).length > 0 && (
        <Alert tone="warn" title="Cần xem">
          {(r.sch.warnings ?? []).map((w) => <div key={w}>{w}</div>)}
          <div className="mt-1 text-[12.5px]">Thông số ở <Link className="link" href="/tham-so">Tham số xếp lịch</Link>, Hồ sơ máy → Tốc độ; người, ca của người ở <Link className="link" href="/nhan-su-xuong">Nhân sự xưởng</Link>.</div>
        </Alert>
      )}
      <div className="grid gap-4 xl:grid-cols-2 [&>*]:min-w-0">
        <section className="card">
          <div className="card-h"><h2>Máy cổ chai</h2><span className="text-[12.5px] text-muted">nhóm máy bận nhất trên thời gian kế hoạch</span></div>
          <div className="overflow-x-auto"><table className="tbl">
            <thead><tr><th>Nhóm máy</th><th>Máy</th><th className="text-right">Bận (ngày máy)</th><th className="text-right">Tải</th><th>Ghi chú</th></tr></thead>
            <tbody>{best.bottleneck.map((b, i) => (
              <tr key={b.group}><td><b>{groupName(b.group)}</b>{i === 0 && <> <Pill tone="bad">cổ chai</Pill></>}</td><td className="text-[12.5px]">{b.machines.join(', ')}</td>
                <td className="text-right">{h1(b.busyDays)}</td><td className="whitespace-nowrap text-right">{nf(b.util * 100)} %</td>
                <td className="text-[12.5px]">{b.waitSilicone_h > 0.5 ? `Line silicone chờ silicone ${nf(b.waitSilicone_h)} giờ` : ''}</td></tr>
            ))}</tbody>
          </table></div>
        </section>
        <section className="card">
          <div className="card-h"><h2>Nếu thêm ca, thêm người thì sao</h2><span className="text-[12.5px] text-muted">mỗi dòng thêm riêng một nhóm</span></div>
          <div className="overflow-x-auto"><table className="tbl">
            <thead><tr><th>Thêm</th><th className="text-right">Xong sau (ngày làm việc)</th><th className="text-right">Nhanh hơn</th></tr></thead>
            <tbody>{best.whatIf.map((w) => (
              <tr key={w.label}><td>{w.label}</td><td className="text-right">{h1(w.days)}</td>
                <td className={`text-right ${w.gain > 0.05 ? 'font-semibold text-ok' : 'text-muted'}`}>{w.gain > 0.05 ? `${h1(w.gain)} ngày` : 'không đáng kể'}</td></tr>
            ))}</tbody>
          </table></div>
          <p className="px-4 pb-3 text-[12.5px] text-muted">&quot;Chạy 2 ca&quot;: tính như đủ người ca 2 (TP SX phân người sau). Máy trộn luôn chạy cùng ca line silicone vì silicone đã pha chỉ dùng trong {h1(F.pot_life_h)} giờ; máy trộn cần 1 người đứng riêng.
            &quot;Thêm 1 người kiêm nhiệm&quot;: một người nữa ca 1 được đứng các máy của nhóm – nhanh hơn nhiều thì TP SX phân công kiêm nhiệm tạm ở <a className="link" href="/nhan-su-xuong">Nhân sự xưởng</a>.</p>
        </section>
      </div>
      <section className="card">
        <div className="card-h"><h2>Thứ tự lô và ngày xong</h2><span className="text-[12.5px] text-muted">MES chọn: {seqTxt}</span></div>
        <div className="overflow-x-auto"><table className="tbl">
          <thead><tr><th>Lô</th><th>Mã</th><th className="text-right">Số mét</th><th>Ngày chốt / hạn</th><th>Xong (ca máy đang duyệt)</th>
            {finS && <th>Xong nếu thêm ca, đủ người</th>}{finR && <th>Xong nếu thêm ca, người hiện có</th>}</tr></thead>
          <tbody>{[...r.orders].sort((a, b) => (a.seq ?? 0) - (b.seq ?? 0)).map((o) => {
            const f = fin.get(o.id), fs = finS?.get(o.id), fr = finR?.get(o.id);
            return <tr key={o.id}><td><b>{o.label}</b></td><td>{o.product_code}</td><td className="text-right">{nf(o.qty)}</td><td>{dd(o.commit ?? o.due)}</td>
              <td>{f ? <FinishPill {...f} due={o.commit ?? o.due} /> : '—'}</td>
              {finS && <td>{fs ? <FinishPill {...fs} due={o.commit ?? o.due} /> : '—'}</td>}{finR && <td>{fr ? <FinishPill {...fr} due={o.commit ?? o.due} /> : '—'}</td>}</tr>;
          })}</tbody>
        </table></div>
        <p className="px-4 pb-3 text-[12.5px] text-muted">Thứ tự lô thường: {h1(best.base.score.makespan)} ngày · MES đổi thứ tự: {h1(base.makespan)} ngày{best.staffed ? ` · thêm ca đề xuất (đủ người): ${h1(best.staffed.score.makespan)} ngày · với người hiện có: ${h1(best.realPlan!.score.makespan)} ngày` : ''}. Bấm <b>Xếp lại lịch</b> để lưu thứ tự này (TP SX xếp thì Giám đốc duyệt); ca máy chỉ vào lịch sau khi Giám đốc duyệt đề xuất thêm ca.</p>
      </section>

      <section className="card" id="them-ca">
        <div className="card-h"><h2>Máy chạy 2 ca, 3 ca</h2>
          <span className="text-[12.5px] text-muted">ca 2 = giờ ca B {shB ? `${hm(shB.start_time)}–${hm(shB.end_time)}` : ''} · ca 3 = giờ ca C {shC ? `${hm(shC.start_time)}–${hm(shC.end_time)}` : ''} · mỗi người tối đa {h1(P.day_max_h)} giờ/ngày</span></div>
        <div className="flex flex-col gap-1 px-4 py-3 text-[14px]">
          {approved.length
            ? <div>Đang duyệt: {approved.map((x) => `${x.machine} ${x.shifts} ca ${dd(x.from)}–${dd(x.to)}`).join('; ')}.</div>
            : <div>Chưa có máy nào chạy thêm ca: mọi máy chạy 1 ca (ca A {shA ? `${hm(shA.start_time)}–${hm(shA.end_time)}` : ''}).</div>}
          {overlapB && <div className="text-[13px] text-warn">Ca B ({hm(shB!.start_time)}–{hm(shB!.end_time)}) trùng giờ ca A đến {hm(shA!.end_time)}: phần trùng không tính thêm, máy chạy ca 2 từ {hm(shA!.end_time)}. Giám đốc đặt lại giờ ca B, ca C ở <Link className="link" href="/tham-so">Tham số xếp lịch</Link> (ví dụ ca 2 {hm(shA!.end_time)}–01:00) để ca 2 đủ giờ.</div>}
          {mode === 'due' && !late.length && !plan.length && <div className="text-ok">Mọi lô kịp ngày chốt / hạn giao với ca hiện tại: không cần thêm ca. Muốn xong sớm hơn thì chọn mục tiêu “Xong sớm nhất có thể”.</div>}
          {plan.length > 0 && <div>MES đề xuất (tính như đủ người): {gainTxt}.</div>}
          {lateS.length > 0 && <div className="text-bad">Vẫn trễ {plan.length ? 'sau khi thêm ca' : ''}: {lateS.map((o) => `${o.label} xong ${dd((finS ?? fin).get(o.id)?.finDate)}, chốt ${dd(o.commit ?? o.due)}`).join('; ')}. Cần dời ngày chốt, thêm máy hoặc thêm người.</div>}
        </div>
        {plan.length > 0 && (
          <div className="overflow-x-auto"><table className="tbl">
            <thead><tr><th>MES đề xuất</th><th>Máy</th><th className="text-right">Số ca</th><th>Từ – đến</th><th className="text-right">Người mỗi ca thêm</th><th className="text-right">Ngày công thêm</th></tr></thead>
            <tbody>{plan.map((p) => (
              <tr key={p.group}><td><b>{groupName(p.group)}</b></td><td className="text-[12.5px]">{p.machines.join(', ')}</td><td className="text-right">{p.shifts}</td>
                <td className="whitespace-nowrap">{dd(p.from)}–{dd(p.to)}</td><td className="text-right">{p.persons}</td><td className="text-right">{nf(p.personDays)}</td></tr>
            ))}</tbody>
          </table></div>
        )}
        {plan.length > 0 && (
          <div className="border-t border-line px-4 py-3 text-[13px]">
            <div className="font-semibold">Với người hiện có</div>
            {!shortW.length && !ext.length ? <div className="text-ok">Đủ người cho các ca thêm.</div> : (
              <ul className="ml-4 list-disc">
                {shortW.map((w) => <li key={w}>{w}</li>)}
                {[...extBy].map(([p, h]) => <li key={p}>{p} làm ca dài (tối đa {h1(P.day_max_h)} giờ/ngày) tổng {h1(h)} giờ làm thêm – chỉ khi thiếu người, tối đa {h1(P.ot_month_h)} giờ/tháng</li>)}
              </ul>
            )}
            <div className="mt-1 text-muted">Sau khi Giám đốc duyệt: TP SX đặt người làm ca 2, ca 3 (và thêm công nhân, tay nghề) ở <Link className="link" href="/nhan-su-xuong">Nhân sự xưởng</Link>, rồi bấm Xếp lại lịch.</div>
          </div>
        )}
        {canPropose && (
          <form action={proposeShifts} className="flex flex-col gap-3 border-t border-line px-4 py-3">
            <input type="hidden" name="plan_id" value={kh.planId ?? ''} />
            <input type="hidden" name="summary" value={summary} />
            <div className="text-[13px] text-muted">{plan.length ? 'Đã điền sẵn theo MES. ' : 'MES chưa thấy cần thêm ca; TP SX vẫn lập được đề xuất. '}Chọn số ca từng nhóm máy (1 ca = không thêm) và khoảng ngày (tối đa 2 tháng). Máy trộn đi cùng line silicone. Giờ 22:00–06:00 tính làm đêm.</div>
            <div className="overflow-x-auto"><table className="tbl">
              <thead><tr><th>Nhóm máy</th><th>Máy</th><th>Số ca</th><th>Từ ngày</th><th>Đến ngày</th></tr></thead>
              <tbody>{groups.map(({ g, machines }) => {
                const p = pre(g);
                return (
                  <tr key={g}><td><b>{groupName(g)}</b></td><td className="text-[12.5px]">{machines.join(', ')}<input type="hidden" name={`m_${g}`} value={machines.join(',')} /></td>
                    <td><select className="inp w-[90px] py-1" name={`n_${g}`} defaultValue={String(p?.shifts ?? 1)} aria-label={`Số ca ${groupName(g)}`}>
                      <option value="1">1 ca</option><option value="2">2 ca</option><option value="3">3 ca</option></select></td>
                    <td><input type="date" className="inp w-[150px] py-1" name={`f_${g}`} defaultValue={p?.from ?? today} aria-label={`Từ ngày ${groupName(g)}`} /></td>
                    <td><input type="date" className="inp w-[150px] py-1" name={`t_${g}`} defaultValue={p?.to ?? (lastFin < today ? today : lastFin)} aria-label={`Đến ngày ${groupName(g)}`} /></td></tr>
                );
              })}</tbody>
            </table></div>
            <div className="flex flex-wrap items-end gap-2">
              <label className="min-w-[280px] flex-1 text-[13px]">Lý do
                <input className="inp mt-1 py-1" name="reason" required defaultValue={plan.length ? (late.length ? `Kịp ngày chốt: ${gainTxt}` : `Rút ngắn kế hoạch: ${gainTxt}`) : ''} /></label>
              <SubmitButton className="btn btn-pri" pendingText="Đang gửi…">{isGd ? 'Áp dụng thêm ca' : 'Đề xuất Giám đốc duyệt'}</SubmitButton>
            </div>
          </form>
        )}
      </section>

      <section className="card">
        <div className="card-h"><h2>Đề xuất thêm ca</h2><span className="text-[12.5px] text-muted">TP SX / Kế hoạch SX đề xuất → Giám đốc duyệt</span></div>
        {!reqs.length ? <Empty>Chưa có đề xuất thêm ca nào.</Empty> : (
          <div className="overflow-x-auto"><table className="tbl">
            <thead><tr><th>Số</th><th>Nội dung</th><th>Người đề xuất</th><th>Trạng thái</th><th></th></tr></thead>
            <tbody>{reqs.map((o) => {
              const to = o.items.map((x) => x.to).sort().at(-1) ?? '', from = o.items.map((x) => x.from).sort()[0] ?? '';
              return (
                <tr key={o.id}>
                  <td><b>{o.req_no}</b><div className="text-[12px] text-muted">{df(o.proposed_at, true)}</div></td>
                  <td className="text-[12.5px]">{o.items.map((x, i) => <div key={i}>{x.group ? `${groupName(x.group)}: ` : ''}{x.machines.join(', ')} {x.shifts} ca {dd(x.from)}–{dd(x.to)}</div>)}
                    <div className="text-muted">{o.reason}</div>{o.summary?.persons && <div className="text-muted">{o.summary.persons}</div>}
                    {o.review_note && <div className="text-muted">Ý kiến: {o.review_note}</div>}</td>
                  <td className="text-[12.5px]">{o.proposed_by_name}{o.reviewed_by_name ? <div className="text-muted">Duyệt/xử lý: {o.reviewed_by_name}</div> : null}</td>
                  <td>{o.status === 'APPROVED' && to < today ? <Pill tone="mute">Hết hạn</Pill>
                    : o.status === 'APPROVED' && from > today ? <Pill tone="ok">Đã duyệt, từ {dd(from)}</Pill>
                    : <Pill tone={ST[o.status]?.[1] ?? 'mute'}>{ST[o.status]?.[0] ?? o.status}</Pill>}</td>
                  <td className="min-w-[260px]">
                    {o.status === 'PROPOSED' && isGd && o.proposed_by !== userId && (
                      <form action={reviewShifts} className="flex flex-wrap gap-1">
                        <input type="hidden" name="plan_id" value={kh.planId ?? ''} /><input type="hidden" name="id" value={o.id} />
                        <input className="inp min-w-[140px] flex-1 py-1" name="note" placeholder="Ý kiến (bắt buộc khi trả lại)" aria-label={`Ý kiến ${o.req_no}`} />
                        <SubmitButton className="btn btn-sm btn-pri" formAction={async (f: FormData) => { 'use server'; f.set('approve', '1'); await reviewShifts(f); }}>Duyệt</SubmitButton>
                        <SubmitButton className="btn btn-sm btn-bad-o" formAction={async (f: FormData) => { 'use server'; f.set('approve', '0'); await reviewShifts(f); }}>Trả lại</SubmitButton>
                      </form>
                    )}
                    {((o.status === 'APPROVED' && to >= today) || o.status === 'PROPOSED') && (isGd || roles.includes('SX_TP')) && (
                      <form action={endShifts} className="mt-1 flex flex-wrap gap-1">
                        <input type="hidden" name="plan_id" value={kh.planId ?? ''} /><input type="hidden" name="id" value={o.id} />
                        <input className="inp min-w-[140px] flex-1 py-1" name="note" placeholder="Lý do" required aria-label={`Lý do kết thúc ${o.req_no}`} />
                        <SubmitButton className="btn btn-sm">{o.status === 'APPROVED' ? 'Kết thúc sớm' : 'Hủy đề xuất'}</SubmitButton>
                      </form>
                    )}
                  </td>
                </tr>
              );
            })}</tbody>
          </table></div>
        )}
      </section>

      {ots.some((o) => o.status === 'APPROVED' && o.date_to >= today) && (
        <section className="card">
          <div className="card-h"><h2>Tăng ca theo giờ (cách cũ) đang áp dụng</h2></div>
          <div className="overflow-x-auto"><table className="tbl"><tbody>{ots.filter((o) => o.status === 'APPROVED' && o.date_to >= today).map((o) => (
            <tr key={o.id}><td><b>{o.req_no}</b></td><td className="text-[12.5px]">{Object.entries(o.extra_min ?? {}).map(([k, v]) => `${k} +${v}′/ngày`).join(', ')}{Number(o.mix_early_h) > 0 ? `; trộn sớm ${h1(Number(o.mix_early_h))} giờ` : ''} · {dd(o.date_from)}–{dd(o.date_to)}</td>
              <td>{(isGd || roles.includes('SX_TP')) && (
                <form action={endOvertime} className="flex flex-wrap gap-1">
                  <input type="hidden" name="plan_id" value={kh.planId ?? ''} /><input type="hidden" name="id" value={o.id} />
                  <input className="inp min-w-[140px] flex-1 py-1" name="note" placeholder="Lý do" required aria-label={`Lý do kết thúc ${o.req_no}`} />
                  <SubmitButton className="btn btn-sm">Kết thúc</SubmitButton>
                </form>
              )}</td></tr>
          ))}</tbody></table></div>
          <p className="px-4 pb-3 text-[12.5px] text-muted">Từ 28/10/2026 máy chậm thì chạy thêm ca (bảng trên) thay cho tăng ca theo giờ.</p>
        </section>
      )}

      <section className="card">
        <div className="card-h"><h2>Thông số đang dùng</h2><Link className="link text-[13px]" href="/tham-so">Sửa ở Tham số xếp lịch</Link></div>
        <div className="overflow-x-auto"><table className="tbl"><tbody>
          <tr><td className="w-[240px]">Ca</td><td>{kh.cfg.shifts.map((s) => `${s.code === 'A' ? 'Ca 1' : s.code === 'B' ? 'Ca 2' : 'Ca 3'} (${s.code}) ${hm(s.start_time)}–${hm(s.end_time)}, chạy ${nf(shiftRun(s))} phút`).join(' · ')}</td></tr>
          <tr><td>Giờ làm mỗi người</td><td>tối đa {h1(P.day_max_h)} giờ/ngày (cả làm thêm) · làm thêm tối đa {nf(P.ot_day_min)} phút/ngày, {h1(P.ot_month_h)} giờ/tháng · đổi ca phải nghỉ ít nhất 12 giờ</td></tr>
          <tr><td>Thời gian QC một bobin</td><td>{nf(F.qc_min)} phút {meta.qc_learn && meta.qc_learned.n >= QC_LEARN_MIN_SAMPLES ? `(MES tự học: trung vị ${meta.qc_learned.n} bobin 30 ngày)` : `(TP KT/QA nhập${meta.qc_learn ? `; MES tự học khi đủ ${QC_LEARN_MIN_SAMPLES} bobin có kết quả QC, hiện ${meta.qc_learned.n}` : ''})`}</td></tr>
          <tr><td>Mét một bobin</td><td>{Object.entries(F.unit_m).filter(([k]) => k !== 'CD0').map(([k, v]) => `${k} ${nf(v)} m`).join(' · ')}</td></tr>
          <tr><td>Đệm an toàn</td><td>{Object.entries(F.safety_min).filter(([, v]) => Number(v) > 0).map(([k, v]) => `${k} ${nf(Number(v))} phút`).join(' · ') || 'không'}</td></tr>
          <tr><td>Máy trộn</td><td>{mixers.map((m) => `${m.code} ${h1(mixerKgh(kh.cfg, m.code))} kg/giờ`).join(' · ') || 'không có'} · hạn dùng silicone {h1(F.pot_life_h)} giờ · mẻ {nf(F.mix_batch_kg)} kg · 1 người đứng riêng</td></tr>
          <tr><td>Gom lô</td><td>{kh.cfg.group_days ?? 0} ngày · việc bắt đầu cách nhau ≤ {F.pick_window_min == null ? 'nửa ca' : `${F.pick_window_min} phút`} coi như cùng lúc</td></tr>
          <tr><td>Tốc độ mặc định</td><td>cỡ từ {nf(F.size_large_mm2, 2)} mm² dùng tốc độ cỡ lớn · tin tốc độ PLC khi đủ {nf(F.plc_min_run)} phút chạy</td></tr>
        </tbody></table></div>
      </section>
    </div>
  );
}
