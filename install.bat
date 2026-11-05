@echo off
chcp 936 >nul
REM =====================================================================
REM  【一键安装】下载官方推理引擎 + 模型，写好配置。
REM  可重复执行：已下载且校验通过的文件会自动跳过。
REM  参数：--skip-model  只装引擎，模型自己放
REM        --vision      额外下载视觉投影器（图片输入）
REM        --parts N     下载并发数，默认 12
REM =====================================================================

setlocal
cd /d "%~dp0"
title Ternary Bonsai 2 27B - 一键安装

if not exist "tools\install.ps1" (
  echo [错误] 缺少 tools\install.ps1，压缩包可能不完整。
  pause
  exit /b 1
)

set "ARGS="
:parse
if "%~1"=="" goto run
if /i "%~1"=="--skip-model" goto m1
if /i "%~1"=="--vision" goto m2
if /i "%~1"=="--parts" goto m3
echo [提示] 忽略未知参数：%~1
shift
goto parse

:m1
set "ARGS=%ARGS% -SkipModel"
shift
goto parse

:m2
set "ARGS=%ARGS% -Vision"
shift
goto parse

:m3
set "ARGS=%ARGS% -Parts %~2"
shift
shift
goto parse

:run

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install.ps1" %ARGS%
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
  echo [失败] 安装没有完成（退出码 %RC%）。
  echo        把上面的报错内容发到 issue，或查看 docs\TROUBLESHOOTING.md
  pause
  exit /b %RC%
)
echo 就绪。双击 start.bat 启动。
pause
exit /b 0
