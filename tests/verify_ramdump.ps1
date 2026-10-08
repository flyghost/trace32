<#
  tests\verify_ramdump.ps1 - 校验只读死机现场（ramdump）。
  =====================================================================
  读取 tests\ramdump.sha256（每行一条 "<sha256>  <relpath>"），把列出的每个文件
  逐字节校验一遍。这些文件被 git 忽略（ramdump\），所以这里是唯一
  能抓出「拷贝被截断」「下载没下完」或「现场被某次运行悄悄覆盖」的地方。

  退出码：0 = 每个文件都存在且完全相同，1 = 其他任何情况。

  Usage: powershell -ExecutionPolicy Bypass -File tests\verify_ramdump.ps1
  NOTE: 本文件存为 UTF-8 with BOM（PS 5.1 读无 BOM 文件会乱码）。
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSScriptRoot          # 仓库根目录（本文件在 tests\ 下）
$list = Join-Path $PSScriptRoot 'ramdump.sha256'
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
Write-Host ("ramdump: ok={0} bad={1} missing={2}  total={3} bytes" -f $ok, $bad, $missing, $bytes)
if ($bad -eq 0 -and $missing -eq 0 -and $ok -gt 0) { Write-Host 'RAMDUMP-OK' -ForegroundColor Green; exit 0 }
Write-Host 'RAMDUMP-FAILED' -ForegroundColor Red
exit 1
