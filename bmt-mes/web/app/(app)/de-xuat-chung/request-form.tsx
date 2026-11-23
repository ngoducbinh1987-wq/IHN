import { DateInput } from '@/components/date-input';
import { SubmitButton } from '@/components/submit-button';
import { numIn } from '@/lib/format';
import { DEPTS, SHIFTS, approvalText, type Req, type ReqType } from '@/lib/requests';
import { saveRequest } from './actions';

type Opt = { code: string; name: string | null };

// Mẫu đề xuất theo loại: ô chung (tiêu đề, nội dung, gấp) + ô riêng của loại
export function RequestForm({ t, r, workers, machines, mats, back, review }: {
  t: ReqType; r?: Req | null; workers?: Opt[]; machines: Opt[]; mats: (Opt & { uom: string | null })[]; back: string; review?: boolean;
}) {
  const d = r?.data ?? {};
  const items = r?.items?.length ? r.items : [];
  const rows = Math.max(items.length + 2, 5);
  return (
    <form action={saveRequest} className="card flex flex-col gap-4 p-4 md:p-5" id="mau-de-xuat">
      <input type="hidden" name="type" value={t.code} />
      <input type="hidden" name="back" value={back} />
      {r && <input type="hidden" name="id" value={r.id} />}
      <div className="rounded bg-brand-soft px-3 py-2 text-[13.5px]">
        <b>{t.name}.</b> {t.hint} <span className="text-muted">{approvalText(t)}</span>
      </div>

      {!review && workers && workers.length > 0 && !r && (
        <label className="lbl max-w-md">Đề xuất cho (lập thay công nhân chưa có tài khoản)
          <select className="inp" name="operator_code" defaultValue="">
            <option value="">Chính tôi</option>
            {workers.map((w) => <option key={w.code} value={w.code}>{w.code}{w.name ? ` · ${w.name}` : ''}</option>)}
          </select>
        </label>
      )}

      <div className="grid gap-4 md:grid-cols-[2fr_1fr]">
        <label className="lbl">Tiêu đề (để trống: theo tên loại)
          <input className="inp" name="title" defaultValue={r?.title ?? ''} maxLength={200} placeholder={t.name} />
        </label>
        <label className="flex items-center gap-2 self-end pb-2 text-[14px]">
          <input type="checkbox" name="urgent" defaultChecked={r?.urgent ?? false} />Gấp (hạn duyệt 4 giờ)
        </label>
      </div>

      {['LEAVE', 'MATERNITY', 'TRIP'].includes(t.form) && (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <label className="lbl"><span className="req">{t.form === 'MATERNITY' ? 'Bắt đầu nghỉ' : 'Từ ngày'}</span><DateInput name="date_from" defaultValue={r?.date_from} required /></label>
          <label className="lbl"><span className={t.form === 'LEAVE' ? '' : 'req'}>{t.form === 'MATERNITY' ? 'Ngày nghỉ cuối' : 'Đến ngày'}</span>
            <DateInput name="date_to" defaultValue={r?.date_to} required={t.form !== 'LEAVE'} /></label>
          {t.form === 'LEAVE' && (
            <label className="lbl">Thời gian
              <select className="inp" name="part" defaultValue={r?.part ?? 'FULL'}>
                <option value="FULL">Cả ngày</option><option value="AM">Nửa đầu ca (1 ngày)</option><option value="PM">Nửa sau ca (1 ngày)</option>
              </select>
            </label>
          )}
          {t.code === 'VIEC_RIENG' && (
            <label className="lbl">Hưởng lương
              <select className="inp" name="paid" defaultValue={r?.paid === false ? '0' : '1'}>
                <option value="1">Có lương (kết hôn, tang…)</option><option value="0">Không lương (Giám đốc duyệt)</option>
              </select>
            </label>
          )}
          {t.form === 'MATERNITY' && <label className="lbl">Ngày dự sinh<DateInput name="data_due_date" defaultValue={d.due_date} /></label>}
          {t.form === 'MATERNITY' && <label className="lbl">Người nhận bàn giao việc<input className="inp" name="data_handover" defaultValue={d.handover ?? ''} /></label>}
          {t.form === 'TRIP' && <label className="lbl"><span className="req">Nơi công tác</span><input className="inp" name="data_place" defaultValue={d.place ?? ''} required /></label>}
          {t.form === 'TRIP' && <label className="lbl">Phương tiện<input className="inp" name="data_transport" defaultValue={d.transport ?? ''} /></label>}
          {t.form === 'TRIP' && <label className="lbl">Dự trù chi phí<input className="inp" name="data_cost_plan" defaultValue={d.cost_plan ?? ''} placeholder="Ví dụ: 2.500.000 đ" /></label>}
        </div>
      )}

      {t.form === 'LATE' && (
        <div className="grid gap-4 sm:grid-cols-3">
          <label className="lbl"><span className="req">Ngày</span><DateInput name="date_from" defaultValue={r?.date_from} required /></label>
          <label className="lbl">Từ giờ<input className="inp" type="time" name="time_from" defaultValue={r?.time_from?.slice(0, 5) ?? ''} /></label>
          <label className="lbl">Đến giờ<input className="inp" type="time" name="time_to" defaultValue={r?.time_to?.slice(0, 5) ?? ''} /></label>
        </div>
      )}

      {t.form === 'SHIFT' && (
        <div className="grid gap-4 sm:grid-cols-3">
          <label className="lbl"><span className="req">Ngày</span><DateInput name="date_from" defaultValue={r?.date_from} required /></label>
          <label className="lbl">Ca hiện tại<select className="inp" name="data_from_shift" defaultValue={d.from_shift ?? 'Ca 1'}>{SHIFTS.map((x) => <option key={x}>{x}</option>)}</select></label>
          <label className="lbl"><span className="req">Muốn đổi sang</span><select className="inp" name="data_to_shift" defaultValue={d.to_shift ?? 'Ca 2'}>{SHIFTS.map((x) => <option key={x}>{x}</option>)}<option>Làm thêm giờ</option></select></label>
        </div>
      )}

      {t.form === 'MONEY' && (
        <div className="grid gap-4 sm:grid-cols-3">
          <label className="lbl"><span className="req">Số tiền (đ)</span><input className="inp text-right" name="amount" inputMode="numeric" required defaultValue={r?.amount ? numIn(r.amount) : ''} /></label>
          {t.code === 'TAM_UNG' && <label className="lbl">Ngày hoàn ứng<DateInput name="date_from" defaultValue={r?.date_from} /></label>}
        </div>
      )}

      {t.form === 'REPAIR' && (
        <label className="lbl max-w-md">Máy (để trống nếu sửa nhà xưởng, điện, nước)
          <select className="inp" name="machine_code" defaultValue={r?.machine_code ?? ''}>
            <option value="">—</option>
            {machines.map((m) => <option key={m.code} value={m.code}>{m.code}{m.name ? ` · ${m.name}` : ''}</option>)}
          </select>
        </label>
      )}

      {t.form === 'OTHER' && (
        <label className="lbl max-w-md"><span className="req">Bộ phận nhận</span>
          <select className="inp" name="target_dept" defaultValue={r?.target_dept ?? ''} required>
            <option value="">— chọn —</option>
            {DEPTS.filter(([c]) => c !== 'IT').map(([c, n]) => <option key={c} value={c}>{n}</option>)}
          </select>
        </label>
      )}

      <label className="lbl"><span className="req">{t.form === 'REPAIR' ? 'Hiện tượng hư hỏng' : t.form === 'IDEA' ? 'Hiện trạng và đề xuất cải tiến' : 'Nội dung / lý do'}</span>
        <textarea className="inp" name="content" rows={4} required defaultValue={r?.content ?? ''} />
      </label>
      {t.form === 'IDEA' && (
        <label className="lbl">Lợi ích ước tính<input className="inp" name="data_benefit" defaultValue={d.benefit ?? ''} placeholder="Ví dụ: giảm 2 % phế, tiết kiệm 30 phút/ca" /></label>
      )}

      {t.form === 'BUY' && (
        <div className="overflow-x-auto rounded border border-line">
          <datalist id="req-mats">{mats.map((m) => <option key={m.code} value={`${m.code} · ${m.name} (${m.uom})`} />)}</datalist>
          <table className="tbl">
            <thead><tr><th className="w-10">#</th><th>Mã vật tư (nếu có)</th><th>Tên hàng</th><th>Quy cách</th><th className="w-28 text-right">Số lượng</th><th className="w-24">ĐVT</th><th className="w-36 text-right">Giá ước tính (đ)</th></tr></thead>
            <tbody>
              {Array.from({ length: rows }, (_, i) => {
                const it = items[i] ?? {};
                return (
                  <tr key={i}>
                    <td className="text-muted">{i + 1}</td>
                    <td><input className="inp" name="item_code" list="req-mats" defaultValue={it.code ?? ''} aria-label={`Mã vật tư dòng ${i + 1}`} /></td>
                    <td><input className="inp" name="item_name" defaultValue={it.name ?? ''} aria-label={`Tên hàng dòng ${i + 1}`} required={i === 0} /></td>
                    <td><input className="inp" name="item_spec" defaultValue={it.spec ?? ''} aria-label={`Quy cách dòng ${i + 1}`} /></td>
                    <td><input className="inp text-right" name="item_qty" inputMode="decimal" defaultValue={it.qty ? numIn(it.qty) : ''} aria-label={`Số lượng dòng ${i + 1}`} required={i === 0} /></td>
                    <td><input className="inp" name="item_unit" defaultValue={it.unit ?? ''} aria-label={`Đơn vị dòng ${i + 1}`} /></td>
                    <td><input className="inp text-right" name="item_price" inputMode="numeric" defaultValue={it.price ? numIn(it.price) : ''} aria-label={`Giá dòng ${i + 1}`} /></td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          <p className="px-3 py-2 text-[12.5px] text-muted">Hàng chưa có mã: chỉ ghi tên, Phòng Mua khai vật tư mới khi lập đề xuất mua. Cần thêm dòng: lưu rồi sửa tiếp.</p>
        </div>
      )}

      {t.allow_anonymous && !review && (
        <label className="flex items-center gap-2 text-[14px]"><input type="checkbox" name="anonymous" defaultChecked={r?.anonymous ?? false} />
          Gửi ẩn danh (người duyệt không thấy tên bạn; chỉ Quản trị hệ thống tra được)</label>
      )}

      <div className="flex flex-wrap gap-2">
        {review ? (
          <SubmitButton className="btn btn-pri">Lưu nội dung đã sửa</SubmitButton>
        ) : (
          <>
            <SubmitButton className="btn btn-pri" name="send" value="1">Lưu và gửi đề xuất</SubmitButton>
            <SubmitButton className="btn" name="send" value="0">Lưu nháp</SubmitButton>
          </>
        )}
      </div>
      {review && <p className="text-[13px] text-muted">Bạn đang giữ bước duyệt: sửa xong MES ghi vào lịch sử duyệt và báo người gửi, sau đó duyệt như thường.</p>}
    </form>
  );
}
