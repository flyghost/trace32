# Dual-entry gate: prove that a customer dialog script kept its dialog code verbatim
# AND that the headless (argument) path can never reach DIALOG/STOP.
#
# Why static: under SCREEN=OFF every DIALOG.* hangs forever (README iron rule 2), so the
# dialog path cannot be executed in CI. The next best thing is a mechanical proof that
#   (a) the frozen customer dialog region appears verbatim in our working copy, and
#   (b) the code before it contains no DIALOG/STOP at all.
#
# Manifest: tests\dual_entry.tsv  (tab separated)
#   workpath <TAB> frozenpath <TAB> regionStartLine <TAB> entryPattern
#
# NOTE on style: the helpers hand results back through $script: variables.
# PowerShell silently unwraps a one-element array on return, so `return ,$array`
# plus `@(...)` at the call site is a trap (measured 2026-10-09: it produced a nested
# array and `$hits.Count` reported 1 for a 2-hit search).
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $PSScriptRoot          # repo root (this file lives in tools\)
$list = Join-Path $here 'tests\dual_entry.tsv'
if (-not (Test-Path -LiteralPath $list)) { throw "missing $list" }

$enc = [System.Text.Encoding]::GetEncoding(28591)

# blank lines and trailing blanks dropped; byte view (encoding agnostic for ASCII patterns)
function Read-Norm([string] $path) {
  $text = $enc.GetString([System.IO.File]::ReadAllBytes($path))
  $out = New-Object System.Collections.ArrayList
  foreach ($l in ($text -split "`n")) {
    $x = $l.TrimEnd()
    if ($x.Trim() -ne '') { [void] $out.Add($x) }
  }
  $script:normLines = $out.ToArray()
}

# comment-stripped (PRACTICE comments start with ';') non-blank lines
function Get-Code([string[]] $lines) {
  $out = New-Object System.Collections.ArrayList
  foreach ($l in $lines) {
    $code = ($l -split ';')[0].Trim()
    if ($code -ne '') { [void] $out.Add($code) }
  }
  $script:codeLines = $out.ToArray()
}

# every start index where $needle occurs as a contiguous block inside $hay
function Find-Seq([string[]] $hay, [string[]] $needle) {
  $script:seqHits = New-Object System.Collections.ArrayList
  if ($needle.Count -eq 0 -or $hay.Count -lt $needle.Count) { return }
  for ($i = 0; $i -le ($hay.Count - $needle.Count); $i++) {
    $ok = $true
    for ($j = 0; $j -lt $needle.Count; $j++) {
      if ($hay[$i + $j] -cne $needle[$j]) { $ok = $false; break }
    }
    if ($ok) { [void] $script:seqHits.Add($i) }
  }
}

$files = 0; $ok = 0; $bad = 0
foreach ($raw in (Get-Content -LiteralPath $list -Encoding UTF8)) {
  if ($raw -match '^\s*#') { continue }
  if ($raw.Trim() -eq '') { continue }
  $col = $raw -split "`t"
  if ($col.Count -lt 4) { throw "bad manifest row: $raw" }
  $workRel = $col[0].Trim(); $frozRel = $col[1].Trim()
  $regionStart = $col[2].Trim(); $entryPattern = $col[3].Trim()

  $files++
  $workPath = Join-Path $here $workRel
  $frozPath = Join-Path $here $frozRel
  $problems = New-Object System.Collections.ArrayList
  if (-not (Test-Path -LiteralPath $workPath)) { [void] $problems.Add('missing working copy') }
  if (-not (Test-Path -LiteralPath $frozPath)) { [void] $problems.Add('missing frozen original') }
  if ($problems.Count -gt 0) { "[BAD ] $workRel  ($($problems -join '; '))"; $bad++; continue }

  Read-Norm $workPath; $work = $script:normLines
  Read-Norm $frozPath; $froz = $script:normLines

  # frozen region = from the region start marker to the end of the frozen original
  $fStart = -1
  for ($i = 0; $i -lt $froz.Count; $i++) { if ($froz[$i] -ceq $regionStart) { $fStart = $i; break } }
  if ($fStart -lt 0) { "[BAD ] $workRel  (region start '$regionStart' not found in the frozen original)"; $bad++; continue }
  $region = $froz[$fStart..($froz.Count - 1)]

  Find-Seq $work $region; $hits = @($script:seqHits)
  if ($hits.Count -ne 1) { [void] $problems.Add("the frozen dialog region occurs $($hits.Count) time(s) in the working copy, expected exactly 1") }

  Get-Code $work; $workCode = $script:codeLines
  $entryCount = 0
  foreach ($c in $workCode) { if ($c -match $entryPattern) { $entryCount++ } }
  if ($entryCount -lt 1) { [void] $problems.Add("no '$entryPattern' in the working copy") }

  $badBefore = @(); $badAfter = @()
  if ($hits.Count -eq 1) {
    $k = [int] $hits[0]
    $before = @()
    if ($k -gt 0) { $before = $work[0..($k - 1)] }
    $after = @()
    if (($k + $region.Count) -lt $work.Count) { $after = $work[($k + $region.Count)..($work.Count - 1)] }
    Get-Code $before; $codeBefore = $script:codeLines
    Get-Code $after;  $codeAfter  = $script:codeLines
    $badBefore = @($codeBefore | Where-Object { $_ -match '\b(DIALOG|STOP)\b' })
    $badAfter  = @($codeAfter  | Where-Object { $_ -match '\b(DIALOG|STOP)\b' })
    if ($badBefore.Count -ne 0) { [void] $problems.Add("$($badBefore.Count) DIALOG/STOP line(s) before the dialog region - the argument path must not open a dialog") }
    if ($badAfter.Count -ne 0) { [void] $problems.Add("$($badAfter.Count) DIALOG/STOP line(s) after the dialog region - our own code must stay headless") }
  }

  if ($problems.Count -eq 0) {
    '[OK  ] {0}  region={1} lines  entry={2}  before_clean={3}  after_clean={4}' -f `
      $workRel, $region.Count, $entryCount, ($badBefore.Count -eq 0), ($badAfter.Count -eq 0)
    $ok++
  } else {
    '[BAD ] {0}  ({1})' -f $workRel, ($problems -join '; ')
    $bad++
  }
}

'dual-entry: files={0} ok={1} bad={2}' -f $files, $ok, $bad
if ($bad -eq 0) { 'DUAL-ENTRY-OK'; exit 0 }
'DUAL-ENTRY-FAILED'; exit 1
