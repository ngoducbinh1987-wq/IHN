import { SubmitButton } from '@/components/submit-button';
import { Flash, Toolbar } from '@/components/ui';
import { requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { createPr } from '../actions';

export const metadata = { title: 'Thêm đề xuất mua hàng' };

export default async function NewPr({ searchParams }: { searchParams: Promise<{ err?: string }> }) {
  const sp = await searchParams;
  const me = await requirePerm('purchase', 'create');
  const buyer = me.roles.some((r) => r === 'MUA_NV' || r === 'MUA_TP' || r === 'ADMIN');
  const supabase = await createClient();
  const { data: mats } = await supabase.schema('app').from('v_materials').select('code, name, uom').order('code');
  return (
    <>
      <Toolbar title="Thêm đề xuất mua hàng" reload="/de-xuat/moi" />
      <div className="mt-4"><Flash err={sp.err} /></div>
      <form action={createPr} className="card flex flex-col gap-4 p-4 md:p-5">
        <datalist id="mats">{(mats ?? []).map((m) => <option key={m.code} value={`${m.code} · ${m.name} (${m.uom})`} />)}</datalist>
        <div className="grid gap-4 md:grid-cols-[1fr_2fr_1fr]">
          <label className="lbl"><span className="req">Loại đề xuất</span>
            <select className="inp" name="kind" defaultValue="BO_SUNG">
              <option value="BO_SUNG">Mua bổ sung</option>
              {buyer && <option value="TICH_TRU">Mua tích trữ</option>}
              {buyer && <option value="TOI_UU">Mua tối ưu (giá, MOQ, rủi ro cung ứng)</option>}
            </select>
          </label>
          <label className="lbl"><span className="req">Nội dung / lý do đề xuất</span>
            <input className="inp" name="note" required placeholder="Ví dụ: Mua bổ sung đồng 0,24 cho đơn hàng tháng 11" />
          </label>
          <label className="lbl">Ngày cần hàng<input className="inp" type="date" name="need_date" /></label>
        </div>
        <div className="overflow-x-auto rounded border border-line">
          <table className="tbl">
            <thead><tr><th className="w-10">#</th><th>Vật tư (gõ mã hoặc tên để chọn)</th><th className="w-40 text-right">Số lượng</th></tr></thead>
            <tbody>
              {Array.from({ length: 8 }, (_, i) => (
                <tr key={i}>
                  <td className="text-muted">{i + 1}</td>
                  <td><input className="inp" name="material_code" list="mats" aria-label={`Vật tư dòng ${i + 1}`} required={i === 0} /></td>
                  <td><input className="inp text-right" name="qty" inputMode="decimal" aria-label={`Số lượng dòng ${i + 1}`} required={i === 0} /></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p className="text-[13px] text-muted">Đề xuất theo kế hoạch tháng sinh từ MRP (Kế hoạch &amp; MRP). Số lượng tùy nhu cầu. Cần thêm dòng: lưu nháp rồi thêm tiếp ở trang chi tiết. Số dùng dấu phẩy cho phần thập phân (12,5). Gửi duyệt: TP Mua duyệt → Giám đốc duyệt.</p>
        <div className="flex flex-wrap gap-2">
          <SubmitButton className="btn btn-pri">Lưu và gửi duyệt</SubmitButton>
          <SubmitButton className="btn" formAction={async (f: FormData) => { 'use server'; f.set('send', '0'); await createPr(f); }}>Lưu nháp</SubmitButton>
        </div>
        <input type="hidden" name="send" value="1" />
      </form>
    </>
  );
}
