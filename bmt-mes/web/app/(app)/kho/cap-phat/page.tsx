import Link from 'next/link';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, StatusPill, Tabs, Toolbar } from '@/components/ui';
import { df, nf } from '@/lib/format';
import { LoadErrors, REQ_STATUS, hasRole } from '@/lib/kho';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { createExtra, createRequisition } from './actions';

export const metadata = { title: 'Cấp NVL' };

const TAB_STATUS: Record<string, string[]> = { mo: ['APPROVED', 'PARTIAL'], cho: ['PENDING_APPROVAL', 'DRAFT'], xong: ['DONE'], huy: ['CANCELLED'] };

export default async function RequisitionsPage({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string; tab?: string }> }) {
  const sp = await searchParams;
  const me = await requireMe();
  const tab = sp.tab && TAB_STATUS[sp.tab] ? sp.tab : 'mo';
  const supabase = await createClient();
  const le = new LoadErrors();
  const [{ data: reqs }, { data: counts }, { data: wos }, { data: reasons }] = le.all(await Promise.all([
    supabase.schema('app').from('v_requisitions').select('*').in('status', TAB_STATUS[tab]).order('created_at', { ascending: false }).limit(200),
    supabase.schema('app').from('v_requisitions').select('status'),
    supabase.schema('app').from('v_open_wos').select('*').order('wo_no'),
    supabase.schema('master').from('reason_codes').select('code, name').eq('kind', 'EXTRA_ISSUE').order('code'),
  ]));
  const n = (k: string) => (counts ?? []).filter((r) => TAB_STATUS[k].includes(r.status)).length;
  const planner = hasRole(me, 'SX_TP', 'TO_TRUONG', 'SX_KH');
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Ho_Chi_Minh' });
  return (
    <>
      <Toolbar title="Cấp nguyên vật liệu theo phiếu lĩnh" reload="/kho/cap-phat" />
      <Tabs active={tab} items={[
        { key: 'mo', label: 'Chờ cấp / đang cấp', href: '/kho/cap-phat', count: n('mo') },
        { key: 'cho', label: 'Lĩnh bổ sung chờ duyệt', href: '/kho/cap-phat?tab=cho', count: n('cho') },
        { key: 'xong', label: 'Đã cấp đủ', href: '/kho/cap-phat?tab=xong' },
        { key: 'huy', label: 'Đã hủy', href: '/kho/cap-phat?tab=huy' },
      ]} />
      <Flash ok={sp.ok} err={sp.err} /><Flash err={le.text} />
      <p className="mb-3 text-[13px] text-muted">
        Phiếu lĩnh do MES tự tính theo định mức từ lệnh sản xuất (Quy chuẩn mục 3). Kho mở đầu ca xuất đủ cho cả ca, cuối ca nhận lại phần thừa và phế.
        Lĩnh vượt định mức phải có TP Kỹ thuật/QA duyệt.
      </p>
      <section className="card mb-4 overflow-x-auto">
        {reqs && reqs.length > 0 ? (
          <table className="tbl">
            <thead><tr><th>Phiếu lĩnh</th><th>Loại</th><th>Lệnh SX</th><th>Sản phẩm</th><th className="num">Mét</th><th>Ngày</th><th>Tiến độ</th><th>Trạng thái</th><th>Người lập</th></tr></thead>
            <tbody>{reqs.map((r) => (
              <tr key={r.id}>
                <td><Link className="link mono font-medium" href={`/kho/cap-phat/${r.id}`}>{r.req_no}</Link></td>
                <td>{r.kind === 'NORM' ? 'Theo định mức' : <span className="text-warn">Bổ sung · {r.reason_name}</span>}</td>
                <td className="mono">{r.wo_no}</td><td className="min-w-[160px]"><span className="mono">{r.product_code}</span> · {r.product_name}</td>
                <td className="num">{nf(r.qty_m)}</td><td className="whitespace-nowrap">{df(r.work_date)}</td>
                <td className="whitespace-nowrap">{r.line_done}/{r.line_count} mã đủ</td>
                <td><StatusPill map={REQ_STATUS} value={r.status} /></td><td>{r.created_by_name}</td>
              </tr>
            ))}</tbody>
          </table>
        ) : <Empty>Không có phiếu lĩnh nào ở mục này.</Empty>}
      </section>

      {planner && (
        <div className="grid gap-4 lg:grid-cols-2">
          <section className="card">
            <div className="card-h">Lập phiếu lĩnh theo định mức (ca/ngày)</div>
            {wos && wos.length > 0 ? (
              <form action={createRequisition} className="grid gap-3 p-4 sm:grid-cols-2">
                <label className="lbl sm:col-span-2"><span className="req">Lệnh sản xuất</span>
                  <select className="inp inp-y" name="wo_id" required>
                    {wos.map((w) => <option key={w.id} value={w.id}>{w.wo_no} · {w.product_code} · còn {nf(Number(w.qty_m) - Number(w.requisitioned_m))} / {nf(w.qty_m)} m</option>)}
                  </select></label>
                <label className="lbl"><span className="req">Mét sản xuất của ca/ngày</span><input className="inp inp-y text-right" name="qty_m" inputMode="decimal" required /></label>
                <label className="lbl">Ngày sản xuất<input className="inp" type="date" name="work_date" defaultValue={today} /></label>
                <label className="lbl sm:col-span-2">Ghi chú<input className="inp" name="note" placeholder="Ca 1, máy…" /></label>
                <div className="sm:col-span-2"><SubmitButton>Tạo phiếu lĩnh</SubmitButton></div>
              </form>
            ) : <Empty>Chưa có lệnh sản xuất đã phát lệnh.</Empty>}
          </section>
          <section className="card">
            <div className="card-h">Lĩnh bổ sung vượt định mức</div>
            {wos && wos.length > 0 ? (
              <form action={createExtra} className="grid gap-3 p-4 sm:grid-cols-2">
                <label className="lbl sm:col-span-2"><span className="req">Lệnh sản xuất</span>
                  <select className="inp inp-y" name="wo_id" required>{wos.map((w) => <option key={w.id} value={w.id}>{w.wo_no} · {w.product_code}</option>)}</select></label>
                <label className="lbl sm:col-span-2"><span className="req">Vật tư cần thêm (mỗi dòng: MÃ số lượng)</span>
                  <textarea className="inp inp-y font-mono" name="lines" rows={3} placeholder={'CU-024 5\nPVC-FR 12,5'} required /></label>
                <label className="lbl"><span className="req">Nguyên nhân</span>
                  <select className="inp inp-y" name="reason" required>{(reasons ?? []).map((r) => <option key={r.code} value={r.code}>{r.name}</option>)}</select></label>
                <label className="lbl">Ghi chú<input className="inp" name="note" /></label>
                <div className="sm:col-span-2"><SubmitButton>Gửi TP Kỹ thuật/QA duyệt</SubmitButton></div>
              </form>
            ) : <Empty>Chưa có lệnh sản xuất đã phát lệnh.</Empty>}
          </section>
        </div>
      )}
    </>
  );
}
