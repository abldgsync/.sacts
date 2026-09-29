#!/usr/bin/env bash
# 阶段1:解析需要同步的 K3s 版本列表,结果写入 ${RUNNER_TEMP}/versions.txt
# 入参(环境变量): WANT / API / GH_TOKEN
set -euo pipefail

jfile='rel.json'
auth=(-H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json")

# 复用过滤器:剔除预发布/草稿,取出稳定 tag 名(保持 GitHub 返回的倒序)
stable_tags='[.[]| select(.prerelease==false and .draft==false)'
stable_tags+='| .tag_name| select(test("^v[0-9]+[.][0-9]+[.][0-9]+[+]k3s[.]?[0-9]+$"))]'

# 分页拉取全部 release,合并成单个 ${jfile}
fetch_all() {
  [ -s "${jfile}" ] && return
  echo '[]' > "${jfile}"
  local page=1
  while true; do
    curl -fsSL --retry 3 --retry-delay 2 "${auth[@]}" "${API}?per_page=100&page=${page}" -o page.json
    local cnt; cnt=$(jq 'length' page.json)
    [[ "${cnt}" -eq 0 ]] && break
    jq -s '.[0] + .[1]' "${jfile}" page.json > rels.tmp.json
    mv rels.tmp.json "${jfile}"
    page=$((page + 1))
    [[ ${page} -gt 10 ]] && break
  done
}

# 无论是否指定 WANT,都先拉取全量 release 列表,再从 rel.json 中过滤
fetch_all
if [[ -n "${WANT:-}" ]]; then
  # 精确 tag 或系列前缀均可:取过滤后列表的首个(列表已倒序,即最新在前)
  VN=$(jq -r --arg p "${WANT}" "${stable_tags}"' | map(select(startswith($p))) | .[0] // empty' "${jfile}")
  if [[ -z "${VN}" ]]; then echo "::error::未找到匹配 ${WANT} 的稳定版本"; exit 1; fi
  printf '%s\n' "${VN}" > "${RUNNER_TEMP}/versions.txt"
else
  # GitHub /releases 默认按创建时间倒序返回,直接取前四个稳定版本
  mapfile -t VS < <(jq -r "${stable_tags}[0:4][]" "${jfile}")
  if [[ ${#VS[@]} -eq 0 ]]; then echo "::error::未解析到任何稳定版本"; exit 1; fi
  printf '%s\n' "${VS[@]}" > "${RUNNER_TEMP}/versions.txt"
fi

echo "解析到版本数: $(wc -l < "${RUNNER_TEMP}/versions.txt")"
cat "${RUNNER_TEMP}/versions.txt"
