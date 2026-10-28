'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { type ChangeInput, type ProductRow, readChange, simulate, stepsFor } from '@/lib/kh/change';
import { type Kh, ROLE, carryOver, flowSig, hasRole, loadKh, metaOf, rebuild, speedSig } from '@/lib/kh/load';
import { parseNum } from '@/lib/format';
import { flowOf } from '@/lib/kh/scheduler';
import type { Order } from '@/lib/kh/scheduler';
import { groupName } from '@/lib/kh/optimize';
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
      group_days: kh.cfg.group_days ?? 0, speeds_sig: speedSig(kh.cfg), flow_sig: flowSig(kh.cfg), flow: flowOf(kh.cfg),
      // thứ tự lô (bộ tối ưu chọn): xếp lại sau giữ thứ tự này, lô mới chen theo hạn giao
      seq: Object.fromEntries(r.orders.filter((o) => o.seq != null).map((o) => [o.id, o.seq!])),
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
const dm = (d: string | null | undefined) => (d ? `${d.slice(8, 10)}/${d.slice(5, 7)}` : 'chưa xếp');
// Lô bị lùi ngày xong và lô mới trễ hạn giao sau khi xếp lại
function pushedLots(kh: Kh, r: ReturnType<typeof rebuild>) {
  const pushed: string[] = [], late: string[] = [];
  for (const o of kh.orders) {
    const a = kh.fin.get(o.id), b = r.fin.get(o.id);
    if (!a?.placed || !a.finDate) continue;
    if (!b?.finDate || b.finDate > a.finDate) pushed.push(`${o.label} ${o.product_code} ${dm(a.finDate)} → ${dm(b?.finDate)}`);
    if ((b?.slack ?? 0) < 0 && !((a.slack ?? 0) < 0)) late.push(`${o.label} ${o.product_code} xong ${dm(b?.finDate)}, hạn ${dm(o.due)}`);
  }
  return { pushed, late };
}

export async function rebuildSchedule(form: FormData) {
  const planId = String(form.get('plan_id'));
  const q = `plan=${planId}&tab=${String(form.get('tab') ?? 'lich')}`;
  const me = await requireMe();
  if (!hasRole(me.roles, ROLE.plan)) go(q, 'err', 'Chỉ Quản lý SX hoặc Giám đốc được xếp lịch máy');
  const db = await createClient();
  const kh = await loadKh(db, { plan: planId, roles: me.roles });
  if (!kh.fromPlan) go(q, 'err', 'Kế hoạch chưa có dòng nào xếp được (cần mã có spec đã phát hành, có công đoạn và số mét > 0)');
  const { credit, missingReports } = await carryOver(db, kh);
  // Xếp lịch = chạy bộ tối ưu (đổi thứ tự lô để ít trễ hạn, xong sớm, ít đổi máy; tăng ca chỉ dùng phần Giám đốc đã duyệt)
  const r = rebuild(kh, kh.orders, { credit, optimize: true });
  if (!r.sch.slots.length) go(q, 'err', ['Không xếp được việc nào: kiểm tra người đứng máy và tay nghề', ...(r.sch.warnings ?? [])].join(' · '));
  const seqTxt = [...r.orders].sort((a, b) => (a.seq ?? 0) - (b.seq ?? 0)).map((o) => o.label).join(' → ');
  const before = [...kh.orders].sort((a, b) => (a.seq ?? 0) - (b.seq ?? 0) || (a.due ?? '').localeCompare(b.due ?? '')).map((o) => o.label).join(' → ');
  const extra = [
    seqTxt !== before ? `MES chọn thứ tự lô ${seqTxt}` : '',
    r.best?.bottleneck[0] ? `máy cổ chai: ${groupName(r.best.bottleneck[0].group)} (${Math.round(r.best.bottleneck[0].util * 100)} %)` : '',
    ...(r.sch.warnings ?? []).slice(0, 3),
    r.sch.unplaced.length ? `${r.sch.unplaced.length} việc chưa xếp được` : '',
  ].filter(Boolean);
  const down = r.windows.filter((w) => w.kind !== 'PM').map((w) => w.label);
  const reason = kh.version
    ? (down.length ? `Xếp lại lịch: ${down.join('; ')}` : kh.dirty ? 'Xếp lại lịch theo tham số mới' : 'Xếp lại lịch theo báo cáo ca và kế hoạch')
    : 'Xếp lịch lần đầu';
  const { data: verId, error } = await db.schema('app').rpc('kh_save_schedule', { p_plan: planId, ...payload(kh, kh.orders, r), p_reason: reason.slice(0, 300), p_change: null });
  if (error) go(q, 'err', error.message);
  const { data: saved } = await db.schema('app').from('v_kh_versions').select('version, status').eq('id', verId as string).single();
  revalidatePath('/lich-may');
  revalidatePath('/lenh-ngay');
  // TP SX xếp: bản đề xuất chờ Giám đốc duyệt; Giám đốc xếp: dùng ngay
  const sent = saved?.status === 'PROPOSED' ? `Đã gửi Giám đốc duyệt lịch bản ${saved.version} (lịch đang dùng giữ nguyên đến khi duyệt)` : '';
  if (!kh.version) go(q, 'ok', [sent || `Đã xếp lịch máy từ ${kh.planNo}. Phiên bản ${saved?.version ?? 1}.`, ...extra].join(' · '));
  const { pushed, late } = pushedLots(kh, r);
  // Lô trễ hạn giao do xếp lại (máy hỏng, bảo dưỡng…): cảnh báo đỏ Giám đốc
  if (late.length) await db.schema('app').rpc('kh_late_alert', { p_plan: planId, p_reason: reason, p_lines: late });
  go(q, 'ok', [
    sent || 'Đã xếp lại lịch',
    `${moved(kh, r)} lệnh đổi ngày xong`,
    r.early ? 'máy không chạy được trong vùng khóa: xếp lại từ ngày mai, lệnh ngày đã phát cần phát lại bản mới' : `phần đã chạy và vùng khóa ${kh.cfg.frozen_days} ngày giữ nguyên`,
    pushed.length ? `Lô bị lùi: ${pushed.join('; ')}` : '',
    late.length ? `Đã cảnh báo đỏ Giám đốc: ${late.length} lô trễ hạn giao` : '',
    missingReports ? `${missingReports} ca-máy đã qua chưa có báo cáo ca xác nhận (coi như đạt kế hoạch)` : '',
    ...extra,
  ].filter(Boolean).join(' · '));
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
  go(q, 'ok', `Đã gửi đề nghị mức ${sim.level}: ${sim.level === 'C' ? 'TP KT/QA cho ý kiến, sau đó ' : ''}Giám đốc duyệt. Người duyệt đã nhận thông báo.`);
}

// Người đang duyệt sửa số mét / hạn giao / ưu tiên của đơn phát sinh: chạy lại mô phỏng rồi lưu (database kiểm mức, ghi lịch sử, báo người lập)
export async function editChange(form: FormData) {
  const planId = String(form.get('plan_id'));
  const id = String(form.get('id'));
  const q = `plan=${planId}&tab=phatsinh`;
  const me = await requireMe();
  const db = await createClient();
  const { data: req } = await db.schema('app').from('v_kh_changes').select('*').eq('id', id).single();
  if (!req) go(q, 'err', 'Không tìm thấy đề nghị');
  const p = req.payload as Record<string, unknown>;
  const input = readChange({ sp: String(p.product_code), qty: String(form.get('qty') ?? ''), due: String(form.get('due') ?? ''), so: String(form.get('so') ?? p.so ?? ''),
    prio: String(form.get('prio') ?? p.priority ?? '1'), br: p.br ? '1' : undefined });
  if (typeof input === 'string') go(q, 'err', input);
  const inp = input as ChangeInput;
  const kh = await loadKh(db, { plan: planId, roles: me.roles });
  const { data: prod } = await db.schema('app').from('v_kh_products').select('*').eq('product_code', inp.product_code).maybeSingle<ProductRow>();
  if (!prod) go(q, 'err', 'Mã sản phẩm chưa có spec đã phát hành');
  const sim = simulate(kh, prod!, inp);
  const { error } = await db.schema('app').rpc('kh_change_edit', {
    p_req: id,
    p_payload: { product_code: inp.product_code, product_name: prod!.product_name, qty_m: inp.qty, due_date: inp.due, so: inp.so, priority: String(inp.prio), br: inp.br },
    p_result: { finish: sim.n.finDate, slack: sim.n.slack, placed: sim.n.placed, rows: sim.rows, newly: sim.newly, notify: sim.notify, touched: sim.touched },
    p_reason: String(form.get('reason') ?? ''),
  });
  if (error) go(q, 'err', error.message);
  revalidatePath('/lich-may');
  go(q, 'ok', `Đã sửa đề nghị (mô phỏng lại: xong ${sim.n.finDate ? sim.n.finDate.split('-').reverse().slice(0, 2).join('/') : 'chưa xếp được'}). Kiểm tra rồi bấm Đồng ý.`);
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

// TP SX chốt ngày hoàn thành của lô. Sớm hơn ngày MES dự kiến: mô phỏng xếp lại với ngày chốt, báo không kịp
// hoặc liệt kê lô bị lùi và bắt buộc tích xác nhận (ghi vào ghi chú gửi Giám đốc).
export async function commitLot(form: FormData) {
  const planId = String(form.get('plan_id'));
  const q = `plan=${planId}&tab=thang`;
  const me = await requireMe();
  if (!hasRole(me.roles, ['SX_TP', 'SX_KH', 'ADMIN'])) go(q, 'err', 'Chỉ TP SX chốt ngày hoàn thành của lô');
  const lineId = String(form.get('line_id'));
  const date = String(form.get('date') ?? '');
  let note = String(form.get('note') ?? '').trim();
  const db = await createClient();
  if (date && !/^\d{4}-\d{2}-\d{2}$/.test(date)) go(q, 'err', 'Chọn ngày chốt');
  if (date) {
    const kh = await loadKh(db, { plan: planId, roles: me.roles });
    const o = kh.orders.find((x) => x.id === lineId);
    const eta = kh.fin.get(lineId)?.finDate ?? null;
    if (o && kh.version && eta && date < eta) {
      const orders = kh.orders.map((x) => (x.id === lineId ? { ...x, commit: date } : x));
      const r = rebuild(kh, orders);
      const now = r.fin.get(lineId);
      if (!now?.placed || !now.finDate || now.finDate > date) {
        go(q, 'err', `${o.label} ${o.product_code}: không đủ máy để xong ${date.split('-').reverse().slice(0, 2).join('/')}; ưu tiên lô này thì xong sớm nhất ${now?.finDate ? now.finDate.split('-').reverse().slice(0, 2).join('/') : 'không xếp được'}. Chọn ngày muộn hơn hoặc Giám đốc bật thêm ca.`);
      }
      const pushed = kh.orders.filter((x) => x.id !== lineId && kh.fin.get(x.id)?.finDate && (r.fin.get(x.id)?.finDate ?? '9999') > kh.fin.get(x.id)!.finDate!)
        .map((x) => `${x.label} ${x.product_code} ${kh.fin.get(x.id)!.finDate!.slice(8, 10)}/${kh.fin.get(x.id)!.finDate!.slice(5, 7)} → ${r.fin.get(x.id)?.finDate ? `${r.fin.get(x.id)!.finDate!.slice(8, 10)}/${r.fin.get(x.id)!.finDate!.slice(5, 7)}` : 'chưa xếp'}`);
      if (pushed.length && form.get('accept') !== '1') {
        go(q, 'err', `Chốt ${o.label} sớm hơn dự kiến làm lùi: ${pushed.join('; ')}. Tích "Đồng ý lùi các lô này" rồi chốt lại.`);
      }
      note = [note, pushed.length ? `Lùi: ${pushed.join('; ')}` : 'Không lô nào bị lùi'].filter(Boolean).join(' · ');
    }
  }
  const { error } = await db.schema('app').rpc('kh_commit_lot', { p_line: lineId, p_date: date || null, p_note: note || null });
  if (error) go(q, 'err', error.message);
  revalidatePath('/lich-may');
  go(q, 'ok', date ? `Đã đệ trình ngày hoàn thành, Giám đốc nhận thông báo duyệt lịch lô. Ngày chốt sớm hơn MES dự kiến thì bấm Xếp lại lịch (Giám đốc duyệt lịch máy) trước.` : 'Đã bỏ ngày chốt');
}

// TP SX đệ trình một lần mọi lô chưa chốt theo ngày MES dự kiến
export async function commitLots(form: FormData) {
  const planId = String(form.get('plan_id'));
  const q = `plan=${planId}&tab=thang`;
  const db = await createClient();
  const { data, error } = await db.schema('app').rpc('kh_commit_lots', { p_plan: planId });
  if (error) go(q, 'err', error.message);
  revalidatePath('/lich-may');
  go(q, 'ok', `Đã đệ trình ${data} lô theo ngày MES dự kiến. Giám đốc nhận thông báo duyệt lịch lô.`);
}

// Giám đốc duyệt mọi lô TP SX đã đệ trình
export async function approveLots(form: FormData) {
  const planId = String(form.get('plan_id'));
  const q = `plan=${planId}&tab=thang`;
  const db = await createClient();
  const { data, error } = await db.schema('app').rpc('kh_approve_lots', { p_plan: planId });
  if (error) go(q, 'err', error.message);
  const r = data as { ok: number; fail: { code: string; msg: string }[] };
  revalidatePath('/lich-may');
  if (r.fail.length) go(q, r.ok ? 'ok' : 'err', `Đã duyệt ${r.ok} lô. Chưa duyệt được: ${r.fail.map((x) => `${x.code} (${x.msg})`).join('; ')}`);
  go(q, 'ok', `Đã duyệt ${r.ok} lô: giữ chỗ trên lịch máy, xếp lại lịch không dời các lô này.`);
}

// Giám đốc duyệt / trả lại bản lịch máy TP SX xếp
export async function reviewSchedule(form: FormData) {
  const planId = String(form.get('plan_id'));
  const ok = form.get('approve') === '1';
  const q = `plan=${planId}&tab=${String(form.get('tab') ?? 'lich')}`;
  const db = await createClient();
  const { error } = await db.schema('app').rpc('kh_schedule_review', {
    p_version: String(form.get('version_id')), p_approve: ok, p_note: String(form.get('note') ?? '').trim() || null,
  });
  if (error) go(q, 'err', error.message);
  revalidatePath('/lich-may');
  revalidatePath('/lenh-ngay');
  go(q, 'ok', ok ? 'Đã duyệt lịch máy: bản mới là lịch đang dùng, TP SX phát lệnh SX ngày theo lịch này.' : 'Đã trả lại lịch máy, TP SX nhận thông báo.');
}

// Giám đốc duyệt lịch lô (giữ chỗ trên lịch máy) hoặc bỏ giữ chỗ
export async function approveLot(form: FormData) {
  const planId = String(form.get('plan_id'));
  const q = `plan=${planId}&tab=thang`;
  const db = await createClient();
  const ok = form.get('approve') === '1';
  const date = String(form.get('date') ?? '');
  if (date && !/^\d{4}-\d{2}-\d{2}$/.test(date)) go(q, 'err', 'Chọn ngày chốt');
  // Giám đốc duyệt (được sửa ngày chốt, bắt buộc ghi chú khi sửa)
  const { error } = await db.schema('app').rpc('kh_approve_lot', {
    p_line: String(form.get('line_id')), p_approve: ok, p_date: date || null, p_note: String(form.get('note') ?? '').trim() || null,
  });
  if (error) go(q, 'err', error.message);
  revalidatePath('/lich-may');
  go(q, 'ok', ok ? 'Đã duyệt lịch lô: giữ chỗ trên lịch máy, xếp lại lịch không dời lô này. TP SX phát lệnh SX ngày theo lịch.' : 'Đã bỏ giữ chỗ lịch lô');
}

// Bảo dưỡng trên lịch máy: TP KT/QA đề xuất ngày + cách làm; TP SX chốt (vùng khóa: Giám đốc) hoặc trả lại
export async function proposeMaint(form: FormData) {
  const q = `plan=${String(form.get('plan_id') ?? '')}&tab=baoduong`;
  const date = String(form.get('date') ?? '');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) go(q, 'err', 'Chọn ngày bảo dưỡng');
  const db = await createClient();
  const { error } = await db.schema('app').rpc('maint_propose', {
    p_plan: form.get('maint_plan') ? String(form.get('maint_plan')) : null, p_wo: form.get('wo') ? String(form.get('wo')) : null,
    p_date: date, p_mode: String(form.get('mode') ?? ''), p_note: String(form.get('note') ?? '') || null,
  });
  if (error) go(q, 'err', error.message);
  revalidatePath('/lich-may');
  go(q, 'ok', 'Đã đề xuất ngày bảo dưỡng. TP SX (trong vùng khóa lịch: Giám đốc) đã nhận thông báo để chốt.');
}

export async function confirmMaint(form: FormData) {
  const q = `plan=${String(form.get('plan_id') ?? '')}&tab=baoduong`;
  const ok = form.get('ok') === '1';
  const db = await createClient();
  const { error } = await db.schema('app').rpc('maint_confirm', { p_wo: String(form.get('wo')), p_ok: ok, p_note: String(form.get('note') ?? '') || null });
  if (error) go(q, 'err', error.message);
  revalidatePath('/lich-may');
  revalidatePath('/lenh-ngay');
  go(q, 'ok', ok ? 'Đã chốt ngày bảo dưỡng. Bảo dưỡng trong ca thành khối giữ chỗ khi bấm Xếp lại lịch.' : 'Đã trả lại TP KT/QA chọn ngày khác');
}

// ---------------- Tăng ca / trộn sớm: TP SX đề xuất theo MES → Giám đốc duyệt (Giám đốc tự đề xuất thì áp ngay) ----------------
export async function proposeOvertime(form: FormData) {
  const planId = String(form.get('plan_id') ?? '');
  const q = `plan=${planId}&tab=toiuu`;
  const from = String(form.get('date_from') ?? ''), to = String(form.get('date_to') ?? '');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(from) || !/^\d{4}-\d{2}-\d{2}$/.test(to)) go(q, 'err', 'Chọn khoảng ngày tăng ca');
  const extra: Record<string, number> = {};
  for (const [k, v] of form.entries()) {
    if (!k.startsWith('ot_') || typeof v !== 'string' || v.trim() === '') continue;
    const n = parseNum(v);
    if (n === null || Number.isNaN(n) || n < 0) go(q, 'err', `Số phút tăng ca máy ${k.slice(3)} không hợp lệ`);
    if (n! > 0) extra[k.slice(3)] = Math.round(n!);
  }
  const early = parseNum(String(form.get('mix_early_h') ?? '') || '0');
  if (early === null || Number.isNaN(early) || early < 0) go(q, 'err', 'Số giờ trộn sớm không hợp lệ');
  let summary: unknown = {};
  try { summary = JSON.parse(String(form.get('summary') ?? '{}')); } catch { summary = {}; }
  const db = await createClient();
  const { error } = await db.schema('app').rpc('kh_ot_propose', {
    p_plan: planId || null,
    p: { extra_min: extra, mix_early_h: early, date_from: from, date_to: to, reason: String(form.get('reason') ?? '').trim(), summary },
  });
  if (error) go(q, 'err', error.message);
  revalidatePath('/lich-may');
  const { data: c } = await db.schema('app').from('v_kh_config').select('ot_request_id').single();
  const { data: last } = await db.schema('app').from('v_kh_overtime').select('id, req_no, status').order('proposed_at', { ascending: false }).limit(1).single();
  go(q, 'ok', last?.status === 'APPROVED' && c?.ot_request_id === last.id
    ? `Đã áp dụng tăng ca ${last.req_no}. Bấm Xếp lại lịch để tính lại.`
    : `Đã gửi Giám đốc duyệt đề xuất tăng ca ${last?.req_no ?? ''}. Cần người lao động đồng ý làm thêm giờ.`);
}

export async function reviewOvertime(form: FormData) {
  const planId = String(form.get('plan_id') ?? '');
  const q = `plan=${planId}&tab=toiuu`;
  const ok = form.get('approve') === '1';
  const db = await createClient();
  const { error } = await db.schema('app').rpc('kh_ot_review', { p_req: String(form.get('id')), p_approve: ok, p_note: String(form.get('note') ?? '').trim() || null });
  if (error) go(q, 'err', error.message);
  revalidatePath('/lich-may');
  go(q, 'ok', ok ? 'Đã duyệt tăng ca. TP SX bấm Xếp lại lịch để áp dụng (bản xếp của Giám đốc dùng ngay).' : 'Đã trả lại đề xuất tăng ca, TP SX nhận thông báo.');
}

export async function endOvertime(form: FormData) {
  const planId = String(form.get('plan_id') ?? '');
  const q = `plan=${planId}&tab=toiuu`;
  const db = await createClient();
  const { error } = await db.schema('app').rpc('kh_ot_end', { p_req: String(form.get('id')), p_note: String(form.get('note') ?? '').trim() });
  if (error) go(q, 'err', error.message);
  revalidatePath('/lich-may');
  go(q, 'ok', 'Đã kết thúc tăng ca. Bấm Xếp lại lịch để tính lại.');
}
