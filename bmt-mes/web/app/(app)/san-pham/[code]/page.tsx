import Link from 'next/link';
import { notFound, redirect } from 'next/navigation';
import { Calculator, CopyPlus, Send, Trash2 } from 'lucide-react';
import { SpecFields, type SpecBomLine } from '@/components/spec-form';
import { StageBar, type Stage } from '@/components/stage-bar';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Pill, StatusPill, Toolbar } from '@/components/ui';
import type { Approval } from '@/lib/approvals';
import { SPEC_STATUS, df, nf, numIn } from '@/lib/format';
import { can, requirePage, requirePerm } from '@/lib/session';
import { wireText } from '@/lib/spec';
import { createClient } from '@/lib/supabase/server';
import { adminDeleteBomLine, adminDeleteVersion, adminSaveBomLine, adminApplyConductor, adminRenameProduct, adminUpdateSpec, deleteBomLine, newVersion, previewSpec, recordPilot, saveBomLine, saveDeviation, submitSpec, updateSpec } from './actions';

const BASIS: Record<string, string> = { KM: '/km', PACK: '/kiện', PALLET: '/pallet', LOT: '/lô' };
const INS_NAME: Record<string, string> = { SIL: 'Silicone', HDPE: 'HDPE', PVC: 'PVC' };
const OPS = ['CD0', 'CD1', 'CD2', 'CD3', 'CD4', 'CD5', 'CD6'];

export default async function ProductDetail({ params, searchParams }:
  { params: Promise<{ code: string }>; searchParams: Promise<{ ok?: string; err?: string; v?: string; tab?: string; tam?: string }> }) {
  const { code: rawCode } = await params;
  const code = decodeURIComponent(rawCode);
  // Mã sản phẩm viết IN HOA từ 27/10/2026 (1p5 → 1P5): đường dẫn cũ chữ thường chuyển sang mã mới
  if (code !== code.toUpperCase()) redirect(`/san-pham/${encodeURIComponent(code.toUpperCase())}`);
  const sp = await searchParams;
  await requirePage('san-pham');
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
  const [{ data: pallets }, { data: bomIss }, { data: coreType }] = await Promise.all([
    supabase.schema('master').from('tech_params').select('code, value').eq('set_id', spec.param_set_id).in('code', ['palletW', 'palletC']),
    supabase.schema('master').rpc('bom_issues', { p_spec: specId }),
    supabase.schema('master').from('core_types').select('rdc_source').eq('set_id', spec.param_set_id).eq('code', spec.core_code).maybeSingle(),
  ]);
  const perPallet = Number((pallets ?? []).find((x) => x.code === (spec.pack_type === 'Cuộn PE' ? 'palletC' : 'palletW'))?.value) || null;
  const { data: flow } = await supabase.schema('wf').from('approval_steps').select('seq, level_label, role_code')
    .eq('doc_type', 'SPEC_NEW').eq('enabled', true).order('seq');
  const problems = (issues as string[] | null) ?? [];
  const editable = ['DRAFT', 'PILOT_PENDING', 'PILOT'].includes(spec.status) && (can(me, 'spec', 'edit') || can(me, 'spec', 'create'));
  // Quản trị hệ thống sửa được cả spec đã phát hành / đang duyệt (giữ trạng thái, bắt buộc lý do, ghi nhật ký)
  const adminEdit = !editable && me.is_admin === true && spec.status !== 'OBSOLETE';
  const canEdit = editable || adminEdit;
  // Tạm tính (chưa lưu): số đang nhập gửi qua tham số tam, database tính trong giao dịch con rồi hủy
  let tam: Record<string, unknown> | null = null;
  try { tam = sp.tam && canEdit ? JSON.parse(sp.tam) : null; } catch { tam = null; }
  const tamReason = tam && typeof tam._reason === 'string' ? tam._reason : '';
  if (tam) delete tam._reason;
  const pv = tam ? await supabase.schema('app').rpc('spec_preview', { p_spec: specId, p: tam }) : null;
  const preview = (pv?.data ?? null) as { spec: Record<string, unknown>; res: Record<string, unknown> | null; issues: string[] | null; bom?: SpecBomLine[] } | null;
  const formVals = { ...spec, ...(res ?? {}), ...(preview ? { ...preview.spec, ...(preview.res ?? {}) } : {}) };
  const reasonField = adminEdit ? <AdminReason status={spec.status} d={tamReason} /> : null;
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
            <form action={submitSpec}>{hidden}<input type="hidden" name="version" value={spec.version} />
              <SubmitButton className="btn btn-pri" ><Send size={15} />Gửi duyệt phát hành</SubmitButton></form>
          )}
          {spec.status === 'RELEASED' && can(me, 'spec', 'create') && (
            <form action={newVersion} className="flex gap-1">{hidden}
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
      {me.is_admin && (
        <details className="mb-4 rounded border border-line bg-surface px-4 py-2 text-[14px]" id="admin-xoa-phien-ban">
          <summary className="cursor-pointer font-medium text-bad">Quản trị hệ thống: xóa phiên bản v{spec.version} đang xem</summary>
          <form action={adminDeleteVersion} className="mt-2 flex flex-wrap items-end gap-2">{hidden}
            <label className="min-w-[260px] flex-1 text-[13px]">Lý do xóa<input className="inp block w-full" name="reason" required /></label>
            <label className="flex items-center gap-2 text-[13px]"><input type="checkbox" name="confirm" />Tôi hiểu phiên bản sẽ bị xóa hẳn</label>
            <SubmitButton className="btn btn-sm btn-bad-o"><Trash2 size={14} />Xóa phiên bản v{spec.version}</SubmitButton>
          </form>
          <p className="mt-2 text-[12.5px] text-muted">Xóa cả BOM của phiên bản. Không xóa được khi phiên bản đang được kế hoạch, lệnh SX, lô hàng dùng hoặc là bản duy nhất của mã. Xóa bản hiện hành thì mã chuyển sang bản đã phát hành gần nhất còn lại (bản cũ được phát hành lại).</p>
        </details>
      )}
      {me.is_admin && spec.status !== 'OBSOLETE' && (
        <details className="mb-4 rounded border border-line bg-surface px-4 py-2 text-[14px]" id="admin-chuan-ruot">
          <summary className="cursor-pointer font-medium text-brand">Quản trị hệ thống: lấy ruột dẫn của {code} v{spec.version} làm chuẩn cho mọi mã lõi {spec.core_code}</summary>
          <form action={adminApplyConductor} className="mt-2 flex flex-wrap items-end gap-2">{hidden}
            <label className="min-w-[260px] flex-1 text-[13px]"><span className="req">Lý do</span><input className="inp block w-full" name="reason" required /></label>
            <SubmitButton className="btn btn-sm btn-pri">Áp ruột dẫn cho mọi mã lõi {spec.core_code}</SubmitButton>
          </form>
          <p className="mt-2 text-[12.5px] text-muted">Mọi spec còn hiệu lực cùng mã lõi {spec.core_code}, cùng vật liệu {spec.conductor_mat} nhận các loại sợi ({wireText(spec)}) và bước bện của bản này; hệ số ghép K, trạng thái từng mã giữ nguyên. MES tính lại đồng, Rdc, BOM; kế hoạch dùng các mã đó cần chạy lại MRP; ghi nhật ký từng spec.</p>
        </details>
      )}
      {me.is_admin && (
        <details className="mb-4 rounded border border-line bg-surface px-4 py-2 text-[14px]" id="admin-doi-ma">
          <summary className="cursor-pointer font-medium text-brand">Quản trị hệ thống: đổi mã sản phẩm {code}</summary>
          <form action={adminRenameProduct} className="mt-2 flex flex-wrap items-end gap-2">{hidden}<input type="hidden" name="product_id" value={p.id} />
            <label className="w-[220px] text-[13px]"><span className="req">Mã mới</span><input className="inp mono block w-full" name="new_code" required placeholder="VD: CFR-2C-1P0" pattern="[A-Za-z0-9][A-Za-z0-9.\-]*" title="Chữ IN HOA, số, dấu chấm, gạch ngang" /></label>
            <label className="min-w-[260px] flex-1 text-[13px]"><span className="req">Lý do đổi mã</span><input className="inp block w-full" name="reason" required /></label>
            <SubmitButton className="btn btn-sm btn-pri">Đổi mã sản phẩm</SubmitButton>
          </form>
          <p className="mt-2 text-[12.5px] text-muted">Mọi phiên bản spec, BOM, kế hoạch, lệnh SX, lô, tồn kho, đơn bán, lệnh giao, tốc độ máy đi theo mã mới. Lịch máy đã xếp và số hồ sơ duyệt spec đổi theo. Số lô, số phiếu, thông báo đã gửi giữ nguyên. Ghi nhật ký can thiệp của Quản trị, báo TP SX, Kế hoạch SX, TP Mua, TP KT/QA.</p>
        </details>
      )}

      <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_340px]">
        <div className="min-w-0">
          <nav className="mb-3 flex gap-1 border-b border-line" aria-label="Nội dung spec">
            {[['thong-so', 'Thông số'], ['bom', `BOM (${bom?.length ?? 0})`], ['pilot', 'Pilot & sai lệch'], ['lich-su', 'Lịch sử duyệt']].map(([k, l]) => (
              <Link key={k} href={tabHref(k)} aria-current={tab === k ? 'page' : undefined}
                className={`-mb-px border-b-[3px] px-3 py-2.5 text-[15px] ${tab === k ? 'border-brand text-brand' : 'border-transparent hover:text-brand'}`}>{l}</Link>
            ))}
          </nav>

          {tab === 'thong-so' && (canEdit ? (
            <form key={sp.tam ?? 'da-luu'} action={adminEdit ? adminUpdateSpec : updateSpec} className="card flex flex-col gap-4 p-4" id={adminEdit ? 'admin-sua-spec' : undefined}>{hidden}
              {reasonField}
              {pv?.error && <div className="rounded border-l-4 border-bad bg-bad/10 px-3 py-2 text-[13.5px]" id="tam-tinh"><b>Tạm tính chưa được:</b> {pv.error.message}</div>}
              {preview && <PreviewBox before={{ ...spec, ...(res ?? {}) }} after={{ ...preview.spec, ...(preview.res ?? {}) }} issues={preview.issues ?? []} href={`/san-pham/${encodeURIComponent(code)}?v=${specId}&tab=thong-so`} />}
              <div className="lbl">Quy cách (MES tự đặt)<div className="inp bg-sunk">{p.description}</div><span className="text-[12px] text-muted">Theo quy tắc: tiết diện × số lõi (số cặp), cách điện/vỏ, chống nhiễu. Đổi thông số rồi Lưu thì tên tự đổi.</span></div>
              <SpecFields s={formVals} coreCodes={[...new Set((cores ?? []).map((c) => c.code as string))]} bom={preview?.bom ?? ((bom ?? []) as SpecBomLine[])} perPallet={perPallet} bomIssues={(bomIss as string[] | null) ?? null} />
              <div className="flex flex-wrap items-center gap-2 border-t border-line pt-3">
                <SubmitButton className="btn btn-pri">Lưu thông số</SubmitButton>
                <SubmitButton className="btn btn-soft" formAction={previewSpec} noValidate pendingText="Đang tính…"><Calculator size={15} />Tạm tính (chưa lưu)</SubmitButton>
                <span className="text-[12.5px] text-muted">Tạm tính: MES tính đồng, cách điện, Rdc, tiết diện theo số đang nhập; chỉ lưu khi bấm Lưu thông số.</span>
              </div>
            </form>
          ) : (
            <section className="card flex flex-col gap-3 p-4">
              <SpecFields s={{ ...spec, ...(res ?? {}) }} coreCodes={[spec.core_code]} bom={(bom ?? []) as SpecBomLine[]} ro perPallet={perPallet} bomIssues={(bomIss as string[] | null) ?? null} />
              {!editable && spec.status !== 'RELEASED' && <p className="text-[13px] text-muted">Spec đang được duyệt nên không sửa được.</p>}
            </section>
          ))}

          {tab === 'bom' && (
            <section className="card overflow-x-auto">
              <table className="tbl">
                <thead><tr><th>Công đoạn</th><th>Mã VT</th><th>Vật tư</th><th className="num">Suất</th><th>ĐVT</th><th className="num">Hao hụt</th><th className="num">Khởi động / lô</th>{canEdit && <th />}</tr></thead>
                <tbody>
                  {(bom ?? []).map((l) => (
                    <tr key={l.id}>
                      <td className="mono">{l.operation_code}</td><td className="mono font-medium">{l.material_code}</td><td>{l.material_name}</td>
                      <td className="num">{nf(l.qty_per_basis, 4)}</td><td className="whitespace-nowrap">{l.uom}{BASIS[l.basis]}</td>
                      <td className="num">{nf(l.loss_rate * 100, 1)}%</td><td className="num">{Number(l.startup_per_lot) ? nf(l.startup_per_lot, 3) : '—'}</td>
                      {canEdit && <td><form action={adminEdit ? adminDeleteBomLine : deleteBomLine} className="flex gap-1">{hidden}<input type="hidden" name="line_id" value={l.id} />
                        {adminEdit && <input className="inp inp-y w-36" name="reason" placeholder="Lý do xóa" aria-label="Lý do xóa dòng BOM" required />}<SubmitButton className="btn btn-sm btn-bad-o" pendingText="…"><Trash2 size={14} />Xóa</SubmitButton></form></td>}
                    </tr>
                  ))}
                  {(bom ?? []).length === 0 && <tr><td colSpan={8}><Empty>BOM chưa có dòng nào.</Empty></td></tr>}
                </tbody>
              </table>
              {canEdit && (
                <form action={adminEdit ? adminSaveBomLine : saveBomLine} id={adminEdit ? 'admin-sua-bom' : undefined} className="grid gap-3 border-t border-line bg-sunk/50 p-4 md:grid-cols-[2fr_0.8fr_0.8fr_0.7fr_0.8fr_0.8fr_auto] md:items-end">{hidden}
                  <datalist id="mats">{(mats ?? []).map((m) => <option key={m.code} value={`${m.code} · ${m.name} (${m.uom})`} />)}</datalist>
                  <label className="lbl"><span className="req">Vật tư</span><input className="inp" name="material_code" list="mats" required /></label>
                  <label className="lbl"><span className="req">Suất</span><input className="inp text-right" name="qty" inputMode="decimal" required /></label>
                  <label className="lbl">Theo<select className="inp" name="basis"><option value="KM">/km</option><option value="PACK">/kiện</option><option value="PALLET">/pallet</option><option value="LOT">/lô</option></select></label>
                  <label className="lbl">Hao hụt %<input className="inp text-right" name="loss" inputMode="decimal" placeholder="mặc định" /></label>
                  <label className="lbl">Khởi động/lô<input className="inp text-right" name="startup" inputMode="decimal" /></label>
                  <label className="lbl">Công đoạn<select className="inp" name="operation">{OPS.map((o) => <option key={o}>{o}</option>)}</select></label>
                  <SubmitButton className="btn btn-pri">Lưu dòng</SubmitButton>
                  {adminEdit && <div className="md:col-span-7">{reasonField}</div>}
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
                    <label className="lbl"><span className="req">Rdc đo (Ω/km)</span><input className="inp text-right" name="rdc" defaultValue={numIn(res?.pilot_rdc)} required /></label>
                    <label className="lbl">kg/km cân thực<input className="inp text-right" name="kgkm" defaultValue={numIn(res?.pilot_kgkm)} /></label>
                    <label className="lbl">OD đo (mm)<input className="inp text-right" name="od" defaultValue={numIn(res?.pilot_od_mm)} /></label>
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
                <tr><td className="text-muted">Đồng {spec.conductor_mat === 'TC' ? 'mạ thiếc (TC)' : 'trần (BC)'}</td><td className="num">{nf(res?.metal_kgkm, 3)} kg/km</td></tr>
                <tr><td className="text-muted">Cách điện {INS_NAME[spec.insulation] ?? spec.insulation}</td><td className="num">{nf(res?.ins_kgkm, 3)} kg/km</td></tr>
                {spec.sheath && spec.sheath !== 'Không' && <tr><td className="text-muted">Vỏ {spec.sheath}</td><td className="num">{nf(res?.sheath_kgkm, 3)} kg/km</td></tr>}
                {Number(res?.pp_kgkm) > 0 && <tr><td className="text-muted">Độn PP</td><td className="num">{nf(res?.pp_kgkm, 3)} kg/km</td></tr>}
                {Number(res?.pet_kgkm) > 0 && <tr><td className="text-muted">Băng PET</td><td className="num">{nf(res?.pet_kgkm, 3)} kg/km</td></tr>}
                {Number(res?.alpet_kgkm) > 0 && <tr><td className="text-muted">Băng AL/PET</td><td className="num">{nf(res?.alpet_kgkm, 3)} kg/km</td></tr>}
                {Number(res?.drain_kgkm) > 0 && <tr><td className="text-muted">Drain {spec.drain_mat}</td><td className="num">{nf(res?.drain_kgkm, 3)} kg/km</td></tr>}
                <tr><td className="text-muted">Tổng</td><td className="num font-medium">{nf(res?.total_kgkm, 2)} kg/km</td></tr>
                <tr><td className="text-muted">OD</td><td className="num">{nf(res?.od_mm, 2)} mm</td></tr>
                <tr><td className="text-muted">Rdc tính / giới hạn</td><td className={`num ${res && res.rdc_limit !== null && res.rdc_calc > res.rdc_limit ? 'font-medium text-bad' : ''}`}>{nf(res?.rdc_calc, 3)} / {res?.rdc_limit === null ? '—' : nf(res?.rdc_limit, 2)}</td></tr>
                {coreType?.rdc_source && <tr><td colSpan={2} className="text-[12px] text-muted">Giới hạn Rdc: {coreType.rdc_source}</td></tr>}
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
            <div className="flex justify-between py-1"><span className="text-muted">Mức thay đổi</span><span>{spec.change_level === 'MINOR' ? 'Nhỏ (quy trình cũ)' : spec.change_level === 'MAJOR' ? 'Thay đổi phiên bản' : 'Mã mới'}</span></div>
            <div className="flex justify-between py-1"><span className="text-muted">Phát hành lúc</span><span>{df(spec.released_at, true)}</span></div>
            {p.spec_status === 'RELEASED' && p.spec_id !== specId && <Pill tone="info">Bản hiện hành vẫn là v{p.version} cho tới khi bản này được duyệt</Pill>}
          </section>
        </aside>
      </div>
    </>
  );
}

function AdminReason({ status, d = '' }: { status: string; d?: string }) {
  return (
    <div className="rounded border-l-4 border-warn bg-warn/10 px-3 py-2 text-[13.5px]">
      <b>Quản trị hệ thống sửa spec {status === 'RELEASED' ? 'đã phát hành' : 'đang duyệt'}:</b> giữ nguyên trạng thái, ghi nhật ký can thiệp
      {status === 'RELEASED' ? '; kế hoạch đang dùng mã này sẽ cần chạy lại MRP.' : '; lịch sử duyệt ghi lần sửa.'}
      <label className="lbl mt-2"><span className="req">Lý do sửa</span><input className="inp" name="reason" defaultValue={d} required /></label>
    </div>
  );
}

// Khung kết quả tạm tính: số cũ (đang lưu) → số mới (theo ô đang nhập), chưa lưu
function PreviewBox({ before, after, issues, href }: { before: Record<string, unknown>; after: Record<string, unknown>; issues: string[]; href: string }) {
  const rows: [string, string, number][] = [
    ['Tiết diện ruột (mm²)', 'a_total_mm2', 4], ['Đường kính ruột (mm)', 'bundle_dia_mm', 3], ['Đường kính lõi (mm)', 'core_dia_mm', 3],
    ['Đồng (kg/km cáp)', 'metal_kgkm', 3], ['Cách điện (kg/km cáp)', 'ins_kgkm', 3], ['Tổng khối lượng (kg/km)', 'total_kgkm', 3],
    ['Rdc tính (Ω/km)', 'rdc_calc', 3], ['Rdc giới hạn (Ω/km)', 'rdc_limit', 2],
  ];
  const n = (x: unknown) => (x === null || x === undefined || x === '' ? null : Number(x));
  return (
    <section id="tam-tinh" className="rounded border-l-4 border-info bg-info/10 px-3 py-3 text-[13.5px]">
      <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
        <b>Kết quả tạm tính – CHƯA LƯU (các ô bên dưới đang hiện số tạm tính)</b>
        <Link className="btn btn-sm" href={href}>Bỏ tạm tính</Link>
      </div>
      <div className="overflow-x-auto">
        <table className="tbl table-fixed min-w-[460px] bg-surface">
          <colgroup><col /><col className="w-[120px]" /><col className="w-[120px]" /><col className="w-[110px]" /></colgroup>
          <thead><tr><th>Chỉ tiêu</th><th className="num" style={{ textAlign: 'right' }}>Đang lưu</th><th className="num" style={{ textAlign: 'right' }}>Tạm tính</th><th className="num" style={{ textAlign: 'right' }}>Chênh</th></tr></thead>
          <tbody>{rows.map(([label, k, d]) => {
            const a = n(before[k]); const b = n(after[k]); const diff = a !== null && b !== null ? b - a : null;
            const over = k === 'rdc_calc' && b !== null && n(after.rdc_limit) !== null && b > (n(after.rdc_limit) as number);
            return (
              <tr key={k}><td>{label}</td><td className="num">{nf(a, d)}</td>
                <td className={`num font-medium ${over ? 'text-bad' : ''}`}>{nf(b, d)}</td>
                <td className={`num ${diff && Math.abs(diff) > 1e-9 ? (diff > 0 ? 'text-warn' : 'text-brand') : 'text-muted'}`}>{diff === null ? '—' : `${diff > 0 ? '+' : ''}${nf(diff, d)}`}</td></tr>
            );
          })}</tbody>
        </table>
      </div>
      {issues.length > 0
        ? <p className="mt-2 text-[13px]"><b>Chưa đủ điều kiện phát hành:</b> {issues.join('; ')}</p>
        : <p className="mt-2 text-[13px] text-brand-dark">Đạt kiểm tra tự động.</p>}
    </section>
  );
}
