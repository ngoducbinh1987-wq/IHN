import type { Config } from 'tailwindcss';

// Màu lấy từ token CSS trong app/globals.css: xanh lá thương hiệu BMTcable (#059B42) + khung tối kiểu Fastcon
const tok = (n: string) => `rgb(var(--${n}) / <alpha-value>)`;

export default {
  content: ['./app/**/*.{ts,tsx}', './components/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        bg: tok('bg'), surface: tok('surface'), sunk: tok('sunk'), ink: tok('ink'), muted: tok('muted'), line: tok('line'),
        brand: tok('brand'), 'brand-dark': tok('brand-dark'), 'brand-soft': tok('brand-soft'),
        side: tok('side'), 'side-2': tok('side-2'), 'side-ink': tok('side-ink'),
        ok: tok('ok'), 'ok-soft': tok('ok-soft'), warn: tok('warn'), 'warn-soft': tok('warn-soft'),
        bad: tok('bad'), 'bad-soft': tok('bad-soft'), info: tok('info'), 'info-soft': tok('info-soft'),
        todo: tok('todo'),
      },
      fontFamily: {
        sans: ['Roboto', 'system-ui', 'sans-serif'],
        mono: ['"Roboto Mono"', 'ui-monospace', 'monospace'],
      },
    },
  },
  plugins: [],
} satisfies Config;
