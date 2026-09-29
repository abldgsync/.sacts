#!/usr/bin/env bash
# 阶段2:逐个版本下载 K3s 二进制到 dist/<版本>/,并生成该校验清单 manifest.sums
# 入参(环境变量): WITHAIRGAP / API / GH_TOKEN
# 依赖: RUNNER_TEMP/versions.txt(由 resolve.sh 生成)
set -euo pipefail

auth=(-H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json")
WXAIR="${WITHAIRGAP:-1}"

# 下载单个二进制(在函数外定义,避免每次循环重复导出);失败时重试 3 次
download_one() {
  local name="$1"
  for i in 1 2 3; do
    if curl -4fL --retry 3 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 1800 \
      -o "dist/${VN}/${name}" "https://github.com/k3s-io/k3s/releases/download/${VN}/${name}"; then
      return 0
    fi
    sleep $((i * 3))
  done
  echo "::error::下载失败: ${name}"; return 1
}
export -f download_one

while IFS= read -r VN; do
  [[ -z "${VN}" ]] && continue
  echo "=====> [download] 处理版本: ${VN}"

  curl -fsSL --retry 3 "${auth[@]}" "${API}/tags/${VN}" -o rel.json
  if [[ "$(jq -r '.tag_name' rel.json)" =~ -(rc|beta|alpha) ]]; then
    echo "::warning::跳过预发布版本 ${VN}"; continue
  fi

  # 主二进制,默认;withairgap=1 时追加各架构离线镜像包
  pat='^k3s$|^k3s-arm64$|^k3s-armhf$'
  if [[ "${WXAIR}" == "1" ]]; then
    pat='^k3s$|^k3s-arm64$|^k3s-armhf$|^k3s-airgap-images-.*\.tar(\.gz)?$'
  fi
  # 待下载二进制文件路径唯一来源:rel.json 的 release assets(按 pat 过滤)
  jq -r --arg pat "${pat}" '.assets[].name | select(test($pat))' rel.json > "${RUNNER_TEMP}/manifest.txt"
  if [[ ! -s "${RUNNER_TEMP}/manifest.txt" ]]; then echo "::error::${VN} 未找到可下载资源"; exit 1; fi

  # 按版本隔离目录,避免多版本文件互相污染;清单与二进制同目录便于校验
  rm -rf "dist/${VN}"; mkdir -p "dist/${VN}"

  # 下载路径全部来自 rel.json(manifest.txt),不依赖 sha256sums.txt
  xargs -a "${RUNNER_TEMP}/manifest.txt" -P 8 -n 1 -I{} bash -c 'download_one "$1"' _ {}

  # 校验清单:文件路径取自 rel.json(manifest.txt),哈希值取自 sha256sums.txt(可选,缺失仅跳过校验)
  SUMURL=$(jq -r '.assets[] | select(.name=="sha256sums.txt") | .browser_download_url' rel.json)
  if [[ -n "${SUMURL}" && "${SUMURL}" != "null" ]]; then
    curl -4fsSL --retry 3 --retry-delay 2 "${SUMURL}" -o "${RUNNER_TEMP}/sha256sums.txt"
    # 单次遍历:以 sha256sums.txt 建立 文件名->整行 映射,再按 manifest.txt 输出,避免逐行 awk 全表扫描
    awk -F '  ' 'FNR==NR{map[$2]=$0; next} ($0 in map){print map[$0]}' \
      "${RUNNER_TEMP}/sha256sums.txt" "${RUNNER_TEMP}/manifest.txt" > "dist/${VN}/manifest.sums"
    if [[ -s "dist/${VN}/manifest.sums" ]]; then
      echo "::notice::${VN} 生成 $(wc -l < "dist/${VN}/manifest.sums") 条校验项"
    else
      echo "::warning::${VN} 未在 sha256sums.txt 匹配到校验项,移除空清单以跳过校验"
      rm -f "dist/${VN}/manifest.sums"
    fi
  else
    echo "::warning::${VN} 未找到 sha256sums.txt,跳过校验清单生成"
  fi

  echo "<===== [download] 完成版本: ${VN}"
done < "${RUNNER_TEMP}/versions.txt"
