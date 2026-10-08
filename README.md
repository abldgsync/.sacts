# actions

本仓库存放一组**可复用的 GitHub 组合 Action(composite actions)**,供 `abldgsync` 组织下各工具仓库(如 `golang`,`kubectl`,`k3s` 等)通过 `uses:` 引用,把各官方源二进制/安装包同步发布到对应仓库的 Releases.

> 本地目录名 `actions/` 对应远端仓库 `abldgsync/actions`;引用时写 `abldgsync/actions/<tool>@main`.

## 📁 目录结构

```
actions/
├── golang/          # Go 二进制
│   ├── action.yaml
│   └── dosync.sh
├── helm/            # Helm 二进制
│   ├── action.yaml
│   └── dosync.sh
├── kubectl/         # kubectl 二进制
│   ├── action.yaml
│   └── dosync.sh
├── k3s/            # K3s 主二进制 + 离线镜像包(多版本)
│   ├── action.yaml
│   └── dosync.sh
├── ziglang/        # Zig 编译器
│   ├── action.yaml
│   └── dosync.sh
└── docker_desktop/ # Docker Desktop 安装包(按日期打标签的每日构建)
    ├── action.yaml
    └── dosync.sh
```

## 🧩 各模块一览

| 模块 | 同步内容 | 上游来源 | 校验方式 | 发布方式 |
| --- | --- | --- | --- | --- |
| `golang` | Go 编译器/工具链 | <https://go.dev/dl/> | SHA256 | `gh` CLI(`dosync.sh` S4) |
| `helm` | Helm 二进制 | <https://get.helm.sh/> | SHA256 | `gh` CLI(`dosync.sh` S4) |
| `kubectl` | kubectl 客户端/服务端/节点 | <https://dl.k8s.io> | SHA512 | `gh` CLI(`dosync.sh` S4) |
| `k3s` | K3s 主二进制 + 各架构离线镜像包 | <https://github.com/k3s-io/k3s/releases> | SHA256 | `gh` CLI(`dosync.sh` S4) |
| `ziglang` | Zig 编译器各平台归档 | <https://ziglang.org/download> | SHA256 | `gh` CLI(`dosync.sh` S4) |
| `docker_desktop` | Docker Desktop 安装包/脚本 | <https://desktop.docker.com> 等 | --(`CS=3` 跳过) | `gh` CLI(`dosync.sh` S4) |

## 🔧 脚本组织约定

各模块脚本按执行阶段拆分,存在两种组织方式:

- **单脚本模式(`golang` / `helm` / `kubectl` / `k3s` / `ziglang` / `docker_desktop`)**:目录下只有一个 `dosync.sh`,通过阶段参数(`CS`)调度:
  | 调用参数 | 阶段职责 |
  | --- | --- |
  | `CS=1 bash dosync.sh` | 解析版本号,生成下载/校验清单(写入 `$RUNNER_TEMP/versions.txt` 与各版本 manifest) |
  | `CS=2 bash dosync.sh` | 基于 `xargs -P 8` 并发下载到 `dist/${VN}/`(失败自动重试) |
  | `CS=3 bash dosync.sh` | 用官方哈希(`sha256sum` / `sha512sum -c`)逐文件校验 |
  | `CS=4 bash dosync.sh` | 用 `gh` CLI 逐个版本 `gh release create` 发布(首个标 `--latest`,已存在先删后建) |

- **`docker_desktop` 说明**:为每日构建(按日期打标签),无官方哈希,故 `CS=3` 为空操作(跳过校验);其余阶段与单脚本模式一致.

## 🚀 如何在工具仓库中引用

在各仓库的 `.github/workflows/dosync.yaml` 中:

```yaml
jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Sync Golang
        uses: abldgsync/actions/golang@main
        with:
          binvern: ''   # 不填则用最新稳定版,可手动指定版本号
```

各模块支持输入参数见对应 `action.yaml` 的 `inputs:`(常见有 `binvern`,`withairgap`,`withsvr` 等).

## ⚠️ 推送须知

- 引用的是 `<tool>/` 这个**目录**(组合 Action),因此必须**把整个目录连同其中的 `dosync.sh` 一起提交推送**,否则 `action.yaml` 中的 `bash "${{ github.action_path }}/dosync.sh"` 会找不到文件.
- 建议把 `@main` 钉成具体 commit SHA 以获得可复现构建.
- 脚本以 `bash <path>` 方式调用,不依赖文件可执行位(已 `chmod +x` 作为双保险).

## 🤝 新增一个同步模块

1. 在仓库根新建 `<tool>/`;
2. 提供 `action.yaml`(`using: composite`,`runs.steps` 中引用本仓库脚本);
3. 提供单脚本 `dosync.sh`(内部按 `CS=1~4` 调度,推荐),通过 `action.yaml` 的 `run:` 以 `CS=N bash "${{ github.action_path }}/dosync.sh"` 调用各阶段;
4. 在各工具仓库工作流中用 `uses: abldgsync/actions/<tool>@main` 引用.
