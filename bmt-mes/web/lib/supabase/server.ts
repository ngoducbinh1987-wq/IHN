import { createServerClient } from '@supabase/ssr';
import { createClient as createPlainClient } from '@supabase/supabase-js';
import { cookies } from 'next/headers';

const URL = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const ANON = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;

// Client theo phiên người dùng: mọi truy vấn chịu RLS của người đang đăng nhập
export async function createClient() {
  const store = await cookies();
  return createServerClient(URL, ANON, {
    cookies: {
      getAll: () => store.getAll(),
      setAll: (list) => {
        try {
          list.forEach(({ name, value, options }) => store.set(name, value, options));
        } catch {
          // Gọi từ Server Component: middleware đã làm mới phiên, bỏ qua
        }
      },
    },
  });
}

// Client service role: chỉ dùng ở server để tạo tài khoản đăng nhập (Auth Admin API)
export function createAdminClient() {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) throw new Error('Chưa cấu hình SUPABASE_SERVICE_ROLE_KEY trên server');
  return createPlainClient(URL, key, { auth: { persistSession: false, autoRefreshToken: false } });
}
