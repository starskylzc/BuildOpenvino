#!/bin/bash
# extract_openvino_linux.sh
# 用法: bash /extract_ov.sh <OV_URL> <DST> <VARIANT>
#   OV_URL  : OpenVINO 官方 tgz 下载地址
#   DST     : 输出目录（绝对路径，容器内）
#   VARIANT : cpu 或 gpu
#
# 在 Docker ubuntu:20.04 容器内运行，提取 OpenVINO 最小运行时
#
# 两个包的差异：
#   x86_64 (ubuntu20):
#     - CPU 插件: libopenvino_intel_cpu_plugin.so
#     - GPU 插件: libopenvino_intel_gpu_plugin.so
#     - TBB: 包内无，需系统安装 libtbb2 (libtbb.so.2)
#   aarch64 (ubuntu18):
#     - CPU 插件: libopenvino_arm_cpu_plugin.so
#     - GPU 插件: 不存在（ARM 平台不支持 Intel GPU）
#     - TBB: 包内自带 3rdparty/tbb/lib/libtbb.so.12.2
set -euxo pipefail

OV_URL="$1"
DST="$2"
VARIANT="${3:-cpu}"   # cpu 或 gpu

apt-get update -qq
apt-get install -y --no-install-recommends curl ca-certificates patchelf

echo ">>> Downloading OpenVINO..."
curl -L -o /tmp/ov.tgz "$OV_URL"

echo ">>> Extracting..."
mkdir -p /tmp/ov_src
tar -xzf /tmp/ov.tgz -C /tmp/ov_src

OV_ROOT=$(find /tmp/ov_src -maxdepth 1 -type d -name "l_openvino_toolkit_*" | head -n 1)
echo ">>> OV_ROOT: $OV_ROOT"

# 动态定位库目录（通过 libopenvino.so.2023.3.0 所在位置，兼容 intel64/aarch64 路径）
SRC_LIB=$(find "$OV_ROOT/runtime/lib" -maxdepth 2 -type f \
  -name "libopenvino.so.2023.3.0" | head -n 1 | xargs dirname)
echo ">>> SRC_LIB: $SRC_LIB"

SRC_INC="$OV_ROOT/runtime/include/ie/c_api"
mkdir -p "$DST/include"

echo ">>> Copying OpenVINO core files (no symlinks)..."
cp "$SRC_LIB/libopenvino.so.2023.3.0"               "$DST/"
cp "$SRC_LIB/libopenvino_c.so.2023.3.0"             "$DST/"
cp "$SRC_LIB/libopenvino_onnx_frontend.so.2023.3.0" "$DST/"
cp "$SRC_INC/ie_c_api.h"                            "$DST/include/"

echo ">>> VARIANT: $VARIANT"
if [ "$VARIANT" = "gpu" ]; then
  # GPU 插件（仅 x86_64 有）
  GPU_PLUGIN="$SRC_LIB/libopenvino_intel_gpu_plugin.so"
  if [ ! -f "$GPU_PLUGIN" ]; then
    echo "ERROR: GPU plugin not found in $SRC_LIB (not supported on this arch?)"
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
# aarch64 包内自带 3rdparty/tbb/lib/libtbb.so.12.2
# x86_64  包内无 TBB，需从系统 libtbb2 获取 libtbb.so.2
BUNDLED_TBB=$(find "$OV_ROOT/runtime/3rdparty/tbb/lib" -maxdepth 1 -type f \
  -name "libtbb.so.*" 2>/dev/null | grep -v debug | sort -V | tail -n 1 || true)

if [ -n "$BUNDLED_TBB" ]; then
  echo ">>> Using bundled TBB: $BUNDLED_TBB"
  TBB_BASENAME=$(basename "$BUNDLED_TBB")   # e.g. libtbb.so.12.2
  TBB_SONAME=$(echo "$TBB_BASENAME" | grep -oP 'libtbb\.so\.\d+')  # e.g. libtbb.so.12
  cp "$BUNDLED_TBB" "$DST/$TBB_BASENAME"
  ln -sf "$TBB_BASENAME" "$DST/$TBB_SONAME"
  ln -sf "$TBB_SONAME"   "$DST/libtbb.so"

  BUNDLED_MALLOC=$(find "$OV_ROOT/runtime/3rdparty/tbb/lib" -maxdepth 1 -type f \
    -name "libtbbmalloc.so.*" 2>/dev/null | grep -v debug | sort -V | tail -n 1 || true)
  if [ -n "$BUNDLED_MALLOC" ]; then
    MALLOC_BASENAME=$(basename "$BUNDLED_MALLOC")
    MALLOC_SONAME=$(echo "$MALLOC_BASENAME" | grep -oP 'libtbbmalloc\.so\.\d+')
    cp "$BUNDLED_MALLOC" "$DST/$MALLOC_BASENAME"
    ln -sf "$MALLOC_BASENAME" "$DST/$MALLOC_SONAME"
    ln -sf "$MALLOC_SONAME"   "$DST/libtbbmalloc.so"
  fi
else
  echo ">>> No bundled TBB, installing system libtbb2..."
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
mv -f "libopenvino.so.2023.3.0"               "libopenvino.so"
mv -f "libopenvino_c.so.2023.3.0"             "libopenvino_c.so"
mv -f "libopenvino_onnx_frontend.so.2023.3.0" "libopenvino_onnx_frontend.2330.so"

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
