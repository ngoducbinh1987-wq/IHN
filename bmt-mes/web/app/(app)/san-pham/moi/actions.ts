'use server';

import { redirect } from 'next/navigation';
import { readParams } from '@/lib/spec';
import { createClient } from '@/lib/supabase/server';

export async function createSpec(form: FormData) {
  const tpl = String(form.get('template') ?? '');
  const fail = (m: string) => redirect(`/san-pham/moi?mau=${encodeURIComponent(String(form.get('template_code') ?? ''))}&err=${encodeURIComponent(m)}`);
  const p = readParams(form);
  if (typeof p === 'string') fail(p);
  const code = String(form.get('new_code') ?? '').trim();
  if (code !== code.toUpperCase()) fail(`Mã sản phẩm phải viết IN HOA (ví dụ PFR-2C-1P5): ${code}`);
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').rpc('create_spec', {
    p_code: code, p_group: String(form.get('group') ?? ''), p_description: String(form.get('description') ?? ''),
    p_template: tpl, p_params: p,
  });
  if (error) fail(error.message);
  redirect(`/san-pham/${encodeURIComponent(code)}?v=${data}&ok=` + encodeURIComponent(`Đã tạo ${code} (spec v1 nháp, BOM sao chép từ mã mẫu). Kiểm tra BOM rồi gửi duyệt.`));
}
