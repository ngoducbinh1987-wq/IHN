'use server';

import { redirect } from 'next/navigation';
import { parseNum } from '@/lib/format';
import { createClient } from '@/lib/supabase/server';

export async function createMaterial(form: FormData) {
  const fail = (m: string) => redirect('/vat-tu/moi?err=' + encodeURIComponent(m));
  const nums = {
    loss: parseNum(form.get('loss')), moq: parseNum(form.get('moq')), multiple: parseNum(form.get('multiple')),
    lead: parseNum(form.get('lead')), price: parseNum(form.get('price')),
  };
  const bad = Object.entries(nums).find(([, v]) => Number.isNaN(v) || (v !== null && v < 0));
  if (bad) fail(`Giá trị "${bad[0]}" không hợp lệ`);
  if (nums.loss !== null && nums.loss >= 100) fail('Hao hụt phải dưới 100%');
  const code = String(form.get('code') ?? '').trim().toUpperCase();
  const supabase = await createClient();
  const { error } = await supabase.schema('app').rpc('create_material', {
    p_code: code, p_name: String(form.get('name') ?? ''), p_group: String(form.get('group') ?? ''), p_uom: String(form.get('uom') ?? 'kg'),
    p_loss: (nums.loss ?? 0) / 100, p_purchase_spec: String(form.get('purchase_spec') ?? ''),
    p_moq: nums.moq ?? 0, p_multiple: nums.multiple ?? 1, p_lead_days: Math.round(nums.lead ?? 0), p_price: nums.price,
  });
  if (error) fail(error.message);
  redirect(`/vat-tu?q=${encodeURIComponent(code)}&ok=` + encodeURIComponent(`Đã thêm vật tư ${code}`));
}
