<#
  tests\compare_baseline.ps1 - 把一次运行的结果与 tests\baseline\ 的改造前快照对比。
  =========================================================================
  这是设计文档 §11.4 里 S1/S2 的验收工具：S1（把 cmm\src_2210\ 提升成 platforms\2210\engine\）
  的验收是「报告与 S0 字节相同」；S2（给两处堆遍历加边界）的验收是「差异只允许出现在 ### 诊断行里」。

  为什么要"规范化"而不是裸比字节：报告头里有三样每次都变的东西 ——
    ① 本机绝对路径（仓库根、TRACE32 安装目录）—— 入库的内容不许带本机路径（基线里已替成占位符）；
    ② 运行时间戳（形如 20261008-174622）；
    ③ 少量耗时字段（elapsed_sec）。
  所以两边都先做同一套替换，再比。判定三级（与设计文档 §11.3 对齐）：
    IDENTICAL   规范化后逐行相同
    NORMALIZED  基线每一行都还在（保持顺序），新增行全部以 '### ' 开头（允许的诊断输出）
    DIFF        其他情况 —— 这就是"改坏了"或"有未申报的变化"

  用法
    powershell -ExecutionPolicy Bypass -File tests\compare_baseline.ps1
    ... -Which 2211_ap            # 只比全量那条链
    ... -RunDir out\runs\2211_ap\20261008-174622   # 指定一次运行，默认取最新
  退出码：0 = 全部 IDENTICAL / NORMALIZED，1 = 有 DIFF 或文件缺失。

  NOTE: 本文件存为 UTF-8 with BOM（PS 5.1 读无 BOM 文件会乱码）。
#>
[CmdletBinding()]
param(
    [string] $Which = '',
    [string] $RunDir = ''
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSScriptRoot          # 仓库根目录（本文件在 tests\ 下）

# 本机路径 -> 占位符。顺序要紧：仓库根必须排在安装目录之前，否则 Trace32_Auto 会被替成 __T32_INSTALL___Auto。
$map = [ordered]@{}
$map[$here] = '__REPO__'
if (Test-Path (Join-Path $here 'local\paths.psd1')) {
    $t32 = (Import-PowerShellDataFile -LiteralPath (Join-Path $here 'local\paths.psd1')).T32_INSTALL
    if ($t32) { $map[$t32] = '__T32_INSTALL__' }
}
$map[(Join-Path (Split-Path -Parent $here) 'Trace32_Start\Temp')] = '__T32_START_TEMP__'

function Convert-Normalized([string] $text) {
    $t = $text
    foreach ($k in $map.Keys) { $t = $t.Replace($k, $map[$k]) }
    $t = [regex]::Replace($t, '\b20\d{6}-\d{6}\b', '__STAMP__')   # 运行时间戳（每次不同）
    # 每个功能的耗时（每次不同）；连它后面的对齐空格一起规范化，否则 4.9 -> 5 会让列宽变一格。
    $t = [regex]::Replace($t, 'sec=[0-9.]+[ \t]*', 'sec=__SEC__ ')
    return $t
}
# 每次都不同、但无信息量的行（耗时），不参与判定。
$volatile = '^(elapsed_sec|elapsed|duration)\s*[:=]'

function Get-NewestRun([string] $which) {
    $root = Join-Path $here ("out\runs\" + $which)
    if (-not (Test-Path $root)) { return $null }
    $d = Get-ChildItem $root -Directory | Sort-Object Name | Select-Object -Last 1
    if ($d) { return $d.FullName }
    return $null
}

$targets = if ($Which) { @($Which) } else { @('2211_ap', '2211_ap_func') }
$bad = 0; $files = 0; $vol = 0
foreach ($w in $targets) {
    $baseDir = Join-Path $here ('tests\baseline\' + $w)
    Write-Host ''
    Write-Host ('===== ' + $w + ' =====') -ForegroundColor Cyan
    if (-not (Test-Path $baseDir)) { Write-Host ('  [FAIL] no baseline dir: ' + $baseDir) -ForegroundColor Red; $bad++; continue }
    $run = if ($RunDir) { Join-Path $here $RunDir } else { Get-NewestRun $w }
    if (-not $run) { Write-Host '  [FAIL] no run directory under out\runs\' -ForegroundColor Red; $bad++; continue }
    Write-Host ('  run: ' + $run.Replace($here, '__REPO__'))
    foreach ($bf in (Get-ChildItem $baseDir -File -Filter '*.txt' | Sort-Object Name)) {
        $files++
        $nf = Join-Path $run $bf.Name
        if (-not (Test-Path -LiteralPath $nf)) { Write-Host ('  [FAIL] missing in run: ' + $bf.Name) -ForegroundColor Red; $bad++; continue }
        $bl = @(Get-Content -LiteralPath $bf.FullName -Encoding UTF8)
        $nl = @(Get-Content -LiteralPath $nf -Encoding UTF8)
        # 先扣掉耗时行，再做规范化
        $vol += (@($bl | Where-Object { $_ -match $volatile }).Count)
        $bN = @($bl | Where-Object { $_ -notmatch $volatile } | ForEach-Object { Convert-Normalized $_ })
        $nN = @($nl | Where-Object { $_ -notmatch $volatile } | ForEach-Object { Convert-Normalized $_ })
        $verdict = 'DIFF'; $detail = ''
        if (($bN -join "`n") -ceq ($nN -join "`n")) {
            $verdict = 'IDENTICAL'; $detail = 'normalized identical'
        } else {
            # 基线行是否都在（保持顺序）？多出来的行是否全以 ### 开头？
            $rest = $bN
            $extra = 0
            $ok = $true
            foreach ($line in $nN) {
                if ($rest.Count -gt 0 -and $rest[0] -ceq $line) {
                    $rest = @($rest | Select-Object -Skip 1)
                } elseif ($line -match '^### ') {
                    $extra++
                } elseif ($rest.Count -eq 0) {
                    $extra++                      # 尾部新增的非 ### 行
                } else {
                    $ok = $false; break           # 基线里一行不见了 / 顺序变了 / 内容改了
                }
            }
            if ($ok -and $rest.Count -eq 0) {
                $verdict = 'NORMALIZED'
                $detail = if ($extra -eq 0) { 'same lines, formatting-only difference' } else { ('+' + $extra + ' line(s)') }
            } else {
                $detail = ('first mismatch near baseline line ' + (@($bN).Count - $rest.Count + 1))
            }
        }
        if ($verdict -eq 'DIFF') { $bad++ }
        $color = if ($verdict -eq 'DIFF') { 'Red' } else { 'Green' }
        Write-Host ('  {0,-10} {1,-30} {2,8} B  {3}' -f $verdict, $bf.Name, $bf.Length, $detail) -ForegroundColor $color
    }
}
Write-Host ''
Write-Host ('baseline: files={0} volatile_lines_skipped={1} diff={2}' -f $files, $vol, $bad)
if ($bad -eq 0 -and $files -gt 0) { Write-Host 'BASELINE-OK' -ForegroundColor Green; exit 0 }
Write-Host 'BASELINE-DIFF' -ForegroundColor Red
exit 1
