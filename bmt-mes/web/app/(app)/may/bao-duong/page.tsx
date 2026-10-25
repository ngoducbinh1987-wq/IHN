import Link from 'next/link';
import { Empty, Flash, Kpi, Pill, StatusPill, Tabs, Toolbar } from '@/components/ui';
import { Meter } from '@/components/machine-ui';
import { SubmitButton } from '@/components/submit-button';
import { ASSIGNEE, LEVEL, PLAN_KIND, PLAN_STATE, WO_STATUS, WO_TYPE, cycleText, remainText, usedFraction, vnToday } from '@/lib/machine';
import { df } from '@/lib/format';
import { can, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { createWo } from '../actions';

export const metadata = { title: 'Bảo dưỡng' };

const SEVERITY: Record<string, number> = { OVERDUE: 0, DUE: 1, SOON: 2, OK: 3 };

export default async function MaintPage({ searchParams }: { searchParams: Promise<{ loc?: string; day?: string; ok?: string; err?: string }> }) {
  const sp = await searchParams;
  const me = await requirePerm('machine', 'view');
  const loc = ['can-lam', 'tat-ca', 'phieu'].includes(sp.loc ?? '') ? sp.loc! : 'can-lam';
  const supabase = await createClient();
  const [{ data: plans, error }, { data: wos }, { data: lines }] = await Promise.all([
    supabase.schema('app').from('v_maint_plans').select('*'),
    supabase.schema('app').from('v_maint_wos').select('*').in('status', ['OPEN', 'IN_PROGRESS']).order('created_at', { ascending: false }),
    supabase.schema('app').from('v_machines').select('id, code').is('line_id', null).eq('active', true).order('code'),
  ]);
  const all = (plans ?? []).filter((p) => !sp.day || p.line_id === sp.day);
  const active = all.filter((p) => p.active);
  const cnt = (s: string) => active.filter((p) => p.state === s && !p.open_wo).length;
  const list = (loc === 'can-lam' ? active.filter((p) => p.state !== 'OK' || p.open_wo) : all)
    .sort((a, b) => Number(!a.active) - Number(!b.active) || (SEVERITY[a.state] ?? 9) - (SEVERITY[b.state] ?? 9) || Number(a.days_left) - Number(b.days_left));
  const openWos = (wos ?? []).filter((w) => !sp.day || w.line_id === sp.day);
  const in30 = vnToday(30);
  const upcoming = active.filter((p) => !p.open_wo && p.due_date <= in30).sort((a, b) => a.due_date.localeCompare(b.due_date));
  const canCreate = can(me, 'machine', 'create');
  const back = `/may/bao-duong?loc=${loc}${sp.day ? `&day=${sp.day}` : ''}`;
  const q = (k: string) => `/may/bao-duong?loc=${k}${sp.day ? `&day=${sp.day}` : ''}`;

  return (
    <>
      <Toolbar title="Bảo dưỡng" reload={back}
        add={can(me, 'machine', 'config') ? { href: '/may/bao-duong/ke-hoach/moi', label: 'Thêm kế hoạch bảo dưỡng' } : undefined}
        actions={<Link className="btn btn-soft" href="/may/checklist">Checklist đầu ca</Link>} />
      <Tabs active={loc} items={[
        { key: 'can-lam', label: 'Cần làm', href: q('can-lam'), count: cnt('OVERDUE') + cnt('DUE') + cnt('SOON') },
        { key: 'phieu', label: 'Phiếu đang mở', href: q('phieu'), count: openWos.length },
        { key: 'tat-ca', label: 'Tất cả kế hoạch', href: q('tat-ca') },
      ]} />
      <Flash ok={sp.ok} err={sp.err ?? error?.message} />
      <div className="mb-4 grid grid-cols-2 gap-3 md:grid-cols-5">
        <Kpi label="Quá hạn" value={cnt('OVERDUE')} tone={cnt('OVERDUE') ? 'bad' : 'ok'} hint="Làm ngay" />
        <Kpi label="Đến hạn" value={cnt('DUE')} tone={cnt('DUE') ? 'warn' : 'ok'} hint="Hôm nay" />
        <Kpi label="Sắp đến hạn" value={cnt('SOON')} tone={cnt('SOON') ? 'warn' : 'ok'} hint="Nhỏ trước 7 ngày · lớn trước 30 ngày" />
        <Kpi label="Phiếu bảo dưỡng mở" value={openWos.filter((w) => w.wo_type === 'PM').length} tone="info" />
        <Kpi label="Sửa chữa đang mở" value={openWos.filter((w) => w.wo_type === 'CM').length} tone={openWos.some((w) => w.wo_type === 'CM') ? 'bad' : 'ok'} />
      </div>
      <form className="mb-3 flex flex-wrap items-center gap-2 text-[14px]">
        <input type="hidden" name="loc" value={loc} />
        <label htmlFor="day" className="text-muted">Dây chuyền</label>
        <select id="day" name="day" defaultValue={sp.day ?? ''} className="inp w-auto">
          <option value="">Tất cả</option>{(lines ?? []).map((l) => <option key={l.id} value={l.id}>{l.code}</option>)}
        </select>
        <button className="btn btn-sm" type="submit">Lọc</button>
      </form>

      {loc !== 'phieu' ? (
        <section className="card mb-4 overflow-x-auto">
          {list.length ? (
            <table className="tbl">
              <thead><tr><th>Máy</th><th>Công việc</th><th>Chu kỳ</th><th>Đã dùng</th><th>Trạng thái</th><th>Dự kiến</th><th className="num">Dừng máy</th><th>Người làm</th><th /></tr></thead>
              <tbody>
                {list.map((p) => (
                  <tr key={p.id} className={p.active ? '' : 'opacity-50'}>
                    <td><Link className="font-medium text-brand hover:underline" href={`/may/${p.line_id}?tab=bao-duong`}>{p.line_code}</Link><div className="text-[12.5px] text-muted">{p.unit_kind ?? p.machine_name}</div></td>
                    <td><Link className="font-medium hover:text-brand hover:underline" href={`/may/bao-duong/ke-hoach/${p.id}`}>{p.name}</Link>
                      <div className="text-[12.5px] text-muted">{PLAN_KIND[p.kind]} · {LEVEL[p.level]}{p.active ? '' : ' · tạm ngừng'}</div></td>
                    <td className="text-[13px]">{cycleText(p)}</td>
                    <td className="min-w-[150px]"><Meter value={usedFraction(p)} tone={p.state === 'OVERDUE' ? 'bad' : p.state === 'OK' ? 'ok' : 'warn'} />
                      <div className={`mt-1 text-[12.5px] ${p.state === 'OVERDUE' ? 'text-bad' : 'text-muted'}`}>{remainText(p)}</div></td>
                    <td>{p.open_wo ? <Pill tone="info">Đã có phiếu</Pill> : <StatusPill map={PLAN_STATE} value={p.state} />}</td>
                    <td className="whitespace-nowrap">{p.state === 'OVERDUE' ? 'Làm ngay' : df(p.due_date)}</td>
                    <td className="num whitespace-nowrap">{p.stop_minutes ? `${p.stop_minutes} phút` : '—'}<div className="text-[12px] text-muted">{p.off_shift ? 'ngoài giờ ca' : 'trong ca'}</div></td>
                    <td className="text-[13px]">{ASSIGNEE[p.assignee_role] ?? p.assignee_role}</td>
                    <td>{p.open_wo ? <Link className="btn btn-sm btn-soft" href={`/may/bao-duong/phieu/${p.open_wo}`}>{p.open_wo_no}</Link>
                      : canCreate && p.active && p.state !== 'OK' ? (
                        <form action={createWo}><input type="hidden" name="plan_id" value={p.id} /><input type="hidden" name="back" value={back} /><SubmitButton className="btn btn-sm btn-pri" pendingText="…">Tạo phiếu</SubmitButton></form>
                      ) : canCreate && p.active ? (
                        <form action={createWo}><input type="hidden" name="plan_id" value={p.id} /><input type="hidden" name="back" value={back} /><SubmitButton className="btn btn-sm" pendingText="…">Làm sớm</SubmitButton></form>
                      ) : null}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : <Empty>{loc === 'can-lam' ? 'Không có việc bảo dưỡng nào đến hạn.' : 'Chưa có kế hoạch bảo dưỡng. Bấm “+ Thêm kế hoạch bảo dưỡng”.'}</Empty>}
        </section>
      ) : (
        <section className="card mb-4 overflow-x-auto">
          {openWos.length ? (
            <table className="tbl">
              <thead><tr><th>Phiếu</th><th>Loại</th><th>Dây chuyền</th><th>Nội dung</th><th>Trạng thái</th><th>Ngày</th><th>Dự kiến xong</th></tr></thead>
              <tbody>
                {openWos.map((w) => (
                  <tr key={w.id}>
                    <td><Link className="mono font-medium text-brand hover:underline" href={`/may/bao-duong/phieu/${w.id}`}>{w.wo_no}</Link></td>
                    <td>{w.wo_type === 'CM' ? <Pill tone="bad">{WO_TYPE.CM}</Pill> : WO_TYPE.PM}</td>
                    <td>{w.line_code}{w.machine_code !== w.line_code && <div className="text-[12.5px] text-muted">{w.machine_code}</div>}</td>
                    <td className="min-w-[220px]">{w.title}</td>
                    <td><StatusPill map={WO_STATUS} value={w.status} /></td>
                    <td className="whitespace-nowrap">{df(w.planned_date ?? w.created_at)}</td>
                    <td className="whitespace-nowrap">{w.eta ? df(w.eta, true) : '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : <Empty>Không có phiếu nào đang mở.</Empty>}
        </section>
      )}

      <section className="card overflow-x-auto">
        <div className="card-h">Lịch bảo dưỡng 30 ngày tới<span className="text-[13px] font-normal text-muted">Việc trong ca: Quản lý SX xếp vào kế hoạch ngày; việc ngoài giờ ca không trừ năng lực máy</span></div>
        {upcoming.length ? (
          <table className="tbl">
            <thead><tr><th>Ngày dự kiến</th><th>Dây chuyền</th><th>Việc</th><th>Mức</th><th className="num">Dừng máy</th><th>Khi nào làm</th></tr></thead>
            <tbody>
              {upcoming.map((p) => (
                <tr key={p.id}>
                  <td className="whitespace-nowrap">{p.state === 'OVERDUE' ? <span className="text-bad">Quá hạn</span> : df(p.due_date)}</td>
                  <td>{p.line_code}</td><td>{p.name}<div className="text-[12.5px] text-muted">{p.unit_kind ?? p.machine_name}</div></td>
                  <td>{p.level === 'MAJOR' ? <Pill tone="warn">Lớn</Pill> : 'Nhỏ'}</td>
                  <td className="num">{p.stop_minutes ? `${p.stop_minutes} phút` : '—'}</td>
                  <td>{p.off_shift ? <Pill>Ngoài giờ ca</Pill> : <Pill tone="info">Trong ca · chặn lịch máy</Pill>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : <Empty>Không có việc bảo dưỡng nào trong 30 ngày tới.</Empty>}
      </section>
    </>
  );
}
