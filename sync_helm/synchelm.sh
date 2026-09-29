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
#   GH_TOKEN - 仅 S1 步骤注入,用于访问 GitHub API
# S1 会把 VTAG/BASE/VERSIONS 写回 GITHUB_ENV,并生成 ${RUNNER_TEMP}/versions.txt 与各版本清单
set -euo pipefail

# 全局下载选项:使用字符串(非数组)并导出,确保 xargs 派生的子 shell 中 download_one 也能继承
CURL_OPTS="--retry 3 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 1800"
export CURL_OPTS

main() {
  # ---------- S1: 解析版本并生成下载清单 ----------
  step1() {
    # auth 仅 S1 使用,且 GH_TOKEN 仅在 S1 步骤注入;定义在函数内避免其它步骤触发 set -u 未绑定错误
    local auth=(-H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json")

    # 1) 分页拉取全部 release 并合并成单个 releases.json
    local page=1
    echo '[]' > releases.json
    while true; do
      if ! curl ${CURL_OPTS} -fsSL "${auth[@]}" "${API}?per_page=100&page=${page}" -o page.json; then
        echo "::error::拉取 release 列表失败: ${API}"; exit 1
      fi
      local n; n=$(jq 'length' page.json)
      jq -s '.[0] + .[1]' releases.json page.json > releases.tmp.json && mv releases.tmp.json releases.json
      if [[ "$n" -lt 100 ]]; then break; fi
      ((page++))
    done

    # 2) 结构化稳定版: tag / major / series / v(数值数组, 便于排序)
    jq '[.[] | select(.prerelease==false and .draft==false and (.tag_name | test("-(rc|beta|alpha)") | not))]
      | map({tag:.tag_name,
             v:(.tag_name | sub("^v";"") | split(".") | map(tonumber)),
             major:("v" + (.tag_name | sub("^v";"") | split(".")[0])),
             series:("v" + (.tag_name | sub("^v";"") | split(".")[0:2] | join(".")))})' \
      releases.json > stable.json
    if [[ ! -s stable.json || "$(jq 'length' stable.json)" -eq 0 ]]; then
      echo "::error::未找到任何稳定版本"; exit 1
    fi

    # 3) 按 WANT 选择版本
    local want="${WANT:-}" out=""
    if [[ -z "$want" ]]; then
      # 不传: 各 major 取最新, 再取版本最新的两个 major
      out=$(jq -r 'group_by(.major) | map(sort_by(.v) | last) | sort_by(.v) | reverse | .[0:2] | .[].tag' stable.json)
    else
      want="${want#v}"
      local dots; dots=$(echo "$want" | tr -cd '.' | wc -c)
      if [[ "$dots" -eq 0 ]]; then
        out=$(jq -r --arg m "v$want" '[.[] | select(.major==$m)] | sort_by(.v) | last | .tag' stable.json)
      elif [[ "$dots" -eq 1 ]]; then
        out=$(jq -r --arg s "v$want" '[.[] | select(.series==$s)] | sort_by(.v) | last | .tag' stable.json)
      else
        out=$(jq -r --arg e "v$want" '.[] | select(.tag==$e) | .tag' stable.json)
      fi
    fi
    if [[ -z "$out" || "$out" == *"null"* ]]; then
      echo "::error::未匹配到任何稳定版本(输入: ${WANT:-<空>})"; exit 1
    fi

    # 4) 写出版本清单 + 各版本资产清单(供 s2/s3 循环), 并写 GITHUB_ENV
    : > "${RUNNER_TEMP}/versions.txt"
    local VN first_vn=""
    while IFS= read -r VN; do
      [[ -z "$VN" ]] && continue
      [[ -z "$first_vn" ]] && first_vn="$VN"
      echo "$VN" >> "${RUNNER_TEMP}/versions.txt"
      jq -r --arg t "$VN" '.[] | select(.tag_name==$t) | .assets[].name | select(endswith(".sha256.asc")) | rtrimstr(".sha256.asc")' releases.json \
        | grep -v 'loong' > "${RUNNER_TEMP}/${VN}.manifest.txt"
      if [[ ! -s "${RUNNER_TEMP}/${VN}.manifest.txt" ]]; then
        echo "::error::版本 $VN 未找到可下载资源"; exit 1
      fi
    done < <(printf '%s\n' "$out")

    {
      echo "VTAG=${first_vn}"
      echo "BASE=https://get.helm.sh/"
      echo "VERSIONS=${out//$'\n'/ }"
    } >> "$GITHUB_ENV"
    echo "解析到版本: ${out//$'\n'/ } (共 $(printf '%s\n' "$out" | wc -l) 个)"
  }

  # ---------- S2: 并行下载二进制包(按版本循环) ----------
  step2() {
    mkdir -p dist
    download_one() {
      local VN="$1" name="$2"
      mkdir -p "dist/${VN}"
      local url="${BASE}${name}"
      for i in 1 2 3; do
        if curl ${CURL_OPTS} -4fL -o "dist/${VN}/${name}" "${url}"; then
          return 0
        fi
        sleep $((i * 3))
      done
      echo "::error::下载失败: ${url}"
      return 1
    }
    export -f download_one
    local VN
    while IFS= read -r VN; do
      [[ -z "$VN" ]] && continue
      echo "=====> [S2] 下载版本: ${VN}"
      xargs -a "${RUNNER_TEMP}/${VN}.manifest.txt" -I{} -P 8 bash -c 'download_one "$1" "$2"' _ "${VN}" {}
    done < "${RUNNER_TEMP}/versions.txt"
    echo "下载完成,文件数: $(find dist -type f | wc -l)"
  }

  # ---------- S3: 校验 SHA256(按版本循环) ----------
  # Helm 的校验方式是联网取得 ${name}.sha256 与本地 sha256sum 比对(源站提供独立 .sha256 文件)
  step3() {
    local fail=0 VN name sum actual
    while IFS= read -r VN; do
      [[ -z "$VN" ]] && continue
      echo "=====> [S3] 校验版本: ${VN}"
      while IFS= read -r name; do
        sum=$(curl ${CURL_OPTS} -4fsSL "${BASE}${name}.sha256" | awk '{print $1}')
        actual=$(sha256sum "dist/${VN}/${name}" | awk '{print $1}')
        if [[ "${sum}" != "${actual}" ]]; then
          echo "::error::校验失败: ${VN}/${name}"
          fail=1
        fi
      done < "${RUNNER_TEMP}/${VN}.manifest.txt"
    done < "${RUNNER_TEMP}/versions.txt"
    exit ${fail}
  }

  # ---------- S4: 发布(占位) ----------
  # Helm 的发布由 action.yaml 中的 gh 循环步骤完成(逐个 tag 发布),
  # 本脚本不负责发布,此处保留空实现以对齐 S1..S4 统一调用约定。
  step4() {
    echo "::notice::Helm 发布由 action.yaml 的 gh 循环步骤处理,synchelm.sh 不执行 S4"
  }

  # ---------- 调度 ----------
  case $1 in
    [Ss][1234]) eval "step${1#[sS]}" ;;
    *)
      echo "::error::未知步骤: ${1:-<空>}, 用法: $0 S1|S2|S3|S4"
      exit 1
      ;;
  esac
}
main "$@"
