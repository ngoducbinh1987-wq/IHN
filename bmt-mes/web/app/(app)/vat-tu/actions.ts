'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { parseNum } from '@/lib/format';
import { createClient } from '@/lib/supabase/server';

export async function saveTerms(form: FormData) {
  const code = String(form.get('code'));
  const fields = {
    moq: parseNum(form.get('moq')) ?? 0,
    pack_multiple: parseNum(form.get('pack_multiple')) ?? 1,
    lead_time_days: parseNum(form.get('lead_time_days')) ?? 0,
    unit_price: parseNum(form.get('unit_price')),
  };
  const bad = Object.entries(fields).find(([, v]) => Number.isNaN(v) || (v !== null && v < 0));
  if (bad) redirect('/vat-tu?err=' + encodeURIComponent(`${code}: giá trị "${bad[0]}" không hợp lệ`));
  if (fields.pack_multiple <= 0) redirect('/vat-tu?err=' + encodeURIComponent(`${code}: bội số mua phải lớn hơn 0`));

  const supabase = await createClient();
  const { data, error } = await supabase.schema('master').from('material_suppliers').update({
    ...fields,
    lead_time_days: Math.round(fields.lead_time_days),
    supplier_item_code: String(form.get('supplier_item_code') ?? '').trim() || null,
  }).eq('id', String(form.get('terms_id'))).select('material_id').single();
  if (error) redirect('/vat-tu?err=' + encodeURIComponent(`${code}: ${error.message}`));
  if (fields.unit_price !== null && data) {
    await supabase.schema('master').from('price_history')
      .insert({ material_id: data.material_id, price: fields.unit_price, source: 'Màn hình Vật tư' });
  }
  revalidatePath('/vat-tu');
  redirect('/vat-tu?ok=' + encodeURIComponent(`Đã lưu điều kiện mua ${code}`));
}
