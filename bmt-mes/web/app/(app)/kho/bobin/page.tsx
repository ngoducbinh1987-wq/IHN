import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, StatusPill, Toolbar } from '@/components/ui';
import { nf, parseNum } from '@/lib/format';
import { CARRIER_STATUS, errText, keeps, withMsg } from '@/lib/kho';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { str } from '../util';

export const metadata = { title: 'Bobin trung gian' };

async function save(form: FormData) {
  'use server';
  const tare = str(form, 'tare_kg') ? parseNum(str(form, 'tare_kg')) : 0;
  if (tare === null || Number.isNaN(tare) || tare < 0) redirect(withMsg('/kho/bobin', 'err', 'Bì không hợp lệ'));
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('save_carrier', {
    p_id: str(form, 'id') || null, p_code: str(form, 'code'), p_type: str(form, 'carrier_type'), p_tare: tare, p_owner: str(form, 'owner') || 'BMT',
    p_status: str(form, 'status') || 'EMPTY', p_note: str(form, 'note'),
  });
  if (error) redirect(withMsg('/kho/bobin', 'err', errText(error.message)));
  revalidatePath('/kho/bobin');
  redirect(withMsg('/kho/bobin', 'ok', 'Đã lưu bobin'));
}

export default async function CarriersPage({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string }> }) {
  const sp = await searchParams;
  const me = await requireMe();
  const supabase = await createClient();
  const { data } = await supabase.schema('app').from('v_carriers').select('*').order('code');
  const edit = keeps(me, 'KBTP') || me.roles.includes('ADMIN');
  const rows = data ?? [];
  const count = (s: string) => rows.filter((r) => r.status === s).length;
  return (
    <>
      <Toolbar title="Bobin trung gian" reload="/kho/bobin" />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /></div>
      <p className="mb-3 text-[13px] text-muted">
        Bobin thép 500/630 là tài sản quay vòng (BR-KHO-15): khi ghi đầu ra công đoạn chọn mã bobin, hệ thống tự chuyển Đang chứa; dùng hết hàng tự về Trống.
        Đang có {rows.length} bobin · trống {count('EMPTY')} · đang chứa {count('IN_USE')} · hỏng {count('DAMAGED')}.
      </p>
      <section className="card mb-4 overflow-x-auto">
        {rows.length ? (
          <table className="tbl">
            <thead><tr><th>Mã</th><th>Loại</th><th className="num">Bì (kg)</th><th>Chủ</th><th>Trạng thái</th><th>Đang chứa</th><th>Vị trí</th><th>Ghi chú</th>{edit && <th />}</tr></thead>
            <tbody>{rows.map((c) => (
              <tr key={c.id}>
                <td className="mono font-medium">{c.code}</td><td>{c.carrier_type}</td><td className="num">{nf(c.tare_kg, 2)}</td><td>{c.owner}</td>
                <td><StatusPill map={CARRIER_STATUS} value={c.status} /></td><td className="mono">{c.hu_no ? `${c.hu_no} · ${nf(c.qty)} m` : '—'}</td>
                <td>{c.location_code ?? '—'}</td><td className="text-[13px]">{c.note ?? ''}</td>
                {edit && <td>{c.status !== 'IN_USE' && (
                  <form action={save} className="flex gap-1">
                    <input type="hidden" name="id" value={c.id} /><input type="hidden" name="code" value={c.code} /><input type="hidden" name="carrier_type" value={c.carrier_type} />
                    <input type="hidden" name="tare_kg" value={String(c.tare_kg)} /><input type="hidden" name="owner" value={c.owner} /><input type="hidden" name="note" value={c.note ?? ''} />
                    <select className="inp w-32" name="status" defaultValue={c.status} aria-label={`Trạng thái ${c.code}`}>
                      <option value="EMPTY">Trống</option><option value="DAMAGED">Hỏng</option><option value="RETIRED">Thanh lý</option></select>
                    <SubmitButton className="btn btn-sm btn-soft" pendingText="…">Lưu</SubmitButton>
                  </form>)}</td>}
              </tr>
            ))}</tbody>
          </table>
        ) : <Empty>Chưa khai báo bobin trung gian.</Empty>}
      </section>
      {edit && (
        <form action={save} className="card grid gap-3 p-4 md:grid-cols-[1fr_1fr_0.8fr_0.8fr_2fr_auto] md:items-end">
          <label className="lbl"><span className="req">Mã bobin</span><input className="inp inp-y" name="code" placeholder="B630-001" required /></label>
          <label className="lbl"><span className="req">Loại</span><select className="inp inp-y" name="carrier_type"><option>B630</option><option>B500</option><option>B800</option><option>ONG-NCC</option></select></label>
          <label className="lbl">Bì (kg)<input className="inp text-right" name="tare_kg" inputMode="decimal" /></label>
          <label className="lbl">Chủ<select className="inp" name="owner"><option value="BMT">BMT</option><option value="NCC">NCC</option><option value="KHACH">Khách</option></select></label>
          <label className="lbl">Ghi chú<input className="inp" name="note" /></label>
          <SubmitButton>Thêm bobin</SubmitButton>
        </form>
      )}
    </>
  );
}
