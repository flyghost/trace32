<#
  为本机重新生成 third_party\launchers\*.lnk。
  ========================================================
  .lnk 内嵌了绝对目标路径，还有创建它的账户名，因此快捷方式不可能做成可移植的，
  并且被 git 忽略（**/*.lnk）。它们还指向客户的 GUI 资源，所以放在 third_party\ 下。
  克隆仓库后跑一次，之后仍能双击进入 GUI 会话。

  它还会依据仓库里的模板 configs\sim-gui.t32（其中带 SYS=__T32_INSTALL__）生成
  local\config_sim.t32，并让快捷方式指向生成出来的那份 —— 不是带占位符的模板。

  Usage: powershell -ExecutionPolicy Bypass -File tools\make_shortcuts.ps1
  Requires: local\paths.psd1（复制 local\paths.psd1.example 并填好）。
  NOTE: 本文件存为 UTF-8 with BOM（PS 5.1 读无 BOM 文件会乱码）。
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$pathsFile = Join-Path $root 'local\paths.psd1'
if (-not (Test-Path $pathsFile)) { throw "missing local\paths.psd1 - copy local\paths.psd1.example and fill it in" }
$paths = Import-PowerShellDataFile -LiteralPath $pathsFile
$T32 = $paths.T32_INSTALL.TrimEnd('\')

$localDir = Join-Path $root 'local'
if (-not (Test-Path $localDir)) { New-Item -ItemType Directory -Path $localDir | Out-Null }

# 保字节替换：这些模板是三编码的（ASCII / GBK / UTF-8）
$L = [System.Text.Encoding]::GetEncoding(28591)
$tmpl = Join-Path $root 'configs\sim-gui.t32'
$s = $L.GetString([System.IO.File]::ReadAllBytes($tmpl))
$s = $s.Replace('__T32_INSTALL__', $T32)
$s = $s.Replace('__T32_START_TEMP__', (Join-Path $T32 'Temp'))
$cfg = Join-Path $localDir 'config_sim.t32'
[System.IO.File]::WriteAllBytes($cfg, $L.GetBytes($s))
Write-Host ("generated " + $cfg)

$lnkDir = Join-Path $root 'third_party\launchers'
if (-not (Test-Path $lnkDir)) { New-Item -ItemType Directory -Path $lnkDir -Force | Out-Null }

$sh = New-Object -ComObject WScript.Shell
foreach ($n in @('t32marm', 't32mceva', 't32mriscv')) {
    $exe = Join-Path $T32 "bin\windows64\$n.exe"
    if (-not (Test-Path $exe)) { Write-Host ("  [WARN] not found, skipped: " + $exe) -ForegroundColor Yellow; continue }
    $lnkPath = Join-Path $lnkDir "$n.exe.lnk"
    $lnk = $sh.CreateShortcut($lnkPath)
    $lnk.TargetPath = $exe
    $lnk.Arguments = '-c ' + $cfg
    $lnk.WorkingDirectory = Join-Path $T32 'bin\windows64'
    $lnk.Save()
    Write-Host ("  wrote " + $lnkPath)
}
Write-Host 'done'
