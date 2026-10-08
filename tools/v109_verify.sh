#!/usr/bin/env bash
# V109 全量验证：fulltest → stress → 8 档性能基线
set -u
PROJ="C:/Users/26483/WorkBuddy/2026-09-29-21-13-37/PelicanRider-Godot"
CONSOLE="C:/Users/26483/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.7.2-stable_win64_console.exe"
GUI="C:/Users/26483/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.7.2-stable_win64.exe"
UDIR="C:/Users/26483/AppData/Roaming/Godot/app_userdata/鹈鹕骑手 3D (Pelican Rider)"
LOGD="$PROJ/logs/V109"
mkdir -p "$LOGD"
cd "$PROJ"

# ft_done 必须不存在，否则 fulltest 会误判为"已重开"直接退出（不能 rm，改为移走）
[ -f "$UDIR/ft_done" ] && mv "$UDIR/ft_done" "$LOGD/ft_done_prev_$(date +%s).bak" || true

echo "=== [1/3] fulltest ==="
timeout 420 "$CONSOLE" --headless --path "$PROJ" --fulltest > "$LOGD/fulltest.log" 2>&1
echo "EXIT=$?"
for k in "SCRIPT ERROR" "Parse Error" "Failed to load script" "SHADER ERROR" "RUNTIME ERROR"; do
  echo "  $k = $(grep -c "$k" "$LOGD/fulltest.log")"
done

[ -f "$UDIR/ft_done" ] && mv "$UDIR/ft_done" "$LOGD/ft_done_prev2_$(date +%s).bak" || true

echo "=== [2/3] stress ==="
timeout 420 "$CONSOLE" --headless --path "$PROJ" --stress > "$LOGD/stress.log" 2>&1
echo "EXIT=$?"
for k in "SCRIPT ERROR" "Parse Error" "Failed to load script" "SHADER ERROR" "RUNTIME ERROR"; do
  echo "  $k = $(grep -c "$k" "$LOGD/stress.log")"
done

echo "=== [3/3] 8 档性能基线（GUI，最小化窗口）==="
STAMP=$(date +%Y%m%d-%H%M)
OUT="$LOGD/perf-baseline-$STAMP.txt"
{
  echo "=== V109 性能基线 $STAMP ==="
  echo "GPU: RTX 4060 Laptop / i7-13650HX / 24GB / Win11 / 每档 300 帧（跳过前 90 帧着色器编译期）"
  echo "（V109-A 修复：--perf 现已生效 --autoday/--autocam，且采样期间冻结昼夜 → 各档光照恒定可比）"
  echo "------------------------------------------------------------"
} > "$OUT"
CASES=(
  "0:0.25:0:高-正午-追尾"
  "1:0.25:0:中-正午-追尾"
  "2:0.25:0:低-正午-追尾"
  "0:0.47:0:高-黄昏-追尾"
  "0:0.80:0:高-深夜-追尾"
  "1:0.80:0:中-深夜-追尾"
  "0:0.25:2:高-正午-侧面"
  "0:0.80:3:高-深夜-第一人称"
)
for c in "${CASES[@]}"; do
  IFS=":" read -r q d cam label <<< "$c"
  [ -f perf_last.txt ] && mv perf_last.txt "$LOGD/perf-stale-$STAMP.txt"
  timeout 150 "$GUI" --path "$PROJ" --perf --perfframes=300 --perfq=$q --autoday=$d --autocam=$cam >/dev/null 2>&1
  if [ -f perf_last.txt ]; then
    line=$(cat perf_last.txt); mv perf_last.txt "$LOGD/perf-${STAMP}-q${q}d${d}c${cam}.txt"
  else
    line="(无结果)"
  fi
  echo "$label -> $line" | tee -a "$OUT"
done
echo "DONE -> $OUT" | tee -a "$OUT"
