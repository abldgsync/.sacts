#!/usr/bin/env bash
# 阶段3:逐个校验 Helm 包 SHA256
set -euo pipefail

fail=0
while read -r name; do
  sum=$(curl -4fsSL --retry 3 "${BASE}${name}.sha256" | awk '{print $1}')
  actual=$(sha256sum "dist/${name}" | awk '{print $1}')
  if [[ "${sum}" != "${actual}" ]]; then
    echo "::error::校验失败: ${name}"
    fail=1
  fi
done < "${RUNNER_TEMP}/manifest.txt"
exit ${fail}
