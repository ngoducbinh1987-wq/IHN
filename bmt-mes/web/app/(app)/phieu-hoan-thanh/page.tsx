import Link from 'next/link';
import { redirect } from 'next/navigation';
import { Printer } from 'lucide-react';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Pill, StatusPill, Toolbar } from '@/components/ui';
import { df, nf } from '@/lib/format';
import { QC_STATUS, hasRole } from '@/lib/kho';
import { can, requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { recordBobbin, voidBobbin } from './actions';

export const metadata = { title: 'Phiếu hoàn thành bobin' };

type Target = {
  wo_id: string; wo_no: string; wo_status: string; wo_qty_m: number; pack_type: string; m_per_pack: number; product_code: string; product_name: string;
  cores: number | null; sheath_color: string | null; insulation_colors: string | null; wo_op_id: string; op_code: string; op_name: string; seq: number;
  machine_type: string; per_core: boolean; planned_m: number | null; good_m: number; machine_code: string | null; slips: number; core_cu_kgkm: number | null;
};
type Slip = {
  id: string; slip_no: string; paper_no: string | null; status: string; void_reason: string | null; recorded_at: string; op_code: string; op_name: string;
  wo_no: string; product_code: string; machine_code: string | null; carrier_code: string | null; operator_code: string; ended_at: string | null;
  gross_kg: number; net_kg: number; qty_m: number; qty_estimated: boolean; scrap_kg: number | null; lot_no: string; qc_status: string;
  inputs: { code: string; left_kg: number | null; used_m: number }[]; recorded_by_name: string | null; true_m: number | null; true_used_kg: number | null;
};
type Hu = { hu_no: string; carrier_code: string | null; lot_no: string; qty: number; gross_kg: number | null; tare_kg: number | null; op_code: string | null; qc_status: string; color: string | null };

// Máy hợp lệ theo công đoạn (bọc PVC/HDPE chạy line vỏ; xoắn + AL/PET cùng máy xoắn)
const MACHINE_TYPES: Record<string, string[]> = {
  CD0: ['MIXER'], CD1: ['BUNCHER'], CD2: ['EXTRUDER_SI', 'EXTRUDER_TP'], CD3: ['TWISTER'], CD4: ['TWISTER'], CD5: ['EXTRUDER_TP'], CD6: [],
};
const vnNow = () => new Date().toLocaleString('sv-SE', { timeZone: 'Asia/Ho_Chi_Minh' }).slice(0, 16).replace(' ', 'T');

export default async function SlipsPage({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string; muc?: string; ngay?: string }> }) {
  const sp = await searchParams;
  const me = await requireMe();
  const canEnter = hasRole(me, 'KT_KHO', 'SX_TP', 'ADMIN');
  if (!canEnter && !can(me, 'production', 'view') && !can(me, 'quality', 'view')) {
    redirect('/?err=' + encodeURIComponent('Bạn chưa được cấp quyền vào trang này'));
  }
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Ho_Chi_Minh' });
  const day = /^\d{4}-\d{2}-\d{2}$/.test(sp.ngay ?? '') ? sp.ngay! : today;
  const supabase = await createClient();
  const [{ data: targets }, { data: slips }, { data: machines }, { data: operators }, { data: reasons }] = await Promise.all([
    supabase.schema('app').from('v_slip_targets').select('*').order('wo_no').order('seq').returns<Target[]>(),
    supabase.schema('app').from('v_bobbin_slips').select('*').eq('work_date', day).order('recorded_at', { ascending: false }).returns<Slip[]>(),
    supabase.schema('master').from('machines').select('code, name, machine_type').eq('active', true).is('inline_with', null).order('code'),
    supabase.schema('master').from('operators').select('code, job').eq('active', true).order('sort'),
    supabase.schema('master').from('reason_codes').select('code, name').eq('kind', 'SCRAP').order('code'),
  ]);
  const all = targets ?? [];
  const sel = all.find((t) => t.wo_op_id === sp.muc) ?? null;
  // Bobin đầu vào gợi ý: BTP cùng mã sản phẩm, công đoạn trước, trong kho BTP
  const { data: hus } = sel
    ? await supabase.schema('app').from('v_hu').select('hu_no, carrier_code, lot_no, qty, gross_kg, tare_kg, op_code, qc_status, color')
        .eq('item_code', sel.product_code).eq('warehouse_code', 'KBTP').eq('status', 'ACTIVE').order('hu_no').returns<Hu[]>()
    : { data: [] as Hu[] };
  const prevHus = (hus ?? []).filter((h) => (h.op_code ?? '') < (sel?.op_code ?? ''));
  const { data: carriers } = sel && canEnter
    ? await supabase.schema('inv').from('carriers').select('code, tare_kg').eq('status', 'EMPTY').order('code')
    : { data: [] as { code: string; tare_kg: number }[] };
  const types = sel ? MACHINE_TYPES[sel.op_code] ?? [] : [];
  const mList = (machines ?? []).filter((m) => types.length === 0 || types.includes(m.machine_type));
  const byWo = new Map<string, Target[]>();
  for (const t of all) byWo.set(t.wo_no, [...(byWo.get(t.wo_no) ?? []), t]);
  const isCd1 = sel?.op_code === 'CD1';
  const isCd6 = sel?.op_code === 'CD6';
  const back = `/phieu-hoan-thanh${sel ? `?muc=${sel.wo_op_id}` : ''}`;

  return (
    <>
      <Toolbar title="Phiếu hoàn thành bobin" reload="/phieu-hoan-thanh" actions={<>
        <Link className="btn btn-soft" href="/kho/qc">Hàng chờ QC</Link>
        <Link className="btn btn-soft" href="/kho/bobin">Bobin (số cố định, bì)</Link>
      </>} />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /></div>
      <p className="mb-3 text-[13px] text-muted">
        Công nhân ghi phiếu giấy khi xong mỗi bobin; Kế toán SX nhập ngay khi nhận phiếu (vắng thì TP SX nhập thay). Nhập xong bobin chuyển Chờ QC và QC được báo.
        Chỉ bobin có tem QC PASS mới lắp được vào công đoạn sau. Bện chỉ cần kg: mét ước tính từ kg, mét thật lấy ở đồng hồ line đùn khi bọc.
      </p>

      <div className="grid gap-4 xl:grid-cols-[340px_minmax(0,1fr)]">
        <section className="card self-start">
          <div className="card-h">Lệnh SX đang chạy · công đoạn</div>
          {all.length === 0 ? <Empty>Chưa có lệnh sản xuất đã phát.</Empty> : (
            <div className="max-h-[70vh] overflow-y-auto">
              {[...byWo.entries()].map(([wo, ops]) => (
                <div key={wo} className="border-b border-line px-4 py-2.5">
                  <div className="text-[13.5px]"><span className="mono font-medium">{wo}</span> · {ops[0].product_code}</div>
                  <div className="mt-1.5 flex flex-wrap gap-1.5">
                    {ops.map((o) => (
                      <Link key={o.wo_op_id} href={`/phieu-hoan-thanh?muc=${o.wo_op_id}`}
                        className={`rounded border px-2 py-1 text-[12.5px] ${o.wo_op_id === sel?.wo_op_id ? 'border-brand bg-brand text-white' : 'border-line hover:bg-sunk'}`}>
                        {o.op_code} · {o.op_name}{o.slips ? ` (${o.slips})` : ''}
                      </Link>
                    ))}
                  </div>
                </div>
              ))}
            </div>
          )}
        </section>

        <section className="card">
          {!sel ? <Empty>Chọn lệnh sản xuất và công đoạn ghi trên phiếu giấy.</Empty> : (
            <>
              <div className="card-h">
                <span>{sel.wo_no} · {sel.product_code} · {sel.op_code} {sel.op_name}</span>
                <Link className="btn btn-sm" href={`/in/phieu-hoan-thanh?muc=${sel.wo_op_id}`} target="_blank"><Printer size={15} />In phiếu trống</Link>
              </div>
              <p className="px-4 pt-3 text-[13px] text-muted">
                Đã nhập {sel.slips} bobin · {nf(sel.good_m)} m{sel.planned_m ? ` / kế hoạch ${nf(sel.planned_m)} m` : ''}{sel.per_core ? ' (mét lõi)' : ''}
                {isCd1 && sel.core_cu_kgkm ? ` · ruột ${nf(sel.core_cu_kgkm, 2)} kg/km một lõi` : ''}
              </p>
              {canEnter ? (
                <form action={recordBobbin} className="grid gap-3 p-4 md:grid-cols-4">
                  <input type="hidden" name="wo_id" value={sel.wo_id} /><input type="hidden" name="op_code" value={sel.op_code} />
                  <input type="hidden" name="wo_op_id" value={sel.wo_op_id} />
                  <label className="lbl"><span className={isCd6 ? '' : 'req'}>Số bobin</span>
                    <input className="inp inp-y mono uppercase" name="carrier" list="carriers" required={!isCd6} placeholder={isCd6 ? 'Cuộn PE: để trống' : 'VD: B015'} />
                  </label>
                  <label className="lbl"><span className={isCd6 ? '' : 'req'}>Máy</span>
                    <select className="inp inp-y" name="machine_code" required={!isCd6} defaultValue={sel.machine_code ?? (mList.length === 1 ? mList[0].code : '')}>
                      <option value="">—</option>{mList.map((m) => <option key={m.code} value={m.code}>{m.code} · {m.name}</option>)}
                    </select></label>
                  <label className="lbl"><span className="req">Người làm</span>
                    <select className="inp inp-y" name="operator_code" required defaultValue="">
                      <option value="">—</option>{(operators ?? []).map((o) => <option key={o.code} value={o.code}>{o.code} · {o.job}</option>)}
                    </select></label>
                  <label className="lbl">Số phiếu giấy<input className="inp" name="paper_no" /></label>
                  <label className="lbl">Bắt đầu<input className="inp" type="datetime-local" name="started_at" /></label>
                  <label className="lbl"><span className="req">Hoàn thành</span><input className="inp inp-y" type="datetime-local" name="ended_at" required defaultValue={vnNow()} /></label>
                  <label className="lbl"><span className="req">Khối lượng cân (kg)</span><input className="inp inp-y text-right" name="gross_kg" inputMode="decimal" required /></label>
                  <span className="self-end pb-2 text-[12.5px] text-muted">MES tự trừ bì bobin.</span>
                  {!isCd1 && !isCd6 && <>
                    <label className="lbl"><span className="req">Đồng hồ mét lúc bắt đầu</span><input className="inp inp-y text-right" name="meter_start" inputMode="decimal" required /></label>
                    <label className="lbl"><span className="req">Đồng hồ mét lúc xong</span><input className="inp inp-y text-right" name="meter_end" inputMode="decimal" required /></label>
                  </>}
                  {isCd6 && <label className="lbl"><span className="req">Chiều dài cuộn (m)</span><input className="inp inp-y text-right" name="qty_m" inputMode="decimal" required /></label>}
                  {(sel.op_code === 'CD2' || sel.op_code === 'CD5') && <>
                    <label className="lbl">Cao áp: số lần báo lỗi<input className="inp text-right" name="spark_faults" inputMode="numeric" /></label>
                    <label className="lbl">OD đọc trên chuyền (mm)<input className="inp text-right" name="od_mm" inputMode="decimal" /></label>
                  </>}
                  {sel.op_code === 'CD2' && <label className="lbl">Màu lõi<input className="inp" name="color" placeholder={sel.insulation_colors ?? ''} /></label>}

                  {!isCd1 && (
                    <fieldset className="rounded border border-line p-3 md:col-span-4">
                      <legend className="px-1 text-[13px] text-muted">Bobin đầu vào đã lắp (chỉ bobin có tem QC PASS) · tháo ra còn dư thì ghi kg còn lại</legend>
                      <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
                        {[0, 1, 2, 3, 4, 5].slice(0, sel.op_code === 'CD3' || sel.op_code === 'CD4' ? 6 : 3).map((i) => (
                          <div key={i} className="flex gap-2">
                            <input className="inp mono uppercase" name={`in_code_${i}`} list="inputs" placeholder="Số bobin / mã tem" aria-label={`Bobin đầu vào ${i + 1}`} />
                            <input className="inp w-28 text-right" name={`in_left_${i}`} inputMode="decimal" placeholder="kg dư" aria-label={`Kg còn dư ${i + 1}`} />
                          </div>
                        ))}
                      </div>
                      {prevHus.length > 0 && (
                        <p className="mt-2 text-[12.5px] text-muted">Trong kho BTP: {prevHus.map((h) => `${h.carrier_code ?? h.hu_no} (${h.op_code}, ${nf(h.qty)} m${h.color ? ', ' + h.color : ''}, ${h.qc_status === 'PASSED' ? 'QC PASS' : 'chưa QC'})`).join(' · ')}</p>
                      )}
                    </fieldset>
                  )}
                  <label className="lbl md:col-span-2">Chủng loại, số lô NVL đã dùng<input className="inp" name="materials" placeholder="VD: sợi đồng lô CU-2610-03; silicone lô SI-12" /></label>
                  <label className="lbl">Phế của bobin (kg)<input className="inp text-right" name="scrap_kg" inputMode="decimal" /></label>
                  <label className="lbl">Lý do phế<select className="inp" name="scrap_reason" defaultValue=""><option value="">—</option>{(reasons ?? []).map((r) => <option key={r.code} value={r.code}>{r.name}</option>)}</select></label>
                  <label className="lbl md:col-span-4">Ghi chú<input className="inp" name="note" /></label>
                  <div className="md:col-span-4"><SubmitButton>Lưu phiếu → Chờ QC</SubmitButton></div>
                  <datalist id="carriers">{(carriers ?? []).map((c) => <option key={c.code} value={c.code}>bì {nf(c.tare_kg, 1)} kg</option>)}</datalist>
                  <datalist id="inputs">{prevHus.filter((h) => h.qc_status === 'PASSED').map((h) => <option key={h.hu_no} value={h.carrier_code ?? h.hu_no}>{h.lot_no}</option>)}</datalist>
                </form>
              ) : <p className="p-4 text-[13px] text-muted">Chỉ Kế toán SX (vắng thì TP SX) nhập phiếu hoàn thành.</p>}
            </>
          )}
        </section>
      </div>

      <section className="card mt-4 overflow-x-auto">
        <div className="card-h">
          <span>Phiếu đã nhập ngày {df(day)}</span>
          <form className="flex items-center gap-2"><input className="inp" type="date" name="ngay" defaultValue={day} aria-label="Ngày" /><button className="btn btn-sm">Xem</button></form>
        </div>
        {(slips ?? []).length === 0 ? <Empty>Chưa có phiếu hoàn thành ngày này.</Empty> : (
          <table className="tbl">
            <thead><tr><th>Phiếu</th><th>Lệnh · mã</th><th>CĐ</th><th>Máy</th><th>Bobin</th><th>Người làm</th><th className="num">kg tịnh</th><th className="num">Mét</th><th>Đầu vào</th><th>Lô</th><th>QC</th><th /></tr></thead>
            <tbody>{(slips ?? []).map((s) => (
              <tr key={s.id} className={s.status === 'VOID' ? 'opacity-50' : ''}>
                <td className="mono">{s.slip_no}{s.paper_no ? <div className="text-[12px] text-muted">giấy {s.paper_no}</div> : null}</td>
                <td><span className="mono">{s.wo_no}</span><div className="text-[12px] text-muted">{s.product_code}</div></td>
                <td>{s.op_code}</td><td>{s.machine_code ?? '—'}</td><td className="mono">{s.carrier_code ?? '—'}</td><td>{s.operator_code}</td>
                <td className="num">{nf(s.net_kg, 2)}</td>
                <td className="num">{nf(s.qty_m, 1)}{s.qty_estimated ? <div className="text-[12px] text-muted">ước tính{s.true_m ? ` · thật ${nf(s.true_m)} m / ${nf(s.true_used_kg, 1)} kg (line đùn)` : ''}</div> : null}</td>
                <td className="text-[12.5px]">{(s.inputs ?? []).map((i) => `${i.code}${i.left_kg ? ` (dư ${nf(i.left_kg, 1)} kg)` : ''}`).join(', ') || '—'}</td>
                <td className="mono text-[12.5px]">{s.lot_no}</td>
                <td>{s.status === 'VOID' ? <Pill tone="mute">Đã hủy</Pill> : <StatusPill map={QC_STATUS} value={s.qc_status} />}</td>
                <td>
                  {s.status === 'ACTIVE' && hasRole(me, 'KT_KHO', 'ADMIN') && (s.qc_status === 'PENDING' || s.qc_status === 'QUARANTINE') && (
                    <details>
                      <summary className="cursor-pointer text-[12.5px] text-bad">Hủy phiếu</summary>
                      <form action={voidBobbin} className="mt-1 flex gap-1">
                        <input type="hidden" name="slip_id" value={s.id} /><input type="hidden" name="back" value={back} />
                        <input className="inp w-40" name="reason" required placeholder="Lý do (nhập sai…)" aria-label="Lý do hủy" />
                        <SubmitButton className="btn btn-sm btn-bad-o">Hủy</SubmitButton>
                      </form>
                    </details>
                  )}
                </td>
              </tr>
            ))}</tbody>
          </table>
        )}
      </section>
    </>
  );
}
