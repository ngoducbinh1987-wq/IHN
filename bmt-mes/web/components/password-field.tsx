'use client';

import { useState } from 'react';
import { Eye, EyeOff, Lock } from 'lucide-react';

// Ô mật khẩu có nút hiện/ẩn
export function PasswordField({ id = 'password', name = 'password' }: { id?: string; name?: string }) {
  const [show, setShow] = useState(false);
  return (
    <div className="relative">
      <Lock size={17} className="pointer-events-none absolute left-3.5 top-1/2 -translate-y-1/2 text-muted" aria-hidden="true" />
      <input className="login-inp pl-10 pr-12" id={id} name={name} type={show ? 'text' : 'password'}
        autoComplete="current-password" required placeholder="Nhập mật khẩu" />
      <button type="button" onClick={() => setShow((v) => !v)}
        className="absolute right-1 top-1/2 grid h-10 w-10 -translate-y-1/2 place-items-center rounded text-muted hover:bg-sunk hover:text-ink"
        aria-label={show ? 'Ẩn mật khẩu' : 'Hiện mật khẩu'} aria-pressed={show}>
        {show ? <EyeOff size={18} aria-hidden="true" /> : <Eye size={18} aria-hidden="true" />}
      </button>
    </div>
  );
}
