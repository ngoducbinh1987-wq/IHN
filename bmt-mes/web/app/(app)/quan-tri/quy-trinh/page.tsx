import Link from 'next/link';
import { StageBar, type Stage } from '@/components/stage-bar';
import { SubmitButton } from '@/components/submit-button';
import { Flash, Pill, Tabs, Toolbar } from '@/components/ui';
import { ROLE_NAMES, nf } from '@/lib/format';
import { can, requirePage, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { saveStep, saveSubmit } from './actions';

export const metadata = { title: 'Cài đặt quy trình' };

type Step = { seq: number; label: string; role: string; users: string[]; sla_hours: number; warn_hours: number; enabled: boolean;
  min_amount: number | null; flags: string[]; fallback: string | null };
type Flag = { doc_type: string; flag: string; name: string };
type Flow = { doc_type: string; name: string; submit_label: string; submit_role: string | null; submit_user_ids: string[]; steps: Step[]; running: number };
type U = { id: string; full_name: string; status: string; roles: string[] };

const ROLES = Object.keys(ROLE_NAMES);
// Thứ tự hiển thị: luồng đang dùng trên web trước
const ORDER = ['PLAN', 'PR', 'PO', 'SPEC_NEW'];

function People({ users, role, selected }: { users: U[]; role: string | null; selected: string[] }) {
  const list = users.filter((u) => u.status === 'ACTIVE' && (!role || u.roles.includes(role)));
  return (
    <fieldset className="sm:col-span-2 lg:col-span-4">
      <legend className="mb-1 text-[12.5px] text-muted">
        Người thực hiện {role ? <>(đang giữ vai trò <b>{ROLE_NAMES[role] ?? role}</b>)</> : null} · không chọn ai = tất cả người giữ vai trò
      </legend>
      {list.length === 0 ? <div className="text-[13px] text-bad">Chưa có ai giữ vai trò này: gán vai trò ở Hệ thống & cài đặt → Người dùng.</div> : (
        <div className="flex flex-wrap gap-x-5 gap-y-1">
          {list.map((u) => (
            <label key={u.id} className="flex items-center gap-2 text-[14px]">
              <input type="checkbox" name="users" value={u.id} defaultChecked={selected.includes(u.id)} className="accent-[rgb(var(--brand))]" />{u.full_name}
            </label>
          ))}
        </div>
      )}
    </fieldset>
  );
}

export default async function FlowConfig({ searchParams }: { searchParams: Promise<{ f?: string; ok?: string; err?: string }> }) {
  const sp = await searchParams;
  await requirePage('quan-tri-quy-trinh');
  const me = await requirePerm('admin', 'view');
  const editable = can(me, 'admin', 'edit');
  const supabase = await createClient();
  const [{ data: flows }, { data: users }, { data: flagRows }] = await Promise.all([
    supabase.schema('app').from('v_flow_config').select('*').returns<Flow[]>(),
    supabase.schema('app').from('v_users').select('id, full_name, status, roles').order('full_name').returns<U[]>(),
    supabase.schema('app').from('v_flow_flags').select('*').returns<Flag[]>(),
  ]);
  const all = (flows ?? []).sort((a, b) => (ORDER.indexOf(a.doc_type) + 1 || 99) - (ORDER.indexOf(b.doc_type) + 1 || 99) || a.name.localeCompare(b.name));
  const f = all.find((x) => x.doc_type === (sp.f ?? 'PLAN')) ?? all[0];
  const us = users ?? [];
  const name = (id: string) => us.find((u) => u.id === id)?.full_name ?? '?';
  const who = (role: string | null, ids: string[]) =>
    ids.length ? ids.map(name).join(', ') : role ? `Mọi ${ROLE_NAMES[role] ?? role}` : 'Người có quyền tạo chứng từ';

  if (!f) return <Toolbar title="Cài đặt quy trình" />;
  const flags = (flagRows ?? []).filter((x) => x.doc_type === f.doc_type);
  const flagName = (c: string) => flags.find((x) => x.flag === c)?.name ?? c;
  // "khi ≥ 20.000.000 đ hoặc Nhập khẩu" (để trống = luôn áp dụng)
  const cond = (s: Step) => {
    const parts = [s.min_amount !== null ? `giá trị ≥ ${nf(s.min_amount)} đ` : null, ...(s.flags ?? []).map(flagName)].filter(Boolean);
    return parts.length ? `khi ${parts.join(' hoặc ')}` : null;
  };
  const preview: Stage[] = [
    { seq: 0, label: f.submit_label, state: 'done', role_name: who(f.submit_role, f.submit_user_ids) },
    ...f.steps.filter((s) => s.enabled).map((s) => ({ seq: s.seq, label: s.label, state: 'todo' as const,
      role_name: [who(s.role, s.users), `${s.sla_hours} giờ`, cond(s)].filter(Boolean).join(' · ') })),
  ];

  return (
    <>
      <Toolbar title="Cài đặt quy trình" reload={`/quan-tri/quy-trinh?f=${f.doc_type}`} />
      <Tabs active={f.doc_type} items={all.map((x) => ({ key: x.doc_type, label: x.name, href: `/quan-tri/quy-trinh?f=${x.doc_type}`, count: x.running || undefined }))} />
      <Flash ok={sp.ok} err={sp.err} />
      <div className="-mx-4 mb-3 md:-mx-5"><StageBar stages={preview} /></div>
      <p className="mb-4 text-[13.5px] text-muted">
        Chỉ người được giao (và còn giữ vai trò) mới xử lý được bước đang hoạt động. Nếu người duyệt duy nhất của một bước chính là người lập,
        hệ thống bỏ bước đó khi Giám đốc đã duyệt ở bước khác, nếu không thì chuyển bước lên Giám đốc. Hết thời hạn mà chưa xử lý, hệ thống tự gửi cảnh báo
        trong app và email cho người phụ trách bước đó (kiểm tra 10 phút/lần trên máy chủ, mỗi lượt chỉ gửi một lần).
        {f.running > 0 && <> <b>{f.running} hồ sơ đang chạy</b> giữ cấu hình lúc gửi; thay đổi chỉ áp dụng cho hồ sơ gửi sau.</>}
      </p>

      <form action={saveSubmit} className="card mb-3 p-4">
        <input type="hidden" name="flow" value={f.doc_type} />
        <div className="mb-3 flex items-center gap-2"><Pill tone="ok">Bước 0</Pill><h2 className="text-[16px] font-medium">{f.submit_label}</h2></div>
        <fieldset disabled={!editable} className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <label className="lbl">Tên bước<input className="inp" name="label" defaultValue={f.submit_label} required /></label>
          <label className="lbl">Vai trò được lập
            <select className="inp" name="role" defaultValue={f.submit_role ?? ''}>
              <option value="">Người có quyền tạo chứng từ</option>
              {ROLES.map((r) => <option key={r} value={r}>{ROLE_NAMES[r]}</option>)}
            </select>
          </label>
          <People users={us} role={f.submit_role} selected={f.submit_user_ids} />
          {editable && <div className="sm:col-span-2 lg:col-span-4"><SubmitButton>Lưu bước lập</SubmitButton></div>}
        </fieldset>
      </form>

      {f.steps.map((s, i) => (
        <form key={s.seq} action={saveStep} className={`card mb-3 p-4 ${s.enabled ? '' : 'opacity-70'}`}>
          <input type="hidden" name="flow" value={f.doc_type} /><input type="hidden" name="seq" value={s.seq} /><input type="hidden" name="rules" value="1" />
          <div className="mb-3 flex items-center gap-2"><Pill tone={s.enabled ? 'info' : 'mute'}>Bước {i + 1}</Pill><h2 className="text-[16px] font-medium">{s.label}</h2>{!s.enabled && <Pill tone="mute">Đang tắt</Pill>}{cond(s) && <Pill tone="info">{cond(s)}</Pill>}</div>
          <fieldset disabled={!editable} className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <label className="lbl">Tên bước<input className="inp" name="label" defaultValue={s.label} required /></label>
            <label className="lbl">Vai trò duyệt
              <select className="inp" name="role" defaultValue={s.role}>{ROLES.map((r) => <option key={r} value={r}>{ROLE_NAMES[r]}</option>)}</select>
            </label>
            <label className="lbl">Thời hạn xử lý (giờ)<input className="inp text-right" name="sla_hours" type="number" min={1} defaultValue={s.sla_hours} required /></label>
            <label className="lbl">Nhắc trước hạn (giờ, 0 = không)<input className="inp text-right" name="warn_hours" type="number" min={0} defaultValue={s.warn_hours} /></label>
            <People users={us} role={s.role} selected={s.users} />
            <label className="lbl">Quá hạn thì cho phép duyệt thay
              <select className="inp" name="fallback" defaultValue={s.fallback ?? ''}>
                <option value="">Không</option>
                {ROLES.map((r) => <option key={r} value={r}>{ROLE_NAMES[r]}</option>)}
              </select>
            </label>
            {flags.length > 0 && (
              <>
                <label className="lbl">Chỉ áp dụng khi giá trị từ (đồng)
                  <input className="inp text-right" name="min_amount" inputMode="numeric" defaultValue={s.min_amount !== null ? nf(s.min_amount) : ''} placeholder="Để trống = không xét giá trị" />
                </label>
                <fieldset className="sm:col-span-2">
                  <legend className="mb-1 text-[12.5px] text-muted">hoặc khi chứng từ là · để trống cả hai = luôn áp dụng</legend>
                  <div className="flex flex-wrap gap-x-5 gap-y-1">
                    {flags.map((x) => (
                      <label key={x.flag} className="flex items-center gap-2 text-[14px]">
                        <input type="checkbox" name="flags" value={x.flag} defaultChecked={(s.flags ?? []).includes(x.flag)} className="accent-[rgb(var(--brand))]" />{x.name}
                      </label>
                    ))}
                  </div>
                </fieldset>
              </>
            )}
            <label className="flex items-center gap-2 text-[14px]"><input type="checkbox" name="enabled" defaultChecked={s.enabled} className="accent-[rgb(var(--brand))]" />Bật bước này</label>
            {editable && <div className="sm:col-span-2 lg:col-span-4"><SubmitButton>Lưu bước</SubmitButton></div>}
          </fieldset>
        </form>
      ))}

      {editable && (
        <form action={saveStep} className="card border-dashed p-4">
          <input type="hidden" name="flow" value={f.doc_type} />
          <h2 className="mb-3 text-[16px] font-medium">+ Thêm bước duyệt</h2>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5 lg:items-end">
            <label className="lbl">Tên bước<input className="inp" name="label" placeholder="Ví dụ: Kiểm tra" required /></label>
            <label className="lbl">Vai trò duyệt<select className="inp" name="role" required>{ROLES.map((r) => <option key={r} value={r}>{ROLE_NAMES[r]}</option>)}</select></label>
            <label className="lbl">Thời hạn (giờ)<input className="inp text-right" name="sla_hours" type="number" min={1} defaultValue={24} required /></label>
            <label className="lbl">Nhắc trước hạn (giờ)<input className="inp text-right" name="warn_hours" type="number" min={0} defaultValue={4} /></label>
            <SubmitButton>Thêm bước</SubmitButton>
          </div>
          <p className="mt-2 text-[12.5px] text-muted">Bước mới thêm vào cuối quy trình. Sau khi thêm, chọn người thực hiện cụ thể ở thẻ của bước.</p>
        </form>
      )}
      <p className="mt-4 text-[13px]"><Link className="link" href="/quan-tri">← Người dùng</Link></p>
    </>
  );
}
