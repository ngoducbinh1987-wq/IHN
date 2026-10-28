import Link from 'next/link';
import { Empty, Flash, Toolbar } from '@/components/ui';
import { SubmitButton } from '@/components/submit-button';
import { requirePage, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { can } from '@/lib/session';
import { addCheckItem, deleteRow, saveSettings } from '../actions';

export const metadata = { title: 'Cài đặt máy' };

const DOW: [number, string][] = [[1, 'T2'], [2, 'T3'], [3, 'T4'], [4, 'T5'], [5, 'T6'], [6, 'T7'], [7, 'CN']];

export default async function MachineSettings({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string }> }) {
  const sp = await searchParams;
  await requirePage('may-cai-dat');
  const me = await requirePerm('machine', 'view');
  const canCfg = can(me, 'machine', 'config');
  const supabase = await createClient();
  const [{ data: settings }, { data: items }, { data: lines }] = await Promise.all([
    supabase.schema('app').from('v_machine_settings').select('key, value'),
    supabase.schema('app').from('v_maint_check_items').select('*').order('sort'),
    supabase.schema('app').from('v_machines').select('id, code').is('line_id', null).order('code'),
  ]);
  const get = (k: string) => (settings ?? []).find((s) => s.key === k)?.value;
  const shift = get('shift') ?? { sessions: [['08:00', '12:00'], ['13:00', '17:00']], minutes: 480, break_min: 60, fill: 0.85, workdays: [1, 2, 3, 4, 5, 6] };
  const remind = get('remind_days') ?? { MINOR: 7, MAJOR: 30 };
  const s = shift.sessions as [string, string][];
  const back = '/may/cai-dat';
  return (
    <>
      <Toolbar title="Cài đặt máy" />
      <div className="mt-4" />
      <Flash ok={sp.ok} err={sp.err} />
      <section className="card mb-4 max-w-4xl px-5 py-4 text-[14px]">
        <div className="mb-1 font-medium">Lịch làm việc (dùng chung với Kế hoạch sản xuất)</div>
        <p>Ca A {s[0]?.[0] ?? '08:00'}–{s[0]?.[1] ?? '12:00'}, {s[1]?.[0] ?? '13:00'}–{s[1]?.[1] ?? '17:00'} · ngày làm việc {DOW.filter(([d]) => (shift.workdays as number[]).includes(d)).map(([, t]) => t).join(', ')} · tỷ lệ xếp lịch {Math.round(Number(shift.fill) * 100)}% · {get('max_machines_per_operator') ?? 2} máy/người.</p>
        <p className="mt-1 text-[12.5px] text-muted">Giám đốc sửa ca, ngày làm việc, tỷ lệ xếp lịch, số máy/người ở <Link href="/tham-so" className="link">Sản xuất → Tham số xếp lịch</Link>.</p>
      </section>

      <form action={saveSettings} className="card mb-4 grid max-w-4xl gap-4 p-5 md:grid-cols-2">
        <input type="hidden" name="back" value={back} />
        <fieldset className="contents" disabled={!canCfg}>
          <label className="lbl">Nhắc bảo dưỡng nhỏ trước (ngày)<input name="remind_minor" className="inp" inputMode="numeric" defaultValue={remind.MINOR} /></label>
          <label className="lbl">Nhắc bảo dưỡng lớn trước (ngày)<input name="remind_major" className="inp" inputMode="numeric" defaultValue={remind.MAJOR} /></label>
        </fieldset>
        <p className="text-[12.5px] text-muted md:col-span-2">Nhắc hiện trên Thông báo cho TP Kỹ thuật/QA và Quản lý SX lúc 07:00; quá hạn báo thêm Ban giám đốc. Báo cáo bảo trì tháng gửi email cho Ban giám đốc ngày 1 hằng tháng. Số ngày nhắc ở đây là mặc định khi thêm kế hoạch mới; mỗi kế hoạch sửa riêng được.</p>
        {canCfg && <div className="md:col-span-2"><SubmitButton>Lưu ngày nhắc</SubmitButton></div>}
      </form>

      <section className="card max-w-4xl overflow-x-auto">
        <div className="card-h">Mục kiểm tra checklist đầu ca</div>
        {(items ?? []).length ? (
          <table className="tbl">
            <thead><tr><th>Mục kiểm tra</th><th>Áp dụng</th><th className="num">Thứ tự</th><th /></tr></thead>
            <tbody>
              {(items ?? []).map((i) => (
                <tr key={i.id}>
                  <td>{i.label}</td><td>{i.machine_id ? (lines ?? []).find((l) => l.id === i.machine_id)?.code : 'Mọi dây chuyền'}</td><td className="num">{i.sort}</td>
                  <td>{canCfg && <form action={deleteRow}><input type="hidden" name="table" value="check_item" /><input type="hidden" name="id" value={i.id} /><input type="hidden" name="back" value={back} /><SubmitButton className="btn btn-sm btn-bad-o" pendingText="…">Xóa</SubmitButton></form>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : <Empty>Chưa có mục kiểm tra.</Empty>}
        {canCfg && <form action={addCheckItem} className="grid gap-3 border-t border-line p-4 sm:grid-cols-[minmax(0,1fr)_200px_90px_auto] sm:items-end">
          <input type="hidden" name="back" value={back} />
          <label className="lbl"><span className="req">Mục kiểm tra</span><input name="label" className="inp" required placeholder="Kiểm tra nhiệt độ 12 module lò" /></label>
          <label className="lbl">Áp dụng cho<select name="machine_id" className="inp" defaultValue=""><option value="">Mọi dây chuyền</option>{(lines ?? []).map((l) => <option key={l.id} value={l.id}>{l.code}</option>)}</select></label>
          <label className="lbl">Thứ tự<input name="sort" className="inp" inputMode="numeric" defaultValue={10} /></label>
          <SubmitButton>Thêm</SubmitButton>
        </form>}
      </section>
    </>
  );
}
