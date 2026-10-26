'use client';

import { useRef, useState } from 'react';
import { Eye, EyeOff, Wand2 } from 'lucide-react';

// Bỏ ký tự dễ nhầm (0/O, 1/l/I) để đọc qua điện thoại hoặc viết ra giấy không sai
const CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';

function randomPassword(len = 12) {
  const buf = new Uint32Array(len);
  crypto.getRandomValues(buf);
  return Array.from(buf, (n) => CHARS[n % CHARS.length]).join('');
}

// Hai ô mật khẩu mới (nhập + nhập lại), nút hiện/ẩn và nút tạo ngẫu nhiên. Kiểm khớp ngay trên trình duyệt.
export function ResetPasswordFields() {
  const [show, setShow] = useState(false);
  const pw = useRef<HTMLInputElement>(null);
  const cf = useRef<HTMLInputElement>(null);

  const check = () => {
    if (!pw.current || !cf.current) return;
    cf.current.setCustomValidity(cf.current.value && cf.current.value !== pw.current.value ? 'Hai ô mật khẩu mới không khớp' : '');
  };
  const generate = () => {
    const v = randomPassword();
    if (pw.current) pw.current.value = v;
    if (cf.current) cf.current.value = v;
    setShow(true);
    check();
  };

  return (
    <div className="flex flex-col gap-3">
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="lbl">Mật khẩu mới (≥ 10 ký tự)
          <input ref={pw} className="inp mono" name="new_password" type={show ? 'text' : 'password'} minLength={10} required
            autoComplete="new-password" onInput={check} />
        </label>
        <label className="lbl">Nhập lại mật khẩu mới
          <input ref={cf} className="inp mono" name="confirm_password" type={show ? 'text' : 'password'} minLength={10} required
            autoComplete="new-password" onInput={check} />
        </label>
      </div>
      <div className="flex flex-wrap gap-2">
        <button type="button" className="btn btn-sm" onClick={() => setShow((v) => !v)} aria-pressed={show}>
          {show ? <EyeOff size={15} aria-hidden="true" /> : <Eye size={15} aria-hidden="true" />}
          {show ? 'Ẩn mật khẩu' : 'Hiện mật khẩu'}
        </button>
        <button type="button" className="btn btn-sm" onClick={generate}>
          <Wand2 size={15} aria-hidden="true" />Tạo mật khẩu ngẫu nhiên
        </button>
      </div>
    </div>
  );
}
