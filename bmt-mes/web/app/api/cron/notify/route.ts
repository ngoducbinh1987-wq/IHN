import { NextResponse, type NextRequest } from 'next/server';
import { flushEmailOutbox } from '@/lib/notify';
import { createAdminClient } from '@/lib/supabase/server';

export const dynamic = 'force-dynamic';

// Job máy chủ (pg_cron + pg_net gọi 10 phút/lần, hoặc bất kỳ bộ lập lịch nào): tạo cảnh báo quá hạn rồi gửi email trong hàng đợi.
// Không phụ thuộc trình duyệt người dùng. Bảo vệ bằng CRON_SECRET (header Authorization: Bearer <CRON_SECRET>).
async function run(req: NextRequest) {
  const secret = process.env.CRON_SECRET;
  if (!secret || req.headers.get('authorization') !== `Bearer ${secret}`) {
    return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  }
  const { data: alerts, error } = await createAdminClient().schema('wf').rpc('check_sla');
  const mail = await flushEmailOutbox();
  return NextResponse.json({ alerts: alerts ?? 0, sla_error: error?.message ?? null, ...mail });
}

export const GET = run;
export const POST = run;
