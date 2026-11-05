@echo off
REM =====================================================================
REM  公共环境变量。其它启动器都 call 本文件，不要单独双击它。
REM  项目根目录由本文件位置推导，整个目录可以随意搬家/改名。
REM  模型文件名 / 上下文 / GPU 层数由安装器写进 config\，不用改脚本。
REM =====================================================================
for %%I in ("%~dp0..") do set "ROOT=%%~fI"
set "PORT=8080"
set "BASE=http://127.0.0.1:%PORT%/"
set "KEYFILE=%ROOT%\config\keys.txt"
set "LOGDIR=%ROOT%\logs"
set "BIN=%ROOT%\runtime\bin\llama-server.exe"
set "ALIAS=ternary-bonsai-2-27b"
set "RULENAME=Bonsai2 llama-server %PORT%"

set "MODELFILE=Ternary-Bonsai-2-27B-PTQ1_0.gguf"
set "CTX=131072"
set "NGL=99"
set "_M="
set "_C="
set "_G="
if exist "%ROOT%\config\model.txt" for /f "usebackq delims=" %%M in ("%ROOT%\config\model.txt") do if not defined _M set "_M=%%M"
if defined _M set "MODELFILE=%_M%"
if exist "%ROOT%\config\ctx.txt" for /f "usebackq delims=" %%C in ("%ROOT%\config\ctx.txt") do if not defined _C set "_C=%%C"
if defined _C set "CTX=%_C%"
if exist "%ROOT%\config\ngl.txt" for /f "usebackq delims=" %%G in ("%ROOT%\config\ngl.txt") do if not defined _G set "_G=%%G"
if defined _G set "NGL=%_G%"
set "TRIPLET=%ROOT%\models\%MODELFILE%"

if not exist "%LOGDIR%" mkdir "%LOGDIR%" >nul 2>&1
exit /b 0
