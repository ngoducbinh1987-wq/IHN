/** @type {import('next').NextConfig} */
const nextConfig = {
  experimental: { serverActions: { bodySizeLimit: '2mb' } },
  // Trung tâm điều hành (mô hình 3D xưởng) là trang tĩnh trong public/dieu-hanh
  async rewrites() {
    return [{ source: '/dieu-hanh', destination: '/dieu-hanh/index.html' }];
  },
};

export default nextConfig;
