<#
  Regenerate launchers\*.lnk for THIS machine.
  ===========================================
  A .lnk embeds an absolute target path AND the name of the account that created it,
  so shortcuts cannot be made portable and are git-ignored (launchers/*.lnk).
  Run this once after cloning so you can still double-click into a GUI session.

  It also materialises local\config_sim.t32 from the committed template
  launchers\config_sim.t32 (which carries SYS=__T32_INSTALL__), and points the
  shortcuts at that generated copy - not at the template with its placeholder.

  Usage: powershell -ExecutionPolicy Bypass -File tools\make_shortcuts.ps1
  Requires: local\paths.psd1 (copy local\paths.psd1.example and fill it in).
  NOTE: keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI).
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$pathsFile = Join-Path $root 'local\paths.psd1'
if (-not (Test-Path $pathsFile)) { throw "missing local\paths.psd1 - copy local\paths.psd1.example and fill it in" }
$paths = Import-PowerShellDataFile -LiteralPath $pathsFile
$T32 = $paths.T32_INSTALL.TrimEnd('\')

$localDir = Join-Path $root 'local'
if (-not (Test-Path $localDir)) { New-Item -ItemType Directory -Path $localDir | Out-Null }

# byte-preserving substitution: the templates are tri-encoding (ASCII / GBK / UTF-8)
$L = [System.Text.Encoding]::GetEncoding(28591)
$tmpl = Join-Path $root 'launchers\config_sim.t32'
$s = $L.GetString([System.IO.File]::ReadAllBytes($tmpl))
$s = $s.Replace('__T32_INSTALL__', $T32)
$s = $s.Replace('__T32_START_TEMP__', (Join-Path $T32 'Temp'))
$cfg = Join-Path $localDir 'config_sim.t32'
[System.IO.File]::WriteAllBytes($cfg, $L.GetBytes($s))
Write-Host ("generated " + $cfg)

$sh = New-Object -ComObject WScript.Shell
foreach ($n in @('t32marm', 't32mceva', 't32mriscv')) {
    $exe = Join-Path $T32 "bin\windows64\$n.exe"
    if (-not (Test-Path $exe)) { Write-Host ("  [WARN] not found, skipped: " + $exe) -ForegroundColor Yellow; continue }
    $lnkPath = Join-Path $root "launchers\$n.exe.lnk"
    $lnk = $sh.CreateShortcut($lnkPath)
    $lnk.TargetPath = $exe
    $lnk.Arguments = '-c ' + $cfg
    $lnk.WorkingDirectory = Join-Path $T32 'bin\windows64'
    $lnk.Save()
    Write-Host ("  wrote " + $lnkPath)
}
Write-Host 'done'
