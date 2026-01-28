#!/usr/bin/env bash
set -euo pipefail

# 用法：
#   build_macos_slice.sh x86_64 10.15
#   build_macos_slice.sh arm64  11.0
ARCH="$1"
DEPLOY="$2"

OPENCV_VERSION="${OPENCV_VERSION:-4.10.0}"        # OpenCvSharp README 里目标 OpenCV 是 4.10.0（可按你需要改）:contentReference[oaicite:5]{index=5}
OPENCVSHARP_REF="${OPENCVSHARP_REF:-main}"        # 也可以换成某个 tag
BUILD_LIST="${BUILD_LIST:-core,imgproc,videoio}"

ROOT="${GITHUB_WORKSPACE:-$(pwd)}/_work"
SRC="$ROOT/src"
B="$ROOT/build-$ARCH"
I="$ROOT/install-$ARCH"
OUT="$ROOT/out-$ARCH"

mkdir -p "$SRC" "$B" "$I" "$OUT"

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

echo "==> Build OpenCV static ($ARCH, macOS >= $DEPLOY)"
cmake -S "$SRC/opencv" -B "$B/opencv" -G Ninja \
  -D CMAKE_BUILD_TYPE=Release \
  -D CMAKE_INSTALL_PREFIX="$I/opencv" \
  -D CMAKE_OSX_ARCHITECTURES="$ARCH" \
  -D CMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY" \
  -D OPENCV_EXTRA_MODULES_PATH="$SRC/opencv_contrib/modules" \
  -D BUILD_SHARED_LIBS=OFF \
  -D BUILD_LIST="$BUILD_LIST" \
  -D BUILD_TESTS=OFF -D BUILD_PERF_TESTS=OFF -D BUILD_EXAMPLES=OFF -D BUILD_DOCS=OFF -D BUILD_opencv_apps=OFF \
  -D WITH_FFMPEG=OFF -D WITH_GSTREAMER=OFF \
  -D WITH_OPENCL=OFF -D WITH_TBB=OFF -D WITH_IPP=OFF \
  -D WITH_OPENGL=OFF -D WITH_QT=OFF \
  -D VIDEOIO_ENABLE_PLUGINS=OFF

ninja -C "$B/opencv"
ninja -C "$B/opencv" install

echo "==> Build OpenCvSharpExtern ($ARCH)"
# OpenCvSharp 运行需要 native binding（OpenCvSharpExtern）:contentReference[oaicite:6]{index=6}
cmake -S "$SRC/opencvsharp/src" -B "$B/opencvsharp" -G Ninja \
  -D CMAKE_BUILD_TYPE=Release \
  -D CMAKE_INSTALL_PREFIX="$OUT" \
  -D CMAKE_OSX_ARCHITECTURES="$ARCH" \
  -D CMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY" \
  -D CMAKE_PREFIX_PATH="$I/opencv" \
  -D OpenCV_DIR="$I/opencv/lib/cmake/opencv4"

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
