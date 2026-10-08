# -*- coding: utf-8 -*-
"""包装器：进程内调用 3D 生成脚本（绕开 Windows 命令行 32KB 限制）
用法: python gen3d_wrapper.py <token> <参考图路径|-> <提示词>
"""
import sys
import base64
import importlib.util

SKILL = r"E:\LenovoSoftstore\Install\WorkBuddy\resources\app.asar.unpacked\resources\plugins\workbuddy-builtin\skills\buddy-multimodal-generation\scripts\buddy-multimodal-generation.py"

TOKEN = sys.argv[1]
REF = sys.argv[2]          # 参考图路径；传 "-" 表示文生 3D
PROMPT = sys.argv[3]

spec = importlib.util.spec_from_file_location("bmg", SKILL)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

args = ["bmg", "3d"]
if REF != "-":
    args += ["--image-base64", base64.b64encode(open(REF, "rb").read()).decode()]
else:
    args += [PROMPT]
args += ["--enable-pbr", "--face-count", "30000", "--token", TOKEN]

sys.argv = args
mod.main()
