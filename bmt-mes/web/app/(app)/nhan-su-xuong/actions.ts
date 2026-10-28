'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { type Kh, ROLE, carryOver, hasRole, loadKh, rebuild, schedulePayload } from '@/lib/kh/load';
import { type RMachine, type RPerson, type RosterIn, evalRoster, suggestRoster, summarize, weekDays } from '@/lib/kh/roster';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { addDays } from '@/lib/kh/scheduler';

// Nhân sự xưởng: TP SX / Kế hoạch SX ghi qua hàm database (database kiểm quyền, ghi nhật ký, làm lịch máy cần xếp lại)
const txt = (f: FormData, k: string) => String(f.get(k) ?? '').trim();
const opt = (f: FormData, k: string) => txt(f, k) || null;
const back = (f: FormData, kind: 'ok' | 'err', msg: string): never => {
  const tab = txt(f, 'tab') || 'nguoi', m = txt(f, 'm');
  redirect(`/nhan-su-xuong?tab=${tab}${m ? `&m=${m}` : ''}&${kind}=${encodeURIComponent(msg)}`);
};
const done = (f: FormData, msg: string): never => {
  revalidatePath('/nhan-su-xuong'); revalidatePath('/lich-may'); revalidatePath('/lenh-ngay');
  return back(f, 'ok', msg);
};
const friendly = (m: string) => m.replace(/^.*?ERROR:\s*/, '');

export async function saveOperator(f: FormData) {
  const db = await createClient();
  const { data, error } = await db.schema('app').rpc('kh_save_operator', {
    p_code: opt(f, 'code'), p_name: txt(f, 'name'), p_job: txt(f, 'job'), p_extra: opt(f, 'extra'), p_note: opt(f, 'note'),
    p_profile: opt(f, 'profile'), p_reason: opt(f, 'reason'),
  });
  if (error) back(f, 'err', friendly(error.message));
  // Người mới: mặc định đứng chính mọi máy (anh Bình 28/10/2026: công nhân vận hành được mọi thiết bị)
  if (!txt(f, 'code') && txt(f, 'all_machines') === '1') {
    const { error: e2 } = await db.schema('app').rpc('kh_skill_all', { p_code: String(data), p_reason: 'Người mới đứng chính mọi máy' });
    if (e2) back(f, 'err', `Đã thêm ${String(data)} nhưng chưa giao máy: ${friendly(e2.message)}`);
    done(f, `Đã thêm ${String(data)}, đứng chính mọi máy. TP KT/QA ký tay nghề ở bảng Người × máy.`);
  }
  done(f, txt(f, 'code') ? `Đã lưu ${String(data)}` : `Đã thêm ${String(data)}. Giao máy ở bảng Người × máy (TP KT/QA ký tay nghề).`);
}

// Người giữ kho thành phẩm (ký phiếu nhập kho TP, phiếu xuất giao) – biến số, TP SX khai báo
export async function setFgKeeper(f: FormData) {
  const db = await createClient();
  const on = txt(f, 'on') === '1';
  const { error } = await db.schema('app').rpc('kh_set_fg_keeper', { p_code: txt(f, 'code'), p_on: on, p_reason: null });
  if (error) back(f, 'err', friendly(error.message));
  done(f, `${txt(f, 'code')} ${on ? 'được giao giữ kho thành phẩm' : 'thôi giữ kho thành phẩm'}`);
}

export async function setOperatorActive(f: FormData) {
  const db = await createClient();
  const active = txt(f, 'active') === '1';
  const { error } = await db.schema('app').rpc('kh_set_operator_active', { p_code: txt(f, 'code'), p_active: active, p_reason: txt(f, 'reason') });
  if (error) back(f, 'err', friendly(error.message));
  done(f, `${txt(f, 'code')} ${active ? 'làm lại' : 'ngừng làm'}. Bấm Xếp lại lịch để lịch máy tính theo người hiện có.`);
}

// Người × máy: Đứng chính / Đang học / bỏ giao (dùng chung tay nghề ở Hồ sơ máy; TP KT/QA ký xác nhận)
export async function setSkill(f: FormData) {
  const db = await createClient();
  const level = txt(f, 'level');
  const { error } = level
    ? await db.schema('app').rpc('set_operator_skill', { p_machine: txt(f, 'machine_id'), p_operator: txt(f, 'operator'), p_level: level, p_reason: opt(f, 'reason') ?? 'Nhân sự xưởng' })
    : await db.schema('app').rpc('remove_operator_skill', { p_machine: txt(f, 'machine_id'), p_operator: txt(f, 'operator'), p_reason: opt(f, 'reason') ?? 'Nhân sự xưởng' });
  if (error) back(f, 'err', friendly(error.message));
  done(f, level ? `Đã giao ${txt(f, 'operator')} ${level === 'MAIN' ? 'đứng chính' : 'đang học'} ${txt(f, 'machine')}` : `Đã bỏ giao ${txt(f, 'operator')} khỏi ${txt(f, 'machine')}`);
}

export async function saveAbsence(f: FormData) {
  const db = await createClient();
  const { error } = await db.schema('app').rpc('kh_save_absence', {
    p_id: opt(f, 'id'), p_operator: txt(f, 'operator'), p_from: opt(f, 'from'), p_to: opt(f, 'to') ?? opt(f, 'from'),
    p_part: txt(f, 'part') || 'FULL', p_kind: txt(f, 'kind') || 'PHEP', p_note: opt(f, 'note'),
  });
  if (error) back(f, 'err', friendly(error.message));
  done(f, `Đã ghi lịch vắng ${txt(f, 'operator')}. Lịch máy cần xếp lại.`);
}

export async function deleteAbsence(f: FormData) {
  const db = await createClient();
  const { error } = await db.schema('app').rpc('kh_delete_absence', { p_id: txt(f, 'id'), p_reason: txt(f, 'reason') });
  if (error) back(f, 'err', friendly(error.message));
  done(f, 'Đã bỏ lịch vắng');
}

export async function saveCover(f: FormData) {
  const db = await createClient();
  const { error } = await db.schema('app').rpc('kh_save_cover', {
    p_id: opt(f, 'id'), p_operator: txt(f, 'operator'), p_machine: txt(f, 'machine'), p_from: opt(f, 'from'), p_to: opt(f, 'to') ?? opt(f, 'from'),
    p_reason: txt(f, 'reason'),
  });
  if (error) back(f, 'err', friendly(error.message));
  done(f, `Đã phân công ${txt(f, 'operator')} kiêm nhiệm tạm ${txt(f, 'machine')}. Lịch máy cần xếp lại.`);
}

export async function deleteCover(f: FormData) {
  const db = await createClient();
  const { error } = await db.schema('app').rpc('kh_delete_cover', { p_id: txt(f, 'id'), p_reason: txt(f, 'reason') });
  if (error) back(f, 'err', friendly(error.message));
  done(f, 'Đã bỏ phân công kiêm nhiệm');
}

// Tổ đóng gói theo ngày: 1 hoặc 2 người (trống = mặc định), chọn người cụ thể (không bắt buộc)
export async function setCrew(f: FormData) {
  const db = await createClient();
  const crew = txt(f, 'crew');
  const members = f.getAll('members').map(String).filter(Boolean);
  const { error } = await db.schema('app').rpc('kh_set_crew', {
    p_date: txt(f, 'date'), p_machine: txt(f, 'machine'), p_crew: crew ? Number(crew) : null, p_members: members, p_note: opt(f, 'note'),
  });
  if (error) back(f, 'err', friendly(error.message));
  done(f, `Đã đặt tổ đóng gói ${txt(f, 'machine')} ngày ${txt(f, 'date').split('-').reverse().slice(0, 2).join('/')}`);
}

// Ca của người: làm ca 2 / ca 3 trong khoảng ngày (ngoài khoảng: ca 1); database kiểm nghỉ 12 giờ khi đổi ca
export async function saveOpShift(f: FormData) {
  const db = await createClient();
  const { error } = await db.schema('app').rpc('kh_save_op_shift', {
    p_id: opt(f, 'id'), p_operator: txt(f, 'operator'), p_from: opt(f, 'from'), p_to: opt(f, 'to') ?? opt(f, 'from'), p_shift: Number(txt(f, 'shift')), p_note: opt(f, 'note'),
  });
  if (error) back(f, 'err', friendly(error.message));
  done(f, `Đã đặt ${txt(f, 'operator')} làm ca ${txt(f, 'shift')}. Bấm Xếp lại lịch ở Lịch máy.`);
}

export async function deleteOpShift(f: FormData) {
  const db = await createClient();
  const { error } = await db.schema('app').rpc('kh_delete_op_shift', { p_id: txt(f, 'id'), p_reason: txt(f, 'reason') });
  if (error) back(f, 'err', friendly(error.message));
  done(f, 'Đã bỏ ca, người đó về ca 1');
}

// ---------------- Tay nghề: đứng chính mọi máy (TP SX), ký một lần (TP KT/QA) ----------------
export async function skillAll(f: FormData) {
  const db = await createClient();
  const { data, error } = await db.schema('app').rpc('kh_skill_all', { p_code: txt(f, 'code'), p_reason: opt(f, 'reason') });
  if (error) back(f, 'err', friendly(error.message));
  done(f, `${txt(f, 'code')} đứng chính mọi máy (${Number(data)} máy mới giao). TP KT/QA ký tay nghề.`);
}

export async function signAll(f: FormData) {
  const db = await createClient();
  const { data, error } = await db.schema('app').rpc('sign_skills_all', { p_operator: opt(f, 'code') });
  if (error) back(f, 'err', friendly(error.message));
  done(f, `Đã ký ${Number(data)} tay nghề`);
}

// ---------------- Bảng ca tuần: MES lập → TP SX sửa, gửi → Giám đốc duyệt (được sửa) → MES gửi công nhân ----------------
const wk = (f: FormData) => txt(f, 'w');
const backW = (f: FormData, kind: 'ok' | 'err', msg: string): never =>
  redirect(`/nhan-su-xuong?tab=ca${wk(f) ? `&w=${wk(f)}` : ''}&${kind}=${encodeURIComponent(msg)}`);
const doneW = (f: FormData, msg: string): never => {
  revalidatePath('/nhan-su-xuong'); revalidatePath('/lich-may'); revalidatePath('/lenh-ngay');
  return backW(f, 'ok', msg);
};

async function khFor(planId?: string | null) {
  const me = await requireMe();
  const db = await createClient();
  const kh = await loadKh(db, { plan: planId ?? undefined, roles: me.roles });
  return { me, db, kh };
}

// Đọc bảng ca từ form: máy (số ca + ngày áp dụng), người (ca, phụ trách), QC
function readRoster(f: FormData, week: string, kh: Kh): RosterIn {
  const days = weekDays(week, kh.cal.wd);
  const machines: RMachine[] = [];
  // ngày đã qua / hôm nay (không sửa được): giữ đúng ca máy đã có trong bảng ca để bản in, lịch sử không mất
  const tomorrow = addDays(kh.now.date, 1);
  for (const m of kh.machines) {
    const past = new Set<string>();
    for (const v of f.getAll(`mp_${m.code}`).map(String)) {
      const [d, k] = v.split(':'); const n = Number(k);
      if (days.includes(d) && d < tomorrow && (n === 2 || n === 3)) { machines.push({ machine: m.code, date: d, shifts: n }); past.add(d); }
    }
    const n = Number(txt(f, `ms_${m.code}`) || 1);
    if (n < 2) continue;
    const on = new Set(f.getAll(`md_${m.code}`).map(String));
    for (const d of days) if (d >= tomorrow && !past.has(d) && on.has(d)) machines.push({ machine: m.code, date: d, shifts: n });
  }
  const lead2 = txt(f, 'lead2'), lead3 = txt(f, 'lead3');
  const people: RPerson[] = kh.operators.map((o) => {
    const sh = Number(txt(f, `ps_${o.code}`) || 1);
    return { code: o.code, shift: sh, ...((sh === 2 && lead2 === o.code) || (sh === 3 && lead3 === o.code) ? { lead: true } : {}) };
  });
  const mode = txt(f, 'qc_mode') === 'QC' ? 'QC' : 'LEAD';
  return { week, machines, people, qc: { mode, who: mode === 'QC' ? opt(f, 'qc_who') : null } };
}

// MES lập (hoặc lập lại) bảng ca tuần
export async function suggestWeek(f: FormData) {
  const week = wk(f);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(week)) backW(f, 'err', 'Chọn tuần');
  const { db, kh } = await khFor(opt(f, 'plan_id'));
  if (!kh.orders.length) backW(f, 'err', 'Chưa có kế hoạch tháng có việc để MES tính bảng ca');
  const { roster, summary } = suggestRoster(kh, week);
  const { error } = await db.schema('app').rpc('roster_save', {
    p: { id: opt(f, 'id'), week_start: week, plan_id: kh.planId, machines: roster.machines, people: roster.people, qc: roster.qc, summary },
  });
  if (error) backW(f, 'err', friendly(error.message));
  doneW(f, `MES đã lập bảng ca: ${summary.reason}. TP SX xem, sửa rồi gửi Giám đốc duyệt.`);
}

// Lưu (và tính lại) bảng ca đã sửa; Giám đốc sửa khi duyệt thì ghi lịch sử, báo TP SX
export async function saveWeek(f: FormData) {
  const week = wk(f);
  const { db, kh } = await khFor(opt(f, 'plan_id'));
  const r = readRoster(f, week, kh);
  const ev = evalRoster(kh, r);
  const base = evalRoster(kh, { ...r, machines: [], people: kh.operators.map((o) => ({ code: o.code, shift: 1 })) });
  const summary = summarize(kh, r, ev, base, opt(f, 'reason_txt') ?? 'TP SX sửa bảng ca', [...new Set(r.machines.map((m) => m.machine))]);
  const { error } = await db.schema('app').rpc('roster_save', {
    p: { id: opt(f, 'id'), week_start: week, plan_id: kh.planId, machines: r.machines, people: r.people, qc: r.qc, summary, note: opt(f, 'note'), edit_note: opt(f, 'edit_note') },
  });
  if (error) backW(f, 'err', friendly(error.message));
  doneW(f, `Đã lưu bảng ca: kế hoạch xong sau ${summary.plan.makespan} ngày làm việc (1 ca: ${summary.base.makespan}), trễ hạn ${summary.plan.late} ngày`);
}

export async function submitWeek(f: FormData) {
  const db = await createClient();
  const { error } = await db.schema('app').rpc('roster_submit', { p_id: txt(f, 'id'), p_note: opt(f, 'note') });
  if (error) backW(f, 'err', friendly(error.message));
  doneW(f, 'Đã gửi Giám đốc duyệt bảng ca tuần. Hạn: 12:00 thứ 7.');
}

// Giám đốc duyệt: áp ca máy, ca người, gửi công nhân; rồi xếp lại lịch máy từ đầu tuần (Giám đốc xếp thì dùng ngay)
export async function reviewWeek(f: FormData) {
  const ok = txt(f, 'approve') === '1';
  const { me, db } = await khFor();
  const { error } = await db.schema('app').rpc('roster_review', { p_id: txt(f, 'id'), p_approve: ok, p_note: opt(f, 'note') });
  if (error) backW(f, 'err', friendly(error.message));
  if (!ok) doneW(f, 'Đã trả lại bảng ca, TP SX nhận thông báo.');
  let extra = '';
  try {
    const kh = await loadKh(db, { plan: opt(f, 'plan_id') ?? undefined, roles: me.roles });
    if (kh.version && kh.fromPlan && hasRole(me.roles, [...ROLE.plan, 'ADMIN'])) {
      const { credit } = await carryOver(db, kh);
      const r = rebuild(kh, kh.orders, { credit, optimize: true, fromDate: wk(f) });
      if (r.sch.slots.length) {
        const { error: e2 } = await db.schema('app').rpc('kh_save_schedule', {
          p_plan: kh.planId, ...schedulePayload(kh, kh.orders, r), p_reason: `Xếp lại theo bảng ca tuần ${wk(f).split('-').reverse().slice(0, 2).join('/')} đã duyệt`, p_change: null,
        });
        extra = e2 ? ` Chưa xếp lại được lịch máy: ${friendly(e2.message)}` : ' Lịch máy đã xếp lại theo bảng ca.';
      }
    }
  } catch (e) { extra = ` Chưa xếp lại được lịch máy: ${e instanceof Error ? e.message : String(e)}`; }
  doneW(f, `Đã duyệt bảng ca, MES đã gửi lịch ca cho công nhân, TP SX, tổ trưởng.${extra}`);
}

export async function cancelWeek(f: FormData) {
  const db = await createClient();
  const { error } = await db.schema('app').rpc('roster_cancel', { p_id: txt(f, 'id'), p_reason: txt(f, 'reason') });
  if (error) backW(f, 'err', friendly(error.message));
  doneW(f, 'Đã hủy bảng ca');
}
