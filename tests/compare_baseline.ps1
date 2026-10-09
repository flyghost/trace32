<#
  tests\compare_baseline.ps1 - 把一次运行的结果与 tests\baseline\ 的改造前快照对比。
  =========================================================================
  这是设计文档 §11.4 里 S1/S2 的验收工具：S1（把 cmm\src_2210\ 提升成工程内的引擎目录）
  的验收是「报告与 S0 字节相同」；S2（给三处堆遍历加边界）的验收是「差异只允许出现在
  ### 诊断行里」。

  为什么要"规范化"而不是裸比字节：报告头里有三样每次都变的东西 ——
    ① 本机绝对路径（仓库根、TRACE32 安装目录）—— 入库的内容不许带本机路径（基线里已替成占位符）；
    ② 运行时间戳（形如 20261008-174622）；
    ③ 少量耗时字段（elapsed_sec、每功能 sec=…）。
  所以两边都先做同一套替换，再比。判定三级（与设计文档 §11.3 对齐）：
    IDENTICAL   规范化后逐行相同（大文件用 sha256 证明字节相同）
    NORMALIZED  基线每一行都还在（保持顺序），新增行全部以 '### ' 开头（允许的诊断输出）
    DIFF        其他情况 —— 这就是"改坏了"或"有未申报的变化"

  ★ 公开仓库边界（为什么大文件只存摘要）：基线里的报告全部来自客户的死机现场，含客户
    内部符号名 / 源文件名 / 堆内存内容。仓库是公开的，所以超过 $digestLimit 个字符的
    快照只入库一行 sha256（`<NAME>.sha256`），字节相同性照样能判定，但不把大段客户内部
    痕迹写进公开历史。小文件（<= $digestLimit）保留全文，因为人眼 diff 才是它存在的意义。
    要强制存全文（例如本地做深度 diff），加 -KeepText。

  用法
    powershell -ExecutionPolicy Bypass -File tests\compare_baseline.ps1
    ... -Which 2211_ap            # 只比全量那条链
    ... -RunDir out\runs\2211_ap\20261008-174622   # 指定一次运行，默认取最新
    ... -Update                   # 用最新（或 -RunDir 指定的）运行**重建** tests\baseline\
  退出码：0 = 全部 IDENTICAL / NORMALIZED（-Update 模式：写成功即 0），1 = 有 DIFF 或文件缺失。

  ★ -Update 模式：规范化只有这一处实现，所以基线必须用它来重建，不要在别处手写替换表。
    它镜像 run 目录里的 *.txt（刻意排除 *_heap_by_file.txt 这种大表），删掉基线里多出来的
    文件，并把每个文件按同一套规则规范化后写回。重建属于「有未申报的变化」的显式收口：
    重建后在 tests\baseline\README.md 里写明这次为什么重建。

  NOTE: 本文件存为 UTF-8 with BOM（PS 5.1 读无 BOM 文件会乱码）。
#>
[CmdletBinding()]
param(
    [string] $Which = '',
    [string] $RunDir = '',
    [switch] $Update,
    [switch] $KeepText
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
# 不镜像进基线的大表（派生数据，体积大且可用 -Func all 重现）。
$skipMirror = '*_heap_by_file.txt'
# 超过这个字符数的快照只存 sha256 摘要（公开仓库边界，见文件头）。
$digestLimit = 20000

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Get-NormalizedLines([string] $path) {
    return @(Get-Content -LiteralPath $path -Encoding UTF8 | Where-Object { $_ -notmatch $volatile } | ForEach-Object { Convert-Normalized $_ })
}
function Get-TextSha([string[]] $lines) {
    $txt = ($lines -join "`n") + "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($txt))) -replace '-', '').ToLower() }
    finally { $sha.Dispose() }
}
function Get-NewestRun([string] $which) {
    $root = Join-Path $here ("out\runs\" + $which)
    if (-not (Test-Path $root)) { return $null }
    $d = Get-ChildItem $root -Directory | Sort-Object Name | Select-Object -Last 1
    if ($d) { return $d.FullName }
    return $null
}

$targets = if ($Which) { @($Which) } else { @('2211_ap', '2211_ap_func') }
$bad = 0; $files = 0; $vol = 0; $written = 0; $digested = 0
foreach ($w in $targets) {
    $baseDir = Join-Path $here ('tests\baseline\' + $w)
    Write-Host ''
    Write-Host ('===== ' + $w + ' =====') -ForegroundColor Cyan
    if (-not (Test-Path $baseDir)) {
        if ($Update) { New-Item -ItemType Directory -Force -Path $baseDir | Out-Null; Write-Host ('  created ' + $baseDir.Replace($here, '__REPO__')) }
        else { Write-Host ('  [FAIL] no baseline dir: ' + $baseDir) -ForegroundColor Red; $bad++; continue }
    }
    $run = if ($RunDir) { Join-Path $here $RunDir } else { Get-NewestRun $w }
    if (-not $run) { Write-Host '  [FAIL] no run directory under out\runs\' -ForegroundColor Red; $bad++; continue }
    Write-Host ('  run: ' + $run.Replace($here, '__REPO__'))

    if ($Update) {
        $mirror = @(Get-ChildItem $run -File -Filter '*.txt' | Where-Object { $_.Name -notlike $skipMirror } | Sort-Object Name)
        $keep = @()
        foreach ($f in $mirror) {
            $bl = Get-NormalizedLines $f.FullName
            $text = ($bl -join "`n") + "`n"
            $destTxt = Join-Path $baseDir $f.Name
            $destSha = Join-Path $baseDir ($f.Name + '.sha256')
            if ($text.Length -gt $digestLimit -and -not $KeepText) {
                $line = ((Get-TextSha $bl) + '  ' + $f.Name + '  ' + $bl.Count + ' lines') + "`n"
                [System.IO.File]::WriteAllText($destSha, $line, $utf8NoBom)
                if (Test-Path $destTxt) { Remove-Item -LiteralPath $destTxt -Force }
                Write-Host ('  digest     ' + $f.Name + '  ' + $bl.Count + ' lines  (' + $text.Length + ' chars)') -ForegroundColor DarkCyan
                $digested++
            } else {
                [System.IO.File]::WriteAllText($destTxt, $text, $utf8NoBom)
                if (Test-Path $destSha) { Remove-Item -LiteralPath $destSha -Force }
                Write-Host ('  wrote      ' + $f.Name + '  ' + $bl.Count + ' lines')
            }
            $keep += $f.Name
            $written++
        }
        # 基线里多出来的文件：run 里已经没有了 —— 删掉（-Update 是"镜像"，不是"合并"）
        foreach ($bf in @(Get-ChildItem $baseDir -File)) {
            if ($bf.Name -eq 'README.md') { continue }
            $orig = $bf.Name -replace '\.sha256$', ''
            if ($keep -notcontains $orig) {
                Remove-Item -LiteralPath $bf.FullName -Force
                Write-Host ('  removed    ' + $bf.Name + '  (not present in this run)') -ForegroundColor Yellow
            }
        }
        Write-Host ('  skipped    ' + $skipMirror + ' (derived table)') -ForegroundColor DarkGray
        continue
    }

    foreach ($bf in (Get-ChildItem $baseDir -File | Where-Object { $_.Name -like '*.txt' -or $_.Name -like '*.txt.sha256' } | Sort-Object Name)) {
        $files++
        $isDigest = $bf.Name.EndsWith('.sha256')
        $runName = if ($isDigest) { $bf.Name -replace '\.sha256$', '' } else { $bf.Name }
        $nf = Join-Path $run $runName
        if (-not (Test-Path -LiteralPath $nf)) { Write-Host ('  [FAIL] missing in run: ' + $runName) -ForegroundColor Red; $bad++; continue }
        $nl = Get-NormalizedLines $nf
        if ($isDigest) {
            $want = (((Get-Content -LiteralPath $bf.FullName -Encoding UTF8) -split '\s+')[0]).ToLower()
            $got = Get-TextSha $nl
            if ($want -eq $got) {
                Write-Host ('  {0,-10} {1,-30} {2,8} B  sha256 match, {3} lines' -f 'IDENTICAL', $runName, $bf.Length, $nl.Count) -ForegroundColor Green
            } else {
                Write-Host ('  {0,-10} {1,-30} {2,8} B  sha256 baseline={3} run={4}' -f 'DIFF', $runName, $bf.Length, $want.Substring(0, 12), $got.Substring(0, 12)) -ForegroundColor Red
                $bad++
            }
            continue
        }
        $bN = Get-NormalizedLines $bf.FullName
        $vol += (@(Get-Content -LiteralPath $bf.FullName -Encoding UTF8 | Where-Object { $_ -match $volatile }).Count)
        $verdict = 'DIFF'; $detail = ''
        if (($bN -join "`n") -ceq ($nl -join "`n")) {
            $verdict = 'IDENTICAL'; $detail = 'normalized identical'
        } else {
            # 基线行是否都在（保持顺序）？多出来的行是否全以 ### 开头？
            $rest = $bN
            $extra = 0
            $ok = $true
            foreach ($line in $nl) {
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
if ($Update) {
    Write-Host ('baseline: updated files={0} (of which sha256 digests={1})' -f $written, $digested) -ForegroundColor Green
    Write-Host 'BASELINE-UPDATED' -ForegroundColor Green
    exit 0
}
Write-Host ('baseline: files={0} volatile_lines_skipped={1} diff={2}' -f $files, $vol, $bad)
if ($bad -eq 0 -and $files -gt 0) { Write-Host 'BASELINE-OK' -ForegroundColor Green; exit 0 }
Write-Host 'BASELINE-DIFF' -ForegroundColor Red
exit 1
