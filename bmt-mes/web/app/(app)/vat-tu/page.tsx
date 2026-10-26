import { Flash, Pill, Toolbar } from '@/components/ui';
import { SubmitButton } from '@/components/submit-button';
import { nf, numIn } from '@/lib/format';
import { can, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { saveTerms } from './actions';

export const metadata = { title: 'Vật tư' };

type Mat = {
  id: string; code: string; name: string; group_name: string; uom: string; loss_rate: number; purchase_spec: string | null;
  has_expiry: boolean; requires_coa: boolean; terms_id: string | null; moq: number | null; pack_multiple: number | null;
  lead_time_days: number | null; unit_price: number | null; supplier_item_code: string | null; available: number | null; in_quality: number | null;
};

export default async function MaterialsPage({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string; q?: string; thieu?: string }> }) {
  const sp = await searchParams;
  const me = await requirePerm('master', 'view');
  const supabase = await createClient();
  let query = supabase.schema('app').from('v_materials').select('*').order('group_name').order('code');
  const q = (sp.q ?? '').replace(/[,()*%\\]/g, ' ').trim();
  if (q) query = query.or(`code.ilike.*${q}*,name.ilike.*${q}*`);
  const { data, error } = await query.returns<Mat[]>();
  const rows = (data ?? []).filter((m) => !sp.thieu || m.unit_price === null || !m.lead_time_days);
  const editable = can(me, 'price', 'edit');
  const showPrice = can(me, 'price', 'view');

  return (
    <>
      <Toolbar title="Danh mục vật tư" reload="/vat-tu" search={{ placeholder: 'Tìm mã hoặc tên vật tư', value: sp.q }} hidden={{ thieu: sp.thieu }}
        add={can(me, 'master', 'create') ? { href: '/vat-tu/moi', label: 'Thêm vật tư' } : undefined} />
      <div className="mb-3 mt-4 flex flex-wrap items-center gap-2">
        <a className={`btn btn-sm ${!sp.thieu ? 'btn-pri' : ''}`} href={`/vat-tu${q ? `?q=${encodeURIComponent(q)}` : ''}`}>Tất cả ({data?.length ?? 0})</a>
        <a className={`btn btn-sm ${sp.thieu ? 'btn-pri' : ''}`} href={`/vat-tu?thieu=1${q ? `&q=${encodeURIComponent(q)}` : ''}`}>Thiếu giá hoặc lead time</a>
      </div>
      <Flash ok={sp.ok} err={sp.err ?? error?.message} />
      {editable && <p className="mb-2 text-[12px] text-muted">Ô vàng sửa được. Giá để trống nghĩa là chưa có giá (MRP không tính là 0). Bấm Lưu ở từng dòng.</p>}
      <div className="card overflow-x-auto">
        <table className="tbl">
          <thead>
            <tr>
              <th>Mã</th><th>Vật tư</th><th>Nhóm</th><th>ĐVT</th><th className="num">Hao hụt</th>
              <th className="num">Tồn khả dụng</th><th className="num">Chờ QC</th>
              <th className="num">MOQ</th><th className="num">Bội số</th><th className="num">Lead time (ngày)</th>
              {showPrice && <th className="num">Đơn giá VND</th>}<th>Mã NCC</th>{editable && <th />}
            </tr>
          </thead>
          <tbody>
            {rows.map((m) => (
              <tr key={m.id}>
                <td className="mono font-medium">{m.code}</td>
                <td className="min-w-[200px]">{m.name}
                  <div className="flex gap-1">{m.has_expiry && <Pill tone="info">Có HSD</Pill>}{m.requires_coa && <Pill tone="cu">Cần COA</Pill>}</div>
                </td>
                <td className="whitespace-nowrap text-muted">{m.group_name}</td>
                <td>{m.uom}</td>
                <td className="num">{nf(m.loss_rate * 100, 1)}%</td>
                <td className="num">{nf(m.available, 1)}</td>
                <td className="num text-muted">{nf(m.in_quality, 1)}</td>
                {editable && m.terms_id ? (
                  <>
                    <td className="num"><input form={`f-${m.id}`} className="inp inp-y w-20 text-right" name="moq" defaultValue={numIn(m.moq ?? 0)} aria-label={`MOQ ${m.code}`} /></td>
                    <td className="num"><input form={`f-${m.id}`} className="inp inp-y w-20 text-right" name="pack_multiple" defaultValue={numIn(m.pack_multiple ?? 1)} aria-label={`Bội số ${m.code}`} /></td>
                    <td className="num"><input form={`f-${m.id}`} className="inp inp-y w-20 text-right" name="lead_time_days" defaultValue={m.lead_time_days ?? 0} aria-label={`Lead time ${m.code}`} /></td>
                    <td className="num"><input form={`f-${m.id}`} className="inp inp-y w-28 text-right" name="unit_price" defaultValue={numIn(m.unit_price)} placeholder="Chưa có" aria-label={`Đơn giá ${m.code}`} /></td>
                    <td><input form={`f-${m.id}`} className="inp inp-y w-28" name="supplier_item_code" defaultValue={m.supplier_item_code ?? ''} aria-label={`Mã NCC ${m.code}`} /></td>
                    <td>
                      <form id={`f-${m.id}`} action={saveTerms}>
                        <input type="hidden" name="terms_id" value={m.terms_id} /><input type="hidden" name="code" value={m.code} />
                        <SubmitButton className="btn btn-sm btn-soft" pendingText="…">Lưu</SubmitButton>
                      </form>
                    </td>
                  </>
                ) : (
                  <>
                    <td className="num">{nf(m.moq)}</td><td className="num">{nf(m.pack_multiple)}</td>
                    <td className="num">{m.lead_time_days ? nf(m.lead_time_days) : <Pill tone="warn">0</Pill>}</td>
                    {showPrice && <td className="num">{m.unit_price === null ? <Pill tone="warn">Chưa có</Pill> : nf(m.unit_price)}</td>}
                    <td className="mono">{m.supplier_item_code ?? '—'}</td>
                  </>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
