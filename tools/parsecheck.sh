#!/usr/bin/env bash
# 快速体检：只加载 main.gd + 编译着色器，秒级发现「缩进 / := 声明 / shader 语法」错误。
# 为什么需要它：
#   1) V83/V92/V95/V98 四次都因缩进或 := 写错而整工程加载失败，
#      而完整 fulltest 要跑数分钟才发现、且会挂死 → 改完先跑这个。
#   2) V98 还踩了 Godot4 的坑：light() 里写 EMISSION 会编译失败
#      （"Unknown identifier in expression: 'EMISSION'"），功能自验照样全绿、只有 SHADER_ERROR 计数才看得出来。
# 用法：bash tools/parsecheck.sh
set -u
PROJ="C:/Users/26483/WorkBuddy/2026-09-29-21-13-37/PelicanRider-Godot"
GODOT="C:/Users/26483/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.7.2-stable_win64_console.exe"
UDIR="C:/Users/26483/AppData/Roaming/Godot/app_userdata/鹈鹕骑手 3D (Pelican Rider)"

# ---- 第 1 步：GDScript 语法 ----
TMP="$PROJ/parsecheck.gd"
cat > "$TMP" <<'EOF'
extends SceneTree
func _init():
	var s = load("res://scripts/main.gd")
	print("PARSE_RESULT=", "OK" if s != null else "FAIL")
	quit()
EOF
OUT=$(timeout 120 "$GODOT" --headless --path "$PROJ" --script res://parsecheck.gd 2>&1)
rm -f "$TMP"
echo "$OUT" | grep -E "PARSE_RESULT|Parse Error|SCRIPT ERROR|at: GDScript" | head -8
if ! echo "$OUT" | grep -q "PARSE_RESULT=OK"; then
	echo "❌ 语法错误，先修上面那行（别跑 fulltest，会挂死）"
	exit 1
fi
echo "✅ 语法通过"

# ---- 第 2 步：着色器编译（--bare 只建场景，秒级）----
rm -f "$UDIR/ft_done" 2>/dev/null
taskkill //F //IM "Godot_v4.7.2-stable_win64_console.exe" >/dev/null 2>&1 || true
SLOG="$PROJ/logs/parsecheck_shader.log"   # V108：日志不再散落在项目根目录
timeout 180 "$GODOT" --headless --path "$PROJ" --bare > "$SLOG" 2>&1
SE=$(grep -c "SHADER ERROR" "$SLOG")
if [ "$SE" -ne 0 ]; then
	echo "❌ 着色器编译失败 $SE 处："
	grep -A 3 "SHADER ERROR" "$SLOG" | head -20
	exit 1
fi
echo "✅ 着色器全部编译通过（0 SHADER_ERROR）→ 可以跑完整测试"
