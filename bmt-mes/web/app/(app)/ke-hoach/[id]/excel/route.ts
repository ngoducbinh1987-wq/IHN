// Xuất Excel kết quả MRP của kế hoạch tháng (lần chạy MRP gần nhất): cùng số liệu với trang /ke-hoach/[id]
// Trang 1 "Kết quả MRP" (khung #mrp), trang 2 "Dự trù nhiều tầng", trang 3 "Lịch sử điều chỉnh MRP" (khi có)
import { NextResponse } from 'next/server';
import { requirePage, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { XLSX_TYPE, buildXlsx, xlsxDisposition, type Sheet } from '@/lib/xlsx';

const n = (x: unknown) => (x === null || x === undefined || x === '' ? null : Number(x));
const d = (x: unknown) => (x ? new Date(String(x).length <= 10 ? `${x}T00:00:00Z` : String(x)).toLocaleDateString('vi-VN', { timeZone: String(x).length <= 10 ? 'UTC' : 'Asia/Ho_Chi_Minh' }) : '');
const dt = (x: unknown) => (x ? new Date(String(x)).toLocaleString('vi-VN', { timeZone: 'Asia/Ho_Chi_Minh' }) : '');

export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  await requirePage('ke-hoach');
  const me = await requirePerm('plan', 'view');
  const db = await createClient();
  const { data: plan } = await db.schema('app').from('v_plans').select('plan_no, period_label, last_run_id').eq('id', id).maybeSingle();
  if (!plan) return new NextResponse('Không tìm thấy kế hoạch', { status: 404 });
  if (!plan.last_run_id) return new NextResponse('Kế hoạch chưa chạy MRP', { status: 400 });
  const [mrp, levels, run, edits] = await Promise.all([
    db.schema('app').from('v_mrp_lines').select('*').eq('run_id', plan.last_run_id).order('suggest_qty', { ascending: false }).order('material_code'),
    db.schema('app').from('v_mrp_products').select('*').eq('run_id', plan.last_run_id).order('id'),
    db.schema('plan').from('mrp_runs').select('run_at').eq('id', plan.last_run_id).maybeSingle(),
    db.schema('app').from('v_mrp_edits').select('*').eq('plan_id', id).order('edited_at', { ascending: false }),
  ]);
  const err = mrp.error ?? levels.error ?? edits.error;
  if (err) return new NextResponse(`Không đọc được kết quả MRP: ${err.message}`, { status: 400 });
  const price = me.can_see_price;
  const at = run.data?.run_at ? ` · chạy lúc ${dt(run.data.run_at)}` : '';

  const head = ['Mã vật tư', 'Tên vật tư', 'ĐVT', 'Lý thuyết', 'Tổng cấp SX', 'Tồn KD', 'Chờ QC', 'Hàng về', 'Đã đề xuất', 'Dự phòng', 'Thiếu ròng',
    'Bội số', 'Đề nghị mua', 'Số gốc MES (khi đã sửa)', 'Tồn dự kiến sau SX', ...(price ? ['Thành tiền (đ)'] : []), 'Ngày cần', 'Ghi chú', 'Trạng thái'];
  const rows = (mrp.data ?? []).map((m) => [m.material_code, m.material_name, m.uom, n(m.theoretical), n(m.total_issue), n(m.available), n(m.in_quality),
    n(m.incoming), n(m.requested), n(m.reserve), n(m.net_short), n(m.pack_multiple), n(m.suggest_qty), n(m.orig_suggest_qty), n(m.projected_after),
    ...(price ? [n(m.amount)] : []), d(m.eff_need_date), m.note ?? '', m.status]);
  const sheets: Sheet[] = [{
    name: 'Kết quả MRP',
    title: `Kết quả MRP · đề nghị mua · ${plan.plan_no} – ${plan.period_label}${at}`,
    rows: [head, ...rows],
    widths: [14, 30, 7, 12, 13, 11, 11, 11, 12, 11, 12, 9, 13, 14, 14, ...(price ? [15] : []), 12, 28, 16],
  }];
  if ((levels.data ?? []).length) sheets.push({
    name: 'Dự trù nhiều tầng',
    title: `Dự trù nhiều tầng (mét cáp còn phải làm ở từng công đoạn sau khi trừ tồn) · ${plan.plan_no}${at}`,
    rows: [['Mã sản phẩm', 'Số lõi', 'Kế hoạch (m)', 'TP sẵn có', 'Đóng gói', 'Cáp CV có', 'Bọc vỏ', 'Cáp xoắn có', 'Xoắn, băng', 'Lõi có (quy cáp)',
      'Bọc cách điện', 'Ruột có (quy cáp)', 'Bện'],
      ...(levels.data ?? []).map((x) => [x.product_code, n(x.cores), n(x.qty_m), n(x.fg_m), n(x.q6), n(x.cv_m), n(x.q5), n(x.bl_m), n(x.q34), n(x.lb_m),
        n(x.q2), n(x.cb_m), n(x.q1)])],
    widths: [16, 8, 13, 12, 12, 12, 12, 12, 12, 14, 14, 14, 12],
  });
  if ((edits.data ?? []).length) sheets.push({
    name: 'Lịch sử điều chỉnh MRP',
    title: `Lịch sử điều chỉnh MRP · ${plan.plan_no}`,
    rows: [['Thời điểm', 'Người sửa', 'Mã vật tư', 'Tên vật tư', 'Số cũ', 'Số mới', 'Ngày cần cũ', 'Ngày cần mới', 'Ghi chú cũ', 'Ghi chú mới', 'Lý do', 'Lần chạy MRP'],
      ...(edits.data ?? []).map((e) => [dt(e.edited_at), e.edited_by_name, e.material_code, e.material_name, n(e.old_qty), n(e.new_qty), d(e.old_need_date),
        d(e.new_need_date), e.old_note ?? '', e.new_note ?? '', e.reason, e.run_id === plan.last_run_id ? 'Lần gần nhất' : 'Lần trước'])],
    widths: [18, 20, 14, 28, 12, 12, 12, 12, 20, 20, 30, 13],
  });
  const body = buildXlsx(sheets);
  return new NextResponse(Buffer.from(body), {
    headers: { 'Content-Type': XLSX_TYPE, 'Content-Disposition': xlsxDisposition(`MRP ${plan.plan_no}.xlsx`), 'Cache-Control': 'no-store' },
  });
}
