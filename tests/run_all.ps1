<#
  tests\run_all.ps1 - the ONE test entry point for this repository.
  =================================================================
  Runs every verification stage in order and returns a single exit code. Nothing else
  in the tree is a test entry: cli\ holds the automation that is also useful on its
  own, tests\ holds the data it is judged against.

  Stages
    1 fixtures : tests\verify_fixtures.ps1        - SHA256 of every read-only fixture
    2 smoke    : cli\run_smoke.ps1                - batch markers + RCL byte checks
    3 full    : cli\run_2211_ap.ps1              - all 9 stages of the 2211 death scene
    4 one-by-one: cli\run_2211_func.ps1 -Func all - every safe GUI function, headless
    5 equiv    : tools\check_entries_equiv.py     - do the two entries agree?

  Usage
    powershell -ExecutionPolicy Bypass -File tests\run_all.ps1
    ... -SkipSmoke        (stages 1,3,4,5: no RT-Thread BSP needed)
    ... -SkipT32          (only stages 1 and 5: nothing is launched, pure file checks)

  Exit code 0 only when every stage that ran passed.

  NOTE: keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI).
#>
[CmdletBinding()]
param(
    [switch] $SkipSmoke,
    [switch] $SkipT32
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSScriptRoot          # repo root (this file is in tests\)
$ps   = (Get-Command powershell -ErrorAction SilentlyContinue).Source
if (-not $ps) { throw 'powershell.exe not found on PATH' }

function Invoke-Stage([string] $name, [string] $file, [string[]] $extra) {
    Write-Host ''
    Write-Host ('===== ' + $name + ' =====') -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $file)) {
        Write-Host ('  [SKIP] not found: ' + $file) -ForegroundColor Yellow
        return @{ name = $name; rc = 99; skipped = $true }
    }
    $argv = @('-ExecutionPolicy', 'Bypass', '-File', $file) + $extra
    # | Out-Host: without it the child's stdout joins this function's return value
    # and the summary below would print one row per output line.
    & $ps @argv | Out-Host
    return @{ name = $name; rc = $LASTEXITCODE; skipped = $false }
}

$results = @()
$results += Invoke-Stage '1/5 fixtures (tests\verify_fixtures.ps1)' 'tests\verify_fixtures.ps1' @()

if (-not $SkipT32) {
    if (-not $SkipSmoke) {
        $results += Invoke-Stage '2/5 smoke (cli\run_smoke.ps1)' 'cli\run_smoke.ps1' @()
    } else {
        Write-Host ''
        Write-Host '===== 2/5 smoke ===== skipped (-SkipSmoke)' -ForegroundColor Yellow
    }
    $results += Invoke-Stage '3/5 full 2211 run (cli\run_2211_ap.ps1)' 'cli\run_2211_ap.ps1' @()
    $results += Invoke-Stage '4/5 one function at a time (cli\run_2211_func.ps1 -Func all)' 'cli\run_2211_func.ps1' @('-Func', 'all')

    Write-Host ''
    Write-Host '===== 5/5 equivalence (tools\check_entries_equiv.py) =====' -ForegroundColor Cyan
    $py = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $py) {
        Write-Host '  [SKIP] python not on PATH' -ForegroundColor Yellow
        $results += @{ name = '5/5 equivalence'; rc = 99; skipped = $true }
    } else {
        & $py (Join-Path $here 'tools\check_entries_equiv.py')
        $results += @{ name = '5/5 equivalence'; rc = $LASTEXITCODE; skipped = $false }
    }
} else {
    Write-Host ''
    Write-Host '===== stages 2-4 ===== skipped (-SkipT32: nothing is launched)' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '===== summary =====' -ForegroundColor Cyan
$failed = 0
foreach ($r in $results) {
    $tag = if ($r.skipped) { '[SKIP]' } elseif ($r.rc -eq 0) { '[PASS]' } else { '[FAIL]' }
    if (-not $r.skipped -and $r.rc -ne 0) { $failed++ }
    Write-Host ('  {0,-9} {1}  exit={2}' -f $tag, $r.name, $r.rc) -ForegroundColor $(if ($tag -eq '[FAIL]') { 'Red' } elseif ($tag -eq '[PASS]') { 'Green' } else { 'Yellow' })
}
Write-Host ''
if ($failed -eq 0) { Write-Host 'TESTS-OK' -ForegroundColor Green; exit 0 }
Write-Host ('TESTS-FAILED (' + $failed + ' stage(s))') -ForegroundColor Red
exit 1
