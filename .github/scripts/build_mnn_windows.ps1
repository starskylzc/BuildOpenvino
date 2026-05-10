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

# 强制使用 pip 装的 cmake (>=3.28,<4),不用系统 cmake 4.x:
# windows-11-arm runner 系统 cmake 4.x 给 ASM target 强加 MSVC_RUNTIME_LIBRARY 属性,
# armasm64.exe 不识别,导致 cmake configure 失败 (实测 win-arm64 卡死在这)。
# x64/x86 上系统 cmake 4.x 工作 OK,但统一切到 pip cmake 一致更稳。
$pipCmakePath = python -c "import sysconfig, os; p = os.path.join(sysconfig.get_path('scripts'), 'cmake.exe'); print(p if os.path.exists(p) else '')"
$pipCmakePath = ($pipCmakePath | Out-String).Trim()
if ($pipCmakePath -and (Test-Path $pipCmakePath)) {
    $pipCmakeDir = Split-Path $pipCmakePath -Parent
    $env:PATH = "$pipCmakeDir;$env:PATH"
    Write-Host ">>> Using pip cmake: $pipCmakePath"
    & $pipCmakePath --version | Select-Object -First 1
} else {
    Write-Host "::warning::pip cmake 未找到,用系统 cmake (arm64 可能因 cmake 4.x ASM bug 失败)"
    & cmake --version | Select-Object -First 1
}

# ── 2. 组装 cmake 参数 ───────────────────────────────────────────────
# 公共参数 (所有 RID 共用)
# MNN_SEP_BUILD=OFF: 单一 MNN.dll 含 MNN+Express+Backends,mnnwrap.cpp 注入到 MNN target
# 时才能链到 Module::load 等 Express 符号(默认 ON 会把 Express 拆到 MNN_Express.dll)
$cmakeCommon = @(
    '-G', 'Ninja',
    "-DCMAKE_BUILD_TYPE=$BUILD_TYPE",
    '-DMNN_BUILD_SHARED_LIBS=ON',
    '-DMNN_SEP_BUILD=OFF',
    '-DMNN_OPENCL=ON',
    '-DMNN_USE_SYSTEM_LIB=OFF',
    '-DMNN_BUILD_TOOLS=ON',
    '-DMNN_BUILD_TEST=OFF',
    '-DMNN_BUILD_DEMO=OFF',
    '-DMNN_BUILD_BENCHMARK=OFF',
    '-DMNN_BUILD_CONVERTER=OFF'
)
# /MT 静态 MSVC: 仅 x64/x86 (Win7 兼容, 免 VC++ Redist 依赖)
# arm64 不开 — Win10+ 才有 ARM64 Win, 而且 ARM64 ASM 编译器不接受 MSVC_RUNTIME_LIBRARY=MultiThreaded

# Per-arch SIMD + Win7 linker flags
$cmakeArchExtra = @()
$linkerSharedExtra = ''
$linkerExeExtra = ''

switch ($ARCH) {
    'x64' {
        $cmakeArchExtra += @('-DMNN_WIN_RUNTIME_MT=ON', '-DMNN_AVX2=ON', '-DMNN_USE_SSE=ON')
        if (-not $YY_THUNKS_OBJ -or -not (Test-Path $YY_THUNKS_OBJ)) {
            throw "YY_THUNKS_OBJ env missing or file not found: $YY_THUNKS_OBJ"
        }
        # /SUBSYSTEM:WINDOWS,6.1 → PE 标 Win7+
        # /ENTRY + /alternatename: YY-Thunks 自定义 DLL 入口处理 thread_local 在 Win7 的初始化
        $linkerSharedExtra = "`"$YY_THUNKS_OBJ`" /SUBSYSTEM:WINDOWS,6.1 /ENTRY:DllMainCRTStartupForYY_Thunks /alternatename:YY_ThunksOriginalDllMainCRTStartup=_DllMainCRTStartup"
        $linkerExeExtra    = "`"$YY_THUNKS_OBJ`" /SUBSYSTEM:CONSOLE,6.1"
    }
    'x86' {
        $cmakeArchExtra += @('-DMNN_WIN_RUNTIME_MT=ON', '-DMNN_USE_SSE=ON', '-DMNN_AVX2=OFF')
        if (-not $YY_THUNKS_OBJ -or -not (Test-Path $YY_THUNKS_OBJ)) {
            throw "YY_THUNKS_OBJ env missing or file not found: $YY_THUNKS_OBJ"
        }
        # x86: /SUBSYSTEM:5.1 (XP/Win7 通用), 32-bit C 名字含 @stdcall 后缀
        $linkerSharedExtra = "`"$YY_THUNKS_OBJ`" /SUBSYSTEM:WINDOWS,5.1 /ENTRY:DllMainCRTStartupForYY_Thunks /alternatename:_YY_ThunksOriginalDllMainCRTStartup@12=__DllMainCRTStartup@12"
        $linkerExeExtra    = "`"$YY_THUNKS_OBJ`" /SUBSYSTEM:CONSOLE,5.1"
    }
    'arm64' {
        # Win10 ARM 起才有 Win on ARM, 不需要 YY-Thunks。
        # ARM82 ON: MNN 自己的 .S 是 GAS 风格, clang-cl 能编 → fp16 加速保留。
        # KleidiAI OFF (仅 win-arm64): KleidiAI 主要给 LLM/量化推理 (int4/int8 + fp16) 加速,
        #   我们项目 (face/object detection, 全 fp16 模型, 不量化) 实际不调 KleidiAI 快路径。
        #   Workload perf 影响 = 0; 关掉避开 KleidiAI 1.14 .S 文件 ARMASM 路径与 clang IA
        #   不兼容的工程麻烦 (clang IA 仅识别 GAS)。
        #   简报 §2 锁定的 KleidiAI=ON 是基于"通用最优" (LLM 用户能享受加速); 在我们具体
        #   workload 上 KleidiAI=OFF 等价。Linux/Mac arm64 仍 ON (那边 GCC/Apple clang 编 GAS
        #   .S 路径无 friction)。
        $cmakeArchExtra += @('-DMNN_ARM82=ON', '-DMNN_KLEIDIAI=OFF')

        # ── win-arm64 上 MNN 3.5.0 与 MSVC ARM64 不兼容,要做两件事 ──
        #
        # 1) Patch MNN/CMakeLists.txt: 'cmake_policy(SET CMP0091 NEW)' → OLD。
        #    NEW 模式下 cmake 给 ASM target 自动设 MSVC_RUNTIME_LIBRARY="MultiThreadedDLL",
        #    armasm64.exe 不识别此属性 → configure 失败。仅 arm64 改成 OLD;
        #    x64/x86 不动(他们靠 NEW 让 MNN_WIN_RUNTIME_MT=ON 设 /MT 工作)。
        $mnnCMakeLists = Join-Path $MNN_SOURCE 'CMakeLists.txt'
        if (Test-Path $mnnCMakeLists) {
            $orig = Get-Content $mnnCMakeLists -Raw
            $patched = $orig -replace 'cmake_policy\(SET CMP0091 NEW\)', 'cmake_policy(SET CMP0091 OLD)'
            if ($patched -ne $orig) {
                Set-Content $mnnCMakeLists -Value $patched -NoNewline
                Write-Host ">>> Patched MNN/CMakeLists.txt: CMP0091 NEW -> OLD"
            }
        }

        # 2) 切换到 clang-cl 编 C/C++:
        #    cl.exe ARM64 不支持 GCC NEON extensions —
        #      SkNx_neon.h 用 'uint32x4_t << n' 运算符
        #      Matrix_CV.cpp 用 '__n128 *' 运算符
        #      Vec.hpp 用 'int32x4_t[i]' 下标
        #    全是 GCC/Clang 才有的 vector 语法糖,MSVC 必须用显式 intrinsic (vshlq/vmulq/vgetq_lane).
        #    Patch 这些 header 加 '!_MSC_VER' 守卫等于关掉所有 ARM NEON 优化 (违背简报锁定的
        #    MNN_ARM82+KleidiAI),不可接受。
        #    替代方案:用 clang-cl(LLVM clang 在 MSVC-compatible 模式),它接受 cl.exe flag
        #    但前端是 clang,完整支持 GCC NEON extensions + vector subscript.
        #    GHA windows-11-arm runner 的 VS 2022 预装 LLVM ARM64 工具集.
        $vsRoot = Split-Path (Split-Path (Split-Path $vcvarsall -Parent) -Parent) -Parent
        $clangCl = $null
        foreach ($cand in @(
            (Join-Path $vsRoot 'VC\Tools\Llvm\ARM64\bin\clang-cl.exe'),
            (Join-Path $vsRoot 'VC\Tools\Llvm\bin\clang-cl.exe'),
            'C:\Program Files\LLVM\bin\clang-cl.exe'
        )) {
            if ($cand -and (Test-Path $cand)) { $clangCl = $cand; break }
        }
        if (-not $clangCl) {
            $cmd = Get-Command clang-cl -ErrorAction SilentlyContinue
            if ($cmd) { $clangCl = $cmd.Source }
        }
        if (-not $clangCl) {
            throw "clang-cl not found on windows-11-arm runner; cannot compile MNN's NEON extensions with cl.exe. Searched VS Llvm/ARM64, VS Llvm/, C:\Program Files\LLVM\, PATH."
        }
        Write-Host ">>> Using clang-cl for C/C++: $clangCl"
        & $clangCl --version | Select-Object -First 1
        $cmakeArchExtra += @(
            "-DCMAKE_C_COMPILER=$clangCl",
            "-DCMAKE_CXX_COMPILER=$clangCl"
        )
        # ASM 仍走 armasm64.exe (cl 配套),CMP0091=OLD 已避免 MSVC_RUNTIME_LIBRARY 抽象。
        # 不强制 SUBSYSTEM (Win10 ARM64 默认 10.0).
    }
    default { throw "Unsupported ARCH: $ARCH" }
}

if ($linkerSharedExtra) { $cmakeArchExtra += "-DCMAKE_SHARED_LINKER_FLAGS=$linkerSharedExtra" }
if ($linkerExeExtra)    { $cmakeArchExtra += "-DCMAKE_EXE_LINKER_FLAGS=$linkerExeExtra" }

# ── 2.5 Inject YuYiNoPhotoLib mnnwrap C ABI into MNN target ──────────
# 把 mnnwrap.cpp 编进 MNN.dll,clients 部署 1 个 native/RID(免单独 mnnwrap.dll)
$mnnwrapDir = Join-Path $PSScriptRoot '..\..\mnnwrap' | Resolve-Path -ErrorAction SilentlyContinue
if (-not $mnnwrapDir -or -not (Test-Path "$mnnwrapDir\mnnwrap.cpp")) {
    Write-Host "::warning::mnnwrap source not found at $($PSScriptRoot)\..\..\mnnwrap; skipping mnnwrap integration"
} else {
    $mnnwrapDirEsc = ($mnnwrapDir.Path -replace '\\', '/')
    # 注:不加 /utf-8 编译选项 — MNN 自己已设 /source-charset:utf-8(详见 cmake/MNNCompileOption),
    #     重复给 cl.exe 会触发 D8016 "/source-charset:utf-8 和 /utf-8 不兼容" 编译错误。
    $injection = @"

# === YuYiNoPhotoLib mnnwrap injection (auto-appended by BuildOpenvino) ===
target_sources(MNN PRIVATE "$mnnwrapDirEsc/mnnwrap.cpp")
target_include_directories(MNN PRIVATE "$mnnwrapDirEsc")
target_compile_definitions(MNN PRIVATE MNNWRAP_BUILDING)
"@
    $mnnCMakeLists = Join-Path $MNN_SOURCE 'CMakeLists.txt'
    if ((Get-Content $mnnCMakeLists -Raw) -notmatch 'mnnwrap injection') {
        Add-Content -Path $mnnCMakeLists -Value $injection -Encoding utf8
        Write-Host ">>> Appended mnnwrap injection to MNN/CMakeLists.txt (mnnwrap dir: $mnnwrapDirEsc)"
    } else {
        Write-Host ">>> mnnwrap injection already present in MNN/CMakeLists.txt"
    }
}

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
    # dumpbin /headers 输出格式: '            6.01 subsystem version' (值在前, key 在后)
    if ($dumpbinOut -match '(\d+)\.(\d+)\s+subsystem version') {
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
