@echo off
setlocal
cd /d "%~dp0"
set "GODOT=C:\Users\26483\AppData\Local\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64.exe"

echo ============================================
echo  Pelican Rider 3D - Launch Diagnostics
echo ============================================
echo.
echo [1] Godot executable:
if exist "%GODOT%" (echo     FOUND  %GODOT%) else (echo     MISSING  %GODOT%)
echo.
echo [2] Project file:
if exist "%~dp0project.godot" (echo     FOUND  %~dp0project.godot) else (echo     MISSING  %~dp0project.godot)
echo.
echo [3] Testing headless run (no window will open):
echo.
"%GODOT%" --headless --path "%~dp0." --verify --quit-after 120
echo.
echo [4] Done. If you saw [BOOT] and [VERIFY] lines above,
echo     the project is fine - the game just needs a moment
echo     to compile shaders on first launch.
echo.
pause
