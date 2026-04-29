#!/usr/bin/env bash
# 一键下载最近成功的 Verify Built Artifacts run 的最终 deploy bundle 到本地 deploy/
#
# Stage Deploy 已经合并进 Verify 工作流的 stage-deploy job (依赖全 7 verify ✅),
# 所以一个 verify run 的 'deploy-1.25.0-<sha>' artifact = 完整 deploy/。
#
# 用法:
#   ./download_deploy.sh                    # 用最近成功的 Verify run
#   ./download_deploy.sh <verify_run_id>    # 指定 run ID

set -euo pipefail
REPO="${REPO:-starskylzc/BuildOpenvino}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="$HERE/deploy"

VERIFY_RUN="${1:-}"
if [ -z "$VERIFY_RUN" ]; then
  VERIFY_RUN=$(gh run list -R "$REPO" \
    --workflow="Verify Built Artifacts (C# 端到端测试)" \
    --status=success --branch=main --limit=1 \
    --json databaseId --jq '.[0].databaseId')
  if [ -z "$VERIFY_RUN" ] || [ "$VERIFY_RUN" = "null" ]; then
    echo "::error::没找到成功的 Verify run。请先 trigger:"
    echo "    gh workflow run 'Verify Built Artifacts (C# 端到端测试)' --ref main -f target_set=all"
    exit 1
  fi
  echo ">>> Using latest success Verify run: $VERIFY_RUN"
fi

ARTIFACT_NAME=$(gh api "repos/$REPO/actions/runs/$VERIFY_RUN/artifacts" \
  --jq '.artifacts[] | select(.name | startswith("deploy-1.25.0-")) | .name' | head -1)
if [ -z "$ARTIFACT_NAME" ]; then
  echo "::error::Verify run $VERIFY_RUN 没找到 deploy-1.25.0-* artifact (stage-deploy job 没跑或没全 ✅)"
  exit 1
fi
echo ">>> Artifact: $ARTIFACT_NAME"

rm -rf "$DEPLOY_DIR"
gh run download "$VERIFY_RUN" -R "$REPO" -n "$ARTIFACT_NAME" -D "$DEPLOY_DIR"

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
