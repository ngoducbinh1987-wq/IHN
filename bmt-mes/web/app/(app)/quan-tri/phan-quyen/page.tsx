import Link from 'next/link';
import { redirect } from 'next/navigation';
import { SubmitButton } from '@/components/submit-button';
import { Flash, Tabs, Toolbar } from '@/components/ui';
import { ROLE_NAMES } from '@/lib/format';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { savePages, savePerms } from './actions';

export const metadata = { title: 'Phân quyền' };

type Matrix = { pages: { key: string; label: string; grp: string }[]; roles: { code: string; name: string }[];
  grants: string[]; perms: string[]; modules: string[] };

// Bộ phận → vai trò, theo thứ tự cột (phương án phân quyền anh Bình duyệt 28/10/2026)
const DEPTS: [string, string[]][] = [
  ['Ban giám đốc', ['BGD']], ['Sản xuất', ['SX_TP', 'SX_KH', 'TO_TRUONG', 'VAN_HANH']], ['Kho', ['THU_KHO', 'KHO_NV']],
  ['Kỹ thuật / QA', ['KT_TP', 'KT_NV', 'QC']], ['Mua hàng', ['MUA_TP', 'MUA_NV']], ['Kế toán', ['KTT', 'KT_KHO', 'KT_GT']], ['Kinh doanh', ['KD_TP', 'KD_NV']],
];
const MODULES: Record<string, string> = {
  purchase: 'Mua hàng', price: 'Giá mua, đơn giá', plan: 'Kế hoạch, MRP', production: 'Sản xuất', inventory: 'Kho', machine: 'Máy',
  quality: 'Chất lượng (QC)', spec: 'Sản phẩm, spec', master: 'Danh mục (vật tư, đối tác)', sales: 'Bán hàng', cost: 'Giá thành',
  approval: 'Quy trình duyệt', admin: 'Quản trị', iot: 'PLC, cảm biến', integration: 'Kết nối kế toán',
};
const ACTIONS: [string, string][] = [['view', 'Xem'], ['create', 'Lập'], ['edit', 'Sửa'], ['approve', 'Duyệt'], ['export', 'Xuất file'], ['config', 'Cài đặt']];

export default async function AccessPage({ searchParams }: { searchParams: Promise<{ tab?: string; role?: string; ok?: string; err?: string }> }) {
  const sp = await searchParams;
  const me = await requireMe();
  // Ô tick phân quyền: chỉ Quản trị hệ thống (gán trực tiếp) thấy và thao tác
  if (!me.is_admin) redirect('/?err=' + encodeURIComponent('Chỉ Quản trị hệ thống vào được Phân quyền'));
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc('admin_access_matrix');
  const mx = data as Matrix | null;
  const tab = sp.tab === 'thao-tac' ? 'thao-tac' : 'muc';
  const known = new Set((mx?.roles ?? []).map((r) => r.code));
  const cols = DEPTS.map(([d, rs]) => [d, rs.filter((r) => known.has(r))] as [string, string[]]).filter(([, rs]) => rs.length);
  const extra = (mx?.roles ?? []).map((r) => r.code).filter((c) => !cols.some(([, rs]) => rs.includes(c)));
  if (extra.length) cols.push(['Khác', extra]);
  const roles = cols.flatMap(([, rs]) => rs);
  const grants = new Set(mx?.grants ?? []);
  const groups = [...new Set((mx?.pages ?? []).map((p) => p.grp))];
  const role = roles.includes(sp.role ?? '') ? sp.role! : roles[0];
  const perms = new Set((mx?.perms ?? []).filter((x) => x.startsWith(role + '|')).map((x) => x.split('|')[1]));
  const modules = [...Object.keys(MODULES).filter((m) => mx?.modules.includes(m)), ...(mx?.modules ?? []).filter((m) => !MODULES[m])];

  return (
    <>
      <Toolbar title="Phân quyền" />
      <Tabs active={tab} items={[
        { key: 'muc', label: 'Quyền vào mục', href: '/quan-tri/phan-quyen' },
        { key: 'thao-tac', label: 'Quyền thao tác', href: `/quan-tri/phan-quyen?tab=thao-tac&role=${role}` },
      ]} />
      <Flash ok={sp.ok} err={sp.err ?? error?.message} />
      <p className="mb-3 max-w-4xl text-[13.5px] text-muted">
        Chỉ Quản trị hệ thống thấy trang này. Mỗi lần lưu ghi vào nhật ký hệ thống (người, lúc, trước – sau).
        {tab === 'muc'
          ? ' Tick = vai trò được thấy mục trên menu và vào trang đó. Tổng quan, Thông báo, Quy trình duyệt, Trung tâm điều hành luôn mở cho mọi người; Quản trị hệ thống vào mọi mục. Người giữ nhiều vai trò được vào tổng các mục của các vai trò.'
          : ' Tick = vai trò được làm việc đó với dữ liệu của phân hệ (database kiểm ở mọi thao tác). Quy trình duyệt (ai duyệt bước nào) đặt ở Cài đặt quy trình. Vai trò Quản trị hệ thống luôn đủ quyền, không sửa ở đây.'}
      </p>

      {tab === 'muc' && mx && (
        <form action={savePages} className="card overflow-x-auto">
          <table className="tbl text-[13px]" id="page-matrix">
            <thead>
              <tr>
                <th rowSpan={2} className="min-w-[200px] align-bottom">Mục</th>
                {cols.map(([d, rs]) => <th key={d} colSpan={rs.length} className="border-l border-line text-center">{d}</th>)}
              </tr>
              <tr>
                {cols.flatMap(([, rs]) => rs.map((r, i) => (
                  <th key={r} title={ROLE_NAMES[r] ?? r} className={`px-1 text-center text-[11.5px] font-normal ${i === 0 ? 'border-l border-line' : ''}`}>
                    <span className="inline-block max-w-[72px] leading-tight">{ROLE_NAMES[r] ?? r}</span>
                  </th>
                )))}
              </tr>
            </thead>
            <tbody>
              {groups.map((g) => [
                <tr key={g} className="bg-sunk/60"><td colSpan={roles.length + 1} className="py-1.5 text-[12px] font-medium uppercase tracking-wide text-muted">{g}</td></tr>,
                ...mx.pages.filter((p) => p.grp === g).map((p) => (
                  <tr key={p.key}>
                    <td>{p.label}</td>
                    {cols.flatMap(([, rs]) => rs.map((r, i) => (
                      <td key={r} className={`px-1 text-center ${i === 0 ? 'border-l border-line' : ''}`}>
                        <input type="checkbox" name="g" value={`${r}|${p.key}`} defaultChecked={grants.has(`${r}|${p.key}`)}
                          aria-label={`${ROLE_NAMES[r] ?? r} vào ${p.label}`} className="h-4 w-4 accent-[rgb(var(--brand))]" />
                      </td>
                    )))}
                  </tr>
                )),
              ])}
            </tbody>
          </table>
          <div className="sticky left-0 flex items-center gap-3 border-t border-line p-4">
            <SubmitButton>Lưu quyền vào mục</SubmitButton>
            <span className="text-[12.5px] text-muted">Bỏ tick mục nào thì vai trò đó không thấy mục trên menu, mở đường dẫn trực tiếp cũng bị chặn.</span>
          </div>
        </form>
      )}

      {tab === 'thao-tac' && mx && (
        <div className="grid gap-4 lg:grid-cols-[230px_minmax(0,1fr)]">
          <nav className="card h-fit p-2" aria-label="Vai trò">
            {cols.map(([d, rs]) => (
              <div key={d} className="mb-1">
                <div className="px-2 pt-1 text-[11.5px] font-medium uppercase tracking-wide text-muted">{d}</div>
                {rs.map((r) => (
                  <Link key={r} href={`/quan-tri/phan-quyen?tab=thao-tac&role=${r}`} aria-current={r === role ? 'page' : undefined}
                    className={`block rounded px-2 py-1.5 text-[14px] ${r === role ? 'bg-brand-soft font-medium text-brand' : 'hover:bg-sunk'}`}>{ROLE_NAMES[r] ?? r}</Link>
                ))}
              </div>
            ))}
          </nav>
          <form action={savePerms} className="card overflow-x-auto" id="perm-matrix">
            <input type="hidden" name="role" value={role} />
            <div className="card-h"><h2>{ROLE_NAMES[role] ?? role}</h2></div>
            <table className="tbl text-[13.5px]">
              <thead><tr><th>Phân hệ</th>{ACTIONS.map(([a, l]) => <th key={a} className="text-center">{l}</th>)}</tr></thead>
              <tbody>{modules.map((m) => (
                <tr key={m}>
                  <td>{MODULES[m] ?? m}</td>
                  {ACTIONS.map(([a, l]) => (
                    <td key={a} className="text-center">
                      <input type="checkbox" name="p" value={`${m}:${a}`} defaultChecked={perms.has(`${m}:${a}`)}
                        aria-label={`${MODULES[m] ?? m}: ${l}`} className="h-4 w-4 accent-[rgb(var(--brand))]" />
                    </td>
                  ))}
                </tr>
              ))}</tbody>
            </table>
            <div className="flex items-center gap-3 border-t border-line p-4">
              <SubmitButton>Lưu quyền thao tác</SubmitButton>
              <span className="text-[12.5px] text-muted">Xem giá mua, đơn giá, giá thành vẫn theo vai trò (Ban giám đốc, Mua hàng, Kế toán); dòng Giá mua là quyền lập, sửa bảng giá.</span>
            </div>
          </form>
        </div>
      )}
    </>
  );
}
