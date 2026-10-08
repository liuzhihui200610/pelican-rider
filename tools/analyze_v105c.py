# -*- coding: utf-8 -*-
"""V105c 像素体检：细节方差（纹理丰富度）+ 亮度分布（过曝/死黑）"""
import sys
from PIL import Image
import numpy as np

def stats(path, tag):
    im = Image.open(path).convert("RGB")
    a = np.asarray(im).astype(np.float32)
    h, w, _ = a.shape
    lum = a @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
    # 路面近景带（画面中下部中央）
    road = lum[int(h*0.62):int(h*0.97), int(w*0.30):int(w*0.72)]
    # 草地远场带（右侧中线偏上）
    grass = lum[int(h*0.52):int(h*0.62), int(w*0.55):int(w*0.98)]
    # 细节方差：高频梯度能量
    def detail(x):
        gx = np.abs(np.diff(x, axis=1)).mean()
        gy = np.abs(np.diff(x, axis=0)).mean()
        return (gx + gy) / 2.0
    over = (lum > 250).mean() * 100.0
    dead = (lum < 5).mean() * 100.0
    print(f"{tag:22s} 路面细节 {detail(road):7.3f}  草地细节 {detail(grass):7.3f}  "
          f"路面均亮 {road.mean():6.1f}  过曝 {over:5.2f}%  死黑 {dead:5.2f}%")

for p, t in [("v105b_summer.png", "v105b summer"),
             ("v105c_summer.png", "v105c summer"),
             ("v105c_golden.png", "v105c golden"),
             ("v105c_night.png",  "v105c night")]:
    try:
        stats(p, t)
    except Exception as e:
        print(f"{t}: {e}")
