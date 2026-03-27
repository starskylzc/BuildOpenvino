#!/bin/bash
# extract_openvino_linux.sh
# 用法: bash /extract_ov.sh <OV_URL> <DST> <VARIANT>
#   OV_URL  : OpenVINO 官方 tgz 下载地址
#   DST     : 输出目录（绝对路径，容器内）
#   VARIANT : cpu 或 gpu
#
# 在 Docker ubuntu:20.04 容器内运行，提取 OpenVINO 最小运行时
#
# Linux 版 OpenVINO 2023.3 包结构：
#   runtime/lib/<arch>/       <- 所有 .so（无 Release 子目录）
#   runtime/include/ie/c_api/ <- C API 头文件
#   TBB 不在包内，链接系统 libtbb.so.2（Ubuntu 20.04 libtbb2 包）
set -euxo pipefail

OV_URL="$1"
DST="$2"
VARIANT="${3:-cpu}"   # cpu 或 gpu

apt-get update -qq
apt-get install -y --no-install-recommends curl ca-certificates patchelf libtbb2 libtbb-dev

echo ">>> Downloading OpenVINO..."
curl -L -o /tmp/ov.tgz "$OV_URL"

echo ">>> Extracting..."
mkdir -p /tmp/ov_src
tar -xzf /tmp/ov.tgz -C /tmp/ov_src

OV_ROOT=$(find /tmp/ov_src -maxdepth 1 -type d -name "l_openvino_toolkit_*" | head -n 1)
echo ">>> OV_ROOT: $OV_ROOT"

# 动态定位库目录（通过 libopenvino_intel_cpu_plugin.so 所在位置，兼容 intel64/aarch64 等路径）
SRC_LIB=$(find "$OV_ROOT/runtime/lib" -maxdepth 2 -type f \
  -name "libopenvino_intel_cpu_plugin.so" | head -n 1 | xargs dirname)
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
  # GPU 插件
  GPU_PLUGIN="$SRC_LIB/libopenvino_intel_gpu_plugin.so"
  if [ ! -f "$GPU_PLUGIN" ]; then
    echo "ERROR: GPU plugin not found in $SRC_LIB"
    ls -la "$SRC_LIB"
    exit 1
  fi
  cp "$GPU_PLUGIN" "$DST/"
  PLUGIN_LOCATION="libopenvino_intel_gpu_plugin.so"
  PLUGIN_NAME="GPU"
else
  # CPU 插件
  CPU_PLUGIN="$SRC_LIB/libopenvino_intel_cpu_plugin.so"
  if [ ! -f "$CPU_PLUGIN" ]; then
    echo "ERROR: CPU plugin not found in $SRC_LIB"
    ls -la "$SRC_LIB"
    exit 1
  fi
  cp "$CPU_PLUGIN" "$DST/"
  PLUGIN_LOCATION="libopenvino_intel_cpu_plugin.so"
  PLUGIN_NAME="CPU"
fi

echo ">>> Locating and copying TBB from system (libtbb2)..."
# OpenVINO 2023.3 Linux 版链接 libtbb.so.2（Ubuntu 20.04 libtbb2 包提供）
TBB_SO=$(find /usr -maxdepth 5 -type f -name "libtbb.so.2" 2>/dev/null | head -n 1)
if [ -z "$TBB_SO" ]; then
  echo "ERROR: libtbb.so.2 not found after installing libtbb2"
  find /usr -name "libtbb*" 2>/dev/null
  exit 1
fi
echo ">>> TBB_SO: $TBB_SO"
cp "$TBB_SO" "$DST/libtbb.so.2"

TBB_MALLOC_SO=$(find /usr -maxdepth 5 -type f -name "libtbbmalloc.so.2" 2>/dev/null | head -n 1)
if [ -n "$TBB_MALLOC_SO" ]; then
  echo ">>> TBB_MALLOC_SO: $TBB_MALLOC_SO"
  cp "$TBB_MALLOC_SO" "$DST/libtbbmalloc.so.2"
else
  echo ">>> libtbbmalloc.so.2 not found, skipping"
fi

cd "$DST"

echo ">>> Renaming core libs..."
mv -f "libopenvino.so.2023.3.0"               "libopenvino.so"
mv -f "libopenvino_c.so.2023.3.0"             "libopenvino_c.so"
mv -f "libopenvino_onnx_frontend.so.2023.3.0" "libopenvino_onnx_frontend.2330.so"

# TBB 软链接（供运行时按无版本号名称查找）
ln -sf "libtbb.so.2" "libtbb.so"
if [ -f "libtbbmalloc.so.2" ]; then
  ln -sf "libtbbmalloc.so.2" "libtbbmalloc.so"
fi

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
