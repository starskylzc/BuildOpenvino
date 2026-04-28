#!/usr/bin/env bash
# 把指定 ORT run 和 OpenCvSharp run 的 artifacts 按"客户端部署平台"重组到 deploy/。
# 每个 deploy/<platform>/ 含该平台需要的全部 native 依赖,客户端 ship 时整个目录平铺即可。
#
# 用法:
#   ./stage.sh <ort_run_id> <opencv_run_id>
#   ./stage.sh                  # 用最近成功的两个 run
#
# 执行后:
#   deploy/win-x64/        OpenCvSharpExtern.dll + onnxruntime.dll + DirectML.dll + version.txt
#   deploy/win-x86/        OpenCvSharpExtern.dll + onnxruntime.dll + version.txt
#   deploy/win-arm64/      OpenCvSharpExtern.dll + onnxruntime.dll + DirectML.dll + version.txt
#   deploy/osx-x64/        libOpenCvSharpExtern.dylib + libonnxruntime.dylib + version.txt
#   deploy/osx-arm64/      libOpenCvSharpExtern.dylib + libonnxruntime.dylib + version.txt
#   deploy/linux-x64/      libOpenCvSharpExtern.so + libonnxruntime.so + version.txt
#   deploy/linux-arm64/    libOpenCvSharpExtern.so + libonnxruntime.so + version.txt
#   deploy/linux-x64-cuda/    + cudart/cublas/cudnn 全套
#   deploy/linux-x64-rocm/    + ROCm runtime
#   deploy/linux-x64-openvino/ + OpenVINO runtime + plugins.xml
set -euo pipefail

REPO="${REPO:-starskylzc/BuildOpenvino}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ORT_DIR="$HERE/ort-1.25.0"
OCV_DIR="$HERE/opencvsharp-4.10.0"
DEPLOY_DIR="$HERE/deploy"

ORT_RUN="${1:-}"
OCV_RUN="${2:-}"

if [ -z "$ORT_RUN" ]; then
  ORT_RUN=$(gh run list -R "$REPO" \
    --workflow="Build ORT 1.25.0 Desktop (Win + Mac, GPU/iGPU/CPU)" \
    --status=success --branch=main --limit=1 --json databaseId --jq '.[0].databaseId')
  echo ">>> Using latest success ORT run: $ORT_RUN"
fi
if [ -z "$OCV_RUN" ]; then
  OCV_RUN=$(gh run list -R "$REPO" \
    --workflow="Build-Opencvsharp-AllPlatforms-4.10.0" \
    --status=success --branch=main --limit=1 --json databaseId --jq '.[0].databaseId')
  echo ">>> Using latest success OpenCvSharp run: $OCV_RUN"
fi

mkdir -p "$ORT_DIR" "$OCV_DIR" "$DEPLOY_DIR"

# 1. 下载所有 ORT artifacts (会跳过已存在的)
echo "=== Downloading ORT artifacts from run $ORT_RUN ==="
gh run download "$ORT_RUN" -R "$REPO" -D "$ORT_DIR" 2>&1 || echo "  (some artifacts may not exist yet)"

# 2. 下载所有 OpenCvSharp artifacts
echo "=== Downloading OpenCvSharp artifacts from run $OCV_RUN ==="
gh run download "$OCV_RUN" -R "$REPO" -D "$OCV_DIR" 2>&1 || echo "  (some artifacts may not exist yet)"

# 3. 整合到 deploy/<platform>/
echo "=== Staging deploy/<platform>/ ==="
stage() {
  local plat=$1
  local ort_subdir=$2
  local ocv_subdir=$3
  local target="$DEPLOY_DIR/$plat"
  rm -rf "$target"
  mkdir -p "$target"

  if [ -d "$ORT_DIR/$ort_subdir" ]; then
    cp -r "$ORT_DIR/$ort_subdir"/* "$target/"
    echo "  ✓ $plat ← ORT/$ort_subdir"
  else
    echo "  ✗ $plat ← ORT/$ort_subdir (missing)"
  fi

  if [ -d "$OCV_DIR/$ocv_subdir" ]; then
    cp "$OCV_DIR/$ocv_subdir"/* "$target/"
    echo "  ✓ $plat ← OpenCvSharp/$ocv_subdir"
  else
    echo "  ✗ $plat ← OpenCvSharp/$ocv_subdir (missing)"
  fi
}

stage win-x64       onnxruntime-1.25.0-win-x64-dml       win-x64
stage win-x86       onnxruntime-1.25.0-win-x86-cpu       win-x86
stage win-arm64     onnxruntime-1.25.0-win-arm64-dml     win-arm64
stage osx-x64       onnxruntime-1.25.0-osx-x64-coreml    osx-x64-slice
stage osx-arm64     onnxruntime-1.25.0-osx-arm64-coreml  osx-arm64-slice
stage linux-x64     onnxruntime-1.25.0-linux-x64-cpu     linux-x86_64
stage linux-arm64   onnxruntime-1.25.0-linux-arm64-cpu   linux-aarch64
stage linux-x64-cuda     onnxruntime-1.25.0-linux-x64-cuda     linux-x86_64
stage linux-x64-rocm     onnxruntime-1.25.0-linux-x64-rocm     linux-x86_64
stage linux-x64-openvino onnxruntime-1.25.0-linux-x64-openvino linux-x86_64

echo ""
echo "=== Final deploy/ tree ==="
find "$DEPLOY_DIR" -type f | sort
