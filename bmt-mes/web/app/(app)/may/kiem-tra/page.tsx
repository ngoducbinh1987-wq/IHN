import Link from 'next/link';
import { Empty, Flash, Kpi, Pill, StatusPill, Toolbar } from '@/components/ui';
import { M_STATUS, vnToday } from '@/lib/machine';
import { nf } from '@/lib/format';
import { requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Kiểm tra năng lực' };

type Issue = { lvl: 'bad' | 'warn' | 'info'; text: string; hint?: string };
type Mach = { id: string; code: string; name: string; status: string; note: string | null; gross_min: number; maint_min: number; down_min: number; operator: string | null };
type Op = { op_code: string; name: string; req_min: number; cap_min: number; load: number; machines: Mach[] };
type Line = { product_id: string; code: string; description: string; qty_m: number; trial: boolean; issues: { lvl: string; op: string; text: string }[] };
type Result = { workdays: number; shifts: number; ot_hours: number; shift_minutes: number; fill: number; ops: Op[]; lines: Line[]; issues: Issue[]; skipped_ops: string[] };

const endOfMonth = () => { const d = new Date(Date.now() + 7 * 3_600_000); return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0)).toISOString().slice(0, 10); };

export default async function CapacityPage({ searchParams }: {
  searchParams: Promise<{ ke_hoach?: string; tu?: string; den?: string; ca?: string; tang_ca?: string; sp?: string; sl?: string; thu?: string; ok?: string; err?: string }>;
}) {
  const sp = await searchParams;
  await requirePerm('machine', 'view');
  const supabase = await createClient();
  const [{ data: plans }, { data: products }] = await Promise.all([
    supabase.schema('app').from('v_plans').select('id, plan_no, period_label, status, line_count, total_m').order('created_at', { ascending: false }).limit(30),
    supabase.schema('master').from('products').select('id, code, description').eq('active', true).not('current_spec_id', 'is', null).order('code'),
  ]);
  const from = /^\d{4}-\d{2}-\d{2}$/.test(sp.tu ?? '') ? sp.tu! : vnToday();
  const to = /^\d{4}-\d{2}-\d{2}$/.test(sp.den ?? '') ? sp.den! : endOfMonth();
  const shifts = Math.min(3, Math.max(1, Number(sp.ca) || 1));
  const ot = Math.max(0, Math.min(8, Number(String(sp.tang_ca ?? '0').replace(',', '.')) || 0));
  // Đơn thử: thu = "id:mét,id:mét"; thêm dòng mới từ sp + sl
  const trial = (sp.thu ?? '').split(',').filter(Boolean).map((x) => { const [id, q] = x.split(':'); return { product_id: id, qty_m: Number(q) }; })
    .filter((x) => x.product_id && x.qty_m > 0);
  const addQty = Number(String(sp.sl ?? '').replace(/\./g, '').replace(',', '.'));
  if (sp.sp && addQty > 0) trial.push({ product_id: sp.sp, qty_m: addQty });
  const planId = sp.ke_hoach || null;
  const ran = Boolean(planId || trial.length || sp.tu);
  let res: Result | null = null;
  let err: string | undefined;
  if (ran) {
    const { data, error } = await supabase.schema('app').rpc('check_capacity', { p_plan: planId, p_from: from, p_to: to, p_shifts: shifts, p_ot_hours: ot, p_extra: trial });
    if (error) err = error.message; else res = data as Result;
  }
  const qs = (extra: Record<string, string | undefined>) => {
    const p = new URLSearchParams();
    const base: Record<string, string | undefined> = { ke_hoach: planId ?? undefined, tu: from, den: to, ca: String(shifts), tang_ca: ot ? String(ot) : undefined, thu: trial.map((t) => `${t.product_id}:${t.qty_m}`).join(',') || undefined, ...extra };
    Object.entries(base).forEach(([k, v]) => { if (v) p.set(k, v); });
    return `/may/kiem-tra?${p.toString()}`;
  };
  const prodName = (id: string) => (products ?? []).find((p) => p.id === id)?.code ?? id;
  const bad = res?.issues.filter((i) => i.lvl === 'bad').length ?? 0;
  const top = res?.ops.slice().sort((a, b) => b.load - a.load)[0];
  const lost = res?.ops.reduce((s, o) => s + o.machines.reduce((a, m) => a + m.maint_min + m.down_min, 0), 0) ?? 0;

  return (
    <>
      <Toolbar title="Kiểm tra năng lực máy" />
      <div className="mt-4" />
      <Flash ok={sp.ok} err={sp.err ?? err} />
      <form className="card mb-4 grid gap-3 p-4 sm:grid-cols-2 lg:grid-cols-[minmax(0,1.4fr)_150px_150px_110px_110px_auto] lg:items-end">
        {trial.length > 0 && <input type="hidden" name="thu" value={trial.map((t) => `${t.product_id}:${t.qty_m}`).join(',')} />}
        <label className="lbl">Kế hoạch sản xuất
          <select name="ke_hoach" className="inp" defaultValue={planId ?? ''}>
            <option value="">Không chọn (chỉ đơn thử)</option>
            {(plans ?? []).map((p) => <option key={p.id} value={p.id}>{p.plan_no} – {p.period_label} · {p.line_count} SKU · {nf(p.total_m)} m</option>)}
          </select>
        </label>
        <label className="lbl">Từ ngày<input type="date" name="tu" className="inp" defaultValue={from} /></label>
        <label className="lbl">Đến ngày<input type="date" name="den" className="inp" defaultValue={to} /></label>
        <label className="lbl">Số ca<select name="ca" className="inp" defaultValue={String(shifts)}><option value="1">1 ca</option><option value="2">2 ca</option><option value="3">3 ca</option></select></label>
        <label className="lbl">Tăng ca (giờ/ngày)<input name="tang_ca" className="inp" inputMode="decimal" defaultValue={ot || ''} placeholder="0" /></label>
        <button className="btn btn-pri" type="submit">Kiểm tra</button>
      </form>

      <section className="card mb-4">
        <div className="card-h">Thử thêm đơn hàng<span className="text-[13px] font-normal text-muted">Xem xưởng có nhận được không trước khi báo khách. Không ghi vào kế hoạch.</span></div>
        <form className="grid gap-3 p-4 sm:grid-cols-[minmax(0,1fr)_160px_auto] sm:items-end">
          {Object.entries({ ke_hoach: planId ?? '', tu: from, den: to, ca: String(shifts), tang_ca: ot ? String(ot) : '', thu: trial.map((t) => `${t.product_id}:${t.qty_m}`).join(',') })
            .map(([k, v]) => v ? <input key={k} type="hidden" name={k} value={v} /> : null)}
          <label className="lbl">Sản phẩm<select name="sp" className="inp" required defaultValue="">
            <option value="" disabled>Chọn mã sản phẩm</option>{(products ?? []).map((p) => <option key={p.id} value={p.id}>{p.code} · {p.description}</option>)}
          </select></label>
          <label className="lbl">Số mét<input name="sl" className="inp" inputMode="numeric" required placeholder="60.000" /></label>
          <button className="btn btn-soft" type="submit">Thêm đơn thử</button>
        </form>
        {trial.length > 0 && (
          <div className="flex flex-wrap items-center gap-2 border-t border-line px-4 py-3 text-[13.5px]">
            <span className="text-muted">Đơn thử:</span>
            {trial.map((t, i) => <Pill key={i} tone="info">{prodName(t.product_id)} · {nf(t.qty_m)} m</Pill>)}
            <Link className="btn btn-sm" href={qs({ thu: undefined })}>Bỏ đơn thử</Link>
          </div>
        )}
      </section>

      {!ran && <div className="card"><Empty>Chọn kế hoạch và khoảng ngày rồi bấm “Kiểm tra”, hoặc thêm đơn thử.</Empty></div>}
      {res && (
        <>
          <div className="mb-4 grid grid-cols-2 gap-3 md:grid-cols-4">
            <Kpi label="Ngày làm việc" value={res.workdays} hint={`${res.shifts} ca × ${nf(res.shift_minutes)} phút${res.ot_hours ? ` + tăng ca ${nf(res.ot_hours, 1)} giờ` : ''} · xếp ${Math.round(res.fill * 100)}%`} />
            <Kpi label="Công đoạn tải cao nhất" value={top ? `${Math.round(top.load * 100)}%` : '—'} hint={top?.name} tone={top && top.load > 1 ? 'bad' : top && top.load >= 0.85 ? 'warn' : 'ok'} />
            <Kpi label="Giờ máy trừ do bảo dưỡng, hỏng" value={nf(lost / 60)} hint="Cả xưởng trong kỳ" tone="info" />
            <Kpi label="Cảnh báo đỏ" value={bad} hint={bad ? 'Giám đốc chưa duyệt được kế hoạch' : 'Duyệt được'} tone={bad ? 'bad' : 'ok'} />
          </div>
          {res.shifts > 1 && (
            <div role="note" className="mb-4 rounded border-l-4 border-warn bg-warn-soft px-4 py-2.5 text-[14px]">
              Chạy {res.shifts} ca cần tuyển thêm người theo mục 11 Quy chuẩn nhân sự (thêm tổ trưởng và 4–5 công nhân mỗi ca). Bộ máy 12 người hiện tại chỉ đủ 1 ca.
            </div>
          )}

          <section className="card mb-4 overflow-x-auto">
            <div className="card-h">Năng lực từng công đoạn<span className="text-[13px] font-normal text-muted">vạch đứng = 85%</span></div>
            {res.ops.length ? (
              <table className="tbl">
                <thead><tr><th>Công đoạn</th><th>Máy</th><th className="num">Giờ cần</th><th className="num">Giờ có</th><th className="min-w-[200px]">Tải</th></tr></thead>
                <tbody>
                  {res.ops.map((o) => {
                    const tone = o.load > 1 ? 'bg-bad' : o.load >= 0.85 ? 'bg-warn' : 'bg-brand';
                    return (
                      <tr key={o.op_code}>
                        <td>{o.name}</td>
                        <td><div className="flex flex-col gap-1">{o.machines.map((m) => (
                          <span key={m.id} className="flex flex-wrap items-center gap-1.5 text-[13px]"><Link className="link" href={`/may/${m.id}`}>{m.code}</Link><StatusPill map={M_STATUS} value={m.status} />
                            <span className="text-muted">{m.operator ?? 'chưa có người đứng'}{m.maint_min ? ` · bảo dưỡng −${nf(m.maint_min / 60, 1)} h` : ''}{m.down_min ? ` · hỏng −${nf(m.down_min / 60, 1)} h` : ''}</span></span>
                        ))}</div></td>
                        <td className="num">{nf(o.req_min / 60)}</td><td className="num">{nf(o.cap_min / 60)}</td>
                        <td><div className="flex items-center gap-2">
                          <div className="relative h-2.5 flex-1 overflow-hidden rounded bg-todo"><div className={`h-full ${tone}`} style={{ width: `${Math.min(100, o.load * 100)}%` }} /><span className="absolute inset-y-0 w-0.5 bg-ink/40" style={{ left: '85%' }} /></div>
                          <b className="w-12 text-right font-medium tabular-nums">{Math.round(o.load * 100)}%</b></div></td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            ) : <Empty>Chưa có dây chuyền nào khai công đoạn.</Empty>}
            {res.skipped_ops.length > 0 && <p className="px-4 pb-3 text-[12.5px] text-muted">Chưa khai báo máy nên chưa kiểm tra: {res.skipped_ops.join(', ')}.</p>}
          </section>

          <section className="card mb-4">
            <div className="card-h">Cảnh báo<span className="text-[13px] font-normal text-muted">{res.issues.length}</span></div>
            {res.issues.length ? (
              <ul className="flex flex-col gap-2 p-4">
                {res.issues.map((i, k) => (
                  <li key={k} className={`rounded border-l-4 px-3 py-2 text-[14px] ${i.lvl === 'bad' ? 'border-bad bg-bad-soft' : i.lvl === 'warn' ? 'border-warn bg-warn-soft' : 'border-info bg-info-soft'}`}>
                    <div className="font-medium">{i.text}</div>{i.hint && <div className="text-[13.5px]">{i.hint}</div>}
                  </li>
                ))}
              </ul>
            ) : <Empty>Không có cảnh báo. Kế hoạch nằm trong năng lực máy.</Empty>}
          </section>

          <section className="card overflow-x-auto">
            <div className="card-h">Từng sản phẩm</div>
            {res.lines.length ? (
              <table className="tbl">
                <thead><tr><th>Mã</th><th>Sản phẩm</th><th className="num">Mét</th><th>Kết quả</th></tr></thead>
                <tbody>
                  {res.lines.map((l, i) => (
                    <tr key={i}>
                      <td className="mono font-medium">{l.code}{l.trial && <> <Pill tone="info">Đơn thử</Pill></>}</td><td>{l.description}</td><td className="num">{nf(l.qty_m)}</td>
                      <td>{l.issues.length ? l.issues.map((x, k) => <div key={k} className="text-[13.5px] text-bad">{x.op}: {x.text}</div>) : <Pill tone="ok">Làm được</Pill>}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            ) : <Empty>Kế hoạch chưa có dòng sản phẩm.</Empty>}
            <p className="px-4 py-3 text-[12.5px] text-muted">Kiểm tra theo tổng giờ máy trong kỳ. Kiểm tra hạn giao từng lệnh sẽ có khi làm module Lịch máy, lệnh sản xuất ngày.</p>
          </section>
        </>
      )}
    </>
  );
}
