#!/usr/bin/env bash
# Kubectl 同步一体化脚本:按 CS 环境变量(1~4)调用对应函数
# 调用方式: CS=1 bash dosync.sh (阶段 1~4,如 CS=2;不传 CS 报错退出)
# 入参(环境变量):
#   WANT     - 可选版本约束:
#             空        -> 取最新两个稳定版本(如 v1.33.6 与 v1.32.4)
#             v1.33 / 1.33     -> 1.33 系列最新稳定版(如 v1.33.6)
#             v1.33.6 / 1.33.6 -> 精确版本(须为稳定版)
#   WXSV     - 是否包含 SERVER/NODE 包(默认 1:含;0:仅 client + 整合包)
#   API      - GitHub releases API(默认 kubernetes/kubernetes)
#   GH_TOKEN - 由 action.yaml 在 S1/S4 步骤注入:S1 拉取 GitHub API,S4 供 gh 发布使用
# 产物与步骤:
#   S1 解析稳定版本 -> 生成各版本 manifest-${VN}.sums(sha512+文件名),并把版本列表写入 FILE_VERSIONS(versions.txt)
#      后续步骤(S2/S3/S4)统一从 FILE_VERSIONS 读取待操作版本(不再依赖 GITHUB_ENV / 环境变量)
#   S2 并行下载到 dist/${VN}/
#   S3 用 manifest-${VN}.sums 做 sha512sum -c 校验
#   S4 逐个版本 gh release create 发布(首个标 --latest,已存在则先删后建)
set -euo pipefail
main() {
  export CURL_OPTS="--retry 3 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 1800"
  export RUNNER_TEMP="${RUNNER_TEMP:-$PWD}"
  export FILE_VERSIONS="${RUNNER_TEMP}/versions.txt"
  export FLIE_RELSJSON="${RUNNER_TEMP}/releases.json"
  export FILE_ALL_TAGS="${RUNNER_TEMP}/all_tags.txt"
  export URL_BASE="${BASE_URL:-https://dl.k8s.io/}"
  export URL_API="${API:-https://api.github.com/repos/kubernetes/kubernetes/releases}"
  export WXSV="${WXSV:-1}"

  # ---------- S1: 解析版本并生成下载/校验清单 ----------
  step1() {
    # 1) 分页拉取全部 release 并合并成单个 releases.json
    if [ ! -e ${FLIE_RELSJSON} ]; then
      echo '[]' > ${FLIE_RELSJSON}
      local page=1
      while true; do
        if ! curl ${CURL_OPTS} -fsSL "${URL_API}?per_page=100&page=${page}" -o pjson; then
          echo "::error::拉取 release 列表失败: ${URL_API}"
          exit 1
        fi
        if [[ "$(jq 'length' pjson)" -lt 100 ]]; then break; fi
        jq -s '.[0] + .[1]' ${FLIE_RELSJSON} pjson > tmp.json && mv tmp.json ${FLIE_RELSJSON}
        ((page++))
      done
      rm -f pjson
    fi
    # 从 releases.json 中取出 tag_name 并写入 ${atags}
    jq -r '.[]|select(.prerelease==false)|.tag_name' ${FLIE_RELSJSON} > ${FILE_ALL_TAGS}

    # 3) 按 WANT 选择版本
    if [[ -z "${WANT:-}" ]]; then
      # 不传: 各 major 取最新, 再取版本最新的4个 major
      head -n 4 ${FILE_ALL_TAGS} > ${FILE_VERSIONS}
    else
      awk '/^.'"${WANT#[Vv]}"'\./' "${FILE_ALL_TAGS}" | head -n 1> ${FILE_VERSIONS}
    fi
    if [[ $(wc -l < "${FILE_VERSIONS}") -eq 0 ]]; then
      echo "::error::未匹配到任何稳定版本(输入: ${WANT:-<空>})"
      exit 1
    fi

    local VN mf && for VN in $(xargs < ${FILE_VERSIONS}); do
      curl -fsSL "${URL_BASE}${VN}/SHA512SUMS" | awk '/.tar.gz$/' > tmpsums
      if [[ "${WXSV}" == "1" ]]; then
        awk '!/(test|manifest)/' tmpsums
      else
        awk '!/(test|manifest|server|node)/' tmpsums
      fi > "${RUNNER_TEMP}/manifest-${VN}.txt"
      rm -f tmpsums
    done
    echo "解析到版本: $(xargs < ${FILE_VERSIONS}) (共 $(wc -l < "${FILE_VERSIONS}") 个)"
  }

  # ---------- S2: 并行下载二进制包(按版本循环) ----------
  step2() {
    mkdir -p dist
    download_one() {
      local sum="$1" name="$2"
      mkdir -p "dist/${VN}"
      local url="${URL_BASE}${VN}/${name}"
      for i in 1 2 3; do
        if curl ${CURL_OPTS} -4fL -o "dist/${VN}/${name}" "${url}"; then
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
      mf="${RUNNER_TEMP}/manifest-${VN}.txt"
      if [[ ! -s "$mf" ]]; then
        echo "::error::未找到版本 ${VN} 的下载清单: ${mf}"
        exit 1
      fi
      xargs -P 8 -n 2 bash -c 'download_one "$@"' _ < "$mf"
    done < "${FILE_VERSIONS}"
    echo "下载完成,文件数: $(find dist -type f | wc -l)"
  }

  # ---------- S3: 校验 SHA512(按版本循环) ----------
  step3() {
    local VN mf fail=0
    while IFS= read -r VN; do
      [[ -z "$VN" ]] && continue
      echo "=====> [S3] 校验版本: ${VN}"
      mf="${RUNNER_TEMP}/manifest-${VN}.txt"
      if ! (cd "dist/${VN}" && sha512sum -c "$mf"); then
        echo "::error::校验失败: ${VN}"
        fail=1
      fi
    done < "${FILE_VERSIONS}"
    if [[ $fail -ne 0 ]]; then
      echo "::error::存在校验失败的版本"
      exit 1
    fi
    echo "SHA512 校验通过"
  }

  # ---------- S4: 发布到 GitHub Releases(按版本循环) ----------
  step4() {
    local VN first=1
    for VN in $(xargs < "${FILE_VERSIONS}"); do
      [[ -z "$VN" ]] && continue
      echo "=====> [S4] 发布版本: ${VN}"
      if gh release view "$VN" > /dev/null 2>&1; then
        echo "::notice::已存在 release ${VN}, 先删除再重建"
        gh release delete "$VN" -y
      fi
      if [[ $first -eq 1 ]]; then
        gh release create "$VN" dist/"$VN"/* \
          --title "Kubectl ${VN} Binaries" \
          --notes "同步自 Kubectl 官网的二进制程序 (版本: ${VN}, 官网: ${URL_BASE}${VN}/)"
        first=0
      else
        gh release create "$VN" dist/"$VN"/* \
          --title "Kubectl ${VN} Binaries" \
          --notes "同步自 Kubectl 官网的二进制程序 (版本: ${VN}, 官网: ${URL_BASE}${VN}/)" \
          --latest=false
      fi
    done
  }

  # ---------- 调度 ----------
  case ${CS:-} in
    [1234]) eval "step${CS}" ;;
    *) echo "::error::非法阶段 CS=${CS}(仅支持 1~4)" && exit 1 ;;
  esac
}
main "$@"
