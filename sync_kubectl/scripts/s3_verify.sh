#!/usr/bin/env bash
# 阶段3:校验 Kubectl 包 SHA512
set -euo pipefail

cd dist
sha512sum -c "${RUNNER_TEMP}/manifest.sums"
