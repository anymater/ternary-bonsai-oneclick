@echo off
chcp 936 >nul
REM =====================================================================
REM  【局域网放行】允许手机 / 别的电脑访问 %PORT% 端口。
REM  需要管理员权限：双击后会自动弹 UAC，点「是」即可。
REM  只对「专用网络 / 域网络」放开，公共 Wi-Fi 不受影响。
REM  撤销放行：右键以管理员身份运行本文件并加参数 remove
REM  查看状态：本文件加参数 status
REM =====================================================================

setlocal
call "%~dp0_env.bat"
title Bonsai 2 - 局域网放行

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo [提权] 这一步需要管理员权限，正在弹出 UAC 确认框，请点「是」...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b 0
)

if /i "%~1"=="remove" goto remove
if /i "%~1"=="status" goto status

netsh advfirewall firewall delete rule name="%RULENAME%" >nul 2>&1
netsh advfirewall firewall add rule name="%RULENAME%" dir=in action=allow protocol=TCP localport=%PORT% profile=private,domain >nul
if %errorlevel% neq 0 (
  echo [失败] 规则添加失败，请确认是以管理员身份运行的。
) else (
  echo [完成] 已放行 TCP %PORT%（专用网络 / 域网络）。
  echo        手机或另一台电脑连同一个 Wi-Fi，访问 http://本机局域网IP:%PORT%/
  echo        本机局域网 IP 在 start.bat 启动后的提示里，或跑 status.bat 查看。
)
echo.
pause
exit /b 0

:remove
netsh advfirewall firewall delete rule name="%RULENAME%"
echo [完成] 已撤销局域网放行。
echo.
pause
exit /b 0

:status
echo 当前规则：
netsh advfirewall firewall show rule name="%RULENAME%"
echo.
pause
exit /b 0
