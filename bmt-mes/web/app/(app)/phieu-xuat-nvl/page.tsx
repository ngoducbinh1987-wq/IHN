import Link from 'next/link';
import { redirect } from 'next/navigation';
import { Printer } from 'lucide-react';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Pill, StatusPill, Toolbar } from '@/components/ui';
import { df, nf } from '@/lib/format';
import { REQ_STATUS, hasRole } from '@/lib/kho';
import { can, requireMe, requirePage } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { paperIssue, paperReturn } from './actions';

export const metadata = { title: 'Phiếu xuất NVL theo lô, NVL thừa' };

type Req = { id: string; req_no: string; kind: string; status: string; work_date: string; note: string | null; wo_no: string; product_code: string; product_name: string };
type Line = { id: string; req_id: string; material_id: string; material_code: string; material_name: string; uom: string; qty_req: number; qty_issued: number; qty_returned: number; remaining: number };
type Pick = { hu_no: string; material_id: string; lot_no: string; available: number; location_code: string | null; pick_order: number };
type Doc = { id: string; doc_no: string; doc_type: string; status: string; paper_no: string | null; receiver_code: string | null; posted_at: string | null; wo_no: string; product_code: string; req_no: string | null; lines: string | null; created_by_name: string | null; reversed_by: string | null };

const ISSUE_ROWS = 2;   // dòng nhập mỗi vật tư (ống/bao)

export default async function PaperIssuePage({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string; ngay?: string }> }) {
  const sp = await searchParams;
  await requirePage('phieu-xuat-nvl');
  const me = await requireMe();
  const canEnter = hasRole(me, 'KT_KHO', 'SX_TP', 'ADMIN');
  if (!canEnter && !can(me, 'inventory', 'view') && !can(me, 'production', 'view')) {
    redirect('/?err=' + encodeURIComponent('Bạn chưa được cấp quyền vào trang này'));
  }
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Ho_Chi_Minh' });
  const day = /^\d{4}-\d{2}-\d{2}$/.test(sp.ngay ?? '') ? sp.ngay! : today;
  const back = `/phieu-xuat-nvl?ngay=${day}`;
  const supabase = await createClient();
  const [{ data: reqs }, { data: docs }, { data: operators }] = await Promise.all([
    supabase.schema('app').from('v_requisitions').select('id, req_no, kind, status, work_date, note, wo_no, product_code, product_name')
      .eq('work_date', day).in('status', ['APPROVED', 'PARTIAL', 'DONE']).order('wo_no').returns<Req[]>(),
    supabase.schema('app').from('v_wo_mat_docs').select('*').eq('work_date', day).order('doc_no', { ascending: false }).returns<Doc[]>(),
    supabase.schema('master').from('operators').select('code, job').eq('active', true).order('sort'),
  ]);
  const ids = (reqs ?? []).map((r) => r.id);
  const { data: lines } = ids.length
    ? await supabase.schema('app').from('v_requisition_lines').select('*').in('req_id', ids).order('material_code').returns<Line[]>()
    : { data: [] as Line[] };
  const mats = [...new Set((lines ?? []).map((l) => l.material_id))];
  const { data: picks } = mats.length
    ? await supabase.schema('app').from('v_pick_suggest').select('hu_no, material_id, lot_no, available, location_code, pick_order')
        .in('material_id', mats).lte('pick_order', 4).order('pick_order').returns<Pick[]>()
    : { data: [] as Pick[] };
  // Mã tem đã xuất trong ngày: gợi ý khi nhập NVL thừa
  const issuedHus = [...new Set((docs ?? []).filter((d) => d.doc_type === 'ISSUE_WO')
    .flatMap((d) => [...(d.lines ?? '').matchAll(/\(([^()]+)\)/g)].map((m) => m[1])))];
  let row = 0;

  return (
    <>
      <Toolbar title="Phiếu xuất NVL theo lô, NVL thừa" reload={back} actions={<>
        <form className="flex items-center gap-2"><input className="inp" type="date" name="ngay" defaultValue={day} aria-label="Ngày sản xuất" /><button className="btn btn-sm">Xem</button></form>
        <Link className="btn btn-soft" href={`/in/phieu-xuat-nvl?d=${day}`} target="_blank"><Printer size={15} />In phiếu xuất + phiếu NVL thừa</Link>
      </>} />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /></div>
      <p className="mb-3 text-[13px] text-muted">
        16:00–17:00 hôm trước: Kế toán SX in phiếu xuất theo từng lô (MES gợi ý ống/bao xuất trước theo hạn dùng, ngày nhập). Thủ kho (TP SX) xuất, NV lấy NVL ký nhận;
        Kế toán SX nhập số thực xuất ở đây. 17:00: NVL thừa cân lại, nhập lại kho theo phiếu NVL thừa (đồng trên giá xả, nhựa trong phễu chạy tiếp cùng lô thì ghi ở Báo cáo ca).
      </p>

      {(reqs ?? []).length === 0 ? (
        <section className="card"><Empty>Ngày {df(day)} chưa có phiếu lĩnh. Phiếu lĩnh tạo khi Kế toán SX duyệt phiếu lĩnh của lệnh SX ngày (Lệnh SX ngày).</Empty></section>
      ) : (reqs ?? []).map((r) => {
        const ls = (lines ?? []).filter((l) => l.req_id === r.id);
        const open = r.status === 'APPROVED' || r.status === 'PARTIAL';
        return (
          <section key={r.id} className="card mb-4">
            <div className="card-h">
              <span><span className="mono">{r.req_no}</span> · lô <span className="mono">{r.wo_no}</span> · {r.product_code}</span>
              <StatusPill map={REQ_STATUS} value={r.status} />
            </div>
            <div className="overflow-x-auto">
              <table className="tbl">
                <thead><tr><th>Vật tư</th><th className="num">Cần xuất</th><th className="num">Đã xuất</th><th className="num">Đã trả</th><th className="num">Còn</th><th>Gợi ý ống/bao xuất trước</th></tr></thead>
                <tbody>{ls.map((l) => (
                  <tr key={l.id}>
                    <td><b>{l.material_code}</b><div className="text-[12px] text-muted">{l.material_name}</div></td>
                    <td className="num">{nf(l.qty_req, 2)} {l.uom}</td><td className="num">{nf(l.qty_issued, 2)}</td><td className="num">{nf(l.qty_returned, 2)}</td>
                    <td className="num">{nf(l.remaining, 2)}</td>
                    <td className="text-[12.5px]">{(picks ?? []).filter((p) => p.material_id === l.material_id).map((p) => `${p.hu_no} (${nf(p.available, 1)})`).join(' · ') || <span className="text-bad">Hết hàng đạt QC</span>}</td>
                  </tr>
                ))}</tbody>
              </table>
            </div>
            {open && canEnter && (
              <form action={paperIssue} className="border-t border-line p-4">
                <input type="hidden" name="req_id" value={r.id} /><input type="hidden" name="back" value={back} />
                <div className="mb-3 grid gap-3 md:grid-cols-4">
                  <label className="lbl"><span className="req">NV lấy NVL (đã ký nhận)</span>
                    <select className="inp inp-y" name="receiver_code" required defaultValue="">
                      <option value="">—</option>{(operators ?? []).map((o) => <option key={o.code} value={o.code}>{o.code} · {o.job}</option>)}
                    </select></label>
                  <label className="lbl">Số phiếu giấy<input className="inp" name="paper_no" /></label>
                  <label className="lbl md:col-span-2">Lý do không theo gợi ý ống/bao (nếu có)<input className="inp" name="reason" /></label>
                </div>
                <div className="grid gap-2 md:grid-cols-2">
                  {ls.filter((l) => l.remaining > 0).map((l) => (
                    <fieldset key={l.id} className="rounded border border-line p-2">
                      <legend className="px-1 text-[12.5px] text-muted">{l.material_code} · còn {nf(l.remaining, 2)} {l.uom}</legend>
                      {Array.from({ length: ISSUE_ROWS }, () => {
                        const i = row++;
                        return (
                          <div key={i} className="mb-1.5 flex gap-2">
                            <input className="inp mono uppercase" name={`is_code_${i}`} list={`pk-${l.material_id}`} placeholder="Mã tem ống/bao" aria-label={`Mã tem ${l.material_code}`} />
                            <input className="inp w-32 text-right" name={`is_qty_${i}`} inputMode="decimal" placeholder="cả ống/bao" aria-label={`Thực xuất ${l.material_code}`} />
                          </div>
                        );
                      })}
                      <datalist id={`pk-${l.material_id}`}>{(picks ?? []).filter((p) => p.material_id === l.material_id).map((p) => <option key={p.hu_no} value={p.hu_no}>{nf(p.available, 1)} {l.uom}</option>)}</datalist>
                    </fieldset>
                  ))}
                </div>
                <p className="mt-2 text-[12.5px] text-muted">Để trống số lượng = xuất cả ống/bao. Chỉ nhập dòng thủ kho đã xuất thật trên phiếu có chữ ký.</p>
                <div className="mt-3"><SubmitButton>Ghi sổ phiếu xuất</SubmitButton></div>
              </form>
            )}
          </section>
        );
      })}

      {canEnter && (
        <section className="card mb-4">
          <div className="card-h">Phiếu nhập NVL thừa cuối ngày</div>
          <form action={paperReturn} className="p-4">
            <input type="hidden" name="back" value={back} />
            <div className="mb-3 grid gap-3 md:grid-cols-4">
              <label className="lbl"><span className="req">Người trả (ghi trên phiếu)</span>
                <select className="inp inp-y" name="giver_code" required defaultValue="">
                  <option value="">—</option>{(operators ?? []).map((o) => <option key={o.code} value={o.code}>{o.code} · {o.job}</option>)}
                </select></label>
              <label className="lbl">Số phiếu giấy<input className="inp" name="paper_no" /></label>
            </div>
            <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
              {Array.from({ length: 8 }, (_, i) => (
                <div key={i} className="flex gap-2">
                  <input className="inp mono uppercase" name={`rt_code_${i}`} list="issued-hus" placeholder="Mã tem" aria-label={`Mã tem trả ${i + 1}`} />
                  <input className="inp w-28 text-right" name={`rt_qty_${i}`} inputMode="decimal" placeholder="kg cân" aria-label={`Kg cân lại ${i + 1}`} />
                </div>
              ))}
            </div>
            <datalist id="issued-hus">{issuedHus.map((h) => <option key={h} value={h} />)}</datalist>
            <p className="mt-2 text-[12.5px] text-muted">NVL trả về đúng ống/bao, đúng lô đã xuất. Không nhận lại nhiều hơn số đã xuất từ ống/bao đó.</p>
            <div className="mt-3"><SubmitButton>Nhập lại kho</SubmitButton></div>
          </form>
        </section>
      )}

      <section className="card overflow-x-auto">
        <div className="card-h">Phiếu đã ghi sổ cho ngày sản xuất {df(day)}</div>
        {(docs ?? []).length === 0 ? <Empty>Chưa có phiếu xuất, phiếu NVL thừa.</Empty> : (
          <table className="tbl">
            <thead><tr><th>Phiếu</th><th>Loại</th><th>Lô</th><th>Phiếu giấy</th><th>NV</th><th>Vật tư (mã tem)</th><th>Người nhập</th></tr></thead>
            <tbody>{(docs ?? []).map((d) => (
              <tr key={d.id} className={d.reversed_by ? 'opacity-50' : ''}>
                <td className="mono"><Link className="link" href={`/kho/phieu/${d.id}`}>{d.doc_no}</Link><div className="text-[12px] text-muted">{df(d.posted_at, true)}</div></td>
                <td>{d.doc_type === 'ISSUE_WO' ? <Pill tone="info">Xuất NVL</Pill> : <Pill tone="ok">NVL thừa nhập lại</Pill>}</td>
                <td><span className="mono">{d.wo_no}</span><div className="text-[12px] text-muted">{d.product_code}{d.req_no ? ` · ${d.req_no}` : ''}</div></td>
                <td>{d.paper_no ?? '—'}</td><td>{d.receiver_code ?? '—'}</td>
                <td className="text-[12.5px]">{d.lines}</td><td>{d.created_by_name ?? '—'}</td>
              </tr>
            ))}</tbody>
          </table>
        )}
      </section>
    </>
  );
}
