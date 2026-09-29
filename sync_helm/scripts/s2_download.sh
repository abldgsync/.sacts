#!/usr/bin/env bash
# 阶段2:并行下载 Helm 二进制包(依赖阶段1写入的 BASE / RUNNER_TEMP/manifest.txt)
set -euo pipefail

mkdir -p dist
download_one() {
  local name="$1"
  for i in 1 2 3; do
    if curl -4fL --retry 3 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 1200 -o "dist/${name}" "${BASE}${name}"; then
      return 0
    fi
    sleep $((i * 3))
  done
  echo "::error::下载失败: ${name}"
  return 1
}
export -f download_one
xargs -a "${RUNNER_TEMP}/manifest.txt" -I{} -P 8 bash -c 'download_one "$@"' _ {}
echo "下载完成,文件数: $(find dist -type f | wc -l)"
