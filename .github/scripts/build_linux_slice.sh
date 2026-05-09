#!/usr/bin/env bash
set -euo pipefail

# 用法：
#   build_linux_slice.sh x86_64           (在 Docker ubuntu:18.04 容器内, glibc 2.27)
#   build_linux_slice.sh aarch64          (在 Docker arm64v8/ubuntu:18.04 容器内, glibc 2.27)
#   build_linux_slice.sh loongarch64      (在 Ubuntu 24.04 host 上交叉编译, 无 docker)
ARCH="$1"

OPENCV_VERSION="${OPENCV_VERSION:-4.10.0}"
OPENCVSHARP_REF="${OPENCVSHARP_REF:-352c778e2034a05b42d0b472a7930aef47147b14}"
BUILD_LIST="${BUILD_LIST:-core,imgproc,videoio}"

# loongarch64: 不在 docker 内, 走交叉编译 (ubuntu 24.04 host 装 gcc-13-loongarch64-linux-gnu)
CROSS_COMPILE=""
[ "$ARCH" = "loongarch64" ] && CROSS_COMPILE="loongarch64"

# ------------------------------------------------------------
# 工作目录
# ------------------------------------------------------------
ROOT="${GITHUB_WORKSPACE:-$(pwd)}/_work"
SRC="$ROOT/src"
B="$ROOT/build-$ARCH"
OUT="$ROOT/out-$ARCH"
mkdir -p "$SRC" "$B" "$OUT"

# ------------------------------------------------------------
# 安装构建依赖
# Docker 模式 (x86_64/aarch64): 容器内 root, 直接 apt-get
# Cross-compile 模式 (loongarch64): host 用 sudo, 装 gcc-loongarch64-linux-gnu
# ------------------------------------------------------------
echo "==> 安装构建依赖 (CROSS_COMPILE=${CROSS_COMPILE:-<docker-native>})"

export DEBIAN_FRONTEND=noninteractive
export TZ=UTC

if [ -z "$CROSS_COMPILE" ]; then
    # Docker 容器内 (root, 无 sudo)
    APT="apt-get"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        ca-certificates tzdata ninja-build python3 git file \
        build-essential pkg-config wget gpg gpg-agent
else
    # Cross-compile on host (Ubuntu 24.04, sudo)
    APT="sudo apt-get"
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends \
        ca-certificates ninja-build python3 git file \
        build-essential pkg-config \
        gcc-13-loongarch64-linux-gnu g++-13-loongarch64-linux-gnu \
        cmake
    # symlink 给 cmake toolchain file 用 (无版本号路径)
    sudo ln -sf "$(command -v loongarch64-linux-gnu-gcc-13)"  /usr/local/bin/loongarch64-linux-gnu-gcc
    sudo ln -sf "$(command -v loongarch64-linux-gnu-g++-13)" /usr/local/bin/loongarch64-linux-gnu-g++
    loongarch64-linux-gnu-gcc --version | head -1
fi

# ------------------------------------------------------------
# 安装新版 cmake（仅 docker 模式; cross-compile host 已通过上面的 cmake 包装好）
# ------------------------------------------------------------
if [ -z "$CROSS_COMPILE" ]; then
    echo "==> 安装新版 cmake（Kitware 官方源）"
    DISTRO_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
    wget -qO - https://apt.kitware.com/keys/kitware-archive-latest.asc \
        | gpg --dearmor > /usr/share/keyrings/kitware-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] \
https://apt.kitware.com/ubuntu/ ${DISTRO_CODENAME} main" \
        > /etc/apt/sources.list.d/kitware.list
    apt-get update -qq
    apt-get install -y --no-install-recommends cmake

    # libstdc++ 静态开发包 (GCC 版本随 distro 变,逐个 fallback)
    apt-get install -y --no-install-recommends libstdc++-7-dev 2>/dev/null \
      || apt-get install -y --no-install-recommends libstdc++-8-dev 2>/dev/null \
      || apt-get install -y --no-install-recommends libstdc++-10-dev 2>/dev/null \
      || apt-get install -y --no-install-recommends libstdc++-12-dev 2>/dev/null \
      || apt-get install -y --no-install-recommends libstdc++-11-dev 2>/dev/null \
      || echo "Warning: libstdc++-dev not found"
fi

echo "==> 工具版本"
cmake --version
ninja --version
gcc --version

# ------------------------------------------------------------
# 克隆或更新源码
# ------------------------------------------------------------
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

echo "==> 获取源码"
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
# 与 macOS 脚本保持一致的写法，Linux 特有：
#   - 无 CMAKE_OSX_* 参数
#   - 禁用 GUI 后端（GTK/Qt/OpenGL）
#   - 启用 V4L（Linux 摄像头）
#   - 禁用 AVFoundation（macOS 专属）
# ------------------------------------------------------------
# ── LoongArch64 cross-compile: 写 cmake toolchain file + 关所有 SIMD ──
TOOLCHAIN_ARGS=()
SIMD_ARGS=()
if [ "$CROSS_COMPILE" = "loongarch64" ]; then
    TC="$B/loongarch64-toolchain.cmake"
    cat > "$TC" <<'TCEOF'
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR loongarch64)
set(CMAKE_C_COMPILER loongarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER loongarch64-linux-gnu-g++)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
TCEOF
    TOOLCHAIN_ARGS+=(-DCMAKE_TOOLCHAIN_FILE="$TC")
    # OpenCV 4.10 默认 CPU dispatch 假设 x86 SSE/AVX 或 ARM NEON, LoongArch 都没有.
    # 强制空, 走通用 C++ kernel.
    SIMD_ARGS+=(-DCPU_BASELINE= -DCPU_DISPATCH=)
fi

echo "==> Build OpenCV static ($ARCH, Linux)"
cmake -S "$SRC/opencv" -B "$B/opencv" -G Ninja \
  "${TOOLCHAIN_ARGS[@]}" "${SIMD_ARGS[@]}" \
  -D CMAKE_BUILD_TYPE=Release \
  -D OPENCV_EXTRA_MODULES_PATH="$SRC/opencv_contrib/modules" \
  -D BUILD_SHARED_LIBS=OFF \
  -D BUILD_LIST="$BUILD_LIST" \
  -D BUILD_TESTS=OFF -D BUILD_PERF_TESTS=OFF -D BUILD_EXAMPLES=OFF -D BUILD_DOCS=OFF -D BUILD_opencv_apps=OFF \
  -D OPENCV_FORCE_3RDPARTY_BUILD=ON \
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
  -D WITH_GTK=OFF \
  -D WITH_QT=OFF \
  -D WITH_OPENGL=OFF \
  -D WITH_V4L=ON \
  -D WITH_LIBV4L=OFF \
  -D WITH_AVFOUNDATION=OFF \
  -D WITH_OBSENSOR=OFF \
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
#   - Linux 特有：静态链接 libstdc++ 和 libgcc（减少运行时依赖）
# ------------------------------------------------------------
echo "==> Build OpenCvSharpExtern ($ARCH)"
cmake -S "$SRC/opencvsharp/src" -B "$B/opencvsharp" -G Ninja \
  "${TOOLCHAIN_ARGS[@]}" \
  -D CMAKE_BUILD_TYPE=Release \
  -D CMAKE_INSTALL_PREFIX="$OUT" \
  -D CMAKE_SHARED_LINKER_FLAGS="-static-libstdc++ -static-libgcc" \
  -D CMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -D OpenCV_DIR="$B/opencv"

ninja -C "$B/opencvsharp"
ninja -C "$B/opencvsharp" install

SOFILE="$(find "$OUT" -name "libOpenCvSharpExtern.so" -print -quit)"
if [[ -z "${SOFILE:-}" ]]; then
  echo "ERROR: libOpenCvSharpExtern.so not found"
  exit 1
fi

mkdir -p "$OUT/final"
cp -f "$SOFILE" "$OUT/final/libOpenCvSharpExtern.so"

# ------------------------------------------------------------
# 验证最终产物 (cross-compile 时跳过 ldd, host 不能加载 loongarch64 ELF)
# ------------------------------------------------------------
echo "==> 验证产物 ($ARCH)"
file "$OUT/final/libOpenCvSharpExtern.so" || true
if [ -z "$CROSS_COMPILE" ]; then
    ldd "$OUT/final/libOpenCvSharpExtern.so" || true
fi

# Cross-compile 后,host runner 是 sudo + chown 不需要 (apt 装的那些都是 root 但产物在 mkdir 的目录下,
# host runner 是 runner uid, 没问题)。Docker 路径需要 chown 给 host uid.
if [ -z "$CROSS_COMPILE" ] && [ -d /ws ]; then
    HOST_UID=$(stat -c '%u' /ws)
    HOST_GID=$(stat -c '%g' /ws)
    chown -R "$HOST_UID:$HOST_GID" "$OUT" "$B" 2>/dev/null || true
fi

echo "==> Done slice: $OUT/final/libOpenCvSharpExtern.so"
