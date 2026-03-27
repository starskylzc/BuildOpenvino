#!/bin/bash
# extract_openvino_linux.sh
# 用法: bash extract_openvino_linux.sh <OV_URL> <DST>
# 在 Docker ubuntu:20.04 容器内运行，提取 OpenVINO 最小运行时
set -euxo pipefail

OV_URL="$1"
DST="$2"

apt-get update -qq
apt-get install -y --no-install-recommends curl ca-certificates patchelf

echo ">>> Downloading OpenVINO..."
curl -L -o /tmp/ov.tgz "$OV_URL"

echo ">>> Extracting..."
mkdir -p /tmp/ov_src
tar -xzf /tmp/ov.tgz -C /tmp/ov_src

OV_ROOT=$(find /tmp/ov_src -maxdepth 1 -type d -name "l_openvino_toolkit_*" | head -n 1)
echo ">>> OV_ROOT: $OV_ROOT"

# 动态定位库目录（通过 libopenvino.so.2023.3.0 所在位置，兼容 intel64/aarch64 等路径）
SRC_LIB=$(find "$OV_ROOT/runtime" -maxdepth 5 -type f -name "libopenvino.so.2023.3.0" | head -n 1 | xargs dirname)
echo ">>> SRC_LIB: $SRC_LIB"

# 动态定位 TBB 目录
SRC_TBB=$(find "$OV_ROOT/runtime/3rdparty/tbb" -type d -name "lib" | head -n 1)
echo ">>> SRC_TBB: $SRC_TBB"

SRC_INC="$OV_ROOT/runtime/include/ie/c_api"
mkdir -p "$DST/include"

echo ">>> Copying real files (no symlinks)..."
cp "$SRC_LIB/libopenvino.so.2023.3.0"               "$DST/"
cp "$SRC_LIB/libopenvino_c.so.2023.3.0"             "$DST/"
cp "$SRC_LIB/libopenvino_onnx_frontend.so.2023.3.0" "$DST/"

CPU_PLUGIN=$(find "$SRC_LIB" -maxdepth 1 -type f -name "libopenvino_intel_cpu_plugin.so*" | head -n 1)
if [ -z "$CPU_PLUGIN" ]; then
  echo "ERROR: CPU plugin not found in $SRC_LIB"
  ls -la "$SRC_LIB"
  exit 1
fi
cp "$CPU_PLUGIN" "$DST/"
CPU_PLUGIN_NAME=$(basename "$CPU_PLUGIN")

cp "$SRC_TBB/libtbb.so.12"      "$DST/"
cp "$SRC_TBB/libtbbmalloc.so.2" "$DST/"
cp "$SRC_INC/ie_c_api.h"        "$DST/include/"

cd "$DST"

echo ">>> Renaming..."
mv -f "libopenvino.so.2023.3.0"               "libopenvino.so"
mv -f "libopenvino_c.so.2023.3.0"             "libopenvino_c.so"
mv -f "libopenvino_onnx_frontend.so.2023.3.0" "libopenvino_onnx_frontend.2330.so"

# TBB 软链接（供运行时按无版本号名称查找）
ln -sf "libtbb.so.12"      "libtbb.so"
ln -sf "libtbbmalloc.so.2" "libtbbmalloc.so"

printf '<ie>\n    <plugins>\n        <plugin name="CPU" location="%s">\n        </plugin>\n    </plugins>\n</ie>\n' \
  "$CPU_PLUGIN_NAME" > "plugins.xml"

echo ">>> Patching RPATH to \$ORIGIN..."
find . -maxdepth 1 \( -name "*.so" -o -name "*.so.*" \) -type f | while read -r LIB; do
  echo "  patchelf: $LIB"
  patchelf --set-rpath '$ORIGIN' "$LIB"
done

echo ">>> Final files:"
ls -la
