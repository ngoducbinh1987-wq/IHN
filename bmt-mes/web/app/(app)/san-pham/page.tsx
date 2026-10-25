import Link from 'next/link';
import { Flash, PageHeader, Pill, StatusPill } from '@/components/ui';
import { SPEC_STATUS, nf } from '@/lib/format';
import { requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Sản phẩm & Spec' };

type Row = {
  id: string; code: string; group_code: string; group_name: string; description: string; default_brand: string;
  version: number; spec_status: string; total_kgkm: number; od_mm: number; rdc_calc: number; rdc_limit: number | null;
  pilot_rdc: number | null; rdc_over: boolean;
};

const GROUPS = ['PFR', 'SFR', 'CFR', 'CTL', 'SIF', 'PVC'];

export default async function ProductsPage({ searchParams }: { searchParams: Promise<{ nhom?: string; tt?: string; ok?: string; err?: string }> }) {
  const sp = await searchParams;
  await requirePerm('spec', 'view');
  const supabase = await createClient();
  let q = supabase.schema('app').from('v_products').select('*').order('code');
  if (sp.nhom && GROUPS.includes(sp.nhom)) q = q.eq('group_code', sp.nhom);
  if (sp.tt === 'rdc') q = q.eq('rdc_over', true);
  else if (sp.tt) q = q.eq('spec_status', sp.tt);
  const { data, error } = await q.returns<Row[]>();
  const link = (k: string, v?: string) => {
    const p = new URLSearchParams({ ...(sp.nhom ? { nhom: sp.nhom } : {}), ...(sp.tt ? { tt: sp.tt } : {}) });
    if (v) p.set(k, v); else p.delete(k);
    const s = p.toString();
    return s ? `/san-pham?${s}` : '/san-pham';
  };
  return (
    <>
      <PageHeader title="Sản phẩm & Spec" sub="Mã có spec Đã phát hành mới được lập kế hoạch chính thức và ra lệnh SX" />
      <Flash ok={sp.ok} err={sp.err ?? error?.message} />
      <div className="mb-3 flex flex-wrap gap-1.5">
        <Link className={`btn ${!sp.nhom ? 'btn-pri' : ''}`} href={link('nhom')}>Tất cả nhóm</Link>
        {GROUPS.map((g) => <Link key={g} className={`btn ${sp.nhom === g ? 'btn-pri' : ''}`} href={link('nhom', g)}>{g}</Link>)}
        <span className="mx-2 w-px bg-line" />
        <Link className={`btn ${!sp.tt ? 'btn-pri' : ''}`} href={link('tt')}>Mọi trạng thái</Link>
        <Link className={`btn ${sp.tt === 'DRAFT' ? 'btn-pri' : ''}`} href={link('tt', 'DRAFT')}>Nháp</Link>
        <Link className={`btn ${sp.tt === 'PENDING_APPROVAL' ? 'btn-pri' : ''}`} href={link('tt', 'PENDING_APPROVAL')}>Chờ duyệt</Link>
        <Link className={`btn ${sp.tt === 'RELEASED' ? 'btn-pri' : ''}`} href={link('tt', 'RELEASED')}>Đã phát hành</Link>
        <Link className={`btn ${sp.tt === 'rdc' ? 'btn-pri' : ''}`} href={link('tt', 'rdc')}>Rdc vượt</Link>
      </div>
      <div className="card overflow-x-auto">
        <table className="tbl">
          <thead><tr><th>Mã SP</th><th>Quy cách</th><th>Nhóm</th><th>TH</th><th className="num">kg/km</th><th className="num">OD mm</th><th className="num">Rdc tính</th><th className="num">Giới hạn</th><th>Spec</th></tr></thead>
          <tbody>
            {(data ?? []).map((r) => (
              <tr key={r.id}>
                <td className="whitespace-nowrap"><Link className="mono font-semibold text-copper" href={`/san-pham/${r.code}`}>{r.code}</Link></td>
                <td className="min-w-[220px]">{r.description}</td>
                <td className="whitespace-nowrap text-muted">{r.group_name}</td>
                <td>{r.default_brand}</td>
                <td className="num">{nf(r.total_kgkm, 2)}</td>
                <td className="num">{nf(r.od_mm, 2)}</td>
                <td className={`num ${r.rdc_over ? 'font-semibold text-bad' : ''}`}>{nf(r.rdc_calc, 3)}</td>
                <td className="num">{r.rdc_limit === null ? <Pill tone="warn">Chưa có</Pill> : nf(r.rdc_limit, 2)}</td>
                <td className="whitespace-nowrap"><StatusPill map={SPEC_STATUS} value={r.spec_status} /> <span className="text-[11px] text-muted">v{r.version}</span></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="mt-2 text-[12px] text-muted">{data?.length ?? 0} mã</p>
    </>
  );
}
