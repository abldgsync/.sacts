# shared_actions

本仓库存放一组**可复用的 GitHub 组合 Action（composite actions）**，供 `abldgsync` 组织下各工具仓库（如 `golang`、`kubectl`、`k3s` 等）通过 `uses:` 引用，把各官方源二进制/安装包同步发布到对应仓库的 Releases。

> 本地目录名 `00_shared_actions/` 对应远端仓库 `abldgsync/shared_actions`；引用时写 `abldgsync/shared_actions/sync_<tool>@main`。

## 📁 目录结构

```
shared_actions/
├── sync_golang/          # Go 二进制
│   ├── action.yaml
│   └── scripts/  (s1_resolve.sh, s2_download.sh, s3_verify.sh)
├── sync_helm/            # Helm 二进制
│   ├── action.yaml
│   └── scripts/  (s1_resolve.sh, s2_download.sh, s3_verify.sh)
├── sync_kubectl/         # kubectl 二进制
│   ├── action.yaml
│   └── scripts/  (s1_resolve.sh, s2_download.sh, s3_verify.sh)
├── sync_k3s/            # K3s 主二进制 + 离线镜像包(多版本)
│   ├── action.yaml
│   └── scripts/  (s1_resolve.sh, s2_download.sh, s3_verify.sh, s4_publish.sh)
├── sync_zig/            # Zig 编译器
│   ├── action.yaml
│   └── scripts/  (s1_resolve.sh, s2_download.sh, s3_verify.sh)
└── sync_docker_desktop/ # Docker Desktop 安装包(脚本内联,未抽文件)
    └── action.yaml
```

## 🧩 各模块一览

| 模块 | 同步内容 | 上游来源 | 校验方式 | 发布方式 |
| --- | --- | --- | --- | --- |
| `sync_golang` | Go 编译器/工具链 | <https://go.dev/dl/> | SHA256 | `softprops/action-gh-release` |
| `sync_helm` | Helm 二进制 | <https://get.helm.sh/> | SHA256 | `softprops/action-gh-release` |
| `sync_kubectl` | kubectl 客户端/服务端/节点 | <https://dl.k8s.io> | SHA512 | `softprops/action-gh-release` |
| `sync_k3s` | K3s 主二进制 + 各架构离线镜像包 | <https://github.com/k3s-io/k3s/releases> | SHA256 | `gh` CLI（脚本内 `s4_publish.sh`） |
| `sync_zig` | Zig 编译器各平台归档 | <https://ziglang.org/download> | SHA256 | `softprops/action-gh-release` |
| `sync_docker_desktop` | Docker Desktop 安装包/脚本 | <https://desktop.docker.com> 等 | — | `softprops/action-gh-release` |

## 🔧 脚本命名约定

为便于维护，抽取出的脚本按执行阶段编号前缀命名：

| 文件名 | 阶段职责 |
| --- | --- |
| `s1_resolve.sh` | 解析版本号 + 生成下载/校验清单（`$RUNNER_TEMP/versions.txt`、`*.sums`） |
| `s2_download.sh` | 基于 `xargs -P 8` 并发下载（失败自动重试） |
| `s3_verify.sh` | 用官方哈希（`sha256sum`/`sha512sum -c`）逐文件校验 |
| `s4_publish.sh` | （仅 `sync_k3s`）用 `gh` CLI 发布到 Releases |

> 除 `sync_k3s` 因多版本 + `gh` 发布额外有 `s4_publish.sh` 外，其余模块到 `s3` 为止；它们的“发布”统一交由 `softprops/action-gh-release` 完成。

## 🚀 如何在工具仓库中引用

在各仓库的 `.github/workflows/dosync.yaml` 中：

```yaml
jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Sync Golang
        uses: abldgsync/shared_actions/sync_golang@main
        with:
          binvern: ''   # 不填则用最新稳定版,可手动指定版本号
```

各模块支持输入参数见对应 `action.yaml` 的 `inputs:`（常见有 `binvern`、`withairgap`、`withsvr` 等）。

## ⚠️ 推送须知

- 引用的是 `sync_<tool>/` 这个**目录**（组合 Action），因此必须**把整个目录连同 `scripts/` 子目录一起提交推送**，否则 `action.yaml` 中的 `bash "${{ github.action_path }}/scripts/..."` 会找不到文件。
- 建议把 `@main` 钉成具体 commit SHA 以获得可复现构建。
- 脚本以 `bash <path>` 方式调用，不依赖文件可执行位（已 `chmod +x` 作为双保险）。

## 🤝 新增一个同步模块

1. 在仓库根新建 `sync_<tool>/`；
2. 提供 `action.yaml`（`using: composite`，`runs.steps` 中引用本仓库脚本）；
3. 在 `scripts/` 下按 `s1~s3` 拆分逻辑（如需自定义发布再加 `s4_publish.sh`）；
4. 在各工具仓库工作流中用 `uses: abldgsync/shared_actions/sync_<tool>@main` 引用。
