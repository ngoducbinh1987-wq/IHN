import Link from 'next/link';
import { notFound } from 'next/navigation';
import { GuideFlow } from '@/components/guide-flow';
import { PrintButton } from '@/components/print-button';
import { Toolbar } from '@/components/ui';
import { GUIDES, guideBySlug } from '@/lib/huong-dan';
import { requireMe } from '@/lib/session';

export async function generateMetadata({ params }: { params: Promise<{ slug: string }> }) {
  const g = guideBySlug((await params).slug);
  return { title: g ? `Hướng dẫn – ${g.title}` : 'Hướng dẫn sử dụng' };
}

export default async function GuidePage({ params }: { params: Promise<{ slug: string }> }) {
  await requireMe();
  const g = guideBySlug((await params).slug);
  if (!g) notFound();
  const i = GUIDES.indexOf(g);
  const prev = GUIDES[i - 1], next = GUIDES[i + 1];
  return (
    <>
      <div className="text-[13px] text-muted print:hidden"><Link href="/huong-dan" className="link">Hướng dẫn sử dụng</Link> / {g.group}</div>
      <Toolbar title={g.title} actions={<PrintButton />} />
      <p className="mt-2 max-w-3xl text-[14px]">{g.intro}</p>
      <section className="card mt-4 p-3 md:p-4" id="luu-do">
        <GuideFlow steps={g.steps} />
      </section>
      {!!g.notes?.length && (
        <section className="card mt-4 p-4" id="luu-y">
          <h2 className="text-[15px] font-semibold">Lưu ý</h2>
          <ul className="mt-2 list-disc space-y-1 pl-5 text-[13.5px]">{g.notes.map((n) => <li key={n}>{n}</li>)}</ul>
        </section>
      )}
      <nav className="mt-4 flex flex-wrap justify-between gap-2 text-[14px] print:hidden" aria-label="Quy trình khác">
        {prev ? <Link href={`/huong-dan/${prev.slug}`} className="link">← {prev.title}</Link> : <span />}
        {next && <Link href={`/huong-dan/${next.slug}`} className="link">{next.title} →</Link>}
      </nav>
    </>
  );
}
