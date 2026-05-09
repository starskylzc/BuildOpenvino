# =====================================================================
# smoke_test_mnn_windows.ps1
# MNN MNN.dll 冒烟测试 (Windows)
#
# 用法:
#   .\smoke_test_mnn_windows.ps1 <MNN.dll 路径>
#
# 测试内容:
#   1. dumpbin /exports — 确认 MNN 命名空间符号充足 (>= 100)
#   2. dumpbin /headers — 确认 PE subsystem 版本符合预期 (Win7 兼容档 应 <= 6.01)
#   3. ctypes (Python) — 确认 dll 能 LoadLibrary 成功 (仅 host arch 匹配时跑)
# =====================================================================

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

if ($args.Count -lt 1) {
    Write-Host "::error::用法: smoke_test_mnn_windows.ps1 <MNN.dll>"
    exit 1
}
$dll = (Resolve-Path $args[0]).Path
if (-not (Test-Path $dll)) {
    Write-Host "::error::文件不存在: $dll"
    exit 1
}

Write-Host ("=" * 64)
Write-Host "  MNN 冒烟测试 (Windows)"
Write-Host "  文件: $dll"
Write-Host "  大小: $((Get-Item $dll).Length) bytes"
Write-Host ("=" * 64)

# ── 1. 导出符号检查 (dumpbin /exports) ─────────────────────────────
Write-Host "── 符号检查 (dumpbin /exports) ──────────────────────────"
$exports = & dumpbin /exports $dll 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Host "::error::dumpbin /exports failed:"
    Write-Host $exports
    exit 1
}
# Windows MSVC 的 C++ 符号 demangle 形如 "?createSession@Interpreter@MNN@@..."
# 或者 mangled "?...MNN@@" 出现在导出表里
$mnnPat = '(MNN@@|class MNN::|MNNCreate|MNNForward)'
$mnnLines = $exports -split "`n" | Select-String -Pattern $mnnPat
$mnnCount = $mnnLines.Count
$totalCount = ($exports -split "`n" | Select-String -Pattern '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+').Count
Write-Host "  导出符号总数:    $totalCount"
Write-Host "  MNN 命名:         $mnnCount"
if ($mnnCount -lt 100) {
    Write-Host "::error::MNN 符号过少,产物可能没编全 (期望 >= 100)"
    exit 1
}
Write-Host "  ✓  MNN 符号充足"

# ── 2. PE Subsystem version (Win7 兼容硬指标) ──────────────────────
Write-Host ""
Write-Host "── PE subsystem version (dumpbin /headers) ─────────────"
$headers = & dumpbin /headers $dll 2>&1 | Out-String
if ($headers -match 'subsystem version\s+(\d+)\.(\d+)') {
    $maj = [int]$matches[1]; $min = [int]$matches[2]
    Write-Host "  PE subsystem version: $maj.$($min.ToString('00'))"
    if ($maj -le 6) {
        Write-Host "  ✓  Win7 (6.01) 或更低 — Win7 兼容"
    } elseif ($maj -eq 10) {
        Write-Host "  ℹ  Win10+ (10.00) — Win7 不兼容档 (win-arm64 期望)"
    } else {
        Write-Host "::warning::非常规 subsystem $maj.$min"
    }
} else {
    Write-Host "::warning::dumpbin 未输出 subsystem version"
}

# ── 3. ctypes 加载 (仅 Python 当前 host arch 匹配时跑) ──────────────
Write-Host ""
Write-Host "── 运行时加载 (Python ctypes) ───────────────────────────"
$pyArch = & python -c "import platform; print(platform.machine().lower())" 2>$null
$pyArch = ($pyArch | Out-String).Trim()
Write-Host "  Python host arch: $pyArch"

# 推测 dll arch (从 dumpbin /headers)
$dllArch = if ($headers -match 'machine \(([^)]+)\)') { $matches[1] } else { 'unknown' }
Write-Host "  DLL machine:      $dllArch"

# 简单匹配规则
$canLoad = $false
switch -Wildcard ($dllArch.ToLower()) {
    '*x64*'   { if ($pyArch -in @('amd64','x86_64')) { $canLoad = $true } }
    '*arm64*' { if ($pyArch -in @('arm64','aarch64')) { $canLoad = $true } }
    '*x86*'   { if ($pyArch -eq 'x86') { $canLoad = $true } }
}

if ($canLoad) {
    & python -c "import ctypes; lib = ctypes.CDLL(r'$dll'); print('  ✓  ctypes.CDLL OK -> ', lib)"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "::error::ctypes.CDLL 加载失败"
        exit 1
    }
} else {
    Write-Host "  (跳过 — host arch=$pyArch 与 DLL arch=$dllArch 不匹配)"
}

Write-Host ""
Write-Host "✅  所有测试通过"
