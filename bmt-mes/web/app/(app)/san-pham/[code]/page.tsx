import Link from 'next/link';
import { notFound } from 'next/navigation';
import { CopyPlus, Send, Trash2 } from 'lucide-react';
import { SpecFields } from '@/components/spec-form';
import { StageBar, type Stage } from '@/components/stage-bar';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Pill, StatusPill, Toolbar } from '@/components/ui';
import type { Approval } from '@/lib/approvals';
import { SPEC_STATUS, df, nf } from '@/lib/format';
import { can, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { deleteBomLine, newVersion, recordPilot, saveBomLine, saveDeviation, submitSpec, updateSpec } from './actions';

const BASIS: Record<string, string> = { KM: '/km', PACK: '/kiện', PALLET: '/pallet', LOT: '/lô' };
const OPS = ['CD0', 'CD1', 'CD2', 'CD3', 'CD4', 'CD5', 'CD6'];

export default async function ProductDetail({ params, searchParams }:
  { params: Promise<{ code: string }>; searchParams: Promise<{ ok?: string; err?: string; v?: string; tab?: string }> }) {
  const { code: rawCode } = await params;
  const code = decodeURIComponent(rawCode);
  const sp = await searchParams;
  const me = await requirePerm('spec', 'view');
  const supabase = await createClient();
  const { data: p } = await supabase.schema('app').from('v_products').select('*').eq('code', code).maybeSingle();
  if (!p) notFound();
  const { data: versions } = await supabase.schema('app').from('v_spec_versions').select('*').eq('product_id', p.id).order('version', { ascending: false });
  const specId = (versions ?? []).some((x) => x.id === sp.v) ? sp.v! : p.spec_id;
  const [{ data: spec }, { data: res }, { data: issues }, { data: bom }, { data: reqs }, { data: mats }, { data: cores }] = await Promise.all([
    supabase.schema('master').from('product_specs').select('*').eq('id', specId).single(),
    supabase.schema('master').from('spec_results').select('*').eq('spec_id', specId).maybeSingle(),
    supabase.schema('master').rpc('check_spec', { p_spec: specId }),
    supabase.schema('app').from('v_bom_lines').select('*').eq('spec_id', specId).order('operation_code').order('material_code'),
    supabase.schema('app').from('v_approvals').select('*').eq('doc_id', specId).order('submitted_at', { ascending: false }).returns<Approval[]>(),
    supabase.schema('app').from('v_materials').select('code, name, uom').order('code'),
    supabase.schema('master').from('core_types').select('code').order('code'),
  ]);
  if (!spec) notFound();
  const minor = spec.change_level === 'MINOR';
  const { data: flow } = await supabase.schema('wf').from('approval_steps').select('seq, level_label, role_code')
    .eq('doc_type', minor ? 'SPEC_MINOR' : 'SPEC_NEW').eq('enabled', true).order('seq');
  const problems = (issues as string[] | null) ?? [];
  const editable = ['DRAFT', 'PILOT_PENDING', 'PILOT'].includes(spec.status) && (can(me, 'spec', 'edit') || can(me, 'spec', 'create'));
  const last = reqs?.[0];
  const stages: Stage[] = last && (last.status === 'PENDING' || spec.status !== 'DRAFT')
    ? last.steps ?? []
    : [{ seq: 0, label: 'Lập phiếu', state: 'current' }, ...(flow ?? []).map((s) => ({ seq: s.seq, label: s.level_label, state: 'todo' as const }))];
  const tab = sp.tab ?? 'thong-so';
  const tabHref = (t: string) => `/san-pham/${encodeURIComponent(code)}?v=${specId}&tab=${t}`;
  const hidden = (<><input type="hidden" name="spec_id" value={specId} /><input type="hidden" name="code" value={code} /></>);

  return (
    <>
      <Toolbar title={<><span className="mono text-[22px]">{code}</span> <span className="text-muted">· {p.description}</span></>}
        actions={<>
          {editable && can(me, 'spec', 'create') && (
            <form action={submitSpec}>{hidden}<input type="hidden" name="version" value={spec.version} /><input type="hidden" name="change_level" value={spec.change_level ?? ''} />
              <SubmitButton className="btn btn-pri" ><Send size={15} />Gửi duyệt phát hành</SubmitButton></form>
          )}
          {spec.status === 'RELEASED' && can(me, 'spec', 'create') && (
            <form action={newVersion} className="flex gap-1">{hidden}
              <select className="inp w-auto" name="level" aria-label="Mức thay đổi" defaultValue="MINOR">
                <option value="MINOR">Thay đổi nhỏ (TP KT duyệt)</option><option value="MAJOR">Thay đổi lớn (QC → TP KT → BGĐ)</option>
              </select>
              <SubmitButton className="btn btn-soft"><CopyPlus size={15} />Tạo phiên bản mới</SubmitButton>
            </form>
          )}
          {last?.status === 'PENDING' && <Link className="btn btn-soft" href={`/duyet/${last.id}`}>Xem quy trình duyệt</Link>}
          <Link className="btn" href="/san-pham">Đóng</Link>
        </>} />
      <div className="-mx-4 mb-4 md:-mx-5"><StageBar stages={stages} /></div>
      <Flash ok={sp.ok} err={sp.err} />

      <div className="mb-4 flex flex-wrap items-center gap-2 text-[14px]">
        <span className="text-muted">Phiên bản:</span>
        {(versions ?? []).map((x) => (
          <Link key={x.id} href={`/san-pham/${encodeURIComponent(code)}?v=${x.id}`}
            className={`btn btn-sm ${x.id === specId ? 'border-brand text-brand' : ''}`}>
            v{x.version} <StatusPill map={SPEC_STATUS} value={x.status} />{x.is_current && <span className="text-[11px] text-muted">hiện hành</span>}
          </Link>
        ))}
      </div>

      <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_340px]">
        <div className="min-w-0">
          <nav className="mb-3 flex gap-1 border-b border-line" aria-label="Nội dung spec">
            {[['thong-so', 'Thông số'], ['bom', `BOM (${bom?.length ?? 0})`], ['pilot', 'Pilot & sai lệch'], ['lich-su', 'Lịch sử duyệt']].map(([k, l]) => (
              <Link key={k} href={tabHref(k)} aria-current={tab === k ? 'page' : undefined}
                className={`-mb-px border-b-[3px] px-3 py-2.5 text-[15px] ${tab === k ? 'border-brand text-brand' : 'border-transparent hover:text-brand'}`}>{l}</Link>
            ))}
          </nav>

          {tab === 'thong-so' && (editable ? (
            <form action={updateSpec} className="card flex flex-col gap-4 p-4">{hidden}
              <label className="lbl">Quy cách<input className="inp" name="description" defaultValue={p.description} /></label>
              <SpecFields s={{ ...spec, ...(res ?? {}) }} coreCodes={[...new Set((cores ?? []).map((c) => c.code as string))]} />
              <div className="border-t border-line pt-3"><SubmitButton className="btn btn-pri">Lưu thông số</SubmitButton></div>
            </form>
          ) : (
            <section className="card p-4">
              <dl className="grid gap-x-6 gap-y-3 text-[14px] sm:grid-cols-2 lg:grid-cols-3">
                {([
                  ['Mã lõi', spec.core_code], ['Số lõi / cặp', `${spec.cores} / ${spec.pairs}`], ['Ruột dẫn', `${spec.wire_count}×${nf(spec.wire_dia_mm, 2)} mm ${spec.conductor_mat}`],
                  ['Bước bện', `${nf(spec.pitch_mm, 1)} mm`], ['Cách điện', `${spec.insulation} · ${nf(spec.ins_thickness_mm, 2)} mm`],
                  ['Vỏ', `${spec.sheath}${spec.sheath_thickness_mm ? ' · ' + nf(spec.sheath_thickness_mm, 2) + ' mm' : ''}`],
                  ['Drain', spec.drain_mat ?? 'Không'], ['Màu vỏ / cách điện', `${spec.sheath_color ?? '—'} · ${spec.insulation_colors ?? '—'}`],
                  ['Thương hiệu', spec.brand], ['Đóng gói', `${spec.pack_type} · ${nf(spec.m_per_pack)} m/kiện`],
                ] as [string, string][]).map(([k, val]) => <div key={k}><dt className="text-[13px] text-muted">{k}</dt><dd className="font-medium">{val}</dd></div>)}
              </dl>
              {spec.config_note && <p className="mt-3 rounded bg-sunk px-3 py-2 text-[13px]">{spec.config_note}</p>}
              {!editable && spec.status !== 'RELEASED' && <p className="mt-3 text-[13px] text-muted">Spec đang được duyệt nên không sửa được.</p>}
            </section>
          ))}

          {tab === 'bom' && (
            <section className="card overflow-x-auto">
              <table className="tbl">
                <thead><tr><th>Công đoạn</th><th>Mã VT</th><th>Vật tư</th><th className="num">Suất</th><th>ĐVT</th><th className="num">Hao hụt</th><th className="num">Khởi động / lô</th>{editable && <th />}</tr></thead>
                <tbody>
                  {(bom ?? []).map((l) => (
                    <tr key={l.id}>
                      <td className="mono">{l.operation_code}</td><td className="mono font-medium">{l.material_code}</td><td>{l.material_name}</td>
                      <td className="num">{nf(l.qty_per_basis, 4)}</td><td className="whitespace-nowrap">{l.uom}{BASIS[l.basis]}</td>
                      <td className="num">{nf(l.loss_rate * 100, 1)}%</td><td className="num">{Number(l.startup_per_lot) ? nf(l.startup_per_lot, 3) : '—'}</td>
                      {editable && <td><form action={deleteBomLine}>{hidden}<input type="hidden" name="line_id" value={l.id} /><SubmitButton className="btn btn-sm btn-bad-o" pendingText="…"><Trash2 size={14} />Xóa</SubmitButton></form></td>}
                    </tr>
                  ))}
                  {(bom ?? []).length === 0 && <tr><td colSpan={8}><Empty>BOM chưa có dòng nào.</Empty></td></tr>}
                </tbody>
              </table>
              {editable && (
                <form action={saveBomLine} className="grid gap-3 border-t border-line bg-sunk/50 p-4 md:grid-cols-[2fr_0.8fr_0.8fr_0.7fr_0.8fr_0.8fr_auto] md:items-end">{hidden}
                  <datalist id="mats">{(mats ?? []).map((m) => <option key={m.code} value={`${m.code} · ${m.name} (${m.uom})`} />)}</datalist>
                  <label className="lbl"><span className="req">Vật tư</span><input className="inp" name="material_code" list="mats" required /></label>
                  <label className="lbl"><span className="req">Suất</span><input className="inp text-right" name="qty" inputMode="decimal" required /></label>
                  <label className="lbl">Theo<select className="inp" name="basis"><option value="KM">/km</option><option value="PACK">/kiện</option><option value="PALLET">/pallet</option><option value="LOT">/lô</option></select></label>
                  <label className="lbl">Hao hụt %<input className="inp text-right" name="loss" inputMode="decimal" placeholder="mặc định" /></label>
                  <label className="lbl">Khởi động/lô<input className="inp text-right" name="startup" inputMode="decimal" /></label>
                  <label className="lbl">Công đoạn<select className="inp" name="operation">{OPS.map((o) => <option key={o}>{o}</option>)}</select></label>
                  <SubmitButton className="btn btn-pri">Lưu dòng</SubmitButton>
                  <p className="text-[12.5px] text-muted md:col-span-7">Nhập lại vật tư đã có cùng “Theo” để sửa suất của dòng đó.</p>
                </form>
              )}
            </section>
          )}

          {tab === 'pilot' && (
            <div className="grid gap-4 lg:grid-cols-2">
              {editable && (can(me, 'quality', 'edit') || can(me, 'spec', 'edit')) ? (
                <form action={recordPilot} className="card flex flex-col gap-3 p-4">{hidden}
                  <h2 className="font-medium">Kết quả pilot (QC nhập)</h2>
                  <div className="grid grid-cols-3 gap-3">
                    <label className="lbl"><span className="req">Rdc đo (Ω/km)</span><input className="inp text-right" name="rdc" defaultValue={res?.pilot_rdc ?? ''} required /></label>
                    <label className="lbl">kg/km cân thực<input className="inp text-right" name="kgkm" defaultValue={res?.pilot_kgkm ?? ''} /></label>
                    <label className="lbl">OD đo (mm)<input className="inp text-right" name="od" defaultValue={res?.pilot_od_mm ?? ''} /></label>
                  </div>
                  <div><SubmitButton className="btn btn-pri">Lưu kết quả pilot</SubmitButton></div>
                </form>
              ) : (
                <section className="card p-4 text-[14px]"><h2 className="mb-2 font-medium">Kết quả pilot</h2>
                  {res?.pilot_rdc === null || res?.pilot_rdc === undefined ? 'Chưa đo' : `Rdc ${nf(res.pilot_rdc, 3)} Ω/km · ${nf(res.pilot_kgkm, 2)} kg/km · OD ${nf(res.pilot_od_mm, 2)} mm`}</section>
              )}
              {editable && can(me, 'spec', 'edit') ? (
                <form action={saveDeviation} className="card flex flex-col gap-3 p-4">{hidden}
                  <h2 className="font-medium">Chấp nhận sai lệch Rdc (TP Kỹ thuật/QA)</h2>
                  <textarea className="inp" name="note" rows={3} defaultValue={spec.rdc_deviation_note ?? ''} placeholder="Lý do và căn cứ: đã thử 3 mẫu, Rdc đo 25,8 Ω/km, đạt TCVN…" aria-label="Lý do chấp nhận sai lệch" />
                  <div><SubmitButton className="btn">Lưu</SubmitButton></div>
                </form>
              ) : spec.rdc_deviation_note && <section className="card p-4 text-[14px]"><h2 className="mb-2 font-medium">Chấp nhận sai lệch</h2>{spec.rdc_deviation_note}</section>}
            </div>
          )}

          {tab === 'lich-su' && (
            <section className="card overflow-x-auto">
              {reqs && reqs.length > 0 ? (
                <table className="tbl">
                  <thead><tr><th>Yêu cầu</th><th>Gửi lúc</th><th>Người gửi</th><th>Kết quả</th></tr></thead>
                  <tbody>{reqs.map((r) => (
                    <tr key={r.id}><td><Link className="link" href={`/duyet/${r.id}`}>{r.doc_no}</Link></td><td>{df(r.submitted_at, true)}</td><td>{r.submitted_by_name}</td>
                      <td><StatusPill map={{ PENDING: ['Đang xử lý', 'info'], APPROVED: ['Đã duyệt', 'ok'], REJECTED: ['Bị trả lại', 'bad'], CANCELLED: ['Đã hủy', 'mute'] }} value={r.status} /></td></tr>
                  ))}</tbody>
                </table>
              ) : <Empty>Phiên bản này chưa gửi duyệt lần nào.</Empty>}
            </section>
          )}
        </div>

        <aside className="flex flex-col gap-4">
          <section className="card p-4">
            <h2 className="mb-2 font-medium">Định mức và kiểm tra · v{spec.version} <StatusPill map={SPEC_STATUS} value={spec.status} /></h2>
            <table className="w-full text-[14px]">
              <tbody className="[&_td]:py-1">
                <tr><td className="text-muted">Đồng / kim loại</td><td className="num">{nf(res?.metal_kgkm, 3)} kg/km</td></tr>
                <tr><td className="text-muted">Cách điện</td><td className="num">{nf(res?.ins_kgkm, 3)} kg/km</td></tr>
                <tr><td className="text-muted">Tổng</td><td className="num font-medium">{nf(res?.total_kgkm, 2)} kg/km</td></tr>
                <tr><td className="text-muted">OD</td><td className="num">{nf(res?.od_mm, 2)} mm</td></tr>
                <tr><td className="text-muted">Rdc tính / giới hạn</td><td className={`num ${res && res.rdc_limit !== null && res.rdc_calc > res.rdc_limit ? 'font-medium text-bad' : ''}`}>{nf(res?.rdc_calc, 3)} / {res?.rdc_limit === null ? '—' : nf(res?.rdc_limit, 2)}</td></tr>
              </tbody>
            </table>
            {problems.length > 0 ? (
              <div className="mt-3 rounded border-l-4 border-warn bg-warn-soft px-3 py-2 text-[13px]">
                <b>Chưa đủ điều kiện phát hành:</b>
                <ul className="mt-1 list-disc pl-5">{problems.map((x) => <li key={x}>{x}</li>)}</ul>
              </div>
            ) : <div className="mt-3 rounded border-l-4 border-brand bg-brand-soft px-3 py-2 text-[13px] text-brand-dark">Đạt kiểm tra tự động.</div>}
          </section>
          <section className="card p-4 text-[14px]">
            <div className="flex justify-between py-1"><span className="text-muted">Nhóm</span><span>{p.group_name}</span></div>
            <div className="flex justify-between py-1"><span className="text-muted">Mức thay đổi</span><span>{spec.change_level === 'MINOR' ? 'Nhỏ' : spec.change_level === 'MAJOR' ? 'Lớn' : 'Mã mới'}</span></div>
            <div className="flex justify-between py-1"><span className="text-muted">Phát hành lúc</span><span>{df(spec.released_at, true)}</span></div>
            {p.spec_status === 'RELEASED' && p.spec_id !== specId && <Pill tone="info">Bản hiện hành vẫn là v{p.version} cho tới khi bản này được duyệt</Pill>}
          </section>
        </aside>
      </div>
    </>
  );
}
