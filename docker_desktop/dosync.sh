#!/usr/bin/env bash
# Docker Desktop 同步一体化脚本:按 CS 环境变量(1~4)调用对应函数
# 调用方式: CS=1 bash dosync.sh (阶段 1~4,如 CS=2;不传 CS 报错退出)
# 说明: Docker Desktop 为每日构建,不解析版本号,而是按日期打标签(vYYYY.MM.DD),
#       从固定 URL 下载各平台安装包;上游无官方哈希,故 S3 为空操作(跳过校验)。
# 产物与步骤:
#   S1 生成日期标签 -> 写入 FILE_VERSIONS(versions.txt)(一行,即当日标签)
#   S2 下载各平台安装包到 dist/(扁平存放,不按版本分子目录)
#   S3 无官方哈希,跳过校验(空操作)
#   S4 gh release create 发布(已存在则先删后建)
# 注意: S4 需要 action.yaml 注入的 GH_TOKEN / GH_REPO 供 gh CLI 使用(步骤内不 checkout,无 .git)
set -euo pipefail
main() {
  export CURL_OPTS="--retry 3 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 1800"
  export RUNNER_TEMP="${RUNNER_TEMP:-$PWD}"
  export FILE_VERSIONS="${RUNNER_TEMP}/versions.txt"

  # ---------- S1: 生成日期标签 ----------
  step1() {
    local vtag="v$(date +'%Y.%m.%d')"
    # : > "${FILE_VERSIONS}"
    echo "${vtag}" > "${FILE_VERSIONS}"
    echo "生成的发布标签为: ${vtag}"
  }

  # ---------- S2: 下载各平台安装包 ----------
  step2() {
    mkdir -p dist
    # URL|本地文件名
    local entries=(
      "https://get.docker.com|linux.sh"
      "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe|docker_desktop_installer_windows_amd64.exe"
      "https://desktop.docker.com/win/main/arm64/Docker%20Desktop%20Installer.exe|docker_desktop_installer_windows_arm64.exe"
      "https://desktop.docker.com/linux/main/amd64/docker-desktop-amd64.deb|docker_desktop_installer_linux_amd64.deb"
      "https://desktop.docker.com/linux/main/amd64/docker-desktop-x86_64.rpm|docker_desktop_installer_linux_amd64.rpm"
      "https://desktop.docker.com/mac/main/amd64/Docker.dmg|docker_desktop_installer_darwin_amd64.dmg"
      "https://desktop.docker.com/mac/main/arm64/Docker.dmg|docker_desktop_installer_darwin_arm64.dmg"
    )
    local entry url name
    for entry in "${entries[@]}"; do
      url="${entry%%|*}"
      name="${entry##*|}"
      echo "  -> 下载: ${name}"
      if ! curl ${CURL_OPTS} -4fL -o "dist/${name}" "${url}"; then
        echo "::error::下载失败: ${url}"
        exit 1
      fi
    done
    echo "下载完成,文件数: $(find dist -type f | wc -l)"
  }

  # ---------- S3: 校验(无官方哈希,跳过) ----------
  step3() {
    echo "Docker Desktop 安装包无官方哈希校验,跳过 S3"
  }

  # ---------- S4: 发布到 GitHub Releases ----------
  # 已存在的 release 先删除再重建,保证可重复运行(同一天重跑也不会失败)。
  # 需要 GH_TOKEN/GH_REPO(由 action.yaml 的 S4 步骤注入)供 gh CLI 使用。
  step4() {
    local tag
    shopt -s nullglob
    if [[ $(find dist -type f | wc -l) -eq 0 ]]; then
      echo "::error::dist/ 无可发布文件,请先运行 S2"
      exit 1
    fi
    while IFS= read -r tag; do
      [[ -z "${tag}" ]] && continue
      echo "=====> [S4] 发布标签: ${tag}"
      if gh release view "${tag}" > /dev/null 2>&1; then
        echo "::notice::已存在 release ${tag}, 先删除再重建"
        gh release delete "${tag}" -y
      fi
      gh release create "${tag}" dist/* \
        --title "Daily Build - ${tag}" \
        --notes "这是一个自动生成的每日构建发布。
        - 构建时间: ${tag}"
    done < "${FILE_VERSIONS}"
  }

  # ---------- 调度 ----------
  case ${CS:-} in
    [1234]) eval "step${CS}" ;;
    *) echo "::error::非法阶段 CS=${CS:-<空>}(仅支持 1~4)" && exit 1 ;;
  esac
}
main "$@"
