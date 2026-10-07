# =============================================================================
#  run_2211_ap.ps1 - headless extraction of the 2211 AP death scene
#
#  Drives the customer's original 2210 TRACE32 scripts against the 2211 binary
#  death scene in fixtures\2211_deathscene, with no GUI and no human clicking.
#
#  Output goes to runs\2211_ap\<timestamp>\ (gitignored):
#      2211_ap_deathscene.txt   the captured analysis
#      run.txt                  provenance: what was run, exit code, hashes
#  Progress markers go to logs\2211ap-<timestamp>.log (gitignored).
#
#  The fixture directory is only read. vendor\ scripts are never modified.
#
#  Usage:
#      powershell -ExecutionPolicy Bypass -File harness\run_2211_ap.ps1
#      ... -TimeoutSec 600
#      ... -RamdumpDir D:\some\other\dump
#
#  ASCII only on purpose: Windows PowerShell 5.1 reads a BOM-less script as ANSI.
# =============================================================================
[CmdletBinding()]
param(
    [int]    $TimeoutSec = 900,
    [string] $RamdumpDir = ''
)

$ErrorActionPreference = 'Stop'

$here      = Split-Path -Parent $PSScriptRoot
$localDir  = Join-Path $here 'local'
$logsDir   = Join-Path $here 'logs'
$scriptDir = Join-Path $here 'vendor\2210_trace32'

# ---------------------------------------------------------------- 1. machine paths
$pathsFile = Join-Path $localDir 'paths.psd1'
if (-not (Test-Path $pathsFile)) {
    throw "missing $pathsFile - copy local\paths.psd1.example to local\paths.psd1 and set T32_INSTALL"
}
$paths = Import-PowerShellDataFile $pathsFile

$t32exe = Join-Path $paths.T32_INSTALL 'bin\windows64\t32mriscv.exe'
if (-not (Test-Path $t32exe))  { throw "t32mriscv.exe not found: $t32exe" }
if (-not (Test-Path $scriptDir)) { throw "customer script dir not found: $scriptDir" }

# ---------------------------------------------------------------- 2. ramdump input
if (-not $RamdumpDir) { $RamdumpDir = Join-Path $here 'fixtures\2211_deathscene' }
$RamdumpDir = (Resolve-Path $RamdumpDir).Path
foreach ($need in 'cpu-ap.elf','IRAM.bin','PSRAM.bin','ap_ilm.bin','ap_dlm.bin') {
    if (-not (Test-Path (Join-Path $RamdumpDir $need))) { throw "$need not found in $RamdumpDir" }
}

# ---------------------------------------------------------------- 3. run directory
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path $here "runs\2211_ap\$stamp"
New-Item -ItemType Directory -Force -Path $runDir,$localDir,$logsDir | Out-Null
$outFile   = Join-Path $runDir '2211_ap_deathscene.txt'
$markerLog = Join-Path $logsDir "2211ap-$stamp.log"

# ---------------------------------------------------------------- 4. expand templates
# Byte-preserving Latin-1 round trip: TRACE32 scripts in this workspace are a mix
# of ASCII / GBK / UTF-8, so re-encoding them as UTF-8 would corrupt them.
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

Expand-Template (Join-Path $here 'configs\g5_screenoff.t32')         $cfg   @{ '__T32_INSTALL__' = $paths.T32_INSTALL }
Expand-Template (Join-Path $here 'harness\2211_ap_analyze.cmm.tmpl') $entry @{
    '__RAMDUMP_DIR__' = $RamdumpDir
    '__OUT_FILE__'    = $outFile
    '__MARKER_LOG__'  = $markerLog
    '__SCRIPT_DIR__'  = $scriptDir
    '__HARNESS_DIR__' = (Join-Path $here 'harness')
    '__RUN_STAMP__'   = $stamp
}

# ---------------------------------------------------------------- 5. kill stale instances
# A leftover TRACE32 instance makes the next start exit 2 or hang.
Get-Process -Name 't32*' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 4

# ---------------------------------------------------------------- 6. run
# WorkingDirectory is the customer script folder on purpose: their scripts call
# each other by bare name (`do frame.cmm`), which resolves against the process CWD.
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$proc = Start-Process -FilePath $t32exe `
                      -ArgumentList @('-c', "`"$cfg`"", '-s', "`"$entry`"") `
                      -WorkingDirectory $scriptDir -PassThru

$exited = $proc.WaitForExit($TimeoutSec * 1000)
if ($exited) { $code = $proc.ExitCode } else { $code = 'TIMEOUT'; $proc.Kill() }
$sw.Stop()

Get-Process -Name 't32*' -ErrorAction SilentlyContinue | Stop-Process -Force

# ---------------------------------------------------------------- 7. report
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

# NOTE: the per-block heap attribute list (Mem Leak Info / Memory Summary By File)
# is NOT part of this report. The customer's own golden output has that block empty
# as well, and the CMM expressions its walker needs (mbinptr/mchunkptr casts,
# sizeof) do not evaluate in this environment - see harness\heap_summary.cmm.

# --------------------------------------------- 7b. offline heap statistics (no T32)
# The chunk chain itself can be reconstructed from the byte-exact dump files and
# checked against the arena's `used` field, so the heap question is answered by a
# deterministic Python step instead of a CMM walk that cannot terminate.
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

$elfHash  = (Get-FileHash (Join-Path $RamdumpDir 'cpu-ap.elf') -Algorithm SHA256).Hash
$meta = @(
    "case        : 2211 AP death scene (headless)"
    "stamp       : $stamp"
    "ramdump     : $RamdumpDir"
    "elf         : cpu-ap.elf sha256=$elfHash"
    "engine      : vendor\2210_trace32 (customer originals) + harness\2211_ap_analyze.cmm.tmpl"
    "bypassed    : LM620_Restore.cmm (GUI wrapper), select_thread.cmm (interactive)"
    "heap        : harness\heap_summary.cmm (arena descriptor only; vendor heap walker spins on this arena)"
    "heap_offline: $heapLine"
    "config      : configs\g5_screenoff.t32 (PBI=SIM, SCREEN=OFF)"
    "t32         : $t32exe"
    "t32_cwd     : $scriptDir"
    "markers     : $markerLog"
    "exit        : $code"
    "elapsed_sec : $([int]$sw.Elapsed.TotalSeconds)"
    "output      : $outFile"
    "output_line : $lines"
) -join "`r`n"
[System.IO.File]::WriteAllText((Join-Path $runDir 'run.txt'), $meta, (New-Object System.Text.UTF8Encoding($false)))
"meta   : {0}" -f (Join-Path $runDir 'run.txt')

if ($code -ne 0) { exit 1 }
