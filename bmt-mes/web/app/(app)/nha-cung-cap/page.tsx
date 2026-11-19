import Link from 'next/link';
import { Empty, Flash, Pill, Tabs, Toolbar } from '@/components/ui';
import { df } from '@/lib/format';
import { requirePage, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { isBuyLead, type Supplier } from '@/lib/suppliers';

export const metadata = { title: 'Nhà cung cấp' };

const TABS = [
  { key: 'dang-dung', label: 'Đang dùng' },
  { key: 'ngung-dung', label: 'Ngừng dùng' },
  { key: 'tat-ca', label: 'Tất cả' },
];

// Danh mục nhà cung cấp (migration 10300): TP Mua thêm mới, khai báo mặt hàng, ngừng dùng; NV mua sửa thông tin; Quản trị xóa
export default async function SupplierList({ searchParams }: { searchParams: Promise<{ tab?: string; q?: string; ok?: string; err?: string }> }) {
  const sp = await searchParams;
  await requirePage('nha-cung-cap');
  const me = await requirePerm('master', 'view');
  const tab = TABS.find((t) => t.key === sp.tab) ?? TABS[0];
  const supabase = await createClient();
  const q = (sp.q ?? '').replace(/[,()*%\\]/g, ' ').trim();

  // Ô tìm kiếm khớp cả mặt hàng: gõ "đồng" ra các NCC bán đồng
  let byMaterial: string[] = [];
  if (q) {
    const { data: hit } = await supabase.schema('app').from('v_supplier_materials').select('supplier_id')
      .or(`material_code.ilike.*${q}*,material_name.ilike.*${q}*`);
    byMaterial = [...new Set((hit ?? []).map((h) => h.supplier_id as string))];
  }
  let query = supabase.schema('app').from('v_suppliers').select('*').order('code');
  if (q) {
    const parts = [`code.ilike.*${q}*`, `name.ilike.*${q}*`, `tax_code.ilike.*${q}*`];
    if (byMaterial.length > 0) parts.push(`id.in.(${byMaterial.join(',')})`);
    query = query.or(parts.join(','));
  }
  const { data, error } = await query.returns<Supplier[]>();
  const all = data ?? [];
  const rows = all.filter((s) => (tab.key === 'tat-ca' ? true : tab.key === 'dang-dung' ? s.active : !s.active));
  const count = (k: string) => all.filter((s) => (k === 'tat-ca' ? true : k === 'dang-dung' ? s.active : !s.active)).length;
  const href = (t: string) => `/nha-cung-cap?tab=${t}${q ? `&q=${encodeURIComponent(q)}` : ''}`;
  const lead = isBuyLead(me.roles);

  return (
    <>
      <Toolbar title="Danh mục nhà cung cấp" reload={href(tab.key)} search={{ placeholder: 'Tìm mã, tên, mã số thuế, mặt hàng', value: sp.q }}
        hidden={{ tab: tab.key }} add={lead ? { href: '/nha-cung-cap/moi', label: 'Thêm nhà cung cấp' } : undefined} />
      <Tabs active={tab.key} items={TABS.map((t) => ({ key: t.key, label: t.label, href: href(t.key), count: count(t.key) }))} />
      <p className="mb-3 text-[13.5px] text-muted">
        Mỗi nhà cung cấp khai báo <b>mặt hàng bán được cho BMT</b>. Trên đơn mua, dòng vật tư nào chỉ hiện các NCC đã khai báo vật tư đó.
        <b> TP Mua</b> thêm NCC mới, khai báo mặt hàng, ngừng dùng. <b>NV mua</b> sửa thông tin liên hệ.
      </p>
      <Flash ok={sp.ok} err={sp.err ?? error?.message} />
      <div className="card overflow-x-auto">
        {rows.length > 0 ? (
          <table className="tbl" id="ds-ncc">
            <thead><tr>
              <th>Mã</th><th>Nhà cung cấp</th><th>Liên hệ</th><th className="num">Mặt hàng</th><th className="num">Hợp đồng</th><th>Mua gần nhất</th><th>Trạng thái</th>
            </tr></thead>
            <tbody>{rows.map((s) => (
              <tr key={s.id} className={s.active ? undefined : 'text-ink/60'}>
                <td className="mono font-medium">{s.code}</td>
                <td className="min-w-[220px] py-3">
                  <Link href={`/nha-cung-cap/${s.id}`} className="text-[15px] font-medium text-brand hover:underline">{s.name}</Link>
                  {(s.tax_code || s.address) && <div className="mt-0.5 text-[13px] text-ink/80">{[s.tax_code && `MST ${s.tax_code}`, s.address].filter(Boolean).join(' · ')}</div>}
                </td>
                <td className="min-w-[160px] text-[14px]">
                  {s.contact || s.phone || s.email
                    ? <>{s.contact}{s.phone && <div>{s.phone}</div>}{s.email && <div className="text-[13px] text-ink/80">{s.email}</div>}</>
                    : <span className="text-muted">Chưa có</span>}
                </td>
                <td className="num">{s.material_count > 0 ? s.material_count : <span className="font-medium text-warn">Chưa khai báo</span>}</td>
                <td className="num">{s.po_count}{s.open_count > 0 && <div className="text-[12px] text-muted">{s.open_count} đơn đang mở</div>}</td>
                <td>{df(s.last_order_date)}</td>
                <td>{s.active ? <Pill tone="ok">Đang dùng</Pill> : <><Pill>Ngừng dùng</Pill>{s.inactive_reason && <div className="mt-0.5 text-[12px] text-muted">{s.inactive_reason}</div>}</>}</td>
              </tr>
            ))}</tbody>
          </table>
        ) : (
          <Empty>{q ? 'Không có nhà cung cấp nào khớp từ khóa.' : tab.key === 'ngung-dung' ? 'Chưa có nhà cung cấp nào ngừng dùng.' : 'Chưa có nhà cung cấp. TP Mua bấm "Thêm nhà cung cấp".'}</Empty>
        )}
      </div>
    </>
  );
}
