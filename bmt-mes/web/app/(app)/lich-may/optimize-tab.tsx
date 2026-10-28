// Thẻ "Tối ưu & tăng ca" của Lịch máy: máy cổ chai, nếu thêm giờ thì sao, thứ tự lô MES chọn, đề xuất tăng ca / trộn sớm để kịp ngày chốt.
// Mọi con số tính từ thông số (Tham số xếp lịch, Hồ sơ máy → Tốc độ); không có số cố định.
import Link from 'next/link';
import { Alert, FinishPill, dd } from '@/components/kh';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Pill } from '@/components/ui';
import { df, nf } from '@/lib/format';
import { type Kh, QC_LEARN_MIN_SAMPLES, analyze } from '@/lib/kh/load';
import { groupName } from '@/lib/kh/optimize';
import { flowOf, mixerKgh } from '@/lib/kh/scheduler';
import { endOvertime, proposeOvertime, reviewOvertime } from './actions';

export type OtRow = {
  id: string; req_no: string; plan_no: string | null; extra_min: Record<string, number>; mix_early_h: number; date_from: string; date_to: string;
  summary: { lines?: string[]; gain?: string } | null; reason: string; status: string; proposed_by: string | null; proposed_by_name: string | null; proposed_at: string;
  reviewed_by_name: string | null; reviewed_at: string | null; review_note: string | null;
};
const OT_STATUS: Record<string, [string, 'warn' | 'ok' | 'bad' | 'mute']> = {
  PROPOSED: ['Chờ Giám đốc duyệt', 'warn'], APPROVED: ['Đang áp dụng', 'ok'], RETURNED: ['Bị trả lại', 'bad'], CANCELLED: ['Đã hủy', 'mute'], ENDED: ['Đã kết thúc', 'mute'],
};
const h1 = (v: number) => { const x = Math.round(v * 10) / 10; return nf(x, Number.isInteger(x) ? 0 : 1); };

export function OptimizeTab({ kh, sp, roles, userId, ots }: { kh: Kh; sp: Record<string, string | undefined>; roles: string[]; userId: string; ots: OtRow[] }) {
  if (!kh.orders.length) return <div className="card"><Empty>Kế hoạch chưa có dòng nào xếp được.</Empty></div>;
  const mode = sp.mode === 'fastest' ? 'fastest' : 'due';
  const t0 = Date.now();
  const r = analyze(kh, mode);
  const ms = Date.now() - t0;
  const best = r.best!;
  const F = flowOf(kh.cfg);
  const meta = kh.flowMeta;
  const canPropose = ['SX_TP', 'SX_KH', 'BGD', 'ADMIN'].some((x) => roles.includes(x));
  const isGd = roles.includes('BGD') || roles.includes('ADMIN');
  const base = best.ordered.score, fin = r.fin;
  const late = r.orders.filter((o) => (fin.get(o.id)?.slack ?? 0) < 0);
  const mixers = kh.machines.filter((m) => m.machine_type === 'MIXER');
  const machinesOf = (g: string) => kh.machines.filter((m) => m.machine_type === g).map((m) => m.code);
  const today = kh.now.date;
  const lastFin = [...fin.values()].map((f) => f.finDate).filter(Boolean).sort().at(-1) ?? today;
  const seqTxt = [...r.orders].sort((a, b) => (a.seq ?? 0) - (b.seq ?? 0)).map((o) => o.label).join(' → ');
  const proposalLines = best.proposals.map((p) => `${groupName(p.group)} +${p.extra_min} phút/ngày (${p.machines.join(', ')})`);
  const gainTxt = `${h1(base.makespan)} → ${h1(best.score.makespan)} ngày làm việc, trễ hạn ${base.late} → ${best.score.late} ngày`;
  const qty = (code: string) => {
    for (const p of best.proposals) if (p.machines.includes(code)) return p.extra_min;
    return Number(meta.ot.extra_min?.[code] ?? 0) || 0;
  };
  const showForm = canPropose && (best.proposals.length > 0 || best.early_h > Number(meta.ot.mix_early_h));
  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center gap-2 text-[13px]">
        <span className="text-muted">Mục tiêu:</span>
        <Link className={`btn btn-sm ${mode === 'due' ? 'btn-pri' : ''}`} href={`?plan=${kh.planId}&tab=toiuu`}>Kịp ngày chốt / hạn giao</Link>
        <Link className={`btn btn-sm ${mode === 'fastest' ? 'btn-pri' : ''}`} href={`?plan=${kh.planId}&tab=toiuu&mode=fastest`}>Xong sớm nhất có thể</Link>
        <span className="text-muted">MES chạy thử {nf(best.evals)} phương án trong {ms < 100 ? 'dưới 0,1' : nf(ms / 1000, 1)} giây</span>
      </div>
      {(r.sch.warnings ?? []).length > 0 && (
        <Alert tone="warn" title="Thiếu thông số">
          {(r.sch.warnings ?? []).map((w) => <div key={w}>{w}</div>)}
          <div className="mt-1 text-[12.5px]">Khai báo ở <Link className="link" href="/tham-so">Tham số xếp lịch</Link> hoặc Hồ sơ máy → Tốc độ.</div>
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
          <div className="card-h"><h2>Nếu thêm giờ thì sao</h2><span className="text-[12.5px] text-muted">mỗi dòng thêm riêng một nhóm</span></div>
          <div className="overflow-x-auto"><table className="tbl">
            <thead><tr><th>Thêm</th><th className="text-right">Xong sau (ngày làm việc)</th><th className="text-right">Nhanh hơn</th></tr></thead>
            <tbody>{best.whatIf.map((w) => (
              <tr key={w.label}><td>{w.label}</td><td className="text-right">{h1(w.days)}</td>
                <td className={`text-right ${w.gain > 0.05 ? 'font-semibold text-ok' : 'text-muted'}`}>{w.gain > 0.05 ? `${h1(w.gain)} ngày` : 'không đáng kể'}</td></tr>
            ))}</tbody>
          </table></div>
          <p className="px-4 pb-3 text-[12.5px] text-muted">Silicone đã pha chỉ dùng trong {h1(F.pot_life_h)} giờ: tăng ca riêng máy trộn thường không có ích, phải tăng ca cùng line silicone. Trộn sớm trước ca là trộn sẵn trước giờ line chạy.</p>
        </section>
      </div>
      <section className="card">
        <div className="card-h"><h2>Thứ tự lô và ngày xong</h2><span className="text-[12.5px] text-muted">MES chọn: {seqTxt}</span></div>
        <div className="overflow-x-auto"><table className="tbl">
          <thead><tr><th>Lô</th><th>Mã</th><th className="text-right">Số mét</th><th>Ngày chốt / hạn</th><th>Xong (theo {mode === 'due' && best.proposals.length + best.early_h > 0 ? 'đề xuất tăng ca bên dưới' : 'lịch tối ưu'})</th></tr></thead>
          <tbody>{[...r.orders].sort((a, b) => (a.seq ?? 0) - (b.seq ?? 0)).map((o) => {
            const f = fin.get(o.id);
            return <tr key={o.id}><td><b>{o.label}</b></td><td>{o.product_code}</td><td className="text-right">{nf(o.qty)}</td><td>{dd(o.commit ?? o.due)}</td>
              <td>{f ? <FinishPill {...f} due={o.commit ?? o.due} /> : '—'}</td></tr>;
          })}</tbody>
        </table></div>
        <p className="px-4 pb-3 text-[12.5px] text-muted">Thứ tự lô thường: {h1(best.base.score.makespan)} ngày · MES đổi thứ tự: {h1(base.makespan)} ngày{best.proposals.length || best.early_h > Number(meta.ot.mix_early_h) ? ` · thêm giờ đề xuất: ${h1(best.score.makespan)} ngày` : ''}. Bấm <b>Xếp lại lịch</b> để lưu thứ tự này (TP SX xếp thì Giám đốc duyệt).</p>
      </section>

      <section className="card" id="tang-ca">
        <div className="card-h"><h2>Tăng ca / trộn sớm</h2>
          <span className="text-[12.5px] text-muted">giới hạn {meta.levers.ot_max_min} phút/ngày, {meta.levers.ot_month_h} giờ/tháng mỗi người; trộn sớm tối đa {h1(meta.levers.early_max_h)} giờ</span></div>
        <div className="px-4 py-3 text-[14px]">
          {meta.ot.active
            ? <div>Đang áp dụng {dd(meta.ot.from)}–{dd(meta.ot.until)}: {Object.entries(F.extra_min).filter(([, v]) => v > 0).map(([k, v]) => `${k} +${v} phút/ngày`).join(', ') || 'không tăng ca'}{F.mix_early_h > 0 ? `; máy trộn chạy trước ca ${h1(F.mix_early_h)} giờ` : ''}.</div>
            : <div>Chưa có tăng ca nào đang áp dụng.</div>}
          {mode === 'due' && !late.length && !best.proposals.length && best.early_h <= Number(meta.ot.mix_early_h) && (
            <div className="mt-1 text-ok">Mọi lô kịp ngày chốt / hạn giao với giờ hiện tại: không cần tăng ca. Muốn xong sớm hơn thì chọn mục tiêu “Xong sớm nhất có thể”.</div>
          )}
          {mode === 'due' && late.length > 0 && <div className="mt-1 text-bad">Vẫn trễ sau khi thêm giờ trong giới hạn: {late.map((o) => `${o.label} xong ${dd(fin.get(o.id)?.finDate)}, chốt ${dd(o.commit ?? o.due)}`).join('; ')}. Cần dời ngày chốt, thêm ca hoặc thêm máy.</div>}
        </div>
        {(best.proposals.length > 0 || best.early_h > Number(meta.ot.mix_early_h)) && (
          <div className="overflow-x-auto"><table className="tbl">
            <thead><tr><th>MES đề xuất</th><th>Máy</th><th className="text-right">Phút/ngày</th><th className="text-right">Người</th><th className="text-right">Ngày</th><th className="text-right">Giờ công</th><th></th></tr></thead>
            <tbody>
              {best.proposals.map((p) => (
                <tr key={p.group}><td><b>{groupName(p.group)}</b></td><td className="text-[12.5px]">{p.machines.join(', ')}</td><td className="text-right">{p.extra_min}</td>
                  <td className="text-right">{p.persons}</td><td className="text-right">{p.days}</td><td className="text-right">{h1(p.hours)}</td>
                  <td>{p.overMonth ? <Pill tone="bad">vượt {meta.levers.ot_month_h} giờ/tháng</Pill> : null}</td></tr>
              ))}
              {best.early_h > 0 && <tr><td><b>Máy trộn chạy trước ca</b></td><td className="text-[12.5px]">{mixers.map((m) => `${m.code} (${h1(mixerKgh(kh.cfg, m.code))} kg/giờ)`).join(', ')}</td>
                <td className="text-right">{nf(best.early_h * 60)}</td><td className="text-right">1</td><td colSpan={3} className="text-[12.5px]">người trộn ca sớm, không phải tăng ca</td></tr>}
            </tbody>
          </table></div>
        )}
        {showForm && (
          <form action={proposeOvertime} className="flex flex-col gap-3 border-t border-line px-4 py-3">
            <input type="hidden" name="plan_id" value={kh.planId ?? ''} />
            <input type="hidden" name="summary" value={JSON.stringify({ lines: proposalLines, gain: gainTxt })} />
            <div className="text-[13px] text-muted">Kiểm tra, sửa số phút nếu cần (để trống = không tăng ca máy đó). Tăng ca cần người lao động đồng ý; giờ 22:00–06:00 tính làm đêm.</div>
            <div className="grid gap-2 sm:grid-cols-3 lg:grid-cols-4">
              {best.bottleneck.flatMap((b) => machinesOf(b.group).filter((c) => b.group !== 'MIXER' || qty(c) > 0 || best.proposals.some((p) => p.group === 'MIXER')).map((code) => (
                <label key={code} className="text-[13px]">{code} <span className="text-muted">({groupName(b.group)})</span>
                  <input className="inp mt-1 py-1 text-right" name={`ot_${code}`} defaultValue={qty(code) || ''} inputMode="numeric" placeholder="phút/ngày" aria-label={`Tăng ca ${code} (phút/ngày)`} /></label>
              )))}
              {mixers.length > 0 && <label className="text-[13px]">Trộn sớm trước ca (giờ)
                <input className="inp mt-1 py-1 text-right" name="mix_early_h" defaultValue={best.early_h ? nf(best.early_h, 1) : ''} inputMode="decimal" aria-label="Trộn sớm trước ca (giờ)" /></label>}
            </div>
            <div className="flex flex-wrap items-end gap-2">
              <label className="text-[13px]">Từ ngày<input type="date" className="inp mt-1 w-[160px] py-1" name="date_from" defaultValue={today} required /></label>
              <label className="text-[13px]">Đến ngày<input type="date" className="inp mt-1 w-[160px] py-1" name="date_to" defaultValue={lastFin < today ? today : lastFin} required /></label>
              <label className="min-w-[280px] flex-1 text-[13px]">Lý do
                <input className="inp mt-1 py-1" name="reason" required defaultValue={late.length || base.late > 0 ? `Kịp ngày chốt: ${r.orders.filter((o) => o.commit ?? o.due).map((o) => o.label).join(', ')} (${gainTxt})` : `Rút ngắn kế hoạch: ${gainTxt}`} /></label>
              <SubmitButton className="btn btn-pri" pendingText="Đang gửi…">{isGd ? 'Áp dụng tăng ca' : 'Đề xuất Giám đốc duyệt'}</SubmitButton>
            </div>
          </form>
        )}
      </section>

      <section className="card">
        <div className="card-h"><h2>Đề xuất tăng ca</h2></div>
        {!ots.length ? <Empty>Chưa có đề xuất tăng ca nào.</Empty> : (
          <div className="overflow-x-auto"><table className="tbl">
            <thead><tr><th>Số</th><th>Nội dung</th><th>Khoảng ngày</th><th>Người đề xuất</th><th>Trạng thái</th><th></th></tr></thead>
            <tbody>{ots.map((o) => (
              <tr key={o.id}>
                <td><b>{o.req_no}</b><div className="text-[12px] text-muted">{df(o.proposed_at, true)}</div></td>
                <td className="text-[12.5px]">{Object.entries(o.extra_min ?? {}).map(([k, v]) => `${k} +${v}′/ngày`).join(', ')}{Number(o.mix_early_h) > 0 ? `${Object.keys(o.extra_min ?? {}).length ? '; ' : ''}trộn sớm ${h1(Number(o.mix_early_h))} giờ` : ''}
                  <div className="text-muted">{o.reason}</div>{o.review_note && <div className="text-muted">Ý kiến: {o.review_note}</div>}</td>
                <td className="whitespace-nowrap">{dd(o.date_from)}–{dd(o.date_to)}</td>
                <td className="text-[12.5px]">{o.proposed_by_name}{o.reviewed_by_name ? <div className="text-muted">Duyệt/xử lý: {o.reviewed_by_name}</div> : null}</td>
                <td><Pill tone={OT_STATUS[o.status]?.[1] ?? 'mute'}>{OT_STATUS[o.status]?.[0] ?? o.status}</Pill></td>
                <td className="min-w-[260px]">
                  {o.status === 'PROPOSED' && isGd && o.proposed_by !== userId && (
                    <form action={reviewOvertime} className="flex flex-wrap gap-1">
                      <input type="hidden" name="plan_id" value={kh.planId ?? ''} /><input type="hidden" name="id" value={o.id} />
                      <input className="inp min-w-[140px] flex-1 py-1" name="note" placeholder="Ý kiến (bắt buộc khi trả lại)" aria-label={`Ý kiến ${o.req_no}`} />
                      <SubmitButton className="btn btn-sm btn-pri" formAction={async (f: FormData) => { 'use server'; f.set('approve', '1'); await reviewOvertime(f); }}>Duyệt</SubmitButton>
                      <SubmitButton className="btn btn-sm btn-bad-o" formAction={async (f: FormData) => { 'use server'; f.set('approve', '0'); await reviewOvertime(f); }}>Trả lại</SubmitButton>
                    </form>
                  )}
                  {(o.status === 'APPROVED' || o.status === 'PROPOSED') && (isGd || roles.includes('SX_TP')) && (
                    <form action={endOvertime} className="mt-1 flex flex-wrap gap-1">
                      <input type="hidden" name="plan_id" value={kh.planId ?? ''} /><input type="hidden" name="id" value={o.id} />
                      <input className="inp min-w-[140px] flex-1 py-1" name="note" placeholder="Lý do" required aria-label={`Lý do kết thúc ${o.req_no}`} />
                      <SubmitButton className="btn btn-sm">{o.status === 'APPROVED' ? 'Kết thúc sớm' : 'Hủy đề xuất'}</SubmitButton>
                    </form>
                  )}
                </td>
              </tr>
            ))}</tbody>
          </table></div>
        )}
      </section>

      <section className="card">
        <div className="card-h"><h2>Thông số đang dùng</h2><Link className="link text-[13px]" href="/tham-so">Sửa ở Tham số xếp lịch</Link></div>
        <div className="overflow-x-auto"><table className="tbl"><tbody>
          <tr><td className="w-[240px]">Thời gian QC một bobin</td><td>{nf(F.qc_min)} phút {meta.qc_learn && meta.qc_learned.n >= QC_LEARN_MIN_SAMPLES ? `(MES tự học: trung vị ${meta.qc_learned.n} bobin 30 ngày)` : `(TP KT/QA nhập${meta.qc_learn ? `; MES tự học khi đủ ${QC_LEARN_MIN_SAMPLES} bobin có kết quả QC, hiện ${meta.qc_learned.n}` : ''})`}</td></tr>
          <tr><td>Mét một bobin</td><td>{Object.entries(F.unit_m).filter(([k]) => k !== 'CD0').map(([k, v]) => `${k} ${nf(v)} m`).join(' · ')}</td></tr>
          <tr><td>Đệm an toàn</td><td>{Object.entries(F.safety_min).filter(([, v]) => Number(v) > 0).map(([k, v]) => `${k} ${nf(Number(v))} phút`).join(' · ') || 'không'}</td></tr>
          <tr><td>Máy trộn</td><td>{mixers.map((m) => `${m.code} ${h1(mixerKgh(kh.cfg, m.code))} kg/giờ`).join(' · ') || 'không có'} · hạn dùng silicone {h1(F.pot_life_h)} giờ · mẻ {nf(F.mix_batch_kg)} kg</td></tr>
          <tr><td>Gom lô</td><td>{kh.cfg.group_days ?? 0} ngày · việc bắt đầu cách nhau ≤ {F.pick_window_min == null ? 'nửa ca' : `${F.pick_window_min} phút`} coi như cùng lúc</td></tr>
          <tr><td>Tốc độ mặc định</td><td>cỡ từ {nf(F.size_large_mm2, 2)} mm² dùng tốc độ cỡ lớn · tin tốc độ PLC khi đủ {nf(F.plc_min_run)} phút chạy</td></tr>
        </tbody></table></div>
      </section>
    </div>
  );
}
