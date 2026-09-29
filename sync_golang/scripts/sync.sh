#!/usr/bin/env bash
# Golang 同步一体化脚本:按步骤参数(S1/S2/S3/S4)调用对应函数
# 调用方式: bash sync.sh S1 | S2 | S3 | S4
# 入参(环境变量): WANT / BASE_URL(S1 会把 VTAG/GOVERSION/BASE 写回 GITHUB_ENV)
set -euo pipefail

# ---------- S1: 解析版本并生成下载/校验清单 ----------
s1_resolve() {
  local want=""
  if [[ -n "${WANT:-}" ]]; then want="go${WANT#go}"; fi
  if ! curl -4fsSLo dl.json --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 "${BASE_URL}?mode=json&include=all"; then
    echo "::error::获取版本清单失败: ${BASE_URL}"
    exit 1
  fi
  if ! jq -e 'type == "array" and length > 0' dl.json > /dev/null 2>&1; then
    echo "::error::获取的版本清单不是有效的JSON数组"
    exit 1
  fi
  local sel='.stable == true'
  if [[ -n "${want}" ]]; then sel="${sel} and .version == \"${want}\""; fi
  local VN
  VN="$(jq -r "map(select(${sel})) | first | .version // empty" dl.json)"
  if [[ -z "${VN}" ]]; then
    echo "::error::未找到匹配的稳定版本${want:+: ${want}}"
    exit 1
  fi
  if [[ "${VN}" =~ (rc|beta|alpha) ]]; then
    echo "::error::解析到预发布版本 ${VN},请显式指定稳定版本号"
    exit 1
  fi
  jq -r --arg vn "${VN}" 'map(select(.version == $vn)) | .[0].files[]? | select(.sha256 != null and .sha256 != "") | "\(.sha256)  \(.filename)"' dl.json > "${RUNNER_TEMP}/manifest.sums"
  if [[ ! -s "${RUNNER_TEMP}/manifest.sums" ]]; then
    echo "::error::未找到任何可下载资源"
    exit 1
  fi
  {
    echo "VTAG=v${VN#go}"
    echo "GOVERSION=${VN}"
    echo "BASE=${BASE_URL}"
  } >> "$GITHUB_ENV"
  echo "解析到版本: ${VN} ($(wc -l < "${RUNNER_TEMP}/manifest.sums") 个资源)"
}

# ---------- S2: 并行下载二进制包 ----------
s2_download() {
  mkdir -p dist
  download_one() {
    local sum="$1" name="$2"
    local url="${BASE}${name}"
    for i in 1 2 3; do
      if curl -4fL --retry 3 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 1800 -o "dist/${name}" "${url}"; then
        return 0
      fi
      sleep $((i * 3))
    done
    echo "::error::下载失败: ${url}"
    return 1
  }
  export -f download_one
  xargs -P 8 -n 2 bash -c 'download_one "$@"' _ < "${RUNNER_TEMP}/manifest.sums"
  echo "下载完成,文件数: $(find dist -type f | wc -l)"
}

# ---------- S3: 校验 SHA256 ----------
s3_verify() {
  cd dist
  # 直接执行(不在 if 中),确保校验失败时以非 0 退出,使 set -e 中止流程
  sha256sum -c "${RUNNER_TEMP}/manifest.sums"
  echo "共 $(wc -l < "${RUNNER_TEMP}/manifest.sums") 个文件,SHA256 校验通过"
}

# ---------- S4: 发布(占位) ----------
# Golang 的发布由 action.yaml 中的 softprops/action-gh-release 步骤完成,
# 本脚本不负责发布,此处保留空实现以对齐 S1..S4 统一调用约定。
s4_publish() {
  echo "::notice::Golang 发布由 softprops/action-gh-release 步骤处理,sync.sh 不执行 S4"
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
