@echo off
chcp 65001 >nul
set "ROOT=E:\迅雷下载"
set "CADDY=C:\Caddy\caddy.exe"
set "BASEURL=http://192.168.0.245:8080"
if not exist "%CADDY%" (echo Caddy not found: %CADDY% & pause & exit /b 1)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Generate-Manifest.ps1" -Root "%ROOT%" -BaseURL "%BASEURL%"
if errorlevel 1 (pause & exit /b 1)
echo Opening LAN server. Press Ctrl+C to stop.
"%CADDY%" file-server --root "%ROOT%" --listen :8080 --browse
pause
