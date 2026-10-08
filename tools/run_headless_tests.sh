#!/usr/bin/env bash
# 无头验证套件：绝不在桌面弹窗。严格用 --headless + console 二进制。
set -u
PROJ="C:/Users/26483/WorkBuddy/2026-09-29-21-13-37/PelicanRider-Godot"
GODOT="C:/Users/26483/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.7.2-stable_win64_console.exe"
UDIR="C:/Users/26483/AppData/Roaming/Godot/app_userdata/鹈鹕骑手 3D (Pelican Rider)"

scan() {
  local f="$1"
  local se=$(grep -c "SCRIPT ERROR" "$f")
  local pe=$(grep -c "Parse Error" "$f")
  local fl=$(grep -c "Failed to load script" "$f")
  local re=$(grep -c "RUNTIME ERROR\|ERROR:.*failed" "$f")
  local sh=$(grep -c "SHADER ERROR" "$f")
  local tot=$((se+pe+fl+sh))
  echo "  SCRIPT_ERROR=$se  PARSE_ERROR=$pe  FAILED_LOAD=$fl  SHADER_ERROR=$sh  RUNTIME_ERR=$re"
  return $tot
}

run_one() {
  local name="$1"; shift
  local args="$*"
  echo "==================== $name ===================="
  echo "args: $args"
  # 清掉残留的 ft_done（fulltest 用）
  rm -f "$UDIR/ft_done" 2>/dev/null
  # 杀掉任何残留 godot 进程，避免端口/锁冲突
  taskkill //F //IM "Godot_v4.7.2-stable_win64_console.exe" >/dev/null 2>&1 || true
  timeout 300 "$GODOT" --headless --path "$PROJ" $args > "$PROJ/${name}.log" 2>&1
  local rc=$?
  echo "raw_exit=$rc"
  scan "$PROJ/${name}.log"
  echo ""
}

run_one "v89d_fulltest" "--fulltest"
run_one "v89d_stress"   "--stress"
run_one "v89d_stress_nogod" "--stress --nogod"
echo "ALL DONE"
