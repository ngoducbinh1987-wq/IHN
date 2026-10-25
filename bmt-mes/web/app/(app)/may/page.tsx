import Link from 'next/link';
import { Empty, Flash, Kpi, Pill, StatusPill, Toolbar } from '@/components/ui';
import { MStatus } from '@/components/machine-ui';
import { PLAN_STATE, remainText, vnToday } from '@/lib/machine';
import { can, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Danh sách máy' };

const SEVERITY: Record<string, number> = { OVERDUE: 0, DUE: 1, SOON: 2, OK: 3 };

export default async function MachinesPage({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string }> }) {
  const sp = await searchParams;
  const me = await requirePerm('machine', 'view');
  const supabase = await createClient();
  const today = vnToday();
  const [{ data: machines, error }, { data: plans }, { data: checks }, { data: speeds }, { data: low }, { data: wos }] = await Promise.all([
    supabase.schema('app').from('v_machines').select('*').order('code'),
    supabase.schema('app').from('v_maint_plans').select('id, name, machine_code, line_id, line_code, state, days_left, trigger, every_days, every_hours, every_km, used_days, used_hours, used_km, open_wo, level').eq('active', true),
    supabase.schema('app').from('v_maint_checks').select('machine_id, has_issue, checked_at, note').eq('check_date', today),
    supabase.schema('app').from('v_machine_speeds').select('id, machine_code, label, op_name, std_mpm, wait_days').eq('status', 'PENDING'),
    supabase.schema('app').from('v_machine_components').select('id, machine_id, name, stock, min_stock').eq('low_stock', true),
    supabase.schema('app').from('v_maint_wos').select('id, wo_no, wo_type, machine_code, title, status, eta').in('status', ['OPEN', 'IN_PROGRESS']),
  ]);
  const all = machines ?? [];
  const lines = all.filter((m) => !m.line_id && m.active);
  const inactive = all.filter((m) => !m.line_id && !m.active);
  const units = all.filter((m) => m.line_id);
  const cnt = (s: string) => lines.filter((l) => l.status === s).length;
  const ps = plans ?? [];
  const overdue = ps.filter((p) => p.state === 'OVERDUE' && !p.open_wo);
  const due = ps.filter((p) => (p.state === 'DUE' || p.state === 'SOON') && !p.open_wo);
  const checkOf = (id: string) => (checks ?? []).find((c) => c.machine_id === id);
  const needCheck = lines.filter((l) => !['OFF', 'DOWN'].includes(l.status));
  const checked = needCheck.filter((l) => checkOf(l.id)).length;

  type Item = { tone: 'bad' | 'warn' | 'info'; text: string; href: string; action: string };
  const items: Item[] = [];
  all.filter((m) => m.status === 'DOWN').forEach((m) => items.push({ tone: 'bad', text: `${m.code} hỏng${m.status_note ? ': ' + m.status_note : ''}`, href: m.open_repair_id ? `/may/bao-duong/phieu/${m.open_repair_id}` : `/may/${m.id}`, action: 'Xem phiếu sửa chữa' }));
  overdue.forEach((p) => items.push({ tone: 'bad', text: `${p.line_code} quá hạn bảo dưỡng: ${p.name} (${remainText(p).toLowerCase()})`, href: '/may/bao-duong?loc=can-lam', action: 'Tạo phiếu' }));
  (speeds ?? []).filter((s) => s.wait_days >= 1).forEach((s) => items.push({ tone: 'warn', text: `Tốc độ chuẩn ${s.machine_code} · ${s.label ?? s.op_name} chờ duyệt quá 1 ngày`, href: '/may/toc-do', action: 'Duyệt' }));
  (checks ?? []).filter((c) => c.has_issue && !c.checked_at).forEach((c) => {
    const m = all.find((x) => x.id === c.machine_id);
    items.push({ tone: 'warn', text: `${m?.code ?? ''} checklist đầu ca có vấn đề${c.note ? ': ' + c.note : ''}`, href: '/may/checklist', action: 'Xem checklist' });
  });
  (low ?? []).forEach((c) => {
    const m = all.find((x) => x.id === c.machine_id);
    items.push({ tone: 'warn', text: `Phụ tùng dưới mức tối thiểu: ${c.name} (tồn ${c.stock}, tối thiểu ${c.min_stock}) · ${m?.code ?? ''}`, href: `/may/${c.machine_id}?tab=thong-so`, action: 'Xem máy' });
  });

  const nextPlan = (lineId: string) => ps.filter((p) => p.line_id === lineId)
    .sort((a, b) => (SEVERITY[a.state] ?? 9) - (SEVERITY[b.state] ?? 9) || Number(a.days_left) - Number(b.days_left))[0];

  return (
    <>
      <Toolbar title="Danh sách máy" reload="/may" add={can(me, 'machine', 'config') ? { href: '/may/moi', label: 'Thêm dây chuyền' } : undefined} />
      <div className="mt-4" />
      <Flash ok={sp.ok} err={sp.err ?? error?.message} />
      <div className="mb-4 grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">
        <Kpi label="Đang chạy" value={`${cnt('RUN')}/${lines.length}`} hint={`Dừng ${cnt('STOP')} · chờ việc ${cnt('IDLE')}`} />
        <Kpi label="Bảo dưỡng" value={cnt('MAINT')} tone="info" hint="Dây chuyền đang bảo dưỡng" />
        <Kpi label="Hỏng" value={all.filter((m) => m.status === 'DOWN').length} tone={all.some((m) => m.status === 'DOWN') ? 'bad' : 'ok'} hint={`${(wos ?? []).filter((w) => w.wo_type === 'CM').length} phiếu sửa chữa đang mở`} href="/may/bao-duong" />
        <Kpi label="Bảo dưỡng quá hạn" value={overdue.length} tone={overdue.length ? 'bad' : 'ok'} hint={`Sắp đến hạn ${due.length}`} href="/may/bao-duong?loc=can-lam" />
        <Kpi label="Checklist đầu ca" value={`${checked}/${needCheck.length}`} tone={checked < needCheck.length ? 'warn' : 'ok'} hint="Hôm nay" href="/may/checklist" />
        <Kpi label="Tốc độ chờ duyệt" value={(speeds ?? []).length} tone={(speeds ?? []).some((s) => s.wait_days >= 1) ? 'warn' : 'ok'} hint="TP Kỹ thuật/QA duyệt" href="/may/toc-do" />
      </div>

      {items.length > 0 && (
        <section className="card mb-4">
          <div className="card-h">Cần xử lý<span className="text-[13px] font-normal text-muted">{items.length} việc</span></div>
          <ul className="divide-y divide-line">
            {items.map((i, k) => (
              <li key={k} className="flex flex-wrap items-center gap-3 px-4 py-2.5">
                <span className={`h-2.5 w-2.5 shrink-0 rounded-full ${i.tone === 'bad' ? 'bg-bad' : i.tone === 'warn' ? 'bg-warn' : 'bg-info'}`} aria-hidden />
                <span className="min-w-0 flex-1 text-[14px]">{i.text}</span>
                <Link href={i.href} className="btn btn-sm btn-soft">{i.action}</Link>
              </li>
            ))}
          </ul>
        </section>
      )}

      <section className="card overflow-x-auto">
        <div className="card-h">Dây chuyền<span className="text-[13px] font-normal text-muted">Bấm mã để xem hồ sơ máy</span></div>
        {lines.length ? (
          <table className="tbl">
            <thead><tr><th>Dây chuyền</th><th>Công đoạn</th><th>Người đứng máy</th><th>Trạng thái</th><th>Máy con</th><th>Thông số</th><th>Bảo dưỡng gần nhất</th><th>Checklist hôm nay</th></tr></thead>
            <tbody>
              {lines.map((l) => {
                const p = nextPlan(l.id);
                const c = checkOf(l.id);
                const us = units.filter((u) => u.line_id === l.id).sort((a, b) => a.seq - b.seq);
                return (
                  <tr key={l.id}>
                    <td className="py-3"><Link href={`/may/${l.id}`} className="text-[15px] font-medium text-brand hover:underline">{l.code}</Link>
                      <div className="text-[13px] text-muted">{l.name}</div></td>
                    <td>{l.op_name ?? '—'}</td>
                    <td className="text-[13px]">{l.operators ?? <span className="text-warn">Chưa giao</span>}</td>
                    <td><MStatus value={l.status} since={l.status_since} eta={l.status_eta} /></td>
                    <td className="max-w-[260px] text-[13px]">
                      {us.length ? us.map((u, i) => (
                        <span key={u.id}>{i > 0 && ', '}<Link href={`/may/${u.id}`} className={`hover:underline ${u.status === 'DOWN' ? 'font-medium text-bad' : 'text-ink/80'}`}>{u.unit_kind ?? u.name}</Link></span>
                      )) : <span className="text-muted">Chưa khai báo</span>}
                    </td>
                    <td className="num text-[13px]">{l.spec_total ? `${l.spec_filled}/${l.spec_total}` : '—'}</td>
                    <td className="text-[13px]">{p ? <><StatusPill map={PLAN_STATE} value={p.open_wo ? 'OK' : p.state} /> <span className="text-muted">{p.open_wo ? 'Đã có phiếu' : remainText(p)}</span><div>{p.name}</div></> : <span className="text-muted">Chưa có kế hoạch</span>}</td>
                    <td>{c ? (c.has_issue ? <Pill tone="warn">Có vấn đề</Pill> : <Pill tone="ok">Đạt</Pill>) : ['OFF', 'DOWN'].includes(l.status) ? <span className="text-muted">—</span> : <Pill>Chưa làm</Pill>}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        ) : <Empty>Chưa có dây chuyền nào. {can(me, 'machine', 'config') ? 'Bấm “+ Thêm dây chuyền”.' : 'TP Kỹ thuật/QA khai báo dây chuyền.'}</Empty>}
      </section>
      {inactive.length > 0 && (
        <p className="mt-3 text-[13px] text-muted">Ngừng dùng: {inactive.map((m, i) => <span key={m.id}>{i > 0 && ', '}<Link className="link" href={`/may/${m.id}`}>{m.code}</Link></span>)}</p>
      )}
    </>
  );
}
