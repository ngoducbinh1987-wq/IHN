import { parseNum } from './format';

// Thông số spec người dùng sửa được (khớp app.update_spec_draft)
export const SPEC_FIELDS = ['core_code', 'cores', 'pairs', 'insulation', 'sheath', 'ins_thickness_mm', 'sheath_thickness_mm', 'lay_factor',
  'conductor_mat', 'wire_dia_mm', 'wire_count', 'pitch_mm', 'drain_mat', 'brand', 'pack_type', 'm_per_pack', 'sheath_color',
  'insulation_colors', 'config_note', 'sheath_kgkm', 'pp_kgkm', 'pet_kgkm', 'alpet_kgkm', 'drain_kgkm', 'od_mm', 'description'] as const;
const NUMERIC = new Set(['cores', 'pairs', 'ins_thickness_mm', 'sheath_thickness_mm', 'lay_factor', 'wire_dia_mm', 'wire_count', 'pitch_mm',
  'm_per_pack', 'sheath_kgkm', 'pp_kgkm', 'pet_kgkm', 'alpet_kgkm', 'drain_kgkm', 'od_mm']);

// Đọc form thông số; số theo kiểu Việt Nam (0,75) đổi sang dạng máy
export function readParams(form: FormData): Record<string, string> | string {
  const out: Record<string, string> = {};
  for (const f of SPEC_FIELDS) {
    const raw = form.get(f);
    if (raw === null || String(raw).trim() === '') continue;
    if (NUMERIC.has(f)) {
      const n = parseNum(raw);
      if (n === null || Number.isNaN(n) || n < 0) return `Giá trị "${f}" không hợp lệ`;
      out[f] = String(n);
    } else out[f] = String(raw).trim();
  }
  return out;
}
