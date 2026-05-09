#!/usr/bin/env bash
# =====================================================================
# build_mnn_macos.sh
#
# 用环境变量驱动的 MNN macOS 构建脚本。osx-x64 / osx-arm64 复用同一脚本。
#
# 输入环境变量:
#   BUILD_TYPE       Release / RelWithDebInfo
#   MNN_SOURCE       MNN 源码绝对路径
#   OUT_DIR          产物输出目录
#   RID              osx-x64 / osx-arm64
#   ARCH             cmake CMAKE_OSX_ARCHITECTURES: x86_64 / arm64
#   DEPLOY_TARGET    CMAKE_OSX_DEPLOYMENT_TARGET: 10.15 (Intel) / 12.0 (Silicon)
#
# 设计要点 (对齐 bench/MNN_BUILD_MATRIX.md §3.4 / §3.5):
#   - Metal + CoreML (Apple 官方加速;Mac 自 10.14 deprecated OpenCL)
#   - osx-x64 加 AVX2; osx-arm64 加 ARM82 + KleidiAI (fp16)
#   - deploy_target 10.15 / 12.0 — 不做 universal binary,分两份编更干净 (10.15 max(10.15,12.0)=12.0 会让 Intel 跑不动)
# =====================================================================
set -euo pipefail

for v in BUILD_TYPE MNN_SOURCE OUT_DIR RID ARCH DEPLOY_TARGET; do
  if [ -z "${!v:-}" ]; then echo "::error::Missing required env var: $v"; exit 1; fi
done

echo "================================================================"
echo "  MNN macOS Build"
echo "  RID:           $RID"
echo "  Arch:          $ARCH"
echo "  DeployTarget:  $DEPLOY_TARGET"
echo "  BuildType:     $BUILD_TYPE"
echo "  Source:        $MNN_SOURCE"
echo "  Out:           $OUT_DIR"
echo "================================================================"

[ -d "$MNN_SOURCE" ] || { echo "::error::MNN source not found: $MNN_SOURCE"; exit 1; }
mkdir -p "$OUT_DIR"

BUILD_DIR="$(dirname "$MNN_SOURCE")/build-mnn-$RID"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ── per-arch SIMD ────────────────────────────────────────────────────
ARCH_FLAGS=()
case "$ARCH" in
  x86_64)
    ARCH_FLAGS+=(-DMNN_AVX2=ON -DMNN_USE_SSE=ON)
    ;;
  arm64)
    ARCH_FLAGS+=(-DMNN_ARM82=ON -DMNN_KLEIDIAI=ON)
    ;;
  *) echo "::error::Unsupported ARCH: $ARCH"; exit 1 ;;
esac

# ── Configure ────────────────────────────────────────────────────────
echo ">>> cmake configure (RID=$RID)"
cmake -S "$MNN_SOURCE" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY_TARGET" \
  -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
  -DCMAKE_OSX_SYSROOT=macosx \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DMNN_BUILD_SHARED_LIBS=ON \
  -DMNN_METAL=ON \
  -DMNN_COREML=ON \
  -DMNN_BUILD_TOOLS=ON \
  -DMNN_BUILD_TEST=OFF \
  -DMNN_BUILD_DEMO=OFF \
  -DMNN_BUILD_BENCHMARK=OFF \
  -DMNN_BUILD_CONVERTER=OFF \
  "${ARCH_FLAGS[@]}"

# ── Build ────────────────────────────────────────────────────────────
echo ">>> ninja (RID=$RID)"
cmake --build "$BUILD_DIR" --parallel

# ── 收产物 ───────────────────────────────────────────────────────────
DYLIB="$BUILD_DIR/libMNN.dylib"
[ -f "$DYLIB" ] || { echo "::error::libMNN.dylib not produced"; ls -la "$BUILD_DIR"; exit 1; }
cp -f "$DYLIB" "$OUT_DIR/"

# Metal 后端的辅助 .metallib (运行时 dlopen,缺了 Metal 路径就用不了)
for f in libMNN_CL.dylib libMNN_Express.dylib libMNN_Vulkan.dylib mnn.metallib; do
  if [ -f "$BUILD_DIR/$f" ]; then cp -f "$BUILD_DIR/$f" "$OUT_DIR/"; fi
done

# Tools (sanity)
for exe in MNNV2Basic.out GetMNNInfo; do
  if [ -f "$BUILD_DIR/$exe" ]; then cp -f "$BUILD_DIR/$exe" "$OUT_DIR/"; fi
done

# ── 验证 deploy target + arch ────────────────────────────────────────
echo ">>> 校验 binary"
file "$OUT_DIR/libMNN.dylib"
lipo -info "$OUT_DIR/libMNN.dylib" | grep -q "$ARCH" \
  || { echo "::error::arch mismatch"; exit 1; }

# 读 LC_BUILD_VERSION 或 LC_VERSION_MIN_MACOSX (旧格式)
MINOS=$(otool -l "$OUT_DIR/libMNN.dylib" | awk '
  $1=="cmd" && $2=="LC_BUILD_VERSION" { in_blk=1 }
  in_blk && $1=="minos" { print $2; exit }')
if [ -z "$MINOS" ]; then
  MINOS=$(otool -l "$OUT_DIR/libMNN.dylib" | awk '
    $1=="cmd" && $2=="LC_VERSION_MIN_MACOSX" { in_blk=1 }
    in_blk && $1=="version" { print $2; exit }')
fi
if [ "$MINOS" != "$DEPLOY_TARGET" ]; then
  echo "::error::minos=$MINOS expected=$DEPLOY_TARGET"
  exit 1
fi
echo "✅ arch + minos OK ($ARCH / $MINOS)"

ls -lh "$OUT_DIR/"
echo "✅ MNN macOS build done: $RID"
