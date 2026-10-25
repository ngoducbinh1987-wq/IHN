'use client';

import { useFormStatus } from 'react-dom';
import type { ReactNode } from 'react';

// Nút gửi form: khóa khi đang xử lý để tránh bấm hai lần
// formAction: cho phép nhiều nút trong cùng form gọi các hành động khác nhau
export function SubmitButton({ children, className = 'btn btn-pri', pendingText = 'Đang xử lý…', formAction }:
  { children: ReactNode; className?: string; pendingText?: string; formAction?: (form: FormData) => void | Promise<void> }) {
  const { pending } = useFormStatus();
  return (
    <button type="submit" className={className} disabled={pending} formAction={formAction}>
      {pending ? pendingText : children}
    </button>
  );
}
