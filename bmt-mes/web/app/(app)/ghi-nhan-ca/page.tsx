import Link from 'next/link';
import { Alert, LockNote, Swatch, dd, pc, wdl } from '@/components/kh';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Pill, Toolbar } from '@/components/ui';
import { ROLE, hasRole, loadKh } from '@/lib/kh/load';
import { DT_REASONS, SCRAP_REASONS, type Sample, sampleTemplate, shiftLines } from '@/lib/kh/shift';
import { OP_NAME, UNIT, type Op, isWorkday } from '@/lib/kh/scheduler';
import { df, nf, numIn } from '@/lib/format';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { confirmReport, judgeSample, reopenReport, saveReport, submitReport } from './actions';

export const metadata = { title: 'Ghi nhận ca' };

type Report = {
  id: string; status: 'DRAFT' | 'SUBMITTED' | 'CONFIRMED'; operator_code: string | null; source: string; scrap_kg: number; scrap_reason: string | null; note: string | null;
  lines: { key: string; declared_m: number; plc_m: number | null; bobbins: number }[]; downtime: { from: string; to: string; min: number; reason: string; src: string }[];
  samples: Sample[]; saved_at: string | null; submitted_at: string | null; submitted_by_name: string | null; confirmed_at: string | null; confirmed_by_name: string | null; machine_code: string; shift_code: string;
};
const MODE: Record<string, [string, 'mute' | 'info' | 'ok']> = { MANUAL: ['Nhập tay', 'mute'], BOTH: ['Song song', 'info'], PLC: ['Tự động (PLC)', 'ok'] };
const ST: Record<string, [string, 'mute' | 'info' | 'ok' | 'warn']> = { DRAFT: ['Nháp', 'warn'], SUBMITTED: ['Chờ xác nhận', 'info'], CONFIRMED: ['Đã xác nhận', 'ok'] };

export default async function GhiNhanCa({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const me = await requireMe();
  const db = await createClient();
  const kh = await loadKh(db, { roles: me.roles });
  const date = sp.d && /^\d{4}-\d{2}-\d{2}$/.test(sp.d) ? sp.d : kh.now.date;
  const shifts = kh.cal.shifts;
  const shift = shifts.find((s) => s.code === sp.s)?.code ?? shifts[0]?.code ?? 'A';
  const { data: repRows } = await db.schema('app').from('v_kh_reports').select('*').eq('work_date', date).eq('shift_code', shift);
  const reports = (repRows ?? []) as Report[];
  const plans = Object.fromEntries(kh.machines.map((m) => [m.code, shiftLines(kh, date, m.code, shift)]));
  const code = kh.machines.find((m) => m.code === sp.m)?.code ?? kh.machines.find((m) => plans[m.code].length)?.code ?? kh.machines[0]?.code;
  const m = kh.machines.find((x) => x.code === code);
  const plan = code ? plans[code] : [];
  const rep = reports.find((r) => r.machine_code === code) ?? null;
  const samples: Sample[] = rep?.samples?.length ? rep.samples : sampleTemplate(plan);
  const canSubmit = hasRole(me.roles, ROLE.submit), canConfirm = hasRole(me.roles, ROLE.confirm), canSample = hasRole(me.roles, ROLE.sample);
  const status = rep?.status ?? 'DRAFT';
  const locked = status !== 'DRAFT' || !canSubmit;
  const pendingSamples = samples.filter((s) => s.status !== 'OK').length;
  const val = (key: string) => rep?.lines.find((l) => l.key === key);
  const dts = [...(rep?.downtime ?? []), ...Array.from({ length: locked ? 0 : 3 }, () => ({ from: '', to: '', min: 0, reason: '', src: 'MANUAL' }))];
  const missingReason = (rep?.downtime ?? []).filter((d) => !d.reason && d.min > kh.cfg.downtime_reason_min).length;
  const opsFor = kh.operators.filter((w) => w.skills.includes(code ?? ''));
  const hidden = <><input type="hidden" name="d" value={date} /><input type="hidden" name="m" value={code ?? ''} /><input type="hidden" name="s" value={shift} /></>;
  const q = (x: Record<string, string>) => '/ghi-nhan-ca?' + new URLSearchParams({ d: date, s: shift, ...(code ? { m: code } : {}), ...x }).toString();
  const sh = shifts.find((s) => s.code === shift);

  return (
    <>
      <Toolbar title={<span>Ghi nhận ca · {wdl(date)} {dd(date)} · Ca {shift}</span>} reload={q({})}
        actions={<form action="/ghi-nhan-ca" className="flex flex-wrap items-center gap-1.5">
          <input type="date" name="d" defaultValue={date} className="inp w-[160px] py-1" aria-label="Ngày" />
          {shifts.length > 1 && <select name="s" defaultValue={shift} className="inp w-auto py-1" aria-label="Ca">{shifts.map((s) => <option key={s.code} value={s.code}>Ca {s.code}</option>)}</select>}
          {code && <input type="hidden" name="m" value={code} />}
          <button className="btn btn-sm">Xem</button>
        </form>} />
      <div className="mt-3 text-[13px] text-muted">Màn hình tại máy · {sh ? `${sh.start_time} – ${sh.end_time}` : ''}{!isWorkday(date, kh.cal.wd) ? ' · ngày nghỉ: không có kế hoạch' : ''}{kh.version ? ` · lịch máy phiên bản ${kh.version.version}` : ''}</div>
      <div className="mt-3"><Flash ok={sp.ok} err={sp.err} /></div>
      {!kh.version && <Alert tone="info">Chưa có lịch máy: chưa có kế hoạch ca. Vẫn ghi được dừng máy, phế phẩm nếu máy chạy việc khác.</Alert>}

      <div className="grid gap-4 lg:grid-cols-[260px_minmax(0,1fr)]">
        <nav className="card self-start" aria-label="Máy">
          <div className="card-h"><h2>Máy</h2></div>
          {kh.machines.map((x) => {
            const r = reports.find((y) => y.machine_code === x.code);
            const p = plans[x.code];
            const s = !p.length && !r ? 'Không chạy ca này' : r ? ST[r.status][0] : `${p[0]?.label ?? ''} · chưa nhập`;
            return (
              <Link key={x.code} href={q({ m: x.code })} aria-current={x.code === code ? 'page' : undefined}
                className={`block border-b border-line px-4 py-2.5 last:border-b-0 ${x.code === code ? 'border-l-4 border-l-brand bg-brand-soft' : 'hover:bg-sunk'}`}>
                <span className="flex items-center gap-2 text-[14px] font-medium">{x.code}<span className="ml-auto"><Pill tone={MODE[x.data_mode]?.[1] ?? 'mute'}>{MODE[x.data_mode]?.[0] ?? x.data_mode}</Pill></span></span>
                <span className="block truncate text-[12.5px] text-muted">{x.name} · {s}</span>
              </Link>
            );
          })}
        </nav>

        <div className="flex min-w-0 flex-col gap-4">
          {m && (
            <section className="card flex flex-wrap items-center gap-3 px-4 py-3">
              <div className="min-w-0"><div className="text-[16px] font-medium">{m.code} · {m.name}</div>
                <div className="text-[12.5px] text-muted">Người đứng máy theo lịch: <b>{plan[0] ? (kh.sch?.byMachine.get(m.code)?.find((s) => s.key === plan[0].key)?.operator ?? '—') : '—'}</b> · {m.tag_count ? `PLC đã khai báo ${m.tag_count} tag` : 'Chưa kết nối PLC: nhập tay theo đồng hồ mét'}</div></div>
              <span className="ml-auto"><Pill tone={ST[status][1]}>{rep ? ST[status][0] : 'Chưa nhập'}</Pill></span>
            </section>
          )}

          {samples.length > 0 && (
            <section className="card">
              <div className="card-h"><h2>Mẫu đầu ca, đầu mã</h2><span className="text-[13px] font-normal text-muted">TP Kỹ thuật/QA hoặc QC duyệt trước khi chạy hàng loạt</span></div>
              <div className="overflow-x-auto"><table className="tbl"><tbody>
                {samples.map((x, i) => (
                  <tr key={i}>
                    <td><b>{x.kind}</b> · {x.product_code}</td>
                    <td>{x.status === 'OK' ? <Pill tone="ok">Đạt · {x.by_name} · {x.at}</Pill> : x.status === 'NG' ? <Pill tone="bad">Không đạt · {x.by_name} · chỉnh máy, lấy mẫu lại</Pill> : <Pill tone="warn">Chờ duyệt</Pill>}</td>
                    <td className="text-right">{x.status !== 'OK' && status !== 'CONFIRMED' && (canSample ? (
                      <span className="inline-flex gap-1.5">
                        <form action={judgeSample}>{hidden}<input type="hidden" name="i" value={i} /><input type="hidden" name="r" value="OK" /><SubmitButton className="btn btn-sm btn-pri" pendingText="…">Đạt</SubmitButton></form>
                        <form action={judgeSample}>{hidden}<input type="hidden" name="i" value={i} /><input type="hidden" name="r" value="NG" /><SubmitButton className="btn btn-sm btn-bad-o" pendingText="…">Không đạt</SubmitButton></form>
                      </span>
                    ) : <LockNote>Chờ TP Kỹ thuật/QA, QC</LockNote>)}</td>
                  </tr>
                ))}
              </tbody></table></div>
              {pendingSamples > 0 && <p className="border-t border-line px-4 py-2.5 text-[13px] text-warn">Mẫu chưa đạt: chỉ chạy lấy mẫu, chưa được chạy hàng loạt và chưa gửi được báo cáo ca.</p>}
            </section>
          )}

          <form action={saveReport} className="flex flex-col gap-4">
            {hidden}
            <section className="card">
              <div className="card-h"><h2>Sản lượng theo lệnh</h2><span className="text-[13px] font-normal text-muted">nhập theo đồng hồ mét, ngay trong ca</span></div>
              {plan.length ? (
                <div className="overflow-x-auto"><table className="tbl">
                  <thead><tr><th>Dòng</th><th>Sản phẩm</th><th className="num">KH cả ca</th><th className="num">Khai báo (m)</th><th className="num">Bobin ra</th><th className="num">Đạt</th></tr></thead>
                  <tbody>{plan.map((l, i) => {
                    const v = val(l.key);
                    return (
                      <tr key={l.key}>
                        <td className="mono">{l.label}</td>
                        <td><b>{l.product_code}</b><div className="text-[12px] text-muted">{OP_NAME[l.op as Op] ?? l.op}{l.color ? <> · <Swatch color={l.color} />{l.color}</> : ''}{l.newCode ? ' · đổi mã giữa ca' : ''}</div></td>
                        <td className="num">{nf(l.planned_m)}<div className="text-[12px] text-muted">{UNIT[l.op as Op]}</div></td>
                        <td className="num w-[140px]"><input name={`decl_${i}`} defaultValue={v ? nf(v.declared_m) : ''} inputMode="numeric" className="inp text-right" disabled={locked} aria-label={`Mét khai báo ${l.label}`} /></td>
                        <td className="num w-[100px]"><input name={`bob_${i}`} defaultValue={v?.bobbins ? String(v.bobbins) : ''} inputMode="numeric" className="inp text-right" disabled={locked} aria-label={`Bobin ra ${l.label}`} /></td>
                        <td className="num">{v && l.planned_m ? pc(v.declared_m / l.planned_m) : '—'}</td>
                      </tr>
                    );
                  })}</tbody>
                </table></div>
              ) : <Empty>{m?.code} không có việc trong ca {shift} ngày {dd(date)} theo lịch máy.</Empty>}
              <div className="flex flex-wrap items-end gap-3 border-t border-line px-4 py-3">
                <label className="lbl">Người đứng máy
                  <select name="operator" defaultValue={rep?.operator_code ?? (plan[0] ? kh.sch?.byMachine.get(code ?? '')?.find((s) => s.key === plan[0].key)?.operator ?? '' : '')} className="inp w-[200px]" disabled={locked}>
                    <option value="">Chọn…</option>{opsFor.map((w) => <option key={w.code} value={w.code}>{w.code}</option>)}
                  </select></label>
              </div>
            </section>

            <section className="card">
              <div className="card-h"><h2>Dừng máy</h2><span className="text-[13px] font-normal text-muted">trên {kh.cfg.downtime_reason_min} phút bắt buộc chọn lý do · hỏng máy báo ngay TP Kỹ thuật/QA</span></div>
              <div className="overflow-x-auto"><table className="tbl">
                <thead><tr><th>Dừng lúc</th><th>Chạy lại lúc</th><th className="num">Phút</th><th>Lý do</th></tr></thead>
                <tbody>{dts.length ? dts.map((d, i) => (
                  <tr key={i}>
                    <td className="w-[130px]"><input name={`dt_from_${i}`} defaultValue={d.from} placeholder="08:12" className="inp mono" disabled={locked} aria-label={`Dừng lúc dòng ${i + 1}`} /></td>
                    <td className="w-[130px]"><input name={`dt_to_${i}`} defaultValue={d.to} placeholder="08:25" className="inp mono" disabled={locked} aria-label={`Chạy lại lúc dòng ${i + 1}`} /></td>
                    <td className="num">{d.min || '—'}</td>
                    <td className="min-w-[200px]"><select name={`dt_reason_${i}`} defaultValue={d.reason} disabled={locked} aria-label={`Lý do dừng dòng ${i + 1}`}
                      className={`inp ${!d.reason && d.min > kh.cfg.downtime_reason_min ? 'border-bad' : ''}`}>
                      <option value="">Chọn lý do…</option>{Object.entries(DT_REASONS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></td>
                  </tr>
                )) : <tr><td colSpan={4} className="text-[13px] text-muted">Không có lần dừng nào.</td></tr>}</tbody>
              </table></div>
              {!locked && <p className="border-t border-line px-4 py-2 text-[12.5px] text-muted">Nhiều hơn 3 lần dừng: lưu nháp, hệ thống thêm dòng trống mới.</p>}
            </section>

            <section className="card">
              <div className="card-h"><h2>Phế phẩm và ghi chú</h2></div>
              <div className="flex flex-wrap items-end gap-3 px-4 py-3">
                <label className="lbl w-[140px]">Khối lượng (kg)<input name="scrap_kg" defaultValue={rep && Number(rep.scrap_kg) ? numIn(rep.scrap_kg) : ''} inputMode="decimal" className="inp text-right" disabled={locked} /></label>
                <label className="lbl min-w-[200px] flex-1">Nguyên nhân<select name="scrap_reason" defaultValue={rep?.scrap_reason ?? ''} className="inp" disabled={locked}>
                  <option value="">—</option>{Object.entries(SCRAP_REASONS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></label>
                <label className="lbl w-full">Ghi chú<textarea name="note" rows={2} defaultValue={rep?.note ?? ''} className="inp" disabled={locked} /></label>
                <p className="w-full text-[12.5px] text-muted">Cuối ca nộp phế đồng về kho cùng vật tư thừa để cân bằng đồng.</p>
              </div>
            </section>

            {status === 'DRAFT' && (plan.length > 0 || rep) && (
              <section className="card flex flex-col gap-2 px-4 py-3">
                {missingReason > 0 && <div className="text-[13px] text-warn">Còn {missingReason} lần dừng chưa chọn lý do. Chọn xong mới gửi được.</div>}
                {pendingSamples > 0 && <div className="text-[13px] text-warn">Mẫu đầu ca/đầu mã chưa đạt. Chưa gửi được báo cáo ca.</div>}
                {canSubmit ? (
                  <div className="flex flex-wrap items-center gap-2">
                    <SubmitButton className="btn">Lưu nháp</SubmitButton>
                    <SubmitButton formAction={submitReport}>Lưu và gửi xác nhận</SubmitButton>
                    <span className="text-[12.5px] text-muted">Tổ trưởng / Quản lý SX xác nhận trước {sh?.end_time ?? 'khi hết ca'}. Vắng thì tổ phó NV1 xác nhận theo ủy quyền.</span>
                  </div>
                ) : <LockNote>Vai trò này chỉ xem báo cáo ca</LockNote>}
                {rep?.saved_at && <div className="text-[12px] text-muted">Lưu lần cuối {df(rep.saved_at, true)}</div>}
              </section>
            )}
          </form>

          {rep && status === 'SUBMITTED' && (
            <section className="card px-4 py-3">
              <div className="mb-2 text-[14px]"><b>Đã gửi lúc {df(rep.submitted_at, true)}</b> · {rep.submitted_by_name ?? ''} · chờ xác nhận trước {sh?.end_time ?? ''}</div>
              {canConfirm ? (
                <form action={confirmReport} className="flex flex-col gap-2">{hidden}<input type="hidden" name="id" value={rep.id} />
                  <label className="lbl">Ghi chú / giải trình (nếu có)<textarea name="note" rows={2} className="inp" /></label>
                  <div className="flex flex-wrap gap-2"><SubmitButton>Xác nhận báo cáo ca</SubmitButton><SubmitButton className="btn" formAction={reopenReport}>Trả lại để sửa</SubmitButton></div>
                </form>
              ) : <LockNote>Chờ tổ trưởng / Quản lý SX xác nhận</LockNote>}
            </section>
          )}
          {rep && status === 'CONFIRMED' && (
            <Alert tone="ok" title={`Đã xác nhận · ${rep.confirmed_by_name ?? ''} · ${df(rep.confirmed_at, true)}`}>Báo cáo ca đã khóa. Số liệu đã cộng vào Kế hoạch – Thực tế và dùng khi xếp lại lịch.</Alert>
          )}
        </div>
      </div>
    </>
  );
}
