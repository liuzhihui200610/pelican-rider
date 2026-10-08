# -*- coding: utf-8 -*-
"""从 AI 生成的颜色贴图推导法线贴图（Sobel 梯度 → 法线）
让地面有凹凸细节、会随光线变化 —— 这是"细腻感"的关键。
"""
import os
import numpy as np
from PIL import Image

DST = r"C:\Users\26483\WorkBuddy\2026-09-29-21-13-37\PelicanRider-Godot\assets"


def height_from_rgb(a):
    # 用亮度作为高度场（暗=凹，亮=凸）
    return 0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]


def sobel(h):
    ky = np.array([[1, 2, 1], [0, 0, 0], [-1, -2, -1]], dtype=np.float32)
    kx = np.array([[1, 0, -1], [2, 0, -2], [1, 0, -1]], dtype=np.float32)
    pad = np.pad(h, 1, mode="wrap")
    gx = np.zeros_like(h)
    gy = np.zeros_like(h)
    for i in range(3):
        for j in range(3):
            gx += kx[i, j] * pad[i:i + h.shape[0], j:j + h.shape[1]]
            gy += ky[i, j] * pad[i:i + h.shape[0], j:j + h.shape[1]]
    return gx, gy


def make_normal(src, dst, strength=2.0, blur=1):
    p = os.path.join(DST, src)
    if not os.path.exists(p):
        print("缺:", src)
        return
    im = Image.open(p).convert("RGB")
    a = np.asarray(im, dtype=np.float32) / 255.0
    h = height_from_rgb(a)
    # 轻微模糊：去掉像素级噪点，只留材质起伏
    if blur > 0:
        k = 2 * blur + 1
        pad = np.pad(h, blur, mode="wrap")
        acc = np.zeros_like(h)
        for i in range(k):
            for j in range(k):
                acc += pad[i:i + h.shape[0], j:j + h.shape[1]]
        h = acc / (k * k)
    gx, gy = sobel(h)
    nx = -gx * strength
    ny = -gy * strength
    nz = np.ones_like(h)
    l = np.sqrt(nx * nx + ny * ny + nz * nz)
    nx, ny, nz = nx / l, ny / l, nz / l
    # 编码到 0..1（切线空间法线）
    out = np.stack([nx * 0.5 + 0.5, ny * 0.5 + 0.5, nz * 0.5 + 0.5], axis=-1)
    Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8)).save(os.path.join(DST, dst))
    print("%s <- %s (强度 %.1f)" % (dst, src, strength))


make_normal("asphalt.png", "asphalt_normal.png", strength=1.6, blur=1)
make_normal("grass.png", "grass_normal.png", strength=2.4, blur=1)
make_normal("sand.png", "sand_normal.png", strength=2.0, blur=2)
print("法线贴图生成完成")
