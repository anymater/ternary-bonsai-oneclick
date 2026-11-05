<#
  detect.ps1 - 检测硬件与环境，决定该下载哪套二进制、用哪个模型档、上下文开多大。
  结果写到 config\env.txt（纯 ASCII 的 KEY=VALUE，供 install.bat 用 for /f 读取）。

  判定规则（都是有依据的，不是拍脑袋）：
  - 驱动 >= 580  -> CUDA 13.3 版（CUDA 13 要求 580+）
  - 驱动 >= 550  -> CUDA 12.4 版（CUDA 12.4 要求 550+）
  - 驱动 <  550  -> Vulkan 版
  - 没有 N 卡    -> CPU 版
  - 显存 >= 20GB -> PQ2_0（prefill 更快，实测值得）
  - 显存 <  20GB -> PTQ1_0（5.95GB，最省）
  - 上下文按显存给：>=11G -> 128K；>=9G -> 64K；>=7G -> 32K；否则 16K
    依据：PTQ1_0 在 12GB 卡上开 128K kv(q8_0) 实测占 10.67GB。
#>
param(
    [string]$OutFile = "",
    [string]$Root    = ""
)

$ErrorActionPreference = 'Stop'
if ($Root -eq "") { $Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
if ($OutFile -eq "") { $OutFile = Join-Path $Root "config\env.txt" }

$gpuName = "unknown"
$vramMB  = 0
$driver  = "0.0"
$driverMajor = 0

$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($smi -ne $null) {
    try {
        $line = & nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits 2>$null | Select-Object -First 1
        if ($line) {
            $p = $line -split ','
            if ($p.Count -ge 3) {
                $gpuName = $p[0].Trim()
                $vramMB  = [int]([double]$p[1].Trim())
                $driver  = $p[2].Trim()
                $driverMajor = [int](($driver -split '\.')[0])
            }
        }
    } catch { }
}

# ---- 选二进制 ----
if ($vramMB -le 0) {
    $asset  = "win-cpu-x64"
    $reason = "没有检测到 NVIDIA 显卡，用 CPU 版（会很慢，27B 建议至少 8GB 显存）"
} elseif ($driverMajor -ge 580) {
    $asset  = "win-cuda-13.3-x64"
    $reason = "驱动 $driver >= 580，用 CUDA 13.3 版（体积最小，198MB）"
} elseif ($driverMajor -ge 550) {
    $asset  = "win-cuda-12.4-x64"
    $reason = "驱动 $driver 在 550..579，用 CUDA 12.4 版"
} else {
    $asset  = "win-vulkan-x64"
    $reason = "驱动 $driver < 550，CUDA 版跑不了，改用 Vulkan 版"
}

# ---- 选模型档 ----
if ($vramMB -ge 20000) { $packing = "PQ2_0" } else { $packing = "PTQ1_0" }

# ---- 上下文 ----
if ($vramMB -ge 11000) { $ctx = 131072 }
elseif ($vramMB -ge 9000) { $ctx = 65536 }
elseif ($vramMB -ge 7000) { $ctx = 32768 }
else { $ctx = 16384 }

if ($asset -eq "win-cpu-x64") { $ngl = 0 } else { $ngl = 99 }

$lines = @(
    "GPU_NAME=$gpuName",
    "VRAM_MB=$vramMB",
    "DRIVER=$driver",
    "ASSET=$asset",
    "PACKING=$packing",
    "CTX=$ctx",
    "NGL=$ngl"
)
$dir = Split-Path -Parent $OutFile
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
# ASCII，无 BOM：install.bat 的 for /f 直接读
[System.IO.File]::WriteAllLines($OutFile, $lines, (New-Object System.Text.ASCIIEncoding))

Write-Host ""
Write-Host "  显卡      : $gpuName"
Write-Host "  显存      : $vramMB MB"
Write-Host "  驱动      : $driver"
Write-Host "  二进制    : $asset"
Write-Host "  模型档    : $packing"
Write-Host "  上下文    : $ctx"
Write-Host "  判定依据  : $reason"
Write-Host ""
