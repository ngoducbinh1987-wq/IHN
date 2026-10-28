import Link from 'next/link';
import { Alert, LockNote, Swatch, dd, pc, wd, wdl } from '@/components/kh';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Pill, Toolbar } from '@/components/ui';
import { bobbins, dayData, dayPeople, infoChecks, type Check, type SlipLine } from '@/lib/kh/day';
import { ROLE, hasRole, loadKh } from '@/lib/kh/load';
import { UNIT, addDays, isWorkday, opName, prevWorkday as prevWd } from '@/lib/kh/scheduler';
import { df, nf } from '@/lib/format';
import { requireMe, requirePage } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { approveSlip, releaseDay, reviewRelease } from './actions';

export const metadata = { title: 'Lệnh sản xuất ngày' };

type Release = {
  id: string; work_date: string; revision: number; version_id: string; note: string | null; released_at: string | null; released_by_name: string | null;
  status: 'PROPOSED' | 'RELEASED' | 'RETURNED' | 'SUPERSEDED'; proposed_by: string | null; proposed_by_name: string | null; proposed_at: string | null; review_note: string | null;
  slip_id: string | null; slip_no: string | null; slip_lines: SlipLine[] | null; slip_status: string | null; approved_at: string | null; approved_by_name: string | null;
  requisitions: { id: string; req_no: string; status: string; wo_no: string; product_code: string }[] | null;
};
type Preview = { checks: Check[]; slip: SlipLine[] };


export default async function LenhNgay({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  await requirePage('lenh-ngay');
  const me = await requireMe();
  const db = await createClient();
  const kh = await loadKh(db, { plan: sp.plan, roles: me.roles });
  const today = kh.now.date;
  const wdays = kh.cal.wd;
  const prevWorkday = (d: string) => prevWd(d, wdays);
  const nextWd = (d: string, n: number) => { let x = d; for (let i = 0; i < n; i++) { x = addDays(x, 1); for (let j = 0; j < 14 && !isWorkday(x, wdays); j++) x = addDays(x, 1); } return x; };
  const todayW = isWorkday(today, wdays) ? today : nextWd(today, 1);
  const date = sp.d && /^\d{4}-\d{2}-\d{2}$/.test(sp.d) ? sp.d : todayW;
  const chips = [prevWorkday(todayW), todayW, nextWd(todayW, 1), nextWd(todayW, 2), nextWd(todayW, 3), nextWd(todayW, 4)];
  const { data: rel } = await db.schema('app').from('v_kh_releases').select('*').eq('plan_id', kh.planId ?? '').eq('work_date', date).order('revision', { ascending: false });
  const all = (rel ?? []) as Release[];
  // Lệnh đã phát (Giám đốc duyệt); bản TP SX đề xuất chờ Giám đốc; bản bị trả lại gần nhất
  const releases = all.filter((r) => r.status === 'RELEASED');
  const last = releases[0] ?? null;
  const pending = all.find((r) => r.status === 'PROPOSED') ?? null;
  const returned = all.find((r) => r.status === 'RETURNED' && (!last || r.revision > last.revision) && (!pending || r.revision > pending.revision)) ?? null;
  const isGd = me.roles.includes('BGD') || me.roles.includes('ADMIN');
  const { data: reps } = await db.schema('app').from('v_kh_reports').select('machine_code, shift_code, status, lines').eq('work_date', date);
  const actual = (machine: string, shift: string, key: string) => {
    const r = (reps ?? []).find((x) => x.machine_code === machine && x.shift_code === shift);
    if (!r) return null;
    return { v: (r.lines as { key?: string; declared_m?: number; plc_m?: number }[]).filter((l) => l.key === key).reduce((a, l) => a + Number(l.declared_m ?? l.plc_m ?? 0), 0), st: r.status as string };
  };

  const { rows, work, idle } = dayData(kh, date);
  const orderOf = new Map(kh.orders.map((o) => [o.id, o]));
  const past = date < today;
  // Kiểm tra bắt buộc + phiếu lĩnh dự kiến: database tính (đúng thứ sẽ kiểm khi bấm phát)
  const { data: pv } = !past && kh.planId && kh.version
    ? await db.schema('app').rpc('kh_day_preview', { p_plan: kh.planId, p_date: date })
    : { data: null };
  const preview = (pv ?? { checks: [], slip: [] }) as Preview;
  const checks = past ? [] : [...preview.checks, ...infoChecks(kh, date)];
  const warns = checks.filter((c) => !c.ok).length;
  const canRelease = hasRole(me.roles, [...ROLE.release, 'BGD']) && kh.fromPlan;
  const direct = me.roles.includes('BGD') || me.roles.includes('ADMIN');
  const canSlip = hasRole(me.roles, ROLE.slip);
  const stale = last && kh.version && last.version_id !== kh.version.id && !past;
  const deadline = `${kh.cfg.cutoff_time} ${dd(prevWorkday(date))}`;
  const status: [string, 'ok' | 'warn' | 'info' | 'mute'] = past ? (last ? ['Đã chạy', 'mute'] : ['Đã qua · không phát lệnh', 'mute'])
    : pending ? ['Chờ Giám đốc duyệt phát', 'warn']
    : last ? [last.revision > 1 ? `Đã phát bản ${last.revision}` : 'Đã phát', 'ok']
    : date === today ? ['Chưa phát · đang trong ngày', 'warn']
    : ['Chưa phát · hạn ' + deadline, date === nextWd(todayW, 1) || date === todayW ? 'warn' : 'info'];
  const slip = last?.slip_lines ? last.slip_lines : !past ? preview.slip : [];
  const people = [...new Set(work.flatMap((x) => dayPeople(kh, x.r.sl, date).map((y) => y.p)))];
  const q = (d: string) => `/lenh-ngay?${kh.planId ? `plan=${kh.planId}&` : ''}d=${d}`;

  return (
    <>
      <Toolbar title={<span>Lệnh sản xuất ngày {wdl(date).toLowerCase()} {dd(date)}</span>} reload={q(date)}
        actions={<Pill tone={status[1]}>{status[0]}</Pill>} />
      <div className="mt-3 text-[13px] text-muted">{kh.planNo ? `${kh.planNo} · ` : ''}TP SX lập từ lịch máy đã duyệt{kh.version ? ` phiên bản ${kh.version.version}` : ''} · Giám đốc duyệt phát · {work.length} việc trên {new Set(work.map((x) => x.machine.code)).size} máy · người: {people.join(', ') || '—'}</div>
      <div className="my-3 flex flex-wrap gap-2">
        {chips.map((d) => (
          <Link key={d} href={q(d)} aria-current={d === date ? 'page' : undefined}
            className={`rounded-full border px-3 py-1 text-[13.5px] ${d === date ? 'border-brand bg-brand text-white' : 'border-line bg-surface hover:border-brand'}`}>
            {wd(d)} {dd(d)}{d === today ? ' · hôm nay' : ''}
          </Link>
        ))}
        <form action="/lenh-ngay" className="flex items-center gap-1.5">
          {kh.planId && <input type="hidden" name="plan" value={kh.planId} />}
          <input type="date" name="d" defaultValue={date} className="inp w-[160px] py-1" aria-label="Chọn ngày" />
          <button className="btn btn-sm">Xem</button>
        </form>
      </div>
      <Flash ok={sp.ok} err={sp.err} />
      {!kh.version && <div className="card"><Empty>Chưa có lịch máy đã duyệt. TP SX xếp lịch ở mục Lịch máy, Giám đốc duyệt trước.</Empty></div>}
      {kh.version && (
        <div className="flex flex-col gap-4">
          {stale && <Alert tone="warn" title={`Lịch máy đã đổi sau khi phát bản ${last!.revision}`}>Lịch đang dùng là phiên bản {kh.version.version}. TP SX đề xuất phát lại bản mới (Giám đốc duyệt) để máy nhận lệnh đúng; phiếu lĩnh tạo theo bản mới.</Alert>}
          {pending && (
            <Alert tone="warn" title={`Lệnh ngày ${dd(date)} bản ${pending.revision} chờ Giám đốc duyệt phát`}>
              <div>{pending.proposed_by_name} đề xuất lúc {df(pending.proposed_at, true)}{pending.note ? ` · Ghi chú: ${pending.note}` : ''}</div>
              {isGd && pending.proposed_by !== me.id && (
                <form action={reviewRelease} className="mt-2 flex flex-wrap items-center gap-2" id="release-review">
                  <input type="hidden" name="plan_id" value={kh.planId ?? ''} /><input type="hidden" name="d" value={date} /><input type="hidden" name="release_id" value={pending.id} />
                  <input name="note" className="inp min-w-[260px] flex-1 py-1" placeholder="Ý kiến Giám đốc (bắt buộc khi trả lại)" aria-label="Ý kiến duyệt lệnh ngày" />
                  <SubmitButton className="btn btn-sm btn-pri" formAction={async (f: FormData) => { 'use server'; f.set('approve', '1'); await reviewRelease(f); }}>Duyệt phát lệnh</SubmitButton>
                  <SubmitButton className="btn btn-sm btn-bad-o" formAction={async (f: FormData) => { 'use server'; f.set('approve', '0'); await reviewRelease(f); }}>Trả lại</SubmitButton>
                </form>
              )}
            </Alert>
          )}
          {returned && (
            <Alert tone="bad" title={`Giám đốc trả lại bản ${returned.revision}`}>{returned.review_note}</Alert>
          )}
          {!past && (
            <section className="card">
              <div className="card-h"><h2>Kiểm tra trước khi phát</h2>{warns ? <Pill tone="warn">{warns} cảnh báo</Pill> : <Pill tone="ok">Đạt</Pill>}</div>
              <div className="flex flex-col gap-2 px-4 py-3">
                {checks.map((c) => (
                  <div key={c.t} className="flex items-start gap-3">
                    <span className="w-[78px] shrink-0"><Pill tone={c.ok ? (c.info ? 'info' : 'ok') : 'warn'}>{c.ok ? (c.info ? 'Lưu ý' : 'Đạt') : 'Cảnh báo'}</Pill></span>
                    <div><b className="text-[14px]">{c.t}</b>{c.d && <div className="text-[12.5px] text-muted">{c.d}</div>}</div>
                  </div>
                ))}
              </div>
              <div className="border-t border-line px-4 py-3">
                {canRelease ? (
                  <form action={releaseDay} className="flex flex-col gap-2">
                    <input type="hidden" name="plan_id" value={kh.planId ?? ''} /><input type="hidden" name="d" value={date} />
                    <label className="lbl">Ghi chú xử lý cảnh báo {warns ? <span className="text-bad">(bắt buộc vì còn {warns} cảnh báo)</span> : '(nếu có)'}
                      <textarea name="note" rows={2} className="inp" placeholder="Ví dụ: Line silicone 2 không chạy vì NV1, NV5 đang đứng line khác → TP Kỹ thuật/QA làm bảo trì định kỳ." /></label>
                    <label className="flex items-start gap-2 text-[13.5px]"><input type="checkbox" name="confirm" value="1" className="mt-1" required />
                      <span>{direct ? `Tôi (Giám đốc) phát lệnh ngày ${dd(date)}.` : `Tôi đề xuất lệnh ngày ${dd(date)}, gửi Giám đốc duyệt phát.`} Giám đốc duyệt xong lệnh hiện ở màn hình Ghi nhận ca tại từng máy; hệ thống tạo phiếu lĩnh cả ca gửi Kế toán SX duyệt. Sau khi phát muốn đổi phải theo quy trình thay đổi lịch.</span></label>
                    <div className="flex flex-wrap items-center gap-3">
                      <SubmitButton>{direct ? (last ? `Phát lại bản ${(all[0]?.revision ?? 0) + 1}` : `Phát lệnh ngày ${dd(date)}`) : pending ? 'Đề xuất lại (thay bản đang chờ)' : last ? 'Đề xuất phát lại bản mới' : `Đề xuất lệnh ngày ${dd(date)}`}</SubmitButton>
                      <span className="text-[12.5px] text-muted">Hạn phát: {deadline}.</span>
                    </div>
                  </form>
                ) : <LockNote>TP SX đề xuất lệnh ngày, Giám đốc duyệt phát</LockNote>}
              </div>
            </section>
          )}
          {last && (
            <Alert tone="ok" title={`Đã phát bản ${last.revision} lúc ${df(last.released_at, true)} · Giám đốc duyệt: ${last.released_by_name ?? ''}`}>
              {last.proposed_by_name && last.proposed_by_name !== last.released_by_name ? <div className="text-[12.5px]">TP SX đề xuất: {last.proposed_by_name} · {df(last.proposed_at, true)}</div> : null}
              {last.note ? <>Ghi chú: {last.note}</> : null}{last.review_note ? <div>Ý kiến Giám đốc: {last.review_note}</div> : null}
              {releases.length > 1 && <div className="text-[12.5px] text-muted">Các bản trước: {releases.slice(1).map((r) => `bản ${r.revision} (${df(r.released_at, true)})`).join(', ')}</div>}
            </Alert>
          )}
          {slip.length > 0 && (
            <section className="card">
              <div className="card-h"><h2>Phiếu lĩnh vật tư cả ca{last?.slip_no ? ` · ${last.slip_no}` : ' · dự kiến'}</h2>
                {last?.slip_status === 'APPROVED' ? <Pill tone="ok">Kế toán kho đã duyệt · {last.approved_by_name ?? ''} · {df(last.approved_at, true)}</Pill>
                  : last?.slip_id ? <Pill tone="warn">Chờ Kế toán kho duyệt</Pill> : <Pill>Tạo khi phát lệnh</Pill>}</div>
              <div className="overflow-x-auto"><table className="tbl">
                <thead><tr><th>Vật tư</th><th className="num">Số lượng</th><th className="num">Tồn NVL đạt QC</th><th>Ghi chú</th></tr></thead>
                <tbody>{slip.map((l) => (
                  <tr key={l.material_code ?? l.item}><td>{l.item}</td><td className="num">{nf(l.qty, l.unit === 'kg' ? 1 : 0)} {l.unit}</td>
                    <td className={`num ${l.available !== undefined && l.available < l.qty ? 'font-medium text-bad' : ''}`}>{l.available === undefined ? '—' : nf(l.available, 1)}</td>
                    <td className="text-[12.5px] text-muted">{l.note}</td></tr>
                ))}</tbody>
              </table></div>
              <div className="flex flex-wrap items-center gap-3 border-t border-line px-4 py-3 text-[12.5px] text-muted">
                <span className="flex-1">Số lượng tính theo định mức BOM của từng mã và số mét trong lịch máy. Kế toán kho duyệt → hệ thống tạo phiếu lĩnh Kho theo lệnh SX; thủ kho quét QR cấp, công nhân nhận tại máy. Vượt định mức phải lập phiếu lĩnh bổ sung (TP Kỹ thuật/QA duyệt).
                  {last?.requisitions && last.requisitions.length > 0 && (
                    <span className="mt-1 flex flex-wrap gap-2 text-ink">Phiếu lĩnh Kho:{last.requisitions.map((r) => (
                      <Link key={r.id} className="link" href={`/kho/cap-phat/${r.id}`}>{r.req_no} · {r.product_code} · {r.wo_no}{r.status === 'CANCELLED' ? ' (đã hủy)' : ''}</Link>
                    ))}</span>
                  )}</span>
                {last?.slip_id && last.slip_status !== 'APPROVED' && (canSlip ? (
                  <form action={approveSlip}><input type="hidden" name="plan_id" value={kh.planId ?? ''} /><input type="hidden" name="d" value={date} /><input type="hidden" name="slip_id" value={last.slip_id} />
                    <SubmitButton className="btn btn-sm btn-pri">Duyệt phiếu lĩnh</SubmitButton></form>
                ) : <LockNote>Chờ Kế toán kho</LockNote>)}
              </div>
            </section>
          )}
          <section className="card overflow-x-auto">
            {rows.length ? (
              <table className="tbl">
                <thead><tr><th>Máy</th><th>Người</th><th>Dòng</th><th>Sản phẩm · công đoạn</th><th>Màu</th><th className="num">Mét kế hoạch</th><th className="num">Bobin ra</th><th className="num">Phút chạy</th><th>Hạn giao</th><th className="num">Thực tế</th></tr></thead>
                <tbody>
                  {rows.map((x, i) => {
                    const head = i === 0 || rows[i - 1].s !== x.s;
                    const sh = kh.cal.shifts.find((s) => s.code === x.shift);
                    const headRow = head ? <tr key={'h' + x.s}><td colSpan={10} className="bg-sunk text-[12.5px] font-medium">Ca {x.shift}{sh ? ` · ${sh.start_time} – ${sh.end_time}` : ''}</td></tr> : null;
                    if (!x.r) return [headRow, <tr key={x.machine.code + x.s}><td className="mono">{x.machine.code}</td><td colSpan={9} className="text-[12.5px] text-muted">Không chạy{idle.includes(x.machine.code) ? ' cả ngày' : ' ca này'}</td></tr>];
                    const o = orderOf.get(x.r.sl.lineId);
                    const a = actual(x.machine.code, x.shift, x.r.sl.key);
                    const near = o?.due && o.due >= date && (new Date(o.due).getTime() - new Date(date).getTime()) / 86400000 <= 3;
                    return [headRow, (
                      <tr key={x.machine.code + x.s + x.r.sl.key + x.r.sl.start}>
                        <td className="mono">{x.machine.code}</td><td className="text-[12.5px]">{dayPeople(kh, x.r.sl, date).map((y, i) => <div key={y.p}>{i === 0 ? <b>{y.p}</b> : y.p}{y.c ? <span className="text-warn"> · kiêm nhiệm tạm</span> : ''}</div>)}</td>
                        <td className="mono whitespace-nowrap">{o?.label}{o?.prio === 0 && <> <Pill tone="bad">Gấp</Pill></>}</td>
                        <td><b>{o?.product_code}</b><div className="text-[12px] text-muted">{o ? opName(x.r.sl.op, o) : x.r.sl.op}</div></td>
                        <td className="text-[12.5px]">{x.r.sl.color ? <><Swatch color={x.r.sl.color} />{x.r.sl.color}</> : '—'}</td>
                        <td className="num">{nf(x.r.m)}<div className="text-[12px] text-muted">{UNIT[x.r.sl.op]}</div></td>
                        <td className="num">{bobbins(x.r.sl.op, x.r.m)}</td>
                        <td className="num">{nf(x.r.run)}{x.r.su > 0.5 && <div className="text-[12px] text-muted">+{nf(x.r.su)}′ đổi mã</div>}</td>
                        <td className="text-[12.5px]">{near ? <Pill tone="warn">Hạn {dd(o!.due)}</Pill> : dd(o?.due)}</td>
                        <td className="num">{a ? <>{nf(a.v)}<div className="text-[12px] text-muted">{pc(a.v / x.r.m)} · {a.st === 'CONFIRMED' ? 'đã xác nhận' : a.st === 'SUBMITTED' ? 'chờ xác nhận' : 'nháp'}</div></> : <span className="text-muted">—</span>}</td>
                      </tr>
                    )];
                  })}
                </tbody>
              </table>
            ) : <Empty>Ngày {dd(date)} không phải ngày làm việc hoặc nằm ngoài lịch máy.</Empty>}
            <p className="border-t border-line px-4 py-3 text-[12.5px] text-muted">Mét kế hoạch đã trừ {100 - kh.cfg.fill_pct}% dự phòng mỗi ca. Bobin ra tính 10 km/bobin cho lõi, 5 km/bobin cho cáp (giả định). Lệnh có hạn giao trong 3 ngày được tô vàng. Thực tế lấy từ báo cáo ca.</p>
          </section>
        </div>
      )}
    </>
  );
}
