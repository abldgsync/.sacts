#!/usr/bin/env bash
# 阶段3:逐个版本校验 dist/<版本>/ 下的二进制 SHA256
# 依赖: RUNNER_TEMP/versions.txt 与 download.sh 生成的 dist/<版本>/manifest.sums
set -euo pipefail

while IFS= read -r VN; do
  [[ -z "${VN}" ]] && continue
  echo "=====> [verify] 校验版本: ${VN}"
  if [[ ! -f "dist/${VN}/manifest.sums" ]]; then
    echo "::warning::跳过未下载的版本 ${VN}"; continue
  fi
  ( cd "dist/${VN}" && sha256sum -c manifest.sums )
  echo "<===== [verify] 通过版本: ${VN}"
done < "${RUNNER_TEMP}/versions.txt"
