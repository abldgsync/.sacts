#!/usr/bin/env bash
# 阶段4:逐个版本发布 dist/<版本>/* 到调用方仓库 Releases(已存在则追加覆盖)
# 入参(环境变量): GH_TOKEN
# 依赖: RUNNER_TEMP/versions.txt 与 download.sh 生成的 dist/<版本>/
set -euo pipefail

REPO="${GITHUB_REPOSITORY}"

shopt -s nullglob
while IFS= read -r VN; do
  [[ -z "${VN}" ]] && continue
  echo "=====> [publish] 发布版本: ${VN}"
  if [[ ! -d "dist/${VN}" ]]; then echo "::warning::跳过未下载的版本 ${VN}"; continue; fi

  # 收集该版本产物,排除校验清单本身
  files=()
  for f in "dist/${VN}"/*; do
    [[ "$(basename "$f")" == "manifest.sums" ]] && continue
    files+=("$f")
  done
  if [[ ${#files[@]} -eq 0 ]]; then echo "::error::${VN} 无可发布文件"; exit 1; fi

  NOTES="同步自 K3s GitHub Releases 的二进制程序
    - 版本: ${VN}
    - 官网下载地址: https://github.com/k3s-io/k3s/releases/download/${VN}
    - 同步任务: ${GITHUB_SERVER_URL}/${REPO}/actions/runs/${GITHUB_RUN_ID}"
  if gh release view "${VN}" --repo "${REPO}" >/dev/null 2>&1; then
    gh release upload "${VN}" "${files[@]}" --repo "${REPO}" --clobber
  else
    gh release create "${VN}" "${files[@]}" --repo "${REPO}" --title "K3s ${VN} Binaries" --notes "${NOTES}"
  fi
  echo "<===== [publish] 完成版本: ${VN}"
done < "${RUNNER_TEMP}/versions.txt"
