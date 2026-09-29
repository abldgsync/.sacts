#!/usr/bin/env bash
# 阶段3:校验 Golang 包 SHA256
set -euo pipefail

cd dist
if sha256sum -c "${RUNNER_TEMP}/manifest.sums"; then
  echo "共 $(wc -l < "${RUNNER_TEMP}/manifest.sums") 个文件,SHA256 校验通过"
fi
