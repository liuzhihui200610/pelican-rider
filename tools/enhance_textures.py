# -*- coding: utf-8 -*-
"""
V106 贴图增强 v2：正确的"去水印 + 升分辨率"方案。

v1 失败教训：块拼接时 4 块都取了原图中央 → 水印被复制 4 份，反而更糟。
正确做法：
  1) **定位并彻底裁除水印区**：AI 图的水印固定在中央约 22% 区域（含其上方 1/3 处也有一处），
     实测该图水印出现在 (0.36~0.50, 0.40~0.52) 与底部 (0.42~0.58, 0.90~1.0) 两处。
     → 取图时**只从确定的干净区域**采样，用 4 象限干净块拼成 2048。
  2) **去涡旋**：v1 的 fbm 裂缝生成出了涡旋纹理 → 改用纯高频颗粒 + 稀疏细裂纹直线段。
  3) **边缘可平铺**：拼接后对边缘做 wrap 混合（把右/下边缘与原图左/上边缘交叉淡化）。
"""
import os, math, random
from PIL import Image, ImageFilter
import numpy as np

SRC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets")

def clip(a):
    return np.clip(a, 0, 255).astype(np.uint8)

def vnoise(h, w, freq, seed):
    rng = np.random.RandomState(seed)
    gh, gw = max(2, h // freq + 1), max(2, w // freq + 1)
    s = rng.rand(gh, gw)
    s[-1, :] = s[0, :]      # wrap 连续
    s[:, -1] = s[:, 0]
    return np.asarray(Image.fromarray((s * 255).astype(np.uint8)).resize((w, h), Image.BICUBIC), dtype=np.float32) / 255.0

def fbm(h, w, freqs, amps, seed):
    o = np.zeros((h, w), dtype=np.float32)
    for i, (f, a) in enumerate(zip(freqs, amps)):
        o += vnoise(h, w, f, seed + i * 31) * a
    return o / sum(amps)

def read_rgb(name):
    return np.asarray(Image.open(os.path.join(SRC, name)).convert("RGB"), dtype=np.float32)

def wrap_blend(a, band=48):
    """让画布左右/上下边缘可无缝平铺：把右边缘与左边缘交叉淡化。"""
    h, w, c = a.shape
    r = np.linspace(0.0, 1.0, band, dtype=np.float32)[None, :, None]
    left = a[:, :band].copy()
    right = a[:, w - band:].copy()
    # 生成"环绕混合"：右半带逐渐过渡到左半带
    mid = (left + right) * 0.5
    a[:, :band] = left * r + mid * (1 - r)
    a[:, w - band:] = right * (1 - r) + mid * r
    r2 = np.linspace(0.0, 1.0, band, dtype=np.float32)[:, None, None]
    top = a[:band].copy()
    bot = a[h - band:].copy()
    mid2 = (top + bot) * 0.5
    a[:band] = top * r2 + mid2 * (1 - r2)
    a[h - band:] = bot * (1 - r2) + mid2 * r2
    return a

def inpaint_watermark(src, boxes, patch_seed=99):
    """
    ⭐ 从根上解决水印：把水印矩形区域用"周围干净邻域的随机块"覆盖填充（简易 inpaint）。
    比"取块时绕开"可靠得多 —— 绕开法只要窗口边界算错一点就会漏进去（已经踩过两次坑）。
    boxes: 归一化 (y0,y1,x0,x1) 列表。
    """
    out = src.copy()
    h, w, c = src.shape
    rng = np.random.RandomState(patch_seed)
    for (y0, y1, x0, x1) in boxes:
        Y0, Y1 = int(y0*h), int(y1*h)
        X0, X1 = int(x0*w), int(x1*w)
        bw, bh = X1-X0, Y1-Y0
        # 用四周的干净块做环形填充（每次取一块随机偏移的等大块，避开所有水印框）
        for by in range(Y0, Y1, bh):
            for bx in range(X0, X1, bw):
                for attempt in range(200):
                    oy = rng.randint(0, h - bh)
                    ox = rng.randint(0, w - bw)
                    # 候选块不能与任何水印框相交
                    ok = True
                    for (a0, a1, b0, b1) in boxes:
                        A0, A1, B0, B1 = int(a0*h), int(a1*h), int(b0*w), int(b1*w)
                        if not (oy + bh < A0 or oy > A1 or ox + bw < B0 or ox > B1):
                            ok = False; break
                    if ok:
                        break
                patch = src[oy:oy+bh, ox:ox+bw]
                py, px = by, bx
                ph2 = min(bh, Y1-py); pw2 = min(bw, X1-px)
                out[py:py+ph2, px:px+pw2] = patch[:ph2, :pw2]
    # 填充区与周围做羽化过渡（避免硬边）
    mask = np.zeros((h, w), dtype=np.float32)
    for (y0, y1, x0, x1) in boxes:
        mask[int(y0*h):int(y1*h), int(x0*w):int(x1*w)] = 1.0
    mimg = Image.fromarray((mask*255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(6))
    m = np.asarray(mimg, dtype=np.float32)/255.0
    soft = np.asarray(Image.fromarray(clip(out)).filter(ImageFilter.GaussianBlur(3)), dtype=np.float32)
    return out*(1-m[...,None]) + soft*m[...,None]

def build_hd(src_name, out_name, size, detail_fn, wm_boxes):
    """
    V106 v4：先把水印 inpaint 掉，再自由取块放大 —— 不再需要"绕开窗口"。
    wm_boxes: 归一化 (y0,y1,x0,x1)，实测水印位置。
    """
    src = read_rgb(src_name)
    src = inpaint_watermark(src, wm_boxes)          # ① 先修掉水印
    h, w, _ = src.shape
    canvas = np.zeros((size, size, 3), dtype=np.float32)
    cells = 2
    cw = size // cells
    rng = np.random.RandomState(306)
    for i in range(cells):
        for j in range(cells):
            # 自由取块（水印已修，全图皆可用）→ 4 块各不相同 → 天然无重复感
            side = min(h, w) // 2
            oy = rng.randint(0, max(1, h - side)); ox = rng.randint(0, max(1, w - side))
            patch = src[oy:oy+side, ox:ox+side]
            im = Image.fromarray(clip(patch)).resize((cw, cw), Image.LANCZOS)
            canvas[i*cw:(i+1)*cw, j*cw:(j+1)*cw] = np.asarray(im, dtype=np.float32)

    soft = np.asarray(Image.fromarray(clip(canvas)).filter(ImageFilter.GaussianBlur(1.0)), dtype=np.float32)
    m = np.zeros((size, size), dtype=np.float32)
    m[cw-20:cw+20, :] = 1.0
    m[:, cw-20:cw+20] = 1.0
    m = np.asarray(Image.fromarray((m*255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(14)), dtype=np.float32)/255.0
    canvas = canvas*(1-m[...,None]) + soft*m[...,None]

    canvas = detail_fn(canvas, size)
    canvas = wrap_blend(canvas, band=64)
    img = Image.fromarray(clip(canvas), mode="RGB")
    p = os.path.join(SRC, out_name)
    img.save(p, optimize=True)
    print("  -> %s  %s  %.1fMB" % (out_name, img.size, os.path.getsize(p)/1024/1024))


def asphalt_detail(a, size):
    # 高频骨料颗粒（无涡旋）
    g = fbm(size, size, [768, 384], [0.55, 0.45], 901)
    a += (g - 0.5)[..., None] * 30.0
    # 稀疏锐利亮骨料
    rng = np.random.RandomState(11)
    br = rng.rand(size, size) > 0.9972
    a[br] = a[br]*0.45 + np.array([158.0, 155.0, 150.0])*0.55
    # 细裂纹：用极窄的 fbm 等值线（阈值收得很紧 → 只有细线，无涡旋感）
    cr = fbm(size, size, [140, 70, 35], [0.5, 0.3, 0.2], 1001)
    line = np.abs(cr - 0.5) < 0.0045
    a[line] *= 0.70
    return a

def grass_detail(a, size):
    h = w = size
    ny, nx = np.mgrid[0:h, 0:w].astype(np.float32)
    blades = np.zeros((h, w), dtype=np.float32)
    for k, ang in enumerate([0.35, 1.15, 2.05, 2.85, 0.75, 1.6]):
        f = 200.0 + k*70.0
        blades += np.sin((nx*math.cos(ang) + ny*math.sin(ang)) * f / w * math.pi * 2 + k*2.1)
    blades = blades/6.0*0.5 + 0.5
    a *= (0.92 + 0.16*blades)[..., None]
    patch = fbm(size, size, [72, 28, 12], [0.45, 0.35, 0.20], 1101)
    a *= (0.86 + 0.28*patch)[..., None]
    dry = fbm(size, size, [44, 18], [0.6, 0.4], 1201) > 0.735
    a[dry] = a[dry]*0.5 + np.array([180.0, 160.0, 98.0])*0.5
    return a

if __name__ == "__main__":
    print("V106 贴图增强 v4（水印 inpaint 根除 / 2048 / 无涡旋 / 可平铺）")
    # ⚠️ 水印实测位置（asphalt.png 1024²，逐条带肉眼扫描 + 亮异常网格双重确认）：
    #    「AI生成 / WORKBUDDY」两行白字位于 y≈430-515、x≈355-525
    #    → 归一化 y 0.41-0.52、x 0.33-0.53（**留足余量**，前两版都是边界算紧导致漏字进游戏）
    wm_y = (0.40, 0.53)
    wm_x = (0.32, 0.55)
    asphalt_wm = [(wm_y[0], wm_y[1], wm_x[0], wm_x[1])]
    grass_wm = [(wm_y[0], wm_y[1], wm_x[0], wm_x[1])]
    build_hd("asphalt.png", "asphalt_hd.png", 2048, asphalt_detail, asphalt_wm)
    build_hd("grass.png", "grass_hd.png", 2048, grass_detail, grass_wm)
    print("完成")
