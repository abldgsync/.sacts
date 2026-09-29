#!/usr/bin/env bash
# 阶段1:解析 Golang 版本并生成下载/校验清单(写入 RUNNER_TEMP/manifest.sums)
# 入参(环境变量): WANT / BASE_URL
set -euo pipefail

want=""
if [[ -n "${WANT:-}" ]]; then want="go${WANT#go}"; fi
if ! curl -4fsSLo dl.json --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 "${BASE_URL}?mode=json&include=all"; then
  echo "::error::获取版本清单失败: ${BASE_URL}"
  exit 1
fi
if ! jq -e 'type == "array" and length > 0' dl.json > /dev/null 2>&1; then
  echo "::error::获取的版本清单不是有效的JSON数组"
  exit 1
fi
sel='.stable == true'
if [[ -n "${want}" ]]; then sel="${sel} and .version == \"${want}\""; fi
VN="$(jq -r "map(select(${sel})) | first | .version // empty" dl.json)"
if [[ -z "${VN}" ]]; then
  echo "::error::未找到匹配的稳定版本${want:+: ${want}}"
  exit 1
fi
if [[ "${VN}" =~ (rc|beta|alpha) ]]; then
  echo "::error::解析到预发布版本 ${VN},请显式指定稳定版本号"
  exit 1
fi
jq -r --arg vn "${VN}" 'map(select(.version == $vn)) | .[0].files[]? | select(.sha256 != null and .sha256 != "") | "\(.sha256)  \(.filename)"' dl.json > "${RUNNER_TEMP}/manifest.sums"
if [[ ! -s "${RUNNER_TEMP}/manifest.sums" ]]; then
  echo "::error::未找到任何可下载资源"
  exit 1
fi
echo "VTAG=v${VN#go}" >> "$GITHUB_ENV"
echo "GOVERSION=${VN}" >> "$GITHUB_ENV"
echo "BASE=${BASE_URL}" >> "$GITHUB_ENV"
echo "解析到版本: ${VN} ($(wc -l < "${RUNNER_TEMP}/manifest.sums") 个资源)"
