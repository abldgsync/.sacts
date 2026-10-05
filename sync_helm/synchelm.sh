#!/usr/bin/env bash
# Helm 同步一体化脚本:按步骤参数(S1/S2/S3/S4)调用对应函数
# 调用方式: bash synchelm.sh S1 | S2 | S3 | S4
# 入参(环境变量):
#   WANT   - 可选版本约束:
#            空        -> 取最新两个稳定版本(默认如 v4.3.0 与 v3.22.0)
#            v3 / 3    -> v3 系列最新稳定版(如 v3.22.0)
#            v3.19     -> v3.19 系列最新 patch(如 v3.19.5)
#            v3.19.2   -> 精确版本(须为稳定版)
#   GH_TOKEN - 由 action.yaml 在 S1/S4 步骤注入:S1 拉取 GitHub API,S4 供 gh 发布使用
# 产物与步骤:
#   S1 解析稳定版本 -> 生成 manifest-${VN}.txt,并把版本列表写入 FILE_VERSIONS(versions.txt)
#      后续步骤(S2/S3/S4)统一从 FILE_VERSIONS 读取待操作版本(不再依赖 GITHUB_ENV / VERSIONS 环境变量)
#   S2 并行下载到 dist/${VN}/
#   S3 联网取 ${name}.sha256 与本地 sha256sum 比对校验
#   S4 逐个版本 gh release create 发布(首个标 --latest,已存在则先删后建)
set -euo pipefail
main() {
  export CURL_OPTS="--retry 3 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 1800"
  export RUNNER_TEMP="${RUNNER_TEMP:-$PWD}"
  export FILE_RELSJSON="${RUNNER_TEMP}/releases.json"
  export FILE_VERSIONS="${RUNNER_TEMP}/versions.txt"
  export FILE_ALL_TAGS="${RUNNER_TEMP}/all_tags.txt"
  export URL_BASE="https://get.helm.sh/"
  export URL_API="https://api.github.com/repos/helm/helm/releases"
  # ---------- S1: 解析版本并生成下载清单 ----------
  step1() {
    # 1) 分页拉取全部 release 并合并成单个 releases.json
    if [ ! -e ${FILE_RELSJSON} ]; then
      echo '[]' > ${FILE_RELSJSON}
      local page=1
      while true; do
        if ! curl ${CURL_OPTS} -fsSL "${URL_API}?per_page=100&page=${page}" -o pjson; then
          echo "::error::拉取 release 列表失败: ${URL_API}"
          exit 1
        fi
        if [[ "$(jq 'length' pjson)" -lt 100 ]]; then break; fi
        jq -s '.[0] + .[1]' ${FILE_RELSJSON} pjson > tmp.json && mv tmp.json ${FILE_RELSJSON}
        ((page++))
      done
      rm -f pjson
    fi
    # 从 releases.json 中取出 tag_name 并写入 ${atags}
    jq -r '.[]|select(.prerelease==false)|.tag_name' ${FILE_RELSJSON} > ${FILE_ALL_TAGS}

    # 3) 按 WANT 选择版本
    if [[ -z "${WANT:-}" ]]; then
      # 不传: 各 major 取最新, 再取版本最新的两个 major
      head -n 2 ${FILE_ALL_TAGS} > ${FILE_VERSIONS}
    else
      awk '/^.'"${WANT#[Vv]}"'\./' "${FILE_ALL_TAGS}" | head -n 1> ${FILE_VERSIONS}
    fi
    if [[ $(wc -l < "${FILE_VERSIONS}") -eq 0 ]]; then
      echo "::error::未匹配到任何稳定版本(输入: ${WANT:-<空>})"
      exit 1
    fi

    # 4) 生成各版本资产清单 manifest-${VN}.txt,并把版本列表写入 FILE_VERSIONS(versions.txt)供后续步骤读取
    local jqpat_getfn='.[]'
    jqpat_getfn+='|select(.tag_name==$t)'
    jqpat_getfn+='|.assets[].name'
    jqpat_getfn+='|select(endswith(".sha256.asc"))'
    jqpat_getfn+='|rtrimstr(".sha256.asc")'
    local VN mf && while IFS= read -r VN; do
      mf="${RUNNER_TEMP}/manifest-${VN}.txt"
      jq -r --arg t "$VN" "${jqpat_getfn}" ${FILE_RELSJSON} | grep -v 'loong' > "${mf}"
      if [[ ! -s "${mf}" ]]; then
        echo "::error::版本 $VN 未找到可下载资源"
        exit 1
      fi
    done < ${FILE_VERSIONS}
    echo "解析到版本: $(xargs < ${FILE_VERSIONS}) (共 $(wc -l < "${FILE_VERSIONS}") 个)"
  }

  # ---------- S2: 并行下载二进制包(按版本循环) ----------
  step2() {
    mkdir -p dist
    download_one() {
      local VN="$1" name="$2"
      mkdir -p "dist/${VN}"
      local url="${URL_BASE}${name}"
      for i in 1 2 3; do
        if curl ${CURL_OPTS} -4fL -o "dist/${VN}/${name}" "${url}"; then
          return 0
        fi
        # 仅在前几次失败后做重试间隔,最后一次失败无需再等待
        [[ $i -lt 3 ]] && sleep $((i * 3))
      done
      echo "::error::下载失败: ${url}"
      return 1
    }
    export -f download_one
    local VN mfile
    while IFS= read -r VN; do
      [[ -z "$VN" ]] && continue
      echo "=====> [S2] 下载版本: ${VN}"
      mfile="${RUNNER_TEMP}/manifest-${VN}.txt"
      # 清单缺失/为空直接报错退出,避免 xargs 静默无作为或报晦涩错误
      if [[ ! -s "${mfile}" ]]; then
        echo "::error::未找到版本 ${VN} 的下载清单: ${mfile}"
        exit 1
      fi
      # 过滤空行/注释,避免 download_one 被传入空文件名;保留 8 路并行
      grep -vE '^(#|$)' "${mfile}" | xargs -I{} -P 8 bash -c 'download_one "$1" "$2"' _ "${VN}" {}
    done < "${FILE_VERSIONS}"
    echo "下载完成,文件数: $(find dist -type f | wc -l)"
  }

  # ---------- S3: 校验 SHA256(按版本循环) ----------
  # Helm 的校验方式是联网取得 ${name}.sha256 与本地 sha256sum 比对(源站提供独立 .sha256 文件)
  step3() {
    local fail=0 VN name sum actual mfile
    while IFS= read -r VN; do
      [[ -z "$VN" ]] && continue
      echo "=====> [S3] 校验版本: ${VN}"
      mfile="${RUNNER_TEMP}/manifest-${VN}.txt"
      while IFS= read -r name; do
        sum=$(curl ${CURL_OPTS} -4fsSL "${URL_BASE}${name}.sha256" | awk '{print $1}')
        actual=$(sha256sum "dist/${VN}/${name}" | awk '{print $1}')
        if [[ "${sum}" != "${actual}" ]]; then
          echo "::error::校验失败: ${VN}/${name}"
          fail=1
        fi
      done < "${mfile}"
    done < "${FILE_VERSIONS}"
    exit ${fail}
  }

  # ---------- S4: 发布到 GitHub Releases(按版本循环) ----------
  # 逐个 tag 发布:首个(最新)版本标 --latest,其余 --latest=false。
  # 已存在的 release 先删除再重建,保证可重复运行。
  # 需要 GH_TOKEN(由 action.yaml 的 S4 步骤注入)供 gh CLI 使用。
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
          --title "Helm ${VN} Binaries" \
          --notes "同步自 Helm 官网的二进制程序 (版本: ${VN}, 官网: https://get.helm.sh/)"
        first=0
      else
        gh release create "$VN" dist/"$VN"/* \
          --title "Helm ${VN} Binaries" \
          --notes "同步自 Helm 官网的二进制程序 (版本: ${VN}, 官网: https://get.helm.sh/)" \
          --latest=false
      fi
    done < "${FILE_VERSIONS}"
  }

  # ---------- 调度 ----------
  case $1 in
    [Ss][1234]) eval "step${1#[sS]}" ;;
    *) echo "用法: $0 S1|S2|S3|S4" && exit 1 ;;
  esac
}
main "$@"
