<#
  run_2211_func.ps1 - 2211 AP 死亡现场的无界面「单函数」运行器。

  一个功能，两个入口
    GUI 入口        third_party\vendor\2210_trace32\LM620_Restore.cmm  （按钮、DIALOG.*、STOP）
    无界面入口      cli\run_2211_func.ps1 + cli\2211_ap_func.cmm.tmpl
  两者驱动的是 third_party\vendor\2210_trace32 里同一批客户脚本，这些脚本永不修改。
  差别只在参数来源：GUI 里是对话框，这里是命令行。函数注册表是 cmm\functions.json，
  因此函数清单只存在于一处。

  示例
    powershell -ExecutionPolicy Bypass -File cli\run_2211_func.ps1 -List
    powershell -ExecutionPolicy Bypass -File cli\run_2211_func.ps1 -Func show_thread
    powershell -ExecutionPolicy Bypass -File cli\run_2211_func.ps1 -Func thread_bt -Thread ImsMain
    powershell -ExecutionPolicy Bypass -File cli\run_2211_func.ps1 -Func all

  -Func all 会跑除「实测在本 arena 上挂死」之外的所有函数（mem_trace、mem_summary）；
  要跑这两个需按名字显式指定，或加 -IncludeUnsafe。
#>
# 注意：本文件存为 UTF-8 with BOM：PS 5.1 读无 BOM 文件会按 GBK 乱码。
param(
    [string] $Func = 'list',
    [string] $Thread = 'idle',
    [int]    $TimeoutSec = 300,
    [string] $RamdumpDir = '',
    [string] $OutRoot = '',
    [switch] $IncludeUnsafe
)
$ErrorActionPreference = 'Stop'

$here       = Split-Path -Parent $PSScriptRoot
$registry   = Join-Path $here 'cmm\functions.json'
$tmpl       = Join-Path $PSScriptRoot '2211_ap_func.cmm.tmpl'
$vendorDir  = Join-Path $here 'third_party\vendor\2210_trace32'
$cmmDir     = Join-Path $here 'cmm'
$localDir   = Join-Path $here 'local'
$logDir     = Join-Path $here 'out\logs'
$cfgSrc     = Join-Path $here 'configs\g5_screenoff.t32'
$pathsFile  = Join-Path $localDir 'paths.psd1'

function Read-Utf8([string] $p) { return [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) }
function Write-Latin1([string] $p, [string] $t) {
    $enc = [System.Text.Encoding]::GetEncoding(28591)
    [System.IO.File]::WriteAllBytes($p, $enc.GetBytes($t))
}
function Expand([string] $text, [hashtable] $map) {
    foreach ($k in @($map.Keys)) { $text = $text.Replace($k, [string]$map[$k]) }
    return $text
}
function Kill-T32 {
    Get-Process -Name 't32*' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 4
}

$reg = (Read-Utf8 $registry) | ConvertFrom-Json
$all = @($reg.functions)

if ($Func -eq 'list') {
    Write-Host ''
    Write-Host ('function registry : ' + $registry)
    Write-Host ('GUI entry         : ' + $reg.gui_entry)
    Write-Host ''
    Write-Host ('{0,-14} {1,-7} {2,-42} {3,-12} {4}' -f 'function', 'kind', 'GUI button', 'safe', 'vendor scripts')
    Write-Host ('{0,-14} {1,-7} {2,-42} {3,-12} {4}' -f '--------', '----', '----------', '----', '--------------')
    foreach ($f in $all) {
        $safe = if ($f.safe -eq $false) { 'NO (hangs)' } else { 'yes' }
        Write-Host ('{0,-14} {1,-7} {2,-42} {3,-12} {4}' -f $f.name, $f.kind, $f.button, $safe, (@($f.vendor) -join ', '))
    }
    Write-Host ''
    exit 0
}

if (-not (Test-Path -LiteralPath $pathsFile)) {
    throw 'missing local\paths.psd1 - copy local\paths.psd1.example to local\paths.psd1 and fill in T32_INSTALL'
}
$paths = Import-PowerShellDataFile -LiteralPath $pathsFile
$t32 = Join-Path ($paths.T32_INSTALL.TrimEnd('\')) 'bin\windows64\t32mriscv.exe'
if (-not (Test-Path -LiteralPath $t32)) { throw ('t32mriscv.exe not found: ' + $t32) }
if ($RamdumpDir -eq '') { $RamdumpDir = Join-Path $here 'fixtures\2211_deathscene' }
if (-not (Test-Path -LiteralPath $RamdumpDir)) { throw ('ramdump dir not found: ' + $RamdumpDir) }

$skipped = @()
if ($Func -eq 'all') {
    $want = @($all | Where-Object { $_.safe -ne $false })
    $skipped = @($all | Where-Object { $_.safe -eq $false })
    if ($IncludeUnsafe) { $want = $all }
} else {
    $want = @($all | Where-Object { $_.name -eq $Func })
}
if (@($want).Count -eq 0) { throw ("unknown function '" + $Func + "' - run with -List to see the registry") }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ($OutRoot -eq '') { $OutRoot = Join-Path $here 'out\runs\2211_ap_func' }
$runDir = Join-Path $OutRoot $stamp
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
New-Item -ItemType Directory -Force -Path $localDir | Out-Null
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

# 每个函数共用的同一份启动配置；只有 -s 脚本不同
$cfg = Join-Path $localDir 'g5_screenoff.t32'
Write-Latin1 $cfg (Expand (Read-Utf8 $cfgSrc) @{ '__T32_INSTALL__' = $paths.T32_INSTALL.TrimEnd('\') })

Write-Host ''
Write-Host ('run dir  : ' + $runDir)
Write-Host ('ramdump  : ' + $RamdumpDir)
Write-Host ('config   : ' + $cfg)
Write-Host ('thread   : ' + $Thread + '   (used by the thread_bt function)')
if (@($skipped).Count -gt 0) {
    $names = (@($skipped) | ForEach-Object { $_.name }) -join ', '
    Write-Host ('skipped  : ' + $names + '   (measured to hang on this arena; ask for one by name or add -IncludeUnsafe)') -ForegroundColor Yellow
}
Write-Host ''

$rows = @()
foreach ($f in $want) {
    $out  = Join-Path $runDir ($f.name + '.txt')
    $mark = Join-Path $logDir ('func-' + $f.name + '-' + $stamp + '.log')
    Remove-Item -LiteralPath $out, $mark -ErrorAction SilentlyContinue

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $rc = ''
    $timedOut = $false
    $note = ''

    if ($f.kind -eq 'python') {
        $py = (Get-Command python -ErrorAction SilentlyContinue).Source
        if (-not $py) { $rc = 'no-python'; $note = 'python not on PATH' }
        else {
            $script = Join-Path $here $f.python
            & $py $script $RamdumpDir $out | Out-Null
            $rc = $LASTEXITCODE
        }
    } else {
        # 函数体本身也含占位符（__SCRIPT_DIR__、__CMM_DIR__），所以必须先展开它、
        # 再插入模板。只把整个模板展开一次是不够的：hashtable 的顺序不确定，
        # 早被替换进去的函数体会原样保留它自己的 __...__ 记号。
        $map = @{
            '__FUNC_NAME__'    = $f.name
            '__FUNC_BUTTON__'  = $f.button
            '__FUNC_DESC__'    = $f.desc
            '__RAMDUMP_DIR__'  = $RamdumpDir
            '__ELF_NAME__'     = $reg.elf
            '__OUT_FILE__'     = $out
            '__MARKER_LOG__'   = $mark
            '__SCRIPT_DIR__'   = $vendorDir
            '__CMM_DIR__'      = $cmmDir
            '__PARAM_THREAD__' = $Thread
        }
        $body = Expand ((@($f.body) -join "`r`n")) $map
        $text = Expand (Read-Utf8 $tmpl) ($map + @{ '__FUNC_BODY__' = $body })
        $left = [regex]::Matches($text, '__[A-Z_]+__')
        if ($left.Count -gt 0) { throw ('unexpanded placeholder(s) in ' + $f.name + ': ' + (($left | ForEach-Object { $_.Value }) -join ', ')) }
        $entry = Join-Path $localDir ('func_' + $f.name + '.cmm')
        Write-Latin1 $entry $text

        Kill-T32
        $proc = Start-Process -FilePath $t32 -ArgumentList @('-c', ('"' + $cfg + '"'), '-s', ('"' + $entry + '"')) -WorkingDirectory $vendorDir -PassThru
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            $timedOut = $true
            Get-Process -Name 't32*' -ErrorAction SilentlyContinue | Stop-Process -Force
        } else { $rc = $proc.ExitCode }
        Get-Process -Name 't32*' -ErrorAction SilentlyContinue | Stop-Process -Force
        if ($timedOut -and $f.safe -eq $false) { $note = 'TIMEOUT after ' + $TimeoutSec + 's - this IS the measured hang, not a runner bug' }
        elseif ($timedOut) { $note = 'TIMEOUT after ' + $TimeoutSec + 's' }
    }
    $sw.Stop()
    $sec = [math]::Round($sw.Elapsed.TotalSeconds, 1)

    $lines = 0
    if (Test-Path -LiteralPath $out) { $lines = @(Get-Content -LiteralPath $out -Encoding Default).Count }
    $mk = @()
    if (Test-Path -LiteralPath $mark) { $mk = @(Get-Content -LiteralPath $mark) }

    $ok = $false
    if ($f.kind -eq 'python') {
        $ok = ($rc -eq 0) -and ($lines -gt 0)
    } else {
        # 期望的 marker 存放于 tests\smoke\func.markers（数据在 tests\，逻辑在此处）
        $need = @(Get-Content -LiteralPath (Join-Path $here 'tests\smoke\func.markers') |
                  Where-Object { $_ -and -not $_.TrimStart().StartsWith('#') } | ForEach-Object { $_.Trim() })
        $mkText = if (Test-Path -LiteralPath $mark) { Get-Content -LiteralPath $mark -Raw } else { '' }
        $missMk = @($need | Where-Object { $mkText -notmatch ('(?m)^' + [regex]::Escape($_)) })
        $ok = ($rc -eq 0) -and (-not $timedOut) -and ($lines -gt 0) -and ($missMk.Count -eq 0)
        if (-not $ok -and $missMk.Count -gt 0) { $note = ('markers missing: ' + ($missMk -join ', ')) }
    }

    $rows += [pscustomobject]@{ name=$f.name; kind=$f.kind; exit=$rc; sec=$sec; lines=$lines; ok=$ok; note=$note; out=$out }
    $tag = if ($ok) { '[PASS]' } else { '[FAIL]' }
    Write-Host ('{0,-14} {1,-7} exit={2,-5} {3,6}s lines={4,-6} {5} {6}' -f $f.name, $f.kind, $rc, $sec, $lines, $tag, $note)
}

# ---- 溯源信息 --------------------------------------------------------------
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('case        : 2211 AP death scene - single-function headless runs')
[void]$sb.AppendLine('stamp       : ' + $stamp)
[void]$sb.AppendLine('ramdump     : ' + $RamdumpDir)
[void]$sb.AppendLine('engine      : third_party\vendor\2210_trace32 (customer originals) + cli\2211_ap_func.cmm.tmpl')
[void]$sb.AppendLine('registry    : cmm\functions.json')
[void]$sb.AppendLine('thread_arg  : ' + $Thread)
[void]$sb.AppendLine('config      : ' + $cfg)
[void]$sb.AppendLine('t32         : ' + $t32)
[void]$sb.AppendLine('t32_cwd     : ' + $vendorDir)
[void]$sb.AppendLine('timeout_sec : ' + $TimeoutSec)
[void]$sb.AppendLine('')
foreach ($r in $rows) {
    [void]$sb.AppendLine(('func {0,-14} kind={1,-7} exit={2,-5} sec={3,-6} lines={4,-6} ok={5,-6} {6}' -f $r.name, $r.kind, $r.exit, $r.sec, $r.lines, $r.ok, $r.out))
}
[System.IO.File]::WriteAllText((Join-Path $runDir 'run.txt'), $sb.ToString(), [System.Text.Encoding]::ASCII)

$bad = @($rows | Where-Object { -not $_.ok })
Write-Host ''
if (@($bad).Count -eq 0) {
    Write-Host ('FUNC-ALL-OK (' + @($rows).Count + ' functions)') -ForegroundColor Green
    exit 0
} else {
    Write-Host ('FUNC-FAILED: ' + ((@($bad) | ForEach-Object { $_.name }) -join ', ')) -ForegroundColor Red
    exit 1
}
