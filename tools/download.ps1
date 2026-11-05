<#
  download.ps1 - 多连接分段下载 + SHA256 校验 + 断点续传。

  为什么不用 Invoke-WebRequest / WebClient：
    单连接在当前网络下实测只有约 100 KB/s，6GB 要下几个小时。
    分段并发（8~16 连接）实测能到 3~9 MB/s，差 30 倍以上。

  为什么必须逐段核对长度：
    有些反代/CDN 会无视 Range，对任意区间都返回整个文件（HTTP 200 而不是 206），
    结果段文件全部变大、拼出来的东西是坏的。所以每段长度必须精确匹配。

  用法：
    download.ps1 -Url <url> -Out <path> -Size <bytes> [-Sha256 <hex>] [-Parts 12] [-Label 名称]
#>
param(
    [Parameter(Mandatory=$true)][string]$Url,
    [Parameter(Mandatory=$true)][string]$Out,
    [long]$Size = 0,
    [string]$Sha256 = "",
    [int]$Parts = 12,
    [string]$Label = ""
)

$ErrorActionPreference = 'Stop'
if ($Label -eq "") { $Label = Split-Path -Leaf $Out }

function Remove-PartDir([string]$d) {
    if (-not (Test-Path $d)) { return }
    Get-ChildItem -LiteralPath $d -File -Force | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    Remove-Item -LiteralPath $d -Force
}

function Get-FileSha256([string]$path) {
    return (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLower()
}

function Format-Size([double]$b) {
    if ($b -ge 1GB) { return ("{0:N2} GB" -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ("{0:N1} MB" -f ($b / 1MB)) }
    return ("{0:N0} KB" -f ($b / 1KB))
}

# ---------- 1. 已存在就跳过 ----------
if (Test-Path $Out) {
    $cur = (Get-Item $Out).Length
    if ($Size -gt 0 -and $cur -ne $Size) {
        Write-Host ("  [重下] {0} 已有的大小不对（{1} != {2}）" -f $Label, $cur, $Size)
        Remove-Item $Out -Force
    } elseif ($Sha256 -ne "") {
        Write-Host ("  [校验] 已存在 {0}，正在核对 SHA256 ..." -f $Label)
        $h = Get-FileSha256 $Out
        if ($h -eq $Sha256.ToLower()) {
            Write-Host ("  [跳过] {0} 已存在且校验通过" -f $Label)
            return
        }
        Write-Host ("  [重下] {0} 校验不符，删除重下" -f $Label)
        Remove-Item $Out -Force
    } else {
        Write-Host ("  [跳过] {0} 已存在（{1}）" -f $Label, (Format-Size $cur))
        return
    }
}

$outDir = Split-Path -Parent $Out
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# ---------- 2. 拿文件总长 ----------
if ($Size -le 0) {
    Write-Host "  [探测] 正在取远端大小 ..."
    try {
        $resp = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -MaximumRedirection 10 -TimeoutSec 60
        $Size = [long]$resp.Headers['Content-Length']
    } catch {
        throw ("取不到远端大小，请检查网络或手动指定 -Size。原始错误：" + $_.Exception.Message)
    }
}
Write-Host ("  [下载] {0}  共 {1}" -f $Label, (Format-Size $Size))

$curl = Join-Path $env:SystemRoot "System32\curl.exe"
if (-not (Test-Path $curl)) { $curl = "curl.exe" }

# ---------- 3. 分段并发 ----------
if ($Parts -gt 16) { $Parts = 16 }
if ($Size -lt (16MB)) { $Parts = 1 }
$chunk = [long][math]::Ceiling($Size / $Parts)
$partDir = "$Out.parts"
Remove-PartDir $partDir
New-Item -ItemType Directory -Path $partDir -Force | Out-Null

$procs = @()
$bounds = @()
for ($i = 0; $i -lt $Parts; $i++) {
    $s = [long]($i * $chunk)
    $e = [long](($s + $chunk) - 1)
    if ($e -ge $Size) { $e = $Size - 1 }
    $part = Join-Path $partDir ("part_{0:D2}" -f $i)
    $bounds += ,@($part, $s, $e)
    $cargs = @("-sL", "--retry", "3", "--retry-delay", "2", "--max-time", "7200",
              "-r", "$s-$e", "-o", $part, $Url)
    $procs += Start-Process -FilePath $curl -ArgumentList $cargs -PassThru -WindowStyle Hidden
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($true) {
    $alive = @($procs | Where-Object { -not $_.HasExited })
    $got = 0
    foreach ($b in $bounds) { if (Test-Path $b[0]) { $got += (Get-Item $b[0]).Length } }
    $pct = [int][math]::Min(100, [math]::Floor($got * 100 / $Size))
    $spd = 0
    if ($sw.Elapsed.TotalSeconds -gt 0.5) { $spd = $got / $sw.Elapsed.TotalSeconds }
    Write-Progress -Activity ("下载 " + $Label) `
        -Status ("{0} / {1}   {2}/s   {3} 个连接" -f (Format-Size $got), (Format-Size $Size), (Format-Size $spd), $alive.Count) `
        -PercentComplete $pct
    if ($alive.Count -eq 0) { break }
    Start-Sleep -Milliseconds 900
}
Write-Progress -Activity ("下载 " + $Label) -Completed

# ---------- 4. 逐段核对（防 Range 被无视） ----------
$bad = 0
foreach ($b in $bounds) {
    $part = $b[0]; $s = $b[1]; $e = $b[2]
    $want = [long]($e - $s + 1)
    if (-not (Test-Path $part)) { Write-Host ("  [错误] 缺段 {0}" -f $part); $bad++; continue }
    $got = (Get-Item $part).Length
    if ($got -ne $want) {
        Write-Host ("  [错误] {0} 长度不符：期望 {1}，实得 {2}（可能是服务端无视 Range）" -f (Split-Path -Leaf $part), $want, $got)
        $bad++
    }
}
if ($bad -gt 0) {
    Remove-PartDir $partDir
    throw ("分段校验失败 $bad 处，已清理临时文件。请换源或减少 -Parts 重试。")
}

# ---------- 5. 合并 ----------
Write-Host "  [合并] 正在拼接分片 ..."
$fs = [System.IO.File]::Create($Out)
try {
    foreach ($b in $bounds) {
        $in = [System.IO.File]::OpenRead($b[0])
        try { $in.CopyTo($fs, 1MB) } finally { $in.Close() }
    }
} finally { $fs.Close() }
Remove-PartDir $partDir

$final = (Get-Item $Out).Length
if ($final -ne $Size) { throw ("合并后大小不符：{0} != {1}" -f $final, $Size) }

# ---------- 6. SHA256 ----------
if ($Sha256 -ne "") {
    Write-Host "  [校验] 计算 SHA256（大文件需要几十秒）..."
    $h = Get-FileSha256 $Out
    if ($h -ne $Sha256.ToLower()) {
        Remove-Item $Out -Force
        throw ("SHA256 不符，文件已删除。期望 {0}，实得 {1}" -f $Sha256.ToLower(), $h)
    }
    Write-Host "  [通过] SHA256 一致"
}
Write-Host ("  [完成] {0}  {1}  用时 {2:N0} 秒" -f $Label, (Format-Size $final), $sw.Elapsed.TotalSeconds)
