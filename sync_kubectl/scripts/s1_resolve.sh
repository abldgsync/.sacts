#!/usr/bin/env bash
# 阶段1:解析 Kubectl 版本并生成下载/校验清单(写入 RUNNER_TEMP/manifest.sums)
# 入参(环境变量): WANT / WXSV / API / GH_TOKEN
set -euo pipefail

auth=(-H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json")
vnstr=latest
if [[ -n "${WANT:-}" ]]; then vnstr="tags/v${WANT#v}"; fi
VN=$(curl -fsSL --retry 3 --retry-delay 2 "${auth[@]}" "${API}/${vnstr}" | jq -r '.tag_name')
if [[ "${VN}" =~ -(rc|beta|alpha) ]]; then
  echo "::error::解析到预发布版本 ${VN},请显式指定稳定版本号"
  exit 1
fi
curl -fsSL --retry 3 "https://dl.k8s.io/${VN}/SHA512SUMS" -o "${RUNNER_TEMP}/SHA512SUMS"
pat='kubernetes\.tar\.gz$|kubernetes-client-.*tar\.gz$'
if [[ "${WXSV:-0}" == "1" ]]; then
  pat='kubernetes-(client|server|node)-.*tar\.gz$'
fi
grep -E "$pat" "${RUNNER_TEMP}/SHA512SUMS" > "${RUNNER_TEMP}/manifest.sums"
grep -v 'loong' "${RUNNER_TEMP}/manifest.sums" > "${RUNNER_TEMP}/manifest.filtered.txt"
mv "${RUNNER_TEMP}/manifest.filtered.txt" "${RUNNER_TEMP}/manifest.sums"
if [[ ! -s "${RUNNER_TEMP}/manifest.sums" ]]; then
  echo "::error::未找到任何可下载资源"
  exit 1
fi
echo "VTAG=${VN}" >> "$GITHUB_ENV"
echo "BASE=https://dl.k8s.io/${VN}" >> "$GITHUB_ENV"
echo "解析到版本: ${VN} ($(wc -l < "${RUNNER_TEMP}/manifest.sums") 个资源)"
