# -*- coding: utf-8 -*-
"""V95 审计帧体检：golden(白天) / dusk(黄昏) / night(夜晚) 三帧像素统计
不看图，用数字判断：时序亮度正确、过曝受控、夜空不死黑（银河/星点可见）。
"""
import sys
import numpy as np
from PIL import Image

BASE = r"C:\Users\26483\WorkBuddy\2026-09-29-21-13-37\PelicanRider-Godot"


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
    c = img[int(h * 0.45): int(h * 0.85), int(w * 0.40): int(w * 0.60)]
    Lc = lum(c)
    print("  中心区亮度     %.3f  过曝 %.1f%%" % (Lc.mean(), 100 * (Lc > 0.95).mean()))
    # 暗部细节：夜空里有多少"非死黑"的微弱亮度（星点/银河/灯池的线索）
    print("  暗部有内容(<0.25且>0.04) %.1f%%" % (100 * ((L < 0.25) & (L > 0.04)).mean()))
    print()


if __name__ == "__main__":
    report(BASE + r"\v95_golden.png", "白天 golden")
    report(BASE + r"\v95_dusk.png", "黄昏 dusk")
    report(BASE + r"\v95_night.png", "夜晚 night")
