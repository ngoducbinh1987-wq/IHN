import Link from 'next/link';
import { Alert, LockNote, SubTabs } from '@/components/kh';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Kpi, Pill, Toolbar } from '@/components/ui';
import { df } from '@/lib/format';
import { type Kh, loadKh, vnNow } from '@/lib/kh/load';
import { addDays, dayIndex, isWorkday, peopleOf } from '@/lib/kh/scheduler';
import { requirePage } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { deleteAbsence, deleteCover, saveAbsence, saveCover, saveOperator, setCrew, setFgKeeper, setOperatorActive, setSkill } from './actions';

export const metadata = { title: 'Nhân sự xưởng' };

type SP = Record<string, string | undefined>;
type Op = {
  code: string; full_name: string | null; job: string; extra: string | null; note: string | null; active: boolean; stopped_at: string | null; sort: number;
  is_deputy: boolean; keeps_fg: boolean; profile_id: string | null; profile_name: string | null; skills: { machine: string; level: 'MAIN' | 'LEARNING'; signed: boolean }[];
};
type Mach = { id: string; code: string; name: string; machine_type: string; status: string | null };
type Abs = { id: string; operator_code: string; full_name: string | null; date_from: string; date_to: string; part: 'FULL' | 'AM' | 'PM'; kind: string; note: string | null; created_by_name: string | null; created_at: string };
type Cov = { id: string; operator_code: string; full_name: string | null; machine_code: string; date_from: string; date_to: string; reason: string; skill: 'MAIN' | 'LEARNING' | 'NONE'; created_by_name: string | null };
type Crew = { work_date: string; machine_code: string; crew: number; members: string[]; note: string | null; set_by_name: string | null };

const TABS = [
  { key: 'nguoi', label: 'Người' }, { key: 'tay-nghe', label: 'Người × máy' }, { key: 'vang', label: 'Lịch vắng' },
  { key: 'kiem-nhiem', label: 'Kiêm nhiệm tạm' }, { key: 'dong-goi', label: 'Tổ đóng gói' }, { key: 'canh-bao', label: 'Cảnh báo & gợi ý' },
];
const KIND: Record<string, string> = { PHEP: 'Nghỉ phép', OM: 'Ốm', RIENG: 'Việc riêng', CONG_TAC: 'Đi công tác', KHAC: 'Khác' };
const KIND_SHORT: Record<string, string> = { PHEP: 'P', OM: 'Ô', RIENG: 'R', CONG_TAC: 'CT', KHAC: 'K' };
const PART: Record<string, string> = { FULL: 'Cả ngày', AM: 'Nửa đầu ca', PM: 'Nửa sau ca' };
const TYPE_NAME: Record<string, string> = { MIXER: 'Máy trộn', BUNCHER: 'Bện', EXTRUDER_SI: 'Line silicone', TWISTER: 'Xoắn', EXTRUDER_TP: 'Line vỏ', PACKER: 'Đóng gói' };
const dd = (d: string | null | undefined) => (d ? `${d.slice(8, 10)}/${d.slice(5, 7)}` : '—');
const WD = ['CN', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7'];
const wdl = (d: string) => WD[new Date(d + 'T00:00:00Z').getUTCDay()];

export default async function NhanSuXuong({ searchParams }: { searchParams: Promise<SP> }) {
  const sp = await searchParams;
  const me = await requirePage('nhan-su-xuong');
  const db = await createClient();
  const tab = TABS.find((t) => t.key === sp.tab)?.key ?? 'nguoi';
  const today = vnNow().date;
  const canEdit = me.roles.some((r) => ['SX_TP', 'SX_KH', 'ADMIN'].includes(r));
  const canSkill = me.roles.some((r) => ['SX_TP', 'ADMIN'].includes(r));
  const [{ data: opRows }, { data: mRows }, { data: absRows }, { data: covRows }, { data: crewRows }, { data: users }] = await Promise.all([
    db.schema('app').from('v_operators_all').select('*').order('sort'),
    db.schema('app').from('v_kh_machines').select('id, code, name, machine_type, status').order('code'),
    db.schema('app').from('v_kh_absences').select('*').gte('date_to', addDays(today, -60)).order('date_from'),
    db.schema('app').from('v_kh_covers').select('*').gte('date_to', addDays(today, -30)).order('date_from'),
    db.schema('app').from('v_kh_crew_days').select('*').gte('work_date', today).order('work_date'),
    canEdit ? db.schema('app').from('v_users').select('id, full_name, status').eq('status', 'ACTIVE').order('full_name') : Promise.resolve({ data: [] as { id: string; full_name: string }[] }),
  ]);
  const ops = (opRows ?? []) as Op[];
  const active = ops.filter((o) => o.active);
  const ORDER = ['SIL-MIX', 'BUN-01', 'EXT-SI-01', 'EXT-SI-02', 'TWS-01', 'EXT-TP-01', 'EXT-TP-02', 'PACK-01'];
  const machines = ((mRows ?? []) as Mach[]).sort((a, b) => (ORDER.indexOf(a.code) + 1 || 99) - (ORDER.indexOf(b.code) + 1 || 99) || a.code.localeCompare(b.code));
  const abs = (absRows ?? []) as Abs[];
  const covs = (covRows ?? []) as Cov[];
  const crews = (crewRows ?? []) as Crew[];
  const name = (code: string) => { const o = ops.find((x) => x.code === code); return o?.full_name ? `${code} · ${o.full_name}` : code; };
  const hidden = (k: string, v: string) => <input type="hidden" name={k} value={v} />;
  const tabIn = hidden('tab', tab);

  // Lịch máy đang dùng: để biết ngày nào máy nào có việc (cảnh báo không ai đứng máy, tổ đóng gói thiếu người)
  let kh: Kh | null = null;
  try { kh = await loadKh(db, { roles: me.roles }); } catch { kh = null; }
  const P = kh ? peopleOf(kh.cfg) : peopleOf({});
  const wd = kh?.cal.wd ?? [1, 2, 3, 4, 5, 6];
  const days: string[] = [];
  for (let d = today; days.length < 14; d = addDays(d, 1)) if (isWorkday(d, wd)) days.push(d);
  const absentOn = (code: string, d: string) => abs.find((a) => a.operator_code === code && a.date_from <= d && d <= a.date_to);
  const coverOn = (code: string, m: string, d: string) => covs.find((c) => c.operator_code === code && c.machine_code === m && c.date_from <= d && d <= c.date_to);
  const hasSkill = (o: Op, m: string, lv: 'MAIN' | 'LEARNING' = 'MAIN') => o.skills.some((s) => s.machine === m && s.level === lv);
  const workOn = (m: string, d: string) => {
    if (!kh?.sch) return false;
    const DAY = kh.sch.S * kh.cal.SPD, di = dayIndex(kh.cal, d);
    return (kh.sch.byMachine.get(m) ?? []).some((s) => s.end > di * DAY + 1e-6 && s.start < (di + 1) * DAY - 1e-6);
  };
  const crewOf = (m: string, d: string) => crews.find((c) => c.machine_code === m && c.work_date === d);
  // Người được đứng máy ngày d (đứng chính hoặc kiêm nhiệm tạm), không vắng cả ngày; máy đóng gói TP SX chọn người thì chỉ người đó
  const standers = (m: Mach, d: string) => {
    const cr = m.machine_type === 'PACKER' ? crewOf(m.code, d) : undefined;
    return active.filter((o) => (cr?.members.length ? cr.members.includes(o.code) : hasSkill(o, m.code) || Boolean(coverOn(o.code, m.code, d)))
      && absentOn(o.code, d)?.part !== 'FULL');
  };
  const alerts: { d: string; m: Mach; text: string; tone: 'bad' | 'warn'; sug: Op[] }[] = [];
  for (const d of days) for (const m of machines) {
    if (m.status === 'OFF' || !workOn(m.code, d)) continue;
    const st = standers(m, d);
    const free = active.filter((o) => absentOn(o.code, d)?.part !== 'FULL' && !st.includes(o));
    const sug = [...free].sort((a, b) => Number(hasSkill(b, m.code, 'LEARNING')) - Number(hasSkill(a, m.code, 'LEARNING'))
      || Number(b.skills.some((s) => machines.find((x) => x.code === s.machine)?.machine_type === m.machine_type)) - Number(a.skills.some((s) => machines.find((x) => x.code === s.machine)?.machine_type === m.machine_type))
      || a.sort - b.sort).slice(0, 3);
    if (!st.length) alerts.push({ d, m, tone: 'bad', sug, text: 'Lịch có việc nhưng không còn ai đứng được máy (người đứng chính vắng hoặc chưa giao người)' });
    else if (m.machine_type === 'PACKER') {
      const target = crewOf(m.code, d)?.crew ?? P.pack_crew;
      if (st.length < target) alerts.push({ d, m, tone: 'warn', sug, text: `Tổ đóng gói đặt ${target} người nhưng chỉ ${st.length} người có mặt: chạy 1 người, tốc độ ${P.pack_one_pct}%` });
    }
  }
  const abNow = abs.filter((a) => a.date_from <= today && today <= a.date_to);
  const covNow = covs.filter((c) => c.date_from <= today && today <= c.date_to);

  // Lịch vắng: lưới tháng
  const month = /^\d{4}-\d{2}$/.test(sp.m ?? '') ? sp.m! : today.slice(0, 7);
  const mDays: string[] = [];
  for (let d = month + '-01'; d.slice(0, 7) === month; d = addDays(d, 1)) mDays.push(d);
  const prevM = addDays(month + '-01', -1).slice(0, 7), nextM = addDays(mDays[mDays.length - 1], 1).slice(0, 7);
  const sched = machines;
  const packers = machines.filter((m) => m.machine_type === 'PACKER');

  return (
    <>
      <Toolbar title="Nhân sự xưởng" reload={`/nhan-su-xuong?tab=${tab}`} />
      <div className="mt-3"><Flash ok={sp.ok} err={sp.err} /></div>
      <Alert tone={canEdit ? 'ok' : 'info'} title={canEdit ? 'TP SX / Kế hoạch SX khai báo người, lịch vắng, kiêm nhiệm tạm, tổ đóng gói' : 'Chỉ xem · TP SX khai báo'}>
        Lịch máy xếp theo người có mặt: máy bện, đùn, xoắn đang chạy không cần người đứng, chỉ cần người lúc đổi máy + khởi động ({P.start_min} phút) và mỗi lần thay bobin ({P.bobbin_min} phút);
        máy trộn 1 người, máy đóng gói tổ {P.pack_crew} người đứng suốt. Mọi thay đổi ở đây ghi nhật ký và làm lịch máy &quot;cần xếp lại&quot;. Tay nghề do TP KT/QA ký xác nhận ở hồ sơ máy.
      </Alert>
      <div className="mb-4 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <Kpi label="Người đang làm" value={active.length} hint={`${ops.length - active.length} người đã ngừng`} />
        <Kpi label="Vắng hôm nay" value={abNow.length} hint={abNow.map((a) => a.operator_code + (a.part === 'FULL' ? '' : ' ½')).join(', ') || 'Không có'} tone={abNow.length ? 'warn' : 'ok'} />
        <Kpi label="Kiêm nhiệm tạm hôm nay" value={covNow.length} hint={covNow.map((c) => `${c.operator_code} → ${c.machine_code}`).join(', ') || 'Không có'} />
        <Kpi label="Cảnh báo 14 ngày tới" value={alerts.length} hint={alerts.length ? 'Máy có việc thiếu người' : 'Đủ người theo lịch đang dùng'} tone={alerts.some((a) => a.tone === 'bad') ? 'bad' : alerts.length ? 'warn' : 'ok'} href="/nhan-su-xuong?tab=canh-bao" />
      </div>
      <SubTabs active={tab} items={TABS.map((t) => ({ ...t, href: `/nhan-su-xuong?tab=${t.key}` }))} />

      {tab === 'nguoi' && (
        <div className="flex flex-col gap-4">
          <section className="card overflow-x-auto">
            <div className="card-h"><h2>Danh sách người</h2><span className="text-[13px] font-normal text-muted">số người là biến số: thêm, ngừng bất kỳ lúc nào</span></div>
            <table className="tbl">
              <thead><tr><th>Mã</th><th>Họ tên</th><th>Công việc</th><th>Đứng máy</th><th>Tài khoản</th><th>Trạng thái</th>{canEdit && <th>Sửa</th>}</tr></thead>
              <tbody>{ops.map((o) => (
                <tr key={o.code} className={o.active ? '' : 'opacity-60'}>
                  <td className="mono"><b>{o.code}</b>{o.is_deputy && <div className="text-[12px] text-muted">Tổ phó</div>}{o.keeps_fg && <div className="text-[12px] text-brand">Giữ kho TP</div>}</td>
                  <td>{o.full_name ?? <span className="text-muted">Chưa nhập</span>}{o.note && <div className="text-[12px] text-muted">{o.note}</div>}</td>
                  <td className="text-[12.5px]">{o.job}{o.extra && <div className="text-muted">{o.extra}</div>}</td>
                  <td className="text-[12.5px]">{o.skills.length ? o.skills.map((s) => <div key={s.machine}>{s.machine} · {s.level === 'MAIN' ? 'đứng chính' : 'đang học'}{s.signed ? ' ✓' : ''}</div>) : <span className="text-muted">Chưa giao máy</span>}</td>
                  <td className="text-[12.5px]">{o.profile_name ?? <span className="text-muted">Chưa liên kết</span>}</td>
                  <td>{o.active ? <Pill tone="ok">Đang làm</Pill> : <Pill>Ngừng từ {dd(o.stopped_at)}</Pill>}</td>
                  {canEdit && (
                    <td className="min-w-[240px]">
                      <details><summary className="cursor-pointer text-[13px] text-brand">Sửa</summary>
                        <form action={saveOperator} className="mt-2 flex flex-col gap-1.5">
                          {tabIn}{hidden('code', o.code)}
                          <input name="name" defaultValue={o.full_name ?? ''} className="inp py-1" placeholder="Họ tên" aria-label={`Họ tên ${o.code}`} required />
                          <input name="job" defaultValue={o.job} className="inp py-1" placeholder="Công việc chính" aria-label={`Công việc ${o.code}`} required />
                          <input name="extra" defaultValue={o.extra ?? ''} className="inp py-1" placeholder="Việc kiêm thêm" aria-label={`Việc kiêm ${o.code}`} />
                          <input name="note" defaultValue={o.note ?? ''} className="inp py-1" placeholder="Ghi chú" aria-label={`Ghi chú ${o.code}`} />
                          <select name="profile" defaultValue={o.profile_id ?? ''} className="inp py-1" aria-label={`Tài khoản ${o.code}`}>
                            <option value="">Không liên kết tài khoản</option>
                            {((users ?? []) as { id: string; full_name: string }[]).map((u) => <option key={u.id} value={u.id}>{u.full_name}</option>)}
                          </select>
                          <input name="reason" className="inp py-1" placeholder="Lý do sửa" aria-label={`Lý do sửa ${o.code}`} />
                          <SubmitButton className="btn btn-sm" pendingText="…">Lưu</SubmitButton>
                        </form>
                        <form action={setFgKeeper} className="mt-2 flex flex-wrap items-center gap-1.5 border-t border-line pt-2">
                          {tabIn}{hidden('code', o.code)}{hidden('on', o.keeps_fg ? '0' : '1')}
                          <SubmitButton className="btn btn-sm" pendingText="…">{o.keeps_fg ? 'Thôi giữ kho thành phẩm' : 'Giao giữ kho thành phẩm'}</SubmitButton>
                        </form>
                        <form action={setOperatorActive} className="mt-2 flex flex-wrap items-center gap-1.5 border-t border-line pt-2">
                          {tabIn}{hidden('code', o.code)}{hidden('active', o.active ? '0' : '1')}
                          <input name="reason" className="inp w-[150px] py-1" placeholder="Lý do (bắt buộc)" aria-label={`Lý do ${o.active ? 'ngừng' : 'làm lại'} ${o.code}`} required />
                          <SubmitButton className={`btn btn-sm ${o.active ? 'btn-bad-o' : ''}`} pendingText="…">{o.active ? 'Ngừng làm' : 'Làm lại'}</SubmitButton>
                        </form>
                      </details>
                    </td>
                  )}
                </tr>
              ))}</tbody>
            </table>
            <p className="border-t border-line px-4 py-3 text-[12.5px] text-muted">Người giữ kho thành phẩm ký phiếu nhập kho TP và phiếu xuất giao; Kế toán SX chọn đúng người này khi nhập phiếu vào MES. Liên kết tài khoản để MES chặn người làm tự ký QC bobin của mình. Người ngừng làm không được xếp lịch, giữ lịch sử phiếu, báo cáo.</p>
          </section>
          {canEdit && (
            <section className="card" id="them-nguoi">
              <div className="card-h"><h2>Thêm người</h2><span className="text-[13px] font-normal text-muted">MES tự cấp mã NV kế tiếp</span></div>
              <form action={saveOperator} className="grid gap-3 p-4 sm:grid-cols-2 lg:grid-cols-4 lg:items-end">
                {tabIn}
                <label className="lbl"><span className="req">Họ tên</span><input name="name" className="inp" required /></label>
                <label className="lbl"><span className="req">Công việc chính</span><input name="job" className="inp" placeholder="Ví dụ: chạy line đùn" required /></label>
                <label className="lbl">Việc kiêm thêm<input name="extra" className="inp" placeholder="Ví dụ: nhập kho" /></label>
                <label className="lbl">Ghi chú<input name="note" className="inp" /></label>
                <div className="lg:col-span-4"><SubmitButton className="btn btn-pri">Thêm người</SubmitButton></div>
              </form>
            </section>
          )}
        </div>
      )}

      {tab === 'tay-nghe' && (
        <section className="card overflow-x-auto">
          <div className="card-h"><h2>Người × máy</h2><span className="text-[13px] font-normal text-muted">TP SX giao · TP KT/QA ký xác nhận tay nghề (✓) ở hồ sơ máy</span></div>
          <table className="tbl">
            <thead><tr><th>Người</th>{sched.map((m) => <th key={m.code} className="text-center"><Link className="link" href={`/may/${m.id}?tab=nguoi`}>{m.code}</Link><div className="text-[11.5px] font-normal text-muted">{TYPE_NAME[m.machine_type] ?? m.machine_type}</div></th>)}</tr></thead>
            <tbody>{active.map((o) => (
              <tr key={o.code}>
                <td className="whitespace-nowrap"><b>{o.code}</b>{o.full_name && <div className="text-[12px] text-muted">{o.full_name}</div>}</td>
                {sched.map((m) => {
                  const sk = o.skills.find((s) => s.machine === m.code);
                  const cv = covs.find((c) => c.operator_code === o.code && c.machine_code === m.code && c.date_to >= today);
                  return (
                    <td key={m.code} className="min-w-[110px] text-center text-[12.5px]">
                      {sk ? <Pill tone={sk.level === 'MAIN' ? 'ok' : 'info'}>{sk.level === 'MAIN' ? 'Đứng chính' : 'Đang học'}{sk.signed ? ' ✓' : ''}</Pill> : cv ? <Pill tone="warn">Kiêm nhiệm tạm</Pill> : <span className="text-muted">—</span>}
                      {cv && sk && <div className="text-warn">kiêm nhiệm tạm</div>}
                      {canSkill && (
                        <form action={setSkill} className="mt-1 flex items-center justify-center gap-1">
                          {tabIn}{hidden('machine_id', m.id)}{hidden('machine', m.code)}{hidden('operator', o.code)}
                          <select name="level" defaultValue={sk?.level ?? ''} className="inp w-auto py-0.5 text-[12px]" aria-label={`${o.code} ${m.code}`}>
                            <option value="">—</option><option value="MAIN">Đứng chính</option><option value="LEARNING">Đang học</option>
                          </select>
                          <SubmitButton className="btn btn-sm px-1.5 py-0.5 text-[12px]" pendingText="…">Lưu</SubmitButton>
                        </form>
                      )}
                    </td>
                  );
                })}
              </tr>
            ))}</tbody>
          </table>
          <p className="border-t border-line px-4 py-3 text-[12.5px] text-muted">Đứng chính: được xếp lịch đứng máy. Đang học: chỉ đứng kèm, không đứng một mình (muốn cho đứng thì phân công kiêm nhiệm tạm). Đổi mức tay nghề thì chữ ký TP KT/QA bị xóa, TP KT/QA ký lại.</p>
        </section>
      )}

      {tab === 'vang' && (
        <div className="flex flex-col gap-4">
          <section className="card overflow-x-auto">
            <div className="card-h"><h2>Lịch vắng tháng {month.slice(5)}/{month.slice(0, 4)}</h2>
              <span className="flex gap-2"><Link className="btn btn-sm" href={`/nhan-su-xuong?tab=vang&m=${prevM}`}>Tháng trước</Link><Link className="btn btn-sm" href="/nhan-su-xuong?tab=vang">Tháng này</Link><Link className="btn btn-sm" href={`/nhan-su-xuong?tab=vang&m=${nextM}`}>Tháng sau</Link></span></div>
            <table className="tbl text-[12px]">
              <thead><tr><th>Người</th>{mDays.map((d) => <th key={d} className={`px-1 text-center ${!isWorkday(d, wd) ? 'bg-sunk' : ''} ${d === today ? 'text-brand' : ''}`}>{Number(d.slice(8))}<div className="font-normal text-muted">{wdl(d)}</div></th>)}</tr></thead>
              <tbody>{active.map((o) => (
                <tr key={o.code}><td className="whitespace-nowrap"><b>{o.code}</b>{o.full_name ? ` · ${o.full_name}` : ''}</td>
                  {mDays.map((d) => { const a = absentOn(o.code, d); return (
                    <td key={d} className={`px-1 text-center ${!isWorkday(d, wd) ? 'bg-sunk' : ''} ${a ? (a.part === 'FULL' ? 'bg-warn/25' : 'bg-warn/10') : ''}`} title={a ? `${KIND[a.kind]} · ${PART[a.part]}${a.note ? ' · ' + a.note : ''}` : undefined}>
                      {a ? `${KIND_SHORT[a.kind] ?? 'V'}${a.part === 'FULL' ? '' : '½'}` : ''}</td>); })}
                </tr>
              ))}</tbody>
            </table>
            <p className="border-t border-line px-4 py-3 text-[12.5px] text-muted">P nghỉ phép · Ô ốm · R việc riêng · CT đi công tác · K khác · ½ nửa ca. Ô xám: ngày nghỉ của xưởng.</p>
          </section>
          {canEdit && (
            <section className="card">
              <div className="card-h"><h2>Nhập lịch vắng</h2></div>
              <form action={saveAbsence} className="grid gap-3 p-4 sm:grid-cols-2 lg:grid-cols-6 lg:items-end">
                {tabIn}{hidden('m', month)}
                <label className="lbl"><span className="req">Người</span><select name="operator" className="inp" required>{active.map((o) => <option key={o.code} value={o.code}>{name(o.code)}</option>)}</select></label>
                <label className="lbl"><span className="req">Từ ngày</span><input type="date" name="from" className="inp" required defaultValue={today} /></label>
                <label className="lbl">Đến ngày<input type="date" name="to" className="inp" /></label>
                <label className="lbl">Thời gian<select name="part" className="inp" defaultValue="FULL">{Object.entries(PART).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></label>
                <label className="lbl">Loại<select name="kind" className="inp" defaultValue="PHEP">{Object.entries(KIND).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></label>
                <label className="lbl">Ghi chú<input name="note" className="inp" /></label>
                <div className="lg:col-span-6"><SubmitButton className="btn btn-pri">Lưu lịch vắng</SubmitButton> <span className="text-[12.5px] text-muted">Nửa ca chỉ nhập cho một ngày. Đến ngày để trống = một ngày.</span></div>
              </form>
            </section>
          )}
          <section className="card overflow-x-auto">
            <div className="card-h"><h2>Danh sách lịch vắng</h2><span className="text-[13px] font-normal text-muted">60 ngày gần nhất và sắp tới</span></div>
            {!abs.length ? <Empty>Chưa có lịch vắng.</Empty> : (
              <table className="tbl">
                <thead><tr><th>Người</th><th>Ngày</th><th>Thời gian</th><th>Loại</th><th>Ghi chú</th><th>Người nhập</th>{canEdit && <th />}</tr></thead>
                <tbody>{abs.map((a) => (
                  <tr key={a.id}><td><b>{a.operator_code}</b>{a.full_name ? ` · ${a.full_name}` : ''}</td><td className="whitespace-nowrap">{dd(a.date_from)}{a.date_to !== a.date_from ? ` – ${dd(a.date_to)}` : ''}</td>
                    <td>{PART[a.part]}</td><td>{KIND[a.kind] ?? a.kind}</td><td className="text-[12.5px]">{a.note}</td><td className="text-[12.5px] text-muted">{a.created_by_name} · {df(a.created_at, true)}</td>
                    {canEdit && <td>{a.date_to >= today && (
                      <form action={deleteAbsence} className="flex items-center gap-1.5">{tabIn}{hidden('m', month)}{hidden('id', a.id)}
                        <input name="reason" className="inp w-[140px] py-1" placeholder="Lý do bỏ" aria-label="Lý do bỏ lịch vắng" required /><SubmitButton className="btn btn-sm" pendingText="…">Bỏ</SubmitButton></form>)}</td>}
                  </tr>
                ))}</tbody>
              </table>
            )}
          </section>
        </div>
      )}

      {tab === 'kiem-nhiem' && (
        <div className="flex flex-col gap-4">
          {canEdit && (
            <section className="card">
              <div className="card-h"><h2>Phân công kiêm nhiệm tạm</h2><span className="text-[13px] font-normal text-muted">QLSX phân công khi vắng người · được cả người chưa có tay nghề máy đó</span></div>
              <form action={saveCover} className="grid gap-3 p-4 sm:grid-cols-2 lg:grid-cols-5 lg:items-end">
                {tabIn}
                <label className="lbl"><span className="req">Người</span><select name="operator" className="inp" required>{active.map((o) => <option key={o.code} value={o.code}>{name(o.code)}</option>)}</select></label>
                <label className="lbl"><span className="req">Máy</span><select name="machine" className="inp" required>{sched.map((m) => <option key={m.code} value={m.code}>{m.code} · {TYPE_NAME[m.machine_type] ?? m.machine_type}</option>)}</select></label>
                <label className="lbl"><span className="req">Từ ngày</span><input type="date" name="from" className="inp" required defaultValue={today} min={today} /></label>
                <label className="lbl">Đến ngày<input type="date" name="to" className="inp" min={today} /></label>
                <label className="lbl"><span className="req">Lý do</span><input name="reason" className="inp" placeholder="Ví dụ: NV5 nghỉ phép" required /></label>
                <div className="lg:col-span-5"><SubmitButton className="btn btn-pri">Phân công</SubmitButton> <span className="text-[12.5px] text-muted">Người chưa có tay nghề: MES ghi &quot;kiêm nhiệm tạm&quot; trên lịch máy, lệnh ngày và báo TP KT/QA kèm, kiểm tra mẫu đầu ca.</span></div>
              </form>
            </section>
          )}
          <section className="card overflow-x-auto">
            <div className="card-h"><h2>Đang và sắp kiêm nhiệm</h2></div>
            {!covs.length ? <Empty>Chưa có phân công kiêm nhiệm tạm.</Empty> : (
              <table className="tbl">
                <thead><tr><th>Người</th><th>Máy</th><th>Ngày</th><th>Tay nghề máy này</th><th>Lý do</th><th>Người phân công</th>{canEdit && <th />}</tr></thead>
                <tbody>{covs.map((c) => (
                  <tr key={c.id} className={c.date_to < today ? 'opacity-60' : ''}>
                    <td><b>{c.operator_code}</b>{c.full_name ? ` · ${c.full_name}` : ''}</td><td className="mono">{c.machine_code}</td>
                    <td className="whitespace-nowrap">{dd(c.date_from)} – {dd(c.date_to)}{c.date_to < today ? ' · đã hết' : ''}</td>
                    <td>{c.skill === 'LEARNING' ? <Pill tone="info">Đang học</Pill> : <Pill tone="warn">Chưa có tay nghề</Pill>}</td>
                    <td className="text-[12.5px]">{c.reason}</td><td className="text-[12.5px] text-muted">{c.created_by_name}</td>
                    {canEdit && <td>{c.date_to >= today && (
                      <form action={deleteCover} className="flex items-center gap-1.5">{tabIn}{hidden('id', c.id)}
                        <input name="reason" className="inp w-[140px] py-1" placeholder="Lý do bỏ" aria-label="Lý do bỏ kiêm nhiệm" required /><SubmitButton className="btn btn-sm" pendingText="…">Bỏ</SubmitButton></form>)}</td>}
                  </tr>
                ))}</tbody>
              </table>
            )}
          </section>
        </div>
      )}

      {tab === 'dong-goi' && (
        <section className="card overflow-x-auto">
          <div className="card-h"><h2>Tổ đóng gói 14 ngày làm việc tới</h2><span className="text-[13px] font-normal text-muted">mặc định {P.pack_crew} người khi có lịch · TP SX đặt 1 hoặc 2 người đầu ca theo sản lượng ngày · 1 người: tốc độ {P.pack_one_pct}%</span></div>
          {!packers.length ? <Empty>Chưa khai báo máy đóng gói.</Empty> : (
            <table className="tbl">
              <thead><tr><th>Ngày</th><th>Máy</th><th>Lịch</th><th>Tổ đặt</th><th>Người có mặt được đóng gói</th>{canEdit && <th>Đặt tổ</th>}</tr></thead>
              <tbody>{days.flatMap((d) => packers.map((m) => {
                const cr = crewOf(m.code, d);
                const st = standers(m, d);
                const cands = active.filter((o) => absentOn(o.code, d)?.part !== 'FULL');
                return (
                  <tr key={d + m.code}>
                    <td className="whitespace-nowrap"><b>{wdl(d)} {dd(d)}</b></td><td className="mono">{m.code}</td>
                    <td className="text-[12.5px]">{workOn(m.code, d) ? 'Có việc' : <span className="text-muted">Không có việc</span>}</td>
                    <td>{cr ? <><b>{cr.crew} người</b>{cr.members.length ? ` · ${cr.members.join(', ')}` : ''}<div className="text-[12px] text-muted">{cr.set_by_name}{cr.note ? ` · ${cr.note}` : ''}</div></> : <span className="text-muted">Mặc định {P.pack_crew} người</span>}</td>
                    <td className="text-[12.5px]">{st.map((o) => o.code).join(', ') || <span className="text-bad">Không có ai</span>}</td>
                    {canEdit && (
                      <td className="min-w-[300px]">
                        <form action={setCrew} className="flex flex-wrap items-center gap-1.5">
                          {tabIn}{hidden('date', d)}{hidden('machine', m.code)}
                          <select name="crew" defaultValue={cr ? String(cr.crew) : ''} className="inp w-auto py-1" aria-label={`Tổ đóng gói ${d}`}>
                            <option value="">Mặc định ({P.pack_crew})</option><option value="1">1 người</option><option value="2">2 người</option>
                          </select>
                          {cands.map((o) => <label key={o.code} className="inline-flex items-center gap-1 text-[12.5px]"><input type="checkbox" name="members" value={o.code} defaultChecked={cr?.members.includes(o.code)} />{o.code}</label>)}
                          <SubmitButton className="btn btn-sm" pendingText="…">Lưu</SubmitButton>
                        </form>
                      </td>
                    )}
                  </tr>
                );
              }))}</tbody>
            </table>
          )}
          <p className="border-t border-line px-4 py-3 text-[12.5px] text-muted">Không chọn người: MES dùng người đứng chính máy đóng gói (và người kiêm nhiệm tạm) có mặt. Chọn người: chỉ những người đó đóng gói ngày đó (được cả người chưa có tay nghề, ghi kiêm nhiệm tạm). Ít người có mặt hơn tổ đặt thì MES chạy với số người có mặt.</p>
        </section>
      )}

      {tab === 'canh-bao' && (
        <section className="card overflow-x-auto">
          <div className="card-h"><h2>Máy có việc mà thiếu người, 14 ngày làm việc tới</h2><span className="text-[13px] font-normal text-muted">theo lịch máy đang dùng{kh?.version ? ` (bản ${kh.version.version})` : ''}</span></div>
          {!kh?.sch ? <Empty>Chưa có lịch máy đã duyệt.</Empty> : !alerts.length ? <Empty>Đủ người đứng máy cho lịch đang dùng.</Empty> : (
            <table className="tbl">
              <thead><tr><th>Ngày</th><th>Máy</th><th>Vấn đề</th><th>Gợi ý kiêm nhiệm (người có mặt)</th>{canEdit && <th />}</tr></thead>
              <tbody>{alerts.map((a) => (
                <tr key={a.d + a.m.code}>
                  <td className="whitespace-nowrap"><b>{wdl(a.d)} {dd(a.d)}</b></td><td className="mono">{a.m.code}</td>
                  <td className={`text-[12.5px] ${a.tone === 'bad' ? 'text-bad' : 'text-warn'}`}>{a.text}</td>
                  <td className="text-[12.5px]">{a.sug.length ? a.sug.map((o) => <div key={o.code}><b>{o.code}</b>{o.full_name ? ` ${o.full_name}` : ''} · {hasSkill(o, a.m.code, 'LEARNING') ? 'đang học máy này' : o.skills.length ? `đứng ${o.skills.map((s) => s.machine).join(', ')}` : 'chưa có tay nghề'}</div>) : <span className="text-muted">Không còn ai có mặt</span>}</td>
                  {canEdit && (
                    <td className="min-w-[260px]">{a.sug[0] && (
                      <form action={saveCover} className="flex flex-wrap items-center gap-1.5">
                        {tabIn}{hidden('machine', a.m.code)}{hidden('from', a.d)}{hidden('to', a.d)}
                        <select name="operator" defaultValue={a.sug[0].code} className="inp w-auto py-1" aria-label="Người kiêm nhiệm">{a.sug.map((o) => <option key={o.code} value={o.code}>{o.code}</option>)}</select>
                        <input name="reason" className="inp w-[130px] py-1" placeholder="Lý do" defaultValue="Thiếu người đứng máy" aria-label="Lý do" required />
                        <SubmitButton className="btn btn-sm" pendingText="…">Kiêm nhiệm ngày này</SubmitButton>
                      </form>
                    )}</td>
                  )}
                </tr>
              ))}</tbody>
            </table>
          )}
          <p className="border-t border-line px-4 py-3 text-[12.5px] text-muted">MES chỉ gợi ý; QLSX quyết định và phân công. Sau khi phân công, TP SX bấm Xếp lại lịch ở <Link className="link" href="/lich-may">Lịch máy</Link>. Lịch máy cũng cảnh báo khi một người phụ trách quá {P.watch_max} máy chạy cùng lúc.</p>
        </section>
      )}
      {!canEdit && tab !== 'canh-bao' && <div className="mt-2"><LockNote>Chỉ TP SX / Kế hoạch SX sửa</LockNote></div>}
    </>
  );
}
