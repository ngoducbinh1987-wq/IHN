import Link from 'next/link';
import { notFound } from 'next/navigation';
import { Flash, Toolbar } from '@/components/ui';
import { type ReqType } from '@/lib/requests';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { RequestForm } from '../request-form';

export const metadata = { title: 'Lập đề xuất' };

export default async function NewRequest({ searchParams }: { searchParams: Promise<{ loai?: string; err?: string }> }) {
  const sp = await searchParams;
  const me = await requireMe();
  const db = await createClient();
  const { data: t } = await db.schema('app').from('v_request_types').select('*').eq('code', sp.loai ?? '').maybeSingle<ReqType>();
  if (!t) notFound();
  const forWorker = me.is_admin || me.roles.some((r) => ['TO_TRUONG', 'SX_TP', 'SX_KH', 'HCNS'].includes(r));
  const [{ data: workers }, { data: machines }, { data: mats }] = await Promise.all([
    forWorker ? db.schema('app').from('v_kh_operators').select('code, full_name').eq('active', true).order('code') : Promise.resolve({ data: [] }),
    t.form === 'REPAIR' ? db.schema('app').from('v_machines').select('code, name').order('code') : Promise.resolve({ data: [] }),
    t.form === 'BUY' ? db.schema('app').from('v_materials').select('code, name, uom').order('code') : Promise.resolve({ data: [] }),
  ]);
  return (
    <>
      <Toolbar title={`Lập đề xuất: ${t.name}`} actions={<Link href="/de-xuat-chung?tab=lap" className="btn">Chọn loại khác</Link>} />
      <div className="mt-4"><Flash err={sp.err} /></div>
      <RequestForm t={t} back={`/de-xuat-chung/moi?loai=${t.code}`}
        workers={(workers ?? []).map((w: { code: string; full_name: string | null }) => ({ code: w.code, name: w.full_name }))}
        machines={(machines ?? []) as { code: string; name: string | null }[]}
        mats={(mats ?? []) as { code: string; name: string | null; uom: string | null }[]} />
    </>
  );
}
