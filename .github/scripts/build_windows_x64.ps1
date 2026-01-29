# ------------------------------------------------------------
# build_windows_x64.ps1
# ------------------------------------------------------------
$ErrorActionPreference = "Stop"

# 1. 接收/设置环境变量
$OPENCV_VERSION = if ($env:OPENCV_VERSION) { $env:OPENCV_VERSION } else { "4.11.0" }
$OPENCVSHARP_REF = if ($env:OPENCVSHARP_REF) { $env:OPENCVSHARP_REF } else { "main" }
# 默认只编译这些模块
$BUILD_LIST = if ($env:BUILD_LIST) { $env:BUILD_LIST } else { "core,imgproc,videoio" }

# 定义路径 (转换为绝对路径)
$ROOT = Join-Path (Get-Location) "_work"
$SRC = Join-Path $ROOT "src"
$B_DIR = Join-Path $ROOT "build-win-x64"
$OUT_DIR = Join-Path $ROOT "out-win-x64"

# 创建目录
New-Item -ItemType Directory -Force -Path $SRC | Out-Null
New-Item -ItemType Directory -Force -Path $B_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $OUT_DIR | Out-Null

Write-Host "==> Tool versions"
cmake --version
ninja --version
python --version

# ------------------------------------------------------------
# 辅助函数: Clone 或 Update
# ------------------------------------------------------------
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
Clone-Or-Update "https://github.com/opencv/opencv.git" (Join-Path $SRC "opencv") $OPENCV_VERSION
Clone-Or-Update "https://github.com/opencv/opencv_contrib.git" (Join-Path $SRC "opencv_contrib") $OPENCV_VERSION
Clone-Or-Update "https://github.com/shimat/opencvsharp.git" (Join-Path $SRC "opencvsharp") $OPENCVSHARP_REF

# ------------------------------------------------------------
# 2. Patch OpenCvSharpExtern CMakeLists
#    只编译 core.cpp, imgproc.cpp, videoio.cpp
# ------------------------------------------------------------
Write-Host "==> Patch OpenCvSharpExtern CMakeLists to minimal sources"

$pyScriptPatchCMake = @"
import pathlib, re, os

# 注意 Windows 路径处理
src_path = pathlib.Path(r'$SRC')
cmake = src_path / 'opencvsharp' / 'src' / 'OpenCvSharpExtern' / 'CMakeLists.txt'
text = cmake.read_text(encoding='utf-8', errors='ignore')

pattern = re.compile(r'add_library\s*\(\s*OpenCvSharpExtern\s+SHARED\s+.*?\)\s*', re.S)
m = pattern.search(text)
if not m:
    print('WARNING: Cannot find add_library target to patch. Content check needed.')
else:
    minimal = '''add_library(OpenCvSharpExtern SHARED
    core.cpp
    imgproc.cpp
    videoio.cpp
)

'''
    text2 = text[:m.start()] + minimal + text[m.end():]
    cmake.write_text(text2, encoding='utf-8')
    print(f'Patched: {cmake}')
"@

# 执行 Python 脚本
$pyScriptPatchCMake | python -

# ------------------------------------------------------------
# 3. Build OpenCV (STATIC, Minimal)
# ------------------------------------------------------------
Write-Host "==> Build OpenCV static (Windows x64)"

# 转换路径为 CMake 友好的格式 (Forward Slashes)
$SRC_OPENCV = (Join-Path $SRC "opencv").Replace("\", "/")
$SRC_CONTRIB = (Join-Path $SRC "opencv_contrib/modules").Replace("\", "/")
$BUILD_OPENCV = (Join-Path $B_DIR "opencv").Replace("\", "/")

# Windows 特有的配置:
# - BUILD_WITH_STATIC_CRT=OFF: 确保使用 /MD (即便是静态库)，这样才能链接到 C# 的 DLL
# - WITH_MSMF=ON / WITH_DSHOW=ON: 启用 Windows 摄像头支持
# - WITH_VTK=OFF / WITH_CUDA=OFF: 彻底禁用不需要的庞大依赖
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
  -D WITH_WEBP=OFF `
  -D WITH_OPENJPEG=OFF `
  -D WITH_JASPER=OFF `
  -D WITH_GPHOTO2=OFF `
  -D WITH_1394=OFF `
  -D VIDEOIO_ENABLE_PLUGINS=OFF

ninja -C "$BUILD_OPENCV"

# ------------------------------------------------------------
# 4. Auto-filter include_opencv.h
#    注释掉不存在的头文件，防止编译报错
# ------------------------------------------------------------
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

# OpenCvSharpExtern 路径
src_path = pathlib.Path(r'$SRC')
hdr = src_path / 'opencvsharp' / 'src' / 'OpenCvSharpExtern' / 'include_opencv.h'
lines = hdr.read_text(encoding='utf-8', errors='ignore').splitlines()

pat = re.compile(r'^\s*#\s*include\s*<([^>]+)>\s*$')

def visible_header_exists(rel):
    # rel like 'opencv2/shape.hpp'
    for root in include_roots:
        target = root / rel
        if target.exists():
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
    # only filter opencv2/*
    if inc.startswith('opencv2/') and not visible_header_exists(inc):
        out.append('// [auto-disabled] ' + line)
        disabled += 1
    else:
        out.append(line)

hdr.write_text('\n'.join(out) + '\n', encoding='utf-8')
print(f'include_opencv.h filtered: disabled {disabled} includes')
"@

$pyScriptFilterHeader | python -

# ------------------------------------------------------------
# 5. Build OpenCvSharpExtern (DLL)
# ------------------------------------------------------------
Write-Host "==> Build OpenCvSharpExtern (Windows x64)"

$SRC_SHARP = (Join-Path $SRC "opencvsharp/src").Replace("\", "/")
$BUILD_SHARP = (Join-Path $B_DIR "opencvsharp").Replace("\", "/")
$INSTALL_PREFIX = $OUT_DIR.Replace("\", "/")

# 注意: OpenCV_DIR 指向刚才编译 OpenCV 的 build 目录 (那里有 OpenCVConfig.cmake)
cmake -S "$SRC_SHARP" -B "$BUILD_SHARP" -G "Ninja" `
  -D CMAKE_BUILD_TYPE=Release `
  -D CMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" `
  -D OpenCV_DIR="$BUILD_OPENCV"

ninja -C "$BUILD_SHARP"
# 即使是 DLL，Windows 下通常不需要 "make install" 这种步骤来拿 .dll，
# 但 OpenCvSharp CMake 可能会有 install target。
ninja -C "$BUILD_SHARP" install

# ------------------------------------------------------------
# 6. 收集 Artifact
# ------------------------------------------------------------
$FINAL_DIR = Join-Path $OUT_DIR "final"
New-Item -ItemType Directory -Force -Path $FINAL_DIR | Out-Null

# 查找生成的 DLL
# Ninja 输出位置通常在 bin 或者是根目录，视 CMakeLists 而定
$DllSource = Get-ChildItem -Path $INSTALL_PREFIX -Filter "OpenCvSharpExtern.dll" -Recurse | Select-Object -First 1

if (-not $DllSource) {
    Write-Host "ERROR: OpenCvSharpExtern.dll not found in $INSTALL_PREFIX"
    exit 1
}

Write-Host "Found DLL: $($DllSource.FullName)"
Copy-Item -Path $DllSource.FullName -Destination $FINAL_DIR -Force

Write-Host "==> Done: $FINAL_DIR\OpenCvSharpExtern.dll"
# 验证依赖 (使用 dumpbin，如果安装了 VS 工具链)
# dumpbin /dependents "$FINAL_DIR\OpenCvSharpExtern.dll"
