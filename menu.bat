@echo off
chcp 936 >nul
REM ===== 【功能菜单】启动 / 停止 / 重启 / 状态。真正的脚本在 launcher\menu.bat。 =====
call "%~dp0launcher\menu.bat"
