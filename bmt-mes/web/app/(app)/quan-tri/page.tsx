import { SubmitButton } from '@/components/submit-button';
import { Flash, Pill, Toolbar } from '@/components/ui';
import { ROLE_NAMES, df } from '@/lib/format';
import { can, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { createUser, updateUser } from './actions';

export const metadata = { title: 'Người dùng & quyền' };

type U = { id: string; full_name: string; employee_code: string | null; department: string | null; title: string | null;
  status: string; email: string | null; last_sign_in_at: string | null; roles: string[]; warehouses: string[] };
type W = { code: string; name: string };
type C = { role_a: string; role_b: string; reason: string };

const DEPTS: [string, string][] = [['BGD', 'Ban giám đốc'], ['KD', 'Kinh doanh'], ['KT', 'Kỹ thuật/QA'], ['KHO', 'Kho'],
  ['MUA', 'Mua hàng'], ['KTOAN', 'Kế toán'], ['SX', 'Sản xuất'], ['IT', 'Quản trị hệ thống']];
const ROLES = Object.keys(ROLE_NAMES);

function RoleChecks({ selected, prefix, conflicts }: { selected: string[]; prefix: string; conflicts: C[] }) {
  return (
    <fieldset className="grid grid-cols-2 gap-x-4 gap-y-1 sm:grid-cols-3">
      <legend className="mb-1 text-[12px] text-muted">Vai trò</legend>
      {ROLES.map((r) => (
        <label key={r} className="flex items-center gap-2 text-[12.5px]">
          <input type="checkbox" name="roles" value={r} defaultChecked={selected.includes(r)} id={`${prefix}-${r}`} className="accent-[rgb(var(--brand))]" />
          {ROLE_NAMES[r]}
        </label>
      ))}
      {conflicts.length > 0 && (
        <p className="col-span-full mt-1 text-[12px] text-muted">
          Không gán chung cho một người: {conflicts.map((c) => `${ROLE_NAMES[c.role_a] ?? c.role_a} + ${ROLE_NAMES[c.role_b] ?? c.role_b}`).join('; ')}.
          Tài khoản có vai trò Quản trị hệ thống được miễn trong giai đoạn chạy thử.
        </p>
      )}
    </fieldset>
  );
}

// Phạm vi kho: không chọn = được làm ở mọi kho
function WarehouseChecks({ selected, warehouses }: { selected: string[]; warehouses: W[] }) {
  return (
    <fieldset className="grid grid-cols-2 gap-x-4 gap-y-1">
      <legend className="mb-1 text-[12px] text-muted">Kho được giao · không chọn = mọi kho</legend>
      {warehouses.map((w) => (
        <label key={w.code} className="flex items-center gap-2 text-[12.5px]">
          <input type="checkbox" name="warehouses" value={w.code} defaultChecked={selected.includes(w.code)} className="accent-[rgb(var(--brand))]" />
          {w.name}
        </label>
      ))}
    </fieldset>
  );
}

export default async function AdminPage({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string; sua?: string; them?: string }> }) {
  const sp = await searchParams;
  const me = await requirePerm('admin', 'view');
  const supabase = await createClient();
  const [{ data, error }, { data: whs }, { data: conf }] = await Promise.all([
    supabase.schema('app').from('v_users').select('*').order('full_name').returns<U[]>(),
    supabase.schema('app').from('v_warehouses').select('code, name').order('code').returns<W[]>(),
    supabase.schema('app').from('v_role_conflicts').select('*').returns<C[]>(),
  ]);
  const warehouses = whs ?? [];
  const conflicts = conf ?? [];
  const whName = (c: string) => warehouses.find((w) => w.code === c)?.name ?? c;
  const editing = data?.find((u) => u.id === sp.sua);
  const editable = can(me, 'admin', 'edit');
  return (
    <>
      <Toolbar title="Người dùng & quyền" reload="/quan-tri" add={editable ? { href: '/quan-tri?them=1', label: 'Thêm người dùng' } : undefined} />
      <div className="mt-4"><Flash ok={sp.ok} err={sp.err ?? error?.message} /></div>
      <div className={`grid gap-4 ${editing || sp.them ? 'xl:grid-cols-[1.4fr_1fr]' : ''}`}>
        <section className="card overflow-x-auto">
          <table className="tbl">
            <thead><tr><th>Họ tên</th><th>Email</th><th>Mã NV</th><th>Vai trò</th><th>Đăng nhập gần nhất</th><th>TT</th>{editable && <th />}</tr></thead>
            <tbody>
              {(data ?? []).map((u) => (
                <tr key={u.id} className={u.id === sp.sua ? 'bg-brand-soft/60' : ''}>
                  <td className="font-medium">{u.full_name}</td><td className="text-muted">{u.email}</td><td className="mono">{u.employee_code ?? '—'}</td>
                  <td className="min-w-[180px]"><div className="flex flex-wrap gap-1">{u.roles.map((r) => <Pill key={r} tone="cu">{ROLE_NAMES[r] ?? r}</Pill>)}</div>
                    {u.warehouses?.length > 0 && <div className="mt-1 text-[12px] text-muted">Kho: {u.warehouses.map(whName).join(', ')}</div>}</td>
                  <td className="whitespace-nowrap">{df(u.last_sign_in_at, true)}</td>
                  <td><Pill tone={u.status === 'ACTIVE' ? 'ok' : 'warn'}>{u.status === 'ACTIVE' ? 'Hoạt động' : u.status === 'LOCKED' ? 'Tạm khóa' : 'Ngưng'}</Pill></td>
                  {editable && <td><a className="btn btn-sm btn-soft" href={`/quan-tri?sua=${u.id}`}>Sửa</a></td>}
                </tr>
              ))}
            </tbody>
          </table>
        </section>

        {editable && (
          editing ? (
            <form action={updateUser} className="card flex flex-col gap-3 p-4">
              <h2 className="text-[16px] font-medium">Sửa: {editing.full_name}</h2>
              <input type="hidden" name="id" value={editing.id} />
              <div className="grid gap-3 sm:grid-cols-2">
                <label className="lbl">Họ tên<input className="inp" name="full_name" defaultValue={editing.full_name} required /></label>
                <label className="lbl">Mã nhân viên<input className="inp" name="employee_code" defaultValue={editing.employee_code ?? ''} /></label>
                <label className="lbl">Phòng ban<select className="inp" name="department" defaultValue={editing.department ?? ''}><option value="">—</option>{DEPTS.map(([c, n]) => <option key={c} value={c}>{n}</option>)}</select></label>
                <label className="lbl">Trạng thái<select className="inp" name="status" defaultValue={editing.status}><option value="ACTIVE">Hoạt động</option><option value="LOCKED">Tạm khóa</option><option value="INACTIVE">Ngưng</option></select></label>
              </div>
              <label className="lbl">Chức danh<input className="inp" name="title" defaultValue={editing.title ?? ''} /></label>
              <RoleChecks selected={editing.roles} prefix="e" conflicts={conflicts} />
              <WarehouseChecks selected={editing.warehouses ?? []} warehouses={warehouses} />
              <div className="flex gap-2"><SubmitButton>Lưu</SubmitButton><a className="btn" href="/quan-tri">Hủy</a></div>
            </form>
          ) : sp.them ? (
            <form action={createUser} className="card flex flex-col gap-3 p-4">
              <h2 className="text-[16px] font-medium">Tạo tài khoản</h2>
              <div className="grid gap-3 sm:grid-cols-2">
                <label className="lbl">Họ tên<input className="inp" name="full_name" required /></label>
                <label className="lbl">Email công ty<input className="inp" type="email" name="email" required placeholder="vd nv01@bmtcable.vn" /></label>
                <label className="lbl">Mật khẩu tạm (≥ 10 ký tự)<input className="inp" type="text" name="password" minLength={10} required autoComplete="off" /></label>
                <label className="lbl">Mã nhân viên<input className="inp" name="employee_code" /></label>
                <label className="lbl">Phòng ban<select className="inp" name="department"><option value="">—</option>{DEPTS.map(([c, n]) => <option key={c} value={c}>{n}</option>)}</select></label>
                <label className="lbl">Chức danh<input className="inp" name="title" /></label>
              </div>
              <RoleChecks selected={[]} prefix="n" conflicts={conflicts} />
              <WarehouseChecks selected={[]} warehouses={warehouses} />
              <p className="text-[12px] text-muted">Gửi mật khẩu tạm cho người dùng qua kênh riêng và yêu cầu đổi sau lần đăng nhập đầu.
                Công nhân không có hộp thư: dùng email nội bộ tự đặt (không cần hộp thư thật), đăng nhập bằng email đó và mật khẩu.</p>
              <div className="flex gap-2"><SubmitButton>Tạo tài khoản</SubmitButton><a className="btn" href="/quan-tri">Hủy</a></div>
            </form>
          ) : null
        )}
      </div>
    </>
  );
}
