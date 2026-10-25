import type { Metadata, Viewport } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: { default: 'BMT MES', template: '%s · BMT MES' },
  description: 'Phần mềm điều hành sản xuất nhà máy cáp BMT',
};

export const viewport: Viewport = { width: 'device-width', initialScale: 1, themeColor: '#059B42' };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="vi">
      <head>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="" />
        <link
          rel="stylesheet"
          href="https://fonts.googleapis.com/css2?family=Roboto:wght@400;500;700&family=Roboto+Mono:wght@400;500&display=swap&subset=vietnamese"
        />
      </head>
      <body>{children}</body>
    </html>
  );
}
