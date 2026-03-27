# smoke_test_windows.ps1
# OpenCvSharpExtern 冒烟测试（Windows）
#
# 用法：
#   pwsh -File smoke_test_windows.ps1 -LibPath "C:\path\to\OpenCvSharpExtern.dll"
#
# 测试内容：
#   1. 静态检查：用 dumpbin /exports 验证关键导出符号存在
#   2. 运行时：用 PowerShell Add-Type P/Invoke 实际调用 core_Mat_sizeof()
#              返回值应为正整数（cv::Mat 的 sizeof，通常 96~200 字节）

param(
    [Parameter(Mandatory=$true)]
    [string]$LibPath
)

$ErrorActionPreference = "Stop"

$REQUIRED_SYMBOLS = @(
    "core_Mat_sizeof",
    "core_Mat_new1",
    "imgproc_resize",
    "videoio_VideoCapture_new1"
)

# ── 辅助函数 ──────────────────────────────────────────────────
function Write-Header($text) {
    Write-Host "── $text $('─' * (48 - $text.Length))"
}

function Exit-Fail($msg) {
    Write-Host ""
    Write-Host "❌  测试失败：$msg"
    exit 1
}

# ── 基本检查 ──────────────────────────────────────────────────
$LibPath = [System.IO.Path]::GetFullPath($LibPath)
if (-not (Test-Path $LibPath)) {
    Exit-Fail "文件不存在: $LibPath"
}

$fileSize = (Get-Item $LibPath).Length
Write-Host ""
Write-Host "===================================================="
Write-Host "  OpenCvSharpExtern 冒烟测试"
Write-Host "  文件: $LibPath"
Write-Host "  大小: $("{0:N0}" -f $fileSize) bytes"
Write-Host "===================================================="
Write-Host ""

# ── 1. 静态符号检查（dumpbin /exports）────────────────────────
Write-Header "符号检查 (dumpbin /exports)"

try {
    $exports = & dumpbin /exports "$LibPath" 2>&1 | Out-String
} catch {
    Exit-Fail "dumpbin 执行失败（需要 MSVC 环境）: $_"
}

$allSymOk = $true
foreach ($sym in $REQUIRED_SYMBOLS) {
    if ($exports -match [regex]::Escape($sym)) {
        Write-Host "  ✓  $sym"
    } else {
        Write-Host "  ✗  $sym  ← 缺失！"
        $allSymOk = $false
    }
}

Write-Host ""

# ── 2. 运行时测试（P/Invoke）──────────────────────────────────
Write-Header "运行时测试 (P/Invoke)"

# 动态注册 P/Invoke，指向实际 DLL 路径
# 注意：Add-Type 的 DllImport 路径在编译时固定，需要先把 DLL 所在目录加入 PATH
$dllDir = [System.IO.Path]::GetDirectoryName($LibPath)
$env:PATH = "$dllDir;$env:PATH"

$pinvokeCode = @"
using System;
using System.Runtime.InteropServices;

public static class OpenCvExternSmoke {
    [DllImport("OpenCvSharpExtern.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern UIntPtr core_Mat_sizeof();

    [DllImport("OpenCvSharpExtern.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int core_Mat_new1(out IntPtr outPtr);
}
"@

try {
    Add-Type -TypeDefinition $pinvokeCode -Language CSharp
} catch {
    Exit-Fail "Add-Type 编译失败: $_"
}

# 调用 core_Mat_sizeof()
try {
    $matSize = [OpenCvExternSmoke]::core_Mat_sizeof().ToUInt64()
    Write-Host "  core_Mat_sizeof()  = $matSize bytes"
    if ($matSize -le 0) {
        Exit-Fail "core_Mat_sizeof 返回值应为正整数"
    }
    Write-Host "  ✓  core_Mat_sizeof 调用成功"
} catch {
    Exit-Fail "core_Mat_sizeof 调用异常: $_"
}

# 调用 core_Mat_new1()
try {
    $outPtr = [IntPtr]::Zero
    $ret = [OpenCvExternSmoke]::core_Mat_new1([ref]$outPtr)
    Write-Host "  ✓  core_Mat_new1 调用成功（ret=$ret, ptr=$outPtr）"
} catch {
    Exit-Fail "core_Mat_new1 调用异常: $_"
}

Write-Host ""

# ── 最终结果 ──────────────────────────────────────────────────
if (-not $allSymOk) {
    Exit-Fail "部分导出符号缺失，请检查编译配置"
}

Write-Host "✅  所有测试通过"
exit 0
