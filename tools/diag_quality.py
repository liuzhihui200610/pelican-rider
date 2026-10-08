# -*- coding: utf-8 -*-
"""V106 画质诊断：分区域多维度体检，找出最弱环节"""
from PIL import Image, ImageFilter
import numpy as np, sys

def region_stats(a, name, box):
    h, w, _ = a.shape
    y0, y1, x0, x1 = int(h*box[0]), int(h*box[1]), int(w*box[2]), int(w*box[3])
    r = a[y0:y1, x0:x1]
    lum = r @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
    gx = np.abs(np.diff(lum, axis=1)).mean()
    gy = np.abs(np.diff(lum, axis=0)).mean()
    detail = (gx + gy) / 2.0
    # 局部对比度（std of 8x8 blocks）
    hh, ww = (lum.shape[0]//8)*8, (lum.shape[1]//8)*8
    if hh > 8 and ww > 8:
        blocks = lum[:hh, :ww].reshape(hh//8, 8, ww//8, 8).transpose(0,2,1,3).reshape(-1,64)
        lc = blocks.std(axis=1).mean()
    else:
        lc = lum.std()
    # 色彩饱和度
    mx = r.max(axis=2); mn = r.min(axis=2)
    sat = np.where(mx>0, (mx-mn)/np.maximum(mx,1), 0).mean()*100
    # 频域：高频能量占比（纹理丰富度的另一视角）
    g = np.asarray(Image.fromarray(r.astype(np.uint8)).convert("L").filter(ImageFilter.FIND_EDGES), dtype=np.float32)
    he = g.mean()
    print(f"  {name:12s} 细节{detail:6.2f}  局部对比{lc:6.2f}  饱和{sat:5.1f}%  边缘能量{he:6.2f}  均亮{lum.mean():6.1f}")

for f in sys.argv[1:] or ["v105d_final.png"]:
    print(f"=== {f} ===")
    a = np.asarray(Image.open(f).convert("RGB")).astype(np.float32)
    region_stats(a, "全画面",   (0.0, 1.0, 0.0, 1.0))
    region_stats(a, "天空",     (0.0, 0.25, 0.30, 0.75))
    region_stats(a, "远山路",   (0.30, 0.45, 0.40, 0.62))
    region_stats(a, "近景路面", (0.70, 0.98, 0.28, 0.72))
    region_stats(a, "左海面",   (0.30, 0.60, 0.0, 0.20))
    region_stats(a, "右草地",   (0.50, 0.62, 0.70, 1.0))
    region_stats(a, "左侧棕榈", (0.05, 0.55, 0.0, 0.25))
