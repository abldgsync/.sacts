#!/usr/bin/env bash
# 阶段2:读取 ${RUNNER_TEMP}/versions.txt,逐个版本下载/校验/发布到调用方仓库
# 入参(环境变量): WITHAIRGAP / API / GH_TOKEN / GITHUB_REPOSITORY / GITHUB_RUN_ID / GITHUB_SERVER_URL
set -euo pipefail

auth=(-H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json")
REPO="${GITHUB_REPOSITORY}"
WXAIR="${WITHAIRGAP:-1}"

while IFS= read -r VN; do
  [[ -z "${VN}" ]] && continue
  echo "=====> 处理版本: ${VN}"

  curl -fsSL --retry 3 "${auth[@]}" "${API}/tags/${VN}" -o rel.json
  if [[ "$(jq -r '.tag_name' rel.json)" =~ -(rc|beta|alpha) ]]; then
    echo "::warning::跳过预发布版本 ${VN}"; continue
  fi

  # 主二进制,默认;withairgap=1 时追加各架构离线镜像包
  pat='^k3s$|^k3s-arm64$|^k3s-armhf$'
  if [[ "${WXAIR}" == "1" ]]; then
    pat='^k3s$|^k3s-arm64$|^k3s-armhf$|^k3s-airgap-images-.*\.tar(\.gz)?$'
  fi
  jq -r --arg pat "${pat}" '.assets[].name | select(test($pat))' rel.json > "${RUNNER_TEMP}/manifest.txt"
  if [[ ! -s "${RUNNER_TEMP}/manifest.txt" ]]; then echo "::error::${VN} 未找到可下载资源"; exit 1; fi

  SUMURL=$(jq -r '.assets[] | select(.name=="sha256sums.txt") | .browser_download_url' rel.json)
  if [[ -z "${SUMURL}" || "${SUMURL}" == "null" ]]; then echo "::error::${VN} 未找到 sha256sums.txt"; exit 1; fi
  curl -4fsSL --retry 3 --retry-delay 2 "${SUMURL}" -o "${RUNNER_TEMP}/sha256sums.txt"

  # 用 manifest 与官方 sha256sums.txt 求交集,得到需要校验的行
  : > "${RUNNER_TEMP}/manifest.sums"
  while IFS= read -r line; do
    fname=$(printf '%s' "$line" | sed 's/^[^ ]*  //')
    if grep -qxF "$fname" "${RUNNER_TEMP}/manifest.txt"; then printf '%s\n' "$line" >> "${RUNNER_TEMP}/manifest.sums"; fi
  done < "${RUNNER_TEMP}/sha256sums.txt"
  if [[ ! -s "${RUNNER_TEMP}/manifest.sums" ]]; then echo "::error::${VN} 未能生成校验项"; exit 1; fi

  rm -rf dist; mkdir -p dist

  download_one() {
    local name="$1"
    for i in 1 2 3; do
      if curl -4fL --retry 3 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 1800 \
        -o "dist/${name}" "https://github.com/k3s-io/k3s/releases/download/${VN}/${name}"; then
        return 0
      fi
      sleep $((i * 3))
    done
    echo "::error::下载失败: ${name}"; return 1
  }
  export -f download_one
  xargs -a "${RUNNER_TEMP}/manifest.txt" -I{} -P 8 bash -c 'download_one "$@"' _ {}

  ( cd dist && sha256sum -c "${RUNNER_TEMP}/manifest.sums" )

  NOTES="同步自 K3s GitHub Releases 的二进制程序
    - 版本: ${VN}
    - 官网下载地址: https://github.com/k3s-io/k3s/releases/download/${VN}
    - 同步任务: ${GITHUB_SERVER_URL}/${REPO}/actions/runs/${GITHUB_RUN_ID}"
  if gh release view "${VN}" --repo "${REPO}" >/dev/null 2>&1; then
    gh release upload "${VN}" dist/* --repo "${REPO}" --clobber
  else
    gh release create "${VN}" dist/* --repo "${REPO}" --title "K3s ${VN} Binaries" --notes "${NOTES}"
  fi
  echo "<===== 完成版本: ${VN}"
done < "${RUNNER_TEMP}/versions.txt"
