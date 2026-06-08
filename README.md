# Fork Sync Template

> 一套用于自动把 fork 仓库同步到上游 (upstream) 的 GitHub Actions 模板
> **GitHub CLI/API 实现 · checkout 配置仓库脚本 · 自动备份 · 免维护 fork 列表**

---

## 这是什么

一个**可直接 fork 使用的 GitHub 模板仓库**。本仓库的 `.github/workflows/sync-dynamic.yml` 是作者日常使用配置(自动排除 claude 相关库);`examples/` 下放两种风格的**通用模板**(不放在 `.github/workflows/` 里所以不会被自动跑,fork 者可按需启用)。

**核心特性**:
- ✅ 纯 GitHub REST API,只 checkout 配置仓库脚本,不 checkout 目标 fork、不 git push
- ✅ 动态发现模式,自动列出你名下所有 fork
- ✅ 支持名称/owner 模式排除(自动跳过指定 fork)
- ✅ 自动检测 fork 的"超前/落后"状态
- ✅ 支持所有分支同步 (不只默认分支)
- ✅ 自动 backup tag (最多保留 20 个)
- ✅ 手动安全清理 local-backup 备份分支
- ✅ master / main 双默认分支兼容
- ✅ 上游删库 / archived 友好 skip
- ✅ 新分支自动拉,旧分支自动保
- ✅ 跳过机制灵活 (per-fork `.no-sync` 或 config-repo `skip.txt`)

---

## 文件结构

```
fork-sync-template/
├── .github/
│   ├── sync-config.yml.example       # 可选本地配置示例
│   └── workflows/
│       ├── sync-dynamic.yml          # ✅ 作者日常使用配置 (默认排除 claude 相关 fork)
│       ├── health-check.yml          # 独立健康检查
│       ├── rollback.yml              # 手动回滚 backup tag
│       └── cleanup-local-backups.yml # 安全清理 local-backup 备份分支
├── examples/                          # 两种风格的通用模板 (fork 后不会被自动跑)
│   ├── sync-dynamic.yml              # 通用动态发现 (排除 pattern 为空,同步所有 fork)
│   └── sync-static.yml               # 通用静态 matrix (需要手写 fork 列表)
├── scripts/                           # 动态 workflow 运行脚本和 helper
│   ├── read-config.sh                 # 读取 .github/sync-config.yml 覆盖配置
│   ├── discover-forks.sh              # 动态发现 fork 并补齐 upstream 元数据
│   ├── sync-each-fork.sh              # 并发同步编排
│   ├── fork-worker.sh                 # 单 fork 同步主流程
│   ├── detect-drift.sh                # 连续失败 drift 检测和状态写回
│   ├── post-issue-summary.sh          # 同步结果 issue 汇总
│   ├── send-webhook.sh                # Slack / 钉钉 / 通用 webhook 通知
│   ├── github-api.sh                  # gh api 重试、错误解析、upstream 探测
│   ├── git-cli.sh                     # git fetch / merge-base / patch-id 签名方法
│   └── common.sh                      # 通用结构化事件日志
├── docs/                              # 10 个独立文档
│   ├── 01-architecture.md
│   ├── 02-setup.md
│   ├── 03-api-flow.md
│   ├── 04-backup-faq.md
│   ├── 05-scenarios.md
│   ├── 06-multi-fork.md
│   ├── 07-skip-mechanisms.md
│   ├── 08-advanced.md
│   ├── 09-template-distribution.md
│   └── 10-roadmap.md
├── README.md                          # 本文件
└── .gitignore
```

---

## 怎么用

### 方式 1: 直接用默认配置 (排除 claude 相关)

最简单,不用维护 fork 列表:

1. **Fork 这个仓库** (点页面右上角的 Fork 按钮)
2. **配置跨仓库 token**: 在配置仓库 Settings → Secrets and variables → Actions 新增 `FORK_SYNC_TOKEN`,值用你自己的 PAT,至少给目标 fork 仓库 `Contents: Read and write` 权限。
3. **开 workflow 写权限**: 进你 fork 后的仓库 → Settings → Actions → General → Workflow permissions → 选 **Read and write permissions** → Save
4. **开定时任务**: 进 Actions 标签页 → 看到黄色提示 "Workflows aren't being run on this forked repository" → 点 **"I understand my workflows, go ahead and enable them"**
5. **完事。** `sync-dynamic.yml` 会自动跑,扫描你名下所有 fork,**自动跳过名称含 "claude" 的 fork**,逐个同步其他。

**想改排除的关键词?** 编辑 `.github/workflows/sync-dynamic.yml` 里的 `DEFAULT_EXCLUDE_PATTERN: 'claude'`,改其他词或留空。

### 方式 2: 用通用动态模板 (不过滤任何 fork)

如果默认的"排除 claude"不符合你的需要:

1. **Fork 这个仓库**
2. **用 `examples/sync-dynamic.yml` 替换默认 yml**:
   - 进 `.github/workflows/`,删掉 `sync-dynamic.yml`
   - 把 `examples/sync-dynamic.yml` 复制/移动到 `.github/workflows/sync-dynamic.yml`
3. **保留 `scripts/` 目录**: 动态 workflow 会 checkout 当前配置仓库并执行 `scripts/*.sh`
4. **开写权限 + 开定时任务** (跟方式 1 的 2/3 步一样)
5. 完事。yml 会同步你名下**所有** fork (无排除)。

### 方式 3: 用静态 matrix (精确控制同步列表)

如果你的 fork 列表固定,想硬编码:

1. **Fork 这个仓库**
2. **编辑 `examples/sync-static.yml`**: 把 `matrix.fork:` 列表改成你自己的 fork
3. **把改好的文件移动到 `.github/workflows/sync-static.yml`** (在 .github/workflows/ 下点 Add file → Create new file,内容粘贴)
4. **删掉 `.github/workflows/sync-dynamic.yml`** (避免重复)
5. **开写权限 + 开定时任务**

### 跳过某些特定 fork (细粒度跳过)

动态版 workflow 内置两种执行阶段跳过机制:
- 在那个 fork 自己的仓库加 `.github/.no-sync` 文件,内容随便写 (推荐)
- 在这个配置仓库根目录加 `skip.txt`,每行一个 fork 名

静态 matrix 版最直接的跳过方式是从 `matrix.fork` 列表删掉对应项。

详见 [docs/07-skip-mechanisms.md](docs/07-skip-mechanisms.md)。

---

## 两种风格的差异 (动态 vs 静态)

| 维度 | 动态发现 (sync-dynamic) | 静态 matrix (sync-static) |
|---|---|---|
| yml 复杂度 | 中等 (有循环逻辑) | 简单 (几行 matrix) |
| **fork 者要不要改 yml** | 不用 (改 env 即可) | ✅ 要 (改 matrix 列表) |
| 新增 fork | 自动包含 | 手动加 matrix 项 |
| 删除 fork | 自动跳过 | 手动删 matrix 项 |
| 排除某些 fork | 改 EXCLUDE_PATTERN 即可 | 在 matrix 删对应行 |
| 适合谁 | fork 列表会变 / 不想维护 matrix | fork 数量固定 / 想精确控制 |

详细对比见 [docs/06-multi-fork.md](docs/06-multi-fork.md)。

---

## 📚 详细文档

按主题拆成 10 个独立文档,按需阅读:

| # | 文档 | 内容 | 何时读 |
|---|---|---|---|
| 1 | [docs/01-architecture.md](docs/01-architecture.md) | 为什么用独立配置仓库(鸡生蛋问题) | 想理解架构设计 |
| 2 | [docs/02-setup.md](docs/02-setup.md) | 一次性配置 4 步 + 触发机制 | **第一次部署必看** |
| 3 | [docs/03-api-flow.md](docs/03-api-flow.md) | 4 个核心 API + 5 阶段执行流程 | 想理解技术细节 |
| 4 | [docs/04-backup-faq.md](docs/04-backup-faq.md) | 备份与回退 + 15 个 FAQ | 出问题查表 |
| 5 | [docs/05-scenarios.md](docs/05-scenarios.md) | 10 个典型场景处理(新增上游删源码防护) | 遇到具体场景查表 |
| 6 | [docs/06-multi-fork.md](docs/06-multi-fork.md) | 两种风格对比(动态发现 vs 静态 matrix) | 想理解两种风格的区别 |
| 7 | [docs/07-skip-mechanisms.md](docs/07-skip-mechanisms.md) | 怎么让某些 fork 不参与同步 | 有不想同步的 fork |
| 8 | [docs/08-advanced.md](docs/08-advanced.md) | 网络重试、通知、reusable workflow | 想深度定制 |
| 9 | [docs/09-template-distribution.md](docs/09-template-distribution.md) | 模板分发的设计思路 | 想理解这个模板为什么这么设计 |
| 10 | [docs/10-roadmap.md](docs/10-roadmap.md) | 17 项优化路线图(4 个 Wave,**全部完成**) | 想看历史/未来要做什么 |

---

## 手动触发筛选方式

动态版 yml 支持手动触发时缩小同步范围,适合先单仓库测试再跑全量:

| 方式 | 怎么用 | 匹配什么 | 适合 |
|---|---|---|---|
| `only_repos` (指定名) | 填 `lanhu-mcp_dsphper` 或 `Link-Start/lanhu-mcp_dsphper` | fork **仓库名**或 `owner/repo` 精确匹配 | 只跑一个或几个 fork 做测试 |
| `upstream_owner_filter` (正向) | 填 `cv-cat` | 只保留**上游 owner** 是这个的 fork | 只想同步某个作者旗下的 fork |
| `exclude_pattern` (关键字) | 填 `claude` | fork **仓库名**包含关键字 (大小写不敏感) | 一次性排除一类 (如所有 anthropic/claude 库) |
| `exclude_repos` (指定名) | 填 `my-test,legacy-fork` | fork **仓库名**精确匹配列表中的任一 | 排除几个特定的 |

**示例** (手动触发时):
- `only_repos=lanhu-mcp_dsphper` → 只同步这一个 fork,用于快速验证逻辑
- `only_repos=Link-Start/lanhu-mcp_dsphper,Link-Start/freeCodeCamp-freeCodeCamp` → 只同步这两个 fork
- 如果某个分支和 upstream 没有共同祖先,默认 `discard_local_changes=force` 会先建 `local-backup/*`,再执行等价 GitHub `Discard commits` 的强制同步
- `exclude_pattern=claude` → 跳过 `claude-code`、`my-claude-fork`、`ClaudeTest`
- `exclude_repos=spider-xhs-test,my-experiment` → 只跳过这两个特定的
- 组合填: `upstream_owner_filter=cv-cat` + `exclude_pattern=test` + `exclude_repos=legacy-thing` → 只同步 cv-cat 旗下、名字不含 test、且不是 legacy-thing 的 fork

> 仓库自带的自动跳过(`.github/.no-sync` 文件)依然生效,跟上面这些筛选条件独立。详见 [docs/07-skip-mechanisms.md](docs/07-skip-mechanisms.md)。

---

## 🌿 分支数量保护

默认每个 fork 只同步 upstream 的前 6 个分支,避免某些上游几百个分支导致 API 调用暴涨或限流。upstream 默认分支会被放到第一位,一定优先处理;超出上限的其他分支本次暂不处理,不是失败。

默认还会跳过这些自动生成/备份类 upstream 分支:`backup/*,local-backup/*,sync-upstream/*,dependabot/*`。默认分支不受跳过规则影响;放进 `full_branch_sync_repos` 的仓库也不受跳过规则影响。

长期配置写到 `.github/sync-config.yml`,手动测试也可以在 workflow input 里临时填同名字段:

```yaml
max_branches_per_fork: 6
skip_branch_patterns: "backup/*,local-backup/*,sync-upstream/*,dependabot/*"

# 指定仓库同步全部分支
full_branch_sync_repos: "repo-a,Link-Start/repo-b"

# 按分支数分组指定 fork,支持任意数量规格
# 例子: repo-c/repo-d 同步 3 个分支,repo-e/repo-f 同步 4 个分支,repo-g 同步 100 个分支
branch_limit_groups: "3:repo-c,repo-d;4:repo-e,repo-f;100:repo-g"

# 单仓库精确覆盖;0 表示该仓库不限制
branch_limit_overrides: "repo-h=12,Link-Start/repo-i=20,repo-j=0"
```

`branch_limit_groups` 的格式是 `分支数:仓库1,仓库2;分支数:仓库3,仓库4`。分支数支持任意非负整数,不需要新增字段;`0` 表示不限制,同步全部 upstream 分支。

优先级:`full_branch_sync_repos` > `branch_limit_overrides` > `branch_limit_groups` > `max_branches_per_fork`。

---

## 🛑 上游删源码防护 (体积暴减检测)

**最危险的场景:upstream 删了所有源码只留一个 README/说明文件,旧版会乖乖同步把 fork 源码也删光。**

新版加了"体积暴减检测",sync 前会比对 fork 和 upstream 的 `size`:

| 条件 | 行为 |
|---|---|
| fork < 50KB | 跳过检测 (避免误杀小项目) |
| upstream 不可访问或 parent 丢失 | **先创建/复用 `local-backup/*` 保护备份,再跳过同步** |
| upstream 体积 = 0KB 且阈值 > 0 | **先创建/复用 `local-backup/*` 保护备份,再跳过同步**,标注上游仓库为空或源码不可用 |
| upstream 体积 < fork × `size_drop_threshold` | **先创建/复用 `local-backup/*` 保护备份,再跳过同步**,打 `::error::` 红色警报 |
| upstream 体积 ≥ fork × `size_drop_threshold` | 通过,正常 sync |

这些保护性跳过场景不会执行 merge、PATCH、Discard commits 或任何会改写 fork 分支的同步操作。

保护备份复用规则:如果没有标准 `local-backup/*` 备份就创建;如果已有备份分支包含当前 fork 默认分支 HEAD,说明当前 fork 的所有提交已经被备份,直接跳过新备份;如果已有备份不包含当前 HEAD,说明 fork 后续又有新提交,会再次创建保护备份。

**`size_drop_threshold` 可调** (默认 `0.10` = 10%):
- `0.10` (默认) — 敏感,推荐大多数人
- `0.30` — 宽松,大重构可能误判
- `0` — 关闭检测 (不推荐)

**手动触发**:
- 填 `size_drop_threshold=0.05` → 5% 触发 (更敏感)
- 留空 → 用默认 (yml 里的 `DEFAULT_SIZE_DROP_THRESHOLD`)

**误报时怎么办**:临时把阈值改成 `0` 跑一次,或直接删 fork。详见 [docs/05-scenarios.md](docs/05-scenarios.md) 场景 10。

---

## 🛡️ 本地修改自动备份 (local-backup 分支)

**场景**:你在 fork 的某个分支(比如 `master`)直接改了东西,忘了建独立分支。等 upstream 也有新 commit 时,下一次 sync 需要处理“upstream 新增 + fork 本地提交”的分歧。

**新版防护**:workflow 会先判断是否真的需要备份,再把 fork 当前 SHA 存到:

```
local-backup/master-20260603-153045-a1b2c3d
   └─固定前缀   └─原分支名 └─时间戳   └─原 SHA 前 7 位
```

- upstream 没有新增(`behind_by = 0`)时跳过,不备份也不写分支
- 仅在 upstream 有新增(`behind_by > 0`)且 fork 有本地提交(`ahead_by > 0`)时创建
- 如果最近的 `local-backup/*` 已经包含相同本地 patch,跳过新备份
- 默认 `discard_local_changes: force` 会在备份后执行 GitHub `Discard commits` 语义,把 fork 分支硬重置到 upstream
- **不自动清理**(本地数据是你自己的,不像 backup tag 自动保留 20 个)
- 清理方法:用 `Cleanup Local Backup Branches` workflow,只允许删标准 `local-backup/*` 备份分支
- 找回方法:`git checkout local-backup/master-...` → 找 commit → cherry-pick 到新分支

详见 [docs/04-backup-faq.md](docs/04-backup-faq.md) 的"本地修改自动备份"章节。

---

## 安全性

- workflow 用的是 **你 (fork 者) 自己配置的 `FORK_SYNC_TOKEN`**,没配置时才回退当前仓库 `GITHUB_TOKEN`
- 不会访问模板作者 (`Link-Start`) 的任何东西
- 代码完全开源,所有逻辑可见,放心 fork

---

## License

MIT - 自由使用,自由修改。
