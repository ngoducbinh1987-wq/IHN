// Thông số spec theo thứ tự sản xuất: 1 Ruột dẫn → 2 Dây đơn (lõi cách điện) → 3 Dây hoàn thiện.
// Dùng chung cho "Thêm spec mới", "Sửa spec" và chế độ chỉ xem (ro). Mọi vật liệu đi kèm định mức theo km cáp.
import { nf } from '@/lib/format';
import { MAX_CORES, WIRE_ROWS, wireMix } from '@/lib/spec';

type Vals = Record<string, unknown>;
export type SpecBomLine = {
  id: string; operation_code: string | null; material_code: string; material_name: string; uom: string;
  basis: string; qty_per_basis: number; loss_rate: number;
};

const COLORS = ['Nâu', 'Trắng', 'Đen', 'Xám', 'Xanh dương', 'Đỏ', 'Vàng', 'Xanh lá', 'Vàng-xanh lá', 'Cam', 'Tím', 'Hồng'];
const R = { textAlign: 'right' as const };
const G4 = 'grid grid-cols-2 gap-x-4 gap-y-3 md:grid-cols-4';

const v = (x: Vals, k: string) => {
  const raw = x[k] === null || x[k] === undefined ? '' : String(x[k]);
  return /^-?\d+(\.\d+)?$/.test(raw) ? raw.replace('.', ',') : raw;   // số hiển thị kiểu Việt Nam: 0,75
};
const num = (x: unknown) => (x === null || x === undefined || x === '' ? null : Number(x));

function Lbl({ label, unit, req }: { label: string; unit?: string; req?: boolean }) {
  return <span className={`truncate whitespace-nowrap ${req ? 'req' : ''}`}>{label}{unit && <span className="text-[12px]"> ({unit})</span>}</span>;
}
function Sel({ name, label, opts, d }: { name: string; label: string; opts: string[]; d: string }) {
  const list = d && !opts.includes(d) ? [d, ...opts] : opts;
  return (
    <label className="lbl min-w-0"><Lbl label={label} />
      <select className="inp" name={name} defaultValue={d}>{list.map((o) => <option key={o}>{o}</option>)}</select>
    </label>
  );
}
function Num({ name, label, d, unit }: { name: string; label: string; d: string; unit?: string }) {
  return (
    <label className="lbl min-w-0"><Lbl label={label} unit={unit} />
      <input className="inp text-right tabular-nums" name={name} defaultValue={d} inputMode="decimal" />
    </label>
  );
}
/** Ô chỉ đọc (số MES tính), cùng kích thước ô nhập để thẳng hàng */
function Calc({ label, unit, value }: { label: string; unit?: string; value: string }) {
  return (
    <div className="lbl min-w-0"><Lbl label={label} unit={unit} />
      <div className="inp bg-sunk text-right tabular-nums text-ink" title="MES tự tính khi lưu">{value}</div>
    </div>
  );
}
function Section({ no, title, sub, children }: { no: number; title: string; sub: string; children: React.ReactNode }) {
  return (
    <section className="rounded border border-line">
      <h3 className="flex flex-wrap items-baseline gap-x-2 border-b border-line bg-sunk/60 px-4 py-2.5">
        <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-brand text-[13px] font-medium text-white">{no}</span>
        <span className="text-[15px] font-medium text-ink">{title}</span><span className="text-[12.5px] text-muted">{sub}</span>
      </h3>
      <div className="flex flex-col gap-4 p-4">{children}</div>
    </section>
  );
}

/** Vật tư BOM của các công đoạn trong lớp, quy về định mức theo km cáp */
function BomRows({ lines, ops, mPerPack }: { lines: SpecBomLine[]; ops: string[]; mPerPack: number | null }) {
  const rows = lines.filter((l) => ops.includes(l.operation_code ?? ''));
  const perKm = (l: SpecBomLine) => l.basis === 'KM' ? Number(l.qty_per_basis)
    : l.basis === 'PACK' && mPerPack ? Number(l.qty_per_basis) * 1000 / mPerPack : null;
  return (
    <div className="overflow-x-auto">
      <div className="mb-1 text-[13px] font-medium text-ink">Vật tư theo BOM ({ops.join(', ')})</div>
      {rows.length === 0 ? <p className="text-[13px] text-muted">Chưa có dòng BOM cho công đoạn này (khai ở thẻ BOM).</p> : (
        <table className="tbl table-fixed min-w-[560px]">
          <colgroup><col className="w-[100px]" /><col className="w-[120px]" /><col /><col className="w-[150px]" /><col className="w-[90px]" /></colgroup>
          <thead><tr><th>Công đoạn</th><th>Mã VT</th><th>Vật tư</th><th className="num" style={R}>Định mức / km cáp</th><th className="num" style={R}>Hao hụt</th></tr></thead>
          <tbody>{rows.map((l) => {
            const k = perKm(l);
            return (
              <tr key={l.id}>
                <td className="mono">{l.operation_code}</td><td className="mono font-medium">{l.material_code}</td><td className="truncate">{l.material_name}</td>
                <td className="num">{k === null ? `${nf(l.qty_per_basis, 3)} ${l.uom}/${l.basis === 'LOT' ? 'lô' : 'pallet'}` : `${nf(k, 4)} ${l.uom}`}</td>
                <td className="num">{nf(Number(l.loss_rate) * 100, 1)}%</td>
              </tr>
            );
          })}</tbody>
        </table>
      )}
    </div>
  );
}

export function SpecFields({ s, coreCodes, bom = [], ro = false }: { s: Vals; coreCodes: string[]; bom?: SpecBomLine[]; ro?: boolean }) {
  const mix = wireMix(s);
  const sumNd2 = mix.reduce((a, w) => a + w.n * w.d * w.d, 0);
  const metal = num(s.metal_kgkm); const ins = num(s.ins_kgkm);
  const cores = Math.min(MAX_CORES, Math.max(1, Number(s.cores) || 1));
  const pairs = Number(s.pairs) || 0;
  const perPair = pairs > 0 ? Math.max(1, Math.round(cores / pairs)) : 0;
  const colors = Array.isArray(s.core_colors) ? (s.core_colors as (string | null)[]) : [];
  const mPerPack = num(s.m_per_pack);
  const wireRows = ro ? mix.length : WIRE_ROWS;

  return (
    <fieldset disabled={ro} className="flex min-w-0 flex-col gap-4">
      <datalist id="core-colors">{COLORS.map((c) => <option key={c} value={c} />)}</datalist>

      <Section no={1} title="Ruột dẫn" sub="bện sợi đồng – CD1">
        <div className={G4}>
          <Sel name="core_code" label="Mã lõi" opts={coreCodes} d={v(s, 'core_code')} />
          <Sel name="conductor_mat" label="Vật liệu ruột dẫn" opts={['BC', 'TC']} d={v(s, 'conductor_mat')} />
          <Num name="pitch_mm" label="Bước bện" unit="mm" d={v(s, 'pitch_mm')} />
          <Num name="lay_factor" label="Hệ số ghép K" d={v(s, 'lay_factor')} />
        </div>
        <div className="overflow-x-auto">
          <table className="tbl table-fixed min-w-[560px]" aria-label="Các loại sợi của ruột dẫn">
            <colgroup><col className="w-[90px]" /><col /><col /><col /><col /></colgroup>
            <thead><tr><th>Loại sợi</th><th className="num" style={R}>Số sợi</th><th className="num" style={R}>Đường kính sợi (mm)</th><th className="num" style={R}>Tiết diện (mm²)</th><th className="num" style={R}>Đồng (kg/km cáp)</th></tr></thead>
            <tbody>
              {Array.from({ length: wireRows }, (_, i) => {
                const w = mix[i];
                const a = w ? w.n * Math.PI * w.d * w.d / 4 : null;
                const kg = w && metal !== null && sumNd2 > 0 ? metal * w.n * w.d * w.d / sumNd2 : null;
                return (
                  <tr key={i}>
                    <td>Loại {i + 1}</td>
                    <td><input className="inp text-right tabular-nums" name={`wire_n_${i}`} defaultValue={w ? String(w.n) : ''} inputMode="numeric" aria-label={`Số sợi loại ${i + 1}`} /></td>
                    <td><input className="inp text-right tabular-nums" name={`wire_d_${i}`} defaultValue={w ? String(w.d).replace('.', ',') : ''} inputMode="decimal" aria-label={`Đường kính sợi loại ${i + 1}`} /></td>
                    <td className="num">{a === null ? '' : nf(a, 4)}</td>
                    <td className="num">{kg === null ? '' : nf(kg, 3)}</td>
                  </tr>
                );
              })}
              <tr className="font-medium">
                <td>Cộng</td><td className="num">{nf(mix.reduce((a, w) => a + w.n, 0))}</td><td />
                <td className="num">{nf(sumNd2 * Math.PI / 4, 4)}</td><td className="num">{nf(metal, 3)}</td>
              </tr>
            </tbody>
          </table>
          {!ro && <p className="mt-1 text-[12.5px] text-muted">Ruột bện từ nhiều cỡ sợi: khai mỗi cỡ một dòng (tối đa {WIRE_ROWS}); dòng để trống được bỏ qua. Đồng tính cho cả {cores} lõi, MES tính lại khi lưu.</p>}
        </div>
        <BomRows lines={bom} ops={['CD1']} mPerPack={mPerPack} />
      </Section>

      <Section no={2} title="Dây đơn" sub="lõi bọc cách điện – CD2, phối trộn CD0">
        <div className={G4}>
          <Sel name="insulation" label="Vật liệu cách điện" opts={['SIL', 'HDPE', 'PVC']} d={v(s, 'insulation')} />
          <Num name="ins_thickness_mm" label="Chiều dày cách điện" unit="mm" d={v(s, 'ins_thickness_mm')} />
          <Num name="cores" label="Số lõi" d={v(s, 'cores')} />
          <Num name="pairs" label="Số cặp" d={v(s, 'pairs')} />
          <Calc label="Đường kính lõi" unit="mm" value={nf(num(s.core_dia_mm), 3)} />
          <Calc label="Cách điện" unit="kg/km cáp" value={nf(ins, 3)} />
          <Calc label="Cách điện mỗi lõi" unit="kg/km" value={ins === null ? '—' : nf(ins / cores, 3)} />
          <Calc label="Đồng mỗi lõi" unit="kg/km" value={metal === null ? '—' : nf(metal / cores, 3)} />
        </div>
        <div className="overflow-x-auto">
          <table className="tbl table-fixed min-w-[480px]" aria-label="Màu cách điện từng lõi">
            <colgroup><col className="w-[90px]" /><col className="w-[90px]" /><col /><col className="w-[170px]" /></colgroup>
            <thead><tr><th>Lõi</th><th>Cặp</th><th>Màu cách điện</th><th className="num" style={R}>Cách điện (kg/km)</th></tr></thead>
            <tbody>{Array.from({ length: cores }, (_, i) => (
              <tr key={i}>
                <td>Lõi {i + 1}</td><td>{perPair ? `Cặp ${Math.floor(i / perPair) + 1}` : '—'}</td>
                <td><input className="inp" name={`color_${i}`} list="core-colors" defaultValue={colors[i] ?? ''} aria-label={`Màu lõi ${i + 1}`} /></td>
                <td className="num">{ins === null ? '—' : nf(ins / cores, 3)}</td>
              </tr>
            ))}</tbody>
          </table>
          {colors.length === 0 && s.insulation_colors ? <p className="mt-1 text-[12.5px] text-muted">Màu đang ghi chung: “{String(s.insulation_colors)}” – khai lại theo từng lõi.</p> : null}
          {!ro && <p className="mt-1 text-[12.5px] text-muted">Đổi số lõi thì bấm Lưu thông số trước, bảng màu sẽ đủ dòng theo số lõi mới.</p>}
        </div>
        <BomRows lines={bom} ops={['CD0', 'CD2']} mPerPack={mPerPack} />
      </Section>

      <Section no={3} title="Dây hoàn thiện" sub="xoắn, băng, drain, vỏ, đóng gói – CD3 → CD6">
        <div className="overflow-x-auto">
          <table className="tbl table-fixed min-w-[640px]" aria-label="Các lớp của dây hoàn thiện">
            <colgroup><col className="w-[150px]" /><col /><col className="w-[130px]" /><col /><col className="w-[150px]" /></colgroup>
            <thead><tr><th>Lớp</th><th>Vật liệu</th><th className="num" style={R}>Chiều dày (mm)</th><th>Màu</th><th className="num" style={R}>Định mức (kg/km)</th></tr></thead>
            <tbody>
              <tr><td>Độn PP</td><td>PP</td><td /><td /><td><KgIn name="pp_kgkm" d={v(s, 'pp_kgkm')} /></td></tr>
              <tr><td>Băng PET</td><td>PET</td><td /><td /><td><KgIn name="pet_kgkm" d={v(s, 'pet_kgkm')} /></td></tr>
              <tr><td>Băng AL/PET</td><td>AL/PET (chống nhiễu)</td><td /><td /><td><KgIn name="alpet_kgkm" d={v(s, 'alpet_kgkm')} /></td></tr>
              <tr><td>Dây drain</td>
                <td><CellSel name="drain_mat" opts={['Không', 'TC', 'TCCA']} d={v(s, 'drain_mat') || 'Không'} /></td><td /><td />
                <td><KgIn name="drain_kgkm" d={v(s, 'drain_kgkm')} /></td></tr>
              <tr><td>Vỏ</td>
                <td><CellSel name="sheath" opts={['FR-PVC', 'LSZH', 'PVC', 'Không']} d={v(s, 'sheath')} /></td>
                <td><input className="inp text-right tabular-nums" name="sheath_thickness_mm" defaultValue={v(s, 'sheath_thickness_mm')} inputMode="decimal" aria-label="Chiều dày vỏ" /></td>
                <td><input className="inp" name="sheath_color" defaultValue={v(s, 'sheath_color')} aria-label="Màu vỏ" /></td>
                <td><KgIn name="sheath_kgkm" d={v(s, 'sheath_kgkm')} /></td></tr>
              <tr className="font-medium"><td colSpan={4}>Tổng khối lượng cáp (đồng + cách điện + các lớp)</td><td className="num">{nf(num(s.total_kgkm), 3)}</td></tr>
            </tbody>
          </table>
        </div>
        <div className={G4}>
          <Num name="od_mm" label="OD cáp" unit="mm" d={v(s, 'od_mm')} />
          <Sel name="brand" label="Thương hiệu" opts={['KAVIX', 'HEIZKA']} d={v(s, 'brand')} />
          <Sel name="pack_type" label="Đóng gói" opts={['Bobin gỗ', 'Cuộn PE']} d={v(s, 'pack_type')} />
          <Num name="m_per_pack" label="Mét / kiện" d={v(s, 'm_per_pack')} />
          <label className="lbl col-span-2 min-w-0 md:col-span-4"><Lbl label="Ghi chú cấu hình" /><input className="inp" name="config_note" defaultValue={v(s, 'config_note')} /></label>
        </div>
        <BomRows lines={bom} ops={['CD3', 'CD4', 'CD5', 'CD6']} mPerPack={mPerPack} />
      </Section>

      {!ro && <p className="text-[13px] text-muted">Định mức đồng, cách điện và Rdc được MES tự tính lại theo công thức file Excel 3.0 khi lưu; các lớp độn, băng, drain, vỏ nhập tay theo kg/km cáp.</p>}
    </fieldset>
  );
}

function KgIn({ name, d }: { name: string; d: string }) {
  return <input className="inp text-right tabular-nums" name={name} defaultValue={d} inputMode="decimal" aria-label={`Định mức ${name}`} />;
}
function CellSel({ name, opts, d }: { name: string; opts: string[]; d: string }) {
  const list = d && !opts.includes(d) ? [d, ...opts] : opts;
  return <select className="inp" name={name} defaultValue={d} aria-label={name}>{list.map((o) => <option key={o}>{o}</option>)}</select>;
}
