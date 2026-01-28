#!/usr/bin/env bash
set -euo pipefail

# 用法：
#   build_macos_slice.sh x86_64 10.15
#   build_macos_slice.sh arm64  11.0
ARCH="$1"
DEPLOY="$2"

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
# Auto-filter include_opencv.h:
#   - Keep opencv2 headers that exist in your trimmed OpenCV tree
#   - Comment out includes that do NOT exist (e.g. highgui, shape, etc.)
# This avoids "file not found" without guessing what's needed.
# ------------------------------------------------------------
echo "==> Auto-filter include_opencv.h based on existing OpenCV headers"

python3 - <<PY
import pathlib, re

opencv_inc = pathlib.Path(r"$SRC/opencv") / "include" / "opencv2"
contrib_inc = pathlib.Path(r"$SRC/opencv_contrib") / "modules"
hdr = pathlib.Path(r"$SRC/opencvsharp") / "src" / "OpenCvSharpExtern" / "include_opencv.h"

text = hdr.read_text(encoding="utf-8", errors="ignore").splitlines()

def header_exists(rel: str) -> bool:
    # rel: like opencv2/shape.hpp or opencv2/highgui/highgui_c.h
    if not rel.startswith("opencv2/"):
        return True
    p = rel[len("opencv2/"):]
    # main opencv include
    if (opencv_inc / p).exists():
        return True
    # contrib headers can be under modules/<name>/include/opencv2/...
    # We'll search quickly for the exact tail path under contrib modules.
    for m in contrib_inc.glob("*"):
        cand = m / "include" / "opencv2" / p
        if cand.exists():
            return True
    return False

out = []
changed = 0

pat = re.compile(r'^\s*#\s*include\s*<([^>]+)>\s*$')
for line in text:
    m = pat.match(line)
    if not m:
        out.append(line)
        continue
    inc = m.group(1).strip()
    if inc.startswith("opencv2/") and not header_exists(inc):
        out.append("// [auto-disabled missing header] " + line)
        changed += 1
    else:
        out.append(line)

hdr.write_text("\n".join(out) + "\n", encoding="utf-8")
print(f"Filtered include_opencv.h: disabled {changed} missing includes")
PY

# ------------------------------------------------------------
# Build OpenCvSharpExtern
#   - Use OpenCV BUILD TREE (fixes missing installed 3rdparty .a like libprotobuf)
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
