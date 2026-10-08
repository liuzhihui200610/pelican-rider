@echo off
setlocal
cd /d "%~dp0"
set "GODOT=C:\Users\26483\AppData\Local\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64.exe"

if not exist "%GODOT%" (
  echo.
  echo [ERROR] Godot not found:
  echo   %GODOT%
  echo Please run Diagnostics.bat to find the correct path.
  echo.
  pause
  exit /b 1
)

echo Launching Pelican Rider 3D ...
echo (First launch may take 15-30 seconds while shaders compile. Please wait.)
start "" "%GODOT%" --path "%~dp0."
exit /b 0
