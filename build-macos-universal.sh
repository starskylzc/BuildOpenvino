#!/usr/bin/env bash
set -euxo pipefail

OPENCV_VERSION="4.7.0"
OPENCVSHARP_TAG="4.7.0.20230224"

ROOT="$(pwd)"
WORK="$ROOT/_work"
OUT="$ROOT/out/macos"
rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"

# Apple Silicon runner 上为了顺利构建 x86_64，确保 Rosetta 可用
if [[ "$(uname -m)" == "arm64" ]]; then
  /usr/sbin/softwareupdate --install-rosetta --agree-to-license || true
fi

brew update
brew install cmake ninja

cd "$WORK"
git clone --depth 1 --branch "${OPENCV_VERSION}" https://github.com/opencv/opencv.git
git clone --depth 1 --branch "${OPENCVSHARP_TAG}" https://github.com/shimat/opencvsharp.git

# ---- Patch: 解决 CMake 新版本不再兼容 <3.5 的 cmake_minimum_required ----
# 同时也给后续 cmake 命令加 -DCMAKE_POLICY_VERSION_MINIMUM=3.5 双保险
python3 - <<'PY'
import pathlib, re
root = pathlib.Path("opencvsharp")
for p in root.rglob("CMakeLists.txt"):
    t = p.read_text(encoding="utf-8", errors="ignore")
    nt = re.sub(r"cmake_minimum_required\s*\(\s*VERSION\s+[0-9.]+\s*\)",
                "cmake_minimum_required(VERSION 3.5)", t)
    if nt != t:
        p.write_text(nt, encoding="utf-8")
PY

build_one() {
  local ARCH="$1"          # x86_64 / arm64
  local DEPLOY="$2"        # 10.15 / 11.0
  local OPENCV_INSTALL="$WORK/install-opencv-$ARCH"
  local OPENCV_BUILD="$WORK/build-opencv-$ARCH"
  local EXTERN_BUILD="$WORK/build-extern-$ARCH"

  rm -rf "$OPENCV_BUILD" "$OPENCV_INSTALL" "$EXTERN_BUILD"
  mkdir -p "$OPENCV_BUILD" "$OPENCV_INSTALL" "$EXTERN_BUILD"

  # ---- Build OpenCV (STATIC, minimal modules) ----
  cmake -S "$WORK/opencv" -B "$OPENCV_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$OPENCV_INSTALL" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_LIST=core,imgproc,videoio \
    -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOCS=OFF \
    -DBUILD_opencv_apps=OFF \
    -DWITH_OPENCL=OFF -DWITH_IPP=OFF -DWITH_TBB=OFF -DWITH_OPENMP=OFF \
    -DWITH_FFMPEG=OFF -DWITH_GSTREAMER=OFF -DWITH_1394=OFF -DWITH_GPHOTO2=OFF \
    -DWITH_FREETYPE=OFF -DWITH_HARFBUZZ=OFF -DWITH_HDF5=OFF -DWITH_WEBP=OFF

  cmake --build "$OPENCV_BUILD" --target install

  # ---- Build OpenCvSharpExtern (shared, link static OpenCV) ----
  cmake -S "$WORK/opencvsharp/src" -B "$EXTERN_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DOpenCV_DIR="$OPENCV_INSTALL/lib/cmake/opencv4"

  cmake --build "$EXTERN_BUILD" --target OpenCvSharpExtern

  # 产物名一般是 libOpenCvSharpExtern.dylib
  local DYLIB
  DYLIB="$(find "$EXTERN_BUILD" -maxdepth 3 -name "libOpenCvSharpExtern.dylib" -print -quit)"
  test -f "$DYLIB"

  cp -f "$DYLIB" "$OUT/libOpenCvSharpExtern.$ARCH.dylib"

  echo "=== otool -L ($ARCH) ==="
  otool -L "$OUT/libOpenCvSharpExtern.$ARCH.dylib" || true
}

build_one "x86_64" "10.15"
build_one "arm64"  "11.0"

# ---- Lipo to universal ----
lipo -create \
  "$OUT/libOpenCvSharpExtern.x86_64.dylib" \
  "$OUT/libOpenCvSharpExtern.arm64.dylib" \
  -output "$OUT/libOpenCvSharpExtern.dylib"

echo "=== lipo info ==="
lipo -info "$OUT/libOpenCvSharpExtern.dylib"

# 收敛输出
rm -f "$OUT/libOpenCvSharpExtern.x86_64.dylib" "$OUT/libOpenCvSharpExtern.arm64.dylib"
