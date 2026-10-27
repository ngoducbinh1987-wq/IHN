import Link from 'next/link';
import { Empty, Flash, Pill, StatusPill, Tabs, Toolbar } from '@/components/ui';
import { SubmitButton } from '@/components/submit-button';
import { SPEED_STATUS } from '@/lib/machine';
import { df, nf } from '@/lib/format';
import { can, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { approveSpeed } from '../actions';

export const metadata = { title: 'Tốc độ sản xuất' };

const TABS = [
  { key: 'hieu-luc', label: 'Đang dùng', st: ['APPROVED', 'PENDING'] },
  { key: 'cho-duyet', label: 'Chờ duyệt', st: ['PENDING'] },
  { key: 'tat-ca', label: 'Tất cả (cả bản cũ)', st: null },
];

export default async function SpeedsPage({ searchParams }: { searchParams: Promise<{ tab?: string; ok?: string; err?: string }> }) {
  const sp = await searchParams;
  const me = await requirePerm('machine', 'view');
  const tab = TABS.find((t) => t.key === sp.tab) ?? TABS[0];
  const supabase = await createClient();
  let q = supabase.schema('app').from('v_machine_speeds').select('*').order('op_code').order('machine_code').order('core_code', { nullsFirst: true });
  if (tab.st) q = q.in('status', tab.st);
  const { data, error } = await q;
  const [{ count: pending }, { data: defaults }] = await Promise.all([
    supabase.schema('app').from('v_machine_speeds').select('id', { count: 'exact', head: true }).eq('status', 'PENDING'),
    supabase.schema('app').rpc('machine_rate_defaults'),
  ]);
  const rows = data ?? [];
  const ops = [...new Map(rows.map((r) => [r.op_code, r.op_name])).entries()];
  const canApprove = can(me, 'machine', 'approve');
  const back = `/may/toc-do?tab=${tab.key}`;
  return (
    <>
      <Toolbar title="Tốc độ sản xuất" reload={back} />
      <Tabs active={tab.key} items={TABS.map((t) => ({ key: t.key, label: t.label, href: `/may/toc-do?tab=${t.key}`, count: t.key === 'cho-duyet' ? pending ?? 0 : undefined }))} />
      <Flash ok={sp.ok} err={sp.err ?? error?.message} />
      <p className="mb-4 max-w-4xl text-[13.5px] text-muted">
        Lịch máy chọn tốc độ: riêng mã SP → theo cỡ ruột → mặc định của máy → mặc định công đoạn (bảng dưới). Khai báo trong Hồ sơ máy → Tốc độ & dải hoạt động; người khác duyệt.
        Đổi tốc độ xong, Quản lý SX bấm Xếp lại lịch để áp dụng.
      </p>
      <section className="card mb-4 max-w-4xl overflow-x-auto">
        <div className="card-h">Tốc độ mặc định theo công đoạn<span className="text-[13px] font-normal text-muted">dùng khi máy chưa khai báo tốc độ riêng</span></div>
        {(defaults ?? []).length ? (
          <table className="tbl">
            <thead><tr><th>Công đoạn</th><th className="num">Ruột &lt; 2,5 mm²</th><th className="num">Ruột ≥ 2,5 mm²</th><th>Đơn vị</th><th>Tình trạng</th></tr></thead>
            <tbody>
              {(defaults ?? []).map((r: { op_code: string; label: string; unit: string; rate_small: number; rate_large: number; confirmed: boolean }) => (
                <tr key={r.op_code}><td><span className="mono">{r.op_code}</span> · {r.label}</td><td className="num">{nf(r.rate_small)}</td><td className="num">{nf(r.rate_large)}</td>
                  <td>{r.unit.includes('/') ? r.unit : `${r.unit}/phút`}</td><td>{r.confirmed ? <Pill tone="ok">Đã xác nhận</Pill> : <Pill tone="warn">Giả định</Pill>}</td></tr>
              ))}
            </tbody>
          </table>
        ) : <Empty>Chưa có tốc độ mặc định.</Empty>}
        <p className="border-t border-line px-4 py-3 text-[12.5px] text-muted">TP Kỹ thuật/QA sửa ở <Link className="link" href="/tham-so">Tham số xếp lịch</Link>. Số “Giả định” cần thay bằng số chạy thật.</p>
      </section>
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
