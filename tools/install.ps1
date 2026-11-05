<#
  install.ps1 - 安装编排：检测 -> 下载官方二进制 -> 下载模型 -> 写配置。

  原则：
  1. 只从官方公开来源下载（PrismML 的 GitHub Release / ModelScope / HuggingFace）。
  2. 每个文件都按 SHA256 校验，校验不过就删除并报错，绝不"凑合用"。
  3. 不修改用户现有环境：不装 Python、不装 CUDA Toolkit、不写注册表、不改 PATH。
     CUDA 运行时通过 Release 附带的 cudart 包解压到 runtime\bin 实现"应用本地"加载。
  4. 可重复执行：已下载且校验通过的文件会跳过。

  用法：
    tools\install.ps1 [-SkipModel] [-Vision] [-Packing PTQ1_0|PQ2_0|Q2_0] [-Ctx 131072] [-Parts 12]
#>
param(
    [switch]$SkipModel,
    [switch]$Vision,
    [string]$Packing = "",
    [int]$Ctx = 0,
    [int]$Parts = 12
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Say([string]$t) { Write-Host $t }

function Expand-ZipTo([string]$zip, [string]$dest) {
    if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path $tar) {
        & $tar -xf $zip -C $dest 2>$null
        if ($LASTEXITCODE -eq 0) { return }
        Say "  [提示] tar 解压失败，改用 Expand-Archive（较慢）"
    }
    Expand-Archive -Path $zip -DestinationPath $dest -Force
}

function Get-Manifest() {
    $p = Join-Path $Root 'manifest.json'
    if (-not (Test-Path $p)) { throw "缺少 manifest.json" }
    return (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Read-EnvFile([string]$path) {
    $h = @{}
    foreach ($line in Get-Content $path) {
        $i = $line.IndexOf('=')
        if ($i -gt 0) { $h[$line.Substring(0, $i)] = $line.Substring($i + 1) }
    }
    return $h
}

# ============ 0. 环境自检 ============
Say ""
Say "============================================================"
Say "  Ternary Bonsai 2 27B  一键安装"
Say "  安装到：$Root"
Say "============================================================"
Say ""

$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -ne 'AMD64') {
    throw "只支持 64 位 Windows（当前 PROCESSOR_ARCHITECTURE=$arch）。"
}
if (-not (Test-Path (Join-Path $env:SystemRoot 'System32\curl.exe'))) {
    Say "  [警告] 系统没有 curl.exe（Windows 10 1803 以下）。将退回单连接下载，可能很慢。"
}

$manifest = Get-Manifest

# ============ 1. 硬件检测 ============
Say "[1/5] 检测硬件与选择版本 ..."
$envFile = Join-Path $Root 'config\env.txt'
& (Join-Path $PSScriptRoot 'detect.ps1') -OutFile $envFile -Root $Root | Out-Null
$envh = Read-EnvFile $envFile

$assetKey = $envh['ASSET']
$packing  = $envh['PACKING']
if ($Packing -ne "") { $packing = $Packing }
$ctx = [int]$envh['CTX']
if ($Ctx -gt 0) { $ctx = $Ctx }
$ngl = $envh['NGL']

$asset = $manifest.engine.assets.$assetKey
if ($asset -eq $null) { throw "manifest 里没有这个平台：$assetKey" }

Say ("  显卡 {0}  /  显存 {1} MB  /  驱动 {2}" -f $envh['GPU_NAME'], $envh['VRAM_MB'], $envh['DRIVER'])
Say ("  选用 {0}，模型档 {1}，上下文 {2}" -f $assetKey, $packing, $ctx)

if ([int]$envh['VRAM_MB'] -lt 7000 -and $assetKey -like 'win-cuda*') {
    Say ""
    Say "  [注意] 显存不足 7GB。PTQ1_0 权重本身约 5.95GB，可能装不下。"
    Say "         可以继续安装，但建议改小上下文，或用 CPU/Vulkan 后端。"
    Say ""
}

# ============ 2. 下载引擎 ============
Say ""
Say "[2/5] 下载推理引擎（官方 PrismML Release）..."
$dl = Join-Path $PSScriptRoot 'download.ps1'
$cacheDir = Join-Path $Root '_cache'
$runtimeBin = Join-Path $Root 'runtime\bin'

$engineZip = Join-Path $cacheDir $asset.name
& $dl -Url ($manifest.engine.base_url + $asset.name) -Out $engineZip `
      -Size ([long]$asset.size) -Sha256 $asset.sha256 -Parts $Parts -Label "引擎 $assetKey"

if ($asset.cudart -ne "") {
    $cud = $manifest.cudart.assets.($asset.cudart)
    if ($cud -eq $null) { throw "manifest 缺少 cudart 条目：$($asset.cudart)" }
    $cudZip = Join-Path $cacheDir $asset.cudart
    & $dl -Url ($manifest.cudart.base_url + $asset.cudart) -Out $cudZip `
          -Size ([long]$cud.size) -Sha256 $cud.sha256 -Parts $Parts -Label "CUDA 运行时"
}

Say "  [解压] 正在展开到 runtime\bin ..."
Expand-ZipTo $engineZip $runtimeBin
if ($asset.cudart -ne "") { Expand-ZipTo $cudZip $runtimeBin }

$exe = Join-Path $runtimeBin 'llama-server.exe'
if (-not (Test-Path $exe)) { throw "解压后找不到 llama-server.exe，安装包可能不完整。" }
Say "  [通过] llama-server.exe 已就位"

# ============ 3. 下载模型 ============
$modelDir = Join-Path $Root 'models'
if (-not (Test-Path $modelDir)) { New-Item -ItemType Directory -Path $modelDir -Force | Out-Null }
$mf = $manifest.model.files.$packing
if ($mf -eq $null) { throw "manifest 里没有模型档：$packing" }

if ($SkipModel) {
    Say ""
    Say "[3/5] 已指定 -SkipModel，跳过模型下载。"
    Say "      请手动把 $($mf.file) 放到 models\ 目录。"
} else {
    Say ""
    Say ("[3/5] 下载模型 {0}（{1:N2} GB）..." -f $packing, ($mf.size / 1GB))
    $modelOut = Join-Path $modelDir $mf.file
    $done = $false
    $lastErr = ""
    foreach ($tpl in $manifest.model.sources) {
        $url = $tpl.Replace('{file}', $mf.file)
        $host_ = ([Uri]$url).Host
        Say "  尝试源：$host_"
        try {
            & $dl -Url $url -Out $modelOut -Size ([long]$mf.size) -Sha256 $mf.sha256 -Parts $Parts -Label $mf.file
            $done = $true
            break
        } catch {
            $lastErr = $_.Exception.Message
            Say ("  [失败] {0}：{1}" -f $host_, $lastErr)
            Say "  换下一个源 ..."
        }
    }
    if (-not $done) { throw "所有下载源都失败了。最后一次错误：$lastErr" }

    if ($Vision) {
        Say ""
        Say "  附加：下载视觉投影器 ..."
        $mm = $manifest.model.files.('mmproj-Q8_0')
        $mmOut = Join-Path $modelDir $mm.file
        $mmOk = $false
        foreach ($tpl in $manifest.model.sources) {
            $url = $tpl.Replace('{file}', $mm.file)
            try {
                & $dl -Url $url -Out $mmOut -Size ([long]$mm.size) -Sha256 $mm.sha256 -Parts $Parts -Label $mm.file
                $mmOk = $true
                break
            } catch { Say ("  [失败] " + $_.Exception.Message) }
        }
        if (-not $mmOk) { Say "  [警告] 视觉投影器下载失败，仅影响图片输入，不影响文字。" }
    }
}

# ============ 4. 写配置 ============
Say ""
Say "[4/5] 写入配置 ..."
$cfgDir = Join-Path $Root 'config'
if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }

$enc = New-Object System.Text.ASCIIEncoding
[System.IO.File]::WriteAllText((Join-Path $cfgDir 'model.txt'), $mf.file + "`r`n", $enc)
[System.IO.File]::WriteAllText((Join-Path $cfgDir 'ctx.txt'),   "$ctx`r`n",     $enc)
[System.IO.File]::WriteAllText((Join-Path $cfgDir 'ngl.txt'),   "$ngl`r`n",     $enc)

$keyFile = Join-Path $cfgDir 'keys.txt'
if (-not (Test-Path $keyFile)) {
    $bytes = New-Object byte[] 12
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $key = "bs2-" + (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    [System.IO.File]::WriteAllText($keyFile, $key + "`r`n", $enc)
    Say "  [生成] 访问密钥已写入 config\keys.txt"
} else {
    Say "  [保留] config\keys.txt 已存在，不覆盖"
}
Say ("  模型文件 {0}，上下文 {1}，GPU 层数 {2}" -f $mf.file, $ctx, $ngl)

# 清理下载缓存里的 zip（保留以便重装可跳过下载）
Say "  [缓存] 安装包保留在 _cache\ ，删掉可释放空间（重装会重新下载）"

# ============ 5. 完成 ============
Say ""
Say "[5/5] 安装完成。"
Say ""
Say "  下一步：双击 start.bat 启动，就绪后会自动打开 Web 界面。"
Say "  查看状态：status.bat     打开菜单：menu.bat     关闭：stop.bat"
Say ""
Say "  访问密钥（Web UI 设置里填，API 客户端用 Authorization: Bearer）："
$key = (Get-Content $keyFile -TotalCount 1)
Say ("    " + $key)
Say ""
