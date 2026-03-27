#!/bin/bash
# extract_openvino_linux.sh
# 用法: bash /extract_ov.sh <OV_URL> <DST> <VARIANT> <OV_VERSION>
#   OV_URL     : OpenVINO 官方 tgz 下载地址
#   DST        : 输出目录（绝对路径，容器内）
#   VARIANT    : cpu 或 gpu
#   OV_VERSION : 完整版本号，如 2024.6.0（用于定位实体 .so 文件名）
#
# 在 Docker ubuntu:20.04 容器内运行，提取 OpenVINO 最小运行时
#
# 适用于 OpenVINO 2023.3 linux ubuntu18 包结构：
#   runtime/lib/<arch>/              <- 所有 .so（无 Release 子目录）
#   runtime/include/ie/c_api/        <- C API 头文件
#
# TBB 说明：
#   x86_64 (ubuntu18) 包内无 TBB，需系统安装 libtbb2（libtbb.so.2）
#   aarch64 (ubuntu18) 包内自带 3rdparty/tbb/lib/libtbb.so.12.2
#   脚本自动检测：有内置 TBB 则用内置，否则从系统安装
#
# aarch64 说明：
#   所有版本的官方预编译包均不含 Intel GPU 插件（ARM 平台无 Intel GPU）
#   CPU 插件名为 libopenvino_arm_cpu_plugin.so（非 intel_cpu）
set -euxo pipefail

OV_URL="$1"
DST="$2"
VARIANT="${3:-cpu}"
OV_VERSION="${4:-2023.3.0}"

apt-get update -qq
apt-get install -y --no-install-recommends curl ca-certificates patchelf

echo ">>> Downloading OpenVINO $OV_VERSION ($VARIANT)..."
curl -L -o /tmp/ov.tgz "$OV_URL"

echo ">>> Extracting..."
mkdir -p /tmp/ov_src
tar -xzf /tmp/ov.tgz -C /tmp/ov_src

OV_ROOT=$(find /tmp/ov_src -maxdepth 1 -type d -name "*openvino_toolkit_*" | head -n 1)
echo ">>> OV_ROOT: $OV_ROOT"

# 动态定位库目录（通过 libopenvino.so.<version> 所在位置，兼容 intel64/aarch64 路径）
SRC_LIB=$(find "$OV_ROOT/runtime/lib" -maxdepth 2 -type f \
  -name "libopenvino.so.${OV_VERSION}" | head -n 1 | xargs dirname)
echo ">>> SRC_LIB: $SRC_LIB"


# 定位头文件（优先新路径，兼容旧路径）
if [ -f "$OV_ROOT/runtime/include/openvino/c/ov_common.h" ]; then
  SRC_INC="$OV_ROOT/runtime/include/openvino/c"
  INC_FILE="ov_common.h"
elif [ -f "$OV_ROOT/runtime/include/ie/c_api/ie_c_api.h" ]; then
  SRC_INC="$OV_ROOT/runtime/include/ie/c_api"
  INC_FILE="ie_c_api.h"
else
  SRC_INC=$(find "$OV_ROOT/runtime/include" -name "*.h" | head -n 1 | xargs dirname 2>/dev/null || echo "")
  INC_FILE=$(basename "$(find "$OV_ROOT/runtime/include" -name "*.h" | head -n 1)")
fi
echo ">>> SRC_INC: $SRC_INC / $INC_FILE"

mkdir -p "$DST/include"

echo ">>> Copying OpenVINO core files (no symlinks)..."
cp "$SRC_LIB/libopenvino.so.${OV_VERSION}"               "$DST/"
cp "$SRC_LIB/libopenvino_c.so.${OV_VERSION}"             "$DST/"
cp "$SRC_LIB/libopenvino_onnx_frontend.so.${OV_VERSION}" "$DST/"
[ -n "$INC_FILE" ] && cp "$SRC_INC/$INC_FILE" "$DST/include/"

echo ">>> VARIANT: $VARIANT"
if [ "$VARIANT" = "gpu" ]; then
  GPU_PLUGIN="$SRC_LIB/libopenvino_intel_gpu_plugin.so"
  if [ ! -f "$GPU_PLUGIN" ]; then
    echo "ERROR: GPU plugin not found in $SRC_LIB (not supported on this arch)"
    ls -la "$SRC_LIB"
    exit 1
  fi
  cp "$GPU_PLUGIN" "$DST/"
  PLUGIN_LOCATION="libopenvino_intel_gpu_plugin.so"
  PLUGIN_NAME="GPU"
else
  # CPU 插件：x86_64 叫 intel_cpu，aarch64 叫 arm_cpu，动态查找
  CPU_PLUGIN=$(find "$SRC_LIB" -maxdepth 1 -type f \
    \( -name "libopenvino_intel_cpu_plugin.so" -o -name "libopenvino_arm_cpu_plugin.so" \) \
    | head -n 1)
  if [ -z "$CPU_PLUGIN" ]; then
    echo "ERROR: CPU plugin not found in $SRC_LIB"
    ls -la "$SRC_LIB"
    exit 1
  fi
  cp "$CPU_PLUGIN" "$DST/"
  PLUGIN_LOCATION=$(basename "$CPU_PLUGIN")
  PLUGIN_NAME="CPU"
fi

echo ">>> Handling TBB..."
# 优先使用包内自带 TBB（aarch64 包有，x86_64 ubuntu18 包无）
TBB_REAL=""
if [ -d "$OV_ROOT/runtime/3rdparty/tbb/lib" ]; then
  TBB_REAL=$(find "$OV_ROOT/runtime/3rdparty/tbb/lib" -maxdepth 1 -type f \
    -name "libtbb.so.*" 2>/dev/null | grep -v debug | sort -V | tail -n 1 || true)
fi

if [ -n "$TBB_REAL" ]; then
  echo ">>> Using bundled TBB: $TBB_REAL"
  TBB_SONAME=$(echo "$TBB_REAL" | grep -oP 'libtbb\.so\.\d+')   # e.g. libtbb.so.12
  TBB_BASENAME=$(basename "$TBB_REAL")                            # e.g. libtbb.so.12.2
  cp "$TBB_REAL" "$DST/$TBB_BASENAME"
  ln -sf "$TBB_BASENAME" "$DST/$TBB_SONAME"
  ln -sf "$TBB_SONAME"   "$DST/libtbb.so"

  MALLOC_REAL=$(find "$OV_ROOT/runtime/3rdparty/tbb/lib" -maxdepth 1 -type f \
    -name "libtbbmalloc.so.*" 2>/dev/null | grep -v debug | sort -V | tail -n 1 || true)
  if [ -n "$MALLOC_REAL" ]; then
    MALLOC_SONAME=$(echo "$MALLOC_REAL" | grep -oP 'libtbbmalloc\.so\.\d+')
    MALLOC_BASENAME=$(basename "$MALLOC_REAL")
    cp "$MALLOC_REAL" "$DST/$MALLOC_BASENAME"
    ln -sf "$MALLOC_BASENAME" "$DST/$MALLOC_SONAME"
    ln -sf "$MALLOC_SONAME"   "$DST/libtbbmalloc.so"
  fi
else
  echo ">>> No bundled TBB found, installing system libtbb2 (libtbb.so.2)..."
  apt-get install -y --no-install-recommends libtbb2 libtbb-dev

  TBB_SO=$(find /usr -maxdepth 5 -type f -name "libtbb.so.2" 2>/dev/null | head -n 1)
  if [ -z "$TBB_SO" ]; then
    echo "ERROR: libtbb.so.2 not found after installing libtbb2"
    find /usr -name "libtbb*" 2>/dev/null
    exit 1
  fi
  echo ">>> System TBB: $TBB_SO"
  cp "$TBB_SO" "$DST/libtbb.so.2"
  ln -sf "libtbb.so.2" "$DST/libtbb.so"

  TBB_MALLOC_SO=$(find /usr -maxdepth 5 -type f -name "libtbbmalloc.so.2" 2>/dev/null | head -n 1)
  if [ -n "$TBB_MALLOC_SO" ]; then
    cp "$TBB_MALLOC_SO" "$DST/libtbbmalloc.so.2"
    ln -sf "libtbbmalloc.so.2" "$DST/libtbbmalloc.so"
  fi
fi

cd "$DST"

echo ">>> Renaming core libs..."
mv -f "libopenvino.so.${OV_VERSION}"               "libopenvino.so"
mv -f "libopenvino_c.so.${OV_VERSION}"             "libopenvino_c.so"
mv -f "libopenvino_onnx_frontend.so.${OV_VERSION}" "libopenvino_onnx_frontend.so"

echo ">>> Generating plugins.xml ($VARIANT)..."
printf '<ie>\n    <plugins>\n        <plugin name="%s" location="%s">\n        </plugin>\n    </plugins>\n</ie>\n' \
  "$PLUGIN_NAME" "$PLUGIN_LOCATION" > "plugins.xml"

echo ">>> Patching RPATH to \$ORIGIN for all .so real files..."
find . -maxdepth 1 \( -name "*.so" -o -name "*.so.*" \) -type f | while read -r LIB; do
  echo "  patchelf: $LIB"
  patchelf --set-rpath '$ORIGIN' "$LIB"
done

echo ">>> Final files:"
ls -la
