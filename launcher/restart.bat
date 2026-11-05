@echo off
chcp 936 >nul
REM ===== 【一键重启】先 stop.bat 再 start.bat（默认档）=====
setlocal
title Bonsai 2 - 重启
call "%~dp0stop.bat"
echo.
call "%~dp0start.bat"
exit /b 0
