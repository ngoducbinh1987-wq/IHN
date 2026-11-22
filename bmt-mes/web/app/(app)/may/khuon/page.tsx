import Link from 'next/link';
import { AlertTriangle } from 'lucide-react';
import { Empty, Flash, Pill, StatusPill, Tabs, Toolbar } from '@/components/ui';
import { SubmitButton } from '@/components/submit-button';
import { DateInput } from '@/components/date-input';
import { DIE_KIND, DIE_STATUS, dieHole } from '@/lib/machine';
import { nf, numIn } from '@/lib/format';
import { canPage, requirePage } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { addProposedDies, orderDies, saveDie, saveDieRules, setDieStatus } from '../actions';

export const metadata = { title: 'Khuôn' };

type Die = {
  id: string; code: string; kind: string; label: string; size: number; a_mm: number | null; l_mm: number | null; qty: number; status: string;
  fit_min: number | null; fit_max: number | null; price: number | null; life_km: number | null; km_run: number; cost_per_km: number | null;
  products: number; product_codes: string | null; plan_codes: string | null; location: string | null; note: string | null; pr_no: string | null;
  od_note: string | null;
};
type Gap = { product_code: string; in_plan: boolean; plan_m: number; kind: string; label: string; op_code: string; basis_name: string; basis: number;
  suggest: number; a_mm: number | null; l_mm: number | null; die_code: string | null; die_status: string | null; reason: string };
type Prop = { kind: string; label: string; size: number; a_mm: number | null; l_mm: number | null; price: number | null; n_codes: number; codes: string;
  in_plan: boolean; basis_min: number; basis_max: number };
type Rule = { kind: string; mat: string; label: string; op_code: string; part: string; basis: string; nominal: number | null; clr_min: number | null;
  clr_max: number | null; factor: number | null; tol: number | null; a_offset: number | null; l_factor: number | null; sort: number };

const TABS = [
  { key: 'danh-muc', label: 'Danh mục khuôn' },
  { key: 'thieu', label: 'Mã thiếu khuôn' },
  { key: 'de-xuat', label: 'MES đề xuất' },
  { key: 'dat', label: 'Đặt khuôn' },
  { key: 'quy-tac', label: 'Quy tắc kích thước' },
];
const BASIS: Record<string, string> = { COND: 'Ø ruột dẫn', CORE: 'Ø lõi cách điện', LAY: 'Ø xoắn (2 × Ø lõi, cáp nhiều lõi theo hệ số bó)', UNDER: 'Ø dưới vỏ', OD: 'OD (thực tế, chưa đo thì tối ưu)' };

export default async function DiesPage({ searchParams }: { searchParams: Promise<{ tab?: string; loai?: string; tt?: string; ok?: string; err?: string }> }) {
  const sp = await searchParams;
  const me = await requirePage('may-khuon');
  const tab = TABS.find((t) => t.key === sp.tab)?.key ?? 'danh-muc';
  const supabase = await createClient();
  const [{ data: dieRows, error: e1 }, { data: gapRows, error: e2 }, { data: ruleRows }] = await Promise.all([
    supabase.schema('app').rpc('die_list'),
    supabase.schema('app').rpc('die_gaps'),
    supabase.schema('master').from('die_rules').select('kind, mat, label, op_code, part, basis, nominal, clr_min, clr_max, factor, tol, a_offset, l_factor, sort').order('sort'),
  ]);
  const props = tab === 'de-xuat' ? ((await supabase.schema('app').rpc('die_propose')).data ?? []) as Prop[] : [];
  const dies = (dieRows ?? []) as Die[];
  const gaps = (gapRows ?? []) as Gap[];
  const rules = (ruleRows ?? []) as Rule[];
  const isAdm = me.roles.includes('ADMIN');
  const canEdit = isAdm || me.roles.includes('KT_TP');
  const canStatus = canEdit || me.roles.includes('SX_TP');
  const canOrder = isAdm || me.roles.includes('MUA_NV') || me.roles.includes('MUA_TP');
  const planGaps = gaps.filter((g) => g.in_plan);
  const planCodes = new Set(planGaps.map((g) => g.product_code));
  const back = `/may/khuon?tab=${tab}${sp.loai ? `&loai=${sp.loai}` : ''}${sp.tt ? `&tt=${sp.tt}` : ''}`;
  const kinds = Object.keys(DIE_KIND);
  const shown = dies.filter((d) => (!sp.loai || d.kind === sp.loai) && (!sp.tt || d.status === sp.tt));
  const sum = (st: string) => dies.filter((d) => d.status === st).length;
  const showPrice = dies.some((d) => d.price !== null);
  const orderable = dies.filter((d) => ['NEEDED', 'WORN', 'BROKEN'].includes(d.status));
  const needDate = new Date(Date.now() + 7 * 864e5 + 7 * 36e5).toISOString().slice(0, 10);
  const canSeeSpec = canPage(me, 'san-pham');
  const codeLink = (c: string) => canSeeSpec ? <Link key={c} className="text-brand hover:underline" href={`/san-pham/${encodeURIComponent(c)}?tab=thong-so#khuon-dung`}>{c}</Link> : <span key={c}>{c}</span>;
  const codes = (s: string | null, max = 6) => {
    const list = (s ?? '').split(', ').filter(Boolean);
    return <>{list.slice(0, max).map((c, i) => <span key={c}>{i > 0 && ', '}{codeLink(c)}</span>)}{list.length > max && <span className="text-muted"> … +{list.length - max}</span>}</>;
  };

  return (
    <>
      <Toolbar title="Khuôn đùn, bện, xoắn" reload={back} />
      <Tabs active={tab} items={TABS.map((t) => ({ key: t.key, label: t.label, href: `/may/khuon?tab=${t.key}`,
        count: t.key === 'thieu' ? planCodes.size : t.key === 'dat' ? orderable.length : undefined }))} />
      <Flash ok={sp.ok} err={sp.err ?? e1?.message ?? e2?.message} />
      {planCodes.size > 0 && tab !== 'thieu' && (
        <div className="mb-4 flex max-w-4xl items-start gap-2 rounded border-l-4 border-bad bg-bad-soft px-4 py-2.5 text-[14px] text-bad" role="alert">
          <AlertTriangle size={16} className="mt-0.5 shrink-0" />
          <span>Alarm: {planCodes.size} mã trong kế hoạch tháng chưa có khuôn sẵn. <Link className="font-medium underline" href="/may/khuon?tab=thieu">Xem mã thiếu khuôn</Link></span>
        </div>
      )}

      {tab === 'danh-muc' && (
        <>
          <div className="mb-3 grid max-w-4xl grid-cols-2 gap-2 text-[13.5px] sm:grid-cols-5">
            {(['AVAILABLE', 'NEEDED', 'ORDERED', 'WORN', 'BROKEN'] as const).map((st) => (
              <Link key={st} href={`/may/khuon?tab=danh-muc&tt=${sp.tt === st ? '' : st}${sp.loai ? `&loai=${sp.loai}` : ''}`}
                className={`card px-3 py-2 hover:border-brand ${sp.tt === st ? 'border-brand' : ''}`}>
                <div className="text-muted">{DIE_STATUS[st][0]}</div><div className="text-[20px] font-semibold">{sum(st)}</div>
              </Link>
            ))}
          </div>
          <div className="mb-3 flex flex-wrap gap-1.5 text-[13px]">
            <Link href={`/may/khuon?tab=danh-muc${sp.tt ? `&tt=${sp.tt}` : ''}`} className={`btn btn-sm ${!sp.loai ? 'btn-pri' : ''}`}>Tất cả ({dies.length})</Link>
            {kinds.map((k) => (
              <Link key={k} href={`/may/khuon?tab=danh-muc&loai=${k}${sp.tt ? `&tt=${sp.tt}` : ''}`} className={`btn btn-sm ${sp.loai === k ? 'btn-pri' : ''}`}>
                {DIE_KIND[k]} ({dies.filter((d) => d.kind === k).length})
              </Link>
            ))}
          </div>
          <p className="mb-3 max-w-4xl text-[13.5px] text-muted">
            MES tự chọn khuôn cho từng spec theo quy tắc kích thước (tab Quy tắc); khuôn có khoảng dùng riêng (TP KT/QA chốt) thì theo khoảng đó.
            Km chạy cộng từ phiếu hoàn thành của công đoạn dùng khuôn, từ ngày nhận khuôn. Khuôn mòn vẫn dùng được, chờ thay; khuôn hỏng không dùng.
          </p>
          {shown.length === 0 ? <div className="card"><Empty>Không có khuôn nào.</Empty></div> : (
            <section className="card mb-4 overflow-x-auto" id="danh-muc-khuon">
              <table className="tbl">
                <thead><tr><th>Mã khuôn</th><th className="num">Ød / ØD</th><th className="num">ØA</th><th className="num">L</th><th className="num">SL</th>
                  <th>Tình trạng</th><th>Dùng cho</th><th className="num">Km chạy</th>{showPrice && <th className="num">Giá (đ)</th>}<th /></tr></thead>
                <tbody>
                  {shown.map((d) => (
                    <tr key={d.id} className={d.status === 'RETIRED' ? 'opacity-50' : ''}>
                      <td><div className="font-medium">{d.code}</div><div className="text-[12.5px] text-muted">{DIE_KIND[d.kind] ?? d.label}</div>
                        {(d.fit_min !== null || d.fit_max !== null) && <div className="text-[12px] text-info">dùng cho cơ sở {nf(d.fit_min, 2)}–{nf(d.fit_max, 2)} mm</div>}
                        {d.location && <div className="text-[12px] text-muted">{d.location}</div>}</td>
                      <td className="num font-medium">{dieHole(d.kind)} {nf(d.size, 2)}</td>
                      <td className="num">{d.a_mm !== null ? nf(d.a_mm, 2) : ''}</td>
                      <td className="num">{d.l_mm !== null ? nf(d.l_mm, 1) : ''}</td>
                      <td className="num">{d.qty}</td>
                      <td><StatusPill map={DIE_STATUS} value={d.status} />{d.pr_no && <div className="text-[12px] text-muted">{d.pr_no}</div>}
                        {d.od_note && <div className="text-[12px] text-warn">{d.od_note}</div>}</td>
                      <td className="max-w-[340px] text-[13px]">{d.products ? <><span className="text-muted">{d.products} mã: </span>{codes(d.product_codes)}</> : <span className="text-muted">Chưa mã nào dùng</span>}
                        {d.plan_codes && <div className="text-[12px]"><Pill tone="info">Kế hoạch tháng</Pill> {codes(d.plan_codes, 4)}</div>}</td>
                      <td className="num">{nf(d.km_run, 1)}{d.life_km ? <div className="text-[12px] text-muted">/ {nf(d.life_km)} km</div> : null}</td>
                      {showPrice && <td className="num">{d.price !== null ? nf(d.price) : ''}{d.cost_per_km !== null && <div className="text-[12px] text-muted">{nf(d.cost_per_km)} đ/km</div>}</td>}
                      <td className="min-w-[200px]">
                        {canStatus && (
                          <details><summary className="cursor-pointer text-[13px] text-brand">Đổi trạng thái</summary>
                            <form action={setDieStatus} className="mt-2 grid gap-1.5">
                              <input type="hidden" name="id" value={d.id} /><input type="hidden" name="back" value={back} />
                              <select className="inp" name="status" defaultValue={d.status === 'ORDERED' ? 'AVAILABLE' : d.status}>
                                {Object.entries(DIE_STATUS).map(([k, [l]]) => <option key={k} value={k}>{k === 'AVAILABLE' ? 'Có sẵn (đã nhận khuôn)' : l}</option>)}
                              </select>
                              <input className="inp" name="qty" placeholder={`Số lượng (${d.qty})`} inputMode="numeric" />
                              <input className="inp" name="note" placeholder="Ghi chú / lý do (mòn, hỏng bắt buộc)" />
                              <SubmitButton className="btn btn-sm btn-pri" pendingText="…">Lưu</SubmitButton>
                            </form>
                          </details>
                        )}
                        {canEdit && (
                          <details><summary className="cursor-pointer text-[13px] text-brand">Sửa khuôn</summary>
                            <DieForm d={d} back={back} />
                          </details>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </section>
          )}
          {canEdit && (
            <section className="card max-w-2xl" id="them-khuon">
              <div className="card-h">Thêm khuôn vào danh mục</div>
              <div className="p-4"><DieForm back={back} /></div>
            </section>
          )}
        </>
      )}

      {tab === 'thieu' && (
        <section className="card overflow-x-auto" id="ma-thieu-khuon">
          <div className="card-h">Mã chưa có khuôn sẵn<span className="text-[13px] font-normal text-muted">mã trong kế hoạch tháng đứng đầu (Alarm); lịch máy vẫn xếp, lệnh SX ngày cảnh báo</span></div>
          {gaps.length === 0 ? <Empty>Mọi mã đang dùng đều có khuôn sẵn.</Empty> : (
            <table className="tbl">
              <thead><tr><th>Mã sản phẩm</th><th>Công đoạn · khuôn</th><th className="num">Cơ sở (mm)</th><th className="num">MES đề xuất</th><th>Khuôn trong danh mục</th><th>Tình trạng</th></tr></thead>
              <tbody>
                {gaps.map((g, i) => (
                  <tr key={i} className={g.in_plan ? 'bg-bad-soft/40' : ''}>
                    <td>{codeLink(g.product_code)}{g.in_plan && <div><Pill tone="bad">Kế hoạch tháng · {nf(g.plan_m)} m</Pill></div>}</td>
                    <td>{g.op_code} · {g.label}</td>
                    <td className="num">{g.basis_name} {nf(g.basis, 2)}</td>
                    <td className="num">{dieHole(g.kind)} {nf(g.suggest, 2)}{g.a_mm !== null && <div className="text-[12px] text-muted">ØA {nf(g.a_mm, 2)}</div>}{g.l_mm !== null && <div className="text-[12px] text-muted">L {nf(g.l_mm, 1)}</div>}</td>
                    <td>{g.die_code ?? <span className="text-muted">Chưa có</span>}</td>
                    <td>{g.die_status ? <StatusPill map={DIE_STATUS} value={g.die_status} /> : <Pill tone="bad">{g.reason}</Pill>}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </section>
      )}

      {tab === 'de-xuat' && (
        <section className="card overflow-x-auto" id="mes-de-xuat-khuon">
          <div className="card-h">Khuôn MES đề xuất làm thêm<span className="text-[13px] font-normal text-muted">cho mã chưa có khuôn nào trong danh mục, gom tối thiểu số khuôn theo quy tắc</span></div>
          {props.length === 0 ? <Empty>Mọi mã đã có khuôn trong danh mục (có sẵn, cần đặt hoặc đã đặt).</Empty> : (
            <>
              <table className="tbl">
                <thead><tr><th>Loại khuôn</th><th className="num">Kích thước</th><th className="num">ØA</th><th className="num">L</th><th>Dùng cho</th><th className="num">Giá (đ)</th></tr></thead>
                <tbody>
                  {props.map((p, i) => (
                    <tr key={i}>
                      <td>{DIE_KIND[p.kind] ?? p.label}</td>
                      <td className="num font-medium">{dieHole(p.kind)} {nf(p.size, 2)}</td>
                      <td className="num">{p.a_mm !== null ? nf(p.a_mm, 2) : ''}</td><td className="num">{p.l_mm !== null ? nf(p.l_mm, 1) : ''}</td>
                      <td className="text-[13px]">{p.n_codes} mã: {codes(p.codes)}{p.in_plan && <Pill tone="bad">Kế hoạch tháng</Pill>}</td>
                      <td className="num">{p.price !== null ? nf(p.price) : ''}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
              {canEdit && (
                <form action={addProposedDies} className="flex flex-wrap items-center gap-3 border-t border-line p-4">
                  <input type="hidden" name="back" value="/may/khuon?tab=danh-muc&tt=NEEDED" />
                  <SubmitButton className="btn btn-pri" pendingText="Đang thêm…">Thêm {props.length} khuôn vào danh mục (Cần đặt)</SubmitButton>
                  <span className="text-[13px] text-muted">Sau đó NV mua đặt khuôn ở tab Đặt khuôn.</span>
                </form>
              )}
            </>
          )}
        </section>
      )}

      {tab === 'dat' && (
        <section className="card overflow-x-auto" id="dat-khuon">
          <div className="card-h">Đặt khuôn<span className="text-[13px] font-normal text-muted">NV mua / TP Mua tích khuôn cần đặt → MES lập đề xuất mua bổ sung (TP Mua → Giám đốc duyệt → đơn mua tổng)</span></div>
          {orderable.length === 0 ? <Empty>Không có khuôn cần đặt.</Empty> : (
            <form action={orderDies}>
              <input type="hidden" name="back" value={back} />
              <table className="tbl">
                <thead><tr><th />{['Mã khuôn', 'Loại', 'Kích thước', 'SL', 'Tình trạng', 'Dùng cho'].map((h) => <th key={h}>{h}</th>)}</tr></thead>
                <tbody>
                  {orderable.sort((a, b) => Number(!!b.plan_codes) - Number(!!a.plan_codes) || a.code.localeCompare(b.code)).map((d) => (
                    <tr key={d.id}>
                      <td><input type="checkbox" name="die" value={d.id} defaultChecked={!!d.plan_codes && canOrder} disabled={!canOrder} aria-label={`Chọn ${d.code}`} /></td>
                      <td className="font-medium">{d.code}</td><td>{DIE_KIND[d.kind]}</td>
                      <td>{dieHole(d.kind)} {nf(d.size, 2)}{d.a_mm !== null && ` · ØA ${nf(d.a_mm, 2)}`}{d.l_mm !== null && ` · L ${nf(d.l_mm, 1)}`}</td>
                      <td>{d.qty}</td><td><StatusPill map={DIE_STATUS} value={d.status} /></td>
                      <td className="text-[13px]">{d.plan_codes ? <><Pill tone="bad">Kế hoạch tháng</Pill> {codes(d.plan_codes, 4)}</> : codes(d.product_codes, 4)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
              {canOrder ? (
                <div className="flex flex-wrap items-end gap-3 border-t border-line p-4">
                  <label className="lbl">Ngày cần khuôn<DateInput name="need_date" defaultValue={needDate} required /></label>
                  <label className="lbl grow">Nội dung đề xuất<input className="inp" name="note" defaultValue="Đặt khuôn theo danh mục khuôn MES" /></label>
                  <SubmitButton className="btn btn-pri" pendingText="Đang lập…">Lập đề xuất mua khuôn đã chọn</SubmitButton>
                </div>
              ) : <p className="border-t border-line p-4 text-[13px] text-muted">NV mua hoặc TP Mua đặt khuôn. Khuôn mã trong kế hoạch tháng được chọn sẵn.</p>}
            </form>
          )}
        </section>
      )}

      {tab === 'quy-tac' && (
        <section className="card overflow-x-auto" id="quy-tac-khuon">
          <div className="card-h">Quy tắc kích thước khuôn<span className="text-[13px] font-normal text-muted">rút từ bảng khuôn nhà máy; TP KT/QA sửa, MES tra lại khuôn cho mọi spec</span></div>
          <form action={saveDieRules}>
            <input type="hidden" name="back" value={back} />
            <table className="tbl">
              <thead><tr><th>Khuôn</th><th>Cơ sở</th><th className="num">Khe hở chuẩn</th><th className="num">Khe hở nhỏ nhất</th><th className="num">Khe hở lớn nhất</th>
                <th className="num">Hệ số</th><th className="num">Dung sai ±</th><th className="num">ØA = Ød +</th><th className="num">L = ØD ×</th></tr></thead>
              <tbody>
                {rules.map((r) => {
                  const k = `${r.kind}|${r.mat}`;
                  const cell = (n: keyof Rule, show: boolean) => (
                    <td className="num">{show ? (canEdit ? <input className="inp w-20 text-right" name={`${n}_${k}`} defaultValue={numIn(r[n] as number | null)} aria-label={`${r.kind} ${n}`} /> : nf(r[n] as number, 3)) : ''}</td>
                  );
                  return (
                    <tr key={k}>
                      <td><input type="hidden" name="rule" value={k} /><div className="font-medium">{r.kind}{r.mat !== '*' ? ` · vỏ ${r.mat}` : ''}</div><div className="text-[12.5px] text-muted">{r.label} · {r.op_code}</div></td>
                      <td className="text-[13px]">{BASIS[r.basis] ?? r.basis}</td>
                      {cell('nominal', r.part === 'TIP')}{cell('clr_min', r.part === 'TIP')}{cell('clr_max', r.part === 'TIP')}
                      {cell('factor', r.part === 'DIE')}{cell('tol', r.part === 'DIE')}{cell('a_offset', r.a_offset !== null)}{cell('l_factor', r.l_factor !== null)}
                    </tr>
                  );
                })}
              </tbody>
            </table>
            <div className="border-t border-line p-4 text-[13px] text-muted">
              Khuôn trong (tip), khuôn bện, khuôn xoắn: lỗ = cơ sở + khe hở (làm tròn 0,05 mm); một khuôn dùng chung cho mọi mã có khe hở trong khoảng nhỏ nhất – lớn nhất.
              Khuôn ngoài (die): lỗ = cơ sở × hệ số; dùng chung khi lỗ chuẩn lệch không quá dung sai. Khuôn vỏ LSZH, PVC, FR-PVC dùng chung (anh Bình chốt 19/11/2026).
              {canEdit && (
                <div className="mt-3 flex flex-wrap items-end gap-3">
                  <label className="lbl grow">Lý do sửa<input className="inp" name="reason" required /></label>
                  <SubmitButton className="btn btn-pri" pendingText="Đang lưu…">Lưu quy tắc</SubmitButton>
                </div>
              )}
            </div>
          </form>
        </section>
      )}
    </>
  );
}

function DieForm({ d, back }: { d?: Die; back: string }) {
  return (
    <form action={saveDie} className="mt-2 grid grid-cols-2 gap-2 sm:grid-cols-4">
      <input type="hidden" name="back" value={back} />
      {d && <input type="hidden" name="id" value={d.id} />}
      <label className="lbl">Loại<select className="inp" name="kind" defaultValue={d?.kind ?? 'DV'}>{Object.entries(DIE_KIND).map(([k, l]) => <option key={k} value={k}>{k} · {l}</option>)}</select></label>
      <label className="lbl">Ød / ØD (mm)<input className="inp text-right" name="size" defaultValue={numIn(d?.size)} required /></label>
      <label className="lbl">ØA (mm)<input className="inp text-right" name="a_mm" defaultValue={numIn(d?.a_mm)} /></label>
      <label className="lbl">L (mm)<input className="inp text-right" name="l_mm" defaultValue={numIn(d?.l_mm)} /></label>
      <label className="lbl">Mã khuôn<input className="inp" name="code" defaultValue={d?.code ?? ''} placeholder="Trống: MES đặt" /></label>
      <label className="lbl">Số lượng<input className="inp text-right" name="qty" defaultValue={d?.qty ?? 1} inputMode="numeric" /></label>
      <label className="lbl">Dùng cho cơ sở từ (mm)<input className="inp text-right" name="fit_min" defaultValue={numIn(d?.fit_min)} placeholder="Trống: theo quy tắc" /></label>
      <label className="lbl">đến (mm)<input className="inp text-right" name="fit_max" defaultValue={numIn(d?.fit_max)} /></label>
      <label className="lbl">Giá (đ)<input className="inp text-right" name="price" defaultValue={numIn(d?.price)} placeholder="Trống: bảng giá" /></label>
      <label className="lbl">Tuổi thọ (km)<input className="inp text-right" name="life_km" defaultValue={numIn(d?.life_km)} /></label>
      <label className="lbl">Vị trí cất<input className="inp" name="location" defaultValue={d?.location ?? ''} /></label>
      <label className="lbl">Ghi chú<input className="inp" name="note" defaultValue={d?.note ?? ''} /></label>
      {d && <label className="lbl col-span-2 sm:col-span-3">Lý do sửa<input className="inp" name="reason" required /></label>}
      <div className="flex items-end"><SubmitButton className="btn btn-sm btn-pri" pendingText="…">{d ? 'Lưu khuôn' : 'Thêm khuôn'}</SubmitButton></div>
    </form>
  );
}
