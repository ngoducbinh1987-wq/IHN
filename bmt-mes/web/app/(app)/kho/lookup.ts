'use server';

import { scanCode, locCode } from '@/lib/kho';
import { createClient } from '@/lib/supabase/server';

export type HuInfo = {
  id: string; hu_no: string; status: string; qty: number; reserved_qty: number; uom: string; item_kind: string; item_code: string;
  item_name: string; lot_no: string; qc_status: string; exp_date: string | null; warehouse_code: string | null; location_code: string | null;
  location_id: string | null; material_id: string | null; product_id: string | null; is_remnant: boolean; expired: boolean;
};
export type LocInfo = { id: string; code: string; name: string | null; warehouse_code: string };

// Tra mã QR đơn vị chứa (dùng cho ô quét trên tablet/điện thoại)
export async function lookupHu(raw: string): Promise<{ hu?: HuInfo; error?: string }> {
  const code = scanCode(raw);
  if (!code) return { error: 'Chưa có mã' };
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').from('v_hu')
    .select('id, hu_no, status, qty, reserved_qty, uom, item_kind, item_code, item_name, lot_no, qc_status, exp_date, warehouse_code, location_code, location_id, material_id, product_id, is_remnant, expired')
    .eq('hu_no', code).maybeSingle();
  if (error) return { error: error.message };
  if (!data) return { error: `Không tìm thấy mã ${code}` };
  return { hu: { ...data, qty: Number(data.qty), reserved_qty: Number(data.reserved_qty) } as HuInfo };
}

export async function lookupLocation(raw: string): Promise<{ loc?: LocInfo; error?: string }> {
  const code = locCode(raw);
  if (!code) return { error: 'Chưa có mã vị trí' };
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').from('v_locations').select('id, code, name, active, warehouse_code').eq('code', code).maybeSingle();
  if (error) return { error: error.message };
  if (!data || !data.active) return { error: `Không có vị trí ${code}` };
  return { loc: { id: data.id, code: data.code, name: data.name, warehouse_code: data.warehouse_code } };
}
