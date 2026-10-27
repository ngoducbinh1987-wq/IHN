"""Dựng 3D máy trộn silicone 2 trục cán và máy đóng gói 2 trục + giá xả, bổ sung vào mô hình Trung tâm điều hành.

Chạy một lần:  python3 bmt-mes/dev/model3d/add_mixer_packer.py
Đọc/ghi web/public/dieu-hanh/model/{meta.json, vertices.bin}. Mỗi đỉnh 11 float: vị trí (3), pháp tuyến (3), màu (3),
mã đối tượng (thứ tự trong meta.assets, bắt đầu 1), giai đoạn. Trục Z hướng lên, đơn vị mét, lưới trục:
số 1–10 theo X mỗi 7,5 m (ô 3,75 m đánh số 1–18), chữ A–F theo Y (A = 0, B = 7,5, C = 14,5, D = 21,5, E = 28,5, F = 36).

- MIXER: thay khối minh họa cũ bằng máy cán trộn 2 trục theo ảnh (tủ trắng, khung xanh navy, 2 trục cán, giàn trên có thanh an toàn
  vàng, tay quay, hộp nút dừng khẩn), đặt trong phòng lạnh phía trục A, trục cán vuông góc chiều dài phòng, cách đều 3 tường
  (tường tây X = 0,1, tường đông X = 3,6, tường phía trục A Y = 2,3); dời kiện nguyên liệu silicone sang nửa phía trong.
  Máy trộn là máy (kind machine) để Trung tâm điều hành hiện thông số chạy giả lập.
- PACK-01: máy cuốn 2 trục lô (tủ xanh, 2 trục lắp bobin gỗ, tay dancer, hộp điều khiển trắng) + giá xả pay-off (khung xanh,
  trục khí nén, phanh, con lăn dẫn trên), bộ đếm mét, kệ bobin gỗ trống; đặt cạnh máy xoắn TW800-02, ngay trên TW630-03
  (X 37,4–44,6, Y 21,5–24,8, theo khoanh đỏ của anh Bình 28/10/2026).
Chạy lại từ mô hình gốc R02:  git show e31def2:bmt-mes/web/public/dieu-hanh/model/<tệp> rồi chạy script.
"""
import json
import math
import os
import sys

import numpy as np

ROOT = os.path.join(os.path.dirname(__file__), '..', '..', 'web', 'public', 'dieu-hanh', 'model')
META = os.path.join(ROOT, 'meta.json')
VERT = os.path.join(ROOT, 'vertices.bin')

# Bảng màu: giữ tông của mô hình R02, màu sơn lấy theo ảnh thiết bị
NAVY = (0.141, 0.247, 0.439)
DARK = (0.149, 0.192, 0.227)
STEEL = (0.612, 0.667, 0.698)
LIGHT = (0.784, 0.804, 0.812)
WHITE = (0.905, 0.915, 0.915)
BLUE = (0.235, 0.620, 0.835)      # xanh da trời của máy đóng gói / giá xả
BLUE_D = (0.165, 0.475, 0.680)
ORANGE = (0.900, 0.470, 0.150)
YELLOW = (0.945, 0.780, 0.160)
RED = (0.820, 0.200, 0.200)
GREEN = (0.120, 0.600, 0.330)
CREAM = (0.900, 0.880, 0.800)
WOOD = (0.720, 0.540, 0.330)
WOOD_D = (0.560, 0.390, 0.220)
CABLE = (0.180, 0.180, 0.200)
COPPER = (0.678, 0.475, 0.322)
PAD = (0.800, 0.860, 0.885)


class Mesh:
    def __init__(self):
        self.v = []

    def tri(self, a, b, c, n, col):
        for p in (a, b, c):
            self.v.append((*p, *n, *col))

    def quad(self, a, b, c, d, n, col):
        self.tri(a, b, c, n, col)
        self.tri(a, c, d, n, col)

    def box(self, x0, y0, z0, x1, y1, z1, col):
        x0, x1 = min(x0, x1), max(x0, x1)
        y0, y1 = min(y0, y1), max(y0, y1)
        z0, z1 = min(z0, z1), max(z0, z1)
        P = lambda i, j, k: ((x0, x1)[i], (y0, y1)[j], (z0, z1)[k])
        self.quad(P(0, 0, 1), P(1, 0, 1), P(1, 1, 1), P(0, 1, 1), (0, 0, 1), col)
        self.quad(P(0, 0, 0), P(0, 1, 0), P(1, 1, 0), P(1, 0, 0), (0, 0, -1), col)
        self.quad(P(0, 0, 0), P(1, 0, 0), P(1, 0, 1), P(0, 0, 1), (0, -1, 0), col)
        self.quad(P(0, 1, 0), P(0, 1, 1), P(1, 1, 1), P(1, 1, 0), (0, 1, 0), col)
        self.quad(P(0, 0, 0), P(0, 0, 1), P(0, 1, 1), P(0, 1, 0), (-1, 0, 0), col)
        self.quad(P(1, 0, 0), P(1, 1, 0), P(1, 1, 1), P(1, 0, 1), (1, 0, 0), col)

    def cyl(self, p0, p1, r, col, seg=24, caps=True, cap_col=None):
        """Trụ tròn từ p0 đến p1 (bất kỳ hướng), bán kính r."""
        p0, p1 = np.array(p0, float), np.array(p1, float)
        ax = p1 - p0
        L = np.linalg.norm(ax)
        if L < 1e-9:
            return
        ax /= L
        ref = np.array([0, 0, 1.0]) if abs(ax[2]) < 0.9 else np.array([1.0, 0, 0])
        u = np.cross(ax, ref); u /= np.linalg.norm(u)
        w = np.cross(ax, u)
        ring = [(math.cos(2 * math.pi * i / seg), math.sin(2 * math.pi * i / seg)) for i in range(seg)]
        for i in range(seg):
            c0, s0 = ring[i]
            c1, s1 = ring[(i + 1) % seg]
            d0 = u * c0 + w * s0
            d1 = u * c1 + w * s1
            a, b = p0 + d0 * r, p0 + d1 * r
            c, d = p1 + d1 * r, p1 + d0 * r
            n = (d0 + d1); n /= np.linalg.norm(n)
            self.quad(tuple(a), tuple(b), tuple(c), tuple(d), tuple(n), col)
            if caps:
                cc = cap_col or col
                self.tri(tuple(p0), tuple(b), tuple(a), tuple(-ax), cc)
                self.tri(tuple(p1), tuple(d), tuple(c), tuple(ax), cc)

    def beam(self, p0, p1, s, col):
        """Thanh tiết diện vuông cạnh s nối p0–p1 (dùng cho tay dancer, khung nghiêng)."""
        self.cyl(p0, p1, s / math.sqrt(2), col, seg=4)

    def reel(self, c, axis, r_fl, half_w, r_core, col_fl, col_core, r_wound=None, col_wound=CABLE, fl_t=0.035):
        """Bobin: 2 mặt bích + lõi (+ lớp dây quấn). axis: 'x' hoặc 'y'."""
        e = np.array([1.0, 0, 0]) if axis == 'x' else np.array([0, 1.0, 0])
        c = np.array(c, float)
        for sgn in (-1, 1):
            m = c + e * sgn * half_w
            self.cyl(tuple(m - e * fl_t / 2), tuple(m + e * fl_t / 2), r_fl, col_fl, seg=32)
        self.cyl(tuple(c - e * half_w), tuple(c + e * half_w), r_core, col_core, seg=24)
        if r_wound:
            self.cyl(tuple(c - e * (half_w - fl_t)), tuple(c + e * (half_w - fl_t)), r_wound, col_wound, seg=32)

    def path(self, pts, r, col):
        for a, b in zip(pts, pts[1:]):
            self.cyl(a, b, r, col, seg=8, caps=False)

    def xform(self, fp, fn):
        """Biến đổi mọi đỉnh: fp(x, y, z) → vị trí mới, fn(nx, ny, nz) → pháp tuyến mới."""
        self.v = [(*fp(*q[0:3]), *fn(*q[3:6]), *q[6:9]) for q in self.v]

    def bbox(self):
        a = np.array([q[0:3] for q in self.v])
        return a.min(0), a.max(0)

    def outline(self, x0, y0, x1, y1, w, col, z=0.004):
        self.box(x0, y0, 0, x1, y0 + w, z, col)
        self.box(x0, y1 - w, 0, x1, y1, z, col)
        self.box(x0, y0, 0, x0 + w, y1, z, col)
        self.box(x1 - w, y0, 0, x1, y1, z, col)


# --------------------------------------------------------------------------- Máy trộn 2 trục cán (phòng lạnh)
def mixer():
    m = Mesh()
    x0, x1, y0, y1 = 0.35, 1.75, 2.45, 4.80   # mặt trước hướng +X (cửa phòng lạnh)
    m.box(x0 - 0.05, y0 - 0.05, 0, x1 + 0.05, y1 + 0.05, 0.006, PAD)
    # Tủ trắng bên trái (truyền động, điện) có cửa và tay nắm
    m.box(0.35, 2.45, 0.0, 1.62, 3.15, 1.05, WHITE)
    m.box(1.620, 2.52, 0.08, 1.630, 3.08, 0.98, LIGHT)            # khe cửa
    m.box(1.630, 2.98, 0.48, 1.655, 3.02, 0.62, DARK)             # tay nắm
    m.box(1.630, 2.60, 0.80, 1.640, 2.75, 0.90, STEEL)            # nhãn máy
    # Hộp điều khiển trắng nâng cao phía trái + màn hình
    m.box(0.40, 2.50, 1.05, 0.62, 2.60, 1.20, STEEL)              # tay đỡ
    m.box(0.40, 2.47, 1.20, 0.78, 3.08, 1.80, WHITE)
    m.box(0.780, 2.58, 1.42, 0.790, 2.96, 1.70, DARK)            # màn hình
    # Thân khung xanh navy giữa: chân, 2 má máy, 2 trục cán bạc, khay hứng
    m.box(0.45, 3.15, 0.0, 1.60, 4.32, 0.58, NAVY)
    m.box(1.600, 3.25, 0.10, 1.610, 4.22, 0.50, LIGHT)            # cửa dưới
    for ya, yb in ((3.15, 3.30), (4.17, 4.32)):
        m.box(0.50, ya, 0.58, 1.52, yb, 1.22, NAVY)
    m.cyl((0.86, 3.30, 0.98), (0.86, 4.17, 0.98), 0.115, (0.80, 0.82, 0.84), seg=32)
    m.cyl((1.12, 3.30, 0.98), (1.12, 4.17, 0.98), 0.115, (0.80, 0.82, 0.84), seg=32)
    m.box(0.62, 3.30, 0.66, 1.52, 4.17, 0.70, DARK)               # khay hứng
    m.box(0.95, 3.40, 1.09, 1.03, 4.07, 1.13, (0.93, 0.93, 0.92))  # tấm silicone trên khe cán
    # Tay quay chỉnh khe + hộp số cam hai bên
    for yc in (3.225, 4.245):
        m.box(1.52, yc - 0.06, 0.92, 1.62, yc + 0.06, 1.06, STEEL)
        m.box(1.40, yc - 0.07, 1.06, 1.55, yc + 0.07, 1.16, ORANGE)
        m.cyl((1.62, yc, 0.99), (1.70, yc, 0.99), 0.02, STEEL, seg=10)
        m.cyl((1.70, yc, 0.99), (1.72, yc, 0.99), 0.13, STEEL, seg=28)
        m.cyl((1.72, yc + 0.08, 1.07), (1.80, yc + 0.08, 1.07), 0.015, DARK, seg=8)
    # Tủ trắng bên phải + hộp số trên
    m.box(0.45, 4.32, 0.0, 1.55, 4.80, 0.95, WHITE)
    m.box(1.550, 4.38, 0.08, 1.560, 4.74, 0.88, LIGHT)
    m.box(0.62, 4.36, 0.95, 1.18, 4.74, 1.18, STEEL)
    m.cyl((0.90, 4.55, 1.18), (0.90, 4.55, 1.30), 0.10, DARK, seg=20)
    # Giàn trên: 2 cột, xà ngang, cụm dao gạt xanh, thanh an toàn vàng
    for yc in (3.10, 4.37):
        m.box(0.52, yc - 0.04, 1.22, 0.62, yc + 0.04, 1.86, WHITE)
    m.box(0.50, 3.06, 1.76, 0.84, 4.41, 1.86, WHITE)
    m.box(0.60, 3.35, 1.56, 0.82, 4.12, 1.76, NAVY)
    m.box(1.38, 3.32, 1.30, 1.44, 4.15, 1.36, YELLOW)              # thanh an toàn (kéo là dừng)
    for yc in (3.32, 4.15):
        m.box(0.62, yc - 0.02, 1.33, 1.38, yc + 0.02, 1.36, STEEL)
    # Hộp nút dừng khẩn vàng + nút đỏ
    for (xa, ya) in ((1.20, 2.86), (1.10, 4.50)):
        zt = 1.05 if ya < 3 else 0.95
        m.box(xa, ya, zt, xa + 0.18, ya + 0.20, zt + 0.10, YELLOW)
        m.cyl((xa + 0.09, ya + 0.10, zt + 0.10), (xa + 0.09, ya + 0.10, zt + 0.14), 0.04, RED, seg=16)
    # Xoay 90°: trục cán theo X (vuông góc chiều dài phòng), mặt thao tác quay vào trong phòng (+Y);
    # thân máy 2,35 × 1,40 m cách đều tường tây, tường đông và tường phía trục A
    inner_x0, inner_x1, inner_y0 = 0.10, 3.60, 2.30
    gap = ((inner_x1 - inner_x0) - (y1 - y0)) / 2
    nx1, ny0 = inner_x1 - gap, inner_y0 + gap
    m.xform(lambda x, y, z: (nx1 - (y - y0), ny0 + (x - x0), z), lambda a, b, c: (-b, a, c))
    lo, hi = m.bbox()
    return m, [float(lo[0]), float(lo[1]), float(hi[0]), float(hi[1])]


# --------------------------------------------------------------------------- Máy đóng gói + giá xả (ô 17–18, trục D–E)
def packer():
    m = Mesh()
    CY = 25.0   # tuyến dây theo X
    # ---- Giá xả (pay-off) — khung xanh, trục bobin theo Y
    px = 61.70
    m.box(px - 0.80, CY - 1.20, 0.0, px + 0.80, CY + 1.70, 0.006, PAD)
    for xa in (px - 0.70, px + 0.60):
        m.box(xa, CY - 1.05, 0.0, xa + 0.10, CY + 1.05, 0.18, BLUE)
    for ya in (CY - 1.05, CY + 0.95):
        m.box(px - 0.70, ya, 0.0, px + 0.70, ya + 0.10, 0.18, BLUE)
    m.box(px - 0.60, CY - 0.30, 0.02, px + 0.60, CY + 0.30, 0.06, BLUE_D)       # tấm sàn
    m.box(px - 0.22, CY + 0.25, 0.06, px + 0.10, CY + 0.50, 0.30, NAVY)          # động cơ giảm tốc
    # Ụ trục trái (xi lanh khí nén đẩy trục) và phải (phanh)
    m.box(px - 0.20, CY - 1.12, 0.18, px + 0.20, CY - 0.72, 0.86, BLUE)
    m.cyl((px, CY - 1.62, 0.76), (px, CY - 1.12, 0.76), 0.10, BLUE, seg=24)
    m.cyl((px, CY - 1.78, 0.76), (px, CY - 1.62, 0.76), 0.12, DARK, seg=24)
    m.cyl((px, CY - 0.72, 0.76), (px, CY - 0.40, 0.76), 0.05, STEEL, seg=16)
    m.cyl((px, CY - 0.52, 0.76), (px, CY - 0.42, 0.76), 0.085, DARK, seg=20)
    m.box(px - 0.12, CY - 1.40, 0.30, px + 0.12, CY - 1.20, 0.55, STEEL)         # van khí
    m.box(px - 0.20, CY + 0.72, 0.18, px + 0.20, CY + 1.12, 0.86, BLUE)
    m.cyl((px, CY + 1.12, 0.76), (px, CY + 1.30, 0.76), 0.22, CREAM, seg=32)     # trống phanh
    m.cyl((px, CY + 0.40, 0.76), (px, CY + 0.72, 0.76), 0.05, STEEL, seg=16)
    m.cyl((px, CY + 0.42, 0.76), (px, CY + 0.52, 0.76), 0.085, DARK, seg=20)
    # Bobin thép cấp dây (từ máy đùn vỏ)
    m.reel((px, CY, 0.76), 'y', 0.60, 0.36, 0.22, (0.50, 0.55, 0.58), (0.45, 0.48, 0.50), r_wound=0.50)
    # Khung con lăn dẫn trên (phía máy cuốn)
    for ya in (CY - 1.00, CY + 0.92):
        m.beam((px + 0.62, ya + 0.04, 0.18), (px + 0.50, ya + 0.04, 1.95), 0.08, BLUE)
    m.cyl((px + 0.50, CY - 1.08, 1.98), (px + 0.50, CY + 1.08, 1.98), 0.045, STEEL, seg=16)
    m.box(px + 0.42, CY - 0.12, 1.86, px + 0.58, CY + 0.12, 1.92, DARK)
    # Hộp điều khiển xám bên phải
    m.box(px + 0.10, CY + 1.30, 0.50, px + 0.70, CY + 1.65, 1.25, (0.82, 0.83, 0.84))
    m.box(px + 0.700, CY + 1.38, 1.02, px + 0.710, CY + 1.56, 1.16, DARK)
    for i, col in enumerate((RED, GREEN, RED)):
        m.cyl((px + 0.70, CY + 1.40 + i * 0.07, 0.86), (px + 0.73, CY + 1.40 + i * 0.07, 0.86), 0.025, col, seg=12)

    # ---- Bộ đếm mét + dẫn hướng giữa giá xả và máy cuốn
    cx = 63.15
    m.box(cx - 0.25, CY - 0.25, 0.0, cx + 0.25, CY + 0.25, 0.06, BLUE_D)
    m.box(cx - 0.05, CY - 0.05, 0.06, cx + 0.05, CY + 0.05, 1.10, STEEL)
    m.box(cx - 0.12, CY - 0.10, 1.05, cx + 0.12, CY + 0.10, 1.22, BLUE)
    m.cyl((cx, CY - 0.13, 1.30), (cx, CY + 0.13, 1.30), 0.12, DARK, seg=24)
    m.box(cx - 0.10, CY + 0.10, 1.08, cx + 0.10, CY + 0.13, 1.20, (0.15, 0.55, 0.30))  # màn đếm mét

    # ---- Máy cuốn 2 trục lô (mặt trước +Y, trục cuốn theo Y)
    wx = 65.30
    m.box(wx - 1.30, 23.30, 0.0, wx + 1.30, 25.80, 0.006, PAD)
    m.box(wx - 1.22, 23.42, 0.0, wx + 1.22, 24.72, 0.08, BLUE_D)                 # đế
    m.box(wx - 1.12, 23.55, 0.08, wx + 1.12, 24.58, 1.45, BLUE)                  # tủ máy
    m.box(wx - 0.20, 23.55, 1.45, wx + 1.12, 24.58, 1.48, STEEL)                 # tấm mặt trên
    m.box(wx - 1.12, 23.70, 1.45, wx - 0.28, 24.45, 2.30, WHITE)                 # hộp điều khiển
    m.box(wx - 1.04, 24.450, 2.06, wx - 0.36, 24.460, 2.24, (0.70, 0.62, 0.40))  # bảng tên
    for i in range(4):                                                           # đồng hồ, nút
        bx = wx - 0.98 + i * 0.17
        m.box(bx, 24.45, 1.90, bx + 0.12, 24.465, 2.00, DARK if i < 2 else WHITE)
        for j, col in enumerate((RED, GREEN, (0.20, 0.35, 0.75))):
            m.cyl((bx + 0.06, 24.45, 1.62 + j * 0.09), (bx + 0.06, 24.49, 1.62 + j * 0.09), 0.025, col if (i + j) % 2 == 0 else RED, seg=12)
    # Tay dancer chữ V và con lăn ở giữa mặt trước
    piv = (wx + 0.05, 24.64, 1.05)
    m.cyl((piv[0], 24.58, piv[2]), (piv[0], 24.66, piv[2]), 0.06, DARK, seg=16)
    for sgn in (-1, 1):
        top = (wx + 0.05 + sgn * 0.30, 24.64, 1.22)
        end = (wx + 0.05 + sgn * 0.62, 24.64, 0.98)
        m.beam(piv, top, 0.05, (0.30, 0.24, 0.18))
        m.beam(top, end, 0.05, (0.30, 0.24, 0.18))
        m.cyl((end[0], 24.58, end[2]), (end[0], 24.76, end[2]), 0.075, DARK, seg=20)
    for sgn in (-1, 1):                                                           # đồng hồ áp lực
        m.box(wx + 0.05 + sgn * 0.12 - 0.05, 24.58, 0.78, wx + 0.05 + sgn * 0.12 + 0.05, 24.59, 0.86, WHITE)
    # 2 trục cuốn (mâm cặp đen) + bobin gỗ 500 m (đang cuốn) và 305 m (chờ)
    spins = (wx - 0.70, wx + 0.80)
    for sx in spins:
        m.cyl((sx, 24.58, 0.52), (sx, 24.72, 0.52), 0.12, DARK, seg=24)
        m.cyl((sx, 24.72, 0.52), (sx, 25.45, 0.52), 0.035, STEEL, seg=12)
    m.reel((spins[1], 25.03, 0.52), 'y', 0.38, 0.25, 0.15, WOOD, WOOD_D, r_wound=0.30)
    m.reel((spins[0], 25.00, 0.52), 'y', 0.32, 0.21, 0.13, WOOD, WOOD_D)
    # Kệ bobin gỗ trống cạnh máy cuốn
    m.box(wx + 1.42, 23.50, 0.0, wx + 2.22, 24.70, 0.10, WOOD_D)
    for yy in (23.82, 24.38):
        m.reel((wx + 1.82, yy, 0.42), 'y', 0.32, 0.18, 0.13, WOOD, WOOD_D)
    # ---- Đường đi của dây: bobin cấp → con lăn trên → bộ đếm mét → tay dancer → bobin gỗ
    m.path([(px, CY, 1.26), (px + 0.50, CY, 2.03), (cx, CY, 1.42), (wx - 0.57, 24.72, 1.06),
            (wx + 0.67, 24.72, 1.06), (spins[1], 25.03, 0.82)], 0.016, (0.86, 0.30, 0.22))
    m.outline(60.75, 23.25, 67.60, 26.75, 0.05, NAVY)
    # Lật theo trục dây (Y = 25) để mặt trước máy cuốn, bobin gỗ, bảng điều khiển quay ra lối đi (−Y, phía TW630)
    m.xform(lambda x, y, z: (x, 2 * CY - y, z), lambda a, b, c: (a, -b, c))
    # Đưa vào ô khoanh đỏ cạnh TW800-02, trên TW630-03 (thu nhỏ đều nếu cần cho vừa ô)
    T = (37.40, 21.50, 44.60, 24.80)
    lo, hi = m.bbox()
    k = min(1.0, (T[2] - T[0]) / (hi[0] - lo[0]), (T[3] - T[1]) / (hi[1] - lo[1]))
    c0 = ((lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2)
    c1 = ((T[0] + T[2]) / 2, (T[1] + T[3]) / 2)
    m.xform(lambda x, y, z: (c1[0] + (x - c0[0]) * k, c1[1] + (y - c0[1]) * k, z * k), lambda a, b, c: (a, b, c))
    lo, hi = m.bbox()
    return m, [float(lo[0]), float(lo[1]), float(hi[0]), float(hi[1])]


def to_arr(mesh, aid, phase):
    a = np.array(mesh.v, dtype=np.float32)
    out = np.zeros((len(a), 11), dtype=np.float32)
    out[:, :9] = a
    out[:, 9] = aid
    out[:, 10] = phase
    return out


def main():
    meta_all = json.load(open(META, encoding='utf-8'))
    meta = meta_all['meta']
    A = meta['assets']
    if any(a['id'] == 'PACK-01' for a in A):
        sys.exit('Đã có PACK-01 trong mô hình, bỏ qua.')
    v = np.fromfile(VERT, dtype=np.float32).reshape(-1, 11)
    assert len(v) == meta_all['vertex_count']
    idx = {a['id']: i + 1 for i, a in enumerate(A)}

    # 1. Máy trộn: bỏ khối cũ, dựng mới; dời kiện silicone vào nửa trong phòng lạnh
    mid = idx['MIXER']
    v = v[v[:, 9] != mid]
    st = v[:, 9] == idx['SILICONE-STOCK']
    v[st, 1] += 3.45
    sa = next(a for a in A if a['id'] == 'SILICONE-STOCK')
    sa['bounds_xy_m'] = [0.4, 6.1, 3.3, 7.6]
    mm, mb = mixer()
    v = np.concatenate([v, to_arr(mm, mid, 1)])
    ma = next(a for a in A if a['id'] == 'MIXER')
    ma.update({
        'name': 'Máy trộn silicone 2 trục cán (SIL-MIX)', 'bounds_xy_m': [round(x, 3) for x in mb], 'kind': 'machine', 'phase': 1,
        'note': 'Máy cán trộn 2 trục dựng theo ảnh chủ đầu tư (28/10/2026): công suất 10–50 kg silicone/giờ, đặt trong phòng lạnh phía trục A, '
                'trục cán vuông góc chiều dài phòng, cách đều 3 tường. '
                'Silicone phải qua máy trộn trước khi ra máy đùn. Kích thước tham chiếu, chờ bản GA của hãng.',
        'components': ['MIXER/cabinet_left', 'MIXER/control', 'MIXER/rolls', 'MIXER/gantry', 'MIXER/cabinet_right', 'MIXER/estop'],
        'display_scale': 1.0, 'mes_code': 'SIL-MIX', 'capacity_kg_h': [10, 50],
    })
    # Mã đối tượng 3D trùng mã máy trên MES (nhãn, danh sách máy chạy hiện SIL-MIX)
    ma['id'] = 'SIL-MIX'
    for a in A:
        for key in ('contents', 'serves'):
            if key in a:
                a[key] = ['SIL-MIX' if c == 'MIXER' else c for c in a[key]]
        if 'components' in a:
            a['components'] = [c.replace('MIXER/', 'SIL-MIX/') for c in a['components']]

    # 2. Máy đóng gói: chèn trước nhóm đèn (đèn phải đứng cuối danh sách), dời mã đối tượng phía sau
    pos = next(i for i, a in enumerate(A) if a['kind'] == 'lighting')
    new_id = pos + 1
    v[v[:, 9] >= new_id, 9] += 1
    pm, pb = packer()
    A.insert(pos, {
        'id': 'PACK-01', 'name': 'Máy đóng gói 2 trục + giá xả • bobin gỗ 500/305 m', 'phase': 1,
        'bounds_xy_m': [round(x, 3) for x in pb], 'source_block': '', 'source_handle': '', 'kind': 'machine',
        'note': 'Dựng theo ảnh chủ đầu tư (28/10/2026): máy cuốn 2 trục lô bobin gỗ + giá xả (pay-off), tốc độ cuốn 50–200 m/phút; '
                'đặt cạnh máy xoắn TW800-02, ngay trên TW630-03. Hình hiển thị 150%, kích thước chờ bản GA.',
        'components': ['PACK-01/payoff', 'PACK-01/guide_roller', 'PACK-01/meter_counter', 'PACK-01/winder', 'PACK-01/dancer',
                       'PACK-01/spindles', 'PACK-01/reels', 'PACK-01/cable_path', 'PACK-01/footprint'],
        'display_scale': 1.5, 'scale_scope': 'functional_module', 'mes_code': 'PACK-01', 'speed_m_min': [50, 200],
    })
    v = np.concatenate([v, to_arr(pm, new_id, 1)])
    assert len(A) < 64, 'Shader chỉ nhận 64 mã trạng thái'

    meta['revision'] = 'R04'
    meta['date'] = '2026-10-28'
    meta_all['vertex_count'] = int(len(v))
    v.astype(np.float32).tofile(VERT)
    json.dump(meta_all, open(META, 'w', encoding='utf-8'), ensure_ascii=False)
    print('OK', len(v), 'đỉnh;', len(A), 'đối tượng; PACK-01 mã', new_id, '; MIXER mã', mid)


if __name__ == '__main__':
    main()
