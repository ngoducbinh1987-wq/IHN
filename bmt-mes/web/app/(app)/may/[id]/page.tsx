import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ExternalLink, Plus } from 'lucide-react';
import { Empty, Flash, InfoRow, Pill, StatusPill, Toolbar } from '@/components/ui';
import { MStatus, Meter, SrcPill, StatusForm, SubTabs } from '@/components/machine-ui';
import { HistoryTable } from '@/components/machine-history';
import { SubmitButton } from '@/components/submit-button';
import {
  COMP_KIND, DOC_KIND, LEVEL, M_STATUS, OPR_ROLE, PLAN_STATE, RANGE_PARAM, RANGE_UOM, SPEC_GROUPS, SPEED_STATUS, WO_STATUS, WO_TYPE,
  cycleText, hhmm, remainText, usedFraction,
} from '@/lib/machine';
import { df, nf } from '@/lib/format';
import { can, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import {
  addComponent, addDoc, addRange, addSpeed, approveSpeed, deleteRow, removeOperatorSkill, saveSpecs, setOperatorSkill, signOperatorSkill, updateMachine,
} from '../actions';

const TABS: [string, string][] = [
  ['thong-so', 'Thông số kỹ thuật'], ['toc-do', 'Tốc độ & dải hoạt động'], ['bao-duong', 'Bảo dưỡng'],
  ['nguoi', 'Người đứng máy & tài liệu'], ['lich-su', 'Lịch sử'], ['thong-tin', 'Thông tin chung'],
];

export default async function MachineProfile({ params, searchParams }:
  { params: Promise<{ id: string }>; searchParams: Promise<{ tab?: string; ok?: string; err?: string }> }) {
  const { id } = await params;
  const sp = await searchParams;
  const me = await requirePerm('machine', 'view');
  const supabase = await createClient();
  const { data: m } = await supabase.schema('app').from('v_machines').select('*').eq('id', id).maybeSingle();
  if (!m) notFound();
  const isLine = !m.line_id;
  const lineId: string = m.line_id ?? m.id;
  const tab = TABS.some(([k]) => k === sp.tab) ? sp.tab! : 'thong-so';
  const base = `/may/${id}`;
  const here = `${base}?tab=${tab}`;
  const cfg = can(me, 'machine', 'config');

  const [{ data: family }, { data: reasons }] = await Promise.all([
    supabase.schema('app').from('v_machines').select('id, code, name, unit_kind, status, critical, seq, line_id, op_code').or(`id.eq.${lineId},line_id.eq.${lineId}`).order('seq'),
    supabase.schema('master').from('reason_codes').select('code, name').eq('kind', 'DOWNTIME').order('name'),
  ]);
  const line = (family ?? []).find((x) => x.id === lineId);
  const units = (family ?? []).filter((x) => x.line_id === lineId);

  return (
    <>
      <Toolbar title={<span>{m.code} · {m.name}</span>}
        actions={<>
          {isLine && cfg && <Link className="btn btn-soft" href={`/may/moi?cha=${id}`}><Plus size={16} />Thêm máy con</Link>}
          <Link className="btn btn-soft" href={`/may/lich-su?may=${lineId}`}>Lịch sử vận hành</Link>
          <Link className="btn" href={isLine ? '/may' : `/may/${lineId}`}>Đóng</Link>
        </>} />
      <div className="mt-4" />
      <Flash ok={sp.ok} err={sp.err} />

      <section className="card mb-4">
        <div className="flex flex-wrap items-start gap-x-8 gap-y-3 p-4">
          <div><div className="text-[12.5px] text-muted">Trạng thái</div><MStatus value={m.status} since={m.status_since} eta={m.status_eta} />
            {m.status_note && <div className="mt-1 max-w-[320px] text-[13px]">{m.status_note}</div>}</div>
          {isLine ? (
            <>
              <div><div className="text-[12.5px] text-muted">Công đoạn</div><div>{m.op_name ?? '—'}</div></div>
              <div><div className="text-[12.5px] text-muted">Người đứng máy chính</div><div>{m.operators ?? <span className="text-warn">Chưa giao</span>}</div></div>
            </>
          ) : (
            <>
              <div><div className="text-[12.5px] text-muted">Thuộc dây chuyền</div><Link className="link" href={`/may/${lineId}`}>{line?.code} · {line?.name}</Link></div>
              <div><div className="text-[12.5px] text-muted">Loại máy con</div><div>{m.unit_kind ?? '—'}</div></div>
              {m.critical && <div><Pill tone="bad">Quan trọng: hỏng là dừng cả dây chuyền</Pill></div>}
            </>
          )}
          <div><div className="text-[12.5px] text-muted">Đủ thông số</div><div className="tabular-nums">{m.spec_total ? `${m.spec_filled}/${m.spec_total}` : 'Chưa khai'}</div></div>
          {m.open_repair_id && <Link className="btn btn-sm btn-bad" href={`/may/bao-duong/phieu/${m.open_repair_id}`}>Phiếu sửa chữa đang mở</Link>}
        </div>
        {(units.length > 0 || !isLine) && (
          <div className="border-t border-line px-4 py-3">
            <div className="mb-2 text-[12.5px] text-muted">Thứ tự máy trên dây chuyền</div>
            <div className="flex flex-wrap items-stretch gap-2">
              {line && (
                <Link href={`/may/${line.id}`} className={`rounded border px-3 py-2 text-[13px] ${line.id === id ? 'border-brand bg-brand-soft' : 'border-line hover:border-ink/30'}`}>
                  <div className="mono text-[11.5px] text-muted">{line.code}</div><div className="font-medium">Cả dây chuyền</div>
                </Link>
              )}
              {units.map((u) => (
                <Link key={u.id} href={`/may/${u.id}`} className={`w-[150px] rounded border px-3 py-2 text-[13px] ${u.id === id ? 'border-brand bg-brand-soft' : 'border-line hover:border-ink/30'}`}>
                  <div className="mono truncate text-[11.5px] text-muted">{u.code}</div>
                  <div className="font-medium leading-tight">{u.unit_kind ?? u.name}</div>
                  <div className="mt-1 flex flex-wrap items-center gap-1"><StatusPill map={M_STATUS} value={u.status} />{u.critical && <span className="text-[11px] font-medium text-bad">Quan trọng</span>}</div>
                </Link>
              ))}
            </div>
          </div>
        )}
        {can(me, 'machine', 'create') && (
          <details className="border-t border-line">
            <summary className="cursor-pointer px-4 py-2.5 text-[14px] font-medium text-brand">Cập nhật trạng thái / báo hỏng</summary>
            <StatusForm machineId={id} current={m.status} reasons={reasons ?? []} back={here} />
          </details>
        )}
      </section>

      <SubTabs base={base} items={TABS} active={tab} />
      {tab === 'thong-so' && <SpecsTab id={id} cfg={cfg} back={here} />}
      {tab === 'toc-do' && <SpeedTab id={id} lineId={lineId} isLine={isLine} opCode={m.op_code ?? line?.op_code} cfg={cfg} canApprove={can(me, 'machine', 'approve')} back={here} />}
      {tab === 'bao-duong' && <MaintTab id={id} lineId={lineId} isLine={isLine} cfg={cfg} />}
      {tab === 'nguoi' && <PeopleTab id={id} lineId={lineId} isLine={isLine} cfg={cfg} canAssign={cfg || me.roles.includes('SX_TP')} canCertify={me.roles.includes('KT_TP') || me.roles.includes('ADMIN')} back={here} />}
      {tab === 'lich-su' && <HistoryTab lineId={lineId} machineId={id} isLine={isLine} />}
      {tab === 'thong-tin' && <InfoTab m={m} cfg={cfg} back={here} />}
    </>
  );
}

// ---------------------------------------------------------------- Thông số + linh kiện
async function SpecsTab({ id, cfg, back }: { id: string; cfg: boolean; back: string }) {
  const supabase = await createClient();
  const [{ data: specs }, { data: comps }, { data: mats }] = await Promise.all([
    supabase.schema('app').from('v_machine_specs').select('*').eq('machine_id', id).order('sort').order('label'),
    supabase.schema('app').from('v_machine_components').select('*').eq('machine_id', id).order('kind').order('name'),
    cfg ? supabase.schema('master').from('materials').select('id, code, name').eq('active', true).order('code') : Promise.resolve({ data: [] as { id: string; code: string; name: string }[] }),
  ]);
  const rows = specs ?? [];
  const groups = [...SPEC_GROUPS.filter((g) => rows.some((r) => r.grp === g)), ...[...new Set(rows.map((r) => r.grp))].filter((g) => !SPEC_GROUPS.includes(g))];
  return (
    <>
      <section className="card mb-4 overflow-x-auto">
        <div className="card-h">Thông số kỹ thuật<span className="text-[13px] font-normal text-muted">Nguồn: Nhà SX = catalog, biên bản NSX · Hồ sơ BMT = bản vẽ, đo thực tế · Giả định = cần kiểm tra lại</span></div>
        {cfg ? (
          <form action={saveSpecs}>
            <input type="hidden" name="machine_id" value={id} /><input type="hidden" name="back" value={back} />
            <table className="tbl">
              <thead><tr><th>Thông số</th><th>Giá trị</th><th>Đơn vị</th><th>Nguồn</th><th>Xóa</th></tr></thead>
              <tbody>
                {groups.map((g) => (
                  <GroupRows key={g} g={g} rows={rows.filter((r) => r.grp === g)} />
                ))}
                {rows.length === 0 && <tr><td colSpan={5}><Empty>Chưa có thông số. Thêm dòng bên dưới.</Empty></td></tr>}
                <tr className="bg-brand-soft/40">
                  <td className="min-w-[260px]"><div className="flex gap-2">
                    <select name="new_grp" className="inp w-auto" defaultValue="Chung">{SPEC_GROUPS.map((x) => <option key={x}>{x}</option>)}</select>
                    <input name="new_label" className="inp" placeholder="Thêm thông số mới" aria-label="Tên thông số mới" />
                  </div></td>
                  <td><input name="new_value" className="inp" placeholder="Giá trị" aria-label="Giá trị thông số mới" /></td>
                  <td><input name="new_uom" className="inp w-24" placeholder="V, kW…" aria-label="Đơn vị thông số mới" /></td>
                  <td><select name="new_source" className="inp w-auto" defaultValue="" aria-label="Nguồn thông số mới"><option value="">—</option><option value="NSX">Nhà SX</option><option value="BMT">Hồ sơ BMT</option><option value="GD">Giả định</option></select></td>
                  <td />
                </tr>
              </tbody>
            </table>
            <div className="flex items-center gap-3 border-t border-line px-4 py-3"><SubmitButton>Lưu thông số</SubmitButton><span className="text-[12.5px] text-muted">Mỗi lần sửa được ghi vào lịch sử vận hành của dây chuyền.</span></div>
          </form>
        ) : rows.length ? (
          <table className="tbl">
            <thead><tr><th>Thông số</th><th>Giá trị</th><th>Nguồn</th></tr></thead>
            <tbody>
              {groups.map((g) => [
                <tr key={g}><td colSpan={3} className="bg-sunk text-[13px] font-medium text-muted">{g}</td></tr>,
                ...rows.filter((r) => r.grp === g).map((r) => (
                  <tr key={r.id}><td className="w-[40%] text-ink/80">{r.label}</td><td>{r.value ? `${r.value}${r.uom ? ' ' + r.uom : ''}` : <span className="text-muted">—</span>}</td><td><SrcPill value={r.value ? r.source : null} /></td></tr>
                )),
              ])}
            </tbody>
          </table>
        ) : <Empty>Chưa khai báo thông số.</Empty>}
      </section>

      <section className="card overflow-x-auto">
        <div className="card-h">Linh kiện, cảm biến, phụ tùng</div>
        <table className="tbl">
          <thead><tr><th>Loại</th><th>Tên</th><th>Quy cách</th><th className="num">SL</th><th>Vị trí</th><th>Phụ tùng trong kho</th>{cfg && <th />}</tr></thead>
          <tbody>
            {(comps ?? []).map((c) => (
              <tr key={c.id}>
                <td>{COMP_KIND[c.kind] ?? c.kind}</td><td className="font-medium">{c.name}</td><td className="text-[13px]">{c.spec ?? '—'}</td>
                <td className="num">{c.qty === null ? '—' : nf(c.qty, 2)}</td><td className="text-[13px]">{c.position ?? '—'}</td>
                <td className="text-[13px]">{c.material_id ? <>
                  <span className="mono">{c.material_code}</span> · tồn {nf(c.stock, 2)}{c.min_stock !== null && <> / tối thiểu {nf(c.min_stock, 2)}</>} {c.low_stock && <Pill tone="bad">Dưới tối thiểu</Pill>}
                </> : <span className="text-muted">Chưa gắn mã kho{c.min_stock !== null ? ` · tối thiểu ${nf(c.min_stock, 2)}` : ''}</span>}</td>
                {cfg && <td><DeleteBtn table="component" id={c.id} back={back} /></td>}
              </tr>
            ))}
            {(comps ?? []).length === 0 && <tr><td colSpan={7}><Empty>Chưa khai linh kiện.</Empty></td></tr>}
          </tbody>
        </table>
        {cfg && (
          <form action={addComponent} className="grid gap-3 border-t border-line p-4 sm:grid-cols-3 lg:grid-cols-[150px_1fr_1fr_80px_1fr_1fr_100px_auto] lg:items-end">
            <input type="hidden" name="machine_id" value={id} /><input type="hidden" name="back" value={back} />
            <label className="lbl">Loại<select name="kind" className="inp">{Object.entries(COMP_KIND).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></label>
            <label className="lbl"><span className="req">Tên</span><input name="name" className="inp" required placeholder="Cặp nhiệt loại K" /></label>
            <label className="lbl">Quy cách<input name="spec" className="inp" placeholder="0–800 °C, 4–20 mA…" /></label>
            <label className="lbl">SL<input name="qty" className="inp" inputMode="decimal" /></label>
            <label className="lbl">Vị trí<input name="position" className="inp" placeholder="1 cái mỗi module" /></label>
            <label className="lbl">Mã kho phụ tùng<select name="material_id" className="inp" defaultValue=""><option value="">—</option>{(mats ?? []).map((x) => <option key={x.id} value={x.id}>{x.code} · {x.name}</option>)}</select></label>
            <label className="lbl">Tồn tối thiểu<input name="min_stock" className="inp" inputMode="decimal" /></label>
            <SubmitButton>Thêm</SubmitButton>
          </form>
        )}
      </section>
    </>
  );
}

type Spec = { id: string; label: string; value: string | null; uom: string | null; source: string | null };
function GroupRows({ g, rows }: { g: string; rows: Spec[] }) {
  return (
    <>
      <tr><td colSpan={5} className="bg-sunk text-[13px] font-medium text-muted">{g}</td></tr>
      {rows.map((r) => (
        <tr key={r.id}>
          <td className="text-ink/80">{r.label}
            <input type="hidden" name="spec_id" value={r.id} />
            <input type="hidden" name={`ov_${r.id}`} value={r.value ?? ''} /><input type="hidden" name={`ou_${r.id}`} value={r.uom ?? ''} /><input type="hidden" name={`os_${r.id}`} value={r.source ?? ''} />
          </td>
          <td><input name={`v_${r.id}`} defaultValue={r.value ?? ''} className="inp" placeholder="Chưa khai" aria-label={r.label} /></td>
          <td><input name={`u_${r.id}`} defaultValue={r.uom ?? ''} className="inp w-24" aria-label={`Đơn vị ${r.label}`} /></td>
          <td><select name={`s_${r.id}`} defaultValue={r.source ?? ''} className="inp w-auto" aria-label={`Nguồn ${r.label}`}>
            <option value="">—</option><option value="NSX">Nhà SX</option><option value="BMT">Hồ sơ BMT</option><option value="GD">Giả định</option>
          </select></td>
          <td><label className="inline-flex items-center gap-1.5 text-[13px] text-bad"><input type="checkbox" name={`del_${r.id}`} />Xóa</label></td>
        </tr>
      ))}
    </>
  );
}

function DeleteBtn({ table, id, back, label = 'Xóa' }: { table: string; id: string; back: string; label?: string }) {
  return (
    <form action={deleteRow}>
      <input type="hidden" name="table" value={table} /><input type="hidden" name="id" value={id} /><input type="hidden" name="back" value={back} />
      <SubmitButton className="btn btn-sm btn-bad-o" pendingText="…">{label}</SubmitButton>
    </form>
  );
}

// ---------------------------------------------------------------- Tốc độ + dải hoạt động
async function SpeedTab({ id, lineId, isLine, opCode, cfg, canApprove, back }:
  { id: string; lineId: string; isLine: boolean; opCode: string | null; cfg: boolean; canApprove: boolean; back: string }) {
  const supabase = await createClient();
  const [{ data: ranges }, { data: speeds }, { data: ops }, { data: groups }, { data: cores }, { data: products }] = await Promise.all([
    supabase.schema('app').from('v_machine_ranges').select('*').eq('machine_id', id).order('sort').order('label'),
    supabase.schema('app').from('v_machine_speeds').select('*').eq('machine_id', lineId).neq('status', 'OBSOLETE').order('op_code').order('core_code', { nullsFirst: true }),
    supabase.schema('master').from('operations').select('code, name').order('seq'),
    supabase.schema('master').from('product_groups').select('code, name').order('code'),
    supabase.schema('master').from('core_types').select('code, nominal_mm2').order('nominal_mm2'),
    supabase.schema('master').from('products').select('id, code').eq('active', true).order('code'),
  ]);
  const coreList = [...new Map((cores ?? []).map((c) => [c.code, c])).values()];
  return (
    <>
      <section className="card mb-4 overflow-x-auto">
        <div className="card-h">Dải hoạt động{!isLine && <span className="text-[13px] font-normal text-muted">của máy con này</span>}</div>
        <table className="tbl">
          <thead><tr><th>Thông số</th><th className="num">Nhỏ nhất</th><th className="num">Lớn nhất</th><th>Giá trị khác</th><th>Đơn vị</th><th>Nguồn</th><th>Dùng khi kiểm tra kế hoạch</th>{cfg && <th />}</tr></thead>
          <tbody>
            {(ranges ?? []).map((r) => (
              <tr key={r.id}>
                <td>{r.label}</td><td className="num">{r.min_value === null ? '—' : nf(r.min_value, 2)}</td><td className="num">{r.max_value === null ? '—' : nf(r.max_value, 2)}</td>
                <td>{r.text_value ?? '—'}</td><td>{r.uom ?? ''}</td><td><SrcPill value={r.source} /></td>
                <td className="text-[13px] text-muted">{r.param === 'SIZE_MM2' ? 'Chặn sản phẩm ngoài dải tiết diện' : r.param === 'SPEED_MPM' ? 'Giới hạn tốc độ tính năng lực' : '—'}</td>
                {cfg && <td><DeleteBtn table="range" id={r.id} back={back} /></td>}
              </tr>
            ))}
            {(ranges ?? []).length === 0 && <tr><td colSpan={8}><Empty>Chưa khai dải hoạt động.</Empty></td></tr>}
          </tbody>
        </table>
        {cfg && (
          <form action={addRange} className="grid gap-3 border-t border-line p-4 sm:grid-cols-3 lg:grid-cols-[180px_1fr_110px_110px_1fr_90px_130px_auto] lg:items-end">
            <input type="hidden" name="machine_id" value={id} /><input type="hidden" name="back" value={back} />
            <label className="lbl">Loại<select name="param" className="inp">{Object.entries(RANGE_PARAM).map(([k, v]) => <option key={k} value={k}>{v}{RANGE_UOM[k] ? ` (${RANGE_UOM[k]})` : ''}</option>)}</select></label>
            <label className="lbl">Tên (khi chọn thông số khác)<input name="label" className="inp" placeholder="Khổ băng AL/PET" /></label>
            <label className="lbl">Nhỏ nhất<input name="min_value" className="inp" inputMode="decimal" /></label>
            <label className="lbl">Lớn nhất<input name="max_value" className="inp" inputMode="decimal" /></label>
            <label className="lbl">Giá trị khác<input name="text_value" className="inp" placeholder="PVC / LSZH / PE" /></label>
            <label className="lbl">Đơn vị<input name="uom" className="inp" placeholder="mm²" /></label>
            <label className="lbl">Nguồn<select name="source" className="inp" defaultValue=""><option value="">—</option><option value="NSX">Nhà SX</option><option value="BMT">Hồ sơ BMT</option><option value="GD">Giả định</option></select></label>
            <SubmitButton>Thêm</SubmitButton>
          </form>
        )}
      </section>

      <section className="card overflow-x-auto">
        <div className="card-h">Tốc độ sản xuất theo sản phẩm (m/ph)<span className="text-[13px] font-normal text-muted">Kế hoạch chọn: mã SP → nhóm + mã lõi → mã lõi → nhóm → mặc định</span></div>
        {!isLine ? <Empty>Tốc độ khai theo dây chuyền. <Link className="link" href={`/may/${lineId}?tab=toc-do`}>Mở dây chuyền</Link>.</Empty> : (
          <>
            <table className="tbl">
              <thead><tr><th>Công đoạn</th><th>Áp dụng cho</th><th className="num">Danh định NSX</th><th className="num">Chuẩn lập KH</th><th className="num">Đổi máy (phút/lô)</th><th>Nguồn</th><th>Tình trạng</th><th /></tr></thead>
              <tbody>
                {(speeds ?? []).map((s) => (
                  <tr key={s.id}>
                    <td>{s.op_name}</td>
                    <td>{s.label && <div className="font-medium">{s.label}</div>}<div className="text-[12.5px] text-muted">{[s.product_code, s.group_name ?? s.group_code, s.core_code && `lõi ${s.core_code}`].filter(Boolean).join(' · ') || 'Mặc định của máy'}</div></td>
                    <td className="num">{s.rated_mpm === null ? '—' : nf(s.rated_mpm, 1)}</td>
                    <td className="num font-medium">{nf(s.std_mpm, 1)}{s.range_max !== null && Number(s.std_mpm) > Number(s.range_max) && <div className="text-[12px] font-normal text-bad">vượt dải {nf(s.range_max)}</div>}</td>
                    <td className="num">{nf(s.setup_min)}</td>
                    <td><SrcPill value={s.source} /></td>
                    <td><StatusPill map={SPEED_STATUS} value={s.status} />
                      {s.status === 'APPROVED' && <div className="text-[12px] text-muted">{s.approved_by_name}{s.temp_approval ? ' (duyệt tạm)' : ''} · {df(s.approved_at)}</div>}
                      {s.status === 'PENDING' && s.wait_days >= 1 && <div className="text-[12px] text-warn">Chờ quá 1 ngày · đã báo Giám đốc</div>}</td>
                    <td><div className="flex gap-1.5">
                      {s.status === 'PENDING' && canApprove && <form action={approveSpeed}><input type="hidden" name="id" value={s.id} /><input type="hidden" name="back" value={back} /><SubmitButton className="btn btn-sm btn-pri" pendingText="…">Duyệt</SubmitButton></form>}
                      {s.status === 'PENDING' && cfg && <DeleteBtn table="speed" id={s.id} back={back} />}
                    </div></td>
                  </tr>
                ))}
                {(speeds ?? []).length === 0 && <tr><td colSpan={8}><Empty>Chưa khai tốc độ. Kiểm tra kế hoạch sẽ báo “Chưa có tốc độ chuẩn”.</Empty></td></tr>}
              </tbody>
            </table>
            {cfg && (
              <form action={addSpeed} className="grid gap-3 border-t border-line p-4 sm:grid-cols-3 lg:grid-cols-6 lg:items-end">
                <input type="hidden" name="machine_id" value={lineId} /><input type="hidden" name="back" value={back} />
                <label className="lbl"><span className="req">Công đoạn</span><select name="op_code" className="inp" defaultValue={opCode ?? ''} required>{(ops ?? []).map((o) => <option key={o.code} value={o.code}>{o.code} · {o.name}</option>)}</select></label>
                <label className="lbl">Nhóm sản phẩm<select name="group_code" className="inp" defaultValue=""><option value="">Mọi nhóm</option>{(groups ?? []).map((g) => <option key={g.code} value={g.code}>{g.code} · {g.name}</option>)}</select></label>
                <label className="lbl">Mã lõi (cỡ ruột)<select name="core_code" className="inp" defaultValue=""><option value="">Mọi cỡ</option>{coreList.map((c) => <option key={c.code} value={c.code}>{c.code} · {nf(c.nominal_mm2, 2)} mm²</option>)}</select></label>
                <label className="lbl">Riêng một mã SP<select name="product_id" className="inp" defaultValue=""><option value="">—</option>{(products ?? []).map((p) => <option key={p.id} value={p.id}>{p.code}</option>)}</select></label>
                <label className="lbl">Tên gọi<input name="label" className="inp" placeholder="Lõi 1,5 mm²" /></label>
                <label className="lbl">Nguồn<select name="source" className="inp" defaultValue=""><option value="">—</option><option value="NSX">Nhà SX</option><option value="BMT">Hồ sơ BMT</option><option value="GD">Giả định</option></select></label>
                <label className="lbl">Danh định NSX (m/ph)<input name="rated_mpm" className="inp" inputMode="decimal" /></label>
                <label className="lbl"><span className="req">Chuẩn lập KH (m/ph)</span><input name="std_mpm" className="inp" inputMode="decimal" required /></label>
                <label className="lbl">Đổi máy (phút/lô)<input name="setup_min" className="inp" inputMode="decimal" defaultValue="0" /></label>
                <label className="lbl lg:col-span-2">Ghi chú<input name="note" className="inp" placeholder="Ví dụ: chạy thử với HCR 9710G" /></label>
                <SubmitButton>Thêm tốc độ</SubmitButton>
              </form>
            )}
          </>
        )}
      </section>
    </>
  );
}

// ---------------------------------------------------------------- Bảo dưỡng
async function MaintTab({ id, lineId, isLine, cfg }: { id: string; lineId: string; isLine: boolean; cfg: boolean }) {
  const supabase = await createClient();
  const plansQ = supabase.schema('app').from('v_maint_plans').select('*').order('due_date');
  const wosQ = supabase.schema('app').from('v_maint_wos').select('*').order('created_at', { ascending: false }).limit(20);
  const [{ data: plans }, { data: wos }] = await Promise.all([
    isLine ? plansQ.eq('line_id', lineId) : plansQ.eq('machine_id', id),
    isLine ? wosQ.eq('line_id', lineId) : wosQ.eq('machine_id', id),
  ]);
  return (
    <>
      <section className="card mb-4 overflow-x-auto">
        <div className="card-h">Kế hoạch bảo dưỡng{cfg && <Link className="btn btn-sm btn-pri" href={`/may/bao-duong/ke-hoach/moi?may=${id}`}><Plus size={15} />Thêm kế hoạch</Link>}</div>
        {(plans ?? []).length ? (
          <table className="tbl">
            <thead><tr><th>Máy</th><th>Công việc</th><th>Chu kỳ</th><th>Đã dùng</th><th>Trạng thái</th><th>Dự kiến</th><th className="num">Dừng máy</th></tr></thead>
            <tbody>
              {(plans ?? []).map((p) => (
                <tr key={p.id} className={p.active ? '' : 'opacity-50'}>
                  <td className="text-[13px]">{p.unit_kind ?? p.machine_name}</td>
                  <td><Link className="font-medium text-brand hover:underline" href={`/may/bao-duong/ke-hoach/${p.id}`}>{p.name}</Link><div className="text-[12.5px] text-muted">{LEVEL[p.level]}{p.active ? '' : ' · tạm ngừng'}</div></td>
                  <td className="text-[13px]">{cycleText(p)}</td>
                  <td className="min-w-[140px]"><Meter value={usedFraction(p)} tone={p.state === 'OVERDUE' ? 'bad' : p.state === 'OK' ? 'ok' : 'warn'} /><div className="mt-1 text-[12.5px] text-muted">{remainText(p)}</div></td>
                  <td>{p.open_wo ? <Link href={`/may/bao-duong/phieu/${p.open_wo}`}><Pill tone="info">{p.open_wo_no}</Pill></Link> : <StatusPill map={PLAN_STATE} value={p.state} />}</td>
                  <td className="whitespace-nowrap">{df(p.due_date)}</td>
                  <td className="num whitespace-nowrap">{p.stop_minutes ? `${p.stop_minutes} phút` : '—'}<div className="text-[12px] text-muted">{p.off_shift ? 'ngoài giờ ca' : 'trong ca'}</div></td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : <Empty>Chưa có kế hoạch bảo dưỡng. Khai báo theo sổ tay bảo dưỡng của nhà sản xuất.</Empty>}
      </section>
      <section className="card overflow-x-auto">
        <div className="card-h">Phiếu bảo dưỡng, sửa chữa gần đây</div>
        {(wos ?? []).length ? (
          <table className="tbl">
            <thead><tr><th>Phiếu</th><th>Loại</th><th>Máy</th><th>Nội dung</th><th>Trạng thái</th><th>Tạo</th><th>Xong</th></tr></thead>
            <tbody>
              {(wos ?? []).map((w) => (
                <tr key={w.id}>
                  <td><Link className="mono font-medium text-brand hover:underline" href={`/may/bao-duong/phieu/${w.id}`}>{w.wo_no}</Link></td>
                  <td>{WO_TYPE[w.wo_type]}</td><td>{w.machine_code}</td><td className="min-w-[200px]">{w.title}</td>
                  <td><StatusPill map={WO_STATUS} value={w.status} /></td><td className="whitespace-nowrap">{df(w.created_at)}</td><td className="whitespace-nowrap">{df(w.finished_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : <Empty>Chưa có phiếu.</Empty>}
      </section>
    </>
  );
}

// ---------------------------------------------------------------- Người đứng máy + tài liệu
async function PeopleTab({ id, lineId, isLine, cfg, canAssign, canCertify, back }: { id: string; lineId: string; isLine: boolean; cfg: boolean; canAssign: boolean; canCertify: boolean; back: string }) {
  const supabase = await createClient();
  const [{ data: ops }, { data: people }, { data: docs }] = await Promise.all([
    supabase.schema('app').from('v_machine_operators').select('*').eq('machine_id', lineId).order('level').order('sort'),
    supabase.schema('app').from('v_kh_operators').select('code, job, profile_name, skills, learning').order('sort'),
    supabase.schema('app').from('v_machine_docs').select('*').eq('machine_id', id).order('kind').order('title'),
  ]);
  const free = (people ?? []).filter((p) => !(ops ?? []).some((o) => o.operator_code === p.code));
  const hidden = (op: string) => <><input type="hidden" name="machine_id" value={lineId} /><input type="hidden" name="operator" value={op} /><input type="hidden" name="back" value={back} /></>;
  return (
    <div className="grid gap-4 xl:grid-cols-2">
      <section className="card overflow-x-auto">
        <div className="card-h">Người đứng máy{!isLine && <span className="text-[13px] font-normal text-muted">theo dây chuyền</span>}</div>
        <table className="tbl">
          <thead><tr><th>Người</th><th>Tay nghề</th><th>Xác nhận tay nghề</th><th /></tr></thead>
          <tbody>
            {(ops ?? []).map((o) => (
              <tr key={o.operator_code}>
                <td className="font-medium">{o.operator_code}{o.profile_name && <span className="font-normal"> · {o.profile_name}</span>}
                  <div className="text-[12.5px] font-normal text-muted">{o.job}{o.is_deputy ? ' · Tổ phó' : ''}</div></td>
                <td>{o.level === 'MAIN' ? <Pill tone="ok">{OPR_ROLE.MAIN}</Pill> : <Pill tone="info">{OPR_ROLE.LEARNING}</Pill>}</td>
                <td>{o.signed_at ? <Pill tone="ok">Đã ký {df(o.signed_at)}</Pill> : <Pill tone="warn">Chưa xác nhận</Pill>}{o.signed_by_name && <div className="text-[12px] text-muted">{o.signed_by_name}</div>}</td>
                <td><div className="flex flex-wrap gap-1.5">
                  {!o.signed_at && canCertify && <form action={signOperatorSkill}>{hidden(o.operator_code)}<SubmitButton className="btn btn-sm btn-soft" pendingText="…">Ký xác nhận</SubmitButton></form>}
                  {canAssign && isLine && o.level === 'LEARNING' && <form action={setOperatorSkill}>{hidden(o.operator_code)}<input type="hidden" name="level" value="MAIN" /><input type="hidden" name="reason" value="Đã học xong, chuyển đứng chính" /><SubmitButton className="btn btn-sm" pendingText="…">Chuyển đứng chính</SubmitButton></form>}
                  {canAssign && isLine && <form action={removeOperatorSkill}>{hidden(o.operator_code)}<SubmitButton className="btn btn-sm btn-bad-o" pendingText="…">Bỏ giao</SubmitButton></form>}
                </div></td>
              </tr>
            ))}
            {(ops ?? []).length === 0 && <tr><td colSpan={4}><Empty>Chưa giao người đứng máy.</Empty></td></tr>}
          </tbody>
        </table>
        {canAssign && isLine && (
          free.length ? (
            <form action={setOperatorSkill} className="grid gap-3 border-t border-line p-4 sm:grid-cols-[minmax(0,1fr)_160px] lg:items-end">
              <input type="hidden" name="machine_id" value={lineId} /><input type="hidden" name="back" value={back} />
              <label className="lbl"><span className="req">Người</span>
                <select name="operator" className="inp" required defaultValue="">
                  <option value="" disabled>Chọn người</option>
                  {free.map((p) => <option key={p.code} value={p.code}>{p.code}{p.profile_name ? ` · ${p.profile_name}` : ''} — {p.job}</option>)}
                </select></label>
              <label className="lbl">Tay nghề<select name="level" className="inp">{Object.entries(OPR_ROLE).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></label>
              <label className="lbl sm:col-span-2">Lý do<input name="reason" className="inp" placeholder="Ví dụ: giao thêm người đứng line vỏ 2" /></label>
              <div><SubmitButton>Giao người</SubmitButton></div>
            </form>
          ) : <p className="border-t border-line px-4 py-3 text-[13px] text-muted">Đã giao hết NV1–NV5 cho dây chuyền này.</p>
        )}
        <p className="border-t border-line px-4 py-3 text-[12.5px] text-muted">Danh sách NV1–NV5 dùng chung với Lịch máy (Tham số xếp lịch). Quản lý SX giao người, TP Kỹ thuật/QA ký xác nhận tay nghề. Đổi mức tay nghề thì phải ký lại.</p>
      </section>
      <section className="card overflow-x-auto">
        <div className="card-h">Tài liệu máy</div>
        <table className="tbl">
          <thead><tr><th>Tài liệu</th><th>Loại</th><th>Tình trạng</th><th /></tr></thead>
          <tbody>
            {(docs ?? []).map((d) => (
              <tr key={d.id}>
                <td>{d.url ? <a className="link inline-flex items-center gap-1" href={d.url} target="_blank" rel="noreferrer">{d.title}<ExternalLink size={13} /></a> : d.title}
                  {d.note && <div className="text-[12.5px] text-muted">{d.note}</div>}</td>
                <td>{DOC_KIND[d.kind]}</td><td>{d.status === 'ISSUED' ? <Pill tone="ok">Đã ban hành</Pill> : <Pill tone="warn">Đang soạn</Pill>}</td>
                <td>{cfg && <DeleteBtn table="doc" id={d.id} back={back} />}</td>
              </tr>
            ))}
            {(docs ?? []).length === 0 && <tr><td colSpan={4}><Empty>Chưa có tài liệu. Dán đường dẫn Google Drive của hướng dẫn vận hành, catalog, sổ tay bảo dưỡng.</Empty></td></tr>}
          </tbody>
        </table>
        {cfg && (
          <form action={addDoc} className="grid gap-3 border-t border-line p-4 sm:grid-cols-2 lg:items-end">
            <input type="hidden" name="machine_id" value={id} /><input type="hidden" name="back" value={back} />
            <label className="lbl"><span className="req">Tên tài liệu</span><input name="title" className="inp" required placeholder="Hướng dẫn vận hành line silicone" /></label>
            <label className="lbl">Đường dẫn<input name="url" className="inp" type="url" placeholder="https://drive.google.com/…" /></label>
            <label className="lbl">Loại<select name="kind" className="inp">{Object.entries(DOC_KIND).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></label>
            <label className="lbl">Tình trạng<select name="status" className="inp"><option value="ISSUED">Đã ban hành</option><option value="DRAFT">Đang soạn</option></select></label>
            <div><SubmitButton>Thêm tài liệu</SubmitButton></div>
          </form>
        )}
      </section>
    </div>
  );
}

// ---------------------------------------------------------------- Lịch sử gần đây
async function HistoryTab({ lineId, machineId, isLine }: { lineId: string; machineId: string; isLine: boolean }) {
  const supabase = await createClient();
  const { data } = await supabase.schema('app').rpc('machine_history', isLine ? { p_line: lineId, p_limit: 40 } : { p_machine: machineId, p_limit: 40 });
  return (
    <section className="card overflow-x-auto">
      <div className="card-h">Sự kiện gần đây<Link className="btn btn-sm btn-soft" href={`/may/lich-su?may=${lineId}`}>Xem dòng thời gian</Link></div>
      <HistoryTable rows={data ?? []} />
    </section>
  );
}

// ---------------------------------------------------------------- Thông tin chung
function InfoTab({ m, cfg, back }: { m: Record<string, any>; cfg: boolean; back: string }) {
  if (!cfg) {
    return (
      <section className="card max-w-2xl px-4 py-2">
        <InfoRow label="Hãng">{m.vendor ?? '—'}</InfoRow><InfoRow label="Model">{m.model ?? '—'}</InfoRow>
        <InfoRow label="Số serial">{m.serial_no ?? '—'}</InfoRow><InfoRow label="Năm sản xuất">{m.year_made ?? '—'}</InfoRow>
        <InfoRow label="Vị trí">{m.location ?? '—'}</InfoRow><InfoRow label="PLC">{m.plc_model ?? '—'}</InfoRow>
        <InfoRow label="Công suất">{m.rated_kw ? `${nf(m.rated_kw, 1)} kW` : '—'}</InfoRow><InfoRow label="Ghi chú">{m.note ?? '—'}</InfoRow>
      </section>
    );
  }
  return (
    <form action={updateMachine} className="card grid max-w-3xl gap-4 p-5 sm:grid-cols-2">
      <input type="hidden" name="id" value={m.id} /><input type="hidden" name="back" value={back} />
      <label className="lbl"><span className="req">Tên</span><input name="name" className="inp" required defaultValue={m.name} /></label>
      {m.line_id
        ? <label className="lbl">Loại máy con<input name="unit_kind" className="inp" defaultValue={m.unit_kind ?? ''} /></label>
        : <input type="hidden" name="unit_kind" value={m.unit_kind ?? ''} />}
      <label className="lbl">Hãng<input name="vendor" className="inp" defaultValue={m.vendor ?? ''} /></label>
      <label className="lbl">Model<input name="model" className="inp" defaultValue={m.model ?? ''} /></label>
      <label className="lbl">Số serial<input name="serial_no" className="inp" defaultValue={m.serial_no ?? ''} /></label>
      <label className="lbl">Năm sản xuất<input name="year_made" className="inp" inputMode="numeric" defaultValue={m.year_made ?? ''} /></label>
      <label className="lbl">Vị trí trong xưởng<input name="location" className="inp" defaultValue={m.location ?? ''} placeholder="Trục A–B, đầu trục 12" /></label>
      <label className="lbl">PLC<input name="plc_model" className="inp" defaultValue={m.plc_model ?? ''} /></label>
      <label className="lbl">Công suất định mức (kW)<input name="rated_kw" className="inp" inputMode="decimal" defaultValue={m.rated_kw ?? ''} /></label>
      <label className="lbl">Thứ tự<input name="seq" className="inp" inputMode="numeric" defaultValue={m.seq ?? 0} /></label>
      <label className="lbl sm:col-span-2">Ghi chú<textarea name="note" className="inp" rows={2} defaultValue={m.note ?? ''} /></label>
      {m.line_id && <label className="flex items-center gap-2 text-[14px]"><input type="checkbox" name="critical" defaultChecked={m.critical} />Máy quan trọng (hỏng là dừng cả dây chuyền)</label>}
      {!m.line_id && <input type="hidden" name="critical" value="" />}
      <label className="flex items-center gap-2 text-[14px]"><input type="checkbox" name="active" defaultChecked={m.active} />Đang dùng</label>
      <div className="sm:col-span-2"><SubmitButton>Lưu thông tin</SubmitButton></div>
    </form>
  );
}
