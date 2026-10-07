<#
  Trace32_Auto smoke test
  =======================
  Phase A (batch)  : t32marm.exe -c local\smoke.t32 -s local\run_restore.cmm
                     verifies: cmdline -> hidden instance -> file contract
  Phase B (RCL)    : start instance + python\rcl_smoke.py
                     verifies: TCP remote control + FLASH byte-exact assertions

  Usage: powershell -ExecutionPolicy Bypass -File run_smoke.ps1

  CONFIGURE FIRST: copy local\paths.psd1.example to local\paths.psd1 and fill in
  T32_INSTALL / BSP_DIR. Nothing in this repository hard-codes a machine path. The
  committed scripts carry placeholders, and this script substitutes them at run time
  into generated files under local\ (git-ignored):
      __T32_INSTALL__ in configs\g3_nettcp.t32 -> local\smoke.t32
      __BSP_DIR__     in cmm\restore.cmm       -> local\run_restore.cmm
  The remaining placeholders (__TMP_DIR__, __T32_START_TEMP__) are in historical
  files only; tools\make_shortcuts.ps1 handles the config_sim.t32 one.

  NOTE (CWD - verified by experiment): TRACE32 resolves RELATIVE paths against the
  working directory of the t32m*.exe process - NOT the -c config dir, NOT the -s
  script dir, NOT SYS. All cmm\ scripts therefore write to the relative path logs\,
  which is why this script MUST start t32 with -WorkingDirectory <repo root>.
  Launch t32 some other way and the marker files silently land somewhere else.

  NOTE (dirs - verified): APPEND does NOT create intermediate directories. If logs\
  does not exist the write fails, and under ON ERROR Continue it fails SILENTLY -
  you get a clean exit and an empty result. This script creates logs\ up front.

  NOTE (permissions): the whole process tree, including the child t32marm.exe, needs
  write access to logs\. If it cannot write there, the very first APPEND fails and
  TRACE32 sits on an error dialog: no log, no exit, i.e. a plain timeout.
  All cmm\ scripts therefore start with ON ERROR Continue.

  NOTE (this machine): Start-Process -RedirectStandardOutput/-RedirectStandardError
  always fails here with a NO_PROXY/no_proxy duplicate-key error, so this script does
  NO stdio redirection. All evidence comes from files written by the CMM itself (logs\)
  and from values returned over RCL.

  NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads BOM-less files as
  ANSI/GBK, which corrupts non-ASCII text and breaks the parser.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

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
$logDir = Join-Path $here 'logs'
foreach ($d in @($localDir, $logDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }

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
$log = Join-Path $here 'logs\restore.log'
if (Test-Path $log) { Remove-Item -LiteralPath $log -Force }   # start clean so old lines are not mistaken for new

$p = Start-Process -FilePath $T32 -ArgumentList @('-c', $cfg, '-s', (Join-Path $localDir 'run_restore.cmm')) `
                   -WorkingDirectory $here -PassThru
if (-not $p.WaitForExit(60000)) { $p.Kill(); throw 'Phase A timed out: batch did not exit in 60s (check the blank-line grouping in the config first)' }
Write-Host ("  exit code = " + $p.ExitCode)

Start-Sleep -Milliseconds 500
if (Test-Path $log) {
    Write-Host '  --- logs\restore.log ---'
    Get-Content -LiteralPath $log | ForEach-Object { '    ' + $_ }
    $txt = (Get-Content -LiteralPath $log -Raw)
    foreach ($must in @('R2-UP-OK', 'R3-BIN-LOADED', 'R4-VECTORS', 'R5-ELF-OK', 'R9-END')) {
        if ($txt -notmatch [regex]::Escape($must)) { Write-Host ("  [FAIL] missing marker " + $must) -ForegroundColor Red }
        else { Write-Host ("  [PASS] " + $must) -ForegroundColor Green }
    }
} else {
    Write-Host '  [FAIL] logs\restore.log was not created - the script never ran (99% a blank-line grouping problem, or t32 was not started with the repo root as CWD)' -ForegroundColor Red
}

# ---------- Phase B: RCL over TCP ----------
Write-Host ''
Write-Host '===== Phase B: RCL mode (python\rcl_smoke.py) =====' -ForegroundColor Cyan
Kill-T32
$q = Start-Process -FilePath $T32 -ArgumentList @('-c', $cfg) -WorkingDirectory $here -PassThru
if (-not (Wait-Port 20000)) { Kill-T32; throw 'TCP 20000 not ready: instance did not start, or RCL=NETTCP did not take effect' }
Write-Host '  TCP 20000 is ready'

# hand the BSP dir to python through the environment instead of a hard-coded path
$env:RAMDUMP_BSP_DIR = $paths.BSP_DIR
& python (Join-Path $here 'python\rcl_smoke.py')
$rc = $LASTEXITCODE

Kill-T32
Write-Host ''
Write-Host ("smoke finished: python exit code = " + $rc) -ForegroundColor $(if ($rc -eq 0) { 'Green' } else { 'Red' })
exit $rc
