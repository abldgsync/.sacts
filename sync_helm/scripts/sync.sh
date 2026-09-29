#!/usr/bin/env bash
# Helm 同步一体化脚本:按步骤参数(S1/S2/S3/S4)调用对应函数
# 调用方式: bash sync.sh S1 | S2 | S3 | S4
# 入参(环境变量): WANT / API / GH_TOKEN(S1 会把 VTAG/BASE 写回 GITHUB_ENV)
set -euo pipefail

# ---------- S1: 解析版本并生成下载清单 ----------
s1_resolve() {
  # auth 仅 S1 使用,且 GH_TOKEN 仅在 S1 步骤注入;定义在函数内避免其它步骤触发 set -u 未绑定错误
  local auth=(-H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json")
  local tag VN
  if [[ -n "${WANT:-}" ]]; then
    tag="v${WANT#v}"
    curl -fsSL --retry 3 --retry-delay 2 "${auth[@]}" "${API}/tags/${tag}" -o rel.json
  else
    curl -fsSL --retry 3 --retry-delay 2 "${auth[@]}" "${API}/latest" -o rel.json
  fi
  VN=$(jq -r '.tag_name' rel.json)
  if [[ "${VN}" =~ -(rc|beta|alpha) ]]; then
    echo "::error::解析到预发布版本 ${VN},请显式指定稳定版本号"
    exit 1
  fi
  jq -r '.assets[].name | select(endswith(".sha256.asc")) | rtrimstr(".sha256.asc")' rel.json | grep -v 'loong' > "${RUNNER_TEMP}/manifest.txt"
  if [[ ! -s "${RUNNER_TEMP}/manifest.txt" ]]; then
    echo "::error::未找到任何可下载资源"
    exit 1
  fi
  {
    echo "VTAG=${VN}"
    echo "BASE=https://get.helm.sh/"
  } >> "$GITHUB_ENV"
  echo "解析到版本: ${VN} ($(wc -l < "${RUNNER_TEMP}/manifest.txt") 个资源)"
}

# ---------- S2: 并行下载二进制包 ----------
s2_download() {
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
}

# ---------- S3: 校验 SHA256 ----------
s3_verify() {
  local fail=0 name sum actual
  while read -r name; do
    sum=$(curl -4fsSL --retry 3 "${BASE}${name}.sha256" | awk '{print $1}')
    actual=$(sha256sum "dist/${name}" | awk '{print $1}')
    if [[ "${sum}" != "${actual}" ]]; then
      echo "::error::校验失败: ${name}"
      fail=1
    fi
  done < "${RUNNER_TEMP}/manifest.txt"
  exit ${fail}
}

# ---------- S4: 发布(占位) ----------
# Helm 的发布由 action.yaml 中的 softprops/action-gh-release 步骤完成,
# 本脚本不负责发布,此处保留空实现以对齐 S1..S4 统一调用约定。
s4_publish() {
  echo "::notice::Helm 发布由 softprops/action-gh-release 步骤处理,sync.sh 不执行 S4"
}

# ---------- 调度 ----------
main() {
  local step="${1:-}"
  case "${step}" in
    S1|s1) s1_resolve ;;
    S2|s2) s2_download ;;
    S3|s3) s3_verify ;;
    S4|s4) s4_publish ;;
    *) echo "::error::未知步骤: ${step:-<空>}, 用法: $0 S1|S2|S3|S4"; exit 1 ;;
  esac
}
main "$@"
