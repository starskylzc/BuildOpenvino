#!/usr/bin/env bash
# 一键下载最近成功的 Stage Deploy run 的最终 deploy bundle 到本地 deploy/
#
# Stage Deploy 是独立工作流,接受 verify_run_id,从对应 verify run 的 7 个
# deploy-<platform> artifact 汇总成单个 deploy-1.25.0-<verify_run_id> bundle。
#
# 用法:
#   ./download_deploy.sh                  # 用最近成功的 Stage Deploy run
#   ./download_deploy.sh <stage_run_id>   # 指定 Stage Deploy run ID

set -euo pipefail
REPO="${REPO:-starskylzc/BuildOpenvino}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="$HERE/deploy"

STAGE_RUN="${1:-}"
if [ -z "$STAGE_RUN" ]; then
  STAGE_RUN=$(gh run list -R "$REPO" \
    --workflow="Stage Deploy" \
    --status=success --branch=main --limit=1 \
    --json databaseId --jq '.[0].databaseId')
  if [ -z "$STAGE_RUN" ] || [ "$STAGE_RUN" = "null" ]; then
    echo "::error::没找到成功的 Stage Deploy run。请先 trigger:"
    echo "    gh workflow run 'Stage Deploy' --ref main -f verify_run_id=<verify_run_id>"
    exit 1
  fi
  echo ">>> Using latest success Stage Deploy run: $STAGE_RUN"
fi

ARTIFACT_NAME=$(gh api "repos/$REPO/actions/runs/$STAGE_RUN/artifacts" \
  --jq '.artifacts[] | select(.name | startswith("deploy-1.25.0-")) | .name' | head -1)
if [ -z "$ARTIFACT_NAME" ]; then
  echo "::error::Stage Deploy run $STAGE_RUN 没找到 deploy-1.25.0-* artifact"
  exit 1
fi
echo ">>> Artifact: $ARTIFACT_NAME"

rm -rf "$DEPLOY_DIR"
gh run download "$STAGE_RUN" -R "$REPO" -n "$ARTIFACT_NAME" -D "$DEPLOY_DIR"

echo ""
echo ">>> Downloaded:"
ls -la "$DEPLOY_DIR"
echo ""
echo ">>> 7 个平台目录:"
for plat in win-x64 win-x86 win-arm64 osx-x64 osx-arm64 linux-x64 linux-aarch64; do
  if [ -d "$DEPLOY_DIR/$plat" ]; then
    SIZE=$(du -sh "$DEPLOY_DIR/$plat" | awk '{print $1}')
    FILES=$(find "$DEPLOY_DIR/$plat" -type f | wc -l | tr -d ' ')
    echo "  ✅ $plat ($SIZE, $FILES files)"
  else
    echo "  ❌ $plat (missing!)"
  fi
done
echo ""
echo "✅ deploy/ 就绪。Ship 给客户时按对应平台 OS 选目录即可。"
