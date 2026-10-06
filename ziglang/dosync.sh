#!/usr/bin/env bash
# Zig 同步一体化脚本:按 CS 环境变量(1~4)调用对应函数
# 调用方式: CS=1 bash dosync.sh (阶段 1~4,如 CS=2;不传 CS 报错退出)
# 入参(环境变量):
#   WANT   - 可选版本约束:
#            空        -> 取最新 LAST_N 个稳定版
#            0.15.2    -> 精确版本(须为稳定版)
#            0.15      -> 取 0.15 系列最新 LAST_N 个
#   LAST_N - 保留的最新稳定版本数量(默认 4);设 1 则仅同步最新一个
#   GH_TOKEN - 由 action.yaml 在 S4 步骤注入(供 gh 发布使用);S1 拉取公开 index 无需鉴权
# 产物与步骤:
#   S1 解析稳定版本 -> 生成 ${VN}-manifest.txt,并把版本列表写入 FILE_VERSIONS(versions.txt)
#      后续步骤(S2/S3/S4)统一从 FILE_VERSIONS 读取待操作版本
#   S2 并行下载到 dist/${VN}/
#   S3 用官方 sha256(manifest 内的 shasum)逐文件校验
#   S4 逐个版本(v 前缀 tag)gh release create 发布(首个标 --latest,已存在则先删后建)
set -euo pipefail
main() {
  export CURL_OPTS="--retry 3 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 1800"
  export RUNNER_TEMP="${RUNNER_TEMP:-$PWD}"
  export FILE_VERSIONS="${RUNNER_TEMP}/versions.txt"
  export FILE_ALL_TAGS="${RUNNER_TEMP}/all_tags.txt"
  export FILE_INDEXJSON="${RUNNER_TEMP}/index.json"
  export INDEX_URL="https://ziglang.org/download/index.json"
  export LAST_N="${LAST_N:-4}"

  # ---------- S1: 解析版本并生成下载清单 ----------
  step1() {
    if [ ! -f "${FILE_INDEXJSON}" ]; then
      if ! curl ${CURL_OPTS} -4fsSL -o "${FILE_INDEXJSON}" "${INDEX_URL}"; then
        echo "::error::获取版本清单失败: ${INDEX_URL}"
        exit 1
      fi
      if ! jq -e 'type == "object"' "${FILE_INDEXJSON}" > /dev/null 2>&1; then
        echo "::error::获取的版本清单不是有效的JSON对象"
        exit 1
      fi
    fi
    ## 获取全部版本列表
    # jq -r 'keys[]' "${FILE_INDEXJSON}" > ${FILE_ALL_TAGS}
    jq -r 'keys[]' "${FILE_INDEXJSON}" \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
      | sort -Vr > ${FILE_ALL_TAGS}

    # 3) 按 WANT 选择版本(数量受 LAST_N 控制,默认 4)
    if [[ -z "${WANT:-}" ]]; then
      # 不传: 取整体最新的 LAST_N 个稳定版
      head -n "${LAST_N}" ${FILE_ALL_TAGS} > ${FILE_VERSIONS}
    else
      # 传前缀(如 0.15): 取该系列最新的 LAST_N 个; 精确版本(如 0.15.2)也按 LAST_N 截断
      awk '/^.'"${WANT#[Vv]}"'\./' "${FILE_ALL_TAGS}" | head -n "${LAST_N}" > ${FILE_VERSIONS}
    fi
    if [[ $(wc -l < "${FILE_VERSIONS}") -eq 0 ]]; then
      echo "::error::未匹配到任何稳定版本(输入: ${WANT:-<空>})"
      exit 1
    fi

    # 生成该版本资产清单 ${VN}-manifest.txt: 每行 "<shasum>  <filename>"
    local jqpat_manifest='.[$vn] | to_entries[] | .value | select(type == "object" and (.tarball != null) and (.shasum != null)) | [.shasum, (.tarball | split("/")[-1])] | join("  ")'
    local jqpat_dld_bins='.[$vn] | to_entries[] | .value | select(type == "object" and (.tarball != null) and (.shasum != null)) | .tarball'
    local VN && for VN in $(xargs < "${FILE_VERSIONS}"); do
      local mf="${RUNNER_TEMP}/${VN}-manifest.txt"
      local bf="${RUNNER_TEMP}/${VN}-binfiles.txt"
      jq -r --arg vn "${VN}" "${jqpat_manifest}" "${FILE_INDEXJSON}" > "${mf}"
      jq -r --arg vn "${VN}" "${jqpat_dld_bins}" "${FILE_INDEXJSON}" > "${bf}"
      echo "解析到版本: ${VN} ($(wc -l < ${mf}) 个资源)"
    done
  }

  # ---------- S2: 并行下载二进制包(按版本循环) ----------
  step2() {
    mkdir -p dist
    local VN bf
    for VN in $(xargs < "${FILE_VERSIONS}"); do
      [[ -z "${VN}" ]] && continue
      echo "=====> [S2] 下载版本: ${VN}"
      bf="${RUNNER_TEMP}/${VN}-binfiles.txt"
      if [[ ! -s "${bf}" ]]; then
        echo "::error::未找到版本 ${VN} 的下载清单"
        exit 1
      fi
      rm -rf "dist/${VN}"
      mkdir -p "dist/${VN}"
      if ! CURL_OPTS="${CURL_OPTS}" VN="${VN}" xargs -a "${bf}" -P 8 -I@ bash -c '
        url="$1"
        name="${url##*/}"
        echo "  -> [${VN}] 下载: ${name}"
        if ! curl ${CURL_OPTS} -4fL -o "dist/${VN}/${name}" "${url}"; then
          echo "::error::下载失败: ${url}"
          exit 1
        fi
        ' _ @; then
        echo "::error::版本 ${VN} 下载失败"
        exit 1
      fi
    done
    echo "下载完成,文件数: $(find dist -type f | wc -l)"
  }

  # ---------- S3: 校验 SHA256(按版本循环) ----------
  step3() {
    local VN mf fail=0
    while IFS= read -r VN; do
      [[ -z "${VN}" ]] && continue
      mf="${RUNNER_TEMP}/${VN}-manifest.txt"
      if [[ ! -s "${mf}" ]]; then
        echo "::warning::跳过无校验清单的版本 ${VN}"
        continue
      fi
      echo "=====> [S3] 校验版本: ${VN}"
      if ! (cd "dist/${VN}" && sha256sum -c "${mf}"); then
        echo "::error::校验失败: ${VN}"
        fail=1
      fi
    done < "${FILE_VERSIONS}"
    if [[ ${fail} -ne 0 ]]; then
      echo "::error::存在校验失败的版本"
      exit 1
    fi
    echo "SHA256 校验通过"
  }

  # ---------- S4: 发布到 GitHub Releases(按版本循环) ----------
  # tag 采用 v 前缀(v${VN})以延续历史 release 命名;已存在的 release 先删后建。
  # 需要 GH_TOKEN(由 action.yaml 的 S4 步骤注入)供 gh CLI 使用。
  step4() {
    local VN first=1 TAG
    while IFS= read -r VN; do
      [[ -z "$VN" ]] && continue
      TAG="v${VN}"
      echo "=====> [S4] 发布版本: ${TAG}"
      if gh release view "${TAG}" > /dev/null 2>&1; then
        echo "::notice::已存在 release ${TAG}, 先删除再重建"
        gh release delete "${TAG}" -y
      fi
      if [[ $first -eq 1 ]]; then
        gh release create "${TAG}" dist/"${VN}"/* \
          --title "Zig ${VN} Binaries" \
          --notes "同步自 Zig 官网的二进制程序 (版本: ${VN}, 官网: https://ziglang.org/download/${VN})"
        first=0
      else
        gh release create "${TAG}" dist/"${VN}"/* \
          --title "Zig ${VN} Binaries" \
          --notes "同步自 Zig 官网的二进制程序 (版本: ${VN}, 官网: https://ziglang.org/download/${VN})" \
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
