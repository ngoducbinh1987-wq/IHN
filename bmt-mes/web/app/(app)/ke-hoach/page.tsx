import Link from 'next/link';
import { Empty, Flash, Pill, StatusPill, Tabs, Toolbar } from '@/components/ui';
import { DOC_STATUS, df, nf } from '@/lib/format';
import { can, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Kế hoạch & MRP' };

const TABS = [
  { key: 'dang-xu-ly', label: 'Đang thực hiện', st: ['DRAFT', 'PENDING_APPROVAL'] },
  { key: 'da-duyet', label: 'Đã duyệt', st: ['APPROVED', 'CLOSED'] },
  { key: 'tat-ca', label: 'Tất cả', st: null },
];

export default async function PlansPage({ searchParams }: { searchParams: Promise<{ tab?: string; ok?: string; err?: string }> }) {
  const sp = await searchParams;
  const me = await requirePerm('plan', 'view');
  const tab = TABS.find((t) => t.key === sp.tab) ?? TABS[2];
  const supabase = await createClient();
  let q = supabase.schema('app').from('v_plans').select('*').order('created_at', { ascending: false });
  if (tab.st) q = q.in('status', tab.st);
  const { data, error } = await q;
  return (
    <>
      <Toolbar title="Kế hoạch sản xuất & MRP" reload={`/ke-hoach?tab=${tab.key}`}
        add={can(me, 'plan', 'create') ? { href: '/ke-hoach/moi', label: 'Thêm kế hoạch' } : undefined} />
      <Tabs active={tab.key} items={TABS.map((t) => ({ key: t.key, label: t.label, href: `/ke-hoach?tab=${t.key}` }))} />
      <Flash ok={sp.ok} err={sp.err ?? error?.message} />
      <div className="card overflow-x-auto">
        {data && data.length > 0 ? (
          <table className="tbl">
            <thead><tr><th>Kế hoạch</th><th>Chế độ</th><th className="num">Số SKU</th><th className="num">Tổng mét</th><th>Ngày cần vật tư</th><th>MRP</th><th>Trạng thái</th></tr></thead>
            <tbody>
              {data.map((p) => (
                <tr key={p.id}>
                  <td className="py-3"><Link className="text-[15px] font-medium text-brand hover:underline" href={`/ke-hoach/${p.id}`}>{p.plan_no} – {p.period_label}</Link>
                    <div className="text-[13px] text-muted">Tạo lúc {df(p.created_at, true)}</div></td>
                  <td>{p.mode === 'OFFICIAL' ? 'Chính thức' : <Pill tone="warn">Sơ bộ</Pill>}</td>
                  <td className="num">{p.line_count}</td><td className="num">{nf(p.total_m)}</td>
                  <td>{df(p.material_need_date)}</td>
                  <td>{p.last_run_id ? <Pill tone="ok">Đã chạy</Pill> : <Pill>Chưa chạy</Pill>}</td>
                  <td><StatusPill map={DOC_STATUS} value={p.status} /></td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : <Empty>Chưa có kế hoạch nào. Bấm “+ Thêm kế hoạch” để tạo kế hoạch kỳ đầu.</Empty>}
      </div>
    </>
  );
}
