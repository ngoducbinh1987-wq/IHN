// Xuất Excel bảng MRP hiệu chỉnh của đề xuất hiệu chỉnh kế hoạch tháng (cùng số liệu với khung #mrp-hieu-chinh: app.adj_mrp)
import { NextResponse } from 'next/server';
import { requirePage, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { XLSX_TYPE, buildXlsx, xlsxDisposition } from '@/lib/xlsx';

type MrpRow = { code: string; name: string; uom: string; old_need: number; new_need: number; delta: number; available: number; incoming: number; approved: number;
  pending_before: number; pending_after: number; buy_more: number; projected_after: number; action: string };
type TblRow = { code: string; name: string; uom: string; mrp_old: number; mrp_new: number; diff: number; available: number | null; incoming: number | null;
  requested: number | null; reserve: number | null; shortage: number | null; suggest: number; projected_after: number | null };
type Cut = { doc_type?: string; pr_no: string; status: string; material_code: string; uom: string; old: number; new: number };

const ACTION: Record<string, string> = {
  BUY: 'Mua thêm', CUT: 'Giảm đề xuất chưa duyệt', PACK: 'Giữ (dư chưa đủ một bội số đóng gói)',
  KEEP: 'Giữ nguyên: đã duyệt mua', LESS: 'Giảm nhu cầu', ENOUGH: 'Đủ, không mua thêm', SAME: 'Không đổi',
};
const ST: Record<string, string> = { DRAFT: 'Nháp', PENDING_APPROVAL: 'Đang duyệt', APPROVED: 'Đã duyệt', CANCELLED: 'Đã hủy' };
const n = (x: unknown) => (x === null || x === undefined || x === '' ? null : Number(x));

export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  await requirePage('dieu-chinh');
  await requirePerm('plan', 'view');
  const db = await createClient();
  const { data: a } = await db.schema('app').from('v_plan_adjustments').select('adj_no, plan_no, status, reason').eq('id', id).maybeSingle();
  if (!a) return new NextResponse('Không tìm thấy đề xuất hiệu chỉnh', { status: 404 });
  const { data, error } = await db.schema('app').rpc('adj_mrp', { p_adj: id });
  if (error) return new NextResponse(`Không tính được bảng MRP: ${error.message}`, { status: 400 });
  const rv = (data ?? {}) as { rows?: MrpRow[]; table?: TblRow[]; reductions?: Cut[]; applied?: boolean; at?: string; error?: string };
  if (rv.error) return new NextResponse(`Chưa tính được bảng MRP: ${rv.error}`, { status: 400 });

  const act = new Map((rv.rows ?? []).map((x) => [x.code, x.action]));
  const head = ['Mã vật tư', 'Tên vật tư', 'ĐVT', 'MRP ban đầu', 'MRP hiện tại', 'Chênh lệch', 'Tồn kho', 'Hàng về', 'Đã đề xuất', 'Dự phòng tồn kho',
    'Thiếu', 'Đề xuất mua', 'Tồn sau SX', 'MES xử lý'];
  const rows = (rv.table ?? []).map((x) => [x.code, x.name, x.uom, n(x.mrp_old), n(x.mrp_new), n(x.diff), n(x.available), n(x.incoming),
    n(x.requested), n(x.reserve), n(x.shortage), n(x.suggest), n(x.projected_after), act.has(x.code) ? ACTION[act.get(x.code) as string] ?? act.get(x.code) : '']);
  const state = rv.applied ? `Đã áp khi duyệt${rv.at ? ` ${new Date(rv.at).toLocaleString('vi-VN', { timeZone: 'Asia/Ho_Chi_Minh' })}` : ''}` : 'Chạy thử (chưa đổi gì), MRP ban đầu = lần chạy MRP gần nhất của kế hoạch';
  const sheets = [{
    name: 'Bảng MRP hiệu chỉnh',
    title: `Bảng MRP hiệu chỉnh ${a.adj_no} · kế hoạch ${a.plan_no} · ${state}`,
    rows: [head, ...rows],
    widths: [14, 30, 7, 13, 13, 13, 12, 12, 13, 14, 12, 13, 13, 30],
  }];
  const cuts = rv.reductions ?? [];
  if (cuts.length) sheets.push({
    name: 'Đơn, đề xuất mua giảm',
    title: `${rv.applied ? 'Đơn mua / đề xuất mua đã giảm' : 'Đơn mua / đề xuất mua sẽ giảm khi duyệt'} · ${a.adj_no}`,
    rows: [['Loại', 'Số chứng từ', 'Trạng thái', 'Mã vật tư', 'ĐVT', 'Số cũ', 'Số mới'],
      ...cuts.map((c) => [c.doc_type === 'PO' ? 'Đơn mua' : 'Đề xuất mua', c.pr_no, ST[c.status] ?? c.status, c.material_code, c.uom, n(c.old), n(c.new)])],
    widths: [14, 18, 18, 14, 7, 13, 13],
  });
  const body = buildXlsx(sheets);
  return new NextResponse(Buffer.from(body), {
    headers: { 'Content-Type': XLSX_TYPE, 'Content-Disposition': xlsxDisposition(`MRP hieu chinh ${a.adj_no}.xlsx`), 'Cache-Control': 'no-store' },
  });
}
