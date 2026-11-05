<#
  download.ps1 - 多线程分块下载器（分块队列 + 工作窃取 + 断点续传）

  为什么不用 Invoke-WebRequest / WebClient / BITS：
    单连接在当前网络实测只有 100 KB/s 上下，6 GB 要十几小时。

  为什么不是"文件等分成 N 段、每段一个连接"：
    那是静态切分，整体速度等于最慢那一段。任何一段遇到慢连接/抖动，
    其余连接就算早早下完也只能干等（straggler 问题），而且一段断了整单失败。

  本实现的调度（参考 aria2 / IDM 的思路）：
    1. 把文件切成很多小块（默认约为 工人数 × 8 块，单块 8-128 MB）
    2. N 个工人从同一个队列里动态领取下一块，下完立刻领新块，谁快谁多干
    3. 每块独立重试（指数退避），失败只影响那一块
    4. 卡死检测：某块 N 秒内字节数不涨就杀掉重排
    5. 断点续传：块文件落盘，重跑时跳过已完整的块（跨进程有效）
    6. 收尾逐块核对精确长度 + 整体 SHA256，防"服务端无视 Range 返回整文件"

  用法：
    download.ps1 -Url <url> -Out <path> [-Size <bytes>] [-Sha256 <hex>]
                 [-Parts 12] [-ChunkMB 0] [-LimitRate 2M] [-StallSeconds 45] [-Retries 4]
                 [-NoProgress]   # 输出被重定向/写日志时用，改成每 5 秒一行
#>
param(
    [Parameter(Mandatory=$true)][string]$Url,
    [Parameter(Mandatory=$true)][string]$Out,
    [long]$Size = 0,
    [string]$Sha256 = "",
    [int]$Parts = 0,            # 工人数（并发连接数）；0 = 按文件大小自动
    [int]$ChunkMB = 0,          # 单块大小；0 = 自动
    [string]$Label = "",
    [string]$LimitRate = "",    # 例如 5M，透传给 curl --limit-rate
    [int]$StallSeconds = 45,
    [int]$Retries = 4,
    [switch]$NoProgress
)

$ErrorActionPreference = 'Stop'
if ($Label -eq "") { $Label = Split-Path -Leaf $Out }

$MIN_CHUNK = 8MB
$MAX_CHUNK = 128MB
$WORKERS_MAX = 24

# ---------------------------------------------------------------- 工具函数
function Remove-DirSafe([string]$d) {
    if (-not (Test-Path $d)) { return }
    Get-ChildItem -LiteralPath $d -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue
}

# 删文件不该让整个下载崩掉：文件可能被杀软/索引器占用。
# 返回是否真的删掉了，调用方决定要不要继续。
function Remove-FileSafe([string]$p) {
    if (-not (Test-Path $p)) { return $true }
    try { Remove-Item -LiteralPath $p -Force -ErrorAction Stop } catch { }
    return (-not (Test-Path $p))
}

function Get-FileSha256([string]$path) {
    return (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLower()
}

function Format-Size([double]$b) {
    if ($b -lt 1KB) { return ("{0:N0} B" -f $b) }
    if ($b -ge 1GB) { return ("{0:N2} GB" -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ("{0:N1} MB" -f ($b / 1MB)) }
    return ("{0:N0} KB" -f ($b / 1KB))
}

function Format-Eta([double]$sec) {
    if ([double]::IsInfinity($sec) -or $sec -le 0 -or $sec -gt 86400) { return "--:--" }
    $t = [TimeSpan]::FromSeconds([math]::Round($sec))
    if ($t.TotalHours -ge 1) { return ("{0}:{1:00}:{2:00}" -f [int]$t.TotalHours, $t.Minutes, $t.Seconds) }
    return ("{0}:{1:00}" -f $t.Minutes, $t.Seconds)
}

$curl = Join-Path $env:SystemRoot "System32\curl.exe"
if (-not (Test-Path $curl)) { $curl = "curl.exe" }

# ---------------------------------------------------------------- 1. 已存在就跳过
if (Test-Path $Out) {
    $cur = (Get-Item $Out).Length
    if ($Size -gt 0 -and $cur -ne $Size) {
        Write-Host ("  [重下] {0} 大小不对（{1} != {2}）" -f $Label, $cur, $Size)
        if (-not (Remove-FileSafe $Out)) { throw ("旧文件删不掉（可能被其它程序占用）：" + $Out) }
    } elseif ($Sha256 -ne "") {
        Write-Host ("  [校验] 已有 {0}，核对 SHA256 ..." -f $Label)
        if ((Get-FileSha256 $Out) -eq $Sha256.ToLower()) {
            Write-Host ("  [跳过] {0} 已存在且校验通过" -f $Label)
            return
        }
        Write-Host ("  [重下] {0} 校验不符，删除重下" -f $Label)
        if (-not (Remove-FileSafe $Out)) { throw ("旧文件删不掉（可能被其它程序占用）：" + $Out) }
    } else {
        Write-Host ("  [跳过] {0} 已存在（{1}）" -f $Label, (Format-Size $cur))
        return
    }
}

$outDir = Split-Path -Parent $Out
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# ---------------------------------------------------------------- 2. 取大小 + 探 Range
$acceptRanges = ""
if ($Size -le 0) {
    Write-Host "  [探测] 取远端大小 ..."
    try {
        $resp = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -MaximumRedirection 10 -TimeoutSec 60
        $Size = [long]$resp.Headers['Content-Length']
        if ($resp.Headers['Accept-Ranges']) { $acceptRanges = [string]$resp.Headers['Accept-Ranges'] }
    } catch {
        throw ("取不到远端大小。请用 -Size 手动指定。原始错误：" + $_.Exception.Message)
    }
}
if ($Size -le 0) { throw "远端大小未知，拒绝下载。" }

# ---------------------------------------------------------------- 3. 规划分块
if ($Parts -le 0) {
    if ($Size -lt 64MB)        { $Parts = 4 }
    elseif ($Size -lt 512MB)   { $Parts = 8 }
    else                       { $Parts = 12 }
}
if ($Parts -gt $WORKERS_MAX) { $Parts = $WORKERS_MAX }

if ($ChunkMB -gt 0) {
    $chunkSize = [long]$ChunkMB * 1MB
} else {
    # 目标是总块数约为 工人数 x 8：够细，工人不会干等；又不至于块太碎
    $chunkSize = [long][math]::Ceiling($Size / ($Parts * 8))
    if ($chunkSize -lt $MIN_CHUNK) { $chunkSize = [long]$MIN_CHUNK }
    if ($chunkSize -gt $MAX_CHUNK) { $chunkSize = [long]$MAX_CHUNK }
}
if ($chunkSize -gt $Size) { $chunkSize = $Size }
$nChunks = [int][math]::Ceiling($Size / $chunkSize)

function Get-ChunkSpan([int]$i) {
    $s = [long]($i * $chunkSize)
    $e = $s + $chunkSize - 1
    if ($e -ge $Size) { $e = $Size - 1 }
    return @($s, $e, [long]($e - $s + 1))
}

# 服务端若不支持 Range，强制单连接（多连接会各自下一整个文件，纯浪费）
if ($nChunks -gt 1 -and $acceptRanges -ne "" -and $acceptRanges -notlike "*bytes*") {
    Write-Host ("  [提示] 服务端声明 Accept-Ranges={0}，退化为单连接" -f $acceptRanges)
    $Parts = 1
    $chunkSize = $Size
    $nChunks = 1
}
if ($nChunks -eq 1) { $Parts = 1 }

Write-Host ("  [计划] {0}  共 {1}   切成 {2} 块 x {3}   并发 {4}" -f `
    $Label, (Format-Size $Size), $nChunks, (Format-Size $chunkSize), $Parts)

# ---------------------------------------------------------------- 4. 续传：块文件与计划
$partDir = "$Out.parts"
$planFile = "$Out.plan"
$planText = ("{0}|{1}|{2}" -f $Url, $Size, $chunkSize)

if ((Test-Path $partDir) -and (Test-Path $planFile)) {
    $old = ""
    try { $old = (Get-Content -LiteralPath $planFile -Raw).Trim() } catch { }
    if ($old -ne $planText) {
        Write-Host "  [提示] 上次的块计划与本次不一致（源或大小变了），清空重下"
        Remove-DirSafe $partDir
        [void](Remove-FileSafe $planFile)
    }
} elseif (Test-Path $partDir) {
    Remove-DirSafe $partDir
}
if (-not (Test-Path $partDir)) { New-Item -ItemType Directory -Path $partDir -Force | Out-Null }
[System.IO.File]::WriteAllText($planFile, $planText)

function Get-ChunkPath([int]$i) { return (Join-Path $partDir ("c{0:D6}" -f $i)) }

# 一个块的实际字节数 = 已落地部分 + 本次正在追加的部分（块内续传用 .new 暂存）
function Get-ChunkBytes([int]$i) {
    $p = Get-ChunkPath $i
    $n = [long]0
    if (Test-Path $p) { $n += (Get-Item $p).Length }
    $q = $p + ".new"
    if (Test-Path $q) { $n += (Get-Item $q).Length }
    return $n
}

# 把 .new 里的新数据追加进块文件；无论成败都追加，下次能接着断点下
function Merge-ChunkNew([string]$part) {
    $q = $part + ".new"
    if (-not (Test-Path $q)) { return }
    try {
        $src = [System.IO.File]::OpenRead($q)
        try {
            $dst = [System.IO.File]::Open($part, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
            try { $src.CopyTo($dst, 1MB) } finally { $dst.Close() }
        } finally { $src.Close() }
    } catch { }
    [void](Remove-FileSafe $q)
}

$pending = New-Object 'System.Collections.Generic.List[int]'
$doneSet = New-Object 'System.Collections.Generic.HashSet[int]'
$preDone = [long]0
$prePart = 0
for ($i = 0; $i -lt $nChunks; $i++) {
    $sp = Get-ChunkSpan $i
    $p = Get-ChunkPath $i
    Merge-ChunkNew $p      # 上次被强杀时留在 .new 里的字节，先并回块文件
    $ok = $false
    if (Test-Path $p) {
        if ((Get-Item $p).Length -eq $sp[2]) { $ok = $true }
    }
    if ($ok) {
        [void]$doneSet.Add($i)
        $preDone += $sp[2]
    } else {
        if (Test-Path $p) { if ((Get-Item $p).Length -gt 0) { $prePart++ } }
        $pending.Add($i)
    }
}
if ($preDone -gt 0 -or $prePart -gt 0) {
    $tail = ""
    if ($prePart -gt 0) { $tail = ("，另有 {0} 块有半截、从断点接着下" -f $prePart) }
    Write-Host ("  [续传] 已有 {0} 块完整（{1}），还需下 {2} 块{3}" -f `
        $doneSet.Count, (Format-Size $preDone), $pending.Count, $tail)
}

# ---------------------------------------------------------------- 5. 调度
$running = @{}       # index -> @{Proc; LastLen; LastChange}
$attempts = @{}      # index -> 失败次数
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$samples = New-Object 'System.Collections.Generic.List[object]'

function Start-Chunk([int]$i) {
    $sp = Get-ChunkSpan $i
    $part = Get-ChunkPath $i
    $have = [long]0
    if (Test-Path $part) { $have = (Get-Item $part).Length }
    if ($have -ge $sp[2]) { $have = 0; [void](Remove-FileSafe $part) }   # 长度异常，从头来

    # 块内续传：已有半截就从断点起要，写进 .new，结束后追加到块文件
    $from = $sp[0] + $have
    if ($have -gt 0) { $target = $part + ".new" } else { $target = $part }
    [void](Remove-FileSafe $target)

    $cargs = @("-sL", "--connect-timeout", "20", "-r", ("{0}-{1}" -f $from, $sp[1]), "-o", $target)
    if ($LimitRate -ne "") { $cargs += @("--limit-rate", $LimitRate) }
    $cargs += $Url
    $p = Start-Process -FilePath $curl -ArgumentList $cargs -PassThru -WindowStyle Hidden
    $running[$i] = @{ Proc = $p; LastLen = [long]-1; LastChange = (Get-Date) }
}

$failMsg = ""
$Interactive = (-not [Console]::IsOutputRedirected) -and (-not $NoProgress)
$lastLog = 0.0
while (($pending.Count -gt 0 -or $running.Count -gt 0) -and $failMsg -eq "") {

    while ($running.Count -lt $Parts -and $pending.Count -gt 0) {
        $i = $pending[0]
        $pending.RemoveAt(0)
        Start-Chunk $i
    }

    Start-Sleep -Milliseconds 400
    $now = Get-Date

    # --- 收已结束的块 ---
    foreach ($i in @($running.Keys)) {
        $info = $running[$i]
        if (-not $info.Proc.HasExited) { continue }
        $info.Proc.Dispose()
        $running.Remove($i)

        $sp = Get-ChunkSpan $i
        $p = Get-ChunkPath $i
        Merge-ChunkNew $p
        $got = [long]0
        if (Test-Path $p) { $got = (Get-Item $p).Length }

        if ($got -eq $sp[2]) {
            [void]$doneSet.Add($i)
            continue
        }

        # 服务端无视 Range：明明只要一小块，却给了整个文件
        if ($got -eq $Size -and $sp[2] -ne $Size) {
            [void](Remove-FileSafe $p)
            $failMsg = "服务端无视了 Range 请求（返回整个文件）。请换源，或用 -Parts 1 走单连接。"
            break
        }

        $n = 1
        if ($attempts.ContainsKey($i)) { $n = $attempts[$i] + 1 }
        $attempts[$i] = $n
        # 长度超过应有值说明写脏了，清掉；否则保留半截，下次从断点接着要
        if ($got -gt $sp[2]) { [void](Remove-FileSafe $p) }

        if ($n -gt $Retries) {
            $failMsg = ("第 {0} 块连续失败 {1} 次（实得 {2} 字节，应为 {3}）。网络不稳或源有问题。" -f $i, $n, $got, $sp[2])
            break
        }
        $pending.Add($i)   # 重排到队尾，让别的块先跑
    }
    if ($failMsg -ne "") { break }

    # --- 卡死检测 ---
    foreach ($i in @($running.Keys)) {
        $info = $running[$i]
        if ($info.Proc.HasExited) { continue }
        $len = Get-ChunkBytes $i
        if ($len -ne $info.LastLen) {
            $info.LastLen = $len
            $info.LastChange = $now
        } elseif (($now - $info.LastChange).TotalSeconds -gt $StallSeconds) {
            try { $info.Proc.Kill() } catch { }
            # 下一轮会被当作"已结束但长度不符"处理，从而重排
        }
    }

    # --- 进度 ---
    $bytes = [long]$preDone
    foreach ($i in $doneSet) { $bytes += (Get-ChunkSpan $i)[2] }
    foreach ($i in @($running.Keys)) { $bytes += (Get-ChunkBytes $i) }
    if ($bytes -gt $Size) { $bytes = $Size }
    $samples.Add(@($sw.Elapsed.TotalSeconds, $bytes))
    while ($samples.Count -gt 24) { $samples.RemoveAt(0) }

    $inst = 0.0
    if ($samples.Count -ge 2) {
        $oldS = $samples[0]
        $dt = $sw.Elapsed.TotalSeconds - $oldS[0]
        if ($dt -gt 0.5) { $inst = ($bytes - $oldS[1]) / $dt }
    }
    $eta = 0.0
    if ($inst -gt 1) { $eta = ($Size - $bytes) / $inst }

    $pct = [int][math]::Min(100, [math]::Floor($bytes * 100 / $Size))
    if ($Interactive) {
        Write-Progress -Activity ("下载 " + $Label) `
            -Status ("{0}/{1} 块   已收 {2} / {3}   {4}/s   剩余 {5}   连接 {6}" -f `
                $doneSet.Count, $nChunks, (Format-Size $bytes), (Format-Size $Size), `
                (Format-Size $inst), (Format-Eta $eta), $running.Count) `
            -PercentComplete $pct
    } elseif (($sw.Elapsed.TotalSeconds - $lastLog) -ge 5) {
        # 输出被重定向（写日志/被别的脚本调用）时，Write-Progress 会刷屏成几百行，
        # 改成每 5 秒一行，日志才可读
        $lastLog = $sw.Elapsed.TotalSeconds
        Write-Host ("  [进度] {0}/{1} 块   已收 {2} / {3}   {4}/s   剩余 {5}" -f `
            $doneSet.Count, $nChunks, (Format-Size $bytes), (Format-Size $Size), `
            (Format-Size $inst), (Format-Eta $eta))
    }
}
if ($Interactive) { Write-Progress -Activity ("下载 " + $Label) -Completed }

if ($failMsg -ne "") {
    throw ($failMsg + "（已完成的块保留在 " + $partDir + "，重跑会接着下）")
}

# ---------------------------------------------------------------- 6. 逐块核对
$bad = @()
for ($i = 0; $i -lt $nChunks; $i++) {
    $sp = Get-ChunkSpan $i
    $p = Get-ChunkPath $i
    if (-not (Test-Path $p)) { $bad += ("缺块 " + $i); continue }
    $got = (Get-Item $p).Length
    if ($got -ne $sp[2]) { $bad += ("块 {0} 长度 {1} != {2}" -f $i, $got, $sp[2]) }
}
if ($bad.Count -gt 0) {
    Remove-DirSafe $partDir
    [void](Remove-FileSafe $planFile)
    throw ("分块校验失败：" + $bad[0] + "（共 " + $bad.Count + " 处），已清理临时文件。")
}

# ---------------------------------------------------------------- 7. 合并
Write-Host "  [合并] 拼接分块 ..."
$fs = [System.IO.File]::Create($Out)
try {
    for ($i = 0; $i -lt $nChunks; $i++) {
        $in = [System.IO.File]::OpenRead((Get-ChunkPath $i))
        try { $in.CopyTo($fs, 1MB) } finally { $in.Close() }
    }
} finally { $fs.Close() }

$final = (Get-Item $Out).Length
if ($final -ne $Size) {
    [void](Remove-FileSafe $Out)
    throw ("合并后大小不符：{0} != {1}" -f $final, $Size)
}
Remove-DirSafe $partDir
[void](Remove-FileSafe $planFile)

# ---------------------------------------------------------------- 8. SHA256
if ($Sha256 -ne "") {
    Write-Host "  [校验] 计算 SHA256（大文件要几十秒）..."
    $h = Get-FileSha256 $Out
    if ($h -ne $Sha256.ToLower()) {
        [void](Remove-FileSafe $Out)
        throw ("SHA256 不符，文件已删除。期望 {0}，实得 {1}" -f $Sha256.ToLower(), $h)
    }
    Write-Host "  [通过] SHA256 一致"
}

$secs = $sw.Elapsed.TotalSeconds
$fetched = $Size - $preDone          # 本次真正拉的字节，续传时不能拿总大小充数
$rate = 0.0
if ($secs -gt 0) { $rate = $fetched / $secs }
$note = ""
if ($preDone -gt 0) { $note = ("（其中 {0} 是上次续传带来的）" -f (Format-Size $preDone)) }
Write-Host ("  [完成] {0}  {1}  用时 {2:N0} 秒，本次拉取 {3}，平均 {4}/s{5}" -f `
    $Label, (Format-Size $final), $secs, (Format-Size $fetched), (Format-Size $rate), $note)
