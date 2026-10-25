import { Bar, FinishPill, dd } from '@/components/kh';
import { Empty, Flash, Kpi, Pill, Toolbar } from '@/components/ui';
import { loadKh } from '@/lib/kh/load';
import { DT_REASONS } from '@/lib/kh/shift';
import { addDays, dayIndex, shiftPlan, toMin } from '@/lib/kh/scheduler';
import { nf } from '@/lib/format';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Kế hoạch – Thực tế' };

type Rep = { work_date: string; shift_code: string; machine_code: string; status: string; lines: { key?: string; declared_m?: number; plc_m?: number | null }[];
  downtime: { min: number; reason: string }[]; scrap_kg: number; samples: { status: string }[] };

export default async function KhThucTe({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const me = await requireMe();
  const db = await createClient();
  const kh = await loadKh(db, { plan: sp.plan, roles: me.roles });
  const today = kh.now.date;
  const dow = (new Date(today + 'T00:00:00Z').getUTCDay() + 6) % 7;
  const okDate = (v?: string) => (v && /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : null);
  const to = okDate(sp.to) ?? today;
  const from = okDate(sp.from) ?? (kh.cal.base > addDays(today, -dow) ? kh.cal.base : addDays(today, -dow));
  const { data } = await db.schema('app').from('v_kh_reports').select('work_date, shift_code, machine_code, status, lines, downtime, scrap_kg, samples').gte('work_date', from).lte('work_date', to);
  const reps = (data ?? []) as Rep[];
  const counted = reps.filter((r) => r.status !== 'DRAFT');
  const S = kh.cal.S, SPD = kh.cal.SPD;
  const shiftEnd = (j: number) => { const s = kh.cal.shifts[j]; return s ? toMin(s.start_time) + kh.cal.RUN + Number(s.break_min) : 1440; };

  // Kế hoạch của các ca đã kết thúc trong khoảng (hoặc đã có báo cáo)
  const per = kh.machines.map((m) => ({ m, p: 0, a: 0, runMin: 0, need: 0, confirmed: 0, dt: 0 }));
  if (kh.sch) {
    const d0 = Math.max(0, dayIndex(kh.cal, from)), d1 = dayIndex(kh.cal, addDays(to, 1));
    for (let di = d0; di < d1 && di < kh.cal.days.length; di++) {
      const date = kh.cal.days[di];
      for (let j = 0; j < SPD; j++) {
        const code = kh.cal.shifts[j].code;
        for (const x of per) {
          const rep = reps.find((r) => r.work_date === date && r.shift_code === code && r.machine_code === x.m.code);
          const ended = date < today || (date === today && kh.now.min >= shiftEnd(j));
          if (!ended && !rep) continue;
          const rows = shiftPlan(kh.sch.byMachine.get(x.m.code) ?? [], di * SPD + j, S);
          if (!rows.length) continue;
          x.p += rows.reduce((a, r) => a + r.m, 0);
          x.runMin += rows.reduce((a, r) => a + r.run, 0) * (kh.cal.RUN / S);
          x.need++;
          if (rep?.status === 'CONFIRMED') x.confirmed++;
        }
      }
    }
  }
  for (const r of counted) {
    const x = per.find((y) => y.m.code === r.machine_code);
    if (!x) continue;
    x.a += r.lines.reduce((a, l) => a + Number(l.declared_m ?? l.plc_m ?? 0), 0);
  }
  for (const r of reps) { const x = per.find((y) => y.m.code === r.machine_code); if (x) x.dt += r.downtime.reduce((a, d) => a + Number(d.min), 0); }
  const P = per.reduce((a, x) => a + x.p, 0), A = per.reduce((a, x) => a + x.a, 0);
  const need = per.reduce((a, x) => a + x.need, 0), conf = per.reduce((a, x) => a + x.confirmed, 0);
  const runAll = per.reduce((a, x) => a + x.runMin, 0);
  const byR: Record<string, number> = {};
  reps.forEach((r) => r.downtime.forEach((d) => { const k = d.reason || 'NONE'; byR[k] = (byR[k] ?? 0) + Number(d.min); }));
  const rs = Object.entries(byR).sort((a, b) => b[1] - a[1]);
  const maxR = rs[0]?.[1] ?? 1;
  const brk = byR.DT_BREAKDOWN ?? 0;
  const scrap = reps.reduce((a, r) => a + Number(r.scrap_kg ?? 0), 0);
  const samp = reps.flatMap((r) => r.samples ?? []);
  const sOk = samp.filter((s) => s.status === 'OK').length, sNg = samp.filter((s) => s.status === 'NG').length;
  const withDue = kh.orders.filter((o) => o.due);
  const onTime = withDue.filter((o) => { const f = kh.fin.get(o.id); return f?.placed && (f.slack ?? -1) >= 0; }).length;
  const risk = kh.orders.filter((o) => { const f = kh.fin.get(o.id); return f && (!f.placed || (f.slack !== null && f.slack <= 1)); });
  const tone = (v: number, good: number, warn: number) => (v >= good ? 'ok' : v >= warn ? 'warn' : 'bad') as 'ok' | 'warn' | 'bad';

  return (
    <>
      <Toolbar title="Kế hoạch – Thực tế" reload={`/kh-thuc-te?from=${from}&to=${to}`}
        actions={<form action="/kh-thuc-te" className="flex flex-wrap items-center gap-1.5">
          <input type="date" name="from" defaultValue={from} className="inp w-[150px] py-1" aria-label="Từ ngày" />
          <span className="text-muted">→</span>
          <input type="date" name="to" defaultValue={to} className="inp w-[150px] py-1" aria-label="Đến ngày" />
          <button className="btn btn-sm">Xem</button>
        </form>} />
      <div className="mt-3 text-[13px] text-muted">Từ {dd(from)} đến {dd(to)} · {kh.planNo || 'chưa có kế hoạch'} · chỉ tiêu xếp theo người chịu trách nhiệm trong Quy chuẩn · kế hoạch chỉ tính các ca đã kết thúc</div>
      <div className="mt-3"><Flash ok={sp.ok} err={sp.err} /></div>
      {!kh.sch ? <div className="card"><Empty>Chưa có lịch máy để so sánh.</Empty></div> : (
        <div className="flex flex-col gap-4">
          <Group title="Quản lý SX">
            <Kpi label="Hoàn thành kế hoạch" value={P ? `${Math.round((A / P) * 100)}%` : '—'} hint={`mục tiêu ≥ 95% · ${nf(A / 1000, 1)} / ${nf(P / 1000, 1)} km`} tone={P ? tone(A / P, 0.95, 0.85) : undefined} />
            <Kpi label="Báo cáo ca đã xác nhận" value={`${conf}/${need}`} hint="ca-máy có kế hoạch · mục tiêu 100% trước khi hết ca" tone={need ? tone(conf / need, 1, 0.8) : undefined} />
            <Kpi label="Phế phẩm" value={`${nf(scrap, 1)} kg`} hint="so định mức TP Kỹ thuật/QA ban hành" />
          </Group>
          <Group title="TP Kỹ thuật/QA">
            <Kpi label="Dừng máy do hỏng" value={runAll ? `${nf((brk / runAll) * 100, 1)}%` : '—'} hint={`${nf(brk)} phút / thời gian chạy · mục tiêu ≤ 3%`} tone={runAll ? (brk / runAll <= 0.03 ? 'ok' : 'bad') : undefined} />
            <Kpi label="Mẫu đầu ca, đầu mã" value={`${sOk} đạt`} hint={`${sNg} không đạt · ${samp.length - sOk - sNg} chờ duyệt`} tone={sNg ? 'warn' : 'ok'} />
          </Group>
          <Group title="Giám đốc">
            <Kpi label="Sản lượng so kế hoạch" value={P ? `${Math.round((A / P) * 100)}%` : '—'} hint="trong khoảng đang xem · mục tiêu ≥ 95%" tone={P ? tone(A / P, 0.95, 0.85) : undefined} />
            <Kpi label="Giao hàng đúng hạn (dự báo)" value={withDue.length ? `${Math.round((onTime / withDue.length) * 100)}%` : '—'} hint={`${withDue.length - onTime} lệnh dự kiến trễ · ${kh.orders.length - withDue.length} lệnh chưa có hạn giao`} tone={withDue.length ? tone(onTime / withDue.length, 0.95, 0.8) : undefined} />
          </Group>

          <section className="card">
            <div className="card-h"><h2>Theo máy</h2><span className="text-[13px] font-normal text-muted">thực tế ÷ kế hoạch</span></div>
            <div className="overflow-x-auto"><table className="tbl">
              <thead><tr><th>Máy</th><th>Người</th><th className="num">KH (m)</th><th className="num">TT (m)</th><th className="min-w-[160px]">Đạt</th><th className="num">Báo cáo xác nhận</th><th className="num">Dừng</th></tr></thead>
              <tbody>{per.map((x) => (
                <tr key={x.m.code}><td><b>{x.m.code}</b><div className="text-[12px] text-muted">{x.m.name}</div></td><td className="text-[12.5px]">{x.m.operators.join(', ')}</td>
                  <td className="num">{x.p ? nf(x.p) : '—'}</td><td className="num">{x.a ? nf(x.a) : '—'}</td>
                  <td>{x.p ? <Bar value={x.a / x.p} mark={0.95} /> : <span className="text-[12.5px] text-muted">Không có kế hoạch</span>}</td>
                  <td className="num">{x.need ? `${x.confirmed}/${x.need}` : '—'}</td><td className="num">{x.dt ? `${x.dt}′` : '—'}</td></tr>
              ))}</tbody>
            </table></div>
            <p className="px-4 py-3 text-[12.5px] text-muted">Vạch đen là 95%. Đạt trên 100% là bình thường vì kế hoạch đã chừa {100 - kh.cfg.fill_pct}% dự phòng mỗi ca. Thực tế tính báo cáo đã gửi hoặc đã xác nhận.</p>
          </section>

          <section className="card">
            <div className="card-h"><h2>Dừng máy theo lý do</h2><span className="text-[13px] font-normal text-muted">phút</span></div>
            <div className="flex flex-col gap-3 px-4 py-3">
              {rs.length ? rs.map(([k, v]) => (
                <div key={k}>
                  <div className="flex justify-between text-[13px]"><span>{k === 'NONE' ? <b className="text-bad">Chưa chọn lý do</b> : DT_REASONS[k] ?? k}{k === 'DT_BREAKDOWN' ? ' · TP Kỹ thuật/QA chịu trách nhiệm' : ''}</span><b className="tabular-nums">{v}</b></div>
                  <div className="h-2.5 overflow-hidden rounded bg-todo"><i className={`block h-full ${k === 'NONE' ? 'bg-bad' : ['DT_BREAKDOWN', 'DT_MATERIAL', 'DT_POWER'].includes(k) ? 'bg-warn' : 'bg-info'}`} style={{ width: `${(v / maxR) * 100}%` }} /></div>
                </div>
              )) : <div className="text-[13px] text-muted">Chưa có lần dừng nào được ghi.</div>}
              <div className="text-[12.5px] text-muted">Vàng: dừng ngoài kế hoạch (hỏng máy, chờ vật tư, mất điện). Xanh: dừng trong định mức (thay khuôn, đổi màu, chờ QC…).</div>
            </div>
          </section>

          <section className="card">
            <div className="card-h"><h2>Lệnh cần theo dõi</h2></div>
            <div className="overflow-x-auto"><table className="tbl">
              <thead><tr><th>Dòng</th><th>Sản phẩm</th><th className="num">Hạn giao</th><th className="num">Dự kiến xong</th><th>Tình trạng</th><th>Việc cần làm</th></tr></thead>
              <tbody>{risk.length ? risk.map((o) => {
                const f = kh.fin.get(o.id)!;
                return (
                  <tr key={o.id}><td className="mono">{o.label}{o.prio === 0 && <> <Pill tone="bad">Gấp</Pill></>}</td><td><b>{o.product_code}</b><div className="text-[12px] text-muted">{o.source}</div></td>
                    <td className="num">{dd(o.due)}</td><td className="num">{dd(f.finDate)}</td><td><FinishPill {...f} due={o.due} /></td>
                    <td className="text-[12.5px]">{!f.placed || (f.slack ?? 0) < 0 ? 'Giám đốc chọn phương án: bật ca B, thêm người, mua bán thành phẩm hoặc chốt lại ngày giao' : 'Quản lý SX theo dõi, không chèn lệnh khác trước lệnh này'}</td></tr>
                );
              }) : <tr><td colSpan={6} className="text-[13px] text-muted">Không có lệnh trễ hoặc sát hạn.</td></tr>}</tbody>
            </table></div>
          </section>
        </div>
      )}
    </>
  );
}

function Group({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div>
      <div className="mb-2 text-[12.5px] font-medium uppercase tracking-wide text-muted">{title}</div>
      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">{children}</div>
    </div>
  );
}
