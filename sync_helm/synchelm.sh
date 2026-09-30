#!/usr/bin/env bash
# Helm 同步一体化脚本:按步骤参数(S1/S2/S3/S4)调用对应函数
# 调用方式: bash synchelm.sh S1 | S2 | S3 | S4
# 入参(环境变量):
#   WANT   - 可选版本约束:
#            空        -> 取最新两个 major 系列各自的最新稳定版(如 v4.3.0 与 v3.22.0)
#            v3 / 3    -> v3 系列最新稳定版(如 v3.22.0)
#            v3.19     -> v3.19 系列最新 patch(如 v3.19.5)
#            v3.19.2   -> 精确版本(须为稳定版)
#   API    - GitHub releases API 基址(默认在 action.yaml 中注入)
#   GH_TOKEN - 由 action.yaml 在 S1/S4 步骤注入:S1 访问 GitHub API,S4 供 gh 发布使用
# S1 会把 VTAG/BASE/VERSIONS 写回 GITHUB_ENV,并生成 ${RUNNER_TEMP}/versions.txt 与各版本清单
set -euo pipefail
export CURL_OPTS="--retry 3 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 1800"
# export RUNNER_TEMP=${PWD}
main() {
  # ---------- S1: 解析版本并生成下载清单 ----------
  step1() {
    # auth 仅 S1 使用,且 GH_TOKEN 仅在 S1 步骤注入;定义在函数内避免其它步骤触发 set -u 未绑定错误
    # local auth=(-H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json")
    # 1) 分页拉取全部 release 并合并成单个 releases.json
    local jfile="${RUNNER_TEMP}/releases.json"
    local atags="${RUNNER_TEMP}/alltags.txt"
    if [ ! -e $jfile ]; then
      echo '[]' > $jfile
      local page=1
      local apiurl="https://api.github.com/repos/helm/helm/releases"
      while true; do
        if ! curl ${CURL_OPTS} -fsSL "${apiurl}?per_page=100&page=${page}" -o pjson; then
          echo "::error::拉取 release 列表失败: ${API}"
          exit 1
        fi
        if [[ "$(jq 'length' pjson)" -lt 100 ]]; then break; fi
        jq -s '.[0] + .[1]' $jfile pjson > tmp.json && mv tmp.json $jfile
        ((page++))
      done
      rm -f pjson
    fi
    # 从 releases.json 中取出 tag_name 并写入 ${atags}
    jq -r '.[]|select(.prerelease==false)|.tag_name' $jfile > ${atags}

    # 3) 按 WANT 选择版本
    local out=""
    if [[ -z "${WANT:-}" ]]; then
      # 不传: 各 major 取最新, 再取版本最新的两个 major
      out="$(head -n 2 ${atags} | xargs)"
    else
      out="$(awk '/^.'"${WANT#[Vv]}"'/' "${atags}" | head -n 1)"
    fi
    if [[ -z "${out}" || "${out}" == *"null"* ]]; then
      echo "::error::未匹配到任何稳定版本(输入: ${WANT:-<空>})"
      exit 1
    fi
    # rm -f alltags

    # 4) 写出版本清单 + 各版本资产清单(供 s2/s3 循环), 并写 GITHUB_ENV
    local jqpat_getfn='.[]'
    jqpat_getfn+='|select(.tag_name==$t)'
    jqpat_getfn+='|.assets[].name'
    jqpat_getfn+='|select(endswith(".sha256.asc"))'
    jqpat_getfn+='|rtrimstr(".sha256.asc")'
    local first_vn=""
    local VN && for VN in ${out}; do
      [[ -z "$VN" ]] && continue
      [[ -z "$first_vn" ]] && first_vn="$VN"
      echo "$VN" >> ${RUNNER_TEMP}/versions.txt
      local mfile="${RUNNER_TEMP}/manifest-${VN}.txt"
      jq -r --arg t "$VN" "${jqpat_getfn}" $jfile | grep -v 'loong' > "${mfile}"
      if [[ ! -s "${mfile}" ]]; then
        echo "::error::版本 $VN 未找到可下载资源"
        exit 1
      fi
    done
    # return 0

    {
      echo "VTAG=${first_vn}"
      echo "RDIR=${RUNNER_TEMP}"
      echo "BASE=https://get.helm.sh/"
      echo "VERSIONS=${out[@]}"
    } >> "$GITHUB_ENV"
    echo "解析到版本: ${out[@]} (共 $(printf '%s\n' ${out[@]} | wc -l) 个)"
  }

  # ---------- S2: 并行下载二进制包(按版本循环) ----------
  step2() {
    local vf="${RUNNER_TEMP}/versions.txt"
    if [[ ! -s "$vf" ]]; then
      echo "::error::未找到版本清单: $vf (请先运行 S1)"
      exit 1
    fi
    mkdir -p dist
    download_one() {
      local VN="$1" name="$2"
      mkdir -p "dist/${VN}"
      local url="${BASE}${name}"
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
      # 过滤空行,避免 download_one 被传入空文件名;保留 8 路并行
      grep -vE '^(#|$)' "${mfile}" | xargs -I{} -P 8 bash -c 'download_one "$1" "$2"' _ "${VN}" {}
    done < "${vf}"
    echo "下载完成,文件数: $(find dist -type f | wc -l)"
  }

  # ---------- S3: 校验 SHA256(按版本循环) ----------
  # Helm 的校验方式是联网取得 ${name}.sha256 与本地 sha256sum 比对(源站提供独立 .sha256 文件)
  step3() {
    local vf="${RUNNER_TEMP}/versions.txt"
    if [[ ! -s "$vf" ]]; then
      echo "::error::未找到版本清单: $vf (请先运行 S1)"
      exit 1
    fi
    local fail=0 VN name sum actual mfile
    while IFS= read -r VN; do
      [[ -z "$VN" ]] && continue
      echo "=====> [S3] 校验版本: ${VN}"
      mfile="${RUNNER_TEMP}/manifest-${VN}.txt"
      while IFS= read -r name; do
        sum=$(curl ${CURL_OPTS} -4fsSL "${BASE}${name}.sha256" | awk '{print $1}')
        actual=$(sha256sum "dist/${VN}/${name}" | awk '{print $1}')
        if [[ "${sum}" != "${actual}" ]]; then
          echo "::error::校验失败: ${VN}/${name}"
          fail=1
        fi
      done < "${mfile}"
    done < "${vf}"
    exit ${fail}
  }

  # ---------- S4: 发布到 GitHub Releases(按版本循环) ----------
  # 逐个 tag 发布:首个(最新)版本标 --latest,其余 --latest=false。
  # 已存在的 release 先删除再重建,保证可重复运行。
  # 需要 GH_TOKEN(由 action.yaml 的 S4 步骤注入)供 gh CLI 使用。
  step4() {
    local vf="${RUNNER_TEMP}/versions.txt"
    if [[ ! -s "$vf" ]]; then
      echo "::error::未找到版本清单: $vf (请先运行 S1)"
      exit 1
    fi
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
    done < "$vf"
  }

  # ---------- 调度 ----------
  case $1 in
    [Ss][1234]) eval "step${1#[sS]}" ;;
    *) echo "用法: $0 S1|S2|S3|S4" && exit 1 ;;
  esac
}
main "$@"
