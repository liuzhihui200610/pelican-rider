# -*- coding: utf-8 -*-
"""V97 审计帧体检：V96 vs V97 逐项对比（不看图，用数字判断改动是否生效）
重点验证：
  1) 白天/黄昏过曝像素是否下降（压太阳死白是否见效）
  2) 时序亮度是否仍 白天 > 黄昏 > 夜晚
  3) 夜晚是否仍不死黑（银河/星点/灯池在）
  4) 天空/地面色彩是否仍随时间正确变化
"""
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
    ground = img[int(h * 0.72):]
    c = img[int(h * 0.45): int(h * 0.85), int(w * 0.40): int(w * 0.60)]
    Lc = lum(c)
    return {
        "mean": L.mean(),
        "over": 100 * (L > 0.95).mean(),
        "dead": 100 * (L < 0.04).mean(),
        "sky": (sky[..., 0].mean(), sky[..., 1].mean(), sky[..., 2].mean()),
        "gnd": (ground[..., 0].mean(), ground[..., 1].mean(), ground[..., 2].mean()),
        "center": Lc.mean(),
        "center_over": 100 * (Lc > 0.95).mean(),
        "dark_content": 100 * ((L < 0.25) & (L > 0.04)).mean(),
    }


def show(tag, s):
    print("  [%s] 亮度%.3f 过曝%.1f%% 死黑%.1f%% 中心亮度%.3f 中心过曝%.1f%% 暗部有内容%.1f%%"
          % (tag, s["mean"], s["over"], s["dead"], s["center"], s["center_over"], s["dark_content"]))
    print("        天空RGB %.2f %.2f %.2f   地面RGB %.2f %.2f %.2f" % (s["sky"] + s["gnd"]))


if __name__ == "__main__":
    for label, v96, v97 in [
        ("白天 golden", "v96_golden.png", "v97_golden.png"),
        ("黄昏 dusk", "v96_dusk.png", "v97_dusk.png"),
        ("夜晚 night", "v96_night.png", "v97_night.png"),
    ]:
        print("== %s ==" % label)
        s96 = stats(BASE + "\\" + v96)
        s97 = stats(BASE + "\\" + v97)
        show("V96", s96)
        show("V97", s97)
        d_over = s97["over"] - s96["over"]
        d_center = s97["center_over"] - s96["center_over"]
        print("  变化: 过曝 %+.1fpp  中心过曝 %+.1fpp  亮度 %+.3f" % (d_over, d_center, s97["mean"] - s96["mean"]))
        print()
