#!/usr/bin/env bash
set -euo pipefail

# 用法：
#   build_macos_slice.sh x86_64 10.15
#   build_macos_slice.sh arm64  11.0
ARCH="$1"
DEPLOY="$2"

OPENCV_VERSION="${OPENCV_VERSION:-4.11.0}"
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
# Patch OpenCvSharpExtern to build only what you use:
#   - core.cpp, imgproc.cpp, videoio.cpp
# ------------------------------------------------------------
echo "==> Patch OpenCvSharpExtern CMakeLists to minimal sources (core/imgproc/videoio)"
python3 - <<PY
import pathlib, re

cmake = pathlib.Path(r"$SRC/opencvsharp") / "src" / "OpenCvSharpExtern" / "CMakeLists.txt"
text = cmake.read_text(encoding="utf-8", errors="ignore")

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
# Build OpenCV (STATIC, minimal modules, minimize deps)
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
# Auto-filter include_opencv.h based on *actual compile include roots*,
# NOT based on opencv_contrib source tree.
#
# Compile include roots (matching what your compiler uses):
#   - $SRC/opencv/include
#   - $SRC/opencv/modules/<module>/include   (only for modules in BUILD_LIST)
#
# Anything else (e.g. opencv_contrib headers like opencv2/shape.hpp)
# must be commented out, otherwise compilation fails.
# ------------------------------------------------------------
echo "==> Auto-filter include_opencv.h based on compile include roots"

python3 - <<PY
import pathlib, re

opencv_root = pathlib.Path(r"$SRC/opencv")
opencv_include = opencv_root / "include"
modules_root = opencv_root / "modules"

build_list = r"$BUILD_LIST".split(",")
module_includes = [modules_root / m / "include" for m in build_list if (modules_root / m / "include").exists()]

# Only these roots are considered "visible" to the compiler in your build.
include_roots = [opencv_include] + module_includes

hdr = pathlib.Path(r"$SRC/opencvsharp") / "src" / "OpenCvSharpExtern" / "include_opencv.h"
lines = hdr.read_text(encoding="utf-8", errors="ignore").splitlines()

pat = re.compile(r'^\s*#\s*include\s*<([^>]+)>\s*$')

def visible_header_exists(rel: str) -> bool:
    # rel like "opencv2/shape.hpp"
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
    # only filter opencv2/*
    if inc.startswith("opencv2/") and not visible_header_exists(inc):
        out.append("// [auto-disabled not in include roots] " + line)
        disabled += 1
    else:
        out.append(line)

hdr.write_text("\n".join(out) + "\n", encoding="utf-8")
print(f"include_opencv.h filtered: disabled {disabled} includes")
print("Include roots:")
for r in include_roots:
    print("  -", r)
PY

# ------------------------------------------------------------
# Build OpenCvSharpExtern
#   - Use OpenCV BUILD TREE to avoid missing installed 3rdparty .a
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
