@echo off
chcp 936 >nul
REM ===== 【一键关闭】释放显存。真正的脚本在 launcher\stop.bat。 =====
call "%~dp0launcher\stop.bat"
