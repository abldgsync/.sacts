#!/usr/bin/env bash
# Golang 同步一体化脚本:按步骤参数(S1/S2/S3/S4)调用对应函数
# 调用方式: bash sync.sh S1 | S2 | S3 | S4
# 入参(环境变量): WANT / BASE_URL(S1 会把 VTAG/GOVERSION/BASE 写回 GITHUB_ENV)
set -euo pipefail

main() {
  # ---------- S1: 解析版本并生成下载/校验清单 ----------
  step1() {
    local jfile='dl.json'
    if ! curl --retry 3 --retry-all-errors --retry-delay 2 \
      --connect-timeout 15 --max-time 1800 -4fsSLo "$jfile" \
      "${BASE_URL}?mode=json&include=all"; then
      echo "::error::获取版本清单失败: ${BASE_URL}"
      exit 1
    fi
    if ! jq -e 'type == "array" and length > 0' "$jfile" > /dev/null 2>&1; then
      echo "::error::获取的版本清单不是有效的JSON数组"
      exit 1
    fi
    local sel='.stable == true'
    local want=""
    if [[ -n "${WANT:-}" ]]; then
      want="go${WANT#go}"
      sel='.stable == true and .version == "'${want}'"'
    fi
    local VN="$(jq -r "map(select(${sel})) | first | .version // empty" "$jfile")"
    if [[ -z "${VN}" ]]; then
      echo "::error::未找到匹配的稳定版本${want:+: ${want}}"
      exit 1
    fi
    if [[ "${VN}" =~ (rc|beta|alpha) ]]; then
      echo "::error::解析到预发布版本 ${VN},请显式指定稳定版本号"
      exit 1
    fi
    local JQPAT='map(select(.version == $vn))'
    JQPAT+='|.[0].files[]?'
    JQPAT+='|select(.sha256 != null and .sha256 != "")'
    JQPAT+='|"\(.sha256) \(.filename)"'
    jq -r --arg vn "${VN}" "${JQPAT}" "$jfile" > "$PKGSUMS"
    if [[ ! -s "$PKGSUMS" ]]; then
      echo "::error::未找到任何可下载资源"
      exit 1
    fi
    {
      echo "VTAG=v${VN#go}"
      echo "GOVERSION=${VN}"
      echo "BASE=${BASE_URL}"
    } >> "$GITHUB_ENV"
    echo "解析到版本: ${VN} ($(wc -l < "$PKGSUMS") 个资源)"
  }

  # ---------- S2: 并行下载二进制包 ----------
  step2() {
    mkdir -p dist
    download_one() {
      local sum="$1" name="$2"
      local url="${BASE}${name}"
      for i in 1 2 3; do
        if curl --retry 3 --retry-all-errors --retry-delay 2 \
          --connect-timeout 15 --max-time 1800 \
          -4fsSLo "dist/${name}" "${url}"; then
          return 0
        fi
        sleep $((i * 3))
      done
      echo "::error::下载失败: ${url}"
      return 1
    }
    export -f download_one
    xargs -P 8 -n 2 bash -c 'download_one "$@"' _ < "${PKGSUMS}"
    echo "下载完成,文件数: $(find dist -type f | wc -l)"
  }
  # ---------- S3: 校验 SHA256 ----------
  step3() {
    # 直接执行(不在 if 中),确保校验失败时以非 0 退出,使 set -e 中止流程
    cd dist
    sha256sum -c "${PKGSUMS}"
    echo "共 $(wc -l < "${PKGSUMS}") 个文件,SHA256 校验通过"
  }
  # ---------- 调度 ----------
  local PKGSUMS="${RUNNER_TEMP}/manifest.sums"
  case $1 in
    [Ss][123]) eval "step${1#[sS]}" ;;
    *) echo "用法: $0 S1|S2|S3" && exit 1 ;;
  esac
}
main "$@"
