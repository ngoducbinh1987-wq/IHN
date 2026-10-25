import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { ScanLocation, ScanOne } from '@/components/scan';
import { SubmitButton } from '@/components/submit-button';
import { Flash, Toolbar } from '@/components/ui';
import { errText, keeps, withMsg } from '@/lib/kho';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Chuyển vị trí' };

type Person = { id: string; name: string };

async function move(form: FormData) {
  'use server';
  if (!form.get('hu_id')) redirect(withMsg('/kho/chuyen', 'err', 'Quét mã QR hàng cần chuyển'));
  if (!form.get('location_id')) redirect(withMsg('/kho/chuyen', 'err', 'Quét hoặc gõ mã vị trí mới'));
  const supabase = await createClient();
  const { error } = await supabase.schema('inv').rpc('move_hu', {
    p_hu: String(form.get('hu_id')), p_to_location: String(form.get('location_id')), p_witness: String(form.get('witness_id') ?? '') || null,
  });
  if (error) redirect(withMsg('/kho/chuyen', 'err', errText(error.message)));
  revalidatePath('/kho/chuyen');
  redirect(withMsg('/kho/chuyen', 'ok', 'Đã chuyển. Quét mã tiếp theo.'));
}

export default async function MovePage({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string; ma?: string }> }) {
  const sp = await searchParams;
  const me = await requireMe();
  if (!keeps(me, 'KNL') && !keeps(me, 'KTP')) redirect('/kho?err=' + encodeURIComponent('Chuyển vị trí do người giữ kho thực hiện'));
  const supabase = await createClient();
  const { data: kt } = await supabase.schema('app').rpc('role_holders', { p_role: 'KT_KHO' });
  return (
    <>
      <Toolbar title="Chuyển vị trí / chuyển kho" />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /></div>
      <p className="mb-3 text-[13px] text-muted">Quét tem hàng, rồi quét tem vị trí mới. Hàng đã giữ cho đơn bán vẫn giữ sau khi chuyển.</p>
      <form action={move} className="card grid gap-4 p-4 md:grid-cols-2">
        <ScanOne name="hu_id" label="Hàng cần chuyển (quét tem QR)" initial={sp.ma} />
        <div className="grid content-start gap-3">
          <ScanLocation name="location_id" />
          <label className="lbl">Kế toán SX chứng kiến (khi giữ kho theo ủy quyền)
            <select className="inp" name="witness_id" defaultValue=""><option value="">Không</option>{((kt ?? []) as Person[]).filter((p) => p.id !== me.id).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></label>
          <div><SubmitButton>Chuyển</SubmitButton></div>
        </div>
      </form>
    </>
  );
}
