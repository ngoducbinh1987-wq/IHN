import { createServerClient } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';

// Làm mới phiên đăng nhập và chặn trang khi chưa đăng nhập
export async function middleware(request: NextRequest) {
  // Job máy chủ tự kiểm tra CRON_SECRET, không cần phiên đăng nhập
  if (request.nextUrl.pathname.startsWith('/api/cron/')) return NextResponse.next();
  let response = NextResponse.next({ request });
  const supabase = createServerClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, {
    cookies: {
      getAll: () => request.cookies.getAll(),
      setAll: (list) => {
        list.forEach(({ name, value }) => request.cookies.set(name, value));
        response = NextResponse.next({ request });
        list.forEach(({ name, value, options }) => response.cookies.set(name, value, options));
      },
    },
  });
  const { data: { user } } = await supabase.auth.getUser();
  const isLogin = request.nextUrl.pathname.startsWith('/login');
  if (!user && !isLogin) {
    const url = request.nextUrl.clone();
    url.pathname = '/login';
    url.search = '';
    return NextResponse.redirect(url);
  }
  if (user && isLogin) {
    const url = request.nextUrl.clone();
    url.pathname = '/';
    url.search = '';
    return NextResponse.redirect(url);
  }
  return response;
}

export const config = {
  // Logo và ảnh trang đăng nhập phải xem được khi chưa đăng nhập
  matcher: ['/((?!_next/static|_next/image|favicon.ico|icon.svg|logo-bmt.png|brand/).*)'],
};
