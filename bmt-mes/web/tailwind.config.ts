import type { Config } from 'tailwindcss';

// Màu lấy từ token CSS trong app/globals.css (cùng hệ màu với mockup BA: thép nguội + đồng)
const tok = (n: string) => `rgb(var(--${n}) / <alpha-value>)`;

export default {
  content: ['./app/**/*.{ts,tsx}', './components/**/*.{ts,tsx}'],
  darkMode: 'media',
  theme: {
    extend: {
      colors: {
        bg: tok('bg'), surface: tok('surface'), sunk: tok('sunk'), ink: tok('ink'), muted: tok('muted'), line: tok('line'),
        copper: tok('copper'), 'copper-soft': tok('copper-soft'), steel: tok('steel'), 'steel-soft': tok('steel-soft'),
        ok: tok('ok'), 'ok-soft': tok('ok-soft'), warn: tok('warn'), 'warn-soft': tok('warn-soft'),
        bad: tok('bad'), 'bad-soft': tok('bad-soft'), info: tok('info'), 'info-soft': tok('info-soft'),
        side: tok('side'),
      },
      fontFamily: {
        display: ['"Barlow Condensed"', '"Arial Narrow"', 'sans-serif'],
        sans: ['"Be Vietnam Pro"', 'system-ui', 'sans-serif'],
        mono: ['"JetBrains Mono"', 'ui-monospace', 'monospace'],
      },
    },
  },
  plugins: [],
} satisfies Config;
