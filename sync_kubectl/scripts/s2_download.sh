#!/usr/bin/env bash
# 阶段2:并行下载 Kubectl 包(依赖阶段1写入的 BASE / RUNNER_TEMP/manifest.sums)
set -euo pipefail

mkdir -p dist
download_one() {
  local sum="$1" name="$2"
  local url="${BASE}/${name}"
  for i in 1 2 3; do
    if curl -4fL --retry 3 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 1200 -o "dist/${name}" "${url}"; then
      return 0
    fi
    sleep $((i * 3))
  done
  echo "::error::下载失败: ${url}"
  return 1
}
export -f download_one
xargs -P 8 -n 2 bash -c 'download_one "$@"' _ < "${RUNNER_TEMP}/manifest.sums"
echo "下载完成,文件数: $(find dist -type f | wc -l)"
