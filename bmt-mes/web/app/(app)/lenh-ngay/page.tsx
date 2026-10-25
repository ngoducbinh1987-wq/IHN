import Link from 'next/link';
import { Alert, LockNote, Swatch, dd, pc, wd, wdl } from '@/components/kh';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Pill, Toolbar } from '@/components/ui';
import { bobbins, dayChecks, dayData, slipLines, type SlipLine } from '@/lib/kh/day';
import { ROLE, hasRole, loadKh } from '@/lib/kh/load';
import { UNIT, addDays, isWorkday, opName } from '@/lib/kh/scheduler';
import { df, nf } from '@/lib/format';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { approveSlip, releaseDay } from './actions';

export const metadata = { title: 'Lệnh sản xuất ngày' };

type Release = {
  id: string; work_date: string; revision: number; version_id: string; note: string | null; released_at: string; released_by_name: string | null;
  slip_id: string | null; slip_no: string | null; slip_lines: SlipLine[] | null; slip_status: string | null; approved_at: string | null; approved_by_name: string | null;
};

const prevWorkday = (d: string) => { let x = addDays(d, -1); while (!isWorkday(x)) x = addDays(x, -1); return x; };
const nextWd = (d: string, n: number) => { let x = d; for (let i = 0; i < n; i++) { x = addDays(x, 1); while (!isWorkday(x)) x = addDays(x, 1); } return x; };

export default async function LenhNgay({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const me = await requireMe();
  const db = await createClient();
  const kh = await loadKh(db, { plan: sp.plan, roles: me.roles });
  const today = kh.now.date;
  const todayW = isWorkday(today) ? today : nextWd(today, 1);
  const date = sp.d && /^\d{4}-\d{2}-\d{2}$/.test(sp.d) ? sp.d : todayW;
  const chips = [prevWorkday(todayW), todayW, nextWd(todayW, 1), nextWd(todayW, 2), nextWd(todayW, 3), nextWd(todayW, 4)];
  const { data: rel } = await db.schema('app').from('v_kh_releases').select('*').eq('plan_id', kh.planId ?? '').eq('work_date', date).order('revision', { ascending: false });
  const releases = (rel ?? []) as Release[];
  const last = releases[0] ?? null;
  const { data: reps } = await db.schema('app').from('v_kh_reports').select('machine_code, shift_code, status, lines').eq('work_date', date);
  const actual = (machine: string, shift: string, key: string) => {
    const r = (reps ?? []).find((x) => x.machine_code === machine && x.shift_code === shift);
    if (!r) return null;
    return { v: (r.lines as { key?: string; declared_m?: number; plc_m?: number }[]).filter((l) => l.key === key).reduce((a, l) => a + Number(l.declared_m ?? l.plc_m ?? 0), 0), st: r.status as string };
  };

  const { rows, work, idle } = dayData(kh, date);
  const orderOf = new Map(kh.orders.map((o) => [o.id, o]));
  const past = date < today;
  const checks = past ? [] : dayChecks(kh, date);
  const warns = checks.filter((c) => !c.ok).length;
  const canRelease = hasRole(me.roles, ROLE.release) && kh.fromPlan;
  const canSlip = hasRole(me.roles, ROLE.slip);
  const stale = last && kh.version && last.version_id !== kh.version.id && !past;
  const deadline = `${kh.cfg.cutoff_time} ${dd(prevWorkday(date))}`;
  const status: [string, 'ok' | 'warn' | 'info' | 'mute'] = past ? (last ? ['Đã chạy', 'mute'] : ['Đã qua · không phát lệnh', 'mute'])
    : last ? [last.revision > 1 ? `Đã phát bản ${last.revision}` : 'Đã phát', 'ok']
    : date === today ? ['Chưa phát · đang trong ngày', 'warn']
    : ['Chưa phát · hạn ' + deadline, date === nextWd(todayW, 1) || date === todayW ? 'warn' : 'info'];
  const slip = last?.slip_lines ? last.slip_lines : !past && work.length ? slipLines(kh, date) : [];
  const people = [...new Set(work.map((x) => x.r.sl.operator).filter(Boolean))];
  const q = (d: string) => `/lenh-ngay?${kh.planId ? `plan=${kh.planId}&` : ''}d=${d}`;

  return (
    <>
      <Toolbar title={<span>Lệnh sản xuất ngày {wdl(date).toLowerCase()} {dd(date)}</span>} reload={q(date)}
        actions={<Pill tone={status[1]}>{status[0]}</Pill>} />
      <div className="mt-3 text-[13px] text-muted">{kh.planNo ? `${kh.planNo} · ` : ''}Quản lý SX lập từ lịch máy{kh.version ? ` phiên bản ${kh.version.version}` : ''} · {work.length} việc trên {new Set(work.map((x) => x.machine.code)).size} máy · người: {people.join(', ') || '—'}</div>
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
      {!kh.version && <div className="card"><Empty>Chưa có lịch máy. Quản lý SX xếp lịch ở mục Lịch máy trước.</Empty></div>}
      {kh.version && (
        <div className="flex flex-col gap-4">
          {stale && <Alert tone="warn" title={`Lịch máy đã đổi sau khi phát bản ${last!.revision}`}>Lịch đang dùng là phiên bản {kh.version.version}. Quản lý SX phát lại bản mới để máy nhận lệnh đúng; phiếu lĩnh bổ sung tạo theo bản mới.</Alert>}
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
                      <span>Tôi xác nhận phát lệnh ngày {dd(date)}. Lệnh hiện ở màn hình Ghi nhận ca tại từng máy; hệ thống tạo phiếu lĩnh cả ca gửi Kế toán kho duyệt. Sau khi phát muốn đổi phải theo quy trình thay đổi lịch.</span></label>
                    <div className="flex flex-wrap items-center gap-3">
                      <SubmitButton>{last ? `Phát lại bản ${last.revision + 1}` : `Phát lệnh ngày ${dd(date)}`}</SubmitButton>
                      <span className="text-[12.5px] text-muted">Hạn phát: {deadline}.</span>
                    </div>
                  </form>
                ) : <LockNote>Chỉ Quản lý SX phát lệnh ngày (Giám đốc được báo)</LockNote>}
              </div>
            </section>
          )}
          {last && (
            <Alert tone="ok" title={`Đã phát bản ${last.revision} lúc ${df(last.released_at, true)} · ${last.released_by_name ?? ''}`}>
              {last.note ? <>Ghi chú: {last.note}</> : null}
              {releases.length > 1 && <div className="text-[12.5px] text-muted">Các bản trước: {releases.slice(1).map((r) => `bản ${r.revision} (${df(r.released_at, true)})`).join(', ')}</div>}
            </Alert>
          )}
          {slip.length > 0 && (
            <section className="card">
              <div className="card-h"><h2>Phiếu lĩnh vật tư cả ca{last?.slip_no ? ` · ${last.slip_no}` : ' · dự kiến'}</h2>
                {last?.slip_status === 'APPROVED' ? <Pill tone="ok">Kế toán kho đã duyệt · {last.approved_by_name ?? ''} · {df(last.approved_at, true)}</Pill>
                  : last?.slip_id ? <Pill tone="warn">Chờ Kế toán kho duyệt</Pill> : <Pill>Tạo khi phát lệnh</Pill>}</div>
              <div className="overflow-x-auto"><table className="tbl">
                <thead><tr><th>Vật tư</th><th className="num">Số lượng</th><th>Ghi chú</th></tr></thead>
                <tbody>{slip.map((l) => <tr key={l.item}><td>{l.item}</td><td className="num">{nf(l.qty, l.unit === 'kg' ? 1 : 0)} {l.unit}</td><td className="text-[12.5px] text-muted">{l.note}</td></tr>)}</tbody>
              </table></div>
              <div className="flex flex-wrap items-center gap-3 border-t border-line px-4 py-3 text-[12.5px] text-muted">
                <span className="flex-1">Thủ kho xuất đầu ca theo phiếu, NV1/NV5 nhận hàng; cuối ca nhập lại vật tư thừa và phế đồng để cân bằng đồng. Vượt định mức phải TP Kỹ thuật/QA duyệt.</span>
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
                        <td className="mono">{x.machine.code}</td><td><b>{x.r.sl.operator}</b></td>
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
