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

$OPENCV_VERSION = if ($env:OPENCV_VERSION) { $env:OPENCV_VERSION } else { "4.11.0" }
$OPENCVSHARP_REF = if ($env:OPENCVSHARP_REF) { $env:OPENCVSHARP_REF } else { "main" }
$BUILD_LIST = if ($env:BUILD_LIST) { $env:BUILD_LIST } else { "core,imgproc,videoio" }


# 使用当前位置作为根目录
$ROOT = Join-Path (Get-Location) "_work"
$SRC = Join-Path $ROOT "src"

# [关键修复] 彻底清理构建目录，防止 CMakeCache 残留导致架构识别错误
if (Test-Path $B_DIR) {
    Write-Host "Cleaning existing build directory: $B_DIR"
    Remove-Item -Path $B_DIR -Recurse -Force
}
if (Test-Path $OUT_DIR) {
    Write-Host "Cleaning existing output directory: $OUT_DIR"
    Remove-Item -Path $OUT_DIR -Recurse -Force
}

# 创建新目录
New-Item -ItemType Directory -Force -Path $SRC | Out-Null
New-Item -ItemType Directory -Force -Path $B_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $OUT_DIR | Out-Null

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
# [关键修复] 针对 ARM64 定义交叉编译参数
# 这会告诉 CMake 不要尝试运行(try_run)生成的二进制文件，防止在 x64 机器上报错或静默失败
$EXTRA_OPENCV_ARGS = @()
if ($TargetArch -eq "arm64") {
    Write-Host "--> Detected ARM64: Enabling CMake Cross-Compiling Mode & Disabling x86 intrinsics" 
    
    # 1. 基础交叉编译标识
    $EXTRA_OPENCV_ARGS += "-D", "CMAKE_SYSTEM_NAME=Windows"
    $EXTRA_OPENCV_ARGS += "-D", "CMAKE_SYSTEM_PROCESSOR=ARM64"
    
    # 2. 彻底禁用 x86 指令集 (关键修复)
    $EXTRA_OPENCV_ARGS += "-D", "CPU_BASELINE=NEON" # 强制基准为 NEON
    $EXTRA_OPENCV_ARGS += "-D", "CPU_DISPATCH="     # 禁用额外的指令集调度
    $EXTRA_OPENCV_ARGS += "-D", "ENABLE_SSE=OFF"
    $EXTRA_OPENCV_ARGS += "-D", "ENABLE_SSE2=OFF"
    $EXTRA_OPENCV_ARGS += "-D", "ENABLE_SSE3=OFF"
    $EXTRA_OPENCV_ARGS += "-D", "ENABLE_AVX=OFF"
    $EXTRA_OPENCV_ARGS += "-D", "ENABLE_AVX2=OFF"
    
    # 3. 禁用可能包含内联 x86 汇编的模块
    # MSMF (Media Foundation) 和 DSHOW (DirectShow) 在旧版 OpenCV 中对 ARM64 支持可能不完善
    # 如果不需要摄像头功能，建议关闭。如果需要，先尝试关闭看是否解决编译错误。
    $EXTRA_OPENCV_ARGS += "-D", "WITH_MSMF=OFF"
    $EXTRA_OPENCV_ARGS += "-D", "WITH_DSHOW=OFF"
}
cmake -S "$SRC_OPENCV" -B "$BUILD_OPENCV" -G "Ninja" `
  -D CMAKE_BUILD_TYPE=Release `
  -D OPENCV_EXTRA_MODULES_PATH="$SRC_CONTRIB" `
  -D BUILD_SHARED_LIBS=OFF `
  -D BUILD_WITH_STATIC_CRT=OFF `
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
  -D VIDEOIO_ENABLE_PLUGINS=OFF


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
# [关键修复] 针对 ARM64 定义交叉编译参数
# 这会告诉 CMake 不要尝试运行(try_run)生成的二进制文件，防止在 x64 机器上报错或静默失败
$EXTRA_OPENCV_ARGS = @()
if ($TargetArch -eq "arm64") {
    Write-Host "--> Detected ARM64: Enabling CMake Cross-Compiling Mode & Disabling x86 intrinsics" 
    
    # 1. 基础交叉编译标识
    $EXTRA_OPENCV_ARGS += "-D", "CMAKE_SYSTEM_NAME=Windows"
    $EXTRA_OPENCV_ARGS += "-D", "CMAKE_SYSTEM_PROCESSOR=ARM64"
    
    # 2. 彻底禁用 x86 指令集 (关键修复)
    $EXTRA_OPENCV_ARGS += "-D", "CPU_BASELINE=NEON" # 强制基准为 NEON
    $EXTRA_OPENCV_ARGS += "-D", "CPU_DISPATCH="     # 禁用额外的指令集调度
    $EXTRA_OPENCV_ARGS += "-D", "ENABLE_SSE=OFF"
    $EXTRA_OPENCV_ARGS += "-D", "ENABLE_SSE2=OFF"
    $EXTRA_OPENCV_ARGS += "-D", "ENABLE_SSE3=OFF"
    $EXTRA_OPENCV_ARGS += "-D", "ENABLE_AVX=OFF"
    $EXTRA_OPENCV_ARGS += "-D", "ENABLE_AVX2=OFF"
    
    # 3. 禁用可能包含内联 x86 汇编的模块
    # MSMF (Media Foundation) 和 DSHOW (DirectShow) 在旧版 OpenCV 中对 ARM64 支持可能不完善
    # 如果不需要摄像头功能，建议关闭。如果需要，先尝试关闭看是否解决编译错误。
    $EXTRA_OPENCV_ARGS += "-D", "WITH_MSMF=OFF"
    $EXTRA_OPENCV_ARGS += "-D", "WITH_DSHOW=OFF"
}
cmake -S "$SRC_SHARP" -B "$BUILD_SHARP" -G "Ninja" `
  -D CMAKE_BUILD_TYPE=Release `
  -D CMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" `
  -D CMAKE_POLICY_VERSION_MINIMUM=3.5 `
  -D CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL `
  -D OpenCV_DIR="$BUILD_OPENCV"

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
