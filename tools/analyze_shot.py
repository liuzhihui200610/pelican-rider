# -*- coding: utf-8 -*-
"""截图像素体检：不看图，用数字判断画质是否正常"""
import sys
import numpy as np
from PIL import Image


def lum(a):
    return 0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]


def report(path, kind):
    img = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0
    h, w, _ = img.shape
    L = lum(img)
    mx = img.max(-1)
    mn = img.min(-1)
    sat = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0.0)

    sky = img[: h // 5]
    ground = img[int(h * 0.72):]
    print("== %s (%s) ==" % (path, kind))
    print("  全图平均亮度   %.3f" % L.mean())
    print("  过曝像素(>0.95) %.1f%%" % (100 * (L > 0.95).mean()))
    print("  死黑像素(<0.04) %.1f%%" % (100 * (L < 0.04).mean()))
    print("  平均饱和度     %.3f" % sat.mean())
    print("  天空区 RGB     %.2f %.2f %.2f" % (sky[..., 0].mean(), sky[..., 1].mean(), sky[..., 2].mean()))
    print("  地面区 RGB     %.2f %.2f %.2f" % (ground[..., 0].mean(), ground[..., 1].mean(), ground[..., 2].mean()))
    # 中心区域（角色所在）
    c = img[int(h * 0.45): int(h * 0.85), int(w * 0.40): int(w * 0.60)]
    Lc = lum(c)
    print("  中心区亮度     %.3f  过曝 %.1f%%" % (Lc.mean(), 100 * (Lc > 0.95).mean()))
    print()


if __name__ == "__main__":
    base = r"C:\Users\26483\WorkBuddy\2026-09-29-21-13-37\PelicanRider-Godot"
    report(base + r"\shot_side.png", "白天侧面")
    report(base + r"\shot_chase.png", "黄昏追尾")
    report(base + r"\shot_night.png", "夜晚")
