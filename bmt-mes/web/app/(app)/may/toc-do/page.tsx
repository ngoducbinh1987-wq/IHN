import Link from 'next/link';
import { AlertTriangle } from 'lucide-react';
import { Empty, Flash, Pill, StatusPill, Tabs, Toolbar } from '@/components/ui';
import { SubmitButton } from '@/components/submit-button';
import { SPEED_STATUS } from '@/lib/machine';
import { df, nf } from '@/lib/format';
import { can, requirePage, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { approveAllSpeeds, approveSpeed } from '../actions';

export const metadata = { title: 'Tốc độ sản xuất' };

const TABS = [
  { key: 'hieu-luc', label: 'Đang dùng', st: ['APPROVED', 'PENDING'] },
  { key: 'cho-duyet', label: 'Chờ duyệt', st: ['PENDING'] },
  { key: 'tat-ca', label: 'Tất cả (cả bản cũ)', st: null },
];

export default async function SpeedsPage({ searchParams }: { searchParams: Promise<{ tab?: string; ok?: string; err?: string }> }) {
  const sp = await searchParams;
  await requirePage('may-toc-do');
  const me = await requirePerm('machine', 'view');
  const tab = TABS.find((t) => t.key === sp.tab) ?? TABS[0];
  const supabase = await createClient();
  let q = supabase.schema('app').from('v_machine_speeds').select('id, machine_id, op_code, op_name, machine_code, machine_name, label, product_code, group_code, group_name, core_code, note, std_mpm, range_max, setup_min, status, approved_by_name, approved_at, temp_approval, submitted_at, wait_days').order('op_code').order('machine_code').order('core_code', { nullsFirst: true });
  if (tab.st) q = q.in('status', tab.st);
  const { data, error } = await q;
  const [{ count: pending }, { data: gapRows }] = await Promise.all([
    supabase.schema('app').from('v_machine_speeds').select('id', { count: 'exact', head: true }).eq('status', 'PENDING'),
    supabase.schema('app').rpc('machine_param_gaps'),
  ]);
  const gaps = (gapRows ?? []) as { machine_id: string; machine_code: string; message: string }[];
  const rows = data ?? [];
  const ops = [...new Map(rows.map((r) => [r.op_code, r.op_name])).entries()];
  const canApprove = can(me, 'machine', 'approve');
  const back = `/may/toc-do?tab=${tab.key}`;
  return (
    <>
      <Toolbar title="Tốc độ sản xuất" reload={back} />
      <Tabs active={tab.key} items={TABS.map((t) => ({ key: t.key, label: t.label, href: `/may/toc-do?tab=${t.key}`, count: t.key === 'cho-duyet' ? pending ?? 0 : undefined }))} />
      <Flash ok={sp.ok} err={sp.err ?? error?.message} />
      {canApprove && (pending ?? 0) > 0 && (
        <form action={approveAllSpeeds} className="mb-4 flex flex-wrap items-center gap-3" id="duyet-tat-ca-toc-do">
          <input type="hidden" name="back" value={back} />
          <SubmitButton className="btn btn-sm btn-pri" pendingText="Đang duyệt…">Duyệt tất cả tốc độ chờ duyệt ({pending})</SubmitButton>
          <span className="text-[12.5px] text-muted">mọi máy{me.is_admin ? '' : ', trừ dòng bạn nhập'}. Quản trị sửa / xóa từng dòng ở Hồ sơ máy → Tốc độ & dải hoạt động.</span>
        </form>
      )}
      <p className="mb-4 max-w-4xl text-[13.5px] text-muted">
        Lịch máy chỉ dùng tốc độ khai báo của từng máy (không còn tốc độ giả định theo công đoạn), chọn: riêng mã SP → theo cỡ ruột → chung của máy. Khai báo trong Hồ sơ máy → Tốc độ & dải hoạt động; người khác duyệt; đã duyệt thì chỉ Quản trị hệ thống sửa.
        Đổi tốc độ xong, Quản lý SX bấm Xếp lại lịch để áp dụng.
      </p>
      {gaps.length > 0 && (
        <section className="card mb-4 max-w-4xl" id="may-thieu-thong-so">
          <div className="card-h"><span className="inline-flex items-center gap-1.5 text-bad"><AlertTriangle size={16} />Alarm: máy thiếu thông số tốc độ</span><span className="text-[13px] font-normal text-muted">lịch máy không xếp việc lên máy / cỡ này</span></div>
          <ul className="px-4 py-3 text-[13.5px]">{gaps.map((g, i) => (
            <li key={i}><Link className="font-medium text-brand hover:underline" href={`/may/${g.machine_id}?tab=toc-do`}>{g.machine_code}</Link>: {g.message}</li>
          ))}</ul>
        </section>
      )}
      {ops.length === 0 && <div className="card"><Empty>Chưa có tốc độ nào. Mở <Link className="link" href="/may">Danh sách máy</Link> → hồ sơ dây chuyền → tab Tốc độ & dải hoạt động.</Empty></div>}
      {ops.map(([op, name]) => (
        <section key={op} className="card mb-4 overflow-x-auto">
          <div className="card-h">{op} · {name}<span className="text-[13px] font-normal text-muted">{op === 'CD0' ? 'kg hỗn hợp/giờ' : 'm/ph'}</span></div>
          <table className="tbl">
            <thead><tr><th>Dây chuyền</th><th>Áp dụng cho</th><th className="num">Chuẩn</th><th className="num">Đổi máy (phút/lô)</th><th>Tình trạng</th><th /></tr></thead>
            <tbody>
              {rows.filter((r) => r.op_code === op).map((s) => (
                <tr key={s.id} className={s.status === 'OBSOLETE' ? 'opacity-50' : ''}>
                  <td><Link className="font-medium text-brand hover:underline" href={`/may/${s.machine_id}?tab=toc-do`}>{s.machine_code}</Link><div className="text-[12.5px] text-muted">{s.machine_name}</div></td>
                  <td>{s.label && <div className="font-medium">{s.label}</div>}<div className="text-[12.5px] text-muted">{[s.product_code, s.group_name ?? s.group_code, s.core_code && `cỡ ruột ${s.core_code}`].filter(Boolean).join(' · ') || 'Mặc định của máy'}</div>
                    {s.note && <div className="text-[12.5px] text-muted">{s.note}</div>}</td>
                  <td className="num font-medium">{nf(s.std_mpm, 1)}{s.range_max !== null && Number(s.std_mpm) > Number(s.range_max) && <div className="text-[12px] font-normal text-bad">vượt dải {nf(s.range_max)}</div>}</td>
                  <td className="num">{nf(s.setup_min)}</td>
                  <td><StatusPill map={SPEED_STATUS} value={s.status} />
                    {s.status === 'APPROVED' && <div className="text-[12px] text-muted">{s.approved_by_name}{s.temp_approval ? ' (duyệt tạm)' : ''} · {df(s.approved_at)}</div>}
                    {s.status === 'PENDING' && <div className={`text-[12px] ${s.wait_days >= 1 ? 'text-warn' : 'text-muted'}`}>Gửi {df(s.submitted_at)}{s.wait_days >= 1 ? ' · quá 1 ngày, đã báo Giám đốc' : ''}</div>}</td>
                  <td>{s.status === 'PENDING' && canApprove && (
                    <form action={approveSpeed}><input type="hidden" name="id" value={s.id} /><input type="hidden" name="back" value={back} />
                      <SubmitButton className="btn btn-sm btn-pri" pendingText="…">{me.roles.includes('KT_TP') || me.roles.includes('ADMIN') ? 'Duyệt' : 'Duyệt tạm'}</SubmitButton></form>
                  )}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      ))}
    </>
  );
}
