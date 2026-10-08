# -*- coding: utf-8 -*-
"""V102 审计：V99 vs V102 三时段像素对比"""
import numpy as np
from PIL import Image

BASE = r"C:\Users\26483\WorkBuddy\2026-09-29-21-13-37\PelicanRider-Godot"


def lum(a):
    return 0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]


def stats(path):
    img = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0
    h, w, _ = img.shape
    L = lum(img)
    sky = img[: h // 5]
    sea = img[int(h * 0.40): int(h * 0.60), : w // 3]
    return {
        "mean": L.mean(),
        "over": 100 * (L > 0.95).mean(),
        "dead": 100 * (L < 0.04).mean(),
        "sky_rgb": (sky[..., 0].mean(), sky[..., 1].mean(), sky[..., 2].mean()),
        "sea_rgb": (sea[..., 0].mean(), sea[..., 1].mean(), sea[..., 2].mean()),
        "sat": (img.max(-1) - img.min(-1)).mean(),
    }


def show(tag, s):
    r, g, b = s["sky_rgb"]
    sr, sg, sb = s["sea_rgb"]
    print(f"[{tag}] 亮度{s['mean']:.3f} 过曝{s['over']:.2f}% 死黑{s['dead']:.2f}% "
          f"饱和{s['sat']:.3f} 天空R{r:.2f}/G{g:.2f}/B{b:.2f} 海R{sr:.2f}/G{sg:.2f}/B{sb:.2f}")


pairs = [("summer", "summer", "夏日"), ("sunset", "dusk", "黄昏"), ("night", "night", "夜晚")]
for old_key, new_key, name in pairs:
    print(f"== {name} ==")
    show("V99 ", stats(f"{BASE}/v99_{old_key}.png"))
    show("V102", stats(f"{BASE}/v102_{new_key}.png"))
