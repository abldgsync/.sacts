#!/usr/bin/env bash
# 阶段3:校验 Zig 包 SHA256,并写入 Job Summary
set -euo pipefail

cd dist
sha256sum -c "${RUNNER_TEMP}/manifest.sums"
{
  echo "### Zig ${ZIGVERSION}"
  echo ""
  echo "共 $(wc -l < "${RUNNER_TEMP}/manifest.sums") 个文件,SHA256 校验通过:"
  echo ""
  echo '```'
  awk '{print $2}' "${RUNNER_TEMP}/manifest.sums"
  echo '```'
} >> "${GITHUB_STEP_SUMMARY}"
