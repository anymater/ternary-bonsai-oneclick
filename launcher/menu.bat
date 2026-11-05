@echo off
chcp 936 >nul
REM ===== 【功能菜单】一个入口，选编号执行 =====
setlocal
call "%~dp0_env.bat"
title Bonsai 2 - 功能菜单

:menu
cls
echo ============================================================
echo    Ternary Bonsai 2 27B   控制面板
echo ============================================================
echo    目录：%ROOT%
echo    模型：%MODELFILE%    上下文：%CTX%
curl -sf -o nul --noproxy "*" --max-time 2 "%BASE%health"
if errorlevel 1 (
  echo    状态：未运行
) else (
  echo    状态：运行中    %BASE%
)
echo.
echo    [1] 启动
echo    [2] 停止（释放显存）
echo    [3] 重启
echo    [4] 打开 Web 界面
echo    [5] 查看状态 / 诊断
echo    [6] 局域网放行（手机访问，需管理员）
echo    [0] 退出
echo.
set "C="
set /p "C=输入编号后回车："

if not defined C goto quit
if "%C%"=="1" ( call "%~dp0start.bat" & goto after )
if "%C%"=="2" ( call "%~dp0stop.bat" & goto after )
if "%C%"=="3" ( call "%~dp0restart.bat" & goto after )
if "%C%"=="4" ( call "%~dp0open-ui.bat" & goto after )
if "%C%"=="5" ( call "%~dp0status.bat" & goto after )
if "%C%"=="6" ( call "%~dp0allow-lan-firewall.bat" & goto after )
if "%C%"=="0" goto quit
echo    无效编号：%C%
ping -n 3 127.0.0.1 >nul
goto menu

:after
echo.
pause
goto menu

:quit
exit /b 0
