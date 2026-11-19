// Danh mục nhà cung cấp (migration 10300). Quyền do database kiểm lại; ở đây chỉ để ẩn/hiện nút.
export type Supplier = {
  id: string; code: string; name: string; tax_code: string | null; contact: string | null; phone: string | null; email: string | null;
  address: string | null; payment_terms: string | null; note: string | null; active: boolean; inactive_reason: string | null;
  inactive_at: string | null; inactive_by_name: string | null; created_at: string; created_by_name: string | null; updated_at: string;
  shared: boolean; material_count: number; po_count: number; open_count: number; last_order_date: string | null;
};
export type SupplierMaterial = {
  supplier_id: string; material_id: string; material_code: string; material_name: string; uom: string; group_code: string | null;
  group_name: string | null; po_count: number; qty: number | null; received_qty: number | null; last_order_date: string | null;
  last_po_no: string | null; last_po_id: string | null; supplier_item_code: string | null; last_price: number | null;
};
export type MaterialOption = { id: string; code: string; name: string; uom: string; group_name: string | null };

// Thêm mới, ngừng dùng / dùng lại, khai báo mặt hàng: chỉ TP Mua (Quản trị có mọi quyền)
export const isBuyLead = (roles: string[]) => roles.includes('MUA_TP') || roles.includes('ADMIN');
// Sửa thông tin: NV mua, TP Mua
export const canEditSupplier = (roles: string[]) => roles.includes('MUA_NV') || isBuyLead(roles);

// Gom vật tư theo nhóm để tick mặt hàng
export function groupMaterials(mats: MaterialOption[]): { name: string; items: MaterialOption[] }[] {
  const by = new Map<string, MaterialOption[]>();
  for (const m of mats) {
    const g = m.group_name ?? 'Khác';
    if (!by.has(g)) by.set(g, []);
    by.get(g)!.push(m);
  }
  return [...by.entries()].map(([name, items]) => ({ name, items }));
}

// Nhãn các trường trong lịch sử thay đổi
export const SUPPLIER_FIELDS: Record<string, string> = {
  name: 'Tên', tax_code: 'Mã số thuế', contact: 'Người liên hệ', phone: 'Điện thoại', email: 'Email', address: 'Địa chỉ',
  payment_terms: 'Điều khoản thanh toán', note: 'Ghi chú', inactive_reason: 'Lý do ngừng dùng',
};
