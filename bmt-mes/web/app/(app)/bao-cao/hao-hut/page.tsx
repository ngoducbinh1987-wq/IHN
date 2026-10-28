import Link from 'next/link';
import { redirect } from 'next/navigation';
import { Empty, Kpi, Pill, Tabs, Toolbar } from '@/components/ui';
import { df, nf } from '@/lib/format';
import { SCRAP_CAT } from '@/lib/kho';
import { can, requireMe, requirePage } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Báo cáo hao hụt' };

type Wo = {
  wo_id: string; wo_no: string; wo_status: string; product_code: string; product_name: string; good_m: number; qty_m: number;
  issued_kg: number; norm_kg: number | null; var_kg: number | null; var_pct: number | null;
  fg_kg: number; fg_theory_kg: number; weighed_km: number; kgkm_theory: number | null; kgkm_actual: number | null; giveaway_kg: number; giveaway_pct: number | null;
  startup_kg: number; quality_kg: number; tail_kg: number; other_scrap_kg: number; overlength_m: number; overlength_kg: number; wip_kg: number; unexplained_kg: number;
  cu_issued: number; cu_fg: number; cu_scrap: number; cu_cable: number | null; cu_wip: number; cu_diff: number; cu_diff_pct: number | null; cu_ok: boolean | null; last_activity: string;
};
type Scrap = { reason_code: string; reason_name: string | null; category: string; op_code: string; machine_code: string | null; scrap_code: string; kg: number; times: number };
type MatRow = { material_code: string; material_name: string; uom: string; group_code: string; norm: number; issued: number; returned: number; net: number; var: number; var_pct: number | null; over_tol: boolean };

const isDate = (s?: string) => !!s && /^\d{4}-\d{2}-\d{2}$/.test(s);
const sum = <T,>(rows: T[], f: (r: T) => number | null | undefined) => rows.reduce((s, r) => s + Number(f(r) ?? 0), 0);
const pct = (a: number, b: number) => (b ? (a / b) * 100 : null);
const OP_NAMES: Record<string, string> = {
  CD0: 'Phối trộn silicone', CD1: 'Bện ruột dẫn', CD2: 'Bọc cách điện', CD3: 'Xoắn cặp / ghép lõi', CD4: 'Quấn băng chống nhiễu', CD5: 'Bọc vỏ + in', CD6: 'Kiểm tra + đóng gói',
};

function Bar({ label, kg, max, tone, hint }: { label: string; kg: number; max: number; tone: string; hint?: string }) {
  const w = max > 0 ? Math.max(0, Math.min(100, (kg / max) * 100)) : 0;
  return (
    <div className="grid grid-cols-[minmax(140px,190px)_1fr_auto] items-center gap-3 py-1.5">
      <div className="text-[13.5px] leading-tight">{label}{hint && <div className="text-[12px] text-muted">{hint}</div>}</div>
      <div className="h-4 rounded-sm bg-sunk"><div className={`h-4 rounded-sm ${tone}`} style={{ width: `${w}%` }} /></div>
      <div className="w-24 text-right text-[13.5px] font-medium tabular-nums">{nf(kg, 1)} kg</div>
    </div>
  );
}

export default async function LossReport({ searchParams }: { searchParams: Promise<{ tu?: string; den?: string; wo?: string; tab?: string }> }) {
  const sp = await searchParams;
  await requirePage('bc-hao-hut');
  const me = await requireMe();
  if (!can(me, 'production', 'view') && !can(me, 'inventory', 'view') && !can(me, 'cost', 'view')) redirect('/?err=' + encodeURIComponent('Không có quyền xem báo cáo hao hụt'));
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Ho_Chi_Minh' });
  const from = isDate(sp.tu) ? sp.tu! : `${today.slice(0, 8)}01`;
  const to = isDate(sp.den) ? sp.den! : today;
  const tab = ['lenh', 'dong', 'phe'].includes(sp.tab ?? '') ? sp.tab! : 'tong';
  const supabase = await createClient();
  const [{ data: woData, error }, { data: scrapData }, { data: setData }] = await Promise.all([
    supabase.schema('app').rpc('loss_by_wo', { p_from: from, p_to: to }),
    supabase.schema('app').rpc('loss_scrap', { p_from: from, p_to: to }),
    supabase.schema('app').from('v_inv_settings').select('key, num_value').in('key', ['copper_tol_pct', 'giveaway_tol_pct', 'material_tol_pct']),
  ]);
  const wos = (woData ?? []) as Wo[];
  const scraps = (scrapData ?? []) as Scrap[];
  const tol = (k: string, d: number) => Number((setData ?? []).find((s) => s.key === k)?.num_value ?? d);
  const cuTol = tol('copper_tol_pct', 1), gaTol = tol('giveaway_tol_pct', 2), matTol = tol('material_tol_pct', 3);
  const qs = (extra: Record<string, string | undefined>) => {
    const p = new URLSearchParams({ tu: from, den: to });
    for (const [k, v] of Object.entries(extra)) if (v) p.set(k, v);
    return `/bao-cao/hao-hut?${p.toString()}`;
  };

  // Tổng kỳ
  const issued = sum(wos, (r) => r.issued_kg);
  const norm = sum(wos.filter((r) => r.norm_kg !== null), (r) => r.norm_kg);
  const issuedNormed = sum(wos.filter((r) => r.norm_kg !== null), (r) => r.issued_kg);
  const giveaway = sum(wos, (r) => r.giveaway_kg);
  const cats = {
    giveaway: Math.max(giveaway, 0),
    startup: sum(wos, (r) => r.startup_kg),
    quality: sum(wos, (r) => r.quality_kg),
    tail: sum(wos, (r) => r.tail_kg),
    overlength: sum(wos, (r) => r.overlength_kg),
  };
  const other = sum(wos, (r) => r.other_scrap_kg);
  const unexplained = sum(wos, (r) => r.unexplained_kg);
  const totalLoss = cats.giveaway + cats.startup + cats.quality + cats.tail + cats.overlength + other;
  const maxBar = Math.max(...Object.values(cats), other, Math.abs(unexplained), 1);
  const weighedTheory = sum(wos, (r) => (r.kgkm_theory ?? 0) * r.weighed_km);
  const gaPct = pct(giveaway, weighedTheory);
  const cuBad = wos.filter((r) => r.cu_ok === false);
  const cuIssued = sum(wos, (r) => r.cu_issued), cuDiff = sum(wos, (r) => r.cu_diff);
  const noWeigh = wos.filter((r) => r.good_m > 0 && r.weighed_km === 0).length;

  // Pareto phế theo nguyên nhân
  const byReason = [...scraps.reduce((m, s) => {
    const k = s.reason_code ?? 'KHAC';
    const cur = m.get(k) ?? { code: k, name: s.reason_name ?? k, category: s.category, kg: 0, times: 0 };
    cur.kg += Number(s.kg); cur.times += Number(s.times);
    return m.set(k, cur);
  }, new Map<string, { code: string; name: string; category: string; kg: number; times: number }>()).values()].sort((a, b) => b.kg - a.kg);
  const scrapTotal = sum(byReason, (r) => r.kg);
  const byMachine = [...scraps.reduce((m, s) => {
    const k = `${s.op_code}|${s.machine_code ?? '—'}`;
    return m.set(k, (m.get(k) ?? 0) + Number(s.kg));
  }, new Map<string, number>()).entries()].map(([k, kg]) => ({ op: k.split('|')[0], machine: k.split('|')[1], kg })).sort((a, b) => b.kg - a.kg);

  // Chi tiết một lệnh
  let detail: { wo: Wo | undefined; mats: MatRow[] } | null = null;
  if (sp.wo && /^[0-9a-f-]{36}$/i.test(sp.wo)) {
    const { data } = await supabase.schema('app').rpc('loss_wo_materials', { p_wo: sp.wo });
    detail = { wo: wos.find((w) => w.wo_id === sp.wo), mats: (data ?? []) as MatRow[] };
  }

  return (
    <>
      <Toolbar title="Báo cáo hao hụt" reload={qs({ tab: tab === 'tong' ? undefined : tab, wo: sp.wo })} />
      <form className="card mb-4 mt-4 flex flex-wrap items-end gap-3 p-3" action="/bao-cao/hao-hut">
        {tab !== 'tong' && <input type="hidden" name="tab" value={tab} />}
        <label className="lbl">Từ ngày<input className="inp" type="date" name="tu" defaultValue={from} /></label>
        <label className="lbl">Đến ngày<input className="inp" type="date" name="den" defaultValue={to} /></label>
        <button className="btn btn-pri" type="submit">Xem</button>
        <span className="text-[12.5px] text-muted">Tính theo các lệnh SX có cấp, trả NVL, ghi phế hoặc đầu ra trong kỳ.</span>
      </form>
      {error && <div className="card mb-4 p-4 text-bad">{error.message}</div>}

      <div className="mb-4 grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">
        <Kpi label="NVL vào cáp đã cấp (net)" value={`${nf(issued)} kg`} hint={`${wos.length} lệnh SX`} />
        <Kpi label="Tiêu hao so định mức" value={issuedNormed && norm ? `${nf(pct(issuedNormed - norm, norm), 1)}%` : '—'}
          hint={norm ? `${nf(issuedNormed - norm)} kg so ${nf(norm)} kg định mức` : 'Chưa có mét đạt'} tone={norm && pct(issuedNormed - norm, norm)! > matTol ? 'bad' : undefined} />
        <Kpi label="Tổng hao hụt nhận diện" value={`${nf(totalLoss)} kg`} hint={issued ? `${nf(pct(totalLoss, issued), 1)}% NVL cấp` : undefined} tone={totalLoss > 0 ? 'warn' : undefined} />
        <Kpi label="Vượt dày (cân so lý thuyết)" value={gaPct === null ? '—' : `${nf(gaPct, 1)}%`} hint={`ngưỡng ${nf(gaTol, 1)}% · ${nf(giveaway)} kg`}
          tone={gaPct !== null && gaPct > gaTol ? 'bad' : gaPct !== null && gaPct < 0 ? 'warn' : undefined} />
        <Kpi label="Lệnh lệch cân bằng đồng" value={cuBad.length} hint={cuIssued ? `lệch ${nf(pct(cuDiff, cuIssued), 2)}% · ngưỡng ±${nf(cuTol, 1)}%` : `ngưỡng ±${nf(cuTol, 1)}%`}
          tone={cuBad.length ? 'bad' : undefined} href={qs({ tab: 'dong' })} />
        <Kpi label="Chưa giải thích được" value={`${nf(unexplained)} kg`} hint={issued ? `${nf(pct(unexplained, issued), 1)}% NVL cấp` : undefined}
          tone={issued && Math.abs(pct(unexplained, issued)!) > matTol ? 'bad' : undefined} />
      </div>

      <Tabs active={tab} items={[
        { key: 'tong', label: 'Tổng hợp 5 nhóm', href: qs({}) },
        { key: 'lenh', label: 'Theo lệnh SX', href: qs({ tab: 'lenh' }), count: wos.length },
        { key: 'dong', label: 'Cân bằng đồng', href: qs({ tab: 'dong' }), count: cuBad.length || undefined },
        { key: 'phe', label: 'Pareto phế', href: qs({ tab: 'phe' }) },
      ]} />

      {tab === 'tong' && (
        <div className="grid gap-4 xl:grid-cols-[3fr_2fr]">
          <section className="card">
            <div className="card-h">Hao hụt theo 5 nhóm nguyên nhân</div>
            {wos.length ? (
              <div className="p-4">
                <Bar label="1. Vượt dày" hint="cáp nặng hơn lý thuyết – cho khách" kg={cats.giveaway} max={maxBar} tone="bg-bad" />
                <Bar label="2. Khởi động, đổi mã, xả máy" kg={cats.startup} max={maxBar} tone="bg-warn" />
                <Bar label="3. Lỗi chất lượng" hint="OD, đánh thủng, đứt, in" kg={cats.quality} max={maxBar} tone="bg-warn" />
                <Bar label="4. Đầu đuôi, chiều dài" kg={cats.tail} max={maxBar} tone="bg-info" />
                <Bar label="5. Giao dư mét" hint={`${nf(sum(wos, (r) => r.overlength_m))} m dư trên bobin`} kg={cats.overlength} max={maxBar} tone="bg-info" />
                <Bar label="Phế khác" kg={other} max={maxBar} tone="bg-muted" />
                <div className="mt-2 border-t border-line pt-2">
                  <Bar label="Chưa giải thích được" hint="cấp − thành phẩm − phế − BTP dở" kg={unexplained} max={maxBar} tone={unexplained < 0 ? 'bg-info' : 'bg-bad'} />
                </div>
                {gaPct !== null && gaPct < 0 && <p className="mt-2 text-[13px] text-warn">Cáp nhẹ hơn lý thuyết {nf(-giveaway)} kg: kiểm tra độ dày tối thiểu theo spec, không chỉ là tiết kiệm.</p>}
                {noWeigh > 0 && <p className="mt-2 text-[13px] text-warn">{noWeigh} lệnh có mét đạt nhưng chưa cân bobin thành phẩm – nhóm vượt dày tính thiếu.</p>}
                {unexplained < 0 && <p className="mt-2 text-[13px] text-muted">Chưa giải thích âm: ghi nhận thành phẩm/phế nhiều hơn NVL cấp – thường do cấp NVL chưa ghi đủ hoặc BTP lệnh trước chuyển sang.</p>}
              </div>
            ) : <Empty>Không có lệnh SX nào hoạt động trong kỳ.</Empty>}
          </section>
          <section className="card">
            <div className="card-h">Cách đọc</div>
            <ul className="list-disc space-y-1.5 py-3 pl-8 pr-4 text-[13.5px]">
              <li><b>Vượt dày</b> = kg cân thành phẩm − mét × kg/km lý thuyết. Lớn nhất về tiền, xử lý bằng chỉnh độ dày về sát dung sai dưới.</li>
              <li><b>Khởi động, lỗi, đầu đuôi</b> lấy từ phiếu ghi phế tại máy (mã nguyên nhân). Xem tab Pareto để biết máy và nguyên nhân nào nhiều nhất.</li>
              <li><b>Giao dư mét</b> = mét trên bobin vượt chiều dài chuẩn đóng gói.</li>
              <li><b>Cân bằng đồng</b>: đồng cấp = đồng trong cáp + phế đồng + đồng trong BTP. Lệch quá ±{nf(cuTol, 1)}% → kiểm tra cân, phiếu cấp, phế chưa ghi.</li>
              <li><b>Tiêu hao so định mức</b> tính trên mét đạt, ngưỡng {nf(matTol, 1)}%.</li>
            </ul>
          </section>
        </div>
      )}

      {tab === 'lenh' && (
        <section className="card overflow-x-auto">
          {wos.length ? (
            <table className="tbl">
              <thead><tr><th>Lệnh SX</th><th>Sản phẩm</th><th className="num">Mét đạt</th><th className="num">NVL cấp (kg)</th><th className="num">Định mức (kg)</th><th className="num">Lệch ĐM</th>
                <th className="num">Vượt dày</th><th className="num">Phế (kg)</th><th className="num">Dư mét</th><th className="num">BTP dở (kg)</th><th className="num">Chưa giải thích</th><th>Đồng</th><th>Cập nhật</th></tr></thead>
              <tbody>{wos.map((r) => {
                const scrap = Number(r.startup_kg) + Number(r.quality_kg) + Number(r.tail_kg) + Number(r.other_scrap_kg);
                return (
                  <tr key={r.wo_id} className={sp.wo === r.wo_id ? 'bg-brand-soft/60' : undefined}>
                    <td><Link className="link mono" href={qs({ tab: 'lenh', wo: r.wo_id })}>{r.wo_no}</Link></td>
                    <td><span className="mono">{r.product_code}</span></td>
                    <td className="num">{nf(r.good_m)}<div className="text-[12px] text-muted">/ {nf(r.qty_m)}</div></td>
                    <td className="num">{nf(r.issued_kg, 1)}</td><td className="num">{nf(r.norm_kg, 1)}</td>
                    <td className={`num ${r.var_pct !== null && r.var_pct > matTol ? 'font-medium text-bad' : ''}`}>{r.var_pct === null ? '—' : `${nf(r.var_pct, 1)}%`}</td>
                    <td className={`num ${r.giveaway_pct !== null && r.giveaway_pct > gaTol ? 'font-medium text-bad' : ''}`}>{r.giveaway_pct === null ? '—' : `${nf(r.giveaway_pct, 1)}%`}<div className="text-[12px] text-muted">{nf(r.giveaway_kg, 1)} kg</div></td>
                    <td className="num">{nf(scrap, 1)}</td>
                    <td className="num">{nf(r.overlength_m)} m</td>
                    <td className="num">{nf(r.wip_kg, 1)}</td>
                    <td className="num">{nf(r.unexplained_kg, 1)}</td>
                    <td>{r.cu_ok === null ? '—' : r.cu_ok ? <Pill tone="ok">Khớp</Pill> : <Pill tone="bad">Lệch {nf(r.cu_diff_pct, 1)}%</Pill>}</td>
                    <td className="text-[13px]">{df(r.last_activity)}</td>
                  </tr>
                );
              })}</tbody>
            </table>
          ) : <Empty>Không có lệnh SX nào hoạt động trong kỳ.</Empty>}
        </section>
      )}

      {tab === 'lenh' && detail && (
        <section className="card mt-4 overflow-x-auto">
          <div className="card-h">
            <span>Tiêu hao từng vật tư · {detail.wo?.wo_no ?? ''} {detail.wo ? `· ${detail.wo.product_code} · ${nf(detail.wo.good_m)} m đạt` : ''}</span>
            <Link className="link text-[13px] font-normal" href={qs({ tab: 'lenh' })}>Đóng</Link>
          </div>
          {detail.mats.length ? (
            <table className="tbl">
              <thead><tr><th>Mã</th><th>Vật tư</th><th>ĐVT</th><th className="num">Định mức</th><th className="num">Đã cấp</th><th className="num">Đã trả</th><th className="num">Thực dùng</th><th className="num">Lệch</th><th className="num">%</th></tr></thead>
              <tbody>{detail.mats.map((m) => (
                <tr key={m.material_code} className={m.over_tol ? 'bg-bad-soft/50' : undefined}>
                  <td className="mono">{m.material_code}</td><td>{m.material_name}</td><td>{m.uom}</td>
                  <td className="num">{nf(m.norm, 2)}</td><td className="num">{nf(m.issued, 2)}</td><td className="num">{nf(m.returned, 2)}</td><td className="num font-medium">{nf(m.net, 2)}</td>
                  <td className="num">{nf(m.var, 2)}</td><td className={`num ${m.over_tol ? 'font-medium text-bad' : ''}`}>{m.var_pct === null ? '—' : `${nf(m.var_pct, 1)}%`}</td>
                </tr>
              ))}</tbody>
            </table>
          ) : <Empty>Lệnh chưa có cấp phát hoặc chưa có mét đạt để tính định mức.</Empty>}
          {detail.wo && detail.wo.kgkm_theory !== null && (
            <p className="border-t border-line px-4 py-2 text-[13px] text-muted">
              kg/km lý thuyết {nf(detail.wo.kgkm_theory, 2)} · thực tế cân {detail.wo.kgkm_actual === null ? 'chưa cân' : nf(detail.wo.kgkm_actual, 2)} trên {nf(detail.wo.weighed_km, 3)} km.
              Định mức gồm hao hụt cho phép và phế khởi động lần cấp đầu.
            </p>
          )}
        </section>
      )}

      {tab === 'dong' && (
        <section className="card overflow-x-auto">
          {wos.length ? (
            <table className="tbl">
              <thead><tr><th>Lệnh SX</th><th>Sản phẩm</th><th className="num">Đồng cấp (kg)</th><th className="num">Trong thành phẩm</th><th className="num">Phế đồng</th><th className="num">Trong cáp phế</th><th className="num">Trong BTP dở</th><th className="num">Lệch (kg)</th><th className="num">Lệch %</th><th /></tr></thead>
              <tbody>{wos.filter((r) => Number(r.cu_issued) > 0).map((r) => (
                <tr key={r.wo_id} className={r.cu_ok === false ? 'bg-bad-soft/50' : undefined}>
                  <td><Link className="link mono" href={qs({ tab: 'lenh', wo: r.wo_id })}>{r.wo_no}</Link></td><td className="mono">{r.product_code}</td>
                  <td className="num">{nf(r.cu_issued, 2)}</td><td className="num">{nf(r.cu_fg, 2)}</td><td className="num">{nf(r.cu_scrap, 2)}</td><td className="num">{nf(r.cu_cable, 2)}</td><td className="num">{nf(r.cu_wip, 2)}</td>
                  <td className="num font-medium">{nf(r.cu_diff, 2)}</td><td className="num">{r.cu_diff_pct === null ? '—' : `${nf(r.cu_diff_pct, 2)}%`}</td>
                  <td>{r.cu_ok === false ? <Pill tone="bad">Vượt ±{nf(cuTol, 1)}%</Pill> : <Pill tone="ok">Khớp</Pill>}</td>
                </tr>
              ))}</tbody>
            </table>
          ) : <Empty>Không có lệnh SX nào hoạt động trong kỳ.</Empty>}
          <p className="border-t border-line px-4 py-2 text-[12.5px] text-muted">Đồng trong thành phẩm = mét đạt × kg/km đồng của spec (gồm dây thoát). Đồng trong cáp phế quy đổi theo tỉ lệ đồng/tổng kg/km. Lệch dương = thiếu đồng chưa giải thích; lệch âm = ghi nhận nhiều hơn cấp.</p>
        </section>
      )}

      {tab === 'phe' && (
        <div className="grid gap-4 xl:grid-cols-[3fr_2fr]">
          <section className="card overflow-x-auto">
            <div className="card-h">Pareto phế theo nguyên nhân · {nf(scrapTotal, 1)} kg</div>
            {byReason.length ? (
              <table className="tbl">
                <thead><tr><th>Nguyên nhân</th><th>Nhóm</th><th className="num">Lần</th><th className="num">kg</th><th className="num">%</th><th className="num">Cộng dồn</th><th className="w-[30%]" /></tr></thead>
                <tbody>{(() => {
                  let cum = 0;
                  return byReason.map((r) => {
                    cum += r.kg;
                    const share = pct(r.kg, scrapTotal) ?? 0;
                    const cumPct = pct(cum, scrapTotal) ?? 0;
                    return (
                      <tr key={r.code}>
                        <td>{r.name}</td><td>{SCRAP_CAT[r.category] ?? r.category}</td><td className="num">{nf(r.times)}</td><td className="num font-medium">{nf(r.kg, 1)}</td>
                        <td className="num">{nf(share, 1)}%</td><td className={`num ${cumPct - share < 80 ? 'font-medium' : 'text-muted'}`}>{nf(cumPct, 0)}%</td>
                        <td><div className="h-3 rounded-sm bg-sunk"><div className={`h-3 rounded-sm ${cumPct - share < 80 ? 'bg-bad' : 'bg-muted'}`} style={{ width: `${share}%` }} /></div></td>
                      </tr>
                    );
                  });
                })()}</tbody>
              </table>
            ) : <Empty>Chưa ghi phế trong kỳ.</Empty>}
            {byReason.length > 0 && <p className="border-t border-line px-4 py-2 text-[12.5px] text-muted">Các dòng tô đậm chiếm 80% khối lượng phế – ưu tiên xử lý trước.</p>}
          </section>
          <section className="card overflow-x-auto">
            <div className="card-h">Phế theo công đoạn, máy</div>
            {byMachine.length ? (
              <table className="tbl"><tbody>{byMachine.map((m) => (
                <tr key={`${m.op}-${m.machine}`}><td>{OP_NAMES[m.op] ?? m.op}</td><td className="mono">{m.machine}</td><td className="num font-medium">{nf(m.kg, 1)} kg</td><td className="num text-muted">{nf(pct(m.kg, scrapTotal), 1)}%</td></tr>
              ))}</tbody></table>
            ) : <Empty>Chưa ghi phế trong kỳ.</Empty>}
          </section>
        </div>
      )}
    </>
  );
}
