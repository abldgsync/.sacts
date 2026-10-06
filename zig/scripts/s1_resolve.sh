#!/usr/bin/env bash
# 阶段1:解析 Zig 版本并生成下载/校验清单(写入 RUNNER_TEMP/manifest.sums)
# 入参(环境变量): WANT / INDEX_URL
set -euo pipefail

if ! curl -4fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 -o "${RUNNER_TEMP}/index.json" "${INDEX_URL}"; then
  echo "::error::获取版本清单失败: ${INDEX_URL}"
  exit 1
fi
if ! jq -e 'type == "object"' "${RUNNER_TEMP}/index.json" >/dev/null 2>&1; then
  echo "::error::获取的版本清单不是有效的JSON对象"
  exit 1
fi
want="${WANT:-}"
if [[ -n "${want}" ]]; then
  if ! jq -e --arg v "${want}" 'has($v)' "${RUNNER_TEMP}/index.json" >/dev/null 2>&1; then
    echo "::error::未找到指定版本: ${want}"
    exit 1
  fi
  VN="${want}"
else
  VN=$(jq -r 'keys[]' "${RUNNER_TEMP}/index.json" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -Vr | head -n 1)
  if [[ -z "${VN}" ]]; then
    echo "::error::无法解析最新稳定版本"
    exit 1
  fi
fi
if [[ "${VN}" =~ (-dev|rc|beta|alpha) ]]; then
  echo "::error::解析到预发布版本 ${VN},请显式指定稳定版本号"
  exit 1
fi
jq -r --arg vn "${VN}" '.[$vn] | to_entries[] | .value | select(type == "object" and (.tarball != null) and (.shasum != null)) | "\(.shasum)  \(.tarball | sub(".*/"; ""))"' "${RUNNER_TEMP}/index.json" > "${RUNNER_TEMP}/manifest.sums"
if [[ ! -s "${RUNNER_TEMP}/manifest.sums" ]]; then
  echo "::error::未找到任何可下载资源"
  exit 1
fi
echo "VTAG=v${VN}" >> "$GITHUB_ENV"
echo "ZIGVERSION=${VN}" >> "$GITHUB_ENV"
echo "BASE=https://ziglang.org/download/${VN}" >> "$GITHUB_ENV"
echo "解析到版本: ${VN} ($(wc -l < "${RUNNER_TEMP}/manifest.sums") 个资源)"
