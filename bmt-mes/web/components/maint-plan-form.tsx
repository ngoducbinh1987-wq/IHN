import { SubmitButton } from '@/components/submit-button';
import { ASSIGNEE, LEVEL, PLAN_KIND } from '@/lib/machine';
import { savePlan } from '@/app/(app)/may/actions';

type M = { id: string; code: string; name: string; unit_kind: string | null; line_id: string | null };
type Plan = Record<string, any>;

// Form kế hoạch bảo dưỡng: người dùng tự đặt chu kỳ (ngày / giờ chạy / km), mức (nhỏ, lớn), nhắc trước, làm trong ca hay ngoài giờ
export function PlanForm({ machines, plan, machineId, remind, back }:
  { machines: M[]; plan?: Plan; machineId?: string; remind: { MINOR: number; MAJOR: number }; back: string }) {
  const lines = machines.filter((m) => !m.line_id);
  const v = (k: string) => (plan?.[k] ?? '') as string | number;
  const lastDone = plan?.last_done_at ? new Date(new Date(plan.last_done_at).getTime() + 7 * 3_600_000).toISOString().slice(0, 10) : '';
  return (
    <form action={savePlan} className="card grid max-w-4xl gap-4 p-5 md:grid-cols-2">
      <input type="hidden" name="back" value={back} />
      {plan && <input type="hidden" name="id" value={plan.id} />}
      <label className="lbl md:col-span-2"><span className="req">Máy</span>
        <select name="machine_id" className="inp" required defaultValue={plan?.machine_id ?? machineId ?? ''}>
          <option value="" disabled>Chọn dây chuyền hoặc máy con</option>
          {lines.map((l) => (
            <optgroup key={l.id} label={`${l.code} · ${l.name}`}>
              <option value={l.id}>{l.code} · cả dây chuyền</option>
              {machines.filter((u) => u.line_id === l.id).map((u) => <option key={u.id} value={u.id}>{u.code} · {u.unit_kind ?? u.name}</option>)}
            </optgroup>
          ))}
        </select>
      </label>
      <label className="lbl md:col-span-2"><span className="req">Công việc</span>
        <input name="name" className="inp" required defaultValue={v('name')} placeholder="Vệ sinh lò lưu hóa, kiểm tra thanh gia nhiệt" />
      </label>
      <label className="lbl">Loại việc
        <select name="kind" className="inp" defaultValue={plan?.kind ?? 'INSPECT'}>{Object.entries(PLAN_KIND).map(([k, t]) => <option key={k} value={k}>{t}</option>)}</select>
      </label>
      <label className="lbl">Mức bảo dưỡng
        <select name="level" className="inp" defaultValue={plan?.level ?? 'MINOR'}>
          {Object.entries(LEVEL).map(([k, t]) => <option key={k} value={k}>{t} (nhắc trước {k === 'MAJOR' ? remind.MAJOR : remind.MINOR} ngày)</option>)}
        </select>
      </label>
      <fieldset className="rounded border border-line p-3 md:col-span-2">
        <legend className="px-1 text-[13px] text-muted">Chu kỳ · điền một hoặc nhiều điều kiện, điều kiện nào đến trước tính trước</legend>
        <div className="grid gap-3 sm:grid-cols-3">
          <label className="lbl">Theo ngày<input name="every_days" className="inp" inputMode="numeric" defaultValue={v('every_days')} placeholder="7" /></label>
          <label className="lbl">Theo giờ chạy<input name="every_hours" className="inp" inputMode="decimal" defaultValue={v('every_hours')} placeholder="500" /></label>
          <label className="lbl">Theo km sản xuất<input name="every_km" className="inp" inputMode="decimal" defaultValue={v('every_km')} placeholder="1.000" /></label>
        </div>
      </fieldset>
      <label className="lbl">Nhắc trước (ngày)
        <input name="remind_days" className="inp" inputMode="numeric" defaultValue={v('remind_days')} placeholder={`Để trống: nhỏ ${remind.MINOR} ngày, lớn ${remind.MAJOR} ngày`} />
      </label>
      <label className="lbl">Người làm
        <select name="assignee_role" className="inp" defaultValue={plan?.assignee_role ?? 'KT_TP'}>{Object.entries(ASSIGNEE).map(([k, t]) => <option key={k} value={k}>{t}</option>)}</select>
      </label>
      <label className="lbl">Thời gian dừng máy (phút)
        <input name="stop_minutes" className="inp" inputMode="numeric" defaultValue={v('stop_minutes') || 0} />
      </label>
      <label className="flex items-center gap-2 self-end pb-2 text-[14px]">
        <input type="checkbox" name="off_shift" defaultChecked={Boolean(plan?.off_shift)} />Làm ngoài giờ ca (không trừ năng lực máy)
      </label>
      <label className="lbl md:col-span-2">Các bước, mỗi dòng một bước
        <textarea name="steps" className="inp" rows={4} defaultValue={(plan?.steps ?? []).join('\n')} placeholder={'Tắt gia nhiệt, chờ nguội dưới 60 °C\nHút bụi trong các module\nĐo điện trở thanh gia nhiệt'} />
      </label>
      <label className="lbl md:col-span-2">Phụ tùng, vật tư
        <input name="parts" className="inp" defaultValue={v('parts')} placeholder="Dầu bánh răng ISO VG 220 · 18 lít" />
      </label>
      <fieldset className="rounded border border-line p-3 md:col-span-2">
        <legend className="px-1 text-[13px] text-muted">Mốc tính chu kỳ</legend>
        <div className="grid gap-3 sm:grid-cols-3">
          <label className="lbl">Lần làm gần nhất<input name="last_done" type="date" className="inp" defaultValue={lastDone} /><input type="hidden" name="last_done_orig" value={lastDone} /></label>
          <label className="lbl">Giờ chạy đã có từ lần đó<input name="base_hours" className="inp" inputMode="decimal" defaultValue={v('base_hours') || ''} placeholder="0" /></label>
          <label className="lbl">Km đã chạy từ lần đó<input name="base_km" className="inp" inputMode="decimal" defaultValue={v('base_km') || ''} placeholder="0" /></label>
        </div>
        <p className="mt-2 text-[12.5px] text-muted">Để trống ngày: tính từ hôm nay. Giờ chạy, km sau đó hệ thống tự cộng từ báo cáo ca hoặc PLC.</p>
      </fieldset>
      <label className="lbl md:col-span-2">Ghi chú<input name="note" className="inp" defaultValue={v('note')} /></label>
      {plan && <label className="flex items-center gap-2 text-[14px]"><input type="checkbox" name="active" defaultChecked={plan.active} />Đang áp dụng</label>}
      <div className="md:col-span-2"><SubmitButton>{plan ? 'Lưu kế hoạch' : 'Thêm kế hoạch'}</SubmitButton></div>
    </form>
  );
}
