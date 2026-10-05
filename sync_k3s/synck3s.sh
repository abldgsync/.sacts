#!/usr/bin/env bash
# K3s 同步一体化脚本:按步骤参数(S1/S2/S3/S4)调用对应函数
# 调用方式: bash synck3s.sh S1 | S2 | S3 | S4
# 入参(环境变量):
#   WANT     - 可选版本约束:
#              空                -> 最新四个稳定版本
#              v1.31 / 1.31       -> 1.31 系列最新稳定版
#              v1.31.0+k3s1       -> 精确版本(须为稳定版)
#   WXAIR    - 是否包含离线镜像包 airgap images(默认 1:含;0:仅主二进制)
#   API      - GitHub releases API(默认 k3s-io/k3s)
#   GH_TOKEN - 由 action.yaml 在 S1/S4 步骤注入:S1 拉取 GitHub API,S4 供 gh 发布使用
# 产物与步骤:
#   S1 解析稳定版本 -> 生成各版本 ${VN}-binfiles.txt(下载 URL 清单)与 ${VN}-manifest.txt(sha256+文件名),
#      并把版本列表写入 FILE_VERSIONS(versions.txt)
#   S2 循环下载到 dist/${VN}/
#   S3 用 ${VN}-manifest.txt 做 sha256sum -c 校验(无清单则跳过)
#   S4 逐个版本 gh release create 发布(首个标 --latest,已存在则先删后建)
set -euo pipefail
main() {
  export CURL_OPTS="--retry 3 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 1800"
  export RUNNER_TEMP="${RUNNER_TEMP:-$PWD}"
  export FILE_VERSIONS="${RUNNER_TEMP}/versions.txt"
  export FILE_RELSJSON="${RUNNER_TEMP}/releases.json"
  export FILE_ALL_TAGS="${RUNNER_TEMP}/all_tags.txt"
  export URL_API="${API:-https://api.github.com/repos/k3s-io/k3s/releases}"
  export URL_BASE="https://github.com/k3s-io/k3s/releases/download/"
  export GHCDN="${GHCDN:-https://ghfast.top/}"
  # ---------- S1: 解析版本并生成下载/校验清单 ----------
  step1() {
    # 1) 分页拉取全部 release 并合并成单个 releases.json(若已存在则复用)
    if [ ! -e "${FILE_RELSJSON}" ]; then
      echo '[]' > "${FILE_RELSJSON}"
      rm -f pjson tmp.json
      local page=1 cnt
      while true; do
        if ! curl ${CURL_OPTS} -fsSL "${URL_API}?per_page=100&page=${page}" -o pjson; then
          echo "::error::拉取 release 列表失败: ${URL_API}"
          exit 1
        fi
        cnt=$(jq 'length' pjson)
        [[ "${cnt}" -eq 0 ]] && break
        jq -s '.[0] + .[1]' "${FILE_RELSJSON}" pjson > tmp.json && mv tmp.json "${FILE_RELSJSON}"
        page=$((page + 1))
        [[ ${page} -gt 10 ]] && break
      done
    fi
    rm -f pjson tmp.json
    # 2) 过滤稳定 tag(排除预发布/草稿,格式 vX.Y.Z+k3sN)
    jq -r '.[] | select(.prerelease==false and .draft==false) | .tag_name
           | select(test("^v[0-9]+[.][0-9]+[.][0-9]+[+]k3s[.]?[0-9]+$"))' \
      "${FILE_RELSJSON}" > "${FILE_ALL_TAGS}"

    # 3) 按 WANT 选择版本(列表已按时间倒序,最新在前)
    local VN
    if [[ -n "${WANT:-}" ]]; then
      VN=$(awk -v p="v${WANT#[Vv]}" 'index($0,p)==1{print;exit}' "${FILE_ALL_TAGS}")
      if [[ -z "${VN}" ]]; then
        echo "::error::未匹配到任何稳定版本(输入: ${WANT})"
        exit 1
      fi
      printf '%s\n' "${VN}" > "${FILE_VERSIONS}"
    else
      head -n 4 "${FILE_ALL_TAGS}" > "${FILE_VERSIONS}"
    fi
    if [[ $(wc -l < "${FILE_VERSIONS}") -eq 0 ]]; then
      echo "::error::未匹配到任何稳定版本(输入: ${WANT:-<空>})"
      exit 1
    fi

    # 4) 逐版本生成下载清单 ${VN}-binfiles.txt 与校验清单 ${VN}-manifest.txt
    local VN mf PAT
    PAT='^sha256sum-.*[.]txt$'
    for VN in $(xargs < "${FILE_VERSIONS}"); do
      [[ -z "${VN}" ]] && continue
      # echo "=====> [S1] 处理版本: ${VN}"
      local bf="${RUNNER_TEMP}/${VN}-binfiles.txt"
      local mf="${RUNNER_TEMP}/${VN}-manifest.txt"
      # 4a) 下载清单:该版本资产(按 PAT 过滤)的 browser_download_url,直接采用官方完整 URL(已含 %2B 等转义)
      local jqpat='.[] | select(.tag_name=="'${VN}'") | .assets[]'
      jqpat+='| select(.name|test("^sha256sum-.*[.]txt$"))|.browser_download_url'
      for u in $(jq -r "${jqpat}" "${FILE_RELSJSON}"); do
        curl -4fsSL "${GHCDN}${u}"
      done > $mf
      if [[ ! -s "${mf}" ]]; then
        echo "::error::版本 ${VN} 未找到可下载资产"
        exit 1
      fi

      # echo "::notice::${VN} 生成 $(wc -l < "${mf}") 条校验项"
      local jqpat_bindlurls='.[] | select(.tag_name=="'${VN}'") | .assets[]'
      jqpat_bindlurls+='| select(.name == $cf)| .browser_download_url'
      for CF in $(awk '{print $2}' "${mf}"); do
        jq -r --arg cf "${CF}" "${jqpat_bindlurls}" "${FILE_RELSJSON}"
      done > $bf
    done
    echo "解析到版本: $(xargs < "${FILE_VERSIONS}") (共 $(wc -l < "${FILE_VERSIONS}") 个)"
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
  step4() {
    local VN first=1
    shopt -s nullglob
    for VN in $(xargs < "${FILE_VERSIONS}"); do
      [[ -z "${VN}" ]] && continue
      echo "=====> [S4] 发布版本: ${VN}"
      if [[ ! -d "dist/${VN}" ]] || [[ $(find "dist/${VN}" -type f | wc -l) -eq 0 ]]; then
        echo "::error::${VN} 无可发布文件"
        exit 1
      fi
      if gh release view "$VN" > /dev/null 2>&1; then
        echo "::notice::已存在 release ${VN}, 先删除再重建"
        gh release delete "$VN" -y
      fi
      local NOTES="同步自 K3s GitHub Releases 的二进制程序 (版本: ${VN}, 官网: ${URL_BASE}${VN})"
      if [[ ${first} -eq 1 ]]; then
        gh release create "$VN" dist/"$VN"/* \
          --title "K3s ${VN} Binaries" \
          --notes "${NOTES}"
        first=0
      else
        gh release create "$VN" dist/"$VN"/* \
          --title "K3s ${VN} Binaries" \
          --notes "${NOTES}" \
          --latest=false
      fi
    done
  }

  # ---------- 调度 ----------
  case $1 in
    [Ss][1234]) eval "step${1#[sS]}" ;;
    *) echo "用法: $0 S1|S2|S3|S4" && exit 1 ;;
  esac
}
main "$@"
