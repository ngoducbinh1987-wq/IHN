import Link from 'next/link';
import { SpecFields } from '@/components/spec-form';
import { SubmitButton } from '@/components/submit-button';
import { Flash, Toolbar } from '@/components/ui';
import { requirePage, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { createSpec } from './actions';

export const metadata = { title: 'Thêm spec mới' };

// Bước 1: chọn mã mẫu gần giống. Bước 2: sửa mã, quy cách và các thông số khác mẫu.
export default async function NewSpec({ searchParams }: { searchParams: Promise<{ mau?: string; err?: string }> }) {
  const sp = await searchParams;
  await requirePage('san-pham');
  await requirePerm('spec', 'create');
  const supabase = await createClient();
  const [{ data: products }, { data: groups }] = await Promise.all([
    supabase.schema('app').from('v_products').select('code, description, spec_id, group_code').order('code'),
    supabase.schema('master').from('product_groups').select('code, name').order('code'),
  ]);
  const tpl = (products ?? []).find((p) => p.code === sp.mau);
  const [{ data: spec }, { data: res }, { data: cores }] = tpl ? await Promise.all([
    supabase.schema('master').from('product_specs').select('*').eq('id', tpl.spec_id).single(),
    supabase.schema('master').from('spec_results').select('*').eq('spec_id', tpl.spec_id).maybeSingle(),
    supabase.schema('master').from('core_types').select('code').order('code'),
  ]) : [{ data: null }, { data: null }, { data: null }];
  const coreCodes = [...new Set((cores ?? []).map((c) => c.code as string))];

  return (
    <>
      <Toolbar title="Thêm spec mới" actions={<Link className="btn" href="/san-pham">Đóng</Link>} />
      <div className="mt-4"><Flash err={sp.err} /></div>
      <form className="card mb-4 flex flex-wrap items-end gap-3 p-4">
        <label className="lbl min-w-[280px] flex-1"><span className="req">Bước 1 · Chọn mã mẫu gần giống nhất</span>
          <select className="inp" name="mau" defaultValue={sp.mau ?? ''} required>
            <option value="" disabled>— Chọn mã mẫu —</option>
            {(products ?? []).map((p) => <option key={p.code} value={p.code}>{p.code} · {p.description}</option>)}
          </select>
        </label>
        <button className="btn btn-soft" type="submit">Sao chép thông số</button>
      </form>

      {tpl && spec && (
        <form action={createSpec} className="card flex flex-col gap-4 p-4 md:p-5">
          <input type="hidden" name="template" value={tpl.spec_id} /><input type="hidden" name="template_code" value={tpl.code} />
          <h2 className="text-[16px] font-medium">Bước 2 · Thông tin mã mới (đang sao chép từ <span className="text-brand">{tpl.code}</span>)</h2>
          <div className="grid gap-3 sm:grid-cols-[1fr_1fr_2fr]">
            <label className="lbl"><span className="req">Mã sản phẩm mới</span><input className="inp mono" name="new_code" required placeholder="PFR-2C-1P0" pattern="[A-Z0-9][A-Z0-9.\-]*" title="Chữ IN HOA, số, dấu gạch ngang (ví dụ PFR-2C-1P5)" /></label>
            <label className="lbl">Nhóm
              <select className="inp" name="group" defaultValue={tpl.group_code}>{(groups ?? []).map((g) => <option key={g.code} value={g.code}>{g.code} · {g.name}</option>)}</select>
            </label>
            <label className="lbl"><span className="req">Quy cách</span><input className="inp" name="description" required placeholder="Cáp chống cháy 2 lõi 1,0 mm²…" /></label>
          </div>
          <SpecFields s={{ ...spec, ...(res ?? {}), config_note: '' }} coreCodes={coreCodes.length ? coreCodes : [spec.core_code]} />
          <div className="flex gap-2 border-t border-line pt-4">
            <SubmitButton className="btn btn-pri">Tạo spec nháp</SubmitButton>
            <Link className="btn" href="/san-pham">Hủy</Link>
          </div>
        </form>
      )}
    </>
  );
}
