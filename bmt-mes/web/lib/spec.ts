import { parseNum } from './format';

// Thông số spec người dùng sửa được (khớp app.update_spec_draft)
export const SPEC_FIELDS = ['core_code', 'cores', 'pairs', 'insulation', 'sheath', 'ins_thickness_mm', 'sheath_thickness_mm', 'lay_factor',
  'conductor_mat', 'pitch_mm', 'drain_mat', 'brand', 'pack_type', 'm_per_pack', 'sheath_color',
  'config_note', 'sheath_kgkm', 'pp_kgkm', 'pet_kgkm', 'alpet_kgkm', 'drain_kgkm', 'od_mm', 'description'] as const;
const NUMERIC = new Set(['cores', 'pairs', 'ins_thickness_mm', 'sheath_thickness_mm', 'lay_factor', 'pitch_mm',
  'm_per_pack', 'sheath_kgkm', 'pp_kgkm', 'pet_kgkm', 'alpet_kgkm', 'drain_kgkm', 'od_mm']);
const LABEL: Record<string, string> = {
  cores: 'Số lõi', pairs: 'Số cặp', ins_thickness_mm: 'Chiều dày cách điện', sheath_thickness_mm: 'Chiều dày vỏ', lay_factor: 'Hệ số ghép K',
  pitch_mm: 'Bước bện', m_per_pack: 'Mét / kiện', sheath_kgkm: 'Định mức vỏ', pp_kgkm: 'Định mức độn PP', pet_kgkm: 'Định mức băng PET',
  alpet_kgkm: 'Định mức băng AL/PET', drain_kgkm: 'Định mức drain', od_mm: 'OD cáp',
};

/** Số loại sợi tối đa của một ruột dẫn, số dòng màu lõi tối đa trên form */
export const WIRE_ROWS = 4;
export const MAX_CORES = 24;

export type WireMix = { n: number; d: number }[];

/** Các loại sợi của spec; dữ liệu cũ chưa có wire_mix thì lấy một loại từ wire_count × wire_dia_mm */
export function wireMix(s: Record<string, unknown>): WireMix {
  const raw = s.wire_mix;
  if (Array.isArray(raw) && raw.length) return raw.map((r) => ({ n: Number((r as { n: unknown }).n), d: Number((r as { d: unknown }).d) }));
  if (s.wire_count && s.wire_dia_mm) return [{ n: Number(s.wire_count), d: Number(s.wire_dia_mm) }];
  return [];
}

/** "16×0,24 + 3×0,30 mm" */
export function wireText(s: Record<string, unknown>): string {
  return wireMix(s).map((w) => `${w.n}×${String(w.d).replace('.', ',')}`).join(' + ') + ' mm';
}

// Đọc form thông số; số theo kiểu Việt Nam (0,75) đổi sang dạng máy
export function readParams(form: FormData): Record<string, unknown> | string {
  const out: Record<string, unknown> = {};
  for (const f of SPEC_FIELDS) {
    const raw = form.get(f);
    if (raw === null || String(raw).trim() === '') continue;
    if (NUMERIC.has(f)) {
      const n = parseNum(raw);
      if (n === null || Number.isNaN(n) || n < 0) return `${LABEL[f] ?? f} không hợp lệ`;
      out[f] = String(n);
    } else out[f] = String(raw).trim();
  }
  // Các loại sợi của ruột dẫn
  if (form.has('wire_n_0')) {
    const mix: WireMix = [];
    for (let i = 0; i < WIRE_ROWS; i++) {
      const rn = String(form.get(`wire_n_${i}`) ?? '').trim(); const rd = String(form.get(`wire_d_${i}`) ?? '').trim();
      if (!rn && !rd) continue;
      const n = parseNum(rn); const d = parseNum(rd);
      if (n === null || Number.isNaN(n) || n < 1 || !Number.isInteger(n)) return `Sợi loại ${i + 1}: số sợi phải là số nguyên ≥ 1`;
      if (d === null || Number.isNaN(d) || d <= 0 || d > 5) return `Sợi loại ${i + 1}: đường kính sợi phải lớn hơn 0 và không quá 5 mm`;
      mix.push({ n, d });
    }
    if (!mix.length) return 'Khai ít nhất một loại sợi (số sợi, đường kính)';
    out.wire_mix = mix;
  }
  // Màu cách điện từng lõi
  if (form.has('color_0')) {
    const colors: string[] = [];
    for (let i = 0; i < MAX_CORES && form.has(`color_${i}`); i++) colors.push(String(form.get(`color_${i}`) ?? '').trim());
    out.core_colors = colors;
  }
  return out;
}
