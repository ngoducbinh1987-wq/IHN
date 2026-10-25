// Nhóm ô nhập thông số spec, dùng chung cho "Thêm spec mới" và "Sửa spec nháp"
type Vals = Record<string, string | number | boolean | null | undefined>;

const v = (x: Vals, k: string) => {
  const raw = x[k] === null || x[k] === undefined ? '' : String(x[k]);
  return /^-?\d+(\.\d+)?$/.test(raw) ? raw.replace('.', ',') : raw;   // số hiển thị kiểu Việt Nam: 0,75
};

function Sel({ name, label, opts, d }: { name: string; label: string; opts: string[]; d: string }) {
  return (
    <label className="lbl">{label}
      <select className="inp" name={name} defaultValue={d}>{opts.map((o) => <option key={o}>{o}</option>)}</select>
    </label>
  );
}
function Num({ name, label, d, unit }: { name: string; label: string; d: string; unit?: string }) {
  return (
    <label className="lbl">{label}{unit && <span className="text-[11.5px]"> ({unit})</span>}
      <input className="inp text-right" name={name} defaultValue={d} inputMode="decimal" />
    </label>
  );
}

export function SpecFields({ s, coreCodes }: { s: Vals; coreCodes: string[] }) {
  return (
    <div className="flex flex-col gap-4">
      <fieldset className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <legend className="mb-2 text-[15px] font-medium text-ink">Ruột dẫn và lõi</legend>
        <Sel name="core_code" label="Mã lõi" opts={coreCodes} d={v(s, 'core_code')} />
        <Num name="cores" label="Số lõi" d={v(s, 'cores')} />
        <Num name="pairs" label="Số cặp" d={v(s, 'pairs')} />
        <Sel name="conductor_mat" label="Vật liệu ruột dẫn" opts={['BC', 'TC']} d={v(s, 'conductor_mat')} />
        <Num name="wire_count" label="Số sợi" d={v(s, 'wire_count')} />
        <Num name="wire_dia_mm" label="Đường kính sợi" unit="mm" d={v(s, 'wire_dia_mm')} />
        <Num name="pitch_mm" label="Bước bện" unit="mm" d={v(s, 'pitch_mm')} />
        <Num name="lay_factor" label="Hệ số ghép K" d={v(s, 'lay_factor')} />
      </fieldset>
      <fieldset className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <legend className="mb-2 text-[15px] font-medium text-ink">Cách điện, vỏ, màu</legend>
        <Sel name="insulation" label="Cách điện" opts={['SIL', 'HDPE', 'PVC']} d={v(s, 'insulation')} />
        <Num name="ins_thickness_mm" label="Chiều dày cách điện" unit="mm" d={v(s, 'ins_thickness_mm')} />
        <Sel name="sheath" label="Vỏ" opts={['FR-PVC', 'LSZH', 'PVC', 'Không']} d={v(s, 'sheath')} />
        <Num name="sheath_thickness_mm" label="Chiều dày vỏ" unit="mm" d={v(s, 'sheath_thickness_mm')} />
        <Sel name="drain_mat" label="Dây drain" opts={['Không', 'TC', 'TCCA']} d={v(s, 'drain_mat') || 'Không'} />
        <label className="lbl">Màu vỏ<input className="inp" name="sheath_color" defaultValue={v(s, 'sheath_color')} /></label>
        <label className="lbl sm:col-span-2">Màu cách điện<input className="inp" name="insulation_colors" defaultValue={v(s, 'insulation_colors')} /></label>
      </fieldset>
      <fieldset className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <legend className="mb-2 text-[15px] font-medium text-ink">Định mức các lớp nhập tay (kg/km) và đóng gói</legend>
        <Num name="sheath_kgkm" label="Vỏ" d={v(s, 'sheath_kgkm')} />
        <Num name="pp_kgkm" label="Độn PP" d={v(s, 'pp_kgkm')} />
        <Num name="pet_kgkm" label="Băng PET" d={v(s, 'pet_kgkm')} />
        <Num name="alpet_kgkm" label="Băng AL/PET" d={v(s, 'alpet_kgkm')} />
        <Num name="drain_kgkm" label="Drain" d={v(s, 'drain_kgkm')} />
        <Num name="od_mm" label="OD cáp" unit="mm" d={v(s, 'od_mm')} />
        <Sel name="brand" label="Thương hiệu" opts={['KAVIX', 'HEIZKA']} d={v(s, 'brand')} />
        <Sel name="pack_type" label="Đóng gói" opts={['Bobin gỗ', 'Cuộn PE']} d={v(s, 'pack_type')} />
        <Num name="m_per_pack" label="Mét / kiện" d={v(s, 'm_per_pack')} />
        <label className="lbl sm:col-span-3">Ghi chú cấu hình<input className="inp" name="config_note" defaultValue={v(s, 'config_note')} /></label>
      </fieldset>
      <p className="text-[13px] text-muted">Định mức đồng, cách điện và Rdc được hệ thống tự tính lại theo công thức file Excel 3.0 khi lưu.</p>
    </div>
  );
}
