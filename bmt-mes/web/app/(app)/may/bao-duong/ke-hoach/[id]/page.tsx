import Link from 'next/link';
import { notFound } from 'next/navigation';
import { Empty, Flash, InfoRow, Pill, StatusPill, Toolbar } from '@/components/ui';
import { Meter } from '@/components/machine-ui';
import { PlanForm } from '@/components/maint-plan-form';
import { SubmitButton } from '@/components/submit-button';
import { ASSIGNEE, LEVEL, PLAN_KIND, PLAN_STATE, WO_STATUS, cycleText, remainText, usedFraction, usedText } from '@/lib/machine';
import { df } from '@/lib/format';
import { can, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { createWo, deleteRow } from '../../../actions';

export const metadata = { title: 'Kế hoạch bảo dưỡng' };

export default async function PlanPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; err?: string; sua?: string }> }) {
  const { id } = await params;
  const sp = await searchParams;
  const me = await requirePerm('machine', 'view');
  const supabase = await createClient();
  const { data: p } = await supabase.schema('app').from('v_maint_plans').select('*').eq('id', id).maybeSingle();
  if (!p) notFound();
  const cfg = can(me, 'machine', 'config');
  const [{ data: wos }, { data: machines }, { data: remind }] = await Promise.all([
    supabase.schema('app').from('v_maint_wos').select('*').eq('plan_id', id).order('created_at', { ascending: false }).limit(20),
    cfg && sp.sua ? supabase.schema('app').from('v_machines').select('id, code, name, unit_kind, line_id').order('code') : Promise.resolve({ data: [] as never[] }),
    supabase.schema('app').from('v_machine_settings').select('value').eq('key', 'remind_days').maybeSingle(),
  ]);
  const back = `/may/bao-duong/ke-hoach/${id}`;
  if (cfg && sp.sua) {
    return (
      <>
        <Toolbar title={`Sửa kế hoạch · ${p.name}`} actions={<Link className="btn" href={back}>Đóng</Link>} />
        <div className="mt-4" />
        <Flash err={sp.err} />
        <PlanForm machines={machines ?? []} plan={p} remind={remind?.value ?? { MINOR: 7, MAJOR: 30 }} back={`${back}?sua=1`} />
      </>
    );
  }
  return (
    <>
      <Toolbar title={p.name} actions={<>
        {can(me, 'machine', 'create') && p.active && !p.open_wo && (
          <form action={createWo}><input type="hidden" name="plan_id" value={id} /><input type="hidden" name="back" value={back} /><SubmitButton>Tạo phiếu bảo dưỡng</SubmitButton></form>
        )}
        {p.open_wo && <Link className="btn btn-pri" href={`/may/bao-duong/phieu/${p.open_wo}`}>Mở phiếu {p.open_wo_no}</Link>}
        {cfg && <Link className="btn btn-soft" href={`${back}?sua=1`}>Sửa</Link>}
        <Link className="btn" href="/may/bao-duong">Đóng</Link>
      </>} />
      <div className="mt-4" />
      <Flash ok={sp.ok} err={sp.err} />
      <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_360px]">
        <section className="card px-4 py-2">
          <InfoRow label="Máy"><Link className="link" href={`/may/${p.machine_id}?tab=bao-duong`}>{p.machine_code} · {p.unit_kind ?? p.machine_name}</Link></InfoRow>
          <InfoRow label="Loại việc">{PLAN_KIND[p.kind]} · {LEVEL[p.level]}</InfoRow>
          <InfoRow label="Chu kỳ">{cycleText(p)}</InfoRow>
          <InfoRow label="Nhắc trước">{p.remind_days} ngày</InfoRow>
          <InfoRow label="Dừng máy">{p.stop_minutes ? `${p.stop_minutes} phút` : 'Không'} · {p.off_shift ? 'làm ngoài giờ ca' : 'làm trong ca'}</InfoRow>
          <InfoRow label="Người làm">{ASSIGNEE[p.assignee_role] ?? p.assignee_role}</InfoRow>
          <InfoRow label="Phụ tùng">{p.parts ?? '—'}</InfoRow>
          <InfoRow label="Lần làm gần nhất">{df(p.last_done_at)}</InfoRow>
          {p.note && <InfoRow label="Ghi chú">{p.note}</InfoRow>}
          <div className="py-2 text-[14px]">
            <div className="mb-1 text-ink/80">Các bước:</div>
            {p.steps?.length ? <ol className="list-decimal space-y-0.5 pl-6">{p.steps.map((s: string, i: number) => <li key={i}>{s}</li>)}</ol> : <span className="text-muted">Chưa khai báo các bước.</span>}
          </div>
        </section>
        <section className="card p-4">
          <div className="mb-2 flex items-center justify-between"><span className="text-[13px] text-muted">Tình trạng</span>
            {p.open_wo ? <Pill tone="info">Đã có phiếu</Pill> : <StatusPill map={PLAN_STATE} value={p.state} />}</div>
          <Meter value={usedFraction(p)} tone={p.state === 'OVERDUE' ? 'bad' : p.state === 'OK' ? 'ok' : 'warn'} />
          <div className="mt-2 text-[14px] font-medium">{remainText(p)}</div>
          <div className="text-[13px] text-muted">{usedText(p)}</div>
          <div className="mt-2 text-[13px]">Dự kiến đến hạn: <b>{df(p.due_date)}</b></div>
          {!p.active && <p className="mt-2 text-[13px] text-warn">Kế hoạch đang tạm ngừng, không nhắc.</p>}
          {cfg && !p.open_wo && (
            <form action={deleteRow} className="mt-4"><input type="hidden" name="table" value="plan" /><input type="hidden" name="id" value={id} /><input type="hidden" name="back" value="/may/bao-duong?loc=tat-ca" />
              <SubmitButton className="btn btn-sm btn-bad-o" pendingText="…">Xóa kế hoạch</SubmitButton></form>
          )}
        </section>
      </div>
      <section className="card mt-4 overflow-x-auto">
        <div className="card-h">Các lần thực hiện</div>
        {(wos ?? []).length ? (
          <table className="tbl">
            <thead><tr><th>Phiếu</th><th>Trạng thái</th><th>Kết quả</th><th>Người làm</th><th>Xong lúc</th><th>Xác nhận</th></tr></thead>
            <tbody>
              {(wos ?? []).map((w) => (
                <tr key={w.id}>
                  <td><Link className="mono font-medium text-brand hover:underline" href={`/may/bao-duong/phieu/${w.id}`}>{w.wo_no}</Link></td>
                  <td><StatusPill map={WO_STATUS} value={w.status} /></td>
                  <td>{w.result === 'OK' ? <Pill tone="ok">Đạt</Pill> : w.result === 'NOT_OK' ? <Pill tone="bad">Chưa đạt</Pill> : '—'}</td>
                  <td>{w.done_by_name ?? '—'}</td><td>{df(w.finished_at, true)}</td><td>{w.confirmed_by_name ?? '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : <Empty>Chưa thực hiện lần nào trên BMT MES.</Empty>}
      </section>
    </>
  );
}
