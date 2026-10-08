# -*- coding: utf-8 -*-
"""资产方向体检：不看模型，用包围盒数值验证每个部件的朝向对不对"""
import sys
import numpy as np
from PIL import Image  # noqa: F401  (确保 pillow 存在)


def obj_bbox(path):
    pts = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("v "):
                _, x, y, z = line.split()[:4]
                pts.append((float(x), float(y), float(z)))
    a = np.asarray(pts)
    lo, hi = a.min(0), a.max(0)
    return lo, hi, hi - lo


base = r"C:\Users\26483\WorkBuddy\2026-09-29-21-13-37\PelicanRider-Godot\assets"
checks = [
    # (文件, 期望: (哪个轴最薄, 哪个轴最长), 容差说明)
    ("bike_wheel.obj",      "x_thin_yz_wide"),   # 车轮：轴朝 X，轮盘在 YZ
    ("bike_whitewall.obj",  "x_thin_yz_wide"),
    ("bike_spokes.obj",     "x_thin_yz_wide"),
    ("bike_chainring.obj",  "x_thin_yz_wide"),
    ("bike_cog.obj",        "cog_small"),
    ("pelican_body.obj",    "longest_z"),        # 身体：前后最长
    ("pelican_beak.obj",    "longest_z"),        # 喙：朝前伸
]
ok = True
for name, expect in checks:
    lo, hi, ext = obj_bbox(base + "\\" + name)
    thin_x = ext[0] < 0.12 and max(ext[1], ext[2]) > 0.2
    longest_z = ext[2] >= ext[0] and ext[2] >= ext[1]
    if expect == "cog_small":
        passed = ext[0] < 0.1 and ext[1] < 0.2 and ext[2] < 0.2
    elif expect == "x_thin_yz_wide":
        passed = thin_x
        detail = "X厚 %.2f / Y %.2f / Z %.2f" % (ext[0], ext[1], ext[2])
    else:
        passed = longest_z
        detail = "X %.2f / Y %.2f / Z %.2f" % tuple(ext)
    print("%-22s %s  (%s)" % (name, "OK " if passed else "FAIL", detail))
    if not passed:
        ok = False
print("\n结论:", "全部通过 ✓" if ok else "存在方向错误 ✗")
sys.exit(0 if ok else 1)
