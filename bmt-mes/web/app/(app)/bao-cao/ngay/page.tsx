import Link from 'next/link';
import { redirect } from 'next/navigation';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Kpi, Pill, Toolbar } from '@/components/ui';
import { df, nf } from '@/lib/format';
import { hasRole } from '@/lib/kho';
import { can, requireMe, requirePage } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { saveLossNote, sendDailyReport } from './actions';

export const metadata = { title: 'Báo cáo sản xuất ngày' };

type Prod = { machine_code: string; op_code: string; op_name: string | null; slips: number; m: number; kg: number; est: boolean; scrap_kg: number };
type Mat = { wo_no: string; material_code: string; material_name: string; uom: string; issued: number; returned: number };
type KeepRow = { machine_code: string; shift_code: string; material_code: string; kg: number; wo_no: string };
type Shift = { machine_code: string; machine_name: string; shift_code: string | null; status: string; downtime_min: number; shift_scrap_kg: number; slips: number };
type Loss = {
  wo_id: string; wo_no: string; product_code: string; wo_status: string; stage: string; label: string; uom: string; in_qty: number | null; out_qty: number | null;
  loss_qty: number | null; loss_pct: number | null; norm_in: number | null; var_pct: number | null; tol_pct: number | null; level: 'GREEN' | 'YELLOW' | 'RED' | 'NA';
  detail: string | null; note: string | null; noted_by: string | null; noted_at: string | null;
};
type Report = {
  production: Prod[]; qc: { made: number; passed: number; failed: number; pending_now: number; late_now: number }; materials: Mat[]; keeps: KeepRow[];
  shifts: Shift[]; loss: Loss[]; counts: Record<string, number>; sent: { sent_at: string; auto: boolean; by: string | null } | null;
};

const LEVEL: Record<Loss['level'], [string, 'ok' | 'warn' | 'bad' | 'mute']> = {
  GREEN: ['Xanh', 'ok'], YELLOW: ['Vàng', 'warn'], RED: ['Đỏ', 'bad'], NA: ['Chưa tính', 'mute'],
};
const SHIFT_ST: Record<string, [string, 'ok' | 'warn' | 'bad' | 'info']> = {
  CONFIRMED: ['Đã chốt', 'ok'], SUBMITTED: ['Chờ chốt', 'info'], DRAFT: ['Nháp', 'warn'], MISSING: ['Chưa nhập', 'bad'],
};
const shiftDay = (d: string, n: number) => {
  const x = new Date(`${d}T00:00:00Z`);
  x.setUTCDate(x.getUTCDate() + n);
  return x.toISOString().slice(0, 10);
};

export default async function DailyReport({ searchParams }: { searchParams: Promise<{ d?: string; ok?: string; err?: string }> }) {
  const sp = await searchParams;
  await requirePage('bc-ngay');
  const me = await requireMe();
  if (!can(me, 'production', 'view') && !can(me, 'inventory', 'view') && !can(me, 'cost', 'view')) {
    redirect('/?err=' + encodeURIComponent('Không có quyền xem báo cáo sản xuất ngày'));
  }
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Ho_Chi_Minh' });
  const d = /^\d{4}-\d{2}-\d{2}$/.test(sp.d ?? '') ? sp.d! : today;
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc('daily_report', { p_date: d });
  const r = data as Report | null;
  const canSend = hasRole(me, 'KT_KHO', 'SX_TP', 'BGD', 'ADMIN');
  const canNote = hasRole(me, 'SX_TP', 'BGD', 'ADMIN');
  const slips = (r?.production ?? []).reduce((a, x) => a + Number(x.slips), 0);
  const meters = (r?.production ?? []).reduce((a, x) => a + Number(x.m), 0);
  const c = r?.counts ?? {};
  const byWo = new Map<string, Loss[]>();
  for (const x of r?.loss ?? []) byWo.set(x.wo_no, [...(byWo.get(x.wo_no) ?? []), x]);

  return (
    <>
      <Toolbar title={`Báo cáo sản xuất ngày ${df(d)}`} reload={`/bao-cao/ngay?d=${d}`} actions={<>
        <Link className="btn btn-sm" href={`/bao-cao/ngay?d=${shiftDay(d, -1)}`}>‹ Ngày trước</Link>
        <form className="flex items-center gap-2"><input className="inp" type="date" name="d" defaultValue={d} aria-label="Ngày" /><button className="btn btn-sm">Xem</button></form>
        {d < today && <Link className="btn btn-sm" href={`/bao-cao/ngay?d=${shiftDay(d, 1)}`}>Ngày sau ›</Link>}
      </>} />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err ?? (error ? error.message : undefined)} /></div>
      {r && (
        <>
          <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
            <Kpi label="Bobin hoàn thành" value={nf(slips)} hint={`${nf(meters)} m theo phiếu hoàn thành`} href={`/phieu-hoan-thanh?ngay=${d}`} />
            <Kpi label="Bobin chờ QC" value={nf(r.qc.pending_now)} hint={`${nf(r.qc.late_now)} quá hạn trả kết quả`} tone={r.qc.late_now ? 'bad' : r.qc.pending_now ? 'warn' : undefined} href="/kho/qc" />
            <Kpi label="Hao hụt đỏ" value={nf(c.RED ?? 0)} hint="TP SX giải trình trước 10:00 hôm sau" tone={c.RED ? 'bad' : undefined} />
            <Kpi label="Hao hụt vàng" value={nf(c.YELLOW ?? 0)} hint="TP SX xem, ghi chú" tone={c.YELLOW ? 'warn' : undefined} />
            <Kpi label="Trong định mức" value={nf(c.GREEN ?? 0)} hint={c.NA ? `${c.NA} mục chưa có đầu ra` : 'xanh'} tone="ok" />
          </div>

          <section className="card mb-4 flex flex-wrap items-center gap-3 px-4 py-3">
            <div className="text-[13.5px]">
              {r.sent ? <>Đã gửi báo cáo lúc <b>{df(r.sent.sent_at, true)}</b> · {r.sent.auto ? 'MES tự gửi 19:30' : r.sent.by ?? ''}</> : 'Chưa gửi báo cáo ngày.'}
              <div className="text-[12.5px] text-muted">Gửi cho TP SX, Kế toán SX, Giám đốc, tổ trưởng; mục đỏ báo riêng Giám đốc (email ngay). 19:30 MES tự gửi nếu chưa ai gửi.</div>
            </div>
            {canSend && d <= today && (
              <form action={sendDailyReport} className="ml-auto"><input type="hidden" name="d" value={d} />
                <SubmitButton>{r.sent ? 'Gửi lại báo cáo ngày' : 'Đã đối soát xong – gửi báo cáo ngày'}</SubmitButton>
              </form>
            )}
          </section>

          <section className="card mb-4 overflow-x-auto">
            <div className="card-h">Hao hụt theo công đoạn, theo lô (cộng dồn đến hết ngày)</div>
            {byWo.size === 0 ? <Empty>Không có lô nào có phiếu hoàn thành hoặc phiếu xuất NVL trong ngày.</Empty> : (
              <table className="tbl">
                <thead><tr><th>Lô · công đoạn</th><th className="num">Vào</th><th className="num">Ra</th><th className="num">Hao hụt</th><th className="num">Định mức vào</th><th className="num">Vượt định mức</th><th>Mức</th><th>Giải trình</th></tr></thead>
                <tbody>{[...byWo.entries()].flatMap(([wo, rows]) => [
                  <tr key={wo} className="bg-sunk"><td colSpan={8}><span className="mono font-medium">{wo}</span> · {rows[0].product_code}</td></tr>,
                  ...rows.map((x) => (
                    <tr key={wo + x.stage}>
                      <td>{x.label}<div className="text-[12px] text-muted">{x.detail}</div></td>
                      <td className="num">{nf(x.in_qty, 2)} {x.uom === 'kg/km' ? 'kg' : x.uom}</td>
                      <td className="num">{nf(x.out_qty, x.uom === 'kg' ? 2 : 1)} {x.uom === 'kg/km' ? 'm' : x.uom}</td>
                      <td className="num">{x.loss_qty === null ? '—' : <>{nf(x.loss_qty, 2)}<div className="text-[12px] text-muted">{nf(x.loss_pct, 2)} %</div></>}</td>
                      <td className="num">{nf(x.norm_in, x.uom === 'kg/km' ? 3 : 2)}{x.uom === 'kg/km' ? <div className="text-[12px] text-muted">kg/km thiết kế</div> : null}</td>
                      <td className="num">{x.var_pct === null ? '—' : `${x.var_pct > 0 ? '+' : ''}${nf(x.var_pct, 2)} %`}<div className="text-[12px] text-muted">ngưỡng {nf(x.tol_pct, 1)} %</div></td>
                      <td><Pill tone={LEVEL[x.level][1]}>{LEVEL[x.level][0]}</Pill></td>
                      <td className="min-w-[220px] text-[12.5px]">
                        {x.note && <div><b>{x.noted_by}</b>: {x.note}</div>}
                        {canNote && (x.level === 'RED' || x.level === 'YELLOW') && (
                          <details open={x.level === 'RED' && !x.note}>
                            <summary className="cursor-pointer text-brand">{x.note ? 'Sửa giải trình' : x.level === 'RED' ? 'Giải trình (bắt buộc)' : 'Ghi chú'}</summary>
                            <form action={saveLossNote} className="mt-1 flex gap-1">
                              <input type="hidden" name="d" value={d} /><input type="hidden" name="wo_id" value={x.wo_id} /><input type="hidden" name="stage" value={x.stage} />
                              <input className="inp" name="note" required defaultValue={x.note ?? ''} placeholder="Nguyên nhân, xử lý" aria-label={`Giải trình ${wo} ${x.label}`} />
                              <SubmitButton className="btn btn-sm">Lưu</SubmitButton>
                            </form>
                          </details>
                        )}
                      </td>
                    </tr>
                  )),
                ])}</tbody>
              </table>
            )}
            <p className="border-t border-line px-4 py-2 text-[12.5px] text-muted">
              Xanh: trong định mức · Vàng: vượt định mức, còn trong ngưỡng · Đỏ: vượt ngưỡng. Vào = NVL cấp − trả kho − để lại máy (theo ngày sản xuất của phiếu lĩnh) hoặc bobin đầu vào đã dùng;
              Ra = bobin đã nhập phiếu hoàn thành. Bobin quấn dở qua đêm chưa có phiếu làm hao hụt tạm tính cao, chốt khi lô xong. Định mức, ngưỡng do TP KT/QA sửa ở Kho → Cài đặt.
            </p>
          </section>

          <div className="grid gap-4 xl:grid-cols-2">
            <section className="card overflow-x-auto">
              <div className="card-h">Sản lượng theo máy</div>
              {r.production.length === 0 ? <Empty>Chưa có phiếu hoàn thành.</Empty> : (
                <table className="tbl">
                  <thead><tr><th>Máy</th><th>Công đoạn</th><th className="num">Bobin</th><th className="num">Mét</th><th className="num">kg</th><th className="num">Phế (kg)</th></tr></thead>
                  <tbody>{r.production.map((x) => (
                    <tr key={x.machine_code + x.op_code}><td className="mono">{x.machine_code}</td><td>{x.op_code} · {x.op_name}</td><td className="num">{x.slips}</td>
                      <td className="num">{nf(x.m)}{x.est ? <div className="text-[12px] text-muted">bện: ước tính</div> : null}</td><td className="num">{nf(x.kg, 1)}</td><td className="num">{nf(x.scrap_kg, 2)}</td></tr>
                  ))}</tbody>
                </table>
              )}
            </section>
            <section className="card overflow-x-auto">
              <div className="card-h">Báo cáo ca</div>
              {r.shifts.length === 0 ? <Empty>Chưa có báo cáo ca.</Empty> : (
                <table className="tbl">
                  <thead><tr><th>Máy</th><th>Trạng thái</th><th className="num">Bobin</th><th className="num">Dừng máy (phút)</th><th className="num">Phế cả ca (kg)</th></tr></thead>
                  <tbody>{r.shifts.map((x) => (
                    <tr key={x.machine_code + (x.shift_code ?? '')}>
                      <td><Link className="link mono" href={`/ghi-nhan-ca?d=${d}&m=${x.machine_code}${x.shift_code ? `&s=${x.shift_code}` : ''}`}>{x.machine_code}</Link><div className="text-[12px] text-muted">{x.machine_name}</div></td>
                      <td><Pill tone={SHIFT_ST[x.status]?.[1] ?? 'mute'}>{SHIFT_ST[x.status]?.[0] ?? x.status}</Pill></td>
                      <td className="num">{x.slips}</td><td className="num">{nf(x.downtime_min)}</td><td className="num">{nf(x.shift_scrap_kg, 2)}</td>
                    </tr>
                  ))}</tbody>
                </table>
              )}
            </section>
            <section className="card overflow-x-auto">
              <div className="card-h"><span>NVL xuất, trả kho theo lô</span><Link className="btn btn-sm" href={`/phieu-xuat-nvl?ngay=${d}`}>Phiếu xuất NVL</Link></div>
              {r.materials.length === 0 ? <Empty>Không có phiếu xuất NVL cho ngày sản xuất này.</Empty> : (
                <table className="tbl">
                  <thead><tr><th>Lô</th><th>Vật tư</th><th className="num">Xuất</th><th className="num">Trả kho</th><th className="num">Còn ở máy / đã dùng</th></tr></thead>
                  <tbody>{r.materials.map((x) => (
                    <tr key={x.wo_no + x.material_code}><td className="mono">{x.wo_no}</td><td><b>{x.material_code}</b><div className="text-[12px] text-muted">{x.material_name}</div></td>
                      <td className="num">{nf(x.issued, 2)} {x.uom}</td><td className="num">{nf(x.returned, 2)}</td><td className="num">{nf(x.issued - x.returned, 2)}</td></tr>
                  ))}</tbody>
                </table>
              )}
            </section>
            <section className="card overflow-x-auto">
              <div className="card-h">NVL để lại máy chạy tiếp cùng lô</div>
              {r.keeps.length === 0 ? <Empty>Không có (theo báo cáo ca).</Empty> : (
                <table className="tbl">
                  <thead><tr><th>Máy</th><th>Vật tư</th><th className="num">kg</th><th>Lô chạy tiếp</th></tr></thead>
                  <tbody>{r.keeps.map((x, i) => (
                    <tr key={i}><td className="mono">{x.machine_code}</td><td>{x.material_code}</td><td className="num">{nf(x.kg, 2)}</td><td className="mono">{x.wo_no}</td></tr>
                  ))}</tbody>
                </table>
              )}
            </section>
          </div>
        </>
      )}
    </>
  );
}
