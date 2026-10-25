import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ScanList } from '@/components/scan';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Pill, StatusPill, Toolbar } from '@/components/ui';
import { df, nf } from '@/lib/format';
import { REQ_STATUS, REVIEW_STATUS, hasRole, keeps } from '@/lib/kho';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { cancelRequisition, issuePick } from '../actions';

export const metadata = { title: 'Phiếu lĩnh' };

type Person = { id: string; name: string; title: string | null };

export default async function RequisitionDetail({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; err?: string }> }) {
  const { id } = await params;
  const sp = await searchParams;
  const me = await requireMe();
  const supabase = await createClient();
  const { data: r } = await supabase.schema('app').from('v_requisitions').select('*').eq('id', id).maybeSingle();
  if (!r) notFound();
  const [{ data: lines }, { data: docs }, { data: vh }, { data: tt }, { data: kt }] = await Promise.all([
    supabase.schema('app').from('v_requisition_lines').select('*').eq('req_id', id).order('material_code'),
    supabase.schema('app').from('v_stock_docs').select('id, doc_no, doc_type, posted_at, receiver_name, received_at, review_status, total_qty, created_by_name')
      .eq('requisition_id', id).order('posted_at', { ascending: false }),
    supabase.schema('app').rpc('role_holders', { p_role: 'VAN_HANH' }),
    supabase.schema('app').rpc('role_holders', { p_role: 'TO_TRUONG' }),
    supabase.schema('app').rpc('role_holders', { p_role: 'KT_KHO' }),
  ]);
  const open = (lines ?? []).filter((l) => Number(l.remaining) > 0);
  const { data: sugg } = open.length
    ? await supabase.schema('app').from('v_pick_suggest').select('*').in('material_id', open.map((l) => l.material_id)).lte('pick_order', 3).order('pick_order')
    : { data: [] as never[] };
  const receivers = [...((vh ?? []) as Person[]), ...((tt ?? []) as Person[])].filter((p, i, a) => p.id !== me.id && a.findIndex((x) => x.id === p.id) === i);
  const witnesses = ((kt ?? []) as Person[]).filter((p) => p.id !== me.id);
  const canIssue = ['APPROVED', 'PARTIAL'].includes(r.status) && keeps(me, 'KNL');
  const canCancel = hasRole(me, 'SX_TP', 'TO_TRUONG', 'SX_KH') && !['DONE', 'CANCELLED'].includes(r.status) && !(lines ?? []).some((l) => Number(l.qty_issued) > 0);
  return (
    <>
      <Toolbar title={<span>{r.req_no} · lệnh {r.wo_no}</span>} reload={`/kho/cap-phat/${id}`}
        actions={<>{r.approval_id && <Link className="btn btn-soft" href={`/duyet/${r.approval_id}`}>Xem quy trình duyệt</Link>}<Link className="btn" href="/kho/cap-phat">Đóng</Link></>} />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /></div>
      <div className="mb-3 flex flex-wrap gap-x-6 gap-y-1 text-[14px]">
        <span><span className="text-muted">Sản phẩm:</span> <span className="mono">{r.product_code}</span> · {r.product_name}</span>
        <span><span className="text-muted">Loại:</span> {r.kind === 'NORM' ? `Theo định mức · ${nf(r.qty_m)} m · ngày ${df(r.work_date)}` : `Bổ sung · ${r.reason_name}`}</span>
        <span><span className="text-muted">Trạng thái:</span> <StatusPill map={REQ_STATUS} value={r.status} /></span>
        {r.note && <span><span className="text-muted">Ghi chú:</span> {r.note}</span>}
      </div>

      <section className="card mb-4 overflow-x-auto">
        <div className="card-h">Vật tư cần cấp</div>
        <table className="tbl">
          <thead><tr><th>Mã</th><th>Vật tư</th><th>ĐVT</th><th className="num">Định mức</th><th className="num">Cần cấp</th><th className="num">Đã xuất</th><th className="num">Đã trả</th><th className="num">Còn phải cấp</th><th className="num">Tồn khả dụng</th><th>Lấy trước (FEFO/FIFO)</th></tr></thead>
          <tbody>{(lines ?? []).map((l) => (
            <tr key={l.id} className={Number(l.remaining) === 0 ? 'text-muted' : ''}>
              <td className="mono font-medium">{l.material_code}</td><td className="min-w-[150px]">{l.material_name}</td><td>{l.uom}</td>
              <td className="num">{nf(l.qty_norm, 3)}</td><td className="num font-medium">{nf(l.qty_req, 3)}</td>
              <td className="num">{nf(l.qty_issued, 3)}</td><td className="num">{nf(l.qty_returned, 3)}</td>
              <td className="num font-medium">{Number(l.remaining) > 0 ? nf(l.remaining, 3) : <Pill tone="ok">Đủ</Pill>}</td>
              <td className={`num ${Number(l.available) < Number(l.remaining) ? 'text-bad' : ''}`}>{nf(l.available, 2)}</td>
              <td className="min-w-[220px] text-[12.5px]">
                {(sugg ?? []).filter((s) => s.material_id === l.material_id).map((s) => (
                  <div key={s.hu_id}><span className="mono">{s.hu_no}</span> · {nf(s.available, 2)} · {s.location_code ?? '—'}{s.exp_date ? ` · HSD ${df(s.exp_date)}` : ''}</div>
                ))}
              </td>
            </tr>
          ))}</tbody>
        </table>
      </section>

      {canIssue && (
        <section className="card mb-4">
          <div className="card-h">Xuất kho: quét từng ống/bao/cuộn</div>
          <form action={issuePick} className="flex flex-col gap-3 p-4">
            <input type="hidden" name="req_id" value={id} />
            <ScanList name="items" warehouse="KNL" kinds={['MAT']} withQty withReason allowed={open.map((l) => l.material_code)} qtyLabel="Xuất (để trống = cả đơn vị)"
              hint="Để trống số lượng = xuất nguyên ống/bao (dư thì trả cuối ca). Xuất lẻ thì nhập số kg đọc trên cân điện tử. Chỉ được dư 1 đơn vị không chia được." />
            <div className="grid gap-3 md:grid-cols-3">
              <label className="lbl"><span className="req">Công nhân nhận tại máy</span>
                <select className="inp inp-y" name="receiver_id" required defaultValue="">
                  <option value="" disabled>Chọn người nhận</option>
                  {receivers.map((p) => <option key={p.id} value={p.id}>{p.name}{p.title ? ` · ${p.title}` : ''}</option>)}
                </select></label>
              <label className="lbl">Kế toán SX chứng kiến (khi giữ kho theo ủy quyền)
                <select className="inp" name="witness_id" defaultValue=""><option value="">Không</option>{witnesses.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></label>
              <label className="lbl">Lý do xuất ngoài giờ mở kho (nếu có)<input className="inp" name="off_hours_reason" /></label>
            </div>
            <div><SubmitButton>Ghi phiếu xuất</SubmitButton></div>
          </form>
        </section>
      )}

      <section className="card mb-4 overflow-x-auto">
        <div className="card-h">Phiếu xuất / trả theo phiếu lĩnh này</div>
        {docs && docs.length > 0 ? (
          <table className="tbl">
            <thead><tr><th>Phiếu</th><th>Ghi sổ</th><th className="num">Số lượng</th><th>Người xuất</th><th>Người nhận</th><th>Kế toán SX</th></tr></thead>
            <tbody>{docs.map((d) => (
              <tr key={d.id}>
                <td><Link className="link mono" href={`/kho/phieu/${d.id}`}>{d.doc_no}</Link><div className="text-[12px] text-muted">{d.doc_type === 'ISSUE_WO' ? 'Xuất' : 'Trả thừa'}</div></td>
                <td className="whitespace-nowrap">{df(d.posted_at, true)}</td><td className="num">{nf(d.total_qty, 3)}</td><td>{d.created_by_name}</td>
                <td>{d.receiver_name ?? '—'}{d.doc_type === 'ISSUE_WO' && d.receiver_name && (d.received_at ? <div className="text-[12px] text-brand">đã nhận {df(d.received_at, true)}</div> : <div className="text-[12px] text-warn">chưa xác nhận</div>)}</td>
                <td><StatusPill map={REVIEW_STATUS} value={d.review_status} /></td>
              </tr>
            ))}</tbody>
          </table>
        ) : <Empty>Chưa xuất lần nào.</Empty>}
      </section>

      {canCancel && (
        <form action={cancelRequisition} className="card flex flex-wrap items-end gap-3 p-4">
          <input type="hidden" name="req_id" value={id} />
          <label className="lbl flex-1">Lý do hủy phiếu lĩnh<input className="inp" name="reason" required /></label>
          <SubmitButton className="btn btn-bad-o">Hủy phiếu lĩnh</SubmitButton>
        </form>
      )}
    </>
  );
}
