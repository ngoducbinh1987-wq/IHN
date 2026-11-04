'use client';

import { useFormStatus } from 'react-dom';
import type { ReactNode } from 'react';

// Nút gửi form: khóa khi đang xử lý để tránh bấm hai lần
// formAction: cho phép nhiều nút trong cùng form gọi các hành động khác nhau
// name/value: nút gửi kèm giá trị (vd. "Gom và gửi" / "Gom nháp" trong cùng form)
export function SubmitButton({ children, className = 'btn btn-pri', pendingText = 'Đang xử lý…', formAction, noValidate, name, value }:
  { children: ReactNode; className?: string; pendingText?: string; formAction?: (form: FormData) => void | Promise<void>; noValidate?: boolean;
    name?: string; value?: string }) {
  const { pending } = useFormStatus();
  return (
    <button type="submit" className={className} disabled={pending} formAction={formAction} formNoValidate={noValidate} name={name} value={value}>
      {pending ? pendingText : children}
    </button>
  );
}
