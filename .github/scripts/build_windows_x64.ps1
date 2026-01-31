# ------------------------------------------------------------
# build_windows_x64.ps1 (实际支持 x64, x86, ARM64)
# ------------------------------------------------------------
$ErrorActionPreference = "Stop"

# ============================================================
# 1. 环境变量与路径配置
# ============================================================
$OPENCV_VERSION = if ($env:OPENCV_VERSION) { $env:OPENCV_VERSION } else { "4.11.0" }
$OPENCVSHARP_REF = if ($env:OPENCVSHARP_REF) { $env:OPENCVSHARP_REF } else { "main" }
$BUILD_LIST = if ($env:BUILD_LIST) { $env:BUILD_LIST } else { "core,imgproc,videoio" }

# 使用当前位置作为根目录
$ROOT = Join-Path (Get-Location) "_work"
$SRC = Join-Path $ROOT "src"

# 确保源码目录存在
New-Item -ItemType Directory -Force -Path $SRC | Out-Null

# 准备 Python 脚本用的路径
$SRC_SLASH = $SRC.Replace("\", "/")

Write-Host "==> Tool versions"
cmake --version
python --version

# ============================================================
# 2. 拉取源码 (只拉一次，全架构共用)
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
# 3. Patch OpenCvSharpExtern (逻辑保持不变)
# ============================================================
Write-Host "==> Patch OpenCvSharpExtern CMakeLists to minimal sources"

$pyScriptPatchCMake = @"
import pathlib, re

src_path = pathlib.Path(r'$SRC_SLASH')
cmake = src_path / 'opencvsharp' / 'src' / 'OpenCvSharpExtern' / 'CMakeLists.txt'
text = cmake.read_text(encoding='utf-8', errors='ignore')

# [Step A] 直接注释掉原有的 ocv_target_compile_definitions 防止报错
text = text.replace('ocv_target_compile_definitions', '# ocv_target_compile_definitions')

# [Step B] 寻找并替换 add_library 部分
pattern = re.compile(r'add_library\s*\(\s*OpenCvSharpExtern\s+SHARED\s+.*?\)\s*', re.S)
m = pattern.search(text)

if not m:
    print('WARNING: Cannot find add_library target to patch.')
else:
    # 保持原有补丁逻辑
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
# 4. 自动过滤 include_opencv.h (逻辑保持不变)
# ============================================================
Write-Host "==> Auto-filter include_opencv.h based on compile include roots"

$SRC_OPENCV = "$SRC_SLASH/opencv"

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
# 5. 多架构构建循环 (核心修改部分)
# ============================================================
$ARCH_LIST = "x64", "x86", "arm64"

foreach ($ARCH_NAME in $ARCH_LIST) {
    # 映射 PowerShell 架构名到 CMake VS Generator 的 -A 参数
    $CMAKE_ARCH_FLAG = $ARCH_NAME
    if ($ARCH_NAME -eq "x86") { $CMAKE_ARCH_FLAG = "Win32" }
    if ($ARCH_NAME -eq "arm64") { $CMAKE_ARCH_FLAG = "ARM64" }
    if ($ARCH_NAME -eq "x64") { $CMAKE_ARCH_FLAG = "x64" }

    Write-Host "`n============================================================"
    Write-Host "STARTING BUILD FOR: $ARCH_NAME (CMake: $CMAKE_ARCH_FLAG)"
    Write-Host "============================================================"

    # 动态定义构建和输出目录，防止冲突
    $B_DIR = Join-Path $ROOT "build-win-$ARCH_NAME"
    $OUT_DIR = Join-Path $ROOT "out-win-$ARCH_NAME"

    New-Item -ItemType Directory -Force -Path $B_DIR | Out-Null
    New-Item -ItemType Directory -Force -Path $OUT_DIR | Out-Null

    $B_DIR_SLASH = $B_DIR.Replace("\", "/")
    $OUT_DIR_SLASH = $OUT_DIR.Replace("\", "/")

    # ------------------------------------------------------------
    # A. 编译 OpenCV Static
    # ------------------------------------------------------------
    Write-Host "==> [$ARCH_NAME] Build OpenCV static"

    $SRC_CONTRIB = "$SRC_SLASH/opencv_contrib/modules"
    $BUILD_OPENCV = "$B_DIR_SLASH/opencv"

    # [CHANGE] 必须使用 Visual Studio 生成器来支持多架构。
    # Ninja 依赖外部环境变量，无法在脚本内自由切换 x86/ARM64。
    cmake -S "$SRC_OPENCV" -B "$BUILD_OPENCV" -G "Visual Studio 17 2022" -A "$CMAKE_ARCH_FLAG" `
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

    # 替换 Ninja 命令
    cmake --build "$BUILD_OPENCV" --config Release --parallel

    # ------------------------------------------------------------
    # B. 编译 OpenCvSharpExtern DLL
    # ------------------------------------------------------------
    Write-Host "==> [$ARCH_NAME] Build OpenCvSharpExtern"

    $SRC_SHARP = "$SRC_SLASH/opencvsharp/src"
    $BUILD_SHARP = "$B_DIR_SLASH/opencvsharp"
    $INSTALL_PREFIX = "$OUT_DIR_SLASH"

    # [FIX] 关键修复:
    # 1. 之前你用 Ninja + ilammy，环境默认匹配。
    # 2. 现在用 VS 生成器，OpenCvSharp 默认可能是静态 CRT (/MT)。
    # 3. OpenCV 之前指定了 BUILD_WITH_STATIC_CRT=OFF (/MD)。
    # 4. 必须添加 CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL 强制 OpenCvSharp 也用 /MD，否则报 LNK2038。
    cmake -S "$SRC_SHARP" -B "$BUILD_SHARP" -G "Visual Studio 17 2022" -A "$CMAKE_ARCH_FLAG" `
      -D CMAKE_BUILD_TYPE=Release `
      -D CMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" `
      -D CMAKE_POLICY_VERSION_MINIMUM=3.5 `
      -D CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL `
      -D OpenCV_DIR="$BUILD_OPENCV"

    cmake --build "$BUILD_SHARP" --config Release --parallel
    cmake --build "$BUILD_SHARP" --config Release --target install

    # ------------------------------------------------------------
    # C. 收集产物
    # ------------------------------------------------------------
    # 最终目录结构: _work/final/x64, _work/final/x86, _work/final/arm64
    $FINAL_DIR = Join-Path $ROOT "final" $ARCH_NAME
    New-Item -ItemType Directory -Force -Path $FINAL_DIR | Out-Null

    # VS 生成的 DLL 可能在 Release 子目录下，扩大搜索范围
    $DllSource = Get-ChildItem -Path "$OUT_DIR", "$BUILD_SHARP" -Filter "OpenCvSharpExtern.dll" -Recurse | Select-Object -First 1

    if (-not $DllSource) {
        Write-Host "ERROR: OpenCvSharpExtern.dll not found for $ARCH_NAME"
        exit 1
    }

    Write-Host "Found DLL: $($DllSource.FullName)"
    Copy-Item -Path $DllSource.FullName -Destination $FINAL_DIR -Force
    Write-Host "==> [$ARCH_NAME] Copied to $FINAL_DIR"
}

Write-Host "`nAll builds completed successfully."
