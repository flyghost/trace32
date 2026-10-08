<#
  tests\run_all.ps1 - 本仓库唯一的测试入口。
  =================================================================
  按顺序跑完每个验证阶段，只返回一个退出码。树里没有别的东西算测试入口：cli\ 放的是
  本身也有用的自动化，tests\ 放的是用来评判它的数据。

  阶段
    1 encoding: tools\check_cn_encoding.ps1        - 编码/BOM/行尾/乱码（纯文件检查）
    2 ramdump : tests\verify_ramdump.ps1           - 对死机现场每个只读 fixture 校验 SHA256
    3 vendor  : tests\verify_vendor.ps1            - 对客户脚本原件（third_party\vendor\）校验 SHA256
    4 smoke   : cli\run_smoke.ps1                  - 批处理标记 + RCL 逐字节校验
    5 full    : cli\run_2211_ap.ps1                - 2211 死机现场的全部 9 个阶段
    6 one-by-one: cli\run_2211_func.ps1 -Func all  - 每个安全的 GUI 功能，无头运行
    7 baseline: tests\compare_baseline.ps1         - 上面两次运行的报告 vs tests\baseline\ 快照
    8 equiv    : tools\check_entries_equiv.py      - 两条入口的结果一致吗？

  用法
    powershell -ExecutionPolicy Bypass -File tests\run_all.ps1
    ... -SkipSmoke        （阶段 1,2,3,5,6,7,8：不需要 RT-Thread BSP）
    ... -SkipT32          （只跑阶段 1,2,3：不启动任何东西，纯文件检查）

  只有当跑过的每个阶段都通过时，退出码才是 0。

  NOTE: 本文件存为 UTF-8 with BOM（PS 5.1 读无 BOM 文件会乱码）。
#>
[CmdletBinding()]
param(
    [switch] $SkipSmoke,
    [switch] $SkipT32
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSScriptRoot          # 仓库根目录（本文件在 tests\ 下）
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
    # | Out-Host：没有它，子进程的 stdout 会并进本函数的返回值，
    # 下面的汇总就会每个输出行打印一行。
    & $ps @argv | Out-Host
    return @{ name = $name; rc = $LASTEXITCODE; skipped = $false }
}

$results = @()
# 阶段 1-3 是静态检查，不需要 TRACE32，也不需要测试用的 BSP —— 所以放在任何开关之外。
$results += Invoke-Stage '1/8 encoding (tools\check_cn_encoding.ps1)' 'tools\check_cn_encoding.ps1' @()
$results += Invoke-Stage '2/8 ramdump (tests\verify_ramdump.ps1)' 'tests\verify_ramdump.ps1' @()
$results += Invoke-Stage '3/8 vendor (tests\verify_vendor.ps1)' 'tests\verify_vendor.ps1' @()

if (-not $SkipT32) {
    if (-not $SkipSmoke) {
        $results += Invoke-Stage '4/8 smoke (cli\run_smoke.ps1)' 'cli\run_smoke.ps1' @()
    } else {
        Write-Host ''
        Write-Host '===== 4/8 smoke ===== skipped (-SkipSmoke)' -ForegroundColor Yellow
    }
    $results += Invoke-Stage '5/8 full 2211 run (cli\run_2211_ap.ps1)' 'cli\run_2211_ap.ps1' @()
    $results += Invoke-Stage '6/8 one function at a time (cli\run_2211_func.ps1 -Func all)' 'cli\run_2211_func.ps1' @('-Func', 'all')
    # 7/8：把刚跑出来的报告与 tests\baseline\ 的冻结快照比 —— 这就是"引擎改造前后必须逐字节一致"的机械闸门。
    $results += Invoke-Stage '7/8 baseline (tests\compare_baseline.ps1)' 'tests\compare_baseline.ps1' @()

    Write-Host ''
    Write-Host '===== 8/8 equivalence (tools\check_entries_equiv.py) =====' -ForegroundColor Cyan
    $py = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $py) {
        Write-Host '  [SKIP] python not on PATH' -ForegroundColor Yellow
        $results += @{ name = '8/8 equivalence'; rc = 99; skipped = $true }
    } else {
        & $py (Join-Path $here 'tools\check_entries_equiv.py')
        $results += @{ name = '8/8 equivalence'; rc = $LASTEXITCODE; skipped = $false }
    }
} else {
    Write-Host ''
    Write-Host '===== stages 4-7 ===== skipped (-SkipT32: nothing is launched)' -ForegroundColor Yellow
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
