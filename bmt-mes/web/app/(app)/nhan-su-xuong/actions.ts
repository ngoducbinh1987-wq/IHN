'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';

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
  done(f, txt(f, 'code') ? `Đã lưu ${String(data)}` : `Đã thêm ${String(data)}. Giao máy ở bảng Người × máy (TP KT/QA ký tay nghề).`);
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
