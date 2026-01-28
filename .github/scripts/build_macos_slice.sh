#!/usr/bin/env bash
set -euo pipefail

# 用法：
#   build_macos_slice.sh x86_64 10.15
#   build_macos_slice.sh arm64  11.0
ARCH="$1"
DEPLOY="$2"

# 可通过 workflow 传入覆盖
OPENCV_VERSION="${OPENCV_VERSION:-4.10.0}"
OPENCVSHARP_REF="${OPENCVSHARP_REF:-main}"
BUILD_LIST="${BUILD_LIST:-core,imgproc,videoio}"

ROOT="${GITHUB_WORKSPACE:-$(pwd)}/_work"
SRC="$ROOT/src"
B="$ROOT/build-$ARCH"
OUT="$ROOT/out-$ARCH"

mkdir -p "$SRC" "$B" "$OUT"

echo "==> Tool versions"
cmake --version || true
ninja --version || true
clang --version || true

clone_or_update() {
  local url="$1"
  local dir="$2"
  local ref="$3"
  if [[ ! -d "$dir/.git" ]]; then
    git clone --depth 1 "$url" "$dir"
  fi
  git -C "$dir" fetch --all --tags --prune
  git -C "$dir" checkout "$ref"
}

echo "==> Fetch sources"
clone_or_update "https://github.com/opencv/opencv.git"         "$SRC/opencv"         "$OPENCV_VERSION"
clone_or_update "https://github.com/opencv/opencv_contrib.git" "$SRC/opencv_contrib" "$OPENCV_VERSION"
clone_or_update "https://github.com/shimat/opencvsharp.git"    "$SRC/opencvsharp"    "$OPENCVSHARP_REF"

# ------------------------------------------------------------
# Patch OpenCvSharpExtern to be minimal: only core/imgproc/videoio wrappers
# and remove dependency on highgui headers (since we won't build highgui).
# ------------------------------------------------------------
echo "==> Patch OpenCvSharpExtern for minimal build (core,imgproc,videoio) and remove highgui include"

# 1) 注释掉 highgui_c.h 的 include（否则 OpenCV 裁剪掉 highgui 后必然找不到该头文件）
INCLUDE_H="$SRC/opencvsharp/src/OpenCvSharpExtern/include_opencv.h"
if [[ -f "$INCLUDE_H" ]]; then
  # macOS sed 需要 -i ''
  sed -i '' 's@^[[:space:]]*#include[[:space:]]*<opencv2/highgui/highgui_c.h>@// #include <opencv2/highgui/highgui_c.h>@' "$INCLUDE_H" || true
fi

# 2) 裁剪 OpenCvSharpExtern/CMakeLists.txt：只编译 core.cpp imgproc.cpp videoio.cpp
python3 - <<PY
import pathlib, re

cmake = pathlib.Path(r"$SRC/opencvsharp") / "src" / "OpenCvSharpExtern" / "CMakeLists.txt"
text = cmake.read_text(encoding="utf-8", errors="ignore")

# 找到 add_library(OpenCvSharpExtern SHARED ... ) 块并替换为最小源文件列表
pattern = re.compile(r"add_library\s*\(\s*OpenCvSharpExtern\s+SHARED\s+.*?\)\s*", re.S)
m = pattern.search(text)
if not m:
    raise SystemExit("Cannot find add_library(OpenCvSharpExtern SHARED ...) in OpenCvSharpExtern/CMakeLists.txt")

minimal = """add_library(OpenCvSharpExtern SHARED
    core.cpp
    imgproc.cpp
    videoio.cpp
)

"""
text2 = text[:m.start()] + minimal + text[m.end():]
cmake.write_text(text2, encoding="utf-8")
print("Patched:", cmake)
PY

# ------------------------------------------------------------
# 1) Build OpenCV (STATIC, minimal modules, minimize deps)
# ------------------------------------------------------------
echo "==> Build OpenCV static ($ARCH, macOS >= $DEPLOY)"
cmake -S "$SRC/opencv" -B "$B/opencv" -G Ninja \
  -D CMAKE_BUILD_TYPE=Release \
  -D CMAKE_OSX_ARCHITECTURES="$ARCH" \
  -D CMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY" \
  -D OPENCV_EXTRA_MODULES_PATH="$SRC/opencv_contrib/modules" \
  -D BUILD_SHARED_LIBS=OFF \
  -D BUILD_LIST="$BUILD_LIST" \
  -D BUILD_TESTS=OFF -D BUILD_PERF_TESTS=OFF -D BUILD_EXAMPLES=OFF -D BUILD_DOCS=OFF -D BUILD_opencv_apps=OFF \
  -D OPENCV_FORCE_3RDPARTY_BUILD=ON \
  \
  -D WITH_FFMPEG=OFF \
  -D WITH_GSTREAMER=OFF \
  -D WITH_OPENCL=OFF \
  -D WITH_TBB=OFF \
  -D WITH_IPP=OFF \
  -D WITH_OPENMP=OFF \
  -D WITH_HDF5=OFF \
  -D WITH_FREETYPE=OFF \
  -D WITH_HARFBUZZ=OFF \
  -D WITH_WEBP=OFF \
  -D WITH_OPENJPEG=OFF \
  -D WITH_JASPER=OFF \
  -D WITH_GPHOTO2=OFF \
  -D WITH_1394=OFF \
  -D WITH_AVFOUNDATION=ON \
  -D VIDEOIO_ENABLE_PLUGINS=OFF

ninja -C "$B/opencv"

# ------------------------------------------------------------
# 2) Build OpenCvSharpExtern
#    IMPORTANT:
#      - Use OpenCV BUILD TREE to avoid missing installed 3rdparty .a (e.g. libprotobuf)
# ------------------------------------------------------------
echo "==> Build OpenCvSharpExtern ($ARCH)"
cmake -S "$SRC/opencvsharp/src" -B "$B/opencvsharp" -G Ninja \
  -D CMAKE_BUILD_TYPE=Release \
  -D CMAKE_INSTALL_PREFIX="$OUT" \
  -D CMAKE_OSX_ARCHITECTURES="$ARCH" \
  -D CMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY" \
  -D CMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -D OpenCV_DIR="$B/opencv"

ninja -C "$B/opencvsharp"
ninja -C "$B/opencvsharp" install

DYLIB="$(find "$OUT" -name "libOpenCvSharpExtern.dylib" -print -quit)"
if [[ -z "${DYLIB:-}" ]]; then
  echo "ERROR: libOpenCvSharpExtern.dylib not found"
  exit 1
fi

mkdir -p "$OUT/final"
cp -f "$DYLIB" "$OUT/final/libOpenCvSharpExtern.dylib"

echo "==> Verify deps ($ARCH)"
lipo -info "$OUT/final/libOpenCvSharpExtern.dylib" || true
otool -L "$OUT/final/libOpenCvSharpExtern.dylib" || true

echo "==> Done slice: $OUT/final/libOpenCvSharpExtern.dylib"
