import Link from 'next/link';
import { Pencil } from 'lucide-react';
import type { ReactNode } from 'react';
import { Alert, LockNote } from '@/components/kh';
import { SubmitButton } from '@/components/submit-button';
import { Flash, Pill, Toolbar } from '@/components/ui';
import { QC_LEARN_MIN_SAMPLES, ROLE, hasRole, loadConfig } from '@/lib/kh/load';
import { DEFAULT_WD, OP_SHORT, type Op, flowOf, shiftRun } from '@/lib/kh/scheduler';
import { df, nf, numIn } from '@/lib/format';
import { requireMe, requirePage } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { saveChangeovers, saveConfig, saveFlow, saveRates, saveShifts, setMode } from './actions';

export const metadata = { title: 'Tham số xếp lịch' };

const DOW: [number, string][] = [[1, 'T2'], [2, 'T3'], [3, 'T4'], [4, 'T5'], [5, 'T6'], [6, 'T7'], [7, 'CN']];

const PARAMS: [key: string, label: string, unit: string, range: string][] = [
  ['fill_pct', 'Tỷ lệ xếp lịch mỗi ca', '%', '60 – 95'], ['frozen_days', 'Vùng khóa lịch', 'ngày', '1 – 7'],
  ['cutoff_time', 'Giờ chốt phát lệnh ngày', 'hôm trước', 'HH:MM'], ['machines_per_operator', 'Số máy 1 người đứng cùng lúc', 'máy', '1 – 3'],
  ['downtime_reason_min', 'Dừng máy bắt buộc lý do khi quá', 'phút', '1 – 30'], ['plc_dev_pct', 'Ngưỡng lệch mét PLC / khai báo', '%', '0,1 – 2'],
  ['auto_shifts', 'Số ca đạt liên tiếp để chuyển tự động', 'ca', '3 – 30'], ['plc_loss_min', 'Mất kết nối PLC chuyển sang nhập tay sau', 'phút', '1 – 60'],
  ['group_days', 'Khung gom lô cùng cỡ ruột, cùng màu (0 = không gom)', 'ngày', '0 – 30'],
];
const MODE: Record<string, string> = { MANUAL: 'Nhập tay', BOTH: 'Song song', PLC: 'Tự động (PLC)' };
const OPNAME: Record<string, string> = { MIXER: 'Trộn silicone (CD0, kg/giờ)', PACKER: 'Kiểm tra + đóng gói bobin gỗ (CD6)', BUNCHER: 'Bện ruột dẫn (CD1)', EXTRUDER_SI: 'Bọc cách điện silicone (CD2)', TWISTER: 'Xoắn + quấn AL/PET (CD3 + CD4)', EXTRUDER_TP: 'Bọc vỏ (CD5); bọc cách điện HDPE/PVC (CD2)' };

export default async function ThamSo({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  await requirePage('tham-so');
  const me = await requireMe();
  const db = await createClient();
  const { cfg, machines, flowMeta } = await loadConfig(db);
  const F = flowOf(cfg);
  const wd = cfg.workdays ?? DEFAULT_WD;
  const { data: log } = await db.schema('app').from('v_kh_param_log').select('*').order('at', { ascending: false }).limit(100);
  const isBgd = hasRole(me.roles, ROLE.params), isKt = hasRole(me.roles, ROLE.rates);
  const edit = sp.sua ?? null;
  const E = (s: string, ok: boolean) => ok && edit === s;
  const mine = [isBgd && 'ca làm việc, tham số xếp lịch, cách nhập dữ liệu máy, giới hạn tăng ca', isKt && 'tốc độ chuẩn, phút đổi máy, thông số dòng chảy (QC, mét/bobin, hạn dùng silicone)'].filter(Boolean).join('; ');
  const head = (sec: string, title: string, ok: boolean, owner: string) => (
    <div className="card-h"><h2>{title}</h2>
      {E(sec, ok) ? <Pill tone="info">Đang sửa</Pill>
        : ok ? <Link href={`/tham-so?sua=${sec}`} scroll={false} className={`btn btn-sm ${edit ? 'pointer-events-none opacity-50' : ''}`} aria-disabled={Boolean(edit)}><Pencil size={14} />Sửa</Link>
        : <LockNote>Chỉ {owner} được sửa</LockNote>}
    </div>
  );
  const foot = (sec: string, hint: string): ReactNode => (
    <div className="flex flex-col gap-2 border-t border-line px-4 py-3">
      <label className="lbl">Lý do thay đổi (bắt buộc)<textarea name="reason" rows={2} required className="inp" placeholder={hint} /></label>
      <div className="flex flex-wrap items-center gap-2">
        <SubmitButton className="btn btn-sm btn-pri">Lưu thay đổi</SubmitButton>
        <Link href="/tham-so" scroll={false} className="btn btn-sm">Hủy</Link>
        <span className="text-[12.5px] text-muted">Lịch áp dụng thay đổi khi Quản lý SX bấm Xếp lại lịch; phần đã chạy và vùng khóa giữ nguyên.</span>
      </div>
    </div>
  );
  const shifts = ['A', 'B', 'C'].map((c) => cfg.shifts.find((s) => s.code === c)!).filter(Boolean);
  const lbl = (k: string) => k === 'cutoff_time' ? cfg.cutoff_time : nf((cfg as unknown as Record<string, number>)[k], k === 'plc_dev_pct' ? 1 : 0);

  return (
    <>
      <Toolbar title="Tham số xếp lịch" reload="/tham-so" />
      <div className="mt-3"><Flash ok={sp.ok} err={sp.err} /></div>
      <Alert tone={mine ? 'ok' : 'info'} title={mine ? `Tài khoản của bạn được sửa: ${mine}` : 'Tài khoản của bạn chỉ xem'}>
        Tốc độ chuẩn, phút đổi máy: TP Kỹ thuật/QA. Ca, ngày làm việc, tham số xếp lịch, cách nhập dữ liệu máy: Giám đốc (chỉ sửa ở trang này). Quản lý SX đề xuất, không sửa trực tiếp. Mọi thay đổi phải ghi lý do và được lưu nhật ký. Người đứng máy và tay nghề khai báo ở <Link href="/may" className="link">Quản lý máy → hồ sơ máy → Người đứng máy</Link>.
      </Alert>

      <div className="flex flex-col gap-4">
        <section className="card">
          <div className="card-h"><h2>Máy và cách nhập dữ liệu</h2>{isBgd ? <span className="text-[13px] font-normal text-muted">Song song / tự động chỉ chọn được khi máy đã khai báo tag PLC</span> : <LockNote>Giám đốc đổi, TP Kỹ thuật/QA đề xuất</LockNote>}</div>
          <div className="overflow-x-auto"><table className="tbl">
            <thead><tr><th>Máy</th><th>Công đoạn</th><th>Người</th><th>Kết nối PLC</th><th>Cách nhập dữ liệu</th></tr></thead>
            <tbody>{machines.map((m) => (
              <tr key={m.code}>
                <td><b>{m.code}</b><div className="text-[12px] text-muted">{m.name}</div></td>
                <td className="text-[12.5px]">{OPNAME[m.machine_type] ?? m.machine_type}</td>
                <td className="text-[12.5px]">{m.operators.join(', ') || <span className="text-bad">Chưa có người</span>}</td>
                <td className="text-[12.5px]">{m.tag_count ? `${m.tag_count} tag đã khai báo` : <span className="text-muted">Chưa kết nối</span>}</td>
                <td>{isBgd ? (
                  <form action={setMode} className="flex flex-wrap items-center gap-1.5">
                    <input type="hidden" name="machine" value={m.code} />
                    <select name="mode" defaultValue={m.data_mode} className="inp w-auto py-1" aria-label={`Cách nhập ${m.code}`}>
                      {Object.entries(MODE).map(([k, v]) => <option key={k} value={k} disabled={k !== 'MANUAL' && !m.tag_count}>{v}{k !== 'MANUAL' && !m.tag_count ? ' (cần PLC)' : ''}</option>)}
                    </select>
                    <input name="reason" className="inp w-[200px] py-1" placeholder="Lý do" aria-label={`Lý do đổi cách nhập ${m.code}`} required />
                    <SubmitButton className="btn btn-sm" pendingText="…">Đổi</SubmitButton>
                  </form>
                ) : <Pill tone={m.data_mode === 'PLC' ? 'ok' : m.data_mode === 'BOTH' ? 'info' : 'mute'}>{MODE[m.data_mode] ?? m.data_mode}</Pill>}</td>
              </tr>
            ))}</tbody>
          </table></div>
          <p className="border-t border-line px-4 py-3 text-[12.5px] text-muted">Tốc độ xếp lịch theo cách nhập: <b>Nhập tay</b> và <b>Song song</b> dùng bảng tốc độ tự nhập của máy (chủng loại × cỡ ruột); <b>Tự động (PLC)</b> dùng tốc độ thực tế đo từ PLC 30 ngày gần nhất, cần ít nhất {nf(F.plc_min_run)} phút chạy cùng mã hoặc cùng cỡ ruột (thông số ở thẻ Dòng chảy), chưa đủ thì dùng bảng tự nhập.</p>
        </section>

        <div className="grid gap-4 xl:grid-cols-2 [&>*]:min-w-0">
          <section className="card">
            {head('shifts', 'Ca làm việc', isBgd, 'Giám đốc')}
            <form action={saveShifts}>
              <div className="overflow-x-auto"><table className="tbl">
                <thead><tr><th>Ca</th><th>Giờ</th><th className="num">Nghỉ (phút)</th><th className="num">Phút chạy</th><th>Trạng thái</th></tr></thead>
                <tbody>{shifts.map((s) => E('shifts', isBgd) ? (
                  <tr key={s.code}><td><b>{s.code}</b></td>
                    <td className="whitespace-nowrap"><input name={`start_${s.code}`} defaultValue={s.start_time} className="inp mono inline-block w-[76px] py-1" aria-label={`Ca ${s.code} bắt đầu`} /> – <input name={`end_${s.code}`} defaultValue={s.end_time} className="inp mono inline-block w-[76px] py-1" aria-label={`Ca ${s.code} kết thúc`} /></td>
                    <td className="num"><input name={`break_${s.code}`} defaultValue={String(s.break_min)} className="inp w-[70px] py-1 text-right" aria-label={`Ca ${s.code} phút nghỉ`} /></td>
                    <td className="num text-muted">{shiftRun(s)}</td>
                    <td>{s.code === 'A' ? <Pill tone="ok">Luôn dùng</Pill> : <label className="flex items-center gap-1.5 text-[13.5px]"><input type="checkbox" name={`active_${s.code}`} value="1" defaultChecked={s.active} />Dùng</label>}</td></tr>
                ) : (
                  <tr key={s.code}><td><b>{s.code}</b></td><td className="mono">{s.start_time} – {s.end_time}</td><td className="num">{s.break_min}′</td><td className="num">{shiftRun(s)}</td>
                    <td>{s.active ? <Pill tone="ok">Dùng</Pill> : <Pill>Tắt{s.code === 'B' ? ' · bật khi tuyển ca 2' : ''}</Pill>}</td></tr>
                ))}</tbody>
              </table></div>
              <div className="flex flex-wrap items-center gap-3 border-t border-line px-4 py-3 text-[13.5px]">
                <span className="text-muted">Ngày làm việc:</span>
                {E('shifts', isBgd) ? <>
                  <input type="hidden" name="wd_old" value={wd.join(',')} />
                  {DOW.map(([d, t]) => <label key={d} className="inline-flex items-center gap-1.5"><input type="checkbox" name="workday" value={d} defaultChecked={wd.includes(d)} />{t}</label>)}
                </> : <b>{DOW.filter(([d]) => wd.includes(d)).map(([, t]) => t).join(', ')}</b>}
              </div>
              {E('shifts', isBgd) ? foot('shifts', 'Ví dụ: Đã tuyển đủ người ca 2 từ 09/11.') : <p className="px-4 py-3 text-[12.5px] text-muted">Giai đoạn chạy thử 1 ca. Bật ca B khi đã có tổ trưởng và 4–5 công nhân ca 2.</p>}
            </form>
          </section>

          <section className="card">
            {head('params', 'Tham số chung', isBgd, 'Giám đốc')}
            <form action={saveConfig}>
              <div className="overflow-x-auto"><table className="tbl"><tbody>
                {PARAMS.map(([k, l, u, r]) => (
                  <tr key={k}><td>{l}</td><td className="num whitespace-nowrap">{E('params', isBgd)
                    ? <><input name={k} defaultValue={k === 'cutoff_time' ? cfg.cutoff_time : numIn((cfg as unknown as Record<string, number>)[k])} className={`inp inline-block w-[90px] py-1 text-right ${k === 'cutoff_time' ? 'mono' : ''}`} aria-label={l} /> <span className="text-[12.5px] text-muted">{u}</span><div className="text-[12px] text-muted">{r}</div></>
                    : <><b>{lbl(k)}{u === '%' ? '%' : ''}</b>{u !== '%' ? ' ' + u : ''}</>}</td></tr>
                ))}
              </tbody></table></div>
              {E('params', isBgd) && foot('params', 'Ví dụ: Chạy thử tháng đầu, giữ dự phòng 20%.')}
            </form>
          </section>

          <section className="card">
            {head('rates', 'Tốc độ mặc định theo công đoạn', isKt, 'TP Kỹ thuật/QA')}
            <form action={saveRates}>
              <input type="hidden" name="ops" value={cfg.rates.map((r) => r.op_code).join(',')} />
              <div className="overflow-x-auto"><table className="tbl">
                <thead><tr><th>Công đoạn</th><th className="num">Cỡ &lt; {nf(F.size_large_mm2, 2)} mm²</th><th className="num">Cỡ ≥ {nf(F.size_large_mm2, 2)} mm²</th><th>Đơn vị</th></tr></thead>
                <tbody>{cfg.rates.map((r) => (
                  <tr key={r.op_code}><td>{r.label}</td>
                    {(['small', 'large'] as const).map((j) => <td key={j} className="num">{E('rates', isKt)
                      ? <input name={`${j}_${r.op_code}`} defaultValue={numIn(j === 'small' ? r.rate_small : r.rate_large)} className="inp inline-block w-[80px] py-1 text-right" aria-label={`${r.label} ${j === 'small' ? 'cỡ nhỏ' : 'cỡ lớn'}`} />
                      : nf(j === 'small' ? r.rate_small : r.rate_large)}</td>)}
                    <td className="text-[12.5px] text-muted">{r.unit.includes('/') ? r.unit : `${r.unit}/phút`}</td></tr>
                ))}</tbody>
              </table></div>
              {E('rates', isKt) ? foot('rates', 'Ví dụ: Theo kết quả chạy thử tuần 44, line silicone chạy ổn định 85 m/phút.')
                : <p className="px-4 py-3 text-[12.5px] text-muted">{cfg.rates.some((r) => !r.confirmed) ? <><Pill tone="warn">Giả định · chờ TP Kỹ thuật/QA ban hành</Pill> </> : <><Pill tone="ok">Đã ban hành</Pill> </>}Cáp chống nhiễu chạy xoắn và quấn AL/PET cùng lượt nên lấy tốc độ chậm hơn của hai bước.</p>}
              <p className="border-t border-line px-4 py-3 text-[12.5px] text-muted">Xếp lịch dùng <b>tốc độ khai báo của từng máy</b> ở <Link href="/may/toc-do" className="link">Quản lý máy → Tốc độ</Link> ({(cfg.speeds ?? []).length ? `${machines.filter((m) => (cfg.speeds ?? []).some((x) => x.machine_code === m.code)).map((m) => m.code).join(', ')} đã khai báo` : 'chưa máy nào khai báo'}); máy hoặc công đoạn chưa khai báo thì dùng bảng này.</p>
            </form>
          </section>

          <section className="card">
            {head('setup', 'Phút đổi máy', isKt, 'TP Kỹ thuật/QA')}
            <form action={saveChangeovers}>
              <input type="hidden" name="codes" value={cfg.changeovers.map((c) => c.code).join(',')} />
              <div className="overflow-x-auto"><table className="tbl">
                <thead><tr><th>Công đoạn</th><th>Loại đổi</th><th className="num">Phút</th></tr></thead>
                <tbody>{cfg.changeovers.map((c) => (
                  <tr key={c.code}><td className="text-[12.5px]">{c.op_code}</td><td>{c.label}</td>
                    <td className="num">{E('setup', isKt) ? <input name={`min_${c.code}`} defaultValue={String(c.minutes)} className="inp inline-block w-[80px] py-1 text-right" aria-label={c.label} /> : c.minutes}</td></tr>
                ))}</tbody>
              </table></div>
              {E('setup', isKt) ? foot('setup', 'Ví dụ: Purge silicone thực tế 40 phút.') : <p className="px-4 py-3 text-[12.5px] text-muted">Đã gồm thời gian lấy mẫu đầu mã. Đổi công đoạn trên line vỏ (bọc cách điện ↔ bọc vỏ) tính như đổi mã.</p>}
            </form>
          </section>
        </div>


        <section className="card">
          {head('flow', 'Dòng chảy, máy trộn, tăng ca', isBgd || isKt, 'Giám đốc, TP Kỹ thuật/QA')}
          <form action={saveFlow}>
            <input type="hidden" name="bgd" value={isBgd ? '1' : '0'} />
            <div className="grid gap-4 p-4 lg:grid-cols-3 [&>*]:min-w-0">
              <div>
                <h3 className="mb-2 text-[13.5px] font-semibold">Gối đầu theo bobin + QC <span className="font-normal text-muted">(TP KT/QA)</span></h3>
                <table className="tbl"><tbody>
                  <tr><td>Thời gian QC một bobin</td><td className="num">{E('flow', isBgd || isKt) ? <input name="qc_min" defaultValue={numIn(flowMeta.qc_set)} className="inp inline-block w-[80px] py-1 text-right" aria-label="Thời gian QC" /> : <b>{nf(flowMeta.qc_set)}</b>} phút</td></tr>
                  <tr><td colSpan={2} className="text-[12.5px]">{E('flow', isBgd || isKt) ? <label className="inline-flex items-center gap-1.5"><input type="checkbox" name="qc_learn" value="1" defaultChecked={flowMeta.qc_learn} />MES tự học từ phiếu hoàn thành (trung vị 30 ngày, cần ≥ {QC_LEARN_MIN_SAMPLES} bobin)</label>
                    : <>MES tự học: <b>{flowMeta.qc_learn ? 'bật' : 'tắt'}</b></>} · hiện {flowMeta.qc_learned.n} bobin{flowMeta.qc_learned.median != null ? `, trung vị ${nf(flowMeta.qc_learned.median)} phút` : ''} · đang dùng <b>{nf(F.qc_min)} phút</b></td></tr>
                  {(['CD1', 'CD2', 'CD3', 'CD5', 'CD6'] as Op[]).map((op) => (
                    <tr key={op}><td>{OP_SHORT[op]}: mét một bobin{op === 'CD6' ? ' (bobin gỗ)' : ''}</td><td className="num whitespace-nowrap">{E('flow', isBgd || isKt)
                      ? <input name={`unit_${op}`} defaultValue={numIn(F.unit_m[op])} className="inp inline-block w-[90px] py-1 text-right" aria-label={`Mét một bobin ${op}`} /> : <b>{nf(F.unit_m[op])}</b>} m</td></tr>
                  ))}
                </tbody></table>
              </div>
              <div>
                <h3 className="mb-2 text-[13.5px] font-semibold">Máy trộn, đệm an toàn <span className="font-normal text-muted">(TP KT/QA)</span></h3>
                <table className="tbl"><tbody>
                  <tr><td>Hạn dùng silicone đã pha lưu hóa</td><td className="num whitespace-nowrap">{E('flow', isBgd || isKt) ? <input name="pot_life_h" defaultValue={numIn(F.pot_life_h)} className="inp inline-block w-[80px] py-1 text-right" aria-label="Hạn dùng silicone" /> : <b>{nf(F.pot_life_h, Number.isInteger(F.pot_life_h) ? 0 : 1)}</b>} giờ</td></tr>
                  <tr><td>kg một mẻ trộn</td><td className="num whitespace-nowrap">{E('flow', isBgd || isKt) ? <input name="mix_batch_kg" defaultValue={numIn(F.mix_batch_kg)} className="inp inline-block w-[80px] py-1 text-right" aria-label="kg một mẻ" /> : <b>{nf(F.mix_batch_kg)}</b>} kg</td></tr>
                  {(['CD1', 'CD2', 'CD3', 'CD5'] as Op[]).map((op) => (
                    <tr key={op}><td>Đệm: {OP_SHORT[op].toLowerCase()} đi trước công đoạn sau</td><td className="num whitespace-nowrap">{E('flow', isBgd || isKt)
                      ? <input name={`safety_${op}`} defaultValue={F.safety_min[op] ? numIn(F.safety_min[op]!) : ''} placeholder="0" className="inp inline-block w-[80px] py-1 text-right" aria-label={`Đệm an toàn ${op}`} /> : <b>{nf(F.safety_min[op] ?? 0)}</b>} phút</td></tr>
                  ))}
                  <tr><td>Ngưỡng cỡ lớn (tốc độ mặc định)</td><td className="num whitespace-nowrap">{E('flow', isBgd || isKt) ? <input name="size_large_mm2" defaultValue={numIn(F.size_large_mm2)} className="inp inline-block w-[80px] py-1 text-right" aria-label="Ngưỡng cỡ lớn" /> : <b>{nf(F.size_large_mm2, 2)}</b>} mm²</td></tr>
                  <tr><td>Phút chạy tối thiểu để tin tốc độ PLC</td><td className="num whitespace-nowrap">{E('flow', isBgd || isKt) ? <input name="plc_min_run" defaultValue={numIn(F.plc_min_run)} className="inp inline-block w-[80px] py-1 text-right" aria-label="Phút chạy PLC tối thiểu" /> : <b>{nf(F.plc_min_run)}</b>} phút</td></tr>
                </tbody></table>
              </div>
              <div>
                <h3 className="mb-2 text-[13.5px] font-semibold">Giới hạn tăng ca, gom lô <span className="font-normal text-muted">(Giám đốc)</span></h3>
                <table className="tbl"><tbody>
                  {([['mix_early_max_h', 'Trộn sớm trước ca tối đa', flowMeta.levers.early_max_h, 'giờ'], ['ot_max_min', 'Tăng ca tối đa mỗi ngày', flowMeta.levers.ot_max_min, 'phút/người'],
                    ['ot_month_h', 'Tăng ca tối đa mỗi tháng', flowMeta.levers.ot_month_h, 'giờ/người']] as [string, string, number, string][]).map(([k, l, v, u]) => (
                    <tr key={k}><td>{l}</td><td className="num whitespace-nowrap">{E('flow', isBgd) ? <input name={k} defaultValue={numIn(v)} className="inp inline-block w-[80px] py-1 text-right" aria-label={l} /> : <b>{nf(v, Number.isInteger(v) ? 0 : 1)}</b>} {u}</td></tr>
                  ))}
                  <tr><td>Khung coi như bắt đầu cùng lúc (gom lô)</td><td className="num whitespace-nowrap">{E('flow', isBgd) ? <input name="pick_window_min" defaultValue={F.pick_window_min == null ? '' : numIn(F.pick_window_min)} placeholder="nửa ca" className="inp inline-block w-[80px] py-1 text-right" aria-label="Khung coi như cùng lúc" /> : <b>{F.pick_window_min == null ? 'nửa ca' : nf(F.pick_window_min)}</b>} phút</td></tr>
                  <tr><td colSpan={2} className="text-[12.5px] text-muted">Luật Lao động 2019: làm thêm ≤ 50 % giờ làm bình thường trong ngày, ≤ 40 giờ/tháng, người lao động đồng ý. Tăng ca, trộn sớm cụ thể: TP SX đề xuất ở Lịch máy → Tối ưu &amp; tăng ca, Giám đốc duyệt.</td></tr>
                </tbody></table>
              </div>
            </div>
            {E('flow', isBgd || isKt) ? foot('flow', 'Ví dụ: Đo thực tế tuần 44: QC trả kết quả trung bình 90 phút, silicone pha dùng tối đa 8 giờ.')
              : <p className="border-t border-line px-4 py-3 text-[12.5px] text-muted">Thuật toán xếp lịch không dùng số cố định: đổi các thông số này (hoặc tốc độ máy) rồi bấm Xếp lại lịch, MES tự tính lại gối đầu, máy cổ chai, thứ tự lô và đề xuất tăng ca.</p>}
          </form>
        </section>
        <section className="card">
          <div className="card-h"><h2>Nhật ký thay đổi tham số</h2><span className="text-[13px] font-normal text-muted">lưu vĩnh viễn, không sửa xóa được</span></div>
          <div className="overflow-x-auto"><table className="tbl">
            <thead><tr><th>Lúc</th><th>Người sửa</th><th>Mục</th><th>Tham số</th><th className="num">Cũ</th><th className="num">Mới</th><th>Lý do</th></tr></thead>
            <tbody>{(log ?? []).length ? (log ?? []).map((l) => (
              <tr key={l.id}><td className="whitespace-nowrap">{df(l.at, true)}</td><td className="text-[12.5px]">{l.user_name ?? ''}</td><td className="text-[12.5px]">{l.section}</td><td>{l.item}</td>
                <td className="max-w-[240px] break-words text-right tabular-nums text-muted">{l.old_value}</td><td className="max-w-[240px] break-words text-right tabular-nums"><b>{l.new_value}</b></td><td className="text-[12.5px]">{l.reason}</td></tr>
            )) : <tr><td colSpan={7} className="text-[13px] text-muted">Chưa có thay đổi nào.</td></tr>}</tbody>
          </table></div>
        </section>
      </div>
    </>
  );
}
