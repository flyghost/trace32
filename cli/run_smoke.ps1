<#
  Trace32_Auto 冒烟测试  (cli\run_smoke.ps1)
  ===========================================
  阶段 A（批处理）: t32marm.exe -c local\smoke.t32 -s local\run_restore.cmm
                    验证：命令行 -> 隐藏实例 -> 文件契约
  阶段 B（RCL）   : 启动实例 + cli\rcl_smoke.py
                    验证：TCP 远程控制 + FLASH 逐字节断言

  用法：powershell -ExecutionPolicy Bypass -File cli\run_smoke.ps1

  目录布局：本文件位于 cli\（仓库根下一级）。仓库根由 $PSScriptRoot 推出，
  不是由 $MyInvocation 推出 —— 见下方「注意（仓库根）」。

  先做配置：把 local\paths.psd1.example 复制为 local\paths.psd1，填入
  T32_INSTALL / BSP_DIR。本仓库任何地方都不硬编码机器路径。提交进仓库的脚本
  只带占位符，运行时由本脚本替换后写入 local\ 下生成的文件（已 gitignore）：
      configs\sim-rcl-tcp-20000.t32 中的 __T32_INSTALL__ -> local\smoke.t32
      cmm\restore.cmm       中的 __BSP_DIR__     -> local\run_restore.cmm
  其余占位符（__TMP_DIR__、__T32_START_TEMP__）只存在于历史文件中；
  config_sim.t32 里的那个由 tools\make_shortcuts.ps1 处理。

  注意（仓库根）：所有 runner/工具都以「自己所在目录的上一级」作为仓库根。
  改变本文件的层级深度，它会静默算出错误的根目录。

  注意（CWD —— 已由实验验证）：TRACE32 是按 t32m*.exe 进程的工作目录来解析
  相对路径的 —— 不是 -c 配置目录、不是 -s 脚本目录、也不是 SYS。因此所有
  cmm\ 脚本都写相对路径 out\logs\，所以本脚本必须用
  -WorkingDirectory <仓库根> 启动 t32。换别的方式启动 t32，marker 文件会静默
  落到别的地方。

  注意（目录 —— 已验证）：APPEND 不会自动创建中间目录。若 out\logs 不存在，
  写入就失败，而在 ON ERROR Continue 下是静默失败 —— 你会看到一个干净的退出码
  和一份空结果。因此本脚本预先创建 out\logs。

  注意（权限）：整条进程树（含子进程 t32marm.exe）都需要 out\logs 的写权限。
  若写不进去，第一次 APPEND 就失败，TRACE32 会卡在错误对话框上：没有日志、没有
  退出码，也就是表现为一次普通超时。因此所有 cmm\ 脚本开头都带 ON ERROR Continue。

  注意（本机）：Start-Process 的 -RedirectStandardOutput/-RedirectStandardError
  在本机总是因 NO_PROXY/no_proxy 重复键报错，所以本脚本不做 stdio 重定向。
  全部证据都来自 CMM 自己写出的文件（out\logs\）以及 RCL 返回的值。

  注意（退出码）：阶段 A 缺少 marker 即为失败。早先的版本只打印 [FAIL]，只要
  python 成功就仍然退出 0，导致一个根本没跑起来的阶段 A 也显示为绿。现在阶段 A
  失败会强制退出 1。

  注意：本文件存为 UTF-8 with BOM：PS 5.1 读无 BOM 文件会按 GBK 乱码。
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSScriptRoot          # 仓库根（本文件位于 cli\）
if (-not (Test-Path (Join-Path $here 'README.md'))) { throw ("repo root not found from " + $PSScriptRoot) }

# ---------- 机器本地路径（永不提交） ----------
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

# 保字节的模板展开：提交进仓库的模板是三种编码混用（ASCII / GBK / UTF-8），
# 所以按 Latin-1 解码、再按同样的方式编码回去
function Expand-Template([string]$src, [string]$dst, [hashtable]$map) {
    $L = [System.Text.Encoding]::GetEncoding(28591)
    $s = $L.GetString([System.IO.File]::ReadAllBytes($src))
    foreach ($k in $map.Keys) { $s = $s.Replace($k, $map[$k]) }
    [System.IO.File]::WriteAllBytes($dst, $L.GetBytes($s))
    Write-Host ('  generated ' + $dst.Replace($here, '.'))
}
Write-Host '===== expanding machine-local templates =====' -ForegroundColor Cyan
Expand-Template (Join-Path $here 'configs\sim-rcl-tcp-20000.t32') (Join-Path $localDir 'smoke.t32') @{ '__T32_INSTALL__' = $paths.T32_INSTALL.TrimEnd('\') }
Expand-Template (Join-Path $here 'cmm\restore.cmm') (Join-Path $localDir 'run_restore.cmm') @{ '__BSP_DIR__' = $paths.BSP_DIR }
$cfg = Join-Path $localDir 'smoke.t32'
$runCmm = Join-Path $localDir 'run_restore.cmm'

function Kill-T32 {
    Get-Process -Name 't32*' -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Kill() } catch {} }
    Start-Sleep -Seconds 4        # 残留实例会让下一次启动退出码=2 或挂死
}
function Test-Port([int]$port) {
    try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $port); $c.Close(); return $true }
    catch { return $false }
}
function Wait-Port([int]$port) {
    for ($i = 0; $i -lt 30; $i++) { if (Test-Port $port) { return $true }; Start-Sleep -Milliseconds 500 }
    return $false
}

# ---------- 阶段 A：批处理 + 文件契约 ----------
Write-Host ''
Write-Host '===== Phase A: batch mode (local\run_restore.cmm) =====' -ForegroundColor Cyan
Kill-T32
$log = Join-Path $logDir 'restore.log'
if (Test-Path $log) { Remove-Item -LiteralPath $log -Force }   # 先清空，免得旧行被误当成新行

# 每个参数都加引号：含空格的路径不加引号会让 t32 静默失败
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
    $markerFile = Join-Path $here 'tests\smoke\smoke.markers'   # 期望的 marker 存放在 tests\
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

# ---------- 阶段 B：基于 TCP 的 RCL ----------
Write-Host ''
Write-Host '===== Phase B: RCL mode (cli\rcl_smoke.py) =====' -ForegroundColor Cyan
Kill-T32
$q = Start-Process -FilePath $T32 -ArgumentList ('-c "' + $cfg + '"') -WorkingDirectory $here -PassThru
if (-not (Wait-Port 20000)) { Kill-T32; throw 'TCP 20000 not ready: instance did not start, or RCL=NETTCP did not take effect' }
Write-Host '  TCP 20000 is ready'

# 通过环境变量把 BSP 目录传给 python，而不是写死路径
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
