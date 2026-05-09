# ------------------------------------------------------------
# build_opencv_windows.ps1
# 参数化版本：接受 -TargetArch 参数 (如 x64, x86, arm64)
# ------------------------------------------------------------
param(
    [string]$TargetArch = "x64"
)

$ErrorActionPreference = "Stop"

Write-Host "============================================================"
Write-Host "STARTING BUILD FOR ARCHITECTURE: $TargetArch"
Write-Host "============================================================"

# ============================================================
# 1. 环境变量与路径配置
# ============================================================

$OPENCV_VERSION = if ($env:OPENCV_VERSION) { $env:OPENCV_VERSION } else { "4.10.0" }
$OPENCVSHARP_REF = if ($env:OPENCVSHARP_REF) { $env:OPENCVSHARP_REF } else { "352c778e2034a05b42d0b472a7930aef47147b14" }
$BUILD_LIST = if ($env:BUILD_LIST) { $env:BUILD_LIST } else { "core,imgproc,videoio" }
$YY_THUNKS_VERSION = if ($env:YY_THUNKS_VERSION) { $env:YY_THUNKS_VERSION } else { "v1.2.1" }

# ── Win7 兼容: x64/x86 链接 YY-Thunks Win7 obj + /SUBSYSTEM:6.1/5.1 + /MT 静态 MSVC ──
# arm64 不需 (Win10+ ARM 起没 Win7 ARM)
$YyThunksObj = $null
if ($TargetArch -in @('x64','x86')) {
    $yyArch = $TargetArch
    $yyZip = Join-Path (Get-Location) "yy-thunks.zip"
    $yyDir = Join-Path (Get-Location) "yy-thunks"
    Invoke-WebRequest -Uri "https://github.com/Chuyu-Team/YY-Thunks/releases/download/$YY_THUNKS_VERSION/YY-Thunks-Objs.zip" `
        -OutFile $yyZip -UseBasicParsing
    Expand-Archive $yyZip -DestinationPath $yyDir -Force
    $YyThunksObj = Join-Path $yyDir "objs\$yyArch\YY_Thunks_for_Win7.obj"
    if (-not (Test-Path $YyThunksObj)) { throw "YY-Thunks obj not found: $YyThunksObj" }
    Write-Host ">>> Win7 compat: linking $YyThunksObj"
}

# ── 强制使用 pip cmake (>=3.28,<4): cmake 4.x 在 ARM64 + ASM target 有 MSVC_RUNTIME_LIBRARY 抽象 bug
#    (跟 MNN workflow 同样的 fix)。OpenCvSharpExtern 不直接编 ASM, 但对齐稳妥。
python -m pip install --quiet "cmake>=3.28,<4"
$pipCmake = python -c "import sysconfig, os; p=os.path.join(sysconfig.get_path('scripts'),'cmake.exe'); print(p if os.path.exists(p) else '')"
$pipCmake = ($pipCmake | Out-String).Trim()
if ($pipCmake -and (Test-Path $pipCmake)) {
    $env:PATH = "$(Split-Path $pipCmake -Parent);$env:PATH"
    Write-Host ">>> Using pip cmake: $pipCmake"
}

# 使用当前位置作为根目录
$ROOT = Join-Path (Get-Location) "_work"
$SRC = Join-Path $ROOT "src"

# 使用参数动态生成目录，实现隔离
$B_DIR = Join-Path $ROOT "build-win-$TargetArch"
$OUT_DIR = Join-Path $ROOT "out-win-$TargetArch"

# 确保目录存在
New-Item -ItemType Directory -Force -Path $SRC | Out-Null
New-Item -ItemType Directory -Force -Path $B_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $OUT_DIR | Out-Null

# 准备 Python 脚本用的路径（统一替换为 / 防止转义问题）
$SRC_SLASH = $SRC.Replace("\", "/")
$B_DIR_SLASH = $B_DIR.Replace("\", "/")
$OUT_DIR_SLASH = $OUT_DIR.Replace("\", "/")

Write-Host "==> Tool versions"
cmake --version
ninja --version
python --version

# ============================================================
# 2. 拉取源码
# ============================================================

function Clone-Or-Update($url, $dir, $ref) {
    if (-not (Test-Path (Join-Path $dir ".git"))) {
        Write-Host "Cloning $url to $dir..."
        git clone --depth 1 $url $dir
    }
    Write-Host "Fetching $ref for $dir..."
    Push-Location $dir
    try {
        git fetch --all --tags --prune
        git checkout $ref
    }
    finally {
        Pop-Location
    }
}


Write-Host "==> Fetch sources"
Clone-Or-Update "https://github.com/opencv/opencv.git"         (Join-Path $SRC "opencv")         $OPENCV_VERSION
Clone-Or-Update "https://github.com/opencv/opencv_contrib.git" (Join-Path $SRC "opencv_contrib") $OPENCV_VERSION
Clone-Or-Update "https://github.com/shimat/opencvsharp.git"    (Join-Path $SRC "opencvsharp")    $OPENCVSHARP_REF


# ============================================================
# 3. Patch OpenCvSharpExtern (逻辑大修: 顺序修复)
# ============================================================

Write-Host "==> Patch OpenCvSharpExtern CMakeLists to minimal sources"

$pyScriptPatchCMake = @"
import pathlib, re

src_path = pathlib.Path(r'$SRC_SLASH')
cmake = src_path / 'opencvsharp' / 'src' / 'OpenCvSharpExtern' / 'CMakeLists.txt'
text = cmake.read_text(encoding='utf-8', errors='ignore')


# [Step A] 直接注释掉原有的 ocv_target_compile_definitions 防止报错
# 因为原文件通常把这个调用放在 add_library 之前，如果直接改成 target_compile_definitions 会报 target not found

text = text.replace('ocv_target_compile_definitions', '# ocv_target_compile_definitions')

# [Step B] 寻找并替换 add_library 部分
# 在 add_library 之后显式追加 target_compile_definitions

pattern = re.compile(r'add_library\s*\(\s*OpenCvSharpExtern\s+SHARED\s+.*?\)\s*', re.S)
m = pattern.search(text)

if not m:
    print('WARNING: Cannot find add_library target to patch.')
else:
    # 注意: 这里我们在 add_library 闭合括号后面，手动加上了 if(MSVC)...
    minimal = '''add_library(OpenCvSharpExtern SHARED
    core.cpp
    imgproc.cpp
    videoio.cpp
)


if(MSVC)
    target_compile_definitions(OpenCvSharpExtern PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()
'''
    text2 = text[:m.start()] + minimal + text[m.end():]
    cmake.write_text(text2, encoding='utf-8')
    print(f'Patched: {cmake}')
"@

$pyScriptPatchCMake | python -

# ============================================================
# 4. 编译 OpenCV Static
# ============================================================

Write-Host "==> Build OpenCV static (Windows $TargetArch)"

$SRC_OPENCV = "$SRC_SLASH/opencv"
$SRC_CONTRIB = "$SRC_SLASH/opencv_contrib/modules"
$BUILD_OPENCV = "$B_DIR_SLASH/opencv"

# ── ARM64 特殊处理 ──────────────────────────────────────
# OpenCV 4.10 的 CPU dispatch 默认会编 SSE2/SSE3/AVX 路径并尝试 include emmintrin.h。
# MSVC 14.44+ (2026 年 4 月起) 严格了 emmintrin.h 的架构检查,导致 ARM64 编译时
# emmintrin.h fatal error C1189。
# 修法:CPU_BASELINE=NEON,CPU_DISPATCH 留空,告诉 OpenCV 只编 NEON 路径,
#       不要尝试任何 x86 SIMD dispatch。
$CpuArgs = @()
if ($TargetArch -eq "arm64") {
  $CpuArgs += "-D CPU_BASELINE=NEON"
  $CpuArgs += "-D CPU_DISPATCH="
  Write-Host ">>> ARM64 build: CPU_BASELINE=NEON, no x86 SIMD dispatch"
}

# ── Win7 兼容档 (x64/x86) 用 /MT 静态 CRT, arm64 默认 /MD ──
# 用 cmake 标准 CMAKE_MSVC_RUNTIME_LIBRARY (CMP0091 NEW) 全局 propagate, 所有 OpenCV target
# (含 opencv_core/imgcodecs 子库 + 3rd_party libpng/IlmImf 等) 一致用 /MT。
# OpenCV 的 BUILD_WITH_STATIC_CRT 是 OpenCV 自定义 option, 不一定 propagate 到所有 target,
# 实测会有 LNK2038 mismatch (子库 /MD vs OpenCvSharpExtern /MT)。
$StaticCrt = if ($TargetArch -in @('x64','x86')) { 'ON' } else { 'OFF' }
$RuntimeLibOpenCV = if ($TargetArch -in @('x64','x86')) { 'MultiThreaded' } else { 'MultiThreadedDLL' }

cmake -S "$SRC_OPENCV" -B "$BUILD_OPENCV" -G "Ninja" `
  -D CMAKE_BUILD_TYPE=Release `
  -D CMAKE_POLICY_DEFAULT_CMP0091=NEW `
  -D CMAKE_MSVC_RUNTIME_LIBRARY=$RuntimeLibOpenCV `
  -D OPENCV_EXTRA_MODULES_PATH="$SRC_CONTRIB" `
  -D BUILD_SHARED_LIBS=OFF `
  -D BUILD_WITH_STATIC_CRT=$StaticCrt `
  -D BUILD_LIST="$BUILD_LIST" `
  -D BUILD_TESTS=OFF -D BUILD_PERF_TESTS=OFF -D BUILD_EXAMPLES=OFF -D BUILD_DOCS=OFF -D BUILD_opencv_apps=OFF `
  -D OPENCV_FORCE_3RDPARTY_BUILD=ON `
  -D WITH_FFMPEG=OFF `
  -D WITH_GSTREAMER=OFF `
  -D WITH_MSMF=ON `
  -D WITH_DSHOW=ON `
  -D WITH_OPENCL=OFF `
  -D WITH_TBB=OFF `
  -D WITH_IPP=OFF `
  -D WITH_OPENMP=OFF `
  -D WITH_HDF5=OFF `
  -D WITH_FREETYPE=OFF `
  -D WITH_HARFBUZZ=OFF `
  -D WITH_WEBP=OFF `
  -D WITH_OPENJPEG=OFF `
  -D WITH_JASPER=OFF `
  -D WITH_GPHOTO2=OFF `
  -D WITH_1394=OFF `
  -D VIDEOIO_ENABLE_PLUGINS=OFF `
  $CpuArgs


ninja -C "$BUILD_OPENCV"


# ============================================================
# 5. 自动过滤 include_opencv.h
# ============================================================
Write-Host "==> Auto-filter include_opencv.h based on compile include roots"

$pyScriptFilterHeader = @"
import pathlib, re

opencv_root = pathlib.Path(r'$SRC_OPENCV')
opencv_include = opencv_root / 'include'
modules_root = opencv_root / 'modules'

build_list_str = r'$BUILD_LIST'
build_list = build_list_str.split(',')
module_includes = [modules_root / m / 'include' for m in build_list if (modules_root / m / 'include').exists()]

include_roots = [opencv_include] + module_includes

src_path = pathlib.Path(r'$SRC_SLASH')
hdr = src_path / 'opencvsharp' / 'src' / 'OpenCvSharpExtern' / 'include_opencv.h'
lines = hdr.read_text(encoding='utf-8', errors='ignore').splitlines()

pat = re.compile(r'^\s*#\s*include\s*<([^>]+)>\s*$')

def visible_header_exists(rel):
    for root in include_roots:
        if (root / rel).exists():
            return True
    return False

out = []
disabled = 0
for line in lines:
    m = pat.match(line)
    if not m:
        out.append(line)
        continue
    inc = m.group(1).strip()
    if inc.startswith('opencv2/') and not visible_header_exists(inc):
        out.append('// [auto-disabled] ' + line)
        disabled += 1
    else:
        out.append(line)

hdr.write_text('\n'.join(out) + '\n', encoding='utf-8')
print(f'include_opencv.h filtered: disabled {disabled} includes')
"@

$pyScriptFilterHeader | python -

# ============================================================
# 6. 编译 OpenCvSharpExtern DLL
# ============================================================

Write-Host "==> Build OpenCvSharpExtern (Windows $TargetArch)"

$SRC_SHARP = "$SRC_SLASH/opencvsharp/src"
$BUILD_SHARP = "$B_DIR_SLASH/opencvsharp"
$INSTALL_PREFIX = "$OUT_DIR_SLASH"

# ── Win7 兼容档 (x64/x86): /MT + YY-Thunks + /SUBSYSTEM:6.1 (x64) / 5.1 (x86) ──
# arm64: /MD, 无 SUBSYSTEM 强制 (Win10+ ARM)
$RuntimeLib = if ($TargetArch -in @('x64','x86')) { 'MultiThreaded' } else { 'MultiThreadedDLL' }
$ExtraLinker = ''
if ($TargetArch -eq 'x64') {
    $ExtraLinker = "`"$YyThunksObj`" /SUBSYSTEM:WINDOWS,6.1 /ENTRY:DllMainCRTStartupForYY_Thunks /alternatename:YY_ThunksOriginalDllMainCRTStartup=_DllMainCRTStartup"
} elseif ($TargetArch -eq 'x86') {
    $ExtraLinker = "`"$YyThunksObj`" /SUBSYSTEM:WINDOWS,5.1 /ENTRY:DllMainCRTStartupForYY_Thunks /alternatename:_YY_ThunksOriginalDllMainCRTStartup@12=__DllMainCRTStartup@12"
}

$cmakeArgs = @(
    '-S', "$SRC_SHARP", '-B', "$BUILD_SHARP", '-G', 'Ninja',
    '-DCMAKE_BUILD_TYPE=Release',
    "-DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX",
    '-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
    '-DCMAKE_POLICY_DEFAULT_CMP0091=NEW',
    "-DCMAKE_MSVC_RUNTIME_LIBRARY=$RuntimeLib",
    "-DOpenCV_DIR=$BUILD_OPENCV"
)
if ($ExtraLinker) {
    $cmakeArgs += "-DCMAKE_SHARED_LINKER_FLAGS=$ExtraLinker"
}
& cmake @cmakeArgs

ninja -C "$BUILD_SHARP"
ninja -C "$BUILD_SHARP" install

# ============================================================
# 7. 收集产物
# ============================================================

$FINAL_DIR = Join-Path $OUT_DIR "final"
New-Item -ItemType Directory -Force -Path $FINAL_DIR | Out-Null
$DllSource = Get-ChildItem -Path $OUT_DIR -Filter "OpenCvSharpExtern.dll" -Recurse | Select-Object -First 1

if (-not $DllSource) {
    Write-Host "ERROR: OpenCvSharpExtern.dll not found in $OUT_DIR"
    exit 1
}

Write-Host "Found DLL: $($DllSource.FullName)"
Copy-Item -Path $DllSource.FullName -Destination $FINAL_DIR -Force

Write-Host "==> Done: $FINAL_DIR\OpenCvSharpExtern.dll"
