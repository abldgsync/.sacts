#!/usr/bin/env bash
# 阶段1:解析 Helm 版本并生成下载清单(写入 RUNNER_TEMP/manifest.txt)
# 入参(环境变量): WANT / API / GH_TOKEN
set -euo pipefail

auth=(-H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json")
if [[ -n "${WANT:-}" ]]; then
  tag="v${WANT#v}"
  curl -fsSL --retry 3 --retry-delay 2 "${auth[@]}" "${API}/tags/${tag}" -o rel.json
else
  curl -fsSL --retry 3 --retry-delay 2 "${auth[@]}" "${API}/latest" -o rel.json
fi
VN=$(jq -r '.tag_name' rel.json)
if [[ "${VN}" =~ -(rc|beta|alpha) ]]; then
  echo "::error::解析到预发布版本 ${VN},请显式指定稳定版本号"
  exit 1
fi
jq -r '.assets[].name | select(endswith(".sha256.asc")) | rtrimstr(".sha256.asc")' rel.json | grep -v 'loong' > "${RUNNER_TEMP}/manifest.txt"
if [[ ! -s "${RUNNER_TEMP}/manifest.txt" ]]; then
  echo "::error::未找到任何可下载资源"
  exit 1
fi
echo "VTAG=${VN}" >> "$GITHUB_ENV"
echo "BASE=https://get.helm.sh/" >> "$GITHUB_ENV"
echo "解析到版本: ${VN} ($(wc -l < "${RUNNER_TEMP}/manifest.txt") 个资源)"
