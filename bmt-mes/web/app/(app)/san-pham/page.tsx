import Link from 'next/link';
import { Empty, Flash, Pill, StatusPill, Tabs, Toolbar } from '@/components/ui';
import { SPEC_STATUS, nf } from '@/lib/format';
import { can, requirePage, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Sản phẩm & Spec' };

type Row = {
  id: string; code: string; group_code: string; group_name: string; description: string; default_brand: string;
  version: number; spec_status: string; total_kgkm: number; od_mm: number; rdc_calc: number; rdc_limit: number | null;
  pilot_rdc: number | null; rdc_over: boolean;
};

const GROUPS = ['PFR', 'SFR', 'CFR', 'CTL', 'SIF', 'PVC'];
const TABS = [
  { key: 'tat-ca', label: 'Tất cả', st: null },
  { key: 'nhap', label: 'Nháp', st: 'DRAFT' },
  { key: 'dang-duyet', label: 'Đang duyệt', st: 'PENDING_APPROVAL' },
  { key: 'phat-hanh', label: 'Đã phát hành', st: 'RELEASED' },
  { key: 'rdc', label: 'Rdc vượt', st: 'rdc' },
];

export default async function ProductsPage({ searchParams }: { searchParams: Promise<{ nhom?: string; tab?: string; q?: string; ok?: string; err?: string }> }) {
  const sp = await searchParams;
  await requirePage('san-pham');
  const me = await requirePerm('spec', 'view');
  const tab = TABS.find((t) => t.key === sp.tab) ?? TABS[0];
  const supabase = await createClient();
  let query = supabase.schema('app').from('v_products').select('*').order('code');
  if (sp.nhom && GROUPS.includes(sp.nhom)) query = query.eq('group_code', sp.nhom);
  if (tab.st === 'rdc') query = query.eq('rdc_over', true);
  else if (tab.st) query = query.eq('spec_status', tab.st);
  const q = (sp.q ?? '').replace(/[,()*%\\]/g, ' ').trim();
  if (q) query = query.or(`code.ilike.*${q}*,description.ilike.*${q}*`);
  const { data, error } = await query.returns<Row[]>();
  const href = (o: { tab?: string; nhom?: string | null }) => {
    const p = new URLSearchParams();
    const t = o.tab ?? tab.key; if (t !== 'tat-ca') p.set('tab', t);
    const n = o.nhom === undefined ? sp.nhom : o.nhom; if (n) p.set('nhom', n);
    if (q) p.set('q', q);
    const s = p.toString();
    return s ? `/san-pham?${s}` : '/san-pham';
  };

  return (
    <>
      <Toolbar title="Sản phẩm & Spec" reload={href({})} search={{ placeholder: 'Tìm mã hoặc quy cách', value: sp.q }} hidden={{ tab: sp.tab, nhom: sp.nhom }}
        add={can(me, 'spec', 'create') ? { href: '/san-pham/moi', label: 'Thêm spec mới' } : undefined} />
      <Tabs active={tab.key} items={TABS.map((t) => ({ key: t.key, label: t.label, href: href({ tab: t.key }) }))} />
      <Flash ok={sp.ok} err={sp.err ?? error?.message} />
      <div className="mb-3 flex flex-wrap items-center gap-1.5">
        <span className="mr-1 text-[13px] text-muted">Nhóm:</span>
        <Link className={`btn btn-sm ${!sp.nhom ? 'btn-pri' : ''}`} href={href({ nhom: null })}>Tất cả</Link>
        {GROUPS.map((g) => <Link key={g} className={`btn btn-sm ${sp.nhom === g ? 'btn-pri' : ''}`} href={href({ nhom: g })}>{g}</Link>)}
      </div>
      <div className="card overflow-x-auto">
        {data && data.length > 0 ? (
          <table className="tbl">
            <thead><tr><th>Mã SP</th><th>Quy cách</th><th>Nhóm</th><th>Thương hiệu</th><th className="num">kg/km</th><th className="num">OD mm</th><th className="num">Rdc tính</th><th className="num">Giới hạn</th><th>Spec</th></tr></thead>
            <tbody>
              {data.map((r) => (
                <tr key={r.id}>
                  <td className="whitespace-nowrap"><Link className="mono text-[14px] font-medium text-brand hover:underline" href={`/san-pham/${encodeURIComponent(r.code)}`}>{r.code}</Link></td>
                  <td className="min-w-[220px]">{r.description}</td>
                  <td className="whitespace-nowrap text-muted">{r.group_name}</td>
                  <td>{r.default_brand}</td>
                  <td className="num">{nf(r.total_kgkm, 2)}</td>
                  <td className="num">{nf(r.od_mm, 2)}</td>
                  <td className={`num ${r.rdc_over ? 'font-medium text-bad' : ''}`}>{nf(r.rdc_calc, 3)}</td>
                  <td className="num">{r.rdc_limit === null ? <Pill tone="warn">Chưa có</Pill> : nf(r.rdc_limit, 2)}</td>
                  <td className="whitespace-nowrap"><StatusPill map={SPEC_STATUS} value={r.spec_status} /> <span className="text-[12px] text-muted">v{r.version}</span></td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : <Empty>Không có mã nào phù hợp.</Empty>}
      </div>
      <p className="mt-2 text-right text-[13px] text-muted">Hiển thị {data?.length ?? 0} mã</p>
    </>
  );
}
