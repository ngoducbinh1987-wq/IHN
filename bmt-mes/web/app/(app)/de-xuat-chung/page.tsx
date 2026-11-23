import Link from 'next/link';
import { Empty, Flash, Pill, StatusPill, Tabs, Toolbar } from '@/components/ui';
import { df, dmy, nf } from '@/lib/format';
import { REQ_GROUPS, REQ_STATUS, fmtDays, type Req, type ReqType } from '@/lib/requests';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Đề xuất' };

const COLS = 'id, req_no, type_code, type_name, grp, form, title, requester_name, dept, dept_name, date_from, date_to, part, days, amount, status, created_at, current_level, current_approvers, step_due_at, overdue, my_turn, can_handle, mine, anonymous';

// Mục Đề xuất chung (anh Bình duyệt 22/11/2026): mọi tài khoản lập đề xuất bất cứ việc gì; database tự lọc ai xem được gì
export default async function Requests({ searchParams }: { searchParams: Promise<{ tab?: string; ok?: string; err?: string; loai?: string; tt?: string }> }) {
  const sp = await searchParams;
  const me = await requireMe();
  const db = await createClient();
  const [{ data: types }, { data: all }, { data: profile }] = await Promise.all([
    db.schema('app').from('v_request_types').select('*').order('sort').returns<ReqType[]>(),
    db.schema('app').from('v_requests').select(COLS).order('created_at', { ascending: false }).limit(500),
    db.schema('core').from('profiles').select('department').eq('id', me.id).maybeSingle(),
  ]);
  const rows = (all ?? []) as unknown as Req[];
  const mine = rows.filter((r) => r.mine);
  const todo = rows.filter((r) => r.my_turn || r.can_handle);
  const myDept = profile?.department ?? null;
  const head = me.roles.some((r) => ['SX_TP', 'THU_KHO', 'KT_TP', 'MUA_TP', 'KTT', 'KD_TP', 'HCNS'].includes(r));
  const wide = me.is_admin || me.roles.includes('BGD') || me.roles.includes('HCNS');
  const dept = rows.filter((r) => !r.mine && myDept !== null && r.dept === myDept);
  const tab = sp.tab ?? (mine.length || todo.length ? (todo.length ? 'cho-toi' : 'cua-toi') : 'lap');
  let list = tab === 'cua-toi' ? mine : tab === 'cho-toi' ? todo : tab === 'bo-phan' ? dept : rows;
  if (sp.loai) list = list.filter((r) => r.type_code === sp.loai);
  if (sp.tt) list = list.filter((r) => r.status === sp.tt);
  const year = new Date().getFullYear();
  const leaveUsed = mine.filter((r) => r.type_code === 'PHEP_NAM' && ['APPROVED', 'DONE'].includes(r.status) && (r.date_from ?? '').startsWith(String(year)))
    .reduce((s, r) => s + Number(r.days ?? 0), 0);
  const tabs = [
    { key: 'lap', label: 'Lập đề xuất', href: '/de-xuat-chung?tab=lap' },
    { key: 'cua-toi', label: 'Của tôi', href: '/de-xuat-chung?tab=cua-toi', count: mine.length },
    { key: 'cho-toi', label: 'Chờ tôi duyệt, xử lý', href: '/de-xuat-chung?tab=cho-toi', count: todo.length },
    ...(head ? [{ key: 'bo-phan', label: 'Bộ phận tôi', href: '/de-xuat-chung?tab=bo-phan' }] : []),
    ...(wide ? [{ key: 'tat-ca', label: 'Tất cả', href: '/de-xuat-chung?tab=tat-ca', count: rows.length }] : []),
  ];
  return (
    <>
      <Toolbar title="Đề xuất" reload="/de-xuat-chung" add={{ href: '/de-xuat-chung?tab=lap', label: 'Lập đề xuất' }} />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err} /></div>
      <Tabs items={tabs} active={tab} />
      {tab === 'lap' ? (
        <div className="flex flex-col gap-5" id="loai-de-xuat">
          <p className="text-[14px] text-muted">Chọn loại đề xuất. MES tự giao người duyệt theo bộ phận của bạn; đề xuất hiện ở Quy trình duyệt của người duyệt,
            duyệt xong MES tự chuyển cho bộ phận xử lý. Phép năm đã nghỉ năm {year}: <b className="text-ink">{fmtDays(leaveUsed) || '0 ngày'}</b>.</p>
          {REQ_GROUPS.map(([g, gname]) => {
            const ts = (types ?? []).filter((t) => t.grp === g);
            if (!ts.length) return null;
            return (
              <section key={g}>
                <h2 className="mb-2 text-[17px] font-medium">{gname}</h2>
                <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
                  {ts.map((t) => (
                    <Link key={t.code} href={`/de-xuat-chung/moi?loai=${t.code}`} className="card block p-3.5 hover:border-brand" data-type={t.code}>
                      <div className="text-[15px] font-medium text-brand">{t.name}</div>
                      <div className="mt-1 text-[13px] text-muted">{t.hint}</div>
                    </Link>
                  ))}
                </div>
              </section>
            );
          })}
        </div>
      ) : list.length === 0 ? (
        <Empty>{tab === 'cho-toi' ? 'Không có đề xuất nào chờ bạn duyệt hoặc xử lý.' : 'Chưa có đề xuất nào.'}</Empty>
      ) : (
        <div className="overflow-x-auto rounded border border-line bg-surface">
          <table className="tbl" id="danh-sach-de-xuat">
            <thead><tr><th>Số</th><th>Loại</th><th>Người đề xuất</th><th>Nội dung</th><th>Thời gian / số tiền</th><th>Trạng thái</th><th>Đang ở bước</th><th>Lập lúc</th></tr></thead>
            <tbody>
              {list.map((r) => (
                <tr key={r.id}>
                  <td className="mono"><Link className="text-brand hover:underline" href={`/de-xuat-chung/${r.id}`}>{r.req_no}</Link></td>
                  <td>{r.type_name}</td>
                  <td>{r.requester_name}<div className="text-[12px] text-muted">{r.dept_name}</div></td>
                  <td className="max-w-[280px] truncate">{r.title}</td>
                  <td className="whitespace-nowrap">
                    {r.date_from ? `${dmy(r.date_from)}${r.date_to && r.date_to !== r.date_from ? ' – ' + dmy(r.date_to) : ''}` : ''}
                    {r.days !== null && <span className="text-muted"> · {fmtDays(Number(r.days))}</span>}
                    {r.amount !== null && <span>{nf(r.amount)} đ</span>}
                  </td>
                  <td><StatusPill map={REQ_STATUS} value={r.status} />{r.overdue && r.status === 'PENDING_APPROVAL' && <> <Pill tone="bad">Quá hạn</Pill></>}</td>
                  <td className="text-[13px]">
                    {r.status === 'PENDING_APPROVAL' ? <>{r.current_level}<div className="text-muted">{(r.current_approvers ?? []).map((p) => p.name).join(', ')}</div></> : r.status === 'APPROVED' ? 'Chờ xử lý' : '—'}
                    {r.my_turn && <div><Pill tone="info">Chờ tôi duyệt</Pill></div>}
                    {r.can_handle && <div><Pill tone="warn">Chờ tôi xử lý</Pill></div>}
                  </td>
                  <td className="whitespace-nowrap text-[13px]">{df(r.created_at, true)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}
