@echo off
chcp 936 >nul
REM ===== 【状态 / 诊断】一屏看清：服务、进程、上下文、显存、密钥、防火墙 =====
setlocal
call "%~dp0_env.bat"
title Bonsai 2 - 状态

echo ============================================================
echo   Ternary Bonsai 2 27B  运行状态
echo ============================================================
echo   项目根目录 : %ROOT%
echo   服务端口   : %PORT%
echo   启动器目录 : %~dp0
echo.

echo --- 1. 服务健康 ---
set "HC=000"
for /f %%H in ('curl -s -o nul -w "%%{http_code}" --noproxy "*" --max-time 3 "%BASE%health"') do set "HC=%%H"
if "%HC%"=="200" (
  echo   [运行中] /health 返回 200
) else if "%HC%"=="503" (
  echo   [加载中] /health 返回 503，模型还在加载权重，稍等再试
) else (
  echo   [未运行] /health 无响应（%HC%）
)

echo.
echo --- 2. 进程 ---
powershell -NoProfile -Command "$p = @(Get-Process -Name llama-server -ErrorAction SilentlyContinue); if ($p.Count -eq 0) { '   没有 llama-server 进程' } else { $p | ForEach-Object { '   PID ' + $_.Id + '  显存/工作集 ' + [math]::Round($_.WorkingSet64/1MB) + ' MB  ' + $_.Path } }"

echo.
echo --- 3. 上下文与鉴权（/props，需密钥）---
set "APIKEY="
if exist "%KEYFILE%" for /f "usebackq delims=" %%K in ("%KEYFILE%") do if not defined APIKEY set "APIKEY=%%K"
if defined APIKEY (
  echo   密钥文件 : %KEYFILE%  ^(前 8 位 %APIKEY:~0,8% ...^)
) else (
  echo   密钥文件 : [缺失或为空] %KEYFILE%
)
if defined APIKEY (
  powershell -NoProfile -Command "try { $r = Invoke-RestMethod -Uri '%BASE%props' -Headers @{Authorization='Bearer %APIKEY%'} -TimeoutSec 4; '   模型别名 : ' + $r.model_alias; '   上下文   : ' + $r.default_generation_settings.n_ctx + ' tokens'; '   并行槽位 : ' + $r.total_slots } catch { '   [/props 失败] 服务未运行，或密钥与 keys.txt 不一致' }"
) else (
  echo   [/props 跳过] 没有密钥
)

echo.
echo --- 4. 显存 ---
nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>nul
if errorlevel 1 echo   [跳过] 取不到 nvidia-smi

echo.
echo --- 5. 局域网防火墙规则 ---
netsh advfirewall firewall show rule name="%RULENAME%" >nul 2>&1
if errorlevel 1 (
  echo   [未放行] 只有本机能访问。需要手机/别的电脑访问时，跑一次 allow-lan-firewall.bat
) else (
  echo   [已放行] 规则 "%RULENAME%" 存在
)

echo.
echo --- 6. 局域网地址 ---
powershell -NoProfile -Command "Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -notlike '198.18.*' } | ForEach-Object { '   http://' + $_.IPAddress + ':%PORT%/' }"

echo.
echo ============================================================
pause
exit /b 0
