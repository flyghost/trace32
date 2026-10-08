# =============================================================================
#  cli\run_2211_ap.ps1 - 无界面提取 2211 AP 死亡现场
#
#  用客户原始的 2210 TRACE32 脚本驱动 ramdump\2211_deathscene 中的 2211 二进制
#  死亡现场，全程无 GUI、无需人工点击。
#
#  目录布局：本文件位于 cli\（仓库根下一级）；仓库根由 $PSScriptRoot 推出。
#
#  输出写入 out\runs\2211_ap\<时间戳>\（已 gitignore）：
#      2211_ap_deathscene.txt   捕获到的分析结果
#      run.txt                  溯源：跑了什么、退出码、哈希
#  进度 marker 写入 out\logs\2211ap-<时间戳>.log（已 gitignore）。
#
#  ramdump 死机现场是只读输入。third_party\ 下的脚本永不修改。
#
#  退出码：仅当进程退出码为 0、tests\smoke\2211_ap.markers 中的每个 marker 都
#  出现过、且报告非空时才为 0。打印 marker 不等于断言 marker —— 早先的版本即使
#  整条链路中途断掉也仍然退出 0。
#
#  用法：
#      powershell -ExecutionPolicy Bypass -File cli\run_2211_ap.ps1
#      ... -TimeoutSec 600
#      ... -RamdumpDir D:\some\other\dump
#
#  故意只用 ASCII：本文件存为 UTF-8 with BOM：PS 5.1 读无 BOM 文件会按 GBK 乱码。
# =============================================================================
[CmdletBinding()]
param(
    [int]    $TimeoutSec = 900,
    [string] $RamdumpDir = ''
)

$ErrorActionPreference = 'Stop'

$here      = Split-Path -Parent $PSScriptRoot          # 仓库根（本文件位于 cli\）
$localDir  = Join-Path $here 'local'
$logsDir   = Join-Path $here 'out\logs'
$scriptDir = Join-Path $here 'third_party\vendor\2210_trace32'
$cmmDir    = Join-Path $here 'cmm'

# ---------------------------------------------------------------- 1. 机器路径
$pathsFile = Join-Path $localDir 'paths.psd1'
if (-not (Test-Path $pathsFile)) {
    throw "missing $pathsFile - copy local\paths.psd1.example to local\paths.psd1 and set T32_INSTALL"
}
$paths = Import-PowerShellDataFile $pathsFile

$t32exe = Join-Path $paths.T32_INSTALL 'bin\windows64\t32mriscv.exe'
if (-not (Test-Path $t32exe))  { throw "t32mriscv.exe not found: $t32exe" }
if (-not (Test-Path $scriptDir)) { throw "customer script dir not found: $scriptDir" }

# ---------------------------------------------------------------- 2. ramdump 输入
if (-not $RamdumpDir) { $RamdumpDir = Join-Path $here 'ramdump\2211_deathscene' }
$RamdumpDir = (Resolve-Path $RamdumpDir).Path
foreach ($need in 'cpu-ap.elf','IRAM.bin','PSRAM.bin','ap_ilm.bin','ap_dlm.bin') {
    if (-not (Test-Path (Join-Path $RamdumpDir $need))) { throw "$need not found in $RamdumpDir" }
}

# ---------------------------------------------------------------- 3. 运行目录
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path $here "out\runs\2211_ap\$stamp"
New-Item -ItemType Directory -Force -Path $runDir,$localDir,$logsDir | Out-Null
$outFile   = Join-Path $runDir '2211_ap_deathscene.txt'
$markerLog = Join-Path $logsDir "2211ap-$stamp.log"

# ---------------------------------------------------------------- 4. 展开模板
# 保字节的 Latin-1 往返：本工作区里的 TRACE32 脚本是 ASCII / GBK / UTF-8 混用，
# 若按 UTF-8 重新编码会把它们弄坏。
function Expand-Template {
    param([string]$Src, [string]$Dst, [hashtable]$Map)
    $bytes = [System.IO.File]::ReadAllBytes($Src)
    $text  = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
    foreach ($k in $Map.Keys) { $text = $text.Replace($k, [string]$Map[$k]) }
    [System.IO.File]::WriteAllBytes($Dst, [System.Text.Encoding]::GetEncoding(28591).GetBytes($text))
    Write-Host ("generated {0}" -f $Dst)
}

$cfg   = Join-Path $localDir 'analyze.t32'
$entry = Join-Path $localDir 'run_2211_ap.cmm'

Expand-Template (Join-Path $here 'configs\sim-batch.t32')              $cfg   @{ '__T32_INSTALL__' = $paths.T32_INSTALL }
Expand-Template (Join-Path $here 'cli\2211_ap_analyze.cmm.tmpl')          $entry @{
    '__RAMDUMP_DIR__' = $RamdumpDir
    '__OUT_FILE__'    = $outFile
    '__MARKER_LOG__'  = $markerLog
    '__SCRIPT_DIR__'  = $scriptDir
    '__CMM_DIR__'     = $cmmDir
    '__RUN_STAMP__'   = $stamp
}

# ---------------------------------------------------------------- 5. 清理残留实例
# 残留的 TRACE32 实例会让下一次启动退出 2 或挂死。
Get-Process -Name 't32*' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 4

# ---------------------------------------------------------------- 6. 运行
# 故意把 WorkingDirectory 设为客户脚本目录：他们的脚本用裸文件名互相调用
# （`do frame.cmm`），而这是按进程 CWD 解析的。
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$proc = Start-Process -FilePath $t32exe `
                      -ArgumentList @('-c', "`"$cfg`"", '-s', "`"$entry`"") `
                      -WorkingDirectory $scriptDir -PassThru

$exited = $proc.WaitForExit($TimeoutSec * 1000)
if ($exited) { $code = $proc.ExitCode } else { $code = 'TIMEOUT'; $proc.Kill() }
$sw.Stop()

Get-Process -Name 't32*' -ErrorAction SilentlyContinue | Stop-Process -Force

# ---------------------------------------------------------------- 7. 报告
"exit={0}  elapsed={1}s  timeout={2}s" -f $code, [int]$sw.Elapsed.TotalSeconds, $TimeoutSec

if (Test-Path $outFile) {
    $fi = Get-Item $outFile
    $lines = @(Get-Content -Path $outFile -Encoding Default).Count
    "output : {0}" -f $outFile
    "size   : {0} bytes, {1} lines" -f $fi.Length, $lines
} else {
    "output : MISSING - {0}" -f $outFile
    $lines = 0
}

"markers: {0}" -f $markerLog
if (Test-Path $markerLog) { Get-Content $markerLog | ForEach-Object { "  $_" } }

# 注意：逐块堆属性列表（Mem Leak Info / Memory Summary By File）不属于本报告。
# 客户自己的 golden 输出里该块同样是空的，而且其 walker 所需的 CMM 表达式
# （mbinptr/mchunkptr 强转、sizeof）在本环境里求不出值 —— 见 cmm\heap_summary.cmm。

# --------------------------------------------- 7b. 离线堆统计（不依赖 T32）
# chunk 链本身可以从逐字节精确的 dump 文件重建，并与 arena 的 `used` 字段核对，
# 所以堆的问题改由一个确定性的 Python 步骤回答，而不用无法终止的 CMM 遍历。
$heapTxt   = Join-Path $runDir 'heap_offline.txt'
$heapLine  = 'skipped (python not on PATH)'
$pythonExe = (Get-Command python -ErrorAction SilentlyContinue).Source
if ($pythonExe) {
    & $pythonExe (Join-Path $here 'tools\heap_stats_offline.py') $RamdumpDir $heapTxt | Out-Null
    if (Test-Path $heapTxt) {
        $heapLine = $heapTxt
        $verdict = (Get-Content $heapTxt | Select-String -Pattern 'walk reproduces|MISMATCH').Line
        "heap   : {0}" -f $heapTxt
        "heap   : {0}" -f ($verdict -replace '^\s+', '')
    } else {
        $heapLine = 'offline stats FAILED'
    }
} else {
    Write-Host 'heap   : skipped (python not on PATH)'
}

# --------------------------------------------- 8. 闸门：marker + 退出码 + 报告
# 所有决定 PASS/FAIL 的断言都在这里，所以退出码不可能在链路提前中断时还说
# "ok"。
$markerFile = Join-Path $here 'tests\smoke\2211_ap.markers'
$missing = @()
$want = @()
if (Test-Path $markerFile) {
    $want = @(Get-Content -LiteralPath $markerFile | Where-Object { $_ -and -not $_.TrimStart().StartsWith('#') } | ForEach-Object { $_.Trim() })
    $txt = if (Test-Path $markerLog) { Get-Content -LiteralPath $markerLog -Raw } else { '' }
    foreach ($m in $want) { if ($txt -notmatch ('(?m)^' + [regex]::Escape($m))) { $missing += $m } }
} else {
    $missing = @("markers file not found: $markerFile")
}
$gate = if ($missing.Count -eq 0) { "PASS ($($want.Count)/$($want.Count) markers)" } else { "FAIL (missing: $($missing -join ', '))" }
"gate   : $gate"
if ($lines -le 0) { $gate = 'FAIL (empty report)'; "gate   : $gate" }

$elfHash  = (Get-FileHash (Join-Path $RamdumpDir 'cpu-ap.elf') -Algorithm SHA256).Hash
$meta = @(
    "case        : 2211 AP death scene (headless)"
    "stamp       : $stamp"
    "ramdump     : $RamdumpDir"
    "elf         : cpu-ap.elf sha256=$elfHash"
    "engine      : third_party\vendor\2210_trace32 (customer originals) + cli\2211_ap_analyze.cmm.tmpl"
    "bypassed    : LM620_Restore.cmm (GUI wrapper), select_thread.cmm (interactive)"
    "heap        : cmm\heap_summary.cmm (arena descriptor only; vendor heap walker spins on this arena)"
    "heap_offline: $heapLine"
    "config      : configs\sim-batch.t32 (PBI=SIM, SCREEN=OFF)"
    "t32         : $t32exe"
    "t32_cwd     : $scriptDir"
    "markers     : $markerLog"
    "gate        : $gate"
    "exit        : $code"
    "elapsed_sec : $([int]$sw.Elapsed.TotalSeconds)"
    "output      : $outFile"
    "output_line : $lines"
) -join "`r`n"
[System.IO.File]::WriteAllText((Join-Path $runDir 'run.txt'), $meta, (New-Object System.Text.UTF8Encoding($false)))
"meta   : {0}" -f (Join-Path $runDir 'run.txt')

if ($code -ne 0 -or $missing.Count -gt 0 -or $lines -le 0) { "RESULT : FAIL"; exit 1 }
"RESULT : PASS"
