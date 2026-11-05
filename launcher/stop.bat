@echo off
chcp 936 >nul
REM =====================================================================
REM  【一键关闭】停止本项目启动的 llama-server 并释放显存。
REM  只按「可执行文件路径在本项目目录下」来匹配，
REM  不会误杀 LM Studio 自带的同名 llama-server.exe。
REM =====================================================================

setlocal
call "%~dp0_env.bat"
title Bonsai 2 - 关闭

echo [停止] 正在查找由 %ROOT% 启动的 llama-server ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$root = '%ROOT%'.ToLower().TrimEnd('\') + '\'; $p = @(Get-Process -Name llama-server -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.ToLower().StartsWith($root) }); if ($p.Count -gt 0) { $p | Stop-Process -Force; Write-Host ('[完成] 已停止 ' + $p.Count + ' 个进程。') } else { Write-Host '[提示] 没有找到本项目启动的 llama-server。' }"

ping -n 3 127.0.0.1 >nul
curl -sf -o nul --noproxy "*" --max-time 2 "%BASE%health"
if errorlevel 1 (
  echo [确认] 端口 %PORT% 已无响应，显存已释放。
) else (
  echo [注意] 端口 %PORT% 仍有响应，可能是别处的 llama-server 占着它。
)
exit /b 0
