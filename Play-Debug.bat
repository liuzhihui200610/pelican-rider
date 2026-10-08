@echo off
setlocal
cd /d "%~dp0"
set "GODOT=C:\Users\26483\AppData\Local\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64.exe"

echo ============================================
echo  Running Godot in foreground (errors visible)
echo ============================================
echo Project: %~dp0.
echo Godot  : %GODOT%
echo.
"%GODOT%" --path "%~dp0."
set RC=%ERRORLEVEL%
echo.
echo Godot exited with code: %RC%
echo (First launch can take 15-30 seconds to compile shaders.)
echo.
pause
