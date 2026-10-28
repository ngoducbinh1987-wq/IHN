import Link from 'next/link';
import { Flash, Toolbar } from '@/components/ui';
import { PlanForm } from '@/components/maint-plan-form';
import { requirePage, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';

export const metadata = { title: 'Thêm kế hoạch bảo dưỡng' };

export default async function NewPlan({ searchParams }: { searchParams: Promise<{ may?: string; err?: string }> }) {
  const sp = await searchParams;
  await requirePage('may-bao-duong');
  await requirePerm('machine', 'config');
  const supabase = await createClient();
  const [{ data: machines }, { data: remind }] = await Promise.all([
    supabase.schema('app').from('v_machines').select('id, code, name, unit_kind, line_id, seq').eq('active', true).order('code'),
    supabase.schema('app').from('v_machine_settings').select('value').eq('key', 'remind_days').maybeSingle(),
  ]);
  return (
    <>
      <Toolbar title="Thêm kế hoạch bảo dưỡng" actions={<Link className="btn" href={sp.may ? `/may/${sp.may}?tab=bao-duong` : '/may/bao-duong'}>Đóng</Link>} />
      <div className="mt-4" />
      <Flash err={sp.err} />
      <p className="mb-4 max-w-4xl text-[13.5px] text-muted">Khai báo theo sổ tay bảo dưỡng của nhà sản xuất. Hệ thống tự nhắc trên Thông báo cho TP Kỹ thuật/QA và Quản lý SX trước khi đến hạn; quá hạn báo thêm Giám đốc.</p>
      <PlanForm machines={machines ?? []} machineId={sp.may} remind={remind?.value ?? { MINOR: 7, MAJOR: 30 }} back={`/may/bao-duong/ke-hoach/moi${sp.may ? `?may=${sp.may}` : ''}`} />
    </>
  );
}
