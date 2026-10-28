import { NextResponse, type NextRequest } from 'next/server';
import { replanDue } from '@/lib/kh/replan';
import { createAdminClient } from '@/lib/supabase/server';

export const dynamic = 'force-dynamic';
export const maxDuration = 60;

// Job máy chủ (pg_cron bmt_replan 10 phút/lần gọi khi có kế hoạch đến lượt): 1 giờ sau khi hết ca, tính lại tiến độ theo sản lượng
// thực tế, xếp lại lịch máy, báo Giám đốc / TP SX. Bảo vệ bằng CRON_SECRET (header Authorization: Bearer <CRON_SECRET>).
async function run(req: NextRequest) {
  const secret = process.env.CRON_SECRET;
  if (!secret || req.headers.get('authorization') !== `Bearer ${secret}`) {
    return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  }
  try {
    const out = await replanDue(createAdminClient(), ['BGD']);
    return NextResponse.json({ runs: out });
  } catch (e) {
    return NextResponse.json({ error: e instanceof Error ? e.message : String(e) }, { status: 500 });
  }
}

export const GET = run;
export const POST = run;
