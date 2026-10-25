import { SubmitButton } from '@/components/submit-button';
import { Flash, PageHeader, Pill } from '@/components/ui';
import { ROLE_NAMES, df } from '@/lib/format';
import { can, requirePerm } from '@/lib/session';
import { createClient } from '@/lib/supabase/server';
import { createUser, updateUser } from './actions';

export const metadata = { title: 'Người dùng & quyền' };

type U = { id: string; full_name: string; employee_code: string | null; department: string | null; title: string | null;
  status: string; email: string | null; last_sign_in_at: string | null; roles: string[] };

const DEPTS: [string, string][] = [['BGD', 'Ban giám đốc'], ['KD', 'Kinh doanh'], ['KT', 'Kỹ thuật/QA'], ['KHO', 'Kho'],
  ['MUA', 'Mua hàng'], ['KTOAN', 'Kế toán'], ['SX', 'Sản xuất'], ['IT', 'Quản trị hệ thống']];
const ROLES = Object.keys(ROLE_NAMES);

function RoleChecks({ selected, prefix }: { selected: string[]; prefix: string }) {
  return (
    <fieldset className="grid grid-cols-2 gap-x-4 gap-y-1 sm:grid-cols-3">
      <legend className="mb-1 text-[12px] text-muted">Vai trò</legend>
      {ROLES.map((r) => (
        <label key={r} className="flex items-center gap-2 text-[12.5px]">
          <input type="checkbox" name="roles" value={r} defaultChecked={selected.includes(r)} id={`${prefix}-${r}`} className="accent-[rgb(var(--copper))]" />
          {ROLE_NAMES[r]}
        </label>
      ))}
    </fieldset>
  );
}

export default async function AdminPage({ searchParams }: { searchParams: Promise<{ ok?: string; err?: string; sua?: string }> }) {
  const sp = await searchParams;
  const me = await requirePerm('admin', 'view');
  const supabase = await createClient();
  const { data, error } = await supabase.schema('app').from('v_users').select('*').order('full_name').returns<U[]>();
  const editing = data?.find((u) => u.id === sp.sua);
  const editable = can(me, 'admin', 'edit');
  return (
    <>
      <PageHeader title="Người dùng & quyền" sub="Quyền được thực thi trong database (RLS), không chỉ ẩn trên giao diện" />
      <Flash ok={sp.ok} err={sp.err ?? error?.message} />
      <div className="grid gap-4 xl:grid-cols-[1.4fr_1fr]">
        <section className="card overflow-x-auto">
          <table className="tbl">
            <thead><tr><th>Họ tên</th><th>Email</th><th>Mã NV</th><th>Vai trò</th><th>Đăng nhập gần nhất</th><th>TT</th>{editable && <th />}</tr></thead>
            <tbody>
              {(data ?? []).map((u) => (
                <tr key={u.id} className={u.id === sp.sua ? 'bg-copper-soft/40' : ''}>
                  <td className="font-medium">{u.full_name}</td><td className="text-muted">{u.email}</td><td className="mono">{u.employee_code ?? '—'}</td>
                  <td className="min-w-[180px]"><div className="flex flex-wrap gap-1">{u.roles.map((r) => <Pill key={r} tone="info">{ROLE_NAMES[r] ?? r}</Pill>)}</div></td>
                  <td className="whitespace-nowrap">{df(u.last_sign_in_at, true)}</td>
                  <td><Pill tone={u.status === 'ACTIVE' ? 'ok' : 'warn'}>{u.status === 'ACTIVE' ? 'Hoạt động' : u.status === 'LOCKED' ? 'Tạm khóa' : 'Ngưng'}</Pill></td>
                  {editable && <td><a className="btn" href={`/quan-tri?sua=${u.id}`}>Sửa</a></td>}
                </tr>
              ))}
            </tbody>
          </table>
        </section>

        {editable && (
          editing ? (
            <form action={updateUser} className="card flex flex-col gap-3 p-4">
              <h2 className="font-semibold">Sửa: {editing.full_name}</h2>
              <input type="hidden" name="id" value={editing.id} />
              <div className="grid gap-3 sm:grid-cols-2">
                <label className="lbl">Họ tên<input className="inp" name="full_name" defaultValue={editing.full_name} required /></label>
                <label className="lbl">Mã nhân viên<input className="inp" name="employee_code" defaultValue={editing.employee_code ?? ''} /></label>
                <label className="lbl">Phòng ban<select className="inp" name="department" defaultValue={editing.department ?? ''}><option value="">—</option>{DEPTS.map(([c, n]) => <option key={c} value={c}>{n}</option>)}</select></label>
                <label className="lbl">Trạng thái<select className="inp" name="status" defaultValue={editing.status}><option value="ACTIVE">Hoạt động</option><option value="LOCKED">Tạm khóa</option><option value="INACTIVE">Ngưng</option></select></label>
              </div>
              <label className="lbl">Chức danh<input className="inp" name="title" defaultValue={editing.title ?? ''} /></label>
              <RoleChecks selected={editing.roles} prefix="e" />
              <div className="flex gap-2"><SubmitButton>Lưu</SubmitButton><a className="btn" href="/quan-tri">Hủy</a></div>
            </form>
          ) : (
            <form action={createUser} className="card flex flex-col gap-3 p-4">
              <h2 className="font-semibold">Tạo tài khoản</h2>
              <div className="grid gap-3 sm:grid-cols-2">
                <label className="lbl">Họ tên<input className="inp" name="full_name" required /></label>
                <label className="lbl">Email công ty<input className="inp" type="email" name="email" required /></label>
                <label className="lbl">Mật khẩu tạm (≥ 10 ký tự)<input className="inp" type="text" name="password" minLength={10} required autoComplete="off" /></label>
                <label className="lbl">Mã nhân viên<input className="inp" name="employee_code" /></label>
                <label className="lbl">Phòng ban<select className="inp" name="department"><option value="">—</option>{DEPTS.map(([c, n]) => <option key={c} value={c}>{n}</option>)}</select></label>
                <label className="lbl">Chức danh<input className="inp" name="title" /></label>
              </div>
              <RoleChecks selected={[]} prefix="n" />
              <p className="text-[12px] text-muted">Gửi mật khẩu tạm cho người dùng qua kênh riêng và yêu cầu đổi sau lần đăng nhập đầu.</p>
              <div><SubmitButton>Tạo tài khoản</SubmitButton></div>
            </form>
          )
        )}
      </div>
    </>
  );
}
