import Link from 'next/link';
import { Printer } from 'lucide-react';
import { SubmitButton } from '@/components/submit-button';
import { Empty, Flash, Pill, Tabs, Toolbar } from '@/components/ui';
import { df, nf, numIn } from '@/lib/format';
import { LOC_KINDS, hasRole, keeps } from '@/lib/kho';
import { requireMe } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { createOpening, saveLocation, saveMaterialStock, savePackage, saveSetting } from './actions';

export const metadata = { title: 'Cài đặt kho' };

const TABS = ['so', 'vi-tri', 'bi', 'vat-tu', 'dau-ky'] as const;

export default async function SettingsPage({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string; tab?: string }> }) {
  const sp = await searchParams;
  const me = await requireMe();
  const tab = (TABS as readonly string[]).includes(sp.tab ?? '') ? sp.tab! : 'so';
  const supabase = await createClient();
  const admin = hasRole(me, 'ADMIN');
  const [{ data: settings }, { data: locs }, { data: pkgs }, { data: mats }, { data: whs }, { data: groups }] = await Promise.all([
    supabase.schema('app').from('v_inv_settings').select('*').order('sort'),
    supabase.schema('app').from('v_locations').select('*').order('warehouse_code').order('sort'),
    supabase.schema('master').from('package_types').select('*').order('code'),
    tab === 'vat-tu' ? supabase.schema('master').from('materials').select('id, code, name, uom, reorder_point, shelf_life_days, storage_zone, abc_class, has_expiry').eq('is_scrap', false).order('code') : Promise.resolve({ data: [] as never[] }),
    supabase.schema('inv').from('warehouses').select('id, code, name').order('code'),
    supabase.schema('master').from('material_groups').select('code, name').order('code'),
  ]);
  const canMat = hasRole(me, 'ADMIN', 'KT_KHO', 'MUA_NV', 'MUA_TP');
  const canPkg = hasRole(me, 'ADMIN', 'THU_KHO', 'MUA_NV', 'KT_KHO');
  const canLoc = (wh: string) => admin || keeps(me, wh as 'KNL');
  return (
    <>
      <Toolbar title="Cài đặt kho" reload={`/kho/cai-dat?tab=${tab}`} />
      <Tabs active={tab} items={[
        { key: 'so', label: 'Thông số', href: '/kho/cai-dat' }, { key: 'vi-tri', label: 'Vị trí kho', href: '/kho/cai-dat?tab=vi-tri' },
        { key: 'bi', label: 'Bảng bì', href: '/kho/cai-dat?tab=bi' }, { key: 'vat-tu', label: 'Vật tư: mức đặt hàng, HSD', href: '/kho/cai-dat?tab=vat-tu' },
        { key: 'dau-ky', label: 'Tồn đầu kỳ', href: '/kho/cai-dat?tab=dau-ky' },
      ]} />
      <Flash ok={sp.ok} err={sp.err} />

      {tab === 'so' && (
        <section className="card overflow-x-auto">
          <table className="tbl">
            <thead><tr><th>Thông số</th><th>Giá trị</th><th>Người phụ trách</th><th>Sửa lần cuối</th></tr></thead>
            <tbody>{(settings ?? []).map((s) => {
              const editable = admin || (s.owner_role && me.roles.includes(s.owner_role));
              return (
                <tr key={s.key}>
                  <td className="min-w-[260px]">{s.label}</td>
                  <td>{editable ? (
                    <form action={saveSetting} className="flex items-center gap-1.5">
                      <input type="hidden" name="key" value={s.key} />
                      {s.key === 'issue_hours'
                        ? <input className="inp inp-y w-56" name="text_value" defaultValue={s.text_value ?? ''} placeholder="06:30-08:00,16:30-17:30" aria-label={s.label} />
                        : <input className="inp inp-y w-24 text-right" name="num_value" defaultValue={numIn(s.num_value)} inputMode="decimal" aria-label={s.label} />}
                      <span className="text-[13px] text-muted">{s.unit}</span>
                      <SubmitButton className="btn btn-sm btn-soft" pendingText="…">Lưu</SubmitButton>
                    </form>
                  ) : <b>{s.key === 'issue_hours' ? s.text_value ?? 'không giới hạn' : `${nf(s.num_value, 2)} ${s.unit ?? ''}`}</b>}</td>
                  <td>{s.owner_role_name ?? 'Quản trị'}</td>
                  <td className="text-[12.5px] text-muted">{s.updated_by_name ? `${s.updated_by_name} · ${df(s.updated_at, true)}` : '—'}</td>
                </tr>
              );
            })}</tbody>
          </table>
          <p className="border-t border-line px-4 py-2 text-[12.5px] text-muted">Mức lệch cân bằng đồng, tiêu hao, vượt dày do TP Kỹ thuật/QA ban hành (Quy chuẩn mục 2). Người giữ kho: kho NVL, BTP, phế – vai trò Thủ kho (Quản lý SX); kho thành phẩm – vai trò NV kho (NV5).</p>
        </section>
      )}

      {tab === 'vi-tri' && (
        <div className="flex flex-col gap-4">
          {(whs ?? []).map((w) => (
            <section key={w.id} className="card overflow-x-auto">
              <div className="card-h">{w.code} · {w.name}<Link className="btn btn-sm btn-soft" href={`/in/tem?loc=${w.code}`} target="_blank"><Printer size={14} />In tem vị trí</Link></div>
              <table className="tbl">
                <thead><tr><th>Mã</th><th>Tên</th><th>Loại</th><th className="num">Đơn vị đang chứa</th><th>Dùng</th>{canLoc(w.code) && <th />}</tr></thead>
                <tbody>
                  {(locs ?? []).filter((l) => l.warehouse_code === w.code).map((l) => canLoc(w.code) ? (
                    <tr key={l.id}>
                      <td colSpan={6} className="p-0">
                        <form action={saveLocation} className="grid grid-cols-[1fr_2fr_1fr_0.6fr_0.6fr_auto] items-center gap-2 px-3 py-2">
                          <input type="hidden" name="id" value={l.id} /><input type="hidden" name="wh" value={w.code} />
                          <input className="inp mono" name="code" defaultValue={l.code} aria-label="Mã vị trí" />
                          <input className="inp" name="name" defaultValue={l.name ?? ''} aria-label="Tên vị trí" />
                          <select className="inp" name="kind" defaultValue={l.kind} aria-label="Loại vị trí">{Object.entries(LOC_KINDS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
                          <span className="num">{l.units}</span>
                          <select className="inp" name="active" defaultValue={l.active ? 'on' : 'off'} aria-label="Đang dùng"><option value="on">Có</option><option value="off">Ngưng</option></select>
                          <SubmitButton className="btn btn-sm btn-soft" pendingText="…">Lưu</SubmitButton>
                        </form>
                      </td>
                    </tr>
                  ) : (
                    <tr key={l.id}><td className="mono">{l.code}</td><td>{l.name}</td><td>{LOC_KINDS[l.kind] ?? l.kind}</td><td className="num">{l.units}</td><td>{l.active ? 'Có' : <Pill>Ngưng</Pill>}</td></tr>
                  ))}
                </tbody>
              </table>
              {canLoc(w.code) && (
                <form action={saveLocation} className="grid gap-2 border-t border-line p-3 sm:grid-cols-[1fr_2fr_1fr_auto]">
                  <input type="hidden" name="wh" value={w.code} />
                  <input className="inp mono" name="code" placeholder={`${w.code}-A1`} required aria-label="Mã vị trí mới" />
                  <input className="inp" name="name" placeholder="Tên/mô tả" aria-label="Tên vị trí mới" />
                  <select className="inp" name="kind" aria-label="Loại vị trí mới">{Object.entries(LOC_KINDS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
                  <SubmitButton className="btn btn-soft">Thêm vị trí</SubmitButton>
                </form>
              )}
            </section>
          ))}
        </div>
      )}

      {tab === 'bi' && (
        <section className="card overflow-x-auto">
          <div className="card-h">Bảng bì ống/thùng/bao (kg tịnh = cân tổng − bì)</div>
          {pkgs && pkgs.length > 0 ? (
            <table className="tbl"><tbody>{pkgs.map((p) => canPkg ? (
              <tr key={p.id}><td colSpan={5} className="p-0">
                <form action={savePackage} className="grid grid-cols-[1fr_2fr_0.8fr_1.2fr_0.6fr_auto] items-center gap-2 px-3 py-2">
                  <input type="hidden" name="id" value={p.id} />
                  <input className="inp mono" name="code" defaultValue={p.code} aria-label="Mã" />
                  <input className="inp" name="name" defaultValue={p.name} aria-label="Tên" />
                  <input className="inp inp-y text-right" name="tare_kg" defaultValue={numIn(p.tare_kg)} inputMode="decimal" aria-label="Bì kg" />
                  <select className="inp" name="group" defaultValue={p.material_group ?? ''} aria-label="Nhóm vật tư"><option value="">Mọi nhóm</option>{(groups ?? []).map((g) => <option key={g.code} value={g.code}>{g.name}</option>)}</select>
                  <select className="inp" name="active" defaultValue={p.active ? 'on' : 'off'} aria-label="Dùng"><option value="on">Dùng</option><option value="off">Ngưng</option></select>
                  <SubmitButton className="btn btn-sm btn-soft" pendingText="…">Lưu</SubmitButton>
                </form>
              </td></tr>
            ) : (
              <tr key={p.id}><td className="mono">{p.code}</td><td>{p.name}</td><td className="num">{nf(p.tare_kg, 3)} kg</td></tr>
            ))}</tbody></table>
          ) : <Empty>Chưa có loại bao bì nào. Thêm theo ống/thùng của từng nhà cung cấp.</Empty>}
          {canPkg && (
            <form action={savePackage} className="grid gap-2 border-t border-line p-3 sm:grid-cols-[1fr_2fr_0.8fr_1.2fr_auto]">
              <input className="inp mono" name="code" placeholder="ONG-CU-NCCA" required aria-label="Mã mới" />
              <input className="inp" name="name" placeholder="Ống nhựa đồng NCC A" required aria-label="Tên mới" />
              <input className="inp inp-y text-right" name="tare_kg" placeholder="bì kg" inputMode="decimal" required aria-label="Bì kg mới" />
              <select className="inp" name="group" aria-label="Nhóm"><option value="">Mọi nhóm</option>{(groups ?? []).map((g) => <option key={g.code} value={g.code}>{g.name}</option>)}</select>
              <SubmitButton className="btn btn-soft">Thêm</SubmitButton>
            </form>
          )}
        </section>
      )}

      {tab === 'vat-tu' && (
        <section className="card overflow-x-auto">
          <div className="card-h">Mức đặt hàng (Kế toán SX theo dõi, báo NV mua hàng), hạn dùng, khu cất, nhóm kiểm kê</div>
          <table className="tbl">
            <thead><tr><th>Mã</th><th>Vật tư</th><th>Mức đặt hàng</th><th>Hạn dùng (ngày)</th><th>Khu cất</th><th>Nhóm ABC</th>{canMat && <th />}</tr></thead>
            <tbody>{(mats ?? []).map((m) => (
              <tr key={m.id}>
                <td className="mono font-medium">{m.code}</td><td className="min-w-[160px]">{m.name}{m.has_expiry && <> <Pill tone="info">Có HSD</Pill></>}</td>
                {canMat ? (
                  <>
                    <td><input form={`m-${m.id}`} className="inp inp-y w-24 text-right" name="reorder_point" defaultValue={m.reorder_point ?? ''} inputMode="decimal" aria-label={`Mức đặt hàng ${m.code}`} /> <span className="text-[12px] text-muted">{m.uom}</span></td>
                    <td><input form={`m-${m.id}`} className="inp w-20 text-right" name="shelf_life_days" defaultValue={m.shelf_life_days ?? ''} inputMode="numeric" aria-label={`Hạn dùng ${m.code}`} /></td>
                    <td><select form={`m-${m.id}`} className="inp w-28" name="zone" defaultValue={m.storage_zone ?? ''} aria-label={`Khu cất ${m.code}`}><option value="">—</option><option value="THUONG">Thường</option><option value="MAT">Mát</option><option value="HOA_CHAT">Hóa chất</option></select></td>
                    <td><select form={`m-${m.id}`} className="inp w-16" name="abc" defaultValue={m.abc_class ?? ''} aria-label={`Nhóm ABC ${m.code}`}><option value="">—</option><option>A</option><option>B</option><option>C</option></select></td>
                    <td><form id={`m-${m.id}`} action={saveMaterialStock}><input type="hidden" name="material_id" value={m.id} /><input type="hidden" name="code" value={m.code} /><SubmitButton className="btn btn-sm btn-soft" pendingText="…">Lưu</SubmitButton></form></td>
                  </>
                ) : (
                  <><td className="num">{nf(m.reorder_point, 2)}</td><td className="num">{m.shelf_life_days ?? '—'}</td><td>{m.storage_zone ?? '—'}</td><td>{m.abc_class ?? '—'}</td></>
                )}
              </tr>
            ))}</tbody>
          </table>
        </section>
      )}

      {tab === 'dau-ky' && (
        hasRole(me, 'KT_KHO') ? (
          <form action={createOpening} className="card grid gap-3 p-4 md:grid-cols-[1fr_1fr]">
            <label className="lbl"><span className="req">Kho</span><select className="inp inp-y" name="warehouse_id" required>{(whs ?? []).map((w) => <option key={w.id} value={w.id}>{w.code} · {w.name}</option>)}</select></label>
            <label className="lbl">Ngày tồn đầu kỳ<input className="inp" type="date" name="doc_date" /></label>
            <label className="lbl md:col-span-2"><span className="req">Mỗi dòng: MÃ; số lượng; đơn giá; vị trí; số đơn vị; HSD (dd/mm/yyyy); thương hiệu</span>
              <textarea className="inp inp-y font-mono" name="lines" rows={8} required placeholder={'CU-024; 420; 268000; KNL-CU; 3\nSIL-9710G; 200; 95000; KNL-SI; 8; 30/03/2027\nPFR-2C-1p5; 1500; ; KTP-A; 3; ; KAVIX'} /></label>
            <p className="text-[12.5px] text-muted md:col-span-2">Số lượng chia đều cho số đơn vị (ống/bao/bobin), mỗi đơn vị một tem QR. Nguyên vật liệu bắt buộc có đơn giá. Kế toán trưởng duyệt xong mới ghi sổ (Quy chuẩn mục 8).</p>
            <div><SubmitButton>Lập tồn đầu kỳ, gửi duyệt</SubmitButton></div>
          </form>
        ) : <div className="card"><Empty>Tồn đầu kỳ do Kế toán SX lập, Kế toán trưởng duyệt.</Empty></div>
      )}
    </>
  );
}
