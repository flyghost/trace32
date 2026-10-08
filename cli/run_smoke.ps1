<#
  Trace32_Auto smoke test  (cli\run_smoke.ps1)
  ===========================================
  Phase A (batch)  : t32marm.exe -c local\smoke.t32 -s local\run_restore.cmm
                     verifies: cmdline -> hidden instance -> file contract
  Phase B (RCL)    : start instance + cli\rcl_smoke.py
                     verifies: TCP remote control + FLASH byte-exact assertions

  Usage: powershell -ExecutionPolicy Bypass -File cli\run_smoke.ps1

  Layout: this file lives in cli\ (one level under the repo root). The repo root is
  derived from $PSScriptRoot, NOT from $MyInvocation - see NOTE (root) below.

  CONFIGURE FIRST: copy local\paths.psd1.example to local\paths.psd1 and fill in
  T32_INSTALL / BSP_DIR. Nothing in this repository hard-codes a machine path. The
  committed scripts carry placeholders, and this script substitutes them at run time
  into generated files under local\ (git-ignored):
      __T32_INSTALL__ in configs\g3_nettcp.t32 -> local\smoke.t32
      __BSP_DIR__     in cmm\restore.cmm       -> local\run_restore.cmm
  The remaining placeholders (__TMP_DIR__, __T32_START_TEMP__) are in historical
  files only; tools\make_shortcuts.ps1 handles the config_sim.t32 one.

  NOTE (root): every runner/tool resolves the repo root as "one level above its own
  directory". Change the depth of this file and it silently produces the wrong root.

  NOTE (CWD - verified by experiment): TRACE32 resolves RELATIVE paths against the
  working directory of the t32m*.exe process - NOT the -c config dir, NOT the -s
  script dir, NOT SYS. All cmm\ scripts therefore write to the relative path
  out\logs\, which is why this script MUST start t32 with -WorkingDirectory <repo root>.
  Launch t32 some other way and the marker files silently land somewhere else.

  NOTE (dirs - verified): APPEND does NOT create intermediate directories. If out\logs
  does not exist the write fails, and under ON ERROR Continue it fails SILENTLY -
  you get a clean exit and an empty result. This script creates out\logs up front.

  NOTE (permissions): the whole process tree, including the child t32marm.exe, needs
  write access to out\logs. If it cannot write there, the very first APPEND fails and
  TRACE32 sits on an error dialog: no log, no exit, i.e. a plain timeout.
  All cmm\ scripts therefore start with ON ERROR Continue.

  NOTE (this machine): Start-Process -RedirectStandardOutput/-RedirectStandardError
  always fails here with a NO_PROXY/no_proxy duplicate-key error, so this script does
  NO stdio redirection. All evidence comes from files written by the CMM itself
  (out\logs\) and from values returned over RCL.

  NOTE (exit code): a missing marker in Phase A is a FAILURE. Earlier revisions only
  printed [FAIL] and still exited 0 whenever python succeeded, which made a Phase A
  that never ran look green. Phase A failures now force exit 1.

  NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads BOM-less files as
  ANSI/GBK, which corrupts non-ASCII text and breaks the parser.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSScriptRoot          # repo root (this file is in cli\)
if (-not (Test-Path (Join-Path $here 'README.md'))) { throw ("repo root not found from " + $PSScriptRoot) }

# ---------- machine-local paths (never committed) ----------
$pathsFile = Join-Path $here 'local\paths.psd1'
if (-not (Test-Path $pathsFile)) {
    throw 'missing local\paths.psd1 - copy local\paths.psd1.example to local\paths.psd1 and fill in T32_INSTALL and BSP_DIR'
}
$paths = Import-PowerShellDataFile -LiteralPath $pathsFile
$T32 = Join-Path $paths.T32_INSTALL.TrimEnd('\') 'bin\windows64\t32marm.exe'
if (-not (Test-Path $T32)) { throw ("t32marm.exe not found: " + $T32 + " (check T32_INSTALL in local\paths.psd1)") }
if (-not (Test-Path (Join-Path $paths.BSP_DIR 'rtthread.bin'))) { throw ("rtthread.bin not found under BSP_DIR: " + $paths.BSP_DIR) }

$localDir = Join-Path $here 'local'
$logDir   = Join-Path $here 'out\logs'
foreach ($d in @($localDir, $logDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

# byte-preserving template expansion: the committed templates are tri-encoding
# (ASCII / GBK / UTF-8), so decode as Latin-1 and re-encode the same way
function Expand-Template([string]$src, [string]$dst, [hashtable]$map) {
    $L = [System.Text.Encoding]::GetEncoding(28591)
    $s = $L.GetString([System.IO.File]::ReadAllBytes($src))
    foreach ($k in $map.Keys) { $s = $s.Replace($k, $map[$k]) }
    [System.IO.File]::WriteAllBytes($dst, $L.GetBytes($s))
    Write-Host ('  generated ' + $dst.Replace($here, '.'))
}
Write-Host '===== expanding machine-local templates =====' -ForegroundColor Cyan
Expand-Template (Join-Path $here 'configs\g3_nettcp.t32') (Join-Path $localDir 'smoke.t32') @{ '__T32_INSTALL__' = $paths.T32_INSTALL.TrimEnd('\') }
Expand-Template (Join-Path $here 'cmm\restore.cmm') (Join-Path $localDir 'run_restore.cmm') @{ '__BSP_DIR__' = $paths.BSP_DIR }
$cfg = Join-Path $localDir 'smoke.t32'
$runCmm = Join-Path $localDir 'run_restore.cmm'

function Kill-T32 {
    Get-Process -Name 't32*' -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Kill() } catch {} }
    Start-Sleep -Seconds 4        # a left-over instance makes the next start exit=2 or hang
}
function Test-Port([int]$port) {
    try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $port); $c.Close(); return $true }
    catch { return $false }
}
function Wait-Port([int]$port) {
    for ($i = 0; $i -lt 30; $i++) { if (Test-Port $port) { return $true }; Start-Sleep -Milliseconds 500 }
    return $false
}

# ---------- Phase A: batch + file contract ----------
Write-Host ''
Write-Host '===== Phase A: batch mode (local\run_restore.cmm) =====' -ForegroundColor Cyan
Kill-T32
$log = Join-Path $logDir 'restore.log'
if (Test-Path $log) { Remove-Item -LiteralPath $log -Force }   # start clean so old lines are not mistaken for new

# quote every argument: an unquoted path containing a space makes t32 fail silently
$p = Start-Process -FilePath $T32 -ArgumentList ('-c "' + $cfg + '" -s "' + $runCmm + '"') `
                   -WorkingDirectory $here -PassThru
if (-not $p.WaitForExit(60000)) { $p.Kill(); throw 'Phase A timed out: batch did not exit in 60s (check the blank-line grouping in the config first)' }
Write-Host ("  exit code = " + $p.ExitCode)

$aFail = 0
Start-Sleep -Milliseconds 500
if (Test-Path $log) {
    Write-Host '  --- out\logs\restore.log ---'
    Get-Content -LiteralPath $log | ForEach-Object { '    ' + $_ }
    $txt = (Get-Content -LiteralPath $log -Raw)
    $markerFile = Join-Path $here 'tests\smoke\smoke.markers'   # expected markers live in tests\
    if (-not (Test-Path $markerFile)) { throw ("missing markers file: " + $markerFile) }
    $wanted = @(Get-Content -LiteralPath $markerFile | Where-Object { $_ -and -not $_.TrimStart().StartsWith('#') } | ForEach-Object { $_.Trim() })
    foreach ($must in $wanted) {
        if ($txt -notmatch [regex]::Escape($must)) { $aFail++; Write-Host ("  [FAIL] missing marker " + $must) -ForegroundColor Red }
        else { Write-Host ("  [PASS] " + $must) -ForegroundColor Green }
    }
} else {
    $aFail = 99
    Write-Host '  [FAIL] out\logs\restore.log was not created - the script never ran (99% a blank-line grouping problem, or t32 was not started with the repo root as CWD)' -ForegroundColor Red
}
if ($p.ExitCode -ne 0) { $aFail++; Write-Host ("  [FAIL] Phase A exit code = " + $p.ExitCode) -ForegroundColor Red }

# ---------- Phase B: RCL over TCP ----------
Write-Host ''
Write-Host '===== Phase B: RCL mode (cli\rcl_smoke.py) =====' -ForegroundColor Cyan
Kill-T32
$q = Start-Process -FilePath $T32 -ArgumentList ('-c "' + $cfg + '"') -WorkingDirectory $here -PassThru
if (-not (Wait-Port 20000)) { Kill-T32; throw 'TCP 20000 not ready: instance did not start, or RCL=NETTCP did not take effect' }
Write-Host '  TCP 20000 is ready'

# hand the BSP dir to python through the environment instead of a hard-coded path
$env:RAMDUMP_BSP_DIR = $paths.BSP_DIR
& python (Join-Path $here 'cli\rcl_smoke.py')
$rc = $LASTEXITCODE

Kill-T32
Write-Host ''
if ($aFail -eq 0 -and $rc -eq 0) {
    Write-Host 'SMOKE-OK  (phase A: all markers present, phase B: rcl exit 0)' -ForegroundColor Green
    exit 0
}
Write-Host ("SMOKE-FAILED  (phase A failures = " + $aFail + ", phase B exit code = " + $rc + ")") -ForegroundColor Red
exit 1
