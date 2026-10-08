<#
  tests\verify_fixtures.ps1 - check the read-only fixtures and baselines.
  =====================================================================
  Reads tests\fixtures.sha256 (one "<sha256>  <relpath>" per line) and verifies
  every listed file byte for byte. These files are git-ignored, so this is the only
  thing that catches a truncated copy, a half-finished download, or a fixture that
  was silently overwritten by a run.

  Exit code: 0 = every file present and identical, 1 = anything else.

  Usage: powershell -ExecutionPolicy Bypass -File tests\verify_fixtures.ps1
  NOTE: keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI).
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSScriptRoot          # repo root (this file is in tests\)
$list = Join-Path $PSScriptRoot 'fixtures.sha256'
if (-not (Test-Path $list)) { throw ("missing " + $list) }

$ok = 0; $bad = 0; $missing = 0; $bytes = 0
foreach ($line in (Get-Content -LiteralPath $list -Encoding UTF8)) {
    if (-not $line -or $line.TrimStart().StartsWith('#')) { continue }
    $parts = $line.Trim() -split '\s+', 2
    if ($parts.Count -lt 2) { Write-Host ("  [FAIL] unparsable line: " + $line) -ForegroundColor Red; $bad++; continue }
    $want = $parts[0].ToLower()
    $rel  = $parts[1].Trim()
    $path = Join-Path $here ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host ("  [FAIL] missing   " + $rel) -ForegroundColor Red
        $missing++
        continue
    }
    $fi = Get-Item -LiteralPath $path
    $got = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
    if ($got -eq $want) {
        Write-Host ("  [PASS] " + $rel + "  (" + $fi.Length + " bytes)")
        $ok++; $bytes += $fi.Length
    } else {
        Write-Host ("  [FAIL] hash differs " + $rel) -ForegroundColor Red
        Write-Host ("         want " + $want) -ForegroundColor DarkGray
        Write-Host ("         got  " + $got)  -ForegroundColor DarkGray
        $bad++
    }
}
Write-Host ""
Write-Host ("fixtures: ok={0} bad={1} missing={2}  total={3} bytes" -f $ok, $bad, $missing, $bytes)
if ($bad -eq 0 -and $missing -eq 0 -and $ok -gt 0) { Write-Host 'FIXTURES-OK' -ForegroundColor Green; exit 0 }
Write-Host 'FIXTURES-FAILED' -ForegroundColor Red
exit 1
