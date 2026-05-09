# =====================================================================
# build_mnn_windows.ps1
#
# 用环境变量驱动的 MNN Windows 构建脚本。被 workflow 调用,3 个 RID 复用同一脚本。
#
# 输入环境变量:
#   BUILD_TYPE       Release / RelWithDebInfo
#   MNN_SOURCE       MNN 源码绝对路径 (workflow checkout 出的 ./MNN)
#   OUT_DIR          产物输出目录 (会被创建/清空)
#   RID              .NET RID: win-x64 / win-x86 / win-arm64
#   ARCH             cmake/vcvars arch tag: x64 / x86 / arm64
#   YY_THUNKS_OBJ    Win7 兼容用 YY-Thunks obj 绝对路径 (仅 win-x64/win-x86)
#
# 设计要点 (对齐 bench/MNN_BUILD_MATRIX.md §3):
#   - x64/x86: 链接 YY-Thunks Win7 obj + /SUBSYSTEM:6.1(x64)/5.1(x86) + /MT 静态 MSVC
#   - arm64:   不需 YY-Thunks (Win10+ 才有 ARM Win), MNN_ARM82 + KleidiAI
#   - OpenCL:  MNN_USE_SYSTEM_LIB=OFF 让 MNN dlopen OpenCL.dll, build 时不找 OpenCL SDK
# =====================================================================

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# ── 输入校验 ──────────────────────────────────────────────────────────
foreach ($var in @('BUILD_TYPE','MNN_SOURCE','OUT_DIR','RID','ARCH')) {
    if (-not (Get-Item -Path "env:$var" -ErrorAction SilentlyContinue)) {
        throw "Missing required env var: $var"
    }
}
$BUILD_TYPE   = $env:BUILD_TYPE
$MNN_SOURCE   = $env:MNN_SOURCE
$OUT_DIR      = $env:OUT_DIR
$RID          = $env:RID
$ARCH         = $env:ARCH
$YY_THUNKS_OBJ= $env:YY_THUNKS_OBJ

Write-Host "================================================================"
Write-Host "  MNN Windows Build"
Write-Host "  RID:        $RID"
Write-Host "  Arch:       $ARCH"
Write-Host "  BuildType:  $BUILD_TYPE"
Write-Host "  Source:     $MNN_SOURCE"
Write-Host "  Out:        $OUT_DIR"
Write-Host "  YY-Thunks:  $YY_THUNKS_OBJ"
Write-Host "================================================================"

if (-not (Test-Path $MNN_SOURCE)) { throw "MNN source not found: $MNN_SOURCE" }
$null = New-Item -ItemType Directory -Force -Path $OUT_DIR

$buildDir = Join-Path (Split-Path $MNN_SOURCE -Parent) "build-mnn-$RID"
if (Test-Path $buildDir) { Remove-Item -Recurse -Force $buildDir }
$null = New-Item -ItemType Directory -Force -Path $buildDir

# ── 1. 加载对应 arch 的 VS 2022 开发者环境 ──────────────────────────
# GitHub windows-2022 runner 预装 VS 2022 Enterprise; windows-11-arm 装 Enterprise (ARM64 host)。
# vcvarsall.bat 接受 arch tag: x64 / x86 / arm64 (host=arch when host=arch),
# windows-11-arm 上要用 arm64 (native) 或 amd64_arm64 (cross from x64 host).
$vsRoots = @(
  'C:\Program Files\Microsoft Visual Studio\2022\Enterprise',
  'C:\Program Files\Microsoft Visual Studio\2022\Community',
  'C:\Program Files\Microsoft Visual Studio\2022\Professional',
  'C:\Program Files\Microsoft Visual Studio\2022\BuildTools'
)
$vcvarsall = $null
foreach ($r in $vsRoots) {
    $cand = Join-Path $r 'VC\Auxiliary\Build\vcvarsall.bat'
    if (Test-Path $cand) { $vcvarsall = $cand; break }
}
if (-not $vcvarsall) { throw "vcvarsall.bat not found under VS 2022 install" }
Write-Host ">>> vcvarsall: $vcvarsall"

# 在 cmd.exe 里调 vcvarsall + dump env, 再回 PS 注入到当前 process env。
# 这是 MS 推荐的跨 shell 加载 VS dev env 方法。
$tmp = New-TemporaryFile
& cmd.exe /c "`"$vcvarsall`" $ARCH && set" 2>&1 | Out-File -FilePath $tmp -Encoding ascii
if ($LASTEXITCODE -ne 0) {
    Get-Content $tmp
    throw "vcvarsall.bat failed for arch=$ARCH"
}
Get-Content $tmp | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($matches[1])" -Value $matches[2] }
}
Remove-Item $tmp -Force
Write-Host ">>> VS env loaded for arch=$ARCH (cl.exe = $((Get-Command cl.exe -ErrorAction SilentlyContinue).Source))"

# ── 2. 组装 cmake 参数 ───────────────────────────────────────────────
# 公共参数 (所有 RID 共用)
$cmakeCommon = @(
    '-G', 'Ninja',
    "-DCMAKE_BUILD_TYPE=$BUILD_TYPE",
    '-DMNN_BUILD_SHARED_LIBS=ON',
    '-DMNN_WIN_RUNTIME_MT=ON',
    '-DMNN_OPENCL=ON',
    '-DMNN_USE_SYSTEM_LIB=OFF',
    '-DMNN_BUILD_TOOLS=ON',
    '-DMNN_BUILD_TEST=OFF',
    '-DMNN_BUILD_DEMO=OFF',
    '-DMNN_BUILD_BENCHMARK=OFF',
    '-DMNN_BUILD_CONVERTER=OFF'
)

# Per-arch SIMD + Win7 linker flags
$cmakeArchExtra = @()
$linkerSharedExtra = ''
$linkerExeExtra = ''

switch ($ARCH) {
    'x64' {
        $cmakeArchExtra += @('-DMNN_AVX2=ON', '-DMNN_USE_SSE=ON')
        if (-not $YY_THUNKS_OBJ -or -not (Test-Path $YY_THUNKS_OBJ)) {
            throw "YY_THUNKS_OBJ env missing or file not found: $YY_THUNKS_OBJ"
        }
        # /SUBSYSTEM:WINDOWS,6.1 → PE 标 Win7+
        # /ENTRY + /alternatename: YY-Thunks 自定义 DLL 入口处理 thread_local 在 Win7 的初始化
        $linkerSharedExtra = "`"$YY_THUNKS_OBJ`" /SUBSYSTEM:WINDOWS,6.1 /ENTRY:DllMainCRTStartupForYY_Thunks /alternatename:YY_ThunksOriginalDllMainCRTStartup=_DllMainCRTStartup"
        $linkerExeExtra    = "`"$YY_THUNKS_OBJ`" /SUBSYSTEM:CONSOLE,6.1"
    }
    'x86' {
        $cmakeArchExtra += @('-DMNN_USE_SSE=ON', '-DMNN_AVX2=OFF')
        if (-not $YY_THUNKS_OBJ -or -not (Test-Path $YY_THUNKS_OBJ)) {
            throw "YY_THUNKS_OBJ env missing or file not found: $YY_THUNKS_OBJ"
        }
        # x86: /SUBSYSTEM:5.1 (XP/Win7 通用), 32-bit C 名字含 @stdcall 后缀
        $linkerSharedExtra = "`"$YY_THUNKS_OBJ`" /SUBSYSTEM:WINDOWS,5.1 /ENTRY:DllMainCRTStartupForYY_Thunks /alternatename:_YY_ThunksOriginalDllMainCRTStartup@12=__DllMainCRTStartup@12"
        $linkerExeExtra    = "`"$YY_THUNKS_OBJ`" /SUBSYSTEM:CONSOLE,5.1"
    }
    'arm64' {
        # Win10 ARM 起才有 Win on ARM, 不需要 YY-Thunks; 启用 ARM82 + KleidiAI fp16 加速
        $cmakeArchExtra += @('-DMNN_ARM82=ON', '-DMNN_KLEIDIAI=ON')
        # 不强制 SUBSYSTEM (Win10 ARM64 默认 10.0)
    }
    default { throw "Unsupported ARCH: $ARCH" }
}

if ($linkerSharedExtra) { $cmakeArchExtra += "-DCMAKE_SHARED_LINKER_FLAGS=$linkerSharedExtra" }
if ($linkerExeExtra)    { $cmakeArchExtra += "-DCMAKE_EXE_LINKER_FLAGS=$linkerExeExtra" }

# ── 3. Configure ─────────────────────────────────────────────────────
Push-Location $buildDir
try {
    Write-Host ">>> cmake configure (RID=$RID)"
    $allCmakeArgs = $cmakeCommon + $cmakeArchExtra + @($MNN_SOURCE)
    Write-Host "    $($allCmakeArgs -join ' ')"
    & cmake @allCmakeArgs
    if ($LASTEXITCODE -ne 0) { throw "cmake configure failed: $LASTEXITCODE" }

    # ── 4. Build ─────────────────────────────────────────────────────
    Write-Host ">>> ninja (RID=$RID)"
    & ninja
    if ($LASTEXITCODE -ne 0) { throw "ninja build failed: $LASTEXITCODE" }
}
finally {
    Pop-Location
}

# ── 5. 收产物 ────────────────────────────────────────────────────────
$mnnDll = Join-Path $buildDir 'MNN.dll'
if (-not (Test-Path $mnnDll)) {
    Write-Host "::error::MNN.dll not produced at $mnnDll"
    Get-ChildItem $buildDir -Filter '*.dll' -Recurse | Select-Object FullName, Length
    throw "MNN.dll missing"
}
Copy-Item $mnnDll $OUT_DIR -Force
$mnnLib = Join-Path $buildDir 'MNN.lib'
if (Test-Path $mnnLib) { Copy-Item $mnnLib $OUT_DIR -Force }

# Tools (sanity 用,不是分发主产物;有 .exe 就拷,免得空跑 smoke test)
foreach ($exe in @('MNNV2Basic.out.exe', 'GetMNNInfo.exe')) {
    $p = Join-Path $buildDir $exe
    if (Test-Path $p) { Copy-Item $p $OUT_DIR -Force }
}

# 复制 PDB (RelWithDebInfo)
if ($BUILD_TYPE -eq 'RelWithDebInfo') {
    Get-ChildItem $buildDir -Filter 'MNN*.pdb' -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-Item $_.FullName $OUT_DIR -Force }
}

# ── 6. 验证 PE subsystem version (Win7 兼容性硬指标) ─────────────────
if ($ARCH -eq 'x64' -or $ARCH -eq 'x86') {
    $expectedSubsysMajor = if ($ARCH -eq 'x64') { 6 } else { 5 }
    $expectedSubsysMinor = if ($ARCH -eq 'x64') { 1 } else { 1 }
    Write-Host ">>> 校验 PE subsystem version >= $expectedSubsysMajor.0$expectedSubsysMinor (Win7=6.01, XP=5.01)"
    $dumpbinOut = & dumpbin /headers (Join-Path $OUT_DIR 'MNN.dll') 2>&1 | Out-String
    if ($dumpbinOut -match 'subsystem version\s+(\d+)\.(\d+)') {
        $actualMaj = [int]$matches[1]
        $actualMin = [int]$matches[2]
        Write-Host "    实际 subsystem: $actualMaj.$($actualMin.ToString('00'))"
        if ($actualMaj -gt $expectedSubsysMajor -or ($actualMaj -eq $expectedSubsysMajor -and $actualMin -gt $expectedSubsysMinor)) {
            throw "PE subsystem 版本 $actualMaj.$actualMin 高于预期 $expectedSubsysMajor.$expectedSubsysMinor — Win7 不兼容!"
        }
        Write-Host "    ✅ subsystem 版本符合 Win7 兼容要求"
    } else {
        Write-Host "::warning::dumpbin /headers 未输出 subsystem version 行,跳过校验"
    }
}

Write-Host ""
Write-Host ">>> Artifacts in $OUT_DIR :"
Get-ChildItem $OUT_DIR | Format-Table Name, Length -AutoSize
Write-Host "✅ MNN Windows build done: $RID"
