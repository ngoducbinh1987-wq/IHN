import Link from 'next/link';
import { notFound } from 'next/navigation';
import { SubmitButton } from '@/components/submit-button';
import { Flash, PageHeader, StatusPill } from '@/components/ui';
import { DOC_STATUS, ROLE_NAMES, df } from '@/lib/format';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { approve, comment, reject } from './actions';

type Step = { seq: number; label: string; role: string };
type Hist = { seq: number; action: string; comment: string | null; at: string; actor: string | null };

// Đường dẫn tới chứng từ gốc theo loại
async function docLink(supabase: Awaited<ReturnType<typeof createClient>>, docType: string, docId: string) {
  if (docType.startsWith('SPEC')) {
    const { data } = await supabase.schema('app').from('v_products').select('code').eq('spec_id', docId).maybeSingle();
    return data ? `/san-pham/${data.code}` : null;
  }
  if (docType === 'PLAN') return `/ke-hoach/${docId}`;
  return null;
}

export default async function ApprovalDetail({ params, searchParams }:
  { params: Promise<{ id: string }>; searchParams: Promise<{ ok?: string; err?: string }> }) {
  const { id } = await params;
  const sp = await searchParams;
  await requireMe();
  const supabase = await createClient();
  const { data: a } = await supabase.schema('app').from('v_approvals').select('*').eq('id', id).maybeSingle();
  if (!a) notFound();
  const steps = (a.steps as Step[] | null) ?? [];
  const hist = (a.history as Hist[] | null) ?? [];
  const href = await docLink(supabase, a.doc_type, a.doc_id);
  const stepState = (s: Step) => {
    if (a.status === 'APPROVED') return 'done';
    if (a.status === 'REJECTED' && s.seq === a.current_seq) return 'rej';
    if (s.seq < a.current_seq) return 'done';
    if (s.seq === a.current_seq && a.status === 'PENDING') return 'cur';
    return '';
  };
  return (
    <>
      <PageHeader title={a.doc_no} sub={<>{a.doc_type_name} · gửi bởi {a.submitted_by_name} lúc {df(a.submitted_at, true)} <StatusPill map={DOC_STATUS} value={a.status} /></>}
        actions={<><Link className="btn" href="/duyet">← Hộp duyệt</Link>{href && <Link className="btn" href={href}>Mở chứng từ</Link>}</>} />
      <Flash ok={sp.ok} err={sp.err} />

      <ol className="card mb-4 flex flex-wrap gap-0 p-4" aria-label="Các bước duyệt">
        {steps.map((s) => {
          const st = stepState(s);
          const tone = st === 'done' ? 'border-ok text-ok' : st === 'cur' ? 'border-copper text-copper font-semibold' : st === 'rej' ? 'border-bad text-bad' : 'border-line text-muted';
          return (
            <li key={s.seq} className={`min-w-[150px] flex-1 border-t-4 px-2 pt-2 text-[12.5px] ${tone}`}>
              <div>{s.seq}. {s.label}</div>
              <div className="text-[11.5px] opacity-80">{ROLE_NAMES[s.role] ?? s.role}</div>
            </li>
          );
        })}
      </ol>

      <div className="grid gap-4 lg:grid-cols-[1.3fr_1fr]">
        <section className="card p-4">
          <h2 className="mb-2 font-semibold">Nội dung</h2>
          <p className="text-[13px]">{a.summary ?? '—'}</p>
          {a.my_turn ? (
            <form action={approve} className="mt-4 flex flex-col gap-3">
              <input type="hidden" name="id" value={a.id} />
              <label className="lbl">Ý kiến (bắt buộc khi trả lại)
                <textarea className="inp" id="comment" name="comment" rows={3} />
              </label>
              <div className="flex flex-wrap gap-2">
                <SubmitButton className="btn btn-ok" formAction={approve}>Phê duyệt</SubmitButton>
                <SubmitButton className="btn btn-bad" formAction={reject}>Trả lại</SubmitButton>
                <SubmitButton className="btn" formAction={comment}>Chỉ ghi ý kiến</SubmitButton>
              </div>
            </form>
          ) : a.status === 'PENDING' && (
            <p className="mt-4 text-[13px] text-muted">Đang chờ bước “{a.current_level}” ({ROLE_NAMES[a.current_role] ?? a.current_role}).</p>
          )}
        </section>
        <section className="card p-4">
          <h2 className="mb-2 font-semibold">Lịch sử</h2>
          {hist.length === 0 ? <p className="text-[13px] text-muted">Chưa có ý kiến.</p> : (
            <ul className="flex flex-col gap-2 text-[13px]">
              {hist.map((h, i) => (
                <li key={i} className="border-l-2 border-line pl-3">
                  <b>{h.actor ?? '—'}</b> · {h.action === 'APPROVE' ? 'Phê duyệt' : h.action === 'REJECT' ? 'Trả lại' : 'Ý kiến'} · <span className="text-muted">{df(h.at, true)}</span>
                  {h.comment && <div className="text-muted">“{h.comment}”</div>}
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>
    </>
  );
}
