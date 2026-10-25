import { signOut } from '../login/actions';

export const metadata = { title: 'Lỗi kết nối' };

// Trang hướng dẫn khi app không đọc được dữ liệu từ Supabase (thường do cấu hình dự án)
export default async function ConnectionErrorPage({ searchParams }: { searchParams: Promise<{ code?: string; msg?: string }> }) {
  const { code, msg } = await searchParams;
  const schemaNotExposed = code === 'PGRST106' || /schema/i.test(msg ?? '');
  return (
    <main className="grid min-h-full place-items-center px-4 py-10">
      <div className="w-full max-w-lg">
        <div className="mb-5 font-display text-[30px] font-bold">BMT <span className="text-copper">MES</span></div>
        <div className="card flex flex-col gap-3 p-5 text-[13px]">
          <h1 className="text-[16px] font-bold">Không đọc được dữ liệu từ máy chủ</h1>
          {schemaNotExposed ? (
            <>
              <p>Đăng nhập thành công nhưng các schema của BMT MES chưa được mở cho Data API.</p>
              <p>Quản trị viên vào Supabase → <b>Project Settings → Data API → Exposed schemas</b>, thêm:</p>
              <p className="mono rounded bg-copper-soft px-2 py-1.5">app, core, master, sales, plan, purchase, inv, mfg, qa, cost, wf, iot, integ</p>
              <p>Bấm Save, chờ khoảng 30 giây rồi tải lại trang.</p>
            </>
          ) : (
            <p>Báo lỗi này cho quản trị hệ thống.</p>
          )}
          <p className="text-muted">Mã lỗi: <span className="mono">{code || '—'}</span> · {msg}</p>
          <div className="flex gap-2">
            <a className="btn btn-pri" href="/">Thử lại</a>
            <form action={signOut}><button className="btn" type="submit">Đăng xuất</button></form>
          </div>
        </div>
      </div>
    </main>
  );
}
