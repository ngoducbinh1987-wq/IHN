'use client';
import { CalendarDays } from 'lucide-react';
import { useEffect, useRef, useState } from 'react';
import { dmy, parseVnDate } from '@/lib/format';

const toVn = (iso: string | null | undefined) => dmy(iso, '');

// Ô nhập ngày luôn hiện dd/mm/yyyy (quy định MES 19/11/2026), không phụ thuộc ngôn ngữ trình duyệt.
// Gửi đi giá trị ISO "YYYY-MM-DD" qua ô ẩn cùng `name` nên server action / tham số URL giữ nguyên.
// Gõ: 5/11/2026, 05112026, 5-11-26… đều hiểu; nút lịch mở bộ chọn ngày của trình duyệt.

type Props = {
  name?: string; defaultValue?: string | null; value?: string | null; onChange?: (iso: string) => void;
  required?: boolean; disabled?: boolean; min?: string | null; max?: string | null; form?: string;
  className?: string; id?: string; 'aria-label'?: string; title?: string;
};

export function DateInput({ name, defaultValue, value, onChange, required, disabled, min, max, form, className = 'inp', id, title, ...rest }: Props) {
  const controlled = value !== undefined;
  const [iso, setIso] = useState(controlled ? value ?? '' : defaultValue ?? '');
  const [text, setText] = useState(toVn(controlled ? value : defaultValue));
  const textRef = useRef<HTMLInputElement>(null);
  const pickRef = useRef<HTMLInputElement>(null);

  // Trang tải lại với giá trị mặc định / giá trị điều khiển mới → hiện lại theo giá trị đó
  const src = controlled ? value ?? '' : defaultValue ?? '';
  const mine = useRef<string | null>(null); // giá trị chính ô này vừa gửi lên (không viết lại chữ người dùng đang gõ)
  useEffect(() => {
    if (mine.current !== null && src === mine.current) return;
    setIso(src); setText(toVn(src));
  }, [src]);

  const check = (v: string | null) => {
    const el = textRef.current;
    if (!el) return;
    let msg = '';
    if (v === null) msg = 'Nhập ngày theo dạng dd/mm/yyyy, ví dụ 05/11/2026';
    else if (v && min && v < min) msg = `Ngày phải từ ${toVn(min)} trở đi`;
    else if (v && max && v > max) msg = `Ngày phải đến ${toVn(max)} là muộn nhất`;
    el.setCustomValidity(msg);
  };
  const commit = (v: string) => { mine.current = v; setIso(v); onChange?.(v); };

  // Lớp độ rộng (w-…) đặt cho khung ngoài, ô chữ chiếm hết khung
  const cls = className.split(/\s+/);
  const wCls = cls.filter((c) => /^w-/.test(c)).join(' ') || 'w-full';
  const inCls = cls.filter((c) => !/^w-/.test(c)).join(' ');
  return (
    <span className={`relative inline-flex items-center ${wCls}`}>
      <input
        ref={textRef} id={id} type="text" inputMode="numeric" autoComplete="off" placeholder="dd/mm/yyyy"
        className={`${inCls} w-full pr-8`} value={text} form={form} required={required} disabled={disabled} title={title ?? 'Ngày dạng dd/mm/yyyy'}
        aria-label={rest['aria-label']} data-date-name={name}
        onChange={(e) => {
          setText(e.target.value);
          const v = parseVnDate(e.target.value);
          check(v);
          if (v !== null) commit(v);
        }}
        onBlur={() => { const v = parseVnDate(text); if (v) setText(toVn(v)); check(v); }}
      />
      <button type="button" tabIndex={-1} disabled={disabled} aria-label="Chọn ngày trên lịch"
        className="absolute right-1.5 top-1/2 -translate-y-1/2 rounded p-0.5 text-muted hover:text-ink disabled:opacity-40"
        onClick={() => { const p = pickRef.current; if (!p) return; try { p.showPicker(); } catch { p.focus(); } }}>
        <CalendarDays size={15} aria-hidden />
      </button>
      <input ref={pickRef} type="date" tabIndex={-1} aria-hidden className="pointer-events-none absolute bottom-0 right-0 h-0 w-0 opacity-0"
        value={iso} min={min ?? undefined} max={max ?? undefined}
        onChange={(e) => { const v = e.target.value; setText(toVn(v)); check(v); commit(v); }} />
      {name && <input type="hidden" name={name} value={iso} form={form} disabled={disabled} />}
    </span>
  );
}
