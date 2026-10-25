import Link from 'next/link';
import { notFound } from 'next/navigation';
import { AlertCircle, ChevronDown, ChevronRight, History, Info, MessageSquare, X } from 'lucide-react';
import { StageBar } from '@/components/stage-bar';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, InfoRow, Pill, StatusPill } from '@/components/ui';
import { type Approval, stageLabel } from '@/lib/approvals';
import { DOC_STATUS, SPEC_STATUS, df, nf, overdueText } from '@/lib/format';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { approve, comment, reject } from './actions';

export const metadata = { title: 'Chi tiết quy trình' };

const ACTION: Record<string, [string, 'ok' | 'bad' | 'info']> = {
  APPROVE: ['Chuyển giai đoạn', 'ok'], REJECT: ['Trả lại', 'bad'], COMMENT: ['Trao đổi', 'info'],
};

export default async function ApprovalDetail({ params, searchParams }:
  { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; err?: string; tab?: string }> }) {
  const { id } = await params;
  const sp = await searchParams;
  const me = await requireMe();
  const supabase = await createClient();
  const { data: a } = await supabase.schema('app').from('v_approvals').select('*').eq('id', id).maybeSingle<Approval>();
  if (!a) notFound();
  const tab = sp.tab ?? 'thong-tin';
  const history = a.history ?? [];
  const comments = history.filter((h) => h.comment);
  const late = a.status === 'PENDING' ? overdueText(a.step_due_at) : null;
  const people = new Map<string, string>();
  if (a.submitted_by_name) people.set(a.submitted_by_name, 'Người lập');
  for (const h of history) if (h.actor && !people.has(h.actor)) people.set(h.actor, h.label ?? 'Người duyệt');
  for (const s of a.steps ?? []) for (const p of s.approvers ?? []) if (!people.has(p.name)) people.set(p.name, s.label);

  return (
    <div className="-m-4 md:-m-5">
      <div className="flex flex-wrap items-center gap-2 border-b border-line bg-surface px-4 py-3 md:px-5">
        <h1 className="mr-auto min-w-0 text-[22px] font-medium leading-tight">{a.doc_no}{a.summary ? ` – ${a.summary}` : ''}</h1>
        {a.doc_link && <Link href={a.doc_link} className="btn btn-soft">Mở chứng từ</Link>}
        <Link href="/duyet" className="btn border-[#BFE7DA] bg-[#E3F6EF] text-brand-dark"><X size={16} />Đóng</Link>
      </div>

      <div className="grid xl:grid-cols-[minmax(0,1fr)_380px]">
        <div className="min-w-0 border-r border-line bg-surface">
          <div className="px-4 pt-4 md:px-5"><Flash ok={sp.ok} err={sp.err} /></div>
          <div className="px-0"><StageBar stages={a.steps ?? []} /></div>

          {/* Giai đoạn hiện tại */}
          <div className="flex flex-wrap items-start gap-4 border-b border-line px-4 py-4 md:px-5">
            <div className="mr-auto min-w-0">
              <div className="flex flex-wrap items-center gap-2 text-[22px] font-medium">
                {a.status === 'PENDING' ? <AlertCircle size={22} className="text-ink" /> : null}
                {a.status === 'PENDING' ? a.current_level : stageLabel(a)}
                {late && <Pill tone="bad">⚠ Quá hạn</Pill>}
                {a.status !== 'PENDING' && <StatusPill map={DOC_STATUS} value={a.status} />}
              </div>
              {a.status === 'PENDING' && (
                <div className="mt-1 space-y-0.5 text-[15px]">
                  <div>vai trò <span className="text-brand">{a.current_role_name}</span></div>
                  <div>người thực hiện <span className="font-medium uppercase text-brand">{a.current_approvers.map((p) => p.name).join(', ') || 'chưa có người giữ vai trò này'}</span></div>
                  <div>hạn hoàn thành <span className="text-brand">{df(a.step_due_at, true)}</span></div>
                </div>
              )}
            </div>
            {a.my_turn && (
              <div className="flex flex-col items-end gap-2">
                <div className="flex">
                  <form action={approve}>
                    <input type="hidden" name="id" value={a.id} />
                    <SubmitButton className="btn btn-pri rounded-r-none px-4 py-2.5 text-[15px]" pendingText="Đang chuyển…"><ChevronRight size={18} />Chuyển giai đoạn tiếp</SubmitButton>
                  </form>
                  <details className="group relative">
                    <summary className="btn btn-pri list-none rounded-l-none border-l border-l-white/40 px-2.5 py-2.5" aria-label="Tùy chọn khác"><ChevronDown size={18} /></summary>
                    <form className="absolute right-0 z-20 mt-1 flex w-[340px] flex-col gap-2 rounded border border-line bg-surface p-3 shadow-lg">
                      <input type="hidden" name="id" value={a.id} />
                      <label className="lbl">Ý kiến / lý do (bắt buộc khi trả lại)
                        <textarea className="inp" name="comment" rows={3} placeholder="Ví dụ: bổ sung kết quả pilot mẫu 2…" />
                      </label>
                      <div className="flex justify-end gap-2">
                        <SubmitButton className="btn btn-bad-o" formAction={reject}>Trả lại người lập</SubmitButton>
                        <SubmitButton className="btn btn-pri" formAction={approve}>Duyệt kèm ý kiến</SubmitButton>
                      </div>
                    </form>
                  </details>
                </div>
                <span className="text-[12.5px] text-muted">Bạn đang giữ bước này</span>
              </div>
            )}
            {a.status === 'PENDING' && !a.my_turn && (
              <div className="rounded bg-sunk px-3 py-2 text-[13px] text-muted">
                {a.i_submitted ? 'Bạn là người lập: chờ người duyệt xử lý.' : 'Bạn không giữ bước này.'}
              </div>
            )}
          </div>

          {/* Thẻ nội dung */}
          <nav className="flex gap-1 overflow-x-auto border-b border-line px-2 md:px-3" aria-label="Nội dung">
            {[
              ['thong-tin', 'Thông tin chung', Info],
              ['lich-su', `Lịch sử giai đoạn (${history.filter((h) => h.action !== 'COMMENT').length})`, History],
              ['trao-doi', `Trao đổi (${comments.length})`, MessageSquare],
            ].map(([k, l, Icon]) => {
              const I = Icon as typeof Info;
              return (
                <Link key={k as string} href={`/duyet/${a.id}?tab=${k}`} aria-current={tab === k ? 'page' : undefined}
                  className={`-mb-px flex items-center gap-1.5 whitespace-nowrap border-b-[3px] px-3 py-3 text-[15px] ${tab === k ? 'border-brand text-brand' : 'border-transparent hover:text-brand'}`}>
                  <I size={16} />{l as string}
                </Link>
              );
            })}
          </nav>

          <div className="px-4 py-4 md:px-5">
            {tab === 'thong-tin' && <DocInfo a={a} canSeePrice={me.can_see_price} />}
            {tab === 'lich-su' && (
              history.filter((h) => h.action !== 'COMMENT').length ? (
                <ol className="relative ml-2 border-l-2 border-line">
                  <li className="mb-4 ml-4"><span className="absolute -left-[7px] mt-1.5 h-3 w-3 rounded-full bg-brand" />
                    <div className="text-[14px]"><b>Lập phiếu</b> · {a.submitted_by_name} · {df(a.submitted_at, true)}</div></li>
                  {history.filter((h) => h.action !== 'COMMENT').map((h, i) => (
                    <li key={i} className="mb-4 ml-4">
                      <span className={`absolute -left-[7px] mt-1.5 h-3 w-3 rounded-full ${h.action === 'REJECT' ? 'bg-bad' : 'bg-brand'}`} />
                      <div className="text-[14px]"><b>{h.label}</b> · {h.actor} · {df(h.at, true)} <Pill tone={ACTION[h.action][1]}>{ACTION[h.action][0]}</Pill></div>
                      {h.comment && <div className="mt-1 rounded bg-sunk px-3 py-2 text-[14px]">{h.comment}</div>}
                    </li>
                  ))}
                </ol>
              ) : <Empty>Chưa có bước nào được xử lý.</Empty>
            )}
            {tab === 'trao-doi' && (
              <div className="flex flex-col gap-3">
                {comments.map((h, i) => (
                  <div key={i} className="flex gap-3">
                    <span className="grid h-9 w-9 shrink-0 place-items-center rounded-full bg-brand-soft text-[12px] font-medium text-brand-dark">
                      {(h.actor ?? '?').split(' ').slice(-1)[0][0]}
                    </span>
                    <div className="min-w-0 flex-1 rounded border border-line px-3 py-2">
                      <div className="text-[13px] text-muted"><b className="text-ink">{h.actor}</b> · {h.label} · {df(h.at, true)} · {ACTION[h.action][0]}</div>
                      <div className="mt-0.5 whitespace-pre-wrap text-[14px]">{h.comment}</div>
                    </div>
                  </div>
                ))}
                {comments.length === 0 && <Empty>Chưa có trao đổi nào.</Empty>}
                {a.status === 'PENDING' && (a.my_turn || a.i_submitted) && (
                  <form action={comment} className="flex flex-col gap-2">
                    <input type="hidden" name="id" value={a.id} />
                    <textarea className="inp" name="comment" rows={3} placeholder="Nhập nội dung trao đổi…" aria-label="Nội dung trao đổi" />
                    <div><SubmitButton className="btn btn-pri">Gửi trao đổi</SubmitButton></div>
                  </form>
                )}
              </div>
            )}
          </div>
        </div>

        {/* Khung thông tin bên phải */}
        <aside className="bg-surface">
          <div className="border-b border-line px-4 py-3 md:px-5">
            <InfoRow label="Quy trình">{a.doc_type_name}</InfoRow>
            <InfoRow label="Giai đoạn hiện tại">{stageLabel(a)}</InfoRow>
            <InfoRow label="Người thực hiện"><span className="uppercase">{a.status === 'PENDING' ? a.current_approvers.map((p) => p.name).join(', ') || '—' : '—'}</span></InfoRow>
            <InfoRow label="Người tạo"><span className="uppercase">{a.submitted_by_name}</span></InfoRow>
            <InfoRow label="Thời gian tạo">{df(a.submitted_at, true)}</InfoRow>
            {a.status === 'PENDING' ? (
              <InfoRow label="Hạn giai đoạn">{df(a.step_due_at, true)}{late && <div className="mt-1"><Pill tone="bad">{late}</Pill></div>}</InfoRow>
            ) : <InfoRow label="Hoàn tất lúc">{df(a.finished_at, true)}</InfoRow>}
          </div>
          <div className="px-4 py-3 md:px-5">
            <h2 className="mb-2 text-[20px] font-medium">Người phối hợp</h2>
            <ul className="divide-y divide-line">
              {[...people.entries()].map(([name, role]) => (
                <li key={name} className="flex items-center gap-3 py-2.5">
                  <span className="grid h-10 w-10 place-items-center rounded-full bg-brand text-[13px] font-medium text-white">
                    {name.split(' ').filter(Boolean).slice(-2).map((w) => w[0]).join('').toUpperCase()}
                  </span>
                  <span><span className="block text-[15px] uppercase text-brand">{name}</span><span className="text-[12.5px] text-muted">{role}</span></span>
                </li>
              ))}
            </ul>
          </div>
        </aside>
      </div>
    </div>
  );
}

// Nội dung chứng từ hiển thị ngay trong trang duyệt để người duyệt không phải mở trang khác
async function DocInfo({ a, canSeePrice }: { a: Approval; canSeePrice: boolean }) {
  const supabase = await createClient();
  if (a.doc_type === 'PR') {
    const [{ data: pr }, { data: lines }] = await Promise.all([
      supabase.schema('app').from('v_prs').select('*').eq('id', a.doc_id).maybeSingle(),
      supabase.schema('app').from('v_pr_lines').select('*').eq('pr_id', a.doc_id).order('material_code'),
    ]);
    const total = (lines ?? []).reduce((s, l) => s + (l.unit_price === null ? 0 : Number(l.qty) * Number(l.unit_price)), 0);
    return (
      <div className="flex flex-col gap-3">
        <Field label="Nội dung đề xuất">{pr?.note}</Field>
        <Field label="Ngày cần hàng">{df(pr?.need_date)}</Field>
        <div className="overflow-x-auto rounded border border-line">
          <table className="tbl">
            <thead><tr><th>Mã VT</th><th>Vật tư</th><th className="num">Số lượng</th><th>ĐVT</th><th className="num">Tồn khả dụng</th><th>Ngày cần</th>{canSeePrice && <th className="num">Đơn giá</th>}{canSeePrice && <th className="num">Thành tiền</th>}</tr></thead>
            <tbody>
              {(lines ?? []).map((l) => (
                <tr key={l.id}><td className="mono font-medium">{l.material_code}</td><td>{l.material_name}</td><td className="num font-medium">{nf(l.qty, 2)}</td><td>{l.uom}</td>
                  <td className="num">{nf(l.available, 1)}</td><td>{df(l.need_date)}</td>
                  {canSeePrice && <td className="num">{l.unit_price === null ? <Pill tone="warn">Chưa có giá</Pill> : nf(l.unit_price)}</td>}
                  {canSeePrice && <td className="num">{l.unit_price === null ? '—' : nf(Number(l.qty) * Number(l.unit_price))}</td>}</tr>
              ))}
            </tbody>
            {canSeePrice && <tfoot><tr><td colSpan={7} className="px-3 py-2 text-right font-medium">Tổng (dòng có giá)</td><td className="num px-3 font-medium">{nf(total)} đ</td></tr></tfoot>}
          </table>
        </div>
      </div>
    );
  }
  if (a.doc_type.startsWith('SPEC')) {
    const { data: s } = await supabase.schema('master').from('product_specs')
      .select('*, products!product_specs_product_id_fkey(code, description), spec_results(*)').eq('id', a.doc_id).maybeSingle();
    const { data: issues } = await supabase.schema('master').rpc('check_spec', { p_spec: a.doc_id });
    if (!s) return <Empty>Không đọc được spec.</Empty>;
    const r = Array.isArray(s.spec_results) ? s.spec_results[0] : s.spec_results;
    const p = Array.isArray(s.products) ? s.products[0] : s.products;
    return (
      <div className="grid gap-x-8 gap-y-1 md:grid-cols-2">
        <Field label="Sản phẩm">{p?.code} · {p?.description}</Field>
        <Field label="Phiên bản">v{s.version} <StatusPill map={SPEC_STATUS} value={s.status} /></Field>
        <Field label="Ruột dẫn">{s.wire_count}×{nf(s.wire_dia_mm, 2)} mm {s.conductor_mat} · bước bện {nf(s.pitch_mm, 1)} mm</Field>
        <Field label="Cách điện / vỏ">{s.insulation} {nf(s.ins_thickness_mm, 2)} mm · {s.sheath} {s.sheath_thickness_mm ? nf(s.sheath_thickness_mm, 2) + ' mm' : ''}</Field>
        <Field label="Định mức tổng">{nf(r?.total_kgkm, 2)} kg/km (đồng {nf(r?.metal_kgkm, 3)})</Field>
        <Field label="Rdc tính / giới hạn">{nf(r?.rdc_calc, 3)} / {r?.rdc_limit === null ? 'chưa có' : nf(r?.rdc_limit, 2)} Ω/km</Field>
        <Field label="Pilot">{r?.pilot_rdc === null || r?.pilot_rdc === undefined ? 'Chưa đo' : `Rdc ${nf(r.pilot_rdc, 3)} · ${nf(r.pilot_kgkm, 2)} kg/km`}</Field>
        <Field label="Kiểm tra tự động">{(issues as string[] | null)?.length ? <span className="text-bad">{(issues as string[]).join('; ')}</span> : <span className="text-brand">Đạt</span>}</Field>
        {s.config_note && <div className="md:col-span-2"><Field label="Ghi chú">{s.config_note}</Field></div>}
      </div>
    );
  }
  if (a.doc_type === 'PLAN') {
    const { data: plan } = await supabase.schema('app').from('v_plans').select('*').eq('id', a.doc_id).maybeSingle();
    const { data: run } = plan?.last_run_id
      ? await supabase.schema('plan').from('mrp_runs').select('budget_vnd, missing_price_count').eq('id', plan.last_run_id).maybeSingle()
      : { data: null };
    return (
      <div className="grid gap-x-8 md:grid-cols-2">
        <Field label="Kỳ kế hoạch">{plan?.period_label}</Field>
        <Field label="Ngày cần vật tư">{df(plan?.material_need_date)}</Field>
        <Field label="Số SKU / tổng mét">{plan?.line_count} SKU · {nf(plan?.total_m)} m</Field>
        {canSeePrice && <Field label="Ngân sách vật tư">{run ? `${nf(run.budget_vnd)} đ` : '—'}{run?.missing_price_count ? ` (${run.missing_price_count} mã thiếu giá)` : ''}</Field>}
      </div>
    );
  }
  return <Field label="Nội dung">{a.summary ?? '—'}</Field>;
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="grid grid-cols-[160px_1fr] gap-3 py-1.5 text-[14px]">
      <div className="font-medium text-ink/80">{label}</div><div className="min-w-0">{children ?? '—'}</div>
    </div>
  );
}
