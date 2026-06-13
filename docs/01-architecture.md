# 01. 架构:为什么用独立配置仓库

## 鸡生蛋问题

把 workflow 文件放到主 fork 上会导致自毁循环:

```
你把 yml 推到 fork master
    ↓
fork master 比 upstream 多 1 个 commit (yml 本身)
    ↓
workflow 跑,compare 返回 ahead=1
    ↓
执行 Discard commits,把 master hard reset 到 upstream 的 SHA
    ↓
.yml 文件被删
    ↓
下次 schedule 触发,yml 没了,workflow 找不到定义 → 再也不跑了
```

**根本原因**:workflow 文件本身就是 fork master 的"内容",Discard commits 等于把整个 master 内容替换成 upstream 的,yml 必然跟着没。

---

## 正确架构

把 workflow 放到**独立的配置仓库**中,主 fork 保持纯内容:

```
你的 GitHub 账号/
├── <fork-name>/              # 主 fork,只装 upstream 镜像内容
└── <fork-name>-sync/         # 配置仓库,只装 .github/workflows/sync-dynamic.yml
```

**优点**:
- ✅ 主 fork 永远跟 upstream 1:1 镜像,**0 个 ahead commit**
- ✅ 配置独立,改 yml 不污染主 fork 的 git 历史
- ✅ 多个 fork 可共用同一个配置仓库(详见 [06-multi-fork.md](06-multi-fork.md))
- ✅ 是 GitHub 官方推荐的 "configuration repository" / "reusable workflow" 模式

---

## 放哪里最稳?三个选项对比

**Q: 这些文件是不是直接放到我 GitHub 账号下任何一个仓库的分支里面就可以达到自动同步的效果?**

**A: 不行,放错地方会自毁。**

### 三种放法对比

| 放哪里 | 能不能跑 | 后果 |
|---|---|---|
| fork 自己 | ❌ | yml 把自己删了 |
| 非 fork 仓库(你建的) | ✅ | 正常工作 |
| 别人的仓库 | ❌ | 你没权限改 Settings |

### 为什么放 fork 自己会自毁

yml 的设计是「用一个独立配置仓库去同步目标 fork」。如果把 yml 放在 fork 本身,yml 文件会变成 fork 的本地提交;纯 `ahead` 时现在会跳过,但只要 upstream 后续也有新增,默认 `discard_local_changes: force` 仍会在备份后执行 Discard commits,这个 workflow 文件会被移走。

如果把 yml 放在 fork 本身:
- yml 本身就是 fork 比 upstream 多出来的那个 commit
- workflow 遇到纯 `ahead` → 暂时跳过
- upstream 后续新增 commit → 分支变成 `diverged` → 默认 Discard commits 对齐 upstream,这个 yml 文件被移走
- 下次再跑 → yml 已经没了 → 整个机制消失

### 非 fork 仓库天然解决两个 fork 上的麻烦

放在非 fork 仓库后,下面这两件事就都不是问题了:

**1. Workflow permissions 默认就开**

- fork 仓库:得手动去 `Settings → Actions → General → Workflow permissions` 改成 **Read and write permissions**,否则所有 `gh api` 写操作都会 403。
- 非 fork 仓库:配一次就够,设置跟 fork 无关。

**2. 定时任务默认开启**

- fork 仓库:schedule 触发器默认被禁用,要去 Actions 标签页点 "I understand my workflows, go ahead and enable them" 那个黄色提示。
- 非 fork 仓库:schedule 触发器默认就是开的,什么也不用做。

### 放哪个非 fork 仓库都行

两种选择:

- **新建专门的配置仓库**(推荐,本项目就是这个架构):`Link-Start/<fork-name>-sync`
- **放你已有的非 fork 仓库**(比如 `Link-Start/dotfiles`、`Link-Start/notes` 之类)

yml 里通过 env 变量指定要同步的 fork 和上游:

```yaml
env:
  UPSTREAM_OWNER: cv-cat
  UPSTREAM_REPO: Spider_XHS
  MY_OWNER: Link-Start
  FORK_REPO: Spider_XHS_cv-cat
```

如果你用「动态发现」风格的 yml(见 [06-multi-fork.md](06-multi-fork.md)),yml 里就不用 hardcode fork,**任何一个非 fork 仓库都能同步你名下所有 fork**。

---

## 实际部署示例

本仓库用的就是这套:

```
Link-Start/
├── Spider_XHS_cv-cat/                # 主 fork
└── Spider_XHS_cv-cat-sync/           # 配置仓库 (跟 fork-sync-template 是同一套结构)
    ├── .github/workflows/
    │   └── sync-dynamic.yml          # 动态发现风格
    └── README.md
```

---

## 文件结构对照

### 模板仓库(本仓库 fork-sync-template)

```
fork-sync-template/
├── .github/
│   └── workflows/
│       └── sync-dynamic.yml          # 作者日常使用版 (动态发现 + 默认排除 claude 相关)
├── examples/
│   ├── sync-dynamic.yml              # 通用模板: 动态发现版 (同步所有 fork)
│   └── sync-static.yml               # 通用模板: 静态 matrix 版 (要手写 fork 列表)
├── scripts/                           # 动态 workflow 运行脚本和 helper
│   ├── read-config.sh                 # 读取 .github/sync-config.yml 覆盖配置
│   ├── discover-forks.sh              # 动态发现 fork 并补齐 upstream 元数据
│   ├── sync-each-fork.sh              # 并发同步编排
│   ├── fork-worker.sh                 # 单 fork 同步主流程
│   ├── detect-drift.sh                # 连续失败 drift 检测和状态写回
│   ├── post-issue-summary.sh          # 同步结果 issue 汇总
│   ├── send-webhook.sh                # Slack / 钉钉 / 通用 webhook 通知
│   ├── github-api.sh                  # gh api 重试、错误解析、upstream 探测
│   ├── git-cli.sh                     # git 签名比较 helper
│   └── common.sh                      # 通用日志函数
├── docs/                              # 10 个独立文档
│   ├── 01-architecture.md            # ← 你正在读
│   ├── 02-setup.md
│   ├── 03-api-flow.md
│   ├── 04-backup-faq.md
│   ├── 05-scenarios.md
│   ├── 06-multi-fork.md
│   ├── 07-skip-mechanisms.md
│   ├── 08-advanced.md
│   ├── 09-template-distribution.md
│   └── 10-roadmap.md
├── README.md                          # 模板快速开始
└── .gitignore
```

### GitHub 上(运行用)

```
你的 GitHub 账号/
├── <fork-name>/                # 主 fork,装 upstream 镜像内容,不放 workflow
└── <fork-name>-sync/           # 独立配置仓库,装 .github/workflows/sync-dynamic.yml
    ├── .github/workflows/
    │   └── sync-dynamic.yml
    ├── scripts/
    │   └── *.sh
    └── README.md (可选,简单说明)
```

详细部署步骤见 [02-setup.md](02-setup.md)。
