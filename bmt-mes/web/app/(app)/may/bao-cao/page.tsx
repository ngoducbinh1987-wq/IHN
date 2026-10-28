import Link from 'next/link';
import { Empty, Flash, Kpi, Pill, StatusPill, Toolbar } from '@/components/ui';
import { WO_STATUS, vnToday } from '@/lib/machine';
import { df, nf } from '@/lib/format';
import { requirePage, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Báo cáo bảo trì' };

type L = { id: string; code: string; name: string; run_h: number; down_h: number; stop_h: number; maint_h: number; pm_done: number; cm_count: number; cm_hours: number; overdue_now: number; checks_done: number; checks_issue: number };
type R = {
  month: string; month_key: string; workdays: number; lines: L[]; run_h: number; down_h: number; pm_done: number; cm_count: number; overdue_now: number;
  repairs: { id: string; wo_no: string; machine: string; title: string; status: string; created_at: string; finished_at: string | null; cause: string | null; action: string | null }[];
  upcoming_major: { machine: string; name: string; due_date: string; stop_minutes: number }[];
  low_stock: { machine: string; name: string; stock: number; min: number }[];
};

const shift = (key: string, n: number) => { const [y, m] = key.split('-').map(Number); const d = new Date(Date.UTC(y, m - 1 + n, 1)); return d.toISOString().slice(0, 7); };

export default async function ReportPage({ searchParams }: { searchParams: Promise<{ thang?: string }> }) {
  const sp = await searchParams;
  await requirePage('may-bao-cao');
  await requirePerm('machine', 'view');
  const cur = vnToday().slice(0, 7);
  const key = /^\d{4}-\d{2}$/.test(sp.thang ?? '') && sp.thang! <= cur ? sp.thang! : cur;
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc('maint_report', { p_month: `${key}-01` });
  const r = data as R | null;
  const pct = (d: number, run: number) => (run > 0 ? (d / run) * 100 : 0);
  return (
    <>
      <Toolbar title={`Báo cáo bảo trì bảo dưỡng tháng ${r?.month ?? key}`} actions={<>
        <Link className="btn" href={`/may/bao-cao?thang=${shift(key, -1)}`}>← Tháng trước</Link>
        {key < cur && <Link className="btn" href={`/may/bao-cao?thang=${shift(key, 1)}`}>Tháng sau →</Link>}
      </>} />
      <div className="mt-4" />
      <Flash err={error?.message} />
      <p className="mb-4 text-[13.5px] text-muted">
        Ngày 1 hằng tháng, BMT MES tự gửi báo cáo tháng trước lên Thông báo và email cho Ban giám đốc (Giám đốc, Chủ tịch). {key === cur && 'Tháng này đang chạy, số liệu tính tới hiện tại.'}
      </p>
      {r && (
        <>
          <div className="mb-4 grid grid-cols-2 gap-3 md:grid-cols-5">
            <Kpi label="Giờ chạy" value={nf(r.run_h, 1)} hint={`${r.workdays} ngày làm việc`} />
            <Kpi label="Dừng do hỏng" value={`${nf(pct(r.down_h, r.run_h), 1)}%`} hint={`${nf(r.down_h, 1)} giờ · mục tiêu ≤ 3%`} tone={pct(r.down_h, r.run_h) > 3 ? 'bad' : 'ok'} />
            <Kpi label="Bảo dưỡng xong" value={r.pm_done} hint="phiếu" tone="info" />
            <Kpi label="Sửa chữa" value={r.cm_count} hint="lần hỏng trong tháng" tone={r.cm_count ? 'warn' : 'ok'} />
            <Kpi label="Đang quá hạn" value={r.overdue_now} hint="việc bảo dưỡng" tone={r.overdue_now ? 'bad' : 'ok'} />
          </div>
          <section className="card mb-4 overflow-x-auto">
            <div className="card-h">Theo dây chuyền</div>
            {r.lines.length ? (
              <table className="tbl">
                <thead><tr><th>Dây chuyền</th><th className="num">Chạy (giờ)</th><th className="num">Dừng (giờ)</th><th className="num">Bảo dưỡng (giờ)</th><th className="num">Hỏng (giờ)</th><th className="num">Dừng do hỏng</th><th className="num">Phiếu BD xong</th><th className="num">Sửa chữa</th><th className="num">Giờ sửa</th><th className="num">Quá hạn</th><th className="num">Checklist</th></tr></thead>
                <tbody>
                  {r.lines.map((l) => {
                    const p = pct(l.down_h, l.run_h);
                    return (
                      <tr key={l.id}>
                        <td><Link className="font-medium text-brand hover:underline" href={`/may/lich-su?may=${l.id}&tu=${key}-01`}>{l.code}</Link><div className="text-[12.5px] text-muted">{l.name}</div></td>
                        <td className="num">{nf(l.run_h, 1)}</td><td className="num">{nf(l.stop_h, 1)}</td><td className="num">{nf(l.maint_h, 1)}</td><td className="num">{nf(l.down_h, 1)}</td>
                        <td className={`num ${p > 3 ? 'font-medium text-bad' : ''}`}>{nf(p, 1)}%</td>
                        <td className="num">{l.pm_done}</td><td className="num">{l.cm_count}</td><td className="num">{nf(l.cm_hours, 1)}</td>
                        <td className={`num ${l.overdue_now ? 'font-medium text-bad' : ''}`}>{l.overdue_now}</td>
                        <td className="num">{l.checks_done}/{r.workdays}{l.checks_issue ? <div className="text-[12px] text-warn">{l.checks_issue} có vấn đề</div> : null}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            ) : <Empty>Chưa có dây chuyền.</Empty>}
          </section>
          <div className="grid gap-4 xl:grid-cols-2">
            <section className="card overflow-x-auto">
              <div className="card-h">Sửa chữa trong tháng</div>
              {r.repairs.length ? (
                <table className="tbl">
                  <thead><tr><th>Phiếu</th><th>Máy</th><th>Nguyên nhân, việc làm</th><th>Trạng thái</th><th>Mở</th><th>Xong</th></tr></thead>
                  <tbody>{r.repairs.map((w) => (
                    <tr key={w.id}>
                      <td><Link className="mono text-brand hover:underline" href={`/may/bao-duong/phieu/${w.id}`}>{w.wo_no}</Link></td><td>{w.machine}</td>
                      <td className="min-w-[200px] text-[13px]">{w.cause ?? w.title}{w.action && <div className="text-muted">{w.action}</div>}</td>
                      <td><StatusPill map={WO_STATUS} value={w.status} /></td><td className="whitespace-nowrap">{df(w.created_at, true)}</td><td className="whitespace-nowrap">{df(w.finished_at, true)}</td>
                    </tr>
                  ))}</tbody>
                </table>
              ) : <Empty>Không có lần hỏng nào.</Empty>}
            </section>
            <section className="card overflow-x-auto">
              <div className="card-h">Bảo dưỡng lớn sắp tới, phụ tùng thiếu</div>
              {r.upcoming_major.length ? (
                <table className="tbl">
                  <thead><tr><th>Ngày dự kiến</th><th>Máy</th><th>Việc</th><th className="num">Dừng máy</th></tr></thead>
                  <tbody>{r.upcoming_major.map((u, i) => <tr key={i}><td>{df(u.due_date)}</td><td>{u.machine}</td><td>{u.name}</td><td className="num">{u.stop_minutes} phút</td></tr>)}</tbody>
                </table>
              ) : <Empty>Không có bảo dưỡng lớn trong 2 tháng tới.</Empty>}
              {r.low_stock.length > 0 && (
                <div className="border-t border-line p-4 text-[14px]">
                  <div className="mb-1 font-medium">Phụ tùng dưới mức tối thiểu</div>
                  <ul className="flex flex-col gap-1">{r.low_stock.map((s, i) => <li key={i}><Pill tone="bad">Thiếu</Pill> {s.name} · {s.machine} · tồn {nf(s.stock, 2)} / tối thiểu {nf(s.min, 2)}</li>)}</ul>
                </div>
              )}
            </section>
          </div>
        </>
      )}
    </>
  );
}
