import Link from 'next/link';
import { notFound } from 'next/navigation';
import { SubmitButton } from '@/components/submit-button';
import { Flash, PageHeader, Pill, StatusPill } from '@/components/ui';
import { DOC_STATUS, SPEC_STATUS, nf } from '@/lib/format';
import { can, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { newVersion, recordPilot, saveDeviation, submitSpec } from './actions';

const BASIS: Record<string, string> = { KM: '/km', PACK: '/kiện', PALLET: '/pallet', LOT: '/lô' };

export default async function ProductDetail({ params, searchParams }:
  { params: Promise<{ code: string }>; searchParams: Promise<{ ok?: string; err?: string }> }) {
  const { code } = await params;
  const sp = await searchParams;
  const me = await requirePerm('spec', 'view');
  const supabase = await createClient();
  const { data: p } = await supabase.schema('app').from('v_products').select('*').eq('code', decodeURIComponent(code)).maybeSingle();
  if (!p) notFound();
  const [{ data: spec }, { data: issues }, { data: bom }, { data: reqs }] = await Promise.all([
    supabase.schema('master').from('product_specs').select('*').eq('id', p.spec_id).single(),
    supabase.schema('master').rpc('check_spec', { p_spec: p.spec_id }),
    supabase.schema('app').from('v_bom_lines').select('*').eq('spec_id', p.spec_id).order('operation_code').order('material_code'),
    supabase.schema('app').from('v_approvals').select('id, doc_no, status, current_level, submitted_at').eq('doc_id', p.spec_id).order('submitted_at', { ascending: false }),
  ]);
  const problems = (issues as string[] | null) ?? [];
  const editable = !['RELEASED', 'OBSOLETE', 'PENDING_APPROVAL'].includes(p.spec_status);
  const pending = reqs?.find((r) => r.status === 'PENDING');

  const facts: [string, React.ReactNode][] = spec ? [
    ['Mã lõi', spec.core_code], ['Số lõi / cặp', `${spec.cores} / ${spec.pairs}`], ['Ruột dẫn', `${spec.wire_count}×${nf(spec.wire_dia_mm, 2)} mm ${spec.conductor_mat}`],
    ['Bước bện', `${nf(spec.pitch_mm, 1)} mm`], ['Cách điện', `${spec.insulation} · ${nf(spec.ins_thickness_mm, 2)} mm`],
    ['Vỏ', `${spec.sheath}${spec.sheath_thickness_mm ? ' · ' + nf(spec.sheath_thickness_mm, 2) + ' mm' : ''}`],
    ['Màn chắn / drain', spec.shield ? `AL/PET ${spec.alpet_width_mm} mm · ${spec.drain_mat} ${spec.drain_wires ?? ''}×${nf(spec.drain_dia_mm, 2)}` : 'Không'],
    ['Màu vỏ / cách điện', `${spec.sheath_color ?? '—'} · ${spec.insulation_colors ?? '—'}`], ['Thương hiệu', spec.brand],
    ['Đóng gói', `${spec.pack_type} · ${nf(spec.m_per_pack)} m/kiện`], ['Cơ sở dữ liệu', spec.source_basis],
  ] : [];

  return (
    <>
      <PageHeader
        title={p.code}
        sub={<>{p.description} · {p.group_name} · Spec v{p.version} <StatusPill map={SPEC_STATUS} value={p.spec_status} /></>}
        actions={<Link className="btn" href="/san-pham">← Danh sách</Link>}
      />
      <Flash ok={sp.ok} err={sp.err} />

      <div className="grid gap-4 xl:grid-cols-[1.2fr_1fr]">
        <section className="card p-4">
          <h2 className="mb-3 font-semibold">Cấu trúc</h2>
          <dl className="grid grid-cols-1 gap-x-6 gap-y-2 text-[13px] sm:grid-cols-2">
            {facts.map(([k, v]) => <div key={k}><dt className="text-[11px] uppercase tracking-wide text-muted">{k}</dt><dd className="font-medium">{v}</dd></div>)}
          </dl>
          {spec?.config_note && <p className="mt-3 text-[12px] text-muted">Lưu ý cấu hình: {spec.config_note}</p>}
        </section>

        <section className="card p-4">
          <h2 className="mb-3 font-semibold">Định mức và kiểm tra</h2>
          <table className="tbl mb-3">
            <tbody>
              <tr><td>Đồng / kim loại</td><td className="num">{nf(p.metal_kgkm, 3)} kg/km</td></tr>
              <tr><td>Cách điện</td><td className="num">{nf(p.ins_kgkm, 3)} kg/km</td></tr>
              <tr><td>Tổng</td><td className="num font-semibold">{nf(p.total_kgkm, 2)} kg/km</td></tr>
              <tr><td>OD</td><td className="num">{nf(p.od_mm, 2)} mm</td></tr>
              <tr><td>Rdc tính / giới hạn</td><td className={`num ${p.rdc_over ? 'font-semibold text-bad' : ''}`}>{nf(p.rdc_calc, 3)} / {p.rdc_limit === null ? '—' : nf(p.rdc_limit, 2)} Ω/km</td></tr>
              <tr><td>Pilot: Rdc / kg/km</td><td className="num">{p.pilot_rdc === null ? 'Chưa đo' : `${nf(p.pilot_rdc, 3)} / ${nf(p.pilot_kgkm, 2)}`}</td></tr>
            </tbody>
          </table>
          {problems.length > 0 ? (
            <div className="rounded-md border border-warn/50 bg-warn-soft px-3 py-2 text-[12.5px] text-warn">
              <b>Chưa đủ điều kiện phát hành:</b>
              <ul className="mt-1 list-disc pl-5">{problems.map((x) => <li key={x}>{x}</li>)}</ul>
            </div>
          ) : <div className="rounded-md border border-ok/40 bg-ok-soft px-3 py-2 text-[12.5px] text-ok">Đạt kiểm tra tự động, có thể gửi duyệt phát hành.</div>}

          <div className="mt-3 flex flex-wrap gap-2">
            {editable && can(me, 'spec', 'create') && (
              <form action={submitSpec}>
                <input type="hidden" name="spec_id" value={p.spec_id} /><input type="hidden" name="code" value={p.code} /><input type="hidden" name="version" value={p.version} />
                <SubmitButton className="btn btn-pri">Gửi duyệt phát hành</SubmitButton>
              </form>
            )}
            {p.spec_status === 'RELEASED' && can(me, 'spec', 'create') && (
              <form action={newVersion}>
                <input type="hidden" name="spec_id" value={p.spec_id} /><input type="hidden" name="code" value={p.code} />
                <select className="inp w-auto" name="level" aria-label="Mức thay đổi" defaultValue="MINOR">
                  <option value="MINOR">Thay đổi nhỏ</option><option value="MAJOR">Thay đổi lớn (cần pilot)</option>
                </select>{' '}
                <SubmitButton className="btn">Tạo phiên bản mới</SubmitButton>
              </form>
            )}
            {pending && <Link className="btn" href={`/duyet/${pending.id}`}>Xem yêu cầu duyệt ({pending.current_level})</Link>}
          </div>
        </section>
      </div>

      {editable && (can(me, 'quality', 'edit') || can(me, 'spec', 'edit')) && (
        <div className="mt-4 grid gap-4 lg:grid-cols-2">
          <form action={recordPilot} className="card flex flex-col gap-3 p-4">
            <h2 className="font-semibold">Kết quả pilot (QC nhập)</h2>
            <input type="hidden" name="spec_id" value={p.spec_id} /><input type="hidden" name="code" value={p.code} />
            <div className="grid grid-cols-3 gap-3">
              <label className="lbl">Rdc đo (Ω/km)<input className="inp inp-y" name="rdc" defaultValue={p.pilot_rdc ?? ''} required /></label>
              <label className="lbl">kg/km cân thực<input className="inp inp-y" name="kgkm" defaultValue={p.pilot_kgkm ?? ''} /></label>
              <label className="lbl">OD đo (mm)<input className="inp inp-y" name="od" /></label>
            </div>
            <div><SubmitButton className="btn">Lưu kết quả pilot</SubmitButton></div>
          </form>
          {can(me, 'spec', 'edit') && (
            <form action={saveDeviation} className="card flex flex-col gap-3 p-4">
              <h2 className="font-semibold">Chấp nhận sai lệch Rdc (TP Kỹ thuật/QA)</h2>
              <input type="hidden" name="spec_id" value={p.spec_id} /><input type="hidden" name="code" value={p.code} />
              <label className="lbl">Lý do và căn cứ
                <textarea className="inp" name="note" rows={3} defaultValue={spec?.rdc_deviation_note ?? ''} placeholder="Ví dụ: đã thử 3 mẫu, Rdc đo 25,8 Ω/km, đạt TCVN…" />
              </label>
              <div><SubmitButton className="btn">Lưu</SubmitButton></div>
            </form>
          )}
        </div>
      )}

      <section className="card mt-4 overflow-x-auto">
        <div className="border-b border-line px-4 py-2.5 font-semibold">BOM v{p.version} · {bom?.length ?? 0} dòng</div>
        <table className="tbl">
          <thead><tr><th>Công đoạn</th><th>Mã VT</th><th>Vật tư</th><th className="num">Suất</th><th>ĐVT</th><th className="num">Hao hụt</th><th className="num">Khởi động / lô</th></tr></thead>
          <tbody>
            {(bom ?? []).map((l) => (
              <tr key={l.id}>
                <td className="mono">{l.operation_code}</td><td className="mono font-semibold">{l.material_code}</td><td>{l.material_name}</td>
                <td className="num">{nf(l.qty_per_basis, 4)}</td><td className="whitespace-nowrap">{l.uom}{BASIS[l.basis]}</td>
                <td className="num">{nf(l.loss_rate * 100, 1)}%</td><td className="num">{Number(l.startup_per_lot) ? nf(l.startup_per_lot, 3) : '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>

      {reqs && reqs.length > 0 && (
        <section className="card mt-4 p-4">
          <h2 className="mb-2 font-semibold">Lịch sử duyệt</h2>
          <ul className="flex flex-col gap-1 text-[13px]">
            {reqs.map((r) => <li key={r.id}><Link className="mono text-copper" href={`/duyet/${r.id}`}>{r.doc_no}</Link> <StatusPill map={DOC_STATUS} value={r.status} /> {r.status === 'PENDING' && <Pill tone="info">{r.current_level}</Pill>}</li>)}
          </ul>
        </section>
      )}
    </>
  );
}
