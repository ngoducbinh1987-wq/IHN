'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { type ChangeInput, type ProductRow, readChange, simulate, stepsFor } from '@/lib/kh/change';
import { type Kh, ROLE, carryOver, hasRole, loadKh, metaOf, rebuild } from '@/lib/kh/load';
import type { Order } from '@/lib/kh/scheduler';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

const go = (q: string, kind: 'ok' | 'err', msg: string): never => redirect(`/lich-may?${q}${q ? '&' : ''}${kind}=${encodeURIComponent(msg)}`);
const r3 = (v: number) => Math.round(v * 1000) / 1000;

// Gói lịch để lưu thành phiên bản mới
function payload(kh: Kh, orders: Order[], r: ReturnType<typeof rebuild>) {
  return {
    p_base: r.cal.base,
    p_params: {
      S: r.cal.S, SPD: r.cal.SPD, RUN: r.cal.RUN, fill_pct: kh.cfg.fill_pct, frozen_days: kh.cfg.frozen_days,
      machines_per_operator: kh.cfg.machines_per_operator, plan_no: kh.planNo, workdays: r.cal.wd,
      shifts: r.cal.shifts.map((s) => ({ code: s.code, start_time: s.start_time, end_time: s.end_time, break_min: s.break_min })),
    },
    p_orders: orders.map((o) => ({
      plan_line_id: o.id, label: o.label, product_code: o.product_code, product_name: o.product_name, group_code: o.group, qty_m: o.qty,
      due_date: o.due, priority: o.prio, source: o.source, finish_date: r.fin.get(o.id)?.finDate ?? null, meta: metaOf(o),
    })),
    p_slots: r.sch.slots.map((s) => ({
      plan_line_id: s.lineId, op_code: s.op, color: s.color, machine_code: s.machine, operator_code: s.operator, lane: s.lane,
      start_min: r3(s.start), run_start_min: r3(s.runStart), end_min: r3(s.end), setup_min: r3(s.setup), meters: r3(s.meters),
      rate: r3(s.rate), speed: r3(s.speed), reason: s.reason, setup_why: s.why, part: s.part,
    })),
  };
}

// Số lệnh đã có trong lịch cũ bị đổi ngày xong (không tính lệnh mới thêm)
const moved = (kh: Kh, r: ReturnType<typeof rebuild>) => kh.orders.filter((o) => kh.fin.has(o.id) && kh.fin.get(o.id)!.placed && (kh.fin.get(o.id)!.finDate ?? null) !== (r.fin.get(o.id)?.finDate ?? null)).length;

export async function rebuildSchedule(form: FormData) {
  const planId = String(form.get('plan_id'));
  const q = `plan=${planId}&tab=${String(form.get('tab') ?? 'lich')}`;
  const me = await requireMe();
  if (!hasRole(me.roles, ROLE.plan)) go(q, 'err', 'Chỉ Quản lý SX hoặc Giám đốc được xếp lịch máy');
  const db = await createClient();
  const kh = await loadKh(db, { plan: planId, roles: me.roles });
  if (!kh.fromPlan) go(q, 'err', 'Kế hoạch chưa có dòng nào xếp được (cần mã có spec đã phát hành, có công đoạn và số mét > 0)');
  const { credit, missingReports } = await carryOver(db, kh);
  const r = rebuild(kh, kh.orders, { credit });
  if (!r.sch.slots.length) go(q, 'err', 'Không xếp được việc nào: kiểm tra người đứng máy và tay nghề');
  const reason = kh.version ? (kh.dirty ? 'Xếp lại lịch theo tham số mới' : 'Xếp lại lịch theo báo cáo ca và kế hoạch') : 'Xếp lịch lần đầu';
  const { error } = await db.schema('app').rpc('kh_save_schedule', { p_plan: planId, ...payload(kh, kh.orders, r), p_reason: reason, p_change: null });
  if (error) go(q, 'err', error.message);
  revalidatePath('/lich-may');
  const n = kh.version ? moved(kh, r) : 0;
  go(q, 'ok', kh.version
    ? `Đã xếp lại lịch · ${n} lệnh đổi ngày xong · phần đã chạy và vùng khóa ${kh.cfg.frozen_days} ngày giữ nguyên${missingReports ? ` · ${missingReports} ca-máy đã qua chưa có báo cáo ca xác nhận (coi như đạt kế hoạch)` : ''}`
    : `Đã xếp lịch máy từ ${kh.planNo}. Phiên bản 1.`);
}

export async function setLine(form: FormData) {
  const planId = String(form.get('plan_id'));
  const q = `plan=${planId}&tab=thang`;
  const due = String(form.get('due') ?? '');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(due)) go(q, 'err', 'Chọn hạn giao');
  const db = await createClient();
  const { error } = await db.schema('app').rpc('kh_set_line', { p_line: String(form.get('line_id')), p_due: due, p_priority: Number(form.get('prio') ?? 1) });
  if (error) go(q, 'err', error.message);
  revalidatePath('/lich-may');
  go(q, 'ok', `Đã lưu hạn giao ${String(form.get('label'))}. Bấm Xếp lại lịch để tính lại ngày xong.`);
}

export async function setStart(form: FormData) {
  const planId = String(form.get('plan_id'));
  const q = `plan=${planId}&tab=thang`;
  const db = await createClient();
  const { error } = await db.schema('app').rpc('kh_set_sched_start', { p_plan: planId, p_date: String(form.get('start')) });
  if (error) go(q, 'err', error.message);
  revalidatePath('/lich-may');
  go(q, 'ok', 'Đã đặt ngày bắt đầu chạy kế hoạch');
}

export async function createChange(form: FormData) {
  const planId = String(form.get('plan_id'));
  const sp = Object.fromEntries(['sp', 'qty', 'due', 'so', 'prio', 'br'].map((k) => [k, form.get(k) ? String(form.get(k)) : undefined]));
  const q = `plan=${planId}&tab=phatsinh`;
  const me = await requireMe();
  if (!hasRole(me.roles, ROLE.release)) go(q, 'err', 'Chỉ Quản lý SX lập đề nghị đơn phát sinh');
  const input = readChange(sp);
  if (typeof input === 'string') go(q, 'err', input);
  const inp = input as ChangeInput;
  const db = await createClient();
  const kh = await loadKh(db, { plan: planId, roles: me.roles });
  if (!kh.version) go(q, 'err', 'Chưa có lịch máy: xếp lịch trước khi nhận đơn phát sinh');
  const { data: prod } = await db.schema('app').from('v_kh_products').select('*').eq('product_code', inp.product_code).maybeSingle<ProductRow>();
  if (!prod) go(q, 'err', 'Mã sản phẩm chưa có spec đã phát hành');
  const sim = simulate(kh, prod!, inp);
  const { error } = await db.schema('app').rpc('kh_create_change', {
    p_plan: planId,
    p_payload: { product_code: inp.product_code, product_name: prod!.product_name, qty_m: inp.qty, due_date: inp.due, so: inp.so, priority: String(inp.prio), br: inp.br },
    p_result: { finish: sim.n.finDate, slack: sim.n.slack, placed: sim.n.placed, rows: sim.rows, newly: sim.newly, notify: sim.notify, touched: sim.touched },
    p_level: sim.level, p_steps: stepsFor(sim.level),
  });
  if (error) go(q, 'err', error.message);
  revalidatePath('/lich-may');
  go(q, 'ok', sim.level === 'A' ? 'Đã lập đề nghị mức A. Bấm Áp dụng để đưa vào lịch.' : `Đã gửi đề nghị mức ${sim.level}. Người duyệt đã nhận thông báo.`);
}

async function step(form: FormData, action: 'approve' | 'return') {
  const planId = String(form.get('plan_id'));
  const q = `plan=${planId}&tab=phatsinh`;
  const db = await createClient();
  const { data, error } = await db.schema('app').rpc('kh_change_step', { p_req: String(form.get('id')), p_action: action, p_comment: String(form.get('comment') ?? '') });
  if (error) go(q, 'err', error.message);
  revalidatePath('/lich-may');
  go(q, 'ok', action === 'return' ? 'Đã trả lại đề nghị. Người lập đã nhận thông báo.' : data === 'READY' ? 'Đã duyệt bước cuối. Bấm Áp dụng để đưa vào lịch.' : 'Đã duyệt, chuyển bước tiếp theo');
}
export async function changeStep(form: FormData) { await step(form, 'approve'); }
export async function returnChange(form: FormData) { await step(form, 'return'); }

export async function applyChange(form: FormData) {
  const planId = String(form.get('plan_id'));
  const id = String(form.get('id'));
  const q = `plan=${planId}&tab=phatsinh`;
  const me = await requireMe();
  const db = await createClient();
  const { data: req } = await db.schema('app').from('v_kh_changes').select('*').eq('id', id).single();
  if (!req) go(q, 'err', 'Không tìm thấy đề nghị');
  if (!['READY', 'LINE_ADDED'].includes(req.status)) go(q, 'err', 'Đề nghị chưa đủ bước duyệt');
  if (req.status === 'READY') {
    const { error } = await db.schema('app').rpc('kh_change_add_line', { p_req: id });
    if (error) go(q, 'err', error.message);
  }
  if (!hasRole(me.roles, ROLE.plan)) go(q, 'ok', 'Đã thêm dòng vào kế hoạch tháng. Quản lý SX bấm Áp dụng để xếp lại lịch.');
  const kh = await loadKh(db, { plan: planId, roles: me.roles });
  const { credit } = await carryOver(db, kh);
  const r = rebuild(kh, kh.orders, { split: Boolean(req.payload?.br), credit });
  const { error } = await db.schema('app').rpc('kh_save_schedule', {
    p_plan: planId, ...payload(kh, kh.orders, r), p_reason: `Chèn đơn phát sinh ${req.req_no} (mức ${req.level})`, p_change: id,
  });
  if (error) go(q, 'err', error.message);
  revalidatePath('/lich-may');
  revalidatePath('/lenh-ngay');
  go(q, 'ok', `Đã áp dụng lịch mới · ${moved(kh, r)} lệnh đổi ngày xong${req.payload?.br ? ' · lệnh ngày đã phát trong vùng khóa cần phát lại bản mới' : ''}`);
}
