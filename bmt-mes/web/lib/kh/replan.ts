// Tính lại tiến độ sau ca: 1 giờ sau khi hết ca (job máy chủ, hoặc lúc TP SX / Giám đốc mở MES), MES lấy sản lượng thực tế,
// tính lại số mét còn phải làm từng lô, xếp lại lịch máy từ lúc hết ca (giữ thứ tự lô, lô đã duyệt lịch), lưu thành lịch đang dùng
// và báo Giám đốc, TP SX lô nhanh / chậm, ngày hoàn thành mới (database so và gửi: app.kh_replan_save).
import type { SupabaseClient } from '@supabase/supabase-js';
import { loadKh, rebuild, schedulePayload, vnNow } from './load';
import { type ReportRow, type SlipRow, progress } from './progress';
import { addDays } from './scheduler';

type Db = SupabaseClient;
export type Claim = { run_id: string; plan_id: string; work_date: string; shift_code: string; shift_no: number; shift_end: string; label: string };
export type ReplanOut = { plan: string; label?: string; ok: boolean; skipped?: boolean; message: string; slower?: number; faster?: number; late?: number };

async function all<T>(q: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: { message: string } | null }>): Promise<T[]> {
  const out: T[] = [];
  for (let i = 0; i < 50; i++) {
    const { data, error } = await q(i * 1000, i * 1000 + 999);
    if (error) throw new Error(error.message);
    out.push(...(data ?? []));
    if ((data ?? []).length < 1000) break;
  }
  return out;
}

export async function replanPlan(db: Db, planId: string, opts: { manual?: boolean; roles: string[] }): Promise<ReplanOut> {
  const { data: c, error: e0 } = await db.schema('app').rpc('replan_claim', { p_plan: planId, p_manual: Boolean(opts.manual) });
  if (e0) return { plan: planId, ok: false, message: e0.message };
  const claim = c as Claim | null;
  if (!claim) return { plan: planId, ok: true, skipped: true, message: 'Chưa đến lượt tính lại' };
  try {
    const kh = await loadKh(db, { plan: planId, roles: opts.roles });
    if (kh.planId !== planId || !kh.sch || !kh.version) throw new Error('Kế hoạch chưa có lịch đang dùng');
    const from = kh.cal.days[0] ?? claim.work_date, to = addDays(claim.work_date, 1);
    // sản lượng thực tế: phiếu hoàn thành bobin (Kế toán SX nhập từ phiếu giấy), báo cáo ca
    const slipRows = await all<{ wo_no: string; op_code: string; machine_code: string; qty_m: number; ended_at: string | null; recorded_at: string; work_date: string }>((a, b) =>
      db.schema('app').from('v_bobbin_slips').select('wo_no, op_code, machine_code, qty_m, ended_at, recorded_at, work_date')
        .eq('status', 'ACTIVE').gte('work_date', from).lte('work_date', to).order('recorded_at').range(a, b));
    const lineIds = kh.orders.map((o) => o.id);
    const wos = lineIds.length ? await all<{ wo_no: string; plan_line_id: string | null }>((a, b) =>
      db.schema('mfg').from('work_orders').select('wo_no, plan_line_id').in('plan_line_id', lineIds).order('wo_no').range(a, b)) : [];
    const lineOf = new Map(wos.filter((w) => w.plan_line_id).map((w) => [w.wo_no, w.plan_line_id as string]));
    const slips: SlipRow[] = slipRows.filter((x) => lineOf.has(x.wo_no) && x.machine_code).map((x) => ({
      line: lineOf.get(x.wo_no)!, op: x.op_code, machine: x.machine_code, m: Number(x.qty_m) || 0,
      at: x.ended_at ? vnNow(new Date(x.ended_at)) : vnNow(new Date(x.recorded_at)),
    }));
    const reps = await all<{ work_date: string; shift_code: string; machine_code: string; status: string; lines: { key?: string; declared_m?: number; plc_m?: number }[] }>((a, b) =>
      db.schema('app').from('v_kh_reports').select('work_date, shift_code, machine_code, status, lines')
        .in('status', ['SUBMITTED', 'CONFIRMED']).gte('work_date', from).lte('work_date', to).order('work_date').range(a, b));
    const reports: ReportRow[] = reps.map((r) => ({ date: r.work_date, code: r.shift_code, machine: r.machine_code,
      lines: (r.lines ?? []).map((l) => ({ key: l.key, m: Number(l.declared_m ?? l.plc_m ?? 0) })) }));
    const cut = { date: claim.work_date, code: claim.shift_code };
    const pg = progress({ cal: kh.cal, sch: kh.sch, cfg: kh.cfg, orders: kh.orders, machines: kh.machines }, cut, slips, reports);
    const r = rebuild(kh, kh.orders, { credit: pg.credit, cut });
    const p = schedulePayload(kh, kh.orders, r);
    const label = new Map(kh.orders.map((o) => [o.id, `${o.label} ${o.product_code}`]));
    const result = {
      shift: claim.label, manual: Boolean(opts.manual), machines: pg.machines, missing: pg.missing,
      short: pg.short.map((x) => ({ ...x, lot: label.get(x.line) ?? x.line })), slips: slips.length,
    };
    const { data: saved, error } = await db.schema('app').rpc('kh_replan_save', {
      p_run: claim.run_id, p_base: p.p_base, p_params: p.p_params, p_orders: p.p_orders, p_slots: p.p_slots, p_result: result,
    });
    if (error) throw new Error(error.message);
    const s = saved as { slower: number; faster: number; late: number; version: number };
    return { plan: planId, label: claim.label, ok: true, message: `Đã tính lại sau ${claim.label}: lịch bản ${s.version}`, slower: s.slower, faster: s.faster, late: s.late };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    await db.schema('app').rpc('replan_fail', { p_run: claim.run_id, p_error: msg });
    return { plan: planId, label: claim.label, ok: false, message: msg };
  }
}

// Mọi kế hoạch đến lượt tính lại (đã hết ca ít nhất 1 giờ, chưa tính)
export async function replanDue(db: Db, roles: string[]): Promise<ReplanOut[]> {
  const { data, error } = await db.schema('app').rpc('replan_due');
  if (error || !Array.isArray(data)) return [];
  const out: ReplanOut[] = [];
  for (const id of data as string[]) out.push(await replanPlan(db, id, { roles }));
  return out;
}
