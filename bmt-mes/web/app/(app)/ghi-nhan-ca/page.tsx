import Link from 'next/link';
import { Alert, LockNote, Swatch, dd, pc, wdl } from '@/components/kh';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Pill, Toolbar } from '@/components/ui';
import { ROLE, hasRole, loadKh } from '@/lib/kh/load';
import { DT_REASONS, SCRAP_REASONS, type Sample, sampleTemplate, shiftLines } from '@/lib/kh/shift';
import { OP_NAME, UNIT, type Op, isWorkday, shiftNoOf } from '@/lib/kh/scheduler';
import { df, nf, numIn } from '@/lib/format';
import { requireMe, requirePage } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { confirmReport, judgeSample, reopenReport, saveReport, submitReport } from './actions';

export const metadata = { title: 'Ghi nhận ca' };

type Keep = { material_code: string; kg: number; wo_no: string };
type Scrap = { wo_no: string; op_code: string; reason: string; kg: number };
type SlipSum = { wo_no: string; op_code: string; qty_m: number; status: string; scrap_kg: number | null };
type Report = {
  id: string; status: 'DRAFT' | 'SUBMITTED' | 'CONFIRMED'; operator_code: string | null; source: string; scrap_kg: number; scrap_reason: string | null; note: string | null;
  keeps: Keep[]; scraps: Scrap[];
  lines: { key: string; declared_m: number; plc_m: number | null; bobbins: number }[]; downtime: { from: string; to: string; min: number; reason: string; src: string }[];
  samples: Sample[]; saved_at: string | null; submitted_at: string | null; submitted_by_name: string | null; confirmed_at: string | null; confirmed_by_name: string | null; machine_code: string; shift_code: string;
};
const MODE: Record<string, [string, 'mute' | 'info' | 'ok']> = { MANUAL: ['Nhập tay', 'mute'], BOTH: ['Song song', 'info'], PLC: ['Tự động (PLC)', 'ok'] };
const ST: Record<string, [string, 'mute' | 'info' | 'ok' | 'warn']> = { DRAFT: ['Nháp', 'warn'], SUBMITTED: ['Chờ xác nhận', 'info'], CONFIRMED: ['Đã xác nhận', 'ok'] };

export default async function GhiNhanCa({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  await requirePage('ghi-nhan-ca');
  const me = await requireMe();
  const db = await createClient();
  const kh = await loadKh(db, { roles: me.roles });
  const date = sp.d && /^\d{4}-\d{2}-\d{2}$/.test(sp.d) ? sp.d : kh.now.date;
  // Ca 2, ca 3 chỉ hiện khi cả xưởng chạy ca đó hoặc có máy được duyệt chạy thêm ca ngày này
  const shifts = kh.cal.shifts.filter((s, j) => j === 0 || kh.cfg.shifts.find((x) => x.code === s.code)?.active
    || (kh.cfg.machine_shifts ?? []).some((x) => x.from <= date && date <= x.to && x.shifts >= shiftNoOf(s.code)));
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

  // Sản lượng MES tự cộng từ phiếu hoàn thành của máy trong ngày (Kế toán SX đã nhập)
  const { data: slipRows } = code
    ? await db.schema('app').from('v_bobbin_slips').select('wo_no, op_code, qty_m, status, scrap_kg').eq('work_date', date).eq('machine_code', code).eq('status', 'ACTIVE').returns<SlipSum[]>()
    : { data: [] as SlipSum[] };
  const slips = slipRows ?? [];
  const lineIds = plan.map((l) => l.plan_line_id).filter(Boolean);
  const { data: wos } = lineIds.length || slips.length
    ? await db.schema('mfg').from('work_orders').select('wo_no, plan_line_id, status')
        .or([lineIds.length ? `plan_line_id.in.(${lineIds.join(',')})` : '', slips.length ? `wo_no.in.(${[...new Set(slips.map((x) => x.wo_no))].join(',')})` : ''].filter(Boolean).join(','))
    : { data: [] as { wo_no: string; plan_line_id: string | null; status: string }[] };
  const woOfLine = (id: string) => (wos ?? []).filter((w) => w.plan_line_id === id && w.status !== 'CANCELLED').map((w) => w.wo_no);
  const schedOp = (op: string) => (op === 'CD4' ? 'CD3' : op);
  const fromSlips = (l: { plan_line_id: string; op: string }) => {
    const mine = slips.filter((x) => woOfLine(l.plan_line_id).includes(x.wo_no) && schedOp(x.op_code) === l.op);
    return { m: mine.reduce((a, x) => a + Number(x.qty_m), 0), n: mine.length };
  };
  const matched = new Set(plan.flatMap((l) => slips.filter((x) => woOfLine(l.plan_line_id).includes(x.wo_no) && schedOp(x.op_code) === l.op)));
  const extraSlips = slips.filter((x) => !matched.has(x));
  const slipScrap = slips.reduce((a, x) => a + Number(x.scrap_kg ?? 0), 0);
  // Lô · công đoạn của máy trong ca: theo lịch và theo phiếu hoàn thành
  const woOps = [...new Set([
    ...plan.flatMap((l) => woOfLine(l.plan_line_id).map((w) => `${w}|${l.op}`)),
    ...slips.map((x) => `${x.wo_no}|${x.op_code}`),
    ...(rep?.scraps ?? []).map((x) => `${x.wo_no}|${x.op_code}`),
  ])];
  const woList = [...new Set([...woOps.map((x) => x.split('|')[0]), ...(rep?.keeps ?? []).map((k) => k.wo_no)])];
  const { data: mats } = await db.schema('master').from('materials').select('code, name, uom').in('group_code', ['CONDUCTOR', 'COMPOUND', 'ADDITIVE', 'COLOR', 'TAPE_FILLER']).eq('is_scrap', false).order('code');
  const keeps: Keep[] = [...(rep?.keeps ?? []), ...Array.from({ length: locked ? 0 : 3 }, () => ({ material_code: '', kg: 0, wo_no: '' }))];
  const oldScrap: Scrap[] = rep && !rep.scraps?.length && Number(rep.scrap_kg) > 0 ? [{ wo_no: '', op_code: '', reason: rep.scrap_reason ?? '', kg: Number(rep.scrap_kg) }] : [];
  const scraps: Scrap[] = [...(rep?.scraps ?? []), ...oldScrap, ...Array.from({ length: locked ? 0 : 3 }, () => ({ wo_no: '', op_code: '', reason: '', kg: 0 }))];

  return (
    <>
      <Toolbar title={<span>Ghi nhận ca · {wdl(date)} {dd(date)} · Ca {shift}</span>} reload={q({})}
        actions={<form action="/ghi-nhan-ca" className="flex flex-wrap items-center gap-1.5">
          <input type="date" name="d" defaultValue={date} className="inp w-[160px] py-1" aria-label="Ngày" />
          {shifts.length > 1 && <select name="s" defaultValue={shift} className="inp w-auto py-1" aria-label="Ca">{shifts.map((s) => <option key={s.code} value={s.code}>Ca {s.code}</option>)}</select>}
          {code && <input type="hidden" name="m" value={code} />}
          <button className="btn btn-sm">Xem</button>
          <Link className="btn btn-sm" href={`/in/bao-cao-ca?d=${date}&s=${shift}`} target="_blank">In báo cáo ca trống</Link>
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
              {pendingSamples > 0 && <p className="border-t border-line px-4 py-2.5 text-[13px] text-warn">Mẫu chưa đạt: chỉ chạy lấy mẫu, chưa chạy hàng loạt. Mẫu Không đạt thì chưa gửi được báo cáo ca (QC vẫn kiểm từng bobin sau công đoạn).</p>}
            </section>
          )}

          <form action={saveReport} className="flex flex-col gap-4">
            {hidden}
            <section className="card">
              <div className="card-h"><h2>Sản lượng theo lệnh</h2><span className="text-[13px] font-normal text-muted">MES tự cộng từ phiếu hoàn thành bobin; máy chưa có phiếu thì nhập theo đồng hồ mét</span></div>
              {plan.length ? (
                <div className="overflow-x-auto"><table className="tbl">
                  <thead><tr><th>Dòng</th><th>Sản phẩm</th><th className="num">KH cả ca</th><th className="num">Phiếu hoàn thành</th><th className="num">Khai báo (m)</th><th className="num">Bobin ra</th><th className="num">Đạt</th></tr></thead>
                  <tbody>{plan.map((l, i) => {
                    const v = val(l.key);
                    const fs = fromSlips(l);
                    return (
                      <tr key={l.key}>
                        <td className="mono">{l.label}</td>
                        <td><b>{l.product_code}</b><div className="text-[12px] text-muted">{OP_NAME[l.op as Op] ?? l.op}{l.color ? <> · <Swatch color={l.color} />{l.color}</> : ''}{l.newCode ? ' · đổi mã giữa ca' : ''}</div></td>
                        <td className="num">{nf(l.planned_m)}<div className="text-[12px] text-muted">{UNIT[l.op as Op]}</div></td>
                        <td className="num">{fs.n ? <>{nf(fs.m)}<div className="text-[12px] text-muted">{fs.n} bobin</div></> : '—'}</td>
                        <td className="num w-[140px]"><input name={`decl_${i}`} defaultValue={v ? nf(v.declared_m) : fs.n ? nf(fs.m) : ''} inputMode="numeric" className="inp text-right" disabled={locked} aria-label={`Mét khai báo ${l.label}`} /></td>
                        <td className="num w-[100px]"><input name={`bob_${i}`} defaultValue={v?.bobbins ? String(v.bobbins) : fs.n ? String(fs.n) : ''} inputMode="numeric" className="inp text-right" disabled={locked} aria-label={`Bobin ra ${l.label}`} /></td>
                        <td className="num">{v && l.planned_m ? pc(v.declared_m / l.planned_m) : '—'}</td>
                      </tr>
                    );
                  })}</tbody>
                </table></div>
              ) : <Empty>{m?.code} không có việc trong ca {shift} ngày {dd(date)} theo lịch máy.</Empty>}
              {extraSlips.length > 0 && (
                <p className="border-t border-line px-4 py-2 text-[12.5px] text-muted">Phiếu hoàn thành ngoài lịch ca này: {extraSlips.map((x) => `${x.wo_no} ${x.op_code} ${nf(x.qty_m)} m`).join(' · ')}</p>
              )}
              <div className="flex flex-wrap items-end gap-3 border-t border-line px-4 py-3">
                <label className="lbl">Người đứng máy
                  <select name="operator" defaultValue={rep?.operator_code ?? (plan[0] ? kh.sch?.byMachine.get(code ?? '')?.find((s) => s.key === plan[0].key)?.operator ?? '' : '')} className="inp w-[200px]" disabled={locked}>
                    <option value="">Chọn…</option>{opsFor.map((w) => <option key={w.code} value={w.code}>{w.code}</option>)}
                  </select></label>
              </div>
            </section>

            <section className="card">
              <div className="card-h"><h2>Dừng máy</h2><span className="text-[13px] font-normal text-muted">trên {kh.cfg.downtime_reason_min} phút bắt buộc chọn lý do · chốt ca: MES ghi vào lịch sử máy, hỏng máy chưa có phiếu thì mở phiếu sửa chữa</span></div>
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
              <div className="card-h"><h2>NVL để lại máy chạy tiếp cùng lô</h2><span className="text-[13px] font-normal text-muted">đồng trên giá xả, nhựa trong phễu khi ngày mai chạy tiếp cùng lô · NVL trả kho nhập ở Phiếu xuất NVL, NVL thừa</span></div>
              <div className="overflow-x-auto"><table className="tbl">
                <thead><tr><th>Vật tư</th><th className="num">Kg cân</th><th>Lô chạy tiếp</th></tr></thead>
                <tbody>{keeps.length ? keeps.map((k, i) => (
                  <tr key={i}>
                    <td className="min-w-[200px]"><input name={`kp_mat_${i}`} defaultValue={k.material_code} list="kp-mats" className="inp mono uppercase" disabled={locked} aria-label={`Vật tư để lại máy ${i + 1}`} /></td>
                    <td className="num w-[140px]"><input name={`kp_kg_${i}`} defaultValue={k.kg ? numIn(k.kg) : ''} inputMode="decimal" className="inp text-right" disabled={locked} aria-label={`Kg để lại máy ${i + 1}`} /></td>
                    <td className="min-w-[180px]"><select name={`kp_wo_${i}`} defaultValue={k.wo_no} className="inp" disabled={locked} aria-label={`Lô chạy tiếp ${i + 1}`}>
                      <option value="">—</option>{woList.map((w) => <option key={w} value={w}>{w}</option>)}</select></td>
                  </tr>
                )) : <tr><td colSpan={3} className="text-[13px] text-muted">Không để lại NVL trên máy.</td></tr>}</tbody>
              </table></div>
              <datalist id="kp-mats">{(mats ?? []).map((x) => <option key={x.code} value={x.code}>{x.name}</option>)}</datalist>
            </section>

            <section className="card">
              <div className="card-h"><h2>Phế cả ca</h2><span className="text-[13px] font-normal text-muted">chỉ phế chưa ghi trên phiếu hoàn thành bobin (khởi động, xả nhựa, đổi màu…) · ghi vào sổ phế khi TP SX chốt ca</span></div>
              <div className="overflow-x-auto"><table className="tbl">
                <thead><tr><th>Lô · công đoạn</th><th>Lý do</th><th className="num">Kg</th></tr></thead>
                <tbody>{scraps.length ? scraps.map((x, i) => (
                  <tr key={i}>
                    <td className="min-w-[200px]"><select name={`sc_wo_${i}`} defaultValue={x.wo_no ? `${x.wo_no}|${x.op_code}` : ''} className="inp" disabled={locked} aria-label={`Lô phế ${i + 1}`}>
                      <option value="">—</option>{woOps.map((w) => <option key={w} value={w}>{w.replace('|', ' · ')}</option>)}</select></td>
                    <td className="min-w-[200px]"><select name={`sc_reason_${i}`} defaultValue={x.reason} className="inp" disabled={locked} aria-label={`Lý do phế ${i + 1}`}>
                      <option value="">—</option>{Object.entries(SCRAP_REASONS).map(([k2, v2]) => <option key={k2} value={k2}>{v2}</option>)}</select></td>
                    <td className="num w-[140px]"><input name={`sc_kg_${i}`} defaultValue={x.kg ? numIn(x.kg) : ''} inputMode="decimal" className="inp text-right" disabled={locked} aria-label={`Kg phế ${i + 1}`} /></td>
                  </tr>
                )) : <tr><td colSpan={3} className="text-[13px] text-muted">Không có phế ngoài phiếu bobin.</td></tr>}</tbody>
              </table></div>
              <div className="flex flex-wrap items-end gap-3 border-t border-line px-4 py-3">
                <p className="w-full text-[12.5px] text-muted">Phế đã ghi trên phiếu hoàn thành của máy trong ngày: {nf(slipScrap, 2)} kg. Phế đồng để thùng riêng.</p>
                <label className="lbl w-full">Ghi chú<textarea name="note" rows={2} defaultValue={rep?.note ?? ''} className="inp" disabled={locked} /></label>
              </div>
            </section>

            {status === 'DRAFT' && (plan.length > 0 || rep) && (
              <section className="card flex flex-col gap-2 px-4 py-3">
                {missingReason > 0 && <div className="text-[13px] text-warn">Còn {missingReason} lần dừng chưa chọn lý do. Chọn xong mới gửi được.</div>}
                {samples.some((x) => x.status === 'NG') && <div className="text-[13px] text-warn">Mẫu đầu ca/đầu mã không đạt. Chưa gửi được báo cáo ca.</div>}
                {canSubmit ? (
                  <div className="flex flex-wrap items-center gap-2">
                    <SubmitButton className="btn">Lưu nháp</SubmitButton>
                    <SubmitButton formAction={submitReport}>Lưu và gửi xác nhận</SubmitButton>
                    <span className="text-[12.5px] text-muted">TP SX chốt ca (vắng thì tổ phó NV1). Kế toán SX nhập từ tờ báo cáo ca giấy có chữ ký công nhân.</span>
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
            <Alert tone="ok" title={`Đã xác nhận · ${rep.confirmed_by_name ?? ''} · ${df(rep.confirmed_at, true)}`}>Báo cáo ca đã khóa. Số liệu đã cộng vào Kế hoạch sản xuất chung và dùng khi xếp lại lịch.</Alert>
          )}
        </div>
      </div>
    </>
  );
}
