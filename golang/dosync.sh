#!/usr/bin/env bash
# Golang 同步一体化脚本:按 CS 环境变量(1~4)调用对应函数
# 调用方式: CS=1 bash dosync.sh (阶段 1~4,如 CS=2;不传 CS 报错退出)
# 入参(环境变量):
#   WANT     - 可选版本约束:
#             空        -> 取最新两个稳定版本(如 go1.25.0 与 go1.24.5)
#             1.25 / go1.25     -> 1.25 系列最新稳定版(如 go1.25.0)
#             1.25.0 / go1.25.0 -> 精确版本(须为稳定版)
#   BASE_URL - 下载站根地址(默认 https://go.dev/dl/)
#   GH_TOKEN - 由 action.yaml 在 S4 步骤注入,供 gh 发布使用
# 产物与步骤:
#   S1 解析稳定版本 -> 生成各版本 manifest-${VN}.sums(sha256+文件名),并把版本列表写入 FILE_VERSIONS(versions.txt)
#      后续步骤(S2/S3/S4)统一从 FILE_VERSIONS 读取待操作版本
#   S2 并行下载到 dist/${VN}/
#   S3 用 manifest-${VN}.sums 做 sha256sum -c 校验
#   S4 逐个版本 gh release create 发布(首个标 --latest,已存在则先删后建)
set -euo pipefail
main() {
  # BASE_URL=https://golang.google.cn/dl/
  export CURL_OPTS="--retry 3 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 1800"
  export RUNNER_TEMP="${RUNNER_TEMP:-$PWD}"
  export FILE_VERSIONS="${RUNNER_TEMP}/versions.txt"
  export FILE_RELSJSON="${RUNNER_TEMP}/releases.json"
  export URL_BASE="${BASE_URL:-https://go.dev/dl/}"

  # ---------- S1: 解析版本并生成下载/校验清单 ----------
  step1() {
    local url_json_rels="${URL_BASE}?mode=json"
    if [ -n "${WANT:-}" ]; then
      ## fetch_all_releases_then_filter
      url_json_rels="${URL_BASE}?mode=json&include=all"
      if [ -s ${FILE_RELSJSON} ]; then
        ## 避免重复下载全量版本json
        if ! grep -q 'go1.9.2rc2.src.tar.gz' ${FILE_RELSJSON}; then
          rm -f ${FILE_RELSJSON}
        fi
      fi
    else
      if [ -s ${FILE_RELSJSON} ]; then
        ## 避免使用全量版本json
        if [ $(jq -r '.[]|select(.stable)|.version' ${FILE_RELSJSON} | wc -l) -gt 100 ]; then
          rm -f ${FILE_RELSJSON}
        fi
      fi
    fi
    if [ ! -e "${FILE_RELSJSON}" ]; then
      if ! curl ${CURL_OPTS} -4fsSLo "${FILE_RELSJSON}" "${url_json_rels}"; then
        echo "::error::获取版本清单失败: ${url_json_rels}"
        exit 1
      fi
    fi
    if ! jq -e 'type == "array" and length > 0' "${FILE_RELSJSON}" &> /dev/null; then
      echo "::error::获取的版本清单不是有效的JSON数组"
      exit 1
    else
      jq -r '.[]|select(.stable)|.version' "${FILE_RELSJSON}" > alltags.txt
    fi
    # 3) 按 WANT 选择版本
    if [[ -z "${WANT:-}" ]]; then
      # 不传: 各 major 取最新, 再取版本最新的两个 major
      head -n 2 alltags.txt > ${FILE_VERSIONS}
    else
      awk '/^..'"${WANT#[Vv]}"'\./&&!/(rc|beta|alpha)/' alltags.txt | head -n 1 > ${FILE_VERSIONS}
    fi
    local VN mf && for VN in $(xargs < ${FILE_VERSIONS}); do
      mf="${RUNNER_TEMP}/manifest-${VN}.sums"
      jq -r --arg vn "$VN" 'map(select(.version == $vn)) | .[0].files[]?
        | select(.sha256 != null and .sha256 != "")
        | "\(.sha256) \(.filename)"' "${FILE_RELSJSON}" > "${mf}"
      if [[ ! -s "${mf}" ]]; then
        echo "::error::版本 ${VN} 未找到可下载资源"
        exit 1
      fi
    done
    echo "解析到版本: $(xargs < ${FILE_VERSIONS}) (共 $(wc -l < ${FILE_VERSIONS}) 个)"
  }

  # ---------- S2: 并行下载二进制包(按版本循环) ----------
  step2() {
    mkdir -p dist
    download_one() {
      local sum="$1" name="$2"
      mkdir -p "dist/${VN}"
      local url="${URL_BASE}${name}"
      for i in 1 2 3; do
        if curl ${CURL_OPTS} -4fsSLo "dist/${VN}/${name}" "${url}"; then
          return 0
        fi
        [[ $i -lt 3 ]] && sleep $((i * 3))
      done
      echo "::error::下载失败: ${url}"
      return 1
    }
    export -f download_one
    local VN mf
    export VN
    while IFS= read -r VN; do
      [[ -z "$VN" ]] && continue
      echo "=====> [S2] 下载版本: ${VN}"
      mf="${RUNNER_TEMP}/manifest-${VN}.sums"
      # 清单缺失/为空直接报错退出,避免 xargs 静默无作为
      if [[ ! -s "$mf" ]]; then
        echo "::error::未找到版本 ${VN} 的下载清单: ${mf}"
        exit 1
      fi
      xargs -P 8 -n 2 bash -c 'download_one "$@"' _ < "$mf"
    done < "${FILE_VERSIONS}"
    echo "下载完成,文件数: $(find dist -type f | wc -l)"
  }

  # ---------- S3: 校验 SHA256(按版本循环) ----------
  step3() {
    local VN mf fail=0
    while IFS= read -r VN; do
      [[ -z "$VN" ]] && continue
      echo "=====> [S3] 校验版本: ${VN}"
      mf="${RUNNER_TEMP}/manifest-${VN}.sums"
      if ! (cd "dist/${VN}" && sha256sum -c "$mf"); then
        echo "::error::校验失败: ${VN}"
        fail=1
      fi
    done < "${FILE_VERSIONS}"
    if [[ $fail -ne 0 ]]; then
      echo "::error::存在校验失败的版本"
      exit 1
    fi
    echo "SHA256 校验通过"
  }

  # ---------- S4: 发布到 GitHub Releases(按版本循环) ----------
  # 逐个 tag 发布:首个(最新)版本标 --latest,其余 --latest=false.
  # 已存在的 release 先删除再重建,保证可重复运行.
  # 需要 GH_TOKEN/GH_REPO(由 action.yaml 的 S4 步骤注入)供 gh CLI 使用.
  step4() {
    local VN first=1
    while IFS= read -r VN; do
      [[ -z "$VN" ]] && continue
      echo "=====> [S4] 发布版本: ${VN}"
      if gh release view "$VN" > /dev/null 2>&1; then
        echo "::notice::已存在 release ${VN}, 先删除再重建"
        gh release delete "$VN" -y
      fi
      if [[ $first -eq 1 ]]; then
        gh release create "$VN" dist/"$VN"/* \
          --title "Golang ${VN} Binaries" \
          --notes "同步自 Golang 官网的二进制程序 (版本: ${VN}, 官网: ${URL_BASE})"
        first=0
      else
        gh release create "$VN" dist/"$VN"/* \
          --title "Golang ${VN} Binaries" \
          --notes "同步自 Golang 官网的二进制程序 (版本: ${VN}, 官网: ${URL_BASE})" \
          --latest=false
      fi
    done < "${FILE_VERSIONS}"
  }

  # ---------- 调度 ----------
  case ${CS:-} in
    [1234]) eval "step${CS}" ;;
    *) echo "::error::非法阶段 CS=${CS}(仅支持 1~4)" && exit 1 ;;
  esac
}
main "$@"
