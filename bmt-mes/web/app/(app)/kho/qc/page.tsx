import { Empty, Flash, Pill, StatusPill, Tabs, Toolbar } from '@/components/ui';
import { SubmitButton } from '@/components/submit-button';
import { df, nf } from '@/lib/format';
import { KIND_NAMES, QC_STATUS, hasRole } from '@/lib/kho';
import { STAGE_NAMES, qcTestsFor } from '@/lib/qc';
import { can, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { failLot, passLot, rejectLot } from './actions';

export const metadata = { title: 'Kiểm tra chất lượng' };

type Lot = {
  lot_id: string; lot_no: string; item_kind: string; qc_status: string; supplier_lot: string | null; mfg_date: string | null; exp_date: string | null;
  created_at: string; weight_kg: number | null; item_code: string; item_name: string; uom: string; requires_coa: boolean | null; supplier_name: string | null;
  wo_no: string | null; op_code: string | null; qty: number; hu_count: number; ncr_no: string | null; ncr_text: string | null;
  total_kgkm: number | null; rdc_limit: number | null; od_mm: number | null;
  wip_stage: string | null; slip_no: string | null; operator_code: string | null; machine_code: string | null; carrier_code: string | null;
  net_kg: number | null; qty_estimated: boolean | null; readings: { spark_faults?: number; od_mm?: number } | null; made_at: string | null; wait_min: number;
};

const QC_LIMIT_MIN = 120;
const waitText = (m: number) => (m >= 60 ? `${Math.floor(m / 60)} giờ ${m % 60} phút` : `${m} phút`);

export default async function QcPage({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string; tab?: string }> }) {
  const sp = await searchParams;
  const me = await requirePerm('quality', 'view');
  const tab = sp.tab === 'cach-ly' ? 'cach-ly' : 'cho';
  const supabase = await createClient();
  const { data } = await supabase.schema('app').from('v_qc_queue').select('*').order('created_at').returns<Lot[]>();
  const all = data ?? [];
  const pending = all.filter((l) => l.qc_status === 'PENDING');
  const held = all.filter((l) => l.qc_status === 'QUARANTINE');
  const rows = tab === 'cho' ? pending : held;
  const canAct = can(me, 'quality', 'edit');
  const tp = hasRole(me, 'KT_TP');
  const back = `/kho/qc${tab === 'cach-ly' ? '?tab=cach-ly' : ''}`;
  return (
    <>
      <Toolbar title="Kiểm tra chất lượng" reload="/kho/qc" />
      <Tabs active={tab} items={[
        { key: 'cho', label: 'Chờ kiểm tra', href: '/kho/qc', count: pending.length },
        { key: 'cach-ly', label: 'Cách ly / NCR', href: '/kho/qc?tab=cach-ly', count: held.length },
      ]} />
      <Flash ok={sp.ok} err={sp.err} />
      <p className="mb-3 text-[13px] text-muted">
        QC lấy mẫu từng bobin sau mỗi công đoạn, trả kết quả trong 2 giờ: Đạt thì dán tem xanh QC PASS (chỉ bobin này được lắp vào máy sau),
        Không đạt thì dán tem đỏ, đưa vào ô cách ly, TP Kỹ thuật/QA quyết định sửa, hạ cấp hay phế. Không ai tự ký QC PASS cho bobin mình làm.
        {tab === 'cach-ly' && ' Lô cách ly: chỉ TP Kỹ thuật/QA được chuyển Đạt (nhận có điều kiện) hoặc Không nhận.'}
      </p>
      {rows.length === 0 ? <div className="card"><Empty>{tab === 'cho' ? 'Không có lô chờ kiểm tra.' : 'Không có lô cách ly.'}</Empty></div> : (
        <div className="flex flex-col gap-3">
          {rows.map((l) => (
            <details key={l.lot_id} className="card">
              <summary className="flex cursor-pointer list-none flex-wrap items-center gap-x-4 gap-y-1 px-4 py-3">
                <span className="mono font-medium">{l.lot_no}</span>
                <Pill tone="cu">{KIND_NAMES[l.item_kind] ?? l.item_kind}</Pill>
                <span><span className="mono">{l.item_code}</span> · {l.item_name}</span>
                <span className="text-muted">{nf(l.qty, 2)} {l.uom} · {l.hu_count} đơn vị</span>
                {l.supplier_name && <span className="text-muted">{l.supplier_name}{l.supplier_lot ? ` · lô ${l.supplier_lot}` : ''}</span>}
                {l.wo_no && <span className="text-muted">Lệnh {l.wo_no} · {STAGE_NAMES[l.item_kind === 'FG' ? 'FG' : l.wip_stage ?? ''] ?? l.op_code}</span>}
                {l.carrier_code && <span className="text-muted">bobin {l.carrier_code}</span>}
                {l.qc_status === 'PENDING' && l.item_kind !== 'MAT' && (
                  <Pill tone={l.wait_min > QC_LIMIT_MIN ? 'bad' : 'warn'}>chờ {waitText(l.wait_min)}</Pill>
                )}
                {l.exp_date && <span className="text-muted">HSD {df(l.exp_date)}</span>}
                <span className="ml-auto text-[12.5px] text-muted">nhận {df(l.created_at, true)}</span>
                <StatusPill map={QC_STATUS} value={l.qc_status} />
              </summary>
              <div className="border-t border-line p-4">
                {l.ncr_no && <p className="mb-3 rounded bg-bad-soft px-3 py-2 text-[13.5px] text-bad">{l.ncr_no}: {l.ncr_text}</p>}
                {l.item_kind === 'FG' && (l.rdc_limit || l.total_kgkm) && (
                  <p className="mb-3 text-[13px] text-muted">Spec: Rdc ≤ {nf(l.rdc_limit, 2)} Ω/km · OD {nf(l.od_mm, 2)} mm · {nf(l.total_kgkm, 2)} kg/km
                    {l.weight_kg ? ` · bobin thực ${nf(l.weight_kg, 2)} kg` : ''}</p>
                )}
                {l.requires_coa && <p className="mb-3 text-[13px] text-warn">Vật tư cần COA: đối chiếu COA trước khi giải phóng.</p>}
                {l.slip_no && (
                  <p className="mb-3 text-[13px] text-muted">
                    Phiếu {l.slip_no} · máy {l.machine_code ?? '—'} · người làm {l.operator_code} · {nf(l.net_kg, 2)} kg tịnh
                    {l.qty_estimated ? ' · mét ước tính từ kg (mét thật lấy ở line đùn)' : ''}
                    {l.made_at ? ` · xong ${df(l.made_at, true)}` : ''}
                    {l.readings && (l.readings.spark_faults != null || l.readings.od_mm != null) &&
                      ` · số đọc trên chuyền: cao áp ${l.readings.spark_faults ?? '—'} lần báo lỗi, OD ${l.readings.od_mm ?? '—'} mm`}
                  </p>
                )}
                {canAct && (l.qc_status === 'PENDING' || tp) ? (
                  <form action={passLot} className="grid gap-3 md:grid-cols-4">
                    <input type="hidden" name="lot_id" value={l.lot_id} /><input type="hidden" name="lot_no" value={l.lot_no} /><input type="hidden" name="back" value={back} />
                    <input type="hidden" name="item_kind" value={l.item_kind} /><input type="hidden" name="wip_stage" value={l.wip_stage ?? ''} />
                    {qcTestsFor(l.item_kind, l.wip_stage).map((t) => (
                      <label key={t.code} className="lbl">{t.label}{t.unit ? ` (${t.unit})` : ''}{t.periodic ? ' · theo tần suất' : ''}
                        {t.kind === 'pf' ? (
                          <select className="inp" name={`t_${t.code}`} defaultValue=""><option value="">—</option><option value="PASS">Đạt</option><option value="FAIL">Không đạt</option></select>
                        ) : <input className="inp" name={`t_${t.code}`} inputMode={t.kind === 'num' ? 'decimal' : undefined} />}
                      </label>
                    ))}
                    <label className="lbl md:col-span-4">Ghi chú / lỗi phát hiện (bắt buộc khi không đạt)<input className="inp" name="note" /></label>
                    <div className="flex flex-wrap gap-2 md:col-span-4">
                      <SubmitButton className="btn btn-ok" formAction={passLot}>
                        {l.qc_status === 'QUARANTINE' ? 'Nhận có điều kiện (Đạt)' : 'Đạt'}
                      </SubmitButton>
                      {l.qc_status === 'PENDING' && <SubmitButton className="btn btn-bad" formAction={failLot}>Không đạt – cách ly</SubmitButton>}
                      {tp && <SubmitButton className="btn btn-bad-o" formAction={rejectLot}>Không nhận (trả NCC / hủy)</SubmitButton>}
                    </div>
                  </form>
                ) : <p className="text-[13px] text-muted">Chờ TP Kỹ thuật/QA quyết định.</p>}
              </div>
            </details>
          ))}
        </div>
      )}
    </>
  );
}
