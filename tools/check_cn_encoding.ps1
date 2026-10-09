<#
  tools\check_cn_encoding.ps1 - 编码 / 中文注释合规闸门（纯文件检查，不启动 TRACE32）
  =================================================================
  这个仓库里的文件是**编码三态**的：客户给的是 GBK，我们自己写的是 UTF-8，
  早期探针是 ASCII。中文注释改造之后，最容易出的事故有三类，本脚本就盯这三类：
    1) 某个文件其实不是 UTF-8（GBK 混进来，或者 UTF-8 被按 Latin-1 写回去）
    2) BOM 不符合规则（见下）——PS 5.1 读**无 BOM** 文件会按 ANSI/GBK 解码，
       中文注释变乱码**并直接破坏解析**（实测报一堆 Unexpected token）
    3) 一个文件里混用 CRLF 与 LF（.gitattributes 是兜底，这里是二次确认）

  BOM 规则
    *.ps1 / *.psd1 / *.psd1.example  -> 必须带 BOM
    其余一切                        -> 必须不带 BOM

  乱码探针
    U+FFFD，以及 [U+00C2/U+00C3][U+0080-U+009F] 这种组合
    ——后者是"UTF-8 字节被当 Latin-1 解码后又存回 UTF-8"留下的指纹，
    正常 UTF-8 中文不会产生它。
    刻意**不查**"锟斤拷"那三个字：它本身就是文档里描述这类事故时用的词，查它只会让
    README 变成假阳性（实测踩过这个坑）。真正的判据是上面的严格 UTF-8 加上这里的 Â/Ã 指纹。

  文件清单从 `git ls-files` 自动发现（跟着 .gitignore 走：客户脚本、夹具、
  死机现场、pylibs 都不入库，所以天然被排除）。**没有硬编码清单**——新加的
  入库文件自动纳入检查；早期版本手写清单，改名之后静默漏检，已废弃。

  用法
    powershell -ExecutionPolicy Bypass -File tools\check_cn_encoding.ps1
    ... -NonCommentVsHead    额外：把 .t32/.cmm/.tmpl 的注释行剔除后与 HEAD 逐行比对
                             （中文注释改造期的迁移闸门，日常不需要：合法改代码也会红）

  NOTE: 本文件存为 UTF-8 with BOM（PS 5.1 读无 BOM 文件会乱码）。
#>
[CmdletBinding()]
param(
    [switch] $NonCommentVsHead
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSScriptRoot          # 仓库根目录（本文件在 tools\ 下）
Set-Location $here

$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)   # 严格：非法字节抛异常
$latin1     = [System.Text.Encoding]::GetEncoding(28591)

$git = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $git) { throw 'git not found on PATH - this gate discovers files with git ls-files' }
$rel = @(& $git ls-files)
if ($rel.Count -eq 0) { throw 'git ls-files returned nothing - is this a git checkout?' }

function Test-WantBom([string] $relPath) {
    $ext = [System.IO.Path]::GetExtension($relPath).ToLowerInvariant()
    if ($ext -eq '.ps1' -or $ext -eq '.psd1') { return $true }
    # paths.psd1.example 的扩展名是 .example，但它就是 PowerShell 数据文件模板
    if ($relPath -match '\.psd1\.example$') { return $true }
    return $false
}

Write-Host '== 编码 / BOM / 行尾 / 乱码（文件清单来自 git ls-files） =='
$badUtf8 = 0; $badBom = 0; $badEol = 0; $badMoji = 0; $missing = 0
$totalBytes = 0
foreach ($f in $rel) {
    $p = Join-Path $here $f
    if (-not (Test-Path -LiteralPath $p)) {
        # git ls-files 走的是索引：文件被删掉但还没 git add 时，索引里仍然有它。
        # 这是必须报出来的事，不能让 ReadAllBytes 直接把整个闸门炸掉（2026-10-09 实测）。
        $missing++
        '[FAIL] {0,-38} MISSING - tracked in the git index, absent in the worktree (run: git add -A)' -f $f
        continue
    }
    $bytes = [System.IO.File]::ReadAllBytes($p)
    $totalBytes += $bytes.Length
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if ($bom) { $body = $bytes[3..($bytes.Length - 1)] } else { $body = $bytes }
    $na = 0
    foreach ($x in $body) { if ($x -gt 127) { $na++ } }
    $isUtf8 = $true
    try { $null = $utf8Strict.GetString($body) } catch { $isUtf8 = $false }
    $wantBom = Test-WantBom $f
    $text  = $latin1.GetString($bytes)
    $crlf  = ([regex]::Matches($text, "`r`n")).Count
    $lf    = ([regex]::Matches($text, "`n")).Count
    $onlyLf = $lf - $crlf
    $moji = 0
    if ($isUtf8) {
        $s = $utf8Strict.GetString($body)
        $moji = ([regex]::Matches($s, '[\uFFFD]{1}|[\u00C2\u00C3][\u0080-\u009F]')).Count
    }
    $notes = @()
    if (-not $isUtf8) { $notes += 'NOT-UTF8'; $badUtf8++ }
    if ($bom -ne $wantBom) { $notes += ('BOM=' + $bom + '/需要=' + $wantBom); $badBom++ }
    if ($crlf -gt 0 -and $onlyLf -gt 0) { $notes += 'MIXED-EOL'; $badEol++ }
    if ($moji -gt 0) { $notes += ('MOJIBAKE=' + $moji); $badMoji++ }
    $tag = '[ok]  '
    if ($notes.Count -gt 0) { $tag = '[FAIL]' }
    '{0} {1,-38} bom={2,-5} utf8={3,-5} CRLF={4,-5} 裸LF={5,-5} 非ASCII={6,-6} {7}' -f `
        $tag, $f, $bom, $isUtf8, $crlf, $onlyLf, $na, ($notes -join ' ')
}

$badNc = 0
if ($NonCommentVsHead) {
    # 注释行剔除后与 HEAD 逐行比对（含空行）：任何代码改动、或 .t32 空行增删都会被抓出。
    # PRACTICE / .t32 配置的注释行首是 ';'。
    Write-Host ''
    Write-Host '== 非注释行对照 HEAD（只查 .t32 / .cmm / .tmpl） =='
    $cmp = @($rel | Where-Object { $_ -match '\.(t32|cmm|tmpl)$' })
    foreach ($f in $cmp) {
        $p = Join-Path $here $f
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $headText = $null
        try { $headText = & $git show ('HEAD:' + $f) } catch { $headText = $null }
        if ($null -eq $headText) { '[SKIP] {0}  （HEAD 里没有，或是新文件）' -f $f; continue }
        $a = @($headText | ForEach-Object { $_.Trim() } | Where-Object { -not $_.StartsWith(';') })
        $b = @([System.IO.File]::ReadAllLines($p) | ForEach-Object { $_.Trim() } | Where-Object { -not $_.StartsWith(';') })
        while ($a.Count -gt 0 -and $a[-1] -eq '') { $a = $a[0..($a.Count - 2)] }
        while ($b.Count -gt 0 -and $b[-1] -eq '') { $b = $b[0..($b.Count - 2)] }
        if (($a -join "`u{1}") -cne ($b -join "`u{1}")) {
            $badNc++
            '[FAIL] {0}  HEAD={1} 行 / 当前={2} 行' -f $f, $a.Count, $b.Count
            for ($i = 0; $i -lt [Math]::Max($a.Count, $b.Count); $i++) {
                if ($a[$i] -cne $b[$i]) {
                    '       line {0}: HEAD=[{1}]  CUR=[{2}]' -f ($i + 1), $a[$i], $b[$i]
                    break
                }
            }
        } else { '[ok]   {0}  非注释行={1}' -f $f, $b.Count }
    }
    'NONCOMMENT-BAD=' + $badNc
}

Write-Host ''
Write-Host ('== 汇总 ==  文件={0}  字节={1}  NOT-UTF8={2}  BOM不合规={3}  行尾混用={4}  乱码={5}  索引有而工作树无={6}{7}' -f `
    $rel.Count, $totalBytes, $badUtf8, $badBom, $badEol, $badMoji, $missing, `
    $(if ($NonCommentVsHead) { '  非注释行不一致=' + $badNc } else { '' }))
$fail = ($badUtf8 + $badBom + $badEol + $badMoji + $badNc + $missing)
if ($fail -eq 0) { Write-Host 'CN-ENCODING-OK' -ForegroundColor Green; exit 0 }
Write-Host 'CN-ENCODING-FAILED' -ForegroundColor Red
exit 1
