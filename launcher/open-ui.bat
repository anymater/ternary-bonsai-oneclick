@echo off
chcp 936 >nul
REM ===== 【打开界面】只开浏览器，不启动模型 =====
setlocal
call "%~dp0_env.bat"
curl -sf -o nul --noproxy "*" --max-time 2 "%BASE%health"
if errorlevel 1 (
  echo [未运行] 服务没起来。先双击 start.bat 启动模型。
  pause
  exit /b 1
)
echo [打开] %BASE%
start "" "%BASE%"
exit /b 0
