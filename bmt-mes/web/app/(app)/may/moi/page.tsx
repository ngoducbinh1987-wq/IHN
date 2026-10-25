import Link from 'next/link';
import { Flash, Toolbar } from '@/components/ui';
import { SubmitButton } from '@/components/submit-button';
import { requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { createMachine } from '../actions';

export const metadata = { title: 'Thêm máy' };

export default async function NewMachine({ searchParams }: { searchParams: Promise<{ cha?: string; err?: string }> }) {
  const sp = await searchParams;
  await requirePerm('machine', 'config');
  const supabase = await createClient();
  const [{ data: ops }, { data: parent }] = await Promise.all([
    supabase.schema('master').from('operations').select('code, name').order('seq'),
    sp.cha ? supabase.schema('app').from('v_machines').select('id, code, name, unit_count').eq('id', sp.cha).maybeSingle() : Promise.resolve({ data: null }),
  ]);
  const unit = Boolean(parent);
  const back = unit ? `/may/moi?cha=${parent!.id}` : '/may/moi';
  return (
    <>
      <Toolbar title={unit ? `Thêm máy con vào ${parent!.code}` : 'Thêm dây chuyền'} actions={<Link className="btn" href={unit ? `/may/${parent!.id}` : '/may'}>Đóng</Link>} />
      <div className="mt-4" />
      <Flash err={sp.err} />
      <form action={createMachine} className="card grid max-w-3xl gap-4 p-5 sm:grid-cols-2">
        <input type="hidden" name="back" value={back} />
        {unit && <input type="hidden" name="parent_id" value={parent!.id} />}
        <label className="lbl"><span className="req">Mã máy</span>
          <input name="code" className="inp mono uppercase" required placeholder={unit ? `${parent!.code}-CV` : 'EXT-SI-02'} defaultValue={unit ? `${parent!.code}-` : ''} />
        </label>
        <label className="lbl"><span className="req">Tên</span>
          <input name="name" className="inp" required placeholder={unit ? 'Lò lưu hóa khí nóng' : 'Line đùn silicone 2'} />
        </label>
        {unit ? (
          <>
            <label className="lbl">Loại máy con
              <input name="unit_kind" className="inp" list="unit-kinds" placeholder="Lò lưu hóa, máy kéo, thu cuộn…" />
              <datalist id="unit-kinds">
                {['Giá xả', 'Bộ tích dây', 'Máy đùn', 'Đầu đùn & khuôn', 'Lò lưu hóa', 'Máng làm mát', 'Hộp phun talc', 'Máy thử cao áp', 'Máy đo OD', 'Máy in', 'Máy kéo', 'Thu cuộn', 'Đầu quấn băng AL/PET', 'Cấp dây drain', 'Tủ điện & PLC'].map((k) => <option key={k} value={k} />)}
              </datalist>
            </label>
            <label className="lbl">Thứ tự trên dây chuyền
              <input name="seq" className="inp" inputMode="numeric" defaultValue={((parent!.unit_count ?? 0) + 1) * 10} />
            </label>
            <label className="flex items-start gap-2 text-[14px] sm:col-span-2">
              <input type="checkbox" name="critical" className="mt-1" />
              <span>Máy quan trọng: máy này hỏng thì cả dây chuyền chuyển sang Hỏng</span>
            </label>
          </>
        ) : (
          <label className="lbl sm:col-span-2"><span className="req">Công đoạn</span>
            <select name="op_code" className="inp" required defaultValue="">
              <option value="" disabled>Chọn công đoạn dây chuyền làm</option>
              {(ops ?? []).map((o) => <option key={o.code} value={o.code}>{o.code} · {o.name}</option>)}
            </select>
          </label>
        )}
        <label className="flex items-start gap-2 text-[14px] sm:col-span-2">
          <input type="checkbox" name="template" defaultChecked className="mt-1" />
          <span>Thêm sẵn bộ trường thông số mẫu (điện áp, công suất, cảm biến, bánh răng, kích thước cút đấu nối…) để điền</span>
        </label>
        <div className="flex gap-2 sm:col-span-2"><SubmitButton>{unit ? 'Thêm máy con' : 'Thêm dây chuyền'}</SubmitButton></div>
      </form>
    </>
  );
}
