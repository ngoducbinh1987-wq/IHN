"""Sinh migration dữ liệu khởi tạo từ file Excel BMT_Du_tru_vat_tu_san_xuat (bản 3.0).

Cách dùng:
    python3 -I tools/gen_seed.py <file.xlsx> supabase/migrations

Sinh nhiều file 202610250010NN_seed_*.sql (mỗi file < 60 KB để gửi được qua Supabase MCP/SQL editor).

Nạp: thương hiệu + pháp nhân, 51 vật tư + điều kiện mua mặc định, bộ tham số v1 (59 tham số, 10 mã lõi),
78 SKU, spec v1 (trạng thái Nháp như file: "Chưa duyệt"), kết quả định mức, BOM v1 (suất + phế khởi động/lô).
"""
import sys

import openpyxl

SRC, OUT_DIR = sys.argv[1], sys.argv[2]
files = []  # (tên, nội dung)
wb = openpyxl.load_workbook(SRC, data_only=True)


def rows(ws, r0, r1, ncol):
    return [list(r) for r in wb[ws].iter_rows(min_row=r0, max_row=r1, max_col=ncol, values_only=True)]


def q(v):
    if v is None or v == "":
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(round(v, 10)) if isinstance(v, float) else str(v)
    return "'" + str(v).replace("'", "''") + "'"


out = ["-- BMT MES · 1000 · Dữ liệu khởi tạo từ file Excel bản 3.0 (24/10/2026) — sinh bởi tools/gen_seed.py",
       "-- Không sửa tay: chạy lại script khi file Excel thay đổi.", ""]

# --------------------------------------------------------------------------- thương hiệu
out += [
    "insert into core.partners (code, name, is_customer, is_brand_entity, partner_type) values",
    "  ('KAVIX','KAVIX (pháp nhân thương hiệu)',true,true,'BRAND_ENTITY'),",
    "  ('HEIZKA','HEIZKA (pháp nhân thương hiệu)',true,true,'BRAND_ENTITY');",
    "",
]

# --------------------------------------------------------------------------- vật tư
ns = wb["Nguon_spec"]
mh = next(r for r in range(100, 140) if ns.cell(r, 1).value == "Mã vật tư")
mats = [r for r in rows("Nguon_spec", mh + 1, 167, 10) if r[0]]


def mat_group(code):
    if code.startswith(("CU-", "TC-", "TCCA")):
        return "CONDUCTOR"
    if code in ("SIL-9710G", "HDPE-I", "PVC-I", "PVC-FR", "LSZH-S", "PVC-S"):
        return "COMPOUND"
    if code in ("DCBP-50", "SIL-ADD", "TALC"):
        return "ADDITIVE"
    if code.startswith(("ALP-", "PET-", "PP-FILL")):
        return "TAPE_FILLER"
    if code in ("INK", "SOLVENT", "PURGE"):
        return "PRINT_CLEAN"
    if code in ("REEL-W", "PE-PACK", "PP-STRAP", "LABEL-K", "LABEL-H", "END-TAPE", "PALLET"):
        return "PACK"
    return "COLOR"


EXPIRY = {"SIL-9710G", "DCBP-50", "SIL-ADD", "INK"}
COA = {"CU-024", "TC-020", "TC-024", "TCCA-020", "SIL-9710G", "HDPE-I", "PVC-I", "PVC-FR", "LSZH-S", "PVC-S", "DCBP-50", "ALP-20", "ALP-25", "ALP-40", "ALP-60"}

out.append("insert into master.materials (code, name, group_code, purchase_spec, uom, loss_rate, has_expiry, requires_coa, check_note, data_note) values")
out.append(",\n".join(
    f"  ({q(m[0])},{q(m[1])},{q(mat_group(m[0]))},{q(m[2])},{q(m[3])},{q(m[4] or 0)},{q(m[0] in EXPIRY)},{q(m[0] in COA)},{q(m[8])},{q(m[9])})"
    for m in mats) + ";")
out.append("")
# Điều kiện mua mặc định (chưa gắn NCC): MOQ, bội số, lead time từ file; giá để trống (≠ 0)
out.append("insert into master.material_suppliers (material_id, supplier_id, moq, pack_multiple, lead_time_days, unit_price, is_preferred)")
out.append("select m.id, null, v.moq, v.mul, v.lt, null, true from (values")
out.append(",\n".join(f"  ({q(m[0])},{q(m[5] or 0)}::numeric,{q(m[6] or 1)}::numeric,{q(int(m[7] or 0))}::int)" for m in mats))
out.append(") v(code, moq, mul, lt) join master.materials m on m.code = v.code;")
out.append("")
out += [
    "insert into core.brands (code, name, owner_partner_id, label_material)",
    "select 'KAVIX','KAVIX', id, 'LABEL-K' from core.partners where code = 'KAVIX'",
    "union all select 'HEIZKA','HEIZKA', id, 'LABEL-H' from core.partners where code = 'HEIZKA';",
    "",
]

# --------------------------------------------------------------------------- tham số
ts = [r for r in rows("Tham_so", 9, 67, 5) if r[0]]
out.append("insert into master.tech_param_sets (version, status, note, released_at) values (1, 'RELEASED', 'Nhập từ Excel bản 3.0 (24/10/2026)', now());")
out.append("insert into master.tech_params (set_id, code, name, value, unit, basis, confirmed)")
out.append("select s.id, v.code, v.name, v.value, v.unit, v.basis, v.confirmed from master.tech_param_sets s, (values")
vals = []
for r in ts:
    basis = str(r[4] or "")
    tentative = any(k in basis.lower() for k in ("tạm tính", "chưa có", "chưa xác nhận", "giả định", "phải xác nhận", "xác nhận theo"))
    vals.append(f"  ({q(r[0])},{q(r[1])},{q(float(r[2]))}::numeric,{q(r[3])},{q(basis)},{q(not tentative)})")
out.append(",\n".join(vals))
out.append(") v(code, name, value, unit, basis, confirmed) where s.version = 1;")
out.append("")

cores = [r[7:26] for r in rows("Tham_so", 9, 18, 26) if r[7]]
out.append("insert into master.core_types (set_id, code, nominal_mm2, wire_count, wire_dia_mm, fill_factor, silicone_mm, sheath_mm, rdc_limit, hdpe_mm, pvc_single_mm, pitch_override_mm, pitch_mm, tc020_wires, tc024_wires, drain_wires, drain_pitch_mm)")
out.append("select s.id, v.* from master.tech_param_sets s, (values")
out.append(",\n".join(
    "  (" + ",".join([q(c[0]), q(c[1]) + "::numeric", q(c[2]) + "::int", q(c[3]) + "::numeric", q(c[4]) + "::numeric",
                      q(c[5]) + "::numeric", q(c[6]) + "::numeric", q(c[7]) + "::numeric", q(c[8]) + "::numeric",
                      q(c[9]) + "::numeric", q(c[10]) + "::numeric", q(c[11]) + "::numeric", q(c[12]) + "::int",
                      q(c[13]) + "::int", q(c[14]) + "::int", q(c[15]) + "::numeric"]) + ")"
    for c in cores))
out.append(") v where s.version = 1;")
out.append("")

files.append(("master_data", out)); out = []
# --------------------------------------------------------------------------- sản phẩm + spec v1
tk = rows("Thiet_ke", 9, 86, 36)
dm = rows("Dinh_muc", 9, 86, 43)
csl = rows("Chon_san_luong", 9, 86, 18)
assert [r[0] for r in tk] == [r[0] for r in dm] == [r[0] for r in csl]

out.append("insert into master.products (code, group_code, description, default_brand, default_pack, default_m_per_pack) values")
out.append(",\n".join(
    f"  ({q(t[0])},{q(t[0].split('-')[0])},{q(t[2])},{q(c[3])},{q(c[8])},{q(c[7])})" for t, c in zip(tk, csl)) + ";")
out.append("")

SHEATH = {"FR-PVC": "FR-PVC", "LSZH": "LSZH", "PVC": "PVC", "Không": "Không"}
spec_cols = ("product_id, version, status, change_level, param_set_id, core_code, cores, pairs, insulation, sheath, "
             "ins_thickness_mm, sheath_thickness_mm, bundle_factor, lay_factor, pp_filler, pet_tape, shield, alpet_width_mm, "
             "conductor_mat, wire_dia_mm, wire_count, pitch_mm, drain_mat, drain_dia_mm, drain_wires, drain_pitch_mm, "
             "sheath_color, insulation_colors, brand, pack_type, m_per_pack, source_basis, config_note")
out.append(f"insert into master.product_specs ({spec_cols})")
out.append("select p.id, 1, 'DRAFT', 'NEW', s.id, v.core_code, v.cores, v.pairs, v.ins, v.sheath, v.ti, v.tj, v.bf, v.lf, v.pp, v.pet, v.sh, v.alw,")
out.append("       v.cm, v.wd, v.wc, v.pitch, v.dm, v.dd, v.dw, v.dp, v.sc, v.ic, v.brand, v.pack, v.mpp, v.basis, v.note")
out.append("from master.tech_param_sets s, (values")
vals = []
for t, d, c in zip(tk, dm, csl):
    vals.append("  (" + ",".join([
        q(t[0]), q(t[3]), q(int(t[4])), q(int(t[5])), q(t[6]), q(SHEATH[d[5]]),
        q(t[8]) + "::numeric", q(d[19]) + "::numeric", q(t[10]) + "::numeric", q(t[11]) + "::numeric",
        q(t[12] or 0) + "::numeric", q(bool(t[13])), q(bool(t[14])), q(t[15]) + "::numeric",
        q(t[18]), q(t[19]) + "::numeric", q(int(t[20])), q(t[23]) + "::numeric",
        q(t[25]), q(t[26] or None) + "::numeric", q(int(t[27] or 0)), q(t[29] or None) + "::numeric",
        q(t[33]), q(t[34]), q(c[3]), q(c[8]), q(c[7]) + "::numeric", q(t[17]), q(t[32])]) + ")")
out.append(",\n".join(vals))
out.append(") v(code, core_code, cores, pairs, ins, sheath, ti, tj, bf, lf, pp, pet, sh, alw, cm, wd, wc, pitch, dm, dd, dw, dp, sc, ic, brand, pack, mpp, basis, note)")
out.append("join master.products p on p.code = v.code where s.version = 1;")
out.append("")

# Kết quả định mức (Dinh_muc) — giá trị file, sau đó master.calc_spec tính lại phần lõi
out.append("insert into master.spec_results (spec_id, a_total_mm2, bundle_dia_mm, core_dia_mm, cable_bundle_mm, od_mm, metal_kgkm, ins_kgkm, sheath_kgkm, pp_kgkm, pet_kgkm, alpet_kgkm, drain_kgkm, total_kgkm, rdc_calc, rdc_limit, tech_check)")
out.append("select sp.id, v.a, v.db, v.dc, v.dbc, v.od, v.metal, v.ins, v.sheath, v.pp, v.pet, v.alpet, v.drain, v.total, v.rdc, v.lim, v.chk from (values")
out.append(",\n".join("  (" + ",".join([q(d[0])] + [q(d[i]) + "::numeric" for i in (12, 13, 15, 17, 21, 22, 23, 24, 25, 26, 27, 28, 35, 29, 30)] + [q(d[31])]) + ")" for d in dm))
out.append(") v(code, a, db, dc, dbc, od, metal, ins, sheath, pp, pet, alpet, drain, total, rdc, lim, chk)")
out.append("join master.products p on p.code = v.code join master.product_specs sp on sp.product_id = p.id and sp.version = 1;")
out.append("")
out.append("update master.products p set current_spec_id = sp.id from master.product_specs sp where sp.product_id = p.id and sp.version = 1;")
out.append("insert into master.bom_headers (spec_id, status, note) select id, 'DRAFT', 'BOM v1 từ BOM_chi_tiet (Excel 3.0)' from master.product_specs where version = 1;")
out.append("")

files.append(("products_specs", out)); out = []
# --------------------------------------------------------------------------- BOM
P = {r[0]: float(r[2]) for r in ts}
INS = {"SIL-9710G", "DCBP-50", "SIL-ADD", "SI-C0", "SI-C1", "SI-C2", "SI-C3", "SI-C4", "SI-W",
       "HDPE-I", "HD-C0", "HD-C1", "HD-W", "HD-B", "PVC-I", "PI-C0", "PI-C1", "PI-C2", "PI-C3", "PI-C4"}
SHE = {"LSZH-S", "LS-G", "LS-O", "PVC-FR", "PF-G", "PF-O", "PVC-S", "PV-G", "PV-O", "PV-GR"}


def op_of(code):
    if code.startswith(("CU-", "TC-")):
        return "CD1"
    if code in ("SIL-9710G", "DCBP-50", "SIL-ADD") or code.startswith("SI-"):
        return "CD0"
    if code in ("HDPE-I", "PVC-I") or code.startswith(("HD-", "PI-")):
        return "CD2"
    if code in ("PP-FILL", "PET-20"):
        return "CD3"
    if code.startswith(("ALP-", "TCCA")):
        return "CD4"
    if code in SHE or code in ("TALC", "INK", "SOLVENT", "PURGE"):
        return "CD5"
    return "CD6"


dmap = {d[0]: d for d in dm}
bom = rows("BOM_chi_tiet", 9, 2806, 11)
lines = []
for r in bom:
    sku, code, uom, d_rate, basis_txt = r[0], r[1], r[2], r[3] or 0, str(r[10] or "")
    d = dmap[sku]
    cores_n, ins_kgkm, sheath_kgkm, ins_type, sheath = d[2], d[23] or 0, d[24] or 0, d[4], d[5]
    start = 0.0
    if code in INS and ins_kgkm:
        per = {"SIL": P["startSi"], "HDPE": P["startHD"]}.get(ins_type, P["startPI"])
        start = d_rate * cores_n * per / ins_kgkm
    elif code in SHE and sheath_kgkm and sheath != "Không":
        start = d_rate * P["startJ"] / sheath_kgkm
    elif code == "PURGE":
        start = P["purge"]
    if not d_rate and not start:
        continue
    basis = "PALLET" if "pallet" in basis_txt.lower() else ("PACK" if "kiện" in basis_txt.lower() else "KM")
    lines.append(f"  ({q(sku)},{q(code)},{q(basis)},{q(float(d_rate))}::numeric,{q(round(start, 8))}::numeric,{q(op_of(code))})")

CHUNK = 350
for i in range(0, len(lines), CHUNK):
    out = [f"-- BOM v1, dòng {i + 1}–{min(i + CHUNK, len(lines))}/{len(lines)}",
           "insert into master.bom_lines (bom_id, material_id, basis, qty_per_basis, loss_rate, startup_per_lot, operation_code)",
           "select h.id, m.id, v.basis, v.rate, m.loss_rate, v.start, v.op from (values",
           ",\n".join(lines[i:i + CHUNK]),
           ") v(sku, mat, basis, rate, start, op)",
           "join master.products p on p.code = v.sku join master.product_specs sp on sp.product_id = p.id and sp.version = 1",
           "join master.bom_headers h on h.spec_id = sp.id join master.materials m on m.code = v.mat;"]
    files.append((f"bom_{i // CHUNK + 1}", out))
files.append(("calc_specs", ["-- Tính lại phần lõi bằng bộ tính trong DB (phải khớp file)",
                             "select master.calc_spec(id) from master.product_specs where version = 1;"]))

import os
for n, (name, body) in enumerate(files):
    path = os.path.join(OUT_DIR, f"2026102500{10 + n:02d}00_seed_{name}.sql")
    head = [] if n == 0 else ["-- BMT MES · Dữ liệu khởi tạo từ Excel bản 3.0 — sinh bởi tools/gen_seed.py", ""]
    open(path, "w").write("\n".join(head + body) + "\n")
    print(path, os.path.getsize(path))
print(f"{len(mats)} vật tư, {len(ts)} tham số, {len(cores)} mã lõi, {len(tk)} SKU, {len(lines)} dòng BOM")
