@echo off
chcp 936 >nul
REM =====================================================================
REM  【一键启动】读取 config\ 里的模型档与上下文，绑 0.0.0.0 并启用密钥。
REM  就绪后自动打开 Web 界面，并打印本机与局域网地址。
REM  停止服务：stop.bat
REM =====================================================================

setlocal
call "%~dp0_env.bat"
title Bonsai 2 - 启动

if not exist "%BIN%" (
  echo [错误] 找不到 llama-server.exe
  echo        %BIN%
  echo        还没安装？先双击根目录的 install.bat。
  pause
  exit /b 1
)
if not exist "%TRIPLET%" (
  echo [错误] 找不到模型文件
  echo        %TRIPLET%
  echo        模型没下完？重新双击 install.bat，已下载的文件会自动跳过。
  pause
  exit /b 1
)

REM 已经跑着就不重复启动，避免两个实例抢显存
curl -sf -o nul --noproxy "*" --max-time 2 "%BASE%health"
if not errorlevel 1 goto already

echo [加载中] Ternary Bonsai 2 27B / %MODELFILE% / %CTX% 上下文
echo          模型走 mmap，通常几秒内就绪；第一次加载会慢一些。

start "Bonsai2" /min /d "%ROOT%" "%BIN%" -m "%TRIPLET%" -a %ALIAS% -ngl %NGL% -fa on -c %CTX% -ctk q8_0 -ctv q8_0 -np 1 --jinja --api-key-file "%KEYFILE%" --host 0.0.0.0 --port %PORT%

set /a N=0
:wait
ping -n 2 127.0.0.1 >nul
curl -sf -o nul --noproxy "*" --max-time 2 "%BASE%health"
if not errorlevel 1 goto ready
set /a N+=1
if %N% lss 120 goto wait
echo.
echo [超时] 120 秒内没就绪。
echo        请点开任务栏里那个最小化的黑色窗口看报错。
echo        显存不够是最常见原因：跑 status.bat 看看当前占用。
pause
exit /b 1

:already
echo [已经在运行] 端口 %PORT% 上已有服务，不重复启动。
goto showlan

:ready
echo [就绪] 模型已加载。耗时约 %N% 秒，上下文 %CTX%。
goto showlan

:showlan
echo.
echo 可访问地址：
echo     本机           %BASE%
echo     局域网 / 手机  （需要先跑过一次 allow-lan-firewall.bat）
powershell -NoProfile -Command "Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -notlike '198.18.*' } | ForEach-Object { '                    http://' + $_.IPAddress + ':%PORT%/' }"
echo.
echo 访问密钥（API 客户端：Authorization: Bearer 后面接这一串）
echo           （Web UI：在设置里填 API Key，填一次浏览器会记住）
if exist "%KEYFILE%" (
  for /f "usebackq delims=" %%K in ("%KEYFILE%") do echo                    %%K
) else (
  echo                     [缺失] %KEYFILE%
)
echo.
echo 关闭服务：stop.bat
echo.
echo 正在打开 Web 界面...
start "" "%BASE%"
exit /b 0
