'use server';

import { errText } from '@/lib/kho';
import { createClient } from '@/lib/supabase/server';

// Ghi nhận đã in tem (đếm số lần in; in lại phải có lý do – lưu nhật ký)
export async function markPrinted(ids: string[], reason: string): Promise<{ error?: string }> {
  if (!ids.length) return {};
  const supabase = await createClient();
  const { error } = await supabase.schema('inv').rpc('mark_printed', { p_hus: ids, p_reason: reason.trim() || null });
  return error ? { error: errText(error.message) } : {};
}
