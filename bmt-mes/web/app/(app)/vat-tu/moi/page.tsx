import Link from 'next/link';
import { SubmitButton } from '@/components/submit-button';
import { Flash, Toolbar } from '@/components/ui';
import { can, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { createMaterial } from './actions';

export const metadata = { title: 'Thêm vật tư' };

export default async function NewMaterial({ searchParams }: { searchParams: Promise<{ err?: string }> }) {
  const sp = await searchParams;
  const me = await requirePerm('master', 'create');
  const supabase = await createClient();
  const [{ data: groups }, { data: uoms }] = await Promise.all([
    supabase.schema('master').from('material_groups').select('code, name').order('name'),
    supabase.schema('core').from('uoms').select('code').order('code'),
  ]);
  return (
    <>
      <Toolbar title="Thêm vật tư" actions={<Link className="btn" href="/vat-tu">Đóng</Link>} />
      <div className="mt-4"><Flash err={sp.err} /></div>
      <form action={createMaterial} className="card flex max-w-4xl flex-col gap-4 p-4 md:p-5">
        <fieldset className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <legend className="mb-2 text-[15px] font-medium">Thông tin vật tư</legend>
          <label className="lbl"><span className="req">Mã vật tư</span><input className="inp mono" name="code" required placeholder="CU-030" /></label>
          <label className="lbl sm:col-span-2"><span className="req">Tên vật tư</span><input className="inp" name="name" required /></label>
          <label className="lbl"><span className="req">ĐVT</span><select className="inp" name="uom" defaultValue="kg">{(uoms ?? []).map((u) => <option key={u.code}>{u.code}</option>)}</select></label>
          <label className="lbl sm:col-span-2">Nhóm<select className="inp" name="group">{(groups ?? []).filter((g) => g.code !== 'SCRAP').map((g) => <option key={g.code} value={g.code}>{g.name}</option>)}</select></label>
          <label className="lbl">Hao hụt chạy (%)<input className="inp text-right" name="loss" inputMode="decimal" defaultValue="0" /></label>
          <label className="lbl sm:col-span-4">Quy cách mua<input className="inp" name="purchase_spec" /></label>
        </fieldset>
        <fieldset className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <legend className="mb-2 text-[15px] font-medium">Điều kiện mua</legend>
          <label className="lbl">MOQ<input className="inp text-right" name="moq" inputMode="decimal" defaultValue="0" /></label>
          <label className="lbl">Bội số mua<input className="inp text-right" name="multiple" inputMode="decimal" defaultValue="1" /></label>
          <label className="lbl">Lead time (ngày)<input className="inp text-right" name="lead" inputMode="numeric" defaultValue="0" /></label>
          {can(me, 'price', 'view') && <label className="lbl">Đơn giá VND (để trống nếu chưa có)<input className="inp text-right" name="price" inputMode="decimal" /></label>}
        </fieldset>
        <div className="flex gap-2 border-t border-line pt-4"><SubmitButton className="btn btn-pri">Lưu vật tư</SubmitButton><Link className="btn" href="/vat-tu">Hủy</Link></div>
      </form>
    </>
  );
}
