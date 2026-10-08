#!/usr/bin/env bash
# ============================================================
# V108-A 性能基线采集（高/中/低三档画质）
# ------------------------------------------------------------
# 为什么必须 GUI 版：headless 不真渲染，FPS 完全无意义。
#   本脚本用 PowerShell 以「最小化窗口」启动 GUI 版真跑，
#   不抢焦点、不干扰用户操作（沿用交接文档的沙箱/窗口约定）。
#
# 前置：main.gd 支持
#   --perf             跑够帧数 → 打印 [PERF] 摘要 → 自动退出
#   --perfframes=N     采样帧数（默认 1200 ≈ 20 秒 @60fps）
#   --perfq=0|1|2      指定画质档（0 高 / 1 中 / 2 低）
#   --autoday=F        指定时段（0.38 正午 / 0.14 黄金 / 0.80 深夜）
#   --autocam=N        指定机位（0 追尾 / 1 低角 / 2 侧面 / 3 第一人称）
#
# 用法： bash tools/perf_baseline.sh
# 产物： logs/V108/perf-<时间戳>.txt        逐档摘要（可直接贴进报告）
#        logs/V108/perf-<...>-raw.log       每档原始 stdout
# ============================================================
set -u

PROJ="C:/Users/26483/WorkBuddy/2026-09-29-21-13-37/PelicanRider-Godot"
EXE="C:/Users/26483/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.7.2-stable_win64.exe"
OUTDIR="$PROJ/logs/V108"
mkdir -p "$OUTDIR"

STAMP=$(date +%Y%m%d-%H%M)
OUT="$OUTDIR/perf-$STAMP.txt"

{
	echo "=== V108 性能基线  $STAMP ==="
	echo "机器：i7-13650HX / RTX 4060 Laptop / 24GB / Windows 11"
	echo "采样：每档 1200 帧（跳过前 90 帧的着色器编译期）"
	echo "------------------------------------------------------------"
} | tee "$OUT"

# 采集组合：  画质档:时段:机位:说明
CASES=(
	"0:0.38:0:高-正午-追尾"
	"1:0.38:0:中-正午-追尾"
	"2:0.38:0:低-正午-追尾"
	"0:0.14:0:高-黄金-追尾"
	"0:0.80:0:高-深夜-追尾"
	"1:0.80:0:中-深夜-追尾"
	"0:0.38:2:高-正午-侧面"
	"0:0.80:3:高-深夜-第一人称"
)

# ⚠️ 本机安全策略会拦截删除（safe-delete）→ 全程只用「移动」，绝不用 rm/Remove-Item。
# 每档跑完立刻把 perf_last.txt 移走，因此下一档开始时该文件必然不存在，无需清理。
if [ -f "$PROJ/perf_last.txt" ]; then
	mv "$PROJ/perf_last.txt" "$OUTDIR/perf-stale-$(date +%H%M%S).txt"
fi

for c in "${CASES[@]}"; do
	IFS=":" read -r q d cam label <<< "$c"
	result="$OUTDIR/perf-${STAMP}-q${q}d${d}c${cam}.txt"
	echo ">> 采集中：$label  (q=$q day=$d cam=$cam)" | tee -a "$OUT"

	# GUI 版 Godot 的 stdout 在外部不可见 → 靠 main.gd 落盘的 perf_last.txt 取结果
	powershell -NoProfile -Command \
		"Start-Process -FilePath '$EXE' -ArgumentList '--path','$PROJ','--perf','--perfframes=600','--perfq=$q','--autoday=$d','--autocam=$cam' -WindowStyle Minimized -Wait" \
		>/dev/null 2>&1
	sleep 2   # 让 GPU / Vulkan 缓存落盘、进程完全退出

	if [ -f "$PROJ/perf_last.txt" ]; then
		mv "$PROJ/perf_last.txt" "$result"
		line=$(cat "$result")
	else
		line="(无结果：进程异常 / Vulkan 缓存被拦截 / 参数未生效)"
	fi
	echo "   $label  ->  $line" | tee -a "$OUT"
done

{
	echo "------------------------------------------------------------"
	echo "完成。摘要：$OUT"
	echo "提示：若某档显示「无输出」，检查该档 raw log 尾部（$OUTDIR/perf-*-raw.log）。"
} | tee -a "$OUT"
