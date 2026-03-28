#!/usr/bin/env bash
set -euo pipefail

# 用法：
#   build_linux_slice.sh x86_64
#   build_linux_slice.sh aarch64
#
# 注意事项：
#   - 在 Docker 容器内执行（ubuntu:18.04）
#   - ARCH 只支持 x86_64 或 aarch64
ARCH="$1"

OPENCV_VERSION="${OPENCV_VERSION:-4.11.0}"
OPENCVSHARP_REF="${OPENCVSHARP_REF:-4.11.0.20250507}"
BUILD_LIST="${BUILD_LIST:-core,imgproc,videoio}"

# ------------------------------------------------------------
# 确定工作目录
# 如果在 Docker 容器中通过 -w /ws 运行，GITHUB_WORKSPACE 不存在
# 此时 pwd 就是 /ws（即项目根目录）
# ------------------------------------------------------------
ROOT="${GITHUB_WORKSPACE:-$(pwd)}/_work"
SRC="$ROOT/src"
B="$ROOT/build-$ARCH"
OUT="$ROOT/out-$ARCH"

mkdir -p "$SRC" "$B" "$OUT"

# ------------------------------------------------------------
# 安装构建依赖（容器内）
# 关键：必须在 apt-get 之前设置以下环境变量，
# 否则 tzdata 等包会触发交互式地区/时区选择界面，导致 workflow 永久卡死。
# DEBIAN_FRONTEND=noninteractive  → 全程静默，不弹任何交互提示
# TZ=UTC                          → 预设时区，tzdata 无需再询问
# ------------------------------------------------------------
echo "==> 安装构建依赖"

export DEBIAN_FRONTEND=noninteractive
export TZ=UTC

apt-get update -qq

# ca-certificates 必须最先装，否则 git clone https:// 会因 SSL 证书验证失败而报错
apt-get install -y --no-install-recommends \
    ca-certificates \
    tzdata \
    ninja-build \
    python3 \
    git \
    build-essential \
    pkg-config \
    wget \
    gpg \
    gpg-agent

# ------------------------------------------------------------
# 安装新版 cmake（通过 Kitware 官方 APT 源）
# Ubuntu 18.04 自带 cmake 3.10，不支持 -S/-B 参数（需要 3.13+）
# 也不支持 -B 自动创建目录（需要 3.14+）
# 通过官方源安装最新稳定版解决所有兼容性问题
# ------------------------------------------------------------
echo "==> 安装新版 cmake（Kitware 官方源）"

# 检测系统代号（ubuntu 18.04 = bionic，ubuntu 20.04 = focal 等）
DISTRO_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")

# 用 gpg 直接写入 trusted keyring，不依赖已废弃的 apt-key
wget -qO - https://apt.kitware.com/keys/kitware-archive-latest.asc \
    | gpg --dearmor \
    > /usr/share/keyrings/kitware-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] \
https://apt.kitware.com/ubuntu/ ${DISTRO_CODENAME} main" \
    > /etc/apt/sources.list.d/kitware.list

apt-get update -qq
apt-get install -y --no-install-recommends cmake

echo "==> cmake 版本"
cmake --version

# 尝试安装静态链接所需的 libstdc++ 开发包
# Ubuntu 18.04 → libstdc++-7-dev（GCC 7）
# Debian 10    → libstdc++-8-dev（GCC 8）
# Ubuntu 20.04 → libstdc++-10-dev（GCC 10）
# Ubuntu 22.04 → libstdc++-12-dev（GCC 12）
# 依次尝试，找到一个能装的即可
echo "==> 尝试安装 libstdc++ 静态开发包"
apt-get install -y --no-install-recommends libstdc++-7-dev 2>/dev/null \
  || apt-get install -y --no-install-recommends libstdc++-8-dev 2>/dev/null \
  || apt-get install -y --no-install-recommends libstdc++-10-dev 2>/dev/null \
  || apt-get install -y --no-install-recommends libstdc++-12-dev 2>/dev/null \
  || apt-get install -y --no-install-recommends libstdc++-11-dev 2>/dev/null \
  || echo "Warning: libstdc++-dev not found, -static-libstdc++ may fail at link time"

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
echo "==> Build OpenCV static ($ARCH, Linux)"
cmake -S "$SRC/opencv" -B "$B/opencv" -G Ninja \
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
# 验证最终产物
# ------------------------------------------------------------
echo "==> 验证产物 ($ARCH)"
file "$OUT/final/libOpenCvSharpExtern.so" || true
ldd  "$OUT/final/libOpenCvSharpExtern.so" || true

echo "==> Done slice: $OUT/final/libOpenCvSharpExtern.so"
