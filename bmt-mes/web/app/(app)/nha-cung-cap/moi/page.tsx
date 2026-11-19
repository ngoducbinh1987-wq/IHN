import Link from 'next/link';
import { redirect } from 'next/navigation';
import { MaterialPicker } from '@/components/material-picker';
import { SubmitButton } from '@/components/submit-button';
import { Flash, Toolbar } from '@/components/ui';
import { requirePage, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { groupMaterials, isBuyLead, type MaterialOption } from '@/lib/suppliers';
import { createSupplier } from '../actions';

export const metadata = { title: 'Thêm nhà cung cấp' };

export default async function NewSupplier({ searchParams }: { searchParams: Promise<{ err?: string }> }) {
  const sp = await searchParams;
  await requirePage('nha-cung-cap');
  const me = await requirePerm('master', 'view');
  if (!isBuyLead(me.roles)) redirect('/nha-cung-cap?err=' + encodeURIComponent('Chỉ TP Mua được thêm nhà cung cấp mới'));
  const supabase = await createClient();
  const { data: mats } = await supabase.schema('app').from('v_materials').select('id, code, name, uom, group_name')
    .or('group_code.is.null,group_code.neq.SCRAP').order('group_name').order('code').returns<MaterialOption[]>();

  return (
    <>
      <Toolbar title="Thêm nhà cung cấp" actions={<Link className="btn" href="/nha-cung-cap">Đóng</Link>} />
      <div className="mt-4"><Flash err={sp.err} /></div>
      <form action={createSupplier} className="card flex max-w-5xl flex-col gap-5 p-4 md:p-5">
        <fieldset className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <legend className="mb-2 text-[15px] font-medium">Thông tin nhà cung cấp</legend>
          <label className="lbl sm:col-span-2"><span className="req">Tên nhà cung cấp</span><input className="inp" name="name" required /></label>
          <label className="lbl">Mã số thuế<input className="inp mono" name="tax_code" inputMode="numeric" placeholder="0101234567" /></label>
          <label className="lbl">Người liên hệ<input className="inp" name="contact" placeholder="Nguyễn Văn A" /></label>
          <label className="lbl">Điện thoại<input className="inp" name="phone" inputMode="tel" placeholder="0912 345 678" /></label>
          <label className="lbl">Email<input className="inp" name="email" type="email" placeholder="ten@congty.vn" /></label>
          <label className="lbl sm:col-span-2">Địa chỉ<input className="inp" name="address" /></label>
          <label className="lbl sm:col-span-2">Điều khoản thanh toán mặc định<input className="inp" name="payment_terms" placeholder="30 ngày sau khi nhận hàng" /></label>
          <label className="lbl sm:col-span-2">Ghi chú<input className="inp" name="note" /></label>
        </fieldset>
        <fieldset>
          <legend className="mb-1 text-[15px] font-medium">Mặt hàng bán được cho BMT</legend>
          <p className="mb-3 text-[13px] text-muted">Tick các vật tư NCC này bán. Trên đơn mua, NCC chỉ hiện ở các dòng vật tư đã tick. Sửa lại sau ở trang chi tiết NCC.</p>
          <MaterialPicker groups={groupMaterials(mats ?? [])} selected={[]} />
        </fieldset>
        <div className="flex gap-2 border-t border-line pt-4"><SubmitButton className="btn btn-pri">Lưu nhà cung cấp</SubmitButton><Link className="btn" href="/nha-cung-cap">Hủy</Link></div>
      </form>
    </>
  );
}
