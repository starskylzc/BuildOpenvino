#!/usr/bin/env bash
# =====================================================================
# build_mnn_linux.sh
#
# 用环境变量驱动的 MNN Linux 构建脚本。3 个 RID 复用同一脚本:
#
#   linux-x64   → 在 Docker ubuntu:18.04 容器内 (glibc 2.27)
#   linux-arm64 → 在 Docker arm64v8/ubuntu:18.04 容器内 (glibc 2.27)
#   linux-loongarch64 → 在 Ubuntu 24.04 host 上交叉编译 (apt 装 gcc-loongarch64-linux-gnu)
#
# 输入环境变量:
#   BUILD_TYPE       Release / RelWithDebInfo
#   MNN_SOURCE       MNN 源码绝对路径
#   OUT_DIR          产物输出目录
#   RID              linux-x64 / linux-arm64 / linux-loongarch64
#   ARCH             cmake CMAKE_SYSTEM_PROCESSOR: x86_64 / aarch64 / loongarch64
#   CROSS_COMPILE    空 = native (in Docker); 非空 (loongarch64) = 交叉编译
#
# 设计要点 (对齐 bench/MNN_BUILD_MATRIX.md §3.6 / §3.7 / §3.8):
#   - x64:    AVX2 + SSE + OpenCL  (glibc 2.27 兼容麒麟/UOS/欧拉)
#   - arm64:  ARM82 + KleidiAI + OpenCL (飞腾/鲲鹏/树莓派/Jetson)
#   - la64:   通用 C++ + OpenCL (龙芯 3A5000+; 无 SIMD 优化)
#   - 不开 MUSA: GHA 无 MUSA SDK,后续在摩尔线程开发机用 SEP_BUILD 单独编 libMNN_MUSA.so
# =====================================================================
set -euo pipefail

for v in BUILD_TYPE MNN_SOURCE OUT_DIR RID ARCH; do
  if [ -z "${!v:-}" ]; then echo "::error::Missing required env var: $v"; exit 1; fi
done
CROSS_COMPILE="${CROSS_COMPILE:-}"

echo "================================================================"
echo "  MNN Linux Build"
echo "  RID:           $RID"
echo "  Arch:          $ARCH"
echo "  CrossCompile:  ${CROSS_COMPILE:-<native-in-docker>}"
echo "  BuildType:     $BUILD_TYPE"
echo "  Source:        $MNN_SOURCE"
echo "  Out:           $OUT_DIR"
echo "================================================================"

[ -d "$MNN_SOURCE" ] || { echo "::error::MNN source not found: $MNN_SOURCE"; exit 1; }
mkdir -p "$OUT_DIR"

BUILD_DIR="$(dirname "$MNN_SOURCE")/build-mnn-$RID"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ====================================================================
# 1. 装依赖 (Docker 容器内 / 交叉编译 host)
# ====================================================================
if [ -z "$CROSS_COMPILE" ]; then
    # ── Docker ubuntu:18.04 / arm64v8/ubuntu:18.04 内 ────────────────
    # 容器是 fresh image, 啥都没装。tzdata 必须先 noninteractive。
    export DEBIAN_FRONTEND=noninteractive
    export TZ=UTC
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        ca-certificates \
        tzdata \
        ninja-build \
        python3 \
        git \
        file \
        build-essential \
        pkg-config \
        wget \
        gpg \
        gpg-agent \
        software-properties-common \
        ocl-icd-opencl-dev

    # aarch64 (linux-arm64): KleidiAI 要求 SVE2/i8mm,需 GCC 10+。Ubuntu 20.04 默认 GCC 9 不够,装 gcc-10。
    # x86_64 (linux-x64): GCC 7 (ubuntu:18.04) / GCC 9 (ubuntu:20.04) 都够,跳过升级。
    if [ "$ARCH" = "aarch64" ]; then
        echo "==> aarch64: 装 gcc-10 (KleidiAI 要求 SVE2/i8mm 支持)"
        apt-get install -y --no-install-recommends gcc-10 g++-10
        update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-10 100
        update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-10 100
        export CC=gcc-10
        export CXX=g++-10
    fi

    # Ubuntu 18.04 / 20.04 自带 cmake 太旧 (3.10 / 3.16),装 Kitware 官方源最新版
    DISTRO_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
    wget -qO - https://apt.kitware.com/keys/kitware-archive-latest.asc \
        | gpg --dearmor > /usr/share/keyrings/kitware-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] \
https://apt.kitware.com/ubuntu/ ${DISTRO_CODENAME} main" \
        > /etc/apt/sources.list.d/kitware.list
    apt-get update -qq
    apt-get install -y --no-install-recommends cmake

    # libstdc++ 静态包 (随 GCC 版本变名,逐个 fallback;成功即停)
    apt-get install -y --no-install-recommends libstdc++-7-dev 2>/dev/null \
        || apt-get install -y --no-install-recommends libstdc++-8-dev 2>/dev/null \
        || apt-get install -y --no-install-recommends libstdc++-10-dev 2>/dev/null \
        || apt-get install -y --no-install-recommends libstdc++-11-dev 2>/dev/null \
        || echo "::warning::libstdc++-dev not found, -static-libstdc++ may fail at link"
else
    # ── Cross-compile host (Ubuntu 24.04) ────────────────────────────
    # workflow yml 已经在 host apt 装好 gcc-${CROSS_COMPILE}-linux-gnu / cmake / ninja。
    # 这里只读不装。
    : "${CROSS_COMPILE:?}"
fi

echo ">>> 工具版本"
cmake --version
ninja --version
gcc --version | head -1

# ====================================================================
# 2. 组装 cmake 参数
# ====================================================================
COMMON_FLAGS=(
    -G Ninja
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
    -DMNN_BUILD_SHARED_LIBS=ON
    -DMNN_OPENCL=ON
    -DMNN_USE_SYSTEM_LIB=OFF
    -DMNN_BUILD_TOOLS=ON
    -DMNN_BUILD_TEST=OFF
    -DMNN_BUILD_DEMO=OFF
    -DMNN_BUILD_BENCHMARK=OFF
    -DMNN_BUILD_CONVERTER=OFF
    # 静态链接 stdc++/gcc 以在低 glibc 客户机上跑通 (麒麟/UOS/欧拉)
    -DCMAKE_SHARED_LINKER_FLAGS="-static-libstdc++ -static-libgcc"
    -DCMAKE_EXE_LINKER_FLAGS="-static-libstdc++ -static-libgcc"
)

ARCH_FLAGS=()
TOOLCHAIN_ARGS=()
case "$ARCH" in
    x86_64)
        # linux-x64: 单一 libMNN.so (CPU+OpenCL+Express embed).
        # MUSA 不集成: MNN 上游 MUSA backend 跟核心 API 长期脱节, 3.5.0 release 上无法编通,
        # 摩尔线程客户走 OpenCL 兜底 (MTT GPU 也支持 OpenCL).
        ARCH_FLAGS+=(-DMNN_AVX2=ON -DMNN_USE_SSE=ON -DMNN_SEP_BUILD=OFF)
        ;;
    aarch64)
        # linux-arm64: 单一 libMNN.so (CPU+ARM82+OpenCL embed)。
        # MNN_KLEIDIAI=OFF: KleidiAI 加速量化 GEMM (LLM) + SME2 上的 fp16/fp32 GEMM。
        # 我们 fp16 detection 模型不量化, 客户机 (麒麟 V10 ARM/飞腾/鲲鹏/树莓派/Jetson)
        # 几乎全部无 SME2 → KleidiAI 在我们 workload 上不触发 → 关掉精简产物.
        ARCH_FLAGS+=(-DMNN_ARM82=ON -DMNN_KLEIDIAI=OFF -DMNN_SEP_BUILD=OFF)
        ;;
    loongarch64)
        # 龙芯 3A5000+: 无 ARM82/AVX2 等 SIMD 优化, 通用 C++ + OpenCL 兜底
        # 简报 §4 期望单一 libMNN.so, 显式关 SEP_BUILD (默认 ON)
        ARCH_FLAGS+=(-DMNN_SEP_BUILD=OFF)
        # 写 cmake toolchain file (交叉编译)
        TC="$BUILD_DIR/loongarch64-toolchain.cmake"
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
        ;;
    *) echo "::error::Unsupported ARCH: $ARCH"; exit 1 ;;
esac

# ====================================================================
# 2.4. Patch MNN OpenCLRuntime.cpp: globalContext → per-platform map
# ====================================================================
# 防多 GPU 切换时 cl::Context 误复用。注:Linux build 在 docker 内可能没
# /python3,fallback python(docker ubuntu:18.04 一般 python2 默认,但 GHA
# Linux runner 装了 python3),都试一下。
SCRIPT_DIR_FOR_PATCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR_FOR_PATCH/patch_mnn_opencl_runtime.py" ]; then
  if command -v python3 >/dev/null 2>&1; then
    python3 "$SCRIPT_DIR_FOR_PATCH/patch_mnn_opencl_runtime.py" "$MNN_SOURCE" || \
      echo "::warning::OpenCLRuntime patch failed"
  elif command -v python >/dev/null 2>&1; then
    python "$SCRIPT_DIR_FOR_PATCH/patch_mnn_opencl_runtime.py" "$MNN_SOURCE" || \
      echo "::warning::OpenCLRuntime patch failed"
  else
    echo "::warning::no python found, skipping OpenCLRuntime patch"
  fi
fi

# ====================================================================
# 2.5. Inject YuYiNoPhotoLib mnnwrap C ABI into MNN target
# ====================================================================
# 把 mnnwrap.cpp 编进 libMNN.so,clients 部署 1 个 native/RID(免单独 libmnnwrap.so)
# 注:Docker(ubuntu:18.04)模式下 BASH_SOURCE 路径在容器视角,host 挂载的 /ws 才能访问 mnnwrap/
#    所以同时 fallback 到 /ws/mnnwrap(linux-x64/arm64)。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MNNWRAP_DIR=""
for cand in "$SCRIPT_DIR/../../mnnwrap" "/ws/mnnwrap" "$PWD/build-tools/mnnwrap" "$PWD/mnnwrap"; do
  if [ -f "$cand/mnnwrap.cpp" ]; then
    MNNWRAP_DIR="$(cd "$cand" && pwd)"
    break
  fi
done
if [ -n "$MNNWRAP_DIR" ]; then
  if ! grep -q 'mnnwrap injection' "$MNN_SOURCE/CMakeLists.txt"; then
    cat >> "$MNN_SOURCE/CMakeLists.txt" <<EOF

# === YuYiNoPhotoLib mnnwrap injection (auto-appended by BuildOpenvino) ===
target_sources(MNN PRIVATE "$MNNWRAP_DIR/mnnwrap.cpp")
target_include_directories(MNN PRIVATE "$MNNWRAP_DIR")
target_compile_definitions(MNN PRIVATE MNNWRAP_BUILDING)
EOF
    echo ">>> Appended mnnwrap injection to MNN/CMakeLists.txt (mnnwrap dir: $MNNWRAP_DIR)"
  fi
else
  echo "::warning::mnnwrap source not found in any of: $SCRIPT_DIR/../../mnnwrap, /ws/mnnwrap, $PWD/build-tools/mnnwrap; skipping mnnwrap integration"
fi

# ====================================================================
# 3. Configure + Build
# ====================================================================
echo ">>> cmake configure (RID=$RID)"
cmake -S "$MNN_SOURCE" -B "$BUILD_DIR" \
    "${COMMON_FLAGS[@]}" \
    "${ARCH_FLAGS[@]}" \
    "${TOOLCHAIN_ARGS[@]}"

echo ">>> ninja (RID=$RID)"
cmake --build "$BUILD_DIR" --parallel

# ====================================================================
# 4. 收产物
# ====================================================================
SO="$BUILD_DIR/libMNN.so"
[ -f "$SO" ] || { echo "::error::libMNN.so not produced"; ls -la "$BUILD_DIR"; exit 1; }
cp -f "$SO" "$OUT_DIR/"

# SEP_BUILD=ON 时会出多个 backend .so;统一拷 libMNN*.so 全部产物。
# (linux-x64 是 SEP_BUILD=ON: libMNN_CL.so 在 source/backend/opencl/, libMNN_Express.so 在 express/;
#  arm64 / loongarch 是 OFF, 只 libMNN.so 不影响)。无 maxdepth, 全树扫描。
find "$BUILD_DIR" -name "libMNN*.so" -not -name "libMNN.so" -type f -print -exec cp -f {} "$OUT_DIR/" \; || true

for exe in MNNV2Basic.out GetMNNInfo; do
    if [ -f "$BUILD_DIR/$exe" ]; then cp -f "$BUILD_DIR/$exe" "$OUT_DIR/"; fi
done

# ====================================================================
# 5. 验证 (file/objdump/glibc 版本)
# ====================================================================
echo ">>> 验证产物"
file "$OUT_DIR/libMNN.so"

if [ -z "$CROSS_COMPILE" ]; then
    # native: 可以读 GLIBC 符号
    echo "── glibc 最低版本 (越低越兼容) ──"
    if command -v objdump >/dev/null 2>&1; then
        objdump -T "$OUT_DIR/libMNN.so" 2>/dev/null \
            | awk -F'[() ]+' '/GLIBC_/ {print $5}' \
            | sort -u -V \
            | tail -1 \
            | xargs -I{} echo "  最低 glibc 依赖: {}" || true
    fi
    echo "── ldd ──"
    ldd "$OUT_DIR/libMNN.so" || true
fi

ls -lh "$OUT_DIR/"

# 把 docker 内 root 创建的产物所有权交回 host runner uid,
# 不然 host 上后续 step (Write version.txt / Upload artifact) Permission denied。
# /ws 是 mount 点,它的 uid 跟 host workspace 一致,从这里读最稳。
if [ -z "$CROSS_COMPILE" ] && [ -d /ws ]; then
    HOST_UID=$(stat -c '%u' /ws)
    HOST_GID=$(stat -c '%g' /ws)
    echo ">>> chown artifacts to host uid:gid = $HOST_UID:$HOST_GID"
    chown -R "$HOST_UID:$HOST_GID" "$OUT_DIR"
    chown -R "$HOST_UID:$HOST_GID" "$BUILD_DIR" 2>/dev/null || true
fi

echo "✅ MNN Linux build done: $RID"
